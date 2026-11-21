package model

// D-pad inside a line that is shown broken over several rows (a long call or
// procedure header, one argument per row - format.odin call_rows):
//   Up / Down   move between those rows (then on to the next line as usual)
//   Left        at the first part of a row, wraps to the dot at the end of that row
// Lines shown as a single row behave the same way: Left on the first part goes to
// the last dot on the line.

// The visual row of each leaf of a line (all 0 when it's one row).
leaf_rows :: proc(n: Node) -> []int {
	leaves := line_leaves(n)
	out := make([]int, len(leaves), context.temp_allocator)
	if len(leaves) == 0 || !needs_break(n) do return out
	rows, ok := call_rows(n)
	if !ok do return out
	for u, k in leaves {
		for r, ri in rows do if u.fa >= r.start && u.fa < r.end { out[k] = ri; break }
	}
	return out
}

// Left: one part to the left; from the first part of a row, the dot at the end
// of that row (else its last part).
row_left :: proc(app: ^App) {
	n := app.doc.nodes[app.editor_line]
	leaves := line_leaves(n)
	if len(leaves) == 0 do return
	f := clamp(app.editor_field, 0, len(leaves) - 1)
	rows := leaf_rows(n)
	if f > 0 && rows[f - 1] == rows[f] {
		app.editor_field = f - 1
		return
	}
	// First part of its row: wrap to the row's end.
	last, last_dot := f, -1
	for k in f ..< len(leaves) {
		if rows[k] != rows[f] do break
		last = k
		if n.fields[leaf_primary_field(n, leaves[k])].slot do last_dot = k
	}
	app.editor_field = last_dot >= 0 ? last_dot : last
}

// Up/Down between the rows of the current line. Returns false when there's no
// row with parts further that way (the caller then moves to another line).
row_move :: proc(app: ^App, dir: int) -> bool {
	if on_dot(app) do return false
	n := app.doc.nodes[app.editor_line]
	leaves := line_leaves(n)
	if len(leaves) == 0 do return false
	rows := leaf_rows(n)
	f := clamp(app.editor_field, 0, len(leaves) - 1)
	if dir < 0 {
		// The nearest earlier row: its first part.
		for k := f - 1; k >= 0; k -= 1 {
			if rows[k] < rows[f] {
				r := rows[k]
				for k > 0 && rows[k - 1] == r do k -= 1
				app.editor_field = k
				return true
			}
		}
	} else {
		for k in f + 1 ..< len(leaves) {
			if rows[k] > rows[f] {
				app.editor_field = k
				return true
			}
		}
	}
	return false
}

// After moving onto a broken line from below, start on its last row (from above,
// on its first row) - so Up/Down read the rows in order.
row_enter :: proc(app: ^App, dir: int) {
	if on_dot(app) do return
	n := app.doc.nodes[app.editor_line]
	rows := leaf_rows(n)
	if len(rows) == 0 || rows[len(rows) - 1] == 0 do return // one row: keep the column
	if dir > 0 {
		app.editor_field = 0
		return
	}
	k := len(rows) - 1
	for k > 0 && rows[k - 1] == rows[len(rows) - 1] do k -= 1
	app.editor_field = k
}

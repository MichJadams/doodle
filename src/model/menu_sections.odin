package model

// Menu sections: a view's first `recent` entries (already imported / recently
// used imports, and procs / types / constants already used in this file) are
// shown as their own "RECENTLY USED" section; the rest start on a new row below.
// These procs map entries to grid cells and move between them with the D-pad.

// The grid cell of entry i: (row, col). The rest section starts on a new row.
menu_cell :: proc(v: ^MenuView, i: int) -> (row, col: int) {
	n := len(v.entries)
	cols := grid_cols(n)
	p := clamp(v.recent, 0, n)
	if i < p do return i / cols, i % cols
	rp := (p + cols - 1) / cols
	return rp + (i - p) / cols, (i - p) % cols
}

// The number of grid rows, and how many of them are the recent section.
menu_rows :: proc(v: ^MenuView) -> (rows, recent_rows: int) {
	n := len(v.entries)
	cols := grid_cols(n)
	p := clamp(v.recent, 0, n)
	rp := (p + cols - 1) / cols
	return rp + (n - p + cols - 1) / cols, rp
}

@(private = "file")
row_len :: proc(v: ^MenuView, r: int) -> int {
	n := len(v.entries)
	cols := grid_cols(n)
	p := clamp(v.recent, 0, n)
	rp := (p + cols - 1) / cols
	if r < rp do return min(cols, p - r * cols)
	return min(cols, (n - p) - (r - rp) * cols)
}

@(private = "file")
index_at :: proc(v: ^MenuView, r, c: int) -> int {
	n := len(v.entries)
	cols := grid_cols(n)
	p := clamp(v.recent, 0, n)
	rp := (p + cols - 1) / cols
	if r < rp do return r * cols + c
	return p + (r - rp) * cols + c
}

// menu_nav moves a view's selection with the D-pad (wrapping at the edges),
// respecting the recent section's separate rows. Without a recent section it
// behaves exactly like grid_nav.
menu_nav :: proc(v: ^MenuView, inp: Input) -> int {
	n := len(v.entries)
	if n <= 0 do return 0
	if v.recent <= 0 || v.recent >= n do return grid_nav(v.index, n, inp)
	rows, _ := menu_rows(v)
	r, c := menu_cell(v, clamp(v.index, 0, n - 1))
	if inp.left do c = c == 0 ? row_len(v, r) - 1 : c - 1
	if inp.right do c = c == row_len(v, r) - 1 ? 0 : c + 1
	if inp.up do r = r == 0 ? rows - 1 : r - 1
	if inp.down do r = r == rows - 1 ? 0 : r + 1
	c = min(c, row_len(v, r) - 1)
	return index_at(v, r, c)
}

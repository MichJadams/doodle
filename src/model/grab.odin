package model

// Refactor (RT+X by default): a menu with
//   Grab        lift the highlighted statement / block and move it (below)
//   Copy line   the same, but a copy moves and the original stays where it
//               was. A copy from inside a procedure can go into any procedure
//               (out of this one, past the others, into another); between
//               procedures it's drawn red and can't be dropped. B: no copy.
//
// Grab: lift the statement / block the RT walk last
// highlighted, move it up and down - into and out of loops and other blocks -
// then drop it.
//
//   Grab        lift the selection (a part of a line lifts its statement; a
//               block's header line lifts the whole block)
//   D-pad Up / Down   one step: past a statement; into a `for` / `if` / `when`
//               / `{ }` block it meets (Down: just under its header; Up: just
//               above its `}`); out of the block it's in at the block's edge
//               (above its header / below its `}`)
//   RT + Up / Down    jump past the whole statement or block above / below
//   X or A      drop it here (X with or without RT: the Grab press again, or
//               just X - the HUD shows G only while RT is held)
//   B           put it back exactly as it was
//
// Lifted from inside a procedure it can go anywhere in that procedure's
// blocks but never out of the procedure; top-level constructs (procedures,
// types) only move past each other, never above `package`. It doesn't go into
// a `switch` (between `switch {` and its first `case`), a struct literal or a
// local type. Moving into / out of a block re-indents it. While it's lifted
// every other button is ignored. The app draws it in a glowing orange box.

import "core:strings"

// One move: lines [lo, hi] of the document rotated so the first `first`
// went to the end; sel = where the lifted lines were before it. Undone by
// rotating the other part back (grab_cancel).
Grab_Op :: struct { lo, hi, first: int, sel: Sel }

// grab_lines: the lifted lines [ni, end_ni], when something is lifted.
grab_lines :: proc(app: ^App) -> (ni, end_ni: int, ok: bool) {
	if !app.grab_active do return
	return app.grab_sel.ni, app.grab_sel.end_ni, true
}

// grab_start lifts the RT selection (see the top). False when there's nothing
// to lift (an empty file, the package line, a `} else {` line).
grab_start :: proc(app: ^App, copy := false) -> bool {
	if _, ok := tree_selection(app); !ok do return false
	path := app.tree_path[:]
	idx := -1
	#reverse for s, i in path do if s.kind != .Unit { idx = i; break }
	if idx < 0 do return false
	lift := path[idx]
	// A block's header line: the block itself.
	if lift.kind == .Line && idx > 0 && path[idx - 1].kind == .Block && path[idx - 1].ni == lift.ni {
		idx -= 1
		lift = path[idx]
	}
	t := line_trim(app, lift.ni)
	if strings.has_prefix(t, "package ") || strings.has_prefix(t, "}") do return false
	if copy {
		// The copy goes in just below the original, and that's what moves.
		size := lift.end_ni - lift.ni + 1
		for k in 0 ..< size do inject_at(&app.doc.nodes, lift.end_ni + 1 + k, clone_line(app.doc.nodes[lift.ni + k]))
		lift.ni += size
		lift.end_ni += size
	}
	app.grab_active = true
	app.grab_copy = copy
	app.grab_sel = lift
	app.grab_top = idx == 0
	app.grab_proc = path[0]
	if app.grab_indent != "" do delete(app.grab_indent)
	app.grab_indent = strings.clone(line_lead(app, lift.ni))
	clear(&app.grab_ops)
	focus_line_start(app, lift.ni)
	return true
}

// grab_update: input while something is lifted. True = the input was used
// (all of it is, while lifted). inp: the raw presses (a plain X is "nothing"
// in the resolved keys).
grab_update :: proc(app: ^App, inp: Input, keys: Resolved) -> bool {
	if !app.grab_active do return false
	n := len(app.doc.nodes)
	if app.grab_sel.ni < 0 || app.grab_sel.end_ni >= n || app.grab_sel.ni > app.grab_sel.end_ni {
		grab_end(app) // the document changed under it (a file was opened)
		return false
	}
	switch {
	case .Grab in keys.fired || inp.x || keys.rest.confirm:
		if grab_blocked(app) do app.notice = "A copy from inside a procedure can only be dropped inside a procedure"
		else do grab_drop(app)
	case keys.rest.cancel:      grab_cancel(app)
	case .Walk_Prev in keys.fired: grab_jump(app, -1)
	case .Walk_Next in keys.fired: grab_jump(app, +1)
	case keys.rest.up:          grab_step(app, -1)
	case keys.rest.down:        grab_step(app, +1)
	}
	return true
}

// grab_drop: leave it here; the RT selection is the dropped construct.
grab_drop :: proc(app: ^App) {
	ni, end := app.grab_sel.ni, app.grab_sel.end_ni
	grab_end(app)
	tree_select_lines(app, ni, end)
}

// grab_cancel: undo every move (and the indent), then drop it there.
grab_cancel :: proc(app: ^App) {
	#reverse for op in app.grab_ops {
		rotate_lines(app, op.lo, op.hi, op.hi - op.lo + 1 - op.first)
		app.grab_sel = op.sel
	}
	if app.grab_copy {
		// Back just below the original: take it away.
		ni, end := app.grab_sel.ni, app.grab_sel.end_ni
		for _ in ni ..= end do remove_node(app, ni)
		grab_end(app)
		focus_line_start(app, max(ni - (end - ni + 1), 0))
		return
	}
	reindent_lifted(app, app.grab_indent)
	grab_drop(app)
}

@(private = "file")
grab_end :: proc(app: ^App) {
	app.grab_active = false
	app.grab_copy = false
	delete(app.grab_ops)
	app.grab_ops = nil
	if app.grab_indent != "" do delete(app.grab_indent)
	app.grab_indent = ""
}

// ---- Where it is ----

// Place: the siblings around the lifted lines (a block's header excluded), its
// index among them, and the block they're in (top: none).
@(private = "file")
Place :: struct {
	sibs:   []Sel,
	idx:    int,
	parent: Sel,
	top:    bool,
}

@(private = "file")
grab_place :: proc(app: ^App) -> (p: Place, ok: bool) {
	lift := app.grab_sel
	level := tree_roots(app)
	p.top = true
	for depth in 0 ..< 64 {
		next := -1
		for s, i in level do if s.kind != .Unit && s.ni <= lift.ni && lift.end_ni <= s.end_ni { next = i; break }
		if next < 0 do return
		s := level[next]
		if s.ni == lift.ni && s.end_ni == lift.end_ni {
			p.sibs, p.idx = level, next
			return p, true
		}
		p.parent, p.top = s, false
		level = block_body(app, s)
	}
	return
}

// A block's children without its header line.
@(private = "file")
block_body :: proc(app: ^App, b: Sel) -> []Sel {
	kids := tree_children(app, b)
	if len(kids) > 0 && kids[0].kind == .Line && kids[0].ni == b.ni do return kids[1:]
	return kids
}

// Can lifted code go into this block? A code block (for / if / else / when /
// `{ }`, labeled or not) - not a switch, a struct literal or a local type.
@(private = "file")
enterable :: proc(app: ^App, b: Sel) -> bool {
	if b.kind != .Block || b.end_ni <= b.ni do return false
	t := line_trim(app, b.ni)
	if colon := strings.index(t, ": "); colon > 0 && is_ident(t[:colon]) do t = strings.trim_space(t[colon + 1:]) // `outer: for ...`
	for kw in ([]string{"for", "if", "else", "when"}) {
		if strings.has_prefix(t, kw) && (len(t) == len(kw) || t[len(kw)] == ' ' || t[len(kw)] == '{') do return true
	}
	if t == "{" do return true // a plain scope block
	// A copy from inside a procedure: into another procedure too.
	return app.grab_copy && !app.grab_top && is_proc_block(app, b)
}

// A procedure's block: `name :: proc(...) {` (any calling convention / directive).
@(private = "file")
is_proc_block :: proc(app: ^App, b: Sel) -> bool {
	t := line_trim(app, b.ni)
	return strings.contains(t, "::") && strings.contains(t, "proc") && strings.has_suffix(t, "{")
}

// Can it step out of this block (it isn't the procedure it was lifted from)?
@(private = "file")
leavable :: proc(app: ^App, b: Sel) -> bool {
	if app.grab_top do return false
	if app.grab_copy do return strings.has_suffix(line_trim(app, b.ni), "{") // a copy can leave its procedure
	return !(b.ni == app.grab_proc.ni) && strings.has_suffix(line_trim(app, b.ni), "{")
}

// ---- Moving ----

// grab_step: one step up (dir < 0) or down - past a statement, into a block it
// meets, out of the block at its edge.
grab_step :: proc(app: ^App, dir: int) -> bool {
	p := grab_place(app) or_return
	lift := app.grab_sel
	size := lift.end_ni - lift.ni + 1
	j := p.idx + dir
	if j >= 0 && j < len(p.sibs) {
		other := p.sibs[j]
		if (!p.top || (app.grab_copy && !app.grab_top)) && enterable(app, other) {
			inner := strings.concatenate({line_lead(app, other.ni), "\t"}, context.temp_allocator)
			if dir > 0 {
				// [lift, gap, header] -> [gap, header, lift]: just under the header.
				move(app, lift.ni, other.ni, size)
				app.grab_sel.ni = other.ni - size + 1
			} else {
				// [}, gap, lift] -> [lift, }, gap]: just above the closing brace.
				move(app, other.end_ni, lift.end_ni, lift.ni - other.end_ni)
				app.grab_sel.ni = other.end_ni
			}
			app.grab_sel.end_ni = app.grab_sel.ni + size - 1
			reindent_lifted(app, inner)
			focus_line_start(app, app.grab_sel.ni)
			return true
		}
		return grab_jump(app, dir)
	}
	// At the edge of its block: out of it (not out of the procedure).
	if p.top || !leavable(app, p.parent) do return false
	outer := strings.clone(line_lead(app, p.parent.ni), context.temp_allocator)
	if dir > 0 {
		// [lift, ..., }] -> [..., }, lift]: just below the block.
		move(app, lift.ni, p.parent.end_ni, size)
		app.grab_sel.ni = p.parent.end_ni - size + 1
	} else {
		// [header, ..., lift] -> [lift, header, ...]: just above the block.
		move(app, p.parent.ni, lift.end_ni, lift.ni - p.parent.ni)
		app.grab_sel.ni = p.parent.ni
	}
	app.grab_sel.end_ni = app.grab_sel.ni + size - 1
	reindent_lifted(app, outer)
	focus_line_start(app, app.grab_sel.ni)
	return true
}

// grab_jump (RT + Up / Down, and a plain step past a statement): swap with the
// whole sibling above / below; the lines between them stay in the middle.
// Never above `package`, never in front of a switch's first `case`.
grab_jump :: proc(app: ^App, dir: int) -> bool {
	p := grab_place(app) or_return
	j := p.idx + dir
	if j < 0 || j >= len(p.sibs) do return false
	other := p.sibs[j]
	if strings.has_prefix(line_trim(app, other.ni), "package ") do return false
	if j == 0 && dir < 0 && !p.top && strings.contains(line_trim(app, p.parent.ni), "switch") do return false
	lift := app.grab_sel
	size := lift.end_ni - lift.ni
	if dir < 0 {
		// [other, gap, lift] -> [lift, gap, other]
		swap_around_gap(app, other, lift)
		app.grab_sel.ni = other.ni
	} else {
		// [lift, gap, other] -> [other, gap, lift]
		swap_around_gap(app, lift, other)
		app.grab_sel.ni = other.end_ni - size
	}
	app.grab_sel.end_ni = app.grab_sel.ni + size
	focus_line_start(app, app.grab_sel.ni)
	return true
}

// [upper, gap, lower] -> [lower, gap, upper], as two recorded rotations.
@(private = "file")
swap_around_gap :: proc(app: ^App, upper, lower: Sel) {
	a := upper.end_ni - upper.ni + 1
	b := lower.end_ni - lower.ni + 1
	lo, hi := upper.ni, lower.end_ni
	move(app, lo, hi, a)               // [gap, lower, upper]
	move(app, lo, hi - a, hi - a - lo + 1 - b) // [lower, gap, upper]
}

// move: rotate lines [lo, hi] so the first `first` go to the end, recorded for B.
@(private = "file")
move :: proc(app: ^App, lo, hi, first: int) {
	if first <= 0 || first > hi - lo do return
	rotate_lines(app, lo, hi, first)
	append(&app.grab_ops, Grab_Op{lo, hi, first, app.grab_sel}) // callers update grab_sel after their moves
}

@(private = "file")
rotate_lines :: proc(app: ^App, lo, hi, first: int) {
	if first <= 0 || first > hi - lo do return
	seg := app.doc.nodes[lo:hi + 1]
	tmp := make([]Node, len(seg), context.temp_allocator)
	copy(tmp, seg[first:])
	copy(tmp[len(seg) - first:], seg[:first])
	copy(seg, tmp)
}

// Re-indent the lifted lines so the first one has `base` (the others keep
// their indent relative to it).
@(private = "file")
reindent_lifted :: proc(app: ^App, base: string) {
	base := strings.clone(base, context.temp_allocator)
	old := strings.clone(line_lead(app, app.grab_sel.ni), context.temp_allocator)
	if old == base do return
	for i in app.grab_sel.ni ..= app.grab_sel.end_ni {
		lead := line_lead(app, i)
		rel := strings.has_prefix(lead, old) ? lead[len(old):] : strings.trim_left(lead, "\t")
		set_indent(&app.doc.nodes[i], strings.concatenate({base, rel}, context.temp_allocator))
	}
}

// ---- Small helpers ----

@(private = "file")
line_trim :: proc(app: ^App, ni: int) -> string {
	if ni < 0 || ni >= len(app.doc.nodes) do return ""
	return strings.trim_space(node_text(app.doc.nodes[ni], context.temp_allocator))
}

// The line's leading whitespace. Temp-allocated.
@(private = "file")
line_lead :: proc(app: ^App, ni: int) -> string {
	if ni < 0 || ni >= len(app.doc.nodes) do return ""
	t := node_text(app.doc.nodes[ni], context.temp_allocator)
	k := 0
	for k < len(t) && (t[k] == '\t' || t[k] == ' ') do k += 1
	return t[:k]
}

// The cursor on line ni (so the view follows the lifted lines).
@(private = "file")
focus_line_start :: proc(app: ^App, ni: int) {
	app.editor_line = ni
	app.editor_dot = false
	app.editor_attr = false
	app.editor_field = 0
	clamp_field(app)
}

// grab_blocked: a copy from inside a procedure, between procedures now - it
// can't be dropped here (the app draws it red).
grab_blocked :: proc(app: ^App) -> bool {
	if !app.grab_active || !app.grab_copy || app.grab_top do return false
	p, ok := grab_place(app)
	return !ok || p.top
}

// A deep copy of a line (Copy line).
@(private = "file")
clone_line :: proc(n: Node) -> Node {
	out: Node
	out.fields = make([dynamic]Field, 0, len(n.fields))
	for f in n.fields {
		c := f
		c.text = strings.clone(f.text)
		append(&out.fields, c)
	}
	return out
}

// ---- The Refactor menu ----

REFACTOR_FILL :: "__refactor__" // call_name = "grab" / "copy"

// open_refactor_menu (the Grab action, RT+X): Grab / Copy line for the
// highlighted statement or block.
open_refactor_menu :: proc(app: ^App) {
	if _, ok := tree_selection(app); !ok do return
	mk :: proc(label, op: string) -> Entry {
		return Entry{label = strings.clone(label), owned_label = true, fill = REFACTOR_FILL, call_name = strings.clone(op)}
	}
	menu := make_slice(mk("Grab", "grab"), mk("Copy line", "copy"))
	if app.slot_menu != nil do free_entries(app.slot_menu)
	app.slot_menu = menu
	clear_nav(app)
	app.return_state = .Editor
	app.state = .Radial
	v := MenuView{title = "Refactor", entries = make([]Entry, len(menu))}
	copy(v.entries, menu)
	push_view(app, v)
}

// refactor_choose (menu_select): lift it, or a copy of it.
refactor_choose :: proc(app: ^App, e: Entry) {
	clear_nav(app)
	app.state = .Editor
	if app.slot_menu != nil { free_entries(app.slot_menu); app.slot_menu = nil }
	if !grab_start(app, e.call_name == "copy") do app.notice = "Nothing here to move"
}

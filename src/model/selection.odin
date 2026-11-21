package model

// Selection: what the cursor can highlight, and the tree RT navigates.
//
// Each line gets a small syntax tree built from its fields ("units"):
//     windows.MessageBoxW(nil, windows.L("Testing"), ●, win.MB_OK | ●)
//     ├─ MessageBoxW            (callee)
//     ├─ nil                    (argument)
//     ├─ windows.L("Testing")   (argument: a call)
//     │   ├─ L                  (callee)
//     │   └─ "Testing"          (argument: string)
//     ├─ ●                      (argument: dot)
//     └─ win.MB_OK | ●          (argument: operator)
//         ├─ win.MB_OK
//         └─ ●
//
// D-pad Left/Right steps through the leaves of a line (editor_field indexes
// them); Y changes the highlighted leaf. RT + D-pad walks the tree like a file
// tree: function -> its statements -> a statement's parts -> nested parts.

import "core:strings"

Unit_Kind :: enum u8 {
	Field,  // a single selectable field: editable name, dot, filled type
	Callee, // a call's procedure name
	Value,  // a filled argument/operand with no further structure (nil, win.MB_OK, 5, loaded text)
	Str,    // a string literal: `"` content `"`
	Call,   // name(args) used as an argument
	Op,     // a op b
	Group,  // anything else made of several fields
	Lit,    // T{name = value, ...}: the type, then each field (a Group: name + value), then the fields dot
}

Unit :: struct {
	fa, fb:   int, // fields [fa, fb)
	kind:     Unit_Kind,
	children: []Unit, // Call: callee + args; Op: operands; Group: its selectable fields
	is_arg:   bool,   // sits in an argument / operand position (Y refills it)
	arg_idx:  int,    // which argument of its call (when is_arg and the parent is a call)
}

@(private = "file")
is_open :: proc(f: Field) -> bool { return !f.slot && (f.text == "(" || f.text == "( " || is_lit_open(f)) }
@(private = "file")
is_close :: proc(f: Field) -> bool { return !f.slot && (f.text == ")" || f.text == " )" || is_lit_close(f)) }
@(private = "file")
is_sep :: proc(f: Field) -> bool { return !f.slot && f.text == ", " }
@(private = "file")
is_quote :: proc(f: Field) -> bool { return !f.slot && (f.text == "\"" || f.text == "`" || f.text == "'") }

@(private = "file")
BINARY_OPS := [?]string{"|", "&", "~", "&~", "<<", ">>", "+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">=", "&&", "||"}

// A binary operator field as inserted by make_slot_operator: " | ".
@(private = "file")
is_op_field :: proc(f: Field) -> bool {
	if f.slot || len(f.text) < 3 || f.text[0] != ' ' || f.text[len(f.text) - 1] != ' ' do return false
	t := strings.trim_space(f.text)
	for o in BINARY_OPS do if o == t do return true
	return false
}

@(private = "file")
// Names, dots, and a declaration's operator (`:=` / `:` / `::`, kind "decl": Y
// switches between `x := v`, `x: T = v` and `x :: v`), and keywords Y / LT+B act
// on (kind "kw": when, #assert, attributes, struct directives, calling conventions - ctrl.odin).
selectable :: proc(f: Field) -> bool { return f.editable || f.slot || f.kind == "decl" || f.kind == KW || f.kind == BR_KW || f.kind == ASSIGN_OP_KIND || f.kind == CONV_KIND } // BR_KW: if / switch / case (branch.odin); ASSIGN_OP_KIND: `=` / `+=` (loops.odin); CONV_KIND: `cast(T)` (expr.odin)

// parse_expr builds the unit for the expression in fields [a, b).
@(private = "file")
parse_expr :: proc(n: Node, a, b: int, is_arg: bool, arg_idx := 0) -> Unit {
	if b <= a do return Unit{fa = a, fb = a, kind = .Value, is_arg = is_arg, arg_idx = arg_idx}
	if b - a == 1 {
		f := n.fields[a]
		return Unit{a, b, selectable(f) ? .Field : .Value, nil, is_arg, arg_idx}
	}
	// A ternary `a if c else b` (lowest precedence, so first): an Op of three operands (expr.odin).
	if k1, k2, tok := tern_split(n, a, b); tok {
		kids := make([]Unit, 3, context.temp_allocator)
		kids[0] = parse_expr(n, a, k1, true)
		kids[1] = parse_expr(n, k1 + 1, k2, true)
		kids[2] = parse_expr(n, k2 + 1, b, true)
		return Unit{a, b, .Op, kids, is_arg, arg_idx}
	}
	// Binary operators at the top level: a | b | c.
	ops := make([dynamic]int, 0, 2, context.temp_allocator)
	depth := 0
	for i in a ..< b {
		f := n.fields[i]
		if is_open(f) do depth += 1
		else if is_close(f) do depth -= 1
		else if depth == 0 && is_op_field(f) do append(&ops, i)
	}
	if len(ops) > 0 {
		kids := make([dynamic]Unit, 0, len(ops) + 1, context.temp_allocator)
		start := a
		for o in ops {
			append(&kids, parse_expr(n, start, o, true))
			start = o + 1
		}
		append(&kids, parse_expr(n, start, b, true))
		return Unit{a, b, .Op, kids[:], is_arg, arg_idx}
	}
	// cast(T)x / transmute(T)x / auto_cast x: the prefix (Y retypes it), then the value (expr.odin).
	if is_conv_prefix(n.fields[a]) {
		kids := make([]Unit, 2, context.temp_allocator)
		kids[0] = Unit{fa = a, fb = a + 1, kind = .Field}
		kids[1] = parse_expr(n, a + 1, b, true)
		return Unit{a, b, .Group, kids, is_arg, arg_idx}
	}
	// A struct literal: T{...} with the "}" at the end (struct_lit.odin).
	if is_lit_close(n.fields[b - 1]) && b - a >= 3 && is_lit_open(n.fields[a + 1]) && lit_close_of(n, a + 1) == b - 1 {
		kids := make([dynamic]Unit, 0, 4, context.temp_allocator)
		append(&kids, Unit{fa = a, fb = a + 1, kind = .Value}) // the type
		for r, k in arg_ranges(n, a + 2, b - 1) {
			if n.fields[r[0]].kind == LIT_KEY_KIND && r[1] - r[0] >= 3 {
				// `name = value`: the name, then the value (Y refills it).
				parts := make([]Unit, 2, context.temp_allocator)
				parts[0] = Unit{fa = r[0], fb = r[0] + 1, kind = .Value}
				parts[1] = parse_expr(n, r[0] + 2, r[1], true, k)
				append(&kids, Unit{r[0], r[1], .Group, parts, false, k})
			} else {
				append(&kids, parse_expr(n, r[0], r[1], false))
			}
		}
		return Unit{a, b, .Lit, kids[:], is_arg, arg_idx}
	}
	// A call: name(...) with the ")" at the end.
	if is_close(n.fields[b - 1]) {
		d := 0
		open := -1
		for i := b - 1; i >= a; i -= 1 {
			if is_close(n.fields[i]) do d += 1
			else if is_open(n.fields[i]) {
				d -= 1
				if d == 0 { open = i; break }
			}
		}
		if open > a {
			kids := make([dynamic]Unit, 0, 4, context.temp_allocator)
			append(&kids, Unit{fa = open - 1, fb = open, kind = .Callee})
			for r, k in arg_ranges(n, open + 1, b - 1) do append(&kids, parse_expr(n, r[0], r[1], true, k))
			return Unit{a, b, .Call, kids[:], is_arg, arg_idx}
		}
	}
	if is_quote(n.fields[a]) && is_quote(n.fields[b - 1]) do return Unit{a, b, .Str, nil, is_arg, arg_idx}
	// Anything else: its selectable fields are the parts.
	kids := make([dynamic]Unit, 0, 2, context.temp_allocator)
	for i in a ..< b do if selectable(n.fields[i]) do append(&kids, Unit{fa = i, fb = i + 1, kind = .Field})
	if len(kids) == 0 do return Unit{a, b, .Value, nil, is_arg, arg_idx}
	return Unit{a, b, .Group, kids[:], is_arg, arg_idx}
}

// parse_expr_unit: the unit for fields [a, b) (e.g. a whole call statement's call).
parse_expr_unit :: proc(n: Node, a, b: int) -> Unit { return parse_expr(n, a, b, false) }

// parse_expr_arg: the same, in an argument position (Y refills it; loops.odin).
parse_expr_arg :: proc(n: Node, a, b: int) -> Unit { return parse_expr(n, a, b, true) }

// focus_kth_selectable puts the cursor on the leaf holding the line's k-th
// name/dot (editable or slot field) - where a fill used to leave the cursor.
focus_kth_selectable :: proc(app: ^App, ni, k: int) {
	if ni < 0 || ni >= len(app.doc.nodes) do return
	idx := 0
	for f, i in app.doc.nodes[ni].fields {
		if f.editable || f.slot {
			if idx == k { focus_field_index(app, ni, i); return }
			idx += 1
		}
	}
	app.editor_line = ni
	app.editor_dot = false
	clamp_field(app)
}

// The argument ranges of a call whose arguments are in fields [a, b), split at
// top-level ", " fields.
arg_ranges :: proc(n: Node, a, b: int) -> [][2]int {
	out := make([dynamic][2]int, 0, 4, context.temp_allocator)
	depth := 0
	start := a
	for i in a ..< b {
		f := n.fields[i]
		if is_open(f) do depth += 1
		else if is_close(f) do depth -= 1
		else if depth == 0 && is_sep(f) {
			if i > start do append(&out, [2]int{start, i})
			start = i + 1
		}
	}
	if b > start do append(&out, [2]int{start, b})
	return out[:]
}

// line_units: the parts of a line (the children of the line in the tree).
// A call statement is its callee and arguments (plus any names/dots around it);
// any other line is its selectable fields. (A capture dot is not one of them:
// RT walks the code itself; D-pad Left reaches the dot - see line_leaves.)
line_units :: proc(n: Node) -> []Unit {
	if units, ok := branch_line_units(n); ok do return units // if / switch headers, case labels (branch.odin)
	if lu, ok := loop_line_units(n); ok do return lu // a loop header (loops.odin)
	if wu, ok := when_line_units(n); ok do return wu // a when / else when header (when_cond.odin)
	out := make([dynamic]Unit, 0, 4, context.temp_allocator)
	al, has_call := find_arg_list(n)
	if !has_call || al.open == 0 || value_is_compound(n) { // `x = f(a) if c else g(b)`: the value is the part (expr.odin)
		// `x := value` / `x = value`: a filled value is one part (Y refills it).
		rhs := stmt_rhs_start(n)
		for f, i in n.fields {
			if rhs >= 0 && i >= rhs do break
			if selectable(f) && !is_capture_dot(f) do append(&out, Unit{fa = i, fb = i + 1, kind = .Field})
		}
		if rhs >= 0 do append(&out, parse_expr(n, rhs, len(n.fields), true))
		return out[:]
	}
	for i in 0 ..< al.open - 1 do if selectable(n.fields[i]) && !is_capture_dot(n.fields[i]) do append(&out, Unit{fa = i, fb = i + 1, kind = .Field})
	call := parse_expr(n, al.open - 1, al.close + 1, false)
	if call.kind == .Call || call.kind == .Lit {
		for c in call.children do append(&out, c)
	} else {
		append(&out, call)
	}
	for i in al.close + 1 ..< len(n.fields) do if selectable(n.fields[i]) do append(&out, Unit{fa = i, fb = i + 1, kind = .Field})
	return out[:]
}

// line_leaves: what D-pad Left/Right steps through on a line.
line_leaves :: proc(n: Node) -> []Unit {
	out := make([dynamic]Unit, 0, 8, context.temp_allocator)
	if ci := capture_dot_index(n); ci >= 0 do append(&out, Unit{fa = ci, fb = ci + 1, kind = .Field}) // the first stop
	collect :: proc(out: ^[dynamic]Unit, units: []Unit) {
		for u in units {
			switch u.kind {
			case .Call, .Op, .Group, .Lit: collect(out, u.children)
			case .Field, .Callee, .Value, .Str: append(out, u)
			}
		}
	}
	collect(&out, line_units(n))
	return out[:]
}

// The field a leaf acts through: its dot / editable field (a string's text, for
// dictation), else its first field.
leaf_primary_field :: proc(n: Node, u: Unit) -> int {
	for i in u.fa ..< u.fb do if n.fields[i].slot do return i
	for i in u.fa ..< u.fb do if n.fields[i].editable do return i
	return u.fa
}

// The leaf under the cursor.
editor_leaf :: proc(app: ^App) -> (ni: int, u: Unit, ok: bool) {
	if app.editor_dot || app.editor_line < 0 || app.editor_line >= len(app.doc.nodes) do return
	leaves := line_leaves(app.doc.nodes[app.editor_line])
	if len(leaves) == 0 do return
	return app.editor_line, leaves[clamp(app.editor_field, 0, len(leaves) - 1)], true
}

// focus_field_index puts the cursor on the leaf containing field fi of line ni.
focus_field_index :: proc(app: ^App, ni, fi: int) {
	app.editor_line = ni
	app.editor_dot = false
	app.editor_field = 0
	for u, k in line_leaves(app.doc.nodes[ni]) {
		if fi >= u.fa && fi < u.fb { app.editor_field = k; break }
		if u.fa > fi { app.editor_field = k; break }
	}
}

// After filling a dot at field fi (whose content now spans `count` fields), put
// the cursor on the first unfilled dot inside it, if any (MessageBoxW( -> its
// hWnd dot; L(● -> its argument).
focus_first_dot_in :: proc(app: ^App, ni, fi, count: int) {
	if ni < 0 || ni >= len(app.doc.nodes) do return
	fields := app.doc.nodes[ni].fields
	for i in fi ..< min(fi + count, len(fields)) {
		if fields[i].slot && fields[i].kind != "body" { focus_field_index(app, ni, i); return }
	}
	focus_field_index(app, ni, fi)
}

// ---- The RT tree ----

Sel_Kind :: enum u8 {
	Block, // a construct / nested block spanning lines ni..end_ni (header line first)
	Line,  // one line
	Unit,  // part of a line: fields [fa, fb) of line ni
}

Sel :: struct {
	kind:       Sel_Kind,
	ni, end_ni: int,
	fa, fb:     int,
}

@(private = "file")
sel_eq :: proc(a, b: Sel) -> bool {
	return a.kind == b.kind && a.ni == b.ni && a.end_ni == b.end_ni && a.fa == b.fa && a.fb == b.fb
}

// The end line of the block a line opens (or the line itself).
@(private = "file")
block_end :: proc(app: ^App, ni: int) -> int {
	if brace_delta(app, ni) <= 0 do return ni
	balance := 0
	for j in ni ..< len(app.doc.nodes) {
		balance += brace_delta(app, j)
		if balance <= 0 do return j
	}
	return len(app.doc.nodes) - 1
}

@(private = "file")
line_sel :: proc(app: ^App, ni: int) -> Sel {
	e := block_end(app, ni)
	if e > ni do return Sel{kind = .Block, ni = ni, end_ni = e}
	return Sel{kind = .Line, ni = ni, end_ni = ni}
}

// The top level of the tree: one entry per construct.
tree_roots :: proc(app: ^App) -> []Sel {
	out := make([dynamic]Sel, 0, 8, context.temp_allocator)
	n := len(app.doc.nodes)
	for i := 0; i < n; {
		s := line_sel(app, i)
		if strings.trim_space(node_text(app.doc.nodes[i], context.temp_allocator)) != "" do append(&out, s)
		i = s.end_ni + 1
	}
	return out[:]
}

// tree_children: one level down. A block -> its header line, then its
// statements (nested blocks stay grouped); a line -> its parts; a part -> its
// sub-parts (a call's name and arguments, an operator's operands).
tree_children :: proc(app: ^App, s: Sel) -> []Sel {
	out := make([dynamic]Sel, 0, 8, context.temp_allocator)
	switch s.kind {
	case .Block:
		append(&out, Sel{kind = .Line, ni = s.ni, end_ni = s.ni})
		for j := s.ni + 1; j < s.end_ni; {
			c := line_sel(app, j)
			t := strings.trim_space(node_text(app.doc.nodes[j], context.temp_allocator))
			if t != "" && t != "}" do append(&out, c)
			j = c.end_ni + 1
		}
	case .Line:
		for u in line_units(app.doc.nodes[s.ni]) do append(&out, Sel{.Unit, s.ni, s.ni, u.fa, u.fb})
	case .Unit:
		if u, ok := find_unit(app.doc.nodes[s.ni], s.fa, s.fb); ok {
			for c in u.children do append(&out, Sel{.Unit, s.ni, s.ni, c.fa, c.fb})
		}
	}
	return out[:]
}

// find_unit locates the unit spanning fields [fa, fb) in a line's tree.
find_unit :: proc(n: Node, fa, fb: int) -> (Unit, bool) {
	search :: proc(units: []Unit, fa, fb: int) -> (Unit, bool) {
		for u in units {
			if u.fa == fa && u.fb == fb do return u, true
			if u.fa <= fa && fb <= u.fb {
				if r, ok := search(u.children, fa, fb); ok do return r, true
			}
		}
		return {}, false
	}
	return search(line_units(n), fa, fb)
}

// The tree path, rebuilt when the cursor moved some other way.
@(private = "file")
tree_ensure :: proc(app: ^App) {
	n := len(app.doc.nodes)
	valid := len(app.tree_path) > 0 && app.tree_line == app.editor_line && app.tree_field == app.editor_field &&
		app.tree_dot == app.editor_dot && app.tree_nodes == n
	if valid {
		top := app.tree_path[len(app.tree_path) - 1]
		valid = top.ni < n && top.end_ni < n
	}
	if valid do return
	clear(&app.tree_path)
	app.tree_sticky = false
	if n == 0 do return
	line := clamp(app.editor_line, 0, n - 1)
	for r in tree_roots(app) do if line >= r.ni && line <= r.end_ni { append(&app.tree_path, r); break }
	if len(app.tree_path) == 0 {
		roots := tree_roots(app)
		if len(roots) > 0 do append(&app.tree_path, roots[len(roots) - 1])
	}
	tree_remember_cursor(app)
}

@(private = "file")
tree_remember_cursor :: proc(app: ^App) {
	app.tree_line, app.tree_field, app.tree_dot = app.editor_line, app.editor_field, app.editor_dot
	app.tree_nodes = len(app.doc.nodes)
}

// The current RT selection (the construct around the cursor if RT wasn't used yet).
tree_selection :: proc(app: ^App) -> (Sel, bool) {
	tree_ensure(app)
	if len(app.tree_path) == 0 do return {}, false
	return app.tree_path[len(app.tree_path) - 1], true
}

// Move the cursor to match a tree selection (its first leaf).
@(private = "file")
tree_sync_cursor :: proc(app: ^App, s: Sel) {
	app.editor_line = s.ni
	app.editor_dot = false
	app.editor_field = 0
	if s.kind == .Unit do focus_field_index(app, s.ni, s.fa)
	else do clamp_field(app)
	tree_remember_cursor(app)
}

// tree_move: RT + D-pad. Up/Down = previous/next sibling, Right = into the
// first child, Left = out to the parent.
tree_move :: proc(app: ^App, dx, dy: int) {
	tree_ensure(app)
	if len(app.tree_path) == 0 do return
	cur := app.tree_path[len(app.tree_path) - 1]
	switch {
	case dx > 0:
		kids := tree_children(app, cur)
		if len(kids) == 0 do return
		append(&app.tree_path, kids[0])
	case dx < 0:
		if len(app.tree_path) <= 1 do return
		pop(&app.tree_path)
	case dy != 0:
		siblings := len(app.tree_path) == 1 ? tree_roots(app) : tree_children(app, app.tree_path[len(app.tree_path) - 2])
		idx := -1
		for s, i in siblings do if sel_eq(s, cur) { idx = i; break }
		if idx < 0 do return
		next := clamp(idx + dy, 0, len(siblings) - 1)
		app.tree_path[len(app.tree_path) - 1] = siblings[next]
	}
	top := app.tree_path[len(app.tree_path) - 1]
	tree_sync_cursor(app, top)
	app.tree_sticky = top.kind == .Unit // keep highlighting this part after RT is released
}

// The highlighted part for the renderer / actions: the RT selection while it's
// sticky, else the leaf under the cursor. Lines [ni, end_ni]; for a single line,
// fields [fa, fb) (fb == -1: the whole line).
Highlight :: struct {
	ni, end_ni: int,
	fa, fb:     int,
}

current_highlight :: proc(app: ^App, rt_held: bool) -> (Highlight, bool) {
	if rt_held || app.tree_sticky {
		if s, ok := tree_selection(app); ok && (rt_held || app.tree_sticky) {
			switch s.kind {
			case .Block: return Highlight{s.ni, s.end_ni, 0, -1}, true
			case .Line:  return Highlight{s.ni, s.ni, 0, -1}, true
			case .Unit:  return Highlight{s.ni, s.ni, s.fa, s.fb}, true
			}
		}
	}
	ni, u, ok := editor_leaf(app)
	if !ok do return {}, false
	return Highlight{ni, ni, u.fa, u.fb}, true
}

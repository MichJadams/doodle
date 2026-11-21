package model

// Field access: `paint.rcPaint.left` as a value, and `window_class.style = ...`
// as an assignment target.
//
// Reference -> pick a name -> "Pass as" gains "Field of <name>" when the name's
// type is a struct (pointers are dereferenced): one entry per field
// ("rcPaint   RECT"). A struct-typed field opens a nested menu whose first entry
// is the field itself (paint.rcPaint), so paint.rcPaint.left is reachable.
// Fields whose type can't fill the dot are grayed (a struct-typed field stays
// lit while something inside it fits); when the dot expects a pointer, &path is
// offered too. The dot is filled with the whole path as one value (Y refills it).
//
// Y on an assignment's target (`brave_otter = ●`) -> pick a name the same way;
// "Assign to" offers the name itself or one of its fields. The value dot then
// expects the target's type.

import "core:fmt"
import "core:strings"

@(private = "file")
MAX_FIELD_MENU_DEPTH :: 3

// ---- Types for the menus ----

@(private = "file")
type_fits :: proc(ctx: ^Type_Ctx, got: Var_Type, exp: Resolved_Type) -> bool {
	if exp.cat == .Unknown || exp.cat == .Any do return true
	return value_fits(resolve_type(ctx, got.expr, got.pkg), exp)
}

// Can `&x` (x of type `got`) fill a dot expecting the pointer type `exp`
// (written in exp_pkg)?
@(private = "file")
ptr_fits :: proc(ctx: ^Type_Ctx, got: Var_Type, exp: Resolved_Type, exp_pkg: string) -> bool {
	if exp.cat == .Unknown || exp.cat == .Any do return true
	if exp.cat != .Pointer do return false
	c := strings.trim_space(exp.canon)
	elem := ""
	switch {
	case c == "rawptr":              return true
	case strings.has_prefix(c, "[^]"): elem = c[3:]
	case strings.has_prefix(c, "^"):   elem = c[1:]
	case:                            return true
	}
	return value_fits(resolve_type(ctx, got.expr, got.pkg), resolve_type(ctx, elem, exp_pkg))
}

// The type of a picked name: from its own declaration line, else as seen
// from line `from`.
picked_type :: proc(app: ^App, pick: Ref_Target, from: int) -> (Var_Type, bool) {
	name := app.doc.nodes[pick.ni].fields[pick.fi].text
	if t, ok := var_type_at(app, pick.ni + 1, name); ok && declared_on(app, pick.ni, name) do return t, true
	return var_type_at(app, from, name)
}

// Does line ni declare `name` (a declaration line or a procedure header)?
@(private = "file")
declared_on :: proc(app: ^App, ni: int, name: string) -> bool {
	for f, i in app.doc.nodes[ni].fields {
		if f.text != name || !f.editable do continue
		if i + 1 >= len(app.doc.nodes[ni].fields) do return false
		next := strings.trim_left_space(app.doc.nodes[ni].fields[i + 1].text)
		return strings.has_prefix(next, ":") || strings.has_prefix(next, ",")
	}
	return false
}

// field_entries: the menu entries for the fields of type `t` reached as `path`.
// `exp` is what the dot expects (graying); `assign` = any field will do.
@(private = "file")
field_entries :: proc(app: ^App, ctx: ^Type_Ctx, path: string, t: Var_Type, exp: Resolved_Type, exp_pkg: string, assign: bool, depth: int) -> (entries: []Entry, any_fit: bool) {
	out := make([dynamic]Entry, 0, 8)
	defer delete(out)
	want_ptr := !assign && exp.cat == .Pointer
	leaf :: proc(label, text: string, dim: bool) -> Entry {
		return Entry{label = strings.clone(label), owned_label = true, fill = REF_AS_FILL, call_name = strings.clone(text), dim = dim}
	}
	for f in struct_fields(app, t) {
		p := fmt.tprintf("%s.%s", path, f.name)
		label := fmt.tprintf("%s   %s", f.name, f.type.expr)
		fits := assign || type_fits(ctx, f.type, exp)
		pfits := want_ptr && ptr_fits(ctx, f.type, exp, exp_pkg)
		// Pointer fields aren't expanded (self-referencing structs like a
		// linked node would multiply the menu): they're offered as a leaf.
		if depth < MAX_FIELD_MENU_DEPTH && !strings.has_prefix(strings.trim_space(f.type.expr), "^") && is_struct_type(app, f.type) {
			kids := make([dynamic]Entry, 0, 8)
			defer delete(kids)
			append(&kids, leaf(p, p, !fits)) // the field itself
			if want_ptr do append(&kids, leaf(fmt.tprintf("&%s", p), fmt.tprintf("&%s", p), !pfits))
			sub, sub_fit := field_entries(app, ctx, p, f.type, exp, exp_pkg, assign, depth + 1)
			for e in sub do append(&kids, e)
			delete(sub)
			children := make([]Entry, len(kids))
			copy(children, kids[:])
			ok := fits || pfits || sub_fit
			append(&out, Entry{label = strings.clone(label), owned_label = true, children = children, dim = !ok})
			any_fit ||= ok
			continue
		}
		append(&out, leaf(label, p, !fits))
		any_fit ||= fits
		if !assign { // `player.items[i]` (index_fill.odin)
			if ie, ifit, iok := index_entry(app, ctx, p, f.type, exp); iok {
				append(&out, ie)
				any_fit ||= ifit
			}
		}
		if want_ptr {
			append(&out, leaf(fmt.tprintf("&%s   ^%s", f.name, f.type.expr), fmt.tprintf("&%s", p), !pfits))
			any_fit ||= pfits
		}
	}
	entries = make([]Entry, len(out))
	copy(entries, out[:])
	return
}

// append_field_group adds "Field of <name>" to the "Pass as" options for the
// picked name when its type has fields.
append_field_group :: proc(app: ^App, pick: Ref_Target, slot: Field, out: ^[dynamic]Entry) {
	name := app.doc.nodes[pick.ni].fields[pick.fi].text
	t, ok := picked_type(app, pick, app.ref_ni)
	if !ok || !is_struct_type(app, t) do return
	ctx := type_ctx_make(app)
	exp := slot_expected_type(&ctx, slot)
	children, any_fit := field_entries(app, &ctx, name, t, exp, slot.hint_pkg, false, 0)
	if len(children) == 0 { delete(children); return }
	append(out, Entry{label = fmt.aprintf("Field of %s", name), owned_label = true, children = children, dim = !any_fit})
}

// ---- Assignment targets ----

// is_assign_target: fields[fi] is the target of an assignment statement
// (`name = ...`, `a.b = ...`, `x += ...`, a C-style loop's post `i += 1`).
is_assign_target :: proc(n: Node, fi: int) -> bool {
	if fi < 0 || fi + 1 >= len(n.fields) do return false
	f := n.fields[fi]
	if !f.editable || f.slot || f.kind != "" do return false
	if is_loop_post_target(n, fi) do return true // loops.odin
	for i in 0 ..< fi do if n.fields[i].slot || n.fields[i].editable || strings.trim_space(n.fields[i].text) != "" do return false
	next := n.fields[fi + 1]
	if next.slot || (next.kind != "" && next.kind != ASSIGN_OP_KIND) do return false
	if next.kind == ASSIGN_OP_KIND do return true // `x += ...` (loops.odin)
	t := strings.trim_left_space(next.text)
	return strings.has_prefix(t, "=") && !strings.has_prefix(t, "==")
}

// open_assign_target_menu: "Assign to" for a name picked as an assignment's
// target: the name itself, what it points to, or one of its fields.
open_assign_target_menu :: proc(app: ^App, pick: Ref_Target) {
	name := app.doc.nodes[pick.ni].fields[pick.fi].text
	out := make([dynamic]Entry, 0, 4)
	defer delete(out)
	append(&out, Entry{label = strings.clone(name), owned_label = true, fill = REF_AS_FILL, call_name = strings.clone(name)})
	if t, ok := picked_type(app, pick, app.ref_ni); ok {
		if strings.has_prefix(strings.trim_space(t.expr), "^") {
			d := fmt.tprintf("%s^", name)
			append(&out, Entry{label = fmt.aprintf("%s   (what it points to)", d), owned_label = true, fill = REF_AS_FILL, call_name = strings.clone(d)})
		}
		if is_struct_type(app, t) {
			ctx := type_ctx_make(app)
			children, _ := field_entries(app, &ctx, name, t, {}, "", true, 0)
			append(&out, Entry{label = fmt.aprintf("Field of %s", name), owned_label = true, children = children})
		}
	}
	assign_target_dims(app, out[:]) // `x op= ●`: targets whose type can't take op (assign_ops.odin)
	if app.slot_menu != nil do free_entries(app.slot_menu)
	app.slot_menu = make([]Entry, len(out))
	copy(app.slot_menu, out[:])
	app.ref_pass_active = true
	clear_nav(app)
	app.return_state = .Editor
	app.state = .Radial
	push_menu(app, "Assign to", app.slot_menu)
}

// set_assign_target: the assignment at line ni now targets `text`; its value
// dot expects the target's type.
set_assign_target :: proc(app: ^App, ni, fi: int, text: string) {
	set_field_text(app, ni, fi, text)
	t, ok := expr_type_at(app, ni, text)
	fields := &app.doc.nodes[ni].fields
	// Only the assignment's own value dot (right after ` = `): a value that is
	// already a call keeps its argument dots' hints.
	if fi + 2 < len(fields) && fields[fi + 2].slot && fields[fi + 2].kind == "value" {
		f := &fields[fi + 2]
		f.hint, f.hint_pkg = "", ""
		if ok && t.expr != "" {
			if t.pkg == "" do f.hint = intern_hint(app, t.expr)
			else do f.hint, f.hint_pkg = intern_hint(app, t.expr), intern_hint(app, t.pkg) // t.pkg can be per-frame (var_types.odin)
		}
	}
	focus_field_index(app, ni, fi)
}

// ---- Statement values (`x := value`, `x = value`) ----

// stmt_rhs_start: where the value of a declaration / assignment line without a
// call starts (`x := ●`, `name: ● = ●`, `a.b = value`, `X :: value`), or -1.
// Only when the value is filled with something (so it can be one part that Y
// refills); a line of just dots and names is left as its dots.
stmt_rhs_start :: proc(n: Node) -> int {
	first := 0
	for first < len(n.fields) && !n.fields[first].slot && !n.fields[first].editable && strings.trim_space(n.fields[first].text) == "" do first += 1
	if first >= len(n.fields) || !n.fields[first].editable || n.fields[first].kind != "" do return -1
	op := -1
	seen_decl := false
	scan: for i in first + 1 ..< len(n.fields) {
		f := n.fields[i]
		t := strings.trim_space(f.text)
		switch {
		case f.slot && f.kind == "type", f.kind == "type", f.editable && f.kind == "", !f.slot && t == ",":
			continue // more names, a type
		case f.kind == "decl" && t == ":":
			seen_decl = true
			continue
		case seen_decl && !f.slot && !f.editable && f.kind == "" && is_composite_type_piece(t):
			continue // `p: ^int = ...`, `a: [4]int = ...`: pieces of the declared type
		case f.kind == "decl" && (t == ":=" || t == "::"), !f.slot && (t == "=" || t == "::"), f.kind == ASSIGN_OP_KIND:
			op = i
			break scan
		case:
			return -1
		}
	}
	if op < 0 || op + 1 >= len(n.fields) do return -1
	content := false
	for f in n.fields[op + 1:] {
		if f.slot && f.kind == "body" do return -1
		if f.slot || f.editable do continue
		t := f.text
		if strings.trim_space(t) == "" do continue
		if len(t) >= 3 && t[0] == ' ' && t[len(t) - 1] == ' ' && f.kind != TERN_KIND do continue // ` | `: an operator (a ternary is a value even unfilled: LT+B on its dots, expr.odin)
		content = true
	}
	return content ? op + 1 : -1
}

@(private = "file")
is_composite_type_piece :: proc(t: string) -> bool {
	switch t {
	case "^", "[", "]", "[]", "[^]", "[dynamic]", "map[", "0..<", "bit_set[", ";":
		return true
	}
	return false
}

// rhs_expected: the type a statement's value (or an operand of it) expects:
// the declared type of `x: T = value`, the target's type of `a.b = value`.
rhs_expected :: proc(app: ^App, ni: int, u: Unit) -> (string, string) {
	n := app.doc.nodes[ni]
	rhs := stmt_rhs_start(n)
	if rhs < 1 || u.fa < rhs do return "", ""
	op := strings.trim_space(n.fields[rhs - 1].text)
	if op != "=" && (n.fields[rhs - 1].kind != ASSIGN_OP_KIND || op == "<<=" || op == ">>=") do return "", "" // `:=` / `::`: the value decides the type; a shift amount: any integer
	t: Var_Type
	ok := false
	decl := -1
	for f, i in n.fields[:rhs - 1] do if f.kind == "decl" { decl = i; break }
	if decl >= 0 {
		b := strings.builder_make(context.temp_allocator)
		for f in n.fields[decl + 1:rhs - 1] do strings.write_string(&b, f.text)
		t, ok = Var_Type{strings.trim_space(strings.to_string(b)), ""}, true
	} else {
		for f, i in n.fields[:rhs - 1] {
			if is_assign_target(n, i) { t, ok = expr_type_at(app, ni, f.text); break }
		}
	}
	if !ok || t.expr == "" do return "", ""
	// The value, or a part of it: operands of `a | b`, a ternary's branches (change.odin expected_in).
	root := parse_expr_unit(n, rhs, len(n.fields))
	h, p, found := expected_in(app, n, root, u.fa, u.fb, t.expr, t.pkg)
	if !found || h == "" do return "", ""
	if p == "" do return intern_hint(app, h), ""
	return h, p
}

// sync_typed_decl_value_hint: on a `name: <type> = ●` line, the empty value
// dot expects the declared type (gray-out, "Pass as T(x)"); while the type is
// still a dot, it expects nothing.
sync_typed_decl_value_hint :: proc(app: ^App, ni: int) {
	if ni < 0 || ni >= len(app.doc.nodes) do return
	fields := &app.doc.nodes[ni].fields
	decl := -1
	for f, i in fields {
		if f.kind == "decl" && strings.trim_space(f.text) == ":" { decl = i; break }
		if f.slot do return
	}
	if decl < 1 do return
	eq := -1
	for i in decl + 1 ..< len(fields) {
		f := fields[i]
		if !f.slot && f.kind == "" && strings.trim_space(f.text) == "=" { eq = i; break }
	}
	if eq < 0 || eq + 2 != len(fields) do return // the value is exactly one empty dot
	v := &fields[eq + 1]
	if !v.slot || v.kind != "value" do return
	b := strings.builder_make(context.temp_allocator)
	typed := true
	for f in fields[decl + 1:eq] {
		if f.slot { typed = false; break }
		strings.write_string(&b, f.text)
	}
	t := strings.trim_space(strings.to_string(b))
	if !typed || t == "" {
		v.hint, v.hint_pkg = "", ""
		return
	}
	v.hint, v.hint_pkg = intern_hint(app, t), ""
}

// ---- Loading ----

// parse_assign_statement: `[indent] a.b.c = value`, `[indent] name = value`,
// `name += value` (any operator of ASSIGN_OPS, loops.odin): the target becomes
// a name (Y re-targets it), the operator a field Y changes, the value is
// structured. False unless it comes back exactly as written.
parse_assign_statement :: proc(line: string, in_data := false) -> (node: Node, ok: bool) {
	if in_data do return // an enum member `South = 5,` is not an assignment
	ind := 0
	for ind < len(line) && (line[ind] == ' ' || line[ind] == '\t') do ind += 1
	s := line[ind:]
	eq := strings.index_byte(s, ' ')
	if eq <= 0 || strings.contains(s, "//") do return
	op_end := eq + 1
	for op_end < len(s) && s[op_end] != ' ' do op_end += 1
	if op_end >= len(s) || !is_assign_op_text(s[eq + 1:op_end]) do return
	target := s[:eq]
	for part in strings.split(target, ".", context.temp_allocator) do if !is_ident(part) do return
	value := s[op_end + 1:]
	if value == "" || value != strings.trim_space(value) do return
	node.fields = make([dynamic]Field)
	if ind > 0 do append(&node.fields, Field{strings.clone(line[:ind]), false, false, "", "", ""})
	append(&node.fields, Field{strings.clone(target), true, false, "", "", ""})
	append(&node.fields, Field{strings.clone(s[eq:op_end + 1]), false, false, ASSIGN_OP_KIND, "", ""})
	emit_expr(&node.fields, value)
	if node_text(node, context.temp_allocator) != line {
		for f in node.fields do if len(f.text) > 0 do delete(f.text)
		delete(node.fields)
		return {}, false
	}
	return node, true
}

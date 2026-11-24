package model

// Branching (branch.odin, branch_parse.odin, range_fill.odin, index_fill.odin),
// driven the way the controller does: A on dots, menu picks, Y, LT+B, Reference.

import "core:strings"
import "core:testing"

@(private = "file")
cleanup :: proc(app: ^App) {
	clear_nav(app)
	delete(app.nav)
	doc_reset(app)
	delete(app.doc.nodes)
	delete(app.recent_imports)
	free_menus(app)
}

@(private = "file")
src :: proc(app: ^App) -> string { return doc_to_source(app, context.temp_allocator) }

@(private = "file")
line_with :: proc(app: ^App, text: string, from := 0) -> int {
	for i in from ..< len(app.doc.nodes) do if strings.contains(node_text(app.doc.nodes[i], context.temp_allocator), text) do return i
	return -1
}

@(private = "file")
line_src :: proc(app: ^App, ni: int) -> string {
	if ni < 0 || ni >= len(app.doc.nodes) do return "<no line>"
	return strings.trim_space(node_source(app.doc.nodes[ni], context.temp_allocator))
}

@(private = "file")
labels :: proc(app: ^App) -> string {
	v := current_view(app)
	if v == nil do return "<no menu>"
	out := make([dynamic]string, context.temp_allocator)
	for e in v.entries do append(&out, e.label)
	return strings.join(out[:], " | ", context.temp_allocator)
}

@(private = "file")
pick :: proc(t: ^testing.T, app: ^App, label: string, loc := #caller_location) -> bool {
	v := current_view(app)
	if v == nil || app.state != .Radial {
		testing.expectf(t, false, "no menu open (wanted %q)", label, loc = loc)
		return false
	}
	for e, i in v.entries {
		if e.label == label {
			v.index = i
			update(app, Input{confirm = true})
			return true
		}
	}
	testing.expectf(t, false, "no %q in menu %q: %s", label, v.title, labels(app), loc = loc)
	return false
}

@(private = "file")
find :: proc(entries: []Entry, label: string) -> (Entry, bool) {
	for e in entries {
		if e.label == label do return e, true
		if r, ok := find(e.children, label); ok do return r, true
	}
	return {}, false
}

@(private = "file")
dimmed :: proc(t: ^testing.T, app: ^App, label: string, loc := #caller_location) -> bool {
	v := current_view(app)
	if v == nil { testing.expect(t, false, "no menu", loc = loc); return false }
	e, ok := find(v.entries, label)
	testing.expectf(t, ok, "menu entry %q should exist: %s", label, labels(app), loc = loc)
	return e.dim
}

@(private = "file")
back_out :: proc(app: ^App) {
	for _ in 0 ..< 16 {
		if app.state == .Editor && !app.ref_pick_active do return
		update(app, Input{cancel = true})
	}
}

@(private = "file")
cursor_text :: proc(app: ^App) -> string {
	ni, fi, ok := editor_target(app)
	if !ok do return "<none>"
	return app.doc.nodes[ni].fields[fi].text
}

// The cursor on the keyword `text` of line ni.
@(private = "file")
focus_kw :: proc(t: ^testing.T, app: ^App, ni: int, text: string, loc := #caller_location) -> bool {
	if ni >= 0 && ni < len(app.doc.nodes) {
		for f, i in app.doc.nodes[ni].fields do if f.kind == BR_KW && f.text == text { focus_field_index(app, ni, i); return true }
	}
	testing.expectf(t, false, "no keyword %q on line %d (%q)", text, ni, line_src(app, ni), loc = loc)
	return false
}

// Y on keyword `text` of line ni, then the option.
@(private = "file")
y_option :: proc(t: ^testing.T, app: ^App, ni: int, text, option: string, loc := #caller_location) {
	back_out(app)
	if !focus_kw(t, app, ni, text, loc) do return
	change_selected(app)
	pick(t, app, option, loc)
}

// LT+B on keyword `text` of line ni.
@(private = "file")
lt_b_kw :: proc(t: ^testing.T, app: ^App, ni: int, text: string, loc := #caller_location) {
	back_out(app)
	if focus_kw(t, app, ni, text, loc) do delete_selected(app)
}

// A on the nth unfilled dot of `kind` on line ni.
@(private = "file")
open_dot :: proc(t: ^testing.T, app: ^App, ni, nth: int, kind := "value", loc := #caller_location) -> bool {
	back_out(app)
	seen := 0
	if ni >= 0 && ni < len(app.doc.nodes) {
		for f, i in app.doc.nodes[ni].fields {
			if f.slot && f.kind == kind {
				if seen == nth {
					focus_field_index(app, ni, i)
					update(app, Input{confirm = true})
					return true
				}
				seen += 1
			}
		}
	}
	testing.expectf(t, false, "no %s dot #%d on %q", kind, nth, line_src(app, ni), loc = loc)
	return false
}

@(private = "file")
fill :: proc(t: ^testing.T, app: ^App, ni: int, labels_: ..string, kind := "value", loc := #caller_location) {
	if !open_dot(t, app, ni, 0, kind, loc) do return
	for l in labels_ do if !pick(t, app, l, loc) do return
}

@(private = "file")
fill_number :: proc(t: ^testing.T, app: ^App, ni: int, text: string, loc := #caller_location) {
	if !open_dot(t, app, ni, 0, loc = loc) || !pick(t, app, "Number", loc) do return
	eni, efi, ok := editor_target(app)
	if testing.expect(t, ok && app.doc.nodes[eni].fields[efi].text == "0", "on the number", loc = loc) do set_field_text(app, eni, efi, text)
}

@(private = "file")
ref_choose :: proc(t: ^testing.T, app: ^App, name: string, loc := #caller_location) {
	if !testing.expect(t, app.ref_pick_active, "in pick mode", loc = loc) do return
	for _ in 0 ..< 64 {
		if cursor_text(app) == name do break
		update(app, Input{left = true})
	}
	testing.expect_value(t, cursor_text(app), name, loc = loc)
	update(app, Input{confirm = true})
}

// The names Reference offers from the dot at (ni, fi).
@(private = "file")
ref_names :: proc(app: ^App, ni: int) -> string {
	saved := app.slot_ni
	app.slot_ni = ni
	defer app.slot_ni = saved
	out := make([dynamic]string, context.temp_allocator)
	for c in ref_candidates(app) do append(&out, app.doc.nodes[c.ni].fields[c.fi].text)
	return strings.join(out[:], " ", context.temp_allocator)
}

// A on the green dot before line `at`, then Branching -> `label`.
@(private = "file")
insert_at_dot :: proc(t: ^testing.T, app: ^App, at: int, group, label: string, loc := #caller_location) {
	back_out(app)
	focus_dot_at(app, at)
	update(app, Input{confirm = true})
	if pick(t, app, group, loc) do pick(t, app, label, loc)
}

@(private = "file")
load :: proc(app: ^App, text: string) {
	app.state = .Editor
	doc_from_source(app, text)
}

@(private = "file")
BASE :: "package main\n\nmain :: proc() {\n\tx := 1\n}"

// ---------------------------------------------------------------------------

@(test)
test_branch_menu_has_all_forms :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, BASE)
	focus_dot_at(&app, 4)
	update(&app, Input{confirm = true})
	pick(t, &app, "Branching")
	testing.expect_value(t, labels(&app), "If | If / Else | If with setup | Switch | Switch (conditions) | Partial switch | Type switch | When")
}

@(test)
test_branch_if_chain :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, BASE)
	insert_at_dot(t, &app, 4, "Branching", "If")
	h := line_with(&app, "if ")
	testing.expect_value(t, h, 4)
	// The cursor is on the condition dot, which expects a bool.
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok && ni == h && app.doc.nodes[ni].fields[fi].slot && app.doc.nodes[ni].fields[fi].hint == "bool", "on the condition")
	update(&app, Input{confirm = true})
	testing.expect(t, dimmed(t, &app, "Number"), "a number isn't a condition")
	pick(t, &app, "true")
	testing.expect_value(t, line_src(&app, h), "if true {")

	// Y on `if` -> Add else, Add else if (before the else), Add else if after the first branch.
	y_option(t, &app, h, "if", "Add else")
	y_option(t, &app, h, "if", "Add else if")
	ei := line_with(&app, "else if")
	testing.expect(t, ei > h, "else if added")
	ni, fi, ok = editor_target(&app)
	testing.expect(t, ok && ni == ei && app.doc.nodes[ni].fields[fi].slot, "on the new condition")
	update(&app, Input{confirm = true})
	pick(t, &app, "Operator")
	pick(t, &app, "Compare")
	pick(t, &app, "a > b")
	if open_dot(t, &app, ei, 0) && pick(t, &app, "Reference") {
		ref_choose(t, &app, "x")
		if app.state == .Radial do pick(t, &app, "x")
	}
	fill_number(t, &app, ei, "0")
	y_option(t, &app, ei, "else if", "Add else if")
	ei2 := line_with(&app, "else if", ei + 1)
	if open_dot(t, &app, ei2, 0) do pick(t, &app, "false")
	// "Add else" is grayed once there is one.
	focus_kw(t, &app, h, "if")
	change_selected(&app)
	testing.expect(t, dimmed(t, &app, "Add else"), "only one else")
	back_out(&app)
	want := "package main\n\nmain :: proc() {\n\tx := 1\n" +
		"\tif true {\n\n" +
		"\t} else if x > 0 {\n\n" +
		"\t} else if false {\n\n" +
		"\t} else {\n\n" +
		"\t}\n}"
	testing.expectf(t, src(&app) == want, "got:\n%s", src(&app))

	// LT+B on the middle else if: just that branch goes.
	lt_b_kw(t, &app, ei, "else if")
	testing.expect_value(t, line_with(&app, "x > 0"), -1)
	testing.expect(t, line_with(&app, "else if false") > 0 && line_with(&app, "} else {") > 0, "chain intact")
	// LT+B on else.
	lt_b_kw(t, &app, line_with(&app, "} else {"), "else")
	testing.expect_value(t, line_with(&app, "} else {"), -1)
	want = "package main\n\nmain :: proc() {\n\tx := 1\n\tif true {\n\n\t} else if false {\n\n\t}\n}"
	testing.expectf(t, src(&app) == want, "got:\n%s", src(&app))

	// Formatted, saved and loaded back: the same.
	format_doc(&app)
	text := strings.clone(src(&app), context.temp_allocator)
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	l, lok := br_line(app.doc.nodes[line_with(&app, "else if")])
	testing.expect(t, lok && l.kind == .Else_If, "else if loads structured")
	// LT+B on `if`: the whole chain.
	lt_b_kw(t, &app, line_with(&app, "if true"), "if")
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n\tx := 1\n}")
}

@(test)
test_branch_else_from_green_dot :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tx := 1\n\tif x > 0 {\n\t\tx = 2\n\t}\n\tx = 3\n}")
	close := line_with(&app, "\t}")
	focus_dot_at(&app, close + 1)
	testing.expect_value(t, ctrl_hint(&app), "A: add a statement, else if or else")
	update(&app, Input{confirm = true})
	testing.expect(t, strings.has_prefix(labels(&app), "Else if | Else | Declarations"), labels(&app))
	pick(t, &app, "Else")
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n\tx := 1\n\tif x > 0 {\n\t\tx = 2\n\t} else {\n\n\t}\n\tx = 3\n}")
	// Now only Else if.
	close = line_with(&app, "\t}", line_with(&app, "} else {") + 1)
	focus_dot_at(&app, close + 1)
	update(&app, Input{confirm = true})
	testing.expect(t, strings.has_prefix(labels(&app), "Else if | Declarations"), labels(&app))
	pick(t, &app, "Else if")
	ei := line_with(&app, "else if")
	testing.expect(t, ei > 0 && ei < line_with(&app, "} else {"), "else if goes before else")
	if open_dot(t, &app, ei, 0) do pick(t, &app, "true")
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n\tx := 1\n\tif x > 0 {\n\t\tx = 2\n\t} else if true {\n\n\t} else {\n\n\t}\n\tx = 3\n}")
	// B on the dot's menu inserts nothing.
	before := len(app.doc.nodes)
	focus_dot_at(&app, line_with(&app, "x = 3"))
	update(&app, Input{confirm = true})
	back_out(&app)
	testing.expect_value(t, len(app.doc.nodes), before)
}

@(test)
test_branch_if_with_setup_and_index :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tm: map[string]int\n}")
	insert_at_dot(t, &app, 4, "Branching", "If with setup")
	h := line_with(&app, "if ")
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok && ni == h && app.doc.nodes[ni].fields[fi].kind == SETUP_KIND, "on the setup dot")
	update(&app, Input{confirm = true})
	testing.expect_value(t, labels(&app), "Variable (:=) | Two names (:=) | Assignment | Call")
	pick(t, &app, "Two names (:=)")
	// rename the first name to v
	for f, i in app.doc.nodes[h].fields do if f.editable && f.text != "ok" { set_field_text(&app, h, i, "v"); break }
	// value: Reference m -> Pass as m[key]
	if open_dot(t, &app, h, 0) && pick(t, &app, "Reference") {
		ref_choose(t, &app, "m")
		if app.state == .Radial do pick(t, &app, "m[key]   int")
	}
	ni, fi, ok = editor_target(&app)
	testing.expect(t, ok && app.doc.nodes[ni].fields[fi].slot && app.doc.nodes[ni].fields[fi].hint == "string", "on the key dot (a string)")
	update(&app, Input{confirm = true})
	pick(t, &app, "String")
	pick(t, &app, "\"...\"  string")
	for f, i in app.doc.nodes[h].fields do if f.kind == "string" { set_field_text(&app, h, i, "key"); break }
	// condition: Reference ok
	if open_dot(t, &app, h, 0) && pick(t, &app, "Reference") {
		ref_choose(t, &app, "ok")
		if app.state == .Radial do pick(t, &app, "ok")
	}
	testing.expect_value(t, line_src(&app, h), "if v, ok := m[\"key\"]; ok {")

	// Types and scope: v is an int and ok a bool inside the if, unknown after it.
	ty, tok := var_type_at(&app, h + 1, "v")
	testing.expectf(t, tok && ty.expr == "int", "v: %v", ty)
	ty, tok = var_type_at(&app, h + 1, "ok")
	testing.expectf(t, tok && ty.expr == "bool", "ok: %v", ty)
	y_option(t, &app, h, "if", "Add else")
	el := line_with(&app, "} else {")
	ty, tok = var_type_at(&app, el + 1, "v")
	testing.expectf(t, tok && ty.expr == "int", "v in else: %v", ty)
	end := line_with(&app, "\t}", el + 1)
	_, tok = var_type_at(&app, end + 1, "v")
	testing.expect(t, !tok, "v unknown after the if")
	// Reference: inside the if the setup names are offered, after it they aren't.
	testing.expect(t, strings.contains(ref_names(&app, h + 1), "v ok"), ref_names(&app, h + 1))
	testing.expect(t, !strings.contains(ref_names(&app, end + 1), "ok"), ref_names(&app, end + 1))

	// LT+B in the setup removes it; Y on `if` -> Add setup brings back a dot.
	back_out(&app)
	for f, i in app.doc.nodes[h].fields do if f.text == "v" { focus_field_index(&app, h, i); break }
	testing.expect_value(t, ctrl_hint(&app), "LT+B: remove setup")
	delete_selected(&app)
	testing.expect_value(t, line_src(&app, h), "if ok {")
	y_option(t, &app, h, "if", "Add setup")
	testing.expect(t, app.state == .Radial && strings.contains(labels(&app), "Variable (:=)"), labels(&app))
	pick(t, &app, "Variable (:=)")
	testing.expect(t, strings.contains(line_src(&app, h), " := ") && strings.has_suffix(line_src(&app, h), "; ok {"), line_src(&app, h))
}

@(test)
test_branch_switch_value_cases :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, BASE)
	insert_at_dot(t, &app, 4, "Branching", "Switch")
	s := line_with(&app, "switch ")
	if open_dot(t, &app, s, 0) && pick(t, &app, "Reference") {
		ref_choose(t, &app, "x")
		if app.state == .Radial do pick(t, &app, "x")
	}
	c1 := s + 1
	// The case dot expects an int now.
	if open_dot(t, &app, c1, 0) {
		testing.expect(t, !dimmed(t, &app, "Number"), "a number fits")
		testing.expect(t, dimmed(t, &app, "true"), "a bool doesn't")
		testing.expect(t, !dimmed(t, &app, "Range"), "a range fits an int")
		pick(t, &app, "Number")
	}
	set_field_text(&app, c1, 3, "1")
	// Y on case -> Add value: case 1, 2:
	y_option(t, &app, c1, "case", "Add value")
	testing.expect(t, app.state == .Radial, "the new value's menu is open")
	pick(t, &app, "Number")
	for f, i in app.doc.nodes[c1].fields do if f.text == "0" && f.editable { set_field_text(&app, c1, i, "2"); break }
	testing.expect_value(t, line_src(&app, c1), "case 1, 2:")
	// Y on switch -> Add case: a range 3..<10
	y_option(t, &app, s, "switch", "Add case")
	c2 := line_with(&app, "case ", c1 + 1)
	if open_dot(t, &app, c2, 0) && pick(t, &app, "Range") do pick(t, &app, "a ..< b  (up to b)")
	fill_number(t, &app, c2, "3")
	fill_number(t, &app, c2, "10")
	testing.expect_value(t, line_src(&app, c2), "case 3..<10:")
	// Default case (only one).
	y_option(t, &app, s, "switch", "Add default case")
	focus_kw(t, &app, s, "switch")
	change_selected(&app)
	testing.expect(t, dimmed(t, &app, "Add default case"), "one default")
	back_out(&app)
	// Add case goes before the default.
	y_option(t, &app, c2, "case", "Add case after")
	c3 := line_with(&app, "case ", c2 + 1)
	fill_number(t, &app, c3, "11")
	want := "package main\n\nmain :: proc() {\n\tx := 1\n\tswitch x {\n" +
		"\tcase 1, 2:\n\n" +
		"\tcase 3..<10:\n\n" +
		"\tcase 11:\n\n" +
		"\tcase:\n\n" +
		"\t}\n}"
	testing.expectf(t, src(&app) == want, "got:\n%s", src(&app))

	// LT+B on a value with others: just it. On a case keyword: the clause.
	back_out(&app)
	for f, i in app.doc.nodes[c1].fields do if f.text == "2" { focus_field_index(&app, c1, i); break }
	delete_selected(&app)
	testing.expect_value(t, line_src(&app, c1), "case 1:")
	lt_b_kw(t, &app, c3, "case")
	testing.expect_value(t, line_with(&app, "case 11"), -1)
	// Y on a case value: refill (B puts it back).
	back_out(&app)
	for f, i in app.doc.nodes[c1].fields do if f.text == "1" { focus_field_index(&app, c1, i); break }
	change_selected(&app)
	testing.expect(t, app.state == .Radial, "value menu")
	back_out(&app)
	testing.expect_value(t, line_src(&app, c1), "case 1:")

	// Saved, loaded: the same structure.
	format_doc(&app)
	text := strings.clone(src(&app), context.temp_allocator)
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	cl, clok := br_line(app.doc.nodes[line_with(&app, "case 3..<10")])
	testing.expect(t, clok && cl.kind == .Case, "case structured")
	if clok {
		n := app.doc.nodes[line_with(&app, "case 3..<10")]
		testing.expect(t, is_range_op(n.fields[cl.expr_a + 1]), "range structured")
	}
}

@(test)
test_branch_enum_partial_switch :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nDir :: enum {\n\tNorth,\n\tSouth,\n\tEast,\n}\n\nmain :: proc() {\n\tdir: Dir\n}")
	at := line_with(&app, "dir: Dir") + 1
	insert_at_dot(t, &app, at, "Branching", "Partial switch")
	s := line_with(&app, "#partial switch")
	testing.expect(t, s > 0, src(&app))
	if open_dot(t, &app, s, 0) && pick(t, &app, "Reference") {
		ref_choose(t, &app, "dir")
		if app.state == .Radial do pick(t, &app, "dir")
	}
	if open_dot(t, &app, s + 1, 0) && pick(t, &app, "Enum value") do pick(t, &app, ".North")
	y_option(t, &app, s, "switch", "Add case")
	c2 := line_with(&app, "case ", s + 2)
	if open_dot(t, &app, c2, 0) {
		pick(t, &app, "Enum value")
		testing.expect(t, dimmed(t, &app, ".North"), ".North is used")
		testing.expect(t, !dimmed(t, &app, ".South"), ".South is free")
		pick(t, &app, ".South")
	}
	testing.expect_value(t, line_src(&app, s), "#partial switch dir {")
	testing.expect_value(t, line_src(&app, c2), "case .South:")
	// Y on switch: remove #partial, make it again.
	y_option(t, &app, s, "switch", "Remove #partial")
	testing.expect_value(t, line_src(&app, s), "switch dir {")
	y_option(t, &app, s, "switch", "Make #partial")
	testing.expect_value(t, line_src(&app, s), "#partial switch dir {")
	// LT+B on #partial.
	lt_b_kw(t, &app, s, "#partial")
	testing.expect_value(t, line_src(&app, s), "switch dir {")
}

@(test)
test_branch_type_switch :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nCircle :: struct {\n\tr: f32,\n}\n\nSquare :: struct {\n\tside: f32,\n}\n\nShape :: union {\n\tCircle,\n\tSquare,\n}\n\nmain :: proc() {\n\tshape: Shape\n}")
	at := line_with(&app, "shape: Shape") + 1
	insert_at_dot(t, &app, at, "Branching", "Type switch")
	s := line_with(&app, "switch ")
	set_field_text(&app, s, 3, "v")
	if open_dot(t, &app, s, 0) && pick(t, &app, "Reference") {
		ref_choose(t, &app, "shape")
		if app.state == .Radial do pick(t, &app, "shape")
	}
	testing.expect_value(t, line_src(&app, s), "switch v in shape {")
	if open_dot(t, &app, s + 1, 0, VARIANT_KIND) {
		testing.expect(t, strings.has_prefix(labels(&app), "Circle | Square | nil"), labels(&app))
		pick(t, &app, "Circle")
	}
	y_option(t, &app, s, "switch", "Add case")
	c2 := line_with(&app, "case ", s + 2)
	if open_dot(t, &app, c2, 0, VARIANT_KIND) {
		testing.expect(t, dimmed(t, &app, "Circle"), "Circle is used")
		pick(t, &app, "Square")
	}
	y_option(t, &app, s, "switch", "Add default case")
	testing.expect_value(t, line_src(&app, s + 1), "case Circle:")
	testing.expect_value(t, line_src(&app, c2), "case Square:")
	// v has the case's type in each clause, the union's in `case:`.
	ty, ok := var_type_at(&app, s + 2, "v")
	testing.expectf(t, ok && ty.expr == "Circle", "v in case Circle: %v", ty)
	ty, ok = var_type_at(&app, c2 + 1, "v")
	testing.expectf(t, ok && ty.expr == "Square", "v in case Square: %v", ty)
	dflt := line_with(&app, "case:")
	ty, ok = var_type_at(&app, dflt + 1, "v")
	testing.expectf(t, ok && ty.expr == "Shape", "v in case: %v", ty)
	_, ok = var_type_at(&app, line_with(&app, "\t}", dflt) + 1, "v")
	testing.expect(t, !ok, "v unknown after the switch")

	// Field of v inside `case Circle:`: v.r.
	body := s + 2
	focus_field_index(&app, body, 1)
	update(&app, Input{confirm = true})
	pick(t, &app, "Declarations")
	pick(t, &app, "Variable (:=)")
	if open_dot(t, &app, body, 0) && pick(t, &app, "Reference") {
		ref_choose(t, &app, "v")
		if app.state == .Radial && pick(t, &app, "Field of v") do pick(t, &app, "r   f32")
	}
	testing.expect(t, strings.has_suffix(line_src(&app, body), ":= v.r"), line_src(&app, body))

	// Y on a filled variant: the variants again.
	back_out(&app)
	c2 = line_with(&app, "case Square")
	for f, i in app.doc.nodes[c2].fields do if f.text == "Square" { focus_field_index(&app, c2, i); break }
	change_selected(&app)
	testing.expect(t, strings.contains(labels(&app), "Circle"), labels(&app))
	back_out(&app)
	testing.expect_value(t, line_src(&app, c2), "case Square:")

	format_doc(&app)
	text := strings.clone(src(&app), context.temp_allocator)
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	ci := line_with(&app, "case Circle:")
	found := false
	for f in app.doc.nodes[ci].fields do if f.text == "Circle" && f.kind == "type" do found = true
	testing.expect(t, found, "a type switch case loads its types as type fields")
}

@(test)
test_branch_switch_conditions :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, BASE)
	insert_at_dot(t, &app, 4, "Branching", "Switch (conditions)")
	s := line_with(&app, "switch {")
	testing.expect(t, s > 0, src(&app))
	if open_dot(t, &app, s + 1, 0) {
		testing.expect(t, dimmed(t, &app, "Number"), "a case condition is a bool")
		testing.expect(t, !dimmed(t, &app, "true"), "true fits")
		pick(t, &app, "Operator")
		pick(t, &app, "Compare")
		pick(t, &app, "a > b")
	}
	if open_dot(t, &app, s + 1, 0) && pick(t, &app, "Reference") {
		ref_choose(t, &app, "x")
		if app.state == .Radial do pick(t, &app, "x")
	}
	fill_number(t, &app, s + 1, "0")
	testing.expect_value(t, line_src(&app, s + 1), "case x > 0:")
}

@(test)
test_branch_case_dots_in_switch_body :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tx := 1\n\tswitch x {\n\tcase 1:\n\t\tx = 2\n\t}\n}")
	s := line_with(&app, "switch x")
	// The dot between the header and the first case: only cases.
	focus_dot_at(&app, s + 1)
	testing.expect_value(t, ctrl_hint(&app), "A: add a case")
	update(&app, Input{confirm = true})
	testing.expect_value(t, labels(&app), "Case | Default case")
	back_out(&app)
	// At the end of the clause: statements and cases.
	end := line_with(&app, "\t}")
	focus_dot_at(&app, end)
	testing.expect_value(t, ctrl_hint(&app), "A: add a statement or a case")
	update(&app, Input{confirm = true})
	testing.expect(t, strings.has_prefix(labels(&app), "Case | Default case | Declarations"), labels(&app))
	pick(t, &app, "Default case")
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n\tx := 1\n\tswitch x {\n\tcase 1:\n\t\tx = 2\n\tcase:\n\n\t}\n}")
	// A statement inserted into the default case gets the body's indentation.
	focus_field_index(&app, line_with(&app, "case:") + 1, 1)
	update(&app, Input{confirm = true})
	pick(t, &app, "Assignment")
	pick(t, &app, "Assignment")
	update(&app, Input{confirm = true}) // its target: the nearest name above (x)...
	update(&app, Input{confirm = true}) // ...Assign to > x
	testing.expect(t, strings.has_prefix(node_text(app.doc.nodes[line_with(&app, "case:") + 1], context.temp_allocator), "\t\tx = "), "statement in the case body")
	// The case via the first dot.
	focus_dot_at(&app, s + 1)
	update(&app, Input{confirm = true})
	pick(t, &app, "Case")
	testing.expect_value(t, line_src(&app, s + 1), "case :")
	testing.expect(t, app.doc.nodes[s + 1].fields[len(app.doc.nodes[s + 1].fields) - 2].hint == "int", "case dot typed from x")
}

@(test)
test_branch_load_round_trip :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\n" +
		"import \"core:fmt\"\n\n" +
		"Circle :: struct {\n\tr: f32,\n}\n\n" +
		"Square :: struct {\n\ts: f32,\n}\n\n" +
		"Shape :: union {\n\tCircle,\n\tSquare,\n}\n\n" +
		"Dir :: enum {\n\tNorth,\n\tSouth,\n}\n\n" +
		"main :: proc() {\n" +
		"\tx := 3\n" +
		"\tm := map[string]int{}\n" +
		"\tif v, ok := m[\"key\"]; ok {\n" +
		"\t\tfmt.println(v)\n" +
		"\t} else if x > 0 { // positive\n" +
		"\t\tfmt.println(ok)\n" +
		"\t} else {\n" +
		"\t}\n" +
		"\tswitch x {\n" +
		"\tcase 1: fmt.println(\"one\")\n" +
		"\tcase 2, 3:\n" +
		"\t\tfmt.println(\"two\")\n" +
		"\t\tswitch {\n" +
		"\t\tcase x > 2:\n" +
		"\t\t}\n" +
		"\tcase 4..<10:\n" +
		"\tcase: // the rest\n" +
		"\t}\n" +
		"\tc := 'b'\n" +
		"\tswitch c {\n" +
		"\tcase 'a'..='z', ':':\n" +
		"\t}\n" +
		"\tdir := Dir.North\n" +
		"\t#partial switch dir {\n" +
		"\tcase .North:\n" +
		"\t}\n" +
		"\tshape: Shape = Circle{1}\n" +
		"\t#partial switch v in shape {\n" +
		"\tcase Circle:\n" +
		"\t\tfmt.println(v.r)\n" +
		"\tcase Square, nil:\n" +
		"\t}\n" +
		"\tswitch y := x * 2; y {\n" +
		"\tcase 6:\n" +
		"\t}\n" +
		"\twhen ODIN_DEBUG {\n" +
		"\t} else when ODIN_OS == .Windows {\n" +
		"\t} else {\n" +
		"\t}\n" +
		"\titems := []int{1, 2}\n" +
		"\tif items[0] > 0 {\n" +
		"\t}\n" +
		"}"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	format_doc(&app)
	testing.expect_value(t, src(&app), text)
	kinds :: proc(app: ^App, needle: string) -> Br_Kind {
		ni := line_with(app, needle)
		if ni < 0 do return .None
		l, _ := br_line(app.doc.nodes[ni])
		return l.kind
	}
	testing.expect_value(t, kinds(&app, "if v, ok"), Br_Kind.If)
	testing.expect_value(t, kinds(&app, "else if x > 0"), Br_Kind.Else_If)
	testing.expect_value(t, kinds(&app, "case 1: fmt"), Br_Kind.Case)
	testing.expect_value(t, kinds(&app, "case 2, 3"), Br_Kind.Case)
	testing.expect_value(t, kinds(&app, "case 'a'"), Br_Kind.Case)
	testing.expect_value(t, kinds(&app, "#partial switch dir"), Br_Kind.Switch)
	testing.expect_value(t, kinds(&app, "switch v in shape"), Br_Kind.Switch)
	testing.expect_value(t, kinds(&app, "switch y :="), Br_Kind.Switch)
	testing.expect_value(t, kinds(&app, "case: // the rest"), Br_Kind.Case)
	// `when` stays a when chain (ctrl.odin), not an if chain.
	testing.expect_value(t, kinds(&app, "} else when"), Br_Kind.None)
	// Types through the loaded structure.
	ty, ok := var_type_at(&app, line_with(&app, "fmt.println(v,"), "v")
	testing.expectf(t, ok && ty.expr == "int", "v: %v", ty)
	ty, ok = var_type_at(&app, line_with(&app, "fmt.println(v.r"), "v")
	testing.expectf(t, ok && ty.expr == "Circle", "type switch v: %v", ty)
	ty, ok = var_type_at(&app, line_with(&app, "case 6:"), "y")
	testing.expectf(t, ok && ty.expr == "int", "switch setup y: %v", ty)
	ty, ok = expr_type_at(&app, line_with(&app, "if items"), "items[0]")
	testing.expectf(t, ok && ty.expr == "int", "items[0]: %v", ty)
	// The index in `m["key"]` is structured like the Index fill makes it.
	h := line_with(&app, "if v, ok")
	found := false
	for f in app.doc.nodes[h].fields do if f.text == "m[" do found = true
	testing.expect(t, found, "m[ is its own field")
}

@(test)
test_branch_handmade_switch :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package handmade\n\n" +
		"import win32 \"core:sys/windows\"\n\n" +
		"main_window_callback :: proc \"system\" (\n" +
		"\twindow: win32.HWND,\n" +
		"\tmessage: win32.UINT,\n" +
		"\tw_param: win32.WPARAM,\n" +
		"\tl_param: win32.LPARAM,\n" +
		") -> win32.LRESULT {\n" +
		"\tresult: win32.LRESULT = 0\n\n" +
		"\tswitch message {\n" +
		"\tcase win32.WM_SIZE:\n" +
		"\t\twin32.OutputDebugStringA(\"WM_SIZE\\n\")\n" +
		"\tcase win32.WM_PAINT:\n" +
		"\t\tpaint: win32.PAINTSTRUCT\n" +
		"\tcase:\n" +
		"\t\tresult = win32.DefWindowProcW(window, message, w_param, l_param)\n" +
		"\t}\n\n" +
		"\treturn result\n" +
		"}"
	app.os_name = "windows"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	format_doc(&app)
	testing.expect_value(t, src(&app), text)

	// Built from the menus: switch message { case win32.WM_SIZE: ... case win32.WM_PAINT: ... case: ... }
	s := line_with(&app, "switch message")
	end := line_with(&app, "\t}", s)
	delete_construct(&app, s, end)
	at := line_with(&app, "result: win32.LRESULT") + 1
	insert_at_dot(t, &app, at, "Branching", "Switch")
	s = line_with(&app, "switch ")
	if open_dot(t, &app, s, 0) && pick(t, &app, "Reference") {
		ref_choose(t, &app, "message")
		if app.state == .Radial do pick(t, &app, "message")
	}
	c1 := s + 1
	testing.expect_value(t, app.doc.nodes[c1].fields[len(app.doc.nodes[c1].fields) - 2].hint, "win32.UINT")
	fill_const :: proc(t: ^testing.T, app: ^App, ni: int, name: string, loc := #caller_location) {
		if !open_dot(t, app, ni, 0, loc = loc) || !pick(t, app, "Constant", loc) do return
		for _ in 0 ..< 8 {
			v := current_view(app)
			if v == nil || app.state != .Radial do return
			idx := -1
			for e, i in v.entries do if e.label == name || (len(e.children) > 0 && contains_leaf(e.children, name)) { idx = i; break }
			if !testing.expectf(t, idx >= 0, "%s reachable in %s", name, v.title, loc = loc) do return
			if v.entries[idx].label == name {
				testing.expect(t, !v.entries[idx].dim, "the constant fits a UINT", loc = loc)
				v.index = idx
				update(app, Input{confirm = true})
				return
			}
			v.index = idx
			update(app, Input{confirm = true})
		}
	}
	contains_leaf :: proc(entries: []Entry, name: string) -> bool {
		for e in entries {
			if len(e.children) == 0 && e.label == name do return true
			if len(e.children) > 0 && contains_leaf(e.children, name) do return true
		}
		return false
	}
	fill_const(t, &app, c1, "WM_SIZE")
	testing.expect_value(t, line_src(&app, c1), "case win32.WM_SIZE:")
	y_option(t, &app, c1, "case", "Add case after")
	c2 := line_with(&app, "case ", c1 + 1)
	fill_const(t, &app, c2, "WM_PAINT")
	y_option(t, &app, s, "switch", "Add default case")
	testing.expect_value(t, line_src(&app, c2), "case win32.WM_PAINT:")
	testing.expect(t, line_with(&app, "case:") > c2, "default case added")
	// WM_SIZE is grayed for a third case.
	y_option(t, &app, c2, "case", "Add case after")
	c3 := line_with(&app, "case ", c2 + 1)
	if open_dot(t, &app, c3, 0) && pick(t, &app, "Constant") {
		e, ok := find(current_view(&app).entries, "WM_SIZE")
		testing.expect(t, ok && e.dim, "WM_SIZE used")
		back_out(&app)
	}
	lt_b_kw(t, &app, c3, "case")
	testing.expect(t, line_with(&app, "case ", c2 + 1) < 0, "third case removed")
}

@(test)
test_branch_when_in_body :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, BASE)
	insert_at_dot(t, &app, 4, "Branching", "When")
	w := line_with(&app, "when ")
	if open_dot(t, &app, w, 0) {
		pick(t, &app, "Built-in constants")
		testing.expect(t, dimmed(t, &app, "ODIN_OS"), "ODIN_OS isn't a bool")
		pick(t, &app, "ODIN_DEBUG")
	}
	testing.expect_value(t, line_src(&app, w), "when ODIN_DEBUG {")
	back_out(&app)
	for f, i in app.doc.nodes[w].fields do if f.kind == KW && f.text == "when" { focus_field_index(&app, w, i); break }
	change_selected(&app)
	pick(t, &app, "Add else")
	back_out(&app)
	for f, i in app.doc.nodes[w].fields do if f.kind == KW && f.text == "when" { focus_field_index(&app, w, i); break }
	change_selected(&app)
	pick(t, &app, "Add else when")
	if open_dot(t, &app, line_with(&app, "else when"), 0) do pick(t, &app, "true")
	want := "package main\n\nmain :: proc() {\n\tx := 1\n\twhen ODIN_DEBUG {\n\n\t} else when true {\n\n\t} else {\n\n\t}\n}"
	testing.expectf(t, src(&app) == want, "got:\n%s", src(&app))
	// LT+B on else when: that branch only.
	back_out(&app)
	ew := line_with(&app, "else when")
	for f, i in app.doc.nodes[ew].fields do if f.kind == KW { focus_field_index(&app, ew, i); break }
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n\tx := 1\n\twhen ODIN_DEBUG {\n\n\t} else {\n\n\t}\n}")
}

@(test)
test_branch_index_on_field_and_comma_ok :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nPlayer :: struct {\n\titems: []int,\n\tname: string,\n}\n\nmain :: proc() {\n\tp: Player\n\ta: any = 1\n\tn, ok := a.(int)\n\tq := 0\n}")
	// Reference p -> Field of p -> p.items[i] -> key dot (an int).
	q := line_with(&app, "q := 0")
	insert_at_dot(t, &app, q + 1, "Declarations", "Variable (:=)")
	ni := q + 1
	if open_dot(t, &app, ni, 0) && pick(t, &app, "Reference") {
		ref_choose(t, &app, "p")
		if app.state == .Radial && pick(t, &app, "Field of p") {
			testing.expect(t, strings.contains(labels(&app), "p.items[i]   int"), labels(&app))
			testing.expect(t, strings.contains(labels(&app), "p.name[i]   u8"), labels(&app))
			pick(t, &app, "p.items[i]   int")
		}
	}
	eni, efi, ok := editor_target(&app)
	testing.expect(t, ok && eni == ni && app.doc.nodes[eni].fields[efi].slot && app.doc.nodes[eni].fields[efi].hint == "int", "on the index dot")
	if open_dot(t, &app, ni, 0) && pick(t, &app, "Reference") {
		ref_choose(t, &app, "q")
		if app.state == .Radial do pick(t, &app, "q")
	}
	testing.expect(t, strings.has_suffix(line_src(&app, ni), ":= p.items[q]"), line_src(&app, ni))
	name := app.doc.nodes[ni].fields[1].text
	ty, tok := var_type_at(&app, ni + 1, name)
	testing.expectf(t, tok && ty.expr == "int", "an element of []int: %v", ty)
	// `n, ok := a.(int)`
	ty, tok = var_type_at(&app, q, "n")
	testing.expectf(t, tok && ty.expr == "int", "n: %v", ty)
	ty, tok = var_type_at(&app, q, "ok")
	testing.expectf(t, tok && ty.expr == "bool", "ok: %v", ty)
}

@(test)
test_branch_switch_setup_and_value :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tx := 1\n\tswitch x {\n\tcase 1:\n\t}\n}")
	s := line_with(&app, "switch x")
	y_option(t, &app, s, "switch", "Add setup")
	pick(t, &app, "Variable (:=)")
	for f, i in app.doc.nodes[s].fields do if f.editable && f.kind == "" { set_field_text(&app, s, i, "y"); break }
	fill_number(t, &app, s, "2")
	testing.expect_value(t, line_src(&app, s), "switch y := 2; x {")
	// Change value: the value turns back into a dot; then y.
	y_option(t, &app, s, "switch", "Change value")
	testing.expect(t, app.state == .Radial, "value menu open")
	pick(t, &app, "Reference")
	ref_choose(t, &app, "y")
	if app.state == .Radial do pick(t, &app, "y")
	testing.expect_value(t, line_src(&app, s), "switch y := 2; y {")
	ty, ok := var_type_at(&app, s + 1, "y")
	testing.expectf(t, ok && ty.expr == "int", "y: %v", ty)
	// B on Change value puts it back.
	y_option(t, &app, s, "switch", "Change value")
	back_out(&app)
	testing.expect_value(t, line_src(&app, s), "switch y := 2; y {")
	y_option(t, &app, s, "switch", "Remove setup")
	testing.expect_value(t, line_src(&app, s), "switch y {")
	// Y on the if condition changes it, keeping its bool hint.
	load(&app, "package main\n\nmain :: proc() {\n\tx := 1\n\tif x > 0 {\n\t}\n}")
	h := line_with(&app, "if x")
	y_option(t, &app, h, "if", "Change condition")
	testing.expect(t, app.state == .Radial && dimmed(t, &app, "Number"), "the condition expects a bool")
	pick(t, &app, "false")
	testing.expect_value(t, line_src(&app, h), "if false {")
}

@(test)
test_branch_type_switch_variable_scope :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nShape :: union {\n\tint,\n\tstring,\n}\n\nmain :: proc() {\n\tshape: Shape\n\tswitch v in shape {\n\tcase int:\n\t\tx := v\n\tcase string:\n\t}\n\ty := 1\n}")
	x := line_with(&app, "x := v")
	y := line_with(&app, "y := 1")
	testing.expect(t, strings.contains(ref_names(&app, x), "v"), ref_names(&app, x))
	testing.expect(t, !strings.contains(ref_names(&app, y + 1), " v "), ref_names(&app, y + 1))
	ty, ok := var_type_at(&app, x + 1, "x")
	testing.expectf(t, ok && ty.expr == "int", "x: %v", ty)
	// A name declared in one case isn't known in another.
	_, ok = var_type_at(&app, line_with(&app, "case string") + 1, "x")
	testing.expect(t, !ok, "x is local to its case")
}

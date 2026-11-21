package model

// Branching (branch.odin) and loops (loops.odin) together, driven the way the
// controller does it: a switch inside a labeled loop breaking out of it, an
// if-with-setup using a C-style loop's variable, a type switch inside a range
// loop, and a file with every branching and loop form loaded and saved back.
//
// Set DOODLE_CHECK_DIR to a folder to have each program written there as
// <dir>/<name>/main.odin, ready for `odin check`.

import "core:os"
import "core:path/filepath"
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
load :: proc(app: ^App, text: string) {
	app.state = .Editor
	doc_from_source(app, text)
}

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
find :: proc(entries: []Entry, label: string) -> (Entry, bool) {
	for e in entries {
		if e.label == label do return e, true
		if r, ok := find(e.children, label); ok do return r, true
	}
	return {}, false
}

@(private = "file")
has_entry :: proc(app: ^App, label: string) -> bool {
	v := current_view(app)
	if v == nil do return false
	_, ok := find(v.entries, label)
	return ok
}

@(private = "file")
dimmed :: proc(t: ^testing.T, app: ^App, label: string, loc := #caller_location) -> bool {
	v := current_view(app)
	if !testing.expectf(t, v != nil, "no menu open (wanted %q)", label, loc = loc) do return false
	e, ok := find(v.entries, label)
	testing.expectf(t, ok, "menu entry %q should exist: %s", label, labels(app), loc = loc)
	return e.dim
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

// A on the green dot before line `at`, then group -> leaf.
@(private = "file")
add_stmt :: proc(t: ^testing.T, app: ^App, at: int, group, leaf: string, loc := #caller_location) -> int {
	back_out(app)
	focus_dot_at(app, at)
	update(app, Input{confirm = true})
	if pick(t, app, group, loc) do pick(t, app, leaf, loc)
	return at
}

// A on the "●" statement line ni, then group -> leaf.
@(private = "file")
add_in_body :: proc(t: ^testing.T, app: ^App, ni: int, group, leaf: string, loc := #caller_location) -> int {
	back_out(app)
	if !testing.expectf(t, ni >= 0 && ni < len(app.doc.nodes) && is_body_slot_line(app.doc.nodes[ni]), "no statement line at %d", ni, loc = loc) do return -1
	focus_field_index(app, ni, 1)
	update(app, Input{confirm = true})
	if pick(t, app, group, loc) do pick(t, app, leaf, loc)
	return ni
}

@(private = "file")
body_line :: proc(app: ^App, from: int) -> int {
	for i in from ..< len(app.doc.nodes) do if is_body_slot_line(app.doc.nodes[i]) do return i
	return -1
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

// In Reference pick mode: D-pad (right, then left) until `name` is highlighted, then A.
@(private = "file")
ref_choose :: proc(t: ^testing.T, app: ^App, name: string, loc := #caller_location) -> bool {
	if !testing.expect(t, app.ref_pick_active, "in pick mode", loc = loc) do return false
	for _ in 0 ..< 64 {
		if cursor_text(app) == name do break
		update(app, Input{right = true})
	}
	for _ in 0 ..< 64 {
		if cursor_text(app) == name do break
		update(app, Input{left = true})
	}
	if !testing.expectf(t, cursor_text(app) == name, "%q should be pickable", name, loc = loc) do return false
	update(app, Input{confirm = true})
	return true
}

// A on the first value dot of ni -> Reference -> `name` -> Pass as `pass_as` (default: the name).
@(private = "file")
fill_ref :: proc(t: ^testing.T, app: ^App, ni: int, name: string, pass_as := "", loc := #caller_location) {
	if !open_dot(t, app, ni, 0, loc = loc) || !pick(t, app, "Reference", loc) do return
	if ref_choose(t, app, name, loc) && app.state == .Radial do pick(t, app, pass_as == "" ? name : pass_as, loc)
}

@(private = "file")
fill_number :: proc(t: ^testing.T, app: ^App, ni: int, text: string, loc := #caller_location) {
	if !open_dot(t, app, ni, 0, loc = loc) || !pick(t, app, "Number", loc) do return
	eni, efi, ok := editor_target(app)
	if testing.expect(t, ok && app.doc.nodes[eni].fields[efi].text == "0", "on the number", loc = loc) do set_field_text(app, eni, efi, text)
}

// The names Reference offers from a dot on line ni.
@(private = "file")
ref_names :: proc(app: ^App, ni: int) -> []string {
	saved_ni, saved_fi := app.slot_ni, app.slot_fi
	app.slot_ni, app.slot_fi = ni, 0
	defer app.slot_ni, app.slot_fi = saved_ni, saved_fi
	out := make([dynamic]string, context.temp_allocator)
	for c in ref_candidates(app) do append(&out, app.doc.nodes[c.ni].fields[c.fi].text)
	return out[:]
}

@(private = "file")
offers :: proc(app: ^App, ni: int, name: string) -> bool {
	for n in ref_names(app, ni) do if n == name do return true
	return false
}

// LT+B on every leftover "●" statement line.
@(private = "file")
drop_body_lines :: proc(app: ^App) {
	back_out(app)
	for _ in 0 ..< 64 {
		b := body_line(app, 0)
		if b < 0 do return
		focus_field_index(app, b, 1)
		delete_selected(app)
	}
}

// Formatted, saved, loaded back, formatted again: unchanged.
@(private = "file")
expect_stable :: proc(t: ^testing.T, app: ^App, loc := #caller_location) -> string {
	format_doc(app)
	text := strings.clone(src(app), context.temp_allocator)
	load(app, text)
	testing.expectf(t, src(app) == text, "reload changed it:\n%s", src(app), loc = loc)
	format_doc(app)
	testing.expectf(t, src(app) == text, "format after reload changed it:\n%s", src(app), loc = loc)
	return text
}

// With DOODLE_CHECK_DIR set: <dir>/<name>/main.odin for `odin check`.
@(private = "file")
write_for_check :: proc(name, text: string) {
	dir := os.get_env("DOODLE_CHECK_DIR", context.temp_allocator)
	if dir == "" do return
	sub, _ := filepath.join({dir, name}, context.temp_allocator)
	os.make_directory_all(sub)
	file, _ := filepath.join({sub, "main.odin"}, context.temp_allocator)
	_ = os.write_entire_file(file, transmute([]u8)text)
}

// ---------------------------------------------------------------------------

// The statement menu has every Branching and Loops form, and Jumps.
@(test)
test_bl_statement_menu_groups :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tx := 1\n}")
	focus_dot_at(&app, 4)
	update(&app, Input{confirm = true})
	if pick(t, &app, "Branching") {
		testing.expect_value(t, labels(&app), "If | If / Else | If with setup | Switch | Switch (conditions) | Partial switch | Type switch | When")
	}
	back_out(&app)
	focus_dot_at(&app, 4)
	update(&app, Input{confirm = true})
	if pick(t, &app, "Loops") {
		testing.expect_value(t, labels(&app), "For (condition) | For (C-style) | For (infinite) | For ... in | For x, i in | For i in 0..<n | For i in 0..=n | For &x in | #reverse for | #unroll for | Labeled for")
	}
	back_out(&app)
	focus_dot_at(&app, 4)
	update(&app, Input{confirm = true})
	if pick(t, &app, "Jumps and cleanup") {
		testing.expect(t, has_entry(&app, "Break") && has_entry(&app, "Continue"), labels(&app))
		testing.expect(t, dimmed(t, &app, "Break"), "no loop or switch here")
		testing.expect(t, !has_entry(&app, "Fallthrough"), "fallthrough only inside a case clause")
	}
}

// outer: for item in nums { switch item { case 1: break outer  case: continue } }
@(test)
test_bl_labeled_loop_switch_break_outer :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tnums: []int\n}\n")
	ni := add_stmt(t, &app, line_with(&app, "nums:") + 1, "Loops", "Labeled for")
	fill_ref(t, &app, ni, "nums")
	testing.expect_value(t, line_src(&app, ni), "outer: for item in nums {")

	s := add_in_body(t, &app, ni + 1, "Branching", "Switch")
	testing.expect(t, offers(&app, s, "item"), "the loop variable can be switched on")
	fill_ref(t, &app, s, "item")
	testing.expect_value(t, line_src(&app, s), "switch item {")
	c1 := s + 1
	// The case dot expects the loop variable's type (int, from []int).
	branch_sync(&app)
	cf := app.doc.nodes[c1].fields
	hint := ""
	for f in cf do if f.slot && f.kind == "value" do hint = f.hint
	testing.expect_value(t, hint, "int")
	fill_number(t, &app, c1, "1")
	testing.expect_value(t, line_src(&app, c1), "case 1:")

	// In the case clause: break (the switch), break outer, continue, continue outer.
	body := c1 + 1
	back_out(&app)
	focus_field_index(&app, body, 1)
	update(&app, Input{confirm = true})
	if pick(t, &app, "Jumps and cleanup") {
		testing.expect(t, !dimmed(t, &app, "Break"), "break fits in a switch")
		testing.expect(t, !dimmed(t, &app, "Continue"), "continue fits: the switch is in a loop")
		testing.expect(t, has_entry(&app, "Continue outer"), "outer is a loop label in scope")
		pick(t, &app, "Break outer")
	}
	testing.expect_value(t, line_src(&app, body), "break outer")
	sc := jump_scope(&app, body)
	testing.expect(t, sc.in_loop && sc.in_switch, "inside a switch inside a loop")

	// Default case: continue (the loop).
	focus_field_index(&app, s, 0)
	for f, i in app.doc.nodes[s].fields do if f.kind == BR_KW && f.text == "switch" do focus_field_index(&app, s, i)
	change_selected(&app)
	pick(t, &app, "Add default case")
	dflt := line_with(&app, "case:")
	testing.expect(t, dflt > c1, src(&app))
	if dflt > 0 {
		b := body_line(&app, dflt)
		add_in_body(t, &app, b, "Jumps and cleanup", "Continue")
		testing.expect_value(t, line_src(&app, b), "continue")
		// The loop variable is known inside the default clause, with its type.
		ty, ok := var_type_at(&app, b, "item")
		testing.expectf(t, ok && ty.expr == "int", "item: %v", ty)
	}
	// After the loop: item isn't offered, the label isn't in scope.
	drop_body_lines(&app)
	end := len(app.doc.nodes) - 1
	for end > 0 && line_src(&app, end) != "}" do end -= 1
	testing.expect(t, !offers(&app, end, "item"), "item is unknown after the loop")
	testing.expect_value(t, len(jump_scope(&app, end).labels), 0)

	want := "package main\n\nmain :: proc() {\n" +
		"\tnums: []int\n" +
		"\touter: for item in nums {\n" +
		"\t\tswitch item {\n" +
		"\t\tcase 1:\n" +
		"\t\t\tbreak outer\n" +
		"\t\tcase:\n" +
		"\t\t\tcontinue\n" +
		"\t\t}\n" +
		"\t}\n" +
		"}"
	text := expect_stable(t, &app)
	testing.expectf(t, text == want, "got:\n%s", text)
	// Both headers load structured.
	testing.expect(t, line_with(&app, "outer: for") >= 0, src(&app))
	if h := line_with(&app, "outer: for"); h >= 0 {
		_, lok := loop_hdr(app.doc.nodes[h])
		testing.expect(t, lok, "the loop header loads structured")
		l, bok := br_line(app.doc.nodes[h + 1])
		testing.expect(t, bok && l.kind == .Switch, "the switch loads structured")
		cl, cok := br_line(app.doc.nodes[h + 2])
		testing.expect(t, cok && cl.kind == .Case, "the case loads structured")
	}
	write_for_check("labeled_switch", text)
}

// for i := 0; i < 10; i += 1 { if v, ok := m[i]; ok { } }
@(test)
test_bl_if_setup_in_cstyle_loop :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nimport \"core:fmt\"\n\nmain :: proc() {\n\tm: map[int]string\n}\n")
	ni := add_stmt(t, &app, line_with(&app, "m: map") + 1, "Loops", "For (C-style)")
	fill_number(t, &app, ni, "10")
	testing.expect_value(t, line_src(&app, ni), "for i := 0; i < 10; i += 1 {")

	h := add_in_body(t, &app, ni + 1, "Branching", "If with setup")
	eni, efi, ok := editor_target(&app)
	testing.expect(t, ok && eni == h && app.doc.nodes[eni].fields[efi].kind == SETUP_KIND, "on the setup dot")
	update(&app, Input{confirm = true})
	pick(t, &app, "Two names (:=)")
	for f, i in app.doc.nodes[h].fields do if f.editable && f.text != "ok" { set_field_text(&app, h, i, "v"); break }
	// value: m[i] (Reference m -> Pass as m[key], the key: the loop variable).
	fill_ref(t, &app, h, "m", "m[key]   string")
	eni, efi, ok = editor_target(&app)
	testing.expect(t, ok && app.doc.nodes[eni].fields[efi].slot && app.doc.nodes[eni].fields[efi].hint == "int", "on the key dot (an int)")
	testing.expect(t, offers(&app, h, "i"), "the loop variable is offered inside the loop")
	fill_ref(t, &app, h, "i")
	fill_ref(t, &app, h, "ok")
	testing.expect_value(t, line_src(&app, h), "if v, ok := m[i]; ok {")

	// Types and scope: i, v, ok inside the if; i (not v / ok) after it; none after the loop.
	inner := h + 1
	ty, tok := var_type_at(&app, inner, "i")
	testing.expectf(t, tok && ty.expr == "int", "i: %v", ty)
	ty, tok = var_type_at(&app, inner, "v")
	testing.expectf(t, tok && ty.expr == "string", "v: %v", ty)
	ty, tok = var_type_at(&app, inner, "ok")
	testing.expectf(t, tok && ty.expr == "bool", "ok: %v", ty)
	testing.expect(t, offers(&app, inner, "v") && offers(&app, inner, "i"), "v and i inside the if")

	// Use them: fmt.println is a call; keep it simple - v printed through a declaration.
	d := add_in_body(t, &app, inner, "Declarations", "Variable (:=)")
	fill_ref(t, &app, d, "v")
	for f, i in app.doc.nodes[d].fields do if f.editable && f.text != "v" { set_field_text(&app, d, i, "s"); break }
	testing.expect(t, strings.has_suffix(line_src(&app, d), ":= v"), line_src(&app, d))

	if_end := line_with(&app, "\t\t}", d + 1)
	after_if := body_line(&app, if_end)
	if testing.expect(t, after_if > if_end && after_if < len(app.doc.nodes), "a statement dot after the if") {
		testing.expect(t, offers(&app, after_if, "i"), "i still in scope after the if")
		testing.expect(t, !offers(&app, after_if, "v") && !offers(&app, after_if, "ok"), "v / ok only inside the if")
		_, vok := var_type_at(&app, after_if, "v")
		testing.expect(t, !vok, "v unknown after the if")
	}
	drop_body_lines(&app)
	end := len(app.doc.nodes) - 1
	for end > 0 && line_src(&app, end) != "}" do end -= 1
	testing.expect(t, !offers(&app, end, "i"), "i unknown after the loop")

	want := "package main\n\nimport \"core:fmt\"\n\nmain :: proc() {\n" +
		"\tm: map[int]string\n" +
		"\tfor i := 0; i < 10; i += 1 {\n" +
		"\t\tif v, ok := m[i]; ok {\n" +
		"\t\t\ts := v\n" +
		"\t\t}\n" +
		"\t}\n" +
		"}"
	text := expect_stable(t, &app)
	testing.expectf(t, text == want, "got:\n%s", text)
	// The check copy prints s (Odin rejects an unused variable; `fmt` is imported for it).
	checked, _ := strings.replace(text, "s := v\n", "s := v\n\t\t\tfmt.println(s)\n", 1, context.temp_allocator)
	write_for_check("if_setup_in_loop", checked)
}

// for i in 0..<3 { switch v in shapes[i] { case Circle: r := v.r  case Square: } }
@(test)
test_bl_type_switch_in_range_loop :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nCircle :: struct {\n\tr: f32,\n}\n\nSquare :: struct {\n\tside: f32,\n}\n\nShape :: union {\n\tCircle,\n\tSquare,\n}\n\nmain :: proc() {\n\tshapes: [3]Shape\n}\n")
	ni := add_stmt(t, &app, line_with(&app, "shapes:") + 1, "Loops", "For i in 0..<n")
	fill_number(t, &app, ni, "3")
	testing.expect_value(t, line_src(&app, ni), "for i in 0..<3 {")

	s := add_in_body(t, &app, ni + 1, "Branching", "Type switch")
	for f, i in app.doc.nodes[s].fields do if f.editable && !f.slot { set_field_text(&app, s, i, "v"); break }
	fill_ref(t, &app, s, "shapes", "shapes[i]   Shape")
	fill_ref(t, &app, s, "i") // the index: the loop variable
	testing.expect_value(t, line_src(&app, s), "switch v in shapes[i] {")

	if open_dot(t, &app, s + 1, 0, VARIANT_KIND) {
		testing.expect(t, strings.has_prefix(labels(&app), "Circle | Square | nil"), labels(&app))
		pick(t, &app, "Circle")
	}
	back_out(&app)
	for f, i in app.doc.nodes[s].fields do if f.kind == BR_KW && f.text == "switch" do focus_field_index(&app, s, i)
	change_selected(&app)
	pick(t, &app, "Add case")
	c2 := line_with(&app, "case ", s + 2)
	if open_dot(t, &app, c2, 0, VARIANT_KIND) {
		testing.expect(t, dimmed(t, &app, "Circle"), "Circle is used")
		pick(t, &app, "Square")
	}
	testing.expect_value(t, line_src(&app, s + 1), "case Circle:")
	testing.expect_value(t, line_src(&app, c2), "case Square:")

	// v has each case's type; i stays known inside the clauses.
	ty, ok := var_type_at(&app, s + 2, "v")
	testing.expectf(t, ok && ty.expr == "Circle", "v in case Circle: %v", ty)
	ty, ok = var_type_at(&app, c2 + 1, "v")
	testing.expectf(t, ok && ty.expr == "Square", "v in case Square: %v", ty)
	ty, ok = var_type_at(&app, c2 + 1, "i")
	testing.expectf(t, ok && ty.expr == "int", "i in case Square: %v", ty)

	// In case Circle: r := v.r (Field of the type switch variable).
	body := s + 2
	add_in_body(t, &app, body, "Declarations", "Variable (:=)")
	if open_dot(t, &app, body, 0) && pick(t, &app, "Reference") {
		if ref_choose(t, &app, "v") && app.state == .Radial && pick(t, &app, "Field of v") do pick(t, &app, "r   f32")
	}
	for f, i in app.doc.nodes[body].fields do if f.editable && f.text != "v.r" && f.text != "v" && f.text != "r" { set_field_text(&app, body, i, "radius"); break }
	testing.expect(t, strings.has_suffix(line_src(&app, body), ":= v.r"), line_src(&app, body))

	drop_body_lines(&app)
	end := len(app.doc.nodes) - 1
	for end > 0 && line_src(&app, end) != "}" do end -= 1
	testing.expect(t, !offers(&app, end, "v") && !offers(&app, end, "i"), "v / i unknown after the loop")

	text := expect_stable(t, &app)
	want_body := "\tfor i in 0..<3 {\n" +
		"\t\tswitch v in shapes[i] {\n" +
		"\t\tcase Circle:\n"
	testing.expectf(t, strings.contains(text, want_body), "got:\n%s", text)
	testing.expectf(t, strings.contains(text, "\t\tcase Square:\n\t\t}\n\t}\n}"), "got:\n%s", text)
	write_for_check("type_switch_in_loop", text)
}

// Every form from both tables, written by hand: loads structured, saves
// unchanged, format_doc leaves it alone.
@(private = "file")
EVERY_FORM :: "package main\n\n" +
	"import \"core:fmt\"\n\n" +
	"Circle :: struct {\n\tr: f32,\n}\n\n" +
	"Square :: struct {\n\tside: f32,\n}\n\n" +
	"Shape :: union {\n\tCircle,\n\tSquare,\n}\n\n" +
	"Dir :: enum {\n\tNorth,\n\tSouth,\n\tEast,\n\tWest,\n}\n\n" +
	"Item :: struct {\n\thp: int,\n}\n\n" +
	"main :: proc() {\n" +
	"\tx := 3\n" +
	"\tm := map[string]int{}\n" +
	"\tdir := Dir.North\n" +
	"\tshape: Shape = Circle{1}\n" +
	"\titems := make([dynamic]Item)\n" +
	"\tif x > 0 {\n" +
	"\t\tfmt.println(\"positive\")\n" +
	"\t} else if x < 0 {\n" +
	"\t\tfmt.println(\"negative\")\n" +
	"\t} else {\n" +
	"\t\tfmt.println(\"zero\")\n" +
	"\t}\n" +
	"\tif v, ok := m[\"key\"]; ok {\n" +
	"\t\tfmt.println(v)\n" +
	"\t}\n" +
	"\tswitch x {\n" +
	"\tcase 1:\n" +
	"\t\tfmt.println(\"one\")\n" +
	"\tcase 2, 3:\n" +
	"\t\tfmt.println(\"two or three\")\n" +
	"\tcase:\n" +
	"\t\tfmt.println(\"other\")\n" +
	"\t}\n" +
	"\tswitch x {\n" +
	"\tcase 0..<10:\n" +
	"\t\tfmt.println(\"small\")\n" +
	"\tcase 10..=99:\n" +
	"\t\tfmt.println(\"medium\")\n" +
	"\t}\n" +
	"\t#partial switch dir {\n" +
	"\tcase .North, .South:\n" +
	"\t\tfmt.println(\"vertical\")\n" +
	"\t}\n" +
	"\tswitch v in shape {\n" +
	"\tcase Circle:\n" +
	"\t\tfmt.println(v.r)\n" +
	"\tcase Square:\n" +
	"\t\tfmt.println(v.side)\n" +
	"\t}\n" +
	"\twhen ODIN_DEBUG {\n" +
	"\t\tfmt.println(\"debug\")\n" +
	"\t}\n" +
	"\tfor i := 0; i < 10; i += 1 {\n" +
	"\t\tfmt.println(i)\n" +
	"\t}\n" +
	"\tfor x < 10 {\n" +
	"\t\tx += 1\n" +
	"\t}\n" +
	"\tfor {\n" +
	"\t\tbreak\n" +
	"\t}\n" +
	"\tfor i in 0..<10 {\n" +
	"\t\tfmt.println(i)\n" +
	"\t}\n" +
	"\tfor i in 0..=9 {\n" +
	"\t\tfmt.println(i)\n" +
	"\t}\n" +
	"\tfor item, index in items {\n" +
	"\t\tfmt.println(item, index)\n" +
	"\t}\n" +
	"\tfor ch, i in \"hello\" {\n" +
	"\t\tfmt.println(ch, i)\n" +
	"\t}\n" +
	"\tfor key, value in m {\n" +
	"\t\tfmt.println(key, value)\n" +
	"\t}\n" +
	"\tfor &item in items {\n" +
	"\t\titem.hp -= 1\n" +
	"\t}\n" +
	"\t#reverse for item in items {\n" +
	"\t\tfmt.println(item)\n" +
	"\t}\n" +
	"\t#unroll for i in 0..<4 {\n" +
	"\t\tfmt.println(i)\n" +
	"\t}\n" +
	"\touter: for item in items {\n" +
	"\t\tfor i in 0..<3 {\n" +
	"\t\t\tswitch i {\n" +
	"\t\t\tcase 1:\n" +
	"\t\t\t\tcontinue outer\n" +
	"\t\t\tcase 2:\n" +
	"\t\t\t\tbreak outer\n" +
	"\t\t\t}\n" +
	"\t\t\tif v, ok := m[\"x\"]; ok && v > item.hp {\n" +
	"\t\t\t\tbreak\n" +
	"\t\t\t}\n" +
	"\t\t}\n" +
	"\t}\n" +
	"}"

@(test)
test_bl_every_form_round_trip :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, EVERY_FORM)
	testing.expectf(t, src(&app) == EVERY_FORM, "load -> save changed it:\n%s", src(&app))
	format_doc(&app)
	testing.expectf(t, src(&app) == EVERY_FORM, "format_doc changed it:\n%s", src(&app))
	load(&app, src(&app))
	testing.expectf(t, src(&app) == EVERY_FORM, "second load changed it:\n%s", src(&app))

	// Every loop header is structured.
	loops := 0
	for n in app.doc.nodes do if _, ok := loop_hdr(n); ok do loops += 1
	testing.expect_value(t, loops, 13)
	// Every if / else / switch / case line is structured.
	kind :: proc(app: ^App, needle: string, from := 0) -> Br_Kind {
		ni := line_with(app, needle, from)
		if ni < 0 do return .None
		l, _ := br_line(app.doc.nodes[ni])
		return l.kind
	}
	testing.expect_value(t, kind(&app, "if x > 0"), Br_Kind.If)
	testing.expect_value(t, kind(&app, "else if x < 0"), Br_Kind.Else_If)
	testing.expect_value(t, kind(&app, "} else {"), Br_Kind.Else)
	testing.expect_value(t, kind(&app, "if v, ok := m[\"key\"]"), Br_Kind.If)
	testing.expect_value(t, kind(&app, "case 2, 3"), Br_Kind.Case)
	testing.expect_value(t, kind(&app, "case 0..<10"), Br_Kind.Case)
	testing.expect_value(t, kind(&app, "case 10..=99"), Br_Kind.Case)
	testing.expect_value(t, kind(&app, "#partial switch dir"), Br_Kind.Switch)
	testing.expect_value(t, kind(&app, "switch v in shape"), Br_Kind.Switch)
	testing.expect_value(t, kind(&app, "switch i {"), Br_Kind.Switch)
	testing.expect_value(t, kind(&app, "if v, ok := m[\"x\"]"), Br_Kind.If)

	// Names and scopes across the two features.
	at := line_with(&app, "continue outer")
	ty, ok := var_type_at(&app, at, "item")
	testing.expectf(t, ok && ty.expr == "Item", "item: %v", ty)
	ty, ok = var_type_at(&app, at, "i")
	testing.expectf(t, ok && ty.expr == "int", "i: %v", ty)
	sc := jump_scope(&app, at)
	testing.expect(t, sc.in_loop && sc.in_switch, "in a switch in a loop")
	has_outer := false
	for l in sc.labels do if l.name == "outer" && l.is_loop do has_outer = true
	testing.expect(t, has_outer, "outer is in scope")
	brk := line_with(&app, "\t\t\t\tbreak\n") // the plain break inside the if
	if brk < 0 do brk = line_with(&app, "if v, ok := m[\"x\"]") + 1
	ty, ok = var_type_at(&app, brk, "v")
	testing.expectf(t, ok && ty.expr == "int", "setup v inside the loop: %v", ty)
	ty, ok = var_type_at(&app, line_with(&app, "case Square:") + 1, "v")
	testing.expectf(t, ok && ty.expr == "Square", "type switch v: %v", ty)
	ty, ok = var_type_at(&app, line_with(&app, "for key, value in m") + 1, "value")
	testing.expectf(t, ok && ty.expr == "int", "map value: %v", ty)
	ty, ok = var_type_at(&app, line_with(&app, "for ch, i in") + 1, "ch")
	testing.expectf(t, ok && ty.expr == "rune", "string char: %v", ty)

	write_for_check("every_form", EVERY_FORM)
}

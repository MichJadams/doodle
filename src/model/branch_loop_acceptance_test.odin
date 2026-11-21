package model

// Acceptance tests for the Branching and Loops tables: one controller-driven
// test per row, each building exactly the row's example inside `main` (A on
// dots, menu picks, Reference / Pass as / Field of, Y, LT+B, LT+A renames),
// checking the saved text and the names the construct introduces (type, scope,
// Reference pick), then running `odin check` on the program.
// Plus: the user's `switch message {...}` and `for win32.GetMessageW(...) > 0`
// in a win32 program, and a verbatim load / save of a file with every example.
//
// `odin check` runs when DOODLE_ODIN is the path to odin.exe (programs go to
// DOODLE_CHECK_DIR, default <temp>/doodle_accept_check/<test>/main.odin).

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
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
	for i in max(from, 0) ..< len(app.doc.nodes) do if strings.contains(node_text(app.doc.nodes[i], context.temp_allocator), text) do return i
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

// The entries leading to the leaf `label` (with fill `fill` when given).
@(private = "file")
path_to :: proc(entries: []Entry, label, fill: string, out: ^[dynamic]Entry) -> bool {
	for e in entries {
		append(out, e)
		if len(e.children) == 0 && e.label == label && (fill == "" || e.fill == fill) do return true
		if len(e.children) > 0 && path_to(e.children, label, fill, out) do return true
		pop(out)
	}
	return false
}

// From the current view, walk down to the leaf `label`, one A per level.
@(private = "file")
pick_leaf :: proc(t: ^testing.T, app: ^App, label: string, fill := "", loc := #caller_location) {
	v := current_view(app)
	if !testing.expectf(t, v != nil, "no menu open (wanted %q)", label, loc = loc) do return
	p := make([dynamic]Entry, 0, 8, context.temp_allocator)
	if !testing.expectf(t, path_to(v.entries, label, fill, &p), "%s should be reachable", label, loc = loc) do return
	for want in p {
		v = current_view(app)
		if !testing.expectf(t, v != nil && app.state == .Radial, "menu closed on the way to %q", label, loc = loc) do return
		found := -1
		for e, i in v.entries {
			same := len(want.children) > 0 ? raw_data(e.children) == raw_data(want.children) : (e.label == want.label && e.fill == want.fill && e.call_name == want.call_name && e.call_pkg == want.call_pkg)
			if same { found = i; break }
		}
		if !testing.expectf(t, found >= 0, "step %q not in menu %q", want.label, v.title, loc = loc) do return
		v.index = found
		update(app, Input{confirm = true})
	}
}

@(private = "file")
back_out :: proc(app: ^App) {
	for _ in 0 ..< 16 {
		if app.state == .Editor && !app.ref_pick_active && !app.mod_pick_active do return
		update(app, Input{cancel = true})
	}
}

@(private = "file")
cursor_text :: proc(app: ^App) -> string {
	ni, fi, ok := editor_target(app)
	if !ok do return "<none>"
	return app.doc.nodes[ni].fields[fi].text
}

@(private = "file")
body_line :: proc(app: ^App, from: int) -> int {
	if from < 0 do return -1
	for i in from ..< len(app.doc.nodes) do if is_body_slot_line(app.doc.nodes[i]) do return i
	return -1
}

// A on the green dot before line `at`, then group -> leaf. Returns the new line.
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

// A on the first value dot of ni -> Reference -> `name` -> Field of name -> `field` ("hp   int").
@(private = "file")
fill_field :: proc(t: ^testing.T, app: ^App, ni: int, name, field: string, loc := #caller_location) {
	if !open_dot(t, app, ni, 0, loc = loc) || !pick(t, app, "Reference", loc) do return
	if ref_choose(t, app, name, loc) && app.state == .Radial && pick(t, app, strings.concatenate({"Field of ", name}, context.temp_allocator), loc) do pick(t, app, field, loc)
}

@(private = "file")
fill_number :: proc(t: ^testing.T, app: ^App, ni: int, text: string, loc := #caller_location) {
	if !open_dot(t, app, ni, 0, loc = loc) || !pick(t, app, "Number", loc) do return
	eni, efi, ok := editor_target(app)
	if testing.expect(t, ok && app.doc.nodes[eni].fields[efi].text == "0", "on the number", loc = loc) && text != "0" do set_field_text(app, eni, efi, text)
}

@(private = "file")
fill_op :: proc(t: ^testing.T, app: ^App, ni: int, group, op: string, loc := #caller_location) {
	if open_dot(t, app, ni, 0, loc = loc) && pick(t, app, "Operator", loc) && pick(t, app, group, loc) do pick(t, app, op, loc)
}

@(private = "file")
fill_const :: proc(t: ^testing.T, app: ^App, ni: int, name: string, loc := #caller_location) {
	if open_dot(t, app, ni, 0, loc = loc) && pick(t, app, "Constant", loc) do pick_leaf(t, app, name, CONST_IMPORT_FILL, loc)
}

@(private = "file")
fill_call :: proc(t: ^testing.T, app: ^App, ni: int, name: string, loc := #caller_location) {
	if !open_dot(t, app, ni, 0, loc = loc) do return
	if pick(t, app, "Call", loc) && pick(t, app, "From import", loc) && pick(t, app, "win32", loc) {
		pick_leaf(t, app, name, "__call_import_proc__", loc)
	}
}

@(private = "file")
fill_type :: proc(t: ^testing.T, app: ^App, ni, nth: int, name: string, loc := #caller_location) {
	if open_dot(t, app, ni, nth, "type", loc) && pick(t, app, "Type", loc) do pick_leaf(t, app, name, TYPE_IMPORT_FILL, loc)
}

// LT+A on the nth editable name of line ni (dictation).
@(private = "file")
rename_nth :: proc(app: ^App, ni: int, name: string, nth := 0) {
	if ni < 0 do return
	seen := 0
	for f, i in app.doc.nodes[ni].fields do if f.editable && f.kind != "string" {
		if seen == nth { set_field_text(app, ni, i, name); return }
		seen += 1
	}
}

// The cursor on the keyword `text` of line ni (any keyword kind).
@(private = "file")
focus_kw :: proc(t: ^testing.T, app: ^App, ni: int, text: string, loc := #caller_location) -> bool {
	if ni >= 0 && ni < len(app.doc.nodes) {
		for f, i in app.doc.nodes[ni].fields do if !f.slot && strings.trim_space(f.text) == text { focus_field_index(app, ni, i); return true }
	}
	testing.expectf(t, false, "no %q on line %d (%q)", text, ni, line_src(app, ni), loc = loc)
	return false
}

// Y on `text` of line ni, then the option.
@(private = "file")
y_option :: proc(t: ^testing.T, app: ^App, ni: int, text, option: string, loc := #caller_location) -> bool {
	back_out(app)
	if !focus_kw(t, app, ni, text, loc) do return false
	change_selected(app)
	return pick(t, app, option, loc)
}

// `target = value` from Assignment > Assignment on the "●" line ni. `value`:
// a number, a name, or name.field (with `field_label` for the Field of menu).
@(private = "file")
assign :: proc(t: ^testing.T, app: ^App, ni: int, target, value: string, field_label := "", loc := #caller_location) {
	if add_in_body(t, app, ni, "Assignment", "Assignment", loc) < 0 do return
	back_out(app)
	for f, i in app.doc.nodes[ni].fields do if f.editable { focus_field_index(app, ni, i); break }
	change_selected(app) // Y on the target
	if ref_choose(t, app, target, loc) && app.state == .Radial do pick(t, app, target, loc)
	if value[0] >= '0' && value[0] <= '9' {
		fill_number(t, app, ni, value, loc)
	} else if dot := strings.index_byte(value, '.'); dot > 0 {
		fill_field(t, app, ni, value[:dot], field_label, loc)
	} else {
		fill_ref(t, app, ni, value, loc = loc)
	}
	want := strings.concatenate({target, " = ", value}, context.temp_allocator)
	testing.expect_value(t, line_src(app, ni), want, loc = loc)
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

// `name` has type `want` at line ni and Reference offers it there.
@(private = "file")
known :: proc(t: ^testing.T, app: ^App, ni: int, name, want: string, loc := #caller_location) {
	ty, ok := var_type_at(app, ni, name)
	testing.expectf(t, ok && ty.expr == want, "%s at %q: want %s, got %v (found=%v)", name, line_src(app, ni), want, ty.expr, ok, loc = loc)
	testing.expectf(t, offers(app, ni, name), "Reference should offer %s at %q: %v", name, line_src(app, ni), ref_names(app, ni), loc = loc)
}

// `name` is unknown at line ni and not offered there.
@(private = "file")
unknown :: proc(t: ^testing.T, app: ^App, ni: int, name: string, loc := #caller_location) {
	_, ok := var_type_at(app, ni, name)
	testing.expectf(t, !ok, "%s should be unknown at %q", name, line_src(app, ni), loc = loc)
	testing.expectf(t, !offers(app, ni, name), "Reference shouldn't offer %s at %q", name, line_src(app, ni), loc = loc)
}

// D-pad stops of line ni: from its first part, right until the cursor leaves the line.
// Dots show as "●".
@(private = "file")
dpad_stops :: proc(app: ^App, ni: int) -> []string {
	back_out(app)
	focus_field_index(app, ni, 0)
	out := make([dynamic]string, context.temp_allocator)
	for _ in 0 ..< 48 {
		eni, efi, ok := editor_target(app)
		if !ok || eni != ni || app.editor_dot do break
		f := app.doc.nodes[eni].fields[efi]
		append(&out, f.slot ? "●" : strings.trim_space(f.text))
		before := app.editor_field
		update(app, Input{right = true})
		if app.editor_line == ni && app.editor_field == before do break
	}
	return out[:]
}

// Every part in `parts` is a D-pad stop on line ni.
@(private = "file")
reach :: proc(t: ^testing.T, app: ^App, ni: int, parts: ..string, loc := #caller_location) {
	got := dpad_stops(app, ni)
	for p in parts {
		found := false
		for g in got do if g == p do found = true
		testing.expectf(t, found, "%q isn't a D-pad stop on %q (stops: %v)", p, line_src(app, ni), got, loc = loc)
	}
}

// LT+B on every leftover "●" statement line.
@(private = "file")
drop_body_lines :: proc(app: ^App) {
	back_out(app)
	for _ in 0 ..< 64 {
		b := body_line(app, 0)
		if b < 0 do return
		before := len(app.doc.nodes)
		focus_field_index(app, b, 1)
		delete_selected(app)
		if len(app.doc.nodes) == before do return
	}
}

// main's closing brace (the last "}" line).
@(private = "file")
last_close :: proc(app: ^App) -> int {
	end := len(app.doc.nodes) - 1
	for end > 0 && line_src(app, end) != "}" do end -= 1
	return end
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

@(private = "file")
check_mutex: sync.Mutex

// `odin check` on `text` as <dir>/<name>/main.odin (when DOODLE_ODIN is set).
@(private = "file")
odin_check :: proc(t: ^testing.T, name, text: string, loc := #caller_location) {
	odin := os.get_env("DOODLE_ODIN", context.temp_allocator)
	if odin == "" do return
	base := os.get_env("DOODLE_CHECK_DIR", context.temp_allocator)
	if base == "" {
		tmp, _ := os.temp_directory(context.temp_allocator)
		base, _ = filepath.join({tmp, "doodle_accept_check"}, context.temp_allocator)
	}
	dir, _ := filepath.join({base, name}, context.temp_allocator)
	os.make_directory_all(dir)
	file, _ := filepath.join({dir, "main.odin"}, context.temp_allocator)
	_ = os.write_entire_file(file, transmute([]u8)text)
	sync.mutex_lock(&check_mutex)
	defer sync.mutex_unlock(&check_mutex)
	state, out, errs, err := os.process_exec(os.Process_Desc{command = []string{odin, "check", dir}}, context.temp_allocator)
	testing.expectf(t, err == nil && state.exit_code == 0, "odin check %s failed (err=%v, exit=%d):\n%s%s\n--- source ---\n%s",
		name, err, state.exit_code, string(out), string(errs), text, loc = loc)
}

// ---------------------------------------------------------------------------

@(private = "file")
HEAD :: "package main\n\n" +
	"Player :: struct {\n\thp: int,\n}\n\n" +
	"Dir :: enum {\n\tNorth,\n\tSouth,\n\tEast,\n\tWest,\n}\n\n" +
	"Circle :: struct {\n\tr: f32,\n}\n\n" +
	"Square :: struct {\n\tside: f32,\n}\n\n" +
	"Shape :: union {\n\tCircle,\n\tSquare,\n}\n\n" +
	"main :: proc() {\n" +
	"\tx := 3\n" +
	"\tm: map[string]int\n" +
	"\titems: [dynamic]Player\n" +
	"\tdir: Dir\n" +
	"\tshape: Shape\n"

@(private = "file")
BASE :: HEAD + "}"

// Loads BASE; returns the line of main's `}` (the green dot before it is where statements go).
@(private = "file")
start :: proc(app: ^App) -> int {
	load(app, BASE)
	return line_with(app, "shape: Shape") + 1
}

// Leftover dots dropped, formatted and stable; main's body is `body`; odin check.
@(private = "file")
finish :: proc(t: ^testing.T, app: ^App, name, body: string, loc := #caller_location) {
	drop_body_lines(app)
	text := expect_stable(t, app, loc)
	want := strings.concatenate({HEAD, body, "}"}, context.temp_allocator)
	testing.expectf(t, text == want, "saved:\n%s\n--- want ---\n%s", text, want, loc = loc)
	odin_check(t, name, text, loc)
}

// ---------------------------------------------------------------------------
// BRANCHING

// if x > 0 { } else if x < 0 { } else { }
@(test)
test_accept_br_if_else_if_else :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	h := add_stmt(t, &app, start(&app), "Branching", "If / Else")
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok && ni == h && app.doc.nodes[ni].fields[fi].slot && app.doc.nodes[ni].fields[fi].hint == "bool", "A lands on the condition (a bool)")
	fill_op(t, &app, h, "Compare", "a > b")
	fill_ref(t, &app, h, "x")
	fill_number(t, &app, h, "0")
	testing.expect_value(t, line_src(&app, h), "if x > 0 {")
	// Y on `if` -> Add else if (goes before the else).
	if y_option(t, &app, h, "if", "Add else if") {
		ei := line_with(&app, "else if")
		testing.expect(t, ei > h && ei < line_with(&app, "} else {"), "else if before else")
		fill_op(t, &app, ei, "Compare", "a < b")
		fill_ref(t, &app, ei, "x")
		fill_number(t, &app, ei, "0")
		testing.expect_value(t, line_src(&app, ei), "} else if x < 0 {")
		reach(t, &app, ei, "else if", "x", "0")
	}
	assign(t, &app, body_line(&app, h), "x", "1")
	assign(t, &app, body_line(&app, line_with(&app, "else if")), "x", "2")
	assign(t, &app, body_line(&app, line_with(&app, "} else {")), "x", "0")
	finish(t, &app, "br_if_else_if_else",
		"\tif x > 0 {\n\t\tx = 1\n\t} else if x < 0 {\n\t\tx = 2\n\t} else {\n\t\tx = 0\n\t}\n")
}

// if v, ok := m["key"]; ok { }
@(test)
test_accept_br_if_with_setup :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	h := add_stmt(t, &app, start(&app), "Branching", "If with setup")
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok && ni == h && app.doc.nodes[ni].fields[fi].kind == SETUP_KIND, "A lands on the setup dot")
	update(&app, Input{confirm = true})
	pick(t, &app, "Two names (:=)")
	for f, i in app.doc.nodes[h].fields do if f.editable && f.text != "ok" { set_field_text(&app, h, i, "v"); break }
	fill_ref(t, &app, h, "m", "m[key]   int")
	eni, efi, eok := editor_target(&app)
	testing.expect(t, eok && app.doc.nodes[eni].fields[efi].slot && app.doc.nodes[eni].fields[efi].hint == "string", "on the key dot (a string)")
	if open_dot(t, &app, h, 0) && pick(t, &app, "String") && pick(t, &app, "\"...\"  string") {
		for f, i in app.doc.nodes[h].fields do if f.kind == "string" { set_field_text(&app, h, i, "key"); break }
	}
	fill_ref(t, &app, h, "ok")
	testing.expect_value(t, line_src(&app, h), "if v, ok := m[\"key\"]; ok {")
	reach(t, &app, h, "if", "v", "ok", "key")
	// v / ok: typed and offered inside, unknown after.
	b := body_line(&app, h)
	known(t, &app, b, "v", "int")
	known(t, &app, b, "ok", "bool")
	assign(t, &app, b, "x", "v")
	drop_body_lines(&app)
	unknown(t, &app, last_close(&app), "v")
	unknown(t, &app, last_close(&app), "ok")
	finish(t, &app, "br_if_with_setup", "\tif v, ok := m[\"key\"]; ok {\n\t\tx = v\n\t}\n")
}

// switch x { case 1: ... case 2, 3: ... case: ... }
@(test)
test_accept_br_switch_value :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	s := add_stmt(t, &app, start(&app), "Branching", "Switch")
	fill_ref(t, &app, s, "x")
	testing.expect_value(t, line_src(&app, s), "switch x {")
	c1 := s + 1
	if open_dot(t, &app, c1, 0) {
		testing.expect(t, dimmed(t, &app, "true"), "a bool doesn't fit an int case")
		back_out(&app)
	}
	fill_number(t, &app, c1, "1")
	// Y on switch -> Add case: case 2, then Y on that case -> Add value: 3.
	y_option(t, &app, s, "switch", "Add case")
	c2 := line_with(&app, "case ", c1 + 1)
	fill_number(t, &app, c2, "2")
	if y_option(t, &app, c2, "case", "Add value") && pick(t, &app, "Number") {
		eni, efi, ok := editor_target(&app)
		if testing.expect(t, ok && eni == c2, "on the new value") do set_field_text(&app, eni, efi, "3")
	}
	testing.expect_value(t, line_src(&app, c2), "case 2, 3:")
	reach(t, &app, c2, "case", "2", "3")
	y_option(t, &app, s, "switch", "Add default case")
	dflt := line_with(&app, "case:")
	testing.expect(t, dflt > c2, "default case last")
	assign(t, &app, body_line(&app, c1), "x", "10")
	assign(t, &app, body_line(&app, line_with(&app, "case 2, 3:")), "x", "20")
	assign(t, &app, body_line(&app, line_with(&app, "case:")), "x", "0")
	finish(t, &app, "br_switch_value",
		"\tswitch x {\n\tcase 1:\n\t\tx = 10\n\tcase 2, 3:\n\t\tx = 20\n\tcase:\n\t\tx = 0\n\t}\n")
}

// switch x { case 0..<10: ... }
@(test)
test_accept_br_switch_range :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	s := add_stmt(t, &app, start(&app), "Branching", "Switch")
	fill_ref(t, &app, s, "x")
	c := s + 1
	if open_dot(t, &app, c, 0) {
		testing.expect(t, !dimmed(t, &app, "Range"), "a range fits an int case")
		if pick(t, &app, "Range") do pick(t, &app, "a ..< b  (up to b)")
	}
	fill_number(t, &app, c, "0")
	fill_number(t, &app, c, "10")
	testing.expect_value(t, line_src(&app, c), "case 0..<10:")
	reach(t, &app, c, "case", "0", "10")
	// And an inclusive one: case 10..=99:
	y_option(t, &app, c, "case", "Add case after")
	c2 := line_with(&app, "case ", c + 1)
	if open_dot(t, &app, c2, 0) && pick(t, &app, "Range") do pick(t, &app, "a ..= b  (through b)")
	fill_number(t, &app, c2, "10")
	fill_number(t, &app, c2, "99")
	testing.expect_value(t, line_src(&app, c2), "case 10..=99:")
	assign(t, &app, body_line(&app, c), "x", "1")
	assign(t, &app, body_line(&app, line_with(&app, "case 10..=99:")), "x", "2")
	finish(t, &app, "br_switch_range",
		"\tswitch x {\n\tcase 0..<10:\n\t\tx = 1\n\tcase 10..=99:\n\t\tx = 2\n\t}\n")
}

// #partial switch dir { case .North: ... }
@(test)
test_accept_br_partial_switch_enum :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	s := add_stmt(t, &app, start(&app), "Branching", "Partial switch")
	fill_ref(t, &app, s, "dir")
	testing.expect_value(t, line_src(&app, s), "#partial switch dir {")
	if open_dot(t, &app, s + 1, 0) && pick(t, &app, "Enum value") do pick(t, &app, ".North")
	testing.expect_value(t, line_src(&app, s + 1), "case .North:")
	reach(t, &app, s, "#partial", "switch", "dir")
	reach(t, &app, s + 1, "case", ".North")
	assign(t, &app, body_line(&app, s + 1), "x", "1")
	finish(t, &app, "br_partial_switch", "\t#partial switch dir {\n\tcase .North:\n\t\tx = 1\n\t}\n")
}

// switch v in shape { case Circle: ... }   (plus `case Square:`: Odin rejects an
// unhandled variant in a non-#partial type switch)
@(test)
test_accept_br_type_switch :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	s := add_stmt(t, &app, start(&app), "Branching", "Type switch")
	for f, i in app.doc.nodes[s].fields do if f.editable && !f.slot { set_field_text(&app, s, i, "v"); break } // LT+A: v
	fill_ref(t, &app, s, "shape")
	testing.expect_value(t, line_src(&app, s), "switch v in shape {")
	reach(t, &app, s, "switch", "v", "shape")
	if open_dot(t, &app, s + 1, 0, VARIANT_KIND) do pick(t, &app, "Circle")
	testing.expect_value(t, line_src(&app, s + 1), "case Circle:")
	y_option(t, &app, s, "switch", "Add case")
	c2 := line_with(&app, "case ", s + 2)
	if open_dot(t, &app, c2, 0, VARIANT_KIND) {
		testing.expect(t, dimmed(t, &app, "Circle"), "Circle is used")
		pick(t, &app, "Square")
	}
	b := body_line(&app, s + 1)
	known(t, &app, b, "v", "Circle")
	// r := v.r  (Declarations > Variable (:=), Reference v > Field of v > r)
	add_in_body(t, &app, b, "Declarations", "Variable (:=)")
	fill_field(t, &app, b, "v", "r   f32")
	rename_nth(&app, b, "r")
	testing.expect_value(t, line_src(&app, b), "r := v.r")
	sq := body_line(&app, line_with(&app, "case Square:"))
	known(t, &app, sq, "v", "Square")
	_, rok := var_type_at(&app, sq, "r")
	testing.expect(t, !rok, "r is local to case Circle")
	assign(t, &app, sq, "x", "2")
	drop_body_lines(&app)
	unknown(t, &app, last_close(&app), "v")
	finish(t, &app, "br_type_switch",
		"\tswitch v in shape {\n\tcase Circle:\n\t\tr := v.r\n\tcase Square:\n\t\tx = 2\n\t}\n")
}

// when ODIN_DEBUG { }
@(test)
test_accept_br_when :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	w := add_stmt(t, &app, start(&app), "Branching", "When")
	if open_dot(t, &app, w, 0) && pick(t, &app, "Built-in constants") {
		testing.expect(t, dimmed(t, &app, "ODIN_OS"), "ODIN_OS isn't a bool")
		pick(t, &app, "ODIN_DEBUG")
	}
	testing.expect_value(t, line_src(&app, w), "when ODIN_DEBUG {")
	reach(t, &app, w, "when", "ODIN_DEBUG")
	assign(t, &app, body_line(&app, w), "x", "1")
	finish(t, &app, "br_when", "\twhen ODIN_DEBUG {\n\t\tx = 1\n\t}\n")
}

// ---------------------------------------------------------------------------
// LOOPS

// for i := 0; i < 10; i += 1 { }
@(test)
test_accept_loop_cstyle :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := add_stmt(t, &app, start(&app), "Loops", "For (C-style)")
	fill_number(t, &app, ni, "10")
	testing.expect_value(t, line_src(&app, ni), "for i := 0; i < 10; i += 1 {")
	reach(t, &app, ni, "for", "i", "0", "10", "+=", "1")
	b := body_line(&app, ni)
	known(t, &app, b, "i", "int")
	assign(t, &app, b, "x", "i")
	drop_body_lines(&app)
	unknown(t, &app, last_close(&app), "i")
	finish(t, &app, "loop_cstyle", "\tfor i := 0; i < 10; i += 1 {\n\t\tx = i\n\t}\n")
}

// for x < 10 { }
@(test)
test_accept_loop_while :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := add_stmt(t, &app, start(&app), "Loops", "For (condition)")
	if open_dot(t, &app, ni, 0) {
		testing.expect(t, dimmed(t, &app, "Number"), "a number isn't a condition")
		back_out(&app)
	}
	fill_op(t, &app, ni, "Compare", "a < b")
	fill_ref(t, &app, ni, "x")
	fill_number(t, &app, ni, "10")
	testing.expect_value(t, line_src(&app, ni), "for x < 10 {")
	reach(t, &app, ni, "for", "x", "10")
	// x += 1   (Assignment > +=, Y on the target)
	a := add_in_body(t, &app, body_line(&app, ni), "Assignment", "+=")
	back_out(&app)
	focus_field_index(&app, a, 1)
	change_selected(&app)
	if ref_choose(t, &app, "x") && app.state == .Radial do pick(t, &app, "x")
	fill_number(t, &app, a, "1")
	testing.expect_value(t, line_src(&app, a), "x += 1")
	finish(t, &app, "loop_while", "\tfor x < 10 {\n\t\tx += 1\n\t}\n")
}

// for { }
@(test)
test_accept_loop_infinite :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := add_stmt(t, &app, start(&app), "Loops", "For (infinite)")
	testing.expect_value(t, line_src(&app, ni), "for {")
	reach(t, &app, ni, "for")
	b := add_in_body(t, &app, body_line(&app, ni), "Jumps and cleanup", "Break")
	testing.expect_value(t, line_src(&app, b), "break")
	finish(t, &app, "loop_infinite", "\tfor {\n\t\tbreak\n\t}\n")
}

// for i in 0..<10 { }, for i in 0..=9 { }
@(test)
test_accept_loop_ranges :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := add_stmt(t, &app, start(&app), "Loops", "For i in 0..<n")
	fill_number(t, &app, ni, "10")
	testing.expect_value(t, line_src(&app, ni), "for i in 0..<10 {")
	reach(t, &app, ni, "for", "i", "0", "10")
	known(t, &app, body_line(&app, ni), "i", "int")
	assign(t, &app, body_line(&app, ni), "x", "i")
	n2 := add_stmt(t, &app, line_with(&app, "\t}", ni) + 1, "Loops", "For i in 0..=n")
	fill_number(t, &app, n2, "9")
	testing.expect_value(t, line_src(&app, n2), "for i in 0..=9 {")
	assign(t, &app, body_line(&app, n2), "x", "i")
	drop_body_lines(&app)
	unknown(t, &app, last_close(&app), "i")
	finish(t, &app, "loop_ranges", "\tfor i in 0..<10 {\n\t\tx = i\n\t}\n\tfor i in 0..=9 {\n\t\tx = i\n\t}\n")
}

// for item, index in items { }   (and a string: for ch, i in "hello" { })
@(test)
test_accept_loop_over_array_and_string :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := add_stmt(t, &app, start(&app), "Loops", "For x, i in")
	fill_ref(t, &app, ni, "items")
	testing.expect_value(t, line_src(&app, ni), "for item, index in items {")
	reach(t, &app, ni, "for", "item", "index", "items")
	b := body_line(&app, ni)
	known(t, &app, b, "item", "Player")
	known(t, &app, b, "index", "int")
	assign(t, &app, b, "x", "item.hp", "hp   int")
	// for ch, i in "hello" {   (For ... in, String literal, Y on for -> Add 2nd variable, LT+A names)
	n2 := add_stmt(t, &app, line_with(&app, "\t}", ni) + 1, "Loops", "For ... in")
	if open_dot(t, &app, n2, 0) && pick(t, &app, "String") && pick(t, &app, "\"...\"  string") {
		for f, i in app.doc.nodes[n2].fields do if f.kind == "string" { set_field_text(&app, n2, i, "hello"); break }
	}
	y_option(t, &app, n2, "for", "Add 2nd variable")
	if h, ok := loop_hdr(app.doc.nodes[n2]); testing.expect(t, ok && h.var1 >= 0 && h.var2 >= 0, "two variables") {
		set_field_text(&app, n2, h.var1, "ch")
		set_field_text(&app, n2, h.var2, "i")
	}
	testing.expect_value(t, line_src(&app, n2), "for ch, i in \"hello\" {")
	b2 := body_line(&app, n2)
	known(t, &app, b2, "ch", "rune")
	known(t, &app, b2, "i", "int")
	unknown(t, &app, b2, "item")
	assign(t, &app, b2, "x", "i")
	drop_body_lines(&app)
	unknown(t, &app, last_close(&app), "index")
	finish(t, &app, "loop_over_array",
		"\tfor item, index in items {\n\t\tx = item.hp\n\t}\n\tfor ch, i in \"hello\" {\n\t\tx = i\n\t}\n")
}

// for key, value in m { }
@(test)
test_accept_loop_over_map :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := add_stmt(t, &app, start(&app), "Loops", "For x, i in")
	fill_ref(t, &app, ni, "m")
	if h, ok := loop_hdr(app.doc.nodes[ni]); testing.expect(t, ok && h.var1 >= 0 && h.var2 >= 0, "two variables") {
		set_field_text(&app, ni, h.var1, "key")
		set_field_text(&app, ni, h.var2, "value")
	}
	testing.expect_value(t, line_src(&app, ni), "for key, value in m {")
	reach(t, &app, ni, "for", "key", "value", "m")
	b := body_line(&app, ni)
	known(t, &app, b, "key", "string")
	known(t, &app, b, "value", "int")
	assign(t, &app, b, "x", "value")
	drop_body_lines(&app)
	unknown(t, &app, last_close(&app), "value")
	finish(t, &app, "loop_over_map", "\tfor key, value in m {\n\t\tx = value\n\t}\n")
}

// for &item in items { item.hp -= 1 }
@(test)
test_accept_loop_by_reference :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := add_stmt(t, &app, start(&app), "Loops", "For &x in")
	fill_ref(t, &app, ni, "items")
	testing.expect_value(t, line_src(&app, ni), "for &item in items {")
	reach(t, &app, ni, "for", "item", "items")
	b := body_line(&app, ni)
	known(t, &app, b, "item", "Player")
	a := add_in_body(t, &app, b, "Assignment", "-=")
	back_out(&app)
	focus_field_index(&app, a, 1)
	change_selected(&app)
	if ref_choose(t, &app, "item") && app.state == .Radial && pick(t, &app, "Field of item") do pick(t, &app, "hp   int")
	fill_number(t, &app, a, "1")
	testing.expect_value(t, line_src(&app, a), "item.hp -= 1")
	finish(t, &app, "loop_by_reference", "\tfor &item in items {\n\t\titem.hp -= 1\n\t}\n")
}

// #reverse for item in items { }
@(test)
test_accept_loop_reverse :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := add_stmt(t, &app, start(&app), "Loops", "#reverse for")
	fill_ref(t, &app, ni, "items")
	testing.expect_value(t, line_src(&app, ni), "#reverse for item in items {")
	reach(t, &app, ni, "#reverse", "for", "item", "items")
	b := body_line(&app, ni)
	known(t, &app, b, "item", "Player")
	assign(t, &app, b, "x", "item.hp", "hp   int")
	finish(t, &app, "loop_reverse", "\t#reverse for item in items {\n\t\tx = item.hp\n\t}\n")
}

// #unroll for i in 0..<4 { }
@(test)
test_accept_loop_unroll :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := add_stmt(t, &app, start(&app), "Loops", "#unroll for")
	fill_number(t, &app, ni, "4")
	testing.expect_value(t, line_src(&app, ni), "#unroll for i in 0..<4 {")
	reach(t, &app, ni, "#unroll", "for", "i", "0", "4")
	b := body_line(&app, ni)
	known(t, &app, b, "i", "int")
	assign(t, &app, b, "x", "i")
	finish(t, &app, "loop_unroll", "\t#unroll for i in 0..<4 {\n\t\tx = i\n\t}\n")
}

// outer: for item in items { for i in 0..<3 { break outer } }
@(test)
test_accept_loop_labeled :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := add_stmt(t, &app, start(&app), "Loops", "Labeled for")
	fill_ref(t, &app, ni, "items")
	testing.expect_value(t, line_src(&app, ni), "outer: for item in items {")
	reach(t, &app, ni, "outer", "for", "item", "items")
	inner := add_in_body(t, &app, body_line(&app, ni), "Loops", "For i in 0..<n")
	fill_number(t, &app, inner, "3")
	testing.expect_value(t, line_src(&app, inner), "for i in 0..<3 {")
	b := body_line(&app, inner)
	known(t, &app, b, "item", "Player")
	known(t, &app, b, "i", "int")
	back_out(&app)
	focus_field_index(&app, b, 1)
	update(&app, Input{confirm = true})
	if pick(t, &app, "Jumps and cleanup") {
		testing.expect(t, has_entry(&app, "Continue outer"), "continue outer offered")
		pick(t, &app, "Break outer")
	}
	testing.expect_value(t, line_src(&app, b), "break outer")
	drop_body_lines(&app)
	end := last_close(&app)
	testing.expect_value(t, len(jump_scope(&app, end).labels), 0)
	unknown(t, &app, end, "item")
	finish(t, &app, "loop_labeled", "\touter: for item in items {\n\t\tfor i in 0..<3 {\n\t\t\tbreak outer\n\t\t}\n\t}\n")
}

// ---------------------------------------------------------------------------
// The user's program: switch message { ... } and the GetMessageW loop.

@(private = "file")
WIN_BASE :: "package handmade\n\n" +
	"import win32 \"core:sys/windows\"\n\n" +
	"main_window_callback :: proc \"system\" (\n" +
	"\twindow: win32.HWND,\n" +
	"\tmessage: win32.UINT,\n" +
	"\tw_param: win32.WPARAM,\n" +
	"\tl_param: win32.LPARAM,\n" +
	") -> win32.LRESULT {\n" +
	"\tresult: win32.LRESULT = 0\n" +
	"\treturn result\n" +
	"}\n\n" +
	"main :: proc() {\n" +
	"\tmessage: win32.MSG\n" +
	"}"

@(private = "file")
WIN_BUILT :: "package handmade\n\n" +
	"import win32 \"core:sys/windows\"\n\n" +
	"main_window_callback :: proc \"system\" (\n" +
	"\twindow: win32.HWND,\n" +
	"\tmessage: win32.UINT,\n" +
	"\tw_param: win32.WPARAM,\n" +
	"\tl_param: win32.LPARAM,\n" +
	") -> win32.LRESULT {\n" +
	"\tresult: win32.LRESULT = 0\n" +
	"\tswitch message {\n" +
	"\tcase win32.WM_SIZE:\n" +
	"\t\twin32.OutputDebugStringA(\"WM_SIZE\\n\")\n" +
	"\tcase win32.WM_DESTROY:\n" +
	"\t\twin32.OutputDebugStringA(\"WM_DESTROY\\n\")\n" +
	"\tcase win32.WM_CLOSE:\n" +
	"\t\twin32.OutputDebugStringA(\"WM_CLOSE\\n\")\n" +
	"\tcase win32.WM_ACTIVATEAPP:\n" +
	"\t\twin32.OutputDebugStringA(\"WM_ACTIVATEAPP\\n\")\n" +
	"\tcase win32.WM_PAINT:\n" +
	"\t\tpaint: win32.PAINTSTRUCT\n" +
	"\t\tdevice_context := win32.BeginPaint(window, &paint)\n" +
	"\t\twin32.EndPaint(window, &paint)\n" +
	"\tcase:\n" +
	"\t\tresult = win32.DefWindowProcW(window, message, w_param, l_param)\n" +
	"\t}\n" +
	"\treturn result\n" +
	"}\n\n" +
	"main :: proc() {\n" +
	"\tmessage: win32.MSG\n" +
	"\tfor win32.GetMessageW(&message, nil, 0, 0) > 0 {\n" +
	"\t\twin32.TranslateMessage(&message)\n" +
	"\t\twin32.DispatchMessageW(&message)\n" +
	"\t}\n" +
	"}"

@(test)
test_accept_handmade_switch_message_and_message_loop :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.os_name = "windows"
	load(&app, WIN_BASE)

	// switch message {
	s := add_stmt(t, &app, line_with(&app, "return result"), "Branching", "Switch")
	fill_ref(t, &app, s, "message")
	testing.expect_value(t, line_src(&app, s), "switch message {")
	reach(t, &app, s, "switch", "message")
	consts := []string{"WM_SIZE", "WM_DESTROY", "WM_CLOSE", "WM_ACTIVATEAPP", "WM_PAINT"}
	c := s + 1
	for name, k in consts {
		if k > 0 {
			y_option(t, &app, c, "case", "Add case after")
			c = line_with(&app, "case ", c + 1)
		}
		fill_const(t, &app, c, name)
		testing.expect_value(t, line_src(&app, c), strings.concatenate({"case win32.", name, ":"}, context.temp_allocator))
	}
	y_option(t, &app, s, "switch", "Add default case")

	// case win32.WM_xxx: win32.OutputDebugStringA("WM_xxx\n")
	for name in consts[:4] {
		ci := line_with(&app, strings.concatenate({"case win32.", name, ":"}, context.temp_allocator))
		ni := add_in_body(t, &app, body_line(&app, ci), "Calls", "From import")
		if ni < 0 do continue
		if pick(t, &app, "win32") do pick_leaf(t, &app, "OutputDebugStringA", "__call_import_proc__")
		if open_dot(t, &app, ni, 0) && pick(t, &app, "String") {
			v := current_view(&app)
			lit := ""
			if v != nil do for e in v.entries do if strings.has_prefix(e.label, "\"...\"") && !e.dim { lit = e.label; break }
			if testing.expectf(t, lit != "", "a string literal that fits LPCSTR: %s", labels(&app)) && pick(t, &app, lit) {
				for f, i in app.doc.nodes[ni].fields do if f.kind == "string" && f.text == "" { set_field_text(&app, ni, i, strings.concatenate({name, "\\n"}, context.temp_allocator)); break }
			}
		}
		testing.expect_value(t, line_src(&app, ni), strings.concatenate({"win32.OutputDebugStringA(\"", name, "\\n\")"}, context.temp_allocator))
	}

	// case win32.WM_PAINT: paint / BeginPaint / EndPaint
	pc := line_with(&app, "case win32.WM_PAINT:")
	ni := add_in_body(t, &app, body_line(&app, pc), "Declarations", "Variable (no value)")
	rename_nth(&app, ni, "paint")
	fill_type(t, &app, ni, 0, "PAINTSTRUCT")
	testing.expect_value(t, line_src(&app, ni), "paint: win32.PAINTSTRUCT")
	known(t, &app, ni + 1, "message", "win32.UINT")
	ni = add_in_body(t, &app, body_line(&app, ni), "Declarations", "Variable (:=)")
	rename_nth(&app, ni, "device_context")
	fill_call(t, &app, ni, "BeginPaint")
	fill_ref(t, &app, ni, "window")
	fill_ref(t, &app, ni, "paint", "&paint   (pointer to it)")
	testing.expect_value(t, line_src(&app, ni), "device_context := win32.BeginPaint(window, &paint)")
	ni = add_in_body(t, &app, body_line(&app, ni), "Calls", "From import")
	if pick(t, &app, "win32") do pick_leaf(t, &app, "EndPaint", "__call_import_proc__")
	fill_ref(t, &app, ni, "window")
	fill_ref(t, &app, ni, "paint", "&paint   (pointer to it)")
	testing.expect_value(t, line_src(&app, ni), "win32.EndPaint(window, &paint)")
	// paint is local to its case clause.
	_, pok := var_type_at(&app, body_line(&app, line_with(&app, "case:")), "paint")
	testing.expect(t, !pok, "paint is local to its case clause")

	// case: result = win32.DefWindowProcW(window, message, w_param, l_param)
	ni = add_in_body(t, &app, body_line(&app, line_with(&app, "case:")), "Assignment", "Assignment")
	back_out(&app)
	for f, i in app.doc.nodes[ni].fields do if f.editable { focus_field_index(&app, ni, i); break }
	change_selected(&app)
	if ref_choose(t, &app, "result") && app.state == .Radial do pick(t, &app, "result")
	fill_call(t, &app, ni, "DefWindowProcW")
	for name in ([]string{"window", "message", "w_param", "l_param"}) do fill_ref(t, &app, ni, name)
	testing.expect_value(t, line_src(&app, ni), "result = win32.DefWindowProcW(window, message, w_param, l_param)")

	// for win32.GetMessageW(&message, nil, 0, 0) > 0 { TranslateMessage / DispatchMessageW }
	loop := add_stmt(t, &app, last_close(&app), "Loops", "For (condition)")
	if open_dot(t, &app, loop, 0) {
		testing.expect(t, dimmed(t, &app, "GetMessageW"), "GetMessageW returns an INT: not a condition by itself")
		back_out(&app)
	}
	fill_op(t, &app, loop, "Compare", "a > b")
	fill_call(t, &app, loop, "GetMessageW")
	fill_ref(t, &app, loop, "message", "&message   (pointer to it)")
	if open_dot(t, &app, loop, 0) do pick(t, &app, "nil")
	fill_number(t, &app, loop, "0")
	fill_number(t, &app, loop, "0")
	fill_number(t, &app, loop, "0")
	testing.expect_value(t, line_src(&app, loop), "for win32.GetMessageW(&message, nil, 0, 0) > 0 {")
	reach(t, &app, loop, "for", "GetMessageW", "&message", "nil", "0")
	for name in ([]string{"TranslateMessage", "DispatchMessageW"}) {
		ni = add_in_body(t, &app, body_line(&app, loop), "Calls", "From import")
		if ni < 0 do break
		if pick(t, &app, "win32") do pick_leaf(t, &app, name, "__call_import_proc__")
		fill_ref(t, &app, ni, "message", "&message   (pointer to it)")
	}
	testing.expect_value(t, line_src(&app, loop + 1), "win32.TranslateMessage(&message)")
	testing.expect_value(t, line_src(&app, loop + 2), "win32.DispatchMessageW(&message)")

	drop_body_lines(&app)
	text := expect_stable(t, &app)
	testing.expectf(t, text == WIN_BUILT, "saved:\n%s\n--- want ---\n%s", text, WIN_BUILT)
	odin_check(t, "handmade_switch_loop", text)
}

// ---------------------------------------------------------------------------
// Every example of both tables, as a file: load -> save verbatim.

@(private = "file")
EVERY_EXAMPLE :: HEAD +
	"\tif x > 0 {\n\t\tx = 1\n\t} else if x < 0 {\n\t\tx = 2\n\t} else {\n\t\tx = 0\n\t}\n" +
	"\tif v, ok := m[\"key\"]; ok {\n\t\tx = v\n\t}\n" +
	"\tswitch x {\n\tcase 1:\n\t\tx = 10\n\tcase 2, 3:\n\t\tx = 20\n\tcase:\n\t\tx = 0\n\t}\n" +
	"\tswitch x {\n\tcase 0..<10:\n\t\tx = 1\n\t}\n" +
	"\t#partial switch dir {\n\tcase .North:\n\t\tx = 1\n\t}\n" +
	"\tswitch v in shape {\n\tcase Circle:\n\t\tr := v.r\n\tcase Square:\n\t\tx = 2\n\t}\n" +
	"\twhen ODIN_DEBUG {\n\t\tx = 1\n\t}\n" +
	"\tfor i := 0; i < 10; i += 1 {\n\t}\n" +
	"\tfor x < 10 {\n\t\tx += 1\n\t}\n" +
	"\tfor {\n\t\tbreak\n\t}\n" +
	"\tfor i in 0..<10 {\n\t}\n" +
	"\tfor i in 0..=9 {\n\t}\n" +
	"\tfor item, index in items {\n\t}\n" +
	"\tfor ch, i in \"hello\" {\n\t}\n" +
	"\tfor key, value in m {\n\t}\n" +
	"\tfor &item in items {\n\t\titem.hp -= 1\n\t}\n" +
	"\t#reverse for item in items {\n\t}\n" +
	"\t#unroll for i in 0..<4 {\n\t}\n" +
	"\touter: for item in items {\n\t\tfor i in 0..<3 {\n\t\t\tbreak outer\n\t\t}\n\t}\n" +
	"}"

// The same examples written the way the table writes them (one line each).
@(private = "file")
ONE_LINERS :: HEAD +
	"\tif x > 0 { } else if x < 0 { } else { }\n" +
	"\tif v, ok := m[\"key\"]; ok { }\n" +
	"\twhen ODIN_DEBUG { }\n" +
	"\tfor i := 0; i < 10; i += 1 { }\n" +
	"\tfor x < 10 { }\n" +
	"\tfor { }\n" +
	"\tfor i in 0..<10 { }\n" +
	"\tfor i in 0..=9 { }\n" +
	"\tfor item, index in items { }\n" +
	"\tfor key, value in m { }\n" +
	"\tfor &item in items { item.hp -= 1 }\n" +
	"\t#reverse for item in items { }\n" +
	"\t#unroll for i in 0..<4 { }\n" +
	"\touter: for item in items { for i in 0..<3 { break outer } }\n" +
	"}"

@(test)
test_accept_every_example_round_trip :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, EVERY_EXAMPLE)
	testing.expectf(t, src(&app) == EVERY_EXAMPLE, "load -> save changed it:\n%s", src(&app))
	format_doc(&app)
	testing.expectf(t, src(&app) == EVERY_EXAMPLE, "format_doc changed it:\n%s", src(&app))
	// Every loop header and every branching line loads structured.
	loops := 0
	for n in app.doc.nodes do if _, ok := loop_hdr(n); ok do loops += 1
	testing.expect_value(t, loops, 13)
	for needle in ([]string{"if x > 0", "else if x < 0", "} else {", "if v, ok", "case 1:", "case 2, 3:", "case:", "case 0..<10:", "#partial switch", "case .North:", "switch v in shape", "case Circle:"}) {
		ni := line_with(&app, needle)
		_, ok := br_line(app.doc.nodes[max(ni, 0)])
		testing.expectf(t, ni >= 0 && ok, "%q loads structured", needle)
	}
	odin_check(t, "every_example", EVERY_EXAMPLE)
}

@(test)
test_accept_one_liners_round_trip :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	odin_check(t, "one_liners", ONE_LINERS)
	load(&app, ONE_LINERS)
	testing.expectf(t, src(&app) == ONE_LINERS, "load -> save changed it:\n%s", src(&app))
	// Formatting (runs on load and save) may reflow them, but must keep them valid and stable.
	format_doc(&app)
	formatted := strings.clone(src(&app), context.temp_allocator)
	load(&app, formatted)
	testing.expectf(t, src(&app) == formatted, "formatted text doesn't round-trip:\n%s", src(&app))
	odin_check(t, "one_liners_formatted", formatted)

	// Loaded one-liners are editable like the multi-line forms: structured, with
	// D-pad stops. (The app formats a file when it opens it - filenav.odin - and
	// format_doc puts one-line blocks on their own lines: block_split.odin.)
	load(&app, ONE_LINERS)
	format_doc(&app)
	for needle in ([]string{"for i := 0; i < 10", "for x < 10 {", "for {", "for i in 0..<10 {", "for &item in items", "#unroll for", "outer: for"}) {
		ni := line_with(&app, needle)
		if !testing.expectf(t, ni >= 0, "no line %q", needle) do continue
		_, ok := loop_hdr(app.doc.nodes[ni])
		stops := dpad_stops(&app, ni)
		min_stops := needle == "for {" ? 1 : 2 // `for {` has only its keyword (as when built from the menu)
		testing.expectf(t, ok && len(stops) >= min_stops, "one-line loop %q loads as plain text (structured=%v, D-pad stops %v)", needle, ok, stops)
	}
	for needle in ([]string{"if x > 0 {", "if v, ok :=", "when ODIN_DEBUG {"}) {
		ni := line_with(&app, needle)
		if !testing.expectf(t, ni >= 0, "no line %q", needle) do continue
		stops := dpad_stops(&app, ni)
		testing.expectf(t, len(stops) > 1, "one-line branch %q has no parts to step through (D-pad stops %v)", needle, stops)
	}
}

// LT+B (or Y > Remove label) on a loop's label while `break outer` uses it
// must not leave code that fails `odin check` ("Undeclared name: outer").
@(test)
test_accept_remove_used_label :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := HEAD + "\touter: for item in items {\n\t\tfor i in 0..<3 {\n\t\t\tbreak outer\n\t\t}\n\t}\n}"
	for how in ([]string{"LT+B", "Y"}) {
		load(&app, text)
		h := line_with(&app, "outer: for")
		if how == "LT+B" {
			if focus_kw(t, &app, h, "outer") do delete_selected(&app)
		} else {
			y_option(t, &app, h, "outer", "Remove label")
		}
		back_out(&app)
		out := src(&app)
		dangling := strings.contains(out, "break outer") && !strings.contains(out, "outer:")
		testing.expectf(t, !dangling, "%s on the label leaves a dangling `break outer`:\n%s", how, out)
		if !dangling do odin_check(t, how == "Y" ? "remove_label_y" : "remove_label_ltb", out)
	}
}

// A local declared in one case clause isn't offered by Reference in a sibling
// clause (var_types already knows it's out of scope there; picking it gives
// "Undeclared name").
@(test)
test_accept_case_locals_not_offered_in_other_clauses :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, HEAD + "\tswitch v in shape {\n\tcase Circle:\n\t\tr := v.r\n\tcase Square:\n\t\tx = 2\n\t}\n}")
	at := line_with(&app, "x = 2")
	_, ok := var_type_at(&app, at, "r")
	testing.expect(t, !ok, "var_types: r unknown in case Square")
	testing.expectf(t, !offers(&app, at, "r"), "Reference offers r (declared in case Circle) inside case Square: %v", ref_names(&app, at))
}

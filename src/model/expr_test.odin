package model

// Expressions (expr.odin): ternaries from Operator > Choose, conversions from
// Convert, and the other value forms of the Handmade program, built with the
// controller (A on dots, menu picks, Reference, Y, LT+B, LT+A), loaded back
// the same, and (with DOODLE_ODIN set) passing `odin check`.

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
	app.os_name = "windows"
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

// The nth unfilled dot of `kind` on line ni (field index), or -1.
@(private = "file")
dot_index :: proc(app: ^App, ni, nth: int, kind := "value") -> int {
	if ni < 0 || ni >= len(app.doc.nodes) do return -1
	seen := 0
	for f, i in app.doc.nodes[ni].fields {
		if f.slot && f.kind == kind {
			if seen == nth do return i
			seen += 1
		}
	}
	return -1
}

// A on the nth unfilled dot of `kind` on line ni.
@(private = "file")
open_dot :: proc(t: ^testing.T, app: ^App, ni, nth: int, kind := "value", loc := #caller_location) -> bool {
	back_out(app)
	fi := dot_index(app, ni, nth, kind)
	if !testing.expectf(t, fi >= 0, "no %s dot #%d on %q", kind, nth, line_src(app, ni), loc = loc) do return false
	focus_field_index(app, ni, fi)
	update(app, Input{confirm = true})
	return true
}

// The cursor on the nth field of line ni whose text is `text`.
@(private = "file")
focus_text :: proc(t: ^testing.T, app: ^App, ni: int, text: string, nth := 0, loc := #caller_location) -> bool {
	back_out(app)
	seen := 0
	if ni >= 0 && ni < len(app.doc.nodes) {
		for f, i in app.doc.nodes[ni].fields do if f.text == text {
			if seen == nth { focus_field_index(app, ni, i); return true }
			seen += 1
		}
	}
	testing.expectf(t, false, "no %q #%d on %q", text, nth, line_src(app, ni), loc = loc)
	return false
}

// In Reference pick mode: D-pad until `name` is highlighted, then A.
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

@(private = "file")
fill_ref :: proc(t: ^testing.T, app: ^App, ni: int, name: string, pass_as := "", loc := #caller_location) {
	if !open_dot(t, app, ni, 0, loc = loc) || !pick(t, app, "Reference", loc) do return
	if ref_choose(t, app, name, loc) && app.state == .Radial do pick(t, app, pass_as == "" ? name : pass_as, loc)
}

@(private = "file")
fill_number :: proc(t: ^testing.T, app: ^App, ni: int, text := "0", loc := #caller_location) {
	if !open_dot(t, app, ni, 0, loc = loc) || !pick(t, app, "Number", loc) do return
	eni, efi, ok := editor_target(app)
	if testing.expect(t, ok && app.doc.nodes[eni].fields[efi].text == "0", "on the number", loc = loc) && text != "0" do set_field_text(app, eni, efi, text)
}

@(private = "file")
fill_nil :: proc(t: ^testing.T, app: ^App, ni: int, loc := #caller_location) {
	if open_dot(t, app, ni, 0, loc = loc) do pick(t, app, "nil", loc)
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

// Convert > form > type (a win32 type, or a basic type).
@(private = "file")
fill_convert :: proc(t: ^testing.T, app: ^App, ni: int, form, type_label: string, loc := #caller_location) {
	if open_dot(t, app, ni, 0, loc = loc) && pick(t, app, "Convert", loc) && pick(t, app, form, loc) do pick_leaf(t, app, type_label, CONV_FILL, loc)
}

@(private = "file")
fill_type :: proc(t: ^testing.T, app: ^App, ni, nth: int, name: string, fill := TYPE_IMPORT_FILL, loc := #caller_location) {
	if open_dot(t, app, ni, nth, "type", loc) && pick(t, app, "Type", loc) do pick_leaf(t, app, name, fill, loc)
}

// win32.L("text")
@(private = "file")
fill_wide_string :: proc(t: ^testing.T, app: ^App, ni: int, text: string, loc := #caller_location) {
	fill_call(t, app, ni, "L", loc)
	if open_dot(t, app, ni, 0, loc = loc) && pick(t, app, "String", loc) && pick(t, app, "\"...\"  string", loc) {
		for f, i in app.doc.nodes[ni].fields do if f.editable && f.kind == "string" && f.text == "" { set_field_text(app, ni, i, text); return }
	}
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

// Assignment > Assignment on the green dot before line `at`, Y on the target -> `target`.
@(private = "file")
add_assignment :: proc(t: ^testing.T, app: ^App, at: int, target: string, loc := #caller_location) -> int {
	ni := add_stmt(t, app, at, "Assignment", "Assignment", loc)
	back_out(app)
	for f, i in app.doc.nodes[ni].fields do if f.editable { focus_field_index(app, ni, i); break }
	change_selected(app) // Y on the target
	if ref_choose(t, app, target, loc) && app.state == .Radial do pick(t, app, target, loc)
	return ni
}

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

// The leaves D-pad steps through on line ni, as text ("●" for a dot).
@(private = "file")
stops :: proc(app: ^App, ni: int) -> string {
	n := app.doc.nodes[ni]
	out := make([dynamic]string, context.temp_allocator)
	for u in line_leaves(n) {
		b := strings.builder_make(context.temp_allocator)
		for i in u.fa ..< u.fb do strings.write_string(&b, n.fields[i].slot ? "●" : n.fields[i].text)
		append(&out, strings.trim_space(strings.to_string(b)))
	}
	return strings.join(out[:], " ", context.temp_allocator)
}

// The fields of line ni from field `from` on: text / slot / kind (what "the same structure" compares).
@(private = "file")
shape :: proc(app: ^App, ni: int, from_text: string) -> string {
	n := app.doc.nodes[ni]
	b := strings.builder_make(context.temp_allocator)
	on := false
	for f in n.fields {
		if !on && strings.contains(f.text, from_text) do on = true
		if !on do continue
		strings.write_string(&b, "[")
		strings.write_string(&b, f.slot ? "●" : f.text)
		if f.kind != "" && !f.slot { strings.write_string(&b, "|"); strings.write_string(&b, f.kind) }
		strings.write_string(&b, "]")
	}
	return strings.to_string(b)
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
		base, _ = filepath.join({tmp, "doodle_expr_check"}, context.temp_allocator)
	}
	dir, _ := filepath.join({base, name}, context.temp_allocator)
	os.make_directory_all(dir)
	file, _ := filepath.join({dir, "main.odin"}, context.temp_allocator)
	_ = os.write_entire_file(file, transmute([]u8)text)
	sync.mutex_lock(&check_mutex)
	defer sync.mutex_unlock(&check_mutex)
	// One compiler thread: these run beside the other acceptance files' checks
	// and timing-sensitive tests (review_fixes_test.odin).
	state, out, errs, err := os.process_exec(os.Process_Desc{command = []string{odin, "check", dir, "-thread-count:1"}}, context.temp_allocator)
	testing.expectf(t, err == nil && state.exit_code == 0, "odin check %s failed (err=%v, exit=%d):\n%s%s\n--- source ---\n%s",
		name, err, state.exit_code, string(out), string(errs), text, loc = loc)
}

// ---------------------------------------------------------------------------
// The ternary

@(private = "file")
TERN_BASE :: "package handmade\n\n" +
	"import win32 \"core:sys/windows\"\n\n" +
	"WHITENESS :: 0x00FF0062\n" +
	"BLACKNESS :: 0x00000042\n\n" +
	"operation: u32 = WHITENESS\n\n" +
	"main :: proc() {\n" +
	"\tok := true\n" +
	"}"

// operation = BLACKNESS if operation == WHITENESS else WHITENESS, from the menus.
@(test)
test_expr_ternary_built_from_menus :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, TERN_BASE)
	close := line_with(&app, "ok := true") + 1

	ni := add_assignment(t, &app, close, "operation")
	testing.expect_value(t, line_src(&app, ni), "operation =")
	// Operator > Choose > "a if c else b": both branches expect the target's type, the condition a bool.
	if open_dot(t, &app, ni, 0) && pick(t, &app, "Operator") {
		testing.expect(t, !dimmed(t, &app, "Choose"), "a ternary can be a u32")
		if pick(t, &app, "Choose") {
			testing.expectf(t, strings.contains(labels(&app), "a if c else b"), "the forms: %s", labels(&app))
			pick(t, &app, "a if c else b")
		}
	}
	testing.expect_value(t, shape(&app, ni, " = "), "[ = |assign_op][●][ if |tern][●][ else |tern][●]")
	hints := make([dynamic]string, context.temp_allocator)
	for f in app.doc.nodes[ni].fields do if f.slot do append(&hints, f.hint)
	testing.expect_value(t, strings.join(hints[:], ",", context.temp_allocator), "u32,bool,u32")
	testing.expect_value(t, cursor_text(&app), "") // on the first dot

	fill_ref(t, &app, ni, "BLACKNESS")
	// The condition: a bool (a number doesn't fit, a comparison does).
	if open_dot(t, &app, ni, 0) {
		testing.expect(t, dimmed(t, &app, "Number"), "a number isn't a condition")
		testing.expect(t, !dimmed(t, &app, "true"), "true is a condition")
		back_out(&app)
	}
	fill_op(t, &app, ni, "Compare", "a == b")
	fill_ref(t, &app, ni, "operation")
	fill_ref(t, &app, ni, "WHITENESS")
	// The else branch: a u32 again.
	if open_dot(t, &app, ni, 0) {
		testing.expect(t, dimmed(t, &app, "true"), "a bool isn't a u32")
		back_out(&app)
	}
	fill_ref(t, &app, ni, "WHITENESS")
	testing.expect_value(t, line_src(&app, ni), "operation = BLACKNESS if operation == WHITENESS else WHITENESS")
	// D-pad: the target, `=`, then each part.
	testing.expect_value(t, stops(&app, ni), "operation = BLACKNESS operation WHITENESS WHITENESS")

	// Y on the else branch: the fill menu for a u32; B puts it back; Reference > BLACKNESS replaces it.
	built := strings.clone(src(&app), context.temp_allocator)
	if focus_text(t, &app, ni, "WHITENESS", 1) {
		change_selected(&app)
		testing.expect_value(t, app.state, State.Radial)
		testing.expect(t, dimmed(t, &app, "true"), "the refilled branch expects a u32")
		back_out(&app)
	}
	testing.expect_value(t, src(&app), built)
	if focus_text(t, &app, ni, "WHITENESS", 1) {
		change_selected(&app)
		if pick(t, &app, "Reference") && ref_choose(t, &app, "BLACKNESS") && app.state == .Radial do pick(t, &app, "BLACKNESS")
	}
	testing.expect_value(t, line_src(&app, ni), "operation = BLACKNESS if operation == WHITENESS else BLACKNESS")
	// Y on the condition's operand: refilled with a dot that takes anything (a comparison).
	if focus_text(t, &app, ni, "operation", 1) {
		change_selected(&app)
		fi := dot_index(&app, ni, 0)
		testing.expect(t, fi >= 0 && app.doc.nodes[ni].fields[fi].hint == "", "a comparison's operand takes anything")
		back_out(&app)
	}

	// LT+B on a branch: a dot of the target's type; refill it.
	if focus_text(t, &app, ni, "BLACKNESS", 1) do delete_selected(&app)
	testing.expect_value(t, shape(&app, ni, " if "), "[ if |tern][operation][ == ][WHITENESS][ else |tern][●]")
	if fi := dot_index(&app, ni, 0); fi >= 0 do testing.expect_value(t, app.doc.nodes[ni].fields[fi].hint, "u32")
	fill_ref(t, &app, ni, "WHITENESS")
	// LT+B on the condition's `WHITENESS`: a dot; LT+B on that dot: the comparison goes (a bool dot).
	if focus_text(t, &app, ni, "WHITENESS", 0) do delete_selected(&app)
	testing.expect_value(t, line_src(&app, ni), "operation = BLACKNESS if operation ==  else WHITENESS")
	if fi := dot_index(&app, ni, 0); fi >= 0 {
		focus_field_index(&app, ni, fi)
		delete_selected(&app)
	}
	testing.expect_value(t, shape(&app, ni, " = "), "[ = |assign_op][BLACKNESS][ if |tern][●][ else |tern][WHITENESS]")
	if fi := dot_index(&app, ni, 0); fi >= 0 do testing.expect_value(t, app.doc.nodes[ni].fields[fi].hint, "bool")
	fill_op(t, &app, ni, "Compare", "a == b")
	fill_ref(t, &app, ni, "operation")
	fill_ref(t, &app, ni, "WHITENESS")
	testing.expect_value(t, line_src(&app, ni), "operation = BLACKNESS if operation == WHITENESS else WHITENESS")
	menu_shape := shape(&app, ni, " = ")

	// Saved and loaded back: the same text, the same structure.
	text := expect_stable(t, &app)
	testing.expect(t, strings.contains(text, "\toperation = BLACKNESS if operation == WHITENESS else WHITENESS\n"), text)
	li := line_with(&app, "operation = BLACKNESS")
	testing.expect_value(t, shape(&app, li, " = "), menu_shape)
	testing.expect_value(t, stops(&app, li), "operation = BLACKNESS operation WHITENESS WHITENESS")
	odin_check(t, "ternary", text)

	// LT+B on a dot of the ternary itself (both branches emptied first): the ternary goes.
	if focus_text(t, &app, li, "BLACKNESS") do delete_selected(&app)
	if fi := dot_index(&app, li, 0); fi >= 0 {
		focus_field_index(&app, li, fi)
		delete_selected(&app)
	}
	testing.expect_value(t, line_src(&app, li), "operation =")
	if fi := dot_index(&app, li, 0); fi >= 0 do testing.expect_value(t, app.doc.nodes[li].fields[fi].hint, "u32")
	// A fresh `● ? ● : ●`: D-pad reaches its three dots; LT+B on one takes the ternary back out.
	fill_op(t, &app, li, "Choose", "c ? a : b")
	testing.expect_value(t, shape(&app, li, " = "), "[ = |assign_op][●][ ? |tern][●][ : |tern][●]")
	testing.expect_value(t, stops(&app, li), "operation = ● ● ●")
	if fi := dot_index(&app, li, 1); fi >= 0 {
		focus_field_index(&app, li, fi)
		delete_selected(&app)
	}
	testing.expect_value(t, line_src(&app, li), "operation =")
	testing.expect(t, li < len(app.doc.nodes) && line_with(&app, "operation =") == li, "the line stays")
}

// The other forms, and a ternary in a declaration, a call argument and a
// typed declaration: loaded structured, saved verbatim, Y refills a part.
@(test)
test_expr_ternary_forms_load :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\n" +
		"import win32 \"core:sys/windows\"\n\n" +
		"pick :: proc(a: int) -> int {\n\treturn a\n}\n\n" +
		"main :: proc() {\n" +
		"\tok := true\n" +
		"\tx := 1 if ok else 2\n" +
		"\ty: u32 = 3 if !ok else 4\n" +
		"\tx = ok ? 5 : 6\n" +
		"\tz := 7 when ODIN_DEBUG else 8\n" +
		"\tx = 1 if ok else 2 if x > 3 else 4\n" +
		"\tx = pick(x) if ok else pick(1)\n" +
		"\tw := pick(1 if ok else 2)\n" +
		"\tx = pick(1000000) if ok && x > 1000000 && x < 200000000 else pick(2000000) + pick(3000000)\n" +
		"\t_, _, _ = y, z, w\n" +
		"}"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	for want in ([]string{"x := 1", "y: u32", "x = ok ?", "z := 7", "x = 1 if ok else 2 if", "x = pick(x)", "w := pick"}) {
		ni := line_with(&app, want)
		has := false
		if ni >= 0 do for f in app.doc.nodes[ni].fields do if f.kind == TERN_KIND do has = true
		testing.expectf(t, has, "%q: a structured ternary: %s", want, ni >= 0 ? shape(&app, ni, "") : "<none>")
	}
	testing.expect_value(t, shape(&app, line_with(&app, "x = ok ?"), " = "), "[ = |assign_op][ok][ ? |tern][5][ : |tern][6]")
	testing.expect_value(t, shape(&app, line_with(&app, "x = 1 if ok else 2 if"), " = "),
		"[ = |assign_op][1][ if |tern][ok][ else |tern][2][ if |tern][x][ > ][3][ else |tern][4]")
	testing.expect_value(t, stops(&app, line_with(&app, "x = pick(x)")), "x = pick x ok pick 1")

	// Y on `ok` of `x = ok ? 5 : 6`: a bool dot. On `6`: what x is (an int).
	ni := line_with(&app, "x = ok ?")
	if focus_text(t, &app, ni, "ok") {
		change_selected(&app)
		fi := dot_index(&app, ni, 0)
		testing.expect(t, fi >= 0 && app.doc.nodes[ni].fields[fi].hint == "bool", "the condition expects a bool")
		testing.expect(t, dimmed(t, &app, "Number"), "a number isn't a condition")
		back_out(&app)
	}
	ni = line_with(&app, "y: u32")
	if focus_text(t, &app, ni, "4") {
		change_selected(&app)
		fi := dot_index(&app, ni, 0)
		testing.expect(t, fi >= 0 && app.doc.nodes[ni].fields[fi].hint == "u32", "a branch expects the declared type")
		back_out(&app)
	}
	// Inside a call: the branches expect the parameter's type.
	ni = line_with(&app, "w := pick")
	if focus_text(t, &app, ni, "2") {
		change_selected(&app)
		fi := dot_index(&app, ni, 0)
		testing.expect(t, fi >= 0 && app.doc.nodes[ni].fields[fi].hint == "int", "a branch in an argument expects the parameter's type")
		back_out(&app)
	}
	testing.expect_value(t, src(&app), text)
	// The types: x := 1 if ok else 2 is an int.
	ty, ok := var_type_at(&app, line_with(&app, "y: u32"), "x")
	testing.expect(t, ok && ty.expr == "int", "x is an int")
	format_doc(&app)
	testing.expect_value(t, src(&app), text)
	odin_check(t, "ternary_forms", text)
}

// ---------------------------------------------------------------------------
// Conversions

@(private = "file")
CONV_BASE :: "package handmade\n\n" +
	"import win32 \"core:sys/windows\"\n\n" +
	"main :: proc() {\n" +
	"\tf: f32 = 1.5\n" +
	"}"

@(test)
test_expr_convert_built_from_menus :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, CONV_BASE)
	close := line_with(&app, "f: f32") + 1

	// instance := win32.HINSTANCE(win32.GetModuleHandleW(nil))
	ni := add_stmt(t, &app, close, "Declarations", "Variable (:=)")
	rename_nth(&app, ni, "instance")
	if open_dot(t, &app, ni, 0) && pick(t, &app, "Convert") {
		testing.expect_value(t, labels(&app), "T(x) | cast(T)x | transmute(T)x | auto_cast x")
		if pick(t, &app, "T(x)") do pick_leaf(t, &app, "HINSTANCE", CONV_FILL)
	}
	testing.expect_value(t, line_src(&app, ni), "instance := win32.HINSTANCE()")
	testing.expect_value(t, cursor_text(&app), "") // on the value's dot
	fill_call(t, &app, ni, "GetModuleHandleW")
	if fi := dot_index(&app, ni, 0); fi >= 0 do testing.expect_value(t, app.doc.nodes[ni].fields[fi].hint, "LPCWSTR")
	if open_dot(t, &app, ni, 0) {
		testing.expect(t, dimmed(t, &app, "true"), "a bool isn't an LPCWSTR")
		back_out(&app)
	}
	fill_nil(t, &app, ni)
	testing.expect_value(t, line_src(&app, ni), "instance := win32.HINSTANCE(win32.GetModuleHandleW(nil))")
	testing.expect_value(t, stops(&app, ni), "instance := HINSTANCE GetModuleHandleW nil")
	ty, ok := var_type_at(&app, ni + 1, "instance")
	testing.expectf(t, ok && ty.expr == "win32.HINSTANCE", "instance is a win32.HINSTANCE: %v", ty)

	// A typed declaration's dot: Convert > T(x) has the expected type first; other types are grayed.
	h := add_stmt(t, &app, ni + 1, "Declarations", "Variable (typed)")
	rename_nth(&app, h, "module")
	if open_dot(t, &app, h, 0, "type") && pick(t, &app, "Type") do pick_leaf(t, &app, "HMODULE", TYPE_IMPORT_FILL)
	if open_dot(t, &app, h, 0) && pick(t, &app, "Convert") && pick(t, &app, "T(x)") {
		v := current_view(&app)
		testing.expect(t, v != nil && len(v.entries) > 0 && v.entries[0].label == "win32.HMODULE" && !v.entries[0].dim, "the expected type is first")
		testing.expect(t, dimmed(t, &app, "BOOL"), "a BOOL isn't an HMODULE")
		testing.expect(t, dimmed(t, &app, "HINSTANCE"), "HMODULE is a distinct HINSTANCE")
		testing.expect(t, !dimmed(t, &app, "HMODULE"), "HMODULE is")
		testing.expect(t, dimmed(t, &app, "bool"), "a bool isn't an HMODULE")
		pick(t, &app, "win32.HMODULE")
	}
	fill_ref(t, &app, h, "instance")
	testing.expect_value(t, line_src(&app, h), "module: win32.HMODULE = win32.HMODULE(instance)")

	// cast(T)x, transmute(T)x, auto_cast x.
	c := add_stmt(t, &app, h + 1, "Declarations", "Variable (:=)")
	rename_nth(&app, c, "addr")
	fill_convert(t, &app, c, "cast(T)x", "uintptr")
	testing.expect_value(t, line_src(&app, c), "addr := cast(uintptr)")
	fill_ref(t, &app, c, "instance")
	testing.expect_value(t, line_src(&app, c), "addr := cast(uintptr)instance")
	testing.expect_value(t, stops(&app, c), "addr := cast(uintptr) instance")
	ty, ok = var_type_at(&app, c + 1, "addr")
	testing.expect(t, ok && ty.expr == "uintptr", "addr is a uintptr")
	bits := add_stmt(t, &app, c + 1, "Declarations", "Variable (:=)")
	rename_nth(&app, bits, "bits")
	fill_convert(t, &app, bits, "transmute(T)x", "u32")
	fill_ref(t, &app, bits, "f")
	testing.expect_value(t, line_src(&app, bits), "bits := transmute(u32)f")
	n := add_stmt(t, &app, bits + 1, "Declarations", "Variable (typed)")
	rename_nth(&app, n, "n")
	if open_dot(t, &app, n, 0, "type") && pick(t, &app, "Type") do pick(t, &app, "int")
	if open_dot(t, &app, n, 0) && pick(t, &app, "Convert") do pick(t, &app, "auto_cast x")
	fill_ref(t, &app, n, "f")
	testing.expect_value(t, line_src(&app, n), "n: int = auto_cast f")

	// Y on cast(uintptr): another form / type, the value kept.
	if focus_text(t, &app, c, "cast(uintptr)") {
		change_selected(&app)
		testing.expect_value(t, labels(&app), "T(x) | cast(T)x | transmute(T)x | auto_cast x")
		if pick(t, &app, "T(x)") do pick(t, &app, "uintptr")
	}
	testing.expect_value(t, line_src(&app, c), "addr := uintptr(instance)")
	// Y on the type of T(x): win32.HINSTANCE -> win32.HMODULE, and back.
	if focus_text(t, &app, ni, "HINSTANCE") {
		change_selected(&app)
		if pick(t, &app, "T(x)") do pick_leaf(t, &app, "HMODULE", CONV_FILL)
	}
	testing.expect_value(t, line_src(&app, ni), "instance := win32.HMODULE(win32.GetModuleHandleW(nil))")
	testing.expect_value(t, cursor_text(&app), "HMODULE")
	change_selected(&app)
	if pick(t, &app, "T(x)") do pick_leaf(t, &app, "HINSTANCE", CONV_FILL)
	testing.expect_value(t, line_src(&app, ni), "instance := win32.HINSTANCE(win32.GetModuleHandleW(nil))")
	// B on the Convert menu changes nothing.
	before := strings.clone(src(&app), context.temp_allocator)
	if focus_text(t, &app, ni, "HINSTANCE") {
		change_selected(&app)
		back_out(&app)
	}
	testing.expect_value(t, src(&app), before)

	text := expect_stable(t, &app)
	testing.expect(t, strings.contains(text, "\tinstance := win32.HINSTANCE(win32.GetModuleHandleW(nil))\n"), text)
	odin_check(t, "convert", text)

	// LT+B on the type of T(x): just the value is left; on `nil` inside it: a typed dot.
	ni = line_with(&app, "instance :=")
	if focus_text(t, &app, ni, "nil") do delete_selected(&app)
	testing.expect_value(t, line_src(&app, ni), "instance := win32.HINSTANCE(win32.GetModuleHandleW())")
	if fi := dot_index(&app, ni, 0); fi >= 0 do testing.expect_value(t, app.doc.nodes[ni].fields[fi].hint, "LPCWSTR")
	fill_nil(t, &app, ni)
	if focus_text(t, &app, ni, "HINSTANCE") do delete_selected(&app)
	testing.expect_value(t, line_src(&app, ni), "instance := win32.GetModuleHandleW(nil)")
	c = line_with(&app, "addr :=")
	if focus_text(t, &app, c, "uintptr") do delete_selected(&app)
	testing.expect_value(t, line_src(&app, c), "addr := instance")
	bits = line_with(&app, "bits :=")
	if focus_text(t, &app, bits, "f") do delete_selected(&app) // the value: a dot
	testing.expect_value(t, line_src(&app, bits), "bits := transmute(u32)")
	if fi := dot_index(&app, bits, 0); fi >= 0 {
		focus_field_index(&app, bits, fi)
		delete_selected(&app) // the dot: the conversion goes
	}
	testing.expect_value(t, line_src(&app, bits), "bits :=")
}

// Conversions as written in a file: structured, verbatim, Y / LT+B work.
@(test)
test_expr_convert_load :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package handmade\n\n" +
		"import win32 \"core:sys/windows\"\n\n" +
		"Meters :: distinct f64\n\n" +
		"main :: proc() {\n" +
		"\tinstance := win32.HINSTANCE(win32.GetModuleHandleW(nil))\n" +
		"\tf: f32 = 1.5\n" +
		"\tm := Meters(f)\n" +
		"\tp := cast(uintptr)instance\n" +
		"\tq := cast(uintptr) instance\n" +
		"\tbits := transmute(u32)f\n" +
		"\tn: int = auto_cast f\n" +
		"\tk := cast(u32)bits + u32(n)\n" +
		"\t_, _, _, _ = m, p, q, k\n" +
		"}"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	ni := line_with(&app, "instance :=")
	ty, ok := var_type_at(&app, ni + 1, "instance")
	testing.expectf(t, ok && ty.expr == "win32.HINSTANCE", "instance is a win32.HINSTANCE: %v", ty)
	ty, ok = var_type_at(&app, line_with(&app, "p :=") + 1, "m")
	testing.expectf(t, ok && ty.expr == "Meters", "m is Meters: %v", ty)
	testing.expect_value(t, stops(&app, ni), "instance := HINSTANCE GetModuleHandleW nil")
	testing.expect_value(t, shape(&app, line_with(&app, "q :="), "cast"), "[cast(uintptr) |conv][instance]")
	testing.expect_value(t, shape(&app, line_with(&app, "n: int"), " = "), "[ = ][auto_cast |conv][f]")
	testing.expect_value(t, stops(&app, line_with(&app, "k :=")), "k := cast(u32) bits u32 n")

	// Y on `nil`: the refill dot expects GetModuleHandleW's LPCWSTR.
	if focus_text(t, &app, ni, "nil") {
		change_selected(&app)
		testing.expect(t, dimmed(t, &app, "true"), "a bool isn't an LPCWSTR")
		testing.expect(t, !dimmed(t, &app, "nil"), "nil is")
		back_out(&app)
	}
	// Y on HINSTANCE: the Convert menu (not the proc list); B: unchanged.
	if focus_text(t, &app, ni, "HINSTANCE") {
		change_selected(&app)
		v := current_view(&app)
		testing.expect(t, v != nil && v.title == "Convert", "the Convert menu")
		back_out(&app)
	}
	// Y on cast(uintptr) with a space: retyped, the space normalized away.
	q := line_with(&app, "q :=")
	if focus_text(t, &app, q, "cast(uintptr) ") {
		change_selected(&app)
		if pick(t, &app, "cast(T)x") do pick(t, &app, "rawptr")
	}
	testing.expect_value(t, line_src(&app, q), "q := cast(rawptr)instance")
	// Y on `Meters` of Meters(f) (a type declared in this file): the Convert menu.
	m := line_with(&app, "m := Meters")
	if focus_text(t, &app, m, "Meters") {
		change_selected(&app)
		v := current_view(&app)
		testing.expect(t, v != nil && v.title == "Convert", "Meters(f) is a conversion")
		if pick(t, &app, "T(x)") do pick(t, &app, "f64")
	}
	testing.expect_value(t, line_src(&app, m), "m := f64(f)")
	format_doc(&app)
	out := strings.clone(src(&app), context.temp_allocator)
	load(&app, out)
	testing.expect_value(t, src(&app), out)
	odin_check(t, "convert_load", out)
}

// A nested call's empty argument (loaded) is typed like a call statement's.
@(test)
test_expr_nested_call_dots_typed_on_load :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package handmade\n\nimport win32 \"core:sys/windows\"\n\nmain :: proc() {\n\tinstance := win32.HINSTANCE(win32.GetModuleHandleW())\n}")
	ni := line_with(&app, "instance :=")
	fi := dot_index(&app, ni, 0)
	if testing.expectf(t, fi >= 0, "GetModuleHandleW() gets its dot back: %s", shape(&app, ni, "")) {
		testing.expect_value(t, app.doc.nodes[ni].fields[fi].hint, "LPCWSTR")
	}
}

// WHITENESS :: 0x00FF0062 without a keyboard: Number, then LT+A -> the keypad.
@(test)
test_expr_number_keypad :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package handmade\n")
	focus_dot(&app)
	update(&app, Input{confirm = true})
	if pick(t, &app, "Values") do pick(t, &app, "Constant")
	c := len(app.doc.nodes) - 1
	rename_nth(&app, c, "WHITENESS")
	if open_dot(t, &app, c, 0) do pick(t, &app, "Number")
	testing.expect_value(t, cursor_text(&app), "0")
	edit_selected(&app) // LT+A
	v := current_view(&app)
	if !testing.expect(t, v != nil && v.title == "Number", "the keypad") do return
	testing.expect(t, dimmed(t, &app, "A"), "no hex digits before 0x")
	testing.expect(t, !dimmed(t, &app, "0x"), "0x on the default 0")
	for k in ([]string{"0x", "0", "0", "F", "F", "0", "0", "6", "2", "7", "Del"}) do pick(t, &app, k)
	testing.expect(t, !dimmed(t, &app, "A"), "hex digits after 0x")
	testing.expect(t, dimmed(t, &app, "0x"), "one 0x")
	testing.expect(t, dimmed(t, &app, "."), "no point in a hex number")
	pick(t, &app, "OK")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, line_src(&app, c), "WHITENESS :: 0x00FF0062")
	// Decimal: 1 . 5, then B keeps it.
	edit_selected(&app)
	pick(t, &app, "Del")
	testing.expect_value(t, line_src(&app, c), "WHITENESS :: 0x00FF006")
	back_out(&app)
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, keypad_apply("0", "1"), "1")
	testing.expect_value(t, keypad_apply("1", "."), "1.")
	testing.expect_value(t, keypad_apply("1.", "."), "1.")
	testing.expect_value(t, keypad_apply("0x", "Del"), "0")
	testing.expect_value(t, keypad_apply("7", "Del"), "0")
}

// ---------------------------------------------------------------------------
// The goal program, exactly as written (with `> 0` on GetMessageW, which this
// Odin's bindings need). handmade_acceptance_test.odin builds the rest of it
// from the menus (`|` of three, win32.L, &x, nil, hex numbers, != 0, != nil,
// > 0); here the two expressions it couldn't: the WM_PAINT ternary and the
// HINSTANCE conversion, built into the file with the controller.

@(private = "file")
HM_TARGET :: "package handmade\n\n" +
	"import win32 \"core:sys/windows\"\n\n" +
	"// Kept local in case your Odin version's gdi32 bindings don't export these\n" +
	"WHITENESS :: 0x00FF0062\n" +
	"BLACKNESS :: 0x00000042\n\n" +
	"// Stands in for Casey's `static DWORD Operation` inside the callback\n" +
	"operation: u32 = WHITENESS\n\n" +
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
	"\tcase win32.WM_DESTROY:\n" +
	"\t\twin32.OutputDebugStringA(\"WM_DESTROY\\n\")\n" +
	"\tcase win32.WM_CLOSE:\n" +
	"\t\twin32.OutputDebugStringA(\"WM_CLOSE\\n\")\n" +
	"\tcase win32.WM_ACTIVATEAPP:\n" +
	"\t\twin32.OutputDebugStringA(\"WM_ACTIVATEAPP\\n\")\n" +
	"\tcase win32.WM_PAINT:\n" +
	"\t\tpaint: win32.PAINTSTRUCT\n" +
	"\t\tdevice_context := win32.BeginPaint(window, &paint)\n" +
	"\t\tx := paint.rcPaint.left\n" +
	"\t\ty := paint.rcPaint.top\n" +
	"\t\twidth := paint.rcPaint.right - paint.rcPaint.left\n" +
	"\t\theight := paint.rcPaint.bottom - paint.rcPaint.top\n" +
	"\t\twin32.PatBlt(device_context, x, y, width, height, operation)\n" +
	"\t\toperation = BLACKNESS if operation == WHITENESS else WHITENESS\n" +
	"\t\twin32.EndPaint(window, &paint)\n" +
	"\tcase:\n" +
	"\t\t// Casey logs here too; that gets noisy fast, so I left it out\n" +
	"\t\tresult = win32.DefWindowProcW(window, message, w_param, l_param)\n" +
	"\t}\n\n" +
	"\treturn result\n" +
	"}\n\n" +
	"main :: proc() {\n" +
	"\tinstance := win32.HINSTANCE(win32.GetModuleHandleW(nil))\n\n" +
	"\twindow_class := win32.WNDCLASSW {\n" +
	"\t\tstyle         = win32.CS_OWNDC | win32.CS_HREDRAW | win32.CS_VREDRAW,\n" +
	"\t\tlpfnWndProc   = main_window_callback,\n" +
	"\t\thInstance     = instance,\n" +
	"\t\tlpszClassName = win32.L(\"HandmadeHeroWindowClass\"),\n" +
	"\t}\n\n" +
	"\tif win32.RegisterClassW(&window_class) != 0 {\n" +
	"\t\twindow_handle := win32.CreateWindowExW(\n" +
	"\t\t\t0,\n" +
	"\t\t\twindow_class.lpszClassName,\n" +
	"\t\t\twin32.L(\"HandmadeHero\"),\n" +
	"\t\t\twin32.WS_OVERLAPPEDWINDOW | win32.WS_VISIBLE,\n" +
	"\t\t\twin32.CW_USEDEFAULT, win32.CW_USEDEFAULT,\n" +
	"\t\t\twin32.CW_USEDEFAULT, win32.CW_USEDEFAULT,\n" +
	"\t\t\tnil, nil, instance, nil,\n" +
	"\t\t)\n\n" +
	"\t\tif window_handle != nil {\n" +
	"\t\t\tmessage: win32.MSG\n" +
	"\t\t\tfor win32.GetMessageW(&message, nil, 0, 0) > 0 {\n" +
	"\t\t\t\twin32.TranslateMessage(&message)\n" +
	"\t\t\t\twin32.DispatchMessageW(&message)\n" +
	"\t\t\t}\n" +
	"\t\t} else {\n" +
	"\t\t\t// TODO logging\n" +
	"\t\t}\n" +
	"\t} else {\n" +
	"\t\t// TODO logging\n" +
	"\t}\n" +
	"}"

@(private = "file")
TERNARY_LINE :: "\t\toperation = BLACKNESS if operation == WHITENESS else WHITENESS\n"
@(private = "file")
INSTANCE_LINE :: "\tinstance := win32.HINSTANCE(win32.GetModuleHandleW(nil))\n"

@(test)
test_expr_handmade_target_built :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	// The target without its two lines.
	base, _ := strings.replace(HM_TARGET, TERNARY_LINE, "", 1, context.temp_allocator)
	base, _ = strings.replace(base, INSTANCE_LINE, "", 1, context.temp_allocator)
	load(&app, base)
	testing.expect_value(t, src(&app), base)

	// operation = BLACKNESS if operation == WHITENESS else WHITENESS   (before EndPaint, in case WM_PAINT)
	ni := add_assignment(t, &app, line_with(&app, "win32.EndPaint"), "operation")
	fill_op(t, &app, ni, "Choose", "a if c else b")
	fill_ref(t, &app, ni, "BLACKNESS")
	fill_op(t, &app, ni, "Compare", "a == b")
	fill_ref(t, &app, ni, "operation")
	fill_ref(t, &app, ni, "WHITENESS")
	fill_ref(t, &app, ni, "WHITENESS")
	testing.expect_value(t, line_src(&app, ni), "operation = BLACKNESS if operation == WHITENESS else WHITENESS")

	// instance := win32.HINSTANCE(win32.GetModuleHandleW(nil))   (main's first statement)
	ni = add_stmt(t, &app, line_with(&app, "main :: proc()") + 1, "Declarations", "Variable (:=)")
	rename_nth(&app, ni, "instance")
	fill_convert(t, &app, ni, "T(x)", "HINSTANCE")
	fill_call(t, &app, ni, "GetModuleHandleW")
	fill_nil(t, &app, ni)
	testing.expect_value(t, line_src(&app, ni), "instance := win32.HINSTANCE(win32.GetModuleHandleW(nil))")

	// `instance` (a converted win32.HINSTANCE) fits `hInstance = ●`: Y on it there.
	cls := line_with(&app, "hInstance")
	if focus_text(t, &app, cls, "instance") {
		change_selected(&app)
		if pick(t, &app, "Reference") && ref_choose(t, &app, "instance") && app.state == .Radial {
			testing.expect(t, !dimmed(t, &app, "instance"), "instance fits hInstance")
			pick(t, &app, "instance")
		}
	}
	// `|` of three: LT+B on the middle operand leaves a UINT dot; Constant puts it back.
	st := line_with(&app, "style ")
	if focus_text(t, &app, st, "win32.CS_HREDRAW") do delete_selected(&app)
	// (The loaded literal's aligned `=` signs are re-padded on save; the node holds " = ".)
	testing.expect(t, strings.contains(line_src(&app, st), "style = win32.CS_OWNDC |  | win32.CS_VREDRAW,"), line_src(&app, st))
	if fi := dot_index(&app, st, 0); fi >= 0 do testing.expect_value(t, app.doc.nodes[st].fields[fi].hint, "UINT")
	fill_const(t, &app, st, "CS_HREDRAW")

	format_doc(&app)
	testing.expectf(t, src(&app) == HM_TARGET, "saved:\n%s\n--- want ---\n%s", src(&app), HM_TARGET)
	text := expect_stable(t, &app)
	ty, ok := var_type_at(&app, line_with(&app, "window_class :="), "instance")
	testing.expectf(t, ok && ty.expr == "win32.HINSTANCE", "instance: %v", ty)
	op := line_with(&app, "operation = BLACKNESS")
	testing.expect_value(t, shape(&app, op, " = "), "[ = |assign_op][BLACKNESS][ if |tern][operation][ == ][WHITENESS][ else |tern][WHITENESS]")
	testing.expect_value(t, stops(&app, line_with(&app, "instance :=")), "instance := HINSTANCE GetModuleHandleW nil")
	odin_check(t, "handmade_target", text)
}


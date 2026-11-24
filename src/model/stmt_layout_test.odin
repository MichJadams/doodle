package model

// Comments, blank lines and grouped call-argument rows (stmt_layout.odin), and
// the user's whole Handmade program built from an empty project with the
// controller: A on dots, menu picks, Reference / Pass as / Field of, Y, LT+B,
// dictation (set_field_text).
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

// The first "●" statement line at or after `from`.
@(private = "file")
body_line :: proc(app: ^App, from: int) -> int {
	if from < 0 do return -1
	for i in from ..< len(app.doc.nodes) do if is_body_slot_line(app.doc.nodes[i]) do return i
	return -1
}

// A on the green dot before line `at`, then group -> leaf.
@(private = "file")
add_at_dot :: proc(t: ^testing.T, app: ^App, at: int, group, leaf: string, loc := #caller_location) -> int {
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

// A on the bottom green dot (file scope), then group -> leaf of the Add menu.
@(private = "file")
add_top :: proc(t: ^testing.T, app: ^App, group, leaf: string, loc := #caller_location) {
	back_out(app)
	focus_dot(app)
	update(app, Input{confirm = true})
	if pick(t, app, group, loc) do pick(t, app, leaf, loc)
}

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

// win32.L("text")
@(private = "file")
fill_wide_string :: proc(t: ^testing.T, app: ^App, ni: int, text: string, loc := #caller_location) {
	fill_call(t, app, ni, "L", loc)
	if open_dot(t, app, ni, 0, loc = loc) && pick(t, app, "String", loc) && pick(t, app, "\"...\"  string", loc) {
		for f, i in app.doc.nodes[ni].fields do if f.editable && f.kind == "string" && f.text == "" { set_field_text(app, ni, i, text); return }
	}
}

@(private = "file")
fill_type :: proc(t: ^testing.T, app: ^App, ni, nth: int, name: string, fill := TYPE_IMPORT_FILL, loc := #caller_location) {
	if open_dot(t, app, ni, nth, "type", loc) && pick(t, app, "Type", loc) do pick_leaf(t, app, name, fill, loc)
}

// Dictation into the nth editable name of line ni.
@(private = "file")
rename :: proc(app: ^App, ni: int, name: string, nth := 0) {
	if ni < 0 do return
	seen := 0
	for f, i in app.doc.nodes[ni].fields do if f.editable && f.kind != "string" && f.kind != COMMENT_KIND {
		if seen == nth { set_field_text(app, ni, i, name); return }
		seen += 1
	}
}

// Dictation into a comment's text (free text, like a string).
@(private = "file")
say_comment :: proc(t: ^testing.T, app: ^App, ni: int, text: string, loc := #caller_location) {
	if ni >= 0 && ni < len(app.doc.nodes) {
		for f, i in app.doc.nodes[ni].fields do if f.editable && f.kind == COMMENT_KIND { set_field_text(app, ni, i, text); return }
	}
	testing.expectf(t, false, "no comment text on %q", line_src(app, ni), loc = loc)
}

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

// Assignment > Assignment on the "●" line ni, Y on the target -> `target`.
@(private = "file")
assign_to :: proc(t: ^testing.T, app: ^App, ni: int, target: string, loc := #caller_location) {
	if add_in_body(t, app, ni, "Assignment", "Assignment", loc) < 0 do return // the target pick opens at once
	if ref_choose(t, app, target, loc) && app.state == .Radial do pick(t, app, target, loc)
}

// Y on top-level argument k of the call on line ni, then `option`.
@(private = "file")
y_arg :: proc(t: ^testing.T, app: ^App, ni, k: int, option: string, loc := #caller_location) -> bool {
	back_out(app)
	al, ok := find_arg_list(app.doc.nodes[ni])
	if !testing.expectf(t, ok && k <= len(al.seps), "no argument %d on %q", k, line_src(app, ni), loc = loc) do return false
	fi := k == 0 ? al.open + 1 : al.seps[k - 1] + 1
	focus_field_index(app, ni, fi)
	change_selected(app)
	return pick(t, app, option, loc)
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
// Comments in bodies.

@(test)
test_layout_comment_in_body :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tx := 1\n\tif x > 0 {\n\t\tx = 2\n\t} else {\n\t}\n}")

	// A on main's dot before `x := 1`: the statement menu has Layout > Comment.
	ni := add_at_dot(t, &app, line_with(&app, "x := 1"), "Layout", "Comment")
	testing.expect_value(t, line_src(&app, ni), "// brave otter")
	// The cursor is on the text: dictate it (apostrophes, backticks, braces are text).
	ci, cf, ok := editor_target(&app)
	testing.expect(t, ok && ci == ni && app.doc.nodes[ci].fields[cf].kind == COMMENT_KIND, "on the comment's text")
	say_comment(t, &app, ni, "Casey's `static DWORD` { not a block")
	testing.expect_value(t, line_src(&app, ni), "// Casey's `static DWORD` { not a block")
	// Green dots above and below it.
	bp := body_points(&app)
	testing.expect(t, bp[ni] && bp[ni + 1], "dots around the comment")

	// In the empty else body ("●" line? no: the dot before its `}`).
	close := line_with(&app, "\t}", line_with(&app, "} else {") + 1)
	ni = add_at_dot(t, &app, close, "Layout", "Comment")
	say_comment(t, &app, ni, "TODO logging")
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n\t// Casey's `static DWORD` { not a block\n\tx := 1\n\tif x > 0 {\n\t\tx = 2\n\t} else {\n\t\t// TODO logging\n\t}\n}")

	// Saved, loaded back, formatted: unchanged; the loaded comment is editable.
	text := strings.clone(src(&app), context.temp_allocator)
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	format_doc(&app)
	testing.expect_value(t, src(&app), text)
	ni = line_with(&app, "TODO logging")
	found := false
	for f in app.doc.nodes[ni].fields do if f.editable && f.kind == COMMENT_KIND && f.text == "TODO logging" do found = true
	testing.expect(t, found, "loaded comment text is editable")
	say_comment(t, &app, ni, "TODO: log it")
	testing.expect_value(t, line_src(&app, ni), "// TODO: log it")
	// It's not a name: Reference doesn't offer it.
	app.slot_ni, app.slot_fi = ni, 0
	for c in ref_candidates(&app) do testing.expect(t, app.doc.nodes[c.ni].fields[c.fi].kind != COMMENT_KIND, "comment offered as a name")

	// LT+B on the comment: just that line (the braces in the first one are text).
	back_out(&app)
	focus_kth_selectable(&app, line_with(&app, "Casey's"), 0)
	delete_selected(&app)
	focus_kth_selectable(&app, line_with(&app, "TODO"), 0)
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n\tx := 1\n\tif x > 0 {\n\t\tx = 2\n\t} else {\n\t}\n}")
}

// A comment as the first line of a `case:` body, from its "●" line.
@(test)
test_layout_comment_first_in_case :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tx := 1\n\tswitch x {\n\tcase 1:\n\t\tx = 2\n\t}\n}")
	s := line_with(&app, "switch x")
	y_option(t, &app, s, "switch", "Add default case")
	d := line_with(&app, "case:")
	ni := add_in_body(t, &app, body_line(&app, d), "Layout", "Comment")
	say_comment(t, &app, ni, "Casey logs here too; that gets noisy fast, so I left it out")
	assign_to(t, &app, body_line(&app, d), "x")
	fill_number(t, &app, line_with(&app, "x = ", d), "0")
	drop_body_lines(&app)
	text := expect_stable(t, &app)
	testing.expect_value(t, text, "package main\n\nmain :: proc() {\n\tx := 1\n\tswitch x {\n\tcase 1:\n\t\tx = 2\n\tcase:\n\t\t// Casey logs here too; that gets noisy fast, so I left it out\n\t\tx = 0\n\t}\n}")
}

// ---------------------------------------------------------------------------
// Blank lines.

@(test)
test_layout_blank_lines_in_body :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tx := 1\n\tx = 2\n}")
	// Layout > Blank line at the dot between the statements.
	add_at_dot(t, &app, line_with(&app, "x = 2"), "Layout", "Blank line")
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n\tx := 1\n\n\tx = 2\n}")
	// format_doc keeps it (a deliberate single blank line between statements)...
	format_doc(&app)
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n\tx := 1\n\n\tx = 2\n}")
	// ...but not one just inside `{` or just before `}`.
	add_at_dot(t, &app, line_with(&app, "x := 1"), "Layout", "Blank line")
	add_at_dot(t, &app, line_with(&app, "}", line_with(&app, "x = 2")), "Layout", "Blank line")
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n\n\tx := 1\n\n\tx = 2\n\n}")
	format_doc(&app)
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n\tx := 1\n\n\tx = 2\n}")
	// LT+B on the dot above the blank line removes it.
	back_out(&app)
	focus_dot_at(&app, line_with(&app, "x := 1") + 1)
	testing.expect(t, is_blank_line(app.doc.nodes[app.editor_line]), "the dot sits above the blank line")
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n\tx := 1\n\tx = 2\n}")
	// LT+B on a dot with no blank line next to it: nothing.
	focus_dot_at(&app, line_with(&app, "x = 2"))
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n\tx := 1\n\tx = 2\n}")

	// From the "●" line of a new procedure: blank, then on to the next "●".
	load(&app, "package main\n")
	add_top(t, &app, "Procedures", "Procedure")
	hdr := line_with(&app, ":: proc")
	rename(&app, hdr, "main")
	ni := add_in_body(t, &app, body_line(&app, hdr), "Declarations", "Variable (:=)")
	rename(&app, ni, "x")
	fill_number(t, &app, ni, "1")
	b := body_line(&app, hdr)
	add_in_body(t, &app, b, "Layout", "Blank line")
	ci, _, ok := editor_target(&app)
	testing.expect(t, ok && ci == b + 1 && is_body_slot_line(app.doc.nodes[ci]), "on to the next statement line")
	assign_to(t, &app, b + 1, "x")
	fill_number(t, &app, b + 1, "3")
	drop_body_lines(&app)
	testing.expect_value(t, expect_stable(t, &app), "package main\n\nmain :: proc() {\n\tx := 1\n\n\tx = 3\n}")
}

// File scope: a comment right above a declaration, and a blank line.
@(test)
test_layout_file_scope_comment_and_blank :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nA :: 1\nB :: 2\nc: int = A\n")
	add_at_dot(t, &app, line_with(&app, "c: int"), "File Setup", "Comments")
	pick(t, &app, "Single-line comment") // File Setup > Comments is a submenu now
	ci := line_with(&app, "c: int") - 1
	say_comment(t, &app, ci, "Stands in for Casey's `static DWORD Operation` inside the callback")
	add_at_dot(t, &app, ci, "File Setup", "Blank line")
	want := "package main\n\nA :: 1\nB :: 2\n\n// Stands in for Casey's `static DWORD Operation` inside the callback\nc: int = A"
	testing.expect_value(t, src(&app), want)
	testing.expect_value(t, expect_stable(t, &app), want)
	// LT+B on the dot below the blank line (above the comment) removes the blank line.
	back_out(&app)
	focus_dot_at(&app, line_with(&app, "// Stands"))
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\nA :: 1\nB :: 2\n// Stands in for Casey's `static DWORD Operation` inside the callback\nc: int = A")
	// LT+B on the comment.
	focus_kth_selectable(&app, line_with(&app, "// Stands"), 0)
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\nA :: 1\nB :: 2\nc: int = A")
}

// Comments keep exactly what's written (no `()` / `->` clean-ups).
@(test)
test_layout_comment_text_round_trip :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\n// call f( ) -> {\n//no space\n//\n//+private\nmain :: proc() {\n\t// a ( ) b `c` 'd'\n\tx := 1 // trailing\n}"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	format_doc(&app)
	testing.expect_value(t, src(&app), text)
	b := body_points(&app)
	testing.expect(t, b[line_with(&app, "x := 1")], "a dot between the comment and the statement")
}

// ---------------------------------------------------------------------------
// Grouped argument rows.

@(test)
test_layout_arg_rows :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.os_name = "windows"
	load(&app, "package main\n\nimport win32 \"core:sys/windows\"\n")
	add_top(t, &app, "Procedures", "Procedure")
	hdr := line_with(&app, ":: proc")
	rename(&app, hdr, "main")
	ni := add_in_body(t, &app, body_line(&app, hdr), "Declarations", "Variable (:=)")
	rename(&app, ni, "window_handle")
	fill_call(t, &app, ni, "CreateWindowExW")
	fill_number(t, &app, ni)
	fill_nil(t, &app, ni)
	fill_wide_string(t, &app, ni, "HandmadeHero")
	fill_op(t, &app, ni, "Bitwise", "a | b")
	fill_const(t, &app, ni, "WS_OVERLAPPEDWINDOW")
	fill_const(t, &app, ni, "WS_VISIBLE")
	for _ in 0 ..< 4 do fill_const(t, &app, ni, "CW_USEDEFAULT")
	fill_nil(t, &app, ni)
	fill_nil(t, &app, ni)
	fill_nil(t, &app, ni)
	fill_nil(t, &app, ni)
	drop_body_lines(&app)
	format_doc(&app)
	ni = line_with(&app, "window_handle :=")
	one_per_row := "\twindow_handle := win32.CreateWindowExW(\n\t\t0,\n\t\tnil,\n\t\twin32.L(\"HandmadeHero\"),\n\t\twin32.WS_OVERLAPPEDWINDOW | win32.WS_VISIBLE,\n" +
		"\t\twin32.CW_USEDEFAULT,\n\t\twin32.CW_USEDEFAULT,\n\t\twin32.CW_USEDEFAULT,\n\t\twin32.CW_USEDEFAULT,\n\t\tnil,\n\t\tnil,\n\t\tnil,\n\t\tnil,\n\t)\n"
	testing.expectf(t, strings.contains(src(&app), one_per_row), "one per row: %s", src(&app))

	// Y on the first argument: no "Join with previous row" (nothing before it), nor "Own row".
	back_out(&app)
	al, _ := find_arg_list(app.doc.nodes[ni])
	focus_field_index(&app, ni, al.open + 1)
	change_selected(&app)
	testing.expect(t, !has_entry(&app, "Join with previous row") && !has_entry(&app, "Own row"), labels(&app))
	back_out(&app)
	testing.expectf(t, strings.contains(src(&app), one_per_row), "B puts it back: %s", src(&app))

	// Y on CW_USEDEFAULT #2 / #4, nil #2..#4: Join with previous row.
	for k in ([]int{5, 7, 9, 10, 11}) do y_arg(t, &app, ni, k, "Join with previous row")
	want := "\twindow_handle := win32.CreateWindowExW(\n\t\t0,\n\t\tnil,\n\t\twin32.L(\"HandmadeHero\"),\n\t\twin32.WS_OVERLAPPEDWINDOW | win32.WS_VISIBLE,\n" +
		"\t\twin32.CW_USEDEFAULT, win32.CW_USEDEFAULT,\n\t\twin32.CW_USEDEFAULT, win32.CW_USEDEFAULT,\n\t\tnil, nil, nil, nil,\n\t)\n"
	testing.expectf(t, strings.contains(src(&app), want), "grouped rows: %s", src(&app))
	text := expect_stable(t, &app)
	testing.expectf(t, strings.contains(text, want), "after reload: %s", text)

	// Joined: no second "Join", but "Own row" (also on a row's first argument).
	ni = line_with(&app, "window_handle :=")
	if y_arg(t, &app, ni, 9, "Own row") {
		testing.expectf(t, strings.contains(src(&app), "\t\tnil,\n\t\tnil,\n\t\tnil, nil,\n\t)"), "own row: %s", src(&app))
	}
	// nil #3 starts the row `nil, nil,`: Join and Own row; nil #1 is alone: only Join.
	back_out(&app)
	al, _ = find_arg_list(app.doc.nodes[ni])
	focus_field_index(&app, ni, al.seps[9] + 1)
	change_selected(&app)
	testing.expect(t, has_entry(&app, "Own row") && has_entry(&app, "Join with previous row"), labels(&app))
	back_out(&app)
	focus_field_index(&app, ni, al.seps[7] + 1)
	change_selected(&app)
	testing.expect(t, !has_entry(&app, "Own row") && has_entry(&app, "Join with previous row"), labels(&app))
	back_out(&app)
	// Every argument on its own row again: back to the default layout.
	for k in ([]int{5, 7, 10}) do y_arg(t, &app, ni, k, "Own row")
	testing.expectf(t, strings.contains(src(&app), one_per_row), "all own rows: %s", src(&app))
	testing.expect_value(t, app.doc.nodes[ni].fields[al.open].hint, "")

	// A short call that isn't broken: nothing offered.
	load(&app, "package main\n\nimport win32 \"core:sys/windows\"\n\nmain :: proc() {\n\twin32.EndPaint(nil, nil)\n}")
	ni = line_with(&app, "EndPaint")
	al, _ = find_arg_list(app.doc.nodes[ni])
	focus_field_index(&app, ni, al.seps[0] + 1)
	change_selected(&app)
	testing.expect(t, !has_entry(&app, "Join with previous row") && !has_entry(&app, "Own row"), labels(&app))
	back_out(&app)
}

// ---------------------------------------------------------------------------
// The whole program, from an empty project.

// The target, exactly as the user's file except for the deliberate
// `for win32.GetMessageW(...) > 0` (this Odin's GetMessageW returns an INT).
@(private = "file")
HANDMADE_LAYOUT :: "package handmade\n\n" +
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

@(test)
test_layout_handmade_from_empty_project :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.os_name = "windows"
	load(&app, "package handmade\n")

	// ---- File scope ----
	// import win32 "core:sys/windows"
	focus_dot(&app)
	update(&app, Input{confirm = true})
	pick(t, &app, "Dependencies")
	pick(t, &app, "Aliased import")
	pick(t, &app, "core")
	for _ in 0 ..< 10 {
		v := current_view(&app)
		if v == nil || app.state != .Radial do break
		done := false
		for e, i in v.entries do if e.import_path == "core:sys/windows" { v.index = i; update(&app, Input{confirm = true}); done = true; break }
		if done do break
		if !pick(t, &app, v.title == "core" ? "sys" : "windows") do break
	}
	imp := line_with(&app, "\"core:sys/windows\"")
	rename(&app, imp, "win32")
	// WHITENESS / BLACKNESS
	for name in ([]string{"WHITENESS", "BLACKNESS"}) {
		add_top(t, &app, "Values", "Constant")
		c := len(app.doc.nodes) - 1
		rename(&app, c, name)
		fill_number(t, &app, c, name == "WHITENESS" ? "0x00FF0062" : "0x00000042")
	}
	// operation: u32 = WHITENESS
	add_top(t, &app, "Values", "Global variable (typed)")
	g := len(app.doc.nodes) - 1
	rename(&app, g, "operation")
	fill_type(t, &app, g, 0, "u32", "")
	fill_ref(t, &app, g, "WHITENESS")
	testing.expect_value(t, line_src(&app, g), "operation: u32 = WHITENESS")
	// The comments right above WHITENESS and operation, a blank line before the second.
	add_at_dot(t, &app, line_with(&app, "WHITENESS ::"), "File Setup", "Comments")
	pick(t, &app, "Single-line comment") // File Setup > Comments is a submenu now
	say_comment(t, &app, line_with(&app, "WHITENESS ::") - 1, "Kept local in case your Odin version's gdi32 bindings don't export these")
	add_at_dot(t, &app, line_with(&app, "operation:"), "File Setup", "Comments")
	pick(t, &app, "Single-line comment") // File Setup > Comments is a submenu now
	ci := line_with(&app, "operation:") - 1
	say_comment(t, &app, ci, "Stands in for Casey's `static DWORD Operation` inside the callback")
	add_at_dot(t, &app, ci, "File Setup", "Blank line")

	// ---- main_window_callback :: proc "system" (...) -> win32.LRESULT ----
	add_top(t, &app, "Procedures", "Procedure")
	hdr := line_with(&app, ":: proc")
	rename(&app, hdr, "main_window_callback")
	for p in ([][2]string{{"window", "HWND"}, {"message", "UINT"}, {"w_param", "WPARAM"}, {"l_param", "LPARAM"}}) {
		if !open_dot(t, &app, hdr, 0, "params") || !pick(t, &app, "Add parameter") do break
		eni, efi, ok := editor_target(&app)
		if ok do set_field_text(&app, eni, efi, p[0])
		fill_type(t, &app, hdr, 0, p[1])
	}
	fill_type(t, &app, hdr, 0, "LRESULT")
	back_out(&app)
	focus_dot(&app)
	update(&app, Input{confirm = true})
	pick(t, &app, "Modifiers")
	pick(t, &app, "Calling convention")
	for _ in 0 ..< 8 do if app.mod_pick_line != hdr do update(&app, Input{up = true})
	update(&app, Input{confirm = true})
	pick(t, &app, "\"system\"")
	testing.expect(t, strings.contains(src(&app), "main_window_callback :: proc \"system\" (\n\twindow: win32.HWND,\n\tmessage: win32.UINT,\n\tw_param: win32.WPARAM,\n\tl_param: win32.LPARAM,\n) -> win32.LRESULT {\n"), "header layout")

	// result: win32.LRESULT = 0, a blank line
	ni := add_in_body(t, &app, body_line(&app, hdr), "Declarations", "Variable (typed)")
	rename(&app, ni, "result")
	fill_type(t, &app, ni, 0, "LRESULT")
	fill_number(t, &app, ni)
	testing.expect_value(t, line_src(&app, ni), "result: win32.LRESULT = 0")
	add_in_body(t, &app, body_line(&app, hdr), "Layout", "Blank line")
	// switch message { ... }
	s := add_in_body(t, &app, body_line(&app, hdr), "Branching", "Switch")
	fill_ref(t, &app, s, "message")
	consts := []string{"WM_SIZE", "WM_DESTROY", "WM_CLOSE", "WM_ACTIVATEAPP", "WM_PAINT"}
	c := s + 1
	for name, k in consts {
		if k > 0 {
			y_option(t, &app, c, "case", "Add case after")
			c = line_with(&app, "case ", c + 1)
		}
		fill_const(t, &app, c, name)
	}
	y_option(t, &app, s, "switch", "Add default case")
	for name in consts[:4] {
		cl := line_with(&app, strings.concatenate({"case win32.", name, ":"}, context.temp_allocator))
		ni = add_in_body(t, &app, body_line(&app, cl), "Calls", "From import")
		if ni < 0 do continue
		if pick(t, &app, "win32") do pick_leaf(t, &app, "OutputDebugStringA", "__call_import_proc__")
		if open_dot(t, &app, ni, 0) && pick(t, &app, "String") && pick(t, &app, "\"...\"  string") {
			for f, i in app.doc.nodes[ni].fields do if f.kind == "string" && f.text == "" { set_field_text(&app, ni, i, strings.concatenate({name, "\\n"}, context.temp_allocator)); break }
		}
	}
	// case win32.WM_PAINT:
	pc := line_with(&app, "case win32.WM_PAINT:")
	ni = add_in_body(t, &app, body_line(&app, pc), "Declarations", "Variable (no value)")
	rename(&app, ni, "paint")
	fill_type(t, &app, ni, 0, "PAINTSTRUCT")
	testing.expect_value(t, line_src(&app, ni), "paint: win32.PAINTSTRUCT")
	ni = add_in_body(t, &app, body_line(&app, ni), "Declarations", "Variable (:=)")
	rename(&app, ni, "device_context")
	fill_call(t, &app, ni, "BeginPaint")
	fill_ref(t, &app, ni, "window")
	fill_ref(t, &app, ni, "paint", "&paint   (pointer to it)")
	field_var :: proc(t: ^testing.T, app: ^App, at: int, name: string, fields: ..string) -> int {
		ni := add_in_body(t, app, body_line(app, at), "Declarations", "Variable (:=)")
		rename(app, ni, name)
		if len(fields) == 2 do fill_op(t, app, ni, "Arithmetic", "a - b")
		for field in fields {
			if open_dot(t, app, ni, 0) && pick(t, app, "Reference") && ref_choose(t, app, "paint") {
				if pick(t, app, "Field of paint") && pick(t, app, "rcPaint   RECT") do pick(t, app, field)
			}
		}
		return ni
	}
	ni = field_var(t, &app, ni, "x", "left   LONG")
	ni = field_var(t, &app, ni, "y", "top   LONG")
	ni = field_var(t, &app, ni, "width", "right   LONG", "left   LONG")
	ni = field_var(t, &app, ni, "height", "bottom   LONG", "top   LONG")
	testing.expect_value(t, line_src(&app, ni), "height := paint.rcPaint.bottom - paint.rcPaint.top")
	ni = add_in_body(t, &app, body_line(&app, ni), "Calls", "From import")
	if pick(t, &app, "win32") do pick_leaf(t, &app, "PatBlt", "__call_import_proc__")
	for name in ([]string{"device_context", "x", "y", "width", "height", "operation"}) do fill_ref(t, &app, ni, name)
	testing.expect_value(t, line_src(&app, ni), "win32.PatBlt(device_context, x, y, width, height, operation)")
	ni = body_line(&app, ni)
	assign_to(t, &app, ni, "operation")
	fill_op(t, &app, ni, "Choose", "a if c else b") // the ternary (expr.odin)
	fill_ref(t, &app, ni, "BLACKNESS")
	fill_op(t, &app, ni, "Compare", "a == b")
	for name in ([]string{"operation", "WHITENESS", "WHITENESS"}) do fill_ref(t, &app, ni, name)
	testing.expect_value(t, line_src(&app, ni), "operation = BLACKNESS if operation == WHITENESS else WHITENESS")
	ni = add_in_body(t, &app, body_line(&app, ni), "Calls", "From import")
	if pick(t, &app, "win32") do pick_leaf(t, &app, "EndPaint", "__call_import_proc__")
	fill_ref(t, &app, ni, "window")
	fill_ref(t, &app, ni, "paint", "&paint   (pointer to it)")
	// case: // Casey logs here too; ...   result = win32.DefWindowProcW(...)
	d := line_with(&app, "case:")
	ni = add_in_body(t, &app, body_line(&app, d), "Layout", "Comment")
	say_comment(t, &app, ni, "Casey logs here too; that gets noisy fast, so I left it out")
	ni = body_line(&app, d)
	assign_to(t, &app, ni, "result")
	fill_call(t, &app, ni, "DefWindowProcW")
	for name in ([]string{"window", "message", "w_param", "l_param"}) do fill_ref(t, &app, ni, name)
	testing.expect_value(t, line_src(&app, ni), "result = win32.DefWindowProcW(window, message, w_param, l_param)")
	// After the switch: a blank line, return result.
	sw_end := line_with(&app, "}", line_with(&app, "result = win32.DefWindowProcW")) // (4-space indents until formatted)
	add_in_body(t, &app, body_line(&app, sw_end), "Layout", "Blank line")
	ni = add_in_body(t, &app, body_line(&app, sw_end), "Jumps and cleanup", "Return")
	fill_ref(t, &app, ni, "result")
	testing.expect_value(t, line_src(&app, ni), "return result")

	// ---- main :: proc() ----
	add_top(t, &app, "Procedures", "Procedure")
	mh := line_with(&app, ":: proc", hdr + 1)
	rename(&app, mh, "main")
	ni = add_in_body(t, &app, body_line(&app, mh), "Declarations", "Variable (:=)")
	rename(&app, ni, "instance")
	// Convert > T(x) > HINSTANCE, then the call inside it (expr.odin).
	if open_dot(t, &app, ni, 0) && pick(t, &app, "Convert") && pick(t, &app, "T(x)") do pick_leaf(t, &app, "HINSTANCE", CONV_FILL)
	fill_call(t, &app, ni, "GetModuleHandleW")
	fill_nil(t, &app, ni)
	testing.expect_value(t, line_src(&app, ni), "instance := win32.HINSTANCE(win32.GetModuleHandleW(nil))")
	add_in_body(t, &app, body_line(&app, mh), "Layout", "Blank line")
	// window_class := win32.WNDCLASSW {...}
	ni = add_in_body(t, &app, body_line(&app, mh), "Declarations", "Variable (:=)")
	rename(&app, ni, "window_class")
	if open_dot(t, &app, ni, 0) && pick(t, &app, "Struct literal") do pick_leaf(t, &app, "WNDCLASSW", LIT_TYPE_FILL)
	if open_dot(t, &app, ni, 0, FIELDS_KIND) do pick(t, &app, "style   UINT")
	fill_op(t, &app, ni, "Bitwise", "a | b")
	fill_const(t, &app, ni, "CS_OWNDC")
	fill_op(t, &app, ni, "Bitwise", "a | b")
	fill_const(t, &app, ni, "CS_HREDRAW")
	fill_const(t, &app, ni, "CS_VREDRAW")
	if open_dot(t, &app, ni, 0, FIELDS_KIND) do pick(t, &app, "lpfnWndProc   WNDPROC")
	fill_ref(t, &app, ni, "main_window_callback")
	if open_dot(t, &app, ni, 0, FIELDS_KIND) do pick(t, &app, "hInstance   HINSTANCE")
	fill_ref(t, &app, ni, "instance")
	if open_dot(t, &app, ni, 0, FIELDS_KIND) do pick(t, &app, "lpszClassName   LPCWSTR")
	fill_wide_string(t, &app, ni, "HandmadeHeroWindowClass")
	add_in_body(t, &app, body_line(&app, mh), "Layout", "Blank line")
	// if win32.RegisterClassW(&window_class) != 0 { ... } else { // TODO logging }
	ifl := add_in_body(t, &app, body_line(&app, mh), "Branching", "If / Else")
	fill_op(t, &app, ifl, "Compare", "a != b")
	fill_call(t, &app, ifl, "RegisterClassW")
	fill_ref(t, &app, ifl, "window_class", "&window_class   (pointer to it)")
	fill_number(t, &app, ifl)
	testing.expect_value(t, line_src(&app, ifl), "if win32.RegisterClassW(&window_class) != 0 {")
	ni = add_in_body(t, &app, body_line(&app, ifl), "Declarations", "Variable (:=)")
	rename(&app, ni, "window_handle")
	fill_call(t, &app, ni, "CreateWindowExW")
	fill_number(t, &app, ni)
	if open_dot(t, &app, ni, 0) && pick(t, &app, "Reference") && ref_choose(t, &app, "window_class") {
		if pick(t, &app, "Field of window_class") do pick(t, &app, "lpszClassName   LPCWSTR")
	}
	fill_wide_string(t, &app, ni, "HandmadeHero")
	fill_op(t, &app, ni, "Bitwise", "a | b")
	fill_const(t, &app, ni, "WS_OVERLAPPEDWINDOW")
	fill_const(t, &app, ni, "WS_VISIBLE")
	for _ in 0 ..< 4 do fill_const(t, &app, ni, "CW_USEDEFAULT")
	fill_nil(t, &app, ni)
	fill_nil(t, &app, ni)
	fill_ref(t, &app, ni, "instance")
	fill_nil(t, &app, ni)
	// The rows: Y on an argument > Join with previous row.
	for k in ([]int{5, 7, 9, 10, 11}) do y_arg(t, &app, ni, k, "Join with previous row")
	add_in_body(t, &app, body_line(&app, ifl), "Layout", "Blank line")
	inner := add_in_body(t, &app, body_line(&app, ifl), "Branching", "If / Else")
	fill_op(t, &app, inner, "Compare", "a != b")
	fill_ref(t, &app, inner, "window_handle")
	fill_nil(t, &app, inner)
	ni = add_in_body(t, &app, body_line(&app, inner), "Declarations", "Variable (no value)")
	rename(&app, ni, "message")
	fill_type(t, &app, ni, 0, "MSG")
	loop := add_in_body(t, &app, body_line(&app, inner), "Loops", "For (condition)")
	fill_op(t, &app, loop, "Compare", "a > b")
	fill_call(t, &app, loop, "GetMessageW")
	fill_ref(t, &app, loop, "message", "&message   (pointer to it)")
	fill_nil(t, &app, loop)
	fill_number(t, &app, loop)
	fill_number(t, &app, loop)
	fill_number(t, &app, loop)
	for name in ([]string{"TranslateMessage", "DispatchMessageW"}) {
		ni = add_in_body(t, &app, body_line(&app, loop), "Calls", "From import")
		if pick(t, &app, "win32") do pick_leaf(t, &app, name, "__call_import_proc__")
		fill_ref(t, &app, ni, "message", "&message   (pointer to it)")
	}
	// The else bodies: // TODO logging
	else_line := line_with(&app, "} else {", loop)
	for _ in 0 ..< 2 {
		ni = add_in_body(t, &app, body_line(&app, else_line), "Layout", "Comment")
		say_comment(t, &app, ni, "TODO logging")
		else_line = line_with(&app, "} else {", else_line + 1)
	}

	drop_body_lines(&app)
	text := expect_stable(t, &app)
	testing.expectf(t, text == HANDMADE_LAYOUT, "saved:\n%s\n--- want ---\n%s", text, HANDMADE_LAYOUT)
	odin_check(t, "handmade_layout", text)
}

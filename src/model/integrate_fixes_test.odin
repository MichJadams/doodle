package model

// Regression tests for the review findings fixed together with the exact
// Handmade build (handmade_exact_build_test.odin): conversions of aliases,
// ternary / operator typing, chain deletes, `when` constants, argument rows,
// body dots after blank lines, comments in switches / data bodies, aligned
// struct literals, saving (no "●" lines, final newline) and the LT+A text tools.

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
	if app.slot_menu != nil { free_entries(app.slot_menu); app.slot_menu = nil }
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
has_label :: proc(app: ^App, label: string) -> bool {
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
		if e.label == label || (strings.has_suffix(label, "*") && strings.has_prefix(e.label, label[:len(label) - 1])) {
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
		if app.state == .Editor && !app.ref_pick_active && !app.mod_pick_active do return
		update(app, Input{cancel = true})
	}
}

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

@(private = "file")
open_dot :: proc(t: ^testing.T, app: ^App, ni, nth: int, kind := "value", loc := #caller_location) -> bool {
	back_out(app)
	fi := dot_index(app, ni, nth, kind)
	if !testing.expectf(t, fi >= 0, "no %s dot #%d on %q", kind, nth, line_src(app, ni), loc = loc) do return false
	focus_field_index(app, ni, fi)
	update(app, Input{confirm = true})
	return true
}

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
	testing.expectf(t, false, "no field %q (#%d) on %q", text, nth, line_src(app, ni), loc = loc)
	return false
}

// The hint of the (first) dot under the cursor's line after a Y.
@(private = "file")
cursor_dot_hint :: proc(app: ^App) -> (string, bool) {
	ni, fi, ok := editor_target(app)
	if ok && app.doc.nodes[ni].fields[fi].slot do return app.doc.nodes[ni].fields[fi].hint, true
	if app.slot_ni >= 0 && app.slot_ni < len(app.doc.nodes) && app.slot_fi >= 0 && app.slot_fi < len(app.doc.nodes[app.slot_ni].fields) {
		f := app.doc.nodes[app.slot_ni].fields[app.slot_fi]
		if f.slot do return f.hint, true
	}
	return "", false
}

// Reference pick mode: left / right to `name`, then A (opens "Pass as").
@(private = "file")
ref_to :: proc(t: ^testing.T, app: ^App, name: string, loc := #caller_location) -> bool {
	if !testing.expect(t, app.ref_pick_active, "in Reference pick mode", loc = loc) do return false
	cur :: proc(app: ^App) -> string {
		ni, fi, ok := editor_target(app)
		return ok ? app.doc.nodes[ni].fields[fi].text : "<none>"
	}
	for _ in 0 ..< 64 { if cur(app) == name do break; update(app, Input{right = true}) }
	for _ in 0 ..< 64 { if cur(app) == name do break; update(app, Input{left = true}) }
	if !testing.expectf(t, cur(app) == name, "%q should be pickable", name, loc = loc) do return false
	update(app, Input{confirm = true})
	return true
}

// ---------------------------------------------------------------------------
// #1 / #5: conversions are exactly the Type menu's types (aliases too, not
// proc aliases or names that merely start with a keyword).

@(test)
test_fix_conv_alias :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nId :: u32\n\nmain :: proc() {\n\tx := 0\n}")
	x := line_with(&app, "x := 0")
	if focus_text(t, &app, x, "0") {
		change_selected(&app)
		if pick(t, &app, "Convert") && pick(t, &app, "T(x)") {
			testing.expectf(t, has_label(&app, "Id"), "Convert > T(x) lists the alias Id: %s", labels(&app))
			pick(t, &app, "Id")
		}
	}
	back_out(&app)
	if fi := dot_index(&app, x, 0); fi >= 0 {
		focus_field_index(&app, x, fi)
		update(&app, Input{confirm = true})
		pick(t, &app, "Number")
	}
	back_out(&app)
	testing.expect_value(t, line_src(&app, x), "x := Id(0)")
	n := app.doc.nodes[x]
	for f, i in n.fields do if f.text == "Id" do testing.expect(t, is_conv_callee(&app, n, i), "Id(...) is a conversion")

	// Saved and reopened: still a conversion; LT+B on Id unwraps the value.
	saved := strings.clone(src(&app), context.temp_allocator)
	load(&app, strings.concatenate({saved, "\n\nf :: proc() {\n\tid := Id(5)\n}"}, context.temp_allocator))
	ty, ok := var_type_at(&app, len(app.doc.nodes) - 1, "id")
	testing.expectf(t, ok && ty.expr == "Id", "id is an Id: %v %v", ty, ok)
	x = line_with(&app, "x := Id(0)")
	if focus_text(t, &app, x, "Id") do delete_selected(&app)
	testing.expect_value(t, line_src(&app, x), "x := 0")
}

@(test)
test_fix_conv_keyword_prefix :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nunion_find :: proc(a: int) -> int {\n\treturn a\n}\n\nuf :: union_find\n\nT :: struct {\n\ta: int,\n}\n\nE :: enum {\n\tA,\n}\n\nU :: union {\n\tint,\n}\n\nD :: distinct int\n\nmain :: proc() {\n\tr := uf(1)\n}")
	_, ok := conversion_type(&app, "uf")
	testing.expect(t, !ok, "a proc alias isn't a type")
	ty, tok := var_type_at(&app, line_with(&app, "r := uf(1)"), "r")
	testing.expectf(t, !(tok && ty.expr == "uf"), "r isn't typed as `uf`: %v", ty)
	for name in ([]string{"T", "E", "U", "D"}) {
		_, cok := conversion_type(&app, name)
		testing.expectf(t, cok, "%s is a type", name)
	}
}

// #2: a ternary's type is its branch's, not its condition's comparison.
@(test)
test_fix_ternary_var_types :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nN :: 5\n\nmain :: proc() {\n\tn := 1\n\tf: f32 = 1\n\ta := n > 3 ? 5 : 6\n\tb := f when N > 3 else f\n\tc := 7 if n > 3 else 8\n}")
	end := len(app.doc.nodes) - 1
	ta, aok := var_type_at(&app, end, "a")
	testing.expectf(t, aok && ta.expr == "int", "a: %v", ta)
	tb, bok := var_type_at(&app, end, "b")
	testing.expectf(t, bok && tb.expr == "f32", "b: %v", tb)
	tc, cok := var_type_at(&app, end, "c")
	testing.expectf(t, cok && tc.expr == "int", "c: %v", tc)
}

// #3: the operands of a mixed chain expect what their own operator needs.
@(test)
test_fix_mixed_chain_operand_expected :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text :: "package main\n\nmain :: proc() {\n\tok := true\n\tn := 1\n\tm: int = 1 if ok && n > 3 else 2\n}"
	load(&app, text)
	m := line_with(&app, "m: int")
	if focus_text(t, &app, m, "3") {
		change_selected(&app)
		h, hok := cursor_dot_hint(&app)
		testing.expectf(t, hok && h == "", "the 3 of `n > 3` expects anything, got %q", h)
		if app.state == .Radial do testing.expect(t, !dimmed(t, &app, "Number"), "Number fits")
	}
	back_out(&app)
	load(&app, text)
	m = line_with(&app, "m: int")
	if focus_text(t, &app, m, "ok") {
		change_selected(&app)
		h, hok := cursor_dot_hint(&app)
		testing.expectf(t, hok && h == "bool", "ok (an operand of &&) expects bool, got %q", h)
	}
	back_out(&app)
	load(&app, text)
	m = line_with(&app, "m: int")
	if focus_text(t, &app, m, "1") {
		change_selected(&app)
		h, hok := cursor_dot_hint(&app)
		testing.expectf(t, hok && h == "int", "the ternary's branch expects int, got %q", h)
	}
	back_out(&app)
}

// #4: LT+B on a dot of a 3-operand chain drops just that operand.
@(test)
test_fix_chain_dot_delete :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text :: "package main\n\nimport win32 \"core:sys/windows\"\n\nmain :: proc() {\n\ts := win32.WNDCLASSW{style = win32.CS_OWNDC | win32.CS_HREDRAW | win32.CS_VREDRAW}\n}"
	load(&app, text)
	s := line_with(&app, "s := ")
	if focus_text(t, &app, s, "win32.CS_HREDRAW") do delete_selected(&app)
	testing.expect_value(t, line_src(&app, s), "s := win32.WNDCLASSW{style = win32.CS_OWNDC |  | win32.CS_VREDRAW}")
	if fi := dot_index(&app, s, 0); fi >= 0 { focus_field_index(&app, s, fi); delete_selected(&app) }
	testing.expect_value(t, line_src(&app, s), "s := win32.WNDCLASSW{style = win32.CS_OWNDC | win32.CS_VREDRAW}")
	out := strings.clone(src(&app), context.temp_allocator)
	load(&app, out)
	testing.expect_value(t, src(&app), out)

	// The first operand.
	load(&app, text)
	s = line_with(&app, "s := ")
	if focus_text(t, &app, s, "win32.CS_OWNDC") do delete_selected(&app)
	if fi := dot_index(&app, s, 0); fi >= 0 { focus_field_index(&app, s, fi); delete_selected(&app) }
	testing.expect_value(t, line_src(&app, s), "s := win32.WNDCLASSW{style = win32.CS_HREDRAW | win32.CS_VREDRAW}")
	// Two operands left: LT+B on a dot turns the operator back into one dot.
	if focus_text(t, &app, s, "win32.CS_VREDRAW") do delete_selected(&app)
	if fi := dot_index(&app, s, 0); fi >= 0 { focus_field_index(&app, s, fi); delete_selected(&app) }
	testing.expect_value(t, line_src(&app, s), "s := win32.WNDCLASSW{style = }")
}

// #6: a `when` condition takes constants only.
@(test)
test_fix_when_condition_constants :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nN :: 5\n\nmain :: proc() {\n\tn := 5\n\tb := false\n}")
	b := line_with(&app, "b := false")
	if focus_text(t, &app, b, "false") {
		change_selected(&app)
		if pick(t, &app, "Operator") && pick(t, &app, "Choose") do pick(t, &app, "a when c else b")
	}
	back_out(&app)
	testing.expect(t, in_when_cond(&app, b, dot_index(&app, b, 1)), "the second dot is the condition")
	testing.expect(t, !in_when_cond(&app, b, dot_index(&app, b, 0)), "the first dot is a branch")
	// The value menu: calls grayed, built-in constants not.
	if open_dot(t, &app, b, 1) {
		testing.expect(t, !dimmed(t, &app, "ODIN_DEBUG"), "ODIN_DEBUG is a constant")
		if v := current_view(&app); v != nil {
			for e in v.entries do if e.label == "Call" do testing.expect(t, e.dim, "calls aren't constants")
		}
		if pick(t, &app, "Reference") && ref_to(t, &app, "n") {
			testing.expect(t, dimmed(t, &app, "n"), "a local variable isn't constant")
		}
	}
	back_out(&app)
	if open_dot(t, &app, b, 1) && pick(t, &app, "Reference") && ref_to(t, &app, "N") {
		testing.expect(t, !dimmed(t, &app, "N"), "N :: 5 is")
	}
	back_out(&app)
	// After Operator > `>`: its left operand still takes constants only.
	if open_dot(t, &app, b, 1) && pick(t, &app, "Operator") && pick(t, &app, "Compare") do pick(t, &app, "a > b")
	back_out(&app)
	if open_dot(t, &app, b, 1) && pick(t, &app, "Reference") && ref_to(t, &app, "n") {
		testing.expect(t, dimmed(t, &app, "n"), "nor in `● > ●` inside the condition")
	}
	back_out(&app)
}

// #7: grouped argument rows of a variadic call survive a reload.
@(test)
test_fix_variadic_rows_round_trip :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text :: "package main\n\nimport \"core:fmt\"\n\nmain :: proc() {\n\tfmt.println(\n\t\t\"aaaaaaaaaaaaaaaaaaaaaaaaa\", \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\n\t\t\"ccccccccccccccccccccccccc\",\n\t)\n}"
	load(&app, text)
	testing.expectf(t, src(&app) == text, "load -> save:\n%s", src(&app))
	format_doc(&app)
	testing.expectf(t, src(&app) == text, "after format_doc:\n%s", src(&app))
}

// #8: every argument joined onto one row stays that way (and loads back).
@(test)
test_fix_join_all_rows :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nimport win32 \"core:sys/windows\"\n\nmain :: proc() {\n\tresult := win32.DefWindowProcW(\n\t\tnil,\n\t\twin32.WM_ACTIVATEAPP,\n\t\twin32.CW_USEDEFAULT,\n\t\twin32.CW_USEDEFAULT,\n\t)\n}")
	r := line_with(&app, "result :=")
	join :: proc(t: ^testing.T, app: ^App, r: int, text: string, nth := 0) {
		if focus_text(t, app, r, text, nth) {
			change_selected(app)
			pick(t, app, "Join with previous row")
		}
		back_out(app)
	}
	join(t, &app, r, "win32.WM_ACTIVATEAPP")
	join(t, &app, r, "win32.CW_USEDEFAULT", 0)
	join(t, &app, r, "win32.CW_USEDEFAULT", 1)
	want :: "package main\n\nimport win32 \"core:sys/windows\"\n\nmain :: proc() {\n\tresult := win32.DefWindowProcW(\n\t\tnil, win32.WM_ACTIVATEAPP, win32.CW_USEDEFAULT, win32.CW_USEDEFAULT,\n\t)\n}"
	testing.expectf(t, src(&app) == want, "joined:\n%s", src(&app))
	if focus_text(t, &app, r, "win32.CW_USEDEFAULT", 1) {
		change_selected(&app)
		testing.expect(t, !has_label(&app, "Join with previous row"), "nothing left to join")
	}
	back_out(&app)
	load(&app, want)
	testing.expectf(t, src(&app) == want, "loaded back:\n%s", src(&app))
}

// #9: a green dot right after a blank line in a body.
@(test)
test_fix_dot_after_blank :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text :: "package main\n\nmain :: proc() {\n\tx := 1\n\n\tx = 2\n}"
	load(&app, text)
	bp := body_points(&app)
	testing.expect(t, bp[5], "a dot before `x = 2`, below the blank line")
	focus_dot_at(&app, 5)
	update(&app, Input{confirm = true})
	if pick(t, &app, "Layout") do pick(t, &app, "Comment")
	back_out(&app)
	c := line_with(&app, "//")
	for f, i in app.doc.nodes[c].fields do if f.kind == COMMENT_KIND do set_field_text(&app, c, i, "above x")
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n\tx := 1\n\n\t// above x\n\tx = 2\n}")
	// LT+B on that dot removes the blank line above it.
	load(&app, text)
	focus_dot_at(&app, 5)
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n\tx := 1\n\tx = 2\n}")
}

// #10: a comment right above a case label keeps the label's indentation.
@(test)
test_fix_format_switch_comment_before_case :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text :: "package main\n\nmain :: proc() {\n\tx := 1\n\tswitch x {\n\t// one\n\tcase 1:\n\t\tx = 2\n\t}\n}"
	load(&app, text)
	format_doc(&app)
	testing.expect_value(t, src(&app), text)
}

// #11: a comment ending in `{` doesn't open a block.
@(test)
test_fix_comment_ending_brace :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tx := 1\n\t// see {\n}")
	focus_dot_at(&app, line_with(&app, "// see {") + 1)
	update(&app, Input{confirm = true})
	if pick(t, &app, "Layout") do pick(t, &app, "Comment")
	back_out(&app)
	c := line_with(&app, "// see {") + 1
	for f, i in app.doc.nodes[c].fields do if f.kind == COMMENT_KIND do set_field_text(&app, c, i, "two")
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n\tx := 1\n\t// see {\n\t// two\n}")

	text :: "package main\n\nmain :: proc() {\n\tx := 1\n\t// see the block below {\n\n\tx = 2\n}"
	load(&app, text)
	format_doc(&app)
	testing.expect_value(t, src(&app), text)
}

// #12: Layout (Comment, Blank line) in a struct body.
@(test)
test_fix_struct_body_layout :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nPlayer :: struct {\n\thp: int,\n\tname: string,\n}")
	focus_dot_at(&app, line_with(&app, "name: string"))
	update(&app, Input{confirm = true})
	testing.expectf(t, has_label(&app, "Layout"), "the struct body menu has Layout: %s", labels(&app))
	if pick(t, &app, "Layout") do pick(t, &app, "Comment")
	back_out(&app)
	c := line_with(&app, "//")
	if testing.expect(t, c >= 0, "a comment line") {
		for f, i in app.doc.nodes[c].fields do if f.kind == COMMENT_KIND do set_field_text(&app, c, i, "the name")
	}
	want :: "package main\n\nPlayer :: struct {\n\thp: int,\n\t// the name\n\tname: string,\n}"
	testing.expect_value(t, src(&app), want)
	format_doc(&app)
	testing.expect_value(t, src(&app), want)
}

// #13: a loaded aligned literal stays aligned after adding / removing a field.
@(test)
test_fix_aligned_literal_edit :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text :: "package main\n\nimport win32 \"core:sys/windows\"\n\nmain :: proc() {\n\twindow_class := win32.WNDCLASSW {\n\t\tstyle         = win32.CS_OWNDC,\n\t\thInstance     = nil,\n\t\tlpszClassName = win32.L(\"X\"),\n\t}\n}"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	w := line_with(&app, "window_class :=")
	if open_dot(t, &app, w, 0, FIELDS_KIND) && pick(t, &app, "hCursor*") {
		if open_dot(t, &app, w, 0) do pick(t, &app, "nil")
	}
	back_out(&app)
	format_doc(&app)
	testing.expectf(t, strings.contains(src(&app), "\t\tlpszClassName = win32.L(\"X\"),\n\t\thCursor       = nil,\n"), "hCursor aligned:\n%s", src(&app))
	if focus_text(t, &app, w, "lpszClassName") do delete_selected(&app)
	back_out(&app)
	testing.expectf(t, strings.contains(src(&app), "\t\tstyle     = win32.CS_OWNDC,\n\t\thInstance = nil,\n\t\thCursor   = nil,\n"), "re-padded:\n%s", src(&app))
	// An unaligned loaded literal keeps its spacing.
	plain :: "package main\n\nimport win32 \"core:sys/windows\"\n\nmain :: proc() {\n\twindow_class := win32.WNDCLASSW {\n\t\tstyle = win32.CS_OWNDC,\n\t\thInstance = nil,\n\t}\n}"
	load(&app, plain)
	format_doc(&app)
	testing.expect_value(t, src(&app), plain)
}

// #14 / #15: what a save writes - no editor-only "●" lines next to real
// statements (a block's only "●" stays as its blank line), a final newline
// unless the opened file had none.
@(test)
test_fix_file_text :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tx := 1\n\tif x > 0 {\n\t\tx = 2\n\t}\n}\n")
	testing.expect(t, !app.doc.no_final_newline, "the file ended in a newline")
	// "●" lines as the editor leaves them after filling blocks.
	slot_line :: proc(ind: string) -> Node {
		n: Node
		append(&n.fields, Field{strings.clone(ind), false, false, "", "", ""}, Field{"", false, true, "body", "", ""})
		return n
	}
	inject_at(&app.doc.nodes, line_with(&app, "\t\tx = 2") + 1, slot_line("\t\t"))
	inject_at(&app.doc.nodes, line_with(&app, "\tx := 1") + 1, slot_line("\t"))
	want :: "package main\n\nmain :: proc() {\n\tx := 1\n\tif x > 0 {\n\t\tx = 2\n\t}\n}\n"
	got := file_text(&app, context.temp_allocator)
	testing.expectf(t, got == want, "saved:\n%q", got)
	testing.expect(t, line_with(&app, "x := 1") + 1 < len(app.doc.nodes) && is_body_slot_line(app.doc.nodes[line_with(&app, "x := 1") + 1]), "the live document keeps its dots")
	// Saved again after reopening: the same.
	load(&app, got)
	testing.expect_value(t, file_text(&app, context.temp_allocator), want)
	// A block's only "●" is written as its blank line.
	load(&app, "package main\n\nf :: proc() {\n}\n")
	inject_at(&app.doc.nodes, line_with(&app, "f :: proc") + 1, slot_line("\t"))
	testing.expect_value(t, save_source(&app, context.temp_allocator), "package main\n\nf :: proc() {\n\n}")
	// A file without a final newline is saved without one.
	load(&app, "package main\n\nX :: 1")
	testing.expect_value(t, file_text(&app, context.temp_allocator), "package main\n\nX :: 1")
	// A new document gets one.
	doc_reset(&app)
	load(&app, "")
	append(&app.doc.nodes, Node{})
	append(&app.doc.nodes[0].fields, Field{strings.clone("package "), false, false, "", "", ""}, Field{strings.clone("x"), true, false, "", "", ""})
	testing.expect_value(t, file_text(&app, context.temp_allocator), "package x\n")
}

// #16: the LT+A text tools.
@(test)
test_fix_text_tools :: proc(t: ^testing.T) {
	testing.expect_value(t, recase("whiteness", .Upper_Snake, context.temp_allocator), "WHITENESS")
	testing.expect_value(t, recase("handmade hero window class", .Pascal, context.temp_allocator), "HandmadeHeroWindowClass")
	testing.expect_value(t, recase("wm size", .Upper_Snake, context.temp_allocator), "WM_SIZE")
	testing.expect_value(t, recase("HandmadeHero", .Snake, context.temp_allocator), "handmade_hero")
	testing.expect_value(t, recase("main window callback", .Camel, context.temp_allocator), "mainWindowCallback")
	testing.expect_value(t, recase("player_state", .Ada_Case, context.temp_allocator), "Player_State")
	testing.expect_value(t, recase("wm size", .Joined, context.temp_allocator), "wmsize")
	testing.expect_value(t, text_tool_apply("WM_SIZE", "esc", `\n`), `WM_SIZE\n`)
	testing.expect_value(t, text_tool_apply("a static dword op b", "wcase:2", "upper"), "a static DWORD op b")
	testing.expect_value(t, text_tool_apply("a static DWORD op b", "tick:1:3", ""), "a `static DWORD op` b")

	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nwhiteness :: 1\n\n// todo later\nmain :: proc() {\n}")
	c := line_with(&app, "whiteness ::")
	if focus_text(t, &app, c, "whiteness") {
		edit_selected(&app)
		testing.expect(t, app.state == .Radial, "LT+A on a name opens the text tools")
		if pick(t, &app, "Case") do pick(t, &app, "UPPER_SNAKE")
		testing.expect(t, app.state == .Editor, "and closes them")
	}
	testing.expect_value(t, line_src(&app, c), "WHITENESS :: 1")
	cm := line_with(&app, "// todo")
	if focus_text(t, &app, cm, "todo later") {
		edit_selected(&app)
		if pick(t, &app, "Word case") && pick(t, &app, "todo") do pick(t, &app, "UPPER")
	}
	back_out(&app)
	testing.expect_value(t, line_src(&app, cm), "// TODO later")
}

package model

import "core:strings"
import "core:testing"

@(private = "file")
MAIN_SRC :: "package handmade\n\nimport win32 \"core:sys/windows\"\n\n" +
	"main_window_callback :: proc \"system\" (window: win32.HWND, message: win32.UINT, w_param: win32.WPARAM, l_param: win32.LPARAM) -> win32.LRESULT {\n" +
	"\treturn win32.DefWindowProcW(window, message, w_param, l_param)\n" +
	"}\n\n" +
	"main :: proc() {\n" +
	"\tinstance := win32.HINSTANCE(win32.GetModuleHandleW(nil))\n" +
	"}"

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
line_with :: proc(app: ^App, text: string) -> int {
	for n, i in app.doc.nodes do if strings.contains(node_text(n, context.temp_allocator), text) do return i
	return -1
}

// Load `src` and add an empty statement line ("●") after the line containing `after`.
@(private = "file")
setup :: proc(app: ^App, src, after: string) {
	app.state = .Editor
	doc_from_source(app, src)
	body: Node
	append(&body.fields, Field{strings.clone("\t"), false, false, "", "", ""})
	append(&body.fields, Field{"", false, true, "body", "", ""})
	inject_at(&app.doc.nodes, line_with(app, after) + 1, body)
}

@(private = "file")
body_line :: proc(app: ^App) -> int {
	for n, i in app.doc.nodes do if is_body_slot_line(n) do return i
	return -1
}

@(private = "file")
pick :: proc(t: ^testing.T, app: ^App, label: string, loc := #caller_location) {
	v := current_view(app)
	if v == nil { testing.expectf(t, false, "no menu open (wanted %q)", label, loc = loc); return }
	for e, i in v.entries {
		if e.label == label {
			v.index = i
			update(app, Input{confirm = true})
			return
		}
	}
	testing.expectf(t, false, "no %q in menu %q: %v", label, v.title, labels(app), loc = loc)
}

@(private = "file")
labels :: proc(app: ^App) -> string {
	out := make([dynamic]string, context.temp_allocator)
	for e in current_view(app).entries do append(&out, e.label)
	return strings.join(out[:], " | ", context.temp_allocator)
}

@(private = "file")
path_to :: proc(entries: []Entry, label, fill: string, out: ^[dynamic]string) -> bool {
	for e in entries {
		append(out, e.label)
		if len(e.children) == 0 && e.label == label && (fill == "" || e.fill == fill) do return true
		if len(e.children) > 0 && path_to(e.children, label, fill, out) do return true
		pop(out)
	}
	return false
}

@(private = "file")
pick_leaf :: proc(t: ^testing.T, app: ^App, label: string, fill := "", loc := #caller_location) {
	p := make([dynamic]string, 0, 8, context.temp_allocator)
	if !testing.expectf(t, path_to(current_view(app).entries, label, fill, &p), "%s should be reachable", label, loc = loc) do return
	for step in p do pick(t, app, step, loc)
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
add_statement :: proc(t: ^testing.T, app: ^App, group, label: string) -> int {
	ni := body_line(app)
	focus_field_index(app, ni, 1)
	update(app, Input{confirm = true})
	pick(t, app, group)
	pick(t, app, label)
	return ni
}

@(private = "file")
rename :: proc(app: ^App, ni: int, name: string) {
	for f, i in app.doc.nodes[ni].fields do if f.editable { set_field_text(app, ni, i, name); return }
}

// A on the nth unfilled dot of `kind` on line ni.
@(private = "file")
open_dot :: proc(app: ^App, ni, nth: int, kind := "value") {
	seen := 0
	for f, i in app.doc.nodes[ni].fields {
		if f.slot && f.kind == kind {
			if seen == nth { focus_field_index(app, ni, i); break }
			seen += 1
		}
	}
	update(app, Input{confirm = true})
}

@(private = "file")
cursor_name :: proc(app: ^App) -> string {
	ni, fi, ok := editor_target(app)
	if !ok do return "<none>"
	return app.doc.nodes[ni].fields[fi].text
}

@(private = "file")
ref_choose :: proc(t: ^testing.T, app: ^App, name: string, loc := #caller_location) {
	for _ in 0 ..< 64 {
		if cursor_name(app) == name do break
		update(app, Input{left = true})
	}
	testing.expect_value(t, cursor_name(app), name, loc = loc)
	update(app, Input{confirm = true})
}

@(private = "file")
set_string :: proc(app: ^App, ni: int, text: string) {
	for f, i in app.doc.nodes[ni].fields do if f.editable && f.kind == "string" && f.text == "" { set_field_text(app, ni, i, text); return }
}

@(private = "file")
fill_number :: proc(t: ^testing.T, app: ^App, ni: int) {
	open_dot(app, ni, 0)
	pick(t, app, "Number")
}

@(private = "file")
fill_nil :: proc(t: ^testing.T, app: ^App, ni: int) {
	open_dot(app, ni, 0)
	pick(t, app, "nil")
}

// What test_build_window_class saves (`odin check` accepts it).
WNDCLASS_SRC :: "package handmade\n\nimport win32 \"core:sys/windows\"\n\n" +
	"main_window_callback :: proc \"system\" (window: win32.HWND, message: win32.UINT, w_param: win32.WPARAM, l_param: win32.LPARAM) -> win32.LRESULT {\n" +
	"\treturn win32.DefWindowProcW(window, message, w_param, l_param)\n" +
	"}\n\n" +
	"main :: proc() {\n" +
	"\tinstance := win32.HINSTANCE(win32.GetModuleHandleW(nil))\n" +
	"\twindow_class := win32.WNDCLASSW {\n" +
	"\t\tstyle         = win32.CS_OWNDC | win32.CS_HREDRAW | win32.CS_VREDRAW,\n" +
	"\t\tlpfnWndProc   = main_window_callback,\n" +
	"\t\thInstance     = instance,\n" +
	"\t\tlpszClassName = win32.L(\"HandmadeHeroWindowClass\"),\n" +
	"\t}\n" +
	"\twin32.RegisterClassW(&window_class)\n" +
	"\twindow_handle := win32.CreateWindowExW(\n" +
	"\t\t0,\n" +
	"\t\twindow_class.lpszClassName,\n" +
	"\t\twin32.L(\"HandmadeHero\"),\n" +
	"\t\t0,\n\t\t0,\n\t\t0,\n\t\t0,\n\t\t0,\n" +
	"\t\tnil,\n\t\tnil,\n" +
	"\t\tinstance,\n" +
	"\t\tnil,\n" +
	"\t)\n" +
	"}"

@(test)
test_build_window_class :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app, MAIN_SRC, "instance :=")

	// window_class := win32.WNDCLASSW{●}
	ni := add_statement(t, &app, "Declarations", "Variable (:=)")
	rename(&app, ni, "window_class")
	open_dot(&app, ni, 0)
	pick(t, &app, "Struct literal")
	pick_leaf(t, &app, "WNDCLASSW", LIT_TYPE_FILL)
	testing.expect_value(t, node_source(app.doc.nodes[ni], context.temp_allocator), "\twindow_class := win32.WNDCLASSW{}")
	_, fi, _ := editor_target(&app)
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].kind, FIELDS_KIND) // the cursor is on the fields dot

	// The fields dot: the fields with their types.
	update(&app, Input{confirm = true})
	testing.expect_value(t, labels(&app), "style   UINT | lpfnWndProc   WNDPROC | cbClsExtra   c_int | cbWndExtra   c_int | " +
		"hInstance   HINSTANCE | hIcon   HICON | hCursor   HCURSOR | hbrBackground   HBRUSH | lpszMenuName   LPCWSTR | lpszClassName   LPCWSTR")
	pick(t, &app, "style   UINT")
	_, fi, _ = editor_target(&app)
	testing.expect(t, app.doc.nodes[ni].fields[fi].slot && app.doc.nodes[ni].fields[fi].hint == "UINT", "on the style value dot")

	// style = win32.CS_OWNDC | win32.CS_HREDRAW | win32.CS_VREDRAW
	update(&app, Input{confirm = true})
	e, _ := find(current_view(&app).entries, "true")
	testing.expect(t, e.dim, "a bool isn't a UINT")
	pick(t, &app, "Operator"); pick(t, &app, "Bitwise"); pick(t, &app, "a | b")
	open_dot(&app, ni, 0); pick(t, &app, "Constant"); pick_leaf(t, &app, "CS_OWNDC", CONST_IMPORT_FILL)
	open_dot(&app, ni, 0); pick(t, &app, "Operator"); pick(t, &app, "Bitwise"); pick(t, &app, "a | b")
	open_dot(&app, ni, 0); pick(t, &app, "Constant"); pick_leaf(t, &app, "CS_HREDRAW", CONST_IMPORT_FILL)
	open_dot(&app, ni, 0); pick(t, &app, "Constant"); pick_leaf(t, &app, "CS_VREDRAW", CONST_IMPORT_FILL)

	// lpfnWndProc = main_window_callback
	open_dot(&app, ni, 0, FIELDS_KIND)
	testing.expect(t, !strings.contains(labels(&app), "style"), "style is set already")
	pick(t, &app, "lpfnWndProc   WNDPROC")
	update(&app, Input{confirm = true})
	pick(t, &app, "Reference")
	ref_choose(t, &app, "main_window_callback")
	pick(t, &app, "main_window_callback")

	// hInstance = instance
	open_dot(&app, ni, 0, FIELDS_KIND)
	pick(t, &app, "hInstance   HINSTANCE")
	update(&app, Input{confirm = true})
	pick(t, &app, "Reference")
	ref_choose(t, &app, "instance")
	pick(t, &app, "instance")

	// lpszClassName = win32.L("HandmadeHeroWindowClass")
	open_dot(&app, ni, 0, FIELDS_KIND)
	pick(t, &app, "lpszClassName   LPCWSTR")
	update(&app, Input{confirm = true})
	pick(t, &app, "Call"); pick(t, &app, "From import"); pick(t, &app, "win32"); pick_leaf(t, &app, "L", "__call_import_proc__")
	open_dot(&app, ni, 0); pick(t, &app, "String"); pick(t, &app, "\"...\"  string")
	set_string(&app, ni, "HandmadeHeroWindowClass")

	// win32.RegisterClassW(&window_class)
	ri := add_statement(t, &app, "Calls", "From import")
	pick(t, &app, "win32"); pick_leaf(t, &app, "RegisterClassW", "__call_import_proc__")
	open_dot(&app, ri, 0)
	pick(t, &app, "Reference")
	ref_choose(t, &app, "window_class")
	pick(t, &app, "&window_class   (pointer to it)")

	// window_handle := win32.CreateWindowExW(0, window_class.lpszClassName, ...)
	ci := add_statement(t, &app, "Declarations", "Variable (:=)")
	rename(&app, ci, "window_handle")
	open_dot(&app, ci, 0)
	pick(t, &app, "Call"); pick(t, &app, "From import"); pick(t, &app, "win32"); pick_leaf(t, &app, "CreateWindowExW", "__call_import_proc__")
	fill_number(t, &app, ci)
	open_dot(&app, ci, 0) // lpClassName: LPCWSTR
	pick(t, &app, "Reference")
	ref_choose(t, &app, "window_class")
	pick(t, &app, "Field of window_class")
	ce, _ := find(current_view(&app).entries, "lpszClassName   LPCWSTR")
	testing.expect(t, !ce.dim, "an LPCWSTR fits")
	ce, _ = find(current_view(&app).entries, "style   UINT")
	testing.expect(t, ce.dim, "a UINT doesn't")
	pick(t, &app, "lpszClassName   LPCWSTR")
	open_dot(&app, ci, 0)
	pick(t, &app, "Call"); pick(t, &app, "From import"); pick(t, &app, "win32"); pick_leaf(t, &app, "L", "__call_import_proc__")
	open_dot(&app, ci, 0); pick(t, &app, "String"); pick(t, &app, "\"...\"  string")
	set_string(&app, ci, "HandmadeHero")
	for _ in 0 ..< 5 do fill_number(t, &app, ci)
	fill_nil(t, &app, ci); fill_nil(t, &app, ci)
	open_dot(&app, ci, 0)
	pick(t, &app, "Reference")
	ref_choose(t, &app, "instance")
	pick(t, &app, "instance")
	fill_nil(t, &app, ci)

	focus_field_index(&app, body_line(&app), 1)
	delete_selected(&app)
	format_doc(&app)
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), WNDCLASS_SRC)

	// Loading the saved file gives the same structure back.
	doc_from_source(&app, WNDCLASS_SRC)
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), WNDCLASS_SRC)
	li := line_with(&app, "window_class := ")
	keys := 0
	for f in app.doc.nodes[li].fields do if f.kind == LIT_KEY_KIND do keys += 1
	testing.expect_value(t, keys, 4)
	dots := 0
	for f in app.doc.nodes[li].fields do if f.slot && f.kind == FIELDS_KIND do dots += 1
	testing.expect_value(t, dots, 1) // six fields are still unset
}

// An untouched literal is saved as T{}; LT+B removes a field (and the fields dot
// comes back); Y on a field's value refills it, expecting the field's type.
@(test)
test_literal_edit_and_delete :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app, MAIN_SRC, "instance :=")
	ni := add_statement(t, &app, "Declarations", "Variable (:=)")
	rename(&app, ni, "r")
	open_dot(&app, ni, 0)
	pick(t, &app, "Struct literal")
	pick_leaf(t, &app, "RECT", LIT_TYPE_FILL)
	testing.expect_value(t, node_source(app.doc.nodes[ni], context.temp_allocator), "\tr := win32.RECT{}")

	for name in ([]string{"left   LONG", "top   LONG", "right   LONG", "bottom   LONG"}) {
		open_dot(&app, ni, 0, FIELDS_KIND)
		pick(t, &app, name)
		open_dot(&app, ni, 0)
		pick(t, &app, "Number")
	}
	testing.expect_value(t, node_source(app.doc.nodes[ni], context.temp_allocator), "\tr := win32.RECT{left = 0, top = 0, right = 0, bottom = 0}")
	for f in app.doc.nodes[ni].fields do testing.expect(t, !(f.slot && f.kind == FIELDS_KIND), "all fields set: no fields dot")

	// D-pad: the type, then each field's name and value.
	leaves := make([dynamic]string, context.temp_allocator)
	for u in line_leaves(app.doc.nodes[ni]) do append(&leaves, app.doc.nodes[ni].fields[u.fa].text)
	testing.expect_value(t, strings.join(leaves[:], " ", context.temp_allocator), "r  :=  win32.RECT left 0 top 0 right 0 bottom 0")

	// LT+B on `top`: gone, and a fields dot is back.
	for f, i in app.doc.nodes[ni].fields do if f.text == "top" { focus_field_index(&app, ni, i); break }
	delete_selected(&app)
	testing.expect_value(t, node_source(app.doc.nodes[ni], context.temp_allocator), "\tr := win32.RECT{left = 0, right = 0, bottom = 0}")
	open_dot(&app, ni, 0, FIELDS_KIND)
	testing.expect_value(t, labels(&app), "top   LONG")
	update(&app, Input{cancel = true})

	// LT+B on the last field's value.
	k := 0
	for f, i in app.doc.nodes[ni].fields do if f.text == "0" { k += 1; if k == 3 { focus_field_index(&app, ni, i); break } }
	delete_selected(&app)
	testing.expect_value(t, node_source(app.doc.nodes[ni], context.temp_allocator), "\tr := win32.RECT{left = 0, right = 0}")

	// Y on `right`'s value: the fill menu for a LONG; B puts it back.
	for f, i in app.doc.nodes[ni].fields do if f.text == "right" { focus_field_index(&app, ni, i + 2); break }
	change_selected(&app)
	testing.expect_value(t, app.state, State.Radial)
	_, fi, _ := editor_target(&app)
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].hint, "LONG")
	e, _ := find(current_view(&app).entries, "true")
	testing.expect(t, e.dim, "a bool isn't a LONG")
	update(&app, Input{cancel = true})
	testing.expect_value(t, node_source(app.doc.nodes[ni], context.temp_allocator), "\tr := win32.RECT{left = 0, right = 0}")

	// A literal as a call argument: RegisterClassW expects a pointer, so no literal fits.
	ri := add_statement(t, &app, "Calls", "From import")
	pick(t, &app, "win32"); pick_leaf(t, &app, "RegisterClassW", "__call_import_proc__")
	open_dot(&app, ri, 0)
	e, _ = find(current_view(&app).entries, "Struct literal")
	testing.expect(t, e.dim, "a ^WNDCLASSW dot takes no struct literal")
	update(&app, Input{cancel = true})
	// ...but a dot expecting a RECT offers RECT first.
	n := &app.doc.nodes[ri]
	for &f in n.fields do if f.slot && f.kind == "value" { f.hint, f.hint_pkg = "RECT", "core:sys/windows" }
	open_dot(&app, ri, 0)
	pick(t, &app, "Struct literal")
	testing.expect_value(t, current_view(&app).entries[0].label, "win32.RECT")
	pick(t, &app, "win32.RECT")
	testing.expect(t, strings.contains(node_source(app.doc.nodes[ri], context.temp_allocator), "win32.RegisterClassW(win32.RECT{})"))
	// The literal inside the call: its fields dot works there too.
	open_dot(&app, ri, 0, FIELDS_KIND)
	pick(t, &app, "left   LONG")
	testing.expect(t, strings.contains(node_source(app.doc.nodes[ri], context.temp_allocator), "win32.RegisterClassW(win32.RECT{left = })"))
}

// Struct literals load structured and come back exactly as written.
@(test)
test_literals_round_trip :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	src := "package main\n\nimport win32 \"core:sys/windows\"\n\n" +
		"Inner :: struct { a: int, b: int }\n\n" +
		"Outer :: struct {\n\tinner: Inner,\n\tc: int,\n}\n\n" +
		"make_outer :: proc() -> Outer {\n" +
		"\treturn Outer{inner = Inner{a = 1}, c = 2}\n" +
		"}\n\n" +
		"main :: proc() {\n" +
		"\tr := win32.RECT{left = 1, top = 2}\n" +
		"\tempty := win32.RECT{}\n" +
		"\tshort := win32.POINT{\n\t\tx = 1,\n\t}\n" +
		"\twindow_class := win32.WNDCLASSW {\n" +
		"\t\tstyle         = win32.CS_OWNDC | win32.CS_HREDRAW | win32.CS_VREDRAW,\n" +
		"\t\tlpfnWndProc   = nil,\n" +
		"\t\tlpszClassName = win32.L(\"HandmadeHeroWindowClass\"),\n" +
		"\t}\n" +
		"\twin32.FillRect(nil, nil, nil)\n" +
		"\tinvalid := win32.InvalidateRect(nil, nil, win32.BOOL(false))\n" +
		"\tpt := win32.MSG{pt = win32.POINT{x = 1, y = 2}, message = }\n" +
		"\tr.left = 5\n" +
		"\tmade := make_outer_from(Inner{a = 1}, 2)\n" +
		"\tgrid := [3]int{1, 2, 3}\n" +
		"\tpos := Inner{1, 2}\n" +
		"\tcolor := Inner{a = 1,b = 2}\n" +
		"}"
	app.state = .Editor
	doc_from_source(&app, src)
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), src)
	format_doc(&app)
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), src)

	has_kind :: proc(app: ^App, ni: int, kind: string) -> int {
		c := 0
		for f in app.doc.nodes[ni].fields do if f.kind == kind do c += 1
		return c
	}
	testing.expect_value(t, has_kind(&app, line_with(&app, "return Outer{"), LIT_KEY_KIND), 3) // inner, a, c
	testing.expect_value(t, has_kind(&app, line_with(&app, "r := win32.RECT"), LIT_KEY_KIND), 2)
	testing.expect_value(t, has_kind(&app, line_with(&app, "short :="), LIT_KEY_KIND), 1)
	testing.expect_value(t, has_kind(&app, line_with(&app, "window_class :="), LIT_KEY_KIND), 3)
	testing.expect_value(t, has_kind(&app, line_with(&app, "pt :="), LIT_KEY_KIND), 4)
	testing.expect_value(t, has_kind(&app, line_with(&app, "made :="), LIT_KEY_KIND), 1) // a call's argument
	testing.expect_value(t, has_kind(&app, line_with(&app, "made :="), FIELDS_KIND), 1)
	testing.expect_value(t, has_kind(&app, line_with(&app, "grid :="), LIT_KEY_KIND), 0) // positional: plain text
	testing.expect_value(t, has_kind(&app, line_with(&app, "pos :="), LIT_KEY_KIND), 0)
	testing.expect_value(t, has_kind(&app, line_with(&app, "color :="), LIT_KEY_KIND), 0) // not as Doodle writes it
	// Fields dots where fields are left (Inner{a = 1} lacks b; RECT lacks right/bottom).
	testing.expect_value(t, has_kind(&app, line_with(&app, "return Outer{"), FIELDS_KIND), 1)
	testing.expect_value(t, has_kind(&app, line_with(&app, "r := win32.RECT"), FIELDS_KIND), 1)
	testing.expect_value(t, has_kind(&app, line_with(&app, "empty :="), FIELDS_KIND), 1)
	// The empty `message = ` loaded as a dot expecting a UINT.
	pi := line_with(&app, "pt :=")
	found := false
	for f in app.doc.nodes[pi].fields do if f.slot && f.kind == "value" { found = true; testing.expect_value(t, f.hint, "UINT") }
	testing.expect(t, found, "message's value is a dot")
	// The field target of `r.left = 5` is a name.
	testing.expect(t, is_assign_target(app.doc.nodes[line_with(&app, "r.left = 5")], 1))
}

package model

import "core:strings"
import "core:testing"

// A Win32 window callback with an empty body, as the user would have it
// before adding the WM_PAINT code.
@(private = "file")
SKELETON :: "package handmade\n\nimport win32 \"core:sys/windows\"\n\n" +
	"WHITENESS :: 0x00FF0062\n\n" +
	"operation: u32 = WHITENESS\n\n" +
	"main_window_callback :: proc \"system\" (\n" +
	"\twindow: win32.HWND,\n" +
	"\tmessage: win32.UINT,\n" +
	"\tw_param: win32.WPARAM,\n" +
	"\tl_param: win32.LPARAM,\n" +
	") -> win32.LRESULT {\n" +
	"\tresult: win32.LRESULT = 0\n" +
	"\treturn result\n" +
	"}\n"

@(private = "file")
cleanup :: proc(app: ^App) {
	clear_nav(app)
	delete(app.nav)
	doc_reset(app)
	delete(app.doc.nodes)
	delete(app.recent_imports)
	free_menus(app)
}

// Load `src` and put an empty statement line ("●") before the line containing `before`.
@(private = "file")
setup :: proc(app: ^App, src, before: string) {
	app.state = .Editor
	doc_from_source(app, src)
	at := line_with(app, before)
	body: Node
	append(&body.fields, Field{strings.clone("\t"), false, false, "", "", ""})
	append(&body.fields, Field{"", false, true, "body", "", ""})
	inject_at(&app.doc.nodes, at, body)
}

@(private = "file")
line_with :: proc(app: ^App, text: string) -> int {
	for n, i in app.doc.nodes do if strings.contains(node_text(n, context.temp_allocator), text) do return i
	return -1
}

// The empty statement line ("●").
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
	labels := make([dynamic]string, context.temp_allocator)
	for e in v.entries do append(&labels, e.label)
	testing.expectf(t, false, "no %q in menu %q: %v", label, v.title, labels[:], loc = loc)
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

// From the current view, walk down to the leaf `label`.
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
dimmed :: proc(t: ^testing.T, app: ^App, label: string, loc := #caller_location) -> bool {
	e, ok := find(current_view(app).entries, label)
	testing.expectf(t, ok, "menu entry %q should exist", label, loc = loc)
	return e.dim
}

// A on the statement line's dot, then a statement from the menu.
@(private = "file")
add_statement :: proc(t: ^testing.T, app: ^App, group, label: string) -> int {
	ni := body_line(app)
	focus_field_index(app, ni, 1)
	update(app, Input{confirm = true})
	pick(t, app, group)
	pick(t, app, label)
	return ni
}

// Name the line's first name (what dictation does).
@(private = "file")
rename :: proc(app: ^App, ni: int, name: string) {
	for f, i in app.doc.nodes[ni].fields do if f.editable { set_field_text(app, ni, i, name); return }
}

// A on the nth unfilled value dot of line ni.
@(private = "file")
open_value :: proc(app: ^App, ni, nth: int) {
	seen := 0
	for f, i in app.doc.nodes[ni].fields {
		if f.slot && f.kind == "value" {
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

// In Reference pick mode: D-pad until `name` is highlighted, then A.
@(private = "file")
ref_choose :: proc(t: ^testing.T, app: ^App, name: string, loc := #caller_location) {
	testing.expect(t, app.ref_pick_active, "in pick mode", loc = loc)
	for _ in 0 ..< 64 {
		if cursor_name(app) == name do break
		update(app, Input{left = true})
	}
	testing.expect_value(t, cursor_name(app), name, loc = loc)
	update(app, Input{confirm = true})
}

@(private = "file")
line_src :: proc(app: ^App, ni: int) -> string {
	return strings.trim_space(node_source(app.doc.nodes[ni], context.temp_allocator))
}

@(test)
test_build_wm_paint_statements :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app, SKELETON, "return result")

	// paint: win32.PAINTSTRUCT   ("Variable (no value)", then its type)
	ni := add_statement(t, &app, "Declarations", "Variable (no value)")
	rename(&app, ni, "paint")
	for f, i in app.doc.nodes[ni].fields do if f.slot && f.kind == "type" { focus_field_index(&app, ni, i); break }
	update(&app, Input{confirm = true})
	pick(t, &app, "Type")
	pick_leaf(t, &app, "PAINTSTRUCT", TYPE_IMPORT_FILL)
	testing.expect_value(t, line_src(&app, ni), "paint: win32.PAINTSTRUCT")

	// device_context := win32.BeginPaint(window, &paint)
	ni = add_statement(t, &app, "Declarations", "Variable (:=)")
	rename(&app, ni, "device_context")
	open_value(&app, ni, 0)
	pick(t, &app, "Call")
	pick(t, &app, "From import")
	pick(t, &app, "win32")
	pick_leaf(t, &app, "BeginPaint", "__call_import_proc__")
	open_value(&app, ni, 0) // hWnd: the callback's parameter
	pick(t, &app, "Reference")
	ref_choose(t, &app, "window")
	pick(t, &app, "window")
	open_value(&app, ni, 0) // lpPaint: ^PAINTSTRUCT
	pick(t, &app, "Reference")
	ref_choose(t, &app, "paint")
	testing.expect_value(t, current_view(&app).title, "Pass as")
	testing.expect(t, !dimmed(t, &app, "&paint   (pointer to it)"), "&paint fits ^PAINTSTRUCT")
	testing.expect(t, dimmed(t, &app, "Field of paint"), "no field of paint is a PAINTSTRUCT")
	pick(t, &app, "&paint   (pointer to it)")
	testing.expect_value(t, line_src(&app, ni), "device_context := win32.BeginPaint(window, &paint)")

	// x := paint.rcPaint.left   (Reference -> paint -> Field of paint -> rcPaint -> left)
	ni = add_statement(t, &app, "Declarations", "Variable (:=)")
	rename(&app, ni, "x")
	open_value(&app, ni, 0)
	pick(t, &app, "Reference")
	ref_choose(t, &app, "paint")
	pick(t, &app, "Field of paint")
	labels := make([dynamic]string, context.temp_allocator)
	for e in current_view(&app).entries do append(&labels, e.label)
	testing.expect_value(t, strings.join(labels[:], " | ", context.temp_allocator),
		"hdc   HDC | fErase   BOOL | rcPaint   RECT | fRestore   BOOL | fIncUpdate   BOOL | rgbReserved   [32]BYTE | paint.rgbReserved[i]   BYTE")
	pick(t, &app, "rcPaint   RECT")
	testing.expect_value(t, current_view(&app).entries[0].label, "paint.rcPaint") // the field itself first
	pick(t, &app, "left   LONG")
	testing.expect_value(t, line_src(&app, ni), "x := paint.rcPaint.left")
	testing.expect(t, !app.ref_pick_active && app.state == .Editor)

	// width := paint.rcPaint.right - paint.rcPaint.left
	ni = add_statement(t, &app, "Declarations", "Variable (:=)")
	rename(&app, ni, "width")
	open_value(&app, ni, 0)
	pick(t, &app, "Operator")
	pick(t, &app, "Arithmetic")
	pick(t, &app, "a - b")
	for path in ([]string{"right   LONG", "left   LONG"}) {
		open_value(&app, ni, 0)
		pick(t, &app, "Reference")
		ref_choose(t, &app, "paint")
		pick(t, &app, "Field of paint")
		pick(t, &app, "rcPaint   RECT")
		pick(t, &app, path)
	}
	testing.expect_value(t, line_src(&app, ni), "width := paint.rcPaint.right - paint.rcPaint.left")

	// The types Doodle now knows.
	ty, ok := var_type_at(&app, ni, "x")
	testing.expect(t, ok && ty.expr == "LONG" && ty.pkg == "core:sys/windows", "x is a LONG")
	ty, ok = var_type_at(&app, ni + 1, "width")
	testing.expect(t, ok && ty.expr == "LONG", "width is a LONG")
	ty, ok = var_type_at(&app, ni, "device_context")
	testing.expect(t, ok && ty.expr == "HDC" && ty.pkg == "core:sys/windows", "BeginPaint returns an HDC")

	// The saved file (formatted) compiles: see test_wm_paint_source_checks.
	delete_selected_line(&app, body_line(&app))
	format_doc(&app)
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), WM_PAINT_SRC)
}

@(private = "file")
delete_selected_line :: proc(app: ^App, ni: int) {
	if ni < 0 do return
	focus_field_index(app, ni, 1)
	delete_selected(app)
}

// What test_build_wm_paint_statements saves (`odin check` accepts it).
WM_PAINT_SRC :: "package handmade\n\nimport win32 \"core:sys/windows\"\n\n" +
	"WHITENESS :: 0x00FF0062\n\n" +
	"operation: u32 = WHITENESS\n\n" +
	"main_window_callback :: proc \"system\" (\n" +
	"\twindow: win32.HWND,\n" +
	"\tmessage: win32.UINT,\n" +
	"\tw_param: win32.WPARAM,\n" +
	"\tl_param: win32.LPARAM,\n" +
	") -> win32.LRESULT {\n" +
	"\tresult: win32.LRESULT = 0\n" +
	"\tpaint: win32.PAINTSTRUCT\n" +
	"\tdevice_context := win32.BeginPaint(window, &paint)\n" +
	"\tx := paint.rcPaint.left\n" +
	"\twidth := paint.rcPaint.right - paint.rcPaint.left\n" +
	"\treturn result\n" +
	"}"

// Fields that can't be an INT are grayed; a struct field stays lit when
// something inside it fits; a pointer dot also gets &path.
@(test)
test_field_menu_gray_out :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app, strings.concatenate({SKELETON[:len(SKELETON) - 2], "\tpaint: win32.PAINTSTRUCT\n\twin32.PatBlt(, , , , , )\n\twin32.InvalidateRect(window, , false)\n}"}, context.temp_allocator), "return result")
	ni := line_with(&app, "PatBlt")
	open_value(&app, ni, 1) // x: INT
	pick(t, &app, "Reference")
	ref_choose(t, &app, "paint")
	testing.expect(t, !dimmed(t, &app, "Field of paint"))
	pick(t, &app, "Field of paint")
	testing.expect(t, !dimmed(t, &app, "rcPaint   RECT"), "leads to LONG fields")
	testing.expect(t, dimmed(t, &app, "fErase   BOOL"))
	testing.expect(t, dimmed(t, &app, "rgbReserved   [32]BYTE"))
	testing.expect(t, dimmed(t, &app, "hdc   HDC"))
	pick(t, &app, "rcPaint   RECT")
	testing.expect(t, dimmed(t, &app, "paint.rcPaint"), "a RECT isn't an INT")
	testing.expect(t, !dimmed(t, &app, "left   LONG"))
	for app.state == .Radial do update(&app, Input{cancel = true})
	update(&app, Input{cancel = true}) // leave pick mode

	ni = line_with(&app, "InvalidateRect")
	open_value(&app, ni, 0) // lpRect: ^RECT
	pick(t, &app, "Reference")
	ref_choose(t, &app, "paint")
	pick(t, &app, "Field of paint")
	pick(t, &app, "rcPaint   RECT")
	testing.expect(t, !dimmed(t, &app, "&paint.rcPaint"), "&paint.rcPaint is a ^RECT")
	testing.expect(t, dimmed(t, &app, "paint.rcPaint"))
	testing.expect(t, dimmed(t, &app, "&left   ^LONG"))
	pick(t, &app, "&paint.rcPaint")
	testing.expect_value(t, line_src(&app, ni), "win32.InvalidateRect(window, &paint.rcPaint, false)")
}

// A loaded field path is one value: Y refills it, and its type is known.
@(test)
test_loaded_field_path_is_one_unit :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	src := strings.concatenate({SKELETON[:len(SKELETON) - 2],
		"\tpaint: win32.PAINTSTRUCT\n\tdevice_context := win32.BeginPaint(window, &paint)\n" +
		"\twin32.PatBlt(device_context, paint.rcPaint.left, 0, 0, 0, 0)\n" +
		"\tp := &paint\n\ty := p.rcPaint.bottom\n}"}, context.temp_allocator)
	app.state = .Editor
	doc_from_source(&app, src)
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), src)
	ni := line_with(&app, "PatBlt")
	n := app.doc.nodes[ni]
	found := false
	for f in n.fields do if f.text == "paint.rcPaint.left" do found = true
	testing.expect(t, found, "paint.rcPaint.left is one field")
	ty, ok := expr_type_at(&app, ni, "paint.rcPaint.left")
	testing.expect(t, ok && ty.expr == "LONG" && ty.pkg == "core:sys/windows", "its type is LONG")
	ty, ok = expr_type_at(&app, ni, "paint.rcPaint")
	testing.expect(t, ok && ty.expr == "RECT", "paint.rcPaint is a RECT")
	ty, ok = var_type_at(&app, line_with(&app, "y :=") + 1, "y")
	testing.expect(t, ok && ty.expr == "LONG", "p.rcPaint.bottom through a pointer")
	ty, ok = var_type_at(&app, ni, "p")
	testing.expect_value(t, ty.expr, "")
	ty, ok = var_type_at(&app, line_with(&app, "y :="), "p")
	testing.expect_value(t, ty.expr, "^win32.PAINTSTRUCT")

	// Y on it: the fill menu, typed for PatBlt's x (INT); B puts it back.
	for f, i in n.fields do if f.text == "paint.rcPaint.left" { focus_field_index(&app, ni, i); break }
	change_selected(&app)
	testing.expect_value(t, app.state, State.Radial)
	_, fi, _ := editor_target(&app)
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].hint, "INT")
	update(&app, Input{cancel = true})
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), src)
}

// Assignment to a field: Y on the target -> pick the variable -> one of its fields.
@(test)
test_assignment_to_a_field :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app, strings.concatenate({SKELETON[:len(SKELETON) - 1], "\n\nmain :: proc() {\n\tclass: win32.WNDCLASSW\n}"}, context.temp_allocator), "class: win32")
	// Put the statement line after the declaration instead.
	ni := body_line(&app)
	line := app.doc.nodes[ni]
	ordered_remove(&app.doc.nodes, ni)
	inject_at(&app.doc.nodes, line_with(&app, "class: win32") + 1, line)

	ni = add_statement(t, &app, "Assignment", "Assignment")
	for f, i in app.doc.nodes[ni].fields do if f.editable { focus_field_index(&app, ni, i); break }
	change_selected(&app) // Y on the target
	testing.expect(t, app.ref_pick_active)
	ref_choose(t, &app, "class")
	testing.expect_value(t, current_view(&app).title, "Assign to")
	pick(t, &app, "Field of class")
	pick(t, &app, "style   UINT")
	testing.expect_value(t, line_src(&app, ni), "class.style =")
	// The value dot now expects the field's type: an or of window class styles.
	dot := -1
	for f, i in app.doc.nodes[ni].fields do if f.slot && f.kind == "value" { dot = i; break }
	testing.expect_value(t, app.doc.nodes[ni].fields[dot].hint, "UINT")
	open_value(&app, ni, 0)
	testing.expect(t, dimmed(t, &app, "true"), "a bool isn't a UINT")
	pick_leaf(t, &app, "CS_OWNDC", CONST_IMPORT_FILL)
	testing.expect_value(t, line_src(&app, ni), "class.style = win32.CS_OWNDC")

	// Loading it back: the target is still a name Y can change.
	delete_selected_line(&app, body_line(&app))
	src := doc_to_source(&app, context.temp_allocator)
	doc_from_source(&app, src)
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), src)
	ni = line_with(&app, "class.style")
	testing.expect(t, is_assign_target(app.doc.nodes[ni], 1), "the target is a name")
	// Y on the value refills it, still expecting a UINT.
	for f, i in app.doc.nodes[ni].fields do if f.text == "win32.CS_OWNDC" { focus_field_index(&app, ni, i); break }
	change_selected(&app)
	_, fi, _ := editor_target(&app)
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].hint, "UINT")
	update(&app, Input{cancel = true})
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), src)
}

// LT+B on the `= ●` of a typed declaration leaves `name: T` (its zero value).
@(test)
test_typed_declaration_without_value :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app, SKELETON, "return result")
	ni := add_statement(t, &app, "Declarations", "Variable (typed)")
	rename(&app, ni, "message")
	for f, i in app.doc.nodes[ni].fields do if f.slot && f.kind == "type" { focus_field_index(&app, ni, i); break }
	update(&app, Input{confirm = true})
	pick(t, &app, "Type")
	pick_leaf(t, &app, "MSG", TYPE_IMPORT_FILL)
	testing.expect_value(t, line_src(&app, ni), "message: win32.MSG =")
	for f, i in app.doc.nodes[ni].fields do if f.slot && f.kind == "value" { focus_field_index(&app, ni, i); break }
	delete_selected(&app) // LT+B on the value dot
	testing.expect_value(t, line_src(&app, ni), "message: win32.MSG")
	testing.expect_value(t, len(app.doc.nodes), len(strings.split_lines(SKELETON, context.temp_allocator)) + 1) // only the dot went
	ty, ok := var_type_at(&app, ni + 1, "message")
	testing.expect(t, ok && ty.expr == "win32.MSG", "message is a MSG")
	testing.expect_value(t, len(struct_fields(&app, ty)), 6)
}

// Types of names from every kind of declaration.
@(test)
test_var_types :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	src := "package main\n\nimport win32 \"core:sys/windows\"\n\n" +
		"Vec2 :: struct { x, y: f32 }\n\n" +
		"Entity :: struct {\n\tusing pos: Vec2, // where it is\n\tname: string,\n\tnext: ^Entity,\n}\n\n" +
		"Stack :: struct($T: typeid) {\n\titems: [dynamic]T,\n\ttop: T,\n}\n\n" +
		"Meters :: distinct Vec2\n\n" +
		"step :: proc(e: ^Entity, s: Stack(int)) -> Vec2 {\n" +
		"\tinstance := win32.HINSTANCE(win32.GetModuleHandleW(nil))\n" +
		"\twc := win32.WNDCLASSW {\n\t\thInstance = instance,\n\t}\n" +
		"\tm: Meters\n" +
		"\tif true {\n\t\tinner := 5\n\t}\n" +
		"\tv := e.pos\n" +
		"\treturn v\n" +
		"}"
	app.state = .Editor
	doc_from_source(&app, src)
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), src)
	at := line_with(&app, "return v")
	check :: proc(t: ^testing.T, app: ^App, at: int, name, want: string, loc := #caller_location) {
		ty, _ := var_type_at(app, at, name)
		testing.expect_value(t, ty.expr, want, loc = loc)
	}
	check(t, &app, at, "e", "^Entity")
	check(t, &app, at, "s", "Stack(int)")
	check(t, &app, at, "instance", "win32.HINSTANCE")
	check(t, &app, at, "wc", "win32.WNDCLASSW")
	check(t, &app, at, "m", "Meters")
	check(t, &app, at, "v", "Vec2")
	check(t, &app, at, "inner", "") // in a block that has ended

	names :: proc(fs: []Struct_Field) -> string {
		out := make([dynamic]string, context.temp_allocator)
		for f in fs do append(&out, strings.concatenate({f.name, ": ", f.type.expr}, context.temp_allocator))
		return strings.join(out[:], ", ", context.temp_allocator)
	}
	testing.expect_value(t, names(struct_fields(&app, {"^Entity", ""})), "pos: Vec2, x: f32, y: f32, name: string, next: ^Entity")
	testing.expect_value(t, names(struct_fields(&app, {"Stack(int)", ""})), "items: [dynamic]int, top: int")
	testing.expect_value(t, names(struct_fields(&app, {"Meters", ""})), "x: f32, y: f32")
	ty, _ := expr_type_at(&app, at, "e.next.x")
	testing.expect_value(t, ty.expr, "f32")
	ty, _ = expr_type_at(&app, at, "wc.hInstance")
	testing.expect(t, ty.expr == "HINSTANCE" && ty.pkg == "core:sys/windows")
	testing.expect(t, is_struct_type(&app, {"win32.LPRECT", ""}), "a pointer to a struct has fields")
}

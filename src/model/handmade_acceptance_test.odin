package model

// Acceptance tests for the user's goal program (Handmade Hero day 3, Win32
// window with a WM_PAINT handler). Everything here is built the way the
// controller builds it: A on dots, menu picks, Reference / Pass as / Field of,
// Struct literal, Modifiers > Calling convention, Y and LT+B.
//
// These tests leave out the `switch message` with its `case` clauses, the
// ternary, the conversion and comments inside procedures; the WM_PAINT
// statements are built straight into the callback's body. The complete file,
// from an empty project, is test_layout_handmade_from_empty_project
// (stmt_layout_test.odin); the ternary and conversion alone are in expr_test.odin.

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

// The first empty statement line ("●") at or after line `from`.
@(private = "file")
body_line :: proc(app: ^App, from := 0) -> int {
	for i in from ..< len(app.doc.nodes) do if is_body_slot_line(app.doc.nodes[i]) do return i
	return -1
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

// The entries leading to the leaf `label` (labels can repeat: two "g" groups).
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

// From the current view, walk down to the leaf `label` (views reorder entries:
// match each step by identity, not position or label).
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

// B until back in the editor (a failed step left a menu open).
@(private = "file")
back_out :: proc(app: ^App) {
	for _ in 0 ..< 16 {
		if app.state == .Editor && !app.ref_pick_active && !app.mod_pick_active do return
		update(app, Input{cancel = true})
	}
}

// A on the bottom green dot (top level), then group -> leaf of the Add menu.
@(private = "file")
add_top :: proc(t: ^testing.T, app: ^App, group, leaf: string, loc := #caller_location) {
	back_out(app)
	focus_dot(app)
	update(app, Input{confirm = true})
	if pick(t, app, group, loc) do pick(t, app, leaf, loc)
}

// A on the statement line ni's dot, then a statement from the menu.
@(private = "file")
add_stmt :: proc(t: ^testing.T, app: ^App, ni: int, group, label: string, loc := #caller_location) -> int {
	back_out(app)
	if !testing.expectf(t, ni >= 0, "no statement line for %s", label, loc = loc) do return -1
	focus_field_index(app, ni, 1)
	update(app, Input{confirm = true})
	if pick(t, app, group, loc) do pick(t, app, label, loc)
	return ni
}

// Name the line's nth editable name (what dictation does).
@(private = "file")
rename :: proc(app: ^App, ni: int, name: string, nth := 0) {
	if ni < 0 do return
	seen := 0
	for f, i in app.doc.nodes[ni].fields do if f.editable && f.kind != "string" {
		if seen == nth { set_field_text(app, ni, i, name); return }
		seen += 1
	}
}

// A on the nth unfilled dot of `kind` on line ni.
@(private = "file")
open_dot :: proc(t: ^testing.T, app: ^App, ni, nth: int, kind := "value", loc := #caller_location) -> bool {
	back_out(app)
	if ni < 0 do return false
	seen := 0
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
	testing.expectf(t, false, "no %s dot #%d on %q", kind, nth, line_src(app, ni), loc = loc)
	return false
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
	if !testing.expect(t, app.ref_pick_active, "in pick mode", loc = loc) do return
	for _ in 0 ..< 64 {
		if cursor_name(app) == name do break
		update(app, Input{left = true})
	}
	if cursor_name(app) != name {
		for _ in 0 ..< 64 {
			if cursor_name(app) == name do break
			update(app, Input{right = true})
		}
	}
	testing.expect_value(t, cursor_name(app), name, loc = loc)
	update(app, Input{confirm = true})
}

// Fill the next value dot of line ni with Reference -> name -> "Pass as" choice.
@(private = "file")
fill_ref :: proc(t: ^testing.T, app: ^App, ni: int, name: string, pass_as := "", loc := #caller_location) {
	if !open_dot(t, app, ni, 0, loc = loc) do return
	if !pick(t, app, "Reference", loc) do return
	ref_choose(t, app, name, loc)
	if app.state == .Radial do pick(t, app, pass_as == "" ? name : pass_as, loc)
}

// Fill the next value dot of line ni with a number (Number, then LT+A typing).
@(private = "file")
fill_number :: proc(t: ^testing.T, app: ^App, ni: int, text := "0", loc := #caller_location) {
	if !open_dot(t, app, ni, 0, loc = loc) do return
	if !pick(t, app, "Number", loc) do return
	if text != "0" {
		eni, efi, ok := editor_target(app)
		if testing.expect(t, ok && app.doc.nodes[eni].fields[efi].text == "0", "on the number", loc = loc) {
			set_field_text(app, eni, efi, text)
		}
	}
}

@(private = "file")
fill_nil :: proc(t: ^testing.T, app: ^App, ni: int, loc := #caller_location) {
	if open_dot(t, app, ni, 0, loc = loc) do pick(t, app, "nil", loc)
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
fill_op :: proc(t: ^testing.T, app: ^App, ni: int, group, op: string, loc := #caller_location) {
	if open_dot(t, app, ni, 0, loc = loc) && pick(t, app, "Operator", loc) && pick(t, app, group, loc) do pick(t, app, op, loc)
}

// win32.L("text")
@(private = "file")
fill_wide_string :: proc(t: ^testing.T, app: ^App, ni: int, text: string, loc := #caller_location) {
	fill_call(t, app, ni, "L", loc)
	if open_dot(t, app, ni, 0, loc = loc) && pick(t, app, "String", loc) && pick(t, app, "\"...\"  string", loc) {
		for f, i in app.doc.nodes[ni].fields do if f.editable && f.kind == "string" && f.text == "" { set_field_text(app, ni, i, text); return }
	}
}

// A on a type dot of line ni -> Type -> a win32 type (or a basic type).
@(private = "file")
fill_type :: proc(t: ^testing.T, app: ^App, ni, nth: int, name: string, fill := TYPE_IMPORT_FILL, loc := #caller_location) {
	if open_dot(t, app, ni, nth, "type", loc) && pick(t, app, "Type", loc) do pick_leaf(t, app, name, fill, loc)
}

// LT+B on line ni's statement dot ("●" line).
@(private = "file")
drop_line :: proc(app: ^App, ni: int) {
	if ni < 0 do return
	focus_field_index(app, ni, 1)
	delete_selected(app)
}

// A procedure parameter: params dot -> Add parameter, name it, then its type.
@(private = "file")
add_param :: proc(t: ^testing.T, app: ^App, hdr: int, name, type_name: string, loc := #caller_location) {
	if !open_dot(t, app, hdr, 0, "params", loc) do return
	if !pick(t, app, "Add parameter", loc) do return
	ni, fi, ok := editor_target(app)
	if testing.expect(t, ok && ni == hdr && app.doc.nodes[ni].fields[fi].editable, "on the new parameter's name", loc = loc) {
		set_field_text(app, ni, fi, name)
	}
	fill_type(t, app, hdr, 0, type_name, loc = loc)
}

// ---------------------------------------------------------------------------
// The file scope: import, constants, global.

@(test)
test_handmade_accept_file_scope :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.os_name = "windows"
	app.state = .Editor
	doc_from_source(&app, "package handmade\n")

	// import win32 "core:sys/windows"   (Aliased import, then rename the alias)
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
	if !testing.expectf(t, imp >= 0, "import added: %q", src(&app)) do return
	rename(&app, imp, "win32")
	testing.expect_value(t, line_src(&app, imp), "import win32 \"core:sys/windows\"")

	// WHITENESS :: 0x00FF0062   (Values > Constant, Number, typed in hex)
	add_top(t, &app, "Values", "Constant")
	c := len(app.doc.nodes) - 1
	rename(&app, c, "WHITENESS")
	fill_number(t, &app, c, "0x00FF0062")
	testing.expect_value(t, line_src(&app, c), "WHITENESS :: 0x00FF0062")
	add_top(t, &app, "Values", "Constant")
	c = len(app.doc.nodes) - 1
	rename(&app, c, "BLACKNESS")
	fill_number(t, &app, c, "0x00000042")
	testing.expect_value(t, line_src(&app, c), "BLACKNESS :: 0x00000042")

	// operation: u32 = WHITENESS   (Values > Global variable (typed) gives `name: ● = ●`)
	add_top(t, &app, "Values", "Global variable (typed)")
	g := len(app.doc.nodes) - 1
	rename(&app, g, "operation")
	fill_type(t, &app, g, 0, "u32", "")
	testing.expect_value(t, line_src(&app, g), "operation: u32 =")
	has_value_dot := false
	for f in app.doc.nodes[g].fields do if f.slot && f.kind == "value" {
		has_value_dot = true
		testing.expect_value(t, f.hint, "u32") // the value dot expects the declared type
	}
	testing.expectf(t, has_value_dot, "a typed global needs an `= ●` value dot to write `operation: u32 = WHITENESS`: %q", line_src(&app, g))
	fill_ref(t, &app, g, "WHITENESS")
	testing.expect_value(t, line_src(&app, g), "operation: u32 = WHITENESS")

	// The constants have the right types for later: WHITENESS fits a DWORD.
	ty, ok := var_type_at(&app, len(app.doc.nodes), "WHITENESS")
	testing.expectf(t, ok, "WHITENESS has a type: %v", ty)

	text := strings.clone(src(&app), context.temp_allocator)
	doc_from_source(&app, text)
	testing.expect_value(t, src(&app), text)
}

// ---------------------------------------------------------------------------
// The whole program, built from menus.

// What test_handmade_accept_build_program saves, after format_doc.
// (`odin check` accepts it - see the notes in the acceptance report.)
HANDMADE_BUILT :: "package handmade\n\n" +
	"import win32 \"core:sys/windows\"\n\n" +
	"WHITENESS :: 0x00FF0062\n" +
	"BLACKNESS :: 0x00000042\n\n" +
	"operation: u32\n\n" +
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
	"\ty := paint.rcPaint.top\n" +
	"\twidth := paint.rcPaint.right - paint.rcPaint.left\n" +
	"\theight := paint.rcPaint.bottom - paint.rcPaint.top\n" +
	"\twin32.PatBlt(device_context, x, y, width, height, operation)\n" +
	"\toperation = BLACKNESS\n" +
	"\twin32.EndPaint(window, &paint)\n" +
	"\tresult = win32.DefWindowProcW(window, message, w_param, l_param)\n" +
	"\treturn result\n" +
	"}\n\n" +
	"main :: proc() {\n" +
	"\tmodule := win32.GetModuleHandleW(nil)\n" +
	"\tinstance: win32.HINSTANCE = win32.HINSTANCE(module)\n" +
	"\twindow_class := win32.WNDCLASSW {\n" +
	"\t\tstyle         = win32.CS_OWNDC | win32.CS_HREDRAW | win32.CS_VREDRAW,\n" +
	"\t\tlpfnWndProc   = main_window_callback,\n" +
	"\t\thInstance     = instance,\n" +
	"\t\tlpszClassName = win32.L(\"HandmadeHeroWindowClass\"),\n" +
	"\t}\n" +
	"\tif win32.RegisterClassW(&window_class) != 0 {\n" +
	"\t\twindow_handle := win32.CreateWindowExW(\n" +
	"\t\t\t0,\n" +
	"\t\t\twindow_class.lpszClassName,\n" +
	"\t\t\twin32.L(\"HandmadeHero\"),\n" +
	"\t\t\twin32.WS_OVERLAPPEDWINDOW | win32.WS_VISIBLE,\n" +
	"\t\t\twin32.CW_USEDEFAULT,\n" +
	"\t\t\twin32.CW_USEDEFAULT,\n" +
	"\t\t\twin32.CW_USEDEFAULT,\n" +
	"\t\t\twin32.CW_USEDEFAULT,\n" +
	"\t\t\tnil,\n" +
	"\t\t\tnil,\n" +
	"\t\t\tinstance,\n" +
	"\t\t\tnil,\n" +
	"\t\t)\n" +
	"\t\tif window_handle != nil {\n" +
	"\t\t\tmessage: win32.MSG\n" +
	"\t\t\tfor win32.GetMessageW(&message, nil, 0, 0) > 0 {\n" +
	"\t\t\t\twin32.TranslateMessage(&message)\n" +
	"\t\t\t\twin32.DispatchMessageW(&message)\n" +
	"\t\t\t}\n" +
	"\t\t} else {\n" +
	"\t\t}\n" +
	"\t} else {\n" +
	"\t}\n" +
	"}"

@(test)
test_handmade_accept_build_program :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.os_name = "windows"
	app.state = .Editor
	// The file-scope part is test_handmade_accept_file_scope; start after it.
	doc_from_source(&app, "package handmade\n\nimport win32 \"core:sys/windows\"\n\nWHITENESS :: 0x00FF0062\nBLACKNESS :: 0x00000042\n\noperation: u32\n")

	// ---- main_window_callback :: proc "system" (...) -> win32.LRESULT ----
	add_top(t, &app, "Procedures", "Procedure")
	hdr := line_with(&app, ":: proc")
	if !testing.expect(t, hdr >= 0, "procedure added") do return
	rename(&app, hdr, "main_window_callback")
	add_param(t, &app, hdr, "window", "HWND")
	add_param(t, &app, hdr, "message", "UINT")
	add_param(t, &app, hdr, "w_param", "WPARAM")
	add_param(t, &app, hdr, "l_param", "LPARAM")
	fill_type(t, &app, hdr, 0, "LRESULT") // the return type
	// Saved, the header reads like Odin source (no `proc( a: T,  )`). As one
	// line it's longer than 80 columns, so the file gets one parameter per row.
	testing.expect_value(t, node_source(app.doc.nodes[hdr], context.temp_allocator),
		"main_window_callback :: proc(window: win32.HWND, message: win32.UINT, w_param: win32.WPARAM, l_param: win32.LPARAM) -> win32.LRESULT {")
	testing.expectf(t, strings.contains(src(&app),
		"main_window_callback :: proc(\n\twindow: win32.HWND,\n\tmessage: win32.UINT,\n\tw_param: win32.WPARAM,\n\tl_param: win32.LPARAM,\n) -> win32.LRESULT {\n"),
		"header as saved: %q", src(&app))

	// Modifiers > Calling convention > (the callback) > "system"
	focus_dot(&app)
	update(&app, Input{confirm = true})
	pick(t, &app, "Modifiers")
	pick(t, &app, "Calling convention")
	testing.expect(t, app.mod_pick_active, "picking the procedure")
	for _ in 0 ..< 8 do if app.mod_pick_line != hdr do update(&app, Input{up = true})
	testing.expect_value(t, app.mod_pick_line, hdr)
	update(&app, Input{confirm = true})
	pick(t, &app, "\"system\"")
	testing.expect(t, strings.has_prefix(line_src(&app, hdr), "main_window_callback :: proc \"system\" ("), line_src(&app, hdr))
	testing.expect(t, strings.contains(line_src(&app, hdr), ") -> win32.LRESULT {"), line_src(&app, hdr))
	cc := false
	for f in app.doc.nodes[hdr].fields do if f.kind == KW && f.text == "\"system\"" do cc = true
	testing.expect(t, cc, "\"system\" is a keyword field (Y / LT+B reach it)")
	// D-pad: the header's stops are the name, the convention, each parameter's name and type, the result type.
	stops := make([dynamic]string, context.temp_allocator)
	for u in line_leaves(app.doc.nodes[hdr]) do append(&stops, strings.trim_space(app.doc.nodes[hdr].fields[leaf_primary_field(app.doc.nodes[hdr], u)].text))
	testing.expect_value(t, strings.join(stops[:], " ", context.temp_allocator),
		"main_window_callback \"system\" window win32.HWND message win32.UINT w_param win32.WPARAM l_param win32.LPARAM  win32.LRESULT")

	// result: win32.LRESULT = 0
	ni := add_stmt(t, &app, body_line(&app, hdr), "Declarations", "Variable (typed)")
	rename(&app, ni, "result")
	fill_type(t, &app, ni, 0, "LRESULT")
	fill_number(t, &app, ni)
	testing.expect_value(t, line_src(&app, ni), "result: win32.LRESULT = 0")

	// paint: win32.PAINTSTRUCT
	ni = add_stmt(t, &app, body_line(&app, hdr), "Declarations", "Variable (no value)")
	rename(&app, ni, "paint")
	fill_type(t, &app, ni, 0, "PAINTSTRUCT")
	testing.expect_value(t, line_src(&app, ni), "paint: win32.PAINTSTRUCT")

	// device_context := win32.BeginPaint(window, &paint)
	ni = add_stmt(t, &app, body_line(&app, hdr), "Declarations", "Variable (:=)")
	rename(&app, ni, "device_context")
	fill_call(t, &app, ni, "BeginPaint")
	fill_ref(t, &app, ni, "window")
	fill_ref(t, &app, ni, "paint", "&paint   (pointer to it)")
	testing.expect_value(t, line_src(&app, ni), "device_context := win32.BeginPaint(window, &paint)")

	// x := paint.rcPaint.left, y := paint.rcPaint.top   (Field of paint -> rcPaint -> left)
	field_var :: proc(t: ^testing.T, app: ^App, hdr: int, name, field: string, loc := #caller_location) -> int {
		ni := add_stmt(t, app, body_line(app, hdr), "Declarations", "Variable (:=)", loc)
		rename(app, ni, name)
		if open_dot(t, app, ni, 0, loc = loc) && pick(t, app, "Reference", loc) {
			ref_choose(t, app, "paint", loc)
			if pick(t, app, "Field of paint", loc) && pick(t, app, "rcPaint   RECT", loc) do pick(t, app, field, loc)
		}
		return ni
	}
	ni = field_var(t, &app, hdr, "x", "left   LONG")
	testing.expect_value(t, line_src(&app, ni), "x := paint.rcPaint.left")
	ni = field_var(t, &app, hdr, "y", "top   LONG")
	testing.expect_value(t, line_src(&app, ni), "y := paint.rcPaint.top")

	// width := paint.rcPaint.right - paint.rcPaint.left   (Operator a - b, two field paths)
	diff_var :: proc(t: ^testing.T, app: ^App, hdr: int, name, a, b: string, loc := #caller_location) -> int {
		ni := add_stmt(t, app, body_line(app, hdr), "Declarations", "Variable (:=)", loc)
		rename(app, ni, name)
		fill_op(t, app, ni, "Arithmetic", "a - b", loc)
		for field in ([]string{a, b}) {
			if open_dot(t, app, ni, 0, loc = loc) && pick(t, app, "Reference", loc) {
				ref_choose(t, app, "paint", loc)
				if pick(t, app, "Field of paint", loc) && pick(t, app, "rcPaint   RECT", loc) do pick(t, app, field, loc)
			}
		}
		return ni
	}
	ni = diff_var(t, &app, hdr, "width", "right   LONG", "left   LONG")
	testing.expect_value(t, line_src(&app, ni), "width := paint.rcPaint.right - paint.rcPaint.left")
	ni = diff_var(t, &app, hdr, "height", "bottom   LONG", "top   LONG")
	testing.expect_value(t, line_src(&app, ni), "height := paint.rcPaint.bottom - paint.rcPaint.top")

	// win32.PatBlt(device_context, x, y, width, height, operation)
	ni = add_stmt(t, &app, body_line(&app, hdr), "Calls", "From import")
	pick(t, &app, "win32")
	pick_leaf(t, &app, "PatBlt", "__call_import_proc__")
	for name in ([]string{"device_context", "x", "y", "width", "height", "operation"}) {
		if !open_dot(t, &app, ni, 0) do break
		testing.expectf(t, !dimmed(t, &app, "Reference"), "Reference for %s", name)
		pick(t, &app, "Reference")
		ref_choose(t, &app, name)
		if app.state == .Radial {
			testing.expectf(t, !dimmed(t, &app, name), "%s fits PatBlt's argument", name)
			pick(t, &app, name)
		}
	}
	testing.expect_value(t, line_src(&app, ni), "win32.PatBlt(device_context, x, y, width, height, operation)")

	// operation = BLACKNESS   (stands in for `BLACKNESS if operation == WHITENESS else WHITENESS`)
	ni = add_stmt(t, &app, body_line(&app, hdr), "Assignment", "Assignment")
	for f, i in app.doc.nodes[ni].fields do if f.editable { focus_field_index(&app, ni, i); break }
	change_selected(&app) // Y on the target
	ref_choose(t, &app, "operation")
	if app.state == .Radial do pick(t, &app, "operation")
	fill_ref(t, &app, ni, "BLACKNESS")
	testing.expect_value(t, line_src(&app, ni), "operation = BLACKNESS")

	// win32.EndPaint(window, &paint)
	ni = add_stmt(t, &app, body_line(&app, hdr), "Calls", "From import")
	pick(t, &app, "win32")
	pick_leaf(t, &app, "EndPaint", "__call_import_proc__")
	fill_ref(t, &app, ni, "window")
	fill_ref(t, &app, ni, "paint", "&paint   (pointer to it)")
	testing.expect_value(t, line_src(&app, ni), "win32.EndPaint(window, &paint)")

	// result = win32.DefWindowProcW(window, message, w_param, l_param)
	ni = add_stmt(t, &app, body_line(&app, hdr), "Assignment", "Assignment")
	for f, i in app.doc.nodes[ni].fields do if f.editable { focus_field_index(&app, ni, i); break }
	change_selected(&app)
	ref_choose(t, &app, "result")
	if app.state == .Radial do pick(t, &app, "result")
	testing.expect_value(t, line_src(&app, ni), "result =")
	fill_call(t, &app, ni, "DefWindowProcW")
	for name in ([]string{"window", "message", "w_param", "l_param"}) do fill_ref(t, &app, ni, name)
	testing.expect_value(t, line_src(&app, ni), "result = win32.DefWindowProcW(window, message, w_param, l_param)")

	// return result
	ni = add_stmt(t, &app, body_line(&app, hdr), "Jumps and cleanup", "Return")
	fill_ref(t, &app, ni, "result")
	testing.expect_value(t, line_src(&app, ni), "return result")
	drop_line(&app, body_line(&app, hdr))

	// ---- main :: proc() ----
	add_top(t, &app, "Procedures", "Procedure")
	mh := line_with(&app, ":: proc", hdr + 1)
	if !testing.expect(t, mh >= 0, "second procedure") do return
	rename(&app, mh, "main")

	// module := win32.GetModuleHandleW(nil)
	// instance: win32.HINSTANCE = win32.HINSTANCE(module)   (Pass as T(x); T(call) isn't offered)
	ni = add_stmt(t, &app, body_line(&app, mh), "Declarations", "Variable (:=)")
	rename(&app, ni, "module")
	fill_call(t, &app, ni, "GetModuleHandleW")
	fill_nil(t, &app, ni)
	testing.expect_value(t, line_src(&app, ni), "module := win32.GetModuleHandleW(nil)")
	ni = add_stmt(t, &app, body_line(&app, mh), "Declarations", "Variable (typed)")
	rename(&app, ni, "instance")
	fill_type(t, &app, ni, 0, "HINSTANCE")
	// The empty value dot expects the declared type (gray-out, Pass as T(x)).
	// (A type written in this file is hinted as written: "win32.HINSTANCE".)
	for f in app.doc.nodes[ni].fields do if f.slot && f.kind == "value" {
		testing.expectf(t, f.hint == "HINSTANCE" || f.hint == "win32.HINSTANCE", "the value dot of `instance: win32.HINSTANCE = ●` expects a HINSTANCE: hint %q", f.hint)
	}
	if open_dot(t, &app, ni, 0) {
		testing.expect(t, dimmed(t, &app, "true"), "a bool isn't a HINSTANCE")
		back_out(&app)
	}
	// Reference > module > Pass as > win32.HINSTANCE(module), straight on the dot.
	fill_ref(t, &app, ni, "module", "win32.HINSTANCE(module)")
	testing.expect_value(t, line_src(&app, ni), "instance: win32.HINSTANCE = win32.HINSTANCE(module)")

	// window_class := win32.WNDCLASSW{...}
	ni = add_stmt(t, &app, body_line(&app, mh), "Declarations", "Variable (:=)")
	rename(&app, ni, "window_class")
	if open_dot(t, &app, ni, 0) && pick(t, &app, "Struct literal") do pick_leaf(t, &app, "WNDCLASSW", LIT_TYPE_FILL)
	if open_dot(t, &app, ni, 0, FIELDS_KIND) do pick(t, &app, "style   UINT")
	fill_op(t, &app, ni, "Bitwise", "a | b")
	fill_const(t, &app, ni, "CS_OWNDC")
	fill_op(t, &app, ni, "Bitwise", "a | b")
	fill_const(t, &app, ni, "CS_HREDRAW")
	fill_const(t, &app, ni, "CS_VREDRAW")
	if open_dot(t, &app, ni, 0, FIELDS_KIND) do pick(t, &app, "lpfnWndProc   WNDPROC")
	if open_dot(t, &app, ni, 0) {
		pick(t, &app, "Reference")
		ref_choose(t, &app, "main_window_callback")
		if app.state == .Radial {
			testing.expect(t, !dimmed(t, &app, "main_window_callback"), "a \"system\" proc fits WNDPROC")
			pick(t, &app, "main_window_callback")
		}
	}
	if open_dot(t, &app, ni, 0, FIELDS_KIND) do pick(t, &app, "hInstance   HINSTANCE")
	fill_ref(t, &app, ni, "instance")
	if open_dot(t, &app, ni, 0, FIELDS_KIND) do pick(t, &app, "lpszClassName   LPCWSTR")
	fill_wide_string(t, &app, ni, "HandmadeHeroWindowClass")
	testing.expect_value(t, line_src(&app, ni),
		"window_class := win32.WNDCLASSW{style = win32.CS_OWNDC | win32.CS_HREDRAW | win32.CS_VREDRAW, lpfnWndProc = main_window_callback, hInstance = instance, lpszClassName = win32.L(\"HandmadeHeroWindowClass\")}")

	// if win32.RegisterClassW(&window_class) != 0 { ... } else { }
	ifl := add_stmt(t, &app, body_line(&app, mh), "Branching", "If / Else")
	fill_op(t, &app, ifl, "Compare", "a != b")
	fill_call(t, &app, ifl, "RegisterClassW")
	fill_ref(t, &app, ifl, "window_class", "&window_class   (pointer to it)")
	fill_number(t, &app, ifl)
	testing.expect_value(t, line_src(&app, ifl), "if win32.RegisterClassW(&window_class) != 0 {")

	// window_handle := win32.CreateWindowExW(0, window_class.lpszClassName, ...)
	ni = add_stmt(t, &app, body_line(&app, ifl), "Declarations", "Variable (:=)")
	rename(&app, ni, "window_handle")
	fill_call(t, &app, ni, "CreateWindowExW")
	fill_number(t, &app, ni)
	if open_dot(t, &app, ni, 0) && pick(t, &app, "Reference") {
		ref_choose(t, &app, "window_class")
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
	testing.expect_value(t, line_src(&app, ni),
		"window_handle := win32.CreateWindowExW(0, window_class.lpszClassName, win32.L(\"HandmadeHero\"), win32.WS_OVERLAPPEDWINDOW | win32.WS_VISIBLE, " +
		"win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, nil, nil, instance, nil)")

	// if window_handle != nil { ... } else { }
	inner := add_stmt(t, &app, body_line(&app, ifl), "Branching", "If / Else")
	fill_op(t, &app, inner, "Compare", "a != b")
	fill_ref(t, &app, inner, "window_handle")
	fill_nil(t, &app, inner)
	testing.expect_value(t, line_src(&app, inner), "if window_handle != nil {")

	// message: win32.MSG
	ni = add_stmt(t, &app, body_line(&app, inner), "Declarations", "Variable (no value)")
	rename(&app, ni, "message")
	fill_type(t, &app, ni, 0, "MSG")
	testing.expect_value(t, line_src(&app, ni), "message: win32.MSG")

	// for win32.GetMessageW(&message, nil, 0, 0) { ... }
	// In this Odin, GetMessageW returns an INT, so the target's
	// `for win32.GetMessageW(...)` fails `odin check` ("Non-boolean condition");
	// built here as `... > 0`. The condition dot should gray out non-bools.
	loop := add_stmt(t, &app, body_line(&app, inner), "Loops", "For (condition)")
	if open_dot(t, &app, loop, 0) {
		testing.expect(t, !dimmed(t, &app, "true"), "a bool fits a for condition")
		testing.expect(t, dimmed(t, &app, "Number"), "a number isn't a for condition")
		testing.expect(t, dimmed(t, &app, "GetMessageW"), "GetMessageW returns an INT: not a for condition by itself")
		back_out(&app)
	}
	fill_op(t, &app, loop, "Compare", "a > b")
	fill_call(t, &app, loop, "GetMessageW")
	fill_ref(t, &app, loop, "message", "&message   (pointer to it)")
	fill_nil(t, &app, loop)
	fill_number(t, &app, loop)
	fill_number(t, &app, loop)
	fill_number(t, &app, loop)
	testing.expect_value(t, line_src(&app, loop), "for win32.GetMessageW(&message, nil, 0, 0) > 0 {")
	for name in ([]string{"TranslateMessage", "DispatchMessageW"}) {
		ni = add_stmt(t, &app, body_line(&app, loop), "Calls", "From import")
		pick(t, &app, "win32")
		pick_leaf(t, &app, name, "__call_import_proc__")
		fill_ref(t, &app, ni, "message", "&message   (pointer to it)")
	}
	testing.expect_value(t, line_src(&app, loop + 1), "win32.TranslateMessage(&message)")
	testing.expect_value(t, line_src(&app, loop + 2), "win32.DispatchMessageW(&message)")

	// Drop the leftover statement lines (the else branches stay empty: no comments in bodies).
	back_out(&app)
	for _ in 0 ..< 32 {
		b := body_line(&app, hdr)
		if b < 0 do break
		before := len(app.doc.nodes)
		drop_line(&app, b)
		if len(app.doc.nodes) == before do break
	}
	testing.expect_value(t, body_line(&app, hdr), -1)

	// The types Doodle knows along the way.
	at := line_with(&app, "win32.PatBlt")
	ty, ok := var_type_at(&app, at, "device_context")
	testing.expect(t, ok && ty.expr == "HDC", "device_context is an HDC")
	ty, ok = var_type_at(&app, at, "height")
	testing.expect(t, ok && ty.expr == "LONG", "height is a LONG")
	ty, ok = var_type_at(&app, line_with(&app, "for win32.GetMessageW"), "window_handle")
	testing.expectf(t, ok && ty.expr == "HWND", "window_handle is an HWND: %v", ty)

	// Formatted and saved, it's the expected program; loading it back changes nothing.
	format_doc(&app)
	testing.expect_value(t, src(&app), HANDMADE_BUILT)
	// Apart from the callback's header, it's exactly that.
	split :: proc(s: string) -> (before, after: string) {
		a := strings.index(s, "main_window_callback :: proc")
		b := strings.index(s, ") -> win32.LRESULT {\n")
		if a < 0 || b < a do return s, ""
		return s[:a], s[b:]
	}
	gb, ga := split(src(&app))
	wb, wa := split(HANDMADE_BUILT)
	testing.expect_value(t, gb, wb)
	testing.expect_value(t, ga, wa)
	text := strings.clone(src(&app), context.temp_allocator)
	doc_from_source(&app, text)
	testing.expect_value(t, src(&app), text)
	format_doc(&app)
	testing.expect_value(t, src(&app), text)
}

// ---------------------------------------------------------------------------
// The target program, loaded as written.

// The user's goal program, exactly as written.
@(private = "file")
HANDMADE_TARGET :: "package handmade\n\n" +
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
	"\t\t\tfor win32.GetMessageW(&message, nil, 0, 0) {\n" +
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
has_field :: proc(n: Node, text, kind: string) -> bool {
	for f in n.fields do if !f.slot && f.text == text && f.kind == kind do return true
	return false
}

// Open the target file and save it: nothing changes.
@(test)
test_handmade_accept_load_verbatim :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, HANDMADE_TARGET)
	testing.expect_value(t, src(&app), HANDMADE_TARGET)
	base := strings.clone(src(&app), context.temp_allocator)

	// The new features are structured in the loaded file (not plain text).
	hdr := line_with(&app, "main_window_callback :: proc")
	testing.expect(t, hdr >= 0 && has_field(app.doc.nodes[hdr], "\"system\"", KW), "calling convention is a keyword field")
	cls := line_with(&app, "window_class := win32.WNDCLASSW")
	testing.expect(t, cls >= 0 && has_field(app.doc.nodes[cls], "lpszClassName", LIT_KEY_KIND), "literal keys are structured")
	testing.expect(t, cls >= 0 && has_field(app.doc.nodes[cls], "style", LIT_KEY_KIND), "style key structured")
	xi := line_with(&app, "x := paint.rcPaint.left")
	found := false
	if xi >= 0 do for f in app.doc.nodes[xi].fields do if f.text == "paint.rcPaint.left" do found = true
	testing.expect(t, found, "paint.rcPaint.left is one field")
	ty, ok := var_type_at(&app, xi + 1, "x")
	testing.expectf(t, ok && ty.expr == "LONG", "x is a LONG: %v", ty)
	ty, ok = var_type_at(&app, line_with(&app, "width :=") + 1, "width")
	testing.expectf(t, ok && ty.expr == "LONG", "width is a LONG: %v", ty)
	ty, ok = var_type_at(&app, line_with(&app, "win32.PatBlt"), "device_context")
	testing.expectf(t, ok && ty.expr == "HDC", "device_context is an HDC: %v", ty)
	ci := line_with(&app, "window_handle := win32.CreateWindowExW")
	testing.expect(t, ci >= 0, "CreateWindowExW line")
	found = false
	if ci >= 0 do for f in app.doc.nodes[ci].fields do if f.text == "window_class.lpszClassName" do found = true
	testing.expect(t, found, "window_class.lpszClassName is one field of the call")

	// Y on `paint.rcPaint.left` (in x := ...): the fill menu; B puts it back.
	for f, i in app.doc.nodes[xi].fields do if f.text == "paint.rcPaint.left" { focus_field_index(&app, xi, i); break }
	change_selected(&app)
	testing.expect_value(t, app.state, State.Radial)
	back_out(&app)
	testing.expect_value(t, src(&app), base)

	// LT+B on "system", then Modifiers > Calling convention puts it back.
	for f, i in app.doc.nodes[hdr].fields do if f.kind == KW && f.text == "\"system\"" { focus_field_index(&app, hdr, i); break }
	testing.expect_value(t, cursor_name(&app), "\"system\"")
	delete_selected(&app)
	testing.expect(t, strings.contains(src(&app), "main_window_callback :: proc(\n\twindow: win32.HWND,"), "callconv removed")
	focus_dot(&app)
	update(&app, Input{confirm = true})
	pick(t, &app, "Modifiers")
	pick(t, &app, "Calling convention")
	for _ in 0 ..< 8 do if app.mod_pick_line != hdr do update(&app, Input{up = true})
	testing.expect_value(t, app.mod_pick_line, hdr)
	update(&app, Input{confirm = true})
	pick(t, &app, "\"system\"")
	testing.expect_value(t, src(&app), base)

	// LT+B on a literal field (lpfnWndProc), then the fields dot offers it again.
	for f, i in app.doc.nodes[cls].fields do if f.kind == LIT_KEY_KIND && f.text == "lpfnWndProc" { focus_field_index(&app, cls, i); break }
	delete_selected(&app)
	testing.expect(t, !strings.contains(src(&app), "lpfnWndProc"), "lpfnWndProc removed")
	if open_dot(t, &app, cls, 0, FIELDS_KIND) {
		testing.expect(t, strings.contains(labels(&app), "lpfnWndProc   WNDPROC"), labels(&app))
		back_out(&app)
	}
}

// The target program, formatted (format_doc runs on load and save).
@(test)
test_handmade_accept_load_formatted :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, HANDMADE_TARGET)
	format_doc(&app)
	out := strings.clone(src(&app), context.temp_allocator)
	// Unchanged: the target is already formatted (paired argument rows kept).
	testing.expect_value(t, out, HANDMADE_TARGET)
	// Formatting is stable, and the formatted file loads back the same.
	format_doc(&app)
	testing.expect_value(t, src(&app), out)
	doc_from_source(&app, out)
	testing.expect_value(t, src(&app), out)
}

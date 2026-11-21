package model

// Cross-feature checks after merging the gen / types / ctrl / fields builders:
// files that use all of them at once load, round-trip and format together.

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
line_with :: proc(app: ^App, text: string) -> int {
	for n, i in app.doc.nodes do if strings.contains(node_text(n, context.temp_allocator), text) do return i
	return -1
}

@(private = "file")
has_field :: proc(n: Node, text, kind: string) -> bool {
	for f in n.fields do if !f.slot && f.text == text && f.kind == kind do return true
	return false
}

// The user's goal program (Handmade Hero day 3), exactly as written.
@(private = "file")
HANDMADE :: "package handmade\n\n" +
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

@(test)
test_integration_handmade_loads_with_all_features :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, HANDMADE)
	// Everything round-trips, the paired CreateWindowExW argument rows included
	// (a loaded call keeps its argument rows), and format_doc changes nothing.
	testing.expect_value(t, src(&app), HANDMADE)
	saved := strings.clone(src(&app), context.temp_allocator)
	format_doc(&app)
	testing.expect_value(t, src(&app), HANDMADE)
	doc_from_source(&app, saved)

	// ctrl: the calling convention is a keyword field.
	hdr := line_with(&app, "main_window_callback :: proc")
	testing.expect(t, hdr >= 0 && has_field(app.doc.nodes[hdr], "\"system\"", KW), "calling convention structured")

	// fields: struct literal keys and field access come from the real CORE_FIELDS.
	cls := line_with(&app, "window_class := win32.WNDCLASSW")
	testing.expect(t, cls >= 0)
	ty, ok := var_type_at(&app, line_with(&app, "x := paint.rcPaint.left"), "paint")
	testing.expectf(t, ok && ty.expr == "win32.PAINTSTRUCT", "paint is a PAINTSTRUCT: %v", ty)
	rty, rok := expr_type_at(&app, line_with(&app, "x := paint.rcPaint.left"), "paint.rcPaint.left")
	testing.expectf(t, rok && strings.has_suffix(rty.expr, "LONG"), "paint.rcPaint.left is a LONG: %v", rty)
	fty, fok := field_type(&app, Var_Type{"RECT", "core:sys/windows"}, "left")
	testing.expect(t, fok && fty.expr == "LONG", "RECT.left is LONG")

	// The multi-line literal loads as one structured line (no statement dots inside it).
	// (Its aligned `=` signs are re-padded on save: the node holds plain " = ".)
	testing.expect_value(t, line_with(&app, "style = win32.CS_OWNDC"), cls)
	testing.expect(t, has_field(app.doc.nodes[cls], "lpszClassName", LIT_KEY_KIND), "literal keys structured")

	// Formatting keeps everything.
	format_doc(&app)
	out := src(&app)
	testing.expect_value(t, out, HANDMADE)
	testing.expect(t, strings.contains(out, "main_window_callback :: proc \"system\" (\n\twindow: win32.HWND,"), "header kept")
	testing.expect(t, strings.contains(out, "\t\tlpszClassName = win32.L(\"HandmadeHeroWindowClass\"),\n\t}\n"), "literal kept")
	testing.expect(t, strings.contains(out, "\t\toperation = BLACKNESS if operation == WHITENESS else WHITENESS\n"), "ternary kept")
	doc_from_source(&app, out)
	testing.expect_value(t, src(&app), out)
}

// Types + Compile-time + Modifiers + struct literals + field access in one file.
@(private = "file")
COMBO :: "package game\n\n" +
	"import \"core:fmt\"\n\n" +
	"Dir :: enum {\n" +
	"\tNorth,\n" +
	"\tSouth,\n" +
	"}\n\n" +
	"Flags :: bit_set[Dir]\n\n" +
	"Vec2 :: struct {\n" +
	"\tx: f32,\n" +
	"\ty: f32,\n" +
	"}\n\n" +
	"@(private)\n" +
	"Player :: struct #packed {\n" +
	"\thp:  i32,\n" +
	"\tpos: Vec2,\n" +
	"}\n\n" +
	"Stack :: struct($T: typeid) #align(8) {\n" +
	"\titems: [dynamic]T,\n" +
	"}\n\n" +
	"Meters :: distinct f64\n\n" +
	"when ODIN_OS == .Windows {\n" +
	"\tSEP :: \"\\\\\"\n" +
	"} else {\n" +
	"\tSEP :: \"/\"\n" +
	"}\n\n" +
	"#assert(size_of(Player) == 12)\n\n" +
	"main :: proc() {\n" +
	"\tp := Player{hp = 3, pos = Vec2{x = 1, y = 2}}\n" +
	"\tp.pos.x = 5\n" +
	"\tfmt.println(p.pos.x, SEP)\n" +
	"}"

@(test)
test_integration_combo_round_trip :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, COMBO)
	testing.expect_value(t, src(&app), COMBO)

	// types: members are structured; ctrl: the directive is a keyword.
	pl := line_with(&app, "Player :: struct")
	testing.expect(t, has_field(app.doc.nodes[pl], "#packed", KW), "#packed is a keyword")
	st := line_with(&app, "Stack :: struct")
	testing.expect(t, has_field(app.doc.nodes[st], "#align(", KW), "#align is a keyword")
	testing.expect(t, has_field(app.doc.nodes[st], "T", "poly"), "$T is a poly name")
	hp := line_with(&app, "hp:  i32")
	testing.expect(t, has_field(app.doc.nodes[hp], "hp", "member"), "hp is a member")

	// fields: the field type through a document struct.
	ty, ok := var_type_at(&app, line_with(&app, "p.pos.x = 5"), "p")
	testing.expect(t, ok && ty.expr == "Player", "p is a Player")
	ety, eok := expr_type_at(&app, line_with(&app, "fmt.println"), "p.pos.x")
	testing.expect(t, eok && ety.expr == "f32", "p.pos.x is f32")

	format_doc(&app)
	testing.expect_value(t, src(&app), COMBO)
}


// ctrl's Enum value reads the generator's real CORE_ENUM_MEMBERS and the
// enums the Types loader structured.
@(test)
test_integration_enum_members_real_tables :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package p\n\nimport \"base:runtime\"\n\nDir :: enum {\n\tNorth,\n\tSouth,\n}")
	doc := enum_members(&app, "Dir", "")
	testing.expect_value(t, len(doc), 2)
	if len(doc) == 2 do testing.expect(t, doc[0] == "North" && doc[1] == "South")
	rt := enum_members(&app, "runtime.Allocator_Mode", "")
	found := false
	for m in rt do if m == "Alloc" do found = true
	testing.expect(t, found, "runtime.Allocator_Mode has Alloc")
}

// Enum value on a bit_set dot: sdl.Init's InitFlags (distinct bit_set[InitFlag;
// Uint32]) lists InitFlag's members as one-member sets; {.VIDEO} fills the dot.
// Also a plain `bit_set[...]` package type and one declared in the document.
@(test)
test_integration_enum_value_bit_set :: proc(t: ^testing.T) {
	e, ep := bit_set_elem(nil, "Logger_Options", "base:runtime")
	testing.expect(t, e == "Logger_Option" && ep == "base:runtime", "plain bit_set row keeps its element")

	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nimport sdl \"vendor:sdl3\"\n\nFlag :: enum {\n\tA,\n\tB,\n}\nFlags :: bit_set[Flag; u8]\n\nmain :: proc() {\n\tsdl.Init()\n}")
	de, dep := bit_set_elem(&app, "Flags", "")
	testing.expect(t, de == "Flag" && dep == "", "document bit_set")

	ni := line_with(&app, "sdl.Init(")
	if !testing.expect(t, ni >= 0, "Init line") do return
	for f, i in app.doc.nodes[ni].fields do if f.slot && f.kind == "value" { focus_field_index(&app, ni, i); break }
	update(&app, Input{confirm = true})
	pick(t, &app, "Enum value")
	v := current_view(&app)
	if !testing.expect(t, v != nil, "Enum value submenu") do return
	labels := make([dynamic]string, context.temp_allocator)
	for en in v.entries do append(&labels, en.label)
	testing.expectf(t, len(labels) > 0 && labels[0] == "{.AUDIO}", "InitFlag members as sets, got %v", labels[:])
	pick(t, &app, "{.VIDEO}")
	testing.expect_value(t, strings.trim_space(node_text(app.doc.nodes[ni], context.temp_allocator)), "sdl.Init({.VIDEO})")

	// The saved source parses back to the same line.
	text := strings.clone(src(&app), context.temp_allocator)
	again: App
	defer cleanup(&again)
	again.state = .Editor
	doc_from_source(&again, text)
	testing.expect_value(t, src(&again), text)
}

// Reopening a saved `● | ●` argument: the empty operands come back as dots
// typed like the argument (Enum value lists InitFlag), and the file round-trips.
@(test)
test_integration_reload_empty_operator_operands :: proc(t: ^testing.T) {
	Case :: struct { src_line: string, dots: int }
	cases := [?]Case{
		{"sdl3.Init( | )", 2},
		{"sdl3.Init({.VIDEO} | )", 1},
		{"sdl3.Init( | {.VIDEO})", 1},
		{"sdl3.Init(sdl3.INIT_VIDEO | )", 1},
	}
	for c in cases {
		text := strings.concatenate({"package main\n\nimport \"vendor:sdl3\"\n\nmain :: proc() {\n\t", c.src_line, "\n}"}, context.temp_allocator) // doc_to_source: no final newline
		app: App
		app.state = .Editor
		doc_from_source(&app, text)
		ni := line_with(&app, "sdl3.Init(")
		if !testing.expectf(t, ni >= 0, "%s: Init line", c.src_line) { cleanup(&app); continue }
		dots := 0
		for f in app.doc.nodes[ni].fields do if f.slot && f.kind == "value" {
			dots += 1
			testing.expectf(t, f.hint == "InitFlags" && f.hint_pkg == "vendor:sdl3", "%s: dot typed InitFlags, got %q/%q", c.src_line, f.hint, f.hint_pkg)
		}
		testing.expectf(t, dots == c.dots, "%s: %d dots, want %d", c.src_line, dots, c.dots)
		testing.expect_value(t, src(&app), text)
		cleanup(&app)
	}
	// A unary operator with an empty operand: `~` alone, no spaces -> ~● (not ● ~ ●).
	app: App
	defer cleanup(&app)
	app.state = .Editor
	text := "package main\n\nimport \"vendor:sdl3\"\n\nmain :: proc() {\n\tsdl3.Init(~)\n}"
	doc_from_source(&app, text)
	ni := line_with(&app, "sdl3.Init(")
	if testing.expect(t, ni >= 0, "Init line") {
		n := 0
		for f in app.doc.nodes[ni].fields do if f.slot && f.kind == "value" do n += 1
		testing.expectf(t, n == 1, "~● has one dot, got %d", n)
	}
	testing.expect_value(t, src(&app), text)
}

// Assignment > Implicit Context > logger: `context.logger = ●`, the dot
// expecting runtime.Logger (a Logger-returning call fits, a number doesn't).
@(test)
test_integration_assign_implicit_context :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nimport \"core:log\"\n\nmain :: proc() {\n\tcl := log.create_console_logger()\n}")
	// The green insertion dot before main's closing brace.
	closing := -1
	for n, i in app.doc.nodes do if strings.trim_space(node_text(n, context.temp_allocator)) == "}" do closing = i
	if !testing.expect(t, closing >= 0, "main's closing brace") do return
	focus_dot_at(&app, closing)
	update(&app, Input{confirm = true})
	pick(t, &app, "Assignment")
	pick(t, &app, "Implicit Context")
	v := current_view(&app)
	if !testing.expect(t, v != nil, "Implicit Context submenu") do return
	labels := make([dynamic]string, context.temp_allocator)
	for e in v.entries do append(&labels, e.label)
	testing.expectf(t, len(labels) == 7, "the runtime.Context fields without _internal, got %v", labels[:])
	pick(t, &app, "logger   Logger")
	free_all(context.temp_allocator)

	ni := line_with(&app, "context.logger")
	if !testing.expect(t, ni >= 0, "context.logger line") do return
	fi := -1
	for f, i in app.doc.nodes[ni].fields do if f.slot && f.kind == "value" { fi = i; break }
	if !testing.expect(t, fi >= 0, "value dot") do return
	f := app.doc.nodes[ni].fields[fi]
	testing.expect(t, f.hint == "Logger" && f.hint_pkg == "base:runtime", "the dot expects runtime.Logger")

	// Graying on the value dot: log.create_console_logger fits, a number doesn't.
	focus_field_index(&app, ni, fi)
	update(&app, Input{confirm = true})
	mv := current_view(&app)
	if testing.expect(t, mv != nil, "value menu") {
		num, nok := top_entry(mv.entries, "Number")
		testing.expect(t, nok && num.dim, "a Number can't be a Logger")
		call, cok := top_entry(mv.entries, "Call")
		if testing.expect(t, cok, "Call") {
			path := make([dynamic]string, context.temp_allocator)
			leaf, lok := find_leaf(call.children, "create_console_logger", &path)
			testing.expectf(t, lok && !leaf.dim, "create_console_logger fits (%v)", path[:])
		}
	}
	for _ in 0 ..< 6 do if app.state == .Radial do update(&app, Input{cancel = true})

	set_slot_text(&app, ni, fi, "cl")
	testing.expect_value(t, strings.trim_space(node_text(app.doc.nodes[ni], context.temp_allocator)), "context.logger = cl")
	text := strings.clone(src(&app), context.temp_allocator)
	again: App
	defer cleanup(&again)
	again.state = .Editor
	doc_from_source(&again, text)
	testing.expect_value(t, src(&again), text)
}

@(private = "file")
find_leaf :: proc(entries: []Entry, label: string, path: ^[dynamic]string) -> (Entry, bool) {
	for e in entries {
		append(path, e.label)
		if len(e.children) == 0 && e.label == label do return e, true
		if len(e.children) > 0 { if r, ok := find_leaf(e.children, label, path); ok do return r, true }
		pop(path)
	}
	return {}, false
}

// Reopening unfilled assignment / declaration values: `x =`, `x :=`, `x: T =`,
// `x +=` (an empty dot saves as nothing) come back with their value dot, as
// the menus build them; a value continued on the next line is left alone.
@(test)
test_integration_reload_open_values :: proc(t: ^testing.T) {
	Case :: struct { line: string, form: string } // form: the fields' kinds, "" = fixed text
	cases := [?]Case{
		{"clever_otter =", "name assign_op dot"},
		{"log :=", "name decl dot"},
		{"w := ", "name decl dot"},
		{"x: int =", "name decl type fixed dot"},
		{"y +=", "name assign_op dot"},
		{"context.logger =", "name assign_op dot"},
	}
	for c in cases {
		text := strings.concatenate({"package main\n\nmain :: proc() {\n\ta := 1\n\t", c.line, "\n}"}, context.temp_allocator)
		app: App
		app.state = .Editor
		doc_from_source(&app, text)
		ni := line_with(&app, strings.trim_space(c.line)[:1])
		for n, i in app.doc.nodes do if strings.has_prefix(strings.trim_space(node_text(n, context.temp_allocator)), strings.trim_space(c.line)) do ni = i
		kinds := make([dynamic]string, context.temp_allocator)
		for f in app.doc.nodes[ni].fields {
			switch {
			case f.slot && f.kind == "value":              append(&kinds, "dot")
			case f.editable && f.kind == "":               append(&kinds, "name")
			case f.kind == ASSIGN_OP_KIND:                 append(&kinds, "assign_op")
			case f.kind == "decl" || f.kind == "type":     append(&kinds, f.kind)
			case strings.trim_space(f.text) == "":         // indentation
			case:                                          append(&kinds, "fixed")
			}
		}
		got := strings.join(kinds[:], " ", context.temp_allocator)
		testing.expectf(t, got == c.form, "%q: fields %q, want %q", c.line, got, c.form)
		cleanup(&app)
	}
	// A value on the next line (more indented): no dot added, round-trips.
	app: App
	defer cleanup(&app)
	app.state = .Editor
	text := "package main\n\nmain :: proc() {\n\tx :=\n\t\t1\n}"
	doc_from_source(&app, text)
	for n in app.doc.nodes do for f in n.fields do testing.expect(t, !(f.slot && f.kind == "value"), "no dot for a continued value")
	testing.expect_value(t, src(&app), text)
}

// A call argument's hint_pkg must outlive the frame. The app frees the temp
// allocator every frame; call_signature used to hand out the import line's
// per-frame path, so after one frame the dot's package was garbage and Enum
// value (and graying) found nothing. Free it between steps like the app does.
@(test)
test_integration_call_hint_pkg_survives_frames :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nimport \"vendor:sdl3\"\n\nmain :: proc() {\n\tsdl3.Init()\n}\n")
	free_all(context.temp_allocator)
	ni := line_with(&app, "sdl3.Init(")
	if !testing.expect(t, ni >= 0, "Init line") do return
	first_dot :: proc(app: ^App, ni: int) -> int {
		for f, i in app.doc.nodes[ni].fields do if f.slot && f.kind == "value" do return i
		return -1
	}
	// Operator > Bitwise > a | b, then Enum value on the left operand.
	focus_field_index(&app, ni, first_dot(&app, ni))
	update(&app, Input{confirm = true})
	free_all(context.temp_allocator)
	pick(t, &app, "Operator"); free_all(context.temp_allocator)
	pick(t, &app, "Bitwise"); free_all(context.temp_allocator)
	pick(t, &app, "a | b"); free_all(context.temp_allocator)
	update(&app, Input{}); free_all(context.temp_allocator)
	fi := first_dot(&app, ni)
	if !testing.expect(t, fi >= 0, "operand dot") do return
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].hint_pkg, "vendor:sdl3")
	focus_field_index(&app, ni, fi)
	update(&app, Input{confirm = true})
	free_all(context.temp_allocator)
	pick(t, &app, "Enum value")
	v := current_view(&app)
	if !testing.expect(t, v != nil, "Enum value submenu") do return
	testing.expectf(t, len(v.entries) == 8 && v.entries[1].label == "{.VIDEO}", "InitFlag members, got %d entries", len(v.entries))
	pick(t, &app, "{.VIDEO}")
	testing.expect_value(t, strings.trim_space(node_text(app.doc.nodes[ni], context.temp_allocator)), "sdl3.Init({.VIDEO} | )")
}


@(private = "file")
pick :: proc(t: ^testing.T, app: ^App, label: string, loc := #caller_location) {
	v := current_view(app)
	if !testing.expectf(t, v != nil, "no menu open (wanted %q)", label, loc = loc) do return
	for e, i in v.entries {
		if e.label == label {
			v.index = i
			update(app, Input{confirm = true})
			return
		}
	}
	testing.expectf(t, false, "no %q in menu %q", label, v.title, loc = loc)
}

// Types (menu-built polymorphic struct) + Modifiers (#align) on the same
// header, then another $ param through the header's params dot.
@(test)
test_integration_poly_struct_with_align_from_menus :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n")
	focus_dot(&app)
	update(&app, Input{confirm = true})
	pick(t, &app, "Types")
	pick(t, &app, "Polymorphic struct")
	h := line_with(&app, ":: struct($")
	if !testing.expect(t, h >= 0, "poly header") do return
	for f, i in app.doc.nodes[h].fields do if f.editable { set_field_text(&app, h, i, "Stack"); break }

	focus_dot(&app)
	update(&app, Input{confirm = true})
	pick(t, &app, "Modifiers")
	pick(t, &app, "Struct directives")
	testing.expect_value(t, app.mod_pick_line, h)
	update(&app, Input{confirm = true})
	pick(t, &app, "#align(N)")
	f := cursor_field_of(&app)
	testing.expect(t, f.slot && f.hint == "int", "on the alignment dot")
	update(&app, Input{confirm = true})
	pick(t, &app, "Number")
	ni, fi, _ := editor_target(&app)
	set_field_text(&app, ni, fi, "16")
	testing.expect_value(t, node_text(app.doc.nodes[h], context.temp_allocator), "Stack :: struct($T: typeid) #align(16) {")

	// The params dot still adds parameters before the `)`.
	for g, i in app.doc.nodes[h].fields do if g.slot && g.kind == "params" { focus_field_index(&app, h, i); break }
	update(&app, Input{confirm = true})
	pick(t, &app, "Type param")
	testing.expect(t, strings.has_prefix(node_text(app.doc.nodes[h], context.temp_allocator), "Stack :: struct($T: typeid, $"), "second param")
	testing.expect(t, strings.has_suffix(node_text(app.doc.nodes[h], context.temp_allocator), ": typeid) #align(16) {"), "directive kept")

	format_doc(&app)
	text := strings.clone(src(&app), context.temp_allocator)
	doc_from_source(&app, text)
	testing.expect_value(t, src(&app), text)
}

@(private = "file")
cursor_field_of :: proc(app: ^App) -> Field {
	ni, fi, ok := editor_target(app)
	if !ok do return {}
	return app.doc.nodes[ni].fields[fi]
}

@(private = "file")
top_entry :: proc(entries: []Entry, label: string) -> (Entry, bool) {
	for e in entries do if e.label == label do return e, true
	return {}, false
}

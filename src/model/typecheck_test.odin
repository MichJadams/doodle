package model

import "core:strings"
import "core:testing"

// Doc: package + `import win "core:sys/windows"` + `import "core:fmt"` + local
// helper proc + main whose body line is an empty body slot. Returns its index.
@(private = "file")
setup :: proc(app: ^App) -> int {
	app.state = .Editor
	doc_from_source(app, "package main\n\nimport win \"core:sys/windows\"\nimport \"core:fmt\"\n\nhelper :: proc(count: int, label: string) -> bool {\n}\n\nmain :: proc() {\n}")
	body: Node
	append(&body.fields, Field{strings.clone("\t"), false, false, "", "", ""})
	append(&body.fields, Field{"", false, true, "body", "", ""})
	ni := len(app.doc.nodes) - 1
	inject_at(&app.doc.nodes, ni, body)
	return ni
}

@(private = "file")
STR_LEAF :: "\"...\"  string"
@(private = "file")
RUNE_LEAF :: "'...'  rune"

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
slots_of :: proc(n: Node, kind: string) -> []Field {
	out := make([dynamic]Field, 0, 4, context.temp_allocator)
	for f in n.fields do if f.slot && f.kind == kind do append(&out, f)
	return out[:]
}

// Open the fill menu on the nth `kind` slot of line ni.
@(private = "file")
open_fill :: proc(app: ^App, ni: int, kind: string, nth: int) {
	focus_line(app, ni)
	k, seen := 0, 0
	for f in app.doc.nodes[ni].fields {
		if f.slot && f.kind == kind {
			if seen == nth { app.editor_field = k; break }
			seen += 1
		}
		if f.editable || f.slot do k += 1
	}
	update(app, Input{confirm = true})
}

// Find an entry by label anywhere in the current view's tree.
@(private = "file")
find :: proc(entries: []Entry, label: string) -> (Entry, bool) {
	for e in entries {
		if e.label == label do return e, true
		if r, ok := find(e.children, label); ok do return r, true
	}
	return {}, false
}

@(private = "file")
dimmed :: proc(t: ^testing.T, app: ^App, label: string) -> bool {
	e, ok := find(current_view(app).entries, label)
	testing.expectf(t, ok, "menu entry %q should exist", label)
	return e.dim
}

@(test)
test_messageboxw_dots_know_their_types :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	make_import_proc_call(&app, ni, 1, "win", "MessageBoxW")
	dots := slots_of(app.doc.nodes[ni], "value")
	testing.expect_value(t, len(dots), 4)
	if len(dots) != 4 do return
	testing.expect_value(t, dots[0].hint, "HWND")
	testing.expect_value(t, dots[1].hint, "LPCWSTR")
	testing.expect_value(t, dots[2].hint, "LPCWSTR")
	testing.expect_value(t, dots[3].hint, "UINT")
	testing.expect_value(t, dots[1].hint_pkg, "core:sys/windows")
}

@(test)
test_resolve_windows_types :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app)
	ctx := type_ctx_make(&app)
	W :: "core:sys/windows"
	r := resolve_type(&ctx, "LPCWSTR", W) // -> wstring -> cstring16
	testing.expect_value(t, r.cat, Type_Cat.CString16)
	testing.expect_value(t, r.canon, "cstring16")
	r = resolve_type(&ctx, "HWND", W)     // distinct HANDLE -> distinct LPVOID -> rawptr
	testing.expect_value(t, r.cat, Type_Cat.Pointer)
	testing.expect_value(t, r.canon, "core:sys/windows.HWND")
	r = resolve_type(&ctx, "UINT", W)     // c_uint -> c.uint -> builtin.u32
	testing.expect_value(t, r.cat, Type_Cat.Integer)
	testing.expect_value(t, r.canon, "u32")
	r = resolve_type(&ctx, "BOOL", W)     // distinct b32
	testing.expect_value(t, r.cat, Type_Cat.Bool)
	r = resolve_type(&ctx, "win.RECT", "") // via the document's import alias
	testing.expect_value(t, r.cat, Type_Cat.Struct)
	r = resolve_type(&ctx, "Not_A_Real_Type", W)
	testing.expect_value(t, r.cat, Type_Cat.Unknown)
}

@(test)
test_lptext_grays_out_bool_and_number :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	make_import_proc_call(&app, ni, 1, "win", "MessageBoxW")
	open_fill(&app, ni, "value", 1) // lpText: LPCWSTR

	testing.expect(t, dimmed(t, &app, "true"), "true can't be an LPCWSTR")
	testing.expect(t, dimmed(t, &app, "false"))
	testing.expect(t, dimmed(t, &app, "Number"))
	testing.expect(t, !dimmed(t, &app, "String"), "a string literal converts to cstring16")
	testing.expect(t, !dimmed(t, &app, "nil"), "cstring16 can be nil")
	testing.expect(t, !dimmed(t, &app, "Reference"), "variables: unknown type, never grayed")
	testing.expect(t, !dimmed(t, &app, "Call"), "some calls fit (win.L)")
	testing.expect(t, !dimmed(t, &app, "L"), "win.L returns cstring16")
	testing.expect(t, dimmed(t, &app, "MessageBoxW"), "MessageBoxW returns INT")
	testing.expect(t, dimmed(t, &app, "ensure_winsock_initialized"), "returns nothing: can't be an argument")
	testing.expect(t, !dimmed(t, &app, "utf8_to_wstring"), "returns wstring (= cstring16)")
	testing.expect(t, !dimmed(t, &app, "utf16_to_utf8"), "proc group: return type unknown, not grayed")
	testing.expect(t, dimmed(t, &app, "Type"), "a type isn't a value here")
}

@(test)
test_hwnd_and_uint_slots :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	make_import_proc_call(&app, ni, 1, "win", "MessageBoxW")

	open_fill(&app, ni, "value", 0) // hWnd: HWND
	testing.expect(t, !dimmed(t, &app, "nil"))
	testing.expect(t, dimmed(t, &app, "String"))
	testing.expect(t, dimmed(t, &app, "Number"))
	testing.expect(t, dimmed(t, &app, "true"))
	testing.expect(t, !dimmed(t, &app, "CreateWindowExW"), "returns HWND")
	testing.expect(t, dimmed(t, &app, "GetModuleHandleW"), "returns HMODULE, a different distinct type")
	update(&app, Input{cancel = true})
	for app.state == .Radial do update(&app, Input{cancel = true})

	open_fill(&app, ni, "value", 3) // uType: UINT
	testing.expect(t, !dimmed(t, &app, "Number"))
	testing.expect(t, dimmed(t, &app, STR_LEAF), "a string isn't a UINT")
	testing.expect(t, !dimmed(t, &app, RUNE_LEAF), "a rune constant converts to an integer")
	testing.expect(t, dimmed(t, &app, "nil"))
}

@(test)
test_println_any_grays_nothing :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	make_import_proc_call(&app, ni, 1, "fmt", "println")
	args := slots_of(app.doc.nodes[ni], "args")
	testing.expect_value(t, len(args), 1)
	if len(args) == 1 do testing.expect_value(t, args[0].hint, "any")
	open_fill(&app, ni, "args", 0)
	for label in ([]string{"Number", "String", "true", "nil", "Call"}) {
		testing.expectf(t, !dimmed(t, &app, label), "%s fits ..any", label)
	}
	// Fill it: the next green dot expects the same type.
	e, _ := find(current_view(&app).entries, "Number")
	_ = e
	v := current_view(&app)
	for en, i in v.entries do if en.label == "Number" { v.index = i; update(&app, Input{confirm = true}); break }
	args = slots_of(app.doc.nodes[ni], "args")
	testing.expect_value(t, len(args), 1)
	if len(args) == 1 do testing.expect_value(t, args[0].hint, "any")
}

@(test)
test_local_proc_params_have_types :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	make_call_this_package(&app, ni, 1, "helper")
	dots := slots_of(app.doc.nodes[ni], "value")
	testing.expect_value(t, len(dots), 2)
	if len(dots) != 2 do return
	testing.expect_value(t, dots[0].hint, "int")
	testing.expect_value(t, dots[1].hint, "string")
	open_fill(&app, ni, "value", 0) // count: int
	testing.expect(t, !dimmed(t, &app, "Number"))
	testing.expect(t, dimmed(t, &app, STR_LEAF))
	testing.expect(t, dimmed(t, &app, "true"))
}

@(test)
test_parse_params :: proc(t: ^testing.T) {
	ps := parse_params("x, y: f32, #any_int n: int, label := \"a, b\", args: ..any")
	testing.expect_value(t, len(ps), 5)
	if len(ps) != 5 do return
	testing.expect(t, ps[0].name == "x" && ps[0].type == "f32" && !ps[0].optional)
	testing.expect(t, ps[1].name == "y" && ps[1].type == "f32")
	testing.expect(t, ps[2].name == "n" && ps[2].type == "int")
	testing.expect(t, ps[3].name == "label" && ps[3].optional)
	testing.expect(t, ps[4].name == "args" && ps[4].type == "any" && ps[4].variadic)
}

package model

import "core:strings"
import "core:testing"

@(private = "file")
setup :: proc(app: ^App) -> int {
	app.state = .Editor
	doc_from_source(app, "package main\n\nimport win \"core:sys/windows\"\n\nmain :: proc() {\n}")
	body: Node
	append(&body.fields, Field{strings.clone("\t"), false, false, "", "", ""})
	append(&body.fields, Field{"", false, true, "body", "", ""})
	ni := len(app.doc.nodes) - 1
	inject_at(&app.doc.nodes, ni, body)
	return ni
}

@(private = "file")
cleanup :: proc(app: ^App) {
	clear_nav(app)
	delete(app.nav)
	doc_reset(app)
	delete(app.doc.nodes)
	delete(app.recent_imports)
	free_menus(app)
}

// Open the fill menu on the nth unfilled value dot of line ni.
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
pick :: proc(t: ^testing.T, app: ^App, label: string) {
	v := current_view(app)
	for e, i in v.entries {
		if e.label == label {
			v.index = i
			update(app, Input{confirm = true})
			return
		}
	}
	testing.expectf(t, false, "no %q in menu %q", label, v.title)
}

@(private = "file")
path_to :: proc(entries: []Entry, label, fill: string, out: ^[dynamic]string) -> bool {
	for e in entries {
		append(out, e.label)
		if len(e.children) == 0 && e.label == label && e.fill == fill do return true
		if len(e.children) > 0 && path_to(e.children, label, fill, out) do return true
		pop(out)
	}
	return false
}

// From the current view, walk down to the leaf `label` (by its labels).
@(private = "file")
pick_leaf :: proc(t: ^testing.T, app: ^App, label, fill: string) {
	p := make([dynamic]string, 0, 8, context.temp_allocator)
	if !testing.expectf(t, path_to(current_view(app).entries, label, fill, &p), "%s should be reachable", label) do return
	for step in p do pick(t, app, step)
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
dimmed :: proc(t: ^testing.T, app: ^App, label: string) -> bool {
	e, ok := find(current_view(app).entries, label)
	testing.expectf(t, ok, "menu entry %q should exist", label)
	return e.dim
}

@(private = "file")
close_menus :: proc(app: ^App) {
	for app.state == .Radial do update(app, Input{cancel = true})
}

@(test)
test_windows_constant_kinds :: proc(t: ^testing.T) {
	Want :: struct { name, kind: string }
	want := [?]Want{
		{"MB_OK", "#int"}, {"MB_ICONINFORMATION", "#int"}, {"TRUE", "BOOL"}, {"INVALID_HANDLE_VALUE", "HANDLE"},
	}
	found := 0
	for c in CORE_CONSTS {
		if c.path != "core:sys/windows" do continue
		for w in want do if w.name == c.name {
			testing.expectf(t, c.kind == w.kind, "%s kind = %q, want %q", c.name, c.kind, w.kind)
			found += 1
		}
	}
	testing.expect_value(t, found, len(want))
}

// The whole example:
//   win.MessageBoxW(nil, "This is Handmade Hero.", win.L("Handmade Hero"), win.MB_OK | win.MB_ICONINFORMATION)
@(test)
test_messageboxw_with_or_of_constants :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	make_import_proc_call(&app, ni, 1, "win", "MessageBoxW")

	open_value(&app, ni, 0); pick(t, &app, "nil")                                     // hWnd
	open_value(&app, ni, 0); pick(t, &app, "String"); pick(t, &app, "\"...\"  string") // lpText
	open_value(&app, ni, 0); pick(t, &app, "Call"); pick(t, &app, "From import")
	pick(t, &app, "win"); pick_leaf(t, &app, "L", "__call_import_proc__")              // lpCaption
	open_value(&app, ni, 0); pick(t, &app, "String"); pick(t, &app, "\"...\"  string") // L's value

	// uType: Operator -> Bitwise -> a | b  =>  ● UINT | ● UINT
	open_value(&app, ni, 0)
	pick(t, &app, "Operator"); pick(t, &app, "Bitwise"); pick(t, &app, "a | b")
	n_uint := 0
	for f in app.doc.nodes[ni].fields do if f.slot && f.kind == "value" && f.hint == "UINT" do n_uint += 1
	testing.expect_value(t, n_uint, 2)

	open_value(&app, ni, 0); pick(t, &app, "Constant"); pick(t, &app, "win.")
	pick_leaf(t, &app, "MB_OK", CONST_IMPORT_FILL)
	open_value(&app, ni, 0); pick(t, &app, "Constant"); pick(t, &app, "win.")
	pick_leaf(t, &app, "MB_ICONINFORMATION", CONST_IMPORT_FILL)

	src := doc_to_source(&app, context.temp_allocator)
	testing.expectf(t, strings.contains(src,
		"win.MessageBoxW(nil, \"\", win.L(\"\"), win.MB_OK | win.MB_ICONINFORMATION)"), "got:\n%s", src)
}

@(test)
test_constants_and_operators_are_grayed_by_type :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	make_import_proc_call(&app, ni, 1, "win", "MessageBoxW")

	open_value(&app, ni, 3) // uType: UINT
	testing.expect(t, !dimmed(t, &app, "Constant"))
	testing.expect(t, !dimmed(t, &app, "MB_OK"), "untyped int constant fits UINT")
	testing.expect(t, !dimmed(t, &app, "a | b"))
	testing.expect(t, dimmed(t, &app, "a == b"), "a comparison is a bool, not a UINT")
	testing.expect(t, dimmed(t, &app, "TRUE"), "TRUE is a BOOL")
	close_menus(&app)

	open_value(&app, ni, 1) // lpText: LPCWSTR
	testing.expect(t, dimmed(t, &app, "MB_OK"), "a number isn't an LPCWSTR")
	testing.expect(t, dimmed(t, &app, "Bitwise"), "no bitwise operator produces a cstring16")
	testing.expect(t, dimmed(t, &app, "Arithmetic"), "no arithmetic operator produces a cstring16")
	testing.expect(t, !dimmed(t, &app, "Choose"), "`a if c else b` can be a cstring16") // expr.odin
	close_menus(&app)

	open_value(&app, ni, 0) // hWnd: HWND
	testing.expect(t, dimmed(t, &app, "INVALID_HANDLE_VALUE"), "a HANDLE isn't an HWND (distinct types)")
}

@(test)
test_used_constant_is_pinned_first :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nimport win \"core:sys/windows\"\n\nX :: win.WM_PAINT\n\nmain :: proc() {\n}")
	body: Node
	append(&body.fields, Field{strings.clone("\t"), false, false, "", "", ""})
	append(&body.fields, Field{"", false, true, "body", "", ""})
	inject_at(&app.doc.nodes, len(app.doc.nodes) - 1, body)
	ni := len(app.doc.nodes) - 2
	make_import_proc_call(&app, ni, 1, "win", "MessageBoxW")
	open_value(&app, ni, 3)
	pick(t, &app, "Constant"); pick(t, &app, "win.")
	testing.expect_value(t, current_view(&app).entries[0].label, "WM_PAINT")
}

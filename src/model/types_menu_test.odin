package model

import "core:strings"
import "core:testing"

// Doc: package + `import win "core:sys/windows"` + a proc whose body line is `node`.
// Returns the index of that body line.
@(private = "file")
setup_win_doc :: proc(app: ^App, body: Node, extra_src := "") -> int {
	app.state = .Editor
	src := strings.concatenate({"package main\n\nimport win \"core:sys/windows\"\n", extra_src, "\nmain :: proc() {\n}"}, context.temp_allocator)
	doc_from_source(app, src)
	ni := len(app.doc.nodes) - 1 // before the closing brace
	inject_at(&app.doc.nodes, ni, body)
	return ni
}

@(private = "file")
cleanup_types :: proc(app: ^App) {
	clear_nav(app)
	delete(app.nav)
	doc_reset(app)
	delete(app.doc.nodes)
	delete(app.recent_imports)
	free_menus(app)
}

@(private = "file")
focus_slot :: proc(app: ^App, ni: int, kind: string, nth := 0) {
	focus_line(app, ni)
	k, seen := 0, 0
	for f in app.doc.nodes[ni].fields {
		if f.slot && f.kind == kind {
			if seen == nth { app.editor_field = k; return }
			seen += 1
		}
		if f.editable || f.slot do k += 1
	}
}

// Pick `label` in the current menu view; returns false if it isn't there.
@(private = "file")
pick :: proc(app: ^App, label: string) -> bool {
	v := current_view(app)
	if v == nil do return false
	for e, i in v.entries {
		if e.label == label {
			v.index = i
			update(app, Input{confirm = true})
			return true
		}
	}
	return false
}

// Depth-first search for a leaf; returns the labels leading to it (temp-allocated).
@(private = "file")
find_leaf :: proc(entries: []Entry, label, fill: string, path: ^[dynamic]string) -> bool {
	for e in entries {
		append(path, e.label)
		if len(e.children) == 0 && e.label == label && e.fill == fill do return true
		if len(e.children) > 0 && find_leaf(e.children, label, fill, path) do return true
		pop(path)
	}
	return false
}

// Navigate from the current view down to a leaf by label, picking each step.
@(private = "file")
navigate_to_leaf :: proc(t: ^testing.T, app: ^App, label, fill: string) -> []string {
	v := current_view(app)
	path := make([dynamic]string, 0, 8, context.temp_allocator)
	if !testing.expectf(t, find_leaf(v.entries, label, fill, &path), "%s should be reachable", label) do return nil
	for step in path do testing.expectf(t, pick(app, step), "menu step %q", step)
	return path[:]
}

// Index of the first value dot after the `L` field (win.L's argument).
@(private = "file")
first_value_after_L :: proc(n: Node) -> int {
	seen_L := false
	for f, i in n.fields {
		if f.text == "L" do seen_L = true
		if seen_L && f.slot && f.kind == "value" do return i
	}
	return 0
}

@(private = "file")
type_slot_line :: proc() -> Node {
	n: Node
	append(&n.fields, Field{strings.clone("\t"), false, false, "", "", ""})
	append(&n.fields, Field{strings.clone("hwnd"), true, false, "", "", ""})
	append(&n.fields, Field{strings.clone(": "), false, false, "", "", ""})
	append(&n.fields, Field{"", false, true, "type", "", ""})
	return n
}

@(test)
test_type_slot_offers_import_types :: proc(t: ^testing.T) {
	app: App
	defer cleanup_types(&app)
	ni := setup_win_doc(&app, type_slot_line())

	focus_slot(&app, ni, "type")
	update(&app, Input{confirm = true})
	testing.expect(t, pick(&app, "Type"))
	testing.expect(t, pick(&app, "win."), "imports appear as `win.` in the Type menu")
	navigate_to_leaf(t, &app, "HWND", TYPE_IMPORT_FILL)

	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, node_text(app.doc.nodes[ni], context.temp_allocator), "\thwnd: win.HWND")
}

@(test)
test_import_type_constants_are_not_types :: proc(t: ^testing.T) {
	found_hwnd, found_mb_ok := false, false
	for ty in CORE_TYPES {
		if ty.path != "core:sys/windows" do continue
		if ty.name == "HWND" || ty.name == "LPCWSTR" do found_hwnd = true
		if ty.name == "MB_OK" || ty.name == "MB_ICONINFORMATION" do found_mb_ok = true
	}
	testing.expect(t, found_hwnd, "HWND/LPCWSTR are types")
	testing.expect(t, !found_mb_ok, "MB_OK/MB_ICONINFORMATION are constants, not types")
}

@(test)
test_used_import_type_is_pinned_first :: proc(t: ^testing.T) {
	app: App
	defer cleanup_types(&app)
	// `win.RECT` is already used in this file -> listed first under "win.".
	ni := setup_win_doc(&app, type_slot_line(), "\nr: win.RECT\n")
	focus_slot(&app, ni, "type")
	update(&app, Input{confirm = true})
	pick(&app, "Type")
	pick(&app, "win.")
	v := current_view(&app)
	testing.expect(t, len(v.entries) > 1)
	testing.expect_value(t, v.entries[0].label, "RECT")
}

@(test)
test_messageboxw_second_arg_win_L_string :: proc(t: ^testing.T) {
	app: App
	defer cleanup_types(&app)
	body: Node
	append(&body.fields, Field{strings.clone("\t"), false, false, "", "", ""})
	append(&body.fields, Field{"", false, true, "body", "", ""})
	ni := setup_win_doc(&app, body)
	make_import_proc_call(&app, ni, 1, "win", "MessageBoxW")

	// 2nd argument dot -> Call -> Procedure from an import -> win -> ... -> L
	focus_slot(&app, ni, "value", 1)
	update(&app, Input{confirm = true})
	testing.expect(t, pick(&app, "Call"))
	testing.expect(t, pick(&app, "Procedure from an import"))
	testing.expect(t, pick(&app, "win"))
	path := navigate_to_leaf(t, &app, "L", "__call_import_proc__")
	testing.expect(t, len(path) <= 2, "L should be at most two steps below win (util -> L)")

	// L's argument dot (value: string; MessageBoxW's hWnd dot is #0) -> String -> "..."
	focus_slot(&app, ni, "value", 1)
	testing.expect_value(t, app.doc.nodes[ni].fields[first_value_after_L(app.doc.nodes[ni])].hint, "string")
	update(&app, Input{confirm = true})
	testing.expect(t, pick(&app, "String"))
	testing.expect(t, pick(&app, "\"...\"  string"))

	src := doc_to_source(&app, context.temp_allocator)
	testing.expectf(t, strings.contains(src, "win.MessageBoxW(, win.L(\"\"), , )"), "got:\n%s", src)

	// Once used, L is pinned at the top of win's procedures.
	focus_slot(&app, ni, "value", 1) // 3rd parameter is now the 2nd unfilled value dot
	update(&app, Input{confirm = true})
	pick(&app, "Call")
	pick(&app, "Procedure from an import")
	pick(&app, "win")
	v := current_view(&app)
	found_first := false
	for e in v.entries {
		if e.label == "MessageBoxW" || e.label == "L" { found_first = true; continue }
		break
	}
	testing.expect(t, found_first && (v.entries[0].label == "MessageBoxW" || v.entries[0].label == "L"),
		"procs already used in this file are listed first")
}

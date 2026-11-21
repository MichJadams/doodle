package model

import "core:strings"
import "core:testing"

@(private = "file")
SRC :: "package main\n\nimport \"core:sys/windows\"\n\nmain :: proc() {\n" +
	"\twindows.MessageBoxW(nil, windows.L(\"Testing\"), windows.L(\"Testing again\"), )\n" +
	"}"

@(private = "file")
setup :: proc(app: ^App) -> int {
	app.state = .Editor
	doc_from_source(app, SRC)
	for n, i in app.doc.nodes do if strings.contains(node_text(n, context.temp_allocator), "MessageBoxW") do return i
	return -1
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

// The text of the leaf under the cursor ("●" for a dot).
@(private = "file")
cursor_text :: proc(app: ^App) -> string {
	ni, u, ok := editor_leaf(app)
	if !ok do return "<none>"
	n := app.doc.nodes[ni]
	if u.fb - u.fa == 1 && n.fields[u.fa].slot do return "●"
	return fields_text(n, u.fa, u.fb)
}

@(private = "file")
pick :: proc(t: ^testing.T, app: ^App, label: string) -> bool {
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

@(private = "file")
pick_leaf :: proc(t: ^testing.T, app: ^App, label: string) -> bool {
	path_to :: proc(es: []Entry, label: string, out: ^[dynamic]string) -> bool {
		for e in es {
			append(out, e.label)
			if len(e.children) == 0 && e.label == label do return true
			if len(e.children) > 0 && path_to(e.children, label, out) do return true
			pop(out)
		}
		return false
	}
	p := make([dynamic]string, context.temp_allocator)
	if !path_to(current_view(app).entries, label, &p) do return false
	for step in p do if !pick(t, app, step) do return false
	return true
}

@(test)
test_dpad_highlights_name_and_every_argument :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	focus_line(&app, ni)
	got := make([dynamic]string, context.temp_allocator)
	for _ in 0 ..< 8 {
		append(&got, cursor_text(&app))
		update(&app, Input{right = true})
	}
	testing.expect_value(t, strings.join(got[:], " | ", context.temp_allocator),
		"MessageBoxW | nil | L | \"Testing\" | L | \"Testing again\" | ● | ●")
}

@(test)
test_y_on_proc_name_changes_it_and_resets_arguments :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	focus_line(&app, ni) // on MessageBoxW
	change_selected(&app)
	testing.expect_value(t, app.state, State.Radial)
	testing.expect_value(t, current_view(&app).title, "Change procedure")
	testing.expect(t, pick_leaf(t, &app, "MessageBoxExW"), "MessageBoxExW is offered")
	testing.expect_value(t, app.state, State.Editor)
	// MessageBoxExW(hWnd, lpText, lpCaption, uType, wLanguageId): the old arguments
	// are gone; five fresh dots typed for the new signature.
	n := app.doc.nodes[ni]
	testing.expectf(t, strings.contains(node_text(n, context.temp_allocator), "windows.MessageBoxExW(, , , , )"),
		"got %q", node_text(n, context.temp_allocator))
	hints := make([dynamic]string, context.temp_allocator)
	for f in n.fields do if f.slot && !is_capture_dot(f) do append(&hints, f.hint)
	testing.expect_value(t, strings.join(hints[:], ",", context.temp_allocator), "HWND,LPCWSTR,LPCWSTR,UINT,WORD")
	testing.expect_value(t, cursor_text(&app), "●") // ready to fill the first one
	_, u, _ := editor_leaf(&app)
	testing.expect_value(t, n.fields[u.fa].hint, "HWND")
}

@(test)
test_y_on_proc_name_to_fewer_params_resets_arguments :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	focus_line(&app, ni)
	change_selected(&app)
	testing.expect(t, pick_leaf(t, &app, "MessageBeep"), "MessageBeep is offered") // MessageBeep(uType: UINT)
	n := app.doc.nodes[ni]
	testing.expectf(t, strings.contains(node_text(n, context.temp_allocator), "windows.MessageBeep()"),
		"got %q", node_text(n, context.temp_allocator))
	dots := 0
	for f in n.fields do if f.slot && !is_capture_dot(f) { dots += 1; testing.expect_value(t, f.hint, "UINT") }
	testing.expect_value(t, dots, 1)
}

@(test)
test_y_on_argument_refills_and_cancel_restores :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	focus_line(&app, ni)
	update(&app, Input{right = true}) // nil
	testing.expect_value(t, cursor_text(&app), "nil")
	before := strings.clone(node_text(app.doc.nodes[ni], context.temp_allocator), context.temp_allocator)

	change_selected(&app) // Y
	testing.expect_value(t, app.state, State.Radial)
	f := app.doc.nodes[ni].fields[app.slot_fi]
	testing.expect(t, f.slot && f.hint == "HWND", "refilling hWnd: typed HWND")
	testing.expect(t, find_entry(current_view(&app).entries, "Number").dim, "a number can't be an HWND")

	for app.state == .Radial do update(&app, Input{cancel = true}) // B
	testing.expect_value(t, node_text(app.doc.nodes[ni], context.temp_allocator), before)
	testing.expect_value(t, cursor_text(&app), "nil")

	change_selected(&app) // Y again, and this time pick a fill
	testing.expect(t, pick(t, &app, "Reference"))
	testing.expect(t, !strings.contains(node_text(app.doc.nodes[ni], context.temp_allocator), "(nil,"), "nil was replaced")
}

@(test)
test_y_on_string_inside_nested_call :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	focus_line(&app, ni)
	for _ in 0 ..< 3 do update(&app, Input{right = true}) // "Testing" (L's argument)
	testing.expect_value(t, cursor_text(&app), "\"Testing\"")
	change_selected(&app)
	f := app.doc.nodes[ni].fields[app.slot_fi]
	testing.expect_value(t, f.hint, "string") // L(value: string)
	testing.expect(t, !find_entry(current_view(&app).entries, "String").dim)
	testing.expect(t, find_entry(current_view(&app).entries, "true").dim)
}

@(test)
test_rt_tree_navigation :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	focus_line(&app, 0) // package main
	rt :: proc(app: ^App, inp: Input) { inp := inp; inp.rt_held = true; update(app, inp) }
	sel :: proc(app: ^App) -> Sel { s, _ := tree_selection(app); return s }

	testing.expect_value(t, sel(&app).kind, Sel_Kind.Line) // `package main`
	rt(&app, Input{down = true})                           // import
	rt(&app, Input{down = true})                           // main :: proc() { ... }
	testing.expect_value(t, sel(&app).kind, Sel_Kind.Block)
	rt(&app, Input{right = true}) // into main: its header line
	testing.expect_value(t, sel(&app).kind, Sel_Kind.Line)
	testing.expect_value(t, sel(&app).ni, ni - 1)
	rt(&app, Input{down = true})  // the MessageBoxW statement
	testing.expect_value(t, sel(&app).ni, ni)
	rt(&app, Input{right = true}) // into the statement: MessageBoxW
	testing.expect_value(t, cursor_text(&app), "MessageBoxW")
	rt(&app, Input{down = true})  // nil
	rt(&app, Input{down = true})  // windows.L("Testing") as a whole
	s := sel(&app)
	testing.expect_value(t, fields_text(app.doc.nodes[ni], s.fa, s.fb), "windows.L(\"Testing\")")
	rt(&app, Input{right = true}) // into it: L
	testing.expect_value(t, cursor_text(&app), "L")
	rt(&app, Input{down = true})  // "Testing"
	testing.expect_value(t, cursor_text(&app), "\"Testing\"")
	rt(&app, Input{left = true})  // back out to windows.L("Testing")
	s = sel(&app)
	testing.expect_value(t, fields_text(app.doc.nodes[ni], s.fa, s.fb), "windows.L(\"Testing\")")

	// Released RT: the whole argument stays highlighted, and Y refills all of it.
	h, ok := current_highlight(&app, false)
	testing.expect(t, ok && h.fa == s.fa && h.fb == s.fb)
	change_selected(&app)
	testing.expect_value(t, app.state, State.Radial)
	testing.expect(t, pick(t, &app, "nil"))
	testing.expectf(t, strings.contains(node_text(app.doc.nodes[ni], context.temp_allocator), "windows.MessageBoxW(nil, nil, windows.L(\"Testing again\"), )"),
		"got %q", node_text(app.doc.nodes[ni], context.temp_allocator))

	// A plain D-pad move drops back to single parts.
	update(&app, Input{right = true})
	testing.expect(t, !app.tree_sticky)
}

@(private = "file")
find_entry :: proc(es: []Entry, label: string) -> Entry {
	for e in es {
		if e.label == label do return e
		if len(e.children) > 0 {
			if r := find_entry(e.children, label); r.label != "" do return r
		}
	}
	return {}
}

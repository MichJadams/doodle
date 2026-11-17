package model

import "core:testing"
import "core:fmt"
import "core:strings"

@(private = "file")
confirm :: proc(app: ^App) { update(app, Input{confirm = true}) }

@(private = "file")
imp :: proc(label, path: string) -> Entry { return Entry{label = label, import_path = path} }

@(private = "file")
add_package :: proc(app: ^App) {
	confirm(app) // Editor: open Add root
	confirm(app) // root: File Setup -> submenu
	confirm(app) // submenu: Package declaration
}

@(test)
test_new_project_enters_editor :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Menu
	confirm(&app)
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 0)
}

@(test)
test_menu_cancel_quits :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Menu
	update(&app, Input{cancel = true})
	testing.expect(t, app.want_quit, "cancel on main menu should quit")
}

@(test)
test_add_package_inserts_text :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	confirm(&app) // open Add root
	testing.expect_value(t, app.state, State.Radial)
	confirm(&app) // File Setup
	confirm(&app) // Package declaration
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.nav), 0)
	testing.expect_value(t, len(app.doc.nodes), 1)
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect_value(t, txt, "package main")
}

@(test)
test_package_main_is_editable :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_package(&app)
	// exactly one editable field ("main"); "package " is fixed
	testing.expect_value(t, num_editable(&app), 1)
	// green dot focused after insert (editor_sel == count)
	_, _, ok0 := editor_target(&app)
	testing.expect(t, !ok0, "dot should be focused right after insert")
	// press Up -> highlight the editable field
	update(&app, Input{up = true})
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok, "up should highlight the editable field")
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].text, "main")
}

@(test)
test_set_field_text_replaces :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_package(&app)
	update(&app, Input{up = true}) // highlight "main"
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok)
	set_field_text(&app, ni, fi, "brave_otter")
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect_value(t, txt, "package brave_otter")
}

@(test)
test_nodes_stack :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_package(&app)
	add_package(&app)
	testing.expect_value(t, len(app.doc.nodes), 2)
}

@(test)
test_ide_menu_exit :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	update(&app, Input{left = true, lt_held = true})
	testing.expect_value(t, app.state, State.Radial)
	confirm(&app) // Exit
	testing.expect(t, app.want_quit, "selecting Exit should quit")
}

@(test)
test_ide_menu_cancel_returns :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	update(&app, Input{left = true, lt_held = true})
	update(&app, Input{cancel = true})
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.nav), 0)
	testing.expect(t, !app.want_quit)
}

// ---- Import / core tree ----

@(test)
test_core_tree_has_fmt :: proc(t: ^testing.T) {
	tree := build_core_tree()
	defer free_entries(tree)
	testing.expect(t, tree_contains_path(tree, "core:fmt"), "core tree should contain core:fmt")
}

@(test)
test_import_core_navigates_to_leaf :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.os_name = "windows"
	app.state = .Editor
	confirm(&app)                 // Add root
	select_label(&app, "File Setup")
	select_label(&app, "Import")
	select_label(&app, "core")
	drill_to_path(&app, "core:fmt")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 1)
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect_value(t, txt, "import \"core:fmt\"")
}

@(test)
test_bucketing_large_menu :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	raw := make([]Entry, 30)
	defer delete(raw)
	for i in 0 ..< 30 {
		raw[i] = Entry{label = fmt.aprintf("a%02d", i), insert = fmt.aprintf("x%02d", i)}
	}
	defer for e in raw { delete(e.label); delete(e.insert) }
	v := make_view(&app, "big", raw)
	defer free_view(&v)
	testing.expect(t, len(v.entries) < 30, "large menu should collapse into buckets")
	testing.expect(t, len(v.entries) >= 2, "should have at least 2 buckets")
	testing.expect(t, len(v.entries[0].children) > 0, "bucket should contain children")
}

@(test)
test_usage_first :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	append_text_node(&app, import_text("core:zzz", context.temp_allocator)) // mark as already imported
	raw := make_slice(imp("aaa", "core:aaa"), imp("zzz", "core:zzz"), imp("mmm", "core:mmm"))
	defer delete(raw)
	v := make_view(&app, "u", raw)
	defer free_view(&v)
	testing.expect_value(t, v.entries[0].label, "zzz") // already-imported floats to top
}

// ---- helpers ----

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
free_view :: proc(v: ^MenuView) {
	delete(v.entries)
	if v.rest != nil do delete(v.rest)
	for s in v.labels do delete(s)
	delete(v.labels)
}

@(private = "file")
select_label :: proc(app: ^App, label: string) {
	v := current_view(app)
	for e, i in v.entries {
		if e.label == label {
			v.index = i
			confirm(app)
			return
		}
	}
}

@(private = "file")
drill_to_path :: proc(app: ^App, path: string) {
	for _ in 0 ..< 40 {
		v := current_view(app)
		if v == nil do return
		for e, i in v.entries {
			if e.import_path == path {
				v.index = i
				confirm(app)
				return
			}
		}
		opened := false
		for e, i in v.entries {
			if len(e.children) > 0 && tree_contains_path(e.children, path) {
				v.index = i
				confirm(app)
				opened = true
				break
			}
		}
		if !opened do return
	}
}

@(private = "file")
tree_contains_path :: proc(entries: []Entry, path: string) -> bool {
	for e in entries {
		if e.import_path == path do return true
		if tree_contains_path(e.children, path) do return true
	}
	return false
}

// ---- Procedure construct tests ----

@(private = "file")
add_proc :: proc(app: ^App) {
	confirm(app)                        // Editor: open Add root
	select_label(app, "Procedures")     // root: Procedures -> submenu
	select_label(app, "Procedure")      // submenu: Procedure
}

@(test)
test_proc_inserts_three_nodes :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 3)
}

@(test)
test_proc_has_four_selectable_fields :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// 1 editable name + 3 slots = 4 selectable
	testing.expect_value(t, num_editable(&app), 4)
}

@(test)
test_proc_green_dot_focused_after_insert :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// editor_sel should equal num_editable (green dot position)
	testing.expect_value(t, app.editor_sel, num_editable(&app))
	_, _, ok := editor_target(&app)
	testing.expect(t, !ok, "green dot should be focused right after insert")
}

@(test)
test_proc_first_line_text :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect(t, strings.contains(txt, "do_thing"), "proc name should be do_thing")
	testing.expect(t, strings.contains(txt, "proc("), "should contain proc(")
}

@(test)
test_proc_name_editable_slots_are_slots :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// Navigate up 4 times to select all fields
	update(&app, Input{up = true}) // body slot
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok)
	testing.expect(t, app.doc.nodes[ni].fields[fi].slot, "should be a slot")
	testing.expect(t, !app.doc.nodes[ni].fields[fi].editable, "slot should not be editable")

	update(&app, Input{up = true}) // return slot
	ni, fi, ok = editor_target(&app)
	testing.expect(t, ok)
	testing.expect(t, app.doc.nodes[ni].fields[fi].slot, "should be a slot")

	update(&app, Input{up = true}) // params slot
	ni, fi, ok = editor_target(&app)
	testing.expect(t, ok)
	testing.expect(t, app.doc.nodes[ni].fields[fi].slot, "should be a slot")

	update(&app, Input{up = true}) // name (editable)
	ni, fi, ok = editor_target(&app)
	testing.expect(t, ok)
	testing.expect(t, app.doc.nodes[ni].fields[fi].editable, "name should be editable")
	testing.expect(t, !app.doc.nodes[ni].fields[fi].slot, "name should not be a slot")
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].text, "do_thing")
}

@(test)
test_proc_set_field_text_on_name :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// Navigate up to the name field (4 up presses from green dot)
	for _ in 0..<4 do update(&app, Input{up = true})
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok)
	set_field_text(&app, ni, fi, "my_func")
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect(t, strings.contains(txt, "my_func"), "proc name should be updated")
}

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
	select_label(&app, "Dependencies")
	select_label(&app, "Import")
	select_label(&app, "core")
	drill_to_path(&app, "core:fmt")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 1)
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect_value(t, txt, "import \"core:fmt\"")
}

@(test)
test_file_setup_no_import :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	confirm(&app)                 // Add root
	select_label(&app, "File Setup")
	v := current_view(&app)
	// Check that File Setup does not contain Import
	for e in v.entries {
		testing.expect(t, e.label != "Import", "File Setup should not contain Import")
	}
	// File Setup should have exactly 3 entries: Package declaration, File tags, Comments
	testing.expect_value(t, len(v.entries), 3)
}

@(test)
test_dependencies_contains_import_and_aliased :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	confirm(&app)                 // Add root
	select_label(&app, "Dependencies")
	v := current_view(&app)
	// Check that Dependencies contains Import
	found_import := false
	for e in v.entries {
		if e.label == "Import" {
			found_import = true
			break
		}
	}
	testing.expect(t, found_import, "Dependencies should contain Import")
}

@(test)
test_aliased_import_inserts_with_editable_alias :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.os_name = "windows"
	app.state = .Editor
	confirm(&app)                 // Add root
	select_label(&app, "Dependencies")
	select_label(&app, "Aliased import")
	select_label(&app, "core")
	drill_to_path(&app, "core:fmt")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 1)
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect_value(t, txt, "import fmt \"core:fmt\"")
	// Check that the second field (alias) is editable
	testing.expect_value(t, len(app.doc.nodes[0].fields), 3)
	testing.expect_value(t, app.doc.nodes[0].fields[1].editable, true)
	testing.expect_value(t, app.doc.nodes[0].fields[1].text, "fmt")
}

@(test)
test_aliased_import_alias_can_be_edited :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.os_name = "windows"
	app.state = .Editor
	confirm(&app)                 // Add root
	select_label(&app, "Dependencies")
	select_label(&app, "Aliased import")
	select_label(&app, "core")
	drill_to_path(&app, "core:fmt")
	// Navigate to the alias field and edit it
	update(&app, Input{up = true})
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok, "should have selected the alias field")
	set_field_text(&app, ni, fi, "f")
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect_value(t, txt, "import f \"core:fmt\"")
}

@(test)
test_plain_import_still_works :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.os_name = "windows"
	app.state = .Editor
	confirm(&app)                 // Add root
	select_label(&app, "Dependencies")
	select_label(&app, "Import")
	select_label(&app, "core")
	drill_to_path(&app, "core:fmt")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 1)
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect_value(t, txt, "import \"core:fmt\"")
}

@(test)
test_alias_default_extracts_last_segment :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.os_name = "windows"
	app.state = .Editor
	confirm(&app)                 // Add root
	select_label(&app, "Dependencies")
	select_label(&app, "Aliased import")
	select_label(&app, "core")
	// Navigate to sys/windows if reachable
	drill_to_path(&app, "core:sys/windows")
	if len(app.doc.nodes) == 1 {
		txt := node_text(app.doc.nodes[0], context.temp_allocator)
		testing.expect_value(t, txt, "import windows \"core:sys/windows\"")
		testing.expect_value(t, app.doc.nodes[0].fields[1].text, "windows")
	}
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
	// green insertion dot focused: editor_line is past the last node
	testing.expect_value(t, app.editor_line, len(app.doc.nodes))
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
	// Up/Down move between lines; Left/Right move between dots on a line.
	update(&app, Input{up = true}) // from green dot -> body slot line (node 1)
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok)
	testing.expect(t, app.doc.nodes[ni].fields[fi].slot, "body should be a slot")
	testing.expect(t, !app.doc.nodes[ni].fields[fi].editable, "slot should not be editable")

	update(&app, Input{up = true}) // -> signature line (node 0), first dot = name
	ni, fi, ok = editor_target(&app)
	testing.expect(t, ok)
	testing.expect(t, app.doc.nodes[ni].fields[fi].editable, "name should be editable")
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].text, "do_thing")

	update(&app, Input{right = true}) // -> params slot
	ni, fi, ok = editor_target(&app)
	testing.expect(t, ok)
	testing.expect(t, app.doc.nodes[ni].fields[fi].slot, "params should be a slot")

	update(&app, Input{right = true}) // -> return slot
	ni, fi, ok = editor_target(&app)
	testing.expect(t, ok)
	testing.expect(t, app.doc.nodes[ni].fields[fi].slot, "return should be a slot")
}

@(test)
test_proc_set_field_text_on_name :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// Up to the body line, up again to the signature line (first dot = name).
	update(&app, Input{up = true})
	update(&app, Input{up = true})
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok)
	testing.expect(t, app.doc.nodes[ni].fields[fi].editable, "should be on the editable name")
	set_field_text(&app, ni, fi, "my_func")
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect(t, strings.contains(txt, "my_func"), "proc name should be updated")
}

// ---- Platform filtering tests ----

@(test)
test_platform_ok_empty_matches_all :: proc(t: ^testing.T) {
	app: App
	app.os_name = "linux"
	e := Entry{label = "test", platform = ""}
	testing.expect(t, platform_ok(&app, e), "empty platform should match all OS")
}

@(test)
test_platform_ok_exact_match :: proc(t: ^testing.T) {
	app: App
	app.os_name = "linux"
	e := Entry{label = "test", platform = "linux"}
	testing.expect(t, platform_ok(&app, e), "linux platform should match linux OS")
}

@(test)
test_platform_ok_no_match :: proc(t: ^testing.T) {
	app: App
	app.os_name = "linux"
	e := Entry{label = "test", platform = "windows"}
	testing.expect(t, !platform_ok(&app, e), "windows platform should not match linux OS")
}

@(test)
test_platform_ok_comma_list :: proc(t: ^testing.T) {
	app: App
	app.os_name = "linux"
	e := Entry{label = "test", platform = "darwin,freebsd,linux"}
	testing.expect(t, platform_ok(&app, e), "comma-separated list should match if OS is in list")
}

@(test)
test_platform_ok_comma_list_no_match :: proc(t: ^testing.T) {
	app: App
	app.os_name = "windows"
	e := Entry{label = "test", platform = "darwin,freebsd,linux"}
	testing.expect(t, !platform_ok(&app, e), "comma-separated list should not match if OS not in list")
}

@(test)
test_make_view_filters_platforms :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.os_name = "linux"
	
	raw := make_slice(
		imp("linux_only", "core:linux"),
		imp("windows_only", "core:windows"),
		imp("all_platforms", "core:fmt"),
	)
	raw[0].platform = "linux"
	raw[1].platform = "windows"
	raw[2].platform = ""
	defer delete(raw)
	
	v := make_view(&app, "test", raw)
	defer free_view(&v)
	
	// Should have linux_only and all_platforms, but not windows_only
	testing.expect_value(t, len(v.entries), 2)
	found_linux := false
	found_all := false
	for e in v.entries {
		if e.label == "linux_only" do found_linux = true
		if e.label == "all_platforms" do found_all = true
		if e.label == "windows_only" do testing.fail(t)
	}
	testing.expect(t, found_linux, "should include linux-specific entry")
	testing.expect(t, found_all, "should include all-platform entry")
}

// ---- Bucketing tests ----

@(test)
test_no_bucketing_for_small_menu :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	
	// 10 items - below threshold
	raw := make([]Entry, 10)
	defer delete(raw)
	for i in 0 ..< 10 {
		raw[i] = Entry{label = fmt.aprintf("item_%02d", i), insert = "x"}
	}
	defer for e in raw { delete(e.label) }
	
	v := make_view(&app, "small", raw)
	defer free_view(&v)
	
	// Should not create buckets
	testing.expect_value(t, len(v.entries), 10)
	testing.expect(t, len(v.entries[0].children) == 0, "no buckets for small menu")
}

@(test)
test_bucketing_for_large_menu :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	
	// 30 items - above threshold (12)
	raw := make([]Entry, 30)
	defer delete(raw)
	for i in 0 ..< 30 {
		// Use names that sort alphabetically: a00, a01, ..., a29
		raw[i] = Entry{label = fmt.aprintf("item%02d", i), insert = "x"}
	}
	defer for e in raw { delete(e.label) }
	
	v := make_view(&app, "large", raw)
	defer free_view(&v)
	
	// Should create buckets (less than 30 entries)
	testing.expect(t, len(v.entries) < 30, "large menu should be bucketed")
	testing.expect(t, len(v.entries) >= 2, "should have at least 2 buckets")
	
	// First entry should be a bucket (have children)
	testing.expect(t, len(v.entries[0].children) > 0, "entries should be buckets with children")
	
	// Check bucket sizes are roughly equal (within 3 of each other)
	if len(v.entries) >= 2 {
		min_size := 999
		max_size := 0
		for e in v.entries {
			if len(e.children) > 0 {
				size := len(e.children)
				if size < min_size do min_size = size
				if size > max_size do max_size = size
			}
		}
		testing.expect(t, max_size - min_size <= 3, 
			"bucket sizes should be roughly equal (within 3)")
	}
}

// ---- Type construct tests ----

@(private = "file")
add_type :: proc(app: ^App, label: string) {
	confirm(app)                    // Editor: open Add root
	select_label(app, "Types")      // root: Types -> submenu
	select_label(app, label)        // submenu: type construct
}

@(test)
test_struct_inserts_three_nodes :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Struct")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 3)
}

@(test)
test_struct_has_two_selectable_fields :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Struct")
	// 1 editable name + 1 body slot = 2 selectable
	testing.expect_value(t, num_editable(&app), 2)
}

@(test)
test_struct_green_dot_focused_after_insert :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Struct")
	// green insertion dot focused: editor_line is past the last node
	testing.expect_value(t, app.editor_line, len(app.doc.nodes))
	_, _, ok := editor_target(&app)
	testing.expect(t, !ok, "green dot should be focused right after insert")
}

@(test)
test_struct_first_line_text :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Struct")
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect(t, strings.contains(txt, "MyType"), "struct name should be MyType")
	testing.expect(t, strings.contains(txt, "struct {"), "should contain struct {")
}

@(test)
test_struct_name_editable_body_is_slot :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Struct")
	// Up from green dot -> body slot line (node 1)
	update(&app, Input{up = true})
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok)
	testing.expect(t, app.doc.nodes[ni].fields[fi].slot, "body should be a slot")
	testing.expect(t, !app.doc.nodes[ni].fields[fi].editable, "slot should not be editable")

	// Up again -> name line (node 0), first dot = name
	update(&app, Input{up = true})
	ni, fi, ok = editor_target(&app)
	testing.expect(t, ok)
	testing.expect(t, app.doc.nodes[ni].fields[fi].editable, "name should be editable")
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].text, "MyType")
}

@(test)
test_enum_inserts_three_nodes :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Enum")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 3)
}

@(test)
test_enum_has_two_selectable_fields :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Enum")
	// 1 editable name + 1 body slot = 2 selectable
	testing.expect_value(t, num_editable(&app), 2)
}

@(test)
test_enum_first_line_text :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Enum")
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect(t, strings.contains(txt, "MyType"), "enum name should be MyType")
	testing.expect(t, strings.contains(txt, "enum {"), "should contain enum {")
}

@(test)
test_union_inserts_three_nodes :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Union")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 3)
}

@(test)
test_union_has_two_selectable_fields :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Union")
	// 1 editable name + 1 body slot = 2 selectable
	testing.expect_value(t, num_editable(&app), 2)
}

@(test)
test_union_first_line_text :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Union")
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect(t, strings.contains(txt, "MyType"), "union name should be MyType")
	testing.expect(t, strings.contains(txt, "union {"), "should contain union {")
}

@(test)
test_bit_set_inserts_one_node :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Bit set")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 1)
}

@(test)
test_bit_set_has_two_selectable_fields :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Bit set")
	// 1 editable name + 1 element type slot = 2 selectable
	testing.expect_value(t, num_editable(&app), 2)
}

@(test)
test_bit_set_text :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Bit set")
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect(t, strings.contains(txt, "MyType"), "bit_set name should be MyType")
	testing.expect(t, strings.contains(txt, "bit_set["), "should contain bit_set[")
	testing.expect(t, strings.contains(txt, "]"), "should contain ]")
}

@(test)
test_distinct_inserts_one_node :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Distinct type")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 1)
}

@(test)
test_distinct_has_two_selectable_fields :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Distinct type")
	// 1 editable name + 1 base type slot = 2 selectable
	testing.expect_value(t, num_editable(&app), 2)
}

@(test)
test_distinct_text :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Distinct type")
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect(t, strings.contains(txt, "MyType"), "distinct name should be MyType")
	testing.expect(t, strings.contains(txt, "distinct"), "should contain distinct")
}

@(test)
test_alias_inserts_one_node :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Type alias")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 1)
}

@(test)
test_alias_has_two_selectable_fields :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Type alias")
	// 1 editable name + 1 type slot = 2 selectable
	testing.expect_value(t, num_editable(&app), 2)
}

@(test)
test_alias_text :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Type alias")
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect(t, strings.contains(txt, "MyType"), "alias name should be MyType")
	testing.expect(t, strings.contains(txt, "::"), "should contain ::")
}

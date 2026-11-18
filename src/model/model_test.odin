package model

import "core:testing"
import "core:fmt"
import "core:strings"
import "core:slice"

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
	// Check that proc name is generated (adjective_animal pattern)
	proc_name := app.doc.nodes[0].fields[0].text
	testing.expect(t, len(proc_name) > 0, "proc should have a name")
	testing.expect(t, strings.contains(proc_name, "_"), "proc name should be snake_case")
	testing.expect(t, strings.contains(txt, ":: proc("), "should contain :: proc(")
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
	// Check that name is generated snake_case
	proc_name := app.doc.nodes[ni].fields[fi].text
	testing.expect(t, len(proc_name) > 0, "name should not be empty")
	testing.expect(t, strings.contains(proc_name, "_"), "name should be snake_case")

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
	// Check that type name is generated (PascalCase)
	type_name := app.doc.nodes[0].fields[0].text
	testing.expect(t, len(type_name) > 0, "struct should have a name")
	testing.expect(t, type_name[0] >= 'A' && type_name[0] <= 'Z', "type name should be PascalCase")
	testing.expect(t, strings.contains(txt, ":: struct {"), "should contain :: struct {")
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
	// Check that name is generated PascalCase
	type_name := app.doc.nodes[ni].fields[fi].text
	testing.expect(t, len(type_name) > 0, "name should not be empty")
	testing.expect(t, type_name[0] >= 'A' && type_name[0] <= 'Z', "name should be PascalCase")
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
	// Check that type name is generated (PascalCase)
	type_name := app.doc.nodes[0].fields[0].text
	testing.expect(t, len(type_name) > 0, "enum should have a name")
	testing.expect(t, type_name[0] >= 'A' && type_name[0] <= 'Z', "type name should be PascalCase")
	testing.expect(t, strings.contains(txt, ":: enum {"), "should contain :: enum {")
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
	// Check that type name is generated (PascalCase)
	type_name := app.doc.nodes[0].fields[0].text
	testing.expect(t, len(type_name) > 0, "union should have a name")
	testing.expect(t, type_name[0] >= 'A' && type_name[0] <= 'Z', "type name should be PascalCase")
	testing.expect(t, strings.contains(txt, ":: union {"), "should contain :: union {")
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
	// Check that type name is generated (PascalCase)
	type_name := app.doc.nodes[0].fields[0].text
	testing.expect(t, len(type_name) > 0, "bit_set should have a name")
	testing.expect(t, type_name[0] >= 'A' && type_name[0] <= 'Z', "type name should be PascalCase")
	testing.expect(t, strings.contains(txt, ":: bit_set["), "should contain :: bit_set[")
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
	// Check that type name is generated (PascalCase)
	type_name := app.doc.nodes[0].fields[0].text
	testing.expect(t, len(type_name) > 0, "distinct should have a name")
	testing.expect(t, type_name[0] >= 'A' && type_name[0] <= 'Z', "type name should be PascalCase")
	testing.expect(t, strings.contains(txt, ":: distinct"), "should contain :: distinct")
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
	// Check that type name is generated (PascalCase)
	type_name := app.doc.nodes[0].fields[0].text
	testing.expect(t, len(type_name) > 0, "alias should have a name")
	testing.expect(t, type_name[0] >= 'A' && type_name[0] <= 'Z', "type name should be PascalCase")
	testing.expect(t, strings.contains(txt, "::"), "should contain ::")
}

// ---- Value tests ----

add_value :: proc(app: ^App, label: string) {
	confirm(app)                    // Editor: open Add root
	select_label(app, "Values")     // root: Values -> submenu
	select_label(app, label)        // submenu: value construct
}

@(test)
test_const_inserts_and_returns :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_value(&app, "Constant")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 1)
	testing.expect_value(t, app.editor_line, len(app.doc.nodes))
}

@(test)
test_const_has_name_and_slot :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_value(&app, "Constant")
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	// Check that const name is generated (UPPER_SNAKE)
	const_name := app.doc.nodes[0].fields[0].text
	testing.expect(t, len(const_name) > 0, "const should have a name")
	testing.expect(t, const_name[0] >= 'A' && const_name[0] <= 'Z', "const name should be UPPER_SNAKE")
	testing.expect(t, strings.contains(const_name, "_"), "const name should contain _")
	testing.expect(t, strings.contains(txt, "::"), "const should contain ::")
	// 1 editable name + 1 value slot = 2 selectable
	testing.expect_value(t, num_editable(&app), 2)
}

@(test)
test_typed_const_inserts_and_returns :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_value(&app, "Typed constant")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 1)
	testing.expect_value(t, app.editor_line, len(app.doc.nodes))
}

@(test)
test_typed_const_has_name_and_two_slots :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_value(&app, "Typed constant")
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	// Check that const name is generated (UPPER_SNAKE)
	const_name := app.doc.nodes[0].fields[0].text
	testing.expect(t, len(const_name) > 0, "const should have a name")
	testing.expect(t, const_name[0] >= 'A' && const_name[0] <= 'Z', "const name should be UPPER_SNAKE")
	testing.expect(t, strings.contains(const_name, "_"), "const name should contain _")
	testing.expect(t, strings.contains(txt, " : "), "typed const should contain ' : ' pattern")
	// 1 editable name + 1 type slot + 1 value slot = 3 selectable
	testing.expect_value(t, num_editable(&app), 3)
}

@(test)
test_config_const_inserts_and_returns :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_value(&app, "Build-config constant")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 1)
	testing.expect_value(t, app.editor_line, len(app.doc.nodes))
}

@(test)
test_config_const_has_config_syntax :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_value(&app, "Build-config constant")
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	// Check that const name is generated (UPPER_SNAKE)
	const_name := app.doc.nodes[0].fields[0].text
	testing.expect(t, len(const_name) > 0, "config const should have a name")
	testing.expect(t, const_name[0] >= 'A' && const_name[0] <= 'Z', "const name should be UPPER_SNAKE")
	testing.expect(t, strings.contains(const_name, "_"), "const name should contain _")
	testing.expect(t, strings.contains(txt, "#config("), "config const should contain #config(")
	// 1 editable name + 1 default value slot = 2 selectable
	testing.expect_value(t, num_editable(&app), 2)
}

@(test)
test_global_typed_inserts_and_returns :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_value(&app, "Global variable (typed)")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 1)
	testing.expect_value(t, app.editor_line, len(app.doc.nodes))
}

@(test)
test_global_typed_has_name_and_type_slot :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_value(&app, "Global variable (typed)")
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	// Check that var name is generated (snake_case)
	var_name := app.doc.nodes[0].fields[0].text
	testing.expect(t, len(var_name) > 0, "global typed should have a name")
	testing.expect(t, strings.contains(var_name, "_"), "var name should be snake_case")
	testing.expect(t, strings.contains(txt, ":"), "global typed should contain :")
	// 1 editable name + 1 type slot = 2 selectable
	testing.expect_value(t, num_editable(&app), 2)
}

@(test)
test_global_init_inserts_and_returns :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_value(&app, "Global variable (init)")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 1)
	testing.expect_value(t, app.editor_line, len(app.doc.nodes))
}

@(test)
test_global_init_has_walrus :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_value(&app, "Global variable (init)")
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	// Check that var name is generated (snake_case)
	var_name := app.doc.nodes[0].fields[0].text
	testing.expect(t, len(var_name) > 0, "global init should have a name")
	testing.expect(t, strings.contains(var_name, "_"), "var name should be snake_case")
	testing.expect(t, strings.contains(txt, ":="), "global init should contain :=")
	// 1 editable name + 1 value slot = 2 selectable
	testing.expect_value(t, num_editable(&app), 2)
}

// ---- Slot filling tests ----

@(private = "file")
add_struct :: proc(app: ^App) {
	confirm(app)                     // Editor: open Add root
	select_label(app, "Types")       // root: Types -> submenu
	select_label(app, "Struct")      // submenu: Struct
}

@(test)
test_slot_fill_proc_return_with_int :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// Navigate up to signature line
	update(&app, Input{up = true})
	// Should be on body slot, navigate to signature line
	update(&app, Input{up = true})
	// Now we're on the signature line, navigate right to return slot
	// Fields: name (editable), " :: proc( ", params (slot), " ) -> ", return (slot), " {"
	// Selectable: name, params, return (3 total)
	// Start at index 0 (name), right to params (1), right to return (2)
	update(&app, Input{right = true}) // to params slot
	update(&app, Input{right = true}) // to return slot
	// Confirm to open fill menu
	update(&app, Input{confirm = true})
	testing.expect_value(t, app.state, State.Radial)
	v := current_view(&app)
	testing.expect_value(t, v.title, "Fill slot")
	// Select "Type" submenu
	select_label(&app, "Type")
	// Select "int"
	select_label(&app, "int")
	// Should be back in Editor
	testing.expect_value(t, app.state, State.Editor)
	// Check that the return slot is now filled with "int"
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect(t, strings.contains(txt, "-> int"), "return slot should contain 'int'")
	// Verify the field is now editable (not a slot)
	ni := 0
	// Find the "int" field
	found := false
	for f, fi in app.doc.nodes[ni].fields {
		if f.text == "int" {
			testing.expect_value(t, f.editable, true)
			testing.expect_value(t, f.slot, false)
			found = true
			break
		}
	}
	testing.expect(t, found, "should have found 'int' field")
}

@(test)
test_slot_fill_variable_then_type :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_struct(&app)
	// Navigate up to body slot line
	update(&app, Input{up = true})
	update(&app, Input{up = true}) // to struct name line
	update(&app, Input{down = true}) // back to body line
	// Confirm to open fill menu (now shows statement menu for body slots)
	update(&app, Input{confirm = true})
	testing.expect_value(t, app.state, State.Radial)
	// Navigate to Declarations -> Variable (typed) which creates name: type = value pattern
	select_label(&app, "Declarations")
	select_label(&app, "Variable (typed)")
	// Should be back in Editor
	testing.expect_value(t, app.state, State.Editor)
	// Check that the body line now contains a generated var name and ":"
	txt := node_text(app.doc.nodes[1], context.temp_allocator)
	testing.expect(t, strings.contains(txt, ":"), "body should contain ':'")
	// Verify we have an editable var name field and a new slot
	ni := 1
	found_var_name := false
	var_name := ""
	found_separator := false
	found_slot := false
	for f in app.doc.nodes[ni].fields {
		if f.editable && !f.slot && len(f.text) > 0 && strings.contains(f.text, "_") {
			found_var_name = true
			var_name = f.text
		}
		if f.text == ": " && !f.editable && !f.slot {
			found_separator = true
		}
		if f.text == "" && !f.editable && f.slot {
			found_slot = true
		}
	}
	testing.expect(t, found_var_name, "should have editable var name field (snake_case)")
	testing.expect(t, found_separator, "should have ': ' separator")
	testing.expect(t, found_slot, "should have new type slot")
	// Now navigate right to the new type slot and fill it with "bool"
	update(&app, Input{right = true}) // to type slot (next selectable field)
	// Confirm to open fill menu again
	update(&app, Input{confirm = true})
	testing.expect_value(t, app.state, State.Radial)
	// Select "Type"
	select_label(&app, "Type")
	// Select "bool"
	select_label(&app, "bool")
	// Should be back in Editor
	testing.expect_value(t, app.state, State.Editor)
	// Check that the body line now contains the var name and ": bool"
	txt2 := node_text(app.doc.nodes[1], context.temp_allocator)
	testing.expect(t, strings.contains(txt2, ": bool"), "body should contain ': bool'")
	testing.expect(t, strings.contains(txt2, var_name), "body should contain the var name")
}

@(test)
test_user_defined_type_in_menu :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_struct(&app) // inserts generated type name :: struct { ... }
	// Capture the generated type name
	type_name := app.doc.nodes[0].fields[0].text
	// Add a member variable using new statement menu
	update(&app, Input{up = true})
	update(&app, Input{up = true})
	update(&app, Input{down = true})
	// Open fill menu (now shows statement menu)
	update(&app, Input{confirm = true})
	testing.expect_value(t, app.state, State.Radial)
	// Navigate to Declarations -> Variable (typed) to add a typed member
	select_label(&app, "Declarations")
	select_label(&app, "Variable (typed)")
	testing.expect_value(t, app.state, State.Editor)
	// Navigate to the type slot
	update(&app, Input{right = true}) // to type slot
	// Open fill menu on type slot
	update(&app, Input{confirm = true})
	testing.expect_value(t, app.state, State.Radial)
	// Select "Type"
	select_label(&app, "Type")
	// Now check that the generated type name appears in the Type submenu
	v := current_view(&app)
	found_type := false
	for e in v.entries {
		if e.label == type_name {
			found_type = true
			break
		}
	}
	testing.expect(t, found_type, "Type menu should contain the generated type name")
	// Cancel back
	update(&app, Input{cancel = true})
	update(&app, Input{cancel = true})
	testing.expect_value(t, app.state, State.Editor)
}

// ---- Param slot filling tests ----

@(test)
test_params_slot_opens_param_menu :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// Navigate to signature line
	update(&app, Input{up = true}) // to body slot
	update(&app, Input{up = true}) // to signature line (name field)
	// Navigate right to params slot
	update(&app, Input{right = true})
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok, "should be on a field")
	testing.expect(t, app.doc.nodes[ni].fields[fi].slot, "should be on params slot")
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].kind, "params")
	// Confirm to open menu
	update(&app, Input{confirm = true})
	testing.expect_value(t, app.state, State.Radial)
	v := current_view(&app)
	// Check for "Add parameter" entry
	found := false
	for e in v.entries {
		if e.label == "Add parameter" {
			found = true
			break
		}
	}
	testing.expect(t, found, "params menu should contain 'Add parameter'")
	// Cancel back
	update(&app, Input{cancel = true})
	testing.expect_value(t, app.state, State.Editor)
}

@(test)
test_add_parameter_transforms_slot :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// Navigate to params slot
	update(&app, Input{up = true})
	update(&app, Input{up = true})
	update(&app, Input{right = true})
	// Confirm and select "Add parameter"
	update(&app, Input{confirm = true})
	select_label(&app, "Add parameter")
	testing.expect_value(t, app.state, State.Editor)
	// Check the signature line now contains a generated param name and ": "
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect(t, strings.contains(txt, ": "), "should contain colon separator")
	// Verify fields: should have editable param name (snake_case), fixed ": ", type slot, fixed ", ", params slot
	ni := 0
	found_param := false
	param_name := ""
	found_separator := false
	found_type_slot := false
	found_comma := false
	found_params_slot := false
	for f in app.doc.nodes[ni].fields {
		if f.editable && !f.slot && len(f.text) > 0 && strings.contains(f.text, "_") {
			found_param = true
			param_name = f.text
		}
		if f.text == ": " && !f.editable && !f.slot {
			found_separator = true
		}
		if f.text == "" && !f.editable && f.slot && f.kind == "type" {
			found_type_slot = true
		}
		if f.text == ", " && !f.editable && !f.slot {
			found_comma = true
		}
		if f.text == "" && !f.editable && f.slot && f.kind == "params" {
			found_params_slot = true
		}
	}
	testing.expect(t, found_param, "should have editable param field")
	testing.expect(t, found_separator, "should have : separator")
	testing.expect(t, found_type_slot, "should have type slot")
	testing.expect(t, found_comma, "should have comma separator")
	testing.expect(t, found_params_slot, "should have trailing params slot")
}

@(test)
test_param_type_slot_fills_with_int :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// Capture the generated param name before navigating
	// Navigate to params slot and add parameter
	update(&app, Input{up = true})
	update(&app, Input{up = true})
	update(&app, Input{right = true})
	update(&app, Input{confirm = true})
	select_label(&app, "Add parameter")
	// Capture the param name
	param_name := ""
	for f in app.doc.nodes[0].fields {
		if f.editable && !f.slot && len(f.text) > 0 && strings.contains(f.text, "_") {
			param_name = f.text
			break
		}
	}
	// Now navigate to the type slot (right from param name)
	update(&app, Input{right = true})
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok, "should be on type slot")
	testing.expect(t, app.doc.nodes[ni].fields[fi].slot, "should be a slot")
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].kind, "type")
	// Fill with int
	update(&app, Input{confirm = true})
	select_label(&app, "Type")
	select_label(&app, "int")
	testing.expect_value(t, app.state, State.Editor)
	// Check the signature contains the param name and ": int"
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect(t, strings.contains(txt, ": int"), "should contain ': int'")
	testing.expect(t, strings.contains(txt, param_name), "should contain the param name")
}

@(test)
test_add_second_parameter :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// Navigate to params slot and add first parameter
	update(&app, Input{up = true})
	update(&app, Input{up = true})
	update(&app, Input{right = true})
	update(&app, Input{confirm = true})
	select_label(&app, "Add parameter")
	// Navigate to the trailing params slot (right twice from param name: once to type, once more to trailing params)
	update(&app, Input{right = true}) // to type slot
	update(&app, Input{right = true}) // to trailing params slot
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok, "should be on trailing params slot")
	testing.expect(t, app.doc.nodes[ni].fields[fi].slot, "should be a slot")
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].kind, "params")
	// Add second parameter
	update(&app, Input{confirm = true})
	select_label(&app, "Add parameter")
	testing.expect_value(t, app.state, State.Editor)
	// Check the signature contains two "param" names and two ": " patterns
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	// Count occurrences of ": "
	colon_count := 0
	for i := 0; i < len(txt) - 1; i += 1 {
		if txt[i] == ':' && txt[i+1] == ' ' {
			colon_count += 1
		}
	}
	testing.expect(t, colon_count >= 2, "should have at least 2 ': ' patterns (for two params)")
}

// ---- Body slot statement tests ----

@(test)
test_body_slot_opens_statement_menu :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// Navigate to body slot
	update(&app, Input{up = true}) // from green dot to body slot line
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok, "should be on body slot")
	testing.expect(t, app.doc.nodes[ni].fields[fi].slot, "should be a slot")
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].kind, "body")
	// Open menu
	update(&app, Input{confirm = true})
	testing.expect_value(t, app.state, State.Radial)
	v := current_view(&app)
	testing.expect_value(t, v.title, "Fill slot")
	// Check for category entries (new structure)
	labels: [dynamic]string
	defer delete(labels)
	for e in v.entries {
		append(&labels, e.label)
	}
	testing.expect(t, slice.contains(labels[:], "Declarations"), "should contain 'Declarations' category")
	testing.expect(t, slice.contains(labels[:], "Assignment"), "should contain 'Assignment' category")
	testing.expect(t, slice.contains(labels[:], "Calls"), "should contain 'Calls' category")
	// Cancel back
	update(&app, Input{cancel = true})
	testing.expect_value(t, app.state, State.Editor)
}

@(test)
test_body_slot_variable_decl_transform :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	initial_node_count := len(app.doc.nodes)
	// Navigate to body slot
	update(&app, Input{up = true})
	// Open menu and navigate to Declarations -> Variable (:=)
	update(&app, Input{confirm = true})
	select_label(&app, "Declarations")
	select_label(&app, "Variable (:=)")
	testing.expect_value(t, app.state, State.Editor)
	// Check that body line now contains a generated var name and ":="
	txt := node_text(app.doc.nodes[1], context.temp_allocator)
	testing.expect(t, strings.contains(txt, ":="), "body should contain ':='")
	// Verify there's a generated snake_case name
	found_var_name := false
	for f in app.doc.nodes[1].fields {
		if f.editable && !f.slot && len(f.text) > 0 && strings.contains(f.text, "_") {
			found_var_name = true
			break
		}
	}
	testing.expect(t, found_var_name, "body should contain a generated var name")
	// Verify a new body slot line was inserted
	testing.expect_value(t, len(app.doc.nodes), initial_node_count + 1)
	// Check that the new line (node 2) has a body slot
	found_body_slot := false
	for f in app.doc.nodes[2].fields {
		if f.slot && f.kind == "body" {
			found_body_slot = true
			break
		}
	}
	testing.expect(t, found_body_slot, "should have new body slot line after statement")
	// Verify closing brace is still last (node 3)
	brace_txt := node_text(app.doc.nodes[3], context.temp_allocator)
	testing.expect(t, strings.contains(brace_txt, "}"), "closing brace should still be last")
}

@(test)
test_body_slot_typed_variable_transform :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// Navigate to body slot
	update(&app, Input{up = true})
	// Open menu and navigate to Declarations -> Variable (typed)
	update(&app, Input{confirm = true})
	select_label(&app, "Declarations")
	select_label(&app, "Variable (typed)")
	testing.expect_value(t, app.state, State.Editor)
	// Check that body line now contains a generated var name, ": " and " = "
	txt := node_text(app.doc.nodes[1], context.temp_allocator)
	testing.expect(t, strings.contains(txt, ": "), "body should contain ': '")
	testing.expect(t, strings.contains(txt, " = "), "body should contain ' = '")
	// Verify fields: editable var name (snake_case), ": ", type slot, " = ", value slot
	ni := 1
	found_name := false
	found_colon := false
	found_type_slot := false
	found_equals := false
	found_value_slot := false
	for f in app.doc.nodes[ni].fields {
		if f.editable && !f.slot && len(f.text) > 0 && strings.contains(f.text, "_") {
			found_name = true
		}
		if f.text == ": " && !f.editable && !f.slot {
			found_colon = true
		}
		if f.text == "" && !f.editable && f.slot && f.kind == "type" {
			found_type_slot = true
		}
		if f.text == " = " && !f.editable && !f.slot {
			found_equals = true
		}
		if f.text == "" && !f.editable && f.slot && f.kind == "value" {
			found_value_slot = true
		}
	}
	testing.expect(t, found_name, "should have editable 'value' field")
	testing.expect(t, found_colon, "should have ': ' separator")
	testing.expect(t, found_type_slot, "should have type slot")
	testing.expect(t, found_equals, "should have ' = ' separator")
	testing.expect(t, found_value_slot, "should have value slot")
}

@(test)
test_body_slot_assignment_transform :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// Navigate to body slot
	update(&app, Input{up = true})
	// Open menu and navigate to Assignment -> Assignment
	update(&app, Input{confirm = true})
	select_label(&app, "Assignment")
	select_label(&app, "Assignment")
	testing.expect_value(t, app.state, State.Editor)
	// Check that body line contains a generated var name and " = "
	txt := node_text(app.doc.nodes[1], context.temp_allocator)
	testing.expect(t, strings.contains(txt, " = "), "body should contain ' = '")
	// Verify fields: editable var name (snake_case), " = ", value slot
	ni := 1
	found_name := false
	found_equals := false
	found_value_slot := false
	for f in app.doc.nodes[ni].fields {
		if f.editable && !f.slot && len(f.text) > 0 && strings.contains(f.text, "_") {
			found_name = true
		}
		if f.text == " = " && !f.editable && !f.slot {
			found_equals = true
		}
		if f.text == "" && !f.editable && f.slot && f.kind == "value" {
			found_value_slot = true
		}
	}
	testing.expect(t, found_name, "should have editable 'value' field")
	testing.expect(t, found_equals, "should have ' = ' separator")
	testing.expect(t, found_value_slot, "should have value slot")
}

// OLD TEST: Procedure call is now replaced by Calls category with subtypes
// @(test)
test_body_slot_procedure_call_transform_OLD :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// Navigate to body slot
	update(&app, Input{up = true})
	// Open menu and select "Procedure call"
	update(&app, Input{confirm = true})
	select_label(&app, "Procedure call")
	testing.expect_value(t, app.state, State.Editor)
	// Check that body line contains a generated call name, "(", and ")"
	txt := node_text(app.doc.nodes[1], context.temp_allocator)
	testing.expect(t, strings.contains(txt, "( "), "body should contain '( '")
	testing.expect(t, strings.contains(txt, " )"), "body should contain ' )'")
	// Verify fields: editable call name (snake_case), "( ", value slot, " )"
	ni := 1
	found_name := false
	found_lparen := false
	found_value_slot := false
	found_rparen := false
	for f in app.doc.nodes[ni].fields {
		if f.editable && !f.slot && len(f.text) > 0 && strings.contains(f.text, "_") {
			found_name = true
		}
		if f.text == "( " && !f.editable && !f.slot {
			found_lparen = true
		}
		if f.text == "" && !f.editable && f.slot && f.kind == "value" {
			found_value_slot = true
		}
		if f.text == " )" && !f.editable && !f.slot {
			found_rparen = true
		}
	}
	testing.expect(t, found_name, "should have editable 'do_thing' field")
	testing.expect(t, found_lparen, "should have '( ' field")
	testing.expect(t, found_value_slot, "should have value slot")
	testing.expect(t, found_rparen, "should have ' )' field")
}

@(test)
test_body_slot_multiple_statements :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// Add first statement
	update(&app, Input{up = true})
	update(&app, Input{confirm = true})
	select_label(&app, "Declarations")
	select_label(&app, "Variable (:=)")
	testing.expect_value(t, app.state, State.Editor)
	// Navigate to new body slot (down from current position)
	update(&app, Input{down = true})
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok, "should be on new body slot")
	testing.expect(t, app.doc.nodes[ni].fields[fi].slot, "should be a slot")
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].kind, "body")
	// Add second statement
	update(&app, Input{confirm = true})
	select_label(&app, "Assignment")
	select_label(&app, "Assignment")
	testing.expect_value(t, app.state, State.Editor)
	// Verify we now have 5 nodes: signature, stmt1, stmt2, new body slot, closing brace
	testing.expect_value(t, len(app.doc.nodes), 5)
	// Check that there's still a body slot available
	update(&app, Input{down = true})
	ni2, fi2, ok2 := editor_target(&app)
	testing.expect(t, ok2, "should be on another body slot")
	testing.expect(t, app.doc.nodes[ni2].fields[fi2].slot, "should be a slot")
	testing.expect_value(t, app.doc.nodes[ni2].fields[fi2].kind, "body")
}

@(test)
test_body_slot_struct_body :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_struct(&app)
	// Navigate to struct body slot
	update(&app, Input{up = true}) // from green dot to body slot
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok, "should be on body slot")
	testing.expect(t, app.doc.nodes[ni].fields[fi].slot, "should be a slot")
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].kind, "body")
	// Open menu - should get statement menu (since it's a body slot)
	update(&app, Input{confirm = true})
	testing.expect_value(t, app.state, State.Radial)
	v := current_view(&app)
	// Check for category entries (new structure)
	labels: [dynamic]string
	defer delete(labels)
	for e in v.entries {
		append(&labels, e.label)
	}
	testing.expect(t, slice.contains(labels[:], "Declarations"), "struct body should offer statement menu with categories")
}

// ---- Name generator tests ----

@(test)
test_name_generator_two_procs_different_names :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	add_proc(&app)
	// Get the two procedure names
	name1 := app.doc.nodes[0].fields[0].text
	name2 := app.doc.nodes[3].fields[0].text // second proc starts at node 3
	testing.expect(t, name1 != name2, "two procs should have different generated names")
	testing.expect(t, len(name1) > 0, "first proc should have a name")
	testing.expect(t, len(name2) > 0, "second proc should have a name")
}

@(test)
test_name_generator_proc_snake_case :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	name := app.doc.nodes[0].fields[0].text
	// Check adjective_animal pattern: lowercase, exactly one underscore
	underscore_count := 0
	for c in name {
		if c == '_' do underscore_count += 1
	}
	testing.expect_value(t, underscore_count, 1)
	testing.expect(t, len(name) > 2, "name should have at least adjective_animal")
	// Check lowercase (first byte should be lowercase letter)
	testing.expect(t, name[0] >= 'a' && name[0] <= 'z', "proc name should start lowercase")
}

@(test)
test_name_generator_type_pascal_case :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(&app, "Struct")
	name := app.doc.nodes[0].fields[0].text
	// Check PascalCase: starts uppercase, no underscores
	testing.expect(t, name[0] >= 'A' && name[0] <= 'Z', "type name should start uppercase")
	testing.expect(t, !strings.contains(name, "_"), "type name should not contain underscore")
	testing.expect(t, len(name) > 1, "type name should not be empty")
}

@(test)
test_name_generator_const_upper_snake :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_value(&app, "Constant")
	name := app.doc.nodes[0].fields[0].text
	// Check UPPER_SNAKE: uppercase, contains underscore
	testing.expect(t, name[0] >= 'A' && name[0] <= 'Z', "const name should start uppercase")
	testing.expect(t, strings.contains(name, "_"), "const name should contain underscore")
	// Check all letters are uppercase
	all_upper := true
	for c in name {
		if c >= 'a' && c <= 'z' {
			all_upper = false
			break
		}
	}
	testing.expect(t, all_upper, "const name should be all uppercase (except underscore)")
}

@(test)
test_name_generator_uniqueness :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	// Generate many names to test uniqueness
	for i in 0..<10 {
		add_proc(&app)
	}
	// Collect all proc names
	names: [dynamic]string
	defer delete(names)
	for ni in 0..<len(app.doc.nodes) {
		for f in app.doc.nodes[ni].fields {
			if f.editable && !f.slot && len(f.text) > 0 && strings.contains(f.text, "_") {
				append(&names, f.text)
			}
		}
	}
	// Check uniqueness: each name should appear only once
	for i in 0..<len(names) {
		count := 0
		for j in 0..<len(names) {
			if names[i] == names[j] do count += 1
		}
		testing.expect_value(t, count, 1)
	}
	testing.expect(t, len(names) >= 10, "should have at least 10 unique proc names")
}

// ---- Statement-level selection and deletion tests ----

@(test)
test_construct_range_procedure :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// A procedure is 3 nodes: header, body, closing brace
	testing.expect_value(t, len(app.doc.nodes), 3)
	// construct_range on the first node (header) should return (0, 2)
	start, end := construct_range(&app, 0)
	testing.expect_value(t, start, 0)
	testing.expect_value(t, end, 2)
}

@(test)
test_construct_range_single_node :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_package(&app)
	// package main is a single node
	testing.expect_value(t, len(app.doc.nodes), 1)
	// construct_range should return (0, 0)
	start, end := construct_range(&app, 0)
	testing.expect_value(t, start, 0)
	testing.expect_value(t, end, 0)
}

@(test)
test_delete_construct_removes_nodes :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// 3 nodes total
	testing.expect_value(t, len(app.doc.nodes), 3)
	// Delete the procedure
	delete_construct(&app, 0, 2)
	// Should have no nodes left
	testing.expect_value(t, len(app.doc.nodes), 0)
}

@(test)
test_statement_menu_delete_flow :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	// Insert package and procedure
	add_package(&app)
	add_proc(&app)
	testing.expect_value(t, len(app.doc.nodes), 4) // 1 package + 3 proc nodes
	// Focus the procedure header (line 1)
	app.editor_line = 1
	app.editor_field = 0
	// Open statement menu
	open_statement_menu(&app)
	testing.expect_value(t, app.state, State.Radial)
	// Verify the construct range was recorded
	testing.expect_value(t, app.sel_start, 1)
	testing.expect_value(t, app.sel_end, 3)
	// Select the "Delete" entry
	select_label(&app, "Delete")
	// Should be back in editor
	testing.expect_value(t, app.state, State.Editor)
	// Procedure should be gone, only package remains
	testing.expect_value(t, len(app.doc.nodes), 1)
	txt := node_text(app.doc.nodes[0], context.temp_allocator)
	testing.expect_value(t, txt, "package main")
}
// ---- Body slot menu categories tests ----

@(test)
test_body_slot_shows_categories :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	// Navigate to body slot
	update(&app, Input{up = true})
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok, "should be on body slot")
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].kind, "body")
	// Open menu
	update(&app, Input{confirm = true})
	testing.expect_value(t, app.state, State.Radial)
	v := current_view(&app)
	testing.expect_value(t, v.title, "Fill slot")
	// Check for category entries
	labels: [dynamic]string
	defer delete(labels)
	for e in v.entries {
		append(&labels, e.label)
	}
	testing.expect(t, slice.contains(labels[:], "Declarations"), "should contain 'Declarations'")
	testing.expect(t, slice.contains(labels[:], "Assignment"), "should contain 'Assignment'")
	testing.expect(t, slice.contains(labels[:], "Calls"), "should contain 'Calls'")
	testing.expect(t, slice.contains(labels[:], "Branching"), "should contain 'Branching'")
	testing.expect(t, slice.contains(labels[:], "Loops"), "should contain 'Loops'")
	testing.expect(t, slice.contains(labels[:], "Jumps and cleanup"), "should contain 'Jumps and cleanup'")
	testing.expect(t, slice.contains(labels[:], "Error handling"), "should contain 'Error handling'")
	testing.expect(t, slice.contains(labels[:], "Scope and blocks"), "should contain 'Scope and blocks'")
	// Cancel back
	update(&app, Input{cancel = true})
	testing.expect_value(t, app.state, State.Editor)
}

@(test)
test_body_declarations_category_has_variable_decl :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_proc(&app)
	initial_node_count := len(app.doc.nodes)
	// Navigate to body slot
	update(&app, Input{up = true})
	// Open menu
	update(&app, Input{confirm = true})
	// Navigate to Declarations category
	select_label(&app, "Declarations")
	// Check submenu contains "Variable (:=)"
	v := current_view(&app)
	labels: [dynamic]string
	defer delete(labels)
	for e in v.entries {
		append(&labels, e.label)
	}
	testing.expect(t, slice.contains(labels[:], "Variable (:=)"), "Declarations should contain 'Variable (:=)'")
	testing.expect(t, slice.contains(labels[:], "Variable (typed)"), "Declarations should contain 'Variable (typed)'")
	// Select "Variable (:=)"
	select_label(&app, "Variable (:=)")
	testing.expect_value(t, app.state, State.Editor)
	// Verify it inserts a := statement
	txt := node_text(app.doc.nodes[1], context.temp_allocator)
	testing.expect(t, strings.contains(txt, ":="), "body should contain ':='")
	// Verify a new body slot line was inserted
	testing.expect_value(t, len(app.doc.nodes), initial_node_count + 1)
}

@(test)
test_body_calls_category_this_package :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	// Add two procs so we have one to call
	add_proc(&app)
	// Change the first proc name to something recognizable
	update(&app, Input{up = true}) // to closing brace
	update(&app, Input{up = true}) // to body slot
	update(&app, Input{up = true}) // to signature line
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok)
	// Set the proc name
	set_field_text(&app, ni, fi, "my_proc")
	// Navigate back to green dot
	update(&app, Input{down = true}) // to body slot
	update(&app, Input{down = true}) // to closing brace
	update(&app, Input{down = true}) // to green dot
	// Add a second proc
	add_proc(&app)
	initial_node_count := len(app.doc.nodes)
	// Navigate to the second proc's body slot
	update(&app, Input{up = true})
	// Open menu
	update(&app, Input{confirm = true})
	// Navigate to Calls category
	select_label(&app, "Calls")
	// Navigate to "Procedure in this package"
	select_label(&app, "Procedure in this package")
	// Check that "my_proc" is in the list
	v := current_view(&app)
	labels: [dynamic]string
	defer delete(labels)
	for e in v.entries {
		append(&labels, e.label)
	}
	testing.expect(t, slice.contains(labels[:], "my_proc"), "should contain 'my_proc'")
	// Select "my_proc"
	select_label(&app, "my_proc")
	testing.expect_value(t, app.state, State.Editor)
	// Verify it inserts a call statement
	txt := node_text(app.doc.nodes[4], context.temp_allocator) // second proc's body line
	testing.expect(t, strings.contains(txt, "my_proc("), "body should contain 'my_proc('")
	// Verify there's a value slot
	found_value_slot := false
	for f in app.doc.nodes[4].fields {
		if f.slot && f.kind == "value" {
			found_value_slot = true
			break
		}
	}
	testing.expect(t, found_value_slot, "should have value slot for argument")
	// Verify a new body slot line was inserted
	testing.expect_value(t, len(app.doc.nodes), initial_node_count + 1)
}

@(test)
test_body_calls_category_import :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	// Add an import first
	confirm(&app) // open Add root
	select_label(&app, "Dependencies")
	select_label(&app, "Import")
	select_label(&app, "core")
	drill_to_path(&app, "core:fmt")
	// Now add a proc
	add_proc(&app)
	initial_node_count := len(app.doc.nodes)
	// Navigate to body slot
	update(&app, Input{up = true})
	// Open menu
	update(&app, Input{confirm = true})
	// Navigate to Calls category
	select_label(&app, "Calls")
	// Navigate to "Procedure from an import"
	select_label(&app, "Procedure from an import")
	// Check that "fmt" is in the list
	v := current_view(&app)
	labels: [dynamic]string
	defer delete(labels)
	for e in v.entries {
		append(&labels, e.label)
	}
	testing.expect(t, slice.contains(labels[:], "fmt"), "should contain 'fmt'")
	// Select "fmt"
	select_label(&app, "fmt")
	testing.expect_value(t, app.state, State.Editor)
	// Verify it inserts a call statement with fmt.
	txt := node_text(app.doc.nodes[2], context.temp_allocator) // proc body line
	testing.expect(t, strings.contains(txt, "fmt."), "body should contain 'fmt.'")
	// Verify there's an editable proc name field
	found_editable := false
	for f in app.doc.nodes[2].fields {
		if f.editable && !f.slot && len(f.text) > 0 && strings.contains(f.text, "_") {
			found_editable = true
			break
		}
	}
	testing.expect(t, found_editable, "should have editable proc name after fmt.")
	// Verify there's a value slot
	found_value_slot := false
	for f in app.doc.nodes[2].fields {
		if f.slot && f.kind == "value" {
			found_value_slot = true
			break
		}
	}
	testing.expect(t, found_value_slot, "should have value slot for argument")
	// Verify a new body slot line was inserted
	testing.expect_value(t, len(app.doc.nodes), initial_node_count + 1)
}

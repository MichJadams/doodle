package model

import "core:testing"

// Convenience: a confirm press.
@(private = "file")
confirm :: proc(app: ^App) { update(app, Input{confirm = true}) }

// Full path: open Add menu -> File Setup -> Package declaration.
@(private = "file")
add_package :: proc(app: ^App) {
	confirm(app) // Editor: open Add root menu
	confirm(app) // root: select File Setup -> submenu
	confirm(app) // submenu: select Package declaration
}

@(test)
test_new_project_enters_editor :: proc(t: ^testing.T) {
	app: App
	defer delete(app.doc.nodes)
	app.state = .Menu
	update(&app, Input{confirm = true}) // select "New Project"
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 0)
}

@(test)
test_menu_cancel_quits :: proc(t: ^testing.T) {
	app: App
	defer delete(app.doc.nodes)
	app.state = .Menu
	update(&app, Input{cancel = true})
	testing.expect(t, app.want_quit, "cancel on main menu should quit")
}

@(test)
test_add_package_inserts_text :: proc(t: ^testing.T) {
	app: App
	defer delete(app.doc.nodes)
	app.state = .Editor
	confirm(&app) // open Add root
	testing.expect_value(t, app.state, State.Radial)
	testing.expect_value(t, app.radial.kind, MenuKind.Add)
	confirm(&app) // File Setup -> submenu
	testing.expect_value(t, app.radial.level, 1)
	confirm(&app) // Package declaration
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 1)
	testing.expect_value(t, app.doc.nodes[0], "package main")
}

@(test)
test_nodes_stack :: proc(t: ^testing.T) {
	app: App
	defer delete(app.doc.nodes)
	app.state = .Editor
	add_package(&app)
	add_package(&app)
	testing.expect_value(t, len(app.doc.nodes), 2)
}

@(test)
test_new_project_clears_doc :: proc(t: ^testing.T) {
	app: App
	defer delete(app.doc.nodes)
	app.state = .Editor
	add_package(&app)
	testing.expect_value(t, len(app.doc.nodes), 1)
	app.state = .Menu
	app.menu_index = 0
	update(&app, Input{confirm = true}) // New Project again
	testing.expect_value(t, len(app.doc.nodes), 0)
}

@(test)
test_file_tags_and_comment :: proc(t: ^testing.T) {
	app: App
	defer delete(app.doc.nodes)
	app.state = .Editor
	// File tags = submenu index 1
	confirm(&app)                       // open root
	confirm(&app)                       // File Setup -> submenu
	update(&app, Input{right = true})   // index 0 -> 1 (File tags)
	update(&app, Input{confirm = true})
	testing.expect_value(t, app.doc.nodes[0], "#+build linux")
}

@(test)
test_ide_menu_exit :: proc(t: ^testing.T) {
	app: App
	defer delete(app.doc.nodes)
	app.state = .Editor
	// LT held + D-pad Left opens the IDE menu.
	update(&app, Input{left = true, lt_held = true})
	testing.expect_value(t, app.state, State.Radial)
	testing.expect_value(t, app.radial.kind, MenuKind.Ide)
	update(&app, Input{confirm = true}) // Exit
	testing.expect(t, app.want_quit, "selecting Exit should quit")
}

@(test)
test_ide_menu_cancel_returns :: proc(t: ^testing.T) {
	app: App
	defer delete(app.doc.nodes)
	app.state = .Editor
	update(&app, Input{left = true, lt_held = true}) // open IDE menu
	update(&app, Input{cancel = true})               // back
	testing.expect_value(t, app.state, State.Editor)
	testing.expect(t, !app.want_quit, "cancel should not quit")
}

@(test)
test_grid_nav_clamps :: proc(t: ^testing.T) {
	app: App
	defer delete(app.doc.nodes)
	app.state = .Editor
	confirm(&app) // root menu: 5 options, index 0
	update(&app, Input{right = true})
	testing.expect_value(t, app.radial.index, 1)
	update(&app, Input{down = true}) // +3 => 4
	testing.expect_value(t, app.radial.index, 4)
	update(&app, Input{down = true}) // +3 => 7 >= 5, clamp (no move)
	testing.expect_value(t, app.radial.index, 4)
	update(&app, Input{right = true}) // min(5,4+1)=4 clamp at n-1
	testing.expect_value(t, app.radial.index, 4)
}

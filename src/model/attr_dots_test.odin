package model

// The purple attribute dots above procedures, and @(test) (attr_dots.odin).

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
pick :: proc(t: ^testing.T, app: ^App, label: string) {
	v := current_view(app)
	if !testing.expectf(t, v != nil, "no menu open (wanted %q)", label) do return
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
dimmed :: proc(t: ^testing.T, app: ^App, label: string) -> bool {
	for e in current_view(app).entries do if e.label == label do return e.dim
	testing.expectf(t, false, "menu entry %q should exist", label)
	return false
}

@(private = "file")
src :: proc(app: ^App) -> string { return doc_to_source(app, context.temp_allocator) }

@(private = "file")
saved :: proc(app: ^App) -> string { return file_text(app, context.temp_allocator) }

@(private = "file")
SRC :: "package main\n\nimport \"core:fmt\"\n\nMAX :: 10\n\n@(private)\nhelper :: proc(x: int) -> int {\n\treturn x\n}\n\nmain :: proc() {\n\tfmt.println(MAX)\n}"
//      0             1  2                  3  4          5  6           7                                8            9  10 11                12                    13

@(test)
test_attr_points_above_procedures :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	ap := attr_points(&app)
	for on, i in ap {
		want := i == 6 || i == 11 // above helper's @(private) line, above main
		testing.expectf(t, on == want, "attribute dot before line %d: %v", i, on)
	}
	testing.expect_value(t, attr_dot_decl(&app, 6), 7)
	testing.expect_value(t, attr_dot_decl(&app, 11), 11)
}

@(test)
test_attr_dot_is_a_cursor_stop :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	// Walk down from the green dot before main: the purple dot comes next, then main.
	focus_dot_at(&app, 10)
	update(&app, Input{down = true})
	testing.expect(t, on_attr_dot(&app), "on the purple dot")
	testing.expect_value(t, app.editor_line, 11)
	testing.expect(t, on_dot(&app), "a dot: no field highlighted")
	testing.expect(t, strings.contains(ctrl_hint(&app), "attributes"), "hint")
	update(&app, Input{down = true})
	testing.expect(t, !on_attr_dot(&app) && !on_dot(&app), "on main")
	testing.expect_value(t, app.editor_line, 11)
	update(&app, Input{up = true})
	testing.expect(t, on_attr_dot(&app), "back on the purple dot")
	update(&app, Input{up = true})
	testing.expect(t, on_dot(&app) && !on_attr_dot(&app), "the green dot above it")
	// The green dot before the @(private) line, then the purple one above helper.
	focus_dot_at(&app, 6)
	testing.expect(t, !on_attr_dot(&app))
	update(&app, Input{down = true})
	testing.expect(t, on_attr_dot(&app))
	testing.expect_value(t, app.editor_line, 6)
	// The purple dot goes away with its procedure: the cursor snaps elsewhere.
	focus_attr_dot(&app, 11)
	testing.expect(t, on_attr_dot(&app))
	doc_from_source(&app, "package main\n\nX :: 1\n\nY :: 2\n\nZ :: 3\n\nW :: 4\n\nV :: 5\n\nU :: 6")
	testing.expect(t, !on_attr_dot(&app), "no procedure there any more")
}

@(test)
test_attr_dot_opens_attributes :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	focus_attr_dot(&app, 6) // above helper (it already has @(private))
	update(&app, Input{confirm = true})
	testing.expect_value(t, app.state, State.Radial)
	testing.expect_value(t, current_view(&app).title, "Attributes")
	testing.expect(t, dimmed(t, &app, "private"), "already there")
	testing.expect(t, dimmed(t, &app, "test"), "helper takes an int and returns one")
	pick(t, &app, "require_results")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, node_text(app.doc.nodes[6], context.temp_allocator), "@(private, require_results)")
	// B closes the menu and leaves the cursor on the purple dot.
	focus_attr_dot(&app, 11)
	update(&app, Input{confirm = true})
	testing.expect_value(t, current_view(&app).title, "Attributes")
	update(&app, Input{cancel = true})
	testing.expect_value(t, app.state, State.Editor)
	testing.expect(t, on_attr_dot(&app) && app.editor_line == 11, "still on the dot")
}

@(test)
test_attr_test_on_loaded_proc :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nimport \"core:fmt\"\n\nadds_up :: proc() {\n\tfmt.println(1 + 1)\n}")
	focus_attr_dot(&app, 4)
	update(&app, Input{confirm = true})
	testing.expect(t, !dimmed(t, &app, "test"), "no parameters, no results")
	pick(t, &app, "test")
	testing.expect_value(t, saved(&app),
		"package main\n\nimport \"core:fmt\"\nimport \"core:testing\"\n\n@(test)\nadds_up :: proc(t: ^testing.T) {\n\tfmt.println(1 + 1)\n}") // (the loaded text had no final newline)
	// The parameter's name is editable.
	found := false
	for f in app.doc.nodes[6].fields do if f.editable && f.text == "t" do found = true
	testing.expect(t, found, "t is an editable name")
	// Loaded back the same.
	text := strings.clone(saved(&app), context.temp_allocator)
	doc_from_source(&app, text)
	testing.expect_value(t, saved(&app), text)
	// Already a test proc (`t: ^testing.T`): test is offered on another one but
	// not twice here.
	focus_attr_dot(&app, attr_group_start(&app, 6))
	update(&app, Input{confirm = true})
	testing.expect(t, dimmed(t, &app, "test"), "already @(test)")
	update(&app, Input{cancel = true})
}

@(test)
test_attr_test_on_menu_built_proc :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n")
	focus_dot_at(&app, 1)
	update(&app, Input{confirm = true})
	pick(t, &app, "Procedures")
	pick(t, &app, "Procedure")
	d := -1
	for n, i in app.doc.nodes do if strings.contains(node_text(n, context.temp_allocator), ":: proc") do d = i
	if !testing.expect(t, d >= 0, "a procedure") do return
	focus_attr_dot(&app, d)
	testing.expect(t, on_attr_dot(&app))
	update(&app, Input{confirm = true})
	pick(t, &app, "test")
	testing.expect_value(t, saved(&app), "package main\n\nimport \"core:testing\"\n\n@(test)\nmain :: proc(t: ^testing.T) {\n\n}\n")
}

@(test)
test_attr_test_uses_import_alias :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nimport tst \"core:testing\"\n\ncheck :: proc() {\n}")
	focus_attr_dot(&app, 4)
	update(&app, Input{confirm = true})
	pick(t, &app, "test")
	testing.expect_value(t, src(&app), "package main\n\nimport tst \"core:testing\"\n\n@(test)\ncheck :: proc(t: ^tst.T) {\n}")
}

@(test)
test_attr_test_dimmed_for_non_test_shapes :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nimport \"core:testing\"\n\nget :: proc() -> int {\n\treturn 1\n}\n\ntwo :: proc(a, b: int) {\n}\n\nok :: proc(t: ^testing.T) {\n}")
	for c in ([][2]int{{4, 1}, {8, 1}, {11, 0}}) {
		focus_attr_dot(&app, c[0])
		update(&app, Input{confirm = true})
		testing.expectf(t, dimmed(t, &app, "test") == (c[1] == 1), "test dimmed on line %d", c[0])
		update(&app, Input{cancel = true})
	}
	// Picking it on the one that already takes `t: ^testing.T` adds just the attribute.
	focus_attr_dot(&app, 11)
	update(&app, Input{confirm = true})
	pick(t, &app, "test")
	testing.expect_value(t, src(&app), "package main\n\nimport \"core:testing\"\n\nget :: proc() -> int {\n\treturn 1\n}\n\ntwo :: proc(a, b: int) {\n}\n\n@(test)\nok :: proc(t: ^testing.T) {\n}")
}

@(test)
test_attr_dots_not_on_other_declarations :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nP :: struct {\n\tx: int,\n}\n\nCb :: #type proc()\n\ng :: proc{a, b}\n\nmain :: proc() {\n\tlocal :: proc() {\n\t}\n}\n\nwhen ODIN_OS == .Windows {\n\twin :: proc() {\n\t}\n}")
	ap := attr_points(&app)
	for on, i in ap {
		want := i == 10 || i == 16 // main; win (inside a file-scope when)
		testing.expectf(t, on == want, "attribute dot before line %d: %v", i, on)
	}
}

@(test)
test_attr_review_fixes :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	// LT+B on the purple dot does nothing (it used to delete the blank line above).
	FILE :: "package main\n\nimport \"core:fmt\"\n\nmain :: proc() {\n\tfmt.println(1)\n}"
	doc_from_source(&app, FILE)
	focus_attr_dot(&app, 4)
	delete_selected(&app)
	testing.expect_value(t, src(&app), FILE)
	testing.expect(t, on_attr_dot(&app) && app.editor_line == 4, "still on the purple dot")
	// Not a test: a calling convention other than "odin", or a ^T of another package.
	doc_from_source(&app, "package main\n\nimport \"core:testing\"\nimport \"core:strings\"\n\na :: proc \"contextless\" () {\n}\n\nb :: proc(x: ^strings.T) {\n}\n\nc :: proc \"odin\" (t: ^testing.T) {\n}")
	for c in ([][2]int{{5, 1}, {8, 1}, {11, 0}}) {
		focus_attr_dot(&app, c[0])
		update(&app, Input{confirm = true})
		testing.expectf(t, dimmed(t, &app, "test") == (c[1] == 1), "test dimmed on line %d", c[0])
		update(&app, Input{cancel = true})
	}
	// @(init) makes it contextless: test is then grayed.
	doc_from_source(&app, "package main\n\nsetup :: proc() {\n}")
	focus_attr_dot(&app, 2)
	update(&app, Input{confirm = true})
	pick(t, &app, "init")
	focus_attr_dot(&app, attr_group_start(&app, 3))
	update(&app, Input{confirm = true})
	testing.expect(t, dimmed(t, &app, "test"), "contextless")
	update(&app, Input{cancel = true})
}

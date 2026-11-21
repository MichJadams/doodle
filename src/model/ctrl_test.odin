package model

// Compile-time control: when blocks, #assert, built-in constants, enum values (ctrl.odin).

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
src :: proc(app: ^App) -> string { return doc_to_source(app, context.temp_allocator) }

@(private = "file")
line :: proc(app: ^App, ni: int) -> string { return node_text(app.doc.nodes[ni], context.temp_allocator) }

// Put the cursor on the nth slot of kind `kind` on line ni.
@(private = "file")
focus_slot :: proc(app: ^App, ni, nth: int, kind := "value") {
	seen := 0
	for f, i in app.doc.nodes[ni].fields {
		if f.slot && f.kind == kind {
			if seen == nth { focus_field_index(app, ni, i); return }
			seen += 1
		}
	}
}

// Put the cursor on the keyword field `text` of line ni.
@(private = "file")
focus_kw :: proc(app: ^App, ni: int, text: string) -> bool {
	for f, i in app.doc.nodes[ni].fields {
		if f.kind == KW && f.text == text { focus_field_index(app, ni, i); return true }
	}
	return false
}

@(private = "file")
cursor_field :: proc(app: ^App) -> Field {
	ni, fi, ok := editor_target(app)
	if !ok do return {}
	return app.doc.nodes[ni].fields[fi]
}

// A on the bottom green dot -> Add -> group -> leaf.
@(private = "file")
add_at :: proc(t: ^testing.T, app: ^App, at: int, group, leaf: string) {
	focus_dot_at(app, at)
	update(app, Input{confirm = true})
	testing.expect_value(t, current_view(app).title, "Add  (insertion point)")
	pick(t, app, group)
	pick(t, app, leaf)
}

// Builds `when ODIN_OS == .Windows {` from the condition dot under the cursor.
@(private = "file")
fill_os_windows :: proc(t: ^testing.T, app: ^App) {
	update(app, Input{confirm = true}) // the condition's menu
	pick(t, app, "Operator")
	pick(t, app, "Compare")
	pick(t, app, "a == b")
	update(app, Input{confirm = true}) // left operand
	pick(t, app, "Built-in constants")
	pick(t, app, "ODIN_OS")
	testing.expect_value(t, cursor_field(app).hint, "Odin_OS_Type") // the right side now expects an Odin_OS_Type
	update(app, Input{confirm = true}) // right operand
	pick(t, app, "Enum value")
	pick(t, app, ".Windows")
}

@(test)
test_when_block_with_os_condition :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n")
	add_at(t, &app, 1, "Compile-time", "When block")
	testing.expect_value(t, app.state, State.Editor)
	f := cursor_field(&app)
	testing.expect(t, f.slot && f.kind == "value" && f.hint == "bool", "the cursor is on the condition dot")
	fill_os_windows(t, &app)
	testing.expect_value(t, src(&app), "package main\nwhen ODIN_OS == .Windows {\n}")

	// The dot inside the when opens the Add menu (declarations, not statements).
	testing.expect(t, insertion_points(&app)[2], "a green dot inside the file-scope when")
	add_at(t, &app, 2, "Values", "Constant")
	testing.expectf(t, strings.has_prefix(line(&app, 2), "\t") && strings.contains(line(&app, 2), " :: "), "indented constant, got %q", line(&app, 2))
	focus_slot(&app, 2, 0)
	update(&app, Input{confirm = true})
	pick(t, &app, "Number")

	format_doc(&app)
	out := src(&app)
	lines := strings.split(out, "\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 5)
	testing.expect_value(t, lines[2], "when ODIN_OS == .Windows {")
	testing.expectf(t, strings.has_prefix(lines[3], "\t") && strings.has_suffix(lines[3], " :: 0"), "got %q", lines[3])
	testing.expect_value(t, lines[4], "}")

	// Loading it back gives the same structure and text.
	doc_from_source(&app, out)
	testing.expect_value(t, src(&app), out)
	testing.expect(t, focus_kw(&app, 2, "when"), "`when` is a keyword field again")
	testing.expect(t, insertion_points(&app)[3] && insertion_points(&app)[4], "dots inside the loaded when")
	testing.expect_value(t, app.doc.nodes[3].fields[1].editable, true) // the constant's name
}

@(test)
test_when_else_branches :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nwhen ODIN_DEBUG {\n\tA :: 1\n}\n")
	testing.expect(t, focus_kw(&app, 2, "when"))
	testing.expect(t, strings.contains(ctrl_hint(&app), "else"), "the HUD hint mentions else")
	change_selected(&app) // Y
	testing.expect_value(t, current_view(&app).title, "When")
	pick(t, &app, "Add else")
	testing.expect_value(t, src(&app), "package main\n\nwhen ODIN_DEBUG {\n\tA :: 1\n} else {\n}")
	testing.expect(t, on_dot(&app) && app.editor_line == 5, "on the dot inside the else")

	// Add else when: before the else.
	testing.expect(t, focus_kw(&app, 2, "when"))
	change_selected(&app)
	testing.expect(t, dimmed(t, &app, "Add else"), "only one else")
	pick(t, &app, "Add else when")
	testing.expect_value(t, line(&app, 4), "} else when  {")
	update(&app, Input{confirm = true}) // the new condition (the cursor is on it)
	pick(t, &app, "Built-in constants")
	pick(t, &app, "ODIN_TEST")
	testing.expect_value(t, src(&app), "package main\n\nwhen ODIN_DEBUG {\n\tA :: 1\n} else when ODIN_TEST {\n} else {\n}")

	// Round trip, and LT+B on a branch removes just that branch.
	text := strings.clone(src(&app), context.temp_allocator)
	doc_from_source(&app, text)
	testing.expect_value(t, src(&app), text)
	testing.expect(t, focus_kw(&app, 4, "else when"))
	testing.expect(t, strings.contains(ctrl_hint(&app), "remove branch"))
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\nwhen ODIN_DEBUG {\n\tA :: 1\n} else {\n}")
	testing.expect(t, focus_kw(&app, 4, "else"))
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\nwhen ODIN_DEBUG {\n\tA :: 1\n}")

	// Change condition.
	testing.expect(t, focus_kw(&app, 2, "when"))
	change_selected(&app)
	pick(t, &app, "Change condition")
	testing.expect_value(t, app.state, State.Radial) // straight into the condition's menu
	pick(t, &app, "true")
	testing.expect_value(t, line(&app, 2), "when true {")

	// LT+B on `when`: the whole block.
	testing.expect(t, focus_kw(&app, 2, "when"))
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n")
}

@(test)
test_declarations_inside_file_scope_when :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	SRC :: "package main\n\nwhen ODIN_OS == .Windows {\n\thelper :: proc() {\n\t\tx := 1\n\t}\n\tB :: 2\n}\n\nmain :: proc() {\n}"
	doc_from_source(&app, SRC)
	testing.expect_value(t, src(&app), SRC)
	pts := insertion_points(&app)
	testing.expect(t, pts[3] && pts[6] && pts[7] && !pts[4] && !pts[5], "dots between the when's declarations, not inside the proc")
	testing.expect(t, app.doc.nodes[3].fields[1].editable && app.doc.nodes[3].fields[1].text == "helper", "the proc's name is editable")
	bp := body_points(&app)
	testing.expect(t, bp[4] && bp[5], "statement dots inside the proc in the when")

	// A procedure added inside the when is indented.
	add_at(t, &app, 7, "Procedures", "Procedure")
	testing.expectf(t, strings.has_prefix(line(&app, 7), "\t") && strings.contains(line(&app, 7), ":: proc("), "got %q", line(&app, 7))
	testing.expect(t, strings.has_prefix(line(&app, 9), "\t}"), "its closing brace too")

	// LT+B on a proc's name inside the when deletes just that proc.
	focus_field_index(&app, 3, 1)
	delete_selected(&app)
	testing.expectf(t, strings.has_prefix(src(&app), "package main\n\nwhen ODIN_OS == .Windows {\n\tB :: 2\n"), "got %q", src(&app))
	testing.expect(t, strings.contains(src(&app), "main :: proc() {\n}"))
}

@(test)
test_imports_dimmed_inside_when :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nwhen ODIN_DEBUG {\n}\n")
	focus_dot_at(&app, 3)
	update(&app, Input{confirm = true})
	testing.expect(t, dimmed(t, &app, "Dependencies"), "imports can't go in a when")
	update(&app, Input{cancel = true})
	focus_dot_at(&app, 4)
	update(&app, Input{confirm = true})
	testing.expect(t, !dimmed(t, &app, "Dependencies"))
}

@(test)
test_static_assert_size_of :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nPlayer :: struct {\n\thp: int,\n}\n")
	add_at(t, &app, 5, "Compile-time", "Static assertion")
	testing.expect_value(t, line(&app, 5), "#assert(, )")
	testing.expect_value(t, src(&app), "package main\n\nPlayer :: struct {\n\thp: int,\n}\n#assert()") // the message dot is optional
	update(&app, Input{confirm = true})
	testing.expect(t, dimmed(t, &app, "Number"), "a number isn't a bool")
	pick(t, &app, "Operator")
	pick(t, &app, "Compare")
	pick(t, &app, "a == b")
	update(&app, Input{confirm = true}) // left operand
	pick(t, &app, "Call")
	pick(t, &app, "Built-in")
	pick(t, &app, "size_of")
	update(&app, Input{confirm = true}) // size_of's argument
	pick(t, &app, "Type")
	pick(t, &app, "Player")
	focus_slot(&app, 5, 0)
	update(&app, Input{confirm = true}) // right operand
	pick(t, &app, "Number")
	ni, fi, _ := editor_target(&app)
	set_field_text(&app, ni, fi, "8")
	testing.expect_value(t, src(&app), "package main\n\nPlayer :: struct {\n\thp: int,\n}\n#assert(size_of(Player) == 8)")

	// The optional message: one dot, filled with a string; no third one after it.
	focus_slot(&app, 5, 0, "args")
	update(&app, Input{confirm = true})
	pick(t, &app, "String")
	pick(t, &app, "\"...\"  string")
	ni, fi, _ = editor_target(&app)
	set_field_text(&app, ni, fi, "Player is 8 bytes")
	testing.expect_value(t, src(&app), "package main\n\nPlayer :: struct {\n\thp: int,\n}\n#assert(size_of(Player) == 8, \"Player is 8 bytes\")")
	slots := 0
	for f in app.doc.nodes[5].fields do if f.slot do slots += 1
	testing.expect_value(t, slots, 0)

	// LT+B on the message: the optional dot comes back.
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\nPlayer :: struct {\n\thp: int,\n}\n#assert(size_of(Player) == 8)")

	// Round trip; the loaded #assert is structured (keyword, arguments, message dot).
	text := strings.clone(src(&app), context.temp_allocator)
	doc_from_source(&app, text)
	testing.expect_value(t, src(&app), text)
	testing.expect(t, focus_kw(&app, 5, "#assert"))
	change_selected(&app)
	testing.expect_value(t, current_view(&app).title, "#assert")
	testing.expect(t, !dimmed(t, &app, "Add message"), "the (empty) message dot")
	pick(t, &app, "Add message") // straight into the message dot's menu
	testing.expect_value(t, app.state, State.Radial)
	testing.expect(t, cursor_field(&app).kind == "args")
	update(&app, Input{cancel = true})
	testing.expect(t, focus_kw(&app, 5, "#assert"))
	delete_selected(&app) // LT+B on #assert: the line
	testing.expect_value(t, src(&app), "package main\n\nPlayer :: struct {\n\thp: int,\n}")
}

@(test)
test_assert_and_when_in_a_procedure :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nmain :: proc() {\n}")
	focus_dot_at(&app, 3) // the dot inside main
	update(&app, Input{confirm = true})
	pick(t, &app, "Compile-time")
	pick(t, &app, "#assert")
	update(&app, Input{confirm = true})
	pick(t, &app, "Built-in constants")
	testing.expect(t, dimmed(t, &app, "ODIN_OS"), "an enum isn't a bool")
	testing.expect(t, !dimmed(t, &app, "ODIN_DEBUG"))
	pick(t, &app, "ODIN_DEBUG")
	testing.expect_value(t, src(&app), "package main\n\nmain :: proc() {\n    #assert(ODIN_DEBUG)\n}")

	// Branching -> When: the same condition support; Y adds else.
	focus_dot_at(&app, 4)
	update(&app, Input{confirm = true})
	pick(t, &app, "Branching")
	pick(t, &app, "When")
	f := cursor_field(&app)
	testing.expect(t, f.slot && f.hint == "bool")
	fill_os_windows(t, &app)
	testing.expect(t, focus_kw(&app, 4, "when"))
	change_selected(&app)
	pick(t, &app, "Add else")
	out := src(&app)
	testing.expectf(t, strings.contains(out, "    when ODIN_OS == .Windows {\n") && strings.contains(out, "    } else {\n"), "got %q", out)
	format_doc(&app)
	out = strings.clone(src(&app), context.temp_allocator)
	doc_from_source(&app, out)
	testing.expect_value(t, src(&app), out)
	k := -1
	for n, i in app.doc.nodes do if strings.contains(node_text(n, context.temp_allocator), "} else {") { k = i; break }
	testing.expect(t, k > 0 && focus_kw(&app, k, "else"), "the loaded else is a keyword")
}

@(test)
test_enum_values :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nimport \"core:c/libc\"\n\nDir :: enum u8 {\n\tNorth,\n\tSouth = 2, // two\n}\n\nAxis :: enum { X, Y }\n")
	testing.expect_value(t, strings.join(enum_members(&app, "Dir", ""), " ", context.temp_allocator), "North South")
	testing.expect_value(t, strings.join(enum_members(&app, "Axis", ""), " ", context.temp_allocator), "X Y")
	testing.expect_value(t, strings.join(enum_members(&app, "libc.Whence", ""), " ", context.temp_allocator), "SET CUR END")
	testing.expect_value(t, strings.join(enum_members(&app, "Odin_Arch_Type", "base:runtime"), " ", context.temp_allocator), "Unknown amd64 i386 arm32 arm64 wasm32 wasm64p32 riscv64")

	// A dot with no enum type: the group is grayed out.
	add_at(t, &app, len(app.doc.nodes), "Compile-time", "When block")
	update(&app, Input{confirm = true})
	testing.expect(t, dimmed(t, &app, "Enum value"))
	pick(t, &app, "Operator")
	pick(t, &app, "Compare")
	pick(t, &app, "a != b")
	update(&app, Input{confirm = true})
	pick(t, &app, "Built-in constants")
	pick(t, &app, "ODIN_ARCH")
	update(&app, Input{confirm = true})
	testing.expect(t, !dimmed(t, &app, "Enum value"))
	pick(t, &app, "Enum value")
	pick(t, &app, ".arm64")
	testing.expect(t, strings.contains(src(&app), "when ODIN_ARCH != .arm64 {\n}"))
}

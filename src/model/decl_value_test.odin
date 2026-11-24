package model

// A declaration's value, loaded from a file: its own part (highlight it, Y
// refills it; a string's text gets the text tools).

import "core:strings"
import "core:testing"

@(private = "file")
cleanup :: proc(app: ^App) {
	clear_nav(app)
	delete(app.nav)
	if app.slot_menu != nil do free_entries(app.slot_menu)
	doc_reset(app)
	delete(app.doc.nodes)
	delete(app.recent_imports)
	free_menus(app)
}

@(private = "file")
SRC :: "package main\n\ng: int = 5\n\nmain :: proc() {\n\tx := \"abc def\"\n\tw: f32 = 1.5\n\tl: string = \"label\"\n}\n"

@(private = "file")
line_with :: proc(app: ^App, prefix: string) -> int {
	for n, i in app.doc.nodes do if strings.has_prefix(strings.trim_space(node_text(n, context.temp_allocator)), prefix) do return i
	return -1
}

// The cursor on the line's last part (the value), then Y.
@(private = "file")
y_on_value :: proc(app: ^App, ln: int) -> string {
	app.editor_line, app.editor_dot = ln, false
	app.editor_field = selectable_in_node(app, ln) - 1
	ni, fi, _ := editor_target(app)
	t := app.doc.nodes[ni].fields[fi].text
	update(app, Input{y = true})
	return t
}

@(test)
test_decl_value_loads_and_saves_unchanged :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	doc_from_source(&app, SRC)
	testing.expect_value(t, file_text(&app, context.temp_allocator), SRC)
}

// `g: int = 5`: the 5 is a part; Y gives a dot expecting an int; B puts it back.
@(test)
test_decl_value_typed_refill :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	for src in ([]string{"g:", "w:"}) {
		ln := line_with(&app, src)
		before := node_text(app.doc.nodes[ln], context.temp_allocator)
		v := y_on_value(&app, ln)
		testing.expectf(t, v == "5" || v == "1.5", "the value is highlighted (got %q)", v)
		if !testing.expect(t, app.refill_active && app.state == .Radial, "Y: the fill menu") do continue
		testing.expect_value(t, app.doc.nodes[app.refill_ni].fields[app.refill_fi].hint, src == "g:" ? "int" : "f32")
		update(&app, Input{cancel = true})
		testing.expect_value(t, node_text(app.doc.nodes[ln], context.temp_allocator), before)
	}
	// Pick something: the value is replaced.
	ln := line_with(&app, "g:")
	y_on_value(&app, ln)
	v := current_view(&app)
	for e, i in v.entries do if e.label == "Number" { v.index = i; update(&app, Input{confirm = true}); break }
	testing.expect_value(t, strings.trim_space(node_text(app.doc.nodes[ln], context.temp_allocator)), "g: int = 0")
}

// `x := "abc def"` / `l: string = "label"`: the text is editable, Y gives the
// text tools (Replace value first), and word by word works on it.
@(test)
test_decl_value_string :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	for src in ([]string{"x :=", "l:"}) {
		ln := line_with(&app, src)
		testing.expect(t, y_on_value(&app, ln) != "", "the string's text")
		v := current_view(&app)
		if !testing.expect(t, v != nil && v.entries[0].label == "Replace value", "the text tools") do continue
		for e, i in v.entries do if e.label == WORDS_LABEL { v.index = i; update(&app, Input{confirm = true}); break }
		testing.expect(t, app.word_edit_active, "word by word")
		update(&app, Input{rt_held = true, cancel = true}) // delete the first word
		update(&app, Input{cancel = true})
	}
	testing.expect_value(t, file_text(&app, context.temp_allocator), "package main\n\ng: int = 5\n\nmain :: proc() {\n\tx := \"def\"\n\tw: f32 = 1.5\n\tl: string = \"\"\n}\n")
}

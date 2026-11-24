package model

// Multi-line comments (block_comment.odin): from the menus, Y / LT+B on them,
// and loading.

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
pick :: proc(t: ^testing.T, app: ^App, label: string, loc := #caller_location) -> bool {
	v := current_view(app)
	if !testing.expectf(t, v != nil, "no menu open (wanted %q)", label, loc = loc) do return false
	for e, i in v.entries do if e.label == label {
		v.index = i
		update(app, Input{confirm = true})
		return true
	}
	testing.expectf(t, false, "no %q in menu %q", label, v.title, loc = loc)
	return false
}

@(private = "file")
line_of :: proc(app: ^App, text: string) -> int {
	for n, i in app.doc.nodes do if strings.trim_space(node_text(n, context.temp_allocator)) == text do return i
	return -1
}

@(private = "file")
set_text :: proc(app: ^App, ni: int, text: string) {
	for f, i in app.doc.nodes[ni].fields do if f.kind == COMMENT_KIND { set_field_text(app, ni, i, text); return }
}

// File Setup > Comments > Multi-line comment; Y adds a line, LT+B removes one,
// LT+B on a marker removes the comment.
@(test)
test_block_comment_from_file_setup :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n")
	focus_dot(&app)
	update(&app, Input{confirm = true})
	if pick(t, &app, "File Setup") && pick(t, &app, "Comments") do pick(t, &app, "Multi-line comment")
	open := line_of(&app, "/*")
	if !testing.expect(t, open >= 0, "/* line") do return
	testing.expect(t, block_comment_body(app.doc.nodes[open + 1]) && line_of(&app, "*/") == open + 2, "/*, a text line, */")
	set_text(&app, open + 1, "first line")

	focus_field_index(&app, open + 1, 0) // Y on the text line: another line after it
	change_selected(&app)
	testing.expect(t, block_comment_body(app.doc.nodes[open + 2]), "a second line")
	set_text(&app, open + 2, "second line")
	testing.expect_value(t, file_text(&app, context.temp_allocator), "package main\n\n/*\n\tfirst line\n\tsecond line\n*/\n")

	open = line_of(&app, "/*") // file_text formats: a blank line now sits after package
	focus_field_index(&app, open + 1, 0) // LT+B on a text line: just that line
	delete_selected(&app)
	testing.expect_value(t, file_text(&app, context.temp_allocator), "package main\n\n/*\n\tsecond line\n*/\n")

	focus_field_index(&app, line_of(&app, "*/"), 0) // LT+B on a marker: the whole comment
	delete_selected(&app)
	testing.expect(t, line_of(&app, "/*") < 0 && line_of(&app, "*/") < 0, "the comment is gone")
}

// Layout > Multi-line comment inside a function, at the body's indentation.
@(test)
test_block_comment_in_a_function :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nmain :: proc() {\n\tx := 1\n}\n")
	closing := -1
	for n, i in app.doc.nodes do if strings.trim_space(node_text(n, context.temp_allocator)) == "}" do closing = i
	focus_dot_at(&app, closing)
	update(&app, Input{confirm = true})
	if pick(t, &app, "Layout") do pick(t, &app, "Multi-line comment")
	o := line_of(&app, "/*")
	if !testing.expect(t, o >= 0, "/* line") do return
	set_text(&app, o + 1, "explain x")
	testing.expect_value(t, file_text(&app, context.temp_allocator), "package main\n\nmain :: proc() {\n\tx := 1\n\t/*\n\t\texplain x\n\t*/\n}\n")
}

// Loaded: braces inside don't count (the code after keeps its indentation),
// no green dots inside, and it saves back unchanged.
@(test)
test_block_comment_loader :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	src := "package main\n\n/*\n\told :: proc() {\n\t\tif x {\n\t\t\ty()\n*/\n\nmain :: proc() {\n\tx := 1\n}\n"
	doc_from_source(&app, src)
	o := line_of(&app, "/*")
	c := line_of(&app, "*/")
	if !testing.expect(t, o >= 0 && c == o + 4, "/* ... */ as five lines") do return
	for i in o + 1 ..< c do testing.expect(t, block_comment_body(app.doc.nodes[i]), "comment text lines")
	dots := dot_points(&app)
	for i in o + 1 ..= c do testing.expectf(t, !dots[i], "no green dot before line %d (inside the comment)", i)
	testing.expect(t, dots[o] || dots[o - 1], "a dot before the comment (or the blank line above it)")
	testing.expect_value(t, file_text(&app, context.temp_allocator), src)
	format_doc(&app) // the open braces in it don't indent what follows
	testing.expect_value(t, file_text(&app, context.temp_allocator), src)
}

package model

import "core:testing"

@(private = "file")
cleanup :: proc(app: ^App) {
	clear_nav(app); delete(app.nav); doc_reset(app); delete(app.doc.nodes)
	delete(app.recent_imports); free_menus(app)
}

@(private = "file")
cur_text :: proc(app: ^App) -> string {
	ni, fi, ok := editor_target(app)
	if !ok do return "<dot>"
	f := app.doc.nodes[ni].fields[fi]
	return f.slot ? "●" : f.text
}

@(private = "file")
LONG :: "package main\n\n" +
	"main :: proc() {\n" +
	"\tfoo(first_argument_value, second_argument_value, third_argument_value, fourth_value)\n" +
	"}\n\n" +
	"foo :: proc(a, b, c, d: int) {\n}\n"

// A call broken one argument per row: Up/Down walk its rows before leaving it.
@(test)
test_row_nav_up_down_through_broken_call :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, LONG)
	call := 3
	testing.expect(t, needs_break(app.doc.nodes[call]), "the call is over 80 columns")
	focus_field_index(&app, call, 0)
	testing.expect_value(t, cur_text(&app), "foo")
	update(&app, Input{down = true})
	testing.expect_value(t, cur_text(&app), "first_argument_value")
	update(&app, Input{down = true})
	testing.expect_value(t, cur_text(&app), "second_argument_value")
	update(&app, Input{up = true})
	testing.expect_value(t, cur_text(&app), "first_argument_value")
	update(&app, Input{up = true})
	testing.expect_value(t, cur_text(&app), "foo")
	// Through the last row, then off the line.
	for _ in 0 ..< 4 do update(&app, Input{down = true})
	testing.expect_value(t, cur_text(&app), "fourth_value")
	update(&app, Input{down = true})
	testing.expect(t, app.editor_line != call || app.editor_dot, "past the last row the cursor leaves the line")
	// Coming back up enters on the last row.
	for _ in 0 ..< 8 {
		if app.editor_line == call && !app.editor_dot do break
		update(&app, Input{up = true})
	}
	testing.expect_value(t, cur_text(&app), "fourth_value")
}

// Left on the first part of a line goes to the dot at the end of the line.
@(test)
test_row_nav_left_wraps_to_end_dot :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nimport \"core:fmt\"\n\nmain :: proc() {\n\tfmt.println(\"hi\")\n}\n")
	ln := 5
	leaves := line_leaves(app.doc.nodes[ln])
	testing.expect(t, len(leaves) >= 3, "callee, string, and the more-args dot")
	focus_field_index(&app, ln, leaves[0].fa)
	testing.expect_value(t, cur_text(&app), "println")
	update(&app, Input{left = true})
	testing.expect_value(t, cur_text(&app), "●")
	now := line_leaves(app.doc.nodes[ln]) // (a capture dot may have joined the line)
	testing.expect_value(t, app.editor_field, len(now) - 1)
	update(&app, Input{left = true}) // then Left moves back along the line as before
	testing.expect_value(t, app.editor_field, len(now) - 2)
}

// One green dot between package and import (and import and main), not one on
// each side of the blank line.
@(test)
test_one_dot_per_gap :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nimport \"core:fmt\"\n\nmain :: proc() {\n}\n")
	pts := dot_points(&app)
	n := len(app.doc.nodes)
	for i in 0 ..< n {
		if is_blank_line(app.doc.nodes[i]) do testing.expectf(t, !(pts[i] && pts[i + 1]), "two dots around the blank line %d", i)
	}
	count := 0
	for i in 0 ..= n do if pts[i] do count += 1
	testing.expect_value(t, count, 4) // top, after package, after import, end
	// insertion_points still marks every file-scope line (other code relies on it).
	testing.expect(t, insertion_points(&app)[2], "import is still at file scope")
	// The D-pad meets one dot between package and import.
	between := 0
	for s in editor_stops(&app) do if s.dot && s.line >= 1 && s.line <= 2 do between += 1
	testing.expect_value(t, between, 1)
}

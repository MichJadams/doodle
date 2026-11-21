package model

import "core:strings"
import "core:testing"

@(test)
test_parse_check_output :: proc(t: ^testing.T) {
	out := "C:/Users/me/AppData/Local/Temp/doodle_check/main.odin(5:27) Error: Cannot assign value 'x' of type '[^]u16' to 'cstring16' in a procedure argument \n" +
		"\t... indows.MessageBoxW(nil, x, x, 0) \n" +
		"\t                          ^ \n" +
		"C:/Users/me/AppData/Local/Temp/doodle_check/other.odin(2:1) Error: not this file\n" +
		"C:\\Users\\me\\AppData\\Local\\Temp\\doodle_check\\main.odin(7:1) Syntax Error: Expected an operand \n"
	ds := parse_check_output(out, "main.odin")
	defer free_diags(ds)
	testing.expect_value(t, len(ds), 2)
	if len(ds) == 2 {
		testing.expect(t, ds[0].line == 5 && ds[0].col == 27)
		testing.expect(t, strings.has_prefix(ds[0].msg, "Cannot assign value 'x'"))
		testing.expect(t, ds[1].line == 7 && strings.has_prefix(ds[1].msg, "Syntax: Expected an operand"))
	}
}

// A long call saved one argument per line covers several lines; the lines
// after it are numbered accordingly.
@(test)
test_node_line_starts :: proc(t: ^testing.T) {
	app: App
	defer {
		clear_nav(&app); delete(app.nav); doc_reset(&app); delete(app.doc.nodes)
		delete(app.recent_imports); free_menus(&app)
	}
	src := "package main\nimport win \"core:sys/windows\"\nmain :: proc() {\n" +
		"\twin.MessageBoxW(\n\t\tnil,\n\t\twin.L(\"This caption is long enough to need its own line\"),\n\t\twin.L(\"x\"),\n\t\twin.MB_OK,\n\t)\n" +
		"\tx := 5\n}"
	doc_from_source(&app, src)
	starts := node_line_starts(&app)
	testing.expect_value(t, len(app.doc.nodes), 6)
	testing.expect_value(t, starts[3], 4)  // the call starts on line 4...
	testing.expect_value(t, starts[4], 10) // ...and covers 4-9, so `x := 5` is line 10
	testing.expect_value(t, node_for_line(starts, 7), 3)
	testing.expect_value(t, node_for_line(starts, 10), 4)
	testing.expect_value(t, node_for_line(starts, 99), -1)
}

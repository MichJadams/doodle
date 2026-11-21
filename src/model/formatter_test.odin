package model

import "core:testing"

@(private = "file")
fmt_src :: proc(src: string) -> string {
	app: App
	defer {
		clear_nav(&app); delete(app.nav); doc_reset(&app); delete(app.doc.nodes)
		delete(app.recent_imports); free_menus(&app)
	}
	doc_from_source(&app, src)
	format_doc(&app)
	return doc_to_source(&app, context.temp_allocator)
}

// The saved project as it was: no indentation, no spacing.
@(test)
test_format_indents_and_spaces :: proc(t: ^testing.T) {
	src := "package main\n" +
		"import \"core:fmt\"\n" +
		"import \"core:sys/windows\"\n" +
		"main :: proc() {\n" +
		"brave_otter: windows.LPCWSTR = windows.L(\"Testing\")\n" +
		"if true {\n" +
		"fmt.println(1)\n" +
		"} else {\n" +
		"fmt.println(2)\n" +
		"}\n" +
		"\n" +
		"}\n" +
		"// greet says hi\n" +
		"greet :: proc() {\n" +
		"}\n" +
		"MAX :: 5\n" +
		"MIN :: 1"
	want := "package main\n" +
		"\n" +
		"import \"core:fmt\"\n" +
		"import \"core:sys/windows\"\n" +
		"\n" +
		"main :: proc() {\n" +
		"\tbrave_otter: windows.LPCWSTR = windows.L(\"Testing\")\n" +
		"\tif true {\n" +
		"\t\tfmt.println(1)\n" +
		"\t} else {\n" +
		"\t\tfmt.println(2)\n" +
		"\t}\n" +
		"}\n" +
		"\n" +
		"// greet says hi\n" +
		"greet :: proc() {\n" +
		"}\n" +
		"\n" +
		"MAX :: 5\n" +
		"MIN :: 1"
	got := fmt_src(src)
	testing.expectf(t, got == want, "got:\n%s", got)
}

@(test)
test_format_is_stable_and_collapses_blanks :: proc(t: ^testing.T) {
	src := "\n\npackage main\n\n\n\nimport \"core:fmt\"\n\n\nmain :: proc() {\n\n    fmt.println(1)\n\n\n    fmt.println(2)\n\n}\n\n\n"
	want := "package main\n\nimport \"core:fmt\"\n\nmain :: proc() {\n\tfmt.println(1)\n\n\tfmt.println(2)\n}"
	got := fmt_src(src)
	testing.expectf(t, got == want, "got:\n%s", got)
	testing.expect_value(t, fmt_src(got), got) // formatting twice changes nothing
}

@(test)
test_format_switch_struct_and_multiline_call :: proc(t: ^testing.T) {
	src := "package main\n" +
		"Player :: struct {\n" +
		"name: string,\n" +
		"}\n" +
		"main :: proc() {\n" +
		"switch x {\n" +
		"case 1:\n" +
		"foo(\n" +
		"1,\n" +
		"2,\n" +
		")\n" +
		"case:\n" +
		"}\n" +
		"}"
	want := "package main\n" +
		"\n" +
		"Player :: struct {\n" +
		"\tname: string,\n" +
		"}\n" +
		"\n" +
		"main :: proc() {\n" +
		"\tswitch x {\n" +
		"\tcase 1:\n" +
		"\t\tfoo(1, 2)\n" + // short enough: joined back onto one line
		"\tcase:\n" +
		"\t}\n" +
		"}"
	got := fmt_src(src)
	testing.expectf(t, got == want, "got:\n%s", got)
}

// Menu-built code (4-space "●" statement lines) keeps its dots.
@(test)
test_format_keeps_statement_dots :: proc(t: ^testing.T) {
	app: App
	defer {
		clear_nav(&app); delete(app.nav); doc_reset(&app); delete(app.doc.nodes)
		delete(app.recent_imports); free_menus(&app)
	}
	app.state = .Editor
	update(&app, Input{confirm = true}) // Add
	v := current_view(&app); for e, i in v.entries do if e.label == "Procedures" { v.index = i; update(&app, Input{confirm = true}); break }
	v = current_view(&app); for e, i in v.entries do if e.label == "Procedure" { v.index = i; update(&app, Input{confirm = true}); break }
	testing.expect_value(t, len(app.doc.nodes), 3) // header, "    ●", }
	format_doc(&app)
	testing.expect_value(t, len(app.doc.nodes), 3)
	testing.expect(t, is_body_slot_line(app.doc.nodes[1]), "the statement dot line survives")
	testing.expect_value(t, app.doc.nodes[1].fields[0].text, "\t")
}

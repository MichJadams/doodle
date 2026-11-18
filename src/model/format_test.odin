package model

import "core:strings"
import "core:testing"

@(private = "file")
setup :: proc(app: ^App) -> int {
	app.state = .Editor
	doc_from_source(app, "package main\n\nimport win \"core:sys/windows\"\nimport \"core:fmt\"\n\nmain :: proc() {\n}")
	body: Node
	append(&body.fields, Field{strings.clone("\t"), false, false, "", "", ""})
	append(&body.fields, Field{"", false, true, "body", "", ""})
	ni := len(app.doc.nodes) - 1
	inject_at(&app.doc.nodes, ni, body)
	return ni
}

@(private = "file")
cleanup :: proc(app: ^App) {
	clear_nav(app)
	delete(app.nav)
	doc_reset(app)
	delete(app.doc.nodes)
	delete(app.recent_imports)
	free_menus(app)
}

// Fill the value dots of line ni, in order, with fixed text.
@(private = "file")
fill_values :: proc(app: ^App, ni: int, values: ..string) {
	for v in values {
		for f, fi in app.doc.nodes[ni].fields {
			if f.slot && f.kind == "value" { set_slot_text(app, ni, fi, v); break }
		}
	}
}

@(test)
test_long_call_saved_one_arg_per_line :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	make_import_proc_call(&app, ni, 1, "win", "MessageBoxW")
	fill_values(&app, ni, "nil", "\"This is Handmade Hero.\"", "win.L(\"Handmade Hero\")", "win.MB_OK | win.MB_ICONINFORMATION")

	testing.expect(t, needs_break(app.doc.nodes[ni]), "longer than 80 columns")
	src := doc_to_source(&app, context.temp_allocator)
	want := "main :: proc() {\n" +
		"\twin.MessageBoxW(\n" +
		"\t\tnil,\n" +
		"\t\t\"This is Handmade Hero.\",\n" +
		"\t\twin.L(\"Handmade Hero\"),\n" +
		"\t\twin.MB_OK | win.MB_ICONINFORMATION,\n" +
		"\t)\n" // (then the empty statement dot's blank line, and `}`)
	testing.expectf(t, strings.contains(src, want), "got:\n%s", src)
}

@(test)
test_short_call_stays_on_one_line :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	make_import_proc_call(&app, ni, 1, "win", "MessageBoxW")
	fill_values(&app, ni, "nil", "\"Hi\"", "\"Doodle\"", "win.MB_OK")
	testing.expect(t, !needs_break(app.doc.nodes[ni]))
	src := doc_to_source(&app, context.temp_allocator)
	testing.expectf(t, strings.contains(src, "\twin.MessageBoxW(nil, \"Hi\", \"Doodle\", win.MB_OK)\n"), "got:\n%s", src)
}

@(test)
test_broken_variadic_call_drops_unfilled_green_dot :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	make_import_proc_call(&app, ni, 1, "fmt", "println")
	// Fill the green dot twice with long strings (each fill adds another green dot).
	for s in ([]string{"\"a fairly long first argument string here\"", "\"and a second one that is long\""}) {
		for f, fi in app.doc.nodes[ni].fields {
			if f.slot && f.kind == "args" {
				set_slot_text(&app, ni, fi, s)
				append_more_args_slot(&app.doc.nodes[ni].fields, fi, 1)
				break
			}
		}
	}
	lines := node_source_lines(app.doc.nodes[ni])
	testing.expect_value(t, len(lines), 4)
	if len(lines) == 4 {
		testing.expect_value(t, lines[0], "\tfmt.println(")
		testing.expect_value(t, lines[1], "\t\t\"a fairly long first argument string here\",")
		testing.expect_value(t, lines[2], "\t\t\"and a second one that is long\",")
		testing.expect_value(t, lines[3], "\t)")
	}
}

@(test)
test_call_rows_plan :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app)
	make_import_proc_call(&app, ni, 1, "win", "MessageBoxW")
	rows, ok := call_rows(app.doc.nodes[ni])
	testing.expect(t, ok)
	testing.expect_value(t, len(rows), 6) // head, 4 args, tail
	if len(rows) == 6 {
		testing.expect(t, !rows[0].is_arg && rows[0].start == 0)
		for r in rows[1:5] do testing.expect(t, r.is_arg && r.extra_indent == 1 && r.suffix == ",")
		testing.expect_value(t, app.doc.nodes[ni].fields[rows[5].start].text, ")")
	}
}

@(test)
test_text_cols :: proc(t: ^testing.T) {
	testing.expect_value(t, text_cols("\tab"), TAB_COLS + 2)
	testing.expect_value(t, text_cols(""), 0)
}

@(test)
test_highlight :: proc(t: ^testing.T) {
	s := "\tx := win.MessageBoxW(nil, \"hi\", 42, win.MB_OK) // note"
	hl := highlight(s)
	at :: proc(s: string, hl: []Hl, word: string) -> Hl { return hl[strings.index(s, word)] }
	testing.expect_value(t, at(s, hl, "win"), Hl.Package)
	testing.expect_value(t, at(s, hl, "MessageBoxW"), Hl.Func)
	testing.expect_value(t, at(s, hl, "nil"), Hl.Constant)
	testing.expect_value(t, at(s, hl, "\"hi\""), Hl.String)
	testing.expect_value(t, at(s, hl, "42"), Hl.Number)
	testing.expect_value(t, at(s, hl, "MB_OK"), Hl.Constant)
	testing.expect_value(t, at(s, hl, "// note"), Hl.Comment)
	testing.expect_value(t, at(s, hl, ":="), Hl.Plain)

	// With the imports in scope known, `p.name` is a field access, not a package.
	s3 := "	fmt.println(p.name)"
	hl3 := highlight(s3, []string{"fmt", "win"})
	testing.expect_value(t, at(s3, hl3, "fmt"), Hl.Package)
	testing.expect_value(t, at(s3, hl3, "p."), Hl.Plain)

	s2 := "main :: proc(count: int, r: win.RECT) -> bool {"
	hl2 := highlight(s2)
	testing.expect_value(t, at(s2, hl2, "proc"), Hl.Keyword)
	testing.expect_value(t, at(s2, hl2, "int"), Hl.Type)
	testing.expect_value(t, at(s2, hl2, "RECT"), Hl.Type)
	testing.expect_value(t, at(s2, hl2, "bool"), Hl.Type)
	testing.expect_value(t, at(s2, hl2, "main"), Hl.Plain)
}

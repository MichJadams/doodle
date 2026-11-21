package model

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
find_node :: proc(app: ^App, contains: string) -> int {
	for n, i in app.doc.nodes do if strings.contains(node_text(n, context.temp_allocator), contains) do return i
	return -1
}

// The text of fields [a, b) of a line.
fields_text :: proc(n: Node, a, b: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i in a ..< b do strings.write_string(&sb, n.fields[i].text)
	return strings.to_string(sb)
}

@(private = "file")
value_dots :: proc(n: Node) -> []Field {
	out := make([dynamic]Field, 0, 4, context.temp_allocator)
	for f in n.fields do if f.slot && f.kind == "value" do append(&out, f)
	return out[:]
}

// The project file that lost its last dot: saved with the 4th argument unfilled.
@(test)
test_load_restores_unfilled_argument_dot :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	src := "package main\nimport \"core:fmt\"\nimport \"core:sys/windows\"\nmain :: proc() {\n" +
		"    windows.MessageBoxW( nil, windows.L( \"Testing\" ), windows.L( \"Testing again\" ),  )\n\n}"
	doc_from_source(&app, src)
	ni := find_node(&app, "MessageBoxW")
	testing.expect(t, ni >= 0)
	if ni < 0 do return
	dots := value_dots(app.doc.nodes[ni])
	testing.expect_value(t, len(dots), 1)
	if len(dots) == 1 {
		testing.expect_value(t, dots[0].hint, "UINT")
		testing.expect_value(t, dots[0].hint_pkg, "core:sys/windows")
	}
	// The filled arguments are kept (in Doodle's spacing); the nested L call and
	// its string are structured too, so they can be highlighted and changed.
	text := node_text(app.doc.nodes[ni], context.temp_allocator)
	testing.expectf(t, strings.contains(text, "windows.MessageBoxW(nil, windows.L(\"Testing\"), windows.L(\"Testing again\"), )"), "got %q", text)
	labels := make([dynamic]string, context.temp_allocator)
	n := app.doc.nodes[ni]
	for u in line_leaves(n) do append(&labels, u.fb - u.fa == 1 && n.fields[u.fa].slot ? "●" : fields_text(n, u.fa, u.fb))
	testing.expect_value(t, strings.join(labels[:], " | ", context.temp_allocator), "MessageBoxW | nil | L | \"Testing\" | L | \"Testing again\" | ●")
}

@(test)
test_load_adds_dots_for_missing_arguments :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	doc_from_source(&app, "package main\nimport win \"core:sys/windows\"\nmain :: proc() {\n\twin.MessageBoxW(nil)\n}")
	ni := find_node(&app, "MessageBoxW")
	dots := value_dots(app.doc.nodes[ni])
	testing.expect_value(t, len(dots), 3)
	if len(dots) == 3 {
		testing.expect_value(t, dots[0].hint, "LPCWSTR")
		testing.expect_value(t, dots[1].hint, "LPCWSTR")
		testing.expect_value(t, dots[2].hint, "UINT")
	}
}

// Saving a long call writes one argument per line; loading it back joins it into
// one call again (with the unfilled argument's dot in the right place), and
// saving again gives the same text.
@(test)
test_one_arg_per_line_round_trip :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	src := "package main\n\nimport win \"core:sys/windows\"\n\nmain :: proc() {\n" +
		"\twin.MessageBoxW(\n" +
		"\t\tnil,\n" +
		"\t\t,\n" +
		"\t\twin.L(\"This caption is long enough to need its own line\"),\n" +
		"\t\twin.MB_OK | win.MB_ICONINFORMATION,\n" +
		"\t)\n" +
		"}"
	doc_from_source(&app, src)
	ni := find_node(&app, "MessageBoxW")
	testing.expect(t, ni >= 0)
	if ni < 0 do return
	testing.expect_value(t, len(app.doc.nodes), 7) // the call is one node again
	dots := value_dots(app.doc.nodes[ni])
	testing.expect_value(t, len(dots), 1)
	if len(dots) == 1 do testing.expect_value(t, dots[0].hint, "LPCWSTR") // lpText, the 2nd argument
	out := doc_to_source(&app, context.temp_allocator)
	testing.expectf(t, out == src, "round trip changed the text:\n%s", out)
}

@(test)
test_load_call_statement_shapes :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	src := "package main\nimport \"core:fmt\"\nmain :: proc() {\n" +
		"\tx := fmt.tprintf(\"%d\", 5)\n" +      // assignment of a call
		"\tdefer fmt.println()\n" +             // defer
		"\tif fmt.println() > 0 {\n" +         // not a call statement
		"\t}\n" +
		"\tp.update(1) // a method-ish call\n" + // unknown proc: structured, no dots added
		"}"
	doc_from_source(&app, src)
	x := app.doc.nodes[find_node(&app, "tprintf")]
	// `\t` + `x` (a name: editable, pickable by "Reference") + ` := ` (the declaration's
	// operator: Y changes its form) + `fmt.` + `tprintf` + `(`
	testing.expect_value(t, x.fields[0].text, "\t")
	testing.expect(t, x.fields[1].text == "x" && x.fields[1].editable)
	testing.expect(t, x.fields[2].text == " := " && x.fields[2].kind == "decl")
	testing.expect_value(t, x.fields[3].text, "fmt.")
	testing.expect_value(t, x.fields[4].text, "tprintf")
	testing.expect(t, len(x.fields) > 6 && x.fields[5].text == "(")
	d := app.doc.nodes[find_node(&app, "defer")]
	testing.expect_value(t, d.fields[0].text, "\tdefer fmt.")
	// An if header is structured (branch_parse.odin): the `if` keyword, then its condition.
	i := app.doc.nodes[find_node(&app, "if ")]
	l, is_if := br_line(i)
	testing.expect(t, is_if && l.kind == .If && i.fields[l.kw].kind == BR_KW, "if header structured")
	u := app.doc.nodes[find_node(&app, "update")]
	for f in u.fields do testing.expect(t, !f.slot, "unknown procs get no dots")
	// Everything except spacing inside the calls round-trips.
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), src)
}

@(test)
test_comment_inside_multiline_call_is_left_alone :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	src := "package main\nimport \"core:fmt\"\nmain :: proc() {\n\tfmt.println(\n\t\t1, // one\n\t\t2,\n\t)\n}"
	doc_from_source(&app, src)
	testing.expect_value(t, len(app.doc.nodes), 8) // not joined
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), src)
}

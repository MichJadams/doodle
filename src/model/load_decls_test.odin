package model

// Loading imports and constants the way the menus build them (parse.odin):
// an import's "core:fmt" is a stop (LT+A swaps the package), an aliased
// import's alias is editable, and a constant's value is structured (a string's
// text editable). Types and aliases stay text.

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
line_of :: proc(app: ^App, text: string) -> int {
	for n, i in app.doc.nodes do if strings.has_prefix(strings.trim_space(node_text(n, context.temp_allocator)), text) do return i
	return -1
}

// The line's fields as "text/kind" (ed = editable), for comparing shapes.
@(private = "file")
shape :: proc(app: ^App, ni: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for f, i in app.doc.nodes[ni].fields {
		if i > 0 do strings.write_string(&b, " | ")
		strings.write_string(&b, f.slot ? "●" : f.text)
		if f.editable do strings.write_string(&b, " ed")
		if f.kind != "" do strings.write_string(&b, strings.concatenate({" ", f.kind}, context.temp_allocator))
	}
	return strings.to_string(b)
}

HELLO :: "package main\n\nimport \"core:fmt\"\n\nCLEVER_OTTER :: \"\"\n\ndivmod :: proc(numerator: int, denominator: int) -> (int, int) {\n\treturn numerator / denominator, numerator % denominator\n}\n\nmain :: proc() {\n\tq, r := divmod(17, 5)\n\tfmt.println(\"\", q, r, CLEVER_OTTER, ODIN_OS, ODIN_ARCH)\n}\n"

// Your hello/main.odin: the import and the constant's string can be reached.
@(test)
test_load_import_and_string_constant :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, HELLO)

	imp := line_of(&app, "import")
	testing.expect_value(t, shape(&app, imp), "import  | \"core:fmt\" import_path")
	testing.expect_value(t, len(line_leaves(app.doc.nodes[imp])), 1)

	c := line_of(&app, "CLEVER_OTTER ::")
	testing.expect_value(t, shape(&app, c), "CLEVER_OTTER ed |  ::  | \" |  ed string | \"")
	// Dictating into the string's text (what the mic does on the highlighted field).
	for f, i in app.doc.nodes[c].fields do if f.kind == "string" { set_field_text(&app, c, i, "clever otter"); break }
	testing.expect(t, strings.contains(file_text(&app, context.temp_allocator), "CLEVER_OTTER :: \"clever otter\"\n"), "the string's text is editable")
	for f, i in app.doc.nodes[c].fields do if f.kind == "string" { set_field_text(&app, c, i, ""); break }
	testing.expect_value(t, file_text(&app, context.temp_allocator), HELLO)

	// LT+A on "core:fmt" reopens the Import menu to swap the package.
	focus_field_index(&app, imp, 1)
	edit_selected(&app)
	testing.expect(t, app.state == .Radial && app.replacing && app.replace_ni == imp, "LT+A on the import opens the Import menu for it")
}

@(test)
test_load_aliased_import :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	src := "package main\n\nimport win \"core:sys/windows\"\nimport \"core:fmt\" // printing\n"
	doc_from_source(&app, src)
	testing.expect_value(t, shape(&app, line_of(&app, "import win")), "import  | win ed |   | \"core:sys/windows\" import_path")
	testing.expect_value(t, shape(&app, line_of(&app, "import \"core:fmt\"")), "import \"core:fmt\" // printing") // a comment: left as text
	testing.expect_value(t, file_text(&app, context.temp_allocator), src)
}

// Constants: clear values are structured; types, aliases and procedures aren't.
@(test)
test_load_constant_values :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	src := "package main\n\nN :: 42\nNEG :: -1\nON :: true\nBOTH :: A | B\nSIZE :: size_of(int)\nRAW :: `C:\\temp`\nVec :: [4]f32\nMeters :: distinct f64\nAlias :: Other\n\nDir :: enum {\n\tNorth,\n}\n\nf :: proc() {\n}\n"
	doc_from_source(&app, src)
	// A number is fixed text, as in a loaded call (LT+A's keypad edits it).
	testing.expect_value(t, shape(&app, line_of(&app, "N ::")), "N ed |  ::  | 42")
	testing.expect_value(t, shape(&app, line_of(&app, "NEG ::")), "NEG ed |  ::  | -1")
	testing.expect_value(t, shape(&app, line_of(&app, "ON ::")), "ON ed |  ::  | true")
	testing.expect_value(t, shape(&app, line_of(&app, "BOTH ::")), "BOTH ed |  ::  | A |  |  | B")
	testing.expect(t, strings.contains(shape(&app, line_of(&app, "SIZE ::")), "size_of"), "a call")
	testing.expect_value(t, shape(&app, line_of(&app, "RAW ::")), "RAW ed |  ::  | ` | C:\\temp ed string | `")
	// Types and aliases aren't values (`Vec :: [4]f32` is shaped by the type
	// declaration pass, data_types.odin; `Alias :: Other` stays text).
	testing.expect_value(t, shape(&app, line_of(&app, "Alias ::")), "Alias ed |  :: Other")
	for f in app.doc.nodes[line_of(&app, "Meters ::")].fields do testing.expect(t, f.kind != "string" && !f.slot, "a distinct type isn't a value")
	testing.expect_value(t, file_text(&app, context.temp_allocator), src)
}

// `case :` saved with its value dot unfilled comes back with the dot (typed
// from the switched value, so Enum value lists the event types); `case:` stays
// the default case; in a type switch the dot is a variant (type) dot.
@(test)
test_load_empty_case :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	src := "package main\n\nimport \"vendor:sdl3\"\n\nmain :: proc() {\n\tevent: sdl3.Event\n\tfor sdl3.PollEvent(&event) {\n\t\tswitch event.type {\n\t\tcase :\n\t\tcase:\n\t\t}\n\t}\n}\n"
	doc_from_source(&app, src)
	update(&app, Input{}) // branch_sync types the case dots
	c := line_of(&app, "case :")
	testing.expect_value(t, shape(&app, c), "\t\t | case brkw |   | ● value | :")
	d := line_of(&app, "case:")
	testing.expect_value(t, shape(&app, d), "\t\t | case brkw | :")
	fi := -1
	for f, i in app.doc.nodes[c].fields do if f.slot { fi = i; break }
	testing.expectf(t, app.doc.nodes[c].fields[fi].hint != "", "the dot expects the switched value's type, got %q", app.doc.nodes[c].fields[fi].hint)
	focus_field_index(&app, c, fi)
	update(&app, Input{confirm = true})
	quit := false
	if v := current_view(&app); v != nil do for e in v.entries do if e.label == "Enum value" do for k in e.children do if k.label == ".QUIT" do quit = true
	testing.expect(t, quit, "Enum value lists the event types (.QUIT)")
	for _ in 0 ..< 4 do if app.state == .Radial do update(&app, Input{cancel = true})
	testing.expect_value(t, file_text(&app, context.temp_allocator), src)

	ts: App
	defer cleanup(&ts)
	ts.state = .Editor
	tsrc := "package main\n\nmain :: proc() {\n\tv: union {\n\t\tint,\n\t}\n\tswitch x in v {\n\tcase :\n\t}\n}\n"
	doc_from_source(&ts, tsrc)
	k := line_of(&ts, "case :")
	testing.expect(t, k >= 0 && strings.contains(shape(&ts, k), "● " + VARIANT_KIND), shape(&ts, k))
	testing.expect_value(t, file_text(&ts, context.temp_allocator), tsrc)
}

// `NAME ::` saved with its value dot unfilled comes back with the dot.
@(test)
test_load_empty_constant :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	src := "package main\n\nBRAVE_OTTER ::\n\nmain :: proc() {\n}\n"
	doc_from_source(&app, src)
	testing.expect_value(t, shape(&app, line_of(&app, "BRAVE_OTTER")), "BRAVE_OTTER ed |  ::  | ● value")
	testing.expect_value(t, file_text(&app, context.temp_allocator), src)
}

package model

// Modifiers: attributes, struct directives, calling conventions (modifiers.odin),
// and loading them back (ctrl_parse.odin).

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
has :: proc(app: ^App, label: string) -> bool {
	for e in current_view(app).entries do if e.label == label do return true
	return false
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
line :: proc(app: ^App, ni: int) -> string { return node_text(app.doc.nodes[ni], context.temp_allocator) }

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

// A on a green dot -> Add -> Modifiers -> leaf: starts the pick.
@(private = "file")
start_pick :: proc(t: ^testing.T, app: ^App, at: int, leaf: string) {
	focus_dot_at(app, at)
	update(app, Input{confirm = true})
	pick(t, app, "Modifiers")
	pick(t, app, leaf)
}

@(private = "file")
SRC :: "package main\n\nscore: int\n\nMAX :: 10\n\nPlayer :: struct {\n\thp: int,\n}\n\nget :: proc() -> int {\n\treturn 1\n}\n\nmain :: proc() {\n}"
//      0             1  2           3  4          5  6                  7          8   9  10                    11           12  13 14

@(test)
test_classify_decl :: proc(t: ^testing.T) {
	testing.expect_value(t, classify_decl("main :: proc() {"), Decl_Kind.Proc)
	testing.expect_value(t, classify_decl("cb :: proc \"system\" ("), Decl_Kind.Proc)
	testing.expect_value(t, classify_decl("f :: #force_inline proc(x: int) -> int {"), Decl_Kind.Proc)
	testing.expect_value(t, classify_decl("group :: proc{a, b}"), Decl_Kind.Proc_Group)
	testing.expect_value(t, classify_decl("Cb :: #type proc \"c\" (x: int)"), Decl_Kind.Proc_Type)
	testing.expect_value(t, classify_decl("Stack :: struct($T: typeid) {"), Decl_Kind.Struct)
	testing.expect_value(t, classify_decl("Dir :: enum {"), Decl_Kind.Type)
	testing.expect_value(t, classify_decl("MAX :: 10"), Decl_Kind.Const)
	testing.expect_value(t, classify_decl("MAX : int : 10"), Decl_Kind.Const)
	testing.expect_value(t, classify_decl("x: int"), Decl_Kind.Var)
	testing.expect_value(t, classify_decl("x: [4]int = {}"), Decl_Kind.Var)
	testing.expect_value(t, classify_decl("a, b := 1, 2"), Decl_Kind.Var)
	testing.expect_value(t, classify_decl("x = 5"), Decl_Kind.None)
	testing.expect_value(t, classify_decl("case .Windows:"), Decl_Kind.None)
	testing.expect_value(t, classify_decl("import \"core:fmt\""), Decl_Kind.None)
	testing.expect_value(t, classify_decl("@(private)"), Decl_Kind.None)
}

@(test)
test_attribute_pick_and_apply :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	start_pick(t, &app, 9, "Attributes") // the dot just below Player
	testing.expect(t, app.mod_pick_active, "picking")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, app.mod_pick_line, 6) // the nearest: Player, just above the dot
	testing.expect(t, strings.contains(mod_pick_banner(&app), "Pick"))
	update(&app, Input{down = true})
	testing.expect_value(t, app.mod_pick_line, 10) // get
	testing.expect_value(t, cursor_field(&app).text, "get")
	update(&app, Input{confirm = true})
	testing.expect_value(t, current_view(&app).title, "Attributes")
	testing.expect(t, !has(&app, "thread_local"), "variables only")
	testing.expect(t, !dimmed(t, &app, "require_results"), "get returns an int")
	testing.expect(t, dimmed(t, &app, "init"), "init procs take and return nothing")

	// B: back to picking; B again: done.
	update(&app, Input{cancel = true})
	testing.expect(t, app.mod_pick_active && app.state == .Editor)
	update(&app, Input{up = true})
	update(&app, Input{up = true})
	testing.expect_value(t, app.mod_pick_line, 4) // MAX
	update(&app, Input{confirm = true})
	testing.expect(t, !has(&app, "export") && has(&app, "private"), "constants: only private")
	update(&app, Input{cancel = true})
	update(&app, Input{cancel = true})
	testing.expect(t, !app.mod_pick_active)
	testing.expect_value(t, src(&app), SRC)

	// Apply, then add a second one with Y on it (merged into the same line).
	start_pick(t, &app, 10, "Attributes") // the dot just above get
	testing.expect_value(t, app.mod_pick_line, 10)
	update(&app, Input{confirm = true})
	pick(t, &app, "require_results")
	testing.expect(t, !app.mod_pick_active)
	testing.expect_value(t, line(&app, 10), "@(require_results)")
	testing.expect_value(t, cursor_field(&app).text, "require_results")
	testing.expect(t, strings.contains(ctrl_hint(&app), "attribute"))
	change_selected(&app) // Y
	testing.expect(t, dimmed(t, &app, "require_results"), "already there")
	pick(t, &app, "link_name=\"...\"")
	testing.expect_value(t, line(&app, 10), "@(require_results, link_name=)")
	f := cursor_field(&app)
	testing.expect(t, f.slot && f.hint == "string", "on the string dot")
	update(&app, Input{confirm = true})
	pick(t, &app, "String")
	pick(t, &app, "\"...\"  string")
	ni, fi, _ := editor_target(&app)
	set_field_text(&app, ni, fi, "get_one")
	want := "package main\n\nscore: int\n\nMAX :: 10\n\nPlayer :: struct {\n\thp: int,\n}\n\n@(require_results, link_name=\"get_one\")\nget :: proc() -> int {\n\treturn 1\n}\n\nmain :: proc() {\n}"
	testing.expect_value(t, src(&app), want)

	// It loads back the same, and format_doc keeps it on its declaration.
	doc_from_source(&app, want)
	testing.expect_value(t, src(&app), want)
	format_doc(&app)
	testing.expect_value(t, src(&app), want)
	testing.expect(t, focus_kw(&app, 10, "link_name"))

	// LT+B: one attribute, then the line with the last one.
	delete_selected(&app)
	testing.expect_value(t, line(&app, 10), "@(require_results)")
	testing.expect(t, focus_kw(&app, 10, "require_results"))
	delete_selected(&app)
	testing.expect_value(t, src(&app), SRC)
}

@(test)
test_attribute_kinds :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	start_pick(t, &app, 1, "Attributes")
	testing.expect_value(t, app.mod_pick_line, 2) // score
	update(&app, Input{confirm = true})
	testing.expect(t, has(&app, "thread_local") && has(&app, "export") && !has(&app, "require_results"))
	pick(t, &app, "thread_local")
	testing.expect_value(t, line(&app, 2), "@(thread_local)")

	// @(init) makes the procedure "contextless".
	start_pick(t, &app, len(app.doc.nodes), "Attributes")
	testing.expect_value(t, app.mod_pick_line, 15) // main
	update(&app, Input{confirm = true})
	testing.expect(t, !dimmed(t, &app, "init"))
	testing.expect(t, dimmed(t, &app, "require_results"), "main returns nothing")
	pick(t, &app, "init")
	testing.expect(t, strings.has_suffix(src(&app), "@(init)\nmain :: proc \"contextless\" () {\n}"), src(&app))

	// Deleting a declaration takes its attributes with it.
	focus_field_index(&app, 3, 0) // score's name
	testing.expect_value(t, cursor_field(&app).text, "score")
	delete_selected(&app)
	testing.expect(t, strings.has_prefix(src(&app), "package main\n\n\nMAX :: 10"), src(&app))
}

@(test)
test_struct_directives :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	start_pick(t, &app, 1, "Struct directives")
	testing.expect_value(t, app.mod_pick_line, 6) // the only struct
	update(&app, Input{confirm = true})
	pick(t, &app, "#packed")
	testing.expect_value(t, line(&app, 6), "Player :: struct #packed {")
	testing.expect_value(t, cursor_field(&app).text, "#packed")
	change_selected(&app) // Y: more directives
	testing.expect(t, dimmed(t, &app, "#packed") && dimmed(t, &app, "#align(N)") && !dimmed(t, &app, "#raw_union"))
	pick(t, &app, "#raw_union")
	testing.expect_value(t, line(&app, 6), "Player :: struct #raw_union #packed {")
	text := strings.clone(src(&app), context.temp_allocator)
	doc_from_source(&app, text)
	testing.expect_value(t, src(&app), text)
	testing.expect(t, focus_kw(&app, 6, "#packed"))
	delete_selected(&app) // LT+B
	testing.expect(t, focus_kw(&app, 6, "#raw_union"))
	delete_selected(&app)
	testing.expect_value(t, src(&app), SRC)

	// #align(●) on a polymorphic struct.
	POLY :: "package main\n\nStack :: struct($T: typeid) {\n\titems: [dynamic]T,\n}"
	doc_from_source(&app, POLY)
	start_pick(t, &app, 1, "Struct directives")
	update(&app, Input{confirm = true})
	pick(t, &app, "#align(N)")
	f := cursor_field(&app)
	testing.expect(t, f.slot && f.hint == "int", "on the alignment dot")
	update(&app, Input{confirm = true})
	pick(t, &app, "Number")
	ni, fi, _ := editor_target(&app)
	set_field_text(&app, ni, fi, "16")
	testing.expect_value(t, line(&app, 2), "Stack :: struct($T: typeid) #align(16) {")
	text = strings.clone(src(&app), context.temp_allocator)
	doc_from_source(&app, text)
	testing.expect_value(t, src(&app), text)
	// The header is structured (Types), so find the 16 by text.
	for f, i in app.doc.nodes[2].fields do if f.text == "16" { focus_field_index(&app, 2, i); break }
	testing.expect_value(t, cursor_field(&app).text, "16")
	delete_selected(&app) // LT+B on the number removes the whole directive
	testing.expect_value(t, src(&app), POLY)
}

@(test)
test_calling_convention :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	start_pick(t, &app, 1, "Calling convention")
	testing.expect_value(t, app.mod_pick_line, 10) // the first procedure
	update(&app, Input{confirm = true})
	testing.expect(t, dimmed(t, &app, "\"none\""), "a procedure with a body can't be \"none\"")
	pick(t, &app, "\"system\"")
	testing.expect_value(t, line(&app, 10), "get :: proc \"system\" () -> int {")
	testing.expect_value(t, cursor_field(&app).text, "\"system\"")
	change_selected(&app) // Y: change it
	testing.expect(t, dimmed(t, &app, "\"system\""), "the current one")
	pick(t, &app, "\"c\"")
	testing.expect_value(t, line(&app, 10), "get :: proc \"c\" () -> int {")
	delete_selected(&app) // LT+B
	testing.expect_value(t, src(&app), SRC)

	// On a procedure built from the menu.
	doc_from_source(&app, "package main\n")
	focus_dot_at(&app, 1)
	update(&app, Input{confirm = true})
	pick(t, &app, "Procedures")
	pick(t, &app, "Procedure")
	start_pick(t, &app, 4, "Calling convention")
	update(&app, Input{confirm = true})
	pick(t, &app, "\"contextless\"")
	testing.expect_value(t, src(&app), "package main\nmain :: proc \"contextless\" () {\n\n}")
	focus_kw(&app, 1, "\"contextless\"")
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\nmain :: proc() {\n\n}")
}

@(test)
test_load_modifiers_and_compile_time :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	FILE :: "package handmade\n\n" +
		"import win32 \"core:sys/windows\"\n\n" +
		"when ODIN_OS == .Windows {\n" +
		"\t@(private)\n" +
		"\tWIN_ONLY :: 1\n" +
		"} else when ODIN_OS == .Linux {\n" +
		"\tWIN_ONLY :: 2\n" +
		"} else {\n" +
		"\tWIN_ONLY :: 3\n" +
		"}\n\n" +
		"#assert(size_of(i32) == 4, \"i32 is 4 bytes\")\n\n" +
		"Packed :: struct #packed {\n\ta: u8,\n}\n\n" +
		"@(private=\"file\", require_results)\n" +
		"f1 :: proc() -> int {\n\treturn 1\n}\n\n" +
		"main_window_callback :: proc \"system\" (\n" +
		"\twindow: win32.HWND,\n" +
		"\tmessage: win32.UINT,\n" +
		"\tw_param: win32.WPARAM,\n" +
		"\tl_param: win32.LPARAM,\n" +
		") -> win32.LRESULT {\n" +
		"\tresult: win32.LRESULT = 0\n" +
		"\twhen ODIN_DEBUG {\n" +
		"\t\t#assert(true)\n" +
		"\t} else {\n" +
		"\t}\n" +
		"\treturn result\n" +
		"}\n\n" +
		"c_proc :: proc \"c\" (x: i32) {\n}\n"
	doc_from_source(&app, FILE)
	testing.expect_value(t, src(&app), strings.trim_suffix(FILE, "\n"))
	format_doc(&app)
	testing.expect_value(t, src(&app), strings.trim_suffix(FILE, "\n"))

	kw_on :: proc(app: ^App, ni: int, text: string) -> bool {
		for f in app.doc.nodes[ni].fields do if f.kind == KW && f.text == text do return true
		return false
	}
	testing.expect(t, kw_on(&app, 4, "when") && kw_on(&app, 7, "else when") && kw_on(&app, 9, "else"))
	testing.expect(t, kw_on(&app, 5, "private"), "attribute inside the when")
	testing.expect(t, kw_on(&app, 13, "#assert"))
	testing.expect(t, kw_on(&app, 15, "#packed"))
	testing.expect(t, kw_on(&app, 19, "private=\"file\"") && kw_on(&app, 19, "require_results"))
	testing.expect(t, kw_on(&app, 24, "\"system\""))
	testing.expect(t, kw_on(&app, 31, "when") && kw_on(&app, 33, "else"), "a when in a procedure")
	testing.expect(t, kw_on(&app, 32, "#assert"))
	testing.expect(t, kw_on(&app, 38, "\"c\""))
	// The parameters after a calling convention are still names.
	testing.expect_value(t, app.doc.nodes[38].fields[0].text, "c_proc")
	x_editable := false
	for f in app.doc.nodes[38].fields do if f.editable && f.text == "x" do x_editable = true
	testing.expect(t, x_editable, "x is an editable parameter name")

	// The file-scope when: dots between its declarations; the proc's when: statements.
	pts := insertion_points(&app)
	testing.expect(t, pts[5] && pts[8] && pts[10] && pts[11], "dots inside the file-scope when chain")
	testing.expect(t, !pts[32], "no declaration dots inside a procedure's when")

	// Every structured part is selectable (Y / LT+B reach them).
	testing.expect(t, focus_kw(&app, 24, "\"system\""))
	testing.expect_value(t, cursor_field(&app).text, "\"system\"")
}

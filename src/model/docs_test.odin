package model

// LT+Y documentation (docs.odin): what the highlighted part names, and finding
// its declaration and comment.

import "core:os"
import "core:path/filepath"
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

// Put the cursor on the leaf of line ni whose text contains `text`.
@(private = "file")
focus_leaf :: proc(t: ^testing.T, app: ^App, ni: int, text: string, loc := #caller_location) -> bool {
	n := app.doc.nodes[ni]
	for u, k in line_leaves(n) {
		b := strings.builder_make(context.temp_allocator)
		for i in u.fa ..< u.fb do strings.write_string(&b, n.fields[i].text)
		if strings.contains(strings.to_string(b), text) {
			app.editor_line, app.editor_dot, app.editor_attr, app.editor_field = ni, false, false, k
			return true
		}
	}
	testing.expectf(t, false, "no leaf %q on line %d (%q)", text, ni, node_text(n, context.temp_allocator), loc = loc)
	return false
}

@(private = "file")
SRC :: "package main\n\nimport \"core:fmt\"\nimport \"core:testing\"\nimport win \"core:sys/windows\"\n\n// The most enemies.\nMAX :: 10 // (per level)\n\nadd :: proc(a, b: int) -> int {\n\treturn a + b\n}\n\nmain :: proc() {\n\tx := add(1, MAX)\n\tfmt.println(x, win.MB_OK)\n\tr: win.RECT\n}"
//      0             1  2                  3                      4                               5  6                    7                     8  9                               10            11 12 13               14                15                          16           17

@(test)
test_doc_query_parts :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)

	expect :: proc(t: ^testing.T, app: ^App, name, path: string, keyword := false, loc := #caller_location) {
		q, ok := doc_query(app)
		testing.expect(t, ok, "something to look up", loc = loc)
		testing.expect_value(t, q.name, name, loc = loc)
		testing.expect_value(t, q.path, path, loc = loc)
		testing.expect_value(t, q.keyword, keyword, loc = loc)
	}
	// A call's name: its package.
	if focus_leaf(t, &app, 15, "println") do expect(t, &app, "println", "core:fmt")
	// A call to this file's procedure.
	if focus_leaf(t, &app, 14, "add") do expect(t, &app, "add", "")
	// Arguments: a local, a constant, a package value.
	if focus_leaf(t, &app, 15, "x") do expect(t, &app, "x", "")
	if focus_leaf(t, &app, 14, "MAX") do expect(t, &app, "MAX", "")
	if focus_leaf(t, &app, 15, "MB_OK") do expect(t, &app, "MB_OK", "core:sys/windows")
	// A literal: the type expected there (add's b: int).
	if focus_leaf(t, &app, 14, "1") do expect(t, &app, "int", "")
	// A declared name.
	if focus_leaf(t, &app, 16, "r") do expect(t, &app, "r", "")
	// The cursor line counts (the nearest declaration wins).
	q, _ := doc_query(&app)
	testing.expect_value(t, q.near, 17)
	// The purple dot: attributes; a green dot: nothing.
	focus_attr_dot(&app, 13)
	expect(t, &app, "attributes", "", true)
	focus_dot_at(&app, 13)
	_, ok := doc_query(&app)
	testing.expect(t, !ok, "nothing on a green dot")
}

@(test)
test_doc_query_dots_and_keywords :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nimport \"core:testing\"\n\nwhen ODIN_OS == .Windows {\n\tX :: 1\n}\n\n@(test)\nchecks :: proc(t: ^testing.T) {\n\ttesting.expect(t, true)\n}")
	// A keyword.
	if focus_leaf(t, &app, 4, "when") {
		q, ok := doc_query(&app)
		testing.expect(t, ok && q.keyword && q.name == "when")
	}
	// An attribute.
	if focus_leaf(t, &app, 8, "test") {
		q, ok := doc_query(&app)
		testing.expect(t, ok && q.keyword && q.name == "test", "@(test)")
	}
	// A dot: the type it expects (testing.expect's ok: bool -> the built-in).
	if focus_leaf(t, &app, 10, "true") {
		q, ok := doc_query(&app)
		testing.expect(t, ok, "a literal")
		testing.expect_value(t, q.name, "bool")
	}
}

@(test)
test_doc_find_decl :: proc(t: ^testing.T) {
	lines := []string{
		"package p",               // 0
		"x :: 1",                  // 1
		"f :: proc(x: int) {",     // 2
		"\tx := 2",                // 3
		"\ty := x",                // 4
		"}",                       // 5
		"// x :: 3",               // 6
		"/*",                      // 7
		"x :: 4",                  // 8
		"*/",                      // 9
		"a, b :: 1, 2",            // 10
		"S :: struct {",           // 11
		"\tx: int,",               // 12
		"}",                       // 13
	}
	i, ok := find_decl(lines, "x", -1, false)
	testing.expect(t, ok && i == 1, "file scope first")
	i, ok = find_decl(lines, "x", 5, true)
	testing.expect_value(t, i, 3) // the local just above the cursor
	i, ok = find_decl(lines, "x", 3, true)
	testing.expect_value(t, i, 2) // the parameter
	i, ok = find_decl(lines, "b", -1, false)
	testing.expect_value(t, i, 10)
	i, ok = find_decl(lines, "nope", -1, false)
	testing.expect(t, !ok)
}

@(test)
test_doc_file_for_os :: proc(t: ^testing.T) {
	none := []string{"package fmt"}
	testing.expect(t, file_for_os("fmt.odin", none, "windows"))
	testing.expect(t, file_for_os("fmt_os.odin", none, "windows"), "os is not an OS tag")
	testing.expect(t, !file_for_os("fmt_js.odin", none, "windows"))
	testing.expect(t, file_for_os("file_windows.odin", none, "windows"))
	testing.expect(t, !file_for_os("file_linux.odin", none, "windows"))
	testing.expect(t, !file_for_os("thread_linux_amd64.odin", none, "windows"))
	testing.expect(t, file_for_os("thread_linux_amd64.odin", none, "linux"))
	testing.expect(t, !file_for_os("x.odin", {"#+build js", "package fmt"}, "windows"))
	testing.expect(t, file_for_os("x.odin", {"#+build !js", "package fmt"}, "windows"))
	testing.expect(t, file_for_os("x.odin", {"// a comment", "#+build linux, windows", "package fmt"}, "windows"))
	testing.expect(t, !file_for_os("x.odin", {"#+build linux amd64", "package fmt"}, "windows"))
	testing.expect(t, !file_for_os("x.odin", {"#+ignore", "package fmt"}, "windows"))
	testing.expect(t, file_for_os("x.odin", {"package fmt", "#+build js"}, "windows"), "only before package")
}

@(test)
test_doc_lookup_this_file :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	info := lookup_doc(&app, Doc_Query{name = "MAX", near = 15}, "", "", "", "windows")
	defer doc_info_free(&info)
	testing.expect(t, info.found)
	testing.expect_value(t, info.location, "this file, line 8")
	testing.expect_value(t, len(info.signature), 1)
	if len(info.signature) == 1 do testing.expect_value(t, info.signature[0], "MAX :: 10 // (per level)")
	testing.expect_value(t, len(info.doc), 1)
	if len(info.doc) == 1 do testing.expect_value(t, info.doc[0], "The most enemies.")
	// A procedure: its header, not its body.
	info2 := lookup_doc(&app, Doc_Query{name = "add", near = 15}, "", "", "", "windows")
	defer doc_info_free(&info2)
	testing.expect_value(t, len(info2.signature), 1)
	if len(info2.signature) == 1 do testing.expect_value(t, info2.signature[0], "add :: proc(a, b: int) -> int")
	// A parameter: the header it's declared in.
	info3 := lookup_doc(&app, Doc_Query{name = "b", near = 11}, "", "", "", "windows")
	defer doc_info_free(&info3)
	testing.expect_value(t, info3.location, "this file, line 10")
	// Keywords; not found.
	info4 := lookup_doc(&app, Doc_Query{name = "when", keyword = true}, "", "", "", "windows")
	defer doc_info_free(&info4)
	testing.expect(t, info4.found && len(info4.doc) > 0)
	info5 := lookup_doc(&app, Doc_Query{name = "nothing_here"}, "", "", "", "windows")
	defer doc_info_free(&info5)
	testing.expect(t, !info5.found)
}

@(test)
test_doc_lookup_folder :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package game\n\nmain :: proc() {\n}")
	tmp, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({tmp, "doodle_docs_test"}, context.temp_allocator)
	os.make_directory_all(dir)
	write :: proc(dir, name, text: string) {
		p, _ := filepath.join({dir, name}, context.temp_allocator)
		_ = os.write_entire_file(p, transmute([]u8)text)
	}
	write(dir, "player.odin", "package game\n\n/*\n\tA player.\n\tHas hit points.\n*/\nPlayer :: struct {\n\thp: int,\n}\n\n// Moves the player.\n@(require_results)\nmove :: proc(\n\tp: ^Player,\n\tdx: int,\n) -> bool {\n\treturn true\n}\n")
	write(dir, "plat_js.odin", "package game\n\n// The JS one.\nplat :: proc() {}\n")
	write(dir, "plat_windows.odin", "package game\n\n// The Windows one.\nplat :: proc() {}\n")
	info := lookup_doc(&app, Doc_Query{name = "Player"}, "", dir, "", "windows")
	defer doc_info_free(&info)
	testing.expect(t, info.found)
	testing.expect(t, strings.has_suffix(info.location, "player.odin:7"), info.location)
	testing.expect_value(t, len(info.signature), 3) // the whole struct
	testing.expect_value(t, len(info.doc), 2)
	if len(info.doc) == 2 do testing.expect_value(t, info.doc[1], "Has hit points.")
	info2 := lookup_doc(&app, Doc_Query{name = "move"}, "", dir, "", "windows")
	defer doc_info_free(&info2)
	sig := strings.join(info2.signature, "\n", context.temp_allocator)
	testing.expect_value(t, sig, "@(require_results)\nmove :: proc(\n\tp: ^Player,\n\tdx: int,\n) -> bool")
	if len(info2.doc) == 1 do testing.expect_value(t, info2.doc[0], "Moves the player.")
	info3 := lookup_doc(&app, Doc_Query{name = "plat"}, "", dir, "", "windows")
	defer doc_info_free(&info3)
	if len(info3.doc) == 1 do testing.expect_value(t, info3.doc[0], "The Windows one.")
	// A relative import resolves next to the folder.
	testing.expect(t, strings.has_suffix(package_dir("../model", dir, ""), "model"))
	testing.expect_value(t, package_dir("core:fmt", dir, ""), "")
}

// Against the Odin install (skipped when it isn't there).
@(test)
test_doc_lookup_odin_install :: proc(t: ^testing.T) {
	root := odin_root()
	fmt_dir, _ := filepath.join({root, "core", "fmt"}, context.temp_allocator)
	if !os.is_dir(fmt_dir) do return
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n")
	info := lookup_doc(&app, Doc_Query{name = "println", path = "core:fmt"}, "", "", root, "windows")
	defer doc_info_free(&info)
	testing.expect(t, info.found)
	testing.expect_value(t, info.title, "fmt.println")
	testing.expect(t, !strings.contains(info.location, "_js"), info.location) // not the JS copy
	testing.expect(t, len(info.doc) > 0, "fmt.println has a comment")
	// Built-ins: base:builtin (with Doodle's text when it has none), runtime's @builtin procedures.
	info2 := lookup_doc(&app, Doc_Query{name = "len"}, "", "", root, "windows")
	defer doc_info_free(&info2)
	testing.expect(t, info2.found && len(info2.doc) > 0 && strings.contains(info2.doc[0], "number of elements"))
	info3 := lookup_doc(&app, Doc_Query{name = "make"}, "", "", root, "windows")
	defer doc_info_free(&info3)
	testing.expect(t, info3.found && strings.contains(info3.location, "core_builtin"), info3.location)
	info4 := lookup_doc(&app, Doc_Query{name = "T", path = "core:testing"}, "", "", root, "windows")
	defer doc_info_free(&info4)
	testing.expect(t, info4.found && len(info4.signature) > 2, "the struct")
}

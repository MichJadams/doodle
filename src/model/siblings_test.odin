package model

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
OTHER :: "package main\n\nimport \"core:fmt\"\n\n" +
	"external_print :: proc() {\n\tfmt.println(\"a call from a different file\")\n}\n\n" +
	"shout :: proc(s: string, times: int) -> string {\n\treturn s\n}\n\n" +
	"@(private=\"file\")\nhidden :: proc() {}\n\n" +
	"@(private = \"file\") also_hidden :: proc() {}\n\n" +
	"@(private)\npackage_private :: proc() -> int { return 1 }\n\n" +
	"long_one :: proc(\n\ta: int,\n\tb: bool,\n) -> (int, bool) {\n\treturn a, b\n}\n\n" +
	"Point :: struct { x: int }\n"

@(private = "file")
MAIN :: "package main\n\nmain :: proc() {\n\tx := 1\n}"

@(private = "file")
cleanup :: proc(app: ^App) {
	clear_nav(app)
	delete(app.nav)
	doc_reset(app)
	delete(app.doc.nodes)
	delete(app.recent_imports)
	free_menus(app)
	free_siblings(app)
}

@(private = "file")
names :: proc(app: ^App) -> string {
	out := make([dynamic]string, context.temp_allocator)
	for p in app.sibling_procs do append(&out, p.name)
	return strings.join(out[:], ",", context.temp_allocator)
}

@(test)
test_sibling_scan :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	scan_sibling_source(&app, OTHER, "new_file.odin")
	// File-private procs are invisible to other files; package-private ones aren't.
	testing.expect_value(t, names(&app), "external_print,shout,package_private,long_one")
	testing.expect_value(t, app.sibling_procs[0].file, "new_file.odin")
}

@(test)
test_sibling_signatures :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	doc_from_source(&app, MAIN)
	scan_sibling_source(&app, OTHER, "new_file.odin")
	sig := call_signature(&app, "", "shout")
	testing.expect(t, sig.known)
	testing.expect_value(t, sig.req, 2)
	testing.expect_value(t, sig.ret, "string")
	testing.expect_value(t, len(sig.params), 2)
	if len(sig.params) == 2 do testing.expect_value(t, sig.params[1].type, "int")
	none := call_signature(&app, "", "external_print")
	testing.expect(t, none.known && none.ret == RET_NONE && none.req == 0)
	long := call_signature(&app, "", "long_one") // signature over several lines
	testing.expect_value(t, long.req, 2)
	testing.expect_value(t, result_count(long.ret), 2)
	testing.expect(t, !call_signature(&app, "", "hidden").known)
}

@(test)
test_sibling_procs_in_calls_menu :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	doc_from_source(&app, MAIN)
	scan_sibling_source(&app, OTHER, "new_file.odin")
	got := collect_proc_names(&app)
	defer delete(got)
	joined := strings.join(got, ",", context.temp_allocator)
	testing.expect_value(t, joined, "main,external_print,shout,package_private,long_one")
}

@(test)
test_sibling_call_gets_dots_and_capture :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	doc_from_source(&app, MAIN)
	scan_sibling_source(&app, OTHER, "new_file.odin")
	app.state = .Editor
	// Turn `x := 1` into a bare call of the sibling's shout(): typed dots + capture dot.
	ni := 3
	fields := &app.doc.nodes[ni].fields
	for f in fields do if len(f.text) > 0 do delete(f.text)
	clear(fields)
	append(fields, Field{strings.clone("\t"), false, false, "", "", ""}, Field{"", false, true, "body", "", ""})
	make_call_this_package(&app, ni, 1, "shout")
	hints := make([dynamic]string, context.temp_allocator)
	for f in app.doc.nodes[ni].fields do if f.slot do append(&hints, f.hint)
	testing.expect_value(t, strings.join(hints[:], ",", context.temp_allocator), "string,int")
	update(&app, Input{})
	testing.expect(t, capture_dot_index(app.doc.nodes[ni]) >= 0, "shout returns a string: capture dot")
}

@(test)
test_load_sibling_procs_from_folder :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	tmp, err := os.temp_directory(context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	dir := fmt.tprintf("%s/doodle_siblings_test_%d", tmp, os.get_pid())
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	_ = os.write_entire_file(fmt.tprintf("%s/main.odin", dir), transmute([]byte)string("package main\n\nmine :: proc() {}\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/new_file.odin", dir), transmute([]byte)string(OTHER))
	_ = os.write_entire_file(fmt.tprintf("%s/notes.txt", dir), transmute([]byte)string("not_code :: proc() {}\n"))
	load_siblings(&app, dir, "main.odin") // the open file itself is left out
	testing.expect_value(t, names(&app), "external_print,shout,package_private,long_one")
	load_siblings(&app, dir, "new_file.odin")
	testing.expect_value(t, names(&app), "mine")
}

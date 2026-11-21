package model

import "core:strings"
import "core:testing"

@(private = "file")
SRC :: "package main\n\nimport \"core:strings\"\n\n" +
	"main :: proc() {\n" +          // 4
	"\ts := \"hi\"\n" +             // 5
	"\tlen(s)\n" +                  // 6
	"\tnothing()\n" +               // 7
	"\tstrings.clone(s)\n" +        // 8
	"\tpair()\n" +                  // 9
	"\tn := len(s)\n" +             // 10
	"}\n\n" +                       // 11, 12
	"nothing :: proc() {}\n" +      // 13
	"pair :: proc() -> (int, bool) { return 1, true }" // 14

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
setup :: proc(app: ^App) {
	doc_from_source(app, SRC)
	app.state = .Editor
	update(app, Input{}) // syncs the capture dots
}

@(test)
test_capture_dots_on_bare_calls_that_return :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app)
	has :: proc(app: ^App, ni: int) -> bool { return capture_dot_index(app.doc.nodes[ni]) >= 0 }
	testing.expect(t, has(&app, 6), "len(s) returns int")
	testing.expect(t, !has(&app, 7), "nothing() returns nothing")
	testing.expect(t, has(&app, 8), "strings.clone(s) returns a string (loaded with its indentation)")
	testing.expect(t, has(&app, 9), "pair() returns two values")
	testing.expect(t, !has(&app, 5), "a declaration is not a bare call")
	testing.expect(t, !has(&app, 10), "an already-captured call")
	// The dots never reach the saved source.
	src := doc_to_source(&app, context.temp_allocator)
	testing.expect_value(t, src, SRC)
}

@(test)
test_capture_dot_is_first_stop_on_its_line :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app)
	app.editor_line, app.editor_dot, app.editor_field = 6, false, 0
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok && ni == 6 && is_capture_dot(app.doc.nodes[ni].fields[fi]), "leaf 0 is the capture dot")
}

@(test)
test_capture_result :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app)
	focus_field_index(&app, 6, capture_dot_index(app.doc.nodes[6]))
	update(&app, Input{confirm = true})
	line := node_text(app.doc.nodes[6], context.temp_allocator)
	testing.expect(t, strings.has_suffix(line, " := len(s)"), line)
	testing.expect_value(t, capture_dot_index(app.doc.nodes[6]), -1)
	ni, fi, ok := editor_target(&app)
	testing.expect(t, ok && ni == 6 && app.doc.nodes[ni].fields[fi].editable, "cursor on the new name")
	name := app.doc.nodes[ni].fields[fi].text
	testing.expect_value(t, line, strings.concatenate({"\t", name, " := len(s)"}, context.temp_allocator))
}

@(test)
test_capture_two_results :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app)
	focus_field_index(&app, 9, capture_dot_index(app.doc.nodes[9]))
	update(&app, Input{confirm = true})
	line := strings.trim_space(node_text(app.doc.nodes[9], context.temp_allocator))
	comma := strings.index(line, ", ")
	decl := strings.index(line, " := pair()")
	testing.expect(t, comma > 0 && decl > comma && strings.has_suffix(line, " := pair()"), line)
}

@(test)
test_capture_loaded_line_keeps_indent :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app)
	focus_field_index(&app, 8, capture_dot_index(app.doc.nodes[8]))
	update(&app, Input{confirm = true})
	line := node_text(app.doc.nodes[8], context.temp_allocator)
	testing.expect(t, strings.has_prefix(line, "\t") && strings.has_suffix(line, " := strings.clone(s)"), line)
}

@(test)
test_capture_dot_follows_the_callee :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app)
	// Renaming the callee to a proc that returns nothing removes the dot.
	cfi := -1
	for f, i in app.doc.nodes[6].fields do if strings.trim_space(f.text) == "len" { cfi = i; break }
	testing.expect(t, cfi >= 0)
	set_field_text(&app, 6, cfi, "nothing")
	update(&app, Input{})
	testing.expect_value(t, capture_dot_index(app.doc.nodes[6]), -1)
	set_field_text(&app, 6, cfi - 1, "len") // the dot was before the callee: index shifted
	update(&app, Input{})
	testing.expect(t, capture_dot_index(app.doc.nodes[6]) >= 0)
}

@(test)
test_result_count :: proc(t: ^testing.T) {
	testing.expect_value(t, result_count("int"), 1)
	testing.expect_value(t, result_count("(int, bool)"), 2)
	testing.expect_value(t, result_count("(a, b: int, ok: bool)"), 3)
	testing.expect_value(t, result_count("(res: string, err: runtime.Allocator_Error) #optional_allocator_error"), 1)
	testing.expect_value(t, result_count("(m: map[string]int, ok: bool)"), 2)
}

@(test)
test_capture_dots_resume_after_cancelled_edit :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app)
	app.replacing = true // as LT+A leaves it while its menu is open...
	app.state = .Radial
	app.return_state = .Editor
	append(&app.nav, MenuView{title = "x"})
	menu_cancel(&app) // ...then B
	testing.expect(t, !app.replacing, "cancel clears the replace mode")
	cfi := -1
	for f, i in app.doc.nodes[7].fields do if strings.trim_space(f.text) == "nothing" { cfi = i; break }
	testing.expect(t, cfi >= 0)
	set_field_text(&app, 7, cfi, "len") // nothing() -> len(): now returns a value
	update(&app, Input{})
	testing.expect(t, capture_dot_index(app.doc.nodes[7]) >= 0, "the dots keep syncing")
}

@(test)
test_capture_after_format :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	doc_from_source(&app, SRC)
	format_doc(&app)
	app.state = .Editor
	update(&app, Input{})
	ci := capture_dot_index(app.doc.nodes[6])
	testing.expect(t, ci >= 0)
	focus_field_index(&app, 6, ci)
	update(&app, Input{confirm = true})
	line := node_text(app.doc.nodes[6], context.temp_allocator)
	testing.expect(t, strings.has_suffix(line, " := len(s)"), line)
}

@(private = "file")
UNCAP_SRC :: "package main\n\nimport \"core:strings\"\n\n" +
	"main :: proc() {\n" +                      // 4
	"\tn := len(s)\n" +                         // 5
	"\tx: string = strings.clone(s)\n" +        // 6
	"\ta, b := pair()\n" +                      // 7
	"\ty := 5\n" +                              // 8
	"}\n" +                                     // 9
	"pair :: proc() -> (int, bool) { return 1, true }" // 10

@(private = "file")
delete_name :: proc(app: ^App, ni: int, name: string) {
	for f, i in app.doc.nodes[ni].fields {
		if f.editable && f.text == name { focus_field_index(app, ni, i); break }
	}
	delete_selected(app)
	update(app, Input{})
}

@(private = "file")
uncap_setup :: proc(app: ^App) {
	doc_from_source(app, UNCAP_SRC)
	format_doc(app)
	app.state = .Editor
	update(app, Input{})
}

@(test)
test_delete_captured_name_leaves_the_call :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	uncap_setup(&app)
	n := len(app.doc.nodes)
	delete_name(&app, 5, "n")
	testing.expect_value(t, len(app.doc.nodes), n) // the line stays
	testing.expect_value(t, strings.trim_right_space(nodes_to_source(&app, 5, 5, context.temp_allocator)), "\tlen(s)")
	ci := capture_dot_index(app.doc.nodes[5])
	testing.expect(t, ci >= 0, "the capture dot is back")
	_, fi, _ := editor_target(&app)
	testing.expect_value(t, fi, ci) // and the cursor is on it
	// A on it captures again.
	update(&app, Input{confirm = true})
	testing.expect(t, strings.has_suffix(node_text(app.doc.nodes[5], context.temp_allocator), " := len(s)"))
}

@(test)
test_delete_typed_captured_name_keeps_package :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	uncap_setup(&app)
	delete_name(&app, 6, "x")
	testing.expect_value(t, strings.trim_right_space(nodes_to_source(&app, 6, 6, context.temp_allocator)), "\tstrings.clone(s)")
	testing.expect(t, capture_dot_index(app.doc.nodes[6]) >= 0)
}

@(test)
test_delete_one_of_several_names :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	uncap_setup(&app)
	delete_name(&app, 7, "a")
	testing.expect_value(t, strings.trim_right_space(nodes_to_source(&app, 7, 7, context.temp_allocator)), "\t_, b := pair()")
	delete_name(&app, 7, "b") // no real name left: the declaration goes
	testing.expect_value(t, strings.trim_right_space(nodes_to_source(&app, 7, 7, context.temp_allocator)), "\tpair()")
	testing.expect(t, capture_dot_index(app.doc.nodes[7]) >= 0)
}

@(test)
test_delete_other_names_still_deletes_the_line :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	uncap_setup(&app)
	n := len(app.doc.nodes)
	delete_name(&app, 8, "y") // `y := 5`: not a call - the whole statement goes, as before
	testing.expect_value(t, len(app.doc.nodes), n - 1)
}

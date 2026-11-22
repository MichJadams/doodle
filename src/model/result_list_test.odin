package model

// Result lists and return values that grow (result_list.odin): through the
// real menus, LT+B, and the loader.

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
pick :: proc(t: ^testing.T, app: ^App, label: string, loc := #caller_location) -> bool {
	v := current_view(app)
	if !testing.expectf(t, v != nil, "no menu open (wanted %q)", label, loc = loc) do return false
	for e, i in v.entries do if e.label == label {
		v.index = i
		update(app, Input{confirm = true})
		return true
	}
	testing.expectf(t, false, "no %q in menu %q", label, v.title, loc = loc)
	return false
}

// The line as shown: dots as ● (an extra dot as ○), other fields' text.
@(private = "file")
shown :: proc(app: ^App, ni: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for f in app.doc.nodes[ni].fields {
		switch {
		case is_more_dot(f): strings.write_string(&b, "○")
		case f.slot && f.kind != "body": strings.write_string(&b, "●")
		case:                strings.write_string(&b, f.text)
		}
	}
	return strings.trim_space(strings.to_string(b))
}

@(private = "file")
line_of :: proc(app: ^App, text: string) -> int {
	for n, i in app.doc.nodes do if strings.contains(node_text(n, context.temp_allocator), text) do return i
	return -1
}

// The field index of the nth dot (any kind but body) of line ni, or -1.
@(private = "file")
nth_dot :: proc(app: ^App, ni, nth: int) -> int {
	seen := 0
	for f, i in app.doc.nodes[ni].fields do if f.slot && f.kind != "body" {
		if seen == nth do return i
		seen += 1
	}
	return -1
}

@(private = "file")
open_at :: proc(app: ^App, ni, fi: int) {
	focus_field_index(app, ni, fi)
	update(app, Input{confirm = true})
}

@(private = "file")
field_with :: proc(app: ^App, ni: int, text: string, nth := 0) -> int {
	seen := 0
	for f, i in app.doc.nodes[ni].fields do if strings.trim_space(f.text) == text {
		if seen == nth do return i
		seen += 1
	}
	return -1
}

@(private = "file")
saved :: proc(app: ^App) -> string { return file_text(app, context.temp_allocator) }

// Result list from the menus: a type, another (parentheses appear), LT+B one
// (they go), LT+B the last (back to the empty result dot, `-> ` not saved).
@(test)
test_result_list_from_menus :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n")
	append_proc_node(&app, "divmod")
	h := line_of(&app, ":: proc")
	if !testing.expect(t, h >= 0, "header") do return
	testing.expect_value(t, shown(&app, h), "divmod :: proc( ● ) -> ● {")

	open_at(&app, h, nth_dot(&app, h, 1)) // the result dot
	if pick(t, &app, "Type") do pick(t, &app, "int")
	testing.expect_value(t, shown(&app, h), "divmod :: proc( ● ) -> int○ {")
	testing.expect(t, strings.contains(saved(&app), "divmod :: proc() -> int {"), saved(&app))

	open_at(&app, h, nth_dot(&app, h, 1)) // the extra (blue) dot
	if pick(t, &app, "Type") do pick(t, &app, "int")
	testing.expect_value(t, shown(&app, h), "divmod :: proc( ● ) -> (int, int○) {")
	testing.expect(t, strings.contains(saved(&app), "divmod :: proc() -> (int, int) {"), saved(&app))

	open_at(&app, h, nth_dot(&app, h, 1))
	if pick(t, &app, "Type") do pick(t, &app, "bool")
	testing.expect_value(t, shown(&app, h), "divmod :: proc( ● ) -> (int, int, bool○) {")

	// LT+B on the first result: it goes with its ", ".
	focus_field_index(&app, h, field_with(&app, h, "int"))
	delete_selected(&app)
	update(&app, Input{})
	testing.expect_value(t, shown(&app, h), "divmod :: proc( ● ) -> (int, bool○) {")
	focus_field_index(&app, h, field_with(&app, h, "bool"))
	delete_selected(&app)
	update(&app, Input{})
	testing.expect_value(t, shown(&app, h), "divmod :: proc( ● ) -> int○ {")
	testing.expect(t, strings.contains(saved(&app), "divmod :: proc() -> int {"), saved(&app))

	// LT+B on the extra dot: nothing (not the procedure).
	focus_field_index(&app, h, nth_dot(&app, h, 1))
	delete_selected(&app)
	testing.expect_value(t, shown(&app, h), "divmod :: proc( ● ) -> int○ {")

	focus_field_index(&app, h, field_with(&app, h, "int"))
	delete_selected(&app)
	update(&app, Input{})
	testing.expect_value(t, shown(&app, h), "divmod :: proc( ● ) -> ● {")
	testing.expect(t, strings.contains(saved(&app), "divmod :: proc() {"), saved(&app))
	// ...and on the empty result dot: nothing either.
	focus_field_index(&app, h, nth_dot(&app, h, 1))
	delete_selected(&app)
	testing.expect(t, line_of(&app, ":: proc") == h, "the procedure is still there")
}

// Return values from the menus: the extra orange dot after the first value,
// typed from the procedure's results; LT+B removes a value with its ", ".
@(test)
test_return_values_from_menus :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\ndivmod :: proc(a, b: int) -> (int, int) {\n}")
	closing := -1
	for n, i in app.doc.nodes do if strings.trim_space(node_text(n, context.temp_allocator)) == "}" do closing = i
	if !testing.expect(t, closing >= 0, "closing brace") do return
	focus_dot_at(&app, closing)
	update(&app, Input{confirm = true})
	if pick(t, &app, "Jumps and cleanup") do pick(t, &app, "Return")
	r := line_of(&app, "return")
	if !testing.expect(t, r >= 0, "return line") do return
	testing.expect_value(t, shown(&app, r), "return ●")
	testing.expect_value(t, app.doc.nodes[r].fields[nth_dot(&app, r, 0)].hint, "int")

	open_at(&app, r, nth_dot(&app, r, 0))
	pick(t, &app, "Number")
	testing.expect_value(t, shown(&app, r), "return 0○")
	more := nth_dot(&app, r, 0)
	testing.expect(t, more >= 0 && app.doc.nodes[r].fields[more].kind == RET_MORE_KIND && app.doc.nodes[r].fields[more].hint == "int", "an orange dot expecting the 2nd result's type")

	open_at(&app, r, more)
	pick(t, &app, "Number")
	testing.expect_value(t, shown(&app, r), "return 0, 0○")
	more = nth_dot(&app, r, 0)
	testing.expect_value(t, app.doc.nodes[r].fields[more].hint, "") // past the procedure's two results
	testing.expect(t, strings.contains(saved(&app), "\treturn 0, 0\n"), saved(&app))

	// LT+B on the 2nd value: `return 0○`; on the extra dot: nothing.
	focus_field_index(&app, r, field_with(&app, r, "0", 1))
	delete_selected(&app)
	update(&app, Input{})
	testing.expect_value(t, shown(&app, r), "return 0○")
	focus_field_index(&app, r, nth_dot(&app, r, 0))
	delete_selected(&app)
	testing.expect_value(t, shown(&app, r), "return 0○")
	testing.expect(t, line_of(&app, "return") == r, "the return is still there")
}

// Loading: your divmod comes back with its result list and return values
// structured, the extra dots in place, and saves back unchanged.
@(test)
test_result_list_loader :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	src := "package main\n\ndivmod :: proc(a, b: int) -> (int, int) { // multiple return values\n\treturn a / b, a % b\n}\n\none :: proc() -> int {\n\treturn 1\n}\n\nnothing :: proc() {\n\treturn\n}\n\nmain :: proc() {\n\tq, r := divmod(7, 2)\n}\n"
	doc_from_source(&app, src)
	free_all(context.temp_allocator)

	h := line_of(&app, "divmod :: proc")
	testing.expect_value(t, shown(&app, h), "divmod :: proc(a, b: int) -> (int, int○) { // multiple return values")
	for f in app.doc.nodes[h].fields do if strings.trim_space(f.text) == "int" && f.kind == "type" do testing.expect(t, f.editable, "result types are type fields")
	r := line_of(&app, "return a / b")
	testing.expect_value(t, shown(&app, r), "return a / b, a % b○")
	more := nth_dot(&app, r, 0)
	testing.expect(t, app.doc.nodes[r].fields[more].kind == RET_MORE_KIND, "the extra return dot")
	testing.expect(t, field_with(&app, r, "/") >= 0 && field_with(&app, r, "%") >= 0, "each value is structured")

	testing.expect_value(t, shown(&app, line_of(&app, "one :: proc")), "one :: proc() -> int○ {")
	testing.expect_value(t, shown(&app, line_of(&app, "return 1")), "return 1○")
	testing.expect_value(t, shown(&app, line_of(&app, "nothing :: proc")), "nothing :: proc() {")
	bare := -1
	for n, i in app.doc.nodes do if strings.trim_space(node_text(n, context.temp_allocator)) == "return" do bare = i
	testing.expect(t, bare >= 0, "bare return")
	if bare >= 0 do testing.expect_value(t, shown(&app, bare), "return ○")

	testing.expect_value(t, saved(&app), src)

	// A loaded result list grows and shrinks like a menu-built one.
	open_at(&app, h, nth_dot(&app, h, 0))
	if pick(t, &app, "Type") do pick(t, &app, "bool")
	testing.expect_value(t, shown(&app, h), "divmod :: proc(a, b: int) -> (int, int, bool○) { // multiple return values")
	focus_field_index(&app, h, field_with(&app, h, "bool"))
	delete_selected(&app)
	update(&app, Input{})
	testing.expect_value(t, saved(&app), src)
}

// Left alone: named results, a proc-typed parameter's arrow, a forward
// declaration, and a return value that is one call keeps its typed arguments.
@(test)
test_result_list_loader_leaves_others :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	src := "package main\n\nimport \"core:fmt\"\n\nnamed :: proc() -> (q, r: int) {\n\treturn\n}\n\napply :: proc(f: proc(x: int) -> int) {\n}\n\nshow :: proc() -> int {\n\treturn fmt.println(\"hi\")\n}\n"
	doc_from_source(&app, src)
	for f in app.doc.nodes[line_of(&app, "named :: proc")].fields do testing.expect(t, !is_more_dot(f), "named results stay as written")
	for f in app.doc.nodes[line_of(&app, "apply :: proc")].fields do testing.expect(t, !is_more_dot(f) && f.kind != "type", "a parameter's -> isn't a result list")
	c := line_of(&app, "return fmt.println")
	testing.expect_value(t, shown(&app, c), "return fmt.println(\"hi\", ●)○")
	testing.expect_value(t, saved(&app), src)
}

package model

// Push-to-talk targets and spoken numbers (dictation.odin).

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
focus_text :: proc(t: ^testing.T, app: ^App, ni: int, text: string, loc := #caller_location) -> bool {
	n := app.doc.nodes[ni]
	seen := 0
	for u, k in line_leaves(n) {
		b := strings.builder_make(context.temp_allocator)
		for i in u.fa ..< u.fb do strings.write_string(&b, n.fields[i].text)
		if strings.to_string(b) == text {
			app.editor_line, app.editor_dot, app.editor_attr, app.editor_field = ni, false, false, k
			return true
		}
		seen += 1
	}
	testing.expectf(t, false, "no part %q on line %d (%q)", text, ni, node_text(n, context.temp_allocator), loc = loc)
	return false
}

@(test)
test_spoken_number :: proc(t: ^testing.T) {
	cases := [][2]string{
		{"10", "10"}, {"10.", "10"}, {" 0", "0"}, {"3.5", "3.5"}, {"-2", "-2"}, {"- 2", "-2"}, {"1,000", "1000"},
		{"Ten.", "10"}, {"zero", "0"}, {"Twenty-five", "25"}, {"twenty five", "25"}, {"ninety nine", "99"},
		{"one hundred", "100"}, {"a hundred and five", "105"}, {"two hundred thirty", "230"},
		{"one thousand two hundred", "1200"}, {"three point one four", "3.14"}, {"point five", "0.5"},
		{"minus two", "-2"}, {"negative ten", "-10"}, {"2 hundred", "200"}, {"0x1F", "0x1F"},
	}
	for c in cases {
		got, ok := spoken_number(c[0], context.temp_allocator)
		testing.expectf(t, ok && got == c[1], "%q -> %q (ok=%v), want %q", c[0], got, ok, c[1])
	}
	for bad in ([]string{"", "hello", "one two", "twenty thirty", "five twenty", "x", "three point", "point", "minus"}) {
		got, ok := spoken_number(bad, context.temp_allocator)
		testing.expectf(t, !ok, "%q should not be a number (got %q)", bad, got)
	}
}

@(test)
test_is_number_text :: proc(t: ^testing.T) {
	for s in ([]string{"0", "10", "3.5", "1_000", "0x1F", "0b101", "1e9", "2.5e-3", "-2"}) do testing.expectf(t, is_number_text(s), "%q", s)
	for s in ([]string{"", "x", "1.2.3", "0..<10", "0x", "1a", "-", "a1"}) do testing.expectf(t, !is_number_text(s), "%q", s)
}

// The reported case: `y = 0` in a struct literal loaded from a file.
@(test)
test_dictate_number_in_loaded_struct_literal :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\npoint :: struct {\n\tx: f32,\n\ty: f32,\n\tz: f32,\n}\n\nmain :: proc() {\n\tp := point{x = 10, y = 0, z = 0}\n}")
	// Every value takes a number - not just the first.
	values := []string{"10", "0", "0"}
	k := 0
	n := app.doc.nodes[9]
	for u, li in line_leaves(n) {
		if u.fb - u.fa != 1 || !is_number_literal_field(n.fields[u.fa]) do continue
		app.editor_line, app.editor_dot, app.editor_field = 9, false, li
		_, fi, mode := dictation_target(&app)
		testing.expectf(t, mode == .Number, "value %d: %v", k, mode)
		testing.expect_value(t, n.fields[fi].text, values[k])
		k += 1
	}
	testing.expect_value(t, k, 3)
	// y = 0 -> "seven" -> y = 7; z = 0 -> "2.5".
	if focus_text(t, &app, 9, "y") {
		app.editor_field += 1 // its value
		ni, fi, mode := dictation_target(&app)
		testing.expect_value(t, mode, Dictation_Mode.Number)
		num, ok := spoken_number("seven", context.temp_allocator)
		testing.expect(t, ok && dictate_number(&app, ni, fi, num))
	}
	if focus_text(t, &app, 9, "z") {
		app.editor_field += 1
		ni, fi, _ := dictation_target(&app)
		testing.expect(t, dictate_number(&app, ni, fi, "2.5"))
	}
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), "package main\n\npoint :: struct {\n\tx: f32,\n\ty: f32,\n\tz: f32,\n}\n\nmain :: proc() {\n\tp := point{x = 10, y = 7, z = 2.5}\n}")
	// The name is still dictated as a name.
	if focus_text(t, &app, 9, "p") {
		_, _, mode := dictation_target(&app)
		testing.expect_value(t, mode, Dictation_Mode.Identifier)
	}
}

// A value dot that takes a number becomes the number; one that doesn't stays out.
@(test)
test_dictate_number_into_value_dot :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nmain :: proc() {\n}")
	n: Node
	append(&n.fields, Field{strings.clone("\tcount: int = "), false, false, "", "", ""})
	append(&n.fields, Field{"", false, true, "value", "int", ""})
	inject_at(&app.doc.nodes, 3, n)
	n2: Node
	append(&n2.fields, Field{strings.clone("\tname: string = "), false, false, "", "", ""})
	append(&n2.fields, Field{"", false, true, "value", "string", ""})
	inject_at(&app.doc.nodes, 4, n2)
	focus_field_index(&app, 3, 1)
	ni, fi, mode := dictation_target(&app)
	testing.expect_value(t, mode, Dictation_Mode.Number)
	testing.expect(t, dictate_number(&app, ni, fi, "12"))
	testing.expect_value(t, node_text(app.doc.nodes[3], context.temp_allocator), "\tcount: int = 12")
	testing.expect(t, app.doc.nodes[3].fields[1].editable, "a number field (LT+A keypad, dictate again)")
	focus_field_index(&app, 4, 1)
	_, _, mode = dictation_target(&app)
	testing.expect_value(t, mode, Dictation_Mode.None)
}

// LT+A's keypad works on a loaded number too.
@(test)
test_keypad_on_loaded_number :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nmain :: proc() {\n\tx := 5\n}")
	if !focus_text(t, &app, 3, "5") do return
	edit_selected(&app)
	testing.expect_value(t, app.state, State.Radial)
	v := current_view(&app)
	if !testing.expect(t, v != nil && v.title == "Number") do return
	for e, i in v.entries do if e.label == "7" { v.index = i; break }
	update(&app, Input{confirm = true})
	testing.expect_value(t, node_text(app.doc.nodes[3], context.temp_allocator), "\tx := 57")
}

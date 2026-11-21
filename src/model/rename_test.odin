package model

import "core:strings"
import "core:testing"

@(private = "file")
cleanup :: proc(app: ^App) {
	rename_clear(app)
	clear_nav(app); delete(app.nav); doc_reset(app); delete(app.doc.nodes)
	delete(app.recent_imports); free_menus(app)
}

@(private = "file")
pick :: proc(app: ^App, label: string) -> bool {
	v := current_view(app)
	if v == nil do return false
	for e, i in v.entries do if e.label == label {
		v.index = i
		update(app, Input{confirm = true})
		return true
	}
	return false
}

@(private = "file")
labels :: proc(app: ^App) -> string {
	v := current_view(app)
	if v == nil do return "<no menu>"
	out := make([dynamic]string, context.temp_allocator)
	for e in v.entries do append(&out, e.label)
	return strings.join(out[:], " | ", context.temp_allocator)
}

// Field index of the editable name `name` on line ni.
@(private = "file")
name_at :: proc(app: ^App, ni: int, name: string) -> int {
	for f, k in app.doc.nodes[ni].fields do if f.editable && !f.slot && f.text == name do return k
	return -1
}

@(private = "file")
line_of :: proc(app: ^App, prefix: string) -> int {
	for n, i in app.doc.nodes do if strings.has_prefix(strings.trim_space(node_text(n, context.temp_allocator)), prefix) do return i
	return -1
}

@(test)
test_rename_constant_everywhere :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nWHITENESS :: 5\n\noperation: int = WHITENESS\n\nmain :: proc() {\n" +
		"\tx := WHITENESS + 1\n\ts := \"WHITENESS\"\n\t// WHITENESS in a comment\n}\n")
	ni := line_of(&app, "WHITENESS ::")
	fi := name_at(&app, ni, "WHITENESS")
	testing.expect(t, fi >= 0, "the constant's name is editable")
	rename_field(&app, ni, fi, "WHITE")
	testing.expect_value(t, app.state, State.Radial)
	testing.expect_value(t, current_view(&app).title, "Rename WHITENESS to WHITE?")
	testing.expect_value(t, labels(&app), "Rename all 2 uses | Only this one")
	testing.expect(t, pick(&app, "Rename all 2 uses"))
	testing.expect_value(t, app.state, State.Editor)
	src := doc_to_source(&app, context.temp_allocator)
	testing.expectf(t, strings.contains(src, "WHITE :: 5"), "%s", src)
	testing.expectf(t, strings.contains(src, "operation: int = WHITE\n"), "%s", src)
	testing.expectf(t, strings.contains(src, "x := WHITE + 1"), "%s", src)
	testing.expectf(t, strings.contains(src, "s := \"WHITENESS\""), "strings are left alone: %s", src)
	testing.expectf(t, strings.contains(src, "// WHITENESS in a comment"), "comments are left alone: %s", src)
}

@(test)
test_rename_local_respects_scope_and_shadowing :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nmain :: proc() {\n" +
		"\tcount := 1\n" +
		"\ty := count\n" +
		"\tif true {\n" +
		"\t\tcount := 2\n" +
		"\t\tz := count\n" +
		"\t}\n" +
		"\tw := count\n" +
		"}\n\n" +
		"other :: proc() {\n" +
		"\tq := count\n" +
		"}\n")
	ni := line_of(&app, "count := 1")
	rename_field(&app, ni, name_at(&app, ni, "count"), "total")
	testing.expect_value(t, labels(&app), "Rename all 2 uses | Only this one")
	testing.expect(t, pick(&app, "Rename all 2 uses"))
	src := doc_to_source(&app, context.temp_allocator)
	for want in ([]string{"total := 1", "y := total", "\t\tcount := 2", "z := count", "w := total", "q := count"}) {
		testing.expectf(t, strings.contains(src, want), "missing %q in:\n%s", want, src)
	}
}

@(test)
test_rename_parameter_and_decline :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nscale :: proc(a: int) -> int {\n\tb := a * 2\n\treturn b + a\n}\n")
	hdr := line_of(&app, "scale ::")
	fi := name_at(&app, hdr, "a")
	testing.expect(t, fi >= 0, "the parameter name is editable")
	// "Only this one": the uses stay.
	rename_field(&app, hdr, fi, "amount")
	testing.expect_value(t, labels(&app), "Rename all 2 uses | Only this one")
	testing.expect(t, pick(&app, "Only this one"))
	src := doc_to_source(&app, context.temp_allocator)
	testing.expectf(t, strings.contains(src, "proc(amount: int)") && strings.contains(src, "b := a * 2"), "%s", src)
	// Back to `a` (nothing uses `amount`, so no prompt), then rename and accept.
	rename_field(&app, hdr, fi, "a")
	testing.expect_value(t, app.state, State.Editor)
	rename_field(&app, hdr, fi, "amount")
	testing.expect(t, pick(&app, "Rename all 2 uses"))
	src = doc_to_source(&app, context.temp_allocator)
	testing.expectf(t, strings.contains(src, "b := amount * 2") && strings.contains(src, "return b + amount"), "%s", src)
	// B on the prompt: only the declaration changes.
	rename_field(&app, hdr, fi, "n")
	testing.expect_value(t, app.state, State.Radial)
	update(&app, Input{cancel = true})
	testing.expect_value(t, app.state, State.Editor)
	testing.expect(t, !app.rename_active)
	src = doc_to_source(&app, context.temp_allocator)
	testing.expectf(t, strings.contains(src, "proc(n: int)") && strings.contains(src, "b := amount * 2"), "%s", src)
}

// Changing a use (not a declaration) never asks.
@(test)
test_rename_no_prompt_for_a_use :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nmain :: proc() {\n\tcount := 1\n\tcount = 2\n\ty := count\n}\n")
	ni := line_of(&app, "count = 2")
	if fi := name_at(&app, ni, "count"); fi >= 0 {
		testing.expect_value(t, len(rename_uses(&app, ni, fi, "count", "total")), 0)
	}
}

@(test)
test_code_word_hits :: proc(t: ^testing.T) {
	testing.expect_value(t, len(code_word_hits("a + ab + a.a + \"a\" + b.a // a", "a")), 2) // `a` and the `a` before `.a`
	testing.expect_value(t, len(code_word_hits("T{a = a, b = 2}", "a")), 1)               // the key isn't the variable
	testing.expect_value(t, len(code_word_hits("x == a", "a")), 1)
}

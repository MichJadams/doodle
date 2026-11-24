package model

// Edit word by word (word_edit.odin).

import "core:strings"
import "core:testing"

@(private = "file")
cleanup :: proc(app: ^App) {
	clear_nav(app)
	delete(app.nav)
	if app.slot_menu != nil do free_entries(app.slot_menu)
	doc_reset(app)
	delete(app.doc.nodes)
	delete(app.recent_imports)
	free_menus(app)
}

@(private = "file")
pick :: proc(t: ^testing.T, app: ^App, label: string, loc := #caller_location) -> bool {
	v := current_view(app)
	if !testing.expectf(t, v != nil, "no menu open (wanted %q)", label, loc = loc) do return false
	for e, i in v.entries do if e.label == label || strings.has_prefix(e.label, strings.concatenate({label, "   "}, context.temp_allocator)) {
		v.index = i
		update(app, Input{confirm = true})
		return true
	}
	testing.expectf(t, false, "no %q in menu %q", label, v.title, loc = loc)
	return false
}

@(private = "file")
SRC :: "package main\n\nimport \"core:fmt\"\n\nmain :: proc() {\n\tfmt.println(\"hello brave world\")\n}\n"

// The string's text field on line 5.
@(private = "file")
string_field :: proc(app: ^App) -> (ni, fi: int) {
	for f, i in app.doc.nodes[5].fields do if f.kind == "string" do return 5, i
	return 5, -1
}

@(private = "file")
text :: proc(app: ^App) -> string {
	ni, fi := string_field(app)
	return app.doc.nodes[ni].fields[fi].text
}

// Y on the string > Edit word by word.
@(private = "file")
enter :: proc(t: ^testing.T, app: ^App) -> bool {
	app.state = .Editor
	doc_from_source(app, SRC)
	ni, fi := string_field(app)
	if !testing.expect(t, fi >= 0, "a string field") do return false
	focus_field_index(app, ni, fi)
	update(app, Input{y = true})
	if !testing.expect(t, app.state == .Radial, "Y opens the text tools") do return false
	if !pick(t, app, WORDS_LABEL) do return false
	return testing.expect(t, app.word_edit_active && app.state == .Editor, "word by word")
}

@(test)
test_word_tokens :: proc(t: ^testing.T) {
	words :: proc(s: string) -> []string {
		toks := word_tokens(s)
		out := make([]string, len(toks), context.temp_allocator)
		for k, i in toks do out[i] = s[k.a:k.b]
		return out
	}
	got := words(`x: %v, y=%08.3f\n {{done}} {:v} 100% sure`)
	want := []string{"x:", "%v", ",", "y=", "%08.3f", `\n`, "{{", "done", "}}", "{:v}", "100%", "sure"}
	if !testing.expect_value(t, len(got), len(want)) do return
	for w, i in want do testing.expect_value(t, got[i], w)
	testing.expect_value(t, len(word_tokens("")), 0)
}

// Y on a string's text: Replace value / Case / Escape / Edit word by word;
// in it, Left/Right step over words and dots, B leaves.
@(test)
test_word_edit_enter_and_move :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	ni, fi := string_field(&app)
	focus_field_index(&app, ni, fi)
	update(&app, Input{y = true})
	v := current_view(&app)
	if !testing.expect(t, v != nil, "a menu") do return
	labels := make([dynamic]string, context.temp_allocator)
	for e in v.entries do append(&labels, e.label)
	testing.expectf(t, len(labels) == 4 && labels[0] == "Replace value" && labels[3] == WORDS_LABEL, "the menu: %v", labels[:])
	clear_nav(&app)
	app.state = .Editor
	if app.slot_menu != nil { free_entries(app.slot_menu); app.slot_menu = nil }

	if !enter(t, &app) do return
	testing.expect_value(t, app.word_stop, 1) // on "hello"
	update(&app, Input{right = true})
	w, d := word_edit_on(&app)
	testing.expect(t, w < 0 && d == 1, "the dot between hello and brave")
	for _ in 0 ..< 10 do update(&app, Input{right = true})
	testing.expect_value(t, app.word_stop, 6) // the dot after "world"
	update(&app, Input{x = true}) // a plain X does nothing in here
	testing.expect(t, app.word_edit_active && app.state == .Editor, "still word by word")
	update(&app, Input{cancel = true})
	testing.expect(t, !app.word_edit_active && app.state == .Editor, "B leaves word by word, not the editor")
	testing.expect_value(t, text(&app), "hello brave world")
}

// A yellow dot: Insert > General > %v (spaced), Escapes > \n (stuck to the word).
@(test)
test_word_edit_insert_specials :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	if !enter(t, &app) do return
	update(&app, Input{right = true}) // the dot after "hello"
	update(&app, Input{confirm = true})
	if pick(t, &app, "General") do pick(t, &app, "%v")
	testing.expect_value(t, text(&app), "hello %v brave world")
	w, _ := word_edit_on(&app)
	testing.expect_value(t, w, 1) // on the new %v
	testing.expect(t, app.word_edit_active && app.state == .Editor, "back word by word")

	for _ in 0 ..< 10 do update(&app, Input{right = true}) // the end dot
	update(&app, Input{rt_held = true, x = true})            // RT+X on a dot: Insert too
	if pick(t, &app, "Escapes") do pick(t, &app, `\n`)
	testing.expect_value(t, text(&app), `hello %v brave world\n`)

	update(&app, Input{left = true}) // from the new \n: the dot between "world" and it
	update(&app, Input{confirm = true})
	if pick(t, &app, "Symbols") do pick(t, &app, "!")
	testing.expect_value(t, text(&app), `hello %v brave world!\n`)
	testing.expect(t, strings.contains(file_text(&app, context.temp_allocator), `fmt.println("hello %v brave world!\n")`), "saved")

	// B in the menu: back word by word, nothing changed.
	update(&app, Input{confirm = true})
	update(&app, Input{cancel = true})
	testing.expect(t, app.word_edit_active && app.state == .Editor, "B in the menu: still word by word")
}

// A word: RT+B deletes it; A > Change word > UPPER / `backticks` / Replace with.
@(test)
test_word_edit_change_and_delete :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	if !enter(t, &app) do return
	update(&app, Input{right = true})
	update(&app, Input{right = true}) // "brave"
	update(&app, Input{rt_held = true, cancel = true})
	testing.expect_value(t, text(&app), "hello world")
	w, _ := word_edit_on(&app)
	testing.expect_value(t, w, 1) // on "world" now
	testing.expect(t, app.word_edit_active, "RT+B doesn't leave")

	update(&app, Input{confirm = true})
	pick(t, &app, "UPPER")
	testing.expect_value(t, text(&app), "hello WORLD")
	update(&app, Input{rt_held = true, x = true})
	pick(t, &app, "`backticks`")
	testing.expect_value(t, text(&app), "hello `WORLD`")
	update(&app, Input{left = true})
	update(&app, Input{left = true}) // "hello"
	update(&app, Input{confirm = true})
	if pick(t, &app, "Replace with") && pick(t, &app, "Integer") do pick(t, &app, "%d")
	testing.expect_value(t, text(&app), "%d `WORLD`")

	// The last words: down to an empty string, then insert into it.
	update(&app, Input{rt_held = true, cancel = true})
	update(&app, Input{rt_held = true, cancel = true})
	testing.expect_value(t, text(&app), "")
	testing.expect_value(t, app.word_stop, 0)
	word_dictated(&app, "brand new")
	testing.expect_value(t, text(&app), "brand new")
}

// Y on a string argument > Replace value: the old refill (a dot and its menu).
@(test)
test_word_edit_replace_value :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	ni, fi := string_field(&app)
	focus_field_index(&app, ni, fi)
	update(&app, Input{y = true})
	pick(t, &app, "Replace value")
	testing.expect(t, app.refill_active && app.state == .Radial, "the fill menu for the argument")
	update(&app, Input{cancel = true})
	testing.expect_value(t, text(&app), "hello brave world")
}

// A comment's text: Y > Edit word by word; its Insert menu is just Symbols.
@(test)
test_word_edit_comment :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\n// fix the thing\nmain :: proc() {\n}\n")
	ci, cf := -1, -1
	for n, i in app.doc.nodes do for f, k in n.fields do if f.kind == COMMENT_KIND { ci, cf = i, k }
	if !testing.expect(t, ci >= 0, "a comment") do return
	focus_field_index(&app, ci, cf)
	update(&app, Input{y = true})
	if !pick(t, &app, WORDS_LABEL) do return
	update(&app, Input{right = true}) // the dot after "fix"
	update(&app, Input{confirm = true})
	v := current_view(&app)
	testing.expect(t, v != nil && len(v.entries) == 1 && v.entries[0].label == "Symbols", "comments: symbols only")
	pick(t, &app, "Symbols")
	pick(t, &app, ":")
	testing.expect_value(t, app.doc.nodes[ci].fields[cf].text, "fix: the thing")
}

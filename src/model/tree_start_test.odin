package model

// Where an RT + d-pad walk starts (selection.odin tree_ensure): at the
// cursor's own line - not the whole procedure - with the constructs around it
// one RT+Left each away; and where the last walk left off while the cursor
// stays put.

import "core:strings"
import "core:testing"

@(private = "file")
cleanup :: proc(app: ^App) {
	clear_nav(app)
	delete(app.nav)
	doc_reset(app)
	delete(app.doc.nodes)
	delete(app.recent_imports)
	delete(app.tree_path)
	free_menus(app)
}

LOOP_SRC :: "package main\n\nmain :: proc() {\n\tsetup()\n\tfor i in 0 ..< 3 {\n\t\ta := i\n\t\tb := a\n\t\tc := b\n\t}\n\tdone()\n}\n"

@(private = "file")
cursor_on :: proc(app: ^App, text: string) -> int {
	for n, i in app.doc.nodes do if strings.trim_space(node_text(n, context.temp_allocator)) == text {
		app.editor_line = i
		app.editor_dot = false
		app.editor_field = 0
		return i
	}
	return -1
}

@(private = "file")
selected :: proc(app: ^App) -> string {
	s, ok := tree_selection(app)
	if !ok do return ""
	return strings.trim_space(node_text(app.doc.nodes[s.ni], context.temp_allocator))
}

@(private = "file") rt :: proc(app: ^App, inp: Input) { i := inp; i.rt_held = true; update(app, i) }

@(test)
test_walk_starts_at_the_cursor_line :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, LOOP_SRC)
	b := cursor_on(&app, "b := a")
	testing.expect_value(t, selected(&app), "b := a") // not `main :: proc() {`

	rt(&app, Input{down = true}) // the next statement in the loop
	testing.expect_value(t, selected(&app), "c := b")
	testing.expect_value(t, app.editor_line, b + 1) // the cursor follows; no jump to the top
	rt(&app, Input{up = true}); rt(&app, Input{up = true})
	testing.expect_value(t, selected(&app), "a := i")

	rt(&app, Input{left = true}) // out: the loop
	s, _ := tree_selection(&app)
	testing.expect(t, s.kind == .Block && selected(&app) == "for i in 0 ..< 3 {", "Left widens to the loop")
	rt(&app, Input{left = true}) // out: the procedure
	testing.expect_value(t, selected(&app), "main :: proc() {")

	// Released and pressed again without moving the cursor: carries on from there.
	update(&app, Input{})
	rt(&app, Input{right = true}) // into main: its header line
	rt(&app, Input{down = true})
	testing.expect_value(t, selected(&app), "setup()")
}

@(test)
test_walk_start_on_a_block_line :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, LOOP_SRC)
	cursor_on(&app, "for i in 0 ..< 3 {")
	s, _ := tree_selection(&app)
	testing.expect(t, s.kind == .Block && s.end_ni > s.ni, "a line that opens a block: that block")
	rt(&app, Input{down = true})
	testing.expect_value(t, selected(&app), "done()")

	cursor_on(&app, "done()") // move away, then onto the loop's closing brace
	for n, i in app.doc.nodes do if strings.trim_space(node_text(n, context.temp_allocator)) == "}" && i < len(app.doc.nodes) - 2 {
		app.editor_line = i
		break
	}
	testing.expect_value(t, selected(&app), "for i in 0 ..< 3 {") // the block around a `}`
}

// Grab without walking first lifts the statement on the cursor's line.
@(test)
test_grab_starts_at_the_cursor_line :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, LOOP_SRC)
	b := cursor_on(&app, "b := a")
	rt(&app, Input{x = true})
	update(&app, Input{confirm = true}) // Refactor > Grab
	ni, end, ok := grab_lines(&app)
	testing.expect(t, ok && ni == b && end == b, "the current statement is lifted, not main")
	update(&app, Input{cancel = true})
}

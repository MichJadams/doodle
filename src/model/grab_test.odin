package model

// Grab (grab.odin), driven by the buttons: RT + d-pad picks, RT+X lifts / drops,
// d-pad slides, B puts it back.

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

@(private = "file")
load :: proc(app: ^App, src: string) {
	app.state = .Editor
	doc_from_source(app, src)
}

// The document as saved, minus the "package main\n\n" every test starts with.
@(private = "file")
body :: proc(app: ^App) -> string {
	return strings.trim_prefix(file_text(app, context.temp_allocator), "package main\n\n")
}

@(private = "file") rt     :: proc(app: ^App, b: string) { press(app, b, true) }
@(private = "file") plain  :: proc(app: ^App, b: string) { press(app, b, false) }
@(private = "file")
press :: proc(app: ^App, b: string, rt_held: bool) {
	inp := Input{rt_held = rt_held}
	switch b {
	case "up":    inp.up = true
	case "down":  inp.down = true
	case "left":  inp.left = true
	case "right": inp.right = true
	case "x":     inp.x = true
	case "b":     inp.cancel = true
	}
	update(app, inp)
	// RT+X opens Refactor: Grab is its first entry.
	if b == "x" && app.state == .Radial && current_view(app).title == "Refactor" do update(app, Input{confirm = true})
}

// The cursor on line `text`, then RT+Right (into its construct) - the walk
// starts from the construct around the cursor.
@(private = "file")
cursor_on :: proc(app: ^App, text: string) {
	for n, i in app.doc.nodes do if strings.contains(node_text(n, context.temp_allocator), text) {
		app.editor_line = i
		app.editor_dot = false
		app.editor_field = 0
		return
	}
}

SLIDE_SRC :: "package main\n\nmain :: proc() {\n\ta := 1\n\tb := 2\n\tc := 3\n}\n"

@(test)
test_grab_slide_and_drop :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, SLIDE_SRC)
	cursor_on(&app, "main ::")
	rt(&app, "right") // the header line
	rt(&app, "down")  // a := 1
	rt(&app, "down")  // b := 2
	rt(&app, "x")     // lift
	ni, end, ok := grab_lines(&app)
	testing.expect(t, ok && ni == end && strings.contains(node_text(app.doc.nodes[ni], context.temp_allocator), "b := 2"), "b is lifted")
	plain(&app, "down")
	testing.expect_value(t, body(&app), "main :: proc() {\n\ta := 1\n\tc := 3\n\tb := 2\n}\n")
	plain(&app, "down") // the bottom of the block: stays
	testing.expect_value(t, body(&app), "main :: proc() {\n\ta := 1\n\tc := 3\n\tb := 2\n}\n")
	rt(&app, "up") // RT + Up slides too
	rt(&app, "up")
	testing.expect_value(t, body(&app), "main :: proc() {\n\tb := 2\n\ta := 1\n\tc := 3\n}\n")
	plain(&app, "up") // not above the header
	testing.expect_value(t, body(&app), "main :: proc() {\n\tb := 2\n\ta := 1\n\tc := 3\n}\n")
	rt(&app, "x") // drop
	testing.expect(t, !app.grab_active, "dropped")
	s, sok := tree_selection(&app)
	testing.expect(t, sok && strings.contains(node_text(app.doc.nodes[s.ni], context.temp_allocator), "b := 2"), "the dropped statement stays selected")
}

@(test)
test_grab_cancel_puts_it_back :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, SLIDE_SRC)
	cursor_on(&app, "main ::")
	rt(&app, "right"); rt(&app, "down"); rt(&app, "down"); rt(&app, "down") // c := 3
	rt(&app, "x")
	plain(&app, "up"); plain(&app, "up")
	testing.expect_value(t, body(&app), "main :: proc() {\n\tc := 3\n\ta := 1\n\tb := 2\n}\n")
	// While lifted, other buttons do nothing (LT+B would delete).
	update(&app, Input{lt_held = true, cancel = true})
	testing.expect(t, app.grab_active, "still lifted")
	testing.expect_value(t, body(&app), "main :: proc() {\n\tc := 3\n\ta := 1\n\tb := 2\n}\n")
	plain(&app, "b") // put it back
	testing.expect(t, !app.grab_active, "put back")
	testing.expect_value(t, body(&app), "main :: proc() {\n\ta := 1\n\tb := 2\n\tc := 3\n}\n")
}

IF_SRC :: "package main\n\nmain :: proc() {\n\tx := 0\n\tif x > 0 {\n\t\tx = 1\n\t}\n\ty := 2\n}\n"

// Up / Down step into a block and back out (re-indented); a part of a line
// lifts its statement; B undoes it all exactly.
@(test)
test_grab_into_and_out_of_a_block :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, IF_SRC)
	cursor_on(&app, "main ::")
	rt(&app, "right"); rt(&app, "down"); rt(&app, "down"); rt(&app, "down") // y := 2
	rt(&app, "right") // a part of it: grabbing lifts the whole statement
	rt(&app, "x")
	ni, end, ok := grab_lines(&app)
	testing.expect(t, ok && ni == end && strings.contains(node_text(app.doc.nodes[ni], context.temp_allocator), "y := 2"), "the statement is lifted")
	plain(&app, "up") // into the if, just above its }
	testing.expect_value(t, body(&app), "main :: proc() {\n\tx := 0\n\tif x > 0 {\n\t\tx = 1\n\t\ty := 2\n\t}\n}\n")
	plain(&app, "up") // past x = 1
	testing.expect_value(t, body(&app), "main :: proc() {\n\tx := 0\n\tif x > 0 {\n\t\ty := 2\n\t\tx = 1\n\t}\n}\n")
	plain(&app, "up") // out, above the if
	testing.expect_value(t, body(&app), "main :: proc() {\n\tx := 0\n\ty := 2\n\tif x > 0 {\n\t\tx = 1\n\t}\n}\n")
	plain(&app, "down") // back in, just under the header
	testing.expect_value(t, body(&app), "main :: proc() {\n\tx := 0\n\tif x > 0 {\n\t\ty := 2\n\t\tx = 1\n\t}\n}\n")
	plain(&app, "b") // put back exactly
	testing.expect(t, !app.grab_active, "put back")
	testing.expect_value(t, body(&app), strings.trim_prefix(IF_SRC, "package main\n\n"))
}

// RT + Up / Down jump past a whole block (the old way); the if block itself
// moves as one piece.
@(test)
test_grab_jump_past_a_block :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, IF_SRC)
	cursor_on(&app, "main ::")
	rt(&app, "right"); rt(&app, "down"); rt(&app, "down"); rt(&app, "down") // y := 2
	rt(&app, "x")
	rt(&app, "up")
	testing.expect_value(t, body(&app), "main :: proc() {\n\tx := 0\n\ty := 2\n\tif x > 0 {\n\t\tx = 1\n\t}\n}\n")
	rt(&app, "x")
	cursor_on(&app, "main ::")
	rt(&app, "right"); rt(&app, "down"); rt(&app, "down"); rt(&app, "down") // the if block
	rt(&app, "x")
	ni, end, ok := grab_lines(&app)
	testing.expect(t, ok && end == ni + 2, "the whole if block is lifted")
	rt(&app, "up")
	testing.expect_value(t, body(&app), "main :: proc() {\n\tx := 0\n\tif x > 0 {\n\t\tx = 1\n\t}\n\ty := 2\n}\n")
	rt(&app, "x")
}

// A for loop and a declaration moved into another for loop (and the inner
// loop's body re-indented with it); not out of the procedure.
@(test)
test_grab_into_a_for_loop :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tfor i in 0 ..< 3 {\n\t\tdo_it(i)\n\t}\n\tfor j in 0 ..< 2 {\n\t\tdo_it(j)\n\t}\n\tn := 5\n}\n")
	cursor_on(&app, "main ::")
	rt(&app, "right"); rt(&app, "down"); rt(&app, "down") // the second for loop
	rt(&app, "x")
	plain(&app, "up") // into the first loop, above its }
	testing.expect_value(t, body(&app), "main :: proc() {\n\tfor i in 0 ..< 3 {\n\t\tdo_it(i)\n\t\tfor j in 0 ..< 2 {\n\t\t\tdo_it(j)\n\t\t}\n\t}\n\tn := 5\n}\n")
	rt(&app, "x") // drop
	cursor_on(&app, "main ::")
	rt(&app, "right"); rt(&app, "down"); rt(&app, "down") // n := 5
	rt(&app, "x")
	plain(&app, "up") // into the outer loop, above its }
	plain(&app, "up") // into the inner loop, above its }
	testing.expect_value(t, body(&app), "main :: proc() {\n\tfor i in 0 ..< 3 {\n\t\tdo_it(i)\n\t\tfor j in 0 ..< 2 {\n\t\t\tdo_it(j)\n\t\t\tn := 5\n\t\t}\n\t}\n}\n")
	rt(&app, "x")
	// Up to the top of main, then no further: it never leaves the procedure.
	cursor_on(&app, "main ::")
	rt(&app, "right"); rt(&app, "down") // the outer loop
	rt(&app, "x")
	plain(&app, "up")
	testing.expect(t, strings.has_prefix(body(&app), "main :: proc() {\n\tfor i in"), "still inside main")
	plain(&app, "down"); plain(&app, "down")
	testing.expect(t, strings.has_suffix(body(&app), "\t}\n}\n"), "still inside main at the bottom too")
	rt(&app, "x")
}

// Top level: procedures swap, the blank line between them stays, nothing goes
// above `package`.
@(test)
test_grab_top_level :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nfirst :: proc() {\n}\n\nsecond :: proc() {\n}\n")
	cursor_on(&app, "second ::")
	rt(&app, "x") // the construct around the cursor: the second procedure
	ni, end, ok := grab_lines(&app)
	testing.expect(t, ok && end == ni + 1, "the procedure is lifted")
	plain(&app, "up")
	testing.expect_value(t, body(&app), "second :: proc() {\n}\n\nfirst :: proc() {\n}\n")
	plain(&app, "up") // the package line stays first
	testing.expect_value(t, file_text(&app, context.temp_allocator), "package main\n\nsecond :: proc() {\n}\n\nfirst :: proc() {\n}\n")
	rt(&app, "x")
	// The package line itself can't be lifted.
	cursor_on(&app, "package main")
	rt(&app, "x")
	testing.expect(t, !app.grab_active, "package isn't lifted")
}

// Dropping: X without RT (the HUD shows G only while RT is held) or A drop it,
// as well as RT+X.
@(test)
test_grab_drop_with_x_or_a :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, SLIDE_SRC)
	cursor_on(&app, "main ::")
	rt(&app, "right"); rt(&app, "down"); rt(&app, "down") // b := 2
	rt(&app, "x")
	plain(&app, "down")
	plain(&app, "x") // plain X: drop
	testing.expect(t, !app.grab_active, "plain X drops")
	testing.expect_value(t, body(&app), "main :: proc() {\n\ta := 1\n\tc := 3\n\tb := 2\n}\n")

	cursor_on(&app, "main ::")
	rt(&app, "right"); rt(&app, "down") // a := 1
	rt(&app, "x")
	plain(&app, "down")
	update(&app, Input{confirm = true}) // A: drop
	testing.expect(t, !app.grab_active, "A drops")
	testing.expect_value(t, body(&app), "main :: proc() {\n\tc := 3\n\ta := 1\n\tb := 2\n}\n")
}

// ---- Refactor > Copy line ----

// The document's lines as they are (file_text would format them mid-move),
// minus "package main" and the blank line after it.
@(private = "file")
lines :: proc(app: ^App) -> string {
	b := strings.builder_make(context.temp_allocator)
	for n, i in app.doc.nodes do if i >= 2 {
		strings.write_string(&b, node_text(n, context.temp_allocator))
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

COPY_SRC :: "package main\n\nmain :: proc() {\n\ta := 1\n\tb := 2\n}\n\nother :: proc() {\n\tc := 3\n}\n"

// RT+X opens Refactor (Grab / Copy line); B closes it without lifting.
@(test)
test_refactor_menu :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, COPY_SRC)
	cursor_on(&app, "a := 1")
	update(&app, Input{rt_held = true, x = true})
	v := current_view(&app)
	if !testing.expect(t, v != nil && v.title == "Refactor" && len(v.entries) == 2, "the Refactor menu") do return
	testing.expect(t, v.entries[0].label == "Grab" && v.entries[1].label == "Copy line", "Grab, Copy line")
	update(&app, Input{cancel = true})
	_, _, lifted := grab_lines(&app)
	testing.expect(t, app.state == .Editor && !lifted, "B: nothing lifted")
	testing.expect_value(t, lines(&app), strings.trim_prefix(COPY_SRC, "package main\n\n"))
}

@(private = "file")
copy_line :: proc(app: ^App, text: string) {
	cursor_on(app, text)
	update(app, Input{rt_held = true, x = true})
	v := current_view(app)
	if v == nil do return
	v.index = 1 // Copy line
	update(app, Input{confirm = true})
}

// The copy moves, the original stays; it goes out of main, past the gap and
// into other (red between them: no drop there), then drops.
@(test)
test_copy_line_into_another_procedure :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, COPY_SRC)
	copy_line(&app, "a := 1")
	ni, end, ok := grab_lines(&app)
	testing.expect(t, ok && ni == end && app.grab_copy, "a copy is lifted")
	testing.expect_value(t, lines(&app), "main :: proc() {\n\ta := 1\n\ta := 1\n\tb := 2\n}\n\nother :: proc() {\n\tc := 3\n}\n")
	plain(&app, "down") // past b
	plain(&app, "down") // out of main
	testing.expect_value(t, lines(&app), "main :: proc() {\n\ta := 1\n\tb := 2\n}\na := 1\n\nother :: proc() {\n\tc := 3\n}\n")
	testing.expect(t, grab_blocked(&app), "between procedures: red")
	rt(&app, "x") // can't drop here
	_, _, still := grab_lines(&app)
	testing.expect(t, still && app.notice != "", "still lifted, with a notice")
	plain(&app, "down") // into other, under its header
	testing.expect_value(t, lines(&app), "main :: proc() {\n\ta := 1\n\tb := 2\n}\n\nother :: proc() {\n\ta := 1\n\tc := 3\n}\n")
	testing.expect(t, !grab_blocked(&app), "inside other: fine")
	plain(&app, "x") // drop
	_, _, after := grab_lines(&app)
	testing.expect(t, !after, "dropped")
	testing.expect_value(t, lines(&app), "main :: proc() {\n\ta := 1\n\tb := 2\n}\n\nother :: proc() {\n\ta := 1\n\tc := 3\n}\n")

	// Up from the bottom of other, back into main just above its `}`.
	copy_line(&app, "c := 3")
	for _ in 0 ..< 4 do plain(&app, "up") // past a, out of other, into main above its `}`
	testing.expect(t, !grab_blocked(&app), "inside a procedure")
	plain(&app, "x")
	testing.expect_value(t, lines(&app), "main :: proc() {\n\ta := 1\n\tb := 2\n\tc := 3\n}\n\nother :: proc() {\n\ta := 1\n\tc := 3\n}\n")
}

// B: the copy goes away wherever it is, the document as it was.
@(test)
test_copy_line_cancel :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, COPY_SRC)
	copy_line(&app, "b := 2")
	plain(&app, "down")
	plain(&app, "down")
	plain(&app, "b")
	_, _, lifted := grab_lines(&app)
	testing.expect(t, !lifted, "nothing lifted")
	testing.expect_value(t, lines(&app), strings.trim_prefix(COPY_SRC, "package main\n\n"))
}

// A top-level construct: the copy only moves among top-level constructs.
@(test)
test_copy_line_top_level :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, COPY_SRC)
	cursor_on(&app, "other ::")
	copy_line(&app, "other ::")
	ni, end, ok := grab_lines(&app)
	testing.expect(t, ok && end == ni + 2, "the whole procedure is copied")
	plain(&app, "up")
	testing.expect(t, !grab_blocked(&app), "top-level copies drop at the top level")
	plain(&app, "x")
	testing.expect_value(t, lines(&app), "main :: proc() {\n\ta := 1\n\tb := 2\n}\n\nother :: proc() {\n\tc := 3\n}\nother :: proc() {\n\tc := 3\n}\n")
}

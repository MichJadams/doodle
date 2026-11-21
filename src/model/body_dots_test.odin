package model

import "core:strings"
import "core:testing"

@(private = "file")
SRC :: "package main\n\nimport \"core:fmt\"\n\n" +
	"Player :: struct {\n" + // 4
	"\tname: string,\n" +    // 5
	"}\n\n" +                // 6, 7
	"main :: proc() {\n" +   // 8
	"\tfmt.println(1)\n" +   // 9
	"\tif true {\n" +        // 10
	"\t\tfmt.println(2)\n" + // 11
	"\t}\n" +                // 12
	"\tfmt.println(3)\n" +   // 13
	"}"                      // 14

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
pick :: proc(app: ^App, label: string) -> bool {
	v := current_view(app)
	if v == nil do return false
	for e, i in v.entries {
		if e.label == label {
			v.index = i
			update(app, Input{confirm = true})
			return true
		}
	}
	return false
}

@(test)
test_body_dots_positions :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	doc_from_source(&app, SRC)
	bp := body_points(&app)
	got := make([dynamic]int, context.temp_allocator)
	for b, i in bp do if b do append(&got, i)
	// Above/below the struct's field (5, 6: they offer members), above/between/below
	// main's statements (9, 10, 13, 14) and inside the if (11, 12); none at the top level.
	want := []int{5, 6, 9, 10, 11, 12, 13, 14}
	testing.expect_value(t, len(got), len(want))
	for w, k in want do if k < len(got) do testing.expect_value(t, got[k], w)
}

@(test)
test_body_dots_are_cursor_stops :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	focus_line(&app, 8) // main :: proc() {
	trail := make([dynamic]string, context.temp_allocator)
	for _ in 0 ..< 9 {
		update(&app, Input{down = true})
		append(&trail, on_dot(&app) ? strings.concatenate({"dot", itoa(app.editor_line)}, context.temp_allocator) : itoa(app.editor_line))
	}
	// (`if true {` is a stop: its `if` keyword (Y: else if / else, branch.odin) and
	// its condition can be changed; `}` lines aren't stops.)
	testing.expect_value(t, strings.join(trail[:], " ", context.temp_allocator),
		"dot9 9 dot10 10 dot11 11 dot12 dot13 13")
}

@(private = "file")
itoa :: proc(n: int) -> string {
	buf: [8]u8
	i := len(buf)
	v := n
	if v == 0 { i -= 1; buf[i] = '0' }
	for v > 0 { i -= 1; buf[i] = u8('0' + v % 10); v /= 10 }
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

@(test)
test_declare_variable_between_statements :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	n_before := len(app.doc.nodes)
	focus_dot_at(&app, 10) // between fmt.println(1) and the if
	update(&app, Input{confirm = true})
	testing.expect_value(t, app.state, State.Radial)
	testing.expect(t, pick(&app, "Declarations"))
	testing.expect(t, pick(&app, "Variable (:=)"))
	testing.expect_value(t, app.state, State.Editor)

	// Exactly one new line, at the dot, indented like its neighbours.
	testing.expect_value(t, len(app.doc.nodes), n_before + 1)
	line := node_text(app.doc.nodes[10], context.temp_allocator)
	testing.expectf(t, strings.has_prefix(line, "\t") && !strings.has_prefix(line, "\t\t") && strings.contains(line, " := "), "got %q", line)
	testing.expect_value(t, strings.trim_space(node_text(app.doc.nodes[11], context.temp_allocator)), "if true {")
	testing.expect(t, !is_body_slot_line(app.doc.nodes[11]), "no extra empty statement line")
}

@(test)
test_body_dot_inside_nested_block_and_cancel :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	before := doc_to_source(&app, context.temp_allocator)

	// Cancel: nothing changes.
	focus_dot_at(&app, 12) // below fmt.println(2), inside the if
	update(&app, Input{confirm = true})
	testing.expect_value(t, app.state, State.Radial)
	for app.state == .Radial do update(&app, Input{cancel = true})
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), before)
	testing.expect(t, on_dot(&app) && app.editor_line == 12, "back on the dot")

	// Insert a block statement there: indented two levels, no stray empty line after it.
	update(&app, Input{confirm = true})
	testing.expect(t, pick(&app, "Loops"))
	testing.expect(t, pick(&app, "For (infinite)"))
	testing.expectf(t, strings.has_prefix(node_text(app.doc.nodes[12], context.temp_allocator), "\t\tfor"), "got %q", node_text(app.doc.nodes[12], context.temp_allocator))
	e := 12
	for j in 12 ..< len(app.doc.nodes) do if strings.trim_space(node_text(app.doc.nodes[j], context.temp_allocator)) == "}" { e = j; break }
	testing.expect_value(t, strings.trim_space(node_text(app.doc.nodes[e + 1], context.temp_allocator)), "}") // the if's own }
}

// An empty function built with the menus shows one green dot (its "●" line);
// saved and loaded back (the "●" line saves as a blank line) it also shows one.
@(test)
test_empty_function_has_one_dot :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nmain :: proc() {\n\n}")
	count := 0
	for b in body_points(&app) do if b do count += 1
	testing.expect_value(t, count, 1)

	// Cancelling an insert there leaves the file exactly as it was...
	before := doc_to_source(&app, context.temp_allocator)
	focus_dot_at(&app, 3)
	update(&app, Input{confirm = true})
	testing.expect_value(t, app.state, State.Radial)
	for app.state == .Radial do update(&app, Input{cancel = true})
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), before)

	// ...and a statement takes the blank line's place (no stray empty line).
	update(&app, Input{confirm = true})
	testing.expect(t, pick(&app, "Declarations"))
	testing.expect(t, pick(&app, "Variable (:=)"))
	testing.expect_value(t, len(app.doc.nodes), 5) // package, blank, header, statement, }
	testing.expect(t, strings.contains(node_text(app.doc.nodes[3], context.temp_allocator), " := "))
	testing.expect_value(t, strings.trim_space(node_text(app.doc.nodes[4], context.temp_allocator)), "}")
}

// Blank spacing between statements: one dot for the gap.
@(test)
test_blank_lines_between_statements_get_one_dot :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	doc_from_source(&app, "package main\nimport \"core:fmt\"\nmain :: proc() {\n\tfmt.println(1)\n\n\n\tfmt.println(2)\n}")
	got := make([dynamic]int, context.temp_allocator)
	for b, i in body_points(&app) do if b do append(&got, i)
	// before println(1) (3), after it above the blanks (4), before println(2)
	// below the blanks (6), and before } (7) - none at 5 (between two blanks).
	testing.expect_value(t, len(got), 4)
	if len(got) == 4 do testing.expect(t, got[0] == 3 && got[1] == 4 && got[2] == 6 && got[3] == 7)
}

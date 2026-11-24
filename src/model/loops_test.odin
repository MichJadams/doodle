package model

// Loops (loops.odin, loop_parse.odin): every shape of `for` built from the
// statement menu the way the controller does it, the loop options (Y / LT+B),
// compound assignment, labeled break / continue, loop variables' types and
// scope, and loading / saving.

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
src :: proc(app: ^App) -> string { return doc_to_source(app, context.temp_allocator) }

@(private = "file")
line_src :: proc(app: ^App, ni: int) -> string {
	if ni < 0 || ni >= len(app.doc.nodes) do return "<no line>"
	return strings.trim_space(node_source(app.doc.nodes[ni], context.temp_allocator))
}

@(private = "file")
line_with :: proc(app: ^App, text: string, from := 0) -> int {
	for i in from ..< len(app.doc.nodes) do if strings.contains(node_text(app.doc.nodes[i], context.temp_allocator), text) do return i
	return -1
}

@(private = "file")
labels :: proc(app: ^App) -> string {
	v := current_view(app)
	if v == nil do return "<no menu>"
	out := make([dynamic]string, context.temp_allocator)
	for e in v.entries do append(&out, e.label)
	return strings.join(out[:], " | ", context.temp_allocator)
}

@(private = "file")
pick :: proc(t: ^testing.T, app: ^App, label: string, loc := #caller_location) -> bool {
	v := current_view(app)
	if v == nil || app.state != .Radial {
		testing.expectf(t, false, "no menu open (wanted %q)", label, loc = loc)
		return false
	}
	for e, i in v.entries {
		if e.label == label {
			v.index = i
			update(app, Input{confirm = true})
			return true
		}
	}
	testing.expectf(t, false, "no %q in menu %q: %s", label, v.title, labels(app), loc = loc)
	return false
}

@(private = "file")
find :: proc(entries: []Entry, label: string) -> (Entry, bool) {
	for e in entries {
		if e.label == label do return e, true
		if r, ok := find(e.children, label); ok do return r, true
	}
	return {}, false
}

@(private = "file")
has_entry :: proc(app: ^App, label: string) -> bool {
	v := current_view(app)
	if v == nil do return false
	_, ok := find(v.entries, label)
	return ok
}

@(private = "file")
dimmed :: proc(t: ^testing.T, app: ^App, label: string, loc := #caller_location) -> bool {
	v := current_view(app)
	if !testing.expectf(t, v != nil, "no menu open (wanted %q)", label, loc = loc) do return false
	e, ok := find(v.entries, label)
	testing.expectf(t, ok, "menu entry %q should exist: %s", label, labels(app), loc = loc)
	return e.dim
}

@(private = "file")
back_out :: proc(app: ^App) {
	for _ in 0 ..< 16 {
		if app.state == .Editor && !app.ref_pick_active do return
		update(app, Input{cancel = true})
	}
}

// A on the green dot before line `at` (inside a function), then group -> leaf.
@(private = "file")
add_stmt :: proc(t: ^testing.T, app: ^App, at: int, group, leaf: string, loc := #caller_location) -> int {
	back_out(app)
	focus_dot_at(app, at)
	update(app, Input{confirm = true})
	if pick(t, app, group, loc) do pick(t, app, leaf, loc)
	return at
}

// A on a "●" statement line, then group -> leaf.
@(private = "file")
add_in_body :: proc(t: ^testing.T, app: ^App, ni: int, group, leaf: string, loc := #caller_location) -> int {
	back_out(app)
	if !testing.expectf(t, ni >= 0 && is_body_slot_line(app.doc.nodes[ni]), "no statement line at %d", ni, loc = loc) do return -1
	focus_field_index(app, ni, 1)
	update(app, Input{confirm = true})
	if pick(t, app, group, loc) do pick(t, app, leaf, loc)
	return ni
}

// The first "●" statement line after `from`.
@(private = "file")
body_line :: proc(app: ^App, from: int) -> int {
	for i in from ..< len(app.doc.nodes) do if is_body_slot_line(app.doc.nodes[i]) do return i
	return -1
}

// A on the nth value dot of line ni.
@(private = "file")
open_dot :: proc(t: ^testing.T, app: ^App, ni, nth: int, loc := #caller_location) -> bool {
	back_out(app)
	seen := 0
	for f, i in app.doc.nodes[ni].fields {
		if f.slot && f.kind == "value" {
			if seen == nth {
				focus_field_index(app, ni, i)
				update(app, Input{confirm = true})
				return true
			}
			seen += 1
		}
	}
	testing.expectf(t, false, "no value dot #%d on %q", nth, line_src(app, ni), loc = loc)
	return false
}

@(private = "file")
cursor_text :: proc(app: ^App) -> string {
	ni, fi, ok := editor_target(app)
	if !ok do return "<none>"
	return app.doc.nodes[ni].fields[fi].text
}

// In Reference pick mode: D-pad until `name` is highlighted, then A.
@(private = "file")
ref_choose :: proc(t: ^testing.T, app: ^App, name: string, loc := #caller_location) -> bool {
	if !testing.expect(t, app.ref_pick_active, "in pick mode", loc = loc) do return false
	for _ in 0 ..< 64 {
		if cursor_text(app) == name do break
		update(app, Input{right = true})
	}
	if !testing.expectf(t, cursor_text(app) == name, "%q should be pickable", name, loc = loc) do return false
	update(app, Input{confirm = true})
	return true
}

@(private = "file")
fill_ref :: proc(t: ^testing.T, app: ^App, ni: int, name: string, pass_as := "", loc := #caller_location) {
	if !open_dot(t, app, ni, 0, loc) || !pick(t, app, "Reference", loc) do return
	if ref_choose(t, app, name, loc) && app.state == .Radial do pick(t, app, pass_as == "" ? name : pass_as, loc)
}

@(private = "file")
fill_number :: proc(t: ^testing.T, app: ^App, ni: int, text: string, loc := #caller_location) {
	if !open_dot(t, app, ni, 0, loc) || !pick(t, app, "Number", loc) do return
	eni, efi, ok := editor_target(app)
	if testing.expect(t, ok && app.doc.nodes[eni].fields[efi].text == "0", "on the number", loc = loc) do set_field_text(app, eni, efi, text)
}

@(private = "file")
focus_text :: proc(app: ^App, ni: int, text: string, nth := 0) -> bool {
	seen := 0
	for f, i in app.doc.nodes[ni].fields {
		if f.text == text && !f.slot {
			if seen == nth { focus_field_index(app, ni, i); return true }
			seen += 1
		}
	}
	return false
}

@(private = "file")
rename :: proc(app: ^App, ni: int, from, to: string) {
	for f, i in app.doc.nodes[ni].fields do if f.editable && f.text == from { set_field_text(app, ni, i, to); return }
}

// LT+B on every leftover "●" statement line.
@(private = "file")
drop_body_lines :: proc(app: ^App) {
	back_out(app)
	for _ in 0 ..< 64 {
		b := body_line(app, 0)
		if b < 0 do return
		focus_field_index(app, b, 1)
		delete_selected(app)
	}
}

@(private = "file")
BASE :: "package main\n\nItem :: struct {\n\thp: int,\n}\n\nmain :: proc() {\n\titems: [dynamic]Item\n\tnames: []string\n\tages: map[string]int\n\ttext := \"hello\"\n\tcount := 3\n\tgrid: [4]f32\n}\n"

@(private = "file")
load :: proc(app: ^App, s: string) {
	app.state = .Editor
	doc_from_source(app, s)
}

// The program every form below builds (checked with `odin check` too).
@(private = "file")
BUILT :: "package main\n\n" +
	"Item :: struct {\n\thp: int,\n}\n\n" +
	"main :: proc() {\n" +
	"\titems: [dynamic]Item\n" +
	"\tnames: []string\n" +
	"\tages: map[string]int\n" +
	"\ttext := \"hello\"\n" +
	"\tcount := 3\n" +
	"\tgrid: [4]f32\n" +
	"\tfor i := 0; i < 10; i += 1 {\n" +
	"\t}\n" +
	"\tfor count < 10 {\n" +
	"\t\tcount += 1\n" +
	"\t}\n" +
	"\tfor {\n" +
	"\t\tbreak\n" +
	"\t}\n" +
	"\tfor i in 0..<10 {\n" +
	"\t}\n" +
	"\tfor i in 0..=9 {\n" +
	"\t}\n" +
	"\tfor item, index in items {\n" +
	"\t}\n" +
	"\tfor key, value in ages {\n" +
	"\t}\n" +
	"\tfor ch, i in text {\n" +
	"\t}\n" +
	"\tfor &item in items {\n" +
	"\t\titem.hp -= 1\n" +
	"\t}\n" +
	"\t#reverse for name in names {\n" +
	"\t}\n" +
	"\t#unroll for i in 0..<4 {\n" +
	"\t}\n" +
	"\touter: for item in items {\n" +
	"\t\tfor i in 0..<3 {\n" +
	"\t\t\tbreak outer\n" +
	"\t\t}\n" +
	"\t}\n" +
	"}"

@(test)
test_loops_build_every_form :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, BASE)
	end := line_with(&app, "grid:") + 1 // the dot before main's `}`

	// for i := 0; i < 10; i += 1 {
	ni := add_stmt(t, &app, end, "Loops", "For (C-style)")
	testing.expect_value(t, line_src(&app, ni), "for i := 0; i < ; i += 1 {")
	fill_number(t, &app, ni, "10")
	testing.expect_value(t, line_src(&app, ni), "for i := 0; i < 10; i += 1 {")

	// for count < 10 { count += 1 }
	ni = add_stmt(t, &app, ni + 3, "Loops", "For (condition)")
	if open_dot(t, &app, ni, 0) {
		testing.expect(t, dimmed(t, &app, "Number"), "a number isn't a condition")
		if pick(t, &app, "Operator") && pick(t, &app, "Compare") do pick(t, &app, "a < b")
	}
	fill_ref(t, &app, ni, "count")
	fill_number(t, &app, ni, "10")
	testing.expect_value(t, line_src(&app, ni), "for count < 10 {")
	a := add_in_body(t, &app, ni + 1, "Assignment", "+=") // the target pick opens at once
	if ref_choose(t, &app, "count") do pick(t, &app, "count")
	fill_number(t, &app, a, "1")
	testing.expect_value(t, line_src(&app, a), "count += 1")
	testing.expect(t, focus_text(&app, a, " += "), "the operator is a part")

	// for { break }
	ni = add_stmt(t, &app, a + 3, "Loops", "For (infinite)")
	focus_field_index(&app, ni + 1, 1)
	update(&app, Input{confirm = true})
	if pick(t, &app, "Jumps and cleanup") {
		testing.expect(t, !dimmed(t, &app, "Break"), "break fits in a loop")
		pick(t, &app, "Break")
	}
	testing.expect_value(t, line_src(&app, ni + 1), "break")

	// for i in 0..<10 {   for i in 0..=9 {
	ni = add_stmt(t, &app, ni + 4, "Loops", "For i in 0..<n")
	testing.expect_value(t, line_src(&app, ni), "for i in 0..< {")
	fill_number(t, &app, ni, "10")
	ni = add_stmt(t, &app, ni + 3, "Loops", "For i in 0..=n")
	fill_number(t, &app, ni, "9")
	testing.expect_value(t, line_src(&app, ni), "for i in 0..=9 {")

	// for item, index in items {
	ni = add_stmt(t, &app, ni + 3, "Loops", "For x, i in")
	if open_dot(t, &app, ni, 0) {
		testing.expect(t, has_entry(&app, "Range"), "an iterable can be a range")
		testing.expect(t, dimmed(t, &app, "Number"), "a number can't be iterated")
		testing.expect(t, dimmed(t, &app, "true"), "a bool can't be iterated")
		testing.expect(t, !dimmed(t, &app, "Reference"), "a name can be")
		back_out(&app)
	}
	fill_ref(t, &app, ni, "items")
	testing.expect_value(t, line_src(&app, ni), "for item, index in items {")

	// for key, value in ages {   (names are dictated: LT+A)
	ni = add_stmt(t, &app, ni + 3, "Loops", "For x, i in")
	fill_ref(t, &app, ni, "ages")
	rename(&app, ni, "item", "key")
	rename(&app, ni, "index", "value")
	testing.expect_value(t, line_src(&app, ni), "for key, value in ages {")

	// for ch, i in text {   (For ... in, then Y on `for` -> Add 2nd variable)
	ni = add_stmt(t, &app, ni + 3, "Loops", "For ... in")
	fill_ref(t, &app, ni, "text")
	focus_text(&app, ni, "for")
	change_selected(&app)
	if testing.expect(t, app.state == .Radial, "loop options") {
		testing.expect(t, dimmed(t, &app, "By reference"), "a string's characters can't be changed in place")
		testing.expect(t, !dimmed(t, &app, "Add #reverse"), "a string can be walked backwards")
		pick(t, &app, "Add 2nd variable")
	}
	rename(&app, ni, "item", "ch")
	rename(&app, ni, "index", "i")
	testing.expect_value(t, line_src(&app, ni), "for ch, i in text {")

	// for &item in items { item.hp -= 1 }
	ni = add_stmt(t, &app, ni + 3, "Loops", "For &x in")
	fill_ref(t, &app, ni, "items")
	testing.expect_value(t, line_src(&app, ni), "for &item in items {")
	a = add_in_body(t, &app, ni + 1, "Assignment", "-=") // the target pick opens at once
	if ref_choose(t, &app, "item") && pick(t, &app, "Field of item") do pick(t, &app, "hp   int")
	fill_number(t, &app, a, "1")
	testing.expect_value(t, line_src(&app, a), "item.hp -= 1")

	// #reverse for name in names {
	ni = add_stmt(t, &app, a + 3, "Loops", "#reverse for")
	fill_ref(t, &app, ni, "names")
	rename(&app, ni, "item", "name")
	testing.expect_value(t, line_src(&app, ni), "#reverse for name in names {")

	// #unroll for i in 0..<4 {
	ni = add_stmt(t, &app, ni + 3, "Loops", "#unroll for")
	fill_number(t, &app, ni, "4")
	testing.expect_value(t, line_src(&app, ni), "#unroll for i in 0..<4 {")

	// outer: for item in items { for i in 0..<3 { break outer } }
	ni = add_stmt(t, &app, ni + 3, "Loops", "Labeled for")
	fill_ref(t, &app, ni, "items")
	testing.expect_value(t, line_src(&app, ni), "outer: for item in items {")
	inner := add_in_body(t, &app, ni + 1, "Loops", "For i in 0..<n")
	fill_number(t, &app, inner, "3")
	focus_field_index(&app, inner + 1, 1)
	update(&app, Input{confirm = true})
	if pick(t, &app, "Jumps and cleanup") {
		testing.expect(t, !dimmed(t, &app, "Continue"), "continue fits in a loop")
		testing.expect(t, has_entry(&app, "Continue outer"), "continue outer: a loop label in scope")
		pick(t, &app, "Break outer")
	}
	testing.expect_value(t, line_src(&app, inner + 1), "break outer")

	drop_body_lines(&app)
	format_doc(&app)
	testing.expect_value(t, src(&app), BUILT)

	// Loading it back changes nothing; every header is a structured loop.
	text := strings.clone(src(&app), context.temp_allocator)
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	format_doc(&app)
	testing.expect_value(t, src(&app), text)
	headers := 0
	for n in app.doc.nodes do if _, ok := loop_hdr(n); ok do headers += 1
	testing.expect_value(t, headers, 13)
}

// Hand-written loops load into the same structure and save unchanged.
@(private = "file")
HAND :: "package main\n\n" +
	"main :: proc() {\n" +
	"\tm: map[string]int\n" +
	"\tarr: [4]int\n" +
	"\tfor ; arr[0] < 10; {\n" +
	"\t\tarr[0] += 1\n" +
	"\t}\n" +
	"\tfor i := 0; ; i += 1 {\n" +
	"\t\tif i > 3 do break\n" +
	"\t}\n" +
	"\tfor i := 0; i < 3; {\n" +
	"\t\ti += 1\n" +
	"\t}\n" +
	"\tfor k, &v in m {\n" +
	"\t\tv *= 2\n" +
	"\t}\n" +
	"\tfor i in 0 ..< 10 {\n" +
	"\t}\n" +
	"\tfor _, i in arr {\n" +
	"\t\tcontinue\n" +
	"\t}\n" +
	"\tlbl: {\n" +
	"\t\tbreak lbl\n" +
	"\t}\n" +
	"\touter: #reverse for &x, i in arr {\n" +
	"\t\tfor {\n" +
	"\t\t\tcontinue outer\n" +
	"\t\t}\n" +
	"\t}\n" +
	"}"

@(test)
test_loops_load_round_trip :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, HAND)
	testing.expect_value(t, src(&app), HAND)
	format_doc(&app)
	testing.expect_value(t, src(&app), HAND)

	hdr :: proc(app: ^App, text: string) -> (Loop_Hdr, Node) {
		ni := line_with(app, text)
		if ni < 0 do return {}, {}
		h, _ := loop_hdr(app.doc.nodes[ni])
		return h, app.doc.nodes[ni]
	}
	h, n := hdr(&app, "for ; arr[0]")
	testing.expect(t, h.form == .CStyle && h.init_b == h.init_a && h.post_b == h.post_a && h.cond_b > h.cond_a, "empty init / post")
	h, n = hdr(&app, "for i := 0; ;")
	testing.expect(t, h.form == .CStyle && h.cond_b == h.cond_a && h.post_b > h.post_a, "empty condition")
	testing.expect(t, is_loop_post_target(n, h.post_a), "the post's target can be re-targeted")
	testing.expect_value(t, strings.trim_space(n.fields[h.post_a + 1].text), "+=")
	h, n = hdr(&app, "for k, &v")
	testing.expect(t, h.form == .In && h.ref2 >= 0 && h.ref1 < 0 && n.fields[h.var2].text == "v", "map value by reference")
	h, n = hdr(&app, "0 ..< 10")
	testing.expect(t, h.form == .In && range_op_in_test(n, h) == "..<", "a range: its ends are separate")
	h, n = hdr(&app, "outer: #reverse")
	testing.expect(t, h.label >= 0 && h.directive >= 0 && h.ref1 >= 0 && h.var2 >= 0, "label, directive, &, two variables")
	testing.expect_value(t, n.fields[h.label].kind, LABEL_KIND)

	// break / continue are keywords Y acts on; `x += 1` has an operator part.
	b := line_with(&app, "continue outer")
	testing.expect(t, is_jump_kw(app.doc.nodes[b].fields[1]), "continue is a keyword")
	v := line_with(&app, "v *= 2")
	testing.expect_value(t, app.doc.nodes[v].fields[2].kind, ASSIGN_OP_KIND)
	lb := line_with(&app, "lbl: {")
	_, is_lb := labeled_block(app.doc.nodes[lb])
	testing.expect(t, is_lb, "a labeled block")
}

@(private = "file")
range_op_in_test :: proc(n: Node, h: Loop_Hdr) -> string {
	for f in n.fields[h.iter_a:h.iter_b] do if t := strings.trim_space(f.text); !f.slot && (t == "..<" || t == "..=") do return t
	return ""
}

// The Handmade loop: an operator on a call's result, loaded and saved unchanged.
@(test)
test_loops_handmade_message_loop :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	s := "package main\n\nimport win32 \"core:sys/windows\"\n\nmain :: proc() {\n\tmessage: win32.MSG\n\tfor win32.GetMessageW(&message, nil, 0, 0) > 0 {\n\t\twin32.TranslateMessage(&message)\n\t\twin32.DispatchMessageW(&message)\n\t}\n}"
	load(&app, s)
	testing.expect_value(t, src(&app), s)
	ni := line_with(&app, "for win32")
	h, ok := loop_hdr(app.doc.nodes[ni])
	testing.expect(t, ok && h.form == .Cond, "a while-style loop")
	// Y on the call's name: other win32 procs; B leaves it as it was.
	testing.expect(t, focus_text(&app, ni, "GetMessageW"), "the call's name is a part")
	change_selected(&app)
	testing.expect_value(t, app.state, State.Radial)
	back_out(&app)
	testing.expect_value(t, src(&app), s)
	// Y on `for` -> Change condition: a bool dot; B puts the condition back.
	focus_text(&app, ni, "for")
	change_selected(&app)
	if pick(t, &app, "Change condition") {
		testing.expect(t, dimmed(t, &app, "Number"), "the condition expects a bool")
		back_out(&app)
	}
	testing.expect_value(t, src(&app), s)
}

// Y / LT+B on the parts of a loop.
@(test)
test_loops_options :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\titems: []int\n\tm: map[string]int\n\tfor x in items {\n\t}\n\tfor k in m {\n\t}\n\tfor i := 0; i < 3; i += 1 {\n\t}\n\tfor {\n\t}\n}")
	opt :: proc(t: ^testing.T, app: ^App, ni: int, on, label: string, loc := #caller_location) {
		back_out(app)
		testing.expectf(t, focus_text(app, ni, on), "no %q", on, loc = loc)
		change_selected(app)
		pick(t, app, label, loc)
	}
	ni := line_with(&app, "for x in items")
	opt(t, &app, ni, "for", "Add label")
	testing.expect_value(t, line_src(&app, ni), "outer: for x in items {")
	opt(t, &app, ni, "for", "Add #reverse")
	opt(t, &app, ni, "for", "By reference")
	opt(t, &app, ni, "for", "Add 2nd variable")
	testing.expect_value(t, line_src(&app, ni), "outer: #reverse for &x, index in items {")
	// #unroll can't iterate a slice; with `&` it isn't allowed at all.
	back_out(&app)
	focus_text(&app, ni, "for")
	change_selected(&app)
	testing.expect(t, dimmed(t, &app, "Add #unroll"), "no #unroll over a slice")
	back_out(&app)
	// Y on the variable: by value again.
	focus_text(&app, ni, "x")
	change_selected(&app)
	testing.expect_value(t, line_src(&app, ni), "outer: #reverse for x, index in items {")
	// LT+B: the 2nd variable, the directive, the label - one at a time.
	focus_text(&app, ni, "index"); delete_selected(&app)
	focus_text(&app, ni, "#reverse"); delete_selected(&app)
	focus_text(&app, ni, "outer"); delete_selected(&app)
	testing.expect_value(t, line_src(&app, ni), "for x in items {")
	// LT+B on the iterable: back to a dot (the loop stays).
	focus_text(&app, ni, "items"); delete_selected(&app)
	testing.expect_value(t, line_src(&app, ni), "for x in  {")

	// A map: #reverse not allowed; by reference only for the value.
	ni = line_with(&app, "for k in m")
	focus_text(&app, ni, "for")
	change_selected(&app)
	testing.expect(t, dimmed(t, &app, "Add #reverse"), "maps are unordered")
	testing.expect(t, dimmed(t, &app, "By reference"), "a map's key can't be changed")
	pick(t, &app, "Add 2nd variable")
	testing.expect_value(t, line_src(&app, ni), "for k, value in m {")
	focus_text(&app, ni, "value")
	change_selected(&app) // Y: &value
	testing.expect_value(t, line_src(&app, ni), "for k, &value in m {")

	// C-style: each part can go and come back.
	ni = line_with(&app, "for i := 0")
	opt(t, &app, ni, "for", "Remove post")
	testing.expect_value(t, line_src(&app, ni), "for i := 0; i < 3; {")
	opt(t, &app, ni, "for", "Remove init")
	testing.expect_value(t, line_src(&app, ni), "for ; i < 3; {")
	opt(t, &app, ni, "for", "Add post")
	testing.expect_value(t, line_src(&app, ni), "for ; i < 3; i += 1 {")
	opt(t, &app, ni, "for", "Add init")
	testing.expect_value(t, line_src(&app, ni), "for i := 0; i < 3; i += 1 {")
	focus_text(&app, ni, "3"); delete_selected(&app) // LT+B in the condition: the condition goes
	testing.expect_value(t, line_src(&app, ni), "for i := 0; ; i += 1 {")
	opt(t, &app, ni, "for", "Add condition")
	testing.expect_value(t, line_src(&app, ni), "for i := 0; ; i += 1 {") // a dot (saved empty)
	// Y on the post's operator: another operator.
	opt(t, &app, ni, " += ", "-=")
	testing.expect_value(t, line_src(&app, ni), "for i := 0; ; i -= 1 {")

	// Infinite <-> while.
	ni = line_with(&app, "for {")
	opt(t, &app, ni, "for", "Add condition")
	testing.expect_value(t, len(app.doc.nodes[ni].fields), 5) // indent, for, " ", ●, " {"
	opt(t, &app, ni, "for", "Remove condition")
	testing.expect_value(t, line_src(&app, ni), "for {")

	// LT+B on `for` deletes the whole loop.
	n_before := len(app.doc.nodes)
	focus_text(&app, ni, "for"); delete_selected(&app)
	testing.expect_value(t, len(app.doc.nodes), n_before - 2)
}

// Loop variables: their types inside the loop; not known (nor offered) outside it.
@(test)
test_loops_variable_types_and_scope :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, BUILT)
	ty :: proc(app: ^App, at: string, name: string) -> string {
		ni := line_with(app, at)
		t, ok := var_type_at(app, ni + 1, name)
		if !ok do return "<none>"
		return t.expr
	}
	testing.expect_value(t, ty(&app, "for i := 0", "i"), "int")
	testing.expect_value(t, ty(&app, "for i in 0..<10", "i"), "int")
	testing.expect_value(t, ty(&app, "for item, index in items", "item"), "Item")
	testing.expect_value(t, ty(&app, "for item, index in items", "index"), "int")
	testing.expect_value(t, ty(&app, "for key, value in ages", "key"), "string")
	testing.expect_value(t, ty(&app, "for key, value in ages", "value"), "int")
	testing.expect_value(t, ty(&app, "for ch, i in text", "ch"), "rune")
	testing.expect_value(t, ty(&app, "for ch, i in text", "i"), "int")
	testing.expect_value(t, ty(&app, "#reverse for name", "name"), "string")
	// item.hp: a field of the loop variable.
	ni := line_with(&app, "item.hp -= 1")
	ft, ok := expr_type_at(&app, ni, "item.hp")
	testing.expect(t, ok && ft.expr == "int", "item.hp is an int")
	// Outside its loop the variable isn't known.
	_, found := var_type_at(&app, line_with(&app, "#reverse for"), "item")
	testing.expect(t, !found, "item is out of scope after its loop")
	_, found = var_type_at(&app, line_with(&app, "for count < 10") + 1, "ch")
	testing.expect(t, !found, "ch isn't declared yet")

	// Reference: inside the loop its variable is offered, outside it isn't.
	names_for :: proc(app: ^App, ni, fi: int) -> []string {
		app.slot_ni, app.slot_fi = ni, fi
		out := make([dynamic]string, context.temp_allocator)
		for c in ref_candidates(app) do append(&out, app.doc.nodes[c.ni].fields[c.fi].text)
		return out[:]
	}
	has :: proc(s: []string, x: string) -> bool { for v in s do if v == x do return true; return false }
	inside := line_with(&app, "item.hp -= 1")
	got := names_for(&app, inside, 3)
	testing.expectf(t, has(got, "item") && has(got, "items"), "inside: %v", got)
	testing.expectf(t, !has(got, "ch") && !has(got, "key"), "other loops' variables: %v", got)
	outside := line_with(&app, "#reverse for")
	got = names_for(&app, outside, 3)
	testing.expectf(t, !has(got, "name") && !has(got, "item") && !has(got, "ch"), "outside their loops: %v", got)
	testing.expectf(t, !has(got, "outer"), "labels aren't values: %v", got)
	header := line_with(&app, "for &item in items")
	got = names_for(&app, header, len(app.doc.nodes[header].fields) - 2) // the iterable itself
	testing.expectf(t, !has(got, "item"), "a loop's variable isn't offered for its own iterable: %v", got)
}

// Pass as on an iterable: names that can't be iterated are grayed.
@(test)
test_loops_iterable_pass_as :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, BASE)
	ni := add_stmt(t, &app, line_with(&app, "grid:") + 1, "Loops", "For ... in")
	if open_dot(t, &app, ni, 0) && pick(t, &app, "Reference") && ref_choose(t, &app, "count") {
		testing.expect(t, dimmed(t, &app, "count"), "an int can't be iterated")
		back_out(&app)
	}
	if open_dot(t, &app, ni, 0) && pick(t, &app, "Reference") && ref_choose(t, &app, "grid") {
		testing.expect(t, !dimmed(t, &app, "grid"), "an array can")
		pick(t, &app, "grid")
	}
	testing.expect_value(t, line_src(&app, ni), "for item in grid {")
	ty, ok := var_type_at(&app, ni + 1, "item")
	testing.expect(t, ok && ty.expr == "f32", "item is an f32")
	// #unroll over an array is fine; By reference too.
	focus_text(&app, ni, "for")
	change_selected(&app)
	testing.expect(t, !dimmed(t, &app, "Add #unroll"), "#unroll over an array")
	testing.expect(t, !dimmed(t, &app, "By reference"), "an array's elements can be changed")
	back_out(&app)
}

// break / continue: grayed outside loops, labels only where they're in scope.
@(test)
test_loops_jumps :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tx := 0\n\tblk: {\n\t\tx = 1\n\t}\n\touter: for {\n\t\tx = 2\n\t}\n}")
	at := line_with(&app, "x := 0") + 1
	focus_dot_at(&app, at)
	update(&app, Input{confirm = true})
	if pick(t, &app, "Jumps and cleanup") {
		testing.expect(t, dimmed(t, &app, "Break"), "no loop here")
		testing.expect(t, dimmed(t, &app, "Continue"), "no loop here")
		testing.expect(t, !has_entry(&app, "Break outer"), "outer isn't in scope here")
	}
	back_out(&app)
	// Inside the labeled block: `break blk`, but no `continue blk`.
	focus_dot_at(&app, line_with(&app, "x = 1"))
	update(&app, Input{confirm = true})
	if pick(t, &app, "Jumps and cleanup") {
		testing.expect(t, has_entry(&app, "Break blk"), "break blk")
		testing.expect(t, !has_entry(&app, "Continue blk"), "continue needs a loop")
		pick(t, &app, "Break blk")
	}
	b := line_with(&app, "break blk")
	testing.expect(t, b >= 0, "break blk inserted")
	// Inside the loop; then Y on `continue` -> continue outer.
	focus_dot_at(&app, line_with(&app, "x = 2"))
	update(&app, Input{confirm = true})
	if pick(t, &app, "Jumps and cleanup") do pick(t, &app, "Continue")
	c := line_with(&app, "continue")
	focus_text(&app, c, "continue")
	change_selected(&app)
	pick(t, &app, "continue outer")
	testing.expect_value(t, line_src(&app, c), "continue outer")
	// LT+B on a labeled block's label while `break blk` uses it: refused (and
	// "Remove label" dimmed); a bare break can't leave a block.
	focus_text(&app, line_with(&app, "blk: {"), "blk")
	delete_selected(&app)
	testing.expect(t, line_with(&app, "blk: {") >= 0 && line_with(&app, "break blk") >= 0, "the label stays while break blk uses it")
	focus_text(&app, line_with(&app, "blk: {"), "blk")
	change_selected(&app)
	testing.expect(t, dimmed(t, &app, "Remove label"), "Remove label dimmed while used")
	back_out(&app)
	// Without the jump: a plain block.
	focus_text(&app, line_with(&app, "break blk"), "break")
	delete_selected(&app)
	testing.expect(t, line_with(&app, "break blk") < 0, "break blk deleted")
	focus_text(&app, line_with(&app, "blk: {"), "blk")
	delete_selected(&app)
	testing.expect(t, line_with(&app, "blk: {") < 0 && line_with(&app, "x = 1") >= 0 && line_src(&app, line_with(&app, "x = 1") - 1) == "{", "a plain block")
}

// Compound assignment: inserted with its operator, Y changes it, loaded back.
@(test)
test_loops_compound_assignment :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tflags: u32\n\tshift := 2\n}")
	ni := add_stmt(t, &app, line_with(&app, "shift :=") + 1, "Assignment", "|=")
	focus_field_index(&app, ni, 1)
	change_selected(&app)
	if ref_choose(t, &app, "flags") do pick(t, &app, "flags")
	if open_dot(t, &app, ni, 0) {
		testing.expect(t, dimmed(t, &app, "true"), "flags |= expects a u32")
		back_out(&app)
	}
	fill_number(t, &app, ni, "4")
	testing.expect_value(t, line_src(&app, ni), "flags |= 4")
	focus_text(&app, ni, " |= ")
	change_selected(&app)
	testing.expect(t, dimmed(t, &app, "|="), "the current operator")
	pick(t, &app, "<<=")
	testing.expect_value(t, line_src(&app, ni), "flags <<= 4")
	s := strings.clone(src(&app), context.temp_allocator)
	load(&app, s)
	testing.expect_value(t, src(&app), s)
	ni = line_with(&app, "flags <<= 4")
	testing.expect_value(t, app.doc.nodes[ni].fields[2].kind, ASSIGN_OP_KIND)
	testing.expect(t, is_assign_target(app.doc.nodes[ni], 1), "Y re-targets it")
}

// The iterable's "Range" fill; Y on a filled iterable refills it (B restores it).
@(test)
test_loops_iterable_range_and_refill :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, BASE)
	ni := add_stmt(t, &app, line_with(&app, "grid:") + 1, "Loops", "For ... in")
	if open_dot(t, &app, ni, 0) && pick(t, &app, "Range") do pick(t, &app, "a ..= b  (through b)") // the shared Range entry (range_fill.odin)
	fill_ref(t, &app, ni, "count")
	fill_number(t, &app, ni, "9")
	testing.expect_value(t, line_src(&app, ni), "for item in count..=9 {")
	ty, ok := var_type_at(&app, ni + 1, "item")
	testing.expect(t, ok && ty.expr == "int", "a range of ints")
	// Y on `9` (one end of the range): refill it; B puts it back.
	focus_text(&app, ni, "9")
	change_selected(&app)
	testing.expect_value(t, app.state, State.Radial)
	back_out(&app)
	testing.expect_value(t, line_src(&app, ni), "for item in count..=9 {")
	// Y on `for` -> Change iterable -> Reference names.
	focus_text(&app, ni, "for")
	change_selected(&app)
	if pick(t, &app, "Change iterable") && pick(t, &app, "Reference") && ref_choose(t, &app, "names") do pick(t, &app, "names")
	testing.expect_value(t, line_src(&app, ni), "for item in names {")
	ty, ok = var_type_at(&app, ni + 1, "item")
	testing.expect(t, ok && ty.expr == "string", "the elements of a []string")
}

// The loop's modifiers decide what it can iterate: `&item` not a string or a
// range, #reverse not a map, #unroll not a slice.
@(test)
test_loops_iterable_respects_modifiers :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, BASE)
	ni := add_stmt(t, &app, line_with(&app, "grid:") + 1, "Loops", "For &x in")
	if open_dot(t, &app, ni, 0) {
		testing.expect(t, dimmed(t, &app, "Range"), "a range's values can't be changed in place")
		testing.expect(t, dimmed(t, &app, "\"...\"  string"), "nor a string's characters")
		if pick(t, &app, "Reference") && ref_choose(t, &app, "text") {
			testing.expect(t, dimmed(t, &app, "text"), "text is a string")
			back_out(&app)
		}
	}
	if open_dot(t, &app, ni, 0) && pick(t, &app, "Reference") && ref_choose(t, &app, "items") {
		testing.expect(t, !dimmed(t, &app, "items"), "a dynamic array's elements can")
		back_out(&app)
	}
	ni = add_stmt(t, &app, ni + 3, "Loops", "#reverse for")
	if open_dot(t, &app, ni, 0) && pick(t, &app, "Reference") && ref_choose(t, &app, "ages") {
		testing.expect(t, dimmed(t, &app, "ages"), "maps are unordered")
		back_out(&app)
	}
	ni = add_stmt(t, &app, ni + 3, "Loops", "#unroll for")
	focus_text(&app, ni, "for")
	change_selected(&app)
	if pick(t, &app, "Change iterable") && pick(t, &app, "Reference") && ref_choose(t, &app, "names") {
		testing.expect(t, dimmed(t, &app, "names"), "#unroll needs a length known at compile time")
		back_out(&app)
	}
	testing.expect_value(t, line_src(&app, ni), "#unroll for i in 0..< {")
}

// Long loop headers / compound assignments holding calls stay on one line when saved.
@(test)
test_loops_long_lines_stay_one_line :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	s := "package main\n\nimport \"core:strings\"\n\nmain :: proc() {\n\ttotal := 0\n" +
		"\tfor part, index in strings.split(\"alpha, beta, gamma, delta, epsilon\", \", \", context.temp_allocator) {\n" +
		"\t\ttotal += len(strings.trim_space(strings.to_upper(part, context.temp_allocator))) + index\n" +
		"\t}\n}"
	load(&app, s)
	testing.expect_value(t, src(&app), s)
	format_doc(&app)
	testing.expect_value(t, src(&app), s)
	_, ok := loop_hdr(app.doc.nodes[line_with(&app, "for part")])
	testing.expect(t, ok, "structured")
	ty, tok := var_type_at(&app, line_with(&app, "total +="), "part")
	testing.expect(t, tok && ty.expr == "string", "strings.split returns a []string")
}

// A C-style loop's post: Y on its target picks the variable (the init's is offered).
@(test)
test_loops_cstyle_post_target :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, BASE)
	ni := add_stmt(t, &app, line_with(&app, "grid:") + 1, "Loops", "For (C-style)")
	rename(&app, ni, "i", "n") // the init's name (dictated)
	h, _ := loop_hdr(app.doc.nodes[ni])
	focus_field_index(&app, ni, h.post_a)
	change_selected(&app)
	if ref_choose(t, &app, "n") do pick(t, &app, "n")
	h, _ = loop_hdr(app.doc.nodes[ni])
	testing.expect_value(t, app.doc.nodes[ni].fields[h.post_a].text, "n")
	ty, ok := var_type_at(&app, ni + 1, "n")
	testing.expect(t, ok && ty.expr == "int", "n is an int")
}

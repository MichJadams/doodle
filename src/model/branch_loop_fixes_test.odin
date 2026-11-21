package model

// Regression tests for the branching / loops review findings (one test per
// finding, driven like the controller: A / Y / LT+B / LT+A, menu picks,
// Reference). `odin check` runs on the results when DOODLE_ODIN is set (see
// branch_loop_acceptance_test.odin).

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
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
load :: proc(app: ^App, text: string) {
	app.state = .Editor
	doc_from_source(app, text)
}

@(private = "file")
line_with :: proc(app: ^App, text: string, from := 0) -> int {
	for i in max(from, 0) ..< len(app.doc.nodes) do if strings.contains(node_text(app.doc.nodes[i], context.temp_allocator), text) do return i
	return -1
}

@(private = "file")
line_src :: proc(app: ^App, ni: int) -> string {
	if ni < 0 || ni >= len(app.doc.nodes) do return "<no line>"
	return strings.trim_space(node_source(app.doc.nodes[ni], context.temp_allocator))
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
	testing.expectf(t, ok, "menu entry %q should exist", label, loc = loc)
	return e.dim
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
	testing.expectf(t, false, "no %q in menu %q", label, v.title, loc = loc)
	return false
}

@(private = "file")
back_out :: proc(app: ^App) {
	for _ in 0 ..< 16 {
		if app.state == .Editor && !app.ref_pick_active && !app.mod_pick_active do return
		update(app, Input{cancel = true})
	}
}

@(private = "file")
cursor_text :: proc(app: ^App) -> string {
	ni, fi, ok := editor_target(app)
	if !ok do return "<none>"
	return app.doc.nodes[ni].fields[fi].text
}

// The cursor on the (nth) field of line ni whose trimmed text is `text`.
@(private = "file")
focus_text :: proc(t: ^testing.T, app: ^App, ni: int, text: string, nth := 0, loc := #caller_location) -> bool {
	back_out(app)
	seen := 0
	if ni >= 0 && ni < len(app.doc.nodes) {
		for f, i in app.doc.nodes[ni].fields {
			if f.slot || strings.trim_space(f.text) != text do continue
			if seen == nth {
				focus_field_index(app, ni, i)
				return true
			}
			seen += 1
		}
	}
	testing.expectf(t, false, "no %q on line %d (%q)", text, ni, line_src(app, ni), loc = loc)
	return false
}

// Y on `text` of line ni.
@(private = "file")
y_on :: proc(t: ^testing.T, app: ^App, ni: int, text: string, loc := #caller_location) -> bool {
	if !focus_text(t, app, ni, text, loc = loc) do return false
	change_selected(app)
	return testing.expectf(t, app.state == .Radial, "Y on %q opened no menu", text, loc = loc)
}

// A on the green dot before line at, then group -> leaf.
@(private = "file")
add_at :: proc(t: ^testing.T, app: ^App, at: int, group, leaf: string, loc := #caller_location) {
	back_out(app)
	focus_dot_at(app, at)
	update(app, Input{confirm = true})
	if pick(t, app, group, loc) && leaf != "" do pick(t, app, leaf, loc)
}

// A on the nth unfilled dot of `kind` on line ni.
@(private = "file")
open_dot :: proc(t: ^testing.T, app: ^App, ni, nth: int, kind := "value", loc := #caller_location) -> bool {
	back_out(app)
	seen := 0
	if ni >= 0 && ni < len(app.doc.nodes) {
		for f, i in app.doc.nodes[ni].fields {
			if f.slot && f.kind == kind {
				if seen == nth {
					focus_field_index(app, ni, i)
					update(app, Input{confirm = true})
					return true
				}
				seen += 1
			}
		}
	}
	testing.expectf(t, false, "no %s dot #%d on %q", kind, nth, line_src(app, ni), loc = loc)
	return false
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

// The names Reference offers from a dot on line ni.
@(private = "file")
ref_names :: proc(app: ^App, ni: int) -> []string {
	saved_ni, saved_fi := app.slot_ni, app.slot_fi
	app.slot_ni, app.slot_fi = ni, 0
	defer app.slot_ni, app.slot_fi = saved_ni, saved_fi
	out := make([dynamic]string, context.temp_allocator)
	for c in ref_candidates(app) do append(&out, app.doc.nodes[c.ni].fields[c.fi].text)
	return out[:]
}

@(private = "file")
offers :: proc(app: ^App, ni: int, name: string) -> bool {
	for n in ref_names(app, ni) do if n == name do return true
	return false
}

@(private = "file")
type_at :: proc(app: ^App, ni: int, name: string) -> string {
	ty, ok := var_type_at(app, ni, name)
	return ok ? ty.expr : "<unknown>"
}

// D-pad stops of line ni (dots show as "●").
@(private = "file")
dpad_stops :: proc(app: ^App, ni: int) -> []string {
	back_out(app)
	focus_field_index(app, ni, 0)
	out := make([dynamic]string, context.temp_allocator)
	for _ in 0 ..< 48 {
		eni, efi, ok := editor_target(app)
		if !ok || eni != ni || app.editor_dot do break
		f := app.doc.nodes[eni].fields[efi]
		append(&out, f.slot ? "●" : strings.trim_space(f.text))
		before := app.editor_field
		update(app, Input{right = true})
		if app.editor_line == ni && app.editor_field == before do break
	}
	return out[:]
}

@(private = "file")
has_slot_in :: proc(n: Node) -> bool {
	for f in n.fields do if f.slot do return true
	return false
}

@(private = "file")
check_mutex: sync.Mutex

// `odin check` on `text` (when DOODLE_ODIN is set).
@(private = "file")
odin_check :: proc(t: ^testing.T, name, text: string, loc := #caller_location) {
	odin := os.get_env("DOODLE_ODIN", context.temp_allocator)
	if odin == "" do return
	base := os.get_env("DOODLE_CHECK_DIR", context.temp_allocator)
	if base == "" {
		tmp, _ := os.temp_directory(context.temp_allocator)
		base, _ = filepath.join({tmp, "doodle_fixes_check"}, context.temp_allocator)
	}
	dir, _ := filepath.join({base, name}, context.temp_allocator)
	os.make_directory_all(dir)
	file, _ := filepath.join({dir, "main.odin"}, context.temp_allocator)
	_ = os.write_entire_file(file, transmute([]u8)text)
	sync.mutex_lock(&check_mutex)
	defer sync.mutex_unlock(&check_mutex)
	state, out, errs, err := os.process_exec(os.Process_Desc{command = []string{odin, "check", dir}}, context.temp_allocator)
	testing.expectf(t, err == nil && state.exit_code == 0, "odin check %s failed (exit=%d):\n%s%s\n--- source ---\n%s",
		name, state.exit_code, string(out), string(errs), text, loc = loc)
}

// ---------------------------------------------------------------------------
// Branching

// #1: LT+B on an if / else if condition or a switch value blanks it (bodies kept).
@(test)
test_fix_ltb_condition_keeps_construct :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\nmain :: proc() {\n\tx := 1\n\tif x > 0 {\n\t\tx = 2\n\t\tx = 5\n\t} else if x < 0 {\n\t\tx = 4\n\t} else {\n\t\tx = 3\n\t}\n}"
	load(&app, text)
	h := line_with(&app, "if x > 0")
	if focus_text(t, &app, h, "x") do delete_selected(&app)
	l, ok := br_line_at(&app, h)
	testing.expectf(t, ok && l.kind == .If && l.expr_b - l.expr_a == 1 && app.doc.nodes[h].fields[l.expr_a].slot, "if ● {: %q", line_src(&app, h))
	for s in ([]string{"x = 2", "x = 5", "x = 4", "x = 3", "} else if x < 0 {", "} else {"}) do testing.expectf(t, line_with(&app, s) >= 0, "%q kept:\n%s", s, src(&app))
	// The else if's condition: blanked, the branch stays.
	e := line_with(&app, "} else if")
	if focus_text(t, &app, e, "x") do delete_selected(&app)
	el, eok := br_line_at(&app, e)
	testing.expectf(t, eok && el.kind == .Else_If && app.doc.nodes[e].fields[el.expr_a].slot, "else if ● {: %q", line_src(&app, e))
	testing.expect(t, line_with(&app, "x = 4") >= 0, "the else if body is kept")
	// LT+B on the `else if` keyword still removes that branch, on `if` the whole chain.
	if focus_text(t, &app, line_with(&app, "} else if"), "else if") do delete_selected(&app)
	testing.expect(t, line_with(&app, "else if") < 0 && line_with(&app, "x = 4") < 0 && line_with(&app, "x = 3") >= 0, "else if branch removed")
	if focus_text(t, &app, line_with(&app, "if "), "if") do delete_selected(&app)
	testing.expect(t, line_with(&app, "x = 2") < 0 && line_with(&app, "x = 3") < 0, "the whole chain removed")

	// A switch's value.
	load(&app, "package main\n\nmain :: proc() {\n\tx := 1\n\tswitch x {\n\tcase 1:\n\t\tx = 2\n\t}\n}")
	s := line_with(&app, "switch x")
	if focus_text(t, &app, s, "x") do delete_selected(&app)
	sl, sok := br_line_at(&app, s)
	testing.expectf(t, sok && sl.kind == .Switch && app.doc.nodes[s].fields[sl.expr_a].slot, "switch ● {: %q", line_src(&app, s))
	testing.expect(t, line_with(&app, "case 1:") >= 0 && line_with(&app, "x = 2") >= 0, "the cases are kept")
	if focus_text(t, &app, s, "switch") do delete_selected(&app)
	testing.expect(t, line_with(&app, "case 1:") < 0, "LT+B on switch: the whole switch")
}

// #2 / #3: Fallthrough only at the end of a case clause that isn't the last, never in a type switch.
@(test)
test_fix_fallthrough_positions :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tx := 1\n\tswitch x {\n\tcase 1:\n\t\tx = 2\n\t\tx = 3\n\tcase 2:\n\t}\n}")
	add_at(t, &app, line_with(&app, "x = 3"), "Jumps and cleanup", "")
	testing.expect(t, !has_entry(&app, "Fallthrough"), "no Fallthrough in the middle of a clause")
	back_out(&app)
	add_at(t, &app, line_with(&app, "case 2:"), "Jumps and cleanup", "")
	testing.expect(t, has_entry(&app, "Fallthrough"), "Fallthrough at the end of a clause that isn't the last")
	if has_entry(&app, "Fallthrough") do pick(t, &app, "Fallthrough")
	back_out(&app)
	odin_check(t, "fix_fallthrough", src(&app))

	load(&app, "package main\n\nShape :: union {\n\tint,\n\tstring,\n}\n\nmain :: proc() {\n\ts: Shape\n\tswitch v in s {\n\tcase int:\n\tcase string:\n\t}\n}")
	add_at(t, &app, line_with(&app, "case string:"), "Jumps and cleanup", "")
	testing.expect(t, !has_entry(&app, "Fallthrough"), "no Fallthrough in a type switch")
	back_out(&app)
}

// #4: an else if's setup names: known in its body and the later branches; LT+B on them removes the setup; Y offers setup.
@(test)
test_fix_else_if_setup :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\nmain :: proc() {\n\tm: map[string]int\n\tx := 0\n\tif x > 1 {\n\t\tx = 1\n\t} else if v, ok := m[\"k\"]; ok {\n\t\tx = v\n\t} else {\n\t\tx = 2\n\t}\n\tx = 3\n}"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	body := line_with(&app, "x = v")
	els := line_with(&app, "x = 2")
	after := line_with(&app, "x = 3")
	testing.expect_value(t, type_at(&app, body, "v"), "int")
	testing.expect_value(t, type_at(&app, body, "ok"), "bool")
	testing.expect_value(t, type_at(&app, els, "ok"), "bool")
	testing.expect_value(t, type_at(&app, els, "v"), "int")
	testing.expect_value(t, type_at(&app, after, "v"), "<unknown>")
	testing.expect(t, offers(&app, body, "v") && offers(&app, els, "ok"), "Reference offers them inside")
	testing.expect(t, !offers(&app, after, "v") && !offers(&app, after, "ok"), "and not after the chain")
	odin_check(t, "fix_else_if_setup", src(&app))
	e := line_with(&app, "} else if")
	if y_on(t, &app, e, "else if") do testing.expect(t, has_entry(&app, "Remove setup"), "Y on else if: Remove setup")
	back_out(&app)
	if focus_text(t, &app, e, "v") do delete_selected(&app)
	testing.expect_value(t, line_src(&app, e), "} else if ok {")
	testing.expect(t, line_with(&app, "x = v") >= 0, "the branch body is kept")
	if y_on(t, &app, e, "else if") do testing.expect(t, has_entry(&app, "Add setup"), "Y on else if: Add setup")
	back_out(&app)
}

// #5: indexing an enumerated array: the key dot expects the enum.
@(test)
test_fix_enum_array_index_key :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nDir :: enum {\n\tNorth,\n\tSouth,\n}\n\nN :: 4\n\nmain :: proc() {\n\tarr: [Dir]f32\n\tnums: [N]int\n\ty: f32 = 0\n}")
	k, el, ok := index_types(&app, Var_Type{"[Dir]f32", ""})
	testing.expectf(t, ok && k.expr == "Dir" && el.expr == "f32", "[Dir]f32: key %v elem %v", k, el)
	k2, _, ok2 := index_types(&app, Var_Type{"[N]int", ""})
	testing.expectf(t, ok2 && k2.expr == "int", "[N]int: key %v", k2)
	k3, _, _ := index_types(&app, Var_Type{"[4]int", ""})
	testing.expect_value(t, k3.expr, "int")
	// Assignment > Assignment, Y on its target -> y, then its value: Reference arr -> arr[i].
	add_at(t, &app, len(app.doc.nodes) - 1, "Assignment", "Assignment")
	back_out(&app)
	y := -1
	for n, i in app.doc.nodes do if has_slot_in(n) && !is_body_slot_line(n) { y = i; break }
	if !testing.expect(t, y >= 0, "an assignment line") do return
	for f, i in app.doc.nodes[y].fields do if f.editable && !f.slot { focus_field_index(&app, y, i); break }
	change_selected(&app)
	if ref_choose(t, &app, "y") && app.state == .Radial do pick(t, &app, "y")
	back_out(&app)
	if !open_dot(t, &app, y, 0) || !pick(t, &app, "Reference") || !ref_choose(t, &app, "arr") do return
	if app.state == .Radial do pick(t, &app, "arr[i]   f32")
	back_out(&app)
	key := -1
	for f, i in app.doc.nodes[y].fields do if f.slot { key = i; break }
	if !testing.expectf(t, key >= 0, "a key dot: %q", line_src(&app, y)) do return
	testing.expect_value(t, app.doc.nodes[y].fields[key].hint, "Dir")
	if open_dot(t, &app, y, 0) {
		testing.expect(t, !dimmed(t, &app, "Enum value"), "Enum value fits the key")
		if pick(t, &app, "Enum value") do pick(t, &app, ".North")
	}
	testing.expect_value(t, line_src(&app, y), "y = arr[.North]")
	for n, i in app.doc.nodes do if is_body_slot_line(n) {
		focus_field_index(&app, i, 1)
		delete_selected(&app)
		break
	}
	odin_check(t, "fix_enum_array_index", src(&app))
}

// #6: `switch &v in s {` loads as a type switch; Y toggles by reference.
@(test)
test_fix_by_reference_type_switch :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\nShape :: union {\n\tint,\n\tf32,\n}\n\nmain :: proc() {\n\ts: Shape\n\tswitch &v in s {\n\tcase int:\n\t\tv += 1\n\tcase f32:\n\t}\n\ty := 0\n}"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	sw := line_with(&app, "switch &v")
	l, ok := br_line_at(&app, sw)
	testing.expectf(t, ok && l.tvar >= 0 && l.tvar_ref >= 0, "a type switch by reference: %v", l)
	ci := line_with(&app, "case int:")
	has_type := false
	for f in app.doc.nodes[ci].fields do if f.kind == "type" && f.editable do has_type = true
	testing.expect(t, has_type, "case int: holds a type")
	testing.expect_value(t, type_at(&app, line_with(&app, "v += 1"), "v"), "int")
	testing.expect_value(t, type_at(&app, line_with(&app, "y := 0"), "v"), "<unknown>")
	odin_check(t, "fix_byref_type_switch", src(&app))
	// LT+B on v: kept.
	if focus_text(t, &app, sw, "v") do delete_selected(&app)
	testing.expect(t, line_with(&app, "switch &v in s {") >= 0, "LT+B on v keeps the switch")
	// Y > By value / By reference.
	if y_on(t, &app, sw, "switch") do pick(t, &app, "By value")
	back_out(&app)
	testing.expect_value(t, line_src(&app, sw), "switch v in s {")
	if y_on(t, &app, sw, "switch") do pick(t, &app, "By reference")
	back_out(&app)
	testing.expect_value(t, line_src(&app, sw), "switch &v in s {")
	// Y > Add case: a variant dot.
	if y_on(t, &app, sw, "switch") do pick(t, &app, "Add case")
	back_out(&app)
	found := false
	for n in app.doc.nodes do for f in n.fields do if f.slot && f.kind == VARIANT_KIND do found = true
	testing.expect(t, found, "Add case: a variant dot")
}

// #19: Reference offers locals only where they're in scope.
@(test)
test_fix_reference_scope :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nCircle :: struct {\n\tr: f32,\n}\n\nSquare :: struct {\n\tside: f32,\n}\n\nShape :: union {\n\tCircle,\n\tSquare,\n}\n\n" +
		"helper :: proc(k: int) {\n\thidden := k\n}\n\n" +
		"main :: proc() {\n\tx := 0\n\tshape: Shape\n\tswitch v in shape {\n\tcase Circle:\n\t\tr := v.r\n\tcase Square:\n\t\tx = 2\n\t}\n\tif x > 0 {\n\t\tinner := 1\n\t}\n\tx = 5\n}")
	sq := line_with(&app, "x = 2")
	testing.expectf(t, !offers(&app, sq, "r"), "r (case Circle) isn't offered in case Square: %v", ref_names(&app, sq))
	testing.expect(t, offers(&app, sq, "v") && offers(&app, sq, "x") && offers(&app, sq, "shape"), "v, x, shape are")
	testing.expect(t, !offers(&app, sq, "hidden") && !offers(&app, sq, "k"), "another procedure's locals / parameters aren't")
	testing.expect(t, offers(&app, sq, "helper") && offers(&app, sq, "Circle"), "file-scope names are")
	end := line_with(&app, "x = 5")
	testing.expect(t, !offers(&app, end, "inner"), "an if body's local isn't offered after it")
	testing.expect(t, !offers(&app, end, "r") && !offers(&app, end, "v"), "nor the switch's names")
	testing.expect(t, offers(&app, line_with(&app, "hidden := k"), "k"), "a procedure's own parameter is")
	testing.expect(t, !offers(&app, line_with(&app, "x := 0"), "shape"), "a local declared later isn't")
}

// #18: a when's condition: a D-pad stop, Y refills it, LT+B blanks it.
@(test)
test_fix_when_condition :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tx := 0\n\twhen ODIN_DEBUG {\n\t\tx = 1\n\t} else when ODIN_TEST {\n\t\tx = 2\n\t}\n}")
	w := line_with(&app, "when ODIN_DEBUG")
	stops := dpad_stops(&app, w)
	testing.expectf(t, len(stops) == 2 && stops[1] == "ODIN_DEBUG", "when line stops: %v", stops)
	if focus_text(t, &app, w, "ODIN_DEBUG") {
		change_selected(&app)
		testing.expect(t, dimmed(t, &app, "ODIN_OS"), "ODIN_OS isn't a bool")
		if pick(t, &app, "Built-in constants") do pick(t, &app, "ODIN_TEST")
	}
	back_out(&app)
	testing.expect_value(t, line_src(&app, w), "when ODIN_TEST {")
	if focus_text(t, &app, w, "ODIN_TEST") do delete_selected(&app)
	testing.expect(t, has_slot_in(app.doc.nodes[w]) && line_with(&app, "x = 1") >= 0 && line_with(&app, "} else when ODIN_TEST {") >= 0, "when ● {, the rest kept")
	e := line_with(&app, "} else when")
	estops := dpad_stops(&app, e)
	testing.expectf(t, len(estops) >= 2 && estops[len(estops) - 1] == "ODIN_TEST", "else when stops: %v", estops)
	if focus_text(t, &app, e, "ODIN_TEST") do delete_selected(&app)
	testing.expect(t, has_slot_in(app.doc.nodes[e]) && line_with(&app, "x = 2") >= 0, "else when ● {, its body kept")
	// LT+B on `when` still deletes the chain.
	if focus_text(t, &app, w, "when") do delete_selected(&app)
	testing.expect(t, line_with(&app, "x = 1") < 0 && line_with(&app, "x = 2") < 0, "the chain is deleted")
}

// ---------------------------------------------------------------------------
// Loops

// #7: labels are unique per procedure (sibling loops, Y > Add label).
@(test)
test_fix_unique_labels :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\titems: [dynamic]int\n}")
	close :: proc(app: ^App) -> int {
		end := len(app.doc.nodes) - 1
		for end > 0 && line_src(app, end) != "}" do end -= 1
		return end
	}
	fill_items :: proc(t: ^testing.T, app: ^App, ni: int) {
		if open_dot(t, app, ni, 0) && pick(t, app, "Reference") && ref_choose(t, app, "items") && app.state == .Radial do pick(t, app, "items")
		back_out(app)
	}
	for leaf in ([]string{"Labeled for", "Labeled for", "For ... in"}) {
		at := close(&app)
		add_at(t, &app, at, "Loops", leaf)
		back_out(&app)
		fill_items(t, &app, at)
	}
	third := -1
	for n, i in app.doc.nodes do if h, ok := loop_hdr(n); ok && h.label < 0 do third = i
	if y_on(t, &app, third, "for") do pick(t, &app, "Add label")
	back_out(&app)
	// Drop the leftover statement dots.
	for _ in 0 ..< 16 {
		b := -1
		for n, i in app.doc.nodes do if is_body_slot_line(n) { b = i; break }
		if b < 0 do break
		focus_field_index(&app, b, 1)
		before := len(app.doc.nodes)
		delete_selected(&app)
		if len(app.doc.nodes) == before do break
	}
	labels := make([dynamic]string, context.temp_allocator)
	for n in app.doc.nodes do if h, ok := loop_hdr(n); ok && h.label >= 0 do append(&labels, n.fields[h.label].text)
	testing.expectf(t, len(labels) == 3 && labels[0] != labels[1] && labels[1] != labels[2] && labels[0] != labels[2], "distinct labels: %v", labels)
	format_doc(&app)
	odin_check(t, "fix_unique_labels", src(&app))
}

// #10 / #16: removing a label its jumps use.
@(test)
test_fix_remove_used_label :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	head := "package main\n\nmain :: proc() {\n\titems: [dynamic]int\n"
	// No loop in between: `break outer` becomes `break`.
	load(&app, strings.concatenate({head, "\touter: for item in items {\n\t\tif item > 0 {\n\t\t\tbreak outer\n\t\t}\n\t\tcontinue outer\n\t}\n}"}, context.temp_allocator))
	if focus_text(t, &app, line_with(&app, "outer: for"), "outer") do delete_selected(&app)
	out := src(&app)
	testing.expectf(t, !strings.contains(out, "outer") && strings.contains(out, "\t\t\tbreak\n") && strings.contains(out, "\t\tcontinue\n"), "bare jumps:\n%s", out)
	odin_check(t, "fix_remove_label_bare", out)
	// A loop in between: refused, "Remove label" dimmed.
	nested := strings.concatenate({head, "\touter: for item in items {\n\t\tfor i in 0..<3 {\n\t\t\tbreak outer\n\t\t}\n\t}\n}"}, context.temp_allocator)
	load(&app, nested)
	h := line_with(&app, "outer: for")
	if focus_text(t, &app, h, "outer") do delete_selected(&app)
	testing.expect_value(t, src(&app), nested)
	if y_on(t, &app, h, "outer") do testing.expect(t, dimmed(t, &app, "Remove label"), "Remove label dimmed")
	back_out(&app)
	// A switch in between: a bare break would leave the switch.
	sw := strings.concatenate({head, "\touter: for item in items {\n\t\tswitch item {\n\t\tcase 1:\n\t\t\tbreak outer\n\t\t}\n\t}\n}"}, context.temp_allocator)
	load(&app, sw)
	if focus_text(t, &app, line_with(&app, "outer: for"), "outer") do delete_selected(&app)
	testing.expect_value(t, src(&app), sw)
	// LT+A rename: the jumps follow.
	load(&app, nested)
	h = line_with(&app, "outer: for")
	for f, i in app.doc.nodes[h].fields do if f.kind == LABEL_KIND { set_field_text(&app, h, i, "top"); break }
	out = src(&app)
	testing.expectf(t, strings.contains(out, "top: for") && strings.contains(out, "break top") && !strings.contains(out, "outer"), "renamed:\n%s", out)
	odin_check(t, "fix_rename_label", out)
}

// #8 / #9: #unroll only over constants.
@(test)
test_fix_unroll_constants :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	// (A local `N :: 3` loads as plain text, not a name Reference offers: these are file-scope.)
	load(&app, "package main\n\nN :: 3\n\nTEXT :: \"hi\"\n\nmain :: proc() {\n\tcount := 3\n\ttext := \"hello\"\n}")
	end := len(app.doc.nodes) - 1
	add_at(t, &app, end, "Loops", "#unroll for")
	back_out(&app)
	u := line_with(&app, "#unroll for")
	if open_dot(t, &app, u, 0) && pick(t, &app, "Reference") && ref_choose(t, &app, "count") {
		testing.expect(t, dimmed(t, &app, "count"), "count := 3 isn't constant")
	}
	back_out(&app)
	if open_dot(t, &app, u, 0) && pick(t, &app, "Reference") && ref_choose(t, &app, "N") {
		testing.expect(t, !dimmed(t, &app, "N"), "N :: 3 is")
		pick(t, &app, "N")
	}
	back_out(&app)
	testing.expect_value(t, line_src(&app, u), "#unroll for i in 0..<N {")
	// Change iterable: a string variable is dimmed, a constant string isn't.
	if y_on(t, &app, u, "for") && pick(t, &app, "Change iterable") && pick(t, &app, "Reference") {
		if ref_choose(t, &app, "text") do testing.expect(t, dimmed(t, &app, "text"), "text := \"hello\" isn't constant")
		update(&app, Input{cancel = true})
		if ref_choose(t, &app, "TEXT") do testing.expect(t, !dimmed(t, &app, "TEXT"), "TEXT :: \"hi\" is")
	}
	back_out(&app)
	testing.expect_value(t, line_src(&app, u), "#unroll for i in 0..<N {")

	base := "package main\n\nmain :: proc() {\n\tcount := 3\n\ttext := \"hello\"\n\tTEXT :: \"hi\"\n"
	cases := [?]struct { loop: string, dim: bool }{
		{"for i in 0..<count {", true},
		{"for i in 0..<4 {", false},
		{"for c in text {", true},
		{"for c in TEXT {", false},
	}
	for c in cases {
		load(&app, strings.concatenate({base, "\t", c.loop, "\n\t}\n}"}, context.temp_allocator))
		l := line_with(&app, c.loop)
		if !y_on(t, &app, l, "for") do continue
		testing.expectf(t, dimmed(t, &app, "Add #unroll") == c.dim, "%q: Add #unroll dimmed should be %v", c.loop, c.dim)
		if !c.dim {
			pick(t, &app, "Add #unroll")
			back_out(&app)
			odin_check(t, "fix_unroll_ok", src(&app))
		}
		back_out(&app)
	}
}

// #11 / #12: compound operators: every one Odin has, dimmed by the target's type.
@(test)
test_fix_assign_ops :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\nmain :: proc() {\n\tratio: f32 = 1\n\tratio *= 2\n\ts := \"a\"\n\ts = \"b\"\n\tb := true\n\tb = false\n\tn := 7\n\tn %%= 3\n\tb &&= false\n\tb ||= true\n\tn += 1\n}"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	op_field :: proc(app: ^App, ni: int) -> int {
		for f, i in app.doc.nodes[ni].fields do if !f.slot && f.kind == ASSIGN_OP_KIND do return i
		return -1
	}
	for l in ([]string{"n %%= 3", "b &&= false", "b ||= true"}) {
		ni := line_with(&app, l)
		testing.expectf(t, ni >= 0 && op_field(&app, ni) >= 0, "%q has an operator part", l)
	}
	y_op :: proc(t: ^testing.T, app: ^App, line: string) -> bool {
		back_out(app)
		ni := line_with(app, line)
		fi := op_field(app, ni)
		if !testing.expectf(t, fi >= 0, "%q: no operator", line) do return false
		focus_field_index(app, ni, fi)
		change_selected(app)
		return testing.expect(t, app.state == .Radial, "operator menu")
	}
	if y_op(t, &app, "ratio *= 2") {
		for op in ([]string{"%=", "|=", "<<=", "%%=", "&&="}) do testing.expectf(t, dimmed(t, &app, op), "%s on a f32", op)
		for op in ([]string{"+=", "=", "/="}) do testing.expectf(t, !dimmed(t, &app, op), "%s on a f32", op)
	}
	if y_op(t, &app, "s = \"b\"") do testing.expect(t, dimmed(t, &app, "+="), "+= on a string variable")
	if y_op(t, &app, "b = false") {
		testing.expect(t, !dimmed(t, &app, "|=") && !dimmed(t, &app, "||="), "|= ||= on a bool")
		testing.expect(t, dimmed(t, &app, "+="), "+= on a bool")
		pick(t, &app, "||=")
	}
	back_out(&app)
	testing.expect(t, line_with(&app, "b ||= false") >= 0, "Y > ||=")
	if y_op(t, &app, "n += 1") {
		testing.expect(t, !dimmed(t, &app, "%%="), "%%= on an int")
		pick(t, &app, "%%=")
	}
	back_out(&app)
	testing.expect(t, line_with(&app, "n %%= 1") >= 0, "Y > %%=")
	odin_check(t, "fix_assign_ops", src(&app))
	// Inserted from the Assignment group; its target picked with Reference is dimmed by type.
	add_at(t, &app, len(app.doc.nodes) - 1, "Assignment", "%%=")
	back_out(&app)
	ni := line_with(&app, "%%= ")
	for k := ni; k >= 0 && k < len(app.doc.nodes); k = line_with(&app, "%%= ", k + 1) {
		if has_slot_in(app.doc.nodes[k]) { ni = k; break }
	}
	if !testing.expectf(t, ni >= 0 && has_slot_in(app.doc.nodes[ni]), "a `● %%%%= ●` line:\n%s", src(&app)) do return
	for f, i in app.doc.nodes[ni].fields do if f.editable && !f.slot { focus_field_index(&app, ni, i); break }
	change_selected(&app)
	if app.ref_pick_active && ref_choose(t, &app, "ratio") do testing.expect(t, dimmed(t, &app, "ratio"), "%%= can't take a f32 target")
	back_out(&app)
}

// #13: the index of an enumerated array is the enum.
@(test)
test_fix_enum_array_loop_index :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\nDir :: enum {\n\tN,\n\tS,\n}\n\nM :: 4\n\nmain :: proc() {\n\tea: [Dir]int\n\ta4: [4]int\n\tam: [M]int\n" +
		"\tfor v, d in ea {\n\t\tx: Dir = d\n\t\t_ = x\n\t}\n\tfor v, k in a4 {\n\t\ty := k\n\t\t_ = y\n\t}\n\tfor v, k in am {\n\t\tz := k\n\t\t_ = z\n\t}\n}"
	load(&app, text)
	testing.expect_value(t, type_at(&app, line_with(&app, "x: Dir = d"), "d"), "Dir")
	testing.expect_value(t, type_at(&app, line_with(&app, "x: Dir = d"), "v"), "int")
	testing.expect_value(t, type_at(&app, line_with(&app, "y := k"), "k"), "int")
	testing.expect_value(t, type_at(&app, line_with(&app, "z := k"), "k"), "int")
	odin_check(t, "fix_enum_array_loop", text)
}

// #14: a loop header with a trailing comment still declares its variables and is a loop.
@(test)
test_fix_comment_loop_header :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\nmain :: proc() {\n\tarr: [3]int\n\tfor x in arr { // walk\n\t\ty := 1\n\t}\n}"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	body := line_with(&app, "y := 1")
	testing.expect_value(t, type_at(&app, body, "x"), "int")
	testing.expect(t, jump_scope(&app, body).in_loop, "inside a loop")
}

// #15: a loaded `x = f(...)` has an operator Y can change.
@(test)
test_fix_loaded_call_assignment_op :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\nfoo :: proc(a: int) -> int {\n\treturn a\n}\n\nmain :: proc() {\n\tcount := 0\n\tcount = foo(1)\n}"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	ni := line_with(&app, "count = foo")
	op := -1
	for f, i in app.doc.nodes[ni].fields do if !f.slot && f.kind == ASSIGN_OP_KIND { op = i; break }
	if !testing.expect(t, op >= 0, "an operator part") do return
	focus_field_index(&app, ni, op)
	change_selected(&app)
	pick(t, &app, "+=")
	back_out(&app)
	testing.expect_value(t, line_src(&app, ni), "count += foo(1)")
	odin_check(t, "fix_call_assign_op", src(&app))
}

// #17: one-line blocks are split by format_doc; their names are scoped.
@(test)
test_fix_one_line_blocks_split :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\nPlayer :: struct {\n\thp: int,\n}\n\nmain :: proc() {\n\tx := 0\n\tm: map[string]int\n" +
		"\tfor i in 0..<3 { x += i }\n" +
		"\tif v, ok := m[\"k\"]; ok { x = v } else { x = 1 }\n" +
		"\tp := Player{hp = 1}\n" +
		"\tf := proc() { }\n" +
		"\tx = 2\n}"
	load(&app, text)
	testing.expect_value(t, src(&app), text) // loading alone keeps them
	format_doc(&app)
	out := strings.clone(src(&app), context.temp_allocator)
	want := "package main\n\nPlayer :: struct {\n\thp: int,\n}\n\nmain :: proc() {\n\tx := 0\n\tm: map[string]int\n" +
		"\tfor i in 0..<3 {\n\t\tx += i\n\t}\n" +
		"\tif v, ok := m[\"k\"]; ok {\n\t\tx = v\n\t} else {\n\t\tx = 1\n\t}\n" +
		"\tp := Player{hp = 1}\n" +
		"\tf := proc() { }\n" +
		"\tx = 2\n}"
	testing.expect_value(t, out, want)
	testing.expect_value(t, type_at(&app, line_with(&app, "x += i"), "i"), "int")
	testing.expect_value(t, type_at(&app, line_with(&app, "x = 1"), "ok"), "bool")
	testing.expect_value(t, type_at(&app, line_with(&app, "x = 2"), "i"), "<unknown>")
	testing.expect_value(t, type_at(&app, line_with(&app, "x = 2"), "v"), "<unknown>")
	_, lok := loop_hdr(app.doc.nodes[line_with(&app, "for i in")])
	_, bok := br_line_at(&app, line_with(&app, "if v, ok"))
	testing.expect(t, lok && bok, "the headers are structured")
	format_doc(&app)
	testing.expect_value(t, src(&app), out)
	load(&app, out)
	testing.expect_value(t, src(&app), out)
	odin_check(t, "fix_one_line_blocks", out)
}

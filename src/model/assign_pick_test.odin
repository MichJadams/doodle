package model

// Assignment picks a declared name to assign to (field_access.odin
// assign_pick_start): no made-up names - Odin assigns only to what exists.

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

SRC :: "package main\n\nLIMIT :: 5\n\nhelper :: proc() {\n}\n\nmain :: proc() {\n\tcount := 0\n\tratio: f32 = 1\n}"

// Add a statement at the green dot before main's closing brace.
@(private = "file")
add_statement :: proc(t: ^testing.T, app: ^App, group, leaf: string, loc := #caller_location) {
	closing := -1
	for n, i in app.doc.nodes do if strings.trim_space(node_text(n, context.temp_allocator)) == "}" do closing = i
	focus_dot_at(app, closing)
	update(app, Input{confirm = true})
	if pick(t, app, group, loc) do pick(t, app, leaf, loc)
}

@(private = "file")
under_cursor :: proc(app: ^App) -> string {
	ni, fi, ok := editor_target(app)
	if !ok do return ""
	return app.doc.nodes[ni].fields[fi].text
}

@(test)
test_assignment_picks_a_declared_name :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	add_statement(t, &app, "Assignment", "Assignment")
	testing.expect(t, app.ref_pick_active, "picking the target right away")
	testing.expect_value(t, under_cursor(&app), "ratio") // the nearest declared name above
	// Only variables: not the constant, the procedures.
	names := make([dynamic]string, context.temp_allocator)
	for c in ref_candidates(&app) do append(&names, app.doc.nodes[c.ni].fields[c.fi].text)
	joined := strings.join(names[:], " ", context.temp_allocator)
	testing.expectf(t, strings.contains(joined, "count") && strings.contains(joined, "ratio") && !strings.contains(joined, "LIMIT") && !strings.contains(joined, "helper") && !strings.contains(joined, "main"), "candidates: %s", joined)

	update(&app, Input{up = true}) // previous name: count
	testing.expect_value(t, under_cursor(&app), "count")
	update(&app, Input{confirm = true})
	testing.expect_value(t, current_view(&app).title, "Assign to")
	pick(t, &app, "count")
	ni := -1
	for n, i in app.doc.nodes do if strings.trim_space(node_text(n, context.temp_allocator)) == "count =" do ni = i
	if !testing.expect(t, ni >= 0, "count = ●") do return
	for f in app.doc.nodes[ni].fields do if f.slot && f.kind == "value" do testing.expect_value(t, f.hint, "int") // typed from count
	testing.expect(t, !app.assign_pick_new, "done picking")
}

@(test)
test_assignment_cancel_takes_the_line_away :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	before := strings.clone(file_text(&app, context.temp_allocator), context.temp_allocator)
	add_statement(t, &app, "Assignment", "+=")
	testing.expect(t, app.ref_pick_active, "+= picks its target too")
	update(&app, Input{cancel = true}) // B
	testing.expect(t, !app.ref_pick_active && !app.assign_pick_new, "not picking")
	testing.expect_value(t, file_text(&app, context.temp_allocator), before)
}

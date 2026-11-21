package model

import "core:strings"
import "core:testing"

@(private = "file")
SRC :: "package main\n\nimport win \"core:sys/windows\"\n\n" +
	"MAX_HP :: 100\n\n" +                          // 4: constant
	"Player :: struct {\n\tname: string,\n}\n\n" + // 6-8: struct (its field isn't a name to pick)
	"greet :: proc(who: string, times: int) {\n" + // 10: proc + params
	"\tcount := 5\n" +                             // 11: local
	"\tlabel: string = \"hi\"\n" +                 // 12: typed local
	"\twin.MessageBoxW(nil, , , 0)\n" +           // 13: dots to fill
	"}"

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

// Open the fill menu on the nth value dot of line ni.
@(private = "file")
open_dot :: proc(app: ^App, ni, nth: int) {
	seen := 0
	for f, i in app.doc.nodes[ni].fields {
		if f.slot && f.kind == "value" {
			if seen == nth { focus_field_index(app, ni, i); break }
			seen += 1
		}
	}
	update(app, Input{confirm = true})
}

@(private = "file")
cursor_name :: proc(app: ^App) -> string {
	ni, fi, ok := editor_target(app)
	if !ok do return "<none>"
	return app.doc.nodes[ni].fields[fi].text
}

@(test)
test_loaded_names_are_pickable :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	doc_from_source(&app, SRC)
	app.slot_ni = 13 // for a dot in greet (locals are only offered where they're in scope)
	names := make([dynamic]string, context.temp_allocator)
	for c in ref_candidates(&app) do append(&names, app.doc.nodes[c.ni].fields[c.fi].text)
	testing.expect_value(t, strings.join(names[:], " ", context.temp_allocator), "MAX_HP Player greet who times count label")
	// Loading still round-trips these lines exactly.
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), SRC)
}

@(test)
test_reference_picks_a_name_from_the_file :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	open_dot(&app, 13, 0) // lpText
	testing.expect_value(t, app.state, State.Radial)
	testing.expect(t, pick(&app, "Reference"))

	// Back in the file, on the nearest name above the dot.
	testing.expect_value(t, app.state, State.Editor)
	testing.expect(t, app.ref_pick_active)
	testing.expect_value(t, cursor_name(&app), "label")
	update(&app, Input{left = true})
	testing.expect_value(t, cursor_name(&app), "count")
	update(&app, Input{up = true}) // the previous line with names: greet's
	testing.expect_value(t, cursor_name(&app), "greet")
	update(&app, Input{right = true})
	testing.expect_value(t, cursor_name(&app), "who")
	update(&app, Input{confirm = true})
	testing.expect_value(t, app.state, State.Radial) // "Pass as"
	testing.expect_value(t, current_view(&app).title, "Pass as")
	testing.expect(t, pick(&app, "who"))             // the value itself

	testing.expect(t, !app.ref_pick_active)
	line := node_text(app.doc.nodes[13], context.temp_allocator)
	testing.expectf(t, strings.contains(line, "win.MessageBoxW(nil, who, , 0)"), "got %q", line)
	testing.expect_value(t, cursor_name(&app), "who") // the cursor is back on the filled argument
}

@(test)
test_reference_cancel_leaves_dot_empty :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	before := doc_to_source(&app, context.temp_allocator)
	open_dot(&app, 13, 0)
	testing.expect(t, pick(&app, "Reference"))
	update(&app, Input{right = true})
	update(&app, Input{cancel = true}) // B
	testing.expect(t, !app.ref_pick_active)
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), before)
	_, fi, _ := editor_target(&app)
	testing.expect(t, app.doc.nodes[13].fields[fi].slot, "back on the empty dot")
}

@(test)
test_reference_via_y_refill :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	// Y on the filled `0` (uType) -> Reference -> cancel: the 0 comes back.
	for f, i in app.doc.nodes[13].fields do if f.text == "0" { focus_field_index(&app, 13, i); break }
	change_selected(&app)
	testing.expect(t, pick(&app, "Reference"))
	update(&app, Input{cancel = true})
	testing.expect(t, strings.contains(node_text(app.doc.nodes[13], context.temp_allocator), ", 0)"))
	// Again, and pick a name: it replaces the 0.
	for f, i in app.doc.nodes[13].fields do if f.text == "0" { focus_field_index(&app, 13, i); break }
	change_selected(&app)
	testing.expect(t, pick(&app, "Reference"))
	update(&app, Input{confirm = true}) // the name under the cursor: `label`
	testing.expect(t, pick(&app, "label"))
	testing.expectf(t, strings.contains(node_text(app.doc.nodes[13], context.temp_allocator), "win.MessageBoxW(nil, , , label)"),
		"got %q", node_text(app.doc.nodes[13], context.temp_allocator))
}

@(test)
test_reference_dimmed_without_names :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\nimport win \"core:sys/windows\"\nmain :: proc() {\n\twin.MessageBoxW(nil, , , 0)\n}")
	// `main` is the only name; drop it so there's nothing to pick.
	for &f in app.doc.nodes[2].fields do f.editable = false
	open_dot(&app, 3, 0)
	v := current_view(&app)
	for e in v.entries do if e.label == "Reference" do testing.expect(t, e.dim, "nothing to reference")
	testing.expect(t, pick(&app, "Reference"))
	testing.expect(t, !app.ref_pick_active)
	testing.expect_value(t, app.state, State.Editor)
}

// The saved project's error: `text := windows.L(...)` is a [^]u16, and MessageBoxW
// wants an LPCWSTR. "Pass as" offers the conversion; a pointer (&) is grayed.
@(test)
test_pass_as_converts_for_messageboxw :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\nimport \"core:sys/windows\"\nmain :: proc() {\n" +
		"\tbrave_otter := windows.L(\"Testing\")\n" +
		"\twindows.MessageBoxW(nil, brave_otter, brave_otter, windows.MB_OK)\n}")
	// Y on the 2nd argument (lpText) -> Reference -> brave_otter -> Pass as
	for f, i in app.doc.nodes[4].fields do if f.text == "brave_otter" { focus_field_index(&app, 4, i); break }
	change_selected(&app)
	testing.expect(t, pick(&app, "Reference"))
	testing.expect_value(t, cursor_name(&app), "brave_otter")
	update(&app, Input{confirm = true})
	v := current_view(&app)
	labels := make([dynamic]string, context.temp_allocator)
	for e in v.entries do append(&labels, e.label)
	testing.expect_value(t, strings.join(labels[:], " | ", context.temp_allocator),
		"brave_otter | windows.LPCWSTR(brave_otter) | &brave_otter   (pointer to it) | brave_otter^   (what it points to)")
	for e in v.entries do if e.label == "&brave_otter   (pointer to it)" do testing.expect(t, e.dim, "an LPCWSTR isn't a pointer to a variable")

	// B goes back to picking; A again, and take the conversion.
	update(&app, Input{cancel = true})
	testing.expect(t, app.ref_pick_active && app.state == .Editor)
	update(&app, Input{confirm = true})
	testing.expect(t, pick(&app, "windows.LPCWSTR(brave_otter)"))
	// (Now over 80 columns, so it's saved one argument per line.)
	testing.expectf(t, strings.contains(doc_to_source(&app, context.temp_allocator),
		"\twindows.MessageBoxW(\n\t\tnil,\n\t\twindows.LPCWSTR(brave_otter),\n\t\tbrave_otter,\n\t\twindows.MB_OK,\n\t)"),
		"got:\n%s", doc_to_source(&app, context.temp_allocator))
}

// The saved project as written (no indentation, a typed declaration from a call):
// `len(●)` -> Reference must be able to reach `brave_otter`.
@(test)
test_reference_reaches_typed_unindented_local :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	src := "package main\nimport \"core:fmt\"\nimport \"core:sys/windows\"\nmain :: proc() {\n" +
		"brave_otter: windows.LPCWSTR = windows.L(\"Testing\")\n" +
		"fmt.println(\"This is a test\")\n" +
		"len()\n\n}"
	doc_from_source(&app, src)
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), src) // still round-trips
	app.slot_ni = 6 // for the dot in len(●)
	names := make([dynamic]string, context.temp_allocator)
	for c in ref_candidates(&app) do append(&names, app.doc.nodes[c.ni].fields[c.fi].text)
	testing.expect_value(t, strings.join(names[:], " ", context.temp_allocator), "main brave_otter")

	open_dot(&app, 6, 0) // len(●)
	testing.expect(t, pick(&app, "Reference"))
	testing.expect(t, app.ref_pick_active)
	testing.expect_value(t, cursor_name(&app), "brave_otter")
	update(&app, Input{up = true})
	testing.expect_value(t, cursor_name(&app), "main")
	update(&app, Input{down = true})
	testing.expect_value(t, cursor_name(&app), "brave_otter")
	update(&app, Input{confirm = true})
	testing.expect(t, pick(&app, "brave_otter"))
	testing.expectf(t, strings.contains(doc_to_source(&app, context.temp_allocator), "len(brave_otter)"),
		"got:\n%s", doc_to_source(&app, context.temp_allocator))
}

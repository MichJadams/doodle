package model

import "core:strings"
import "core:testing"

@(private = "file")
SRC :: "package main\nimport \"core:fmt\"\nimport \"core:sys/windows\"\nmain :: proc() {\n" +
	"\tbrave_otter := windows.L(\"Testing\")\n" + // 4
	"\tlabel: string = \"hi\"\n" +               // 5
	"\tcount := 5\n" +                           // 6
	"\twindows.MessageBoxW(nil, brave_otter, brave_otter, windows.MB_OK)\n" +
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

@(private = "file")
pick_leaf :: proc(app: ^App, label: string) -> bool {
	path_to :: proc(es: []Entry, label: string, out: ^[dynamic]string) -> bool {
		for e in es {
			append(out, e.label)
			if len(e.children) == 0 && e.label == label do return true
			if len(e.children) > 0 && path_to(e.children, label, out) do return true
			pop(out)
		}
		return false
	}
	p := make([dynamic]string, context.temp_allocator)
	if !path_to(current_view(app).entries, label, &p) do return false
	for step in p do if !pick(app, step) do return false
	return true
}

// Put the cursor on the declaration operator of line ni and press Y.
@(private = "file")
y_on_operator :: proc(app: ^App, ni: int) {
	for f, i in app.doc.nodes[ni].fields do if f.kind == "decl" { focus_field_index(app, ni, i); break }
	change_selected(app)
}

@(private = "file")
line :: proc(app: ^App, ni: int) -> string { return node_text(app.doc.nodes[ni], context.temp_allocator) }

@(test)
test_operator_is_highlightable :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	doc_from_source(&app, SRC)
	n := app.doc.nodes[4]
	labels := make([dynamic]string, context.temp_allocator)
	for u in line_leaves(n) do append(&labels, fields_text(n, u.fa, u.fb))
	testing.expect_value(t, strings.join(labels[:], " | ", context.temp_allocator), "brave_otter |  :=  | L | \"Testing\"")
}

// The saved project: declare brave_otter as a windows.LPCWSTR.
@(test)
test_declare_with_a_type :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	y_on_operator(&app, 4)
	testing.expect_value(t, app.state, State.Radial)
	testing.expect_value(t, current_view(&app).title, "Declare as")
	labels := make([dynamic]string, context.temp_allocator)
	for e in current_view(&app).entries do append(&labels, e.label)
	testing.expect_value(t, strings.join(labels[:], " | ", context.temp_allocator),
		"brave_otter := value   (type inferred) | brave_otter: type = value   (choose the type) | brave_otter :: value   (constant)")

	testing.expect(t, pick(&app, "brave_otter: type = value   (choose the type)"))
	testing.expect_value(t, line(&app, 4), "\tbrave_otter:  = windows.L(\"Testing\")") // `: ` + a type dot (no text) + ` = `
	testing.expect_value(t, app.state, State.Radial) // straight into choosing the type
	testing.expect(t, pick(&app, "Type"))
	testing.expect(t, pick(&app, "windows."))
	testing.expect(t, pick_leaf(&app, "LPCWSTR"))
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, line(&app, 4), "\tbrave_otter: windows.LPCWSTR = windows.L(\"Testing\")")
}

@(test)
test_back_to_inferred_and_constant :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, SRC)
	// A loaded typed declaration -> inferred.
	y_on_operator(&app, 5)
	testing.expect(t, pick(&app, "label := value   (type inferred)"))
	testing.expect_value(t, line(&app, 5), "\tlabel := \"hi\"")
	// -> constant -> back to inferred.
	y_on_operator(&app, 6)
	testing.expect(t, pick(&app, "count :: value   (constant)"))
	testing.expect_value(t, line(&app, 6), "\tcount :: 5")
	y_on_operator(&app, 6)
	testing.expect(t, pick(&app, "count := value   (type inferred)"))
	testing.expect_value(t, line(&app, 6), "\tcount := 5")
	// B in "Declare as" changes nothing.
	before := doc_to_source(&app, context.temp_allocator)
	y_on_operator(&app, 6)
	update(&app, Input{cancel = true})
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, doc_to_source(&app, context.temp_allocator), before)
}

@(test)
test_menu_built_declaration_forms :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\nmain :: proc() {\n}")
	body: Node
	append(&body.fields, Field{strings.clone("\t"), false, false, "", "", ""})
	append(&body.fields, Field{"", false, true, "body", "", ""})
	inject_at(&app.doc.nodes, 2, body)
	make_body_statement(&app, 2, 1, "__stmt_decl__") // name := ●
	y_on_operator(&app, 2)
	testing.expect(t, pick_leaf(&app, strings.concatenate({app.doc.nodes[2].fields[1].text, ": type = value   (choose the type)"}, context.temp_allocator)))
	testing.expect(t, pick(&app, "Type"))
	testing.expect(t, pick(&app, "int"))
	testing.expectf(t, strings.has_suffix(line(&app, 2), ": int = "), "got %q", line(&app, 2)) // name: int = ●
	y_on_operator(&app, 2)
	testing.expect(t, pick_leaf(&app, strings.concatenate({app.doc.nodes[2].fields[1].text, " := value   (type inferred)"}, context.temp_allocator)))
	testing.expectf(t, strings.has_suffix(line(&app, 2), " := "), "got %q", line(&app, 2)) // name := ●
	dots := 0
	for f in app.doc.nodes[2].fields do if f.slot do dots += 1
	testing.expect_value(t, dots, 1) // the value dot survived
}

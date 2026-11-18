package model

import "core:strings"
import "core:testing"

// A doc with imports + a proc whose body is a single empty body slot (node index returned).
@(private = "file")
setup_call_doc :: proc(app: ^App) -> (body_ni: int) {
	app.state = .Editor
	doc_from_source(app, "package main\n\nimport win \"core:sys/windows\"\nimport \"core:fmt\"\n\nmain :: proc() {\n}")
	body: Node
	append(&body.fields, Field{strings.clone("\t"), false, false, "", "", ""})
	append(&body.fields, Field{"", false, true, "body", "", ""})
	inject_at(&app.doc.nodes, 6, body)
	return 6
}

@(private = "file")
cleanup_calls :: proc(app: ^App) {
	clear_nav(app)
	delete(app.nav)
	doc_reset(app)
	delete(app.doc.nodes)
	delete(app.recent_imports)
	free_menus(app)
}

// Put the cursor on fields[fi] of node ni (must be an editable field or slot).
@(private = "file")
focus_field :: proc(app: ^App, ni, fi: int) {
	focus_line(app, ni)
	k := 0
	for f, i in app.doc.nodes[ni].fields {
		if i == fi do break
		if f.editable || f.slot do k += 1
	}
	app.editor_field = k
}

@(private = "file")
count_slots :: proc(n: Node, kind: string) -> int {
	c := 0
	for f in n.fields do if f.slot && f.kind == kind do c += 1
	return c
}

@(private = "file")
first_slot :: proc(n: Node, kind: string) -> int {
	for f, i in n.fields do if f.slot && f.kind == kind do return i
	return -1
}

// Pick an entry by label in the current menu view (drills into groups too).
@(private = "file")
pick :: proc(app: ^App, label: string) {
	v := current_view(app)
	for e, i in v.entries {
		if e.label == label {
			v.index = i
			update(app, Input{confirm = true})
			return
		}
	}
}

@(test)
test_param_arity :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, params: string, want_req: int, want_var: bool) {
		req, variadic := param_arity(params)
		testing.expectf(t, req == want_req && variadic == want_var,
			"param_arity(%q) = (%d, %v), want (%d, %v)", params, req, variadic, want_req, want_var)
	}
	check(t, "", 0, false)
	check(t, "hWnd: HWND, lpText: LPCWSTR, lpCaption: LPCWSTR, uType: UINT", 4, false)
	check(t, "args: ..any, sep := \" \", flush := true", 0, true)
	check(t, "fmt: string, args: ..any, flush := true", 1, true)
	check(t, "a, b: int", 2, false)
	check(t, "x: int, y: f32 = 1.0", 1, false)
	check(t, "m: map[string]int, f: proc(a, b: int) -> int", 2, false) // nested commas
	check(t, "s := \"a, b\"", 0, false)                                  // comma inside a string
	check(t, "#c_vararg args: ..any", 0, true)
	check(t, "a: int, ", 1, false) // trailing comma / unfilled params slot
}

@(test)
test_call_arity_sources :: proc(t: ^testing.T) {
	app: App
	defer cleanup_calls(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nimport win \"core:sys/windows\"\nimport \"core:fmt\"\n\nhelper :: proc(a: int, b: string) -> int {\n}")

	req, variadic := call_arity(&app, "win", "MessageBoxW") // via the alias
	testing.expect(t, req == 4 && !variadic, "MessageBoxW takes 4 args")
	req, variadic = call_arity(&app, "fmt", "println")
	testing.expect(t, req == 0 && variadic, "println: any number of args")
	req, variadic = call_arity(&app, "fmt", "printf")
	testing.expect(t, req == 1 && variadic, "printf: format + any number of args")
	req, variadic = call_arity(&app, "", "helper") // declared in this file
	testing.expect(t, req == 2 && !variadic, "helper takes 2 args")
	req, variadic = call_arity(&app, "", "append") // built-in
	testing.expect(t, req == 2 && variadic, "append(&arr, x, ...)")
	req, variadic = call_arity(&app, "", "nope_not_a_proc")
	testing.expect(t, req == 0 && variadic, "unknown proc: any number of args")
}

@(test)
test_messageboxw_call_has_four_arg_dots :: proc(t: ^testing.T) {
	app: App
	defer cleanup_calls(&app)
	ni := setup_call_doc(&app)
	make_import_proc_call(&app, ni, 1, "win", "MessageBoxW")
	n := app.doc.nodes[ni]
	testing.expect_value(t, count_slots(n, "value"), 4)
	testing.expect_value(t, count_slots(n, "args"), 0)
	testing.expect_value(t, node_text(n, context.temp_allocator), "\twin.MessageBoxW(, , , )")
}

@(test)
test_println_keeps_offering_arg_dots :: proc(t: ^testing.T) {
	app: App
	defer cleanup_calls(&app)
	ni := setup_call_doc(&app)
	make_import_proc_call(&app, ni, 1, "fmt", "println")
	testing.expect_value(t, count_slots(app.doc.nodes[ni], "value"), 0)
	testing.expect_value(t, count_slots(app.doc.nodes[ni], "args"), 1)

	// Unfilled: saves as a plain call with no args.
	src := doc_to_source(&app, context.temp_allocator)
	testing.expect(t, strings.contains(src, "\tfmt.println()\n"), "unfilled println saves as fmt.println()")

	// Fill the green dot with a string: a new green dot appears after it.
	focus_field(&app, ni, first_slot(app.doc.nodes[ni], "args"))
	update(&app, Input{confirm = true})
	testing.expect_value(t, app.state, State.Radial)
	pick(&app, "String")
	pick(&app, "\"...\"  string")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, count_slots(app.doc.nodes[ni], "args"), 1)

	// Fill the new green dot with a number: still one green dot, now after "0".
	focus_field(&app, ni, first_slot(app.doc.nodes[ni], "args"))
	update(&app, Input{confirm = true})
	pick(&app, "Number")
	testing.expect_value(t, count_slots(app.doc.nodes[ni], "args"), 1)
	testing.expect_value(t, node_text(app.doc.nodes[ni], context.temp_allocator), "\tfmt.println(\"\", 0, )")

	// Saved source drops the trailing unfilled green dot.
	src = doc_to_source(&app, context.temp_allocator)
	testing.expect(t, strings.contains(src, "\tfmt.println(\"\", 0)\n"), "saved call has exactly the filled args")
}

@(test)
test_printf_has_format_dot_then_green_dot :: proc(t: ^testing.T) {
	app: App
	defer cleanup_calls(&app)
	ni := setup_call_doc(&app)
	make_import_proc_call(&app, ni, 1, "fmt", "printf")
	n := app.doc.nodes[ni]
	testing.expect_value(t, count_slots(n, "value"), 1)
	testing.expect_value(t, count_slots(n, "args"), 1)
	testing.expect(t, first_slot(n, "value") < first_slot(n, "args"), "required arg comes before the green dot")
}

@(test)
test_builtin_len_call_has_one_dot :: proc(t: ^testing.T) {
	app: App
	defer cleanup_calls(&app)
	ni := setup_call_doc(&app)
	make_call_this_package(&app, ni, 1, "len")
	testing.expect_value(t, count_slots(app.doc.nodes[ni], "value"), 1)
	testing.expect_value(t, count_slots(app.doc.nodes[ni], "args"), 0)
	testing.expect_value(t, node_text(app.doc.nodes[ni], context.temp_allocator), "\tlen()")
}

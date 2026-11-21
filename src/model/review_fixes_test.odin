package model

// Regression tests for the review findings fixed after the four-feature merge
// (packages, types, compile-time control / modifiers, field access / struct
// literals, and the Handmade Hero acceptance run). Each test names its finding.

import "core:strings"
import "core:testing"
import "core:time"

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
	app.os_name = "windows"
	doc_from_source(app, text)
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
find_entry :: proc(entries: []Entry, label: string) -> (Entry, bool) {
	for e in entries {
		if e.label == label do return e, true
		if r, ok := find_entry(e.children, label); ok do return r, true
	}
	return {}, false
}

@(private = "file")
any_label_prefix :: proc(entries: []Entry, prefix: string) -> bool {
	for e in entries {
		if strings.has_prefix(e.label, prefix) do return true
		if any_label_prefix(e.children, prefix) do return true
	}
	return false
}

@(private = "file")
any_leaf :: proc(entries: []Entry, label: string) -> bool {
	for e in entries {
		if len(e.children) == 0 && e.label == label do return true
		if any_leaf(e.children, label) do return true
	}
	return false
}

// Focus the first field of line ni whose text is `text` (from field `from`).
@(private = "file")
focus_text :: proc(app: ^App, ni: int, text: string, from := 0) -> bool {
	if ni < 0 do return false
	for f, i in app.doc.nodes[ni].fields do if i >= from && f.text == text {
		focus_field_index(app, ni, i)
		return true
	}
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
field_names :: proc(fs: []Struct_Field) -> string {
	out := make([dynamic]string, context.temp_allocator)
	for f in fs do append(&out, f.name)
	return strings.join(out[:], " ", context.temp_allocator)
}

// ---- #1 / #2: `_` fields and fields promoted from anonymous `using _` ----

@(test)
test_review_no_underscore_fields_and_promoted_ones :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nimport win32 \"core:sys/windows\"\nimport sdl \"vendor:sdl2\"\n\nmain :: proc() {\n\tinp := win32.INPUT{}\n\tev := sdl.KeyboardEvent{}\n}")
	W :: "core:sys/windows"
	testing.expect_value(t, field_names(struct_fields(&app, Var_Type{"INPUT", W})), "type mi ki hi")
	testing.expect_value(t, field_names(struct_fields(&app, Var_Type{"OVERLAPPED", W})), "Internal InternalHigh Offset OffsetHigh OffsetFull hEvent")
	dcb := struct_fields(&app, Var_Type{"DCB", W})
	found_bin, found_dtr := false, false
	for f in dcb {
		testing.expect(t, f.name != "_", "DCB lists no `_`")
		if f.name == "fBinary" do found_bin = true
		if f.name == "fDtrControl" { found_dtr = true; testing.expect_value(t, f.type.expr, "DTR_Control") }
	}
	testing.expect(t, found_bin && found_dtr, "DCB's bit_field members are listed")
	for f in struct_fields(&app, Var_Type{"KeyboardEvent", "vendor:sdl2"}) do testing.expect(t, f.name != "_", "KeyboardEvent padding isn't listed")

	// The literal's fields dot never offers `_`.
	for text in ([]string{"win32.INPUT", "sdl.KeyboardEvent"}) {
		ni := line_with(&app, text)
		dot := -1
		for f, i in app.doc.nodes[ni].fields do if f.slot && f.kind == FIELDS_KIND do dot = i
		if !testing.expectf(t, dot >= 0, "%s{} has a fields dot", text) do continue
		menu := build_lit_field_menu(&app, ni, dot)
		defer free_entries(menu)
		testing.expectf(t, !any_label_prefix(menu, "_ "), "%s: no `_` field offered", text)
		if text == "win32.INPUT" do testing.expect(t, any_label_prefix(menu, "mi "), "INPUT offers mi")
	}
}

// ---- #3: vendor:glfw re-exports are procedures ----

@(test)
test_review_glfw_reexports_are_procs :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nimport \"vendor:glfw\"\nimport img \"vendor:sdl2/image\"\n")
	calls := build_call_children(&app)
	defer free_entries(calls)
	testing.expect(t, any_leaf(calls, "CreateWindow"), "glfw.CreateWindow is callable")
	testing.expect(t, any_leaf(calls, "PollEvents"), "glfw.PollEvents is callable")
	types := build_type_entries(&app)
	defer free_entries(types)
	testing.expect(t, !any_leaf(types, "CreateWindow"), "glfw.CreateWindow isn't a type")
	sig := call_signature(&app, "glfw", "CreateWindow")
	testing.expect(t, sig.known && sig.req == 5, "CreateWindow takes 5 arguments")
	sig = call_signature(&app, "img", "GetError")
	testing.expect(t, sig.known, "sdl2/image GetError is a procedure")
}

// ---- #4: runtime.X inside core packages resolves to base:runtime ----

@(test)
test_review_runtime_types_in_core_packages :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nimport \"core:bufio\"\n\nmain :: proc() {\n\tr: bufio.Reader\n\tx := r.buf_allocator.data\n}")
	alloc: Var_Type
	for f in struct_fields(&app, Var_Type{"Reader", "core:bufio"}) do if f.name == "buf_allocator" do alloc = f.type
	testing.expect_value(t, alloc.expr, "runtime.Allocator")
	testing.expect_value(t, field_names(struct_fields(&app, alloc)), "procedure data")
	ty, ok := var_type_at(&app, line_with(&app, "x :=") + 1, "x")
	testing.expect(t, ok && ty.expr == "rawptr", "r.buf_allocator.data is a rawptr")
}

// ---- #5: graying a value dot's Struct literal entries stays fast ----

@(test)
test_review_struct_literal_graying_is_fast :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nimport win32 \"core:sys/windows\"\nimport sdl \"vendor:sdl2\"\nimport vk \"vendor:vulkan\"\n\nmain :: proc() {\n\tr: win32.RECT = q\n}")
	ni := line_with(&app, "r: win32.RECT")
	dot := -1
	for f, i in app.doc.nodes[ni].fields do if f.text == " = q" do dot = i
	if !testing.expect(t, dot >= 0, fields_debug(app.doc.nodes[ni])) do return
	delete(app.doc.nodes[ni].fields[dot].text)
	app.doc.nodes[ni].fields[dot] = Field{strings.clone(" = "), false, false, "", "", ""}
	dot += 1
	inject_at(&app.doc.nodes[ni].fields, dot, Field{"", false, true, "value", "", ""})
	sync_typed_decl_value_hint(&app, ni)
	focus_field_index(&app, ni, dot)
	start := time.now()
	update(&app, Input{confirm = true})
	took := time.since(start)
	testing.expectf(t, took < 300 * time.Millisecond, "opening the dot took %v", took)
	e, ok := find_entry(current_view(&app).entries, "Struct literal")
	if testing.expect(t, ok) {
		rect, rok := find_entry(e.children, "RECT")
		point, pok := find_entry(e.children, "POINT")
		testing.expect(t, rok && !rect.dim, "a RECT literal fits")
		testing.expect(t, pok && point.dim, "a POINT literal doesn't")
	}
	back_out(&app)
}

// ---- #6 / #7 / #8 / #22: tables and small helpers ----

@(test)
test_review_import_rows_and_aliases :: proc(t: ^testing.T) {
	has_row :: proc(rows: []CoreRow, path: string) -> bool {
		for r in rows do if r.path == path do return true
		return false
	}
	for p in ([]string{"core:path", "core:odin/format", "core:odin/printer"}) do testing.expectf(t, !has_row(CORE_ROWS[:], p), "%s #panics on import", p)
	testing.expect(t, !has_row(VENDOR_ROWS[:], "vendor:libc"), "vendor:libc #panics on import")
	testing.expect(t, has_row(CORE_ROWS[:], "core:path/filepath") && has_row(CORE_ROWS[:], "core:path/slashpath"))
	testing.expect(t, has_row(VENDOR_ROWS[:], "vendor:libc-shim"))
	testing.expect(t, has_row(CORE_ROWS[:], "core:os"), "core:os panics only on js/wasm")

	testing.expect_value(t, alias_default("shared:my-lib"), "my_lib")
	testing.expect_value(t, alias_default("shared:foo/1.0"), "foo")
	testing.expect_value(t, alias_default("shared:3d"), "_3d")
	testing.expect_value(t, alias_default("core:fmt"), "fmt")
	for p in ([]string{"shared:my-lib", "shared:foo/1.0", "shared:3d"}) do testing.expectf(t, is_ident(alias_default(p)), "%s gets an identifier", p)

	app: App
	defer cleanup(&app)
	testing.expect_value(t, call_signature(&app, "", "min").req, 2)
	testing.expect_value(t, call_signature(&app, "", "max").req, 2)
	testing.expect_value(t, call_signature(&app, "", "swizzle").req, 3)
	_, tilde := builtin_const("ODIN_TILDE")
	testing.expect(t, !tilde, "ODIN_TILDE isn't declared by this Odin")
}

// ---- #10: LT+B on one name of a shared `x, y: f32` ----

@(test)
test_review_delete_shared_member_names :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	cases := [?][3]string{
		{"V :: struct { x, y: f32 }", "y", "V :: struct { x: f32 }"},
		{"V :: struct { x, y: f32 }", "x", "V :: struct { y: f32 }"},
		{"V :: struct { x, y: f32 }", "f32", "V :: struct {}"},
		{"V :: struct { a: int, x, y: f32 }", "f32", "V :: struct { a: int }"},
	}
	for c in cases {
		load(&app, strings.concatenate({"package main\n\n", c[0]}, context.temp_allocator))
		ni := line_with(&app, "V ::")
		testing.expect(t, focus_text(&app, ni, c[1], 1), c[1])
		delete_selected(&app)
		testing.expectf(t, strings.contains(src(&app), c[2]), "LT+B on %s in %s: %q", c[1], c[0], src(&app))
	}
	// Multi-line: `name, title: string,`.
	load(&app, "package main\n\nP :: struct {\n\tname, title: string,\n\thp: int,\n}")
	ni := line_with(&app, "name, title")
	focus_text(&app, ni, "name")
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\nP :: struct {\n\ttitle: string,\n\thp: int,\n}")
	load(&app, "package main\n\nP :: struct {\n\tname, title: string,\n\thp: int,\n}")
	ni = line_with(&app, "name, title")
	focus_text(&app, ni, "title")
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\nP :: struct {\n\tname: string,\n\thp: int,\n}")
	text := strings.clone(src(&app), context.temp_allocator)
	doc_from_source(&app, text)
	testing.expect_value(t, src(&app), text)
}

// ---- #11: adding a member after a last member without a comma ----

@(test)
test_review_add_member_after_no_comma :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nP :: struct {\n\thp: int\n}\n\nD :: enum {\n\tA\n}")
	add :: proc(t: ^testing.T, app: ^App, header, group, leaf: string) {
		h := line_with(app, header)
		body: Node
		append(&body.fields, Field{strings.clone("\t"), false, false, "", "", ""}, Field{"", false, true, "body", "", ""})
		inject_at(&app.doc.nodes, h + 2, body)
		focus_field_index(app, h + 2, 1)
		update(app, Input{confirm = true})
		if leaf == "" { pick(t, app, group); return }
		if pick(t, app, group) do pick(t, app, leaf)
	}
	add(t, &app, "P ::", "Field", "")
	if app.state == .Radial {
		// The field's type.
		v := current_view(&app)
		if e, ok := find_entry(v.entries, "int"); ok { _ = e; pick_path(t, &app, "int") }
	}
	back_out(&app)
	add(t, &app, "D ::", "Member", "")
	back_out(&app)
	out := src(&app)
	testing.expectf(t, strings.contains(out, "\thp: int,\n"), "hp gets its comma: %q", out)
	testing.expectf(t, strings.contains(out, "\tA,\n"), "A gets its comma: %q", out)
	text := strings.clone(out, context.temp_allocator)
	doc_from_source(&app, text)
	testing.expect_value(t, src(&app), text)
}

// Walk down to a leaf by label (first match, depth-first).
@(private = "file")
pick_path :: proc(t: ^testing.T, app: ^App, label: string, loc := #caller_location) {
	path :: proc(entries: []Entry, label: string, out: ^[dynamic]string) -> bool {
		for e in entries {
			append(out, e.label)
			if len(e.children) == 0 && e.label == label do return true
			if len(e.children) > 0 && path(e.children, label, out) do return true
			pop(out)
		}
		return false
	}
	p := make([dynamic]string, context.temp_allocator)
	v := current_view(app)
	if v == nil || !path(v.entries, label, &p) {
		testing.expectf(t, false, "%s not reachable", label, loc = loc)
		return
	}
	for step in p do if !pick(t, app, step, loc) do return
}

// ---- #12: an alias of a document type keeps its structure on reload ----

@(test)
test_review_alias_of_document_type :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\nAlias :: Player\n\nPlayer :: struct {\n\thp: int,\n}\n\nAlias2 :: Alias\n\nX :: 5\n\nY :: X"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	ni := line_with(&app, "Alias :: Player")
	testing.expect_value(t, fields_debug(app.doc.nodes[ni]), "[Alias][ :: ][Player]")
	testing.expect_value(t, app.doc.nodes[ni].fields[2].kind, "type")
	names := doc_type_names(&app)
	has :: proc(names: []string, n: string) -> bool {
		for x in names do if x == n do return true
		return false
	}
	testing.expectf(t, has(names, "Alias") && has(names, "Alias2") && has(names, "Player"), "aliases are types: %v", names)
	testing.expect(t, !has(names, "Y"), "an alias of a constant isn't a type")
}

// ---- #13: the value of `p: ^int = nil` is a leaf ----

@(test)
test_review_composite_typed_value_is_a_leaf :: proc(t: ^testing.T) {
	n: Node
	defer delete(n.fields)
	append(&n.fields,
		Field{"\t", false, false, "", "", ""}, Field{"p", true, false, "", "", ""}, Field{": ", false, false, "decl", "", ""},
		Field{"^", false, false, "", "", ""}, Field{"int", true, false, "type", "", ""},
		Field{" = ", false, false, "", "", ""}, Field{"nil", false, false, "", "", ""})
	testing.expect_value(t, stmt_rhs_start(n), 6)
	found := false
	for u in line_leaves(n) do if n.fields[leaf_primary_field(n, u)].text == "nil" do found = true
	testing.expect(t, found, "nil is a d-pad stop")
}

// ---- #14 / #15 / #21: deleting $T params and one-line members ----

@(test)
test_review_poly_param_delete :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nPair :: struct($K, $V: typeid) {\n\tk: K,\n}")
	ni := line_with(&app, "Pair ::")
	focus_text(&app, ni, "V")
	delete_selected(&app)
	testing.expect_value(t, node_text(app.doc.nodes[ni], context.temp_allocator), "Pair :: struct($K: typeid) {")
	load(&app, "package main\n\nPair :: struct($K, $V: typeid) {\n\tk: K,\n}")
	focus_text(&app, ni, "K")
	delete_selected(&app)
	testing.expect_value(t, node_text(app.doc.nodes[ni], context.temp_allocator), "Pair :: struct($V: typeid) {")

	// The directive stays a keyword field.
	load(&app, "package main\n\nPair :: struct($K: typeid, $V: typeid) #align(8) {\n\tk: K,\n}")
	focus_text(&app, ni, "V")
	delete_selected(&app)
	testing.expect_value(t, node_text(app.doc.nodes[ni], context.temp_allocator), "Pair :: struct($K: typeid) #align(8) {")
	kw := -1
	for f, i in app.doc.nodes[ni].fields do if f.kind == KW && f.text == "#align(" do kw = i
	testing.expect(t, kw >= 0 && app.doc.nodes[ni].fields[kw + 1].editable && app.doc.nodes[ni].fields[kw + 1].text == "8", fields_debug(app.doc.nodes[ni]))

	load(&app, "package main\n\nP :: struct #packed { a: u8, b: u32 }")
	ni = line_with(&app, "P ::")
	focus_text(&app, ni, "a")
	delete_selected(&app)
	testing.expect_value(t, node_text(app.doc.nodes[ni], context.temp_allocator), "P :: struct #packed { b: u32 }")
	kw = -1
	for f, i in app.doc.nodes[ni].fields do if f.kind == KW && f.text == "#packed" do kw = i
	testing.expect(t, kw >= 0, fields_debug(app.doc.nodes[ni]))
}

// ---- #16: an attribute on the type's own line ----

@(test)
test_review_attribute_on_type_line :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\n@(private) Player :: struct {\n\thp: int,\n}\n\n@(private) Grid :: [8]int"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	testing.expect_value(t, fields_debug(app.doc.nodes[line_with(&app, "Player ::")]), "[@(private) ][Player][ :: struct {]")
	names := doc_type_names(&app)
	p, g := false, false
	for n in names { if n == "Player" do p = true; if n == "Grid" do g = true }
	testing.expect(t, p && g, "Player and Grid are types")
}

// ---- #17: LT+B on part of an attributed / when-nested declaration ----

@(test)
test_review_delete_part_of_attributed_declaration :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\n@(private)\nDir :: enum { North, South }\n\nX :: 1")
	focus_text(&app, line_with(&app, "Dir ::"), "South")
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\n@(private)\nDir :: enum { North }\n\nX :: 1")

	load(&app, "package main\n\nwhen ODIN_DEBUG {\n\tDir :: enum { North, South }\n\tY :: 2\n}\n\nX :: 1")
	focus_text(&app, line_with(&app, "Dir ::"), "South")
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\nwhen ODIN_DEBUG {\n\tDir :: enum { North }\n\tY :: 2\n}\n\nX :: 1")

	load(&app, "package main\n\n@(private)\nPair :: struct($K: typeid, $V: typeid) {\n\tk: K,\n}\n\nX :: 1")
	focus_text(&app, line_with(&app, "Pair ::"), "V")
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\n@(private)\nPair :: struct($K: typeid) {\n\tk: K,\n}\n\nX :: 1")

	load(&app, "package main\n\nVec :: struct {\n\tx: int,\n\ty: int,\n}\n\n@(private)\norigin := Vec{x = 1, y = 2}\n\nX :: 1")
	focus_text(&app, line_with(&app, "origin :="), "y")
	delete_selected(&app)
	testing.expectf(t, strings.contains(src(&app), "@(private)\norigin := Vec{x = 1}\n\nX :: 1"), "%q", src(&app))

	// On the name: only the one-line enum and its attribute go.
	load(&app, "package main\n\n@(private)\nDir :: enum { North, South }\n\nX :: 1")
	focus_text(&app, line_with(&app, "Dir ::"), "Dir")
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\n\nX :: 1")
	load(&app, "package main\n\nwhen ODIN_DEBUG {\n\t@(private)\n\tDir :: enum { North, South }\n\tY :: 2\n}")
	focus_text(&app, line_with(&app, "Dir ::"), "Dir")
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\nwhen ODIN_DEBUG {\n\tY :: 2\n}")
}

// ---- #18: #align(align_of(int)) ----

@(test)
test_review_align_with_parens :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	// Loaded: `#align(` is a keyword, its argument one fixed field.
	text := "package main\n\nPlayer :: struct #align(align_of(int)) {\n\thp: int,\n}"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	ni := line_with(&app, "Player ::")
	testing.expect_value(t, fields_debug(app.doc.nodes[ni]), "[Player][ :: struct ][#align(][align_of(int)][)][ {]")
	focus_text(&app, ni, "#align(")
	delete_selected(&app)
	testing.expect_value(t, src(&app), "package main\n\nPlayer :: struct {\n\thp: int,\n}")

	// Built from the menus (Call > Built-in > align_of > int in the #align dot):
	// LT+B on `#align(` or on `align_of` removes the whole directive.
	for on in ([]string{"#align(", "align_of"}) {
		load(&app, "package main\n\nPlayer :: struct {\n\thp: int,\n}")
		n := &app.doc.nodes[ni]
		for f in n.fields do delete(f.text)
		clear(&n.fields)
		append(&n.fields,
			Field{strings.clone("Player"), true, false, "", "", ""}, Field{strings.clone(" :: struct "), false, false, "", "", ""},
			Field{strings.clone("#align("), false, false, KW, "", ""}, Field{strings.clone("align_of"), false, false, "", "", ""},
			Field{strings.clone("("), false, false, "", "", ""}, Field{strings.clone("int"), true, false, "type", "", ""},
			Field{strings.clone(")"), false, false, "", "", ""}, Field{strings.clone(")"), false, false, "", "", ""},
			Field{strings.clone(" {"), false, false, "", "", ""})
		k, e, ok := directive_span(app.doc.nodes[ni], 3)
		testing.expect(t, ok && k == 2 && e == 7, "the directive runs to its matching `)`")
		focus_text(&app, ni, on)
		delete_selected(&app)
		testing.expect_value(t, node_text(app.doc.nodes[ni], context.temp_allocator), "Player :: struct {")
	}
}

// ---- #19: a parameter's calling convention isn't the procedure's ----

@(test)
test_review_callconv_of_param_type :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nset_cb :: proc(cb: proc \"c\" (x: i32)) {\n}")
	ni := line_with(&app, "set_cb ::")
	testing.expect_value(t, callconv_of(app.doc.nodes[ni]), "")
	testing.expect(t, set_callconv(&app, ni, "system") >= 0)
	testing.expect_value(t, node_text(app.doc.nodes[ni], context.temp_allocator), "set_cb :: proc \"system\" (cb: proc \"c\" (x: i32)) {")
	testing.expect_value(t, callconv_of(app.doc.nodes[ni]), "system")
	testing.expect(t, set_callconv(&app, ni, "c") >= 0)
	testing.expect_value(t, node_text(app.doc.nodes[ni], context.temp_allocator), "set_cb :: proc \"c\" (cb: proc \"c\" (x: i32)) {")

	load(&app, "package main\n\nset_cb :: proc \"contextless\" (cb: proc \"c\" (x: i32)) {\n}")
	testing.expect_value(t, callconv_of(app.doc.nodes[ni]), "contextless")
	testing.expect(t, set_callconv(&app, ni, "system") >= 0)
	testing.expect_value(t, node_text(app.doc.nodes[ni], context.temp_allocator), "set_cb :: proc \"system\" (cb: proc \"c\" (x: i32)) {")
}

// ---- #20: attributes of a local declaration ----

@(test)
test_review_local_attribute_options :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\t@(static)\n\tcounter: int\n\t_ = counter\n}")
	d := line_with(&app, "counter: int")
	out := make([dynamic]Entry)
	defer { for e in out { delete(e.label); delete(e.call_name) }; delete(out) }
	attr_options(&app, d, &out)
	for e in out {
		testing.expectf(t, e.call_name == "thread_local", "only thread_local for a local variable, got %s", e.label)
	}
	apply_attribute(&app, d, "private")
	testing.expect(t, !strings.contains(src(&app), "private"), "private can't go on a local")
}

// ---- #23: a long #assert stays one line ----

@(test)
test_review_long_assert_one_line :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\n#assert(size_of(int) == 8, \"this message is long enough to push the line well past eighty columns\")"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	ni := line_with(&app, "#assert")
	kw := false
	for f in app.doc.nodes[ni].fields do if f.kind == KW && f.text == "#assert" do kw = true
	testing.expect(t, kw, "#assert is a keyword field")
}

// ---- #24: type declarations inside a file-scope when ----

@(test)
test_review_types_in_when :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\nwhen ODIN_DEBUG {\n\tFlags2 :: bit_set[Dir]\n\tStack2 :: struct($T: typeid) {\n\t}\n\tDir :: enum { North, South }\n}"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	testing.expect_value(t, fields_debug(app.doc.nodes[line_with(&app, "Flags2")]), "[\t][Flags2][ :: bit_set[][Dir][]]")
	testing.expect_value(t, fields_debug(app.doc.nodes[line_with(&app, "Stack2")]), "[\t][Stack2][ :: struct($][T][: typeid][●params][) {]")
	testing.expect_value(t, fields_debug(app.doc.nodes[line_with(&app, "Dir ::")]), "[\t][Dir][ :: enum { ][North][, ][South][ }]")
}

// ---- #25: Change condition, then B, restores the condition ----

@(test)
test_review_change_condition_cancel :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	for text in ([]string{"package main\n\n#assert(size_of(int) == 8, \"m\")", "package main\n\nwhen ODIN_DEBUG {\n\tA :: 1\n}"}) {
		load(&app, text)
		ni := line_with(&app, text[len("package main\n\n"):][:5])
		kw := text[len("package main\n\n")] == '#' ? "#assert" : "when"
		focus_text(&app, ni, kw)
		change_selected(&app)
		pick(t, &app, "Change condition")
		testing.expect_value(t, app.state, State.Radial)
		back_out(&app)
		testing.expect_value(t, src(&app), text)
	}
	// A fill still replaces it.
	load(&app, "package main\n\nwhen ODIN_DEBUG {\n\tA :: 1\n}")
	focus_text(&app, 2, "when")
	change_selected(&app)
	pick(t, &app, "Change condition")
	pick(t, &app, "true")
	testing.expect_value(t, src(&app), "package main\n\nwhen true {\n\tA :: 1\n}")
}

// ---- #26 / #27: LT+B on parts of a struct literal line ----

@(private = "file")
LIT_SRC :: "package main\n\nimport win32 \"core:sys/windows\"\n\nmain :: proc() {\n\ty := 1\n\tq := win32.RECT{left = 0}\n\tr: win32.RECT\n\tr = win32.RECT{}\n\tz := 2\n}\n\nf :: proc() -> win32.RECT {\n\treturn win32.RECT{}\n}"

@(test)
test_review_delete_literal_line_parts :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	cases := [?][3]string{
		{"q := win32.RECT", "win32.RECT", "\tq := win32.RECT{left = 0}\n"},
		{"q := win32.RECT", "q", "\tq := win32.RECT{left = 0}\n"},
		{"r = win32.RECT", "r", "\tr = win32.RECT{}\n"},
		{"r = win32.RECT", "win32.RECT", "\tr = win32.RECT{}\n"},
		{"return win32.RECT", "win32.RECT", "\treturn win32.RECT{}\n"},
	}
	for c in cases {
		load(&app, LIT_SRC)
		ni := line_with(&app, c[0])
		testing.expectf(t, focus_text(&app, ni, c[1]), "focus %s on %s", c[1], c[0])
		delete_selected(&app)
		out := src(&app)
		want, _ := strings.replace(LIT_SRC, c[2], "", 1, context.temp_allocator)
		testing.expectf(t, out == want, "LT+B on %s in %s: %q", c[1], c[0], out)
	}
	// Right after inserting a literal: LT+B on its fields dot turns it back into a dot.
	load(&app, LIT_SRC)
	ni := line_with(&app, "z := 2")
	set_field_text(&app, ni, 3, "")
	n := &app.doc.nodes[ni]
	delete(n.fields[3].text)
	n.fields[3] = Field{"", false, true, "value", "", ""}
	focus_field_index(&app, ni, 3)
	update(&app, Input{confirm = true})
	if pick(t, &app, "Struct literal") {
		pick_path(t, &app, "RECT")
	}
	dot := -1
	for f, i in app.doc.nodes[ni].fields do if f.slot && f.kind == FIELDS_KIND do dot = i
	if testing.expectf(t, dot >= 0, "literal inserted: %s", fields_debug(app.doc.nodes[ni])) {
		focus_field_index(&app, ni, dot)
		delete_selected(&app)
		testing.expect_value(t, fields_debug(app.doc.nodes[ni]), "[\t][z][ := ][●value]")
		testing.expect(t, line_with(&app, "main :: proc") >= 0 && line_with(&app, "y := 1") >= 0, "main is still there")
	}
}

// ---- #28: Y on a struct literal's type ----

@(test)
test_review_change_literal_type :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\nimport win32 \"core:sys/windows\"\n\nmain :: proc() {\n\tq := win32.RECT{left = 0}\n\tz := win32.MSG{pt = win32.POINT{x = 1}}\n}"
	load(&app, text)
	ni := line_with(&app, "q :=")
	focus_text(&app, ni, "win32.RECT")
	change_selected(&app)
	testing.expect_value(t, app.state, State.Radial)
	testing.expect_value(t, fields_debug(app.doc.nodes[ni]), "[\t][q][ := ][●value]")
	back_out(&app)
	testing.expect_value(t, src(&app), text)

	ni = line_with(&app, "z :=")
	focus_text(&app, ni, "win32.POINT")
	change_selected(&app)
	testing.expect_value(t, app.state, State.Radial)
	for f in app.doc.nodes[ni].fields do if f.slot && f.kind == "value" do testing.expect_value(t, f.hint, "POINT")
	back_out(&app)
	testing.expect_value(t, src(&app), text)
}

// ---- #29: polymorphic structs in the Struct literal menu ----

@(test)
test_review_poly_struct_literal :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\nimport \"core:container/queue\"\n\nStack :: struct($T: typeid) {\n\titems: [dynamic]T,\n\ttop: int,\n}\n\nPlain :: struct {\n\ta: int,\n}\n\nmain :: proc() {\n\ts := Stack(int){top = 1}\n\tx := 0\n}"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	ni := line_with(&app, "s := Stack(int)")
	has_key := false
	for f in app.doc.nodes[ni].fields do if f.kind == LIT_KEY_KIND && f.text == "top" do has_key = true
	testing.expect(t, has_key, fields_debug(app.doc.nodes[ni]))
	slot := Field{"", false, true, "value", "", ""}
	entries := build_struct_lit_entries(&app, slot)
	defer free_entries(entries)
	testing.expect(t, !any_leaf(entries, "Stack"), "bare Stack isn't offered")
	testing.expect(t, any_leaf(entries, "Plain"))
	testing.expect(t, !any_leaf(entries, "Queue"), "queue.Queue needs parameters")
}

// ---- #30: re-targeting an assignment keeps its call's argument hints ----

@(test)
test_review_retarget_keeps_call_hints :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nimport win32 \"core:sys/windows\"\n\nmain :: proc() {\n\tr: win32.RECT\n\tok: win32.INT\n\tok = win32.FillRect(, , )\n}")
	ni := line_with(&app, "ok = win32.FillRect")
	before := make([dynamic]string, context.temp_allocator)
	for f in app.doc.nodes[ni].fields do if f.slot && f.kind == "value" do append(&before, f.hint)
	set_assign_target(&app, ni, 1, "ok")
	after := make([dynamic]string, context.temp_allocator)
	for f in app.doc.nodes[ni].fields do if f.slot && f.kind == "value" do append(&after, f.hint)
	testing.expect_value(t, strings.join(after[:], ",", context.temp_allocator), strings.join(before[:], ",", context.temp_allocator))
	testing.expect_value(t, strings.join(after[:], ",", context.temp_allocator), "HDC,^RECT,HBRUSH")
}

// ---- #31: `} else {` ends the if-branch's scope ----

@(test)
test_review_else_scope :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nimport win32 \"core:sys/windows\"\n\nmain :: proc() {\n\tv: win32.RECT\n\tif true {\n\t\tv := 5\n\t\tw := v\n\t} else {\n\t\tx := v.left\n\t}\n}")
	ty, ok := var_type_at(&app, line_with(&app, "x := v.left"), "v")
	testing.expect(t, ok && ty.expr == "win32.RECT", "the outer v in the else branch")
	ty, ok = var_type_at(&app, line_with(&app, "w := v"), "v")
	testing.expect(t, ok && ty.expr == "int", "the inner v in the if branch")
}

// ---- #32: a loaded plain-name assignment is structured ----

@(test)
test_review_loaded_plain_assignment :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	text := "package main\n\nD :: enum {\n\tNorth,\n\tSouth = 5,\n}\n\nmain :: proc() {\n\tz := 1\n\tz = 5\n\toperation := 1\n\toperation = 2 if operation == 1 else 1\n}"
	load(&app, text)
	testing.expect_value(t, src(&app), text)
	ni := line_with(&app, "\tz = 5")
	testing.expect(t, is_assign_target(app.doc.nodes[ni], 1), fields_debug(app.doc.nodes[ni]))
	ni = line_with(&app, "operation = 2")
	testing.expect(t, is_assign_target(app.doc.nodes[ni], 1), fields_debug(app.doc.nodes[ni]))
	ni = line_with(&app, "South = 5")
	testing.expect_value(t, fields_debug(app.doc.nodes[ni]), "[\t][South][ = ][5][,]")
}

// ---- #33: an emptied one-field-per-line literal is `T{}` again ----

@(test)
test_review_emptied_broken_literal :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nimport win32 \"core:sys/windows\"\n\nmain :: proc() {\n\tr := win32.RECT {\n\t\tleft = 0,\n\t\ttop = 0,\n\t}\n}")
	ni := line_with(&app, "r := win32.RECT")
	for _ in 0 ..< 2 {
		k := -1
		for f, i in app.doc.nodes[ni].fields do if f.kind == LIT_KEY_KIND { k = i; break }
		if k < 0 do break
		focus_field_index(&app, ni, k)
		delete_selected(&app)
	}
	format_doc(&app)
	out := src(&app)
	testing.expectf(t, strings.contains(out, "\tr := win32.RECT{}\n"), "%q", out)
	text := strings.clone(out, context.temp_allocator)
	doc_from_source(&app, text)
	testing.expect_value(t, src(&app), text)
}

// ---- #34: pointer fields aren't expanded in "Field of" ----

@(test)
test_review_field_menu_pointer_fields_are_leaves :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nNode :: struct {\n\tnext: ^Node,\n\tval: int,\n}\n\nmain :: proc() {\n\tn: Node\n\tx := 0\n}")
	ni := line_with(&app, "x := 0")
	n := &app.doc.nodes[ni]
	delete(n.fields[3].text)
	n.fields[3] = Field{"", false, true, "value", "", ""}
	focus_field_index(&app, ni, 3)
	update(&app, Input{confirm = true})
	if pick(t, &app, "Reference") {
		for _ in 0 ..< 32 {
			eni, efi, ok := editor_target(&app)
			if ok && app.doc.nodes[eni].fields[efi].text == "n" && eni == line_with(&app, "n: Node") do break
			update(&app, Input{up = true})
		}
		update(&app, Input{confirm = true})
		if app.state == .Radial {
			e, ok := find_entry(current_view(&app).entries, "Field of n")
			if testing.expect(t, ok, labels(&app)) {
				nx, nok := find_entry(e.children, "next   ^Node")
				testing.expect(t, nok && len(nx.children) == 0, "^Node is a leaf")
			}
		}
	}
	back_out(&app)
}

// ---- #39: if / for conditions expect a bool ----

@(test)
test_review_condition_dots_expect_bool :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tx := 1\n}")
	for kind in ([]string{"__br_if__", "__br_ifelse__", "__loop_for__"}) {
		load(&app, "package main\n\nmain :: proc() {\n\tx := 1\n}")
		ni := line_with(&app, "x := 1")
		body: Node
		append(&body.fields, Field{strings.clone("\t"), false, false, "", "", ""}, Field{"", false, true, "body", "", ""})
		inject_at(&app.doc.nodes, ni + 1, body)
		if kind == "__loop_for__" do make_loop_statement(&app, ni + 1, 1, kind)
		else do make_branch_statement(&app, ni + 1, 1, kind)
		hint := ""
		for f in app.doc.nodes[ni + 1].fields do if f.slot && f.kind == "value" do hint = f.hint
		testing.expectf(t, hint == "bool", "%s condition hint %q", kind, hint)
	}
}

// ---- #37: `x: T = ●` expects T ----

@(test)
test_review_typed_decl_value_hint :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	load(&app, "package main\n\nmain :: proc() {\n\tx := 1\n}")
	ni := line_with(&app, "x := 1")
	body: Node
	append(&body.fields, Field{strings.clone("\t"), false, false, "", "", ""}, Field{"", false, true, "body", "", ""})
	inject_at(&app.doc.nodes, ni + 1, body)
	make_body_statement(&app, ni + 1, 1, "__stmt_typed__")
	set_slot_type(&app, ni + 1, 3, "f32")
	sync_typed_decl_value_hint(&app, ni + 1)
	last := app.doc.nodes[ni + 1].fields[len(app.doc.nodes[ni + 1].fields) - 1]
	testing.expect(t, last.slot && last.hint == "f32", fields_debug(app.doc.nodes[ni + 1]))
}

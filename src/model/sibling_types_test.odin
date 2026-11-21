package model

// Types declared in the package's other files (siblings.odin): the slow-tiger
// scenario - `point` declared in new_file.odin, used while editing
// renamed_new_file.odin - driven through the model without disk.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// renamed_new_file.odin (the open document).
@(private = "file")
OPEN :: "package main\n\nimport \"core:testing\"\n\n" +
	"@(test)\n" +
	"lucky_test :: proc(t: ^testing.T) {\n" +
	"\ttesting.expect(t, true)\n" +
	"}\n"

// new_file.odin (the sibling), as the user wrote it.
@(private = "file")
SIB :: "package main\n\npoint :: struct { x: f32, y: f32, z: f32, point_or_vector: i8, }\n"

// More sibling declarations: enums, unions, aliases, privacy.
@(private = "file")
SIB2 :: "package main\n\n" +
	"Dir :: enum u8 {\n" +
	"\tNorth,\n" +
	"\tSouth = 2, // a comment\n" +
	"\tEast,\n" +
	"}\n\n" +
	"Robot :: struct {\n" +
	"\tfacing: Dir,\n" +
	"\tpos:    point,\n" +
	"}\n\n" +
	"Shape :: union { point, Dir }\n\n" +
	"@(private=\"file\")\n" +
	"Secret :: struct { a: int }\n\n" +
	"@(private = \"file\") Hidden_Too :: distinct int\n\n" +
	"@(private)\n" +
	"Pkg_Only :: distinct f32\n\n" +
	"Grid :: [4]Dir\n\n" +
	"Lookup :: map[string]int\n\n" +
	"Callback :: #type proc(x: int)\n\n" +
	"Stack :: struct($T: typeid) { items: [dynamic]T }\n\n" +
	"helper :: proc() -> int { return 1 }\n"

@(private = "file")
cleanup :: proc(app: ^App) {
	clear_nav(app)
	delete(app.nav)
	doc_reset(app)
	delete(app.doc.nodes)
	delete(app.recent_imports)
	free_menus(app)
	free_siblings(app)
}

// The open document plus its siblings, an empty statement line ("●") added
// after the line containing `after`.
@(private = "file")
setup :: proc(app: ^App, open := OPEN, after := "testing.expect") {
	scan_sibling_source(app, SIB, "new_file.odin")
	scan_sibling_source(app, SIB2, "more.odin")
	app.state = .Editor
	doc_from_source(app, open)
	body: Node
	append(&body.fields, Field{strings.clone("\t"), false, false, "", "", ""})
	append(&body.fields, Field{"", false, true, "body", "", ""})
	inject_at(&app.doc.nodes, line_with(app, after) + 1, body)
}

@(private = "file")
line_with :: proc(app: ^App, text: string) -> int {
	for n, i in app.doc.nodes do if strings.contains(node_text(n, context.temp_allocator), text) do return i
	return -1
}

@(private = "file")
body_line :: proc(app: ^App) -> int {
	for n, i in app.doc.nodes do if is_body_slot_line(n) do return i
	return -1
}

@(private = "file")
labels_of :: proc(entries: []Entry) -> string {
	out := make([dynamic]string, context.temp_allocator)
	for e in entries do append(&out, e.label)
	return strings.join(out[:], " | ", context.temp_allocator)
}

@(private = "file")
labels :: proc(app: ^App) -> string { return labels_of(current_view(app).entries) }

@(private = "file")
pick :: proc(t: ^testing.T, app: ^App, label: string, loc := #caller_location) -> bool {
	v := current_view(app)
	if v == nil { testing.expectf(t, false, "no menu open (wanted %q)", label, loc = loc); return false }
	for e, i in v.entries {
		if e.label == label {
			v.index = i
			update(app, Input{confirm = true})
			return true
		}
	}
	testing.expectf(t, false, "no %q in menu %q: %v", label, v.title, labels(app), loc = loc)
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
has_label :: proc(entries: []Entry, label: string) -> bool {
	for e in entries do if e.label == label do return true
	return false
}

// A on the statement dot -> Declarations > Variable (:=), renamed to `name`.
@(private = "file")
add_var :: proc(t: ^testing.T, app: ^App, name: string) -> int {
	ni := body_line(app)
	focus_field_index(app, ni, 1)
	update(app, Input{confirm = true})
	pick(t, app, "Declarations")
	pick(t, app, "Variable (:=)")
	for f, i in app.doc.nodes[ni].fields do if f.editable { set_field_text(app, ni, i, name); break }
	return ni
}

// A on the nth unfilled dot of `kind` on line ni.
@(private = "file")
open_dot :: proc(app: ^App, ni, nth: int, kind := "value") {
	seen := 0
	for f, i in app.doc.nodes[ni].fields {
		if f.slot && f.kind == kind {
			if seen == nth { focus_field_index(app, ni, i); break }
			seen += 1
		}
	}
	update(app, Input{confirm = true})
}

@(private = "file")
cursor_text :: proc(app: ^App) -> string {
	ni, fi, ok := editor_target(app)
	if !ok do return "<none>"
	return app.doc.nodes[ni].fields[fi].text
}

@(private = "file")
type_names :: proc(app: ^App) -> string { return strings.join(doc_type_names(app), ",", context.temp_allocator) }

// ---- Scanning ----

@(test)
test_sibling_types_scanned :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	scan_sibling_source(&app, SIB, "new_file.odin")
	scan_sibling_source(&app, SIB2, "more.odin")
	got := make([dynamic]string, context.temp_allocator)
	for st in app.sibling_types do append(&got, fmt.tprintf("%s:%s", st.name, st.kind))
	// File-private types are left out; package-private ones stay. Procedures aren't types.
	testing.expect_value(t, strings.join(got[:], " ", context.temp_allocator),
		"point:struct Dir:enum Robot:struct Shape:union Pkg_Only:distinct Grid:alias Lookup:alias Callback:proc_type Stack:struct")
	p, ok := sibling_type(&app, "point")
	testing.expect(t, ok)
	testing.expect_value(t, p.file, "new_file.odin")
	testing.expect_value(t, p.text, "struct { x: f32, y: f32, z: f32, point_or_vector: i8, }")
	r, _ := sibling_type(&app, "Robot")
	testing.expect_value(t, r.text, "struct {\n\tfacing: Dir,\n\tpos:    point,\n}")
	rhs, _ := sibling_type_rhs(&app, "Robot")
	testing.expect_value(t, rhs.expr, "struct {")
	// The procedures are still read as before.
	testing.expect_value(t, len(app.sibling_procs), 1)
}

@(test)
test_sibling_file_private_tag_hides_everything :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	scan_sibling_source(&app, "#+private file\npackage main\n\nGhost :: struct { a: int }\n\nboo :: proc() {}\n", "ghost.odin")
	testing.expect_value(t, len(app.sibling_types), 0)
	testing.expect_value(t, len(app.sibling_procs), 0)
	// `#+private` (package) keeps them visible.
	scan_sibling_source(&app, "#+private\npackage main\n\nVisible :: struct { a: int }\n", "pkg.odin")
	testing.expect_value(t, len(app.sibling_types), 1)
}

@(test)
test_sibling_types_listed_after_own :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app, "package main\n\nMine :: struct { a: int }\n\nmain :: proc() {\n\ttesting.expect\n}\n")
	testing.expect_value(t, type_names(&app), "Mine,point,Dir,Robot,Shape,Pkg_Only,Grid,Lookup,Stack")
	testing.expect_value(t, strings.join(doc_type_names(&app, true), ",", context.temp_allocator), "Dir,Mine,point,Robot,Shape,Pkg_Only,Grid,Lookup,Stack")
	// A sibling's type never carries a line index into this document.
	for d in doc_type_decls(&app) {
		if d.file == "" {
			testing.expect(t, d.ni >= 0 && d.ni < len(app.doc.nodes), "own types index app.doc")
		} else {
			testing.expectf(t, d.ni == -1, "%s (from %s) has ni %d", d.name, d.file, d.ni)
		}
	}
}

// ---- The slow-tiger scenario ----

@(test)
test_sibling_struct_literal_and_fields :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app)

	// lucky_otter := ●  ->  Struct literal lists point; it inserts `point{●}` (no import).
	ni := add_var(t, &app, "lucky_otter")
	open_dot(&app, ni, 0)
	lit, ok := find(current_view(&app).entries, "Struct literal")
	testing.expect(t, ok)
	// After the import's group ("testing."), this package's structs: polymorphic
	// Stack needs parameters; unions / enums aren't struct literals.
	testing.expect_value(t, labels_of(lit.children), "testing. | point | Robot")
	// Fill > Type lists it too.
	ty, _ := find(current_view(&app).entries, "Type")
	testing.expect(t, has_label(ty.children, "point"), "Type menu lists point")
	pick(t, &app, "Struct literal")
	pick(t, &app, "point")
	testing.expect_value(t, node_source(app.doc.nodes[ni], context.temp_allocator), "\tlucky_otter := point{}")

	// The fields dot: point's fields with their types.
	update(&app, Input{confirm = true})
	testing.expect_value(t, labels(&app), "x   f32 | y   f32 | z   f32 | point_or_vector   i8")
	pick(t, &app, "x   f32")
	eni, efi, _ := editor_target(&app)
	testing.expect(t, app.doc.nodes[eni].fields[efi].slot && app.doc.nodes[eni].fields[efi].hint == "f32", "x's value dot expects an f32")
	update(&app, Input{confirm = true})
	pick(t, &app, "Number")

	// The variable's type and its fields, as member access sees them.
	vt, vok := var_type_at(&app, ni + 1, "lucky_otter")
	testing.expect(t, vok && vt.expr == "point", "lucky_otter is a point")
	xt, xok := expr_type_at(&app, ni + 1, "lucky_otter.point_or_vector")
	testing.expect(t, xok && xt.expr == "i8", "lucky_otter.point_or_vector is an i8")
	testing.expect_value(t, file_text(&app, context.temp_allocator),
		"package main\n\nimport \"core:testing\"\n\n@(test)\nlucky_test :: proc(t: ^testing.T) {\n\ttesting.expect(t, true)\n\tlucky_otter := point{x = 0}\n}\n")
}

@(test)
test_sibling_typed_var_field_of_menu :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app, "package main\n\nimport \"core:testing\"\n\nmain :: proc() {\n\tp: point\n\ttesting.expect\n}\n")
	// copy := ●  -> Reference -> p -> Field of p: x / y / z / point_or_vector, typed.
	ni := add_var(t, &app, "copy")
	open_dot(&app, ni, 0)
	pick(t, &app, "Reference")
	for _ in 0 ..< 64 {
		if cursor_text(&app) == "p" do break
		update(&app, Input{left = true})
	}
	testing.expect_value(t, cursor_text(&app), "p")
	update(&app, Input{confirm = true})
	fo, ok := find(current_view(&app).entries, "Field of p")
	if testing.expectf(t, ok, "Pass as should offer Field of p: %v", labels(&app)) {
		testing.expect_value(t, labels_of(fo.children), "x   f32 | y   f32 | z   f32 | point_or_vector   i8")
	}
	pick(t, &app, "Field of p")
	pick(t, &app, "y   f32")
	testing.expect_value(t, node_source(app.doc.nodes[ni], context.temp_allocator), "\tcopy := p.y")
	ct, _ := var_type_at(&app, ni + 1, "copy")
	testing.expect_value(t, ct.expr, "f32")
}

@(test)
test_sibling_enum_values_and_variants :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app)
	testing.expect_value(t, strings.join(enum_members(&app, "Dir", ""), ",", context.temp_allocator), "North,South,East")
	testing.expect_value(t, strings.join(union_variants(&app, Var_Type{"Shape", ""}), ",", context.temp_allocator), "point,Dir")

	// r := Robot{facing = ●}: the Enum value menu lists Dir's members.
	ni := add_var(t, &app, "r")
	open_dot(&app, ni, 0)
	pick(t, &app, "Struct literal")
	pick(t, &app, "Robot")
	update(&app, Input{confirm = true})
	testing.expect_value(t, labels(&app), "facing   Dir | pos   point")
	pick(t, &app, "facing   Dir")
	update(&app, Input{confirm = true})
	ev, ok := find(current_view(&app).entries, "Enum value")
	testing.expect(t, ok && !ev.dim, "Enum value is offered for a Dir")
	testing.expect_value(t, labels_of(ev.children), ".North | .South | .East")
	pick(t, &app, "Enum value")
	pick(t, &app, ".South")
	testing.expect_value(t, node_source(app.doc.nodes[ni], context.temp_allocator), "\tr := Robot{facing = .South}")
	// Nested: r.pos is a point.
	pt, _ := expr_type_at(&app, ni + 1, "r.pos.z")
	testing.expect_value(t, pt.expr, "f32")
}

@(test)
test_sibling_aliases_followed :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	// `Vec :: point` here is an alias of the sibling's struct; Grid is `[4]Dir`.
	setup(&app, "package main\n\nVec :: point\n\nmain :: proc() {\n\tv: Vec\n\tg: Grid\n\ttesting.expect\n}\n")
	testing.expect(t, strings.contains(type_names(&app), "Vec,"), "Vec reads as a type alias")
	ni := line_with(&app, "v: Vec")
	xt, ok := expr_type_at(&app, ni + 1, "v.x")
	testing.expect(t, ok && xt.expr == "f32", "fields through an alias of a sibling struct")
	// An enumerated array of a sibling's alias: indexed by a Dir.
	et, eok := enum_index_type(&app, "Dir", "")
	testing.expect(t, eok && et.expr == "Dir", "Dir is an enum")
	k, v1, _ := iter_types(&app, line_with(&app, "testing.expect"), "g")
	testing.expect_value(t, k, Iter_Kind.Array)
	testing.expect_value(t, v1.expr, "Dir")
	// A conversion to a sibling's type: Pkg_Only(1) is a Pkg_Only.
	cv, cok := conversion_type(&app, "Pkg_Only")
	testing.expect(t, cok && cv.expr == "Pkg_Only")
	_, pok := conversion_type(&app, "Callback") // `#type proc`: converting to it works too
	testing.expect(t, pok)
}

@(test)
test_sibling_private_types_hidden :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app)
	names := type_names(&app)
	testing.expect(t, !strings.contains(names, "Secret"), "@(private=\"file\") on its own line")
	testing.expect(t, !strings.contains(names, "Hidden_Too"), "@(private = \"file\") on the same line")
	testing.expect(t, strings.contains(names, "Pkg_Only"), "@(private) is package-private: visible")
	testing.expect(t, len(struct_fields(&app, Var_Type{"Secret", ""})) == 0)
}

@(test)
test_sibling_type_shadowed_by_own :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app, "package main\n\nimport \"core:testing\"\n\npoint :: struct { a: int }\n\nDir :: enum { Up, Down }\n\nmain :: proc() {\n\tp: point\n\ttesting.expect\n}\n")
	// Listed once, as this file's.
	testing.expect_value(t, strings.count(type_names(&app), "point"), 1)
	for d in doc_type_decls(&app) do if d.name == "point" do testing.expect(t, d.file == "" && d.ni >= 0)
	fs := struct_fields(&app, Var_Type{"point", ""})
	testing.expect(t, len(fs) == 1 && fs[0].name == "a", "this file's point")
	testing.expect_value(t, strings.join(enum_members(&app, "Dir", ""), ",", context.temp_allocator), "Up,Down")
	_, vis := visible_sibling_type(&app, "point")
	testing.expect(t, !vis)
	// The Struct literal list has one point.
	ni := add_var(t, &app, "q")
	open_dot(&app, ni, 0)
	lit, _ := find(current_view(&app).entries, "Struct literal")
	testing.expect_value(t, labels_of(lit.children), "testing. | point | Robot")
}

@(test)
test_sibling_types_bit_set_and_names :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app, "package main\n\nFlags :: bit_set[Dir]\n\nmain :: proc() {\n\ttesting.expect\n}\n")
	// bit_set[●] offers the sibling's enum.
	ni := line_with(&app, "Flags ::")
	found := false
	for f, i in app.doc.nodes[ni].fields {
		if !f.editable || f.text != "Dir" do continue
		found = true
		app.doc.nodes[ni].fields[i] = Field{"", false, true, "type", "", ""}
		delete(f.text)
		menu, ok := types_slot_menu(&app, ni, i)
		testing.expect(t, ok && has_label(menu, "Dir"), "bit_set[●] lists Dir")
		free_entries(menu)
		break
	}
	testing.expectf(t, found, "bit_set[Dir] has an editable Dir: %s", fields_debug(app.doc.nodes[ni]))
	// Generated names never collide with a sibling's declarations.
	testing.expect(t, is_name_used(&app, "point") && is_name_used(&app, "helper"))
}

// ---- Loading ----

@(test)
test_load_siblings_types_from_folder :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	tmp, err := os.temp_directory(context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	dir := fmt.tprintf("%s/doodle_sibling_types_test_%d", tmp, os.get_pid())
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	_ = os.write_entire_file(fmt.tprintf("%s/renamed_new_file.odin", dir), transmute([]byte)string(OPEN))
	_ = os.write_entire_file(fmt.tprintf("%s/new_file.odin", dir), transmute([]byte)string(SIB))
	load_siblings(&app, dir, "renamed_new_file.odin")
	testing.expect_value(t, len(app.sibling_types), 1)
	testing.expect_value(t, app.sibling_types[0].name, "point")
	// Reloading replaces (and frees) what was read before: the tracker sees no leak.
	_ = os.write_entire_file(fmt.tprintf("%s/new_file.odin", dir), transmute([]byte)string(SIB2))
	load_siblings(&app, dir, "renamed_new_file.odin")
	_, still := sibling_type(&app, "point")
	testing.expect(t, !still, "point is gone after the reload")
	_, robot := sibling_type(&app, "Robot")
	testing.expect(t, robot)
	// From the other file's point of view: renamed_new_file.odin has no types.
	load_siblings(&app, dir, "new_file.odin")
	testing.expect_value(t, len(app.sibling_types), 0)
	testing.expect_value(t, len(app.sibling_procs), 1) // lucky_test
}

@(test)
test_sibling_huge_source_skipped :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	big := strings.concatenate({"package main\n\nBig :: struct { a: int }\n", strings.repeat("// padding\n", SIBLING_MAX_BYTES / 10, context.temp_allocator)}, context.temp_allocator)
	scan_sibling_source(&app, big, "big.odin")
	testing.expect_value(t, len(app.sibling_types), 0)
}

// ---- Review fixes ----

// A types file importing the packages its types use; the open file doesn't
// (or under another name).
@(private = "file")
SIB_IMP :: "package main\n\n" +
	"import \"core:strings\"\n" +
	"import \"core:math/linalg\"\n\n" +
	"Logger :: struct {\n" +
	"\tsb:    strings.Builder,\n" +
	"\tcount: int,\n" +
	"}\n\n" +
	"Vec3 :: linalg.Vector3f32\n\n" +
	"Builders :: [4]strings.Builder\n"

@(private = "file")
open_doc :: proc(app: ^App, src: string) {
	app.state = .Editor
	doc_from_source(app, src)
}

@(test)
test_sibling_types_use_their_files_imports :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	scan_sibling_source(&app, SIB_IMP, "types.odin")
	open_doc(&app, "package main\n\nmain :: proc() {\n\tl: Logger\n\tv: Vec3\n\tbs: Builders\n\tx := 1\n}\n")
	testing.expect(t, strings.contains(type_names(&app), "Vec3"), "Vec3 (an alias of a package's type) is listed")
	// No core:strings import here: sb is a Builder written inside core:strings.
	sb, ok := field_type(&app, Var_Type{"Logger", ""}, "sb")
	testing.expect(t, ok && sb.expr == "Builder" && sb.pkg == "core:strings", fmt.tprintf("sb: %v", sb))
	testing.expect(t, is_struct_type(&app, sb), "a Builder is a struct (Struct literal pin)")
	at := line_with(&app, "x := 1")
	bt, bok := expr_type_at(&app, at, "l.sb.buf")
	testing.expect(t, bok && bt.expr == "[dynamic]byte", fmt.tprintf("l.sb.buf: %v", bt))
	// Vec3 -> linalg.Vector3f32 -> [3]f32: iterated / indexed as an array of f32.
	k, v1, _ := iter_types(&app, at, "v")
	testing.expect_value(t, k, Iter_Kind.Array)
	testing.expect_value(t, v1.expr, "f32")
	k2, e2, _ := iter_types(&app, at, "bs")
	testing.expect_value(t, k2, Iter_Kind.Array)
	testing.expect(t, e2.expr == "Builder" && e2.pkg == "core:strings", fmt.tprintf("bs element: %v", e2))
	ke, ve, iok := index_types(&app, Var_Type{"Vec3", ""})
	testing.expect(t, iok && ve.expr == "f32", fmt.tprintf("v[i]: %v %v", ke, ve))
}

@(test)
test_sibling_types_use_this_files_import_name :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	scan_sibling_source(&app, SIB_IMP, "types.odin")
	open_doc(&app, "package main\n\nimport str \"core:strings\"\n\nmain :: proc() {\n\tl: Logger\n}\n")
	// Written with this file's reference to core:strings.
	sb, _ := field_type(&app, Var_Type{"Logger", ""}, "sb")
	testing.expect(t, sb.expr == "str.Builder" && sb.pkg == "", fmt.tprintf("sb: %v", sb))
	testing.expect(t, is_struct_type(&app, sb))
	// A mix with one of this package's types stays as written (best effort).
	testing.expect_value(t, sibling_type_here(&app, "map[point]strings.Builder", "types.odin"), Var_Type{"map[point]str.Builder", ""})
	scan_sibling_source(&app, SIB, "new_file.odin")
	testing.expect_value(t, sibling_type_here(&app, "map[point]linalg.Vector3f32", "types.odin"), Var_Type{"map[point]linalg.Vector3f32", ""})
	testing.expect_value(t, sibling_type_here(&app, "[dynamic]linalg.Vector3f32", "types.odin"), Var_Type{"[dynamic]Vector3f32", "core:math/linalg"})
	// The open document's own text is left alone.
	testing.expect_value(t, sibling_type_here(&app, "strings.Builder", ""), Var_Type{"strings.Builder", ""})
}

@(test)
test_sibling_alias_read_before_its_target :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	// a_alias.odin is read before new_file.odin (directory order).
	scan_sibling_source(&app, "package main\n\nVec :: point\n\nSpeed :: MAX_SPEED\n\nMAX_SPEED :: 10\n", "a_alias.odin")
	scan_sibling_source(&app, SIB, "new_file.odin")
	open_doc(&app, "package main\n\nmain :: proc() {\n\tv: Vec\n}\n")
	names := type_names(&app)
	testing.expect(t, strings.contains(names, "Vec"), names)
	testing.expect(t, !strings.contains(names, "Speed"), "a constant alias is not a type")
	fs := struct_fields(&app, Var_Type{"Vec", ""})
	testing.expect(t, len(fs) == 4 && fs[0].name == "x", "Vec has point's fields")
	_, sok := sibling_type(&app, "Speed")
	testing.expect(t, !sok)
}

@(test)
test_sibling_alias_of_open_files_type :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	// The other file aliases a type declared in the open file.
	scan_sibling_source(&app, "package main\n\nVec :: point\n", "aliases.odin")
	open_doc(&app, "package main\n\npoint :: struct { x: f32 }\n\nW :: Vec\n\nmain :: proc() {\n\tv: Vec\n}\n")
	testing.expect(t, strings.contains(type_names(&app), "Vec"), type_names(&app))
	fs := struct_fields(&app, Var_Type{"Vec", ""})
	testing.expect(t, len(fs) == 1 && fs[0].name == "x" && fs[0].type.expr == "f32", "Vec has the open file's point's fields")
	// This file's `W :: Vec` reads as an alias too (through the other file's Vec).
	testing.expect(t, doc_declared_type_names(&app)["W"], "W is a type")
	fw := struct_fields(&app, Var_Type{"W", ""})
	testing.expect(t, len(fw) == 1, "W has point's fields")
}

@(test)
test_sibling_privacy_through_attributes_and_comments :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	src := "package main\n\n" +
		"@(private=\"file\")\n@(require_results)\nhidden_proc :: proc() -> int { return 1 }\n\n" +
		"@(private=\"file\")\n// doc\nhidden_too :: proc() {}\n\n" +
		"@(private=\"file\")\n// doc\nHidden_T :: struct { a: int }\n\n" +
		"@(require_results)\n@(private=\"file\")\nHidden_U :: distinct int\n\n" +
		"@(require_results)\n// doc\nshown_proc :: proc() -> int { return 2 }\n\n" +
		"// doc\nShown_T :: struct { b: int }\n"
	scan_sibling_source(&app, src, "priv.odin")
	procs := make([dynamic]string, context.temp_allocator)
	for p in app.sibling_procs do append(&procs, p.name)
	testing.expect_value(t, strings.join(procs[:], ",", context.temp_allocator), "shown_proc")
	types := make([dynamic]string, context.temp_allocator)
	for st in app.sibling_types do append(&types, st.name)
	testing.expect_value(t, strings.join(types[:], ",", context.temp_allocator), "Shown_T")
}

@(test)
test_load_siblings_reuses_unchanged_files :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	tmp, err := os.temp_directory(context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	dir := fmt.tprintf("%s/doodle_sibling_cache_test_%d", tmp, os.get_pid())
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	_ = os.write_entire_file(fmt.tprintf("%s/renamed_new_file.odin", dir), transmute([]byte)string(OPEN))
	_ = os.write_entire_file(fmt.tprintf("%s/new_file.odin", dir), transmute([]byte)string(SIB))
	load_siblings(&app, dir, "renamed_new_file.odin")
	if !testing.expect_value(t, len(app.sibling_cache), 1) do return
	cached := raw_data(app.sibling_cache[0].path)
	// Saving the open file (same folder, same file): new_file.odin isn't parsed again.
	load_siblings(&app, dir, "renamed_new_file.odin")
	testing.expect_value(t, len(app.sibling_cache), 1)
	testing.expect(t, raw_data(app.sibling_cache[0].path) == cached, "the cached scan is reused")
	testing.expect_value(t, len(app.sibling_types), 1)
	// Opening the other file: both are kept (the open one unused).
	load_siblings(&app, dir, "new_file.odin")
	testing.expect_value(t, len(app.sibling_cache), 2)
	testing.expect_value(t, len(app.sibling_types), 0)
	testing.expect_value(t, len(app.sibling_procs), 1)
	// A changed file is read again; a deleted one is dropped.
	_ = os.write_entire_file(fmt.tprintf("%s/new_file.odin", dir), transmute([]byte)string(SIB2))
	load_siblings(&app, dir, "renamed_new_file.odin")
	_, robot := sibling_type(&app, "Robot")
	testing.expect(t, robot, "the edited file is read again")
	_ = os.remove(fmt.tprintf("%s/new_file.odin", dir))
	load_siblings(&app, dir, "renamed_new_file.odin")
	testing.expect_value(t, len(app.sibling_types), 0)
	// No folder: the cache is emptied.
	load_siblings(&app, "", "")
	testing.expect_value(t, len(app.sibling_cache), 0)
}

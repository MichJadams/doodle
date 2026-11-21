package model

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

// Pick `label` in the current menu view; false if it isn't there.
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
labels_of :: proc(app: ^App) -> []string {
	out := make([dynamic]string, 0, 8, context.temp_allocator)
	if v := current_view(app); v != nil do for e in v.entries do append(&out, e.label)
	return out[:]
}

@(private = "file")
has_label :: proc(app: ^App, label: string) -> bool {
	for l in labels_of(app) do if l == label do return true
	return false
}

@(private = "file")
entry_dim :: proc(app: ^App, label: string) -> bool {
	if v := current_view(app); v != nil do for e in v.entries do if e.label == label do return e.dim
	return false
}

// Add > Types > label at the bottom green dot.
@(private = "file")
add_type :: proc(t: ^testing.T, app: ^App, label: string) {
	focus_dot(app)
	update(app, Input{confirm = true})
	testing.expect(t, pick(app, "Types"), "Types group")
	testing.expectf(t, pick(app, label), "Types > %s", label)
	testing.expect_value(t, app.state, State.Editor)
}

// The first line whose text (trimmed) starts with prefix; -1 if none.
@(private = "file")
line_of :: proc(app: ^App, prefix: string, from := 0) -> int {
	for i in from ..< len(app.doc.nodes) {
		if strings.has_prefix(strings.trim_space(node_text(app.doc.nodes[i], context.temp_allocator)), prefix) do return i
	}
	return -1
}

// Field index of the nth dot of `kind` on line ni; -1 if none.
@(private = "file")
dot_at :: proc(app: ^App, ni: int, kind: string, nth := 0) -> int {
	if ni < 0 do return -1
	seen := 0
	for f, i in app.doc.nodes[ni].fields {
		if f.slot && f.kind == kind {
			if seen == nth do return i
			seen += 1
		}
	}
	return -1
}

// A on the nth dot of `kind` on line ni, then pick each label in turn.
@(private = "file")
fill :: proc(t: ^testing.T, app: ^App, ni: int, kind: string, path: ..string) {
	fi := dot_at(app, ni, kind)
	if !testing.expectf(t, fi >= 0, "a %s dot on line %d (%s)", kind, ni, fields_debug(app.doc.nodes[max(ni, 0)])) do return
	focus_field_index(app, ni, fi)
	update(app, Input{confirm = true})
	for p in path do testing.expectf(t, pick(app, p), "menu entry %q (have %v)", p, labels_of(app))
	testing.expect_value(t, app.state, State.Editor)
}

// Rename the first editable field of line ni whose text is `old`.
@(private = "file")
rename :: proc(app: ^App, ni: int, old, new_text: string) {
	for f, i in app.doc.nodes[ni].fields {
		if f.editable && f.text == old { set_field_text(app, ni, i, new_text); return }
	}
}

// Rename the nth editable field of line ni.
@(private = "file")
rename_nth :: proc(app: ^App, ni, nth: int, new_text: string) {
	k := 0
	for f, i in app.doc.nodes[ni].fields {
		if !f.editable do continue
		if k == nth { set_field_text(app, ni, i, new_text); return }
		k += 1
	}
}

// A on the green dot before line `at` (inside a body), then pick the labels.
@(private = "file")
add_at_dot :: proc(t: ^testing.T, app: ^App, at: int, path: ..string) {
	testing.expectf(t, body_points(app)[at], "a green dot before line %d", at)
	focus_dot_at(app, at)
	update(app, Input{confirm = true})
	for p in path do testing.expectf(t, pick(app, p), "menu entry %q (have %v)", p, labels_of(app))
	testing.expect_value(t, app.state, State.Editor)
}

// Same structure field by field (text, name / dot / kind).
@(private = "file")
same_structure :: proc(t: ^testing.T, a, b: ^App) {
	if !testing.expect_value(t, len(b.doc.nodes), len(a.doc.nodes)) do return
	for i in 0 ..< len(a.doc.nodes) {
		x, y := a.doc.nodes[i], b.doc.nodes[i]
		same := len(x.fields) == len(y.fields)
		if same {
			for f, k in x.fields {
				g := y.fields[k]
				if f.text != g.text || f.editable != g.editable || f.slot != g.slot || f.kind != g.kind do same = false
			}
		}
		testing.expectf(t, same, "line %d: menus %s, loaded %s", i, fields_debug(x), fields_debug(y))
	}
}

ALL_TYPES_SRC :: `package main

Player :: struct {
	hp: int,
}

Stack :: struct($T: typeid) {
	items: [dynamic]T,
}

Dir :: enum {
	North,
	South,
}

Shape :: union {
	Player,
	Dir,
}

Flags :: bit_set[Dir]

Packed :: bit_field u32 {
	a: u8 | 4,
}

Meters :: distinct f64
Grid :: [8][8]int
Lookup :: map[string]int`

@(test)
test_types_menu_entries :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	update(&app, Input{confirm = true})
	pick(&app, "Types")
	want := []string{"Struct", "Polymorphic struct", "Enum", "Union", "Bit set", "Bit field", "Distinct type", "Type alias"}
	got := labels_of(&app)
	testing.expect_value(t, len(got), len(want))
	for w, i in want do if i < len(got) do testing.expect_value(t, got[i], w)
}

// Every Types entry built from the menus, formatted and saved; loading the
// saved file gives the same fields back.
@(test)
test_build_every_type_from_menus :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	focus_dot(&app)
	update(&app, Input{confirm = true})
	pick(&app, "File Setup")
	pick(&app, "Package declaration")

	// Player :: struct { hp: int }
	add_type(t, &app, "Struct")
	h := len(app.doc.nodes) - 3
	rename_nth(&app, h, 0, "Player")
	fill(t, &app, h + 1, "body", "Field")
	rename_nth(&app, h + 1, 0, "hp")
	fill(t, &app, h + 1, "type", "Type", "int")

	// Stack :: struct($T: typeid) { items: [dynamic]T }
	add_type(t, &app, "Polymorphic struct")
	h = len(app.doc.nodes) - 3
	rename_nth(&app, h, 0, "Stack")
	testing.expect(t, strings.contains(node_text(app.doc.nodes[h], context.temp_allocator), ":: struct($T: typeid) {"), "poly header")
	fill(t, &app, h + 1, "body", "Field")
	rename_nth(&app, h + 1, 0, "items")
	fill(t, &app, h + 1, "type", "Type", "Composite", "[dynamic]T")
	fill(t, &app, h + 1, "type", "Type", "T") // the struct's own parameter

	// Dir :: enum { North, South }
	add_type(t, &app, "Enum")
	h = len(app.doc.nodes) - 3
	rename_nth(&app, h, 0, "Dir")
	fill(t, &app, h + 1, "body", "Member")
	rename_nth(&app, h + 1, 0, "North")
	add_at_dot(t, &app, h + 2, "Member") // the dot before `}`
	rename_nth(&app, h + 2, 0, "South")

	// Shape :: union { Player, Dir }
	add_type(t, &app, "Union")
	h = len(app.doc.nodes) - 3
	rename_nth(&app, h, 0, "Shape")
	fill(t, &app, h + 1, "body", "Variant")
	fill(t, &app, h + 1, "type", "Type", "Player")
	add_at_dot(t, &app, h + 2, "Variant")
	fill(t, &app, h + 2, "type", "Type", "Dir")

	// Flags :: bit_set[Dir]: the file's enums are offered first.
	add_type(t, &app, "Bit set")
	h = len(app.doc.nodes) - 1
	rename_nth(&app, h, 0, "Flags")
	focus_field_index(&app, h, dot_at(&app, h, "type"))
	update(&app, Input{confirm = true})
	testing.expect_value(t, labels_of(&app)[0], "Dir")
	testing.expect(t, has_label(&app, "0..<N range"), "range form offered")
	pick(&app, "Dir")

	// Packed :: bit_field u32 { a: u8 | 4 }
	add_type(t, &app, "Bit field")
	h = len(app.doc.nodes) - 3
	rename_nth(&app, h, 0, "Packed")
	fill(t, &app, h, "type", "Type", "u32")
	fill(t, &app, h + 1, "body", "Field")
	rename_nth(&app, h + 1, 0, "a")
	fill(t, &app, h + 1, "type", "Type", "u8")
	fill(t, &app, h + 1, "value", "Number")
	rename(&app, h + 1, "0", "4")

	// Meters :: distinct f64
	add_type(t, &app, "Distinct type")
	h = len(app.doc.nodes) - 1
	rename_nth(&app, h, 0, "Meters")
	fill(t, &app, h, "type", "Type", "f64")

	// Grid :: [8][8]int
	add_type(t, &app, "Type alias")
	h = len(app.doc.nodes) - 1
	rename_nth(&app, h, 0, "Grid")
	fill(t, &app, h, "type", "Type", "Composite", "[N]T array")
	fill(t, &app, h, "value", "Number")
	rename(&app, h, "0", "8")
	fill(t, &app, h, "type", "Type", "Composite", "[N]T array")
	fill(t, &app, h, "value", "Number")
	rename(&app, h, "0", "8")
	fill(t, &app, h, "type", "Type", "int")

	// Lookup :: map[string]int
	add_type(t, &app, "Type alias")
	h = len(app.doc.nodes) - 1
	rename_nth(&app, h, 0, "Lookup")
	fill(t, &app, h, "type", "Type", "Composite", "map[K]V")
	fill(t, &app, h, "type", "Type", "string")
	fill(t, &app, h, "type", "Type", "int")

	format_doc(&app)
	src := doc_to_source(&app)
	defer delete(src)
	testing.expect_value(t, src, ALL_TYPES_SRC)

	// Loading it back: the same fields, and it saves unchanged.
	loaded: App
	defer cleanup(&loaded)
	doc_from_source(&loaded, src)
	format_doc(&loaded)
	same_structure(t, &app, &loaded)
	src2 := doc_to_source(&loaded)
	defer delete(src2)
	testing.expect_value(t, src2, src)
}

@(private = "file")
LOAD_SRC :: `package main

import win "core:sys/windows"

// A comment above a struct
Player :: struct {
	name, title: string ` + "`json:\"name\"`" + `, // tagged
	using pos:   Vec2,
	hp:          int,
	grid:        [4][4]^Cell,
	lookup:      map[string][dynamic]int,
	inner:       struct {
		x: f32,
	},
}

Vec2 :: struct { x, y: f32 }
Dir :: enum u8 { North, South = 5, East = 1 << 2 }
Shape :: union { Circle, Square }
Small :: bit_field u16 { lo: u8 | 4, hi: u8 | 4 }

Pair :: struct($K: typeid, $N: int) #align(8) {
	keys: [N]K,
}

Flags :: bit_set[Dir; u8]
Bits :: bit_set[0..<8]
Handle :: distinct win.HANDLE
Matrix :: matrix[2, 2]f32
Ptrs :: [^]^u8
NOT_A_TYPE :: 0x00FF0062

main :: proc() {
	grid: [8][8]int
	Local :: enum { A, B }
	n := 5
}`

@(test)
test_load_type_decls_round_trip :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	doc_from_source(&app, LOAD_SRC)
	out := doc_to_source(&app)
	defer delete(out)
	testing.expect_value(t, out, LOAD_SRC)

	expect_line :: proc(t: ^testing.T, app: ^App, prefix, want: string, loc := #caller_location) {
		ni := line_of(app, prefix)
		if !testing.expectf(t, ni >= 0, "line %q", prefix, loc = loc) do return
		testing.expect_value(t, fields_debug(app.doc.nodes[ni]), want, loc = loc)
	}
	expect_line(t, &app, "name, title", "[\t][name][, ][title][: ][string][ `json:\"name\"`][,][ // tagged]")
	expect_line(t, &app, "using pos", "[\t][using ][pos][:   ][Vec2][,]")
	expect_line(t, &app, "grid:        [4]", "[\t][grid][:        ][[][4][]][[][4][]][^][Cell][,]")
	expect_line(t, &app, "lookup:", "[\t][lookup][:      ][map[][string][]][[dynamic]][int][,]")
	expect_line(t, &app, "x: f32", "[\t\t][x][: ][f32][,]")
	expect_line(t, &app, "Vec2 :: ", "[Vec2][ :: struct { ][x][, ][y][: ][f32][ }]")
	expect_line(t, &app, "Dir :: ", "[Dir][ :: enum ][u8][ { ][North][, ][South][ = ][5][, ][East][ = ][1 << 2][ }]")
	expect_line(t, &app, "Shape :: ", "[Shape][ :: union { ][Circle][, ][Square][ }]")
	expect_line(t, &app, "Small :: ", "[Small][ :: bit_field ][u16][ { ][lo][: ][u8][ | ][4][, ][hi][: ][u8][ | ][4][ }]")
	expect_line(t, &app, "Pair :: ", "[Pair][ :: struct($][K][: typeid][, $][N][: ][int][●params][) ][#align(][8][)][ {]")
	expect_line(t, &app, "keys:", "[\t][keys][: ][[][N][]][K][,]")
	expect_line(t, &app, "Flags :: ", "[Flags][ :: bit_set[][Dir][; ][u8][]]")
	expect_line(t, &app, "Bits :: ", "[Bits][ :: bit_set[][0..<][8][]]")
	expect_line(t, &app, "Handle :: ", "[Handle][ :: distinct ][win.HANDLE]")
	expect_line(t, &app, "Matrix :: ", "[Matrix][ :: ][matrix[2, 2]f32]")
	expect_line(t, &app, "Ptrs :: ", "[Ptrs][ :: ][[^]][^][u8]")
	expect_line(t, &app, "NOT_A_TYPE", "[NOT_A_TYPE][ :: 0x00FF0062]")
	expect_line(t, &app, "grid: [8]", "[\t][grid][: ][[][8][]][[][8][]][int]")
	expect_line(t, &app, "Local :: ", "[\t][Local][ :: enum { ][A][, ][B][ }]") // a local type

	// Member names are names (editable, kind "member"), not references or types.
	ni := line_of(&app, "hp:")
	testing.expect(t, app.doc.nodes[ni].fields[1].editable && app.doc.nodes[ni].fields[1].kind == "member")
	names := doc_type_names(&app)
	has :: proc(s: []string, x: string) -> bool { for v in s do if v == x do return true; return false }
	for want in ([]string{"Player", "Vec2", "Dir", "Shape", "Small", "Pair", "Flags", "Bits", "Handle", "Matrix", "Ptrs"}) {
		testing.expectf(t, has(names, want), "%s is a declared type", want)
	}
	testing.expect(t, !has(names, "NOT_A_TYPE"), "constants are not types")
	testing.expect(t, !has(names, "North"), "enum members are not types")
	for c in ref_candidates(&app) {
		f := app.doc.nodes[c.ni].fields[c.fi]
		testing.expectf(t, f.text != "hp" && f.text != "North" && f.text != "K", "%s is not a reference", f.text)
	}

	// Formatting keeps it (and indents members one level).
	format_doc(&app)
	out2 := doc_to_source(&app)
	defer delete(out2)
	testing.expect_value(t, out2, LOAD_SRC)
}

@(test)
test_format_indents_members :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	doc_from_source(&app, "package main\nPlayer :: struct {\nhp: int,\n  name: string,\n}\nDir :: enum {\nNorth,\n}")
	format_doc(&app)
	out := doc_to_source(&app)
	defer delete(out)
	testing.expect_value(t, out, "package main\n\nPlayer :: struct {\n\thp: int,\n\tname: string,\n}\n\nDir :: enum {\n\tNorth,\n}")
	// still structured after formatting
	ni := line_of(&app, "name:")
	testing.expect_value(t, fields_debug(app.doc.nodes[ni]), "[\t][name][: ][string][,]")
}

// Green dots between members: A offers members; LT+B deletes a member line.
@(test)
test_member_dots_and_delete :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nPlayer :: struct {\n\thp: int,\n\tname: string,\n}\n\nmain :: proc() {\n\tx := 1\n}")
	bp := body_points(&app)
	testing.expect(t, bp[3] && bp[4] && bp[5], "dots above, between and below the fields")
	// The dot between the fields: A -> Field / Using field (not statements).
	focus_dot_at(&app, 4)
	update(&app, Input{confirm = true})
	testing.expect(t, has_label(&app, "Field") && has_label(&app, "Using field"), "struct members offered")
	testing.expect(t, !has_label(&app, "Declarations"), "no statements in a struct")
	pick(&app, "Using field")
	txt := node_text(app.doc.nodes[4], context.temp_allocator)
	testing.expect(t, strings.has_prefix(strings.trim_space(txt), "using ") && strings.has_suffix(txt, ": ,"), txt)
	testing.expect_value(t, len(app.doc.nodes), 11) // no extra "●" line
	// The cursor is on the new name; its type dot is next.
	ni, fi, _ := editor_target(&app)
	testing.expect_value(t, ni, 4)
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].kind, "member")
	// B on the menu instead: nothing added.
	focus_dot_at(&app, 3)
	update(&app, Input{confirm = true})
	update(&app, Input{cancel = true})
	testing.expect_value(t, len(app.doc.nodes), 11)
	// LT+B on `hp` deletes just that line.
	focus_line(&app, 3)
	delete_selected(&app)
	testing.expect_value(t, len(app.doc.nodes), 10)
	testing.expect(t, line_of(&app, "hp:") < 0, "hp deleted")
	testing.expect(t, line_of(&app, "Player :: struct {") >= 0, "struct kept")
	// Dots inside the function still offer statements.
	focus_dot_at(&app, line_of(&app, "x := 1"))
	update(&app, Input{confirm = true})
	testing.expect(t, has_label(&app, "Declarations"), "statements in a proc")
	update(&app, Input{cancel = true})
}

@(test)
test_enum_union_bit_field_members :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nDir :: enum {\n\tNorth,\n}\n\nShape :: union {\n\tint,\n}\n\nPacked :: bit_field u32 {\n\ta: u8 | 4,\n}")
	// enum: Member = value
	add_at_dot(t, &app, 4, "Member = value")
	testing.expect_value(t, fields_debug(app.doc.nodes[4])[:4], "[\t][")
	fi := dot_at(&app, 4, "value")
	testing.expect_value(t, app.doc.nodes[4].fields[fi].hint, "int")
	fill(t, &app, 4, "value", "Number")
	testing.expect(t, strings.has_suffix(node_text(app.doc.nodes[4], context.temp_allocator), " = 0,"), "Name = 0,")
	// union: Variant -> a type dot
	u := line_of(&app, "Shape ::")
	add_at_dot(t, &app, u + 2, "Variant")
	testing.expect_value(t, fields_debug(app.doc.nodes[u + 2]), "[\t][●type][,]")
	fill(t, &app, u + 2, "type", "Type", "string")
	testing.expect_value(t, node_text(app.doc.nodes[u + 2], context.temp_allocator), "\tstring,")
	// bit_field: Field -> name: ● | ●,
	b := line_of(&app, "Packed ::")
	add_at_dot(t, &app, b + 2, "Field")
	testing.expect(t, strings.has_suffix(fields_debug(app.doc.nodes[b + 2]), "[: ][●type][ | ][●value][,]"), fields_debug(app.doc.nodes[b + 2]))
	// The bit_field's backing type: non-integers grayed.
	focus_field_index(&app, b, 2) // the u32
	change_selected(&app)          // Y on a filled type: the type menu
	pick(&app, "Type")
	testing.expect(t, has_label(&app, "u16"), "integers listed")
	testing.expect(t, !entry_dim(&app, "u16"), "u16 fits")
	update(&app, Input{cancel = true})
	update(&app, Input{cancel = true})
	// A fresh backing dot: f32 grayed out.
	set_slot_type_back :: proc(app: ^App, ni, fi: int) {
		delete(app.doc.nodes[ni].fields[fi].text)
		app.doc.nodes[ni].fields[fi] = Field{"", false, true, "type", "", ""}
	}
	set_slot_type_back(&app, b, 2)
	focus_field_index(&app, b, 2)
	update(&app, Input{confirm = true})
	pick(&app, "Type")
	testing.expect(t, entry_dim(&app, "f32"), "f32 can't back a bit_field")
	testing.expect(t, !entry_dim(&app, "u64"), "u64 can")
	pick(&app, "u64")
	testing.expect_value(t, node_text(app.doc.nodes[b], context.temp_allocator), "Packed :: bit_field u64 {")
}

@(test)
test_poly_struct_params :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nStack :: struct($T: typeid) {\n\titems: [dynamic]T,\n}\n\nOther :: struct {\n\tx: int,\n}")
	// Add parameters: the params dot offers Type param / Value param.
	fill(t, &app, 2, "params", "Type param")
	testing.expect_value(t, node_text(app.doc.nodes[2], context.temp_allocator), "Stack :: struct($T: typeid, $U: typeid) {")
	ni, fi, _ := editor_target(&app)
	testing.expect_value(t, app.doc.nodes[ni].fields[fi].text, "U") // cursor on the new name
	fill(t, &app, 2, "params", "Value param")
	fill(t, &app, 2, "type", "Type", "int")
	testing.expect_value(t, node_text(app.doc.nodes[2], context.temp_allocator), "Stack :: struct($T: typeid, $U: typeid, $N: int) {")

	// Inside the struct the type menu offers T and U; outside it doesn't.
	add_at_dot(t, &app, 4, "Field")
	focus_field_index(&app, 4, dot_at(&app, 4, "type"))
	update(&app, Input{confirm = true})
	pick(&app, "Type")
	testing.expect(t, has_label(&app, "T") && has_label(&app, "U"), "own parameters offered")
	testing.expect(t, has_label(&app, "Composite"), "composites offered")
	pick(&app, "U")
	add_at_dot(t, &app, line_of(&app, "x: int"), "Field")
	o := line_of(&app, "Other ::") + 1
	focus_field_index(&app, o, dot_at(&app, o, "type"))
	update(&app, Input{confirm = true})
	pick(&app, "Type")
	testing.expect(t, !has_label(&app, "T"), "T is not a type outside Stack")
	update(&app, Input{cancel = true})
	update(&app, Input{cancel = true})

	// LT+B on a parameter removes just it.
	focus_field_index(&app, 2, 5) // U
	testing.expect_value(t, app.doc.nodes[2].fields[5].text, "U")
	delete_selected(&app)
	testing.expect_value(t, node_text(app.doc.nodes[2], context.temp_allocator), "Stack :: struct($T: typeid, $N: int) {")
	testing.expect(t, dot_at(&app, 2, "params") >= 0, "params dot kept")
	focus_field_index(&app, 2, 2) // T
	delete_selected(&app)
	focus_field_index(&app, 2, 2) // N
	delete_selected(&app)
	testing.expect_value(t, node_text(app.doc.nodes[2], context.temp_allocator), "Stack :: struct {")
	testing.expect(t, line_of(&app, "items:") == 3, "body kept")
}

@(test)
test_composite_types_in_any_type_dot :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	focus_dot(&app)
	update(&app, Input{confirm = true})
	pick(&app, "Procedures")
	pick(&app, "Procedure") // main :: proc( ● ) -> ● {
	// A proc parameter: map[string]^int
	fill(t, &app, 0, "params", "Add parameter")
	fill(t, &app, 0, "type", "Type", "Composite", "map[K]V")
	fill(t, &app, 0, "type", "Type", "string")
	fill(t, &app, 0, "type", "Type", "Composite", "^T pointer")
	fill(t, &app, 0, "type", "Type", "int")
	testing.expect(t, strings.contains(node_text(app.doc.nodes[0], context.temp_allocator), ": map[string]^int, "), node_text(app.doc.nodes[0], context.temp_allocator))
	// A typed variable; Y on its filled `int` -> the type menu -> []T slice.
	fill(t, &app, 1, "body", "Declarations", "Variable (typed)")
	fill(t, &app, 1, "type", "Type", "int")
	tfi := -1
	for f, i in app.doc.nodes[1].fields do if f.kind == "type" && f.text == "int" do tfi = i
	focus_field_index(&app, 1, tfi)
	change_selected(&app)
	pick(&app, "Type")
	pick(&app, "Composite")
	pick(&app, "[]T slice")
	testing.expect_value(t, app.state, State.Editor)
	fill(t, &app, 1, "type", "Type", "Composite", "[^]T multi-ptr")
	fill(t, &app, 1, "type", "Type", "u8")
	fill(t, &app, 1, "value", "nil")
	testing.expect(t, strings.has_suffix(node_text(app.doc.nodes[1], context.temp_allocator), ": [][^]u8 = nil"), node_text(app.doc.nodes[1], context.temp_allocator))
	// Loaded back: the variable's type has the same parts.
	src := doc_to_source(&app)
	defer delete(src)
	loaded: App
	defer cleanup(&loaded)
	doc_from_source(&loaded, src)
	testing.expect(t, strings.contains(fields_debug(loaded.doc.nodes[1]), "[[]][[^]][u8]"), fields_debug(loaded.doc.nodes[1]))
}

@(test)
test_one_line_member_delete :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nDir :: enum { North, South, East }\nOne :: union { int }")
	focus_field_index(&app, 2, 4) // South
	testing.expect_value(t, app.doc.nodes[2].fields[4].text, "South")
	delete_selected(&app)
	testing.expect_value(t, node_text(app.doc.nodes[2], context.temp_allocator), "Dir :: enum { North, East }")
	focus_field_index(&app, 2, 4) // East (last)
	delete_selected(&app)
	testing.expect_value(t, node_text(app.doc.nodes[2], context.temp_allocator), "Dir :: enum { North }")
	focus_field_index(&app, 3, 2) // int: the only variant
	delete_selected(&app)
	testing.expect_value(t, node_text(app.doc.nodes[3], context.temp_allocator), "One :: union {}")
	testing.expect_value(t, len(app.doc.nodes), 4)
	// LT+B on the declaration's name still deletes the whole thing.
	focus_field_index(&app, 2, 0)
	delete_selected(&app)
	testing.expect_value(t, len(app.doc.nodes), 3)
}

@(test)
test_bit_set_range :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	add_type(t, &app, "Bit set")
	focus_field_index(&app, 0, dot_at(&app, 0, "type"))
	update(&app, Input{confirm = true})
	testing.expect_value(t, labels_of(&app)[0], "0..<N range") // no enums in the file yet
	pick(&app, "0..<N range")
	fill(t, &app, 0, "value", "Number")
	rename(&app, 0, "0", "16")
	testing.expect(t, strings.has_suffix(node_text(app.doc.nodes[0], context.temp_allocator), " :: bit_set[0..<16]"), node_text(app.doc.nodes[0], context.temp_allocator))
	src := doc_to_source(&app)
	defer delete(src)
	loaded: App
	defer cleanup(&loaded)
	doc_from_source(&loaded, src)
	same_structure(t, &app, &loaded)
}

// Y on the int of `[8]int` offers "Drop [8]": back to plain `int`.
@(test)
test_unwrap_composite :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nGrid :: [8]^map[string]int\n")
	n := &app.doc.nodes[2]
	last := len(n.fields) - 1 // the int (map value)
	focus_field_index(&app, 2, last)
	change_selected(&app)
	testing.expect(t, pick(&app, "Drop map[string]"), "drop the map")
	testing.expect_value(t, node_text(app.doc.nodes[2], context.temp_allocator), "Grid :: [8]^int")
	focus_field_index(&app, 2, len(app.doc.nodes[2].fields) - 1)
	change_selected(&app)
	testing.expect(t, pick(&app, "Drop ^"), "drop the pointer")
	focus_field_index(&app, 2, len(app.doc.nodes[2].fields) - 1)
	change_selected(&app)
	testing.expect(t, pick(&app, "Drop [8]"), "drop the array")
	testing.expect_value(t, node_text(app.doc.nodes[2], context.temp_allocator), "Grid :: int")
	testing.expect_value(t, app.state, State.Editor)
	// A plain type has nothing to drop.
	focus_field_index(&app, 2, len(app.doc.nodes[2].fields) - 1)
	change_selected(&app)
	testing.expect_value(t, len(labels_of(&app)), 1)
	update(&app, Input{cancel = true})
}

// A proc whose parameter is an anonymous struct still has a code body.
@(test)
test_anonymous_struct_param_body_is_code :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nf :: proc(s: struct { a: int }) {\n\tx := 1\n}\n\ng :: proc() {\n\tsome_enum := 1\n\tswitch some_enum {\n\tcase:\n\t\ty := 2\n\t}\n}")
	testing.expect_value(t, data_block_at(&app, 3), Data_Kind.None)
	// `some_enum` is not the `enum` keyword: the switch body is code, `y` a name.
	yl := line_of(&app, "y := 2")
	testing.expect_value(t, data_block_at(&app, yl), Data_Kind.None)
	testing.expect(t, app.doc.nodes[yl].fields[1].editable && app.doc.nodes[yl].fields[1].text == "y", fields_debug(app.doc.nodes[yl]))
	add_at_dot(t, &app, 4, "Declarations", "Variable (:=)")
	testing.expect(t, strings.contains(node_text(app.doc.nodes[4], context.temp_allocator), " := "), "a statement")
}

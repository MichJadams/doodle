package model

// Compile-time control (Add menu "Compile-time"):
//   When block        when ● { ... }     conditional declarations at file scope
//   Static assertion  #assert(●)         with an optional message dot: #assert(●, "...")
// In the value menu: "Built-in constants" (ODIN_OS, ODIN_DEBUG, ...) and "Enum
// value" (.Windows - the members of the enum the dot expects, or of the other
// side of a comparison: ODIN_OS == ●). In the statement menu: a "Compile-time"
// group (#assert, when).
//
// A `when` at file scope holds declarations, not statements: its braces don't
// count as nesting for the green insertion dots (block_infos / insertion_points),
// so the dots inside it open the Add menu like the top-level ones.
//
// Keywords are fields of kind "kw" (selectable, selection.odin); Y / LT+B act on them:
//   when            Y: add else when / add else / change condition    LT+B: delete the whole when
//   else when/else  Y: same menu                                      LT+B: remove that branch
//   #assert         Y: change condition / add message                 LT+B: delete the line
// (Attributes, struct directives and calling conventions: modifiers.odin.)

import "core:fmt"
import "core:strings"

KW :: "kw" // Field.kind of a keyword Y / LT+B act on

// Fill markers (Entry.fill).
CT_ASSERT_FILL     :: "__ct_assert__"     // statement: #assert(●)
BUILTIN_CONST_FILL :: "__builtin_const__" // value: ODIN_OS, ...  (call_name = the name)
ENUM_VALUE_FILL    :: "__enum_value__"    // value: .Windows       (call_name = ".Windows")
CTRL_MENU_FILL     :: "__ctrl_menu__"     // an option of a compile-time / modifier menu (call_name = its id)

// Entry.special: the Add menu's Compile-time / Modifiers leaves.
SPECIAL_WHEN      :: "when_block"
SPECIAL_ASSERT    :: "static_assert"
SPECIAL_ATTR      :: "mod_attr"
SPECIAL_DIRECTIVE :: "mod_directive"
SPECIAL_CALLCONV  :: "mod_callconv"

// The options menu that's open (App.ctrl_menu).
Ctrl_Menu :: enum u8 {
	None,
	When_Chain, // Y on when / else when / else
	Assert,     // Y on #assert
	Attr,       // attributes for the declaration at ctrl_ni
	Directive,  // struct directives for the struct at ctrl_ni
	Callconv,   // calling convention for the procedure at ctrl_ni
}

compile_time_entries :: proc() -> []Entry {
	return make_slice(
		Entry{label = "When block", special = SPECIAL_WHEN},
		Entry{label = "Static assertion", special = SPECIAL_ASSERT},
	)
}

// ---- Block structure ----

Block_Info :: struct {
	depth:      int, // open braces before the line
	after:      int, // open braces after it
	decl_depth: int, // open braces before the line, not counting file-scope `when` blocks
	chain:      int, // the `when` header of the chain this line is part of (when / else when / else lines), else -1
}

// The braces of a line in order, outside strings, runes and comments.
line_brace_seq :: proc(txt: string) -> []u8 {
	out := make([dynamic]u8, 0, 4, context.temp_allocator)
	quote: u8 = 0
	for k := 0; k < len(txt); k += 1 {
		c := txt[k]
		if quote != 0 {
			if c == '\\' && quote != '`' { k += 1; continue }
			if c == quote do quote = 0
			continue
		}
		switch c {
		case '"', '\'', '`': quote = c
		case '/':
			if k + 1 < len(txt) && txt[k + 1] == '/' do return out[:]
		case '{', '}':
			append(&out, c)
		}
	}
	return out[:]
}

// The when / else when / else keyword field of a line, or -1.
when_kw_index :: proc(n: Node) -> int {
	for f, i in n.fields {
		if f.slot || f.kind != KW do continue
		if f.text == "when" || f.text == "else when" || f.text == "else" do return i
	}
	return -1
}

// block_infos: brace depth per line, and which braces are file-scope `when`
// blocks (the declarations in them are still at file scope).
block_infos :: proc(app: ^App) -> []Block_Info {
	n := len(app.doc.nodes)
	out := make([]Block_Info, n, context.temp_allocator)
	Open :: struct { line: int, see_through: bool }
	stack := make([dynamic]Open, 0, 16, context.temp_allocator)
	solid := 0 // open braces that aren't file-scope when blocks
	for i in 0 ..< n {
		out[i] = Block_Info{len(stack), 0, solid, -1}
		node := app.doc.nodes[i]
		k := when_kw_index(node)
		kw := k >= 0 ? node.fields[k].text : ""
		popped := -1
		for c in line_brace_seq(node_text(node, context.temp_allocator)) {
			if c == '}' {
				if len(stack) == 0 do continue
				o := pop(&stack)
				if !o.see_through do solid -= 1
				if popped < 0 do popped = o.line
			} else {
				chain := kw == "when" || (kw != "" && popped >= 0 && out[popped].chain >= 0)
				see := chain && solid == 0
				append(&stack, Open{i, see})
				if !see do solid += 1
			}
		}
		out[i].after = len(stack)
		if kw == "when" {
			out[i].chain = i
		} else if kw != "" && popped >= 0 && out[popped].chain >= 0 {
			out[i].chain = out[popped].chain
		}
	}
	return out
}

// The line closing the block that line `ni` opens (ni itself if it opens none).
block_close :: proc(app: ^App, infos: []Block_Info, ni: int) -> int {
	if ni < 0 || ni >= len(infos) do return ni
	d := infos[ni].after
	// Only a line that leaves a `{` open opens a block (`} else {` does): a
	// one-line `X :: enum { A, B }` or `v := T{a = 1}` is just itself.
	open := 0
	for c in line_brace_seq(node_text(app.doc.nodes[ni], context.temp_allocator)) {
		if c == '{' do open += 1
		else if open > 0 do open -= 1
	}
	if open == 0 do return ni
	for j in ni + 1 ..< len(infos) do if infos[j].after < d do return j
	return len(infos) - 1
}

// One indentation level in the document's style (a tab, or 4 spaces).
@(private = "file")
indent_unit_of :: proc(app: ^App) -> string {
	for n in app.doc.nodes {
		ind := line_indent(n)
		if len(ind) > 0 do return ind[0] == '\t' ? "\t" : "    "
	}
	return "\t"
}

// decl_indent_at: the indentation for a declaration inserted before line i
// ("" at the top level; one level per enclosing file-scope when). Temp-allocated.
decl_indent_at :: proc(app: ^App, i: int) -> string {
	if i < 0 || i >= len(app.doc.nodes) do return ""
	infos := block_infos(app)
	if infos[i].decl_depth > 0 do return ""
	return strings.repeat(indent_unit_of(app), infos[i].depth, context.temp_allocator)
}

// insertion_indents: decl_indent_at for every insertion point 0..=len (where the
// renderer draws the green dots).
insertion_indents :: proc(app: ^App, allocator := context.temp_allocator) -> []string {
	n := len(app.doc.nodes)
	out := make([]string, n + 1, allocator)
	infos := block_infos(app)
	unit := indent_unit_of(app)
	for i in 0 ..< n {
		if infos[i].decl_depth == 0 && infos[i].depth > 0 do out[i] = strings.repeat(unit, infos[i].depth, allocator)
	}
	return out
}

// Prefix a line with indentation (a fixed first field takes it; else its own field).
@(private = "file")
indent_line :: proc(n: ^Node, ind: string) {
	if ind == "" || is_blank_line(n^) do return
	if len(n.fields) > 0 && !n.fields[0].slot && !n.fields[0].editable && n.fields[0].kind == "" {
		t := strings.concatenate({ind, n.fields[0].text})
		delete(n.fields[0].text)
		n.fields[0].text = t
	} else {
		inject_at(&n.fields, 0, Field{strings.clone(ind), false, false, "", "", ""})
	}
}

// After an Add-menu insertion: lines put inside a file-scope when get its indentation.
ctrl_indent_inserted :: proc(app: ^App) {
	from, to := app.add_from, app.insert_at
	if from < 0 || from >= to || to > len(app.doc.nodes) do return
	ind := strings.clone(decl_indent_at(app, from), context.temp_allocator)
	if ind == "" do return
	for i in from ..< to do indent_line(&app.doc.nodes[i], ind)
}

// The Add menu opened inside a file-scope when: imports can't go there.
ctrl_add_menu_opened :: proc(app: ^App) {
	if decl_indent_at(app, app.insert_at) == "" do return
	v := current_view(app)
	if v == nil do return
	for &e in v.entries do if e.label == "Dependencies" do e.dim = true
}

// ---- The Add menu's Compile-time / Modifiers leaves ----

ctrl_add_select :: proc(app: ^App, e: Entry) {
	clear_nav(app)
	app.state = .Editor
	switch e.special {
	case SPECIAL_WHEN:   insert_when_block(app)
	case SPECIAL_ASSERT: insert_static_assert(app)
	case SPECIAL_ATTR, SPECIAL_DIRECTIVE, SPECIAL_CALLCONV:
		start_mod_pick(app, e.special)
	}
}

@(private = "file")
fx :: proc(text: string) -> Field { return Field{strings.clone(text), false, false, "", "", ""} } // fixed text
@(private = "file")
fkw :: proc(text: string) -> Field { return Field{strings.clone(text), false, false, KW, "", ""} } // keyword
@(private = "file")
cond_dot :: proc() -> Field { return Field{"", false, true, "value", "bool", ""} }
@(private = "file")
msg_dot :: proc() -> Field { return Field{"", false, true, "args", "string", ""} }

// when ● {
// }
insert_when_block :: proc(app: ^App) {
	at := clamp(app.insert_at, 0, len(app.doc.nodes))
	ind := strings.clone(decl_indent_at(app, at), context.temp_allocator)
	h: Node
	if ind != "" do append(&h.fields, fx(ind))
	append(&h.fields, fkw("when"), fx(" "), cond_dot(), fx(" {"))
	c: Node
	append(&c.fields, fx(strings.concatenate({ind, "}"}, context.temp_allocator)))
	inject_at(&app.doc.nodes, at, h, c)
	app.insert_at = at + 2
	focus_field_index(app, at, ind != "" ? 3 : 2) // the condition
}

// #assert(●)   (+ the optional message dot)
insert_static_assert :: proc(app: ^App) {
	at := clamp(app.insert_at, 0, len(app.doc.nodes))
	ind := strings.clone(decl_indent_at(app, at), context.temp_allocator)
	n: Node
	if ind != "" do append(&n.fields, fx(ind))
	append(&n.fields, fkw("#assert"), fx("("), cond_dot(), fx(", "), msg_dot(), fx(")"))
	inject_at(&app.doc.nodes, at, n)
	app.insert_at = at + 1
	focus_field_index(app, at, ind != "" ? 3 : 2)
}

// #assert at a statement dot (the statement menu's Compile-time group).
make_assert_statement :: proc(app: ^App, ni, fi: int) {
	indent := get_body_indent(app, ni)
	defer delete(indent)
	fields := &app.doc.nodes[ni].fields
	ordered_remove(fields, fi)
	inject_at(fields, fi, fkw("#assert"), fx("("), cond_dot(), fx(", "), msg_dot(), fx(")"))
	// A new statement line after it (dropped again when inserted at a green dot).
	nb: Node
	append(&nb.fields, fx(indent), Field{"", false, true, "body", "", ""})
	inject_at(&app.doc.nodes, ni + 1, nb)
}

// The statement menu gets a "Compile-time" group.
ctrl_extend_body_menu :: proc(app: ^App) {
	group := Entry{label = "Compile-time", children = make_slice(
		Entry{label = "#assert", fill = CT_ASSERT_FILL},
		Entry{label = "When", fill = "__br_when__"},
	)}
	old := app.slot_menu
	out := make([]Entry, len(old) + 1)
	copy(out, old)
	out[len(old)] = group
	delete(old)
	app.slot_menu = out
}

// ---- Built-in constants ----

Builtin_Const :: struct {
	name: string,
	type: string,   // its type: "bool", "string", "int", or a compiler enum (Odin_OS_Type)
	cat:  Type_Cat,
	common: bool,   // listed first; the rest are under "More"
}

BUILTIN_CONSTS := [?]Builtin_Const{
	{"ODIN_OS", "Odin_OS_Type", .Enum, true},
	{"ODIN_ARCH", "Odin_Arch_Type", .Enum, true},
	{"ODIN_DEBUG", "bool", .Bool, true},
	{"ODIN_OPTIMIZATION_MODE", "Odin_Optimization_Mode", .Enum, true},
	{"ODIN_ENDIAN", "Odin_Endian_Type", .Enum, true},
	{"ODIN_BUILD_MODE", "Odin_Build_Mode_Type", .Enum, true},
	{"ODIN_NO_CRT", "bool", .Bool, true},
	{"ODIN_TEST", "bool", .Bool, true},
	{"ODIN_VENDOR", "string", .String, true},
	{"ODIN_VERSION", "string", .String, true},
	{"ODIN_OS_STRING", "string", .String, false},
	{"ODIN_ARCH_STRING", "string", .String, false},
	{"ODIN_ENDIAN_STRING", "string", .String, false},
	{"ODIN_BUILD_PROJECT_NAME", "string", .String, false},
	{"ODIN_ROOT", "string", .String, false},
	{"ODIN_VERSION_HASH", "string", .String, false},
	{"ODIN_MICROARCH_STRING", "string", .String, false},
	{"ODIN_WINDOWS_SUBSYSTEM", "Odin_Windows_Subsystem_Type", .Enum, false},
	{"ODIN_WINDOWS_SUBSYSTEM_STRING", "string", .String, false},
	{"ODIN_PLATFORM_SUBTARGET", "Odin_Platform_Subtarget_Type", .Enum, false},
	{"ODIN_ERROR_POS_STYLE", "Odin_Error_Pos_Style_Type", .Enum, false},
	{"ODIN_SANITIZER_FLAGS", "Odin_Sanitizer_Flags", .BitSet, false},
	{"ODIN_MINIMUM_OS_VERSION", "int", .Integer, false},
	{"ODIN_COMPILE_TIMESTAMP", "int", .Integer, false},
	{"ODIN_DISABLE_ASSERT", "bool", .Bool, false},
	{"ODIN_NO_BOUNDS_CHECK", "bool", .Bool, false},
	{"ODIN_NO_ENTRY_POINT", "bool", .Bool, false},
	{"ODIN_NO_RTTI", "bool", .Bool, false},
	{"ODIN_NO_TYPE_ASSERT", "bool", .Bool, false},
	{"ODIN_DEFAULT_TO_NIL_ALLOCATOR", "bool", .Bool, false},
	{"ODIN_DEFAULT_TO_PANIC_ALLOCATOR", "bool", .Bool, false},
	{"ODIN_FOREIGN_ERROR_PROCEDURES", "bool", .Bool, false},
	{"ODIN_USE_SEPARATE_MODULES", "bool", .Bool, false},
	{"ODIN_VALGRIND_SUPPORT", "bool", .Bool, false},
}

builtin_const :: proc(name: string) -> (Builtin_Const, bool) {
	for b in BUILTIN_CONSTS do if b.name == name do return b, true
	return {}, false
}

// The compiler-defined enums (base:runtime documents them; the compiler defines them).
@(private = "file") ODIN_OS_MEMBERS := [?]string{"Unknown", "Windows", "Darwin", "Linux", "FreeBSD", "OpenBSD", "NetBSD", "WASI", "JS", "Orca", "Freestanding"}
@(private = "file") ODIN_ARCH_MEMBERS := [?]string{"Unknown", "amd64", "i386", "arm32", "arm64", "wasm32", "wasm64p32", "riscv64"}
@(private = "file") ODIN_BUILD_MODE_MEMBERS := [?]string{"Executable", "Dynamic", "Static", "Object", "Assembly", "LLVM_IR"}
@(private = "file") ODIN_ENDIAN_MEMBERS := [?]string{"Little", "Big"}
@(private = "file") ODIN_OPT_MEMBERS := [?]string{"None", "Minimal", "Size", "Speed", "Aggressive"}
@(private = "file") ODIN_ERROR_POS_MEMBERS := [?]string{"Default", "Unix"}
@(private = "file") ODIN_SUBSYSTEM_MEMBERS := [?]string{"Unknown", "Boot_Application", "Console", "EFI_Application", "EFI_Boot_Service_Driver", "EFI_Rom", "EFI_Runtime_Driver", "Native", "Posix", "Windows", "Windows_CE"}
@(private = "file") ODIN_SUBTARGET_MEMBERS := [?]string{"Default", "iPhone", "iPhoneSimulator", "Android", "Playdate"}
@(private = "file") ODIN_SANITIZER_MEMBERS := [?]string{"Address", "Memory", "Thread"}

compiler_enum_members :: proc(type_name: string) -> []string {
	t := strings.trim_prefix(type_name, "runtime.")
	switch t {
	case "Odin_OS_Type":                 return ODIN_OS_MEMBERS[:]
	case "Odin_Arch_Type":               return ODIN_ARCH_MEMBERS[:]
	case "Odin_Build_Mode_Type":         return ODIN_BUILD_MODE_MEMBERS[:]
	case "Odin_Endian_Type":             return ODIN_ENDIAN_MEMBERS[:]
	case "Odin_Optimization_Mode":       return ODIN_OPT_MEMBERS[:]
	case "Odin_Error_Pos_Style_Type":    return ODIN_ERROR_POS_MEMBERS[:]
	case "Odin_Windows_Subsystem_Type":  return ODIN_SUBSYSTEM_MEMBERS[:]
	case "Odin_Platform_Subtarget_Type": return ODIN_SUBTARGET_MEMBERS[:]
	case "Odin_Sanitizer_Flags", "Odin_Sanitizer_Flag": return ODIN_SANITIZER_MEMBERS[:]
	}
	return nil
}

@(private = "file")
build_builtin_const_entries :: proc() -> []Entry {
	common := make([dynamic]Entry, 0, 12)
	more := make([dynamic]Entry, 0, 32)
	defer delete(common)
	defer delete(more)
	for b in BUILTIN_CONSTS {
		e := Entry{label = b.name, fill = BUILTIN_CONST_FILL, call_name = strings.clone(b.name)}
		if b.common do append(&common, e)
		else do append(&more, e)
	}
	more_s := make([]Entry, len(more))
	copy(more_s, more[:])
	append(&common, grp("More", more_s))
	out := make([]Entry, len(common))
	copy(out, common[:])
	return out
}

// ---- Enum values ----

// enum_members: the member names of enum type `type_name` written in package
// `pkg` ("" = this file / builtin): compiler enums, enums declared in the
// document, and CORE_ENUM_MEMBERS. Temp-allocated (or static).
enum_members :: proc(app: ^App, type_name, pkg: string) -> []string {
	t := strings.trim_space(type_name)
	if t == "" do return nil
	if m := compiler_enum_members(t); m != nil do return m
	path, name := pkg, t
	if dot := strings.index_byte(t, '.'); dot > 0 {
		ref := t[:dot]
		name = t[dot + 1:]
		path = ""
		imports := collect_imports(app)
		defer delete(imports)
		for imp in imports do if imp.ref == ref { path = strings.clone(imp.path, context.temp_allocator); break }
		if path == "" do return nil
	}
	out := make([dynamic]string, 0, 8, context.temp_allocator)
	if path == "" {
		doc_enum_members(app, name, &out)
	} else {
		for r in CORE_ENUM_MEMBERS do if r.path == path && r.type_name == name do append(&out, r.name)
	}
	return out[:]
}

// The members of `Name :: enum ... { A, B = 2, ... }` declared in the document
// (or, not declared there, in another file of the package).
@(private = "file")
doc_enum_members :: proc(app: ^App, name: string, out: ^[dynamic]string) {
	for n, ni in app.doc.nodes {
		t := strings.trim_space(node_text(n, context.temp_allocator))
		if !strings.has_prefix(t, name) do continue
		rest := strings.trim_left_space(t[len(name):])
		if !strings.has_prefix(rest, "::") do continue
		rest = strings.trim_left_space(rest[2:])
		if !strings.has_prefix(rest, "enum") do continue
		// The body: from the `{` to the matching `}` (possibly over several lines).
		b := strings.builder_make(context.temp_allocator)
		depth := 0
		done := false
		for j in ni ..< len(app.doc.nodes) {
			line := node_source(app.doc.nodes[j], context.temp_allocator)
			if c := strings.index(line, "//"); c >= 0 do line = line[:c]
			for k in 0 ..< len(line) {
				c := line[k]
				if c == '{' { depth += 1; if depth == 1 do continue }
				if c == '}' { depth -= 1; if depth == 0 { done = true; break } }
				if depth >= 1 do strings.write_byte(&b, c)
			}
			if done do break
			if depth >= 1 do strings.write_byte(&b, ',')
		}
		for item in strings.split(strings.to_string(b), ",", context.temp_allocator) {
			it := strings.trim_space(item)
			if eq := strings.index_byte(it, '='); eq >= 0 do it = strings.trim_space(it[:eq])
			if is_ident(it) do append(out, it)
		}
		return
	}
	// Not in the document: an enum of another file of the package (siblings.odin).
	if st, ok := visible_sibling_type(app, name); ok && st.kind == "enum" {
		for item in brace_items(st.text) {
			it := item
			if eq := strings.index_byte(it, '='); eq >= 0 do it = strings.trim_space(it[:eq])
			if is_ident(it) do append(out, it)
		}
	}
}

@(private = "file")
is_compare_op :: proc(f: Field) -> bool {
	if f.slot do return false
	t := strings.trim_space(f.text)
	return (t == "==" || t == "!=") && len(f.text) > len(t)
}

// operand_enum_type: the enum type of an operand: a built-in constant, or a
// name declared in the document with a type (`dir: Direction`).
operand_enum_type :: proc(app: ^App, text: string) -> (type_name, pkg: string) {
	t := strings.trim_space(text)
	if b, ok := builtin_const(t); ok {
		if b.cat == .Enum do return b.type, "base:runtime"
		return "", ""
	}
	if !is_ident(t) do return "", ""
	for n in app.doc.nodes {
		for f, i in n.fields {
			if !f.editable || f.kind != "" || f.text != t do continue
			b := strings.builder_make(context.temp_allocator)
			for g in n.fields[i + 1:] do strings.write_string(&b, g.text)
			rest := strings.trim_left_space(strings.to_string(b))
			if !strings.has_prefix(rest, ":") || strings.has_prefix(rest, "::") || strings.has_prefix(rest, ":=") do continue
			rest = rest[1:]
			end := len(rest)
			for c, k in transmute([]u8)rest do if c == ',' || c == ')' || c == '=' || c == '{' { end = k; break }
			ty := strings.trim_space(rest[:end])
			if ty != "" do return ty, ""
		}
	}
	return "", ""
}

// The enum type for the dot at (ni, fi): its expected type, or the type of the
// other side of a comparison it's in.
enum_type_for_dot :: proc(app: ^App, ni, fi: int) -> (type_name, pkg: string) {
	fields := app.doc.nodes[ni].fields
	f := fields[fi]
	if f.hint != "" && len(enum_members(app, f.hint, f.hint_pkg)) > 0 do return f.hint, f.hint_pkg
	other := -1
	if fi >= 2 && is_compare_op(fields[fi - 1]) do other = fi - 2
	else if fi + 2 < len(fields) && is_compare_op(fields[fi + 1]) do other = fi + 2
	if other >= 0 && !fields[other].slot do return operand_enum_type(app, fields[other].text)
	return "", ""
}

@(private = "file")
build_enum_value_entries :: proc(app: ^App, ni, fi: int) -> (entries: []Entry, ok: bool) {
	ty, pkg := enum_type_for_dot(app, ni, fi)
	members := enum_members(app, ty, pkg)
	if len(members) == 0 do return make_slice(grp_dim("(no enum type here)")), false
	out := make([]Entry, len(members))
	for m, i in members {
		v := fmt.aprintf(".%s", m)
		// Heat (heat.odin) per enum: `.None` of one enum isn't another's.
		hk := pkg != "" ? fmt.aprintf("%s.%s%s", pkg, ty, v) : fmt.aprintf("%s%s", ty, v)
		out[i] = Entry{label = v, owned_label = true, fill = ENUM_VALUE_FILL, call_name = strings.clone(v), heat_key = hk}
	}
	return out, true
}

// The value menu gets "Built-in constants" and "Enum value" (after "Constant").
ctrl_extend_value_menu :: proc(app: ^App, ni, fi: int) {
	enum_children, has_enum := build_enum_value_entries(app, ni, fi)
	extra := [2]Entry{
		{label = "Built-in constants", children = build_builtin_const_entries()},
		{label = "Enum value", children = enum_children, dim = !has_enum},
	}
	old := app.slot_menu
	at := len(old)
	for e, i in old do if e.label == "Constant" { at = i + 1; break }
	out := make([]Entry, len(old) + 2)
	copy(out[:at], old[:at])
	out[at] = extra[0]
	out[at + 1] = extra[1]
	copy(out[at + 2:], old[at:])
	delete(old)
	app.slot_menu = out
}

// Graying for the new fills (typecheck.odin entry_fits).
ctrl_entry_fits :: proc(e: Entry, exp: Resolved_Type) -> bool {
	if exp.cat == .Unknown || exp.cat == .Any do return true
	if e.fill == ENUM_VALUE_FILL do return true // built for this dot's enum
	b, ok := builtin_const(e.call_name)
	if !ok do return true
	#partial switch b.cat {
	case .Bool:    return literal_fits("__lit_true__", exp.cat)
	case .String:  return literal_fits("__lit_str__", exp.cat)
	case .Integer: return literal_fits("__lit_num__", exp.cat)
	}
	return exp.cat == b.cat
}

// The fill dispatch for #assert / built-in constants / enum values.
ctrl_fill :: proc(app: ^App, e: Entry) {
	ni, fi := app.slot_ni, app.slot_fi
	if ni < 0 || ni >= len(app.doc.nodes) || fi < 0 || fi >= len(app.doc.nodes[ni].fields) do return
	switch e.fill {
	case CT_ASSERT_FILL:
		make_assert_statement(app, ni, fi)
	case ENUM_VALUE_FILL:
		set_slot_text(app, ni, fi, e.call_name)
	case BUILTIN_CONST_FILL:
		set_slot_text(app, ni, fi, e.call_name)
		// ODIN_OS == ●: the other side expects an Odin_OS_Type (its Enum value menu lists .Windows, ...).
		if b, ok := builtin_const(e.call_name); ok && b.cat == .Enum {
			fields := &app.doc.nodes[ni].fields
			for o in ([2]int{fi + 2, fi - 2}) {
				if o < 0 || o >= len(fields) || !fields[o].slot || fields[o].kind != "value" || fields[o].hint != "" do continue
				if !is_compare_op(fields[(o + fi) / 2]) do continue
				fields[o].hint, fields[o].hint_pkg = b.type, "base:runtime"
			}
		}
	}
}

// ---- #assert ----

// The `#assert` keyword field of a line, or -1.
assert_kw_index :: proc(n: Node) -> int {
	for f, i in n.fields do if !f.slot && f.kind == KW && f.text == "#assert" do return i
	return -1
}

// Per input: an #assert keeps at most one optional (message) dot - filling the
// message dot would otherwise offer a third argument.
ctrl_sync :: proc(app: ^App) {
	if app.state != .Editor do return
	changed := false
	for &n in app.doc.nodes {
		if assert_kw_index(n) < 0 do continue
		for {
			al, ok := find_arg_list(n)
			if !ok || len(al.seps) < 2 do break
			last := al.seps[len(al.seps) - 1]
			if al.close - last != 2 || !n.fields[last + 1].slot || n.fields[last + 1].kind != "args" do break
			for k in last ..< al.close do if len(n.fields[k].text) > 0 do delete(n.fields[k].text)
			remove_range(&n.fields, last, al.close)
			changed = true
		}
	}
	if changed do clamp_field(app)
}

// ---- when chains ----

// The lines of the when chain headed by line h: h and its else when / else
// lines, and the line closing the last branch.
when_chain :: proc(app: ^App, infos: []Block_Info, h: int) -> (lines: []int, end: int) {
	out := make([dynamic]int, 0, 4, context.temp_allocator)
	for j in h ..< len(infos) do if infos[j].chain == h do append(&out, j)
	if len(out) == 0 do return nil, h
	return out[:], block_close(app, infos, out[len(out) - 1])
}

@(private = "file")
chain_has_else :: proc(app: ^App, lines: []int) -> bool {
	for l in lines {
		k := when_kw_index(app.doc.nodes[l])
		if k >= 0 && app.doc.nodes[l].fields[k].text == "else" do return true
	}
	return false
}

// A when chain inside a procedure (statements) vs at file scope (declarations).
@(private = "file")
chain_in_code :: proc(infos: []Block_Info, h: int) -> bool { return infos[h].decl_depth > 0 }

@(private = "file")
free_node :: proc(n: ^Node) {
	for f in n.fields do if len(f.text) > 0 do delete(f.text)
	delete(n.fields)
}

// Add `} else when ● {` (before the else, if there is one) or `} else {` at the end.
add_when_branch :: proc(app: ^App, h: int, with_cond: bool) {
	infos := block_infos(app)
	lines, end := when_chain(app, infos, h)
	if len(lines) == 0 do return
	has_else := chain_has_else(app, lines)
	if !with_cond && has_else do return
	at := end
	if with_cond && has_else do at = lines[len(lines) - 1]
	ind := strings.clone(line_indent(app.doc.nodes[h]), context.temp_allocator)
	line: Node
	append(&line.fields, fx(strings.concatenate({ind, "} "}, context.temp_allocator)))
	if with_cond {
		append(&line.fields, fkw("else when"), fx(" "), cond_dot(), fx(" {"))
	} else {
		append(&line.fields, fkw("else"), fx(" {"))
	}
	inject_at(&app.doc.nodes, at, line)
	if chain_in_code(infos, h) {
		// Statements: the new branch gets a "●" statement line, like if / else.
		unit := indent_unit(ind)
		body: Node
		append(&body.fields, fx(strings.concatenate({ind, unit}, context.temp_allocator)), Field{"", false, true, "body", "", ""})
		inject_at(&app.doc.nodes, at + 1, body)
		if !with_cond { focus_field_index(app, at + 1, 1); return }
	} else if !with_cond {
		focus_dot_at(app, at + 1) // the dot inside the new else
		return
	}
	focus_field_index(app, at, 3) // the new condition
}

// Remove the else when / else branch starting at line b.
remove_when_branch :: proc(app: ^App, b: int) {
	infos := block_infos(app)
	h := infos[b].chain
	if h < 0 || h == b do return
	lines, end := when_chain(app, infos, h)
	next := end
	for l in lines do if l > b { next = l; break }
	delete_construct(app, b, next - 1)
	focus_line(app, h)
	if k := when_kw_index(app.doc.nodes[h]); k >= 0 do focus_field_index(app, h, k)
}

// Delete a whole when chain (LT+B on `when`).
delete_when_chain :: proc(app: ^App, h: int) {
	infos := block_infos(app)
	_, end := when_chain(app, infos, h)
	delete_construct(app, h, end)
}

// Change condition: the condition becomes a dot again and its fill menu opens.
reset_condition :: proc(app: ^App, ni, k: int) {
	fields := &app.doc.nodes[ni].fields
	last := len(fields) - 1
	if k + 2 > last || fields[k + 1].text != " " || strings.trim_space(fields[last].text) != "{" do return
	refill_range_with_dot(app, ni, k + 2, last, cond_dot())
}

// refill_range_with_dot: fields [fa, fb) of line ni become `dot` and its fill
// menu opens; cancelling (B) puts the original fields back, as Y does
// elsewhere (begin_refill, change.odin).
@(private = "file")
refill_range_with_dot :: proc(app: ^App, ni, fa, fb: int, dot: Field) {
	refill_discard(app)
	fields := &app.doc.nodes[ni].fields
	for i in fa ..< fb do append(&app.refill_saved, fields[i]) // ownership moves to refill_saved
	remove_range(fields, fa, fb)
	inject_at(fields, fa, dot)
	app.refill_active = true
	app.refill_ni = ni
	app.refill_fi = fa
	focus_field_index(app, ni, fa)
	open_slot_menu(app)
	if app.state != .Radial do refill_restore(app)
}

// #assert: the condition (first argument) becomes a dot again.
@(private = "file")
reset_assert_condition :: proc(app: ^App, ni: int) {
	al, ok := find_arg_list(app.doc.nodes[ni])
	if !ok do return
	stop := al.close
	if len(al.seps) > 0 do stop = al.seps[0]
	refill_range_with_dot(app, ni, al.open + 1, stop, cond_dot())
}

// Is there a message argument (filled), or its optional dot (dot >= 0)?
@(private = "file")
assert_message :: proc(n: Node) -> (filled: bool, dot: int) {
	al, ok := find_arg_list(n)
	if !ok || len(al.seps) == 0 do return false, -1
	sep := al.seps[0]
	stop := len(al.seps) > 1 ? al.seps[1] : al.close
	if stop - sep == 2 && n.fields[sep + 1].slot do return false, sep + 1
	return true, -1
}

// #assert: open the message dot's menu (adding the dot back if it's gone).
@(private = "file")
add_assert_message :: proc(app: ^App, ni: int) {
	filled, dot := assert_message(app.doc.nodes[ni])
	if filled do return
	if dot < 0 {
		al, ok := find_arg_list(app.doc.nodes[ni])
		if !ok do return
		inject_at(&app.doc.nodes[ni].fields, al.close, fx(", "), msg_dot())
		dot = al.close + 1
	}
	focus_field_index(app, ni, dot)
	open_slot_menu(app)
}

// LT+B inside an #assert's message: the message goes (the optional dot comes back).
@(private = "file")
remove_assert_message :: proc(app: ^App, ni, fi: int) -> bool {
	n := app.doc.nodes[ni]
	al, ok := find_arg_list(n)
	if !ok || len(al.seps) == 0 do return false
	sep := al.seps[0]
	stop := len(al.seps) > 1 ? al.seps[1] : al.close
	if fi <= sep || fi >= stop do return false
	if stop - sep == 2 && n.fields[sep + 1].slot do return true // already the empty dot
	fields := &app.doc.nodes[ni].fields
	for i in sep + 1 ..< stop do if len(fields[i].text) > 0 do delete(fields[i].text)
	remove_range(fields, sep + 1, stop)
	inject_at(fields, sep + 1, msg_dot())
	focus_field_index(app, ni, sep + 1)
	return true
}

// ---- Y and LT+B ----

// ctrl_change: Y on a keyword field. True when handled.
ctrl_change :: proc(app: ^App, ni: int, u: Unit) -> bool {
	n := app.doc.nodes[ni]
	if when_cond_change(app, ni, u) do return true // a when's condition (when_cond.odin)
	if u.fb - u.fa != 1 do return false
	f := n.fields[u.fa]
	if f.slot || f.kind != KW do return false
	switch {
	case f.text == "when" || f.text == "else when" || f.text == "else":
		ctrl_open_menu(app, .When_Chain, ni, u.fa, false)
	case f.text == "#assert":
		ctrl_open_menu(app, .Assert, ni, u.fa, false)
	case is_callconv_kw(f):
		ctrl_open_menu(app, .Callconv, ni, u.fa, false)
	case is_directive_kw(f):
		ctrl_open_menu(app, .Directive, ni, u.fa, false)
	case is_attr_line(n):
		d := attr_decl_line(app, ni)
		if d < 0 do return true
		ctrl_open_menu(app, .Attr, d, -1, false)
	case:
		return false
	}
	return true
}

// ctrl_delete: LT+B on attributes, directives, conventions, when keywords, an
// #assert message, or a declaration with attributes / inside a file-scope when.
// True when handled.
ctrl_delete :: proc(app: ^App) -> bool {
	ni, fi, ok := editor_target(app)
	if !ok do return false
	n := app.doc.nodes[ni]
	f := n.fields[fi]
	if is_attr_line(n) {
		remove_attribute(app, ni, fi)
		return true
	}
	if k, _, in_dir := directive_span(n, fi); in_dir {
		remove_directive(app, ni, k)
		return true
	}
	if is_callconv_kw(f) {
		remove_callconv(app, ni, fi)
		return true
	}
	if when_cond_delete(app, ni, fi) do return true // a when's condition: back to its dot (when_cond.odin)
	// Anywhere else on a when / else when / else line: the whole when, or that branch.
	if k := when_kw_index(n); k >= 0 {
		if n.fields[k].text == "when" do delete_when_chain(app, ni)
		else do remove_when_branch(app, ni)
		return true
	}
	if assert_kw_index(n) >= 0 && remove_assert_message(app, ni, fi) do return true
	return false
}

// ctrl_delete_declaration: LT+B on the name or `::` / `:=` of a declaration
// with attribute lines above it, or inside a file-scope when (delete_selected
// tries it after the finer-grained deletes: an enum member, a literal field, a
// $T parameter go on their own).
ctrl_delete_declaration :: proc(app: ^App) -> bool {
	ni, fi, ok := editor_target(app)
	if !ok do return false
	n := app.doc.nodes[ni]
	name := -1
	for f, i in n.fields {
		if f.editable && !f.slot { name = i; break }
		if f.slot || strings.trim_space(f.text) != "" do break
	}
	if name < 0 do return false
	if fi != name && !(fi == name + 1 && !n.fields[fi].slot && !n.fields[fi].editable) && n.fields[fi].kind != "decl" do return false
	return delete_declaration(app, ni)
}

// A declaration at file scope: deleted with the attribute lines above it; inside
// a file-scope when, just the declaration (not the whole when).
@(private = "file")
delete_declaration :: proc(app: ^App, ni: int) -> bool {
	infos := block_infos(app)
	if infos[ni].decl_depth != 0 do return false
	if classify_decl(strings.trim_space(node_text(app.doc.nodes[ni], context.temp_allocator))) == .None do return false
	start := ni
	for start > 0 && is_attr_line(app.doc.nodes[start - 1]) do start -= 1
	if start == ni && infos[ni].depth == 0 do return false // the usual delete
	delete_construct(app, start, block_close(app, infos, ni))
	return true
}

// ---- Options menus ----

@(private = "file")
option :: proc(out: ^[dynamic]Entry, label, id: string, dim := false) {
	append(out, Entry{label = strings.clone(label), owned_label = true, fill = CTRL_MENU_FILL, call_name = strings.clone(id), dim = dim})
}

// ctrl_open_menu opens the options for `kind` acting on line ni (field fi).
ctrl_open_menu :: proc(app: ^App, kind: Ctrl_Menu, ni, fi: int, from_pick: bool) {
	out := make([dynamic]Entry, 0, 10)
	defer delete(out)
	title := ""
	n := app.doc.nodes[ni]
	switch kind {
	case .None:
		return
	case .When_Chain:
		title = "When"
		infos := block_infos(app)
		h := infos[ni].chain
		if h < 0 do return
		lines, _ := when_chain(app, infos, h)
		option(&out, "Add else when", "else_when")
		option(&out, "Add else", "else", chain_has_else(app, lines))
		k := when_kw_index(n)
		if k >= 0 && n.fields[k].text != "else" do option(&out, "Change condition", "cond")
	case .Assert:
		title = "#assert"
		option(&out, "Change condition", "cond")
		filled, _ := assert_message(n)
		option(&out, "Add message", "msg", filled)
	case .Attr:
		title = "Attributes"
		attr_options(app, ni, &out)
	case .Directive:
		title = "Struct directives"
		directive_options(app, ni, &out)
	case .Callconv:
		title = "Calling convention"
		callconv_options(app, ni, &out)
	}
	if len(out) == 0 do return
	if app.slot_menu != nil do free_entries(app.slot_menu)
	app.slot_menu = make([]Entry, len(out))
	copy(app.slot_menu, out[:])
	app.ctrl_menu = kind
	app.ctrl_ni, app.ctrl_fi = ni, fi
	app.ctrl_from_pick = from_pick
	clear_nav(app)
	app.return_state = .Editor
	app.state = .Radial
	push_menu(app, title, app.slot_menu)
}

// An option was chosen.
ctrl_menu_choose :: proc(app: ^App, e: Entry) {
	if e.dim do return // not possible here (already there / not allowed): the menu stays open
	kind := app.ctrl_menu
	id := strings.clone(e.call_name, context.temp_allocator)
	ni, fi := app.ctrl_ni, app.ctrl_fi
	app.ctrl_menu = .None
	app.ctrl_from_pick = false
	app.mod_pick_active = false
	clear_nav(app)
	if app.slot_menu != nil {
		free_entries(app.slot_menu)
		app.slot_menu = nil
	}
	app.state = .Editor
	if ni < 0 || ni >= len(app.doc.nodes) do return
	switch kind {
	case .None:
	case .When_Chain:
		infos := block_infos(app)
		h := infos[ni].chain
		switch id {
		case "else_when": if h >= 0 do add_when_branch(app, h, true)
		case "else":      if h >= 0 do add_when_branch(app, h, false)
		case "cond":      if k := when_kw_index(app.doc.nodes[ni]); k >= 0 do reset_condition(app, ni, k)
		}
	case .Assert:
		switch id {
		case "cond": reset_assert_condition(app, ni)
		case "msg":  add_assert_message(app, ni)
		}
	case .Attr:      apply_attribute(app, ni, id)
	case .Directive: apply_directive(app, ni, id)
	case .Callconv:  apply_callconv(app, ni, id)
	}
}

// B in an options menu: back to the file (or to picking the declaration).
ctrl_menu_cancel :: proc(app: ^App) {
	from_pick := app.ctrl_from_pick
	app.ctrl_menu = .None
	app.ctrl_from_pick = false
	if app.slot_menu != nil {
		free_entries(app.slot_menu)
		app.slot_menu = nil
	}
	app.state = .Editor
	if from_pick do mod_pick_focus(app, app.mod_pick_line)
}

// ---- HUD hint ----

// ctrl_hint: what Y / LT+B do on the highlighted keyword ("" = nothing special).
ctrl_hint :: proc(app: ^App) -> string {
	if app.state != .Editor || app.mod_pick_active do return ""
	if on_attr_dot(app) do return "A: attributes  (test, private, ...)" // the purple dot (attr_dots.odin)
	if h := branch_hint(app); h != "" do return h // if / switch / case (branch.odin)
	if h := loop_hint(app); h != "" do return h // loops, `+=`, break / continue (loops.odin)
	ni, fi, ok := editor_target(app)
	if !ok do return ""
	n := app.doc.nodes[ni]
	f := n.fields[fi]
	if is_attr_line(n) do return "Y: add attribute    LT+B: remove it"
	if _, _, in_dir := directive_span(n, fi); in_dir do return "Y: add directive    LT+B: remove it"
	if f.slot || f.kind != KW do return ""
	switch {
	case f.text == "when":      return "Y: add else / else when, change condition    LT+B: delete"
	case f.text == "else when": return "Y: add else / else when, change condition    LT+B: remove branch"
	case f.text == "else":      return "Y: add else when    LT+B: remove branch"
	case f.text == "#assert":   return "Y: change condition / add message    LT+B: delete"
	case is_callconv_kw(f):     return "Y: change convention    LT+B: remove it"
	}
	return ""
}

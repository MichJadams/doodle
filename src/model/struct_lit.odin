package model

// Struct literals with named fields:
//
//     window_class := win32.WNDCLASSW{style = ●, lpfnWndProc = main_window_callback, ●}
//
// "Struct literal" in a value dot's menu asks for the type (the dot's expected
// type first, then the struct types of each import and of this file) and
// inserts `T{●}`. The green "fields" dot inside opens a menu of the fields not
// set yet ("style   UINT"); picking one inserts `style = ●` (an orange dot that
// expects the field's type) and keeps a fields dot after it while fields are
// left. Unfilled fields dots aren't saved, so an untouched literal is `T{}`.
// A long literal is saved one field per line, like a long call:
//
//     window_class := win32.WNDCLASSW{
//         style = win32.CS_OWNDC | win32.CS_HREDRAW | win32.CS_VREDRAW,
//         lpfnWndProc = main_window_callback,
//     }
//
// Fields on a line: the type (fixed text), "{" / "}" (kind LIT_KIND), and per
// field: the field name (kind LIT_KEY_KIND), " = ", the value's fields, ", ".
// LT+B on a field's name or value removes that field; Y on its value refills it.

import "core:fmt"
import "core:strings"

LIT_KIND       :: "lit"        // a struct literal's "{" / "}" field
LIT_KEY_KIND   :: "litkey"     // a field name inside a struct literal
FIELDS_KIND    :: "fields"     // the green dot inside a literal: add a field
LIT_BREAK      :: "break"      // hint on a literal's "{": keep it one field per line (loaded that way)
LIT_ALIGNED    :: "aligned"    // hint_pkg on a loaded LIT_BREAK "{": its `=` signs were aligned - keep re-aligning them
LIT_TYPE_FILL  :: "__lit_type__"  // "Struct literal" leaf: call_pkg.call_name (or call_name) is the type
LIT_FIELD_FILL :: "__lit_field__" // fields-dot leaf: call_name = field, ret/ret_pkg = its type
ZERO_DECL_FILL :: "__stmt_zero__" // "Variable (no value)": name: ●

is_lit_open  :: proc(f: Field) -> bool { return !f.slot && f.kind == LIT_KIND && strings.has_suffix(f.text, "{") }
is_lit_close :: proc(f: Field) -> bool { return !f.slot && f.kind == LIT_KIND && f.text == "}" }

// Dots that are optional and left out of the saved source: a call's green
// "add argument" dot and a literal's "add a field" dot.
is_optional_dot :: proc(f: Field) -> bool { return f.slot && (f.kind == "args" || f.kind == FIELDS_KIND || f.kind == RES_MORE_KIND || f.kind == RET_MORE_KIND) } // + another result / return value (result_list.odin)

@(private = "file")
opens :: proc(f: Field) -> bool { return !f.slot && (f.text == "(" || f.text == "( " || is_lit_open(f)) }
@(private = "file")
closes :: proc(f: Field) -> bool { return !f.slot && (f.text == ")" || f.text == " )" || is_lit_close(f)) }
@(private = "file")
is_comma :: proc(f: Field) -> bool { return !f.slot && f.text == ", " }

// The "}" matching the literal "{" at fields[open], or -1.
lit_close_of :: proc(n: Node, open: int) -> int {
	depth := 0
	for i in open ..< len(n.fields) {
		f := n.fields[i]
		if opens(f) do depth += 1
		else if closes(f) {
			depth -= 1
			if depth == 0 do return is_lit_close(f) ? i : -1
		}
	}
	return -1
}

// The literal "{" directly enclosing field fi, or -1.
lit_open_around :: proc(n: Node, fi: int) -> int {
	depth := 0
	for k := fi - 1; k >= 0; k -= 1 {
		f := n.fields[k]
		if closes(f) do depth += 1
		else if opens(f) {
			if depth == 0 do return is_lit_open(f) ? k : -1
			depth -= 1
		}
	}
	return -1
}

// The type text of the literal opened at fields[open] ("win32.WNDCLASSW").
lit_type :: proc(n: Node, open: int) -> Var_Type {
	if open <= 0 do return {}
	return Var_Type{strings.trim_space(n.fields[open - 1].text), ""}
}

// The field names already set in the literal opened at fields[open].
@(private = "file")
lit_keys :: proc(n: Node, open: int) -> []string {
	out := make([dynamic]string, 0, 8, context.temp_allocator)
	close := lit_close_of(n, open)
	if close < 0 do return out[:]
	depth := 0
	for i in open + 1 ..< close {
		f := n.fields[i]
		if opens(f) do depth += 1
		else if closes(f) do depth -= 1
		else if depth == 0 && !f.slot && f.kind == LIT_KEY_KIND do append(&out, f.text)
	}
	return out[:]
}

// The fields a literal of type t can set (promoted `using` fields can't be named).
@(private = "file")
settable_fields :: proc(app: ^App, t: Var_Type) -> []Struct_Field {
	out := make([dynamic]Struct_Field, 0, 8, context.temp_allocator)
	for f in struct_fields(app, t) do if !f.promoted do append(&out, f)
	return out[:]
}

@(private = "file")
unset_fields :: proc(app: ^App, n: Node, open: int) -> []Struct_Field {
	keys := lit_keys(n, open)
	out := make([dynamic]Struct_Field, 0, 8, context.temp_allocator)
	outer: for f in settable_fields(app, lit_type(n, open)) {
		for k in keys do if k == f.name do continue outer
		append(&out, f)
	}
	return out[:]
}

// A field type as a dot hint (document text is copied into the hint pool).
@(private = "file")
hint_of :: proc(app: ^App, t: Var_Type) -> (string, string) {
	if t.expr == "" do return "", ""
	if t.pkg == "" do return intern_hint(app, t.expr), ""
	return t.expr, t.pkg
}

// ---- Inserting ----

// make_struct_literal replaces the value dot at (ni, fi) with `type{●}`.
make_struct_literal :: proc(app: ^App, ni, fi: int, type_text: string) {
	fields := &app.doc.nodes[ni].fields
	if len(fields[fi].text) > 0 do delete(fields[fi].text)
	ordered_remove(fields, fi)
	inject_at(fields, fi,
		Field{strings.clone(type_text), false, false, "", "", ""},
		Field{strings.clone("{"), false, false, LIT_KIND, "", ""},
		Field{"", false, true, FIELDS_KIND, "", ""},
		Field{strings.clone("}"), false, false, LIT_KIND, "", ""},
	)
}

// The type text a "Struct literal" leaf inserts.
lit_fill_type_text :: proc(e: Entry) -> string {
	if e.call_pkg != "" do return fmt.tprintf("%s.%s", e.call_pkg, e.call_name)
	return e.call_name
}

// build_lit_field_menu: the fields dot's menu - the fields not set yet.
build_lit_field_menu :: proc(app: ^App, ni, fi: int) -> []Entry {
	n := app.doc.nodes[ni]
	open := lit_open_around(n, fi)
	out := make([dynamic]Entry, 0, 8)
	defer delete(out)
	if open > 0 {
		for f in unset_fields(app, n, open) {
			h, hp := hint_of(app, f.type)
			append(&out, Entry{
				label = fmt.aprintf("%s   %s", f.name, f.type.expr), owned_label = true,
				fill = LIT_FIELD_FILL, call_name = strings.clone(f.name), ret = h, ret_pkg = hp,
			})
		}
	}
	if len(out) == 0 do append(&out, grp_dim(open > 0 && len(struct_fields(app, lit_type(n, open))) > 0 ? "(all fields set)" : "(fields unknown)"))
	r := make([]Entry, len(out))
	copy(r, out[:])
	return r
}

// lit_add_field replaces the fields dot at (ni, fi) with `name = ●` (the dot
// expects the field's type), plus `, ●` (another fields dot) while fields are left.
lit_add_field :: proc(app: ^App, ni, fi: int, name, hint, hint_pkg: string) {
	n := app.doc.nodes[ni]
	open := lit_open_around(n, fi)
	left := 0
	if open > 0 do for f in unset_fields(app, n, open) do if f.name != name do left += 1
	fields := &app.doc.nodes[ni].fields
	ordered_remove(fields, fi)
	list := make([dynamic]Field, 0, 5, context.temp_allocator)
	append(&list,
		Field{strings.clone(name), false, false, LIT_KEY_KIND, "", ""},
		Field{strings.clone(" = "), false, false, "", "", ""},
		Field{"", false, true, "value", hint, hint != "" ? hint_pkg : ""},
	)
	if left > 0 do append(&list, Field{strings.clone(", "), false, false, "", "", ""}, Field{"", false, true, FIELDS_KIND, "", ""})
	inject_at(fields, fi, ..list[:])
}

// ---- The "Struct literal" type menu ----

// Struct types of an import path (CoreProc shape for the shared menu grouping).
@(private = "file")
struct_types_for_path :: proc(path: string) -> []CoreProc {
	out := make([dynamic]CoreProc, 0, 16, context.temp_allocator)
	// (Polymorphic structs - target "($T: typeid)" - need parameters: `Queue{}` doesn't compile.)
	for t in CORE_TYPES do if t.path == path && t.kind == "struct" && t.target == "" do append(&out, CoreProc{path = t.path, file = t.file, block = t.kind, name = t.name})
	return out[:]
}

// build_struct_lit_entries: the dot's expected type first (when it's a
// struct), then each import's struct types, then this file's structs (and those
// of the package's other files).
build_struct_lit_entries :: proc(app: ^App, slot: Field) -> []Entry {
	out := make([dynamic]Entry, 0, 8)
	defer delete(out)
	if h := slot.hint; h != "" && !strings.has_prefix(h, "^") && is_struct_type(app, Var_Type{h, slot.hint_pkg}) {
		// As written in this file: `win32.WNDCLASSW` for WNDCLASSW in core:sys/windows.
		text := slot.hint_pkg == "" ? h : (is_ident(h) ? doc_type_text(app, h, slot.hint_pkg) : "")
		if text != "" {
			pin := Entry{label = strings.clone(text), owned_label = true, fill = LIT_TYPE_FILL, call_name = strings.clone(text), pinned = true}
			// The label has this file's alias: heat goes by "<import path>.<Name>" (heat.odin).
			if slot.hint_pkg != "" do pin.heat_key = strings.concatenate({slot.hint_pkg, ".", h})
			append(&out, pin)
		}
	}
	imports := collect_imports(app)
	defer delete(imports)
	for imp in imports {
		types := struct_types_for_path(imp.path)
		if len(types) == 0 do continue
		children := build_proc_hierarchy(imp.ref, types)
		retarget_leaves(children, LIT_TYPE_FILL)
		append(&out, Entry{label = fmt.aprintf("%s.", imp.ref), owned_label = true, heat_key = strings.clone(imp.path), children = children})
	}
	pts := insertion_points(app, context.temp_allocator)
	for n, ni in app.doc.nodes {
		if !pts[ni] do continue
		t := strings.trim_space(node_text(n, context.temp_allocator))
		at := strings.index(t, " :: struct")
		if at <= 0 || !is_ident(t[:at]) do continue
		if strings.has_prefix(t[at:], " :: struct(") do continue // polymorphic: `Stack{}` needs parameters
		append(&out, Entry{label = strings.clone(t[:at]), owned_label = true, fill = LIT_TYPE_FILL, call_name = strings.clone(t[:at])})
	}
	// The structs of the package's other files (siblings.odin), unless this file
	// declares the same name: they're this package's types too (bare name, no import).
	own := len(app.sibling_types) > 0 ? own_decl_names(app) : nil
	for st in app.sibling_types {
		if st.kind != "struct" || strings.has_prefix(st.text, "struct(") || st.name in own do continue
		append(&out, Entry{label = strings.clone(st.name), owned_label = true, fill = LIT_TYPE_FILL, call_name = strings.clone(st.name)})
	}
	if len(out) == 0 do append(&out, grp_dim("(no struct types)"))
	r := make([]Entry, len(out))
	copy(r, out[:])
	return r
}

// lit_type_fits: can a literal of this leaf's type fill a dot expecting `exp`?
lit_type_fits :: proc(ctx: ^Type_Ctx, e: Entry, exp: Resolved_Type) -> bool {
	if exp.cat == .Unknown || exp.cat == .Any do return true
	// An import's struct leaf (call_pkg = ref, call_name = Name, ret_pkg = its
	// path) lists only kind "struct" CORE_TYPES rows, so its identity is
	// "path.Name": no resolve_type (a CORE_TYPES scan) per leaf.
	if e.call_pkg != "" && e.ret_pkg != "" do return exp.cat == .Struct && exp.canon == fmt.tprintf("%s.%s", e.ret_pkg, e.call_name)
	return value_fits(resolve_type(ctx, lit_fill_type_text(e), ""), exp)
}

// ---- Deleting (LT+B) ----

// The literal element (`name = value`) containing field fi: fields [start, end).
lit_element_at :: proc(n: Node, fi: int) -> (start, end, open: int, ok: bool) {
	depth := 0
	cand := -1 // where the element containing fi starts, at the level being scanned
	for k := fi; k >= 0; k -= 1 {
		f := n.fields[k]
		if k < fi && closes(f) { depth += 1; continue }
		if k < fi && opens(f) {
			if depth > 0 { depth -= 1; continue }
			st := cand >= 0 ? cand : k + 1
			if is_lit_open(f) && st < len(n.fields) && n.fields[st].kind == LIT_KEY_KIND && st <= fi {
				start, open = st, k
				break
			}
			cand = -1 // inside a call / a fields dot: look further out
			continue
		}
		if k < fi && depth == 0 && is_comma(f) && cand < 0 do cand = k + 1
	}
	if open <= 0 do return
	// The element ends at the next ", " or the closing brace at its level.
	depth = 0
	end = len(n.fields)
	for i in start ..< len(n.fields) {
		f := n.fields[i]
		if opens(f) do depth += 1
		else if closes(f) {
			if depth == 0 { end = i; break }
			depth -= 1
		} else if depth == 0 && is_comma(f) { end = i; break }
	}
	return start, end, open, true
}

@(private = "file")
remove_fields :: proc(fields: ^[dynamic]Field, a, b: int) {
	for i in a ..< b do if len(fields[i].text) > 0 do delete(fields[i].text)
	remove_range(fields, a, b)
}

// lit_delete_selected (LT+B): a field of a struct literal -> just that field;
// the empty `= ●` of a typed declaration -> just that (`x: T` = its zero value).
// Returns false when it's something else (the whole line goes, as before).
lit_delete_selected :: proc(app: ^App) -> bool {
	ni, u, ok := editor_leaf(app)
	if !ok do return false
	fields := &app.doc.nodes[ni].fields
	fi := leaf_primary_field(app.doc.nodes[ni], u)

	// `name: T = ●` -> `name: T`
	if f := fields[fi]; f.slot && f.kind == "value" && fi > 0 && fi == len(fields) - 1 && strings.trim_space(fields[fi - 1].text) == "=" && !fields[fi - 1].slot {
		typed := false
		for k in 0 ..< fi - 1 do if fields[k].kind == "decl" && strings.trim_space(fields[k].text) == ":" { typed = true; break }
		if typed {
			remove_fields(fields, fi - 1, fi + 1)
			focus_field_index(app, ni, fi - 2)
			return true
		}
	}

	start, end, open, found := lit_element_at(app.doc.nodes[ni], fi)
	if !found do return false
	a, b := start, end
	if b < len(fields) && is_comma(fields[b]) {
		b += 1
	} else if a > 0 && is_comma(fields[a - 1]) {
		a -= 1
	}
	remove_fields(fields, a, b)
	// A field can be added again: make sure the literal has its fields dot.
	if close := lit_close_of(app.doc.nodes[ni], open); close > 0 {
		has_dot := false
		depth := 0
		for i in open + 1 ..< close {
			f := fields[i]
			if opens(f) do depth += 1
			else if closes(f) do depth -= 1
			else if depth == 0 && f.slot && f.kind == FIELDS_KIND do has_dot = true
		}
		if !has_dot {
			if close - 1 > open {
				inject_at(fields, close, Field{strings.clone(", "), false, false, "", "", ""}, Field{"", false, true, FIELDS_KIND, "", ""})
			} else {
				inject_at(fields, close, Field{"", false, true, FIELDS_KIND, "", ""})
			}
		}
		// A literal loaded one field per line, now empty: back to `T{}`.
		if fields[open].hint == LIT_BREAK {
			empty := true
			if c := lit_close_of(app.doc.nodes[ni], open); c > open {
				for i in open + 1 ..< c do if !is_optional_dot(fields[i]) && !is_comma(fields[i]) { empty = false; break }
			}
			if empty {
				delete(fields[open].text)
				fields[open].text = strings.clone("{")
				fields[open].hint = ""
				fields[open].hint_pkg = ""
			}
		}
	}
	focus_field_index(app, ni, min(a, len(fields) - 1))
	return true
}

// ---- Expected types (Y on a field's value) ----

// lit_field_hint: the type the value of element `elem` (a unit inside the
// literal unit `lit`) expects: its field's type.
lit_field_hint :: proc(app: ^App, n: Node, lit, elem: Unit) -> (string, string) {
	open := -1
	for i in lit.fa ..< lit.fb do if is_lit_open(n.fields[i]) { open = i; break }
	if open < 0 do return "", ""
	t, ok := field_type(app, lit_type(n, open), n.fields[elem.fa].text)
	if !ok do return "", ""
	return hint_of(app, t)
}

// ---- "Variable (no value)" ----

// make_zero_decl replaces a body dot with `name: ●` (a typed variable that
// starts as its type's zero value) and adds the next statement line.
make_zero_decl :: proc(app: ^App, ni, fi: int) {
	fields := &app.doc.nodes[ni].fields
	ordered_remove(fields, fi)
	name := generate_ident(app)
	defer delete(name)
	inject_at(fields, fi,
		Field{strings.clone(name), true, false, "", "", ""},
		Field{strings.clone(": "), false, false, "decl", "", ""},
		Field{"", false, true, "type", "", ""},
	)
	new_body: Node
	append(&new_body.fields, Field{strings.clone("    "), false, false, "", "", ""})
	append(&new_body.fields, Field{"", false, true, "body", "", ""})
	inject_at(&app.doc.nodes, ni + 1, new_body)
}

// ---- Loading ----

@(private = "file")
NOT_LIT_TYPES := [?]string{"struct", "union", "enum", "proc", "map", "matrix", "bit_set", "bit_field", "distinct", "if", "for", "switch", "when", "else", "do", "where", "return", "defer"}

// Split at top-level commas, keeping empty parts.
@(private = "file")
split_keep_empty :: proc(s: string) -> []string {
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	depth := 0
	quote: u8 = 0
	start := 0
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if quote != 0 {
			if c == '\\' && quote != '`' { i += 1; continue }
			if c == quote do quote = 0
			continue
		}
		switch c {
		case '"', '\'', '`': quote = c
		case '(', '[', '{':  depth += 1
		case ')', ']', '}':  depth -= 1
		case ',':
			if depth == 0 {
				append(&out, s[start:i])
				start = i + 1
			}
		}
	}
	append(&out, s[start:])
	return out[:]
}

// `T{` / `T {` ending at s[brace]: the type's start, or -1 when it isn't a
// struct literal's type (a keyword, `[3]int`, `map[...]`, ...).
@(private = "file")
lit_type_start :: proc(s: string, brace: int) -> int {
	e := brace
	if e > 0 && s[e - 1] == ' ' do e -= 1
	b := e
	for b > 0 && (is_ident_byte_lit(s[b - 1]) || s[b - 1] == '.') do b -= 1
	// A parameterised type: `Stack(int){`.
	if b == e && e > 0 && s[e - 1] == ')' {
		depth := 0
		p := -1
		for k := e - 1; k >= 0; k -= 1 {
			if s[k] == ')' do depth += 1
			else if s[k] == '(' {
				depth -= 1
				if depth == 0 { p = k; break }
			}
		}
		if p <= 0 do return -1
		pb := p
		for pb > 0 && (is_ident_byte_lit(s[pb - 1]) || s[pb - 1] == '.') do pb -= 1
		if pb == p || !(s[pb] < '0' || s[pb] > '9') do return -1
		for part in strings.split(s[pb:p], ".", context.temp_allocator) do if !is_ident(part) do return -1
		for k in NOT_LIT_TYPES do if s[pb:p] == k do return -1
		if pb > 0 && (s[pb - 1] == ']' || s[pb - 1] == '^' || s[pb - 1] == ')') do return -1
		return pb
	}
	ty := s[b:e]
	if ty == "" || !(s[b] < '0' || s[b] > '9') do return -1
	parts := strings.split(ty, ".", context.temp_allocator)
	if len(parts) > 2 do return -1
	for p in parts do if !is_ident(p) do return -1
	for k in NOT_LIT_TYPES do if ty == k do return -1
	if b > 0 && (s[b - 1] == ']' || s[b - 1] == '^' || s[b - 1] == ')') do return -1
	return b
}

@(private = "file")
is_ident_byte_lit :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

// One element `name = value` (exactly as written; `value` may be empty).
@(private = "file")
split_element :: proc(p: string) -> (key, eq, value: string, ok: bool) {
	k := 0
	for k < len(p) && is_ident_byte_lit(p[k]) do k += 1
	if k == 0 || !is_ident(p[:k]) do return
	e := k
	for e < len(p) && p[e] == ' ' do e += 1
	if e >= len(p) || p[e] != '=' || (e + 1 < len(p) && p[e + 1] == '=') do return
	e += 1
	for e < len(p) && p[e] == ' ' do e += 1
	value = p[e:]
	if value != strings.trim_right_space(value) do return
	return p[:k], p[k:e], value, true
}

// Append a literal's elements (", "-separated `name = value`). `parts` are
// already split; false when one isn't `name = value`.
@(private = "file")
emit_elements :: proc(fields: ^[dynamic]Field, parts: []string) -> bool {
	for p, i in parts {
		key, eq, value, ok := split_element(p)
		if !ok do return false
		if i > 0 do append(fields, Field{strings.clone(", "), false, false, "", "", ""})
		append(fields, Field{strings.clone(key), false, false, LIT_KEY_KIND, "", ""})
		append(fields, Field{strings.clone(eq), false, false, "", "", ""})
		if value == "" {
			append(fields, Field{"", false, true, "value", "", ""})
		} else {
			emit_expr(fields, value)
		}
	}
	return true
}

@(private = "file")
fields_text :: proc(fields: []Field) -> string {
	b := strings.builder_make(context.temp_allocator)
	for f in fields do strings.write_string(&b, f.text)
	return strings.to_string(b)
}

// lit_emit_expr: an argument / value that is a whole struct literal with named
// fields, `T{a = 1, b = x}` (or `T {...}`), appended structured. False (nothing
// appended) when `s` isn't one or wouldn't come back exactly as written.
lit_emit_expr :: proc(fields: ^[dynamic]Field, s: string) -> bool {
	if len(s) < 3 || s[len(s) - 1] != '}' do return false
	brace := strings.index_byte(s, '{')
	if brace <= 0 || match_bracket(s, brace) != len(s) - 1 do return false
	if lit_type_start(s, brace) != 0 do return false
	ty := strings.trim_right_space(s[:brace])
	inner := s[brace + 1:len(s) - 1]
	parts: []string
	if inner != "" {
		parts = split_keep_empty(inner)
		for &p, i in parts {
			if i > 0 {
				if !strings.has_prefix(p, " ") do return false
				p = p[1:]
			}
		}
	}
	mark := len(fields)
	append(fields, Field{strings.clone(ty), false, false, "", "", ""})
	append(fields, Field{strings.clone(s[len(ty):brace + 1]), false, false, LIT_KIND, "", ""})
	ok := emit_elements(fields, parts)
	append(fields, Field{strings.clone("}"), false, false, LIT_KIND, "", ""})
	if !ok || fields_text(fields[mark:]) != s {
		for i in mark ..< len(fields) do if len(fields[i].text) > 0 do delete(fields[i].text)
		resize(fields, mark)
		return false
	}
	return true
}

@(private = "file")
free_node :: proc(n: ^Node) {
	for f in n.fields do if len(f.text) > 0 do delete(f.text)
	delete(n.fields)
	n.fields = nil
}

// parse_lit_statement: a statement whose value is a struct literal,
//     [indent] (lhs := | lhs = | lhs: T = | return ) T{name = value, ...}
// on one line, or over several (one field per line, `}` on its own line).
// Returns the node and how many lines it used; false unless the lines come
// back exactly as written.
parse_lit_statement :: proc(lines: []string) -> (node: Node, consumed: int, ok: bool) {
	first := lines[0]
	ind := 0
	for ind < len(first) && (first[ind] == ' ' || first[ind] == '\t') do ind += 1
	s := first[ind:]
	if strings.contains(s, "//") do return
	brace := strings.index_byte(s, '{')
	if brace <= 0 do return
	b := lit_type_start(s, brace)
	if b <= 0 do return
	prefix := strings.trim_right_space(s[:b])
	if strings.contains_any(prefix, "({[\"'`") do return
	if !(prefix == "return" || (strings.has_suffix(prefix, "=") && !strings.has_suffix(prefix, "==") &&
	     !strings.has_suffix(prefix, "!=") && !strings.has_suffix(prefix, "<=") && !strings.has_suffix(prefix, ">="))) {
		return
	}
	if strings.has_prefix(prefix, "for ") || strings.has_prefix(prefix, "if ") || strings.has_prefix(prefix, "when ") || strings.has_prefix(prefix, "switch ") do return

	node.fields = make([dynamic]Field)
	emit_names_prefix(&node.fields, first[:ind + b])
	close := match_bracket(s, brace)
	if close == len(s) - 1 {
		// One line.
		if !lit_emit_expr(&node.fields, s[b:]) { free_node(&node); return }
		if node_source(node, context.temp_allocator) != first { free_node(&node); return }
		return node, 1, true
	}
	if close >= 0 || brace != len(s) - 1 { free_node(&node); return }

	// Over several lines: one `name = value,` per line, then `}`.
	ty := strings.trim_right_space(s[b:brace])
	append(&node.fields, Field{strings.clone(ty), false, false, "", "", ""})
	open := len(node.fields)
	append(&node.fields, Field{strings.clone(s[b + len(ty):]), false, false, LIT_KIND, LIT_BREAK, ""})
	parts := make([dynamic]string, 0, 8, context.temp_allocator)
	end := -1
	for li in 1 ..< min(len(lines), 256) {
		t := strings.trim_space(lines[li])
		if t == "}" { end = li; break }
		if !strings.has_suffix(t, ",") || strings.contains(t, "//") { free_node(&node); return }
		append(&parts, t[:len(t) - 1])
	}
	if end < 0 || !emit_elements(&node.fields, parts[:]) { free_node(&node); return }
	mark_lit_aligned(&node, open)
	append(&node.fields, Field{strings.clone("}"), false, false, LIT_KIND, "", ""})
	out := node_source_lines(node)
	if len(out) != end + 1 { free_node(&node); return }
	for l, i in out {
		if fixup_line(l, context.temp_allocator) != lines[i] { free_node(&node); return }
	}
	return node, end + 1, true
}

// mark_lit_aligned (parse_lit_statement): a loaded `T {` literal whose `=`
// signs line up one past its longest name (as odinfmt writes it) gets
// LIT_ALIGNED and plain " = " separators, so format.odin re-pads every row
// after a field is added or removed. Other loaded spacing is kept as written.
@(private = "file")
mark_lit_aligned :: proc(node: ^Node, open: int) {
	fields := node.fields[:]
	if !strings.has_prefix(fields[open].text, " ") do return
	keys := make([dynamic]int, 0, 8, context.temp_allocator)
	depth := 0
	for i in open + 1 ..< len(fields) {
		f := fields[i]
		if is_lit_open(f) { depth += 1; continue }
		if is_lit_close(f) { depth -= 1; continue }
		if depth != 0 || f.slot || f.kind != LIT_KEY_KIND || i + 1 >= len(fields) do continue
		sep := fields[i + 1]
		if sep.slot || strings.trim_space(sep.text) != "=" do continue
		append(&keys, i)
	}
	if len(keys) < 2 do return
	key_w := 0
	for k in keys do key_w = max(key_w, len(fields[k].text))
	for k in keys {
		sep := fields[k + 1].text
		eq := strings.index_byte(sep, '=')
		if len(fields[k].text) + eq != key_w + 1 || !strings.has_suffix(sep, "= ") do return
	}
	for k in keys {
		delete(fields[k + 1].text)
		fields[k + 1].text = strings.clone(" = ")
	}
	fields[open].hint_pkg = LIT_ALIGNED
}

// attach_lit_hints (after loading): the empty values of loaded literals expect
// their field's type, and literals with fields left to set get a fields dot.
attach_lit_hints :: proc(app: ^App) {
	for ni in 0 ..< len(app.doc.nodes) {
		opens_at := make([dynamic]int, 0, 2, context.temp_allocator)
		for f, i in app.doc.nodes[ni].fields do if is_lit_open(f) do append(&opens_at, i)
		#reverse for open in opens_at {
			n := app.doc.nodes[ni]
			close := lit_close_of(n, open)
			if close < 0 do continue
			t := lit_type(n, open)
			depth := 0
			has_dot := false
			for i in open + 1 ..< close {
				f := n.fields[i]
				if opens(f) do depth += 1
				else if closes(f) do depth -= 1
				else if depth == 0 && f.slot && f.kind == FIELDS_KIND do has_dot = true
				else if depth == 0 && f.slot && f.kind == "value" && f.hint == "" && i >= 2 && n.fields[i - 2].kind == LIT_KEY_KIND {
					if ft, ok := field_type(app, t, n.fields[i - 2].text); ok {
						h, hp := hint_of(app, ft)
						app.doc.nodes[ni].fields[i].hint = intern_hint(app, h)
						app.doc.nodes[ni].fields[i].hint_pkg = intern_hint(app, hp)
					}
				}
			}
			if has_dot || len(unset_fields(app, n, open)) == 0 do continue
			fields := &app.doc.nodes[ni].fields
			if close - 1 > open {
				inject_at(fields, close, Field{strings.clone(", "), false, false, "", "", ""}, Field{"", false, true, FIELDS_KIND, "", ""})
			} else {
				inject_at(fields, close, Field{"", false, true, FIELDS_KIND, "", ""})
			}
		}
	}
}

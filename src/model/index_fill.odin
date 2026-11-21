package model

// Index expressions: `items[i]`, `m["key"]`, `player.items[i]`.
//
// Reference -> pick a name -> "Pass as" gains "items[i]   T" when the name's
// type can be indexed (array, slice, dynamic array, map, string; aliases
// followed); "Field of" lists `player.items[i]` for such fields. The dot is
// filled with `items[` ● `]`, the key dot typed from the map's key type (int
// for the others). Grayed when the element type can't fill the dot.
//
// Types: `m[k]` is the map's value type (an element for the others, u8 for a
// string), and the "comma ok" forms `v, ok := m[k]` / `v, ok := x.(T)` give
// v that type and ok a bool (comma_ok_type, used by var_types.odin).

import "core:fmt"
import "core:strings"

INDEX_FILL :: "__index__" // call_name: the indexed path; call_pkg: "<key type>|<its package>"

// index_types: the key and element types of indexable type t.
index_types :: proc(app: ^App, t: Var_Type, depth := 0) -> (key, elem: Var_Type, ok: bool) {
	if depth > 6 do return
	e := strings.trim_space(t.expr)
	for strings.has_prefix(e, "distinct ") do e = strings.trim_space(e[len("distinct "):])
	switch {
	case strings.has_prefix(e, "map["):
		close := match_bracket(e, 3)
		if close < 0 do return
		return Var_Type{strings.trim_space(e[4:close]), t.pkg}, Var_Type{strings.trim_space(e[close + 1:]), t.pkg}, true
	case strings.has_prefix(e, "["):
		close := match_bracket(e, 0)
		if close < 0 || close + 1 >= len(e) do return
		elem = Var_Type{strings.trim_space(e[close + 1:]), t.pkg}
		if k, kok := enum_index_type(app, e[1:close], t.pkg); kok do return k, elem, true // `[Dir]f32` (enum_index.odin)
		return Var_Type{"int", ""}, elem, true
	case e == "string":
		return Var_Type{"int", ""}, Var_Type{"u8", ""}, true
	}
	// An alias / distinct type: `Grid :: [8][8]int`, `Lookup :: map[string]int`.
	if dot := strings.index_byte(e, '.'); dot > 0 {
		path := ""
		if t.pkg == "" {
			imports := collect_imports(app)
			defer delete(imports)
			for imp in imports do if imp.ref == e[:dot] { path = strings.clone(imp.path, context.temp_allocator); break }
		}
		if path == "" do return
		if i, found := core_type_index(path, e[dot + 1:]); found {
			ct := CORE_TYPES[i]
			if ct.kind == "alias" || ct.kind == "distinct" do return index_types(app, Var_Type{ct.target, ct.path}, depth + 1)
		}
		return
	}
	if !is_ident(e) do return
	if t.pkg != "" {
		if i, found := core_type_index(t.pkg, e); found {
			ct := CORE_TYPES[i]
			if ct.kind == "alias" || ct.kind == "distinct" do return index_types(app, Var_Type{ct.target, ct.path}, depth + 1)
		}
		return
	}
	for n in app.doc.nodes {
		txt := strings.trim_space(node_text(n, context.temp_allocator))
		if !strings.has_prefix(txt, e) do continue
		rest := strings.trim_left_space(txt[len(e):])
		if !strings.has_prefix(rest, "::") do continue
		rest = strings.trim_space(rest[2:])
		if rest == "" || strings.has_prefix(rest, "struct") || strings.has_prefix(rest, "proc") do return
		return index_types(app, Var_Type{rest, ""}, depth + 1)
	}
	// A type of another file of the package (siblings.odin).
	if rest, found := sibling_type_rhs(app, e); found { // (as seen from here: may be written in another package)
		if rest.expr == "" || strings.has_prefix(rest.expr, "struct") || strings.has_prefix(rest.expr, "proc") do return
		return index_types(app, rest, depth + 1)
	}
	return
}

// The menu entry for indexing `path` (of type t): nil-ok when t can't be indexed.
index_entry :: proc(app: ^App, ctx: ^Type_Ctx, path: string, t: Var_Type, exp: Resolved_Type) -> (e: Entry, fits: bool, ok: bool) {
	key, elem, iok := index_types(app, t)
	if !iok do return
	fits = exp.cat == .Unknown || exp.cat == .Any || value_fits(resolve_type(ctx, elem.expr, elem.pkg), exp)
	k := strings.has_prefix(strings.trim_space(t.expr), "map[") ? "key" : "i"
	e = Entry{
		label = fmt.aprintf("%s[%s]   %s", path, k, elem.expr),
		owned_label = true,
		fill = INDEX_FILL,
		call_name = strings.clone(path),
		call_pkg = strings.concatenate({key.expr, "|", key.pkg}),
		dim = !fits,
	}
	return e, fits, true
}

// append_index_entries: "items[i]" in the "Pass as" options for a picked name.
append_index_entries :: proc(app: ^App, pick: Ref_Target, slot: Field, out: ^[dynamic]Entry) {
	name := app.doc.nodes[pick.ni].fields[pick.fi].text
	t, ok := picked_type(app, pick, app.ref_ni)
	if !ok do return
	ctx := type_ctx_make(app)
	if e, _, iok := index_entry(app, &ctx, name, t, slot_expected_type(&ctx, slot)); iok do append(out, e)
}

// ref_pass_index: the "Pass as" choice `path[●]`: the dot becomes the index
// expression with a key dot (the cursor goes there).
ref_pass_index :: proc(app: ^App, e: Entry) {
	app.ref_pass_active = false
	app.ref_pick_active = false
	ni, fi := app.ref_ni, app.ref_fi
	if ni < 0 || ni >= len(app.doc.nodes) || fi < 0 || fi >= len(app.doc.nodes[ni].fields) do return
	fields := &app.doc.nodes[ni].fields
	f := fields[fi]
	if !f.slot do return
	key, key_pkg := e.call_pkg, ""
	if bar := strings.index_byte(key, '|'); bar >= 0 do key, key_pkg = key[:bar], key[bar + 1:]
	was_args := f.kind == "args"
	hint, hint_pkg := f.hint, f.hint_pkg
	if len(f.text) > 0 do delete(f.text)
	ordered_remove(fields, fi)
	inject_at(fields, fi,
		Field{strings.concatenate({e.call_name, "["}), false, false, "", "", ""},
		Field{"", false, true, "value", intern_hint(app, key), intern_hint(app, key_pkg)},
		Field{strings.clone("]"), false, false, "", "", ""},
	)
	if was_args do append_more_args_slot(fields, fi, 3, hint, hint_pkg)
	if app.refill_active do refill_discard(app)
	focus_field_index(app, ni, fi + 1)
}

// The `[` matching the `]` that ends s (strings skipped), or -1.
index_open :: proc(s: string) -> int {
	if len(s) == 0 || s[len(s) - 1] != ']' do return -1
	depth := 0
	for k := len(s) - 1; k >= 0; k -= 1 {
		switch s[k] {
		case ']', ')', '}': depth += 1
		case '[', '(', '{':
			depth -= 1
			if depth == 0 do return s[k] == '[' ? k : -1
		case '"', '\'', '`':
			q := s[k]
			k -= 1
			for k >= 0 && s[k] != q do k -= 1
		}
	}
	return -1
}

// comma_ok_type: the idx-th name of `a, b := value` for the comma-ok forms
// (`m[k]` on a map, a type assertion `x.(T)`), seen from line ni.
comma_ok_type :: proc(app: ^App, ni: int, value: string, idx: int) -> (Var_Type, bool) {
	v := strings.trim_space(value)
	if idx != 0 && idx != 1 do return {}, false
	if open := index_open(v); open > 0 {
		base, ok := expr_type_at(app, ni, v[:open])
		if !ok || !is_map_type(app, base) do return {}, false
		_, elem, iok := index_types(app, base)
		if !iok do return {}, false
		return idx == 0 ? elem : Var_Type{"bool", ""}, true
	}
	if strings.has_suffix(v, ")") {
		if at := strings.last_index(v, ".("); at > 0 {
			ty := strings.trim_space(v[at + 2:len(v) - 1])
			if ty == "" do return {}, false
			return idx == 0 ? Var_Type{ty, ""} : Var_Type{"bool", ""}, true
		}
	}
	return {}, false
}

// Does t resolve (through aliases) to a map type?
@(private = "file")
is_map_type :: proc(app: ^App, t: Var_Type, depth := 0) -> bool {
	if depth > 6 do return false
	e := strings.trim_space(t.expr)
	if strings.has_prefix(e, "map[") do return true
	if !is_ident(e) || t.pkg != "" do return false
	for n in app.doc.nodes {
		txt := strings.trim_space(node_text(n, context.temp_allocator))
		if !strings.has_prefix(txt, e) do continue
		rest := strings.trim_left_space(txt[len(e):])
		if !strings.has_prefix(rest, "::") do continue
		return is_map_type(app, Var_Type{strings.trim_space(rest[2:]), ""}, depth + 1)
	}
	if rest, found := sibling_type_rhs(app, e); found do return is_map_type(app, rest, depth + 1) // another file's type
	return false
}

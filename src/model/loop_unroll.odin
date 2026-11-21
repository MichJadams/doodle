package model

// `#unroll for` needs compile-time values (Odin: "Interval expressions must be
// constant", "An '#unroll for' expression must be known at compile time"):
// a range's ends and a string iterable must be constants. So:
//   - Y on `for` > "Add #unroll" is dimmed over a range / string that isn't constant;
//   - on an #unroll loop's range-end dots, calls are dimmed in the value menu,
//     and Reference > Pass as dims names that aren't constants (`count := 3`;
//     `N :: 3` stays);
//   - on an #unroll loop's iterable dot, Reference dims a string variable, and
//     the value menu dims calls returning a string.
// (Arrays, also from a call, are fine.)

import "core:strings"

@(private = "file")
CONV_TYPES := [?]string{
	"int", "uint", "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "uintptr", "byte",
	"f16", "f32", "f64", "rune", "bool", "string",
}

@(private = "file")
is_word_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

// unroll_const_name: is `name` (a name or pkg.NAME), seen from line at, a compile-time constant?
unroll_const_name :: proc(app: ^App, at: int, name: string) -> bool {
	name := strings.trim_space(name)
	if name == "" do return true
	if name == "true" || name == "false" || name == "nil" do return true
	if _, ok := builtin_const(name); ok do return true
	if dot := strings.index_byte(name, '.'); dot > 0 {
		ref, nm := name[:dot], name[dot + 1:]
		imports := collect_imports(app)
		defer delete(imports)
		for imp in imports do if imp.ref == ref {
			for c in CORE_CONSTS do if c.path == imp.path && c.name == nm do return true
			return false
		}
		return false // a field of a value
	}
	if !is_ident(name) do return false
	n := len(app.doc.nodes)
	at := clamp(at, 0, max(n - 1, 0))
	// The nearest declaration in scope inside the procedure.
	scope := ref_scope_make(app, at)
	if scope.start >= 0 {
		for j := at - 1; j > scope.start; j -= 1 {
			if !scope.visible[j - scope.start] do continue
			if _, found, hdr := loop_header_declares(app, j, name, true); hdr {
				if found && at <= loop_block_end(app, j) do return false // a loop variable
				continue
			}
			if _, found := branch_declares(app, j, at, name, 0); found do return false // an if / switch name
			if is_const, found := line_names(app, j, name); found do return is_const
		}
		if _, hdr, ok := enclosing_proc(app, at); ok {
			for p in parse_params(hdr) do if p.name == name do return false
		}
	}
	// File scope: `N :: 3` (not a type or a procedure).
	if rhs, found := doc_type_rhs(app, name); found {
		for kw in ([]string{"proc", "struct", "enum", "union", "bit_set", "bit_field", "distinct", "#type", "map[", "[", "^", "matrix"}) {
			if strings.has_prefix(rhs, kw) do return false
		}
		return true
	}
	return false
}

// Does line j declare `name` (`name :: v` -> is_const; `name := v`, `name: T` -> not)?
@(private = "file")
line_names :: proc(app: ^App, j: int, name: string) -> (is_const, found: bool) {
	t := strings.trim_space(strip_comment(node_text(app.doc.nodes[j], context.temp_allocator)))
	colon := strings.index_byte(t, ':')
	if colon <= 0 do return
	head := t[:colon]
	for c in transmute([]u8)head do if !(is_word_byte(c) || c == ',' || c == ' ' || c == '\t') do return
	for nm in strings.split(head, ",", context.temp_allocator) {
		if strings.trim_space(nm) == name do return strings.has_prefix(t[colon:], "::"), true
	}
	return
}

// unroll_const_expr: is expression text `s` (seen from line at) made of constants only?
unroll_const_expr :: proc(app: ^App, at: int, s: string) -> bool {
	i := 0
	prev: u8 = 0 // the previous non-space byte
	for i < len(s) {
		c := s[i]
		switch {
		case c == '"' || c == '`' || c == '\'':
			q := c
			i += 1
			for i < len(s) && s[i] != q {
				if s[i] == '\\' && q != '`' do i += 1
				i += 1
			}
			i += 1
			prev = q
		case c >= '0' && c <= '9':
			for i < len(s) && (is_word_byte(s[i]) || (s[i] == '.' && i + 1 < len(s) && s[i + 1] >= '0' && s[i + 1] <= '9')) do i += 1
			prev = '0'
		case is_word_byte(c):
			st := i
			for i < len(s) && (is_word_byte(s[i]) || (s[i] == '.' && i + 1 < len(s) && is_word_byte(s[i + 1]))) do i += 1
			word := s[st:i]
			k := i
			for k < len(s) && s[k] == ' ' do k += 1
			if prev == '.' {
				// `.North`: an enum value
			} else if k < len(s) && s[k] == '(' {
				conv := false
				for ty in CONV_TYPES do if ty == word { conv = true; break }
				if !conv do return false // a call (its result isn't constant)
			} else if !unroll_const_name(app, at, word) {
				return false
			}
			prev = 'a'
		case:
			if c != ' ' && c != '\t' do prev = c
			i += 1
		}
	}
	return true
}

// The text of fields [a, b) of n, a dot standing for a constant still to choose.
@(private = "file")
region_text :: proc(n: Node, a, b: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for k in a ..< b {
		if n.fields[k].slot do strings.write_string(&sb, " 0 ")
		else do strings.write_string(&sb, n.fields[k].text)
	}
	return strings.to_string(sb)
}

// unroll_iter_const (open_loop_options): the loop's iterable (a range / a
// string) is made of constants.
unroll_iter_const :: proc(app: ^App, ni: int, h: Loop_Hdr) -> bool {
	if h.form != .In || h.iter_a < 0 || h.iter_b <= h.iter_a do return true
	return unroll_const_expr(app, ni, region_text(app.doc.nodes[ni], h.iter_a, h.iter_b))
}

@(private = "file")
is_unroll_loop :: proc(n: Node) -> (h: Loop_Hdr, ok: bool) {
	h, ok = loop_hdr(n)
	if !ok || h.form != .In || h.directive < 0 || n.fields[h.directive].text != "#unroll" do return h, false
	return h, true
}

// A dot at one end of an #unroll loop's range.
is_unroll_range_end_dot :: proc(n: Node, fi: int) -> bool {
	h, ok := is_unroll_loop(n)
	if !ok || fi < h.iter_a || fi >= h.iter_b || !n.fields[fi].slot || h.iter_b - h.iter_a < 2 do return false
	for k in h.iter_a ..< h.iter_b {
		f := n.fields[k]
		t := strings.trim_space(f.text)
		if !f.slot && !f.editable && (t == "..<" || t == "..=") do return true
	}
	return false
}

@(private = "file")
is_call_fill :: proc(fill: string) -> bool {
	return fill == "__call_import__" || fill == "__call_import_proc__" || fill == "__call_this_pkg__"
}

// Dim the leaves `dim_leaf` says can't go; a group with nothing left is dimmed too.
@(private = "file")
dim_tree :: proc(app: ^App, entries: []Entry, dim_leaf: proc(app: ^App, e: Entry) -> bool) -> (any_fit: bool) {
	for &e in entries {
		if len(e.children) > 0 {
			f := dim_tree(app, e.children, dim_leaf)
			if !f do e.dim = true
			any_fit ||= f
			continue
		}
		if e.fill != "" && dim_leaf(app, e) do e.dim = true
		any_fit ||= !e.dim
	}
	return
}

// unroll_extend_value_menu (after loop_extend_value_menu): calls can't give an
// #unroll loop's range ends, nor its string.
unroll_extend_value_menu :: proc(app: ^App, ni, fi: int) {
	if ni < 0 || ni >= len(app.doc.nodes) do return
	n := app.doc.nodes[ni]
	if is_unroll_range_end_dot(n, fi) {
		dim_tree(app, app.slot_menu, proc(app: ^App, e: Entry) -> bool { return is_call_fill(e.fill) })
		return
	}
	if _, ok := is_unroll_loop(n); ok && is_iterable_dot(n, fi) {
		dim_tree(app, app.slot_menu, proc(app: ^App, e: Entry) -> bool {
			ret := ""
			switch e.fill {
			case "__call_import_proc__": ret = e.ret
			case "__call_this_pkg__":    ret = call_signature(app, "", e.call_name).ret
			case:                        return false
			}
			r := strings.trim_space(ret)
			return r == "string" || r == "cstring"
		})
	}
}

// unroll_pass_as_dims (loop_pass_as_dims): Reference on an #unroll loop's
// range end / string iterable: only constants.
unroll_pass_as_dims :: proc(app: ^App, pick: Ref_Target, out: []Entry) {
	ni, fi := app.ref_ni, app.ref_fi
	if ni < 0 || ni >= len(app.doc.nodes) do return
	n := app.doc.nodes[ni]
	if is_unroll_range_end_dot(n, fi) {
		for &e in out {
			if e.fill == REF_AS_FILL {
				if !unroll_const_expr(app, ni, e.call_name) || strings.has_prefix(e.call_name, "&") || strings.has_suffix(e.call_name, "^") do e.dim = true
			} else {
				e.dim = true // a field / an element of a value
				for &c in e.children do c.dim = true
			}
		}
		return
	}
	if _, ok := is_unroll_loop(n); !ok || !is_iterable_dot(n, fi) do return
	name := app.doc.nodes[pick.ni].fields[pick.fi].text
	t, tok := var_type_at(app, ni, name)
	if !tok do return
	k, _, _ := iter_info(app, t)
	if k != .String || unroll_const_name(app, ni, name) do return
	for &e in out do if e.fill == REF_AS_FILL && e.call_name == name do e.dim = true
}

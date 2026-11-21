package model

// Editing members of data bodies (struct / bit_field / enum / union) beyond
// what data_types.odin does on its own:
//   - LT+B on one name of a shared list (`x, y: f32`, `name, title: string,`)
//     removes just that name and keeps the type for the others;
//   - a member added after a hand-written last member that has no comma
//     (`hp: int` / `A`) gives that member its comma, so the body still parses.

import "core:strings"

is_member_sep :: proc(f: Field) -> bool { return !f.slot && !f.editable && strings.trim_space(f.text) == "," }

// A member name standing alone in a list (`x` in `x, y: f32`).
is_bare_name :: proc(f: Field) -> bool { return !f.slot && f.editable && f.kind == "member" }

// Do the fields of one member hold its type (`: f32`)?
span_has_type :: proc(fs: []Field) -> bool {
	for f in fs do if !f.slot && !f.editable && strings.has_prefix(strings.trim_space(f.text), ":") do return true
	return false
}

// delete_shared_member_name: LT+B on one of several names of a member line in a
// multi-line struct / bit_field body (`\tname, title: string,`). Only that name
// goes; the line (and the type) stay for the others. False when the line has a
// single name or the cursor is on the type (the whole line goes, as before).
delete_shared_member_name :: proc(app: ^App, ni, fi: int) -> bool {
	fs := app.doc.nodes[ni].fields[:]
	if !is_bare_name(fs[fi]) do return false
	if k := data_block_at(app, ni); k != .Struct && k != .Bit_Field do return false
	lo := 0
	for lo < len(fs) && !fs[lo].slot && !fs[lo].editable && strings.trim_space(fs[lo].text) == "" do lo += 1
	s := fi
	for s > lo && !is_member_sep(fs[s - 1]) do s -= 1
	e := fi + 1
	for e < len(fs) && !is_member_sep(fs[e]) do e += 1
	a, b := -1, -1
	switch {
	case e - s == 1 && e < len(fs) && s == fi:
		// A name followed by `, ` and another name: the name and that separator.
		more := false
		for g in fs[e + 1:] do if is_bare_name(g) { more = true; break }
		if more do a, b = s, e + 1
	case span_has_type(fs[s:e]) && s == fi && s - 2 >= lo && is_member_sep(fs[s - 1]) && is_bare_name(fs[s - 2]):
		// The last name of the list: the separator before it and the name.
		a, b = s - 1, s + 1
	}
	if a < 0 do return false
	fields := &app.doc.nodes[ni].fields
	for i in a ..< b do if len(fields[i].text) > 0 do delete(fields[i].text)
	remove_range(fields, a, b)
	focus_field_index(app, ni, max(a - 1, lo))
	return true
}

// ensure_prev_member_comma: after a member was added on line ni of a
// multi-line data body, the member line above it (skipping blank, comment and
// "●" lines; none when the body's header comes first) must end in a comma.
ensure_prev_member_comma :: proc(app: ^App, ni: int) {
	if ni <= 0 || ni >= len(app.doc.nodes) do return
	if strings.contains_any(node_text(app.doc.nodes[ni], context.temp_allocator), "{}") do return // a one-line body
	for j := ni - 1; j >= 0; j -= 1 {
		n := app.doc.nodes[j]
		if is_body_slot_line(n) do continue
		t := node_text(n, context.temp_allocator)
		code := strings.trim_space(t[:comment_at(t)])
		if code == "" do continue
		if strings.has_suffix(code, "{") || strings.has_suffix(code, ",") do return
		if strings.contains_any(code, "{}") do return
		// The last code field: skip a trailing comment / whitespace-only field.
		last := -1
		for f, i in n.fields {
			tt := strings.trim_space(f.text)
			if f.slot || tt == "" || strings.has_prefix(tt, "//") do continue
			last = i
		}
		if last < 0 do return
		inject_at(&app.doc.nodes[j].fields, last + 1, Field{strings.clone(","), false, false, "", "", ""})
		return
	}
}

// Where a `//` comment starts in s (len(s) when there's none), strings skipped.
@(private = "file")
comment_at :: proc(s: string) -> int {
	quote: u8 = 0
	for k := 0; k < len(s); k += 1 {
		c := s[k]
		if quote != 0 {
			if c == '\\' && quote != '`' { k += 1; continue }
			if c == quote do quote = 0
			continue
		}
		switch c {
		case '"', '\'', '`': quote = c
		case '/': if k + 1 < len(s) && s[k + 1] == '/' do return k
		}
	}
	return len(s)
}

// ---- Type names declared in the document (for aliases of them) ----

// doc_declared_type_names: the names of `Name :: <type>` declarations in the
// document, including aliases of those (`Alias :: Player`, chains and forward
// references too), plus the types of the package's other files. Temp-allocated set.
doc_declared_type_names :: proc(app: ^App) -> map[string]bool {
	set := make(map[string]bool, 16, context.temp_allocator)
	Decl :: struct { name, rhs: string }
	decls := make([dynamic]Decl, 0, 16, context.temp_allocator)
	for n in app.doc.nodes {
		t := node_text(n, context.temp_allocator)
		t = strings.trim_space(t[:comment_at(t)])
		if strings.has_prefix(t, "@") {
			// `@(private) Player :: struct {`: past the attribute.
			if strings.has_prefix(t, "@(") {
				close := match_bracket(t, 1)
				if close < 0 do continue
				t = strings.trim_left_space(t[close + 1:])
			} else {
				sp := strings.index_byte(t, ' ')
				if sp < 0 do continue
				t = strings.trim_left_space(t[sp:])
			}
		}
		k := 0
		for k < len(t) && (name_byte(t[k])) do k += 1
		if k == 0 || !is_ident(t[:k]) do continue
		rest := strings.trim_left_space(t[k:])
		if !strings.has_prefix(rest, "::") do continue
		append(&decls, Decl{t[:k], strings.trim_space(rest[2:])})
	}
	// The types of the package's other files (siblings.odin): `Alias :: point`
	// is a type alias when point is declared next door. Their bare-name
	// declarations (`Vec :: point`, kind "ident") join the alias chains below,
	// so they count when they repeat one of this file's types. A name this file
	// declares itself shadows the sibling's.
	own := make(map[string]bool, len(decls), context.temp_allocator)
	for d in decls do own[d.name] = true
	for st in app.sibling_types {
		if st.name in own do continue
		switch st.kind {
		case "proc_type":
		case "ident":     append(&decls, Decl{st.name, st.text})
		case:             set[st.name] = true
		}
	}
	for d in decls {
		r := d.rhs
		for kw in ([]string{"struct", "enum", "union", "bit_field", "distinct"}) {
			if word_starts(r, kw) { set[d.name] = true; break }
		}
		if strings.has_prefix(r, "bit_set[") || strings.has_prefix(r, "[") || strings.has_prefix(r, "^") || strings.has_prefix(r, "map[") do set[d.name] = true
	}
	for changed := true; changed; {
		changed = false
		for d in decls {
			if d.name in set || !is_ident(d.rhs) do continue
			if d.rhs in set {
				set[d.name] = true
				changed = true
			}
		}
	}
	return set
}

@(private = "file")
word_starts :: proc(s, w: string) -> bool {
	if !strings.has_prefix(s, w) do return false
	return len(s) == len(w) || !name_byte(s[len(w)])
}

@(private = "file")
name_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

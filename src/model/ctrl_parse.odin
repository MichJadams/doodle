package model

// Loading compile-time control and modifiers back into the editable structure
// (doc_from_source, parse.odin). Every node's fields concatenate back to
// exactly the source line; anything that doesn't fit the expected shape is left
// as the usual fixed text.
//
//   when ODIN_OS == .Windows {      kw "when", " ", ODIN_OS, " == ", .Windows, " {"
//   } else when ODIN_DEBUG {        "} ", kw "else when", " ", ..., " {"
//   } else {                        "} ", kw "else", " {"
//   #assert(size_of(T) == 8)        kw "#assert", "(", ..., ", " ●message, ")"
//   @(private, link_name="x")       "@(", kw "private", ", ", kw "link_name", "=", '"', x, '"', ")"
//   name :: proc "system" (         ..., " :: proc ", kw "\"system\"", " ("
//   T :: struct #packed {           ..., " :: struct ", kw "#packed", " {"
//   T :: struct #align(16) {        ..., kw "#align(", 16 (editable), ")", " {"

import "core:strings"

Line_Role :: struct {
	kind:      u8,   // 1 = when header, 2 = } else when ... {, 3 = } else { of a when chain
	when_decl: bool, // an indented `name :: ...` declaration inside a file-scope when
}

@(private = "file")
is_simple_decl :: proc(t: string) -> bool {
	idx := strings.index(t, " :: ")
	if idx <= 0 do return false
	return is_ident(t[:idx])
}

// ctrl_line_roles: which source lines are parts of when chains, and which are
// declarations inside a file-scope when.
ctrl_line_roles :: proc(lines: []string) -> []Line_Role {
	out := make([]Line_Role, len(lines), context.temp_allocator)
	Open :: struct { chain, see_through: bool }
	stack := make([dynamic]Open, 0, 16, context.temp_allocator)
	solid := 0
	for line, i in lines {
		t := strings.trim_space(line)
		is_when := strings.has_prefix(t, "when ") && strings.has_suffix(t, "{")
		is_else_when := strings.has_prefix(t, "} else when ") && strings.has_suffix(t, "{")
		is_else := t == "} else {"
		if solid == 0 && len(stack) > 0 && len(line) > 0 && (line[0] == ' ' || line[0] == '\t') && is_simple_decl(t) {
			out[i].when_decl = true
		}
		popped_chain, first := false, true
		for c in line_brace_seq(line) {
			if c == '}' {
				if len(stack) == 0 do continue
				o := pop(&stack)
				if !o.see_through do solid -= 1
				if first { popped_chain = o.chain; first = false }
			} else {
				chain := is_when || ((is_else_when || is_else) && popped_chain)
				see := chain && solid == 0
				append(&stack, Open{chain, see})
				if !see do solid += 1
			}
		}
		switch {
		case is_when:                      out[i].kind = 1
		case is_else_when && popped_chain: out[i].kind = 2
		case is_else && popped_chain:      out[i].kind = 3
		}
	}
	return out
}

@(private = "file")
fields_text :: proc(fs: []Field) -> string {
	b := strings.builder_make(context.temp_allocator)
	for f in fs do strings.write_string(&b, f.text)
	return strings.to_string(b)
}

@(private = "file")
free_fields :: proc(fs: ^[dynamic]Field) {
	for f in fs do if len(f.text) > 0 do delete(f.text)
	delete(fs^)
}

// Structured fields for an expression, only if they give back exactly `text`.
@(private = "file")
expr_fields :: proc(out: ^[dynamic]Field, text: string) -> bool {
	tmp := make([dynamic]Field)
	parse_expr_fields(&tmp, text)
	if fields_text(tmp[:]) != text {
		free_fields(&tmp)
		return false
	}
	append(out, ..tmp[:])
	delete(tmp)
	return true
}

// The index of the `)` matching the `(` at s[open], or -1.
@(private = "file")
match_paren :: proc(s: string, open: int) -> int {
	depth := 0
	quote: u8 = 0
	for k := open; k < len(s); k += 1 {
		c := s[k]
		if quote != 0 {
			if c == '\\' && quote != '`' { k += 1; continue }
			if c == quote do quote = 0
			continue
		}
		switch c {
		case '"', '\'', '`': quote = c
		case '(', '[', '{': depth += 1
		case ')', ']', '}':
			depth -= 1
			if depth == 0 do return k
		}
	}
	return -1
}

// Split at top-level commas.
@(private = "file")
split_commas :: proc(s: string) -> []string {
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	depth := 0
	quote: u8 = 0
	start := 0
	for k := 0; k < len(s); k += 1 {
		c := s[k]
		if quote != 0 {
			if c == '\\' && quote != '`' { k += 1; continue }
			if c == quote do quote = 0
			continue
		}
		switch c {
		case '"', '\'', '`': quote = c
		case '(', '[', '{': depth += 1
		case ')', ']', '}': depth -= 1
		case ',':
			if depth == 0 {
				append(&out, s[start:k])
				start = k + 1
			}
		}
	}
	append(&out, s[start:])
	return out[:]
}

// Arguments written as `a, b, c` (exactly ", " between them): their fields.
@(private = "file")
arg_fields :: proc(out: ^[dynamic]Field, inner: string) -> bool {
	parts := split_commas(inner)
	for p, i in parts {
		if i > 0 {
			if !strings.has_prefix(p, " ") do return false
			append(out, Field{strings.clone(", "), false, false, "", "", ""})
		}
		body := i > 0 ? p[1:] : p
		if body == "" || strings.trim_space(body) != body do return false
		if !expr_fields(out, body) do return false
	}
	return true
}

@(private = "file")
STRING_ATTRS := [?]string{"link_name", "link_prefix", "link_suffix", "link_section", "deprecated", "objc_name", "require_target_feature", "enable_target_feature"}

// One attribute `name` / `name=value`.
@(private = "file")
attr_fields :: proc(out: ^[dynamic]Field, p: string) -> bool {
	if p == "" || strings.trim_space(p) != p do return false
	eq := strings.index_byte(p, '=')
	if eq > 0 {
		name, value := p[:eq], p[eq + 1:]
		is_str := false
		for s in STRING_ATTRS do if s == name { is_str = true; break }
		if is_str && len(value) >= 2 && value[0] == '"' && value[len(value) - 1] == '"' && !strings.contains_any(value[1:len(value) - 1], "\"\\") {
			append(out,
				Field{strings.clone(name), false, false, KW, "", ""},
				Field{strings.clone("="), false, false, "", "", ""},
				Field{strings.clone("\""), false, false, "", "", ""},
				Field{strings.clone(value[1:len(value) - 1]), true, false, "string", "", ""},
				Field{strings.clone("\""), false, false, "", "", ""},
			)
			return true
		}
	}
	append(out, Field{strings.clone(p), false, false, KW, "", ""})
	return true
}

// parse_ctrl_line: a when / else when / else line, an #assert, or an attribute
// line as structured fields (ok=false: not one of them, parse it the usual way).
parse_ctrl_line :: proc(line: string, role: Line_Role) -> (node: Node, ok: bool) {
	ind := 0
	for ind < len(line) && (line[ind] == ' ' || line[ind] == '\t') do ind += 1
	s := line[ind:]
	fs := make([dynamic]Field)
	defer if !ok do free_fields(&fs)

	// `when <cond> {` / `} else when <cond> {` / `} else {`
	cond_line :: proc(fs: ^[dynamic]Field, s: string, kw_at, kw_len: int) -> bool {
		k := kw_at + kw_len
		ws := k
		for ws < len(s) && s[ws] == ' ' do ws += 1
		brace := strings.last_index_byte(s, '{')
		if ws == k || brace <= ws do return false
		cond_end := brace
		for cond_end > ws && s[cond_end - 1] == ' ' do cond_end -= 1
		if cond_end <= ws do return false
		append(fs, Field{strings.clone(s[kw_at:k]), false, false, KW, "", ""})
		append(fs, Field{strings.clone(s[k:ws]), false, false, "", "", ""})
		if !expr_fields(fs, s[ws:cond_end]) do return false
		append(fs, Field{strings.clone(s[cond_end:]), false, false, "", "", ""})
		return true
	}
	lead := line[:ind]
	switch role.kind {
	case 1:
		if ind > 0 do append(&fs, Field{strings.clone(lead), false, false, "", "", ""})
		if !cond_line(&fs, s, 0, len("when")) do return
		return Node{fs}, true
	case 2:
		append(&fs, Field{strings.concatenate({lead, "} "}), false, false, "", "", ""})
		if !cond_line(&fs, s, 2, len("else when")) do return
		return Node{fs}, true
	case 3:
		append(&fs, Field{strings.concatenate({lead, "} "}), false, false, "", "", ""},
			Field{strings.clone("else"), false, false, KW, "", ""},
			Field{strings.clone(s[len("} else"):]), false, false, "", "", ""})
		return Node{fs}, true
	}

	// #assert(<cond>[, <message>])
	if strings.has_prefix(s, "#assert(") {
		open := len("#assert")
		close := match_paren(s, open)
		if close != len(s) - 1 do return
		if ind > 0 do append(&fs, Field{strings.clone(lead), false, false, "", "", ""})
		append(&fs, Field{strings.clone("#assert"), false, false, KW, "", ""}, Field{strings.clone("("), false, false, "", "", ""})
		inner := s[open + 1:close]
		if !arg_fields(&fs, inner) do return
		if len(split_commas(inner)) == 1 { // the optional message dot
			append(&fs, Field{strings.clone(", "), false, false, "", "", ""}, Field{"", false, true, "args", "string", ""})
		}
		append(&fs, Field{strings.clone(")"), false, false, "", "", ""})
		return Node{fs}, true
	}

	// @(a, b="x") / @name
	if strings.has_prefix(s, "@(") {
		close := match_paren(s, 1)
		if close != len(s) - 1 do return
		append(&fs, Field{strings.concatenate({lead, "@("}), false, false, "", "", ""})
		for p, i in split_commas(s[2:close]) {
			if i > 0 {
				if !strings.has_prefix(p, " ") do return
				append(&fs, Field{strings.clone(", "), false, false, "", "", ""})
			}
			if !attr_fields(&fs, i > 0 ? p[1:] : p) do return
		}
		append(&fs, Field{strings.clone(")"), false, false, "", "", ""})
		return Node{fs}, true
	}
	if strings.has_prefix(s, "@") && is_ident(s[1:]) {
		append(&fs, Field{strings.concatenate({lead, "@"}), false, false, "", "", ""}, Field{strings.clone(s[1:]), false, false, KW, "", ""})
		return Node{fs}, true
	}
	return
}

// split_modifiers: calling conventions and struct directives inside a parsed
// line's fixed text become keyword fields.
split_modifiers :: proc(n: ^Node) {
	txt := node_text(n^, context.temp_allocator)
	if strings.has_prefix(strings.trim_space(txt), "//") do return
	conv := strings.contains(txt, "::") && strings.contains(txt, "proc \"")
	directives := strings.contains(txt, ":: struct") && strings.contains(txt, "#")
	if !conv && !directives do return
	for i := 0; i < len(n.fields); i += 1 {
		f := n.fields[i]
		if f.slot || f.editable || f.kind != "" do continue
		pieces := make([dynamic]Field, 0, 4, context.temp_allocator)
		// Only the declaration's own convention (`name :: proc "c" (`), once: a
		// `proc "c" (x: i32)` parameter type stays plain text.
		if conv && own_proc_quote(f.text) >= 0 {
			split_callconv_text(f.text, &pieces)
			if len(pieces) > 0 do conv = false
		}
		if len(pieces) == 0 && directives do split_directive_text(f.text, &pieces)
		if len(pieces) == 0 do continue
		delete(n.fields[i].text)
		ordered_remove(&n.fields, i)
		inject_at(&n.fields, i, ..pieces[:])
		i += len(pieces) - 1
	}
}

// own_proc_quote: where `proc "` starts in text holding a declaration's own
// `:: [#force_inline |#force_no_inline |#type ]proc "`, or -1.
@(private = "file")
own_proc_quote :: proc(t: string) -> int {
	dc := strings.index(t, "::")
	if dc < 0 do return -1
	k := dc + 2
	for k < len(t) && t[k] == ' ' do k += 1
	for pre in ([]string{"#force_inline ", "#force_no_inline ", "#type "}) {
		if strings.has_prefix(t[k:], pre) {
			k += len(pre)
			for k < len(t) && t[k] == ' ' do k += 1
			break
		}
	}
	return strings.has_prefix(t[k:], "proc \"") ? k : -1
}

// `... proc "system" (` -> `... proc `, kw `"system"`, ` (`.
@(private = "file")
split_callconv_text :: proc(t: string, out: ^[dynamic]Field) {
	at := own_proc_quote(t)
	if at < 0 do return
	q := at + len("proc ")
	end := strings.index_byte(t[q + 1:], '"')
	if end < 0 do return
	e := q + 1 + end + 1
	append(out, Field{strings.clone(t[:q]), false, false, "", "", ""}, Field{strings.clone(t[q:e]), false, false, KW, "", ""})
	if e < len(t) do append(out, Field{strings.clone(t[e:]), false, false, "", "", ""})
}

// ` :: struct #packed #align(16) {` -> fixed text around kw `#packed`, kw `#align(`, 16, `)`.
@(private = "file")
split_directive_text :: proc(t: string, out: ^[dynamic]Field) {
	TOKENS :: [?]string{"#packed", "#raw_union", "#align("}
	rest := t
	found := false
	for {
		best, which := -1, ""
		for tok in TOKENS {
			at := strings.index(rest, tok)
			if at > 0 && rest[at - 1] == ' ' && (best < 0 || at < best) { best, which = at, tok }
		}
		if best < 0 do break
		after := best + len(which)
		if which != "#align(" && after < len(rest) && is_ident(rest[after:after + 1]) do break // e.g. #packed_x
		append(out, Field{strings.clone(rest[:best]), false, false, "", "", ""}, Field{strings.clone(which), false, false, KW, "", ""})
		found = true
		if which == "#align(" {
			// The matching `)`: `#align(align_of(int))`.
			close := match_paren(rest, after - 1)
			if close < 0 { rest = rest[after:]; break }
			arg := rest[after:close]
			digits := len(arg) > 0
			for c in transmute([]u8)arg do if c < '0' || c > '9' { digits = false; break }
			if len(arg) > 0 do append(out, Field{strings.clone(arg), digits, false, "", "", ""})
			append(out, Field{strings.clone(")"), false, false, "", "", ""})
			rest = rest[close + 1:]
		} else {
			rest = rest[after:]
		}
	}
	if !found do return
	if rest != "" do append(out, Field{strings.clone(rest), false, false, "", "", ""})
}

// proc_params_open: the `(` of a procedure's parameter list in a declaration's
// text: `proc(` or `proc "c" (`. -1 if none.
proc_params_open :: proc(rest: string) -> int {
	plain := strings.index(rest, "proc(")
	conv := strings.index(rest, "proc \"")
	if conv >= 0 && (plain < 0 || conv < plain) {
		q := conv + len("proc \"")
		end := strings.index_byte(rest[q:], '"')
		if end < 0 do return -1
		k := q + end + 1
		for k < len(rest) && rest[k] == ' ' do k += 1
		if k < len(rest) && rest[k] == '(' do return k
		return -1
	}
	if plain >= 0 do return plain + len("proc")
	return -1
}

package model

// Loading branching statements back into the structure the menus build
// (doc_from_source, parse.odin; branch.odin). Every node's fields concatenate
// back to exactly the source line; a line that doesn't fit is left as it was.
//
//   if v, ok := m["key"]; ok {      kw "if", " ", v, ", ", ok, " := ", m[, "key", ], "; ", ok, " {"
//   } else if x > 0 {               "} ", kw "else if", " ", x, " > ", 0, " {"
//   } else {                        "} ", kw "else", " {"
//   #partial switch dir {           kw "#partial", " ", kw "switch", " ", dir, " {"
//   switch v in shape {             kw "switch", " ", v (name), " in ", shape, " {"
//   case 2, 3:                      kw "case", " ", 2, ", ", 3, ":"
//   case 0..<10: foo()              kw "case", " ", 0, "..<", 10, ":", " foo()"
//   case Circle:                    (in a type switch) kw "case", " ", Circle (type), ":"
//   case:                           kw "case", ":"
// A trailing `// comment` stays with the line.

import "core:strings"

// Is t (trimmed) the header of a type switch `[#partial ]switch v in x {`?
@(private = "file")
is_type_switch_text :: proc(t: string) -> bool {
	s := strings.trim_prefix(t, "#partial ")
	if !strings.has_prefix(s, "switch ") || !strings.has_suffix(s, "{") do return false
	inner := strings.trim_space(s[len("switch "):len(s) - 1])
	at := strings.index(inner, " in ")
	if at <= 0 do return false
	v := inner[:at]
	if strings.has_prefix(v, "&") do v = v[1:] // `switch &v in x {`
	return is_ident(v)
}

// branch_line_roles: per source line, whether it's a case label of a type switch.
branch_line_roles :: proc(lines: []string) -> []bool {
	out := make([]bool, len(lines), context.temp_allocator)
	stack := make([dynamic]bool, 0, 16, context.temp_allocator) // per open brace: a type switch's body
	for line, i in lines {
		t := strings.trim_space(line)
		if (strings.has_prefix(t, "case ") || strings.has_prefix(t, "case:")) && len(stack) > 0 && stack[len(stack) - 1] do out[i] = true
		ts := is_type_switch_text(t)
		seq := line_brace_seq(line)
		for c, k in seq {
			if c == '}' {
				if len(stack) > 0 do pop(&stack)
			} else {
				append(&stack, ts && k == len(seq) - 1)
			}
		}
	}
	return out
}

@(private = "file")
fx :: proc(text: string) -> Field { return Field{strings.clone(text), false, false, "", "", ""} }
@(private = "file")
kw :: proc(text: string) -> Field { return Field{strings.clone(text), false, false, BR_KW, "", ""} }

@(private = "file")
free_fields :: proc(fs: ^[dynamic]Field) {
	for f in fs do if len(f.text) > 0 do delete(f.text)
	delete(fs^)
}

// The index of the first `sub` in s outside strings and brackets, or -1.
@(private = "file")
top_index :: proc(s, sub: string) -> int {
	depth := 0
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
		case '(', '[', '{':  depth += 1
		case ')', ']', '}':  depth -= 1
		case:
			if depth == 0 && strings.has_prefix(s[k:], sub) do return k
		}
	}
	return -1
}

// Split s at top-level ", " (nil when a comma isn't followed by exactly one space).
@(private = "file")
split_values :: proc(s: string) -> []string {
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
		case '(', '[', '{':  depth += 1
		case ')', ']', '}':  depth -= 1
		case ',':
			if depth != 0 do continue
			if k + 1 >= len(s) || s[k + 1] != ' ' do return nil
			append(&out, s[start:k])
			start = k + 2
			k += 1
		}
	}
	append(&out, s[start:])
	return out[:]
}

// `a.b.c` (identifiers joined by dots).
@(private = "file")
is_path :: proc(s: string) -> bool {
	if s == "" do return false
	for p in strings.split(s, ".", context.temp_allocator) do if !is_ident(p) do return false
	return true
}

// br_emit_expr: an expression's fields (parse.odin's emit_expr), with index
// expressions `items[i]` split into `items[`, i, `]` as the Index fill makes them.
br_emit_expr :: proc(out: ^[dynamic]Field, text: string) {
	tmp := make([dynamic]Field, 0, 4, context.temp_allocator)
	parse_expr_fields(&tmp, text)
	for f in tmp {
		open := index_open(f.text)
		if f.slot || f.editable || f.kind != "" || open <= 0 || open + 2 >= len(f.text) || !is_path(f.text[:open]) {
			append(out, f)
			continue
		}
		append(out, fx(f.text[:open + 1]))
		br_emit_expr(out, f.text[open + 1:len(f.text) - 1])
		append(out, fx("]"))
		delete(f.text)
	}
}

// A case value: a range `lo..<hi` / `lo ..= hi` as lo, op, hi; else the expression.
@(private = "file")
emit_case_value :: proc(out: ^[dynamic]Field, v: string) {
	k := top_index(v, "..<")
	if k < 0 do k = top_index(v, "..=")
	if k > 0 && k + 3 < len(v) {
		lo := strings.trim_right_space(v[:k])
		hi := strings.trim_left_space(v[k + 3:])
		if lo != "" && hi != "" {
			br_emit_expr(out, lo)
			append(out, fx(v[len(lo):len(v) - len(hi)]))
			br_emit_expr(out, hi)
			return
		}
	}
	br_emit_expr(out, v)
}

// A setup statement: `a, b := value` / `x = value` with the names editable; else an expression (a call).
@(private = "file")
emit_setup :: proc(out: ^[dynamic]Field, s: string) {
	op, op_len := strings.index(s, " := "), 4
	if op < 0 do op, op_len = top_index(s, " = "), 3
	if op > 0 {
		names := split_values(s[:op])
		good := len(names) > 0
		for nm in names do if !is_ident(nm) { good = false; break }
		if good {
			for nm, i in names {
				if i > 0 do append(out, fx(", "))
				append(out, Field{strings.clone(nm), true, false, "", "", ""})
			}
			append(out, fx(s[op:op + op_len]))
			br_emit_expr(out, s[op + op_len:])
			return
		}
	}
	br_emit_expr(out, s)
}

// The text before a trailing `// comment` and the comment (with the spaces before it).
@(private = "file")
split_comment :: proc(s: string) -> (code, comment: string) {
	at := top_index(s, "//")
	if at < 0 do return s, ""
	code = strings.trim_right_space(s[:at])
	return code, s[len(code):]
}

// A header's condition / value (with an optional setup; a type switch's `v in x`).
@(private = "file")
emit_header :: proc(out: ^[dynamic]Field, s: string, is_switch: bool) {
	rest := s
	if semi := top_index(s, "; "); semi > 0 {
		emit_setup(out, s[:semi])
		append(out, fx("; "))
		rest = s[semi + 2:]
	} else if is_switch {
		if at := strings.index(s, " in "); at > 0 {
			name := s[:at]
			ref := strings.has_prefix(name, "&") // `switch &v in x {`: v addressable
			if ref do name = name[1:]
			if is_ident(name) {
				if ref do append(out, fx("&"))
				append(out, Field{strings.clone(name), true, false, "", "", ""}, fx(" in "))
				rest = s[at + 4:]
			}
		}
	}
	br_emit_expr(out, rest)
}

// parse_branch_line: an if / else if / else / switch header or a case label as
// structured fields (ok=false: not one of them, parse it the usual way).
// type_case: the line is a case label of a type switch (its values are types).
parse_branch_line :: proc(line: string, type_case: bool, in_data := false) -> (node: Node, ok: bool) {
	if in_data do return
	ind := 0
	for ind < len(line) && (line[ind] == ' ' || line[ind] == '\t') do ind += 1
	lead, s := line[:ind], line[ind:]
	if !(strings.has_prefix(s, "if ") || strings.has_prefix(s, "} else") || strings.has_prefix(s, "switch") ||
	     strings.has_prefix(s, "#partial switch") || strings.has_prefix(s, "case ") || strings.has_prefix(s, "case:")) {
		return
	}
	fs := make([dynamic]Field)
	defer if !ok do free_fields(&fs)
	indent :: proc(fs: ^[dynamic]Field, lead: string) { if lead != "" do append(fs, fx(lead)) }

	if strings.has_prefix(s, "case") {
		// The label's colon: the first top-level ':'.
		colon := top_index(s, ":")
		if colon < 0 do return
		indent(&fs, lead)
		append(&fs, kw("case"))
		if colon > len("case") {
			if s[4] != ' ' do return
			append(&fs, fx(" "))
			values := split_values(s[5:colon])
			if len(values) == 0 do return
			for v, i in values {
				if v == "" || strings.trim_space(v) != v do return
				if i > 0 do append(&fs, fx(", "))
				if type_case do append(&fs, Field{strings.clone(v), true, false, "type", "", ""})
				else do emit_case_value(&fs, v)
			}
		} else if colon != len("case") {
			return
		}
		append(&fs, fx(":"))
		if colon + 1 < len(s) do append(&fs, fx(s[colon + 1:]))
	} else {
		code, comment := split_comment(s)
		if !strings.has_suffix(code, " {") && code != "switch {" && code != "#partial switch {" do return
		inner := ""
		switch {
		case code == "} else {":
			append(&fs, fx(strings.concatenate({lead, "} "}, context.temp_allocator)), kw("else"))
		case strings.has_prefix(code, "} else if "):
			append(&fs, fx(strings.concatenate({lead, "} "}, context.temp_allocator)), kw("else if"), fx(" "))
			inner = code[len("} else if "):len(code) - 2]
			emit_header(&fs, inner, false)
		case strings.has_prefix(code, "if "):
			indent(&fs, lead)
			append(&fs, kw("if"), fx(" "))
			inner = code[len("if "):len(code) - 2]
			emit_header(&fs, inner, false)
		case strings.has_prefix(code, "switch") || strings.has_prefix(code, "#partial switch"):
			indent(&fs, lead)
			rest := code
			if strings.has_prefix(rest, "#partial ") {
				append(&fs, kw("#partial"), fx(" "))
				rest = rest[len("#partial "):]
			}
			append(&fs, kw("switch"))
			if rest != "switch {" {
				if !strings.has_prefix(rest, "switch ") do return
				append(&fs, fx(" "))
				inner = rest[len("switch "):len(rest) - 2]
				emit_header(&fs, inner, true)
			}
		case:
			return
		}
		append(&fs, fx(" {"))
		if comment != "" do append(&fs, fx(comment))
	}
	node = Node{fs}
	if node_text(node, context.temp_allocator) != line do return {}, false
	if _, structured := br_line(node); !structured do return {}, false
	return node, true
}

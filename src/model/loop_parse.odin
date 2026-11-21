package model

// Loading loops back into the structure the Loops menu builds (doc_from_source,
// parse.odin). Every node's fields concatenate back to exactly the source line;
// anything that doesn't fit is left to the usual parsing.
//
//   for x < 10 {                       kw "for", " ", <x < 10>, " {"
//   for {                              kw "for", " {"
//   outer: #reverse for &item, i in items {
//                                      label, ": ", kw "#reverse", " ", kw "for", " ", "&", item, ", ", i, " in ", <items>, " {"
//   for i in 0..<10 {                  ..., " in ", <0>, "..<", <10>, " {"
//   for i := 0; i < 10; i += 1 {       ..., i, " := ", <0>, "; ", <i < 10>, "; ", i, op " += ", <1>, " {"
//   break / continue [label]           kw "break", " ", label
//   outer: {                           label, ": {"

import "core:strings"

@(private = "file")
fx :: proc(text: string) -> Field { return Field{strings.clone(text), false, false, "", "", ""} }
@(private = "file")
fkw :: proc(text: string) -> Field { return Field{strings.clone(text), false, false, KW, "", ""} }

@(private = "file")
is_name :: proc(s: string) -> bool { return is_ident(s) }

@(private = "file")
free_fields :: proc(fs: ^[dynamic]Field) {
	for f in fs do if len(f.text) > 0 do delete(f.text)
	delete(fs^)
}

// An expression's structured fields (emit_expr), with the spaces around it as
// fixed text so the fields give back exactly `text`.
@(private = "file")
expr_into :: proc(out: ^[dynamic]Field, text: string) {
	t := strings.trim_space(text)
	if t == "" {
		if text != "" do append(out, fx(text))
		return
	}
	lead := strings.index(text, t)
	if lead > 0 do append(out, fx(text[:lead]))
	parse_expr_fields(out, t)
	if tail := text[lead + len(t):]; tail != "" do append(out, fx(tail))
}

// Index of `sub` at the top level of s (outside brackets and strings), or -1.
@(private = "file")
top_at :: proc(s, sub: string, from := 0) -> int {
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
			if k >= from && depth == 0 && strings.has_prefix(s[k:], sub) do return k
		}
	}
	return -1
}

// The iterable: a range's two ends separately (`0..<10`, `0 ..= n`).
@(private = "file")
iter_into :: proc(out: ^[dynamic]Field, text: string) {
	at := top_at(text, "..<")
	if at < 0 do at = top_at(text, "..=")
	if at < 0 {
		expr_into(out, text)
		return
	}
	lo := text[:at]
	hi := text[at + 3:]
	lo_t := strings.trim_right_space(lo)
	hi_t := strings.trim_left_space(hi)
	expr_into(out, lo_t)
	append(out, fx(text[len(lo_t):at + 3 + (len(hi) - len(hi_t))])) // the operator with its spaces
	expr_into(out, hi_t)
}

// A C-style part: `name := value`, `target op value`, else an expression.
@(private = "file")
part_into :: proc(out: ^[dynamic]Field, text: string, is_post: bool) {
	t := text
	sp := strings.index_byte(t, ' ')
	if sp > 0 {
		op_end := sp + 1
		for op_end < len(t) && t[op_end] != ' ' do op_end += 1
		if op_end < len(t) {
			op := t[sp + 1:op_end]
			target := t[:sp]
			ok_target := true
			for p in strings.split(target, ".", context.temp_allocator) do if !is_name(p) { ok_target = false; break }
			if !is_post && op == ":=" && is_name(target) {
				append(out, Field{strings.clone(target), true, false, "", "", ""}, fx(t[sp:op_end + 1]))
				expr_into(out, t[op_end + 1:])
				return
			}
			if is_post && ok_target && is_assign_op_text(op) {
				append(out, Field{strings.clone(target), true, false, "", "", ""}, Field{strings.clone(t[sp:op_end + 1]), false, false, ASSIGN_OP_KIND, "", ""})
				expr_into(out, t[op_end + 1:])
				return
			}
		}
	}
	expr_into(out, text)
}

// parse_loop_line: a loop header, break / continue, or a labeled block as
// structured fields (ok=false: not one of them).
parse_loop_line :: proc(line: string, in_data := false) -> (node: Node, ok: bool) {
	if in_data do return // inside a struct / enum body
	ind := 0
	for ind < len(line) && (line[ind] == ' ' || line[ind] == '\t') do ind += 1
	s := line[ind:]
	if s == "" || strings.contains(s, "//") do return
	fs := make([dynamic]Field)
	defer if !ok do free_fields(&fs)
	if ind > 0 do append(&fs, fx(line[:ind]))

	// break / continue [label]
	for w in ([]string{"break", "continue"}) {
		if s == w {
			append(&fs, fkw(w))
			return Node{fs}, true
		}
		if strings.has_prefix(s, w) && len(s) > len(w) + 1 && s[len(w)] == ' ' && is_name(s[len(w) + 1:]) {
			append(&fs, fkw(w), fx(" "), fx(s[len(w) + 1:]))
			return Node{fs}, true
		}
	}

	rest := s
	lbl, after := split_label(s)
	if lbl != "" {
		if after == "{" && s[len(lbl):] == ": {" {
			append(&fs, Field{strings.clone(lbl), true, false, LABEL_KIND, "", ""}, fx(": {"))
			return Node{fs}, true
		}
		if s[len(lbl):len(lbl) + 2] != ": " || (!strings.has_prefix(s[len(lbl) + 2:], "for") && !strings.has_prefix(s[len(lbl) + 2:], "#")) do return
		append(&fs, Field{strings.clone(lbl), true, false, LABEL_KIND, "", ""}, fx(": "))
		rest = s[len(lbl) + 2:]
	}
	for d in ([]string{"#reverse ", "#unroll "}) {
		if strings.has_prefix(rest, d) {
			append(&fs, fkw(d[:len(d) - 1]), fx(" "))
			rest = rest[len(d):]
			break
		}
	}
	if !strings.has_prefix(rest, "for") do return
	rest = rest[len("for"):]
	// The whole line must open exactly one block, at its end.
	if !strings.has_suffix(rest, "{") do return
	opens := 0
	for c in line_brace_seq(rest) do opens += c == '{' ? 1 : -1
	if opens != 1 do return
	append(&fs, fkw("for"))
	if rest == " {" {
		append(&fs, fx(" {"))
		return Node{fs}, true
	}
	if !strings.has_prefix(rest, " ") || !strings.has_suffix(rest, " {") do return
	mid := rest[1:len(rest) - 2]
	if strings.trim_space(mid) != mid || mid == "" do return
	append(&fs, fx(" "))

	if at := top_at(mid, " in "); at >= 0 && top_at(mid, ";") < 0 {
		// Loop variables: [&]a[, [&]b]
		vars := mid[:at]
		k := 0
		for nv := 0; ; nv += 1 {
			if nv > 0 {
				if nv > 1 || k >= len(vars) || vars[k] != ',' do return
				st := k
				k += 1
				for k < len(vars) && vars[k] == ' ' do k += 1
				append(&fs, fx(vars[st:k]))
			}
			if k < len(vars) && vars[k] == '&' {
				append(&fs, fx("&"))
				k += 1
			}
			st := k
			for k < len(vars) && vars[k] != ',' && vars[k] != ' ' do k += 1
			if !is_name(vars[st:k]) do return
			append(&fs, Field{strings.clone(vars[st:k]), true, false, "", "", ""})
			if k >= len(vars) do break
		}
		append(&fs, fx(" in "))
		iter_into(&fs, mid[at + 4:])
	} else if s1 := top_at(mid, ";"); s1 >= 0 {
		s2 := top_at(mid, ";", s1 + 1)
		if s2 < 0 || top_at(mid, ";", s2 + 1) >= 0 do return
		// Separators carry the spaces after the ";" (`; `, or `;` before an empty post).
		sep_end :: proc(mid: string, at: int) -> int {
			k := at + 1
			for k < len(mid) && mid[k] == ' ' do k += 1
			return k
		}
		e1, e2 := sep_end(mid, s1), sep_end(mid, s2)
		init := mid[:s1]
		if strings.trim_space(init) != init do return
		cond := mid[e1:s2]
		post := mid[e2:]
		if strings.trim_space(cond) != cond || strings.trim_space(post) != post do return
		if init != "" do part_into(&fs, init, false)
		append(&fs, fx(mid[s1:e1]))
		if cond != "" do expr_into(&fs, cond)
		append(&fs, fx(mid[s2:e2]))
		if post != "" do part_into(&fs, post, true)
	} else {
		expr_into(&fs, mid)
	}
	append(&fs, fx(" {"))
	if node_text(Node{fs}, context.temp_allocator) != line do return
	n := Node{fs}
	if _, hok := loop_hdr(n); !hok do return
	return n, true
}

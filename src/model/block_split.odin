package model

// One-line blocks, as tables write them (`for i in 0..<10 { }`,
// `if x > 0 { } else { }`, `outer: for x in xs { for i in 0..<3 { break outer } }`),
// are split onto their own lines by format_doc (which runs on load and save):
// header `{`, each body statement one level deeper, `}` (merged with a
// following `else` into `} else {`). The headers are then the same structured
// lines the menus build (loops, if / switch / when, labeled blocks). A line is
// only split when every header it makes loads structured; struct literals,
// procedure literals, `switch` with case clauses on one line and lines with a
// comment stay as written. doc_from_source itself still round-trips exactly.

import "core:strings"

@(private = "file")
BLOCK_HEADS := [?]string{"if ", "for ", "for{", "switch ", "#partial switch ", "when ", "#reverse ", "#unroll "}

@(private = "file")
is_block_head :: proc(s: string) -> bool {
	for h in BLOCK_HEADS do if strings.has_prefix(s, h) do return true
	if lbl, rest := split_label(s); lbl != "" && rest != s do return is_block_head(rest) || strings.has_prefix(rest, "{")
	return false
}

// The index of the `}` matching the `{` at s[open] (strings respected), or -1.
@(private = "file")
match_brace :: proc(s: string, open: int) -> int {
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
		case '{': depth += 1
		case '}':
			depth -= 1
			if depth == 0 do return k
		}
	}
	return -1
}

// The `{` opening the block of header text s: the first one outside (), [] and
// strings that follows a space (`Point{1, 2}` / `[]int{1}` aren't blocks), or -1.
@(private = "file")
block_open :: proc(s: string) -> int {
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
		case '(', '[': depth += 1
		case ')', ']': depth -= 1
		case '{':
			if depth == 0 {
				if k > 0 && s[k - 1] != ' ' do return -1
				return k
			}
		}
	}
	return -1
}

// Split s at top-level `;` (outside brackets, braces and strings).
@(private = "file")
split_statements :: proc(s: string) -> []string {
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
		case ';':
			if depth == 0 {
				append(&out, strings.trim_space(s[start:k]))
				start = k + 1
			}
		}
	}
	append(&out, strings.trim_space(s[start:]))
	return out[:]
}

Split_Out :: struct {
	lines:   [dynamic]string,
	headers: [dynamic]int, // which lines are block headers
}

// split_block: header-led text s (a block statement on one line) as lines at
// `indent`; lead: text before the header (`} ` for an else).
@(private = "file")
split_block :: proc(out: ^Split_Out, s, indent, lead: string) -> bool {
	open := block_open(s)
	if open < 0 do return false
	close := match_brace(s, open)
	if close < 0 do return false
	head := strings.trim_right_space(s[:open])
	body := strings.trim_space(s[open + 1:close])
	rest := strings.trim_space(s[close + 1:])
	append(&out.headers, len(out.lines))
	append(&out.lines, strings.concatenate({indent, lead, head, " {"}, context.temp_allocator))
	if body != "" {
		if strings.has_prefix(body, "case ") || strings.has_prefix(body, "case:") do return false // case clauses stay as written
		inner := strings.concatenate({indent, "\t"}, context.temp_allocator)
		for st in split_statements(body) {
			if st == "" do continue
			if is_block_head(st) && strings.contains(st, "{") {
				if !split_block(out, st, inner, "") do return false
			} else {
				append(&out.lines, strings.concatenate({inner, st}, context.temp_allocator))
			}
		}
	}
	if rest == "" {
		append(&out.lines, strings.concatenate({indent, "}"}, context.temp_allocator))
		return true
	}
	if strings.has_prefix(rest, "else ") || strings.has_prefix(rest, "else{") do return split_block(out, rest, indent, "} ")
	return false
}

// split_inline_block: the lines a one-line block statement becomes (ok=false: leave it).
split_inline_block :: proc(line: string) -> (out: Split_Out, ok: bool) {
	out.lines = make([dynamic]string, 0, 8, context.temp_allocator)
	out.headers = make([dynamic]int, 0, 4, context.temp_allocator)
	ind := 0
	for ind < len(line) && (line[ind] == ' ' || line[ind] == '\t') do ind += 1
	s := strings.trim_right_space(line[ind:])
	if !is_block_head(s) || !strings.has_suffix(s, "}") || strings.contains(s, "//") || strings.contains(s, "/*") do return
	seq := line_brace_seq(s)
	bal := 0
	for c in seq do bal += c == '{' ? 1 : -1
	if bal != 0 || len(seq) < 2 do return
	if !split_block(&out, s, line[:ind], "") do return
	return out, len(out.lines) > 1
}

// A loaded header line is structured like the menus build it.
@(private = "file")
header_structured :: proc(n: Node) -> bool {
	if _, ok := loop_hdr(n); ok do return true
	if _, ok := br_line(n); ok do return true
	if _, ok := labeled_block(n); ok do return true
	if when_kw_index(n) >= 0 do return true
	return false
}

// split_one_line_blocks (format_doc): replace each one-line block statement
// (a line with no dots) by its lines, parsed as a file would be.
split_one_line_blocks :: proc(app: ^App) {
	imports := make([dynamic]string, 0, 8, context.temp_allocator)
	for n in app.doc.nodes {
		t := strings.trim_space(node_text(n, context.temp_allocator))
		if strings.has_prefix(t, "import ") do append(&imports, t)
	}
	for i := 0; i < len(app.doc.nodes); i += 1 {
		n := app.doc.nodes[i]
		has_dot := false
		for f in n.fields do if f.slot { has_dot = true; break }
		if has_dot do continue
		sp, ok := split_inline_block(node_text(n, context.temp_allocator))
		if !ok do continue
		// Parse the lines after the file's imports (call dots get their types).
		sb := strings.builder_make(context.temp_allocator)
		for imp in imports { strings.write_string(&sb, imp); strings.write_byte(&sb, '\n') }
		for l, k in sp.lines {
			if k > 0 do strings.write_byte(&sb, '\n')
			strings.write_string(&sb, l)
		}
		tmp: App
		doc_from_source(&tmp, strings.to_string(sb))
		good := len(tmp.doc.nodes) == len(imports) + len(sp.lines)
		if good do for h in sp.headers do if !header_structured(tmp.doc.nodes[len(imports) + h]) { good = false; break }
		if good {
			news := tmp.doc.nodes[len(imports):]
			for &nn in news {
				for &f in nn.fields {
					f.hint = intern_hint(app, f.hint)
					f.hint_pkg = intern_hint(app, f.hint_pkg)
				}
			}
			for f in app.doc.nodes[i].fields do if len(f.text) > 0 do delete(f.text)
			delete(app.doc.nodes[i].fields)
			ordered_remove(&app.doc.nodes, i)
			inject_at(&app.doc.nodes, i, ..news)
			if app.editor_line > i do app.editor_line += len(news) - 1
			// The moved nodes belong to app.doc now: drop them from tmp before resetting it.
			k := len(news)
			remove_range(&tmp.doc.nodes, len(imports), len(tmp.doc.nodes))
			i += k - 1
		}
		doc_reset(&tmp)
		delete(tmp.doc.nodes)
		delete(tmp.recent_imports)
	}
}

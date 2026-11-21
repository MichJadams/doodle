package model

// Parse existing Odin source files back into Doodle's document model.

import "core:os"
import "core:strings"
import "core:unicode/utf8"

// doc_from_source parses Odin source text into nodes, replacing app.doc.
// Parsing is line-based and pragmatic (not a full Odin parser):
//   - Each line becomes one Node, except a call statement written over several
//     lines (one argument per line), which is joined back into one Node
//   - Recognized patterns have editable identifiers; the rest is fixed
//   - Call statements (`foo(a, b)`, `x := pkg.foo(a)`, `defer foo()`) get their
//     argument list back: empty arguments become dots again (typed from the
//     proc's signature), and missing required arguments get dots
//   - Other lines round-trip exactly; call lines come back in Doodle's format
doc_from_source :: proc(app: ^App, src: string) {
	doc_reset(app)

	// Trim a single trailing newline from src (file_text writes it back)
	text := src
	if len(text) > 0 && text[len(text)-1] == '\n' {
		text = text[:len(text)-1]
	} else if len(text) > 0 {
		app.doc.no_final_newline = true
	}

	// Split on newline, stripping carriage returns
	raw := strings.split_lines(text, context.temp_allocator)
	lines := make([]string, len(raw), context.temp_allocator)
	for line, i in raw {
		lines[i] = strings.trim_right(line, "\r")
	}

	calls := make([dynamic]Parsed_Call, 0, 8, context.temp_allocator)
	blocks := make([dynamic]bool, 0, 8, context.temp_allocator) // open braces: true = data (struct/enum/...)
	roles := ctrl_line_roles(lines) // when / #assert / attribute lines (ctrl_parse.odin)
	type_cases := branch_line_roles(lines) // case labels of type switches (branch_parse.odin)
	for i := 0; i < len(lines); {
		in_data := len(blocks) > 0 && blocks[len(blocks) - 1]
		consumed := 1
		if cnode, cok := parse_comment_line(lines[i]); cok {
			append(&app.doc.nodes, cnode) // `// text`: the text is editable (stmt_layout.odin)
		} else if node, ok := parse_ctrl_line(lines[i], roles[i]); ok {
			append(&app.doc.nodes, node)
		} else if bnode, bok := parse_branch_line(lines[i], type_cases[i], in_data); bok {
			append(&app.doc.nodes, bnode) // if / else / switch / case (branch_parse.odin)
		} else if lpnode, lpok := parse_loop_line(lines[i], in_data); lpok {
			append(&app.doc.nodes, lpnode) // loops, break / continue, labeled blocks (loop_parse.odin)
		} else if node, callee, used, ok := parse_call_statement(lines[i:]); ok {
			append(&app.doc.nodes, node)
			append(&calls, Parsed_Call{len(app.doc.nodes) - 1, callee})
			consumed = used
		} else if roles[i].when_decl {
			append(&app.doc.nodes, parse_indented_line(lines[i], in_data)) // a declaration inside a file-scope when
		} else if lnode, lused, lok := parse_lit_statement(lines[i:]); lok {
			append(&app.doc.nodes, lnode) // `x := T{name = value, ...}` (struct_lit.odin)
			consumed = lused
		} else if anode, aok := parse_assign_statement(lines[i], in_data); aok {
			append(&app.doc.nodes, anode) // `a.b = value`, `x = value` (field_access.odin)
		} else {
			append(&app.doc.nodes, parse_line(lines[i], in_data))
		}
		for k in i ..< i + consumed do track_blocks(&blocks, lines[k])
		i += consumed
	}
	// Type declarations and data-body members: the same fields the menus build (data_types.odin).
	structure_type_decls(app)
	// Calling conventions and struct directives become keyword fields (ctrl_parse.odin).
	// After structure_type_decls, so `Pair :: struct($K: typeid) #align(8) {` is
	// first structured as a type declaration and its directive split afterwards.
	for &n in app.doc.nodes do split_modifiers(&n)
	// With all imports known, give the calls' dots their expected types.
	for c in calls do attach_call_signature(app, c.ni, c.callee)
	attach_lit_hints(app) // struct literals' dots (struct_lit.odin)
	attach_nested_call_hints(app) // dots of calls inside other expressions (expr.odin)
}

@(private = "file")
Parsed_Call :: struct {
	ni:     int,
	callee: string, // e.g. "windows.MessageBoxW"
}

@(private = "file")
NOT_CALLEES := [?]string{
	"proc", "if", "for", "switch", "when", "cast", "transmute", "auto_cast", "struct",
	"union", "enum", "map", "matrix", "bit_set", "bit_field", "distinct", "return", "defer",
}

// parse_call_statement recognizes a call statement starting at lines[0]:
//   [indent] [defer |return |lhs := |lhs = ] callee(args) [tail]
// where callee is `name` or `pkg.name`. The argument list may continue over
// several lines (one per argument, Doodle's long-call format). Returns the
// structured node, the callee, and how many lines it used.
@(private = "file")
parse_call_statement :: proc(lines: []string) -> (node: Node, callee: string, consumed: int, ok: bool) {
	first := lines[0]
	ind := 0
	for ind < len(first) && (first[ind] == ' ' || first[ind] == '\t') do ind += 1
	s := first[ind:]

	// Optional prefix.
	pos := 0
	switch {
	case strings.has_prefix(s, "defer "):  pos = len("defer ")
	case strings.has_prefix(s, "return "): pos = len("return ")
	case:
		// `a, b := ` / `x = ` before the call.
		paren := strings.index_byte(s, '(')
		if paren > 0 {
			head := s[:paren]
			op := strings.index(head, ":=")
			oplen := 2
			if op < 0 {
				op = strings.index(head, " = ")
				oplen = 3
			}
			if op > 0 {
				// The names being assigned: `a, b` - or a typed declaration `x: windows.LPCWSTR`.
				lhs := strings.trim_space(head[:op])
				end, count := scan_name_list(lhs)
				lhs_ok := count > 0
				if lhs_ok {
					rest := strings.trim_space(lhs[end:])
					if rest != "" {
						lhs_ok = rest[0] == ':' && len(rest) > 1 && rest[1] != ':'
						for c in transmute([]u8)rest[1:] do if !(is_ident_byte(c) || c == '.' || c == ' ' || c == '^' || c == '[' || c == ']' || c == '$') { lhs_ok = false; break }
					}
				}
				if lhs_ok {
					pos = op + oplen
					for pos < len(s) && s[pos] == ' ' do pos += 1
				}
			}
		}
	}

	// Callee: ident ('.' ident)* immediately followed by '('.
	j := pos
	for {
		if j >= len(s) || !(is_ident_byte(s[j]) && !(s[j] >= '0' && s[j] <= '9')) do return
		for j < len(s) && is_ident_byte(s[j]) do j += 1
		if j < len(s) && s[j] == '.' { j += 1; continue }
		break
	}
	if j >= len(s) || s[j] != '(' do return
	callee = s[pos:j]
	for k in NOT_CALLEES do if callee == k do return

	// Find the matching ')' (possibly lines later), collecting the argument text.
	args := strings.builder_make(context.temp_allocator)
	depth := 0
	quote: u8 = 0
	tail := ""
	closed := false
	consumed = 0
	for li in 0 ..< min(len(lines), 64) {
		line := lines[li]
		start := li == 0 ? ind + j : 0
		if li > 0 do strings.write_byte(&args, ' ')
		for k := start; k < len(line); k += 1 {
			c := line[k]
			if quote != 0 {
				strings.write_byte(&args, c)
				if c == '\\' && quote != '`' && k + 1 < len(line) { k += 1; strings.write_byte(&args, line[k]); continue }
				if c == quote do quote = 0
				continue
			}
			if c == '/' && k + 1 < len(line) && line[k + 1] == '/' {
				if li > 0 do return // a comment inside a multi-line call: leave the lines as they are
				break               // a trailing comment on a one-line call is handled as tail below
			}
			switch c {
			case '"', '\'', '`': quote = c
			case '(', '[', '{':  depth += 1
			case ')', ']', '}':
				depth -= 1
				if depth == 0 {
					tail = line[k + 1:]
					closed = true
				}
			}
			if closed do break
			if !(depth == 1 && c == '(' && k == start && li == 0) do strings.write_byte(&args, c)
		}
		if closed { consumed = li + 1; break }
		if li == 0 && strings.contains(line[start:], "//") do return // comment before the call closes
	}
	if !closed do return
	if consumed > 1 && strings.trim_space(tail) != "" && !strings.has_prefix(strings.trim_space(tail), "or_") do return
	if strings.has_prefix(strings.trim_left_space(tail), "{") do return // `Stack(int){top = 1}`: a struct literal (struct_lit.odin)
	if is_ternary_tail(tail) do return // `x := f(a) if c else b`: a ternary (expr.odin)

	// Split the arguments at top-level commas, keeping empty ones (unfilled dots).
	inner := strings.to_string(args)
	parts := split_args_keep_empty(inner)
	if consumed > 1 && len(parts) > 0 && strings.trim_space(parts[len(parts) - 1]) == "" {
		parts = parts[:len(parts) - 1] // trailing comma of the one-per-line format
	}
	if len(parts) == 1 && strings.trim_space(parts[0]) == "" do parts = nil // `foo()`

	node.fields = make([dynamic]Field)
	// `\twindows.` + `MessageBoxW`: the callee's name is its own field so it can
	// be highlighted and changed (Y).
	name_at := ind + pos
	if dot := strings.last_index_byte(callee, '.'); dot >= 0 do name_at = ind + pos + dot + 1
	if name_at > 0 do emit_names_prefix(&node.fields, first[:name_at]) // `\tx := windows.`: x is a name
	append(&node.fields, Field{strings.clone(first[name_at:ind + j]), false, false, "", "", ""})
	append(&node.fields, Field{strings.clone("("), false, false, "", "", ""})
	emit_args(&node.fields, parts)
	append(&node.fields, Field{strings.clone(")"), false, false, "", "", ""})
	if tail != "" do append(&node.fields, Field{strings.clone(tail), false, false, "", "", ""})
	if consumed > 2 do record_arg_rows(&node, lines[:consumed], ind + j, len(parts))
	ok = true
	return
}

// record_arg_rows: a call written over several lines with some rows holding
// several arguments (`win32.CW_USEDEFAULT, win32.CW_USEDEFAULT,`) keeps that
// layout: the ", " ending each row is marked ARG_ROW_END and the "(" records
// the argument count (format.odin call_rows; dropped once the count changes).
@(private = "file")
record_arg_rows :: proc(node: ^Node, lines: []string, paren: int, nargs: int) {
	if strings.trim_space(lines[0][paren + 1:]) != "" do return
	if !strings.has_prefix(strings.trim_space(lines[len(lines) - 1]), ")") do return
	counts := make([dynamic]int, 0, len(lines), context.temp_allocator)
	total, several := 0, false
	for line in lines[1:len(lines) - 1] {
		t := strings.trim_space(line)
		if !strings.has_suffix(t, ",") do return
		c := len(split_args_keep_empty(t[:len(t) - 1]))
		append(&counts, c)
		total += c
		several ||= c > 1
	}
	if !several || total != nargs do return
	al, ok := find_arg_list(node^)
	if !ok || len(al.seps) != nargs - 1 do return
	at := 0
	for c in counts[:len(counts) - 1] {
		at += c
		node.fields[al.seps[at - 1]].hint = ARG_ROW_END
	}
	node.fields[al.open].hint = arg_rows_hint(nargs)
}

// emit_args appends an argument list's fields (without the parens): each
// argument structured by emit_expr, separated by ", "; empty ones are dots.
@(private = "file")
emit_args :: proc(fields: ^[dynamic]Field, parts: []string) {
	for p, i in parts {
		if i > 0 do append(fields, Field{strings.clone(", "), false, false, "", "", ""})
		arg := strings.trim_space(p)
		if arg == "" {
			append(fields, Field{"", false, true, "value", "", ""}) // an unfilled argument
		} else {
			emit_expr(fields, arg)
		}
	}
}

@(private = "file")
EXPR_BINARY_OPS := [?]string{"||", "&&", "==", "!=", "<=", ">=", "<<", ">>", "&~", "|", "&", "~", "+", "-", "*", "/", "%", "<", ">"}

// emit_expr appends the fields for one argument expression, structured so its
// parts can be highlighted and changed:
//   a | b               -> a, " | ", b          (each operand structured too)
//   pkg.name(args)      -> "pkg.", "name", "(", args..., ")"
//   "text"              -> `"`, text (editable, dictation), `"`
//   anything else       -> one fixed field
emit_expr :: proc(fields: ^[dynamic]Field, text: string) {
	s := strings.trim_space(text)
	// `a if c else b`, `c ? a : b`, `a when c else b`: the lowest precedence (expr.odin).
	if emit_ternary(fields, s) do return
	// Top-level binary operator written with spaces around it (Doodle's format).
	depth := 0
	quote: u8 = 0
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
		case ' ':
			if depth != 0 || i == 0 do continue
			for op in EXPR_BINARY_OPS {
				end := i + 1 + len(op)
				if end < len(s) && s[i + 1:end] == op && s[end] == ' ' {
					emit_expr(fields, s[:i])
					append(fields, Field{strings.concatenate({" ", op, " "}), false, false, "", "", ""})
					emit_expr(fields, s[end + 1:])
					return
				}
			}
		}
	}
	// cast(T)x, transmute(T)x, auto_cast x (expr.odin).
	if emit_conv_prefix(fields, s) do return
	// A struct literal with named fields: T{a = 1, b = x} (struct_lit.odin).
	if lit_emit_expr(fields, s) do return
	// A call: ident(.ident)* "(" ... ")" spanning the whole expression.
	j := 0
	for j < len(s) && (is_ident_byte(s[j]) || s[j] == '.') do j += 1
	if j > 0 && j < len(s) && s[j] == '(' && s[len(s) - 1] == ')' && !(s[0] >= '0' && s[0] <= '9') {
		d := 0
		q: u8 = 0
		closes_at_end := false
		for k := j; k < len(s); k += 1 {
			c := s[k]
			if q != 0 {
				if c == '\\' && q != '`' { k += 1; continue }
				if c == q do q = 0
				continue
			}
			switch c {
			case '"', '\'', '`': q = c
			case '(', '[', '{':  d += 1
			case ')', ']', '}':
				d -= 1
				if d == 0 do closes_at_end = k == len(s) - 1
			}
			if d == 0 do break
		}
		if closes_at_end {
			name_at := 0
			if dot := strings.last_index_byte(s[:j], '.'); dot >= 0 do name_at = dot + 1
			if name_at > 0 do append(fields, Field{strings.clone(s[:name_at]), false, false, "", "", ""})
			append(fields, Field{strings.clone(s[name_at:j]), false, false, "", "", ""})
			append(fields, Field{strings.clone("("), false, false, "", "", ""})
			inner := s[j + 1:len(s) - 1]
			if strings.trim_space(inner) != "" do emit_args(fields, split_args_keep_empty(inner))
			append(fields, Field{strings.clone(")"), false, false, "", "", ""})
			return
		}
	}
	// A simple string literal: its text becomes editable (dictation).
	if len(s) >= 2 && (s[0] == '"' || s[0] == '`') && s[len(s) - 1] == s[0] {
		body := s[1:len(s) - 1]
		simple := true
		for k := 0; k < len(body); k += 1 {
			if body[k] == '\\' && s[0] == '"' { k += 1; continue }
			if body[k] == s[0] { simple = false; break }
		}
		if simple {
			q := s[:1]
			append(fields, Field{strings.clone(q), false, false, "", "", ""})
			append(fields, Field{strings.clone(body), true, false, "string", "", ""})
			append(fields, Field{strings.clone(q), false, false, "", "", ""})
			return
		}
	}
	append(fields, Field{strings.clone(s), false, false, "", "", ""})
}

// Split at top-level commas, keeping empty parts (unlike split_top_level).
@(private = "file")
split_args_keep_empty :: proc(s: string) -> []string {
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

// parse_expr_fields: emit_expr for other files (ctrl_parse.odin: when conditions, #assert).
parse_expr_fields :: proc(fields: ^[dynamic]Field, text: string) { emit_expr(fields, text) }

// parse_indented_line: parse_line for an indented declaration inside a
// file-scope `when` block (the indentation becomes its own field).
parse_indented_line :: proc(line: string, in_data := false) -> Node {
	k := 0
	for k < len(line) && (line[k] == ' ' || line[k] == '\t') do k += 1
	node := parse_line(line[k:], in_data)
	if k > 0 do inject_at(&node.fields, 0, Field{strings.clone(line[:k]), false, false, "", "", ""})
	return node
}

@(private = "file")
is_ident_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

// attach_call_signature gives a parsed call's dots their expected types, adds
// dots for missing required arguments, and a green "add argument" dot when the
// proc is variadic. Calls to procs Doodle doesn't know are left as they are.
@(private = "file")
attach_call_signature :: proc(app: ^App, ni: int, callee: string) {
	ref, name := "", callee
	if dot := strings.last_index_byte(callee, '.'); dot >= 0 {
		ref, name = callee[:dot], callee[dot + 1:]
	}
	sig := call_signature(app, ref, name)
	if !sig.known do return

	fields := &app.doc.nodes[ni].fields
	open := 0
	for open < len(fields) && !(fields[open].text == "(" && !fields[open].slot) do open += 1
	close := len(fields) - 1
	for close > open && !(fields[close].text == ")" && !fields[close].slot) do close -= 1

	hints := make([dynamic]string, 0, sig.req, context.temp_allocator)
	var_hint := ""
	for p in sig.params {
		if p.variadic do var_hint = p.type
		else if !p.optional do append(&hints, p.type)
	}
	hint_for :: proc(app: ^App, sig: Call_Sig, t: string) -> string {
		return sig.pkg == "" ? intern_hint(app, t) : t
	}

	// Type the existing unfilled dots by position.
	// (Arguments split at top-level ", " only: a nested call has its own.)
	nargs := 0
	for r in arg_ranges(app.doc.nodes[ni], open + 1, close) {
		f := &fields[r[0]]
		if r[1] - r[0] == 1 && f.slot && f.kind == "value" && nargs < len(hints) {
			f.hint = hint_for(app, sig, hints[nargs])
			if f.hint != "" do f.hint_pkg = sig.pkg
		}
		nargs += 1
	}
	nargs_written, first_added := nargs, close
	// Dots for missing required arguments.
	for k in nargs ..< sig.req {
		h := k < len(hints) ? hint_for(app, sig, hints[k]) : ""
		if k > 0 { inject_at(fields, close, Field{strings.clone(", "), false, false, "", "", ""}); close += 1 }
		inject_at(fields, close, Field{"", false, true, "value", h, h != "" ? sig.pkg : ""}); close += 1
		nargs += 1
	}
	// The green "add argument" dot for variadic procs.
	if sig.variadic {
		h := hint_for(app, sig, var_hint)
		if nargs > 0 { inject_at(fields, close, Field{strings.clone(", "), false, false, "", "", ""}); close += 1 }
		inject_at(fields, close, Field{"", false, true, "args", h, h != "" ? sig.pkg : ""})
	}
	// Grouped rows recorded by record_arg_rows count only the written
	// arguments; re-stamp them for the dots added above (each on its own row,
	// as set_arg_row would), or format.odin has_arg_rows drops the layout.
	if strings.has_prefix(fields[open].hint, "argrows:") {
		if al, ok := find_arg_list(app.doc.nodes[ni]); ok && al.open == open && len(al.seps) + 1 != nargs_written {
			for s in al.seps do if s >= first_added do fields[s].hint = ARG_ROW_END
			fields[al.open].hint = arg_rows_hint(len(al.seps) + 1)
		}
	}
}

// parse_line creates a Node from a single line of source.
// Recognizes:
//   - `package <name>` -> fixed "package " + editable "<name>"
//   - Non-indented `<ident> :: <rest>` -> editable "<ident>" + fixed " :: <rest>"
//   - Everything else -> one fixed field with the whole line
@(private = "file")
parse_line :: proc(line: string, in_data := false) -> Node {
	node: Node
	node.fields = make([dynamic]Field)
	
	// Check for package declaration: exactly "package <name>"
	if strings.has_prefix(line, "package ") {
		// Two fields: fixed "package " + editable name
		append(&node.fields, Field{
			text = strings.clone("package "),
			editable = false,
			slot = false,
			kind = "",
		})
		name := line[len("package "):]
		append(&node.fields, Field{
			text = strings.clone(name),
			editable = true,
			slot = false,
			kind = "",
		})
		return node
	}
	
	// Check for top-level declaration: non-indented "<ident> :: <rest>"
	// Must start with a non-whitespace character (not indented)
	if len(line) > 0 && !is_whitespace(rune(line[0])) {
		// Find " :: " pattern
		idx := strings.index(line, " :: ")
		if idx > 0 {
			// Extract identifier (everything before " :: ")
			ident := line[:idx]
			// Check that ident is a valid identifier (letters, digits, underscore)
			if is_valid_identifier(ident) {
				// Two fields: editable ident + fixed " :: <rest>"
				append(&node.fields, Field{
					text = strings.clone(ident),
					editable = true,
					slot = false,
					kind = "",
				})
				rest := line[idx:]
				// `name :: proc(a: int, b: string) ...`: the parameter names are names too.
				if emit_proc_params(&node.fields, rest) do return node
				append(&node.fields, Field{
					text = strings.clone(rest),
					editable = false,
					slot = false,
					kind = "",
				})
				return node
			}
		}
	}
	
	// A declaration in code: `x := ...`, `a, b := ...`, `x: T = ...` - the names
	// are editable (and can be picked by "Reference").
	// (Indented or not: a file saved without indentation still has its locals.)
	if !in_data && len(line) > 0 && is_declaration(line) {
		emit_names_prefix(&node.fields, line)
		return node
	}

	// Everything else: one fixed field with the whole line
	append(&node.fields, Field{
		text = strings.clone(line),
		editable = false,
		slot = false,
		kind = "",
	})
	return node
}

// is_whitespace checks if a rune is whitespace
@(private = "file")
is_whitespace :: proc(r: rune) -> bool {
	return r == ' ' || r == '\t' || r == '\n' || r == '\r'
}

// is_valid_identifier checks if a string is a valid Odin identifier
@(private = "file")
is_valid_identifier :: proc(s: string) -> bool {
	if len(s) == 0 do return false
	
	// First character must be letter or underscore
	r, size := utf8.decode_rune_in_string(s)
	if !is_letter(r) && r != '_' do return false
	
	// Rest can be letters, digits, or underscores
	offset := size
	for offset < len(s) {
		r, size = utf8.decode_rune_in_string(s[offset:])
		if !is_letter(r) && !is_digit(r) && r != '_' do return false
		offset += size
	}
	
	return true
}

// is_letter checks if a rune is a letter
@(private = "file")
is_letter :: proc(r: rune) -> bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
}

// is_digit checks if a rune is a digit
@(private = "file")
is_digit :: proc(r: rune) -> bool {
	return r >= '0' && r <= '9'
}

// load_file reads an Odin file and parses it into app.doc.
// Returns true on success, false on error (e.g., file not found).
load_file :: proc(app: ^App, path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return false
	
	doc_from_source(app, string(data))
	normalize_cursor(app)
	return true
}

// Track the open braces of a line: push true for a data block (struct / enum /
// union / bit_field), false for code; pop on `}`. (Strings / comments skipped.)
@(private = "file")
track_blocks :: proc(blocks: ^[dynamic]bool, line: string) {
	seg := 0 // the text since the previous brace: what a `{` belongs to (data_types.odin)
	quote: u8 = 0
	for k := 0; k < len(line); k += 1 {
		c := line[k]
		if quote != 0 {
			if c == '\\' && quote != '`' { k += 1; continue }
			if c == quote do quote = 0
			continue
		}
		switch c {
		case '"', '\'', '`': quote = c
		case '/': if k + 1 < len(line) && line[k + 1] == '/' do return
		case '{':
			top := len(blocks) > 0 && blocks[len(blocks) - 1]
			append(blocks, data_kind_of_line(line[seg:k]) != .None || top)
			seg = k + 1
		case '}':
			if len(blocks) > 0 do pop(blocks)
			seg = k + 1
		}
	}
}

@(private = "file")
NOT_NAMES := [?]string{"case", "default", "return", "defer", "if", "else", "for", "switch", "when", "using", "break", "continue", "fallthrough", "package", "import", "foreign"}

// Reads `name, name2 ` at the start of s (after indentation). Returns where
// the list ends (after trailing spaces) and how many names, or 0 names.
@(private = "file")
scan_name_list :: proc(s: string) -> (end: int, count: int) {
	k := 0
	for k < len(s) && (s[k] == ' ' || s[k] == '\t') do k += 1
	for {
		if k >= len(s) || !(is_ident_byte(s[k]) && !(s[k] >= '0' && s[k] <= '9')) do return 0, 0
		st := k
		for k < len(s) && is_ident_byte(s[k]) do k += 1
		for w in NOT_NAMES do if s[st:k] == w do return 0, 0
		count += 1
		for k < len(s) && s[k] == ' ' do k += 1
		if k < len(s) && s[k] == ',' {
			k += 1
			for k < len(s) && s[k] == ' ' do k += 1
			continue
		}
		return k, count
	}
}

// `x := v`, `a, b := v`, `x: T = v`, `x: T` (but not `x :: v`, `x = v`, `case x:`).
@(private = "file")
is_declaration :: proc(line: string) -> bool {
	end, count := scan_name_list(line)
	if count == 0 || end >= len(line) do return false
	rest := line[end:]
	if strings.has_prefix(rest, ":=") do return true
	return len(rest) >= 2 && rest[0] == ':' && rest[1] != ':' && rest[1] != '='
}

// emit_names_prefix appends `text` as fields, with the leading name list
// (`x`, `a, b`) as editable fields when it's followed by `:=`, `=` or `:`.
// The fields' texts concatenate back to exactly `text`.
emit_names_prefix :: proc(fields: ^[dynamic]Field, text: string) {
	end, count := scan_name_list(text)
	rest := text[end:] if count > 0 else ""
	assigns := count > 0 && (strings.has_prefix(rest, ":=") || strings.has_prefix(rest, "=") ||
		(strings.has_prefix(rest, ":") && !strings.has_prefix(rest, "::")))
	if !assigns {
		append(fields, Field{strings.clone(text), false, false, "", "", ""})
		return
	}
	k := 0
	start := 0
	for k < end {
		if is_ident_byte(text[k]) {
			if k > start do append(fields, Field{strings.clone(text[start:k]), false, false, "", "", ""})
			st := k
			for k < end && is_ident_byte(text[k]) do k += 1
			append(fields, Field{strings.clone(text[st:k]), true, false, "", "", ""})
			start = k
		} else {
			k += 1
		}
	}
	// `x = f(...)`: the operator is an assignment operator (Y: += -= ..., loops.odin),
	// as for a menu-built assignment. Several targets only take `=`: stays fixed.
	if count == 1 && strings.has_prefix(text[start:], " = ") {
		append(fields, Field{strings.clone(" = "), false, false, ASSIGN_OP_KIND, "", ""})
		if start + 3 < len(text) do append(fields, Field{strings.clone(text[start + 3:]), false, false, "", "", ""})
		return
	}
	emit_decl_rest(fields, text, start, end)
}

// After a declaration's names (text[start:end] is the space before the
// operator): the operator as a "decl" field (Y changes the form), a typed
// declaration's type as a type field, then the rest. Exactly `text[start:]`.
@(private = "file")
emit_decl_rest :: proc(fields: ^[dynamic]Field, text: string, start, end: int) {
	rest := text[end:]
	op_len := 0
	typed := false
	switch {
	case strings.has_prefix(rest, ":="): op_len = 2
	case strings.has_prefix(rest, ":") && !strings.has_prefix(rest, "::"): op_len = 1; typed = true
	}
	if op_len == 0 { // a plain assignment `x = v`: not a declaration
		if start < len(text) do append(fields, Field{strings.clone(text[start:]), false, false, "", "", ""})
		return
	}
	k := end + op_len
	for k < len(text) && text[k] == ' ' do k += 1
	append(fields, Field{strings.clone(text[start:k]), false, false, "decl", "", ""}) // ` := ` / `: `
	if typed {
		// The type runs to the `=` (or the end): `string` in `label: string = "hi"`.
		eq := strings.index_byte(text[k:], '=')
		t_end := eq >= 0 ? k + eq : len(text)
		ty := strings.trim_right_space(text[k:t_end])
		if len(ty) > 0 {
			append(fields, Field{strings.clone(ty), true, false, "type", "", ""})
			k += len(ty)
		}
	}
	if k < len(text) && emit_structured_value(fields, text[k:]) do return // a ternary / cast(T)x value (expr.odin)
	if k < len(text) do append(fields, Field{strings.clone(text[k:]), false, false, "", "", ""})
}

// emit_proc_params: ` :: proc(a: int, b, c: string) -> int {` with the
// parameter names as editable fields. False (nothing appended) when there are
// no parameters to split. The fields concatenate back to exactly `rest`.
@(private = "file")
emit_proc_params :: proc(fields: ^[dynamic]Field, rest: string) -> bool {
	open := proc_params_open(rest) // `proc(` or `proc "c" (` (ctrl_parse.odin)
	if open < 0 do return false
	depth := 0
	close := -1
	for k in open ..< len(rest) {
		switch rest[k] {
		case '(': depth += 1
		case ')':
			depth -= 1
			if depth == 0 { close = k; break }
		}
		if close >= 0 do break
	}
	if close < 0 || strings.trim_space(rest[open + 1:close]) == "" do return false

	append(fields, Field{strings.clone(rest[:open + 1]), false, false, "", "", ""})
	inner := rest[open + 1:close]
	parts := split_args_keep_empty(inner)
	for p, pi in parts {
		if pi > 0 do append(fields, Field{strings.clone(","), false, false, "", "", ""})
		// leading spaces, optional `using ` / `$`, the name, then the rest (`: int`).
		k := 0
		for k < len(p) && p[k] == ' ' do k += 1
		if strings.has_prefix(p[k:], "using ") do k += len("using ")
		if k < len(p) && p[k] == '$' do k += 1
		st := k
		for k < len(p) && is_ident_byte(p[k]) do k += 1
		if k == st {
			append(fields, Field{strings.clone(p), false, false, "", "", ""})
			continue
		}
		if st > 0 do append(fields, Field{strings.clone(p[:st]), false, false, "", "", ""})
		append(fields, Field{strings.clone(p[st:k]), true, false, "", "", ""})
		if k < len(p) do append(fields, Field{strings.clone(p[k:]), false, false, "", "", ""})
	}
	append(fields, Field{strings.clone(rest[close:]), false, false, "", "", ""})
	return true
}

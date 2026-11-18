package model

// Formatting: a node is one logical line, but a long call is shown and saved
// with one argument per line (Odin style, trailing commas):
//
//     win.MessageBoxW(
//         nil,
//         "This is Handmade Hero.",
//         win.L("Handmade Hero"),
//         win.MB_OK | win.MB_ICONINFORMATION,
//     )
//
// The same row plan drives the editor (which also wraps rows that still don't
// fit on screen) and doc_to_source, so what you see is what gets saved.

import "core:strings"

MAX_COLS :: 80 // break a call whose line is longer than this
TAB_COLS :: 4  // a tab counts as this many columns

// Columns a string occupies (tabs = TAB_COLS).
text_cols :: proc(s: string) -> int {
	n := 0
	for c in transmute([]u8)s do n += c == '\t' ? TAB_COLS : 1
	return n
}

@(private = "file")
is_open_paren :: proc(f: Field) -> bool { return !f.slot && (f.text == "(" || f.text == "( ") }
@(private = "file")
is_close_paren :: proc(f: Field) -> bool { return !f.slot && (f.text == ")" || f.text == " )") }
@(private = "file")
is_arg_sep :: proc(f: Field) -> bool { return !f.slot && f.text == ", " }

// The outermost call argument list on a line: its "(" / ")" fields and the
// top-level ", " separators between arguments (field indices).
Arg_List :: struct {
	open, close: int,
	seps:        []int, // temp-allocated
}

find_arg_list :: proc(n: Node) -> (al: Arg_List, ok: bool) {
	depth := 0
	seps := make([dynamic]int, 0, 4, context.temp_allocator)
	for f, i in n.fields {
		if is_open_paren(f) {
			depth += 1
			if depth == 1 do al.open = i
		} else if is_close_paren(f) {
			if depth == 1 {
				al.close = i
				al.seps = seps[:]
				return al, true
			}
			depth -= 1
		} else if depth == 1 && is_arg_sep(f) {
			append(&seps, i)
		}
	}
	return {}, false
}

// One visual row of a node: fields [start, end), indented `extra_indent`
// levels deeper than the line, followed by `suffix` ("," after an argument).
Row_Span :: struct {
	start, end:   int,
	extra_indent: int,
	suffix:       string,
	is_arg:       bool,
}

// call_rows: the node laid out one argument per row. ok=false when the node
// has no call argument list (then it's a single row).
call_rows :: proc(n: Node, allocator := context.temp_allocator) -> (rows: []Row_Span, ok: bool) {
	al := find_arg_list(n) or_return
	out := make([dynamic]Row_Span, 0, len(al.seps) + 3, allocator)
	append(&out, Row_Span{start = 0, end = al.open + 1}) // head: `win.MessageBoxW(`
	start := al.open + 1
	bounds := make([dynamic]int, 0, len(al.seps) + 1, context.temp_allocator)
	for s in al.seps do append(&bounds, s)
	append(&bounds, al.close)
	for b in bounds {
		if b > start do append(&out, Row_Span{start = start, end = b, extra_indent = 1, suffix = ",", is_arg = true})
		start = b + 1
	}
	append(&out, Row_Span{start = al.close, end = len(n.fields)}) // tail: `)` and anything after
	return out[:], true
}

// Saved-source text of fields [start, end) (unfilled optional "args" dots and
// the ", " in front of them are left out, as in node_source).
range_source :: proc(n: Node, start, end: int, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for i in start ..< end {
		f := n.fields[i]
		if f.slot && f.kind == "args" do continue
		if is_arg_sep(f) && i + 1 < len(n.fields) && n.fields[i + 1].slot && n.fields[i + 1].kind == "args" do continue
		strings.write_string(&b, f.text)
	}
	return strings.to_string(b)
}

// Leading whitespace of the line (its indentation).
line_indent :: proc(n: Node) -> string {
	txt := node_text(n, context.temp_allocator)
	i := 0
	for i < len(txt) && (txt[i] == ' ' || txt[i] == '\t') do i += 1
	return txt[:i]
}

// One indentation level in the same style as `indent` (tabs unless it uses spaces).
indent_unit :: proc(indent: string) -> string {
	return len(indent) > 0 && indent[0] == ' ' ? "    " : "\t"
}

// Should this line be broken one argument per row in the saved file?
needs_break :: proc(n: Node) -> bool {
	return text_cols(node_source(n, context.temp_allocator)) > MAX_COLS
}

// node_source_lines: the saved text of a node, as one or more lines.
node_source_lines :: proc(n: Node, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, 4, allocator)
	rows, ok := call_rows(n)
	if !ok || !needs_break(n) {
		append(&out, node_source(n, allocator))
		return out[:]
	}
	base := line_indent(n)
	unit := indent_unit(base)
	for r in rows {
		text := range_source(n, r.start, r.end)
		if r.is_arg {
			text = strings.trim_space(text)
			if text == "" do continue // an unfilled optional argument
			append(&out, strings.concatenate({base, unit, text, r.suffix}, allocator))
		} else if r.start == 0 {
			append(&out, strings.clone(strings.trim_right_space(text), allocator)) // `\twin.MessageBoxW(`
		} else {
			append(&out, strings.concatenate({base, strings.trim_left_space(text)}, allocator)) // `\t)`
		}
	}
	return out[:]
}

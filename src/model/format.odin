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
is_open_paren :: proc(f: Field) -> bool { return !f.slot && (f.text == "(" || f.text == "( " || is_lit_open(f)) } // or a struct literal's "{"
@(private = "file")
is_close_paren :: proc(f: Field) -> bool { return !f.slot && (f.text == ")" || f.text == " )" || is_lit_close(f)) }
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
	al: Arg_List
	if hal, hok := header_arg_list(n); hok {
		al = hal // a procedure header: one parameter per row
	} else {
		al = find_arg_list(n) or_return
	}
	out := make([dynamic]Row_Span, 0, len(al.seps) + 3, allocator)
	append(&out, Row_Span{start = 0, end = al.open + 1}) // head: `win.MessageBoxW(`
	start := al.open + 1
	bounds := make([dynamic]int, 0, len(al.seps) + 1, context.temp_allocator)
	grouped := has_arg_rows(n, al)
	for s in al.seps do if !grouped || n.fields[s].hint == ARG_ROW_END do append(&bounds, s)
	append(&bounds, al.close)
	for b in bounds {
		if b > start do append(&out, Row_Span{start = start, end = b, extra_indent = 1, suffix = ",", is_arg = true})
		start = b + 1
	}
	append(&out, Row_Span{start = al.close, end = len(n.fields)}) // tail: `)` and anything after
	return out[:], true
}

// proc_header_parens: a menu-built procedure header (it has a "params" dot):
// the "(" field before the parameters, the params dot, and the ")" field after
// it (`[name][ :: proc ]["system"][ ( ][a][: ][T][, ][●params][ ) -> ][R][ {]`).
proc_header_parens :: proc(n: Node) -> (open, dot, close: int, ok: bool) {
	dot = -1
	for f, i in n.fields do if f.slot && f.kind == "params" { dot = i; break }
	if dot < 0 || dot + 1 >= len(n.fields) do return
	c := n.fields[dot + 1]
	if c.slot || c.editable || !strings.has_prefix(strings.trim_left_space(c.text), ")") do return
	for k := dot - 1; k >= 0; k -= 1 {
		f := n.fields[k]
		if !f.slot && !f.editable && f.kind == "" && strings.has_suffix(strings.trim_right_space(f.text), "(") {
			return k, dot, dot + 1, true
		}
	}
	return
}

// header_arg_list: a procedure header's parameter list as an Arg_List (the
// ", " between parameters are its separators).
@(private = "file")
header_arg_list :: proc(n: Node) -> (al: Arg_List, ok: bool) {
	open, _, close := proc_header_parens(n) or_return
	seps := make([dynamic]int, 0, 4, context.temp_allocator)
	depth := 0
	for i in open + 1 ..< close {
		f := n.fields[i]
		if f.slot do continue
		for c in transmute([]u8)f.text {
			switch c {
			case '(', '[', '{': depth += 1
			case ')', ']', '}': depth -= 1
			}
		}
		if depth == 0 && is_arg_sep(f) do append(&seps, i)
	}
	return Arg_List{open, close, seps[:]}, true
}

// Saved-source text of fields [start, end) (unfilled optional "args" dots and
// the ", " in front of them are left out, as in node_source).
range_source :: proc(n: Node, start, end: int, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for i in start ..< end {
		f := n.fields[i]
		if is_optional_dot(f) do continue
		if is_arg_sep(f) && i + 1 < len(n.fields) && is_optional_dot(n.fields[i + 1]) do continue
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

// A call loaded with several arguments on some rows (`a, b,` per line) keeps
// that layout: the ", " ending a row has hint ARG_ROW_END, and the "(" hint
// records the argument count. Once arguments are added or removed the
// recorded layout no longer applies (default: one argument per row).
ARG_ROW_END :: "rowend"

arg_rows_hint :: proc(nargs: int) -> string {
	return nargs >= 0 && nargs < len(ARG_ROWS_HINTS) ? ARG_ROWS_HINTS[nargs] : "argrows:"
}

@(private = "file")
ARG_ROWS_HINTS := [?]string{
	"argrows:0",
	"argrows:1",
	"argrows:2",
	"argrows:3",
	"argrows:4",
	"argrows:5",
	"argrows:6",
	"argrows:7",
	"argrows:8",
	"argrows:9",
	"argrows:10",
	"argrows:11",
	"argrows:12",
	"argrows:13",
	"argrows:14",
	"argrows:15",
	"argrows:16",
	"argrows:17",
	"argrows:18",
	"argrows:19",
	"argrows:20",
	"argrows:21",
	"argrows:22",
	"argrows:23",
	"argrows:24",
	"argrows:25",
	"argrows:26",
	"argrows:27",
	"argrows:28",
	"argrows:29",
	"argrows:30",
	"argrows:31",
	"argrows:32",
	"argrows:33",
	"argrows:34",
	"argrows:35",
	"argrows:36",
	"argrows:37",
	"argrows:38",
	"argrows:39",
	"argrows:40",
	"argrows:41",
	"argrows:42",
	"argrows:43",
	"argrows:44",
	"argrows:45",
	"argrows:46",
	"argrows:47",
	"argrows:48",
	"argrows:49",
	"argrows:50",
	"argrows:51",
	"argrows:52",
	"argrows:53",
	"argrows:54",
	"argrows:55",
	"argrows:56",
	"argrows:57",
	"argrows:58",
	"argrows:59",
	"argrows:60",
	"argrows:61",
	"argrows:62",
	"argrows:63",
}

has_arg_rows :: proc(n: Node, al: Arg_List) -> bool {
	h := n.fields[al.open].hint
	if !strings.has_prefix(h, "argrows:") do return false
	// A matching count is the mark: with no ARG_ROW_END the arguments share one row.
	return len(al.seps) > 0 && h == arg_rows_hint(len(al.seps) + 1)
}

// Should this line be broken one argument per row in the saved file?
needs_break :: proc(n: Node) -> bool {
	if branch_no_break(n) do return false // if / switch headers, case labels stay on one line (branch.odin)
	if loop_keeps_one_line(n) do return false // a loop header, `x += f(...)`: one line, as the loader reads them (loops.odin)
	if value_is_compound(n) do return false // `x = f(a) if c else g(b)`, `x := cast(T)f(a)`: one line (expr.odin)
	// `#assert(...)` stays on one line (Odin allows it; the loader structures
	// only the one-line form).
	for f in n.fields {
		if !f.slot && !f.editable && strings.trim_space(f.text) == "" do continue
		if !f.slot && f.kind == KW && f.text == "#assert" do return false
		break
	}
	// A struct literal loaded one field per line stays that way (struct_lit.odin).
	// (Not once all its fields are deleted: then it's `T{}` again.)
	if al, ok := find_arg_list(n); ok && n.fields[al.open].hint == LIT_BREAK {
		close := lit_close_of(n, al.open)
		for i in al.open + 1 ..< max(close, al.open + 1) {
			f := n.fields[i]
			if !is_optional_dot(f) && !is_arg_sep(f) do return true
		}
	}
	// So does a call loaded with grouped argument rows.
	if al, ok := find_arg_list(n); ok && has_arg_rows(n, al) do return true
	return text_cols(node_source(n, context.temp_allocator)) > MAX_COLS
}

// The `name` field of a literal row `name = value` (fields [r.start, r.end)), or -1.
@(private = "file")
lit_row_key :: proc(n: Node, r: Row_Span) -> int {
	k := r.start
	for k < r.end && !n.fields[k].slot && strings.trim_space(n.fields[k].text) == "" do k += 1
	if k + 1 >= r.end || n.fields[k].slot || n.fields[k].kind != LIT_KEY_KIND do return -1
	if n.fields[k + 1].slot || strings.trim_space(n.fields[k + 1].text) != "=" do return -1
	return k
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
	// A struct literal broken for width (built from the menus, or loaded with
	// its `=` signs aligned - LIT_ALIGNED): `T {` and its `name = value` rows
	// with the `=` signs aligned, as Odin code is usually written. Another
	// loaded literal keeps its own spacing.
	al, _ := find_arg_list(n)
	styled := is_lit_open(n.fields[al.open]) && (n.fields[al.open].hint != LIT_BREAK || n.fields[al.open].hint_pkg == LIT_ALIGNED)
	key_w := 0
	if styled do for r in rows do if r.is_arg && lit_row_key(n, r) >= 0 do key_w = max(key_w, len(n.fields[lit_row_key(n, r)].text))
	for r in rows {
		text := range_source(n, r.start, r.end)
		if styled && r.is_arg {
			if k := lit_row_key(n, r); k >= 0 {
				key := n.fields[k].text
				pad := strings.repeat(" ", key_w - len(key), context.temp_allocator)
				text = strings.concatenate({key, pad, " = ", range_source(n, k + 2, r.end)}, context.temp_allocator)
			}
		} else if styled && r.start == 0 && al.open > 0 && n.fields[al.open].hint != LIT_BREAK && n.fields[al.open].text == "{" && !strings.has_suffix(n.fields[al.open - 1].text, " ") {
			text = strings.concatenate({range_source(n, 0, al.open), " {"}, context.temp_allocator)
		}
		if r.is_arg {
			text = strings.trim_space(text)
			// An unfilled optional ("args") dot is left out; an unfilled required
			// argument keeps its place as a bare `,` line, so loading the file
			// back puts the dot in the right position.
			only_optional := true
			for fi in r.start ..< r.end {
				f := n.fields[fi]
				if !is_optional_dot(f) && !(f.slot && f.kind == "params") { only_optional = false; break }
			}
			if text == "" && only_optional do continue
			append(&out, strings.concatenate({base, unit, text, r.suffix}, allocator))
		} else if r.start == 0 {
			append(&out, strings.clone(strings.trim_right_space(text), allocator)) // `\twin.MessageBoxW(`
		} else {
			append(&out, strings.concatenate({base, strings.trim_left_space(text)}, allocator)) // `\t)`
		}
	}
	return out[:]
}

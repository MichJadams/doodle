package model

// Multi-line comments: File Setup > Comments > Multi-line comment, and Layout >
// Multi-line comment inside a function.
//
//   /*                 the markers: stops (LT+B on one deletes the comment)
//   	brave otter     each line: editable text (dictate into it)
//   */
//
//   Y on a line of it      adds a line after it
//   LT+B on a line of it   deletes that line (the last one: the comment)
//
// No green dots inside it (code can't be added into a comment), its braces
// don't count for indentation or blocks, and the loader structures a
// `/*` ... `*/` whose markers are on lines of their own the same way.

import "core:strings"

COMMENT_MARK         :: "comment_mark" // the `/*` / `*/` field of a multi-line comment
BLOCK_COMMENT_INSERT :: "\x00multi-line comment" // File Setup > Comments > Multi-line comment
BLOCK_COMMENT_FILL   :: "__stmt_block_comment__" // Layout > Multi-line comment (in a function)

@(private = "file")
has_mark :: proc(n: Node, text: string) -> bool {
	for f in n.fields do if f.kind == COMMENT_MARK && strings.trim_space(f.text) == text do return true
	return false
}

block_comment_open  :: proc(n: Node) -> bool { return has_mark(n, "/*") }
block_comment_close :: proc(n: Node) -> bool { return has_mark(n, "*/") }

// A line of a multi-line comment's text (editable comment text, no `//`).
block_comment_body :: proc(n: Node) -> bool {
	for f in n.fields do if f.kind == COMMENT_KIND do return !is_comment_line(n)
	return false
}

// Any line of a multi-line comment (its markers or its text).
in_block_comment :: proc(n: Node) -> bool { return block_comment_open(n) || block_comment_close(n) || block_comment_body(n) }

// block_comment_range: the `/*` and `*/` lines of the comment line ni is in.
block_comment_range :: proc(app: ^App, ni: int) -> (s, e: int, ok: bool) {
	if ni < 0 || ni >= len(app.doc.nodes) || !in_block_comment(app.doc.nodes[ni]) do return
	s = ni
	for s >= 0 && !block_comment_open(app.doc.nodes[s]) {
		if !in_block_comment(app.doc.nodes[s]) do return
		s -= 1
	}
	e = ni
	for e < len(app.doc.nodes) && !block_comment_close(app.doc.nodes[e]) {
		if !in_block_comment(app.doc.nodes[e]) do return
		e += 1
	}
	if s < 0 || e >= len(app.doc.nodes) do return
	return s, e, true
}

@(private = "file")
mark_line :: proc(indent, mark: string) -> Node {
	n: Node
	if indent != "" do append(&n.fields, Field{strings.clone(indent), false, false, "", "", ""})
	append(&n.fields, Field{strings.clone(mark), false, false, COMMENT_MARK, "", ""})
	return n
}

@(private = "file")
text_line :: proc(indent, text: string) -> Node {
	n: Node
	if indent != "" do append(&n.fields, Field{strings.clone(indent), false, false, "", "", ""})
	append(&n.fields, Field{strings.clone(text), true, false, COMMENT_KIND, "", ""})
	return n
}

// The lines of a new multi-line comment at `indent`, its text `text`.
@(private = "file")
new_block_comment :: proc(indent, text: string) -> [3]Node {
	return {mark_line(indent, "/*"), text_line(strings.concatenate({indent, "\t"}, context.temp_allocator), text), mark_line(indent, "*/")}
}

// inside_block_comment: is the gap before line i inside a comment (no green
// dot there: code can't go into a comment)?
inside_block_comment :: proc(app: ^App, i: int) -> bool {
	return i > 0 && i < len(app.doc.nodes) && in_block_comment(app.doc.nodes[i]) && !block_comment_open(app.doc.nodes[i])
}

// ---- Adding one ----

// File Setup > Comments > Multi-line comment (layout_add_insert).
block_comment_insert :: proc(app: ^App) {
	nodes := new_block_comment("", comment_placeholder(app))
	for n in nodes do doc_insert(app, n)
}

// Layout > Multi-line comment on the statement dot (ni, fi) (layout_fill): the
// comment in the statement's place, a statement dot after it.
block_comment_fill :: proc(app: ^App, ni, fi: int) -> (text_line_ni: int) {
	indent := strings.clone(line_indent(app.doc.nodes[ni]), context.temp_allocator)
	nodes := new_block_comment(indent, comment_placeholder(app))
	for f in app.doc.nodes[ni].fields do if len(f.text) > 0 do delete(f.text)
	delete(app.doc.nodes[ni].fields)
	app.doc.nodes[ni] = nodes[0]
	inject_at(&app.doc.nodes, ni + 1, nodes[1], nodes[2])
	next: Node
	append(&next.fields, Field{strings.clone(indent), false, false, "", "", ""})
	append(&next.fields, Field{"", false, true, "body", "", ""})
	inject_at(&app.doc.nodes, ni + 3, next)
	return ni + 1
}

// ---- Y and LT+B ----

// block_comment_change (Y): on a line of a multi-line comment, a new line after
// it (after `/*` on the opening marker), focused for dictation.
block_comment_change :: proc(app: ^App) -> bool {
	ni := app.editor_line
	if app.editor_dot || ni < 0 || ni >= len(app.doc.nodes) do return false
	s, e, ok := block_comment_range(app, ni)
	if !ok do return false
	at := ni == e ? e : ni + 1 // on `*/`: before it
	indent := strings.concatenate({line_indent(app.doc.nodes[s]), "\t"}, context.temp_allocator)
	if block_comment_body(app.doc.nodes[ni]) do indent = strings.clone(line_indent(app.doc.nodes[ni]), context.temp_allocator)
	inject_at(&app.doc.nodes, at, text_line(indent, comment_placeholder(app)))
	focus_kth_selectable(app, at, 0)
	return true
}

// block_comment_delete (LT+B): a text line goes (the last one: the whole
// comment); on a marker, the whole comment.
block_comment_delete :: proc(app: ^App) -> bool {
	ni := app.editor_line
	if app.editor_dot || ni < 0 || ni >= len(app.doc.nodes) do return false
	s, e, ok := block_comment_range(app, ni)
	if !ok do return false
	if block_comment_body(app.doc.nodes[ni]) && e - s > 2 {
		remove_node(app, ni)
		focus_kth_selectable(app, min(ni, e - 1), 0)
		return true
	}
	for _ in s ..= e do remove_node(app, s)
	app.editor_line = min(s, len(app.doc.nodes))
	app.editor_field = 0
	normalize_cursor(app)
	return true
}

// The hint for the cursor on a multi-line comment (ctrl_hint).
block_comment_hint :: proc(app: ^App) -> string {
	if app.editor_dot || app.editor_line < 0 || app.editor_line >= len(app.doc.nodes) do return ""
	n := app.doc.nodes[app.editor_line]
	if block_comment_body(n) do return "Y: add a line    LT+B: delete line"
	if block_comment_open(n) || block_comment_close(n) do return "Y: add a line    LT+B: delete comment"
	return ""
}

// ---- Loading ----

// parse_block_comment: lines[0] is `/*` on its own line, and a later line is
// `*/` on its own: the comment as lines (the markers, then each line's text
// editable). consumed: how many lines it took.
parse_block_comment :: proc(lines: []string) -> (nodes: [dynamic]Node, consumed: int, ok: bool) {
	if len(lines) == 0 || strings.trim_space(lines[0]) != "/*" do return
	end := -1
	for k in 1 ..< len(lines) do if strings.trim_space(lines[k]) == "*/" { end = k; break }
	if end < 0 do return
	lead :: proc(l: string) -> (string, string) {
		k := 0
		for k < len(l) && (l[k] == ' ' || l[k] == '\t') do k += 1
		return l[:k], strings.trim_right_space(l[k:])
	}
	nodes = make([dynamic]Node, 0, end + 1)
	ind, _ := lead(lines[0])
	append(&nodes, mark_line(ind, "/*"))
	for k in 1 ..< end {
		i, txt := lead(lines[k])
		append(&nodes, text_line(i, txt))
	}
	ind, _ = lead(lines[end])
	append(&nodes, mark_line(ind, "*/"))
	return nodes, end + 1, true
}

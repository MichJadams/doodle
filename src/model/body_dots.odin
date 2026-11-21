package model

// Green insertion dots inside functions: one above the first statement, one
// between each pair of statements and one below the last, at every nesting
// level (inside if / for / ... blocks too). They're cursor stops like the
// top-level dots; A on one opens the statement menu (declarations, calls,
// branching, ...) and inserts the new statement right there.
//
// Inside data blocks (struct / enum / union / bit_field bodies) the dots work the
// same way but offer members instead (data_types.odin). Not shown next to an
// empty "●" statement line (that one already offers the same menu). There is a
// dot above a run of blank lines and one right after it (to start a paragraph),
// but none between two blank lines, nor between a blank line and a closing `}`
// (an empty function saved and loaded back has a blank line where its "●" was:
// one dot, not one above and one below it).

import "core:strings"

// A blank line (only whitespace, no dots).
is_blank_line :: proc(n: Node) -> bool {
	for f in n.fields do if f.slot || strings.trim_space(f.text) != "" do return false
	return true
}

// An empty statement line: just indentation and a body dot.
is_body_slot_line :: proc(n: Node) -> bool {
	switch len(n.fields) {
	case 1: return n.fields[0].slot && n.fields[0].kind == "body"
	case 2: return !n.fields[0].slot && strings.trim_space(n.fields[0].text) == "" && n.fields[1].slot && n.fields[1].kind == "body"
	}
	return false
}

// Does a line opening a block open *code* (a proc body, if/for/... inside one)?
// (A `{` that opens data - struct/enum/union/bit_field fields - is found first,
// per brace, by data_kind_of_line.)
@(private = "file")
opens_code :: proc(txt: string, in_code: bool) -> bool {
	return in_code || strings.contains(txt, "proc(") || strings.contains(txt, "proc \"") || strings.contains(txt, ":: proc")
}

// body_points: bp[i] is true when a green dot sits before line i inside a
// function body or a data body. (Top-level dots are insertion_points.)
body_points :: proc(app: ^App, allocator := context.temp_allocator) -> []bool {
	n := len(app.doc.nodes)
	bp := make([]bool, n + 1, allocator)
	stack := make([dynamic]bool, 0, 8, context.temp_allocator) // per open brace: is it code?
	for i in 0 ..< n {
		in_code := len(stack) > 0 && stack[len(stack) - 1]
		prev := app.doc.nodes[i - 1] if i > 0 else Node{}
		cur := app.doc.nodes[i]
		// After a run of blank lines: a dot on the first real line (not between two
		// blanks, and not before a closing `}`, so an empty function `{\n\n}` keeps one dot).
		after_blank_ok := !is_blank_line(prev) || (!is_blank_line(cur) && !strings.has_prefix(strings.trim_space(node_text(cur, context.temp_allocator)), "}"))
		if in_code && i > 0 && !is_body_slot_line(cur) && !is_body_slot_line(prev) && after_blank_ok {
			bp[i] = true
		}
		// Track braces on this line (outside strings and comments).
		txt := node_text(app.doc.nodes[i], context.temp_allocator)
		quote: u8 = 0
		seg := 0 // start of the text since the previous brace (what this `{` belongs to)
		for k := 0; k < len(txt); k += 1 {
			c := txt[k]
			if quote != 0 {
				if c == '\\' && quote != '`' { k += 1; continue }
				if c == quote do quote = 0
				continue
			}
			switch c {
			case '"', '\'', '`': quote = c
			case '/':
				if k + 1 < len(txt) && txt[k + 1] == '/' do k = len(txt)
			case '{':
				top := len(stack) > 0 && stack[len(stack) - 1]
				header := strings.has_prefix(strings.trim_left_space(txt), ")") && multi_line_header_end(app, i) // `) -> T {`
				append(&stack, data_kind_of_line(txt[seg:k]) != .None || opens_code(txt, top) || header) // data bodies get dots too
				seg = k + 1
			case '}':
				if len(stack) > 0 do pop(&stack)
				seg = k + 1
			}
		}
	}
	return bp
}

// Line i (`) -> T {`) ends a procedure header whose parameters run over the
// lines above it (`name :: proc "system" (` ... `)`).
@(private = "file")
multi_line_header_end :: proc(app: ^App, i: int) -> bool {
	for j := i - 1; j >= 0 && i - j < 64; j -= 1 {
		t := node_text(app.doc.nodes[j], context.temp_allocator)
		if strings.contains(t, "{") || strings.contains(t, "}") do return false
		if opens_code(t, false) do return true
	}
	return false
}

// The indentation for a statement inserted before line i (inside a body):
// the next statement's, else the previous statement's, else one level deeper
// than the block header just above.
body_indent_at :: proc(app: ^App, i: int) -> string {
	if ind, ok := branch_body_indent(app, i); ok do return ind // next to case labels (branch.odin)
	n := len(app.doc.nodes)
	if i < n {
		t := strings.trim_space(node_text(app.doc.nodes[i], context.temp_allocator))
		if !strings.has_prefix(t, "}") && t != "" do return line_indent(app.doc.nodes[i]) // (a blank line has none)
	}
	if i > 0 {
		prev := app.doc.nodes[i - 1]
		ind := line_indent(prev)
		opens := brace_delta(app, i - 1) > 0 || !is_comment_line(prev) && strings.has_suffix(strings.trim_space(node_text(prev, context.temp_allocator)), "{") // (`} else {` too; not `// see {`)
		if opens do return strings.concatenate({ind, doc_indent_unit(app)}, context.temp_allocator)
		return ind
	}
	return doc_indent_unit(app)
}

// The document's indentation style: a tab, or 4 spaces (Doodle's own bodies).
@(private = "file")
doc_indent_unit :: proc(app: ^App) -> string {
	for n in app.doc.nodes {
		ind := line_indent(n)
		if len(ind) > 0 do return ind[0] == '\t' ? "\t" : "    "
	}
	return "    "
}

// open_body_insert: A on a dot inside a function. A temporary statement line is
// added there and the statement menu opened for it; picking a statement keeps
// it (without the extra trailing "●" line statements normally add), cancelling
// removes it again.
open_body_insert :: proc(app: ^App, i: int) {
	if i < 0 || i > len(app.doc.nodes) do return
	indent := strings.clone(body_indent_at(app, i), context.temp_allocator)
	// An empty block that only holds blank line(s) (an empty function saved and
	// loaded back): the new statement takes the blank line's place.
	app.body_insert_blank = ""
	app.body_insert_reused = false
	if i < len(app.doc.nodes) && i > 0 && is_blank_line(app.doc.nodes[i]) && brace_delta(app, i - 1) > 0 {
		j := i
		for j < len(app.doc.nodes) && is_blank_line(app.doc.nodes[j]) do j += 1
		if j < len(app.doc.nodes) && strings.has_prefix(strings.trim_space(node_text(app.doc.nodes[j], context.temp_allocator)), "}") {
			app.body_insert_blank = strings.clone(node_text(app.doc.nodes[i], context.temp_allocator))
			app.body_insert_reused = true
			remove_node(app, i)
		}
	}
	line: Node
	append(&line.fields, Field{strings.clone(indent), false, false, "", "", ""})
	append(&line.fields, Field{"", false, true, "body", "", ""})
	inject_at(&app.doc.nodes, i, line)
	app.body_insert_active = true
	app.body_insert_ni = i
	focus_field_index(app, i, 1)
	open_slot_menu(app)
	if app.state != .Radial do body_insert_cancel(app)
}

// A statement was picked at a body dot: drop the trailing empty "●" line that
// statements add after themselves (the dots already cover that).
body_insert_done :: proc(app: ^App) {
	if !app.body_insert_active do return
	app.body_insert_active = false
	if app.body_insert_reused { // the blank line was replaced for good
		delete(app.body_insert_blank)
		app.body_insert_blank = ""
		app.body_insert_reused = false
	}
	ni := app.body_insert_ni
	if ni < 0 || ni >= len(app.doc.nodes) do return
	e := ni
	if brace_delta(app, ni) > 0 { // a block statement (if / for / ...): skip to its end
		balance := 0
		for j in ni ..< len(app.doc.nodes) {
			balance += brace_delta(app, j)
			e = j
			if balance <= 0 do break
		}
	}
	if e + 1 < len(app.doc.nodes) && is_body_slot_line(app.doc.nodes[e + 1]) {
		remove_node(app, e + 1)
	}
}

// The statement menu was cancelled: remove the temporary line, back to the dot.
body_insert_cancel :: proc(app: ^App) {
	if !app.body_insert_active do return
	app.body_insert_active = false
	ni := app.body_insert_ni
	if ni >= 0 && ni < len(app.doc.nodes) && is_body_slot_line(app.doc.nodes[ni]) do remove_node(app, ni)
	if app.body_insert_reused { // put the blank line back
		blank: Node
		append(&blank.fields, Field{app.body_insert_blank, false, false, "", "", ""}) // ownership moves to the doc
		inject_at(&app.doc.nodes, ni, blank)
		app.body_insert_blank = ""
		app.body_insert_reused = false
	}
	focus_dot_at(app, ni)
}

@(private = "file")
remove_node :: proc(app: ^App, ni: int) {
	for f in app.doc.nodes[ni].fields do if len(f.text) > 0 do delete(f.text)
	delete(app.doc.nodes[ni].fields)
	ordered_remove(&app.doc.nodes, ni)
}

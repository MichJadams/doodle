package model

// format_doc: Odin-style formatting of the whole document (run on load, on save,
// and from the IDE menu):
//   - indentation by nesting: one tab per open { ( [ ; lines starting with a
//     closer (`}`, `) or_return`, `} else {`) and `case` labels sit one level out
//   - one blank line after `package`, imports kept together with one blank line
//     after them, one blank line around every multi-line top-level construct
//     (procs, structs, ...); a comment right above a construct stays attached
//   - runs of blank lines become one; no blank lines just inside { ... }, at the
//     start, or at the end of the file
// Lines with dots ("●" statement lines etc.) are never removed.

import "core:strings"

// Brace / paren / bracket balance of a line, outside strings and comments,
// and how many closers it starts with.
@(private = "file")
line_balance :: proc(txt: string) -> (delta: int, leading_closers: int) {
	t := strings.trim_left_space(txt)
	for k := 0; k < len(t) && (t[k] == '}' || t[k] == ')' || t[k] == ']'); k += 1 do leading_closers += 1
	quote: u8 = 0
	for k := 0; k < len(txt); k += 1 {
		c := txt[k]
		if quote != 0 {
			if c == '\\' && quote != '`' { k += 1; continue }
			if c == quote do quote = 0
			continue
		}
		switch c {
		case '"', '\'', '`': quote = c
		case '/': if k + 1 < len(txt) && txt[k + 1] == '/' do return
		case '{', '(', '[': delta += 1
		case '}', ')', ']': delta -= 1
		}
	}
	return
}

// Set a line's indentation (its leading whitespace) to `indent`.
@(private = "file")
set_indent :: proc(n: ^Node, indent: string) {
	if is_blank_line(n^) {
		for f in n.fields do if len(f.text) > 0 do delete(f.text)
		clear(&n.fields)
		append(&n.fields, Field{strings.clone(""), false, false, "", "", ""})
		return
	}
	// Drop leading whitespace: whole whitespace-only fixed fields, and the start
	// of the first fixed text field.
	for len(n.fields) > 0 {
		f := &n.fields[0]
		if f.slot || f.editable do break
		trimmed := strings.trim_left_space(f.text)
		if trimmed == "" {
			delete(f.text)
			ordered_remove(&n.fields, 0)
			continue
		}
		if len(trimmed) != len(f.text) {
			t := strings.clone(trimmed)
			delete(f.text)
			f.text = t
		}
		break
	}
	if indent == "" do return
	// A fixed first field takes the indent at its front; otherwise (a name or a
	// dot first) the indent is its own field.
	if len(n.fields) > 0 && !n.fields[0].slot && !n.fields[0].editable && n.fields[0].kind == "" {
		t := strings.concatenate({indent, n.fields[0].text})
		delete(n.fields[0].text)
		n.fields[0].text = t
	} else {
		inject_at(&n.fields, 0, Field{strings.clone(indent), false, false, "", "", ""})
	}
}

// What a top-level construct is, for blank-line grouping.
@(private = "file")
Top_Kind :: enum { Package, Import, Comment, Single, Block }

format_doc :: proc(app: ^App) {
	split_one_line_blocks(app) // `for x in xs { }` -> header / body / `}` lines (block_split.odin)
	n := len(app.doc.nodes)
	if n == 0 do return

	// 1) Indentation.
	depth := 0
	for i in 0 ..< n {
		txt := node_text(app.doc.nodes[i], context.temp_allocator)
		delta, lead := line_balance(txt)
		t := strings.trim_space(txt)
		level := depth - lead
		if strings.has_prefix(t, "case ") || strings.has_prefix(t, "case:") do level -= 1
		else if strings.has_prefix(t, "//") {
			// A comment (run) right above a `case` label sits at the label's level.
			for j := i + 1; j < n; j += 1 {
				tj := strings.trim_space(node_text(app.doc.nodes[j], context.temp_allocator))
				if strings.has_prefix(tj, "//") do continue
				if strings.has_prefix(tj, "case ") || strings.has_prefix(tj, "case:") do level -= 1
				break
			}
		}
		level = max(level, 0)
		set_indent(&app.doc.nodes[i], strings.repeat("\t", level, context.temp_allocator))
		depth = max(depth + delta, 0)
	}

	// 2) Blank lines. Build the new order as indices into the old nodes
	//    (-1 = a new blank line), then rebuild.
	cur_line := app.editor_line
	out := make([dynamic]int, 0, n + 8, context.temp_allocator)
	blank :: proc(app: ^App, i: int) -> bool { return is_blank_line(app.doc.nodes[i]) }
	last_out_blank :: proc(app: ^App, out: [dynamic]int) -> bool {
		return len(out) == 0 || out[len(out) - 1] == -1 || is_blank_line(app.doc.nodes[out[len(out) - 1]])
	}
	ends_open :: proc(app: ^App, i: int) -> bool {
		return !is_comment_line(app.doc.nodes[i]) && strings.has_suffix(strings.trim_space(node_text(app.doc.nodes[i], context.temp_allocator)), "{")
	}

	// Top-level constructs: their start line and kind.
	prev_kind: Top_Kind
	have_prev := false
	depth = 0
	for i := 0; i < n; i += 1 {
		txt := node_text(app.doc.nodes[i], context.temp_allocator)
		delta, _ := line_balance(txt)
		at_top := depth == 0
		t := strings.trim_space(txt)

		if blank(app, i) {
			// Keep one blank line, except at the start, after another blank, just
			// inside a block (after `{`), or just before `}`.
			next_closes := false
			for j := i + 1; j < n; j += 1 {
				if blank(app, j) do continue
				next_closes = strings.has_prefix(strings.trim_space(node_text(app.doc.nodes[j], context.temp_allocator)), "}")
				break
			}
			after_open := len(out) > 0 && out[len(out) - 1] >= 0 && ends_open(app, out[len(out) - 1])
			last_line := true
			for j := i + 1; j < n; j += 1 do if !blank(app, j) { last_line = false; break }
			if !last_out_blank(app, out) && !after_open && !next_closes && !last_line do append(&out, i)
			continue
		}

		if at_top {
			kind: Top_Kind
			switch {
			case strings.has_prefix(t, "package "):                                    kind = .Package
			case strings.has_prefix(t, "import ") || strings.has_prefix(t, "foreign import "): kind = .Import
			case strings.has_prefix(t, "//") || strings.has_prefix(t, "@"):            kind = .Comment // attributes stay on their declaration too
			case delta > 0:                                                            kind = .Block
			case:                                                                       kind = .Single
			}
			// A comment belongs to what follows it: decide its spacing from that.
			eff := kind
			if kind == .Comment {
				for j := i + 1; j < n; j += 1 {
					if blank(app, j) do break
					tj := strings.trim_space(node_text(app.doc.nodes[j], context.temp_allocator))
					if strings.has_prefix(tj, "//") || strings.has_prefix(tj, "@") do continue
					dj, _ := line_balance(node_text(app.doc.nodes[j], context.temp_allocator))
					eff = dj > 0 ? .Block : .Single
					break
				}
			}
			// One blank line between different kinds of construct, and around blocks.
			// (Nothing between a comment and what it documents.)
			if have_prev && prev_kind != .Comment {
				need := prev_kind != eff || eff == .Block || prev_kind == .Block
				if need && !last_out_blank(app, out) do append(&out, -1)
			}
			prev_kind = kind == .Comment ? .Comment : eff
			have_prev = true
		}
		append(&out, i)
		depth = max(depth + delta, 0)
	}

	// Rebuild the node list in the new order (dropping blanks that weren't kept).
	keep := make([]bool, n, context.temp_allocator)
	for k in out do if k >= 0 do keep[k] = true
	new_nodes := make([dynamic]Node, 0, len(out))
	old_to_new := make([]int, n + 1, context.temp_allocator)
	for k in out {
		if k >= 0 {
			old_to_new[k] = len(new_nodes)
			append(&new_nodes, app.doc.nodes[k])
		} else {
			nb: Node
			append(&nb.fields, Field{strings.clone(""), false, false, "", "", ""})
			append(&new_nodes, nb)
		}
	}
	for i in 0 ..< n {
		if keep[i] do continue
		for f in app.doc.nodes[i].fields do if len(f.text) > 0 do delete(f.text)
		delete(app.doc.nodes[i].fields)
		// a dropped blank line: its "position" is the next kept line
		old_to_new[i] = -1
	}
	old_to_new[n] = len(new_nodes)
	for i := n - 1; i >= 0; i -= 1 do if old_to_new[i] < 0 do old_to_new[i] = old_to_new[i + 1]
	delete(app.doc.nodes)
	app.doc.nodes = new_nodes

	// Keep the cursor on the same line.
	if cur_line >= 0 && cur_line <= n do app.editor_line = old_to_new[cur_line]
	normalize_cursor(app)
}

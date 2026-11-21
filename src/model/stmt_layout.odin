package model

// Statement-level layout: comments, blank lines and grouped call-argument rows.
//
//   - "Comment" (statement menu, and File Setup > Comments at file scope) adds
//     `// <text>`: the text is an editable field (COMMENT_KIND) that dictation
//     fills with free text. Loaded comment lines get the same fields, so they
//     can be re-dictated, deleted with LT+B and keep their green dots.
//   - "Blank line" (statement menu, and File Setup at file scope) adds an empty
//     line. format_doc keeps a single blank line between statements (it drops
//     the ones just after `{` or just before `}`). LT+B on the green dot right
//     above a blank line (or right below it) removes it.
//   - Y on an argument of a call that's broken one argument per row offers
//     "Join with previous row" / "Own row": several arguments on one row, as in
//         win32.CW_USEDEFAULT, win32.CW_USEDEFAULT,
//         nil, nil, instance, nil,
//     (the ", " ending a row is marked ARG_ROW_END, format.odin).

import "core:strings"

COMMENT_KIND :: "comment" // the editable text of a `// text` line

COMMENT_FILL :: "__stmt_comment__"
BLANK_FILL   :: "__stmt_blank__"
ARG_ROW_FILL :: "__arg_row__" // call_name: "join" / "own"

// Add menu (File Setup) leaves: Entry.insert markers.
COMMENT_INSERT :: "// comment"
BLANK_INSERT   :: "\x00blank line"

// A `// text` line (code or file scope).
is_comment_line :: proc(n: Node) -> bool {
	return strings.has_prefix(strings.trim_left_space(node_text(n, context.temp_allocator)), "//")
}

// The fields of `// text` at fields[at]: the fixed marker, then the editable text.
@(private = "file")
inject_comment :: proc(fields: ^[dynamic]Field, at: int, marker, text: string) {
	inject_at(fields, at,
		Field{strings.clone(marker), false, false, "", "", ""},
		Field{strings.clone(text), true, false, COMMENT_KIND, "", ""},
	)
}

// Placeholder text for a new comment: a generated name, as words ("brave otter").
@(private = "file")
comment_placeholder :: proc(app: ^App) -> string {
	name := generate_ident(app)
	defer delete(name)
	s, _ := strings.replace_all(name, "_", " ", context.temp_allocator)
	return s
}

// parse_comment_line: a whole-line `// text` comment (any indentation) as
// [indent]["// "][text (editable)]. Empty comments and `//+` tags stay one
// fixed field. Round-trips exactly.
parse_comment_line :: proc(line: string) -> (node: Node, ok: bool) {
	k := 0
	for k < len(line) && (line[k] == ' ' || line[k] == '\t') do k += 1
	rest := line[k:]
	if !strings.has_prefix(rest, "//") || strings.has_prefix(rest, "//+") do return
	marker := strings.has_prefix(rest, "// ") ? rest[:3] : rest[:2]
	text := rest[len(marker):]
	if strings.trim_space(text) == "" do return
	node.fields = make([dynamic]Field)
	if k > 0 do append(&node.fields, Field{strings.clone(line[:k]), false, false, "", "", ""})
	inject_comment(&node.fields, len(node.fields), marker, text)
	return node, true
}

// ---- Menus ----

// The statement menu's "Layout" group: Comment, Blank line (model.odin
// open_slot_menu). One group, so the menu stays short enough to keep its
// order. Not where only cases fit (between `switch x {` and its first case).
layout_extend_body_menu :: proc(app: ^App) {
	old := app.slot_menu
	statements := false
	for e in old do if e.label == "Declarations" do statements = true
	if !statements do return
	out := make([]Entry, len(old) + 1)
	copy(out, old)
	out[len(old)] = layout_group()
	delete(old)
	app.slot_menu = out
}

// The "Layout" group (statement menu and struct / enum / union / bit_field bodies).
layout_group :: proc() -> Entry {
	return Entry{label = "Layout", children = make_slice(
		Entry{label = "Comment", fill = COMMENT_FILL},
		Entry{label = "Blank line", fill = BLANK_FILL},
	)}
}

// File Setup > Comments / Blank line at file scope (model.odin menu_select).
// False for other inserts.
layout_add_insert :: proc(app: ^App, insert: string) -> bool {
	n: Node
	switch insert {
	case COMMENT_INSERT:
		inject_comment(&n.fields, 0, "// ", comment_placeholder(app))
	case BLANK_INSERT:
		append(&n.fields, Field{strings.clone(""), false, false, "", "", ""})
	case:
		return false
	}
	doc_insert(app, n)
	return true
}

// ---- Fills (model.odin menu_select, before the generic slot fills) ----

layout_fill :: proc(app: ^App, e: Entry) -> bool {
	switch e.fill {
	case ARG_ROW_FILL:
		arg_row_choose(app, e.call_name)
		return true
	case COMMENT_FILL, BLANK_FILL:
	case:
		return false
	}
	ni, fi := app.slot_ni, app.slot_fi
	if ni < 0 || ni >= len(app.doc.nodes) || fi < 0 || fi >= len(app.doc.nodes[ni].fields) || app.doc.nodes[ni].fields[fi].kind != "body" {
		return false
	}
	fields := &app.doc.nodes[ni].fields
	indent := strings.clone(line_indent(app.doc.nodes[ni]), context.temp_allocator)
	ordered_remove(fields, fi) // the body dot (its text is empty)
	if e.fill == COMMENT_FILL do inject_comment(fields, fi, "// ", comment_placeholder(app))
	// The next statement line, as every statement adds (dropped again when this
	// was inserted at a green dot: body_insert_done).
	next: Node
	append(&next.fields, Field{strings.clone(indent), false, false, "", "", ""})
	append(&next.fields, Field{"", false, true, "body", "", ""})
	inject_at(&app.doc.nodes, ni + 1, next)
	from_dot := app.body_insert_active
	body_insert_done(app)
	clear_nav(app)
	app.state = app.return_state
	if app.slot_menu != nil {
		free_entries(app.slot_menu)
		app.slot_menu = nil
	}
	if e.fill == COMMENT_FILL {
		focus_kth_selectable(app, ni, 0) // on the text: dictate it
	} else if !from_dot && ni + 1 < len(app.doc.nodes) && is_body_slot_line(app.doc.nodes[ni + 1]) {
		focus_kth_selectable(app, ni + 1, 0) // a blank line: on to the next statement
	} else {
		focus_dot_at(app, ni + 1)
		normalize_cursor(app)
	}
	return true
}

// ---- LT+B ----

// layout_delete: LT+B on a comment line (just that line, whatever its text
// holds), or on the green dot next to a blank line (that blank line).
layout_delete :: proc(app: ^App) -> bool {
	n := len(app.doc.nodes)
	if on_attr_dot(app) do return false // the purple dot isn't a green one (attr_dots.odin)
	if on_dot(app) {
		i := app.editor_line
		target := -1
		if i < n && is_blank_line(app.doc.nodes[i]) do target = i
		else if i > 0 && i - 1 < n && is_blank_line(app.doc.nodes[i - 1]) do target = i - 1
		if target < 0 do return false
		remove_line(app, target)
		focus_dot_at(app, target)
		normalize_cursor(app)
		return true
	}
	ni := app.editor_line
	if ni < 0 || ni >= n || !is_comment_line(app.doc.nodes[ni]) do return false
	remove_line(app, ni)
	app.editor_line = min(ni, len(app.doc.nodes))
	app.editor_field = 0
	normalize_cursor(app)
	return true
}

@(private = "file")
remove_line :: proc(app: ^App, ni: int) {
	for f in app.doc.nodes[ni].fields do if len(f.text) > 0 do delete(f.text)
	delete(app.doc.nodes[ni].fields)
	ordered_remove(&app.doc.nodes, ni)
}

// ---- Argument rows ----

// The call argument list on line n whose argument k holds field fi (a direct
// argument of the line's outermost call; not a literal's or a header's).
@(private = "file")
arg_row_target :: proc(n: Node, fi: int) -> (al: Arg_List, k: int, ok: bool) {
	if _, _, _, hdr := proc_header_parens(n); hdr do return
	al = find_arg_list(n) or_return
	if is_lit_open(n.fields[al.open]) || fi <= al.open || fi >= al.close do return
	for s in al.seps do if s < fi do k += 1
	return al, k, true
}

@(private = "file")
row_ends_after :: proc(n: Node, al: Arg_List, j: int) -> bool {
	return !has_arg_rows(n, al) || n.fields[al.seps[j]].hint == ARG_ROW_END
}

// arg_row_extend_menu: Y on an argument (a refill) of a call that's saved one
// argument per row: "Join with previous row" / "Own row" (model.odin open_slot_menu).
arg_row_extend_menu :: proc(app: ^App, ni, fi: int) {
	if !app.refill_active || app.refill_ni != ni || app.refill_fi != fi do return
	cur := app.doc.nodes[ni]
	// The line as it is (with the argument back in place of the refill dot).
	tmp: Node
	tmp.fields = make([dynamic]Field, 0, len(cur.fields) + len(app.refill_saved), context.temp_allocator)
	for f, i in cur.fields {
		if i == fi do append(&tmp.fields, ..app.refill_saved[:])
		else do append(&tmp.fields, f)
	}
	if !needs_break(tmp) do return
	if _, ok := call_rows(tmp); !ok do return
	al, k, ok := arg_row_target(tmp, fi)
	if !ok || len(al.seps) == 0 do return
	last := len(al.seps)
	extra := make([dynamic]Entry, 0, 2, context.temp_allocator)
	if k > 0 && row_ends_after(tmp, al, k - 1) {
		append(&extra, Entry{label = "Join with previous row", fill = ARG_ROW_FILL, call_name = strings.clone("join")})
	}
	alone := (k == 0 || row_ends_after(tmp, al, k - 1)) && (k == last || row_ends_after(tmp, al, k))
	if !alone do append(&extra, Entry{label = "Own row", fill = ARG_ROW_FILL, call_name = strings.clone("own")})
	if len(extra) == 0 do return
	old := app.slot_menu
	out := make([]Entry, len(old) + len(extra))
	copy(out, old)
	copy(out[len(old):], extra[:])
	delete(old)
	app.slot_menu = out
}

// The row choice was made: put the argument back, then mark its rows.
@(private = "file")
arg_row_choose :: proc(app: ^App, choice: string) {
	join := choice == "join" // (the menu and its strings are freed below)
	ni, fi := app.refill_ni, app.refill_fi
	refill_restore(app)
	clear_nav(app)
	app.state = .Editor
	if app.slot_menu != nil {
		free_entries(app.slot_menu)
		app.slot_menu = nil
	}
	if ni < 0 || ni >= len(app.doc.nodes) do return
	set_arg_row(&app.doc.nodes[ni], fi, join)
	focus_field_index(app, ni, fi)
}

// set_arg_row: argument (holding field fi) joins the previous argument's row,
// or gets a row of its own.
set_arg_row :: proc(n: ^Node, fi: int, join: bool) {
	al, k, ok := arg_row_target(n^, fi)
	if !ok || len(al.seps) == 0 do return
	if !has_arg_rows(n^, al) {
		// Start from one argument per row.
		for s in al.seps do n.fields[s].hint = ARG_ROW_END
		n.fields[al.open].hint = arg_rows_hint(len(al.seps) + 1)
	}
	if join {
		if k > 0 do n.fields[al.seps[k - 1]].hint = ""
	} else {
		if k > 0 do n.fields[al.seps[k - 1]].hint = ARG_ROW_END
		if k < len(al.seps) do n.fields[al.seps[k]].hint = ARG_ROW_END
	}
	// Every argument on its own row again: the default layout (no marks).
	all := true
	for s in al.seps do if n.fields[s].hint != ARG_ROW_END { all = false; break }
	if all {
		for s in al.seps do n.fields[s].hint = ""
		n.fields[al.open].hint = ""
	}
}

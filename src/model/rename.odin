package model

// Rename with propagation, like an IDE's "rename symbol": when you change the
// name a declaration introduces (dictation, typing, or the LT+A text tools), and
// that name is used elsewhere in its scope, a prompt asks
//     Rename brave_otter to window_title?
//       Rename all 3 uses   /   Only this one
// "Rename all" rewrites every use the declaration can see:
//   - file-scope declarations (constants, globals, procedures, types): the whole file
//   - parameters: their procedure
//   - loop / if / switch variables: that block
//   - other locals: from the declaration to the end of the block it's in
// A redeclaration of the same name in an inner block shadows it there, and those
// uses are left alone. Uses are whole words in code - not inside strings or
// comments, not after a "." (a field or package member), not a struct-literal
// field name. Labels already carry their break / continue along (label_refs.odin).
// Other files of the package are not changed.

import "core:fmt"
import "core:strings"

RENAME_FILL :: "__rename__"

Rename_Hit :: struct { ni, fi: int }

// Change a name and, when it's a declaration with uses in scope, ask whether to
// rename those too. Use this for user edits of names (not for internal updates).
rename_field :: proc(app: ^App, ni, fi: int, new_text: string) {
	if ni < 0 || ni >= len(app.doc.nodes) || fi < 0 || fi >= len(app.doc.nodes[ni].fields) do return
	old := strings.clone(app.doc.nodes[ni].fields[fi].text, context.temp_allocator)
	hits := rename_uses(app, ni, fi, old, new_text)
	set_field_text(app, ni, fi, new_text)
	if len(hits) == 0 do return
	rename_offer(app, ni, fi, old, new_text, hits)
}

// The uses that would follow a rename of field fi of line ni from `old` to
// `new_text` (empty when it isn't a declaration or nothing uses it). Temp-allocated.
rename_uses :: proc(app: ^App, ni, fi: int, old, new_text: string) -> []Rename_Hit {
	f := app.doc.nodes[ni].fields[fi]
	if !f.editable || f.slot || old == new_text || !is_ident(old) || !is_ident(new_text) do return nil
	switch f.kind {
	case "string", COMMENT_KIND, LIT_KEY_KIND, LABEL_KIND, "member": return nil
	}
	if !field_declares(app, ni, fi, old) do return nil
	lo, hi := rename_scope(app, ni, fi)
	out := make([dynamic]Rename_Hit, 0, 8, context.temp_allocator)
	skip := -1 // lines up to here are shadowed by an inner redeclaration
	for j in lo ..= hi {
		if j <= skip do continue
		if j != ni && line_redeclares(app, j, old) {
			// Shadowed from here to the end of that declaration's reach.
			if dfi := name_field(app.doc.nodes[j], old); dfi >= 0 {
				_, shi := rename_scope(app, j, dfi)
				skip = shi
				continue
			}
		}
		for g, k in app.doc.nodes[j].fields {
			if j == ni && k == fi do continue
			if g.slot do continue
			switch g.kind {
			case "string", COMMENT_KIND, LIT_KEY_KIND, LABEL_KIND: continue
			}
			if len(code_word_hits(g.text, old)) > 0 do append(&out, Rename_Hit{j, k})
		}
	}
	return out[:]
}

// Does field fi of line ni declare `name`? (Not a use of it.)
@(private = "file")
field_declares :: proc(app: ^App, ni, fi: int, name: string) -> bool {
	fs := app.doc.nodes[ni].fields
	t := strings.trim_space(strip_comment(node_text(app.doc.nodes[ni], context.temp_allocator)))
	// A procedure's parameter: the field sits inside the header's "( ... )".
	before := strings.builder_make(context.temp_allocator)
	for k in 0 ..< fi do strings.write_string(&before, fs[k].text)
	head := strings.to_string(before)
	if p := strings.index(head, "proc"); p >= 0 && strings.contains(head[p:], "(") && !strings.contains(head[p:], ")") {
		if s, params, ok := enclosing_proc(app, min(ni + 1, len(app.doc.nodes) - 1)); ok && s == ni {
			for prm in parse_params(params) do if prm.name == name do return true
		}
		return false
	}
	if _, found, _ := loop_header_declares(app, ni, name, true); found do return true
	if _, found := branch_declares(app, ni, ni + 1, name, 0); found do return true
	for kw in ([]string{"if ", "for ", "switch ", "when ", "case ", "return ", "defer ", "import ", "package ", "foreign "}) {
		if strings.has_prefix(t, kw) do return false
	}
	// Only a name left of the declaration operator declares it (`y := x`: x is a use).
	if strings.index_byte(head, ':') >= 0 || strings.index_byte(head, '=') >= 0 do return false
	_, found := decl_text_declares(app, ni, t, name, 0)
	return found
}

// Does line j declare `name` (any kind of declaration)?
@(private = "file")
line_redeclares :: proc(app: ^App, j: int, name: string) -> bool {
	k := name_field(app.doc.nodes[j], name)
	return k >= 0 && field_declares(app, j, k, name)
}

// The editable field of a line whose text is `name`, or -1.
@(private = "file")
name_field :: proc(n: Node, name: string) -> int {
	for f, k in n.fields do if f.editable && !f.slot && f.text == name do return k
	return -1
}

// The lines a declaration made by field fi of line ni can be seen from.
rename_scope :: proc(app: ^App, ni, fi: int) -> (lo, hi: int) {
	n := len(app.doc.nodes)
	fs := app.doc.nodes[ni].fields
	before := strings.builder_make(context.temp_allocator)
	for k in 0 ..< fi do strings.write_string(&before, fs[k].text)
	head := strings.to_string(before)
	is_param := false
	if p := strings.index(head, "proc"); p >= 0 && strings.contains(head[p:], "(") && !strings.contains(head[p:], ")") do is_param = true

	if insertion_points(app, context.temp_allocator)[ni] && !is_param do return 0, n - 1 // file scope
	if is_param || brace_delta(app, ni) > 0 {
		// A parameter, or a loop / if / switch header's own names: its block.
		s, e := construct_range(app, ni)
		return s, e
	}
	// A local: from here to the end of the enclosing block.
	depth := 0
	hi = n - 1
	for j in ni + 1 ..< n {
		if depth - leading_closes(app, j) < 0 { hi = j - 1; break }
		depth += brace_delta(app, j)
	}
	return ni, hi
}

// Byte offsets of `name` as a whole word in code: not in a string or comment,
// not after "." (a member), not a `name = ` key after "{" "(" or ",".
code_word_hits :: proc(s, name: string) -> []int {
	out := make([dynamic]int, 0, 2, context.temp_allocator)
	if name == "" || !strings.contains(s, name) do return out[:]
	quote: u8 = 0
	for k := 0; k < len(s); k += 1 {
		c := s[k]
		if quote != 0 {
			if c == '\\' && quote != '`' { k += 1; continue }
			if c == quote do quote = 0
			continue
		}
		if c == '"' || c == '\'' || c == '`' { quote = c; continue }
		if c == '/' && k + 1 < len(s) && s[k + 1] == '/' do break
		if !strings.has_prefix(s[k:], name) do continue
		if k > 0 && (rn_ident(s[k - 1]) || s[k - 1] == '.') do continue
		end := k + len(name)
		if end < len(s) && rn_ident(s[end]) do continue
		// `{name = ...}` / `f(name = ...)`: a field / argument name, not this variable.
		after := strings.trim_left_space(s[end:])
		prev := strings.trim_right_space(s[:k])
		if strings.has_prefix(after, "=") && !strings.has_prefix(after, "==") && len(prev) > 0 {
			if p := prev[len(prev) - 1]; p == '{' || p == '(' || p == ',' do continue
		}
		append(&out, k)
		k = end - 1
	}
	return out[:]
}

// Rewrite the whole-word uses of `old` in s.
@(private = "file")
replace_code_word :: proc(s, old, new_text: string) -> string {
	hits := code_word_hits(s, old)
	if len(hits) == 0 do return s
	b := strings.builder_make(context.temp_allocator)
	last := 0
	for h in hits {
		strings.write_string(&b, s[last:h])
		strings.write_string(&b, new_text)
		last = h + len(old)
	}
	strings.write_string(&b, s[last:])
	return strings.to_string(b)
}

// The prompt.
@(private = "file")
rename_offer :: proc(app: ^App, ni, fi: int, old, new_text: string, hits: []Rename_Hit) {
	rename_clear(app)
	app.rename_active = true
	app.rename_ni, app.rename_fi = ni, fi
	app.rename_old = strings.clone(old)
	app.rename_new = strings.clone(new_text)
	app.rename_hits = make([dynamic]Rename_Hit, 0, len(hits))
	append(&app.rename_hits, ..hits)
	uses := 0
	for h in hits do uses += len(code_word_hits(app.doc.nodes[h.ni].fields[h.fi].text, old))
	entries := make([dynamic]Entry, 0, 2)
	defer delete(entries)
	append(&entries, Entry{label = strings.clone(fmt.tprintf(uses == 1 ? "Rename the other use" : "Rename all %d uses", uses)), owned_label = true, fill = RENAME_FILL, call_name = strings.clone("all")})
	append(&entries, Entry{label = strings.clone("Only this one"), owned_label = true, fill = RENAME_FILL, call_name = strings.clone("one")})
	if app.slot_menu != nil do free_entries(app.slot_menu)
	app.slot_menu = make([]Entry, len(entries))
	copy(app.slot_menu, entries[:])
	clear_nav(app)
	app.return_state = .Editor
	app.state = .Radial
	push_menu(app, fmt.tprintf("Rename %s to %s?", old, new_text), app.slot_menu)
}

// The answer (menu_select): "all" rewrites the uses; anything else keeps them.
rename_choose :: proc(app: ^App, choice: string) {
	if choice == "all" do rename_apply(app)
	ni, fi := app.rename_ni, app.rename_fi
	rename_clear(app)
	clear_nav(app)
	app.state = .Editor
	if app.slot_menu != nil { free_entries(app.slot_menu); app.slot_menu = nil }
	if ni >= 0 && ni < len(app.doc.nodes) && fi < len(app.doc.nodes[ni].fields) do focus_field_index(app, ni, fi)
}

@(private = "file")
rename_apply :: proc(app: ^App) {
	for h in app.rename_hits {
		if h.ni >= len(app.doc.nodes) || h.fi >= len(app.doc.nodes[h.ni].fields) do continue
		t := app.doc.nodes[h.ni].fields[h.fi].text
		if nt := replace_code_word(t, app.rename_old, app.rename_new); nt != t do set_field_text(app, h.ni, h.fi, nt)
	}
}

// Forget a pending prompt (also on B: the new name stays, the uses don't change).
rename_clear :: proc(app: ^App) {
	app.rename_active = false
	if app.rename_old != "" do delete(app.rename_old)
	if app.rename_new != "" do delete(app.rename_new)
	app.rename_old, app.rename_new = "", ""
	delete(app.rename_hits)
	app.rename_hits = nil
}

@(private = "file")
rn_ident :: proc(c: u8) -> bool { return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') }

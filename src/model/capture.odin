package model

// Capture dots: a pink dot in front of a bare call statement whose procedure
// returns something (`len(name)`, `strings.clone(s)`, ...). A on it captures the
// result in a new variable:
//
//     ● len(name)    ->    brave_otter := len(name)
//
// with the cursor on the new (editable) name. The dot is a slot field of kind
// "capture" with no text, so it never shows up in the saved source. It is kept
// in sync with the document by sync_capture_dots (added when a call statement
// starts returning a value, removed when it stops being one).

import "core:strings"

CAPTURE_KIND :: "capture"

is_capture_dot :: proc(f: Field) -> bool { return f.slot && f.kind == CAPTURE_KIND }

// The capture dot's field index on line n, or -1.
capture_dot_index :: proc(n: Node) -> int {
	for f, i in n.fields do if is_capture_dot(f) do return i
	return -1
}

// wants_capture_dot: line ni is a bare call statement inside a block whose
// procedure is known to return a value.
wants_capture_dot :: proc(app: ^App, ni: int, inside: bool) -> bool {
	return inside && call_result_count(app, app.doc.nodes[ni]) > 0
}

// call_result_count: for a bare call statement (only indentation and an
// optional `pkg.` before the call, nothing after it), how many values its
// procedure returns: 0 = nothing / not a bare call / can't tell. A result list
// with `#optional_...` (strings.clone's allocator error) counts as one.
call_result_count :: proc(app: ^App, n: Node) -> int {
	al, ok := find_arg_list(n)
	if !ok || al.open == 0 || is_lit_open(n.fields[al.open]) do return 0 // a struct literal isn't a call
	for i in al.close + 1 ..< len(n.fields) {
		if n.fields[i].slot || strings.trim_space(n.fields[i].text) != "" do return 0
	}
	callee := n.fields[al.open - 1]
	if callee.slot do return 0
	name := strings.trim_space(callee.text)
	if !is_ident(name) do return 0
	// Before the callee: indentation, the capture dot, and at most `pkg.`.
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< al.open - 1 {
		f := n.fields[i]
		if is_capture_dot(f) do continue
		if f.slot do return 0
		strings.write_string(&b, f.text)
	}
	prefix := strings.trim_space(strings.to_string(b))
	if prefix != "" && !(strings.has_suffix(prefix, ".") && is_ident(prefix[:len(prefix) - 1])) do return 0
	pkg_ref := prefix != "" ? prefix[:len(prefix) - 1] : ""
	sig := call_signature(app, pkg_ref, name)
	if !sig.known || sig.ret == RET_NONE || sig.ret == RET_UNKNOWN do return 0
	return result_count(sig.ret)
}

// The number of values a return type text declares: `int` -> 1,
// `(int, bool)` / `(a, b: int)` -> 2, `(res: string, err: E) #optional_...` -> 1.
result_count :: proc(ret: string) -> int {
	r := strings.trim_space(ret)
	if !strings.has_prefix(r, "(") || strings.contains(r, "#optional") do return 1
	count, depth := 1, 0
	for c in transmute([]u8)r {
		switch c {
		case '(', '[', '{': depth += 1
		case ')', ']', '}':
			depth -= 1
			if depth == 0 do return count
		case ',':
			if depth == 1 do count += 1
		}
	}
	return count
}

// is_ident: a plain Odin identifier (ASCII letters, digits, _).
is_ident :: proc(s: string) -> bool {
	if s == "" do return false
	for c, i in transmute([]u8)s {
		alpha := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
		if !alpha && !(i > 0 && c >= '0' && c <= '9') do return false
	}
	return true
}

// A cheap fingerprint of the document, so the sync only runs after changes.
@(private = "file")
doc_fingerprint :: proc(app: ^App) -> u64 {
	h: u64 = 14695981039346656037
	mix :: #force_inline proc(h: ^u64, b: u8) { h^ = (h^ ~ u64(b)) * 1099511628211 }
	for n in app.doc.nodes {
		for f in n.fields {
			for c in transmute([]u8)f.text do mix(&h, c)
			mix(&h, f.slot ? 1 : 2)
		}
		mix(&h, 0)
	}
	return h
}

// sync_capture_dots adds / removes capture dots so exactly the lines that want
// one have one. Only while plainly editing (no menu or pick in progress: those
// remember field indexes). Keeps the cursor on the same leaf.
sync_capture_dots :: proc(app: ^App) {
	if app.state != .Editor || app.refill_active || app.change_call || app.ref_pick_active ||
	   app.ref_pass_active || app.decl_form_active || app.body_insert_active || app.replacing {
		return
	}
	fp := doc_fingerprint(app)
	if fp == app.capture_fp do return
	pts := insertion_points(app, context.temp_allocator) // false = inside a block
	changed := false
	for ni in 0 ..< len(app.doc.nodes) {
		has := capture_dot_index(app.doc.nodes[ni]) >= 0
		want := wants_capture_dot(app, ni, !pts[ni])
		if want == has do continue
		changed = true
		on_line := !on_dot(app) && app.editor_line == ni
		if want {
			add_capture_dot(&app.doc.nodes[ni])
			if on_line do app.editor_field += 1 // the dot is the new first leaf
		} else {
			ci := capture_dot_index(app.doc.nodes[ni])
			before := on_line && leaf_index_of(app.doc.nodes[ni], ci) < app.editor_field
			ordered_remove(&app.doc.nodes[ni].fields, ci)
			if before do app.editor_field -= 1
		}
	}
	if changed {
		clear(&app.tree_path) // field indexes moved: rebuild the RT tree
		clamp_field(app)
		fp = doc_fingerprint(app)
	}
	app.capture_fp = fp
}

// The capture dot goes right after the indentation (split off its own field
// when it shares one with the code, as in loaded lines: "\twindows.").
@(private = "file")
add_capture_dot :: proc(n: ^Node) {
	at := 0
	if len(n.fields) > 0 && !n.fields[0].slot {
		t := n.fields[0].text
		code := strings.trim_left_space(t)
		ws := len(t) - len(code)
		if ws > 0 && code != "" {
			n.fields[0].text = strings.clone(code)
			inject_at(&n.fields, 0, Field{strings.clone(t[:ws]), false, false, "", "", ""})
			delete(t)
		}
		if ws > 0 do at = 1
	}
	inject_at(&n.fields, at, Field{"", false, true, CAPTURE_KIND, "", ""})
}

@(private = "file")
leaf_index_of :: proc(n: Node, fi: int) -> int {
	for u, k in line_leaves(n) do if fi >= u.fa && fi < u.fb do return k
	return -1
}

// capture_call_result: A on a capture dot. `● len(s)` -> `brave_otter := len(s)`
// (`a, b := f()` for a proc with two results), the cursor on the first new name.
capture_call_result :: proc(app: ^App, ni, fi: int) {
	if fi < 0 || fi >= len(app.doc.nodes[ni].fields) || !is_capture_dot(app.doc.nodes[ni].fields[fi]) do return
	count := max(1, call_result_count(app, app.doc.nodes[ni]))
	fields := &app.doc.nodes[ni].fields
	ordered_remove(fields, fi)
	inject_at(fields, fi, Field{strings.clone(" := "), false, false, "decl", "", ""})
	for k := count - 1; k >= 0; k -= 1 {
		inject_at(fields, fi, Field{generate_ident(app), true, false, "", "", ""}) // owned: moves into the field
		if k > 0 do inject_at(fields, fi, Field{strings.clone(", "), false, false, "", "", ""})
	}
	focus_field_index(app, ni, fi)
	clear(&app.tree_path)
	app.capture_fp = 0 // re-check the document
}

// uncapture: LT+B (delete) on a name declared from a call - `n := len(s)`,
// `x: string = strings.clone(s)` - deletes just the declaration and leaves the
// bare call (whose capture dot comes back, with the cursor on it). With several
// names (`a, b := pair()`) the deleted one becomes `_`; when no real name is
// left, the declaration goes. False (nothing changed) for any other name.
uncapture :: proc(app: ^App, ni, fi: int) -> bool {
	if ni < 0 || ni >= len(app.doc.nodes) do return false
	fields := &app.doc.nodes[ni].fields
	if fi < 0 || fi >= len(fields) || !fields[fi].editable || fields[fi].kind != "" do return false
	d := -1 // the declaration operator (` := ` / `: `)
	for f, i in fields do if f.kind == "decl" { d = i; break }
	if d < 0 || fi > d do return false
	op := strings.trim_space(fields[d].text)
	if op != ":=" && op != ":" do return false

	// The value must be a bare call: [pkg.]name(...) and nothing after it.
	al, ok := find_arg_list(app.doc.nodes[ni])
	if !ok || is_lit_open(fields[al.open]) || al.open - 1 <= d do return false // `r := T{...}` isn't a call result
	c := al.open - 1
	for i in al.close + 1 ..< len(fields) {
		if fields[i].slot || strings.trim_space(fields[i].text) != "" do return false
	}
	b := strings.builder_make(context.temp_allocator)
	for i in d + 1 ..< c {
		if fields[i].slot do return false
		strings.write_string(&b, fields[i].text)
	}
	between := strings.to_string(b) // ":=" form: "" or "pkg."; typed: "string = pkg."
	if op == ":" {
		eq := strings.index_byte(between, '=')
		if eq < 0 do return false
		between = between[eq + 1:]
	}
	prefix := strings.trim_space(between)
	if prefix != "" && !(strings.has_suffix(prefix, ".") && is_ident(prefix[:len(prefix) - 1])) do return false

	// Names: the editable fields before the operator. Is another real one left?
	first := -1
	others := false
	for i in 0 ..< d {
		if !fields[i].editable do continue
		if first < 0 do first = i
		if i != fi && strings.trim_space(fields[i].text) != "_" do others = true
	}
	if others {
		delete(fields[fi].text)
		fields[fi].text = strings.clone("_")
		focus_field_index(app, ni, fi)
		return true
	}

	// Drop the declaration: fields [first, c), keeping `pkg.` in a field of its own.
	for i in first ..< c do if len(fields[i].text) > 0 do delete(fields[i].text)
	remove_range(fields, first, c)
	if prefix != "" do inject_at(fields, first, Field{strings.clone(prefix), false, false, "", "", ""})
	clear(&app.tree_path)
	app.capture_fp = 0
	focus_field_index(app, ni, first)
	sync_capture_dots(app) // the bare call gets its capture dot back...
	if ci := capture_dot_index(app.doc.nodes[ni]); ci >= 0 do focus_field_index(app, ni, ci) // ...and the cursor
	return true
}

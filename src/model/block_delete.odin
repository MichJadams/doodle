package model

// LT+B on a line holding braces: which lines go.
//
// At file scope it's the whole construct (construct_range), as before. Inside
// a body it's only the statement the line belongs to:
//   - a line that opens a block (`if x {`, `for ... {`, `y := T {` over
//     several lines): that line through the matching close;
//   - a line that starts by closing one (`}`, `} else {`): the statement whose
//     block it closes (the `if` and all its branches);
//   - a balanced line (`q := T{a = 1}`, `r = T{}`, `return T{}`, a one-line
//     `x :: struct { a: int }`): just that line.

import "core:strings"

// block_delete_range: the lines [s, e] LT+B deletes for line ln, or ok=false
// when it's a single line (delete just that node).
block_delete_range :: proc(app: ^App, ln: int) -> (s, e: int, ok: bool) {
	n := len(app.doc.nodes)
	if ln < 0 || ln >= n do return
	// dep[i] = brace depth before line i (as construct_range counts it).
	dep := make([]int, ln + 1, context.temp_allocator)
	for i in 0 ..< ln do dep[i + 1] = dep[i] + brace_delta(app, i)
	d := brace_delta(app, ln)
	t := strings.trim_left_space(node_text(app.doc.nodes[ln], context.temp_allocator))
	closes_first := strings.has_prefix(t, "}")

	if dep[ln] <= 0 {
		if d == 0 && !closes_first do return // a balanced top-level line: just it
		s, e = construct_range(app, ln)
		return s, e, true
	}
	switch {
	case closes_first:
		// The line whose block this leading `}` closes.
		target := dep[ln] - 1
		s = ln
		for j := ln - 1; j >= 0; j -= 1 {
			if dep[j] <= target { s = j; break }
		}
		if s == ln do return
	case d > 0:
		s = ln
	case:
		return // balanced: just this line
	}
	balance := 0
	e = s
	for j := s; j < n; j += 1 {
		balance += brace_delta(app, j)
		e = j
		if balance <= 0 do break
	}
	return s, e, true
}

// lit_fields_dot_delete (LT+B on a struct literal's green "fields" dot): an
// empty literal `T{●}` turns back into the value dot it was made from; with
// fields set, nothing happens (the dot only adds fields). False when the
// cursor isn't on a fields dot.
lit_fields_dot_delete :: proc(app: ^App) -> bool {
	ni, fi, ok := editor_target(app)
	if !ok do return false
	n := app.doc.nodes[ni]
	if !n.fields[fi].slot || n.fields[fi].kind != FIELDS_KIND do return false
	open := lit_open_around(n, fi)
	if open <= 0 do return true
	close := lit_close_of(n, open)
	if close != fi + 1 || open != fi - 1 do return true // fields are set: keep the literal
	// [type][{][●fields][}] -> one value dot.
	fields := &app.doc.nodes[ni].fields
	a := open - 1
	for i in a ..= close do if len(fields[i].text) > 0 do delete(fields[i].text)
	remove_range(fields, a, close + 1)
	inject_at(fields, a, Field{"", false, true, "value", "", ""})
	sync_typed_decl_value_hint(app, ni) // `x: T = ●` expects T again
	focus_field_index(app, ni, a)
	return true
}

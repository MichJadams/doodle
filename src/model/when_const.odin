package model

// A `when` condition must be a compile-time constant (Odin: "Expected a
// constant boolean condition in ternary when expression", and the same for a
// `when` statement). So, on a dot inside the condition of `a when c else b`
// or of a `when ● {` / `else when ● {` header - also on the operands of an
// operator built there (`● > ●`):
//   - the value menu dims calls;
//   - Reference > Pass as dims names that aren't constants (`n := 5`), and
//     fields / elements of values. `N :: 5`, ODIN_* built-ins, true / false,
//     and pkg.CONST stay (unroll_const_name in loop_unroll.odin).

import "core:strings"

// in_when_cond: is field fi of line ni inside a `when` condition?
in_when_cond :: proc(app: ^App, ni, fi: int) -> bool {
	if ni < 0 || ni >= len(app.doc.nodes) do return false
	n := app.doc.nodes[ni]
	if fi < 0 || fi >= len(n.fields) do return false
	// A `when` / `else when` statement header (when_cond.odin).
	if _, a, b, ok := when_cond_range(n); ok && fi >= a && fi < b do return true
	// A `when` ternary somewhere above fi.
	walk :: proc(n: Node, units: []Unit, fi: int) -> bool {
		for u in units {
			if fi < u.fa || fi >= u.fb do continue
			if u.kind == .Op && len(u.children) == 3 {
				c0 := u.children[0]
				if c0.fb < len(n.fields) {
					kw := n.fields[c0.fb]
					if !kw.slot && kw.kind == TERN_KIND && strings.trim_space(kw.text) == "when" {
						c1 := u.children[1]
						if fi >= c1.fa && fi < c1.fb do return true
					}
				}
			}
			if walk(n, u.children, fi) do return true
		}
		return false
	}
	return walk(n, line_units(n), fi)
}

// when_extend_value_menu (model.odin, after the type pass): on a dot in a
// `when` condition, calls are dimmed (their results aren't constants).
when_extend_value_menu :: proc(app: ^App, ni, fi: int) {
	if ni < 0 || ni >= len(app.doc.nodes) || fi < 0 || fi >= len(app.doc.nodes[ni].fields) do return
	f := app.doc.nodes[ni].fields[fi]
	if !f.slot || f.kind != "value" || !in_when_cond(app, ni, fi) do return
	when_dim_calls(app.slot_menu)
}

// Dim call fills; a group with nothing left is dimmed too.
@(private = "file")
when_dim_calls :: proc(entries: []Entry) -> (any_fit: bool) {
	for &e in entries {
		if len(e.children) > 0 {
			f := when_dim_calls(e.children)
			if !f do e.dim = true
			any_fit ||= f
			continue
		}
		if e.fill == "__call_import__" || e.fill == "__call_import_proc__" || e.fill == "__call_this_pkg__" do e.dim = true
		any_fit ||= !e.dim
	}
	return
}

// when_pass_as_dims (ref_pick.odin open_pass_as_menu): Reference on a dot in
// a `when` condition: only constants.
when_pass_as_dims :: proc(app: ^App, pick: Ref_Target, out: []Entry) {
	if !in_when_cond(app, app.ref_ni, app.ref_fi) do return
	for &e in out {
		if e.fill == REF_AS_FILL {
			if !unroll_const_expr(app, app.ref_ni, e.call_name) do e.dim = true
		} else {
			e.dim = true // a field / an element of a value
			for &c in e.children do c.dim = true
		}
	}
}

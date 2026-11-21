package model

// The condition of a `when` / `else when` header (ctrl.odin) is one part of
// the line: a D-pad stop (its operands below it), Y refills it with a bool dot
// (B puts it back), LT+B turns it back into the dot. LT+B on `when` itself
// still deletes the chain / branch.

import "core:strings"

// The condition [a, b) of a when / else when header, or ok=false.
when_cond_range :: proc(n: Node) -> (k, a, b: int, ok: bool) {
	k = when_kw_index(n)
	if k < 0 || n.fields[k].text == "else" do return
	last := len(n.fields) - 1
	if k + 2 > last || n.fields[k + 1].slot || n.fields[k + 1].text != " " || strings.trim_space(n.fields[last].text) != "{" do return
	return k, k + 2, last, true
}

// when_line_units (selection.odin line_units): the keyword, then the condition.
when_line_units :: proc(n: Node) -> ([]Unit, bool) {
	k, a, b, ok := when_cond_range(n)
	if !ok do return nil, false
	out := make([dynamic]Unit, 0, 4, context.temp_allocator)
	append(&out, Unit{fa = k, fb = k + 1, kind = .Field})
	append(&out, parse_expr_arg(n, a, b))
	return out[:], true
}

// when_cond_change (ctrl_change): Y on the whole condition refills it.
when_cond_change :: proc(app: ^App, ni: int, u: Unit) -> bool {
	n := app.doc.nodes[ni]
	k, a, b, ok := when_cond_range(n)
	if !ok || u.fa != a || u.fb != b do return false
	if b - a == 1 && n.fields[a].slot do return false // a dot: its menu (as A)
	reset_condition(app, ni, k)
	return true
}

// when_cond_delete (ctrl_delete): LT+B inside the condition: back to its dot.
when_cond_delete :: proc(app: ^App, ni, fi: int) -> bool {
	n := app.doc.nodes[ni]
	_, a, b, ok := when_cond_range(n)
	if !ok || fi < a || fi >= b do return false
	if b - a == 1 && n.fields[a].slot do return true
	fields := &app.doc.nodes[ni].fields
	for i in a ..< b do if len(fields[i].text) > 0 do delete(fields[i].text)
	remove_range(fields, a, b)
	inject_at(fields, a, Field{"", false, true, "value", "bool", ""})
	focus_field_index(app, ni, a)
	return true
}

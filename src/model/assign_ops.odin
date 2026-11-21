package model

// Which compound assignment operators a target's type can take (Odin rejects
// `%=` on a float, `|=` on a float, `+=` on a string variable, ...): Y on an
// assignment's operator dims the others, and so does picking the target of an
// operator statement (Assignment > `+=` ...) with Reference.

import "core:strings"

// assign_op_fits: can a target of category c take `op`? (Unknown / Any: anything.)
assign_op_fits :: proc(op: string, c: Type_Cat) -> bool {
	if c == .Unknown || c == .Any do return true
	switch op {
	case "=":
		return true
	case "%=", "%%=", "<<=", ">>=":
		return c == .Integer || c == .Rune
	case "|=", "&=", "~=", "&~=":
		return c == .Integer || c == .Rune || c == .Bool || c == .BitSet
	case "&&=", "||=":
		return c == .Bool
	case "+=", "-=":
		return c == .Integer || c == .Rune || c == .Float || c == .BitSet || c == .Array // arrays / matrices: element-wise
	case "*=", "/=":
		return c == .Integer || c == .Rune || c == .Float || c == .Array
	}
	return true
}

// The category of expression text `target` at line ni (Unknown when it can't tell).
assign_target_cat :: proc(app: ^App, ni: int, target: string) -> Type_Cat {
	t := strings.trim_space(target)
	if t == "" do return .Unknown
	vt, ok := expr_type_at(app, ni, t)
	if !ok || vt.expr == "" do return .Unknown
	ctx := type_ctx_make(app)
	return resolve_type(&ctx, vt.expr, vt.pkg).cat
}

// assign_target_dims (open_assign_target_menu): picking the target of `● op= ●`:
// names whose type can't take op are dimmed.
assign_target_dims :: proc(app: ^App, out: []Entry) {
	ni, fi := app.ref_ni, app.ref_fi
	if ni < 0 || ni >= len(app.doc.nodes) do return
	fs := app.doc.nodes[ni].fields
	if fi < 0 || fi + 1 >= len(fs) || fs[fi + 1].slot || fs[fi + 1].kind != ASSIGN_OP_KIND do return
	op := strings.trim_space(fs[fi + 1].text)
	if op == "=" do return
	for &e in out {
		if e.fill == REF_AS_FILL && !assign_op_fits(op, assign_target_cat(app, ni, e.call_name)) do e.dim = true
	}
}

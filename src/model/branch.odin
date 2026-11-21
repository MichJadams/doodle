package model

// Branching statements (the statement menu's "Branching" group):
//
//   if ● {                         If
//   } else if ● {                  (Y on `if` / a green dot after the block: Else if, Else)
//   } else {
//   }
//   if ⦿; ● {                      If with setup: `if v, ok := m["key"]; ok {`
//   switch ● {                     Switch: case clauses, `case 2, 3:`, `case 0..<10:`, `case:`
//   case ●:
//   }
//   switch {                       Switch (conditions): `case x > 0:`
//   #partial switch ● {            Partial switch (Y on `switch` toggles #partial)
//   switch v in ● {                Type switch: case dots list the union's variants
//   case ◆:
//   }
//
// Keywords are fields of kind BR_KW (selectable; Y / LT+B act on them):
//   if              Y: add else if / else, add / remove setup, change condition   LT+B: delete it all
//   else if / else  Y: add else if / else                                          LT+B: remove that branch
//   switch          Y: add case / default case, #partial, setup, change value     LT+B: delete it all
//   #partial        Y: as switch                                                   LT+B: remove #partial
//   case            Y: add value / case after / default case                      LT+B: delete that clause
// LT+B inside a setup removes the setup; on a case value (with others) removes that value.
// The green dot after an if chain offers "Else if" / "Else"; the dot (or "●" line)
// at the end of a case clause offers "Case" / "Default case"; the dot between
// `switch ... {` and the first case only offers those two.
//
// Names these introduce (setup names, the type switch variable) are known to
// var_types.odin with their types inside the construct only (branch_declares),
// and only pickable by "Reference" there (branch_name_hidden). Loading: branch_parse.odin.

import "core:fmt"
import "core:strings"

BR_KW        :: "brkw"    // Field.kind of if / else if / else / switch / #partial / case
SETUP_KIND   :: "setup"   // the dot of an if / switch setup statement
VARIANT_KIND :: "variant" // a type switch's case dot (a union variant)

// Fill markers (Entry.fill).
BR_IF_FILL          :: "__br_if__"
BR_IFELSE_FILL      :: "__br_ifelse__"
BR_IFSETUP_FILL     :: "__br_ifsetup__"
BR_SWITCH_FILL      :: "__br_switch__"
BR_SWITCH_BOOL_FILL :: "__br_switch_bool__"
BR_PARTIAL_FILL     :: "__br_partial__"
BR_TYPESWITCH_FILL  :: "__br_typeswitch__"
BR_ELSEIF_FILL      :: "__br_elseif__"  // at a dot after an if chain
BR_ELSE_FILL        :: "__br_else__"
BR_CASE_FILL        :: "__br_case__"    // at a dot in a switch body
BR_DEFAULT_FILL     :: "__br_default__"
BR_SETUP_FILL       :: "__br_setup__"   // call_name: decl / multi / assign
BR_VARIANT_FILL     :: "__br_variant__" // call_name: the type
BR_OPT_FILL         :: "__br_opt__"     // a Y option (call_name = its id); target = app.slot_ni / slot_fi

// The statement menu's Branching group.
branching_entries :: proc() -> []Entry {
	return make_slice(
		Entry{label = "If", fill = BR_IF_FILL},
		Entry{label = "If / Else", fill = BR_IFELSE_FILL},
		Entry{label = "If with setup", fill = BR_IFSETUP_FILL},
		Entry{label = "Switch", fill = BR_SWITCH_FILL},
		Entry{label = "Switch (conditions)", fill = BR_SWITCH_BOOL_FILL},
		Entry{label = "Partial switch", fill = BR_PARTIAL_FILL},
		Entry{label = "Type switch", fill = BR_TYPESWITCH_FILL},
		Entry{label = "When", fill = "__br_when__"},
	)
}

// ---- Fields ----

@(private = "file")
fx :: proc(text: string) -> Field { return Field{strings.clone(text), false, false, "", "", ""} }
@(private = "file")
kw :: proc(text: string) -> Field { return Field{strings.clone(text), false, false, BR_KW, "", ""} }
@(private = "file")
cond_dot :: proc() -> Field { return Field{"", false, true, "value", "bool", ""} }
@(private = "file")
value_dot :: proc(hint := "", pkg := "") -> Field { return Field{"", false, true, "value", hint, pkg} }
@(private = "file")
stmt_dot :: proc() -> Field { return Field{"", false, true, "body", "", ""} }

// A line: optional indentation, then `fs`.
@(private = "file")
make_line :: proc(indent: string, fs: ..Field) -> Node {
	n: Node
	if indent != "" do append(&n.fields, fx(indent))
	append(&n.fields, ..fs)
	return n
}

@(private = "file")
free_line :: proc(app: ^App, ni: int) {
	for f in app.doc.nodes[ni].fields do if len(f.text) > 0 do delete(f.text)
	delete(app.doc.nodes[ni].fields)
	ordered_remove(&app.doc.nodes, ni)
}

@(private = "file")
cut_fields :: proc(fields: ^[dynamic]Field, a, b: int) {
	for i in a ..< b do if len(fields[i].text) > 0 do delete(fields[i].text)
	remove_range(fields, a, b)
}

// The text of fields [a, b) (temp).
range_text :: proc(n: Node, a, b: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i in a ..< b do strings.write_string(&sb, n.fields[i].text)
	return strings.to_string(sb)
}

@(private = "file")
has_slot :: proc(n: Node, a, b: int) -> bool {
	for i in a ..< b do if n.fields[i].slot do return true
	return false
}

// Interned hint strings for a type (Field.hint is not owned).
br_hint :: proc(app: ^App, t: Var_Type) -> (string, string) {
	if t.expr == "" do return "", ""
	return intern_hint(app, t.expr), intern_hint(app, t.pkg)
}

// ---- Line structure ----

Br_Kind :: enum u8 { None, If, Else_If, Else, Switch, Case }

// The parts of an if / else if / else / switch header or a case label (field indexes).
Br_Line :: struct {
	kind:             Br_Kind,
	kw:               int, // the keyword field
	partial:          int, // `#partial`, or -1
	setup_a, setup_b: int, // the setup statement [a, b), b = its "; " field; a = -1 when none
	expr_a, expr_b:   int, // condition / switch value / a case's values [a, b); a = -1 when none
	tvar:             int, // a type switch's variable, or -1
	tvar_ref:         int, // the `&` before a by-reference type switch's variable, or -1
	open:             int, // the " {" field of a header, the ":" of a case label
	default_case:     bool,
}

@(private = "file")
is_trailing_comment :: proc(f: Field) -> bool {
	if f.slot || f.editable do return false
	t := strings.trim_space(f.text)
	return t == "" || strings.has_prefix(t, "//")
}

// br_line: the structure of a branching line (ok=false: not one, or not in the shape the menus build).
br_line :: proc(n: Node) -> (l: Br_Line, ok: bool) {
	k := -1
	for f, i in n.fields {
		if !f.slot && f.kind == BR_KW { k = i; break }
		if f.slot || f.editable do return
	}
	if k < 0 do return
	l = Br_Line{kw = k, partial = -1, setup_a = -1, setup_b = -1, expr_a = -1, expr_b = -1, tvar = -1, tvar_ref = -1, open = -1}
	fs := n.fields[:]
	txt := fs[k].text
	if txt == "#partial" {
		if k + 2 >= len(fs) || fs[k + 1].slot || fs[k + 1].text != " " || fs[k + 2].kind != BR_KW || fs[k + 2].text != "switch" do return
		l.partial = k
		k += 2
		l.kw = k
		txt = "switch"
	}
	switch txt {
	case "if":      l.kind = .If
	case "else if": l.kind = .Else_If
	case "else":    l.kind = .Else
	case "switch":  l.kind = .Switch
	case "case":    l.kind = .Case
	case:           return
	}
	if l.kind == .Case {
		colon := -1
		for i in k + 1 ..< len(fs) do if !fs[i].slot && !fs[i].editable && fs[i].text == ":" { colon = i; break }
		if colon < 0 do return
		l.open = colon
		if colon == k + 1 {
			l.default_case = true
		} else {
			if fs[k + 1].slot || fs[k + 1].text != " " || colon == k + 2 do return
			l.expr_a, l.expr_b = k + 2, colon
		}
		return l, true
	}
	open := -1
	for i := len(fs) - 1; i > k; i -= 1 {
		if !fs[i].slot && fs[i].text == " {" { open = i; break }
		if !is_trailing_comment(fs[i]) do return
	}
	if open < 0 do return
	l.open = open
	if l.kind == .Else do return l, open == k + 1
	if open == k + 1 do return l, l.kind == .Switch // `switch {`
	if fs[k + 1].slot || fs[k + 1].text != " " do return
	a := k + 2
	for i in a ..< open {
		f := fs[i]
		if !f.slot && !f.editable && f.text == "; " { l.setup_a, l.setup_b = a, i; a = i + 1; break }
	}
	if l.kind == .Switch && l.setup_a < 0 && a + 2 < open && !fs[a].slot && !fs[a].editable && fs[a].text == "&" && fs[a + 1].editable && !fs[a + 2].slot && fs[a + 2].text == " in " {
		l.tvar_ref = a // `switch &v in x {`
		a += 1
	}
	if l.kind == .Switch && l.setup_a < 0 && a + 1 < open && fs[a].editable && !fs[a + 1].slot && fs[a + 1].text == " in " {
		l.tvar = a
		a += 2
	}
	if a >= open do return
	l.expr_a, l.expr_b = a, open
	return l, true
}

br_line_at :: proc(app: ^App, ni: int) -> (Br_Line, bool) {
	if ni < 0 || ni >= len(app.doc.nodes) do return {}, false
	return br_line(app.doc.nodes[ni])
}

// A case label line (structured or not).
is_case_line :: proc(app: ^App, ni: int) -> bool {
	if ni < 0 || ni >= len(app.doc.nodes) do return false
	t := strings.trim_left_space(node_text(app.doc.nodes[ni], context.temp_allocator))
	return strings.has_prefix(t, "case ") || strings.has_prefix(t, "case:")
}

// The line closing the block line ni opens (ni when it opens none).
br_block_end :: proc(app: ^App, ni: int) -> int {
	if brace_delta(app, ni) <= 0 do return ni
	bal := 0
	for j in ni ..< len(app.doc.nodes) {
		bal += brace_delta(app, j)
		if bal <= 0 do return j
	}
	return len(app.doc.nodes) - 1
}

// The else if / else lines of the if chain headed by h, and the line closing it.
if_chain :: proc(app: ^App, h: int) -> (branches: []int, end: int) {
	out := make([dynamic]int, 0, 4, context.temp_allocator)
	bal := 0
	end = h
	for j in h ..< len(app.doc.nodes) {
		if j > h && bal == 1 {
			if l, ok := br_line_at(app, j); ok && (l.kind == .Else_If || l.kind == .Else) do append(&out, j)
		}
		bal += brace_delta(app, j)
		end = j
		if bal <= 0 do break
	}
	return out[:], end
}

// The `if` header of the chain whose branch line (or closing line) is b, or -1.
if_chain_header :: proc(app: ^App, b: int) -> int {
	cnt := 0
	for j := b - 1; j >= 0; j -= 1 {
		if cnt == 0 {
			if l, ok := br_line_at(app, j); ok && l.kind == .If do return j
		}
		cnt -= brace_delta(app, j)
		if cnt < 0 do return -1
	}
	return -1
}

@(private = "file")
chain_has_else :: proc(app: ^App, branches: []int) -> bool {
	if len(branches) == 0 do return false
	l, _ := br_line_at(app, branches[len(branches) - 1])
	return l.kind == .Else
}

// The case labels of the switch headed by s, and the line closing it.
switch_cases :: proc(app: ^App, s: int) -> (cases: []int, end: int) {
	out := make([dynamic]int, 0, 4, context.temp_allocator)
	bal := 0
	end = s
	for j in s ..< len(app.doc.nodes) {
		if j > s && bal == 1 && is_case_line(app, j) do append(&out, j)
		bal += brace_delta(app, j)
		end = j
		if bal <= 0 do break
	}
	return out[:], end
}

// The block around the position just after line `prev`: the line opening it
// (-1: none) and whether a case label sits between that line and the position.
@(private = "file")
enclosing_block :: proc(app: ^App, prev: int) -> (opener: int, saw_case: bool) {
	cnt := 0
	for j := min(prev, len(app.doc.nodes) - 1); j >= 0; j -= 1 {
		d := brace_delta(app, j)
		if cnt == 0 && d > 0 do return j, saw_case
		if cnt == 0 && is_case_line(app, j) do saw_case = true
		cnt -= d
	}
	return -1, saw_case
}

// The switch a case label c belongs to, or -1.
case_switch :: proc(app: ^App, c: int) -> int {
	o, _ := enclosing_block(app, c - 1)
	if l, ok := br_line_at(app, o); ok && l.kind == .Switch do return o
	return -1
}

Switch_Ctx :: struct {
	s:         int,  // the switch header
	in_clause: bool, // after a case label (else: between the header and the first case)
	at_end:    bool, // the next line is a case label or the switch's closing line
	final:     bool, // no case label after the position
}

// The switch body directly around the position between lines prev and next.
switch_ctx :: proc(app: ^App, prev, next: int) -> (c: Switch_Ctx, ok: bool) {
	o, saw := enclosing_block(app, prev)
	l, lok := br_line_at(app, o)
	if !lok || l.kind != .Switch do return
	end := br_block_end(app, o)
	c = Switch_Ctx{s = o, in_clause = saw, final = true}
	c.at_end = next >= end || is_case_line(app, next)
	cnt := 0
	for j in max(next, 0) ..< end {
		if cnt == 0 && is_case_line(app, j) { c.final = false; break }
		cnt += brace_delta(app, j)
		if cnt < 0 do break
	}
	return c, true
}

// The `if` chain the line `prev` closes, or -1.
@(private = "file")
chain_closed_by :: proc(app: ^App, prev: int) -> int {
	if prev < 0 || prev >= len(app.doc.nodes) do return -1
	if strings.trim_space(node_text(app.doc.nodes[prev], context.temp_allocator)) != "}" do return -1
	h := if_chain_header(app, prev)
	if h < 0 do return -1
	_, end := if_chain(app, h)
	return end == prev ? h : -1
}

// ---- Types for case dots ----

// switch_value_type: the type of the value switch s switches on.
switch_value_type :: proc(app: ^App, s: int) -> (Var_Type, bool) {
	l, ok := br_line_at(app, s)
	if !ok || l.kind != .Switch || l.expr_a < 0 do return {}, false
	n := app.doc.nodes[s]
	if has_slot(n, l.expr_a, l.expr_b) do return {}, false
	// Seen from the first line inside: a setup's names are known there.
	return expr_type_at(app, min(s + 1, len(app.doc.nodes) - 1), range_text(n, l.expr_a, l.expr_b))
}

// What a case value dot of switch s expects: the switched value's type, or bool (`switch {`).
switch_case_hint :: proc(app: ^App, s: int) -> (string, string) {
	l, ok := br_line_at(app, s)
	if !ok do return "", ""
	if l.expr_a < 0 do return "bool", ""
	t, tok := switch_value_type(app, s)
	if !tok do return "", ""
	return br_hint(app, t)
}

@(private = "file")
case_dot :: proc(app: ^App, s: int) -> Field {
	l, _ := br_line_at(app, s)
	if l.tvar >= 0 do return Field{"", false, true, VARIANT_KIND, "", ""}
	h, p := switch_case_hint(app, s)
	return value_dot(h, p)
}

// The values already used by the cases of switch s (except the one at line ni, fields [fa, fb)).
@(private = "file")
used_case_values :: proc(app: ^App, s, ni, fa, fb: int) -> map[string]bool {
	used := make(map[string]bool, 8, context.temp_allocator)
	cases, _ := switch_cases(app, s)
	for c in cases {
		l, ok := br_line_at(app, c)
		if !ok || l.expr_a < 0 do continue
		n := app.doc.nodes[c]
		for r in arg_ranges(n, l.expr_a, l.expr_b) {
			if c == ni && r[0] <= fa && fb <= r[1] do continue
			if has_slot(n, r[0], r[1]) do continue
			used[strings.trim_space(range_text(n, r[0], r[1]))] = true
		}
	}
	return used
}

// ---- Inserting (the statement menu) ----

// branch_make: the if / switch statement `kind` replaces the statement dot at
// (ni, fi); a new statement line follows it (dropped again at a green dot).
branch_make :: proc(app: ^App, ni, fi: int, kind: string) {
	indent := strings.clone(line_indent(app.doc.nodes[ni]), context.temp_allocator) // the header's own
	inner := strings.concatenate({indent, indent_unit(indent)}, context.temp_allocator)
	fields := &app.doc.nodes[ni].fields
	if len(fields[fi].text) > 0 do delete(fields[fi].text)
	ordered_remove(fields, fi)
	lines := make([dynamic]Node, 0, 6, context.temp_allocator)
	switch kind {
	case BR_IFSETUP_FILL:
		inject_at(fields, fi, kw("if"), fx(" "), Field{"", false, true, SETUP_KIND, "", ""}, fx("; "), cond_dot(), fx(" {"))
		append(&lines, make_line(inner, stmt_dot()))
	case BR_IFELSE_FILL:
		inject_at(fields, fi, kw("if"), fx(" "), cond_dot(), fx(" {"))
		append(&lines, make_line(inner, stmt_dot()))
		append(&lines, make_line("", fx(strings.concatenate({indent, "} "}, context.temp_allocator)), kw("else"), fx(" {")))
		append(&lines, make_line(inner, stmt_dot()))
	case BR_SWITCH_FILL, BR_PARTIAL_FILL:
		if kind == BR_PARTIAL_FILL {
			inject_at(fields, fi, kw("#partial"), fx(" "), kw("switch"), fx(" "), value_dot(), fx(" {"))
		} else {
			inject_at(fields, fi, kw("switch"), fx(" "), value_dot(), fx(" {"))
		}
		append(&lines, make_line(indent, kw("case"), fx(" "), value_dot(), fx(":")))
		append(&lines, make_line(inner, stmt_dot()))
	case BR_SWITCH_BOOL_FILL:
		inject_at(fields, fi, kw("switch"), fx(" {"))
		append(&lines, make_line(indent, kw("case"), fx(" "), cond_dot(), fx(":")))
		append(&lines, make_line(inner, stmt_dot()))
	case BR_TYPESWITCH_FILL:
		name := generate_ident(app)
		inject_at(fields, fi, kw("switch"), fx(" "), Field{name, true, false, "", "", ""}, fx(" in "), value_dot(), fx(" {"))
		append(&lines, make_line(indent, kw("case"), fx(" "), Field{"", false, true, VARIANT_KIND, "", ""}, fx(":")))
		append(&lines, make_line(inner, stmt_dot()))
	case: // BR_IF_FILL
		inject_at(fields, fi, kw("if"), fx(" "), cond_dot(), fx(" {"))
		append(&lines, make_line(inner, stmt_dot()))
	}
	append(&lines, make_line("", fx(strings.concatenate({indent, "}"}, context.temp_allocator))))
	append(&lines, make_line(indent, stmt_dot())) // the next statement
	inject_at(&app.doc.nodes, ni + 1, ..lines[:])
}

@(private = "file")
is_statement_fill :: proc(fill: string) -> bool {
	switch fill {
	case BR_IF_FILL, BR_IFELSE_FILL, BR_IFSETUP_FILL, BR_SWITCH_FILL, BR_SWITCH_BOOL_FILL, BR_PARTIAL_FILL, BR_TYPESWITCH_FILL:
		return true
	}
	return false
}

// The cursor on the first unfilled dot (not a statement dot) of line ni, else of the next line.
@(private = "file")
focus_first_dot :: proc(app: ^App, ni: int) {
	for k in ni ..< min(ni + 2, len(app.doc.nodes)) {
		for f, i in app.doc.nodes[k].fields do if f.slot && f.kind != "body" { focus_field_index(app, k, i); return }
	}
	focus_field_index(app, ni, 0)
}

// The temporary statement line of a green dot (body_dots.odin) is used up by a
// fill that doesn't keep it: forget it (the caller removes or replaces the line).
@(private = "file")
end_body_insert :: proc(app: ^App) {
	if !app.body_insert_active do return
	app.body_insert_active = false
	if app.body_insert_reused {
		delete(app.body_insert_blank)
		app.body_insert_blank = ""
		app.body_insert_reused = false
	}
}

// Add `} else if ● {` (or `} else {`) with a statement line before line `at` of the chain headed by h.
@(private = "file")
insert_branch :: proc(app: ^App, h, at: int, with_cond: bool) {
	ind := strings.clone(line_indent(app.doc.nodes[h]), context.temp_allocator)
	inner := strings.concatenate({ind, indent_unit(ind)}, context.temp_allocator)
	head := fx(strings.concatenate({ind, "} "}, context.temp_allocator))
	line: Node
	if with_cond {
		line = make_line("", head, kw("else if"), fx(" "), cond_dot(), fx(" {"))
	} else {
		line = make_line("", head, kw("else"), fx(" {"))
	}
	inject_at(&app.doc.nodes, at, line, make_line(inner, stmt_dot()))
	if with_cond do focus_field_index(app, at, 3)
	else do focus_field_index(app, at + 1, len(app.doc.nodes[at + 1].fields) - 1)
}

// Else if / Else from the statement menu at line L (just after the chain's closing line).
@(private = "file")
add_branch_after_chain :: proc(app: ^App, L: int, with_cond: bool) {
	h := chain_closed_by(app, L - 1)
	if h < 0 do return
	branches, end := if_chain(app, h)
	has_else := chain_has_else(app, branches)
	if !with_cond && has_else do return
	if app.body_insert_active && app.body_insert_ni == L {
		end_body_insert(app)
		free_line(app, L)
	}
	at := end
	if with_cond && has_else do at = branches[len(branches) - 1]
	insert_branch(app, h, at, with_cond)
}

// Add a case clause (`case ●:` + a statement line) to switch s before line `at`.
// Returns the case line.
@(private = "file")
insert_case :: proc(app: ^App, s, at: int, is_default: bool) -> int {
	ind := strings.clone(line_indent(app.doc.nodes[s]), context.temp_allocator)
	inner := strings.concatenate({ind, indent_unit(ind)}, context.temp_allocator)
	line: Node
	if is_default {
		line = make_line(ind, kw("case"), fx(":"))
	} else {
		line = make_line(ind, kw("case"), fx(" "), case_dot(app, s), fx(":"))
	}
	inject_at(&app.doc.nodes, at, line, make_line(inner, stmt_dot()))
	if is_default {
		focus_field_index(app, at + 1, len(app.doc.nodes[at + 1].fields) - 1)
	} else {
		focus_first_dot(app, at)
	}
	return at
}

@(private = "file")
has_default_case :: proc(app: ^App, s: int) -> bool {
	cases, _ := switch_cases(app, s)
	for c in cases do if l, ok := br_line_at(app, c); ok && l.default_case do return true
	return false
}

// Case / Default case from the statement menu at line L (in a switch body).
@(private = "file")
add_case_at :: proc(app: ^App, L: int, is_default: bool) {
	c, ok := switch_ctx(app, L - 1, L + 1)
	if !ok do return
	if is_default && has_default_case(app, c.s) do return
	temp := app.body_insert_active && app.body_insert_ni == L
	at := L + 1
	if temp || !c.in_clause {
		// The line becomes the case (a "●" line before the first case can't stay there).
		if temp do end_body_insert(app)
		if is_body_slot_line(app.doc.nodes[L]) || temp {
			free_line(app, L)
			at = L
		}
	}
	insert_case(app, c.s, at, is_default)
}

// ---- The statement menu ----

@(private = "file")
prepend_entries :: proc(app: ^App, extra: []Entry) {
	if len(extra) == 0 do return
	old := app.slot_menu
	out := make([]Entry, len(old) + len(extra))
	copy(out, extra)
	copy(out[len(extra):], old)
	delete(old)
	app.slot_menu = out
}

// branch_extend_body_menu: the statement menu for the statement line L gets
// "Else if" / "Else" after an if chain, "Case" / "Default case" at the end of a
// case clause (only those two before the first case), and "Fallthrough" only
// at the end of a case clause that isn't the last, and never in a type switch.
branch_extend_body_menu :: proc(app: ^App, L: int) {
	extra := make([dynamic]Entry, 0, 4, context.temp_allocator)
	if h := chain_closed_by(app, L - 1); h >= 0 {
		branches, _ := if_chain(app, h)
		append(&extra, Entry{label = "Else if", fill = BR_ELSEIF_FILL})
		if !chain_has_else(app, branches) do append(&extra, Entry{label = "Else", fill = BR_ELSE_FILL})
	}
	c, in_switch := switch_ctx(app, L - 1, L + 1)
	type_switch := false
	if in_switch {
		if sl, ok := br_line_at(app, c.s); ok && sl.tvar >= 0 do type_switch = true
	}
	if in_switch && !c.in_clause {
		free_entries(app.slot_menu)
		app.slot_menu = nil
		cases := make([dynamic]Entry, 0, 2, context.temp_allocator)
		append(&cases, Entry{label = "Case", fill = BR_CASE_FILL})
		if !has_default_case(app, c.s) do append(&cases, Entry{label = "Default case", fill = BR_DEFAULT_FILL})
		app.slot_menu = make([]Entry, len(cases))
		copy(app.slot_menu, cases[:])
		return
	}
	if in_switch && c.at_end {
		append(&extra, Entry{label = "Case", fill = BR_CASE_FILL})
		if !has_default_case(app, c.s) do append(&extra, Entry{label = "Default case", fill = BR_DEFAULT_FILL})
	}
	if !(in_switch && c.in_clause && c.at_end && !c.final && !type_switch) {
		for &g in app.slot_menu {
			keep := make([dynamic]Entry, 0, len(g.children), context.temp_allocator)
			found := false
			for e in g.children {
				if e.fill == "__jmp_fallthrough__" { found = true; continue }
				append(&keep, e)
			}
			if !found do continue
			kids := make([]Entry, len(keep))
			copy(kids, keep[:])
			delete(g.children)
			g.children = kids
		}
	}
	prepend_entries(app, extra[:])
}

// ---- Fill menus of the new dots ----

// The variants of union type t declared in this document (`Shape :: union { Circle, Square }`),
// or in another file of the package.
union_variants :: proc(app: ^App, t: Var_Type) -> []string {
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	name := strings.trim_space(t.expr)
	if t.pkg != "" || !is_ident(name) do return out[:]
	for n, ni in app.doc.nodes {
		txt := strings.trim_space(node_text(n, context.temp_allocator))
		if !strings.has_prefix(txt, name) do continue
		rest := strings.trim_left_space(txt[len(name):])
		if !strings.has_prefix(rest, "::") do continue
		rest = strings.trim_left_space(rest[2:])
		if !strings.has_prefix(rest, "union") do continue
		sb := strings.builder_make(context.temp_allocator)
		depth := 0
		done := false
		for j in ni ..< len(app.doc.nodes) {
			line := node_text(app.doc.nodes[j], context.temp_allocator)
			if c := strings.index(line, "//"); c >= 0 do line = line[:c]
			for k in 0 ..< len(line) {
				ch := line[k]
				if ch == '{' { depth += 1; if depth == 1 do continue }
				if ch == '}' { depth -= 1; if depth == 0 { done = true; break } }
				if depth >= 1 do strings.write_byte(&sb, ch)
			}
			if done do break
			if depth >= 1 do strings.write_byte(&sb, ',')
		}
		for item in split_top_level(strings.to_string(sb)) {
			v := strings.trim_space(item)
			if v != "" do append(&out, v)
		}
		return out[:]
	}
	// Not in the document: a union of another file of the package (siblings.odin).
	if st, ok := visible_sibling_type(app, name); ok && st.kind == "union" {
		for v in brace_items(st.text) {
			// `strings.Builder` there: this file's reference to that package, when it imports it.
			here := sibling_type_here(app, v, st.file)
			append(&out, here.pkg == "" ? here.expr : v)
		}
	}
	return out[:]
}

// branch_slot_menu: the menus of a setup dot and of a type switch's case dot.
branch_slot_menu :: proc(app: ^App, ni, fi: int) -> ([]Entry, bool) {
	f := app.doc.nodes[ni].fields[fi]
	if !f.slot do return nil, false
	switch f.kind {
	case SETUP_KIND:
		return make_slice(
			Entry{label = "Variable (:=)", fill = BR_SETUP_FILL, call_name = strings.clone("decl")},
			Entry{label = "Two names (:=)", fill = BR_SETUP_FILL, call_name = strings.clone("multi")},
			Entry{label = "Assignment", fill = BR_SETUP_FILL, call_name = strings.clone("assign")},
			Entry{label = strings.clone("Call"), owned_label = true, children = build_call_children(app)},
		), true
	case VARIANT_KIND:
		out := make([dynamic]Entry, 0, 8)
		defer delete(out)
		s := case_switch(app, ni)
		used := make(map[string]bool, 1, context.temp_allocator)
		if s >= 0 {
			used = used_case_values(app, s, ni, fi, fi + 1)
			l, _ := br_line_at(app, s)
			n := app.doc.nodes[s]
			if l.expr_a >= 0 && !has_slot(n, l.expr_a, l.expr_b) {
				ut, _ := expr_type_at(app, s, range_text(n, l.expr_a, l.expr_b))
				for v in union_variants(app, ut) {
					append(&out, Entry{label = strings.clone(v), owned_label = true, fill = BR_VARIANT_FILL, call_name = strings.clone(v), dim = v in used})
				}
			}
		}
		append(&out, Entry{label = strings.clone("nil"), owned_label = true, fill = BR_VARIANT_FILL, call_name = strings.clone("nil"), dim = "nil" in used})
		append(&out, Entry{label = "Type", children = build_type_entries(app)})
		menu := make([]Entry, len(out))
		copy(menu, out[:])
		return menu, true
	}
	return nil, false
}

// branch_prepare_slot (before a dot's menu is built): a case value dot expects
// the switched value's type (it may have been filled since the dot was made).
branch_prepare_slot :: proc(app: ^App, ni, fi: int) {
	n := app.doc.nodes[ni]
	f := &app.doc.nodes[ni].fields[fi]
	if !f.slot || f.kind != "value" do return
	l, ok := br_line(n)
	if !ok || l.kind != .Case || l.expr_a < 0 || fi < l.expr_a || fi >= l.expr_b do return
	whole := false
	for r in arg_ranges(n, l.expr_a, l.expr_b) {
		if r[0] == fi && r[1] == fi + 1 do whole = true
		if fi >= r[0] && fi < r[1] && r[1] - r[0] == 3 && is_range_op(n.fields[r[0] + 1]) do whole = true // a range's ends
	}
	if !whole do return
	s := case_switch(app, ni)
	if s < 0 do return
	f.hint, f.hint_pkg = switch_case_hint(app, s)
}

// branch_sync (per input, while editing): the empty case value dots of each
// switch expect the switched value's current type (it may have been filled or
// changed since they were made).
branch_sync :: proc(app: ^App) {
	if app.state != .Editor || app.refill_active || app.ref_pick_active do return
	for ni in 0 ..< len(app.doc.nodes) {
		n := app.doc.nodes[ni]
		has_dot := false
		for f in n.fields do if f.slot && f.kind == "value" { has_dot = true; break }
		if !has_dot do continue
		l, ok := br_line(n)
		if !ok || l.kind != .Case || l.expr_a < 0 do continue
		for fi in l.expr_a ..< l.expr_b do if n.fields[fi].slot && n.fields[fi].kind == "value" do branch_prepare_slot(app, ni, fi)
	}
}

// Dim every leaf whose value is already used by another case.
@(private = "file")
dim_used :: proc(entries: []Entry, used: map[string]bool) {
	for &e in entries {
		if len(e.children) > 0 {
			dim_used(e.children, used)
			continue
		}
		v := ""
		switch e.fill {
		case ENUM_VALUE_FILL, BUILTIN_CONST_FILL: v = e.call_name
		case CONST_IMPORT_FILL:                   v = fmt.tprintf("%s.%s", e.call_pkg, e.call_name)
		case:                                     continue
		}
		if v in used do e.dim = true
	}
}

// branch_adjust_menu (after the gray-out pass): a case value dot's menu gets
// "Range" (lo ..< hi, lo ..= hi) and grays the values other cases already use.
branch_adjust_menu :: proc(app: ^App, ni, fi: int) {
	n := app.doc.nodes[ni]
	f := n.fields[fi]
	if !f.slot || f.kind != "value" do return
	l, ok := br_line(n)
	if !ok || l.kind != .Case || l.expr_a < 0 || fi < l.expr_a || fi >= l.expr_b do return
	s := case_switch(app, ni)
	if s < 0 do return
	if sl, _ := br_line_at(app, s); sl.expr_a < 0 do return // `switch {`: conditions
	used := used_case_values(app, s, ni, fi, fi + 1)
	dim_used(app.slot_menu, used)
	ctx := type_ctx_make(app)
	insert_range_entry(app, slot_expected_type(&ctx, f)) // range_fill.odin
}

// ---- Y: the options menus ----

@(private = "file")
option :: proc(out: ^[dynamic]Entry, label, id: string, dim := false) {
	append(out, Entry{label = strings.clone(label), owned_label = true, fill = BR_OPT_FILL, call_name = strings.clone(id), dim = dim})
}

@(private = "file")
open_options :: proc(app: ^App, ni, fi: int) -> bool {
	l, ok := br_line_at(app, ni)
	if !ok do return false
	out := make([dynamic]Entry, 0, 8)
	defer delete(out)
	title := ""
	switch l.kind {
	case .None:
		return false
	case .If, .Else_If, .Else:
		h := l.kind == .If ? ni : if_chain_header(app, ni)
		if h < 0 do return false
		branches, _ := if_chain(app, h)
		title = l.kind == .If ? "If" : (l.kind == .Else ? "Else" : "Else if")
		option(&out, "Add else if", "elseif")
		if l.kind != .Else do option(&out, "Add else", "else", chain_has_else(app, branches))
		if l.kind == .If || l.kind == .Else_If {
			if l.setup_a >= 0 do option(&out, "Remove setup", "nosetup")
			else do option(&out, "Add setup", "setup")
		}
		if l.kind != .Else do option(&out, "Change condition", "cond")
	case .Switch:
		title = "Switch"
		option(&out, "Add case", "case")
		option(&out, "Add default case", "default", has_default_case(app, ni))
		if l.partial >= 0 do option(&out, "Remove #partial", "nopartial")
		else do option(&out, "Make #partial", "partial")
		if l.tvar >= 0 {
			if l.tvar_ref >= 0 do option(&out, "By value", "noref")
			else do option(&out, "By reference", "ref")
		}
		if l.tvar < 0 && l.expr_a >= 0 {
			if l.setup_a >= 0 do option(&out, "Remove setup", "nosetup")
			else do option(&out, "Add setup", "setup")
			option(&out, "Change value", "cond")
		}
	case .Case:
		title = "Case"
		s := case_switch(app, ni)
		if s < 0 do return false
		if !l.default_case do option(&out, "Add value", "value")
		option(&out, "Add case after", "case_after")
		option(&out, "Add default case", "default", has_default_case(app, s))
	}
	if app.slot_menu != nil do free_entries(app.slot_menu)
	app.slot_menu = make([]Entry, len(out))
	copy(app.slot_menu, out[:])
	app.slot_ni, app.slot_fi = ni, fi
	clear_nav(app)
	app.return_state = .Editor
	app.state = .Radial
	push_menu(app, title, app.slot_menu)
	return true
}

// Turn fields [fa, fb) of line ni back into `dot` and open its menu; B puts them back.
@(private = "file")
refill :: proc(app: ^App, ni, fa, fb: int, dot: Field) {
	refill_discard(app)
	fields := &app.doc.nodes[ni].fields
	for i in fa ..< fb do append(&app.refill_saved, fields[i]) // ownership moves to refill_saved
	remove_range(fields, fa, fb)
	inject_at(fields, fa, dot)
	app.refill_active = true
	app.refill_ni = ni
	app.refill_fi = fa
	focus_field_index(app, ni, fa)
	open_slot_menu(app)
	if app.state != .Radial do refill_restore(app)
}

// The dot a header's condition / value turns back into.
@(private = "file")
expr_dot :: proc(l: Br_Line) -> Field {
	if l.kind == .Switch do return value_dot()
	return cond_dot()
}

@(private = "file")
apply_option :: proc(app: ^App, ni, fi: int, id: string) {
	l, ok := br_line_at(app, ni)
	if !ok do return
	switch l.kind {
	case .None:
	case .If, .Else_If, .Else:
		h := l.kind == .If ? ni : if_chain_header(app, ni)
		if h < 0 do return
		branches, end := if_chain(app, h)
		switch id {
		case "elseif":
			at := end
			if l.kind == .Else {
				at = ni
			} else {
				for b in branches do if b > ni { at = b; break }
			}
			insert_branch(app, h, at, true)
		case "else":
			if !chain_has_else(app, branches) do insert_branch(app, h, end, false)
		case "setup":   add_setup(app, ni, l)
		case "nosetup": remove_setup(app, ni, l)
		case "cond":    if l.expr_a >= 0 do refill(app, ni, l.expr_a, l.expr_b, expr_dot(l))
		}
	case .Switch:
		cases, end := switch_cases(app, ni)
		switch id {
		case "case":
			at := end
			if len(cases) > 0 {
				if ll, _ := br_line_at(app, cases[len(cases) - 1]); ll.default_case do at = cases[len(cases) - 1]
			}
			insert_case(app, ni, at, false)
		case "default":
			if !has_default_case(app, ni) do insert_case(app, ni, end, true)
		case "partial":
			if l.partial < 0 {
				inject_at(&app.doc.nodes[ni].fields, l.kw, kw("#partial"), fx(" "))
				focus_field_index(app, ni, l.kw + 2)
			}
		case "nopartial":
			if l.partial >= 0 {
				cut_fields(&app.doc.nodes[ni].fields, l.partial, l.partial + 2)
				focus_field_index(app, ni, l.partial)
			}
		case "ref": // `switch &v in x {`
			if l.tvar >= 0 && l.tvar_ref < 0 {
				inject_at(&app.doc.nodes[ni].fields, l.tvar, fx("&"))
				focus_field_index(app, ni, l.tvar + 1)
			}
		case "noref":
			if l.tvar_ref >= 0 {
				cut_fields(&app.doc.nodes[ni].fields, l.tvar_ref, l.tvar_ref + 1)
				focus_field_index(app, ni, l.tvar_ref)
			}
		case "setup":   add_setup(app, ni, l)
		case "nosetup": remove_setup(app, ni, l)
		case "cond":    if l.expr_a >= 0 do refill(app, ni, l.expr_a, l.expr_b, expr_dot(l))
		}
	case .Case:
		s := case_switch(app, ni)
		if s < 0 do return
		cases, end := switch_cases(app, s)
		switch id {
		case "value":
			if l.default_case do return
			inject_at(&app.doc.nodes[ni].fields, l.open, fx(", "), case_dot(app, s))
			focus_field_index(app, ni, l.open + 1)
			open_slot_menu(app)
		case "case_after":
			at := end
			for c in cases do if c > ni { at = c; break }
			insert_case(app, s, at, false)
		case "default":
			if !has_default_case(app, s) do insert_case(app, s, end, true)
		}
	}
}

@(private = "file")
add_setup :: proc(app: ^App, ni: int, l: Br_Line) {
	if l.setup_a >= 0 || l.expr_a < 0 || l.tvar >= 0 do return
	inject_at(&app.doc.nodes[ni].fields, l.expr_a, Field{"", false, true, SETUP_KIND, "", ""}, fx("; "))
	focus_field_index(app, ni, l.expr_a)
	open_slot_menu(app)
}

@(private = "file")
remove_setup :: proc(app: ^App, ni: int, l: Br_Line) {
	if l.setup_a < 0 do return
	cut_fields(&app.doc.nodes[ni].fields, l.setup_a, l.setup_b + 1)
	focus_field_index(app, ni, l.kw)
}

// A setup dot's fill: `name := ●`, `name, ok := ●`, `name = ●`.
@(private = "file")
fill_setup :: proc(app: ^App, ni, fi: int, form: string) {
	fields := &app.doc.nodes[ni].fields
	if fi < 0 || fi >= len(fields) || !fields[fi].slot || fields[fi].kind != SETUP_KIND do return
	ordered_remove(fields, fi)
	name := generate_ident(app) // owned by the field
	switch form {
	case "multi":
		inject_at(fields, fi, Field{name, true, false, "", "", ""}, fx(", "), Field{strings.clone("ok"), true, false, "", "", ""}, fx(" := "), value_dot())
		focus_field_index(app, ni, fi + 4)
	case "assign":
		inject_at(fields, fi, Field{name, true, false, "", "", ""}, fx(" = "), value_dot())
		focus_field_index(app, ni, fi + 2)
	case:
		inject_at(fields, fi, Field{name, true, false, "", "", ""}, fx(" := "), value_dot())
		focus_field_index(app, ni, fi + 2)
	}
}

// branch_fill: a menu choice owned by this file (statement inserts, else / case
// at a dot, setup / variant fills, Y options). False when it isn't one.
branch_fill :: proc(app: ^App, e: Entry) -> bool {
	switch e.fill {
	case BR_IF_FILL, BR_IFELSE_FILL, BR_IFSETUP_FILL, BR_SWITCH_FILL, BR_SWITCH_BOOL_FILL, BR_PARTIAL_FILL, BR_TYPESWITCH_FILL,
	     BR_ELSEIF_FILL, BR_ELSE_FILL, BR_CASE_FILL, BR_DEFAULT_FILL, BR_SETUP_FILL, BR_VARIANT_FILL, BR_OPT_FILL:
	case:
		return false
	}
	if e.dim && e.fill == BR_OPT_FILL do return true // not possible here: the menu stays open
	fill := e.fill
	id := strings.clone(e.call_name, context.temp_allocator)
	ni, fi := app.slot_ni, app.slot_fi
	clear_nav(app)
	if app.slot_menu != nil {
		free_entries(app.slot_menu)
		app.slot_menu = nil
	}
	app.state = .Editor
	if ni < 0 || ni >= len(app.doc.nodes) do return true
	switch {
	case is_statement_fill(fill):
		if fi < 0 || fi >= len(app.doc.nodes[ni].fields) do return true
		make_branch_statement(app, ni, fi, fill)
		body_insert_done(app)
		focus_first_dot(app, ni)
	case fill == BR_ELSEIF_FILL || fill == BR_ELSE_FILL:
		add_branch_after_chain(app, ni, fill == BR_ELSEIF_FILL)
	case fill == BR_CASE_FILL || fill == BR_DEFAULT_FILL:
		add_case_at(app, ni, fill == BR_DEFAULT_FILL)
	case fill == BR_SETUP_FILL:
		fill_setup(app, ni, fi, id)
		if app.refill_active do refill_discard(app)
	case fill == BR_VARIANT_FILL:
		if fi >= 0 && fi < len(app.doc.nodes[ni].fields) && app.doc.nodes[ni].fields[fi].slot {
			set_slot_type(app, ni, fi, id)
			focus_field_index(app, ni, fi)
		}
		if app.refill_active do refill_discard(app)
	case fill == BR_OPT_FILL:
		apply_option(app, ni, fi, id)
	}
	if app.body_insert_active do body_insert_cancel(app) // a choice that didn't use the temporary line
	return true
}

// ---- Y / LT+B / RT ----

// branch_line_units: the parts of a branching line for selection.odin: the
// keywords, the setup's names and value, the condition / value (one part: Y
// changes it), a type switch's variable, each case value.
branch_line_units :: proc(n: Node) -> ([]Unit, bool) {
	l, ok := br_line(n)
	if !ok do return nil, false
	out := make([dynamic]Unit, 0, 6, context.temp_allocator)
	expr :: proc(n: Node, a, b: int) -> Unit {
		u := parse_expr_unit(n, a, b)
		u.is_arg = true
		return u
	}
	if l.partial >= 0 do append(&out, Unit{fa = l.partial, fb = l.partial + 1, kind = .Field})
	append(&out, Unit{fa = l.kw, fb = l.kw + 1, kind = .Field})
	if l.setup_a >= 0 {
		// names (and their separators) up to ` := ` / ` = `, then the value
		val := l.setup_a
		for i in l.setup_a ..< l.setup_b {
			f := n.fields[i]
			t := strings.trim_space(f.text)
			if !f.slot && !f.editable && (t == ":=" || t == "=") { val = i + 1; break }
		}
		for i in l.setup_a ..< val do if n.fields[i].editable || n.fields[i].slot do append(&out, Unit{fa = i, fb = i + 1, kind = .Field})
		if val < l.setup_b do append(&out, expr(n, val, l.setup_b))
	}
	if l.tvar >= 0 do append(&out, Unit{fa = l.tvar_ref >= 0 ? l.tvar_ref : l.tvar, fb = l.tvar + 1, kind = .Field}) // `&v`: one part
	if l.expr_a >= 0 {
		if l.kind == .Case {
			for r in arg_ranges(n, l.expr_a, l.expr_b) do append(&out, expr(n, r[0], r[1]))
		} else {
			append(&out, expr(n, l.expr_a, l.expr_b))
		}
	}
	for i in l.open + 1 ..< len(n.fields) do if n.fields[i].slot || n.fields[i].editable do append(&out, Unit{fa = i, fb = i + 1, kind = .Field})
	return out[:], true
}

// branch_change: Y on a branching line's keyword (its options), its whole
// condition / switch value, or a case value (refilled: B puts it back).
branch_change :: proc(app: ^App, ni: int, u: Unit) -> bool {
	n := app.doc.nodes[ni]
	l, ok := br_line(n)
	if !ok do return false
	if u.fb - u.fa == 1 && (u.fa == l.kw || u.fa == l.partial) do return open_options(app, ni, u.fa)
	if u.fb - u.fa == 1 && n.fields[u.fa].slot do return false // a dot: its menu (as A)
	if l.expr_a < 0 do return false
	if l.kind != .Case {
		if u.fa == l.expr_a && u.fb == l.expr_b {
			refill(app, ni, u.fa, u.fb, expr_dot(l))
			return true
		}
		return false
	}
	for r in arg_ranges(n, l.expr_a, l.expr_b) {
		if r[0] != u.fa || r[1] != u.fb do continue
		s := case_switch(app, ni)
		if s < 0 do return false
		refill(app, ni, u.fa, u.fb, case_dot(app, s))
		return true
	}
	return false
}

// branch_delete: LT+B on a branching line. True when handled.
branch_delete :: proc(app: ^App) -> bool {
	ni, fi, ok := editor_target(app)
	if !ok do return false
	n := app.doc.nodes[ni]
	l, lok := br_line(n)
	if !lok do return false
	fields := &app.doc.nodes[ni].fields
	// The condition / switch value: turn it back into its dot (not the whole construct).
	if (l.kind == .If || l.kind == .Else_If || l.kind == .Switch) && l.expr_a >= 0 && fi >= l.expr_a && fi < l.expr_b {
		if !(l.expr_b - l.expr_a == 1 && n.fields[l.expr_a].slot) {
			dot := expr_dot(l)
			cut_fields(fields, l.expr_a, l.expr_b)
			inject_at(fields, l.expr_a, dot)
		}
		focus_field_index(app, ni, l.expr_a)
		return true
	}
	// A type switch's variable: kept (LT+A renames it); the switch isn't deleted.
	if l.kind == .Switch && l.tvar >= 0 && (fi == l.tvar || fi == l.tvar_ref) do return true
	switch l.kind {
	case .None:
		return false
	case .Else_If, .Else:
		if l.kind == .Else_If && l.setup_a >= 0 && fi >= l.setup_a && fi <= l.setup_b {
			remove_setup(app, ni, l)
			return true
		}
		if fi != l.kw do return true
		h := if_chain_header(app, ni)
		if h < 0 do return false
		branches, end := if_chain(app, h)
		next := end
		for b in branches do if b > ni { next = b; break }
		delete_construct(app, ni, next - 1)
		if hl, hok := br_line_at(app, h); hok do focus_field_index(app, h, hl.kw)
		return true
	case .If, .Switch:
		if l.partial >= 0 && fi == l.partial {
			cut_fields(fields, l.partial, l.partial + 2)
			focus_field_index(app, ni, l.partial)
			return true
		}
		if l.setup_a >= 0 && fi >= l.setup_a && fi <= l.setup_b {
			remove_setup(app, ni, l)
			return true
		}
		if fi != l.kw do return true
		return false // the whole statement (block_delete.odin)
	case .Case:
		s := case_switch(app, ni)
		if fi == l.kw || l.default_case {
			if s < 0 do return false
			cases, end := switch_cases(app, s)
			next := end
			for c in cases do if c > ni { next = c; break }
			delete_construct(app, ni, next - 1)
			if c2, cok := br_line_at(app, s); cok do focus_field_index(app, s, c2.kw)
			return true
		}
		if l.expr_a < 0 || fi < l.expr_a || fi >= l.expr_b do return true
		ranges := arg_ranges(n, l.expr_a, l.expr_b)
		for r, k in ranges {
			if fi < r[0] || fi >= r[1] do continue
			if len(ranges) > 1 {
				// `case 1, 2:` -> `case 1:` (the value and a separator next to it)
				a, b := r[0], r[1]
				if k + 1 < len(ranges) do b += 1
				else do a -= 1
				cut_fields(fields, a, b)
				focus_field_index(app, ni, max(a - 1, l.expr_a))
			} else if !(r[1] - r[0] == 1 && n.fields[r[0]].slot) && s >= 0 {
				dot := case_dot(app, s)
				cut_fields(fields, r[0], r[1])
				inject_at(fields, r[0], dot)
				focus_field_index(app, ni, r[0])
			}
			return true
		}
		return true
	}
	return false
}

// ---- HUD ----

// branch_hint: what A / Y / LT+B do here ("" = nothing special).
branch_hint :: proc(app: ^App) -> string {
	if on_dot(app) {
		i := app.editor_line
		if i <= 0 || i > len(app.doc.nodes) do return ""
		if insertion_points(app, context.temp_allocator)[i] || !body_points(app, context.temp_allocator)[i] do return ""
		if c, ok := switch_ctx(app, i - 1, i); ok {
			if !c.in_clause do return "A: add a case"
			if c.at_end do return "A: add a statement or a case"
		}
		if chain_closed_by(app, i - 1) >= 0 do return "A: add a statement, else if or else"
		return ""
	}
	ni, fi, ok := editor_target(app)
	if !ok do return ""
	n := app.doc.nodes[ni]
	l, lok := br_line(n)
	if !lok do return ""
	if is_body_slot_line(n) do return ""
	if fi == l.kw || fi == l.partial {
		switch l.kind {
		case .None:
		case .If:      return "Y: add else if / else / setup, change condition    LT+B: delete"
		case .Else_If: return "Y: add else if / else / setup, change condition    LT+B: remove branch"
		case .Else:    return "Y: add else if    LT+B: remove branch"
		case .Switch:
			if fi == l.partial do return "Y: add case, #partial    LT+B: remove #partial"
			return "Y: add case / default, #partial, change value    LT+B: delete"
		case .Case:    return "Y: add value / case    LT+B: delete case"
		}
	}
	if l.setup_a >= 0 && fi >= l.setup_a && fi < l.setup_b do return "LT+B: remove setup"
	if l.kind == .Case && l.expr_a >= 0 && fi >= l.expr_a && fi < l.expr_b do return "Y: change value    LT+B: remove it"
	return ""
}

// ---- Other files' hooks ----

// branch_body_indent: the indentation of a statement inserted before line i
// next to case labels (body_dots.odin).
branch_body_indent :: proc(app: ^App, i: int) -> (string, bool) {
	n := len(app.doc.nodes)
	if i > 0 && i - 1 < n {
		if l, ok := br_line_at(app, i - 1); ok && l.kind == .Switch do return strings.clone(line_indent(app.doc.nodes[i - 1]), context.temp_allocator), true
		if is_case_line(app, i - 1) {
			ind := line_indent(app.doc.nodes[i - 1])
			return strings.concatenate({ind, indent_unit(ind)}, context.temp_allocator), true
		}
	}
	if i < n && is_case_line(app, i) {
		ind := line_indent(app.doc.nodes[i])
		return strings.concatenate({ind, indent_unit(ind)}, context.temp_allocator), true
	}
	return "", false
}

// branch_declares (var_types.odin): line j is an if / switch header whose setup
// declares `name`, or a type switch on `name`, and line `at` is inside it.
branch_declares :: proc(app: ^App, j, at: int, name: string, depth: int) -> (Var_Type, bool) {
	n := app.doc.nodes[j]
	l, ok := br_line(n)
	if !ok || (l.kind != .If && l.kind != .Switch && l.kind != .Else_If) || (l.setup_a < 0 && l.tvar < 0) do return {}, false
	end := br_block_end(app, j)
	if l.kind == .Else_If {
		// an else if's setup names: known to the end of the chain (later else if / else too)
		h := if_chain_header(app, j)
		if h >= 0 { _, end = if_chain(app, h) }
	}
	if at <= j || at > end do return {}, false
	if l.tvar >= 0 && n.fields[l.tvar].text == name do return type_switch_var(app, j, at, l), true
	if l.setup_a < 0 do return {}, false
	return decl_text_declares(app, j, strings.trim_space(range_text(n, l.setup_a, l.setup_b)), name, depth)
}

// The type of a type switch's variable on line at: the case's type when the
// clause names exactly one, else the switched value's (union) type.
@(private = "file")
type_switch_var :: proc(app: ^App, s, at: int, l: Br_Line) -> Var_Type {
	c := -1
	bal := 0
	for k in s ..< min(at + 1, len(app.doc.nodes)) {
		if k > s && bal == 1 && is_case_line(app, k) do c = k
		bal += brace_delta(app, k)
	}
	if cl, ok := br_line_at(app, c); ok && !cl.default_case && cl.expr_a >= 0 {
		cn := app.doc.nodes[c]
		rs := arg_ranges(cn, cl.expr_a, cl.expr_b)
		if len(rs) == 1 && !has_slot(cn, rs[0][0], rs[0][1]) {
			t := strings.trim_space(range_text(cn, rs[0][0], rs[0][1]))
			if t != "nil" do return Var_Type{t, ""}
		}
	}
	n := app.doc.nodes[s]
	if has_slot(n, l.expr_a, l.expr_b) do return {}
	t, _ := expr_type_at(app, s, range_text(n, l.expr_a, l.expr_b))
	return t
}

// branch_name_hidden (ref_pick.odin): field fi of line ni is a name only known
// inside its if / switch (a setup name, a type switch's variable) and line
// `from` is outside it.
branch_name_hidden :: proc(app: ^App, ni, fi, from: int) -> bool {
	l, ok := br_line_at(app, ni)
	if !ok do return false
	scoped := (l.setup_a >= 0 && fi >= l.setup_a && fi < l.setup_b) || fi == l.tvar
	if !scoped do return false
	end := br_block_end(app, ni)
	if l.kind == .Else_If {
		h := if_chain_header(app, ni)
		if h >= 0 { _, end = if_chain(app, h) }
	}
	return from < ni || from > end
}

// branch_no_break (format.odin): a branching line stays on one line.
branch_no_break :: proc(n: Node) -> bool {
	_, ok := br_line(n)
	return ok
}

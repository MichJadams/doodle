package model

// Expressions the value menu builds (and the loader reads back the same way):
//
//   Operator > Choose > "a if c else b"     ●  if  ●bool  else  ●
//                       "c ? a : b"         ●bool  ?  ●  :  ●
//                       "a when c else b"   ●  when  ●bool  else  ●
//     Both branches expect what the dot expected; the condition a bool. The
//     keywords are TERN_KIND fields; selection.odin makes the three parts an Op
//     unit (Y refills a part, LT+B turns it back into a dot).
//
//   Convert > T(x) > <type>                 T(●)       win32.HINSTANCE(●)
//             cast(T)x > <type>             cast(T)●   (one CONV_KIND field + the value)
//             transmute(T)x > <type>        transmute(T)●
//             auto_cast x                   auto_cast ●
//     The type menu has the dot's expected type pinned first; types that can't
//     produce it are grayed. T(x) is written like a call - a loaded `T(...)` is
//     a conversion when T names a type (var_types.odin conversion_type). Y on
//     T / cast(T) picks another type (or form); LT+B on it unwraps the value.
//
// LT+B on a part of an operator, a ternary or a conversion turns it into a dot;
// on a dot, the whole operator becomes one dot again - except in a chain of 3+
// operands (`a | ● | c`), where just that operand and one operator go.

import "core:fmt"
import "core:strings"

TERN_KIND :: "tern"     // " if ", " else ", " ? ", " : ", " when " of a ternary
CONV_KIND :: "conv"     // "cast(T)", "transmute(T)", "auto_cast " before a value
CONV_FILL :: "__conv__" // Convert leaves: call_name = the type as written here, ret = the form

CONV_CALL      :: "call"      // T(x)
CONV_CAST      :: "cast"      // cast(T)x
CONV_TRANSMUTE :: "transmute" // transmute(T)x
CONV_AUTO      :: "auto_cast" // auto_cast x

// ---- Ternary ----

// make_slot_ternary replaces a value dot with `● if ● else ●` (op "if"),
// `● ? ● : ●` (op "?") or `● when ● else ●` (op "when").
make_slot_ternary :: proc(app: ^App, ni, fi: int, op: string) {
	fields := &app.doc.nodes[ni].fields
	slot := fields[fi]
	h, p := slot.hint, slot.hint != "" ? slot.hint_pkg : ""
	if len(slot.text) > 0 do delete(slot.text)
	ordered_remove(fields, fi)
	val := Field{"", false, true, "value", h, p}
	cond := Field{"", false, true, "value", "bool", ""}
	kw :: proc(t: string) -> Field { return Field{strings.clone(t), false, false, TERN_KIND, "", ""} }
	if op == "?" {
		inject_at(fields, fi, cond, kw(" ? "), val, kw(" : "), val)
	} else {
		inject_at(fields, fi, val, kw(op == "when" ? " when " : " if "), cond, kw(" else "), val)
	}
}

@(private = "file")
is_tern_field :: proc(f: Field) -> bool { return !f.slot && f.kind == TERN_KIND }

@(private = "file")
x_open :: proc(f: Field) -> bool { return !f.slot && (f.text == "(" || f.text == "( " || is_lit_open(f)) }
@(private = "file")
x_close :: proc(f: Field) -> bool { return !f.slot && (f.text == ")" || f.text == " )" || is_lit_close(f)) }

// tern_split: a ternary at the top level of fields [a, b): its two keyword
// fields (`if` / `else`). Right-associative: `a if c else b if d else e`
// splits at the first `if` and its `else`.
tern_split :: proc(n: Node, a, b: int) -> (k1, k2: int, ok: bool) {
	depth, nest := 0, 0
	k1 = -1
	for i in a ..< b {
		f := n.fields[i]
		if x_open(f) { depth += 1; continue }
		if x_close(f) { depth -= 1; continue }
		if depth != 0 || !is_tern_field(f) do continue
		switch strings.trim_space(f.text) {
		case "if", "when", "?":
			if k1 < 0 do k1 = i
			else do nest += 1
		case "else", ":":
			if k1 < 0 do return -1, -1, false
			if nest > 0 { nest -= 1; continue }
			if k1 == a || i == k1 + 1 || i + 1 >= b do return -1, -1, false
			return k1, i, true
		}
	}
	return -1, -1, false
}

// The condition's position among a ternary's three parts (0 for `c ? a : b`).
@(private = "file")
tern_cond_index :: proc(n: Node, u: Unit) -> int {
	if len(u.children) != 3 do return -1
	f := n.fields[u.children[0].fb]
	if !is_tern_field(f) do return -1
	return strings.trim_space(f.text) == "?" ? 0 : 1
}

// op_operand_expected: what operand i of the operator unit u expects when u
// must produce `exp`: comparisons take anything, && / || bools, a shift
// count any integer, a ternary's condition a bool and its branches `exp`.
op_operand_expected :: proc(n: Node, u: Unit, i: int, exp, exp_pkg: string) -> (string, string) {
	if c := tern_cond_index(n, u); c >= 0 {
		if i == c do return "bool", ""
		return exp, exp_pkg
	}
	// parse_expr flattens every top-level operator into one Op (`ok && n > 3`:
	// ok, n, 3), so regroup by precedence: split the operand range at its
	// loosest operators, keep the segment holding i, and repeat.
	exp, exp_pkg := exp, exp_pkg
	lo, hi := 0, len(u.children)
	for hi - lo > 1 {
		loosest := max(int)
		for k in lo ..< hi - 1 do loosest = min(loosest, op_prec(op_after(n, u, k)))
		seg_lo, seg_hi := lo, hi
		for k in lo ..< hi - 1 {
			if op_prec(op_after(n, u, k)) != loosest do continue
			if k < i do seg_lo = k + 1
			else { seg_hi = k + 1; break }
		}
		switch loosest {
		case 3: return "", "" // a comparison's operands: anything
		case 1, 2: exp, exp_pkg = "bool", ""
		case 5:
			// A shift count: any integer.
			if seg_lo > lo {
				o := op_after(n, u, seg_lo - 1)
				if o == "<<" || o == ">>" do return "", ""
			}
		}
		lo, hi = seg_lo, seg_hi
	}
	return exp, exp_pkg
}

// The operator between operands k and k+1 of a flattened Op.
@(private = "file")
op_after :: proc(n: Node, u: Unit, k: int) -> string {
	o := u.children[k].fb
	return o < len(n.fields) ? strings.trim_space(n.fields[o].text) : ""
}

// Odin's binary operator precedence (1 binds loosest).
@(private = "file")
op_prec :: proc(op: string) -> int {
	switch op {
	case "||":                                       return 1
	case "&&":                                       return 2
	case "==", "!=", "<", "<=", ">", ">=":           return 3
	case "+", "-", "|", "~":                         return 4
	case "*", "/", "%", "%%", "&", "&~", "<<", ">>": return 5
	}
	return 6
}

// tern_split_text: a top-level ternary in s (single spaces around its
// keywords, non-empty parts): the byte ranges of the two keywords.
tern_split_text :: proc(s: string) -> (k1, e1, k2, e2: int, ok: bool) {
	depth, nest := 0, 0
	quote: u8 = 0
	k1 = -1
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if quote != 0 {
			if c == '\\' && quote != '`' { i += 1; continue }
			if c == quote do quote = 0
			continue
		}
		switch c {
		case '"', '\'', '`': quote = c
		case '(', '[', '{':  depth += 1
		case ')', ']', '}':  depth -= 1
		case ' ':
			if depth != 0 do continue
			rest := s[i:]
			for kw in ([]string{" if ", " when ", " ? "}) {
				if !strings.has_prefix(rest, kw) do continue
				if k1 < 0 { k1, e1 = i, i + len(kw) } else do nest += 1
				break
			}
			for kw in ([]string{" else ", " : "}) {
				if !strings.has_prefix(rest, kw) do continue
				if k1 < 0 do return
				if nest > 0 { nest -= 1; break }
				k2, e2 = i, i + len(kw)
				parts := [3]string{s[:k1], s[e1:k2], s[e2:]}
				for p in parts do if p == "" || p != strings.trim_space(p) do return
				// The keywords must agree: `if`/`when` ... `else`, `?` ... `:`.
				q := strings.trim_space(s[k1:e1]) == "?"
				if q != (strings.trim_space(s[k2:e2]) == ":") do return
				ok = true
				return
			}
		}
	}
	return
}

// emit_ternary: the fields of a ternary expression (parse.odin emit_expr).
emit_ternary :: proc(fields: ^[dynamic]Field, s: string) -> bool {
	k1, e1, k2, e2, ok := tern_split_text(s)
	if !ok do return false
	parse_expr_fields(fields, s[:k1])
	append(fields, Field{strings.clone(s[k1:e1]), false, false, TERN_KIND, "", ""})
	parse_expr_fields(fields, s[e1:k2])
	append(fields, Field{strings.clone(s[k2:e2]), false, false, TERN_KIND, "", ""})
	parse_expr_fields(fields, s[e2:])
	return true
}

// is_ternary_tail: the text after a call's ")" makes the value a ternary
// (`x := f(a) if c else b`): the call isn't the whole statement.
is_ternary_tail :: proc(tail: string) -> bool {
	t := tail
	if i := strings.index(t, "//"); i >= 0 do t = t[:i]
	t = strings.trim_space(t)
	if t == "" do return false
	_, _, _, _, ok := tern_split_text(strings.concatenate({"x ", t}, context.temp_allocator))
	return ok
}

// ---- Conversion prefixes: cast(T)x, transmute(T)x, auto_cast x ----

is_conv_prefix :: proc(f: Field) -> bool { return !f.slot && f.kind == CONV_KIND }

// The length of a conversion prefix at the start of s (with the spaces after it), or 0.
@(private = "file")
conv_prefix_len :: proc(s: string) -> int {
	n := 0
	if strings.has_prefix(s, "auto_cast ") {
		n = len("auto_cast ")
	} else {
		for kw in ([]string{"cast(", "transmute("}) {
			if !strings.has_prefix(s, kw) do continue
			close := match_bracket(s, len(kw) - 1)
			if close < 0 || strings.trim_space(s[len(kw):close]) == "" do return 0
			n = close + 1
			break
		}
	}
	if n == 0 do return 0
	for n < len(s) && s[n] == ' ' do n += 1
	return n < len(s) ? n : 0
}

// emit_conv_prefix: `cast(T)x` -> "cast(T)" (CONV_KIND) + the fields of x.
emit_conv_prefix :: proc(fields: ^[dynamic]Field, s: string) -> bool {
	n := conv_prefix_len(s)
	if n == 0 do return false
	append(fields, Field{strings.clone(s[:n]), false, false, CONV_KIND, "", ""})
	parse_expr_fields(fields, s[n:])
	return true
}

// emit_structured_value: a declaration's value (`x := <v>`, or ` = <v>` after
// a typed declaration's type) that is a ternary or starts with a conversion
// prefix is structured like an argument (parse.odin emit_decl_rest). False
// (nothing appended) for anything else: that stays one field, as before.
emit_structured_value :: proc(fields: ^[dynamic]Field, rest: string) -> bool {
	lead := ""
	v := rest
	if strings.has_prefix(rest, " = ") do lead, v = " = ", rest[3:]
	if v == "" || v != strings.trim_space(v) || strings.contains(v, "//") do return false
	_, _, _, _, tern := tern_split_text(v)
	if !tern && conv_prefix_len(v) == 0 do return false
	if lead != "" do append(fields, Field{strings.clone(lead), false, false, "", "", ""})
	parse_expr_fields(fields, v)
	return true
}

// The form of a conversion prefix field.
@(private = "file")
conv_form_of :: proc(text: string) -> string {
	switch {
	case strings.has_prefix(text, "cast("):      return CONV_CAST
	case strings.has_prefix(text, "transmute("): return CONV_TRANSMUTE
	case strings.has_prefix(text, "auto_cast"):  return CONV_AUTO
	}
	return ""
}

// ---- T(x) ----

// is_conv_callee: field cfi is the name before a "(" that names a type:
// `win32.HINSTANCE(...)`, `u32(...)`, a type declared in this file.
is_conv_callee :: proc(app: ^App, n: Node, cfi: int) -> bool {
	if cfi < 0 || cfi + 1 >= len(n.fields) do return false
	f := n.fields[cfi]
	if f.slot || f.editable || n.fields[cfi + 1].slot || n.fields[cfi + 1].text != "(" do return false
	if f.text == "" || !(is_ident(f.text) || strings.contains(f.text, ".")) do return false
	ref := callee_ref(n, cfi)
	full := ref != "" ? fmt.tprintf("%s.%s", ref, f.text) : f.text
	_, ok := conversion_type(app, full)
	return ok
}

// The fields of a conversion of type `ty` in form `form` around `inner`
// (moved in, not copied). T(x) is written like a call: `win32` `.` `HINSTANCE` `(` x `)`.
@(private = "file")
conv_fields :: proc(ty, form: string, inner: []Field) -> [dynamic]Field {
	out := make([dynamic]Field, 0, len(inner) + 5, context.temp_allocator)
	switch form {
	case CONV_CALL:
		if dot := strings.last_index_byte(ty, '.'); dot > 0 {
			append(&out, Field{strings.clone(ty[:dot]), false, false, "", "", ""})
			append(&out, Field{strings.clone("."), false, false, "", "", ""})
			append(&out, Field{strings.clone(ty[dot + 1:]), false, false, "", "", ""})
		} else {
			append(&out, Field{strings.clone(ty), false, false, "", "", ""})
		}
		append(&out, Field{strings.clone("("), false, false, "", "", ""})
		append(&out, ..inner)
		append(&out, Field{strings.clone(")"), false, false, "", "", ""})
	case CONV_AUTO:
		append(&out, Field{strings.clone("auto_cast "), false, false, CONV_KIND, "", ""})
		append(&out, ..inner)
	case:
		append(&out, Field{fmt.aprintf("%s(%s)", form, ty), false, false, CONV_KIND, "", ""})
		append(&out, ..inner)
	}
	return out
}

// make_slot_conversion replaces a value dot with T(●) / cast(T)● / ... (the
// inner dot takes any value).
make_slot_conversion :: proc(app: ^App, ni, fi: int, e: Entry) {
	fields := &app.doc.nodes[ni].fields
	if len(fields[fi].text) > 0 do delete(fields[fi].text)
	ordered_remove(fields, fi)
	inner := []Field{{"", false, true, "value", "", ""}}
	inject_at(fields, fi, ..conv_fields(e.call_name, e.ret, inner)[:])
}

// ---- The Convert menu ----

// How a type is written in this file: `HINSTANCE` in core:sys/windows -> "win32.HINSTANCE".
@(private = "file")
type_text_here :: proc(app: ^App, hint, hint_pkg: string) -> string {
	if hint_pkg == "" do return hint
	imports := collect_imports(app)
	defer delete(imports)
	for imp in imports do if imp.path == hint_pkg do return fmt.tprintf("%s.%s", imp.ref, hint)
	return hint
}

// A Type-menu entry as a Convert leaf (fill CONV_FILL); composite types are
// left out (`[]u8(x)` needs parentheses). Takes ownership of e's strings.
@(private = "file")
conv_retarget :: proc(e: Entry, form: string) -> (Entry, bool) {
	e := e
	if len(e.children) > 0 {
		kids := make([dynamic]Entry, 0, len(e.children), context.temp_allocator)
		for c in e.children do if r, ok := conv_retarget(c, form); ok do append(&kids, r)
		delete(e.children)
		e.children = nil
		if len(kids) == 0 {
			if e.owned_label do delete(e.label)
			if len(e.call_name) > 0 do delete(e.call_name)
			if len(e.call_pkg) > 0 do delete(e.call_pkg)
			if len(e.heat_key) > 0 do delete(e.heat_key)
			return {}, false
		}
		e.children = make([]Entry, len(kids))
		copy(e.children, kids[:])
		return e, true
	}
	if e.fill == "" do return e, true // a placeholder ("(no imports yet)")
	if is_types_fill(e.fill) {
		if e.owned_label do delete(e.label)
		if len(e.call_name) > 0 do delete(e.call_name)
		if len(e.call_pkg) > 0 do delete(e.call_pkg)
		if len(e.heat_key) > 0 do delete(e.heat_key)
		return {}, false
	}
	text := strings.clone(fill_type_text(e))
	if len(e.call_name) > 0 do delete(e.call_name)
	if len(e.call_pkg) > 0 do delete(e.call_pkg)
	e.call_name, e.call_pkg = text, ""
	e.fill, e.ret, e.ret_pkg = CONV_FILL, form, ""
	return e, true
}

// The types for one form: the expected type pinned first, then the Type menu.
@(private = "file")
conv_type_entries :: proc(app: ^App, hint, hint_pkg, form: string) -> []Entry {
	out := make([dynamic]Entry, 0, 16, context.temp_allocator)
	if hint != "" {
		text := type_text_here(app, hint, hint_pkg)
		append(&out, Entry{
			label = strings.clone(text), owned_label = true, pinned = true,
			fill = CONV_FILL, call_name = strings.clone(text), ret = form,
			// The label has this file's alias: heat goes by "<import path>.<Name>" (heat.odin).
			heat_key = hint_pkg != "" ? strings.concatenate({hint_pkg, ".", hint}) : "",
		})
	}
	types := build_type_entries(app)
	for e in types do if r, ok := conv_retarget(e, form); ok do append(&out, r)
	delete(types)
	r := make([]Entry, len(out))
	copy(r, out[:])
	return r
}

// build_convert_entries: the value menu's "Convert" group (and Y on a
// conversion's type). The forms' type lists are built when a form is opened
// (conv_expand): three copies of every imported type would make each value
// dot slow to open. A form leaf keeps the expected type (call_name / ret_pkg).
build_convert_entries :: proc(app: ^App, hint, hint_pkg: string) -> []Entry {
	form :: proc(label, form, hint, hint_pkg: string) -> Entry {
		return Entry{label = label, fill = CONV_FORM_FILL, ret = form, call_name = strings.clone(hint), ret_pkg = hint_pkg}
	}
	return make_slice(
		form("T(x)", CONV_CALL, hint, hint_pkg),
		form("cast(T)x", CONV_CAST, hint, hint_pkg),
		form("transmute(T)x", CONV_TRANSMUTE, hint, hint_pkg),
		Entry{label = "auto_cast x", fill = CONV_FILL, ret = CONV_AUTO},
	)
}

CONV_FORM_FILL :: "__conv_form__"

// conv_expand: A on a Convert form (T(x), cast(T)x, ...): its type list
// (built the first time, kept in the slot menu), grayed for the expected type.
conv_expand :: proc(app: ^App, e: Entry) {
	find :: proc(entries: []Entry, form: string) -> ^Entry {
		for &x in entries {
			if x.fill == CONV_FORM_FILL && x.ret == form do return &x
			if r := find(x.children, form); r != nil do return r
		}
		return nil
	}
	target := find(app.slot_menu, e.ret)
	if target == nil do return
	if len(target.children) == 0 {
		target.children = conv_type_entries(app, e.call_name, e.ret_pkg, e.ret)
		if e.call_name != "" {
			ctx := type_ctx_make(app)
			if exp := resolve_type(&ctx, e.call_name, e.ret_pkg); exp.cat != .Unknown do apply_fit_dims(&ctx, target.children, exp)
		}
	}
	push_menu(app, e.label, target.children)
}

// conv_fits: can the conversion produce the type a dot expects? (auto_cast,
// and a form whose type isn't chosen yet: yes.)
conv_fits :: proc(ctx: ^Type_Ctx, e: Entry, exp: Resolved_Type) -> bool {
	if e.fill != CONV_FILL || e.ret == CONV_AUTO || e.call_name == "" do return true
	return value_fits(resolve_type(ctx, e.call_name, ""), exp)
}

// value_is_compound: a statement's value is an operator, a ternary or a
// cast(T)x whose parts include calls (`x = f(a) if c else g(b)`): its parts
// are the value's tree, not the first call's arguments (selection.odin line_units).
value_is_compound :: proc(n: Node) -> bool {
	rhs := stmt_rhs_start(n)
	if rhs < 0 do return false
	u := parse_expr_unit(n, rhs, len(n.fields))
	return u.kind == .Op || (u.kind == .Group && is_conv_prefix(n.fields[rhs]))
}

// ---- Finding a part's enclosing units ----

// unit_chain: the units from the line's top level down to [fa, fb). A call
// statement's own call (its parts are the line's top level) is included.
@(private = "file")
unit_chain :: proc(n: Node, fa, fb: int) -> []Unit {
	out := make([dynamic]Unit, 0, 6, context.temp_allocator)
	search :: proc(units: []Unit, fa, fb: int, out: ^[dynamic]Unit) -> bool {
		for u in units {
			if u.fa == fa && u.fb == fb { append(out, u); return true }
			if u.fa <= fa && fb <= u.fb && len(u.children) > 0 {
				append(out, u)
				if search(u.children, fa, fb, out) do return true
				pop(out)
			}
		}
		return false
	}
	if !search(line_units(n), fa, fb, &out) do return nil
	// line_units lists a call statement's callee and arguments (or a literal's
	// parts) at the top level: put the call / literal itself above them.
	if al, ok := find_arg_list(n); ok && al.open > 0 {
		ca, cb := al.open - 1, al.close + 1
		top := out[0]
		if top.fa >= ca && top.fb <= cb && !(top.fa == ca && top.fb == cb) {
			whole := parse_expr_unit(n, ca, cb)
			if whole.kind == .Call || whole.kind == .Lit do inject_at(&out, 0, whole)
		}
	}
	return out[:]
}

// Is u a conversion: T(x) or cast(T)x? Returns the type field and the value's range.
@(private = "file")
conv_unit :: proc(app: ^App, n: Node, u: Unit) -> (tfi, va, vb: int, ok: bool) {
	if len(u.children) != 2 do return
	#partial switch u.kind {
	case .Group:
		c := u.children[0]
		if c.fb - c.fa == 1 && is_conv_prefix(n.fields[c.fa]) do return c.fa, u.children[1].fa, u.children[1].fb, true
	case .Call:
		c := u.children[0]
		if is_conv_callee(app, n, c.fa) && u.fb - 1 == u.children[1].fb do return c.fa, u.children[1].fa, u.children[1].fb, true
	}
	return
}

// ---- Y: another type for a conversion ----

// conv_change: Y on T of T(x) or on cast(T): the Convert menu (all forms,
// the expected type pinned); the choice rewrites the conversion, keeping x.
conv_change :: proc(app: ^App, ni: int, u: Unit) -> bool {
	if u.fb - u.fa != 1 do return false
	n := app.doc.nodes[ni]
	if !is_conv_prefix(n.fields[u.fa]) && !(u.kind == .Callee && is_conv_callee(app, n, u.fa)) do return false
	chain := unit_chain(n, u.fa, u.fb)
	if len(chain) < 2 do return false
	conv := chain[len(chain) - 2]
	if _, _, _, ok := conv_unit(app, n, conv); !ok do return false
	hint, pkg := unit_expected(app, ni, conv)

	app.replacing = true
	app.replace_ni, app.replace_fi = ni, u.fa
	app.slot_ni, app.slot_fi = ni, u.fa
	if app.slot_menu != nil do free_entries(app.slot_menu)
	app.slot_menu = build_convert_entries(app, hint, pkg)
	if hint != "" {
		ctx := type_ctx_make(app)
		if exp := resolve_type(&ctx, hint, pkg); exp.cat != .Unknown do apply_fit_dims(&ctx, app.slot_menu, exp)
	}
	clear_nav(app)
	app.return_state = .Editor
	app.state = .Radial
	push_menu(app, "Convert", app.slot_menu)
	return true
}

// Remove the `ref.` written before field cfi (it may be glued to the end of
// an earlier field: "\tx := win32."). Returns cfi's new index.
@(private = "file")
strip_qualifier :: proc(fields: ^[dynamic]Field, cfi: int, ref: string) -> int {
	cfi := cfi
	left := len(ref) + 1
	for i := cfi - 1; left > 0 && i >= 0; i -= 1 {
		f := &fields[i]
		if len(f.text) <= left {
			left -= len(f.text)
			if len(f.text) > 0 do delete(f.text)
			ordered_remove(fields, i)
			cfi -= 1
		} else {
			t := strings.clone(f.text[:len(f.text) - left])
			delete(f.text)
			f.text = t
			left = 0
		}
	}
	return cfi
}

// conv_rewrite: the conversion whose type field is tfi becomes `form` with
// type `ty` (form "" = unwrap: just the value). The cursor goes to its type
// (or the value). False when tfi isn't a conversion's type.
@(private = "file")
conv_rewrite :: proc(app: ^App, ni, tfi: int, ty, form: string) -> bool {
	n := app.doc.nodes[ni]
	chain := unit_chain(n, tfi, tfi + 1)
	if len(chain) < 2 do return false
	_, va, vb, ok := conv_unit(app, n, chain[len(chain) - 2])
	if !ok do return false
	fields := &app.doc.nodes[ni].fields
	start, end := tfi, chain[len(chain) - 2].fb
	if !is_conv_prefix(n.fields[tfi]) {
		if ref := callee_ref(n, tfi); ref != "" {
			ns := strip_qualifier(fields, tfi, ref)
			shift := tfi - ns
			start, end, va, vb = ns, end - shift, va - shift, vb - shift
		}
	}
	inner := make([dynamic]Field, 0, vb - va, context.temp_allocator)
	for i in va ..< vb do append(&inner, fields[i]) // moved
	for i in start ..< end do if (i < va || i >= vb) && len(fields[i].text) > 0 do delete(fields[i].text)
	remove_range(fields, start, end)
	if form == "" {
		inject_at(fields, start, ..inner[:])
		focus_field_index(app, ni, start)
		return true
	}
	nf := conv_fields(ty, form, inner[:])
	inject_at(fields, start, ..nf[:])
	at := start
	if form == CONV_CALL && strings.last_index_byte(ty, '.') > 0 do at += 2 // the name after `win32.`
	focus_field_index(app, ni, at)
	return true
}

// conv_retype: the Convert menu choice for Y on a conversion's type.
conv_retype :: proc(app: ^App, ni, fi: int, e: Entry) {
	if ni < 0 || ni >= len(app.doc.nodes) || fi < 0 || fi >= len(app.doc.nodes[ni].fields) do return
	conv_rewrite(app, ni, fi, e.call_name, e.ret)
}

// ---- LT+B ----

// Replace the part u of line ni with a dot of the type it expects.
@(private = "file")
part_to_dot :: proc(app: ^App, ni: int, u: Unit) {
	hint, pkg := unit_expected(app, ni, u)
	fields := &app.doc.nodes[ni].fields
	for i in u.fa ..< u.fb do if len(fields[i].text) > 0 do delete(fields[i].text)
	remove_range(fields, u.fa, u.fb)
	inject_at(fields, u.fa, Field{"", false, true, "value", hint, pkg})
	focus_field_index(app, ni, u.fa)
}

// expr_delete (LT+B, before the line-level deletes): on the type of T(x) /
// cast(T)x, unwrap the value; on a part of an operator, ternary or conversion,
// turn it into a dot; on such a dot: in a chain of 3+ operands (`a | ● | c`)
// drop that operand and one adjacent operator; with 2 operands (or a
// ternary), the whole operator becomes one dot.
expr_delete :: proc(app: ^App) -> bool {
	if app.state != .Editor do return false
	ni, leaf, ok := editor_leaf(app)
	if !ok do return false
	n := app.doc.nodes[ni]
	if leaf.fb - leaf.fa == 1 && (is_conv_prefix(n.fields[leaf.fa]) || (leaf.kind == .Callee && is_conv_callee(app, n, leaf.fa))) {
		return conv_rewrite(app, ni, leaf.fa, "", "")
	}
	chain := unit_chain(n, leaf.fa, leaf.fb)
	if len(chain) == 0 do return false
	pi := len(chain) - 1
	// The name of a call inside an expression: the call is the part.
	if leaf.kind == .Callee && pi >= 1 && chain[pi - 1].kind == .Call do pi -= 1
	if pi < 1 do return false
	part, parent := chain[pi], chain[pi - 1]
	_, _, _, is_conv := conv_unit(app, n, parent)
	// An argument of a call inside an expression (not the statement's own call).
	nested_arg := parent.kind == .Call && pi >= 2 && part.kind != .Callee
	if parent.kind != .Op && !is_conv && !nested_arg do return false
	if part.fb - part.fa == 1 && n.fields[part.fa].slot {
		if is_conv do return conv_rewrite(app, ni, parent.children[0].fa, "", "")
		if nested_arg do return true // already a dot (LT+B on the call's name removes the call)
		// A dot of a chain `a | ● | c` (not a ternary): drop just the dot and one operator next to it.
		if len(parent.children) > 2 && tern_cond_index(n, parent) < 0 {
			k := -1
			for c, i in parent.children do if c.fa == part.fa { k = i; break }
			if k >= 0 {
				ra, rb := parent.children[k - 1 if k > 0 else 0].fb, part.fb // the operator before + the dot
				if k == 0 do ra, rb = part.fa, parent.children[1].fa // the dot + the operator after
				fields := &app.doc.nodes[ni].fields
				for i in ra ..< rb do if len(fields[i].text) > 0 do delete(fields[i].text)
				remove_range(fields, ra, rb)
				focus_field_index(app, ni, k > 0 ? ra - 1 : ra)
				return true
			}
		}
		part_to_dot(app, ni, parent) // a dot of `● | ●`: drop the operator
		return true
	}
	part_to_dot(app, ni, part)
	return true
}

// ---- LT+A on a number: the keypad ----
//
// Value > Number puts an editable `0`; LT+A on it opens a keypad (1-9, 0, A-F,
// 0x, ".", Del, OK) that edits it in place: 0x -> 0 0 F F 0 0 6 2 gives
// 0x00FF0062. Keys that can't apply are grayed (A-F before 0x, ...). B / OK closes it.

NUM_KEY_FILL :: "__num_key__"

@(private = "file")
NUM_KEYS := [?]string{"1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "A", "B", "C", "D", "E", "F", "0x", ".", "Del", "OK"}

// A number literal built from the menus (an editable field starting with a digit).
is_number_field :: proc(f: Field) -> bool {
	return !f.slot && f.editable && f.kind == "" && len(f.text) > 0 && f.text[0] >= '0' && f.text[0] <= '9'
}

// number_keypad_open: LT+A on a number (model.odin edit_selected). False when it isn't one.
number_keypad_open :: proc(app: ^App, ni, fi: int) -> bool {
	// A number loaded from a file is fixed text: it becomes editable (dictation.odin).
	if f := &app.doc.nodes[ni].fields[fi]; is_number_literal_field(f^) && !f.editable && f.text[0] != '-' do f.editable = true
	if !is_number_field(app.doc.nodes[ni].fields[fi]) do return false
	if app.slot_menu != nil do free_entries(app.slot_menu)
	app.slot_menu = make([]Entry, len(NUM_KEYS))
	for k, i in NUM_KEYS do app.slot_menu[i] = Entry{label = k, fill = NUM_KEY_FILL}
	app.slot_ni, app.slot_fi = ni, fi
	clear_nav(app)
	app.return_state = .Editor
	app.state = .Radial
	v := MenuView{title = "Number", entries = make([]Entry, len(app.slot_menu))} // in key order (no sorting)
	copy(v.entries, app.slot_menu)
	push_view(app, v)
	keypad_dims(app)
	return true
}

// The number after pressing `key`.
keypad_apply :: proc(t, key: string) -> string {
	hex := strings.has_prefix(t, "0x")
	switch key {
	case "Del":
		if t == "0x" || len(t) <= 1 do return "0"
		return t[:len(t) - 1]
	case "0x":
		return t == "0" ? "0x" : t
	case ".":
		return !hex && !strings.contains(t, ".") ? strings.concatenate({t, "."}, context.temp_allocator) : t
	case "OK":
		return t
	}
	if len(key) != 1 do return t
	if key[0] >= 'A' && key[0] <= 'F' && !hex do return t
	if t == "0" do return key // the default 0 is replaced
	return strings.concatenate({t, key}, context.temp_allocator)
}

@(private = "file")
keypad_dims :: proc(app: ^App) {
	v := current_view(app)
	if v == nil || app.slot_ni < 0 || app.slot_ni >= len(app.doc.nodes) || app.slot_fi < 0 || app.slot_fi >= len(app.doc.nodes[app.slot_ni].fields) do return
	t := app.doc.nodes[app.slot_ni].fields[app.slot_fi].text
	for &e in v.entries do e.dim = e.label != "OK" && e.label != "Del" && keypad_apply(t, e.label) == t
}

// number_key: a keypad key (model.odin menu_select). The keypad stays open until OK / B.
number_key :: proc(app: ^App, e: Entry) {
	ni, fi := app.slot_ni, app.slot_fi
	ok := ni >= 0 && ni < len(app.doc.nodes) && fi >= 0 && fi < len(app.doc.nodes[ni].fields) && is_number_field(app.doc.nodes[ni].fields[fi])
	if !ok || e.label == "OK" {
		clear_nav(app)
		app.state = .Editor
		if app.slot_menu != nil { free_entries(app.slot_menu); app.slot_menu = nil }
		if ok do focus_field_index(app, ni, fi)
		return
	}
	t := app.doc.nodes[ni].fields[fi].text
	if nt := keypad_apply(t, e.label); nt != t do set_field_text(app, ni, fi, nt)
	keypad_dims(app)
}

// ---- Loading: the dots of nested calls ----

// attach_nested_call_hints: dots of calls inside other expressions
// (`win32.HINSTANCE(win32.GetModuleHandleW(●))`) expect their parameters'
// types, as a call statement's own dots do (parse.odin attach_call_signature).
attach_nested_call_hints :: proc(app: ^App) {
	// `f()` of a proc with one required parameter: its dot (saved the same: `f()`).
	// Returns true when it added one (the units are stale then).
	add_dot :: proc(app: ^App, ni: int, units: []Unit) -> bool {
		for u in units {
			if u.kind == .Call && len(u.children) == 1 && u.fb - u.children[0].fb == 2 {
				n := app.doc.nodes[ni]
				cfi := u.children[0].fa
				if is_conv_callee(app, n, cfi) do continue
				sig := call_signature(app, callee_ref(n, cfi), n.fields[cfi].text)
				if sig.known && sig.req == 1 {
					inject_at(&app.doc.nodes[ni].fields, u.fb - 1, Field{"", false, true, "value", "", ""})
					return true
				}
			}
			if add_dot(app, ni, u.children) do return true
		}
		return false
	}
	visit :: proc(app: ^App, ni: int, units: []Unit) {
		for u in units {
			if u.kind == .Call && len(u.children) > 1 {
				n := app.doc.nodes[ni]
				cfi := u.children[0].fa
				sig := call_signature(app, callee_ref(n, cfi), n.fields[cfi].text)
				if sig.known {
					req := make([dynamic]string, 0, 4, context.temp_allocator)
					var_hint := ""
					for p in sig.params {
						if p.variadic do var_hint = p.type
						else if !p.optional do append(&req, p.type)
					}
					for c in u.children[1:] {
						if c.fb - c.fa != 1 do continue
						f := &app.doc.nodes[ni].fields[c.fa]
						if !f.slot || f.kind != "value" || f.hint != "" do continue
						h := c.arg_idx < len(req) ? req[c.arg_idx] : var_hint
						if h == "" do continue
						if sig.pkg == "" { f.hint, f.hint_pkg = intern_hint(app, h), "" } else { f.hint, f.hint_pkg = h, sig.pkg }
					}
				}
			}
			visit(app, ni, u.children)
		}
	}
	for n, ni in app.doc.nodes {
		if strings.contains(node_text(n, context.temp_allocator), "()") {
			for _ in 0 ..< 8 do if !add_dot(app, ni, line_units(app.doc.nodes[ni])) do break
		}
		has_dot := false
		for f in app.doc.nodes[ni].fields do if f.slot && f.kind == "value" && f.hint == "" { has_dot = true; break }
		if has_dot do visit(app, ni, line_units(app.doc.nodes[ni]))
	}
}

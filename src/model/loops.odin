package model

// Loops (the statement menu's "Loops" group). Odin has only `for`, in many shapes:
//
//   For (condition)   for ● {                       while-style: a bool condition
//   For (C-style)     for i := 0; i < ●; i += 1 {   init; condition; post (each may be empty)
//   For (infinite)    for {
//   For ... in        for item in ● {               over an array / slice / string / map
//   For x, i in       for item, index in ● {        + index (a map: key, value; a string: rune, index)
//   For i in 0..<n    for i in 0..<● {              a range (range_fill.odin); 0..=n inclusive
//   For &x in         for &item in ● {              by reference: edit the elements in place
//   #reverse for      #reverse for item in ● {      backwards (not maps, not ranges)
//   #unroll for       #unroll for i in 0..<● {      unrolled at compile time (constant ranges, arrays)
//   Labeled for       outer: for item in ● {        `break outer` / `continue outer` from inner loops
//
// A loop header's fields:
//   [indent] [label (LABEL_KIND)][": "] [#reverse / #unroll (kw)][" "] [for (kw)] ...
//     while:     " " <condition> " {"
//     infinite:  " {"
//     for-in:    " " ["&"] var1 [", " ["&"] var2] " in " <iterable> " {"
//     C-style:   " " <init> "; " <condition> "; " <post> " {"   (";" alone before " {" when post is empty)
//   init  = name " := " value;   post = target op value   (op: ASSIGN_OP_KIND, `+=` ...)
//
// Controller:
//   Y on `for` / the directive / the label -> the loop's options (label, #reverse / #unroll,
//       2nd variable, by reference, add / remove / change the condition, init, post, iterable)
//   Y on a loop variable                   -> by reference on / off (`&item`)
//   Y on an assignment's operator          -> another operator (= += -= ...)
//   Y on break / continue                  -> with which label
//   LT+B on the label / directive / 2nd variable -> removes it; on a C-style part -> removes
//       that part; on the condition / iterable -> back to a dot; on `for` -> the whole loop
// Loop variables are typed and scoped in var_types.odin (loop_header_declares) and
// only offered by Reference inside their loop (loop_name_visible).

import "core:fmt"
import "core:strconv"
import "core:strings"

LABEL_KIND     :: "label"     // a statement label: `outer` in `outer: for ... {` (editable)
ASSIGN_OP_KIND :: "assign_op" // an assignment's operator field: " = ", " += ", ...

// Fills (Entry.fill).
LOOP_CSTYLE_FILL     :: "__loop_cstyle__"
LOOP_IN2_FILL        :: "__loop_forin2__"
LOOP_RANGE_FILL      :: "__loop_range__"
LOOP_RANGE_INCL_FILL :: "__loop_rangeincl__"
LOOP_BYREF_FILL      :: "__loop_byref__"
LOOP_REVERSE_FILL    :: "__loop_reverse__"
LOOP_UNROLL_FILL     :: "__loop_unroll__"
LOOP_LABELED_FILL    :: "__loop_labeled__"
LOOP_ITER_RANGE_FILL :: "__loop_iter_range__" // "Range" on an iterable dot (call_name = "..<" / "..=")
LOOP_JUMP_FILL       :: "__loop_jump__"       // "Break outer" (call_name = "break outer")
ASSIGN_OP_FILL       :: "__stmt_assign_op__"  // "+=" ... in the Assignment group (call_name = the op)
CTX_ASSIGN_FILL      :: "__stmt_ctx_assign__" // Assignment > Implicit Context > field: context.field = ● (call_name = field, ret = its type)
LOOP_OPT_FILL        :: "__loop_opt__"        // an option of a loop / operator / jump menu (call_name = id, call_pkg = "ni fi")

ASSIGN_OPS := [?]string{"=", "+=", "-=", "*=", "/=", "%=", "%%=", "|=", "&=", "~=", "&~=", "<<=", ">>=", "&&=", "||="}

is_assign_op_text :: proc(t: string) -> bool {
	for o in ASSIGN_OPS do if o == t do return true
	return false
}

// ---- Fields ----

@(private = "file")
fx :: proc(text: string) -> Field { return Field{strings.clone(text), false, false, "", "", ""} }
@(private = "file")
fkw :: proc(text: string) -> Field { return Field{strings.clone(text), false, false, KW, "", ""} }
@(private = "file")
fname :: proc(text: string) -> Field { return Field{strings.clone(text), true, false, "", "", ""} }
@(private = "file")
flabel :: proc(text: string) -> Field { return Field{strings.clone(text), true, false, LABEL_KIND, "", ""} }
@(private = "file")
fdot :: proc(hint := "") -> Field { return Field{"", false, true, "value", hint, ""} }
@(private = "file")
fop :: proc(op: string) -> Field { return Field{fmt.aprintf(" %s ", op), false, false, ASSIGN_OP_KIND, "", ""} }

@(private = "file")
is_ws :: proc(f: Field) -> bool { return !f.slot && !f.editable && f.kind == "" && strings.trim_space(f.text) == "" }
@(private = "file")
is_fixed :: proc(f: Field, text: string) -> bool { return !f.slot && !f.editable && f.kind == "" && strings.trim_space(f.text) == text }
@(private = "file")
is_var_field :: proc(f: Field) -> bool { return f.editable && !f.slot && f.kind == "" }

is_for_kw :: proc(f: Field) -> bool { return !f.slot && f.kind == KW && f.text == "for" }
is_loop_directive :: proc(f: Field) -> bool { return !f.slot && f.kind == KW && (f.text == "#reverse" || f.text == "#unroll") }
is_jump_kw :: proc(f: Field) -> bool { return !f.slot && f.kind == KW && (f.text == "break" || f.text == "continue") }

@(private = "file")
del_fields :: proc(fields: ^[dynamic]Field, a, b: int) {
	if b <= a do return
	for i in a ..< b do if len(fields[i].text) > 0 do delete(fields[i].text)
	remove_range(fields, a, b)
}

@(private = "file")
set_text :: proc(f: ^Field, text: string) {
	if len(f.text) > 0 do delete(f.text)
	f.text = strings.clone(text)
}

// Bracket balance of a field's text.
@(private = "file")
paren_delta :: proc(f: Field) -> int {
	if f.slot || f.kind == "string" do return 0
	d := 0
	for c in transmute([]u8)f.text {
		switch c {
		case '(', '[', '{': d += 1
		case ')', ']', '}': d -= 1
		}
	}
	return d
}

// ---- The structure of a loop header ----

Loop_Form :: enum u8 { Infinite, Cond, In, CStyle }

Loop_Hdr :: struct {
	label, label_sep: int, // -1 when unlabeled
	directive:        int, // #reverse / #unroll keyword (a " " follows it), -1 when none
	kw:               int, // the `for` keyword
	open:             int, // the trailing " {"
	form:             Loop_Form,
	// for-in
	var1, var2:       int, // -1 when absent
	ref1, ref2:       int, // the "&" before var1 / var2, -1 when absent
	vsep:             int, // the ", " between them
	in_sep:           int, // " in "
	// C-style
	semi1, semi2:     int,
	// expression regions [a, b)
	cond_a, cond_b:   int, // while / C-style condition
	iter_a, iter_b:   int, // for-in iterable
	init_a, init_b:   int, // C-style init
	post_a, post_b:   int, // C-style post
}

// loop_hdr: the structure of line n when it's a loop header.
loop_hdr :: proc(n: Node) -> (h: Loop_Hdr, ok: bool) {
	h = Loop_Hdr{label = -1, label_sep = -1, directive = -1, kw = -1, open = -1, var1 = -1, var2 = -1, ref1 = -1, ref2 = -1,
		vsep = -1, in_sep = -1, semi1 = -1, semi2 = -1}
	fs := n.fields
	i := 0
	for i < len(fs) && is_ws(fs[i]) do i += 1
	if i + 1 < len(fs) && fs[i].editable && !fs[i].slot && !fs[i + 1].slot && fs[i + 1].text == ": " {
		h.label, h.label_sep = i, i + 1
		i += 2
	}
	if i + 1 < len(fs) && is_loop_directive(fs[i]) && fs[i + 1].text == " " {
		h.directive = i
		i += 2
	}
	if i >= len(fs) || !is_for_kw(fs[i]) do return h, false
	h.kw = i
	last := len(fs) - 1
	if last <= h.kw || fs[last].slot || fs[last].editable || fs[last].kind != "" || !strings.has_suffix(fs[last].text, "{") || strings.trim_space(fs[last].text) != "{" do return h, false
	h.open = last
	if last == h.kw + 1 {
		h.form = .Infinite
		return h, true
	}
	if fs[h.kw + 1].slot || fs[h.kw + 1].text != " " do return h, false
	a, b := h.kw + 2, last
	semis: [2]int
	ns := 0
	depth := 0
	for k in a ..< b {
		f := fs[k]
		if depth == 0 && !f.slot && !f.editable && f.kind == "" {
			t := strings.trim_space(f.text)
			if t == "in" && h.in_sep < 0 && len(f.text) > 2 do h.in_sep = k
			else if t == ";" {
				if ns < 2 do semis[ns] = k
				ns += 1
			}
		}
		depth += paren_delta(f)
	}
	switch {
	case h.in_sep >= 0 && ns == 0:
		h.form = .In
		k := a
		if k < h.in_sep && is_fixed(fs[k], "&") { h.ref1 = k; k += 1 }
		if k >= h.in_sep || !is_var_field(fs[k]) do return h, false
		h.var1 = k
		k += 1
		if k < h.in_sep {
			if !is_fixed(fs[k], ",") do return h, false
			h.vsep = k
			k += 1
			if k < h.in_sep && is_fixed(fs[k], "&") { h.ref2 = k; k += 1 }
			if k >= h.in_sep || !is_var_field(fs[k]) do return h, false
			h.var2 = k
			k += 1
		}
		if k != h.in_sep do return h, false
		h.iter_a, h.iter_b = h.in_sep + 1, b
	case ns == 2 && h.in_sep < 0:
		h.form = .CStyle
		h.semi1, h.semi2 = semis[0], semis[1]
		h.init_a, h.init_b = a, h.semi1
		h.cond_a, h.cond_b = h.semi1 + 1, h.semi2
		h.post_a, h.post_b = h.semi2 + 1, b
	case ns == 0:
		h.form = .Cond
		h.cond_a, h.cond_b = a, b
	case:
		return h, false
	}
	return h, true
}

// A labeled block `outer: {`: its label field.
labeled_block :: proc(n: Node) -> (label: int, ok: bool) {
	i := 0
	for i < len(n.fields) && is_ws(n.fields[i]) do i += 1
	if i + 2 != len(n.fields) do return -1, false
	f, g := n.fields[i], n.fields[i + 1]
	if !f.editable || f.slot || g.slot || g.editable || g.text != ": {" do return -1, false
	return i, true
}

// The range operator field inside [a, b) (`0..<n`), or -1.
@(private = "file")
range_op_in :: proc(n: Node, a, b: int) -> int {
	depth := 0
	for k in a ..< b {
		f := n.fields[k]
		if depth == 0 && !f.slot && !f.editable {
			t := strings.trim_space(f.text)
			if t == "..<" || t == "..=" do return k
		}
		depth += paren_delta(f)
	}
	return -1
}

// The C-style init / post parts when structured: name, " := " / op, value [v, b).
@(private = "file")
part_split :: proc(n: Node, a, b: int) -> (name, op, v: int, ok: bool) {
	if b - a < 3 || !is_var_field(n.fields[a]) do return
	f := n.fields[a + 1]
	if f.slot do return
	if f.kind == ASSIGN_OP_KIND || is_fixed(f, ":=") do return a, a + 1, a + 2, true
	return
}

// The last line of the block a header at line ni opens.
loop_block_end :: proc(app: ^App, ni: int) -> int {
	balance := 0
	for j in ni ..< len(app.doc.nodes) {
		for c in line_brace_seq(node_text(app.doc.nodes[j], context.temp_allocator)) {
			balance += c == '{' ? 1 : -1
		}
		if balance <= 0 do return j
	}
	return len(app.doc.nodes) - 1
}

// ---- The text of a loop header (var_types.odin, jump scopes) ----

Loop_Text :: struct {
	label:     string,
	directive: string,
	form:      Loop_Form,
	vars:      [2]string,
	refs:      [2]bool,
	nvars:     int,
	iter:      string,
	init:      string,
	cond:      string,
	post:      string,
}

@(private = "file")
ident_end :: proc(s: string) -> int {
	k := 0
	for k < len(s) && ((s[k] >= 'a' && s[k] <= 'z') || (s[k] >= 'A' && s[k] <= 'Z') || s[k] == '_' || (k > 0 && s[k] >= '0' && s[k] <= '9')) do k += 1
	return k
}

// split_label: `outer: rest` -> "outer", "rest" (only before a block / loop / switch / if).
split_label :: proc(t: string) -> (label, rest: string) {
	k := ident_end(t)
	if k == 0 || k + 1 >= len(t) || t[k] != ':' || t[k + 1] != ' ' do return "", t
	if t[:k] == "case" do return "", t
	r := strings.trim_left_space(t[k + 1:])
	for p in ([]string{"{", "for ", "for{", "#reverse ", "#unroll ", "switch ", "#partial ", "if "}) {
		if strings.has_prefix(r, p) do return t[:k], r
	}
	return "", t
}

// Index of `sub` at the top level of s (outside brackets and strings), from `from`.
@(private = "file")
top_index :: proc(s, sub: string, from := 0) -> int {
	depth := 0
	quote: u8 = 0
	for k := 0; k < len(s); k += 1 {
		c := s[k]
		if quote != 0 {
			if c == '\\' && quote != '`' { k += 1; continue }
			if c == quote do quote = 0
			continue
		}
		switch c {
		case '"', '\'', '`': quote = c
		case '(', '[', '{':  depth += 1
		case ')', ']', '}':  depth -= 1
		case:
			if k >= from && depth == 0 && strings.has_prefix(s[k:], sub) do return k
		}
	}
	return -1
}

// loop_text: a (trimmed, comment-free) line read as a loop header.
loop_text :: proc(line: string) -> (lt: Loop_Text, ok: bool) {
	t := strings.trim_space(line)
	lt.label, t = split_label(t)
	for d in ([]string{"#reverse ", "#unroll "}) {
		if strings.has_prefix(t, d) {
			lt.directive = strings.trim_space(d)
			t = strings.trim_left_space(t[len(d):])
		}
	}
	if !strings.has_prefix(t, "for") || !strings.has_suffix(t, "{") do return
	rest := t[len("for"):]
	if len(rest) > 0 && rest[0] != ' ' && rest[0] != '{' do return
	mid := strings.trim_space(rest[:len(rest) - 1])
	if mid == "" {
		lt.form = .Infinite
		return lt, true
	}
	if at := top_index(mid, " in "); at >= 0 && top_index(mid, ";") < 0 {
		lt.form = .In
		lt.iter = strings.trim_space(mid[at + 4:])
		for p in strings.split(mid[:at], ",", context.temp_allocator) {
			v := strings.trim_space(p)
			ref := strings.has_prefix(v, "&")
			if ref do v = strings.trim_space(v[1:])
			if lt.nvars >= 2 || ident_end(v) != len(v) || v == "" do return
			lt.vars[lt.nvars], lt.refs[lt.nvars] = v, ref
			lt.nvars += 1
		}
		return lt, lt.nvars > 0
	}
	s1 := top_index(mid, ";")
	if s1 >= 0 {
		s2 := top_index(mid, ";", s1 + 1)
		if s2 < 0 do return
		lt.form = .CStyle
		lt.init = strings.trim_space(mid[:s1])
		lt.cond = strings.trim_space(mid[s1 + 1:s2])
		lt.post = strings.trim_space(mid[s2 + 1:])
		return lt, true
	}
	lt.form = .Cond
	lt.cond = mid
	return lt, true
}

// ---- What can be iterated ----

Iter_Kind :: enum u8 { Unknown, None, Array, Slice, Dynamic, Map, String, Range }

// iter_info: how a value of type t iterates: the kind, and the types of the
// first / second loop variable (element, index - a map's key, value).
iter_info :: proc(app: ^App, t: Var_Type, depth := 0) -> (k: Iter_Kind, v1, v2: Var_Type) {
	s := strings.trim_space(t.expr)
	for strings.has_prefix(s, "distinct ") do s = strings.trim_space(s[len("distinct "):])
	if s == "" || depth > 8 do return .Unknown, {}, {}
	int_t := Var_Type{"int", ""}
	switch {
	case strings.has_prefix(s, "[dynamic]"): return .Dynamic, Var_Type{strings.trim_space(s[len("[dynamic]"):]), t.pkg}, int_t
	case strings.has_prefix(s, "[^]"):       return .None, {}, {}
	case strings.has_prefix(s, "[]"):        return .Slice, Var_Type{strings.trim_space(s[2:]), t.pkg}, int_t
	case strings.has_prefix(s, "#"):         return .Unknown, {}, {}
	case strings.has_prefix(s, "["):
		close := match_bracket(s, 0)
		if close < 0 do return .Unknown, {}, {}
		idx := int_t
		if et, eok := enum_index_type(app, s[1:close], t.pkg); eok do idx = et // `[Dir]int`: d is a Dir (enum_index.odin)
		return .Array, Var_Type{strings.trim_space(s[close + 1:]), t.pkg}, idx
	case strings.has_prefix(s, "map["):
		close := match_bracket(s, 3)
		if close < 0 do return .Map, {}, {}
		return .Map, Var_Type{strings.trim_space(s[4:close]), t.pkg}, Var_Type{strings.trim_space(s[close + 1:]), t.pkg}
	case s == "string", s == "string16":
		return .String, Var_Type{"rune", ""}, int_t
	case strings.has_prefix(s, "^"), strings.has_prefix(s, "proc"), strings.has_prefix(s, "struct"), strings.has_prefix(s, "enum"),
	     strings.has_prefix(s, "union"), strings.has_prefix(s, "bit_set"), strings.has_prefix(s, "bit_field"), strings.has_prefix(s, "matrix"):
		return .None, {}, {}
	}
	// A named type: follow aliases / distinct types.
	if t.pkg == "" && strings.index_byte(s, '.') < 0 {
		if rhs, found := doc_type_rhs_type(app, s); found { // (another file's type: as seen from here)
			for kw in ([]string{"struct", "enum", "union", "bit_", "proc", "#type"}) do if strings.has_prefix(rhs.expr, kw) do return .None, {}, {}
			return iter_info(app, rhs, depth + 1)
		}
	}
	ctx := type_ctx_make(app)
	r := resolve_type(&ctx, s, t.pkg)
	#partial switch r.cat {
	case .Unknown, .Any: return .Unknown, {}, {}
	case .String:        return .String, Var_Type{"rune", ""}, int_t
	case .Slice, .Array, .Map:
		if r.canon != s do return iter_info(app, Var_Type{r.canon, type_path(app, s, t.pkg)}, depth + 1)
		return .Unknown, {}, {}
	}
	return .None, {}, {}
}

// The import path a (possibly qualified) type name is declared in, best effort.
@(private = "file")
type_path :: proc(app: ^App, s, pkg: string) -> string {
	dot := strings.index_byte(s, '.')
	if dot < 0 do return pkg
	if pkg == "" {
		imports := collect_imports(app)
		defer delete(imports)
		for imp in imports do if imp.ref == s[:dot] do return strings.clone(imp.path, context.temp_allocator)
	}
	return pkg
}

// `Name :: <rhs>` at file scope: the first line of rhs. Not declared in the
// document: a type of another file of the package (siblings.odin), as written
// there (doc_type_rhs_type reads it as a type seen from here).
doc_type_rhs :: proc(app: ^App, name: string) -> (string, bool) {
	if rhs, found := own_type_rhs(app, name); found do return rhs, true
	if st, found := sibling_type(app, name); found do return sibling_rhs_line(st), true
	return "", false
}

// doc_type_rhs_type: doc_type_rhs as a type seen from this document. A
// sibling's rhs may be written in another package: `linalg.Vector3f32` in a
// file importing core:math/linalg, read from one that doesn't, is
// {"Vector3f32", "core:math/linalg"} (sibling_type_here).
doc_type_rhs_type :: proc(app: ^App, name: string) -> (Var_Type, bool) {
	if rhs, found := own_type_rhs(app, name); found do return Var_Type{rhs, ""}, true
	return sibling_type_rhs(app, name)
}

@(private = "file")
own_type_rhs :: proc(app: ^App, name: string) -> (string, bool) {
	pts := insertion_points(app, context.temp_allocator)
	for n, ni in app.doc.nodes {
		if !pts[ni] do continue
		t := strings.trim_space(node_text(n, context.temp_allocator))
		if !strings.has_prefix(t, name) do continue
		rest := strings.trim_left_space(t[len(name):])
		if !strings.has_prefix(rest, "::") do continue
		return strings.trim_space(rest[2:]), true
	}
	return "", false
}

@(private = "file")
is_int_literal :: proc(s: string) -> bool {
	if s == "" do return false
	for c in transmute([]u8)s do if !((c >= '0' && c <= '9') || c == '_' || c == 'x' || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) do return false
	return s[0] >= '0' && s[0] <= '9'
}

// iter_types: the iterable `iter` written on line ni: its kind and the loop variables' types.
iter_types :: proc(app: ^App, ni: int, iter: string) -> (k: Iter_Kind, v1, v2: Var_Type) {
	s := strings.trim_space(iter)
	if s == "" do return .Unknown, {}, {}
	int_t := Var_Type{"int", ""}
	at := top_index(s, "..<")
	if at < 0 do at = top_index(s, "..=")
	if at >= 0 {
		lo := strings.trim_space(s[:at])
		vt := int_t
		if !is_int_literal(lo) {
			if t, ok := expr_type_at(app, ni, lo); ok && t.expr != "" do vt = t
		}
		return .Range, vt, int_t
	}
	if s[0] == '"' || s[0] == '`' do return .String, Var_Type{"rune", ""}, int_t
	t, ok := expr_type_at(app, ni, s)
	if !ok do return .Unknown, {}, {}
	return iter_info(app, t)
}

// The kind of the loop's iterable (Unknown while it's a dot).
@(private = "file")
hdr_iter_kind :: proc(app: ^App, ni: int, h: Loop_Hdr) -> Iter_Kind {
	n := app.doc.nodes[ni]
	if h.form != .In do return .Unknown
	if range_op_in(n, h.iter_a, h.iter_b) >= 0 do return .Range
	b := strings.builder_make(context.temp_allocator)
	for f in n.fields[h.iter_a:h.iter_b] {
		if f.slot do return .Unknown
		strings.write_string(&b, f.text)
	}
	k, _, _ := iter_types(app, ni, strings.to_string(b))
	return k
}

// ---- Scopes: loop variables, labels, break / continue ----

// loop_header_declares (var_types.odin): line j is a loop header (or a labeled
// block): `name` is one of its loop variables, with its type, when the line
// being looked from is inside the loop (in_scope). is_hdr = it's such a line
// (it declares nothing else).
loop_header_declares :: proc(app: ^App, j: int, name: string, in_scope: bool) -> (t: Var_Type, found: bool, is_hdr: bool) {
	txt := strings.trim_space(strip_comment(node_text(app.doc.nodes[j], context.temp_allocator)))
	lt, ok := loop_text(txt)
	if !ok {
		lbl, rest := split_label(txt)
		return {}, false, lbl != "" && rest == "{"
	}
	if !in_scope do return {}, false, true
	#partial switch lt.form {
	case .In:
		for v, i in lt.vars[:lt.nvars] {
			if v != name do continue
			_, v1, v2 := iter_types(app, j, lt.iter)
			return i == 0 ? v1 : v2, true, true
		}
	case .CStyle:
		return init_declares(app, j, lt.init, name)
	}
	return {}, false, true
}

// `i := 0`, `i, j := 0, 10`, `i: int = 0` in a C-style init.
@(private = "file")
init_declares :: proc(app: ^App, j: int, init, name: string) -> (Var_Type, bool, bool) {
	op := top_index(init, ":=")
	typed := false
	if op < 0 {
		op = top_index(init, ":")
		typed = true
	}
	if op <= 0 do return {}, false, true
	names := strings.split(init[:op], ",", context.temp_allocator)
	idx := -1
	for nm, i in names do if strings.trim_space(nm) == name { idx = i; break }
	if idx < 0 do return {}, false, true
	if typed {
		ty := init[op + 1:]
		if eq := strings.index_byte(ty, '='); eq >= 0 do ty = ty[:eq]
		return Var_Type{strings.trim_space(ty), ""}, true, true
	}
	values := split_top_level(init[op + 2:])
	if idx < len(values) {
		v := strings.trim_space(values[idx])
		if is_int_literal(v) do return Var_Type{"int", ""}, true, true
		t, _ := expr_type_at(app, j, v)
		return t, true, true
	}
	return {}, true, true
}

// loop_name_visible (ref_pick.odin): a loop variable is only offered for a dot
// inside its loop (a C-style loop's own condition / post too).
loop_name_visible :: proc(app: ^App, ni, fi, tni, tfi: int) -> bool {
	h, ok := loop_hdr(app.doc.nodes[ni])
	if !ok do return true
	declares := false
	#partial switch h.form {
	case .In:     declares = fi == h.var1 || fi == h.var2
	case .CStyle: declares = (fi >= h.init_a && fi < h.init_b) || (fi >= h.post_a && fi < h.post_b)
	}
	if !declares do return true
	if tni == ni do return h.form == .CStyle && tfi > h.semi1
	return tni > ni && tni <= loop_block_end(app, ni)
}

// ref_target: the dot a Reference is being picked for.
ref_target :: proc(app: ^App) -> (ni, fi: int) {
	if app.ref_pick_active do return app.ref_ni, app.ref_fi
	return app.slot_ni, app.slot_fi
}

Scope_Label :: struct {
	name:    string,
	is_loop: bool,
}

Jump_Scope :: struct {
	in_loop, in_switch: bool,
	labels:             []Scope_Label, // innermost first
}

// jump_scope: the statements enclosing line ni (inside its procedure): is it
// in a loop / a switch, and the labels break / continue can name there.
jump_scope :: proc(app: ^App, ni: int) -> Jump_Scope {
	stack := make([dynamic]int, 0, 16, context.temp_allocator)
	for i in 0 ..< min(ni, len(app.doc.nodes)) {
		for c in line_brace_seq(node_text(app.doc.nodes[i], context.temp_allocator)) {
			if c == '{' do append(&stack, i)
			else if len(stack) > 0 do pop(&stack)
		}
	}
	out: Jump_Scope
	labels := make([dynamic]Scope_Label, 0, 4, context.temp_allocator)
	for k := len(stack) - 1; k >= 0; k -= 1 {
		t := strings.trim_space(strip_comment(node_text(app.doc.nodes[stack[k]], context.temp_allocator)))
		if strings.contains(t, "proc(") || strings.contains(t, "proc \"") || strings.contains(t, ":: proc") do break
		lbl, rest := split_label(t)
		_, is_loop := loop_text(t)
		is_switch := strings.has_prefix(rest, "switch") || strings.has_prefix(rest, "#partial switch")
		out.in_loop ||= is_loop
		out.in_switch ||= is_switch
		if lbl != "" do append(&labels, Scope_Label{lbl, is_loop})
	}
	out.labels = labels[:]
	return out
}

// A fresh name for a new loop variable / label at line ni: base, else the
// next of `alts`, else base_2, base_3, ...
@(private = "file")
fresh_name :: proc(app: ^App, ni: int, base: string, alts: []string = nil, label := false) -> string {
	taken :: proc(app: ^App, ni: int, name: string, label: bool) -> bool {
		if label do return proc_has_label(app, ni, name) // unique per procedure (label_refs.odin)
		_, ok := var_type_at(app, ni, name)
		if ok do return true
		// Names on the line itself (a second loop variable next to the first).
		if ni < len(app.doc.nodes) do for f in app.doc.nodes[ni].fields do if f.editable && f.text == name do return true
		return false
	}
	if !taken(app, ni, base, label) do return base
	for a in alts do if !taken(app, ni, a, label) do return a
	for k in 2 ..< 100 {
		c := fmt.tprintf("%s_%d", base, k)
		if !taken(app, ni, c, label) do return c
	}
	return base
}

// ---- The statement menu ----

loop_menu_entries :: proc() -> []Entry {
	return make_slice(
		Entry{label = "For (condition)", fill = "__loop_for__"},
		Entry{label = "For (C-style)", fill = LOOP_CSTYLE_FILL},
		Entry{label = "For (infinite)", fill = "__loop_forinf__"},
		Entry{label = "For ... in", fill = "__loop_forin__"},
		Entry{label = "For x, i in", fill = LOOP_IN2_FILL},
		Entry{label = "For i in 0..<n", fill = LOOP_RANGE_FILL},
		Entry{label = "For i in 0..=n", fill = LOOP_RANGE_INCL_FILL},
		Entry{label = "For &x in", fill = LOOP_BYREF_FILL},
		Entry{label = "#reverse for", fill = LOOP_REVERSE_FILL},
		Entry{label = "#unroll for", fill = LOOP_UNROLL_FILL},
		Entry{label = "Labeled for", fill = LOOP_LABELED_FILL},
	)
}

// The Assignment group: `x = ●`, Implicit Context (`context.logger = ●`) and
// the compound operators `x += ●`, ...
assign_menu_entries :: proc() -> []Entry {
	out := make([]Entry, len(ASSIGN_OPS) + 1)
	out[0] = Entry{label = "Assignment", fill = "__stmt_assign__"}
	out[1] = Entry{label = "Implicit Context", children = context_field_entries()}
	for op, i in ASSIGN_OPS[1:] do out[i + 2] = Entry{label = op, fill = ASSIGN_OP_FILL, call_name = strings.clone(op)}
	return out
}

// The fields of runtime.Context you can assign (`_internal` and other `_`
// fields are the runtime's own): "logger   Logger" -> context.logger = ●.
context_field_entries :: proc() -> []Entry {
	out := make([dynamic]Entry, 0, 8)
	defer delete(out)
	for f in CORE_FIELDS {
		if f.path != "base:runtime" || f.type_name != "Context" || strings.has_prefix(f.name, "_") do continue
		append(&out, Entry{
			label = fmt.aprintf("%s   %s", f.name, f.type), owned_label = true,
			fill = CTX_ASSIGN_FILL, call_name = strings.clone(f.name),
			ret = f.type, ret_pkg = f.path, // static table strings: they become the value dot's hint
		})
	}
	result := make([]Entry, len(out))
	copy(result, out[:])
	return result
}

is_loop_fill :: proc(fill: string) -> bool {
	switch fill {
	case "__loop_for__", "__loop_forin__", "__loop_forinf__", LOOP_CSTYLE_FILL, LOOP_IN2_FILL, LOOP_RANGE_FILL,
	     LOOP_RANGE_INCL_FILL, LOOP_BYREF_FILL, LOOP_REVERSE_FILL, LOOP_UNROLL_FILL, LOOP_LABELED_FILL,
	     LOOP_ITER_RANGE_FILL, LOOP_JUMP_FILL, ASSIGN_OP_FILL, CTX_ASSIGN_FILL, "__jmp_break__", "__jmp_continue__":
		return true
	}
	return false
}

// loop_fill: the fill dispatch for the fills above (the slot at slot_ni / slot_fi).
loop_fill :: proc(app: ^App, e: Entry) {
	ni, fi := app.slot_ni, app.slot_fi
	if ni < 0 || ni >= len(app.doc.nodes) || fi < 0 || fi >= len(app.doc.nodes[ni].fields) do return
	switch e.fill {
	case ASSIGN_OP_FILL:       make_assign_op_statement(app, ni, fi, e.call_name)
	case CTX_ASSIGN_FILL:      make_ctx_assign_statement(app, ni, fi, e.call_name, e.ret, e.ret_pkg)
	case LOOP_ITER_RANGE_FILL: make_slot_range(app, ni, fi, e.call_name == "..=")
	case "__jmp_break__":      make_jump(app, ni, fi, "break")
	case "__jmp_continue__":   make_jump(app, ni, fi, "continue")
	case LOOP_JUMP_FILL:       make_jump(app, ni, fi, e.call_name)
	case:                      make_loop(app, ni, fi, e.fill)
	}
}

// Replace the statement dot at (ni, fi) with `header`, then the body line, the
// closing brace and a statement line after the block.
@(private = "file")
inject_block :: proc(app: ^App, ni, fi: int, header: []Field) {
	indent := get_body_indent(app, ni)
	defer delete(indent)
	inner := strings.concatenate({indent, indent == "" ? "    " : indent_unit(indent)}, context.temp_allocator)
	fields := &app.doc.nodes[ni].fields
	if len(fields[fi].text) > 0 do delete(fields[fi].text)
	ordered_remove(fields, fi)
	inject_at(fields, fi, ..header)
	body, close, next: Node
	append(&body.fields, fx(inner), Field{"", false, true, "body", "", ""})
	append(&close.fields, fx(indent), fx("}"))
	append(&next.fields, fx(indent), Field{"", false, true, "body", "", ""})
	inject_at(&app.doc.nodes, ni + 1, body, close, next)
}

// A statement line after a one-line statement at ni (dropped again when inserted at a green dot).
@(private = "file")
add_next_line :: proc(app: ^App, ni: int, indent: string) {
	nb: Node
	append(&nb.fields, fx(indent), Field{"", false, true, "body", "", ""})
	inject_at(&app.doc.nodes, ni + 1, nb)
}

// make_loop: a loop statement of `kind` (a Loops fill) at the statement dot (ni, fi).
make_loop :: proc(app: ^App, ni, fi: int, kind: string) {
	h := make([dynamic]Field, 0, 16, context.temp_allocator)
	iter := -1 // the iterable dot's index in h
	range_kind := 0 // 1 = ..<, 2 = ..=
	item :: proc(app: ^App, ni: int) -> string { return fresh_name(app, ni, "item") }
	switch kind {
	case "__loop_for__":
		append(&h, fkw("for"), fx(" "), fdot("bool"), fx(" {"))
	case "__loop_forinf__":
		append(&h, fkw("for"), fx(" {"))
	case LOOP_CSTYLE_FILL:
		v := fresh_name(app, ni, "i", []string{"j", "k"})
		append(&h, fkw("for"), fx(" "), fname(v), fx(" := "), fname("0"), fx("; "),
			fx(v), fx(" < "), fdot("int"), fx("; "), fname(v), fop("+="), fname("1"), fx(" {"))
	case "__loop_forin__":
		append(&h, fkw("for"), fx(" "), fname(item(app, ni)), fx(" in "))
		iter = len(h)
		append(&h, fdot(), fx(" {"))
	case LOOP_IN2_FILL:
		append(&h, fkw("for"), fx(" "), fname(item(app, ni)), fx(", "), fname(fresh_name(app, ni, "index")), fx(" in "))
		iter = len(h)
		append(&h, fdot(), fx(" {"))
	case LOOP_RANGE_FILL, LOOP_RANGE_INCL_FILL, LOOP_UNROLL_FILL:
		if kind == LOOP_UNROLL_FILL do append(&h, fkw("#unroll"), fx(" "))
		append(&h, fkw("for"), fx(" "), fname(fresh_name(app, ni, "i", []string{"j", "k"})), fx(" in "))
		iter = len(h)
		append(&h, fdot(), fx(" {"))
		range_kind = kind == LOOP_RANGE_INCL_FILL ? 2 : 1
	case LOOP_BYREF_FILL:
		append(&h, fkw("for"), fx(" "), fx("&"), fname(item(app, ni)), fx(" in "))
		iter = len(h)
		append(&h, fdot(), fx(" {"))
	case LOOP_REVERSE_FILL:
		append(&h, fkw("#reverse"), fx(" "), fkw("for"), fx(" "), fname(item(app, ni)), fx(" in "))
		iter = len(h)
		append(&h, fdot(), fx(" {"))
	case LOOP_LABELED_FILL:
		append(&h, flabel(fresh_name(app, ni, "outer", label = true)), fx(": "), fkw("for"), fx(" "), fname(item(app, ni)), fx(" in "))
		iter = len(h)
		append(&h, fdot(), fx(" {"))
	case:
		return
	}
	inject_block(app, ni, fi, h[:])
	if range_kind > 0 {
		it := fi + iter
		make_slot_range(app, ni, it, range_kind == 2)
		fields := &app.doc.nodes[ni].fields
		if it < len(fields) && fields[it].slot do fields[it] = fname("0") // lo = 0
		for k in it + 1 ..< len(fields) do if fields[k].slot { fields[k].hint = "int"; break }
	}
}

// `break` / `continue` [label] at the statement dot (ni, fi).
make_jump :: proc(app: ^App, ni, fi: int, text: string) {
	indent := get_body_indent(app, ni)
	defer delete(indent)
	fields := &app.doc.nodes[ni].fields
	if len(fields[fi].text) > 0 do delete(fields[fi].text)
	ordered_remove(fields, fi)
	sp := strings.index_byte(text, ' ')
	if sp < 0 {
		inject_at(fields, fi, fkw(text))
	} else {
		inject_at(fields, fi, fkw(text[:sp]), fx(" "), fx(text[sp + 1:]))
	}
	add_next_line(app, ni, indent)
}

// `name op= ●` at the statement dot (ni, fi).
make_assign_op_statement :: proc(app: ^App, ni, fi: int, op: string) {
	indent := get_body_indent(app, ni)
	defer delete(indent)
	fields := &app.doc.nodes[ni].fields
	if len(fields[fi].text) > 0 do delete(fields[fi].text)
	ordered_remove(fields, fi)
	inject_at(fields, fi, fname(""), fop(op), fdot()) // the target is picked next (assign_pick_start)
	add_next_line(app, ni, indent)
}

// make_ctx_assign_statement: `context.<field> = ●`, the value dot expecting the
// field's type (written in base:runtime: Logger, Allocator, ...). The target is
// one editable field, as the loader makes it (field_access.odin).
@(private = "file")
make_ctx_assign_statement :: proc(app: ^App, ni, fi: int, field, type, pkg: string) {
	indent := get_body_indent(app, ni)
	defer delete(indent)
	fields := &app.doc.nodes[ni].fields
	if len(fields[fi].text) > 0 do delete(fields[fi].text)
	ordered_remove(fields, fi)
	target := strings.concatenate({"context.", field}, context.temp_allocator)
	inject_at(fields, fi, fname(target), fop("="), Field{"", false, true, "value", type, pkg})
	add_next_line(app, ni, indent)
}

// loop_extend_body_menu: the Jumps group's Break / Continue are grayed where
// they can't go, and offer `break outer` / `continue outer` for the labels in scope.
loop_extend_body_menu :: proc(app: ^App, ni: int) {
	sc := jump_scope(app, ni)
	for &g in app.slot_menu {
		if g.label != "Jumps and cleanup" do continue
		out := make([dynamic]Entry, 0, len(g.children) + 2 * len(sc.labels))
		defer delete(out)
		for e in g.children {
			e := e
			switch e.fill {
			case "__jmp_break__":
				e.dim = !(sc.in_loop || sc.in_switch)
				append(&out, e)
				for l in sc.labels {
					append(&out, Entry{label = fmt.aprintf("Break %s", l.name), owned_label = true, fill = LOOP_JUMP_FILL, call_name = fmt.aprintf("break %s", l.name)})
				}
			case "__jmp_continue__":
				e.dim = !sc.in_loop
				append(&out, e)
				for l in sc.labels do if l.is_loop {
					append(&out, Entry{label = fmt.aprintf("Continue %s", l.name), owned_label = true, fill = LOOP_JUMP_FILL, call_name = fmt.aprintf("continue %s", l.name)})
				}
			case:
				append(&out, e)
			}
		}
		delete(g.children)
		g.children = make([]Entry, len(out))
		copy(g.children, out[:])
	}
}

// ---- The iterable dot ----

// Is (ni, fi) the iterable dot of a for-in loop?
is_iterable_dot :: proc(n: Node, fi: int) -> bool {
	h, ok := loop_hdr(n)
	return ok && h.form == .In && h.iter_b - h.iter_a == 1 && fi == h.iter_a && n.fields[fi].slot
}

@(private = "file")
has_fill :: proc(entries: []Entry, fill: string) -> bool {
	for e in entries {
		if e.fill == fill do return true
		if has_fill(e.children, fill) do return true
	}
	return false
}

// loop_extend_value_menu: on a loop's iterable dot, the value menu gets "Range"
// and everything that can't be iterated (by this loop) is grayed.
loop_extend_value_menu :: proc(app: ^App, ni, fi: int) {
	n := app.doc.nodes[ni]
	defer unroll_extend_value_menu(app, ni, fi) // #unroll: constants only (loop_unroll.odin)
	if !is_iterable_dot(n, fi) do return
	// "Range" (a ..< b / a ..= b) is the shared entry from range_fill.odin;
	// iter_dims below grays it when this loop can't iterate a range.
	insert_range_entry(app, Resolved_Type{})
	h, _ := loop_hdr(n)
	iter_dims(app, n, h, app.slot_menu)
}

// iter_allowed: can this loop iterate a value of kind k? `&item` needs
// addressable elements (not a string's, a range's or a map's keys), `&index` /
// `&value` only a map's value; #reverse not over maps / ranges; #unroll only
// over constant ranges, arrays and constant strings.
iter_allowed :: proc(n: Node, h: Loop_Hdr, k: Iter_Kind) -> bool {
	if k == .None do return false
	if k == .Unknown do return true
	if h.ref1 >= 0 && (k == .String || k == .Range || k == .Map) do return false
	if h.ref2 >= 0 && k != .Map do return false
	if h.directive >= 0 {
		switch n.fields[h.directive].text {
		case "#reverse": if k == .Range || k == .Map do return false
		case "#unroll":  if k == .Slice || k == .Dynamic || k == .Map do return false
		}
	}
	return true
}

@(private = "file")
iter_dims :: proc(app: ^App, n: Node, h: Loop_Hdr, entries: []Entry) -> (any_fit: bool) {
	for &e in entries {
		if len(e.children) > 0 {
			f := iter_dims(app, n, h, e.children)
			e.dim = !f
			any_fit ||= f
			continue
		}
		if e.fill == "" do continue
		f := iter_allowed(n, h, entry_iter_kind(app, e))
		e.dim = !f
		any_fit ||= f
	}
	return
}

// How a type iterates (None: it can't).
@(private = "file")
type_iter_kind :: proc(app: ^App, ret, pkg: string) -> Iter_Kind {
	r := strings.trim_space(ret)
	if ret == RET_UNKNOWN || r == "?" do return .Unknown
	if r == "" || strings.has_prefix(r, "(") do return .None
	k, _, _ := iter_info(app, Var_Type{r, pkg})
	return k
}

// What a value-menu leaf would put in the iterable (None: nothing iterable).
@(private = "file")
entry_iter_kind :: proc(app: ^App, e: Entry) -> Iter_Kind {
	switch e.fill {
	case "__lit_str__", "__lit_rawstr__":         return .String
	case LOOP_ITER_RANGE_FILL, RANGE_FILL:         return .Range
	case "__lit_ref__", "__call_import__":         return .Unknown // a name / an unknown proc: can't tell yet
	case CONST_IMPORT_FILL:
		switch e.ret {
		case "?", "":   return .Unknown
		case "#string": return .String
		}
		if strings.has_prefix(e.ret, "#") do return .None
		return type_iter_kind(app, e.ret, e.ret_pkg)
	case "__call_import_proc__":
		return type_iter_kind(app, e.ret, e.ret_pkg)
	case "__call_this_pkg__":
		sig := call_signature(app, "", e.call_name)
		return type_iter_kind(app, sig.ret, "")
	case BUILTIN_CONST_FILL:
		b, ok := builtin_const(e.call_name)
		if !ok do return .Unknown
		return b.cat == .String ? .String : .None
	}
	return .None // numbers, bools, nil, operators, enum values, struct literals, types
}

// loop_pass_as_dims (ref_pick.odin): "Pass as" for a loop's iterable: the name
// itself only when it can be iterated; no pointers.
loop_pass_as_dims :: proc(app: ^App, pick: Ref_Target, out: []Entry) {
	defer unroll_pass_as_dims(app, pick, out) // #unroll: constants only (loop_unroll.odin)
	if !is_iterable_dot(app.doc.nodes[app.ref_ni], app.ref_fi) do return
	name := app.doc.nodes[pick.ni].fields[pick.fi].text
	t, ok := var_type_at(app, app.ref_ni, name)
	k := Iter_Kind.Unknown
	if ok do k, _, _ = iter_info(app, t)
	deref := Iter_Kind.Unknown
	if ok {
		s := strings.trim_space(t.expr)
		if strings.has_prefix(s, "^") do deref, _, _ = iter_info(app, Var_Type{s[1:], t.pkg})
		else do deref = .None
	}
	n := app.doc.nodes[app.ref_ni]
	h, _ := loop_hdr(n)
	for &e in out {
		if e.fill != REF_AS_FILL do continue
		switch {
		case e.call_name == name:                 e.dim = !iter_allowed(n, h, k)
		case strings.has_prefix(e.call_name, "&"): e.dim = true
		case strings.has_suffix(e.call_name, "^"): e.dim = !iter_allowed(n, h, deref)
		}
	}
}

// ---- Y ----

// loop_change: Y on a part of a loop / an assignment operator / break / continue.
// True when handled.
loop_change :: proc(app: ^App, ni: int, u: Unit) -> bool {
	if u.fb - u.fa != 1 do return false
	n := app.doc.nodes[ni]
	fi := u.fa
	f := n.fields[fi]
	if !f.slot && f.kind == ASSIGN_OP_KIND {
		open_assign_op_menu(app, ni, fi)
		return true
	}
	if is_jump_kw(f) {
		open_jump_menu(app, ni, fi)
		return true
	}
	if lb, ok := labeled_block(n); ok && fi == lb {
		open_loop_options(app, ni, fi)
		return true
	}
	h, ok := loop_hdr(n)
	if !ok do return false
	switch {
	case fi == h.kw || fi == h.directive || fi == h.label:
		open_loop_options(app, ni, fi)
		return true
	case h.form == .In && (fi == h.var1 || fi == h.var2):
		toggle_by_ref(app, ni, fi)
		return true
	}
	return false
}

// Which loop variable can be `&`: the element (a map's value), and only when
// the iterable allows it. -1 = none.
@(private = "file")
ref_var :: proc(app: ^App, ni: int, h: Loop_Hdr) -> int {
	if h.form != .In || (h.directive >= 0 && app.doc.nodes[ni].fields[h.directive].text == "#unroll") do return -1
	switch hdr_iter_kind(app, ni, h) {
	case .String, .Range, .None: return -1
	case .Map:                   return h.var2
	case .Unknown, .Array, .Slice, .Dynamic:
	}
	return h.var1
}

@(private = "file")
toggle_by_ref :: proc(app: ^App, ni, fi: int) {
	h, ok := loop_hdr(app.doc.nodes[ni])
	if !ok do return
	fields := &app.doc.nodes[ni].fields
	has := (fi == h.var1 && h.ref1 >= 0) || (fi == h.var2 && h.ref2 >= 0)
	if has {
		del_fields(fields, fi - 1, fi)
		focus_field_index(app, ni, fi - 1)
		return
	}
	if fi != ref_var(app, ni, h) do return
	inject_at(fields, fi, fx("&"))
	focus_field_index(app, ni, fi + 1)
}

@(private = "file")
option :: proc(out: ^[dynamic]Entry, ni, fi: int, label, id: string, dim := false) {
	append(out, Entry{label = strings.clone(label), owned_label = true, fill = LOOP_OPT_FILL, call_name = strings.clone(id),
		call_pkg = fmt.aprintf("%d %d", ni, fi), dim = dim})
}

@(private = "file")
open_options_menu :: proc(app: ^App, title: string, out: []Entry) {
	if app.slot_menu != nil do free_entries(app.slot_menu)
	app.slot_menu = make([]Entry, len(out))
	copy(app.slot_menu, out)
	clear_nav(app)
	app.return_state = .Editor
	app.state = .Radial
	push_menu(app, title, app.slot_menu)
}

// The loop's options (Y on `for`, its directive or its label).
open_loop_options :: proc(app: ^App, ni, fi: int) {
	n := app.doc.nodes[ni]
	out := make([dynamic]Entry, 0, 12)
	defer delete(out)
	if lb, ok := labeled_block(n); ok {
		option(&out, ni, fi, "Remove label", "label-", label_removal_blocked(app, ni, n.fields[lb].text))
		open_options_menu(app, "Labeled block", out[:])
		return
	}
	h, ok := loop_hdr(n)
	if !ok do return
	if h.label >= 0 do option(&out, ni, fi, "Remove label", "label-", label_removal_blocked(app, ni, n.fields[h.label].text))
	else do option(&out, ni, fi, "Add label", "label+")
	switch h.form {
	case .Infinite:
		option(&out, ni, fi, "Add condition", "cond+")
	case .Cond:
		option(&out, ni, fi, "Change condition", "cond")
		option(&out, ni, fi, "Remove condition", "cond-")
	case .CStyle:
		if h.init_b > h.init_a do option(&out, ni, fi, "Remove init", "init-")
		else do option(&out, ni, fi, "Add init", "init+")
		if h.cond_b > h.cond_a {
			option(&out, ni, fi, "Change condition", "cond")
			option(&out, ni, fi, "Remove condition", "cond-")
		} else {
			option(&out, ni, fi, "Add condition", "cond+")
		}
		if h.post_b > h.post_a do option(&out, ni, fi, "Remove post", "post-")
		else do option(&out, ni, fi, "Add post", "post+")
	case .In:
		k := hdr_iter_kind(app, ni, h)
		dir := h.directive >= 0 ? n.fields[h.directive].text : ""
		any_ref := h.ref1 >= 0 || h.ref2 >= 0
		if dir == "#reverse" do option(&out, ni, fi, "Remove #reverse", "dir-")
		else do option(&out, ni, fi, "Add #reverse", "rev+", k == .Range || k == .Map || k == .None)
		if dir == "#unroll" do option(&out, ni, fi, "Remove #unroll", "dir-")
		else do option(&out, ni, fi, "Add #unroll", "unroll+", k == .Slice || k == .Dynamic || k == .Map || k == .None || any_ref ||
			((k == .Range || k == .String) && !unroll_iter_const(app, ni, h))) // constants only (loop_unroll.odin)
		if h.var2 >= 0 do option(&out, ni, fi, "Remove 2nd variable", "var2-")
		else do option(&out, ni, fi, "Add 2nd variable", "var2+")
		if any_ref do option(&out, ni, fi, "By value", "ref")
		else do option(&out, ni, fi, "By reference", "ref", ref_var(app, ni, h) < 0)
		option(&out, ni, fi, "Change iterable", "iter")
	}
	open_options_menu(app, "Loop", out[:])
}

// Y on an assignment's operator: the other operators.
open_assign_op_menu :: proc(app: ^App, ni, fi: int) {
	cur := strings.trim_space(app.doc.nodes[ni].fields[fi].text)
	out := make([dynamic]Entry, 0, len(ASSIGN_OPS))
	defer delete(out)
	cat := Type_Cat.Unknown // the target's: operators it can't take are dimmed (assign_ops.odin)
	if fi > 0 do cat = assign_target_cat(app, ni, app.doc.nodes[ni].fields[fi - 1].text)
	for op in ASSIGN_OPS do option(&out, ni, fi, op, fmt.tprintf("op:%s", op), op == cur || !assign_op_fits(op, cat))
	open_options_menu(app, "Operator", out[:])
}

// Y on break / continue: with which label (those in scope).
open_jump_menu :: proc(app: ^App, ni, fi: int) {
	word := app.doc.nodes[ni].fields[fi].text
	sc := jump_scope(app, ni)
	out := make([dynamic]Entry, 0, 4)
	defer delete(out)
	option(&out, ni, fi, word, fmt.tprintf("jump:%s", word))
	for l in sc.labels {
		if word == "continue" && !l.is_loop do continue
		t := fmt.tprintf("%s %s", word, l.name)
		option(&out, ni, fi, t, fmt.tprintf("jump:%s", t))
	}
	open_options_menu(app, word, out[:])
}

// An option was chosen (menu_select).
loop_option_choose :: proc(app: ^App, e: Entry) {
	if e.dim do return // not possible here: the menu stays open
	id := strings.clone(e.call_name, context.temp_allocator)
	parts := strings.fields(e.call_pkg, context.temp_allocator)
	ni, fi := -1, -1
	if len(parts) == 2 {
		if v, vok := strconv.parse_int(parts[0]); vok do ni = v
		if v, vok := strconv.parse_int(parts[1]); vok do fi = v
	}
	clear_nav(app)
	if app.slot_menu != nil {
		free_entries(app.slot_menu)
		app.slot_menu = nil
	}
	app.state = .Editor
	if ni < 0 || ni >= len(app.doc.nodes) || fi < 0 || fi >= len(app.doc.nodes[ni].fields) do return
	switch {
	case strings.has_prefix(id, "op:"):   set_assign_op(app, ni, fi, id[3:])
	case strings.has_prefix(id, "jump:"): set_jump(app, ni, fi, id[5:])
	case:                                 loop_apply(app, ni, fi, id)
	}
}

@(private = "file")
set_assign_op :: proc(app: ^App, ni, fi: int, op: string) {
	fields := &app.doc.nodes[ni].fields
	if fields[fi].kind != ASSIGN_OP_KIND do return
	if len(fields[fi].text) > 0 do delete(fields[fi].text)
	fields[fi].text = fmt.aprintf(" %s ", op)
	// An empty value dot: a shift amount is any integer; otherwise the target's type.
	if fi + 2 == len(fields) && fields[fi + 1].slot && fields[fi + 1].kind == "value" && fi > 0 {
		v := &fields[fi + 1]
		v.hint, v.hint_pkg = "", ""
		if op != "<<=" && op != ">>=" {
			if t, ok := expr_type_at(app, ni, fields[fi - 1].text); ok && t.expr != "" {
				if t.pkg == "" do v.hint = intern_hint(app, t.expr)
				else do v.hint, v.hint_pkg = intern_hint(app, t.expr), intern_hint(app, t.pkg) // t.pkg can be per-frame (var_types.odin)
			}
		}
	}
	focus_field_index(app, ni, fi)
}

@(private = "file")
set_jump :: proc(app: ^App, ni, fi: int, text: string) {
	fields := &app.doc.nodes[ni].fields
	if !is_jump_kw(fields[fi]) do return
	end := len(fields)
	del_fields(fields, fi + 1, end)
	if sp := strings.index_byte(text, ' '); sp >= 0 do inject_at(fields, fi + 1, fx(" "), fx(text[sp + 1:]))
	focus_field_index(app, ni, fi)
}

// Refill fields [a, b) of line ni through a dot (B puts them back), like Y on an argument.
@(private = "file")
refill_region :: proc(app: ^App, ni, a, b: int, dot: Field) {
	refill_discard(app)
	fields := &app.doc.nodes[ni].fields
	for i in a ..< b do append(&app.refill_saved, fields[i]) // ownership moves to refill_saved
	remove_range(fields, a, b)
	inject_at(fields, a, dot)
	app.refill_active = true
	app.refill_ni = ni
	app.refill_fi = a
	focus_field_index(app, ni, a)
	open_slot_menu(app)
	if app.state != .Radial do refill_restore(app)
}

// loop_apply: a loop option (the line's structure is read again: it may have changed).
loop_apply :: proc(app: ^App, ni, fi: int, id: string) {
	n := app.doc.nodes[ni]
	fields := &app.doc.nodes[ni].fields
	if lb, ok := labeled_block(n); ok {
		if id == "label-" {
			if label_removal_blocked(app, ni, n.fields[lb].text) do return // a jump still needs it
			del_fields(fields, lb, lb + 2)
			inject_at(fields, lb, fx("{"))
			focus_line(app, ni)
		}
		return
	}
	h, ok := loop_hdr(n)
	if !ok do return
	switch id {
	case "label+":
		at := h.directive >= 0 ? h.directive : h.kw
		inject_at(fields, at, flabel(fresh_name(app, ni, "outer", label = true)), fx(": "))
		focus_field_index(app, ni, at)
	case "label-":
		if h.label < 0 do return
		name := strings.clone(n.fields[h.label].text, context.temp_allocator)
		if label_removal_blocked(app, ni, name) do return // a jump still needs it
		label_unname_jumps(app, ni, name) // `break outer` -> `break`
		del_fields(fields, h.label, h.label_sep + 1)
		focus_field_index(app, ni, h.label)
	case "rev+", "unroll+":
		d := id == "rev+" ? "#reverse" : "#unroll"
		if h.directive >= 0 {
			set_text(&fields[h.directive], d)
			focus_field_index(app, ni, h.directive)
		} else {
			inject_at(fields, h.kw, fkw(d), fx(" "))
			focus_field_index(app, ni, h.kw)
		}
	case "dir-":
		if h.directive < 0 do return
		del_fields(fields, h.directive, h.directive + 2)
		focus_field_index(app, ni, h.directive)
	case "var2+":
		if h.form != .In || h.var2 >= 0 do return
		base := hdr_iter_kind(app, ni, h) == .Map ? "value" : "index"
		inject_at(fields, h.in_sep, fx(", "), fname(fresh_name(app, ni, base)))
		focus_field_index(app, ni, h.in_sep + 1)
	case "var2-":
		if h.var2 < 0 do return
		del_fields(fields, h.vsep, h.var2 + 1)
		focus_field_index(app, ni, h.var1)
	case "ref":
		if h.form != .In do return
		switch {
		case h.ref2 >= 0: toggle_by_ref(app, ni, h.var2)
		case h.ref1 >= 0: toggle_by_ref(app, ni, h.var1)
		case:             if v := ref_var(app, ni, h); v >= 0 do toggle_by_ref(app, ni, v)
		}
	case "iter":
		if h.form == .In do refill_region(app, ni, h.iter_a, h.iter_b, fdot())
	case "cond":
		if h.cond_b > h.cond_a do refill_region(app, ni, h.cond_a, h.cond_b, fdot("bool"))
	case "cond-":
		remove_condition(app, ni, h)
	case "cond+":
		#partial switch h.form {
		case .Infinite:
			inject_at(fields, h.kw + 1, fx(" "), fdot("bool"))
			focus_field_index(app, ni, h.kw + 2)
		case .CStyle:
			if h.cond_b > h.cond_a do return
			inject_at(fields, h.cond_a, fdot("bool"))
			focus_field_index(app, ni, h.cond_a)
		}
	case "init+":
		if h.form != .CStyle || h.init_b > h.init_a do return
		v := ""
		if name, _, _, sok := part_split(n, h.post_a, h.post_b); sok do v = strings.clone(n.fields[name].text, context.temp_allocator) // the post's variable
		else do v = fresh_name(app, ni, "i", []string{"j", "k"})
		inject_at(fields, h.init_a, fname(v), fx(" := "), fname("0"))
		focus_field_index(app, ni, h.init_a)
	case "init-":
		if h.form != .CStyle do return
		del_fields(fields, h.init_a, h.init_b)
		focus_field_index(app, ni, h.kw)
	case "post+":
		if h.form != .CStyle || h.post_b > h.post_a do return
		v := "i"
		if name, _, _, sok := part_split(n, h.init_a, h.init_b); sok do v = n.fields[name].text
		v = strings.clone(v, context.temp_allocator)
		set_text(&fields[h.semi2], "; ")
		inject_at(fields, h.post_a, fname(v), fop("+="), fname("1"))
		focus_field_index(app, ni, h.post_a)
	case "post-":
		if h.form != .CStyle do return
		del_fields(fields, h.post_a, h.post_b)
		set_text(&fields[h.semi2], ";")
		focus_field_index(app, ni, h.kw)
	}
}

// The condition goes: a while loop becomes infinite; a C-style loop's part is left empty.
@(private = "file")
remove_condition :: proc(app: ^App, ni: int, h: Loop_Hdr) {
	fields := &app.doc.nodes[ni].fields
	#partial switch h.form {
	case .Cond:
		del_fields(fields, h.kw + 1, h.open) // " " and the condition
		focus_field_index(app, ni, h.kw)
	case .CStyle:
		del_fields(fields, h.cond_a, h.cond_b)
		focus_field_index(app, ni, h.kw)
	}
}

// ---- LT+B ----

// loop_delete: LT+B on part of a loop header. True when handled (on `for`
// itself it isn't: the whole loop goes, block_delete.odin).
loop_delete :: proc(app: ^App) -> bool {
	ni, fi, ok := editor_target(app)
	if !ok do return false
	n := app.doc.nodes[ni]
	fields := &app.doc.nodes[ni].fields
	if lb, lok := labeled_block(n); lok && fi == lb {
		loop_apply(app, ni, fi, "label-")
		return true
	}
	h, hok := loop_hdr(n)
	if !hok do return false
	in_region :: proc(fi, a, b: int) -> bool { return fi >= a && fi < b }
	switch {
	case fi == h.kw:
		return false
	case fi == h.label:
		loop_apply(app, ni, fi, "label-")
	case fi == h.directive:
		loop_apply(app, ni, fi, "dir-")
	case h.form == .In && fi == h.var2:
		loop_apply(app, ni, fi, "var2-")
	case h.form == .In && fi == h.var1:
		if h.var2 >= 0 {
			// The element isn't needed: `for _, index in ...`.
			if h.ref1 >= 0 do del_fields(fields, h.ref1, h.ref1 + 1)
			v := h.ref1 >= 0 ? h.ref1 : h.var1
			set_text(&fields[v], "_")
			focus_field_index(app, ni, v)
		}
	case h.form == .In && in_region(fi, h.iter_a, h.iter_b):
		if !(h.iter_b - h.iter_a == 1 && n.fields[h.iter_a].slot) {
			del_fields(fields, h.iter_a, h.iter_b)
			inject_at(fields, h.iter_a, fdot())
			focus_field_index(app, ni, h.iter_a)
		}
	case h.form == .Cond && in_region(fi, h.cond_a, h.cond_b):
		if h.cond_b - h.cond_a == 1 && n.fields[h.cond_a].slot {
			remove_condition(app, ni, h)
		} else {
			del_fields(fields, h.cond_a, h.cond_b)
			inject_at(fields, h.cond_a, fdot("bool"))
			focus_field_index(app, ni, h.cond_a)
		}
	case h.form == .CStyle && in_region(fi, h.init_a, h.init_b):
		loop_apply(app, ni, fi, "init-")
	case h.form == .CStyle && in_region(fi, h.cond_a, h.cond_b):
		loop_apply(app, ni, fi, "cond-")
	case h.form == .CStyle && in_region(fi, h.post_a, h.post_b):
		loop_apply(app, ni, fi, "post-")
	}
	return true
}

// ---- Selection ----

// loop_line_units (selection.odin line_units): a loop header's parts: label,
// directive, `for`, the loop variables, and each expression (Y refills it; a
// range's two ends separately).
loop_line_units :: proc(n: Node) -> ([]Unit, bool) {
	h, ok := loop_hdr(n)
	if !ok do return nil, false
	out := make([dynamic]Unit, 0, 8, context.temp_allocator)
	field :: proc(out: ^[dynamic]Unit, i: int) { if i >= 0 do append(out, Unit{fa = i, fb = i + 1, kind = .Field}) }
	expr :: proc(out: ^[dynamic]Unit, n: Node, a, b: int) {
		if b <= a do return
		if r := range_op_in(n, a, b); r >= 0 {
			kids := make([dynamic]Unit, 0, 2, context.temp_allocator)
			if r > a do append(&kids, parse_expr_arg(n, a, r))
			if b > r + 1 do append(&kids, parse_expr_arg(n, r + 1, b))
			append(out, Unit{a, b, .Group, kids[:], true, 0})
			return
		}
		append(out, parse_expr_arg(n, a, b))
	}
	part :: proc(out: ^[dynamic]Unit, n: Node, a, b: int) {
		if name, op, v, ok := part_split(n, a, b); ok {
			append(out, Unit{fa = name, fb = name + 1, kind = .Field})
			if n.fields[op].kind == ASSIGN_OP_KIND do append(out, Unit{fa = op, fb = op + 1, kind = .Field})
			expr(out, n, v, b)
			return
		}
		expr(out, n, a, b)
	}
	field(&out, h.label)
	field(&out, h.directive)
	field(&out, h.kw)
	switch h.form {
	case .Infinite:
	case .Cond:
		expr(&out, n, h.cond_a, h.cond_b)
	case .In:
		field(&out, h.var1)
		field(&out, h.var2)
		expr(&out, n, h.iter_a, h.iter_b)
	case .CStyle:
		part(&out, n, h.init_a, h.init_b)
		expr(&out, n, h.cond_a, h.cond_b)
		part(&out, n, h.post_a, h.post_b)
	}
	return out[:], true
}

// loop_expected (change.odin begin_refill): what a refilled part of a loop
// header expects: a condition is a bool; a C-style post value the target's type.
loop_expected :: proc(app: ^App, ni: int, u: Unit) -> (hint, pkg: string) {
	n := app.doc.nodes[ni]
	h, ok := loop_hdr(n)
	if !ok do return "", ""
	#partial switch h.form {
	case .Cond, .CStyle:
		if u.fa == h.cond_a && u.fb == h.cond_b do return "bool", ""
	}
	if h.form == .CStyle {
		if name, op, v, sok := part_split(n, h.post_a, h.post_b); sok && u.fa == v && u.fb == h.post_b {
			o := strings.trim_space(n.fields[op].text)
			if o == "<<=" || o == ">>=" do return "", ""
			if t, tok := expr_type_at(app, ni + 1, n.fields[name].text); tok && t.expr != "" {
				if t.pkg == "" do return intern_hint(app, t.expr), ""
				return t.expr, t.pkg
			}
		}
	}
	return "", ""
}

// is_loop_post_target (field_access.odin is_assign_target): the target of a C-style post.
is_loop_post_target :: proc(n: Node, fi: int) -> bool {
	h, ok := loop_hdr(n)
	if !ok || h.form != .CStyle do return false
	name, op, _, sok := part_split(n, h.post_a, h.post_b)
	return sok && name == fi && n.fields[op].kind == ASSIGN_OP_KIND
}

// loop_keeps_one_line (format.odin needs_break): a loop header and a compound
// assignment are saved on one line even when long (the loader reads them that way).
loop_keeps_one_line :: proc(n: Node) -> bool {
	if _, ok := loop_hdr(n); ok do return true
	for f in n.fields do if !f.slot && f.kind == ASSIGN_OP_KIND && strings.trim_space(f.text) != "=" do return true
	return false
}

// ---- HUD hint ----

loop_hint :: proc(app: ^App) -> string {
	if app.state != .Editor do return ""
	ni, fi, ok := editor_target(app)
	if !ok do return ""
	n := app.doc.nodes[ni]
	f := n.fields[fi]
	if !f.slot && f.kind == ASSIGN_OP_KIND do return "Y: change operator"
	if is_jump_kw(f) do return "Y: choose label    LT+B: delete"
	if lb, lok := labeled_block(n); lok && fi == lb {
		if label_removal_blocked(app, ni, n.fields[lb].text) do return "Y: options    (a jump needs the label: it stays)"
		return "Y: options    LT+B: remove label"
	}
	h, hok := loop_hdr(n)
	if !hok do return ""
	switch {
	case fi == h.kw:        return "Y: loop options    LT+B: delete loop"
	case fi == h.label:
		if label_removal_blocked(app, ni, n.fields[h.label].text) do return "Y: loop options    (a jump needs the label: it stays)"
		return "Y: loop options    LT+B: remove label"
	case fi == h.directive: return "Y: loop options    LT+B: remove it"
	case h.form == .In && fi == h.var2: return "Y: by reference on/off    LT+B: remove"
	case h.form == .In && fi == h.var1: return "Y: by reference on/off"
	}
	return ""
}

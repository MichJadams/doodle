package model

// Variable types and struct fields: "what is the type of this name here?" and
// "what fields does that type have?", read from the document text and the
// generated tables (CORE_TYPES, CORE_PROCS, CORE_FIELDS).
//
// A type is a type expression plus the package it is written in (the same
// convention as Field.hint / hint_pkg): {"win32.PAINTSTRUCT", ""} is written
// in this document (win32 = an import alias), {"RECT", "core:sys/windows"} is
// written inside that package.
//
// Where a name's type comes from (roughly scoped: names declared earlier in the
// same procedure at the same or an outer block level, its parameters, then the
// file-scope declarations):
//     window: win32.HWND                (a parameter)          -> win32.HWND
//     paint: win32.PAINTSTRUCT          (typed, no value)      -> win32.PAINTSTRUCT
//     result: win32.LRESULT = 0         (typed)                -> win32.LRESULT
//     wc := win32.WNDCLASSW{...}        (struct literal)       -> win32.WNDCLASSW
//     instance := win32.HINSTANCE(...)  (conversion)           -> win32.HINSTANCE
//     dc := win32.BeginPaint(...)       (call: its return type) -> HDC in core:sys/windows
//     p := &paint                       (address)              -> ^win32.PAINTSTRUCT
//     x := paint.rcPaint.left           (field path)           -> LONG in core:sys/windows
// Struct fields follow aliases / distinct types to a struct declaration
// (CORE_FIELDS rows, or a `Name :: struct {...}` in this document, including
// polymorphic `struct($T: typeid)` and `using` fields, whose fields are
// promoted). A pointer is dereferenced automatically (p.x works on ^T).

import "base:runtime"
import "core:strings"
import "core:sync"

Var_Type :: struct {
	expr: string, // type expression ("" = unknown)
	pkg:  string, // import path it is written in ("" = this document / builtin)
}

// One field of a struct type.
Struct_Field :: struct {
	name:     string,
	type:     Var_Type,
	promoted: bool, // reached through a `using` field
}

@(private = "file")
MAX_TYPE_DEPTH :: 10

// ---- Small text helpers ----

@(private = "file")
ident_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

// A qualified identifier: `name` or `pkg.Name` (no spaces).
@(private = "file")
is_qual_ident :: proc(s: string) -> bool {
	if s == "" do return false
	parts := strings.split(s, ".", context.temp_allocator)
	if len(parts) > 2 do return false
	for p in parts do if !is_ident(p) do return false
	return true
}

// The matching closer of the bracket at s[open] (strings skipped), or -1.
match_bracket :: proc(s: string, open: int) -> int {
	depth := 0
	quote: u8 = 0
	for k := open; k < len(s); k += 1 {
		c := s[k]
		if quote != 0 {
			if c == '\\' && quote != '`' { k += 1; continue }
			if c == quote do quote = 0
			continue
		}
		switch c {
		case '"', '\'', '`': quote = c
		case '(', '[', '{':  depth += 1
		case ')', ']', '}':
			depth -= 1
			if depth == 0 do return k
		}
	}
	return -1
}

// Text without a trailing `// comment` (strings respected).
strip_comment :: proc(s: string) -> string {
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
		case '/': if k + 1 < len(s) && s[k + 1] == '/' do return s[:k]
		}
	}
	return s
}

// Replace whole-word `from` with `to` in s (polymorphic parameter substitution).
@(private = "file")
replace_word :: proc(s, from, to: string) -> string {
	if from == "" || !strings.contains(s, from) do return s
	b := strings.builder_make(context.temp_allocator)
	k := 0
	for k < len(s) {
		if strings.has_prefix(s[k:], from) && (k == 0 || !ident_byte(s[k - 1])) &&
		   (k + len(from) >= len(s) || !ident_byte(s[k + len(from)])) {
			strings.write_string(&b, to)
			k += len(from)
			continue
		}
		strings.write_byte(&b, s[k])
		k += 1
	}
	return strings.to_string(b)
}

// ---- Packages ----

// The import path of a package reference used in package `pkg`: in this
// document an import alias / last path segment; inside a core package, a
// package whose last path segment is `ref` (best effort).
@(private = "file")
ref_path :: proc(app: ^App, ref, pkg: string) -> string {
	if pkg == "" {
		imports := collect_imports(app)
		defer delete(imports)
		for imp in imports do if imp.ref == ref do return strings.clone(imp.path, context.temp_allocator)
		return ""
	}
	if ref == "builtin" do return ""
	core := strings.concatenate({"core:", ref}, context.temp_allocator)
	base := strings.concatenate({"base:", ref}, context.temp_allocator)
	suffix := strings.concatenate({"/", ref}, context.temp_allocator)
	// core: and base: first, so a package whose path merely ends in "/runtime"
	// can't shadow base:runtime.
	for t in CORE_TYPES do if t.path == core || t.path == base do return t.path
	for t in CORE_TYPES do if strings.has_suffix(t.path, suffix) do return t.path
	return ""
}

// The document text `ref.Name` for type `name` declared in import path `path`
// (e.g. "win32.WNDCLASSW"), or "" when that package isn't imported.
doc_type_text :: proc(app: ^App, name, path: string) -> string {
	if path == "" do return name
	imports := collect_imports(app)
	defer delete(imports)
	for imp in imports do if imp.path == path do return strings.concatenate({imp.ref, ".", name}, context.temp_allocator)
	return ""
}

// ---- Document declarations ----

// The text of a top-level declaration `name :: ...` in the document: the
// lines from its header through the end of its block, joined with "\n" (after
// `::`). Not declared in the document: a type declared in another file of the
// package (siblings.odin), as the same text.
doc_decl_text :: proc(app: ^App, name: string) -> (string, bool) {
	text, _, ok := decl_text_src(app, name)
	return text, ok
}

// decl_text_src: doc_decl_text, plus the sibling file the text comes from (""
// = this document). Package references in a sibling's text are that file's
// (read them with sibling_type_here).
@(private = "file")
decl_text_src :: proc(app: ^App, name: string) -> (text, file: string, ok: bool) {
	pts := insertion_points(app, context.temp_allocator)
	for n, ni in app.doc.nodes {
		if !pts[ni] do continue
		t := strings.trim_space(node_text(n, context.temp_allocator))
		if !strings.has_prefix(t, name) do continue
		rest := strings.trim_left_space(t[len(name):])
		if !strings.has_prefix(rest, "::") do continue
		e := decl_block_end(app, ni) // (not construct_range: that takes a whole enclosing file-scope `when`)
		b := strings.builder_make(context.temp_allocator)
		for j in ni ..= e {
			if j > ni do strings.write_byte(&b, '\n')
			strings.write_string(&b, node_text(app.doc.nodes[j], context.temp_allocator))
		}
		s := strings.trim_space(strings.to_string(b))
		return strings.trim_space(strings.trim_left_space(s[len(name):])[2:]), "", true // after `::`
	}
	if st, found := sibling_type(app, name); found do return st.text, st.file, true
	return "", "", false
}

// The fields declared in a struct type text: `struct { a: int, b, c: f32 }`,
// `struct($T: typeid) #packed { ... }` (poly params substituted from `args`).
// `sib`: the sibling file the text was written in ("" = none): its field types
// are read from the open document's side (sibling_type_here).
@(private = "file")
fields_of_struct_text :: proc(app: ^App, text: string, pkg: string, args: []string, depth: int, out: ^[dynamic]Struct_Field, sib := "") -> bool {
	s := strings.trim_space(text)
	if !strings.has_prefix(s, "struct") do return false
	s = strings.trim_left_space(s[len("struct"):])
	params: []Param
	if strings.has_prefix(s, "(") {
		close := match_bracket(s, 0)
		if close < 0 do return false
		params = parse_params(s[1:close])
		s = s[close + 1:]
	}
	open := strings.index_byte(s, '{')
	if open < 0 do return false
	close := match_bracket(s, open)
	if close < 0 do return false
	body := s[open + 1:close]

	// One declaration per line or comma: strip comments, then split.
	b := strings.builder_make(context.temp_allocator)
	for line in strings.split_lines(body, context.temp_allocator) {
		strings.write_string(&b, strip_comment(line))
		strings.write_byte(&b, ',')
	}
	pending := make([dynamic]string, 0, 2, context.temp_allocator)
	for part in split_top_level(strings.to_string(b)) {
		p := strings.trim_space(part)
		using_field := false
		if strings.has_prefix(p, "using ") {
			using_field = true
			p = strings.trim_space(p[len("using "):])
		}
		for strings.has_prefix(p, "#") { // #subtype / #align(...) field directives
			sp := strings.index_byte(p, ' ')
			if sp < 0 { p = ""; break }
			p = strings.trim_space(p[sp:])
		}
		colon := strings.index_byte(p, ':')
		if colon < 0 {
			if is_ident(p) do append(&pending, p)
			continue
		}
		name := strings.trim_space(p[:colon])
		ty := strings.trim_space(p[colon + 1:])
		// A field tag after the type: `a: int "json:a"`.
		if len(ty) > 0 && (ty[len(ty) - 1] == '"' || ty[len(ty) - 1] == '`') {
			if q := strings.index_any(ty, "\"`"); q > 0 do ty = strings.trim_space(ty[:q])
		}
		for pa, i in params {
			if i < len(args) do ty = replace_word(ty, pa.name, args[i])
		}
		ft := sib != "" ? sibling_type_here(app, ty, sib) : Var_Type{ty, pkg}
		// `_` (padding, an anonymous `using _: T`) can't be named: never listed,
		// but a `using _` still promotes its fields.
		for pn in pending do if pn != "_" do append(out, Struct_Field{pn, ft, false})
		clear(&pending)
		if !is_ident(name) do continue
		if name != "_" do append(out, Struct_Field{name, ft, false})
		if using_field do append_promoted(app, ft, depth, out)
	}
	return true
}

@(private = "file")
append_promoted :: proc(app: ^App, t: Var_Type, depth: int, out: ^[dynamic]Struct_Field) {
	inner := make([dynamic]Struct_Field, 0, 8, context.temp_allocator)
	collect_fields(app, t, depth + 1, &inner)
	for f in inner do append(out, Struct_Field{f.name, f.type, true})
}

// ---- Fields of a type ----

// struct_fields: the fields of type `t` (following aliases, distinct types and
// one pointer level to a struct). Temp-allocated; nil when it isn't a struct
// Doodle knows.
struct_fields :: proc(app: ^App, t: Var_Type) -> []Struct_Field {
	out := make([dynamic]Struct_Field, 0, 8, context.temp_allocator)
	collect_fields(app, t, 0, &out)
	if len(out) == 0 do return nil
	return out[:]
}

@(private = "file")
collect_fields :: proc(app: ^App, t: Var_Type, depth: int, out: ^[dynamic]Struct_Field) {
	if depth > MAX_TYPE_DEPTH do return
	s := strings.trim_space(t.expr)
	if strings.has_prefix(s, "^") do s = strings.trim_space(s[1:]) // auto-dereference
	for strings.has_prefix(s, "distinct ") do s = strings.trim_space(s[len("distinct "):])
	if s == "" || s == "?" do return
	if strings.has_prefix(s, "struct") {
		fields_of_struct_text(app, s, t.pkg, nil, depth, out)
		return
	}
	// A polymorphic instantiation: Stack(int).
	args: []string
	if paren := strings.index_byte(s, '('); paren > 0 && s[len(s) - 1] == ')' {
		args = split_top_level(s[paren + 1:len(s) - 1])
		s = s[:paren]
	}
	if !is_qual_ident(s) do return

	if dot := strings.index_byte(s, '.'); dot >= 0 {
		path := ref_path(app, s[:dot], t.pkg)
		if path == "" do return
		collect_fields(app, Var_Type{s[dot + 1:], path}, depth + 1, out)
		return
	}
	if t.pkg == "" {
		text, file, ok := decl_text_src(app, s)
		if !ok do return
		if has_kw_prefix(text, "struct") {
			fields_of_struct_text(app, text, "", args, depth, out, file)
			return
		}
		// An alias / distinct type of another type.
		first := strings.trim_space(strings.split_lines(text, context.temp_allocator)[0])
		for kw in ([]string{"#type", "proc", "enum", "union", "bit_set", "bit_field"}) do if has_kw_prefix(first, kw) do return
		collect_fields(app, sibling_type_here(app, first, file), depth + 1, out)
		return
	}
	// A type in an imported package.
	if lo, hi, found := core_field_range(t.pkg, s); found {
		for f in CORE_FIELDS[lo:hi] {
			if f.name != "_" do append(out, Struct_Field{f.name, Var_Type{f.type, f.path}, false})
			if f.using_field do append_promoted(app, Var_Type{f.type, f.path}, depth, out)
		}
		return
	}
	if i, ok := core_type_index(t.pkg, s); ok {
		ct := CORE_TYPES[i]
		if ct.kind == "alias" || ct.kind == "distinct" do collect_fields(app, Var_Type{ct.target, ct.path}, depth + 1, out)
	}
}

// CORE_FIELDS rows are grouped per (path, type_name): "path|name" -> [lo, hi).
// Built on first use (a linear scan of ~29k rows per lookup made deep field
// menus slow); lives for the whole run, outside any tracked allocator.
@(private = "file")
core_field_map: map[string][2]int
@(private = "file")
core_field_once: sync.Once

@(private = "file")
core_field_range :: proc(path, name: string) -> (lo, hi: int, ok: bool) {
	sync.once_do(&core_field_once, proc() {
		a := runtime.heap_allocator()
		core_field_map = make(map[string][2]int, 8192, a)
		i := 0
		for i < len(CORE_FIELDS) {
			j := i + 1
			for j < len(CORE_FIELDS) && CORE_FIELDS[j].path == CORE_FIELDS[i].path && CORE_FIELDS[j].type_name == CORE_FIELDS[i].type_name do j += 1
			k := strings.concatenate({CORE_FIELDS[i].path, "|", CORE_FIELDS[i].type_name}, a)
			if k in core_field_map do delete(k, a)
			else do core_field_map[k] = {i, j}
			i = j
		}
	})
	r, found := core_field_map[strings.concatenate({path, "|", name}, context.temp_allocator)]
	return r[0], r[1], found
}

// field_type: the type of field `name` of type `t` (pointer auto-deref).
field_type :: proc(app: ^App, t: Var_Type, name: string) -> (Var_Type, bool) {
	for f in struct_fields(app, t) do if f.name == name do return f.type, true
	return {}, false
}

// is_struct_type: does `t` resolve to a struct with fields Doodle knows?
is_struct_type :: proc(app: ^App, t: Var_Type) -> bool {
	if strings.has_prefix(strings.trim_space(t.expr), "[") do return false
	return len(struct_fields(app, t)) > 0
}

// ---- Types of names ----

// var_type_at: the type of `name` as seen from line `ni` (a local declared
// earlier in the same procedure, a parameter, or a file-scope declaration).
var_type_at :: proc(app: ^App, ni: int, name: string) -> (Var_Type, bool) {
	return var_type_depth(app, ni, name, 0)
}

@(private = "file")
var_type_depth :: proc(app: ^App, ni: int, name: string, depth: int) -> (Var_Type, bool) {
	n := len(app.doc.nodes)
	if depth > MAX_TYPE_DEPTH || n == 0 || !is_ident(name) do return {}, false
	at := clamp(ni, 0, n - 1)

	// Inside a procedure: earlier statements, then its parameters.
	if start, hdr, ok := enclosing_proc(app, at); ok && at > start {
		// d[k] = brace depth before line start + k.
		d := make([]int, at - start + 1, context.temp_allocator)
		for j in start ..< at do d[j - start + 1] = d[j - start] + brace_delta(app, j)
		min_d := d[at - start]
		for j := at - 1; j > start; j -= 1 {
			min_d = min(min_d, d[j - start + 1])
			// `} else {` nets 0 but ends the block above it: the dip to the depth
			// after its leading `}` counts.
			if j + 1 < at do min_d = min(min_d, d[j + 1 - start] - leading_closes(app, j + 1))
			if d[j - start] > min_d {
				// inside a block that has ended; but an `else if`'s setup names reach the
				// later branches of its chain (branch.odin)
				if t, found := branch_declares(app, j, at, name, depth); found do return t, t.expr != ""
				continue
			}
			if t, found := branch_declares(app, j, at, name, depth); found do return t, t.expr != "" // if / switch setups, type switch variables (branch.odin)
			// A loop header: its variables, while inside the loop (loops.odin).
			if t, found, hdr := loop_header_declares(app, j, name, d[j - start] < min_d); hdr {
				if found do return t, t.expr != ""
				continue
			}
			if t, found := line_declares(app, j, name, depth); found do return t, t.expr != ""
			// Another case clause of the same switch is out of scope.
			if d[j - start] == min_d && is_case_line(app, j) do min_d -= 1
		}
		for p in parse_params(hdr) {
			if p.name == name && p.type != "" do return Var_Type{p.type, ""}, true
		}
	}

	// File scope.
	pts := insertion_points(app, context.temp_allocator)
	for j in 0 ..< n {
		if !pts[j] do continue
		if t, found := line_declares(app, j, name, depth); found do return t, t.expr != ""
	}
	return {}, false
}

// How many `}` start line i (before anything else).
leading_closes :: proc(app: ^App, i: int) -> int {
	t := strings.trim_space(strip_comment(node_text(app.doc.nodes[i], context.temp_allocator)))
	n := 0
	for c in transmute([]u8)t {
		if c == '}' do n += 1
		else if c != ' ' && c != '\t' do break
	}
	return n
}

// The procedure line ni is in: the line its body opens on, and its parameter
// text (a header can run over several lines).
enclosing_proc :: proc(app: ^App, ni: int) -> (start: int, params: string, ok: bool) {
	s, _ := construct_range(app, ni)
	if brace_delta(app, s) <= 0 do return
	// Collect the header: back to the line with `proc` (a parameter list can run
	// over several lines; they hold no braces).
	h := s
	for k := 0; k < 64 && h >= 0; k += 1 {
		t := node_text(app.doc.nodes[h], context.temp_allocator)
		if strings.contains(t, "proc") do break
		if h < s && (strings.contains(t, "{") || strings.contains(t, "}")) do return
		h -= 1
	}
	if h < 0 do return
	b := strings.builder_make(context.temp_allocator)
	for j in h ..= s {
		strings.write_string(&b, strip_comment(node_text(app.doc.nodes[j], context.temp_allocator)))
		strings.write_byte(&b, ' ')
	}
	txt := strings.to_string(b)
	at := strings.index(txt, "proc")
	if at < 0 do return
	open := strings.index_byte(txt[at:], '(')
	if open < 0 do return
	open += at
	close := match_bracket(txt, open)
	if close < 0 do return
	if !strings.contains(txt[close:], "{") do return
	return s, txt[open + 1:close], true
}

// line_declares: does line j declare `name`? Returns its type (expr "" when
// declared but of unknown type).
@(private = "file")
line_declares :: proc(app: ^App, j: int, name: string, depth: int) -> (Var_Type, bool) {
	t := strings.trim_space(strip_comment(node_text(app.doc.nodes[j], context.temp_allocator)))
	if t == "" do return {}, false
	for kw in ([]string{"if ", "for ", "switch ", "when ", "case ", "return ", "defer ", "import ", "package ", "foreign "}) {
		if strings.has_prefix(t, kw) do return {}, false
	}
	return decl_text_declares(app, j, t, name, depth)
}

// decl_text_declares: does declaration text `t` (written on line j) declare
// `name`? Its type as for line_declares (also for an if / switch setup, branch.odin).
decl_text_declares :: proc(app: ^App, j: int, text: string, name: string, depth: int) -> (Var_Type, bool) {
	t := text
	if strings.has_prefix(t, "using ") do t = strings.trim_space(t[len("using "):])

	// The name list: `a`, `a, b`.
	names := make([dynamic]string, 0, 2, context.temp_allocator)
	k := 0
	for {
		st := k
		for k < len(t) && ident_byte(t[k]) do k += 1
		if k == st do return {}, false
		append(&names, t[st:k])
		for k < len(t) && t[k] == ' ' do k += 1
		if k < len(t) && t[k] == ',' {
			k += 1
			for k < len(t) && t[k] == ' ' do k += 1
			continue
		}
		break
	}
	idx := -1
	for nm, i in names do if nm == name { idx = i; break }
	if idx < 0 do return {}, false
	rest := t[k:]

	switch {
	case strings.has_prefix(rest, "::"):
		v := strings.trim_space(rest[2:])
		for kw in ([]string{"struct", "enum", "union", "bit_set", "bit_field", "distinct", "#type"}) {
			if strings.has_prefix(v, kw) do return {}, false // a type, not a value
		}
		if strings.has_prefix(v, "proc") do return Var_Type{"proc", ""}, true
		if strings.has_prefix(v, "#config(") do return {}, true
		vt, _ := expr_type_depth(app, j, v, depth + 1)
		return vt, true
	case strings.has_prefix(rest, ":="):
		values := split_top_level(strings.trim_space(rest[2:]))
		if len(values) == len(names) {
			vt, _ := expr_type_depth(app, j, values[idx], depth + 1)
			return vt, true
		}
		if len(values) == 1 && len(names) == 2 {
			// v, ok := m[k] / x.(T) (index_fill.odin)
			if ct, ok := comma_ok_type(app, j, values[0], idx); ok do return ct, true
		}
		if len(values) == 1 {
			// a, b := f(): the idx-th result.
			ret, pkg, ok := call_ret_text(app, values[0])
			if !ok do return {}, true
			r := strings.trim_space(ret)
			if strings.has_prefix(r, "(") && strings.contains(r, ")") {
				ps := parse_params(r[1:strings.last_index_byte(r, ')')])
				if idx < len(ps) do return Var_Type{ps[idx].type, pkg}, true
			}
		}
		return {}, true
	case strings.has_prefix(rest, ":"):
		ty := rest[1:]
		if eq := strings.index_byte(ty, '='); eq >= 0 do ty = ty[:eq]
		if c := strings.index_byte(ty, ':'); c >= 0 do ty = ty[:c] // typed constant `X : T : v`
		ty = strings.trim_space(ty)
		ty = strings.trim_right(ty, ",){ ") // a parameter line of a multi-line header
		return Var_Type{ty, ""}, true
	}
	return {}, false
}

// ---- Types of expressions ----

// expr_type_at: the type of expression `text` written on line ni
// (`paint.rcPaint.left`, `&paint`, `win32.BeginPaint(...)`, ...).
expr_type_at :: proc(app: ^App, ni: int, text: string) -> (Var_Type, bool) {
	return expr_type_depth(app, ni, text, 0)
}

@(private = "file")
BINOPS := [?]string{" || ", " && ", " == ", " != ", " <= ", " >= ", " < ", " > ", " | ", " ~ ", " &~ ", " & ", " << ", " >> ", " + ", " - ", " * ", " / ", " % ", " %% "}

@(private = "file")
expr_type_depth :: proc(app: ^App, ni: int, text: string, depth: int) -> (Var_Type, bool) {
	s := strings.trim_space(text)
	if s == "" || depth > MAX_TYPE_DEPTH do return {}, false

	// A ternary: `x if c else y` / `x when c else y` -> x; `c ? x : y` -> x
	// (before the operators: the condition's comparison isn't the result).
	if k1, e1, k2, _, ok := tern_split_text(s); ok {
		if strings.trim_space(s[k1:e1]) == "?" do return expr_type_depth(app, ni, s[e1:k2], depth + 1)
		return expr_type_depth(app, ni, s[:k1], depth + 1)
	}
	// A binary operator: comparisons are bool, the rest the left operand's type.
	for op in BINOPS {
		at := top_level_index(s, op)
		if at <= 0 do continue
		switch strings.trim_space(op) {
		case "||", "&&", "==", "!=", "<", "<=", ">", ">=":
			return Var_Type{"bool", ""}, true
		}
		if t, ok := expr_type_depth(app, ni, s[:at], depth + 1); ok do return t, true
		return expr_type_depth(app, ni, s[at + len(op):], depth + 1)
	}
	switch {
	case s[0] == '&':
		t, ok := expr_type_depth(app, ni, s[1:], depth + 1)
		if !ok do return {}, false
		return Var_Type{strings.concatenate({"^", t.expr}, context.temp_allocator), t.pkg}, true
	case s[0] == '"' || s[0] == '`':
		return Var_Type{"string", ""}, true
	case s[0] == '\'':
		return Var_Type{"rune", ""}, true
	case s[0] >= '0' && s[0] <= '9':
		if strings.contains(s, ".") && !strings.has_prefix(s, "0x") do return Var_Type{"f64", ""}, true
		return Var_Type{"int", ""}, true
	case s == "true" || s == "false":
		return Var_Type{"bool", ""}, true
	case strings.has_prefix(s, "cast(") || strings.has_prefix(s, "transmute("):
		open := strings.index_byte(s, '(')
		close := match_bracket(s, open)
		if close < 0 do return {}, false
		return Var_Type{strings.trim_space(s[open + 1:close]), ""}, true
	}
	last := s[len(s) - 1]
	// x^: what a pointer points to.
	if last == '^' {
		t, ok := expr_type_depth(app, ni, s[:len(s) - 1], depth + 1)
		if !ok || !strings.has_prefix(t.expr, "^") do return {}, false
		return Var_Type{t.expr[1:], t.pkg}, true
	}
	// T{...} / T {...}: a composite literal.
	if last == '}' {
		open := strings.index_byte(s, '{')
		if open <= 0 do return {}, false
		ty := strings.trim_space(s[:open])
		if ty == "" do return {}, false
		return Var_Type{ty, ""}, true
	}
	// A call or a conversion: callee(args).
	if last == ')' {
		open := strings.index_byte(s, '(')
		if open > 0 && match_bracket(s, open) == len(s) - 1 {
			callee := s[:open]
			if !is_qual_ident(callee) do return {}, false
			if callee == "make" { // make(map[string]int), make([]T, n)
				args := split_top_level(s[open + 1:len(s) - 1])
				if len(args) > 0 && strings.trim_space(args[0]) != "" do return Var_Type{strings.trim_space(args[0]), ""}, true
			}
			if conv, ok := conversion_type(app, callee); ok do return conv, true
			ret, pkg, ok := call_ret_text(app, s)
			if !ok do return {}, false
			r := strings.trim_space(ret)
			if strings.has_prefix(r, "(") do return {}, false // several results
			return Var_Type{r, pkg}, true
		}
		return {}, false
	}
	// x[i]: an element (a map's value, a string's byte; index_fill.odin).
	if last == ']' {
		open := index_open(s)
		if open <= 0 do return {}, false
		t, ok := expr_type_depth(app, ni, s[:open], depth + 1)
		if !ok do return {}, false
		if _, elem, iok := index_types(app, t); iok do return elem, true
		return {}, false
	}
	// a.b.c: a field path, or pkg.CONSTANT.
	if !strings.contains(s, ".") do return var_type_depth(app, ni, s, depth + 1)
	parts := strings.split(s, ".", context.temp_allocator)
	for p in parts do if !is_ident(p) do return {}, false
	base, ok := var_type_depth(app, ni, parts[0], depth + 1)
	if !ok {
		// pkg.NAME: an imported constant with a known type.
		if len(parts) != 2 do return {}, false
		path := ref_path(app, parts[0], "")
		if path == "" do return {}, false
		for c in CORE_CONSTS {
			if c.path != path || c.name != parts[1] do continue
			if c.kind == "" || c.kind == "?" || strings.has_prefix(c.kind, "#") do return {}, false
			return Var_Type{c.kind, path}, true
		}
		return {}, false
	}
	t := base
	for p in parts[1:] {
		ft, found := field_type(app, t, p)
		if !found do return {}, false
		t = ft
	}
	return t, true
}

// Index of `sub` in s outside brackets and strings (first), or -1.
@(private = "file")
top_level_index :: proc(s, sub: string) -> int {
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
			if depth == 0 && strings.has_prefix(s[k:], sub) do return k
		}
	}
	return -1
}

// conversion_type: `callee` names a type (T(x) is a conversion): win32.HINSTANCE,
// int, a type declared in this document. (Also expr.odin: is T(x) a conversion.)
conversion_type :: proc(app: ^App, callee: string) -> (Var_Type, bool) {
	if dot := strings.index_byte(callee, '.'); dot >= 0 {
		path := ref_path(app, callee[:dot], "")
		if path == "" do return {}, false
		name := callee[dot + 1:]
		for t in CORE_TYPES do if t.path == path && t.name == name do return Var_Type{callee, ""}, true
		return {}, false
	}
	for b in BASIC_TYPES do if b == callee do return Var_Type{callee, ""}, true
	switch callee {
	case "i128", "u128", "f16", "b8", "b16", "b32", "b64", "string16", "cstring16", "typeid", "any", "complex64", "complex128":
		return Var_Type{callee, ""}, true
	}
	// The document's types: exactly what the Type menu (and so Convert) lists -
	// structs, enums, ..., distinct, and aliases (`Id :: u32`, `Vec :: [3]f32`);
	// not proc aliases (`uf :: union_find`). Plus `#type proc(...)` aliases.
	for d in doc_type_decls(app) do if d.name == callee do return Var_Type{callee, ""}, true
	if text, ok := doc_decl_text(app, callee); ok && has_kw_prefix(strings.trim_space(text), "#type") {
		return Var_Type{callee, ""}, true
	}
	return {}, false
}

// s starts with the keyword kw as a whole word (`union {`, not `union_find`).
@(private = "file")
has_kw_prefix :: proc(s, kw: string) -> bool {
	if !strings.has_prefix(s, kw) do return false
	return len(s) == len(kw) || !ident_byte(s[len(kw)])
}

// call_ret_text: the return type text of the call `callee(args)` and the
// package it's written in.
@(private = "file")
call_ret_text :: proc(app: ^App, call: string) -> (ret, pkg: string, ok: bool) {
	open := strings.index_byte(call, '(')
	if open <= 0 do return
	callee := strings.trim_space(call[:open])
	ref, name := "", callee
	if dot := strings.last_index_byte(callee, '.'); dot >= 0 do ref, name = callee[:dot], callee[dot + 1:]
	sig := call_signature(app, ref, name)
	if !sig.known || sig.ret == RET_NONE || sig.ret == RET_UNKNOWN do return
	r := strings.trim_space(sig.ret)
	if strings.contains(r, "#optional") && strings.has_prefix(r, "(") {
		// `(res: T, err: E) #optional_...`: used as one value, it's the first.
		ps := parse_params(r[1:strings.last_index_byte(r, ')')])
		if len(ps) > 0 do r = ps[0].type
	}
	return r, sig.pkg, true
}

package model

// Types (data shapes): struct / polymorphic struct / enum / union / bit_set /
// bit_field / distinct / alias declarations, the members inside their bodies,
// and composite type expressions ([N]T, []T, [dynamic]T, map[K]V, ^T, [^]T).
//
// Field structure. The loader (structure_type_decls) produces exactly what the
// menus build, so loaded code is edited the same way:
//   Player :: struct {             [Player][" :: struct {"]
//       hp: int,                   [indent][hp member][": "][int type][","]
//       using base: Base,          [indent]["using "][base member][": "][Base][","]
//   Stack :: struct($T: typeid) {  [Stack][" :: struct($"][T poly][": typeid"][● params][") {"]
//   Dir :: enum {                  [Dir][" :: enum {"]
//       North,                     [indent][North member][","]
//       South = 5,                 [indent][South member][" = "][5][","]
//   Shape :: union {               [Shape][" :: union {"]
//       Circle,                    [indent][Circle type][","]
//   Packed :: bit_field u32 {      [Packed][" :: bit_field "][u32 type][" {"]
//       a: u8 | 4,                 [indent][a member][": "][u8][" | "][4][","]
//   Flags :: bit_set[Dir]          [Flags][" :: bit_set["][Dir type]["]"]  (or ["0..<"][8])
//   Meters :: distinct f64         [Meters][" :: distinct "][f64 type]
//   Grid :: [8][8]int              [Grid][" :: "]["["][8]["]"]["["][8]["]"][int type]
//   Lookup :: map[string]int       [Lookup][" :: "]["map["][string]["]"][int]
// A body written on one line keeps its members there:
//   Dir :: enum { North, South }   [Dir][" :: enum { "][North][", "][South][" }"]
//
// Inside a data body the green dots (body_dots.odin) and the "●" line offer
// members instead of statements: Field / Using field (struct), Member /
// Member = value (enum), Variant (union), Field (bit_field).

import "core:fmt"
import "core:strings"

Data_Kind :: enum u8 { None, Struct, Enum, Union, Bit_Field }

// Fill markers handled by apply_types_fill (all start with TYPES_FILL_PREFIX).
TYPES_FILL_PREFIX :: "__ty_"
TY_ARRAY     :: "__ty_array__"     // [●]●
TY_SLICE     :: "__ty_slice__"     // []●
TY_DYNAMIC   :: "__ty_dynamic__"   // [dynamic]●
TY_MAP       :: "__ty_map__"       // map[●]●
TY_POINTER   :: "__ty_pointer__"   // ^●
TY_MULTI_PTR :: "__ty_multiptr__"  // [^]●
TY_RANGE     :: "__ty_range__"     // 0..<● (bit_set element)
TY_FIELD     :: "__ty_field__"     // struct: name: ●,
TY_USING     :: "__ty_using__"     // struct: using name: ●,
TY_MEMBER    :: "__ty_member__"    // enum: Name,
TY_MEMBER_EQ :: "__ty_member_eq__" // enum: Name = ●,
TY_VARIANT   :: "__ty_variant__"   // union: ●,
TY_BITS      :: "__ty_bits__"      // bit_field: name: ● | ●,
TY_TPARAM    :: "__ty_tparam__"    // polymorphic struct: , $U: typeid
TY_VPARAM    :: "__ty_vparam__"    // polymorphic struct: , $N: ●
TY_UNWRAP    :: "__ty_unwrap__"    // [8]int -> int (Y / LT+A on the int)

is_types_fill :: proc(fill: string) -> bool { return strings.has_prefix(fill, TYPES_FILL_PREFIX) }

// ---- Lexical helpers ----

@(private = "file")
is_ws :: proc(c: u8) -> bool { return c == ' ' || c == '\t' }
@(private = "file")
dt_ident_start :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' }
@(private = "file")
dt_ident_char :: proc(c: u8) -> bool { return dt_ident_start(c) || (c >= '0' && c <= '9') }

@(private = "file")
skip_ws :: proc(s: string, at: int) -> int {
	k := at
	for k < len(s) && is_ws(s[k]) do k += 1
	return k
}

// End of the identifier starting at `at` (== at when there is none).
@(private = "file")
scan_ident :: proc(s: string, at: int) -> int {
	if at >= len(s) || !dt_ident_start(s[at]) do return at
	k := at + 1
	for k < len(s) && dt_ident_char(s[k]) do k += 1
	return k
}

// s starts with keyword w as a whole word.
@(private = "file")
word_prefix :: proc(s, w: string) -> bool {
	return strings.has_prefix(s, w) && (len(s) == len(w) || !dt_ident_char(s[len(w)]))
}

// Index of `word` as a whole word in txt, outside strings and comments; -1 if absent.
@(private = "file")
find_word :: proc(txt, word: string) -> int {
	quote: u8 = 0
	for k := 0; k < len(txt); k += 1 {
		c := txt[k]
		if quote != 0 {
			if c == '\\' && quote != '`' { k += 1; continue }
			if c == quote do quote = 0
			continue
		}
		switch c {
		case '"', '\'', '`':
			quote = c
			continue
		case '/':
			if k + 1 < len(txt) && txt[k + 1] == '/' do return -1
		}
		if strings.has_prefix(txt[k:], word) && (k == 0 || !dt_ident_char(txt[k - 1])) {
			end := k + len(word)
			if end >= len(txt) || !dt_ident_char(txt[end]) do return k
		}
	}
	return -1
}

// Where a `//` comment starts (outside strings), or len(s).
@(private = "file")
comment_start :: proc(s: string) -> int {
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
		case '/': if k + 1 < len(s) && s[k + 1] == '/' do return k
		}
	}
	return len(s)
}

// The bracket matching s[open] ('(' '[' '{'), skipping strings; -1 if unclosed.
@(private = "file")
matching_close :: proc(s: string, open: int) -> int {
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
		case '(', '[', '{': depth += 1
		case ')', ']', '}':
			depth -= 1
			if depth == 0 do return k
		}
	}
	return -1
}

// [start, end) spans of s split at top-level commas.
@(private = "file")
comma_spans :: proc(s: string) -> [][2]int {
	out := make([dynamic][2]int, 0, 4, context.temp_allocator)
	depth := 0
	quote: u8 = 0
	start := 0
	for k := 0; k < len(s); k += 1 {
		c := s[k]
		if quote != 0 {
			if c == '\\' && quote != '`' { k += 1; continue }
			if c == quote do quote = 0
			continue
		}
		switch c {
		case '"', '\'', '`': quote = c
		case '(', '[', '{': depth += 1
		case ')', ']', '}': depth -= 1
		case ',':
			if depth == 0 {
				append(&out, [2]int{start, k})
				start = k + 1
			}
		}
	}
	append(&out, [2]int{start, len(s)})
	return out[:]
}

// `Name` or `pkg.Name`.
@(private = "file")
is_simple_type :: proc(s: string) -> bool {
	e := scan_ident(s, 0)
	if e == 0 do return false
	if e == len(s) do return true
	if s[e] != '.' do return false
	return scan_ident(s, e + 1) == len(s) && e + 1 < len(s)
}

// A number or a name (what Number / Reference put in a dot).
@(private = "file")
is_simple_value :: proc(s: string) -> bool {
	if s == "" do return false
	for c in transmute([]u8)s do if !dt_ident_char(c) do return false
	return true
}

@(private = "file")
COMPOSITE_PREFIXES := [?]string{"[", "^", "map[", "#soa", "#simd", "matrix["}

@(private = "file")
is_composite_text :: proc(s: string) -> bool {
	for p in COMPOSITE_PREFIXES do if strings.has_prefix(s, p) do return true
	return false
}

@(private = "file")
BUILTIN_TYPE_NAMES := [?]string{
	"int", "uint", "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128",
	"uintptr", "byte", "f16", "f32", "f64", "complex64", "complex128", "quaternion256",
	"rune", "bool", "b8", "b16", "b32", "b64", "string", "cstring", "rawptr", "typeid", "any",
}

// Does the right-hand side of `Name :: rhs` read as a type (so it's a type alias)?
@(private = "file")
is_type_rhs :: proc(rhs: string) -> bool {
	if is_composite_text(rhs) do return true
	for b in BUILTIN_TYPE_NAMES do if rhs == b do return true
	if dot := strings.index_byte(rhs, '.'); dot > 0 && is_simple_type(rhs) {
		name := rhs[dot + 1:]
		for t in CORE_TYPES do if t.name == name do return true
	}
	return false
}

// ---- Data blocks ----

// The kind of data block a line opens with its `{` (by keyword), or .None.
data_kind_of_line :: proc(txt: string) -> Data_Kind {
	best, kind := -1, Data_Kind.None
	KWS :: [4]string{"struct", "enum", "union", "bit_field"}
	kws := KWS
	for kw, k in kws {
		i := find_word(txt, kw)
		if i >= 0 && (best < 0 || i < best) {
			best = i
			kind = Data_Kind(k + 1)
		}
	}
	return kind
}

// Push/pop the line's braces: data blocks get their kind, other blocks .None.
// (Each `{` is classified by the text since the previous brace on the line:
// `f :: proc(s: struct { a: int }) {` opens a data block, then code.)
data_track_braces :: proc(stack: ^[dynamic]Data_Kind, txt: string) {
	seg := 0
	quote: u8 = 0
	for k := 0; k < len(txt); k += 1 {
		c := txt[k]
		if quote != 0 {
			if c == '\\' && quote != '`' { k += 1; continue }
			if c == quote do quote = 0
			continue
		}
		switch c {
		case '"', '\'', '`': quote = c
		case '/': if k + 1 < len(txt) && txt[k + 1] == '/' do return
		case '{':
			append(stack, data_kind_of_line(txt[seg:k]))
			seg = k + 1
		case '}':
			if len(stack) > 0 do pop(stack)
			seg = k + 1
		}
	}
}

// The data block line ni sits directly inside (.None in code / at the top level).
data_block_at :: proc(app: ^App, ni: int) -> Data_Kind {
	stack := make([dynamic]Data_Kind, 0, 8, context.temp_allocator)
	for i in 0 ..< min(ni, len(app.doc.nodes)) {
		data_track_braces(&stack, node_text(app.doc.nodes[i], context.temp_allocator))
	}
	return len(stack) > 0 ? stack[len(stack) - 1] : .None
}

// ---- Declared types ----

Doc_Type :: struct {
	name: string, // references the document's field text (or the sibling's owned name)
	kind: string, // "struct" / "enum" / "union" / "bit_field" / "bit_set" / "distinct" / "alias"
	ni:   int,    // its line in app.doc; -1 for a sibling's type (never index app.doc with it)
	file: string, // "" = the open file; else the sibling file it's declared in (siblings.odin)
}

// doc_type_decls: the types this file can name without an import: the ones
// declared in the document (`Name :: struct ...`, `Name :: distinct f64`,
// `Name :: [8]int`, ... - not constants or procs), then those of the package's
// other files (siblings.odin; ni = -1) that the document doesn't shadow.
// Temp-allocated.
doc_type_decls :: proc(app: ^App) -> []Doc_Type {
	own := own_type_decls(app)
	if len(app.sibling_types) == 0 do return own
	out := make([dynamic]Doc_Type, 0, len(own) + len(app.sibling_types), context.temp_allocator)
	append(&out, ..own)
	sib: for st in app.sibling_types {
		kind := sibling_kind(app, st, own) // (a bare-name `Vec :: point`: an alias when point is a type)
		if kind == "" || kind == "proc_type" do continue // `#type proc`: not listed as a type (as in this file)
		for d in own do if d.name == st.name do continue sib
		append(&out, Doc_Type{name = st.name, kind = kind, ni = -1, file = st.file})
	}
	return out[:]
}

// own_type_decls: doc_type_decls of the open document only (line indexes valid
// in app.doc). Temp-allocated.
own_type_decls :: proc(app: ^App) -> []Doc_Type {
	out := make([dynamic]Doc_Type, 0, 8, context.temp_allocator)
	for n, ni in app.doc.nodes {
		fs := n.fields
		i := 0
		// Indentation, and an attribute on the same line (`@(private) Player :: ...`).
		for i < len(fs) && !fs[i].slot && !fs[i].editable && (strings.trim_space(fs[i].text) == "" || strings.has_prefix(strings.trim_space(fs[i].text), "@")) do i += 1
		if i + 1 >= len(fs) do continue
		f, sep := fs[i], fs[i + 1]
		if !f.editable || f.kind != "" || sep.slot || sep.editable do continue
		st := strings.trim_left_space(sep.text)
		if !strings.has_prefix(st, "::") do continue
		r := strings.trim_left_space(st[2:])
		kind := ""
		switch {
		case word_prefix(r, "struct"):    kind = "struct"
		case word_prefix(r, "enum"):      kind = "enum"
		case word_prefix(r, "union"):     kind = "union"
		case word_prefix(r, "bit_field"): kind = "bit_field"
		case strings.has_prefix(r, "bit_set["): kind = "bit_set"
		case word_prefix(r, "distinct"):  kind = "distinct"
		case r == "":
			if i + 2 < len(fs) {
				nx := fs[i + 2]
				if nx.kind == "type" || (!nx.slot && !nx.editable && is_composite_text(nx.text)) do kind = "alias"
			}
		case is_composite_text(r) && !strings.contains_any(r, "{("): kind = "alias"
		}
		if kind != "" do append(&out, Doc_Type{name = f.text, kind = kind, ni = ni})
	}
	return out[:]
}

// The names of the types this file can name (its own, then its siblings'; no
// duplicates), enums first when asked. Temp-allocated.
doc_type_names :: proc(app: ^App, enums_first := false) -> []string {
	out := make([dynamic]string, 0, 8, context.temp_allocator)
	add :: proc(out: ^[dynamic]string, name: string) {
		for s in out do if s == name do return
		append(out, name)
	}
	decls := doc_type_decls(app)
	if enums_first do for d in decls do if d.kind == "enum" do add(&out, d.name)
	for d in decls do add(&out, d.name)
	return out[:]
}

// The lines enclosing line ni (the headers of the blocks it's inside), innermost first.
@(private = "file")
enclosing_headers :: proc(app: ^App, ni: int) -> []int {
	out := make([dynamic]int, 0, 4, context.temp_allocator)
	level := 0
	for i := min(ni, len(app.doc.nodes)) - 1; i >= 0; i -= 1 {
		level += brace_delta(app, i)
		if level > 0 {
			append(&out, i)
			level = 0
		}
	}
	return out[:]
}

// poly_params_in_scope: the `$T` parameters of the polymorphic struct(s) line ni
// is in (or the header line ni itself). Temp-allocated; strings are the doc's.
poly_params_in_scope :: proc(app: ^App, ni: int) -> []string {
	out := make([dynamic]string, 0, 2, context.temp_allocator)
	if ni < 0 || ni >= len(app.doc.nodes) + 1 do return out[:]
	lines := make([dynamic]int, 0, 4, context.temp_allocator)
	if ni < len(app.doc.nodes) do append(&lines, ni)
	for h in enclosing_headers(app, ni) do append(&lines, h)
	for l in lines {
		for f in app.doc.nodes[l].fields {
			if !f.editable || f.kind != "poly" || f.text == "" do continue
			dup := false
			for s in out do if s == f.text { dup = true; break }
			if !dup do append(&out, f.text)
		}
	}
	return out[:]
}

// ---- Menus ----

// The "Composite" group of every Type menu.
composite_type_group :: proc() -> Entry {
	return Entry{label = "Composite", children = make_slice(
		Entry{label = "[N]T array", fill = TY_ARRAY},
		Entry{label = "[]T slice", fill = TY_SLICE},
		Entry{label = "[dynamic]T", fill = TY_DYNAMIC},
		Entry{label = "map[K]V", fill = TY_MAP},
		Entry{label = "^T pointer", fill = TY_POINTER},
		Entry{label = "[^]T multi-ptr", fill = TY_MULTI_PTR},
	)}
}

// What can be added inside a data body.
@(private = "file")
member_entries :: proc(kind: Data_Kind) -> []Entry {
	switch kind {
	case .Struct:    return make_slice(Entry{label = "Field", fill = TY_FIELD}, Entry{label = "Using field", fill = TY_USING})
	case .Enum:      return make_slice(Entry{label = "Member", fill = TY_MEMBER}, Entry{label = "Member = value", fill = TY_MEMBER_EQ})
	case .Union:     return make_slice(Entry{label = "Variant", fill = TY_VARIANT})
	case .Bit_Field: return make_slice(Entry{label = "Field", fill = TY_BITS})
	case .None:
	}
	return nil
}

// The fixed text right before field fi ("" if none).
@(private = "file")
text_before :: proc(n: Node, fi: int) -> string {
	if fi <= 0 || fi > len(n.fields) do return ""
	p := n.fields[fi - 1]
	return p.slot || p.editable ? "" : p.text
}

// Gray out what can't back a bit_field (basic non-integer types, composites).
// Import groups are left alone (resolving all of them would be slow).
@(private = "file")
dim_non_integers :: proc(app: ^App, entries: []Entry) {
	ctx := type_ctx_make(app)
	for &e in entries {
		if e.label == "Composite" { e.dim = true; continue }
		if len(e.children) > 0 || e.fill == "" || e.fill == TYPE_IMPORT_FILL do continue
		r := resolve_type(&ctx, e.fill, "")
		e.dim = !(r.cat == .Integer || r.cat == .Unknown)
	}
}

// types_slot_menu: the fill menu for dots that belong to type declarations.
// ok=false: not one of them (open_slot_menu builds its usual menu).
//   ● in a struct / enum / union / bit_field body -> its members
//   ● after `struct($T: typeid` (params)            -> Type param / Value param
//   ● in `bit_set[●]`                                -> the file's enums, 0..<N, Type
//   ● in `bit_field ● {` (backing type)              -> Type (integers)
types_slot_menu :: proc(app: ^App, ni, fi: int) -> ([]Entry, bool) {
	if ni < 0 || ni >= len(app.doc.nodes) do return nil, false
	n := app.doc.nodes[ni]
	if fi < 0 || fi >= len(n.fields) do return nil, false
	f := n.fields[fi]
	switch f.kind {
	case "body":
		dk := data_block_at(app, ni)
		if dk == .None do return nil, false
		m := member_entries(dk)
		out := make([]Entry, len(m) + 1)
		copy(out, m)
		out[len(m)] = layout_group() // Comment, Blank line (stmt_layout.odin)
		delete(m)
		return out, true
	case "params":
		b := strings.builder_make(context.temp_allocator)
		for i in 0 ..< fi do strings.write_string(&b, n.fields[i].text)
		head := strings.to_string(b)
		if find_word(head, "struct") < 0 && find_word(head, "union") < 0 do return nil, false
		return make_slice(
			Entry{label = "Type param", fill = TY_TPARAM},
			Entry{label = "Value param", fill = TY_VPARAM},
		), true
	case "type":
		before := text_before(n, fi)
		if strings.has_suffix(before, "bit_set[") {
			out := make([dynamic]Entry, 0, 8, context.temp_allocator)
			for d in doc_type_decls(app) do if d.kind == "enum" do append(&out, fill_leaf(d.name, d.name))
			append(&out, Entry{label = "0..<N range", fill = TY_RANGE})
			append(&out, Entry{label = "Type", children = build_type_entries(app)})
			res := make([]Entry, len(out))
			copy(res, out[:])
			return res, true
		}
		if strings.has_suffix(before, "bit_field ") {
			types := build_type_entries(app)
			dim_non_integers(app, types)
			return make_slice(Entry{label = "Type", children = types}), true
		}
	}
	return nil, false
}

// ---- Applying the fills ----

@(private = "file")
fixed :: proc(s: string) -> Field { return Field{strings.clone(s), false, false, "", "", ""} }
@(private = "file")
type_dot :: proc() -> Field { return Field{"", false, true, "type", "", ""} }
@(private = "file")
int_dot :: proc() -> Field { return Field{"", false, true, "value", "int", ""} }

// A parameter name for a polymorphic struct not used on its header yet.
@(private = "file")
next_poly_name :: proc(n: Node, value: bool) -> string {
	TYPE_NAMES :: [?]string{"T", "U", "V", "W", "K", "E", "P", "Q"}
	VALUE_NAMES :: [?]string{"N", "M", "L", "SIZE", "COUNT"}
	used :: proc(n: Node, s: string) -> bool {
		for f in n.fields do if f.editable && f.text == s do return true
		return false
	}
	if value {
		names := VALUE_NAMES
		for s in names do if !used(n, s) do return s
	} else {
		names := TYPE_NAMES
		for s in names do if !used(n, s) do return s
	}
	return value ? "N" : "T"
}

// apply_types_fill applies one of the TY_* fills to field fi of line ni (a dot,
// or a filled type being changed): the field is replaced by the new fields.
// The parameter fills keep the params dot and add the parameter before it.
apply_types_fill :: proc(app: ^App, ni, fi: int, fill: string) {
	if ni < 0 || ni >= len(app.doc.nodes) do return
	fields := &app.doc.nodes[ni].fields
	if fi < 0 || fi >= len(fields) do return

	if fill == TY_UNWRAP {
		a, b, ok := wrapper_span(app.doc.nodes[ni], fi)
		if !ok do return
		for i in a ..< b do if len(fields[i].text) > 0 do delete(fields[i].text)
		remove_range(fields, a, b)
		return
	}

	if fill == TY_TPARAM || fill == TY_VPARAM {
		name := next_poly_name(app.doc.nodes[ni], fill == TY_VPARAM)
		if fill == TY_TPARAM {
			inject_at(fields, fi, fixed(", $"), Field{strings.clone(name), true, false, "poly", "", ""}, fixed(": typeid"))
		} else {
			inject_at(fields, fi, fixed(", $"), Field{strings.clone(name), true, false, "poly", "", ""}, fixed(": "), type_dot())
		}
		return
	}

	list := make([dynamic]Field, 0, 6, context.temp_allocator)
	switch fill {
	case TY_ARRAY:     append(&list, fixed("["), int_dot(), fixed("]"), type_dot())
	case TY_SLICE:     append(&list, fixed("[]"), type_dot())
	case TY_DYNAMIC:   append(&list, fixed("[dynamic]"), type_dot())
	case TY_MAP:       append(&list, fixed("map["), type_dot(), fixed("]"), type_dot())
	case TY_POINTER:   append(&list, fixed("^"), type_dot())
	case TY_MULTI_PTR: append(&list, fixed("[^]"), type_dot())
	case TY_RANGE:     append(&list, fixed("0..<"), int_dot())
	case TY_FIELD, TY_USING, TY_BITS:
		name := generate_ident(app)
		if fill == TY_USING do append(&list, fixed("using "))
		append(&list, Field{name, true, false, "member", "", ""}, fixed(": "), type_dot()) // name: ownership moves
		if fill == TY_BITS do append(&list, fixed(" | "), int_dot())
		append(&list, fixed(","))
	case TY_MEMBER, TY_MEMBER_EQ:
		name := generate_type(app)
		append(&list, Field{name, true, false, "member", "", ""})
		if fill == TY_MEMBER_EQ do append(&list, fixed(" = "), int_dot())
		append(&list, fixed(","))
	case TY_VARIANT:
		append(&list, type_dot(), fixed(","))
	}
	if len(list) == 0 do return
	fields = &app.doc.nodes[ni].fields
	if len(fields[fi].text) > 0 do delete(fields[fi].text)
	ordered_remove(fields, fi)
	inject_at(fields, fi, ..list[:])
	switch fill {
	case TY_FIELD, TY_USING, TY_BITS, TY_MEMBER, TY_MEMBER_EQ, TY_VARIANT:
		// The member above may lack its comma (`hp: int` written by hand).
		ensure_prev_member_comma(app, ni) // data_member_edit.odin
	}
}

// ---- Unwrapping a composite ----

// wrapper_span: the fields [a, b) of the composite directly around the type at
// field fi - `[`8`]` in `[8]int`, `^` in `^int`, `map[`string`]` in
// `map[string]int` (fi = the value type). ok=false when it isn't wrapped.
@(private = "file")
wrapper_span :: proc(n: Node, fi: int) -> (a, b: int, ok: bool) {
	if fi < 1 || fi >= len(n.fields) do return
	fs := n.fields
	plain :: proc(f: Field) -> bool { return !f.slot && !f.editable }
	p := fi - 1
	if !plain(fs[p]) do return
	switch fs[p].text {
	case "[]", "[dynamic]", "^", "[^]":
		return p, fi, true
	case "]":
		if p >= 2 && plain(fs[p - 2]) && fs[p - 2].text == "[" && !plain(fs[p - 1]) do return p - 2, fi, true            // [N]T
		if p >= 2 && plain(fs[p - 2]) && fs[p - 2].text == "map[" && !plain(fs[p - 1]) do return p - 2, fi, true         // map[K]V
	}
	return
}

// unwrap_entry: for the type edit menu of field fi - "Drop [8]" etc. when the
// type sits inside a composite. ok=false otherwise.
unwrap_entry :: proc(app: ^App, ni, fi: int) -> (Entry, bool) {
	if ni < 0 || ni >= len(app.doc.nodes) do return {}, false
	n := app.doc.nodes[ni]
	a, b, ok := wrapper_span(n, fi)
	if !ok do return {}, false
	label := fmt.aprintf("Drop %s", fields_text(n.fields[a:b]))
	return Entry{label = label, owned_label = true, fill = TY_UNWRAP}, true
}

// ---- New declarations (Add > Types) ----

// append_data_header inserts a polymorphic struct or a bit_field: the header,
// a "●" member line and the closing brace.
//   Stack :: struct($T: typeid●) {      Packed :: bit_field ● {
append_data_header :: proc(app: ^App, kind, type_name: string) {
	n1: Node
	append(&n1.fields, Field{strings.clone(type_name), true, false, "", "", ""})
	switch kind {
	case "poly_struct":
		append(&n1.fields, fixed(" :: struct($"), Field{strings.clone("T"), true, false, "poly", "", ""}, fixed(": typeid"))
		append(&n1.fields, Field{"", false, true, "params", "", ""}, fixed(") {"))
	case "bit_field":
		append(&n1.fields, fixed(" :: bit_field "), type_dot(), fixed(" {"))
	}
	doc_insert(app, n1)
	n2: Node
	append(&n2.fields, fixed("    "), Field{"", false, true, "body", "", ""})
	doc_insert(app, n2)
	n3: Node
	append(&n3.fields, fixed("}"))
	doc_insert(app, n3)
}

// ---- Deleting parts of a declaration (LT+B) ----

@(private = "file")
fields_text :: proc(fs: []Field) -> string {
	b := strings.builder_make(context.temp_allocator)
	for f in fs do strings.write_string(&b, f.text)
	return strings.to_string(b)
}

// Replace line ni with the declaration `txt` re-read (keeps the structure right).
@(private = "file")
reread_decl :: proc(app: ^App, ni: int, txt: string) -> bool {
	out := make([dynamic]Field, 0, 8)
	if !emit_type_decl_line(&out, txt) {
		for f in out do if len(f.text) > 0 do delete(f.text)
		delete(out)
		return false
	}
	n := &app.doc.nodes[ni]
	for f in n.fields do if len(f.text) > 0 do delete(f.text)
	delete(n.fields)
	n.fields = out
	split_modifiers(n) // `#align(8)` / `#packed` stay keyword fields, as after loading
	return true
}

// delete_type_part: LT+B on a polymorphic struct's parameter removes just that
// parameter; on a member of a one-line body (`enum { North, South }`) just that
// member. False when the field is neither (delete_selected does the rest).
delete_type_part :: proc(app: ^App, ni, fi: int) -> bool {
	if ni < 0 || ni >= len(app.doc.nodes) do return false
	fs := app.doc.nodes[ni].fields[:]
	if fi < 0 || fi >= len(fs) do return false

	if fs[fi].editable && fs[fi].kind == "poly" {
		first, slot := -1, -1
		for g, i in fs {
			if g.slot && g.kind == "params" { slot = i; break }
			if first < 0 && !g.slot && !g.editable && strings.has_suffix(g.text, "$") do first = i
		}
		if first < 0 || slot < 0 || fi < first || fi > slot do return false
		kept := make([dynamic]string, 0, 4, context.temp_allocator)
		for s := first; s < slot; {
			e := s + 1
			for e < slot && !(!fs[e].slot && !fs[e].editable && strings.has_suffix(fs[e].text, "$")) do e += 1
			seg := fields_text(fs[s + 1:e])
			if !(fi > s && fi < e) {
				append(&kept, strings.concatenate({"$", seg}, context.temp_allocator))
			} else if c := strings.index_byte(seg, ':'); c >= 0 && len(kept) > 0 && strings.index_byte(kept[len(kept) - 1], ':') < 0 {
				// `$K, $V: typeid` without V: K keeps the shared type (`$K: typeid`).
				kept[len(kept) - 1] = strings.concatenate({kept[len(kept) - 1], seg[c:]}, context.temp_allocator)
			}
			s = e
		}
		head := strings.trim_right_space(strings.trim_suffix(fields_text(fs[:first + 1]), "$"))
		base := strings.trim_right_space(strings.trim_suffix(head, "("))
		tail := fields_text(fs[slot + 1:])
		if !strings.has_prefix(tail, ")") do return false
		txt: string
		if len(kept) > 0 {
			txt = strings.concatenate({base, "(", strings.join(kept[:], ", ", context.temp_allocator), tail}, context.temp_allocator)
		} else {
			txt = strings.concatenate({base, tail[1:]}, context.temp_allocator)
		}
		if !reread_decl(app, ni, txt) do return false
		focus_line(app, ni)
		return true
	}

	// A member of a one-line body: between the field holding `{` and the one holding `}`.
	ob, cb := -1, -1
	for g, i in fs {
		if g.slot || g.editable do continue
		if ob < 0 && strings.contains(g.text, "{") do ob = i
		if strings.contains(g.text, "}") do cb = i
	}
	if ob < 0 || cb <= ob || fi <= ob || fi >= cb {
		return delete_shared_member_name(app, ni, fi) // `\tname, title: string,` in a multi-line body
	}
	if data_kind_of_line(fields_text(fs)) == .None do return false
	s := fi
	for s > ob + 1 && !is_member_sep(fs[s - 1]) do s -= 1
	e := fi + 1
	for e < cb && !is_member_sep(fs[e]) do e += 1
	// The last name of a shared list (`x, y: f32`): `y` takes only itself and
	// the separator before it (`x: f32`); its type takes the whole list.
	if span_has_type(fs[s:e]) && s - 2 > ob && is_member_sep(fs[s - 1]) && is_bare_name(fs[s - 2]) {
		if fi == s && fs[fi].kind == "member" {
			e = s + 1
			s -= 1
		} else {
			for s - 2 > ob && is_member_sep(fs[s - 1]) && is_bare_name(fs[s - 2]) do s -= 2
			if e < cb do e += 1
			else if s > ob + 1 do s -= 1
		}
	} else {
		// Remove the member and one separator next to it.
		if e < cb do e += 1
		else if s > ob + 1 do s -= 1
	}
	txt := strings.concatenate({fields_text(fs[:s]), fields_text(fs[e:])}, context.temp_allocator)
	// An emptied body: `{}`.
	if open := strings.index_byte(txt, '{'); open >= 0 {
		if close := matching_close(txt, open); close > open && strings.trim_space(txt[open + 1:close]) == "" {
			txt = strings.concatenate({txt[:open + 1], txt[close:]}, context.temp_allocator)
		}
	}
	if !reread_decl(app, ni, txt) do return false
	focus_line(app, ni)
	return true
}

// ---- Loading: give type declarations their structure ----

@(private = "file")
put_fixed :: proc(out: ^[dynamic]Field, s: string) {
	if s != "" do append(out, Field{strings.clone(s), false, false, "", "", ""})
}
@(private = "file")
put_name :: proc(out: ^[dynamic]Field, s, kind: string) {
	append(out, Field{strings.clone(s), true, false, kind, "", ""})
}

// emit_type: the fields of a type expression, as the Type / Composite menus build it.
emit_type :: proc(out: ^[dynamic]Field, t: string) {
	if t == "" do return
	switch {
	case word_prefix(t, "distinct"):
		k := skip_ws(t, len("distinct"))
		put_fixed(out, t[:k])
		emit_type(out, t[k:])
		return
	case strings.has_prefix(t, "[^]"), strings.has_prefix(t, "[]"), strings.has_prefix(t, "[dynamic]"), strings.has_prefix(t, "^"):
		k := strings.index_byte(t, ']') + 1 if t[0] == '[' else 1
		put_fixed(out, t[:k])
		emit_type(out, t[k:])
		return
	case strings.has_prefix(t, "map["):
		close := matching_close(t, 3)
		if close > 4 && close + 1 < len(t) {
			put_fixed(out, "map[")
			emit_type(out, t[4:close])
			put_fixed(out, "]")
			emit_type(out, t[close + 1:])
			return
		}
	case strings.has_prefix(t, "bit_set["):
		close := matching_close(t, 7)
		if close > 8 {
			put_fixed(out, "bit_set[")
			emit_bit_set_inner(out, t[8:close])
			put_fixed(out, t[close:])
			return
		}
	case strings.has_prefix(t, "["):
		close := matching_close(t, 0)
		if close > 0 && close + 1 < len(t) {
			if is_simple_value(t[1:close]) {
				put_fixed(out, "[")
				put_name(out, t[1:close], "")
				put_fixed(out, "]")
			} else {
				put_fixed(out, t[:close + 1])
			}
			emit_type(out, t[close + 1:])
			return
		}
	}
	if is_simple_type(t) do put_name(out, t, "type")
	else do put_fixed(out, t)
}

// `Dir`, `0..<8`, `Dir; u8` inside bit_set[...].
@(private = "file")
emit_bit_set_inner :: proc(out: ^[dynamic]Field, s: string) {
	semi := strings.index_byte(s, ';')
	elem := s if semi < 0 else s[:semi]
	switch {
	case strings.has_prefix(elem, "0..<") && is_simple_value(elem[4:]):
		put_fixed(out, "0..<")
		put_name(out, elem[4:], "")
	case is_simple_type(elem):
		put_name(out, elem, "type")
	case:
		put_fixed(out, elem)
	}
	if semi >= 0 {
		k := skip_ws(s, semi + 1)
		ty := strings.trim_right_space(s[k:])
		put_fixed(out, s[semi:k])
		emit_type(out, ty)
		put_fixed(out, s[k + len(ty):])
	}
}

// One member (trimmed, without its comma) of a data body.
@(private = "file")
emit_member :: proc(out: ^[dynamic]Field, kind: Data_Kind, m: string) -> bool {
	switch kind {
	case .Union:
		emit_type(out, m)
		return true
	case .Enum:
		ne := scan_ident(m, 0)
		if ne == 0 do return false
		put_name(out, m[:ne], "member")
		if ne == len(m) do return true
		k := skip_ws(m, ne)
		if k >= len(m) || m[k] != '=' do return false
		k2 := skip_ws(m, k + 1)
		if k2 >= len(m) do return false
		put_fixed(out, m[ne:k2])
		v := m[k2:]
		if is_simple_value(v) do put_name(out, v, "")
		else do put_fixed(out, v)
		return true
	case .Struct, .Bit_Field:
		k := 0
		if kind == .Struct {
			for p in ([]string{"using ", "#subtype "}) {
				if strings.has_prefix(m, p) {
					k = skip_ws(m, len(p))
					put_fixed(out, m[:k])
					break
				}
			}
		}
		ne := scan_ident(m, k)
		if ne == k do return false
		put_name(out, m[k:ne], "member")
		if ne == len(m) do return k == 0 // one of the names in `x, y: f32`
		k2 := skip_ws(m, ne)
		if k2 >= len(m) || m[k2] != ':' do return false
		k3 := skip_ws(m, k2 + 1)
		put_fixed(out, m[ne:k3])
		stop := len(m)
		if kind == .Struct {
			if tag := strings.index_byte(m[k3:], '`'); tag >= 0 do stop = k3 + tag
		} else {
			if bar := strings.index_byte(m[k3:], '|'); bar >= 0 do stop = k3 + bar
		}
		ty := strings.trim_right_space(m[k3:stop])
		if ty == "" do return false
		emit_type(out, ty)
		if kind == .Bit_Field && stop < len(m) {
			b := skip_ws(m, stop + 1)
			put_fixed(out, m[k3 + len(ty):b])
			bits := m[b:]
			if is_simple_value(bits) do put_name(out, bits, "")
			else do put_fixed(out, bits)
		} else {
			put_fixed(out, m[k3 + len(ty):])
		}
		return true
	case .None:
	}
	return false
}

// A comma-separated member list (`hp: int,` or `North, South`).
@(private = "file")
emit_member_list :: proc(out: ^[dynamic]Field, kind: Data_Kind, s: string) -> bool {
	prev := 0
	any := false
	for sp in comma_spans(s) {
		a, b := sp[0], sp[1]
		for a < b && is_ws(s[a]) do a += 1
		for b > a && is_ws(s[b - 1]) do b -= 1
		if a == b do continue
		put_fixed(out, s[prev:a])
		if !emit_member(out, kind, s[a:b]) do return false
		prev = b
		any = true
	}
	put_fixed(out, s[prev:])
	return any
}

// A line inside a data body: indentation, members, then any comment.
@(private = "file")
emit_member_line :: proc(out: ^[dynamic]Field, kind: Data_Kind, txt: string) -> bool {
	ind := skip_ws(txt, 0)
	cs := comment_start(txt)
	if cs < ind do return false
	code := strings.trim_right_space(txt[ind:cs])
	if code == "" || strings.contains_any(code, "{}") do return false
	if strings.has_prefix(code, "#") && !strings.has_prefix(code, "#subtype ") do return false
	put_fixed(out, txt[:ind])
	if !emit_member_list(out, kind, code) do return false
	put_fixed(out, txt[ind + len(code):])
	return true
}

// The rest of a block declaration from (just before) its `{`: the header text,
// and the members when the whole body is on this line.
@(private = "file")
emit_block_tail :: proc(out: ^[dynamic]Field, kind: Data_Kind, text: string) {
	ob := strings.index_byte(text, '{')
	cb := ob >= 0 ? matching_close(text, ob) : -1
	if cb < 0 {
		put_fixed(out, text)
		return
	}
	inner := text[ob + 1:cb]
	it := strings.trim_space(inner)
	if it == "" {
		put_fixed(out, text)
		return
	}
	a := ob + 1 + len(inner) - len(strings.trim_left_space(inner))
	b := a + len(it)
	save := len(out)
	put_fixed(out, text[:a])
	if !emit_member_list(out, kind, it) {
		for i in save ..< len(out) do if len(out[i].text) > 0 do delete(out[i].text)
		resize(out, save)
		put_fixed(out, text)
		return
	}
	put_fixed(out, text[b:])
}

// `$T: typeid, $N: int` of a polymorphic struct; `head` is ` :: struct(`.
@(private = "file")
emit_poly_params :: proc(out: ^[dynamic]Field, head, inner: string) -> bool {
	for sp, i in comma_spans(inner) {
		p := inner[sp[0]:sp[1]]
		k := skip_ws(p, 0)
		if k >= len(p) || p[k] != '$' do return false
		k += 1
		ne := scan_ident(p, k)
		if ne == k do return false
		put_fixed(out, strings.concatenate({i == 0 ? head : ",", p[:k]}, context.temp_allocator))
		put_name(out, p[k:ne], "poly")
		rest := p[ne:]
		r := strings.trim_left_space(rest)
		if strings.has_prefix(r, ":") {
			k2 := skip_ws(rest, len(rest) - len(r) + 1)
			ty := strings.trim_right_space(rest[k2:])
			if ty == "typeid" || ty == "" {
				put_fixed(out, rest)
			} else {
				put_fixed(out, rest[:k2])
				emit_type(out, ty)
				put_fixed(out, rest[k2 + len(ty):])
			}
		} else {
			put_fixed(out, rest)
		}
	}
	append(out, Field{"", false, true, "params", "", ""})
	return true
}

// `Name :: <type>` (any indentation): the name, then the type's structure.
// False when the line isn't a type declaration (procs, constants, ...).
emit_type_decl_line :: proc(out: ^[dynamic]Field, txt: string) -> bool {
	ind := skip_ws(txt, 0)
	// An attribute before the name on the same line: `@(private) Player :: struct {`
	// (kept with the indentation as one fixed field).
	if ind < len(txt) && txt[ind] == '@' {
		a := ind + 1
		if a < len(txt) && txt[a] == '(' {
			close := matching_close(txt, a)
			if close < 0 do return false
			a = close + 1
		} else {
			e := scan_ident(txt, a)
			if e == a do return false
			a = e
		}
		b := skip_ws(txt, a)
		if b == a do return false
		ind = b
	}
	ne := scan_ident(txt, ind)
	if ne == ind do return false
	k := skip_ws(txt, ne)
	if !strings.has_prefix(txt[k:], "::") do return false
	op_end := skip_ws(txt, k + 2)
	cs := comment_start(txt)
	if cs < op_end do return false
	code_end := len(strings.trim_right_space(txt[:cs]))
	if code_end <= op_end do return false
	rhs := txt[op_end:code_end]
	sep := txt[ne:op_end]
	cat :: proc(a, b: string) -> string { return strings.concatenate({a, b}, context.temp_allocator) }

	save := len(out)
	put_fixed(out, txt[:ind])
	put_name(out, txt[ind:ne], "")
	ok := true
	switch {
	case word_prefix(rhs, "struct") || word_prefix(rhs, "union"):
		kind := word_prefix(rhs, "struct") ? Data_Kind.Struct : Data_Kind.Union
		kw := kind == .Struct ? len("struct") : len("union")
		if kw < len(rhs) && rhs[kw] == '(' {
			close := matching_close(rhs, kw)
			if close < 0 || !emit_poly_params(out, cat(sep, rhs[:kw + 1]), rhs[kw + 1:close]) {
				ok = false
				break
			}
			emit_block_tail(out, kind, rhs[close:])
		} else {
			emit_block_tail(out, kind, cat(sep, rhs))
		}
	case word_prefix(rhs, "enum") || word_prefix(rhs, "bit_field"):
		kind := word_prefix(rhs, "enum") ? Data_Kind.Enum : Data_Kind.Bit_Field
		k2 := skip_ws(rhs, kind == .Enum ? len("enum") : len("bit_field"))
		if k2 < len(rhs) && rhs[k2] != '{' && rhs[k2] != '#' {
			ob := strings.index_byte(rhs, '{')
			if ob < 0 do ob = len(rhs)
			ty := strings.trim_right_space(rhs[k2:ob])
			put_fixed(out, cat(sep, rhs[:k2]))
			emit_type(out, ty)
			emit_block_tail(out, kind, rhs[k2 + len(ty):])
		} else {
			emit_block_tail(out, kind, cat(sep, rhs))
		}
	case strings.contains_any(rhs, "{}()"):
		ok = false
	case word_prefix(rhs, "distinct"):
		k2 := skip_ws(rhs, len("distinct"))
		if k2 >= len(rhs) { ok = false; break }
		put_fixed(out, cat(sep, rhs[:k2]))
		emit_type(out, rhs[k2:])
	case strings.has_prefix(rhs, "bit_set["):
		close := matching_close(rhs, 7)
		if close < 9 { ok = false; break }
		put_fixed(out, cat(sep, "bit_set["))
		emit_bit_set_inner(out, rhs[8:close])
		put_fixed(out, rhs[close:])
	case is_type_rhs(rhs) || (is_simple_type(rhs) && rhs in decl_type_names):
		// (`Alias :: Player`: an alias of a type declared in this file.)
		put_fixed(out, sep)
		emit_type(out, rhs)
	case:
		ok = false
	}
	if !ok {
		for i in save ..< len(out) do if len(out[i].text) > 0 do delete(out[i].text)
		resize(out, save)
		return false
	}
	put_fixed(out, txt[code_end:])
	return true
}

// The document's declared type names while structure_type_decls runs (so
// `Alias :: Player` reads as a type alias). Temp-allocated; nil otherwise.
@(thread_local) // tests load documents on several threads
decl_type_names: map[string]bool

// A line as parse_line leaves it: one fixed field, or `name` + ` :: rest`.
@(private = "file")
is_plain_line :: proc(n: Node) -> bool {
	for f in n.fields do if f.slot do return false
	switch len(n.fields) {
	case 1: return !n.fields[0].editable
	case 2:
		a, b := n.fields[0], n.fields[1]
		return a.editable && a.kind == "" && !b.editable && strings.has_prefix(strings.trim_left_space(b.text), "::")
	case 3: // the same, indented inside a file-scope `when` (parse_indented_line)
		w, a, b := n.fields[0], n.fields[1], n.fields[2]
		return !w.editable && w.text != "" && strings.trim_space(w.text) == "" &&
			a.editable && a.kind == "" && !b.editable && strings.has_prefix(strings.trim_left_space(b.text), "::")
	}
	return false
}

// Split filled type fields holding a composite type (`[8]int` read from
// `x: [8]int = ...`) into the composite's parts, as the menus build them.
@(private = "file")
split_type_fields :: proc(n: ^Node) {
	for fi := 0; fi < len(n.fields); fi += 1 {
		f := n.fields[fi]
		if f.slot || !f.editable || f.kind != "type" do continue
		if !is_composite_text(f.text) && !word_prefix(f.text, "distinct") && !strings.has_prefix(f.text, "bit_set[") do continue
		parts := make([dynamic]Field, 0, 6, context.temp_allocator)
		emit_type(&parts, f.text)
		if fields_text(parts[:]) != f.text || len(parts) <= 1 {
			for p in parts do if len(p.text) > 0 do delete(p.text)
			continue
		}
		delete(f.text)
		ordered_remove(&n.fields, fi)
		inject_at(&n.fields, fi, ..parts[:])
		fi += len(parts) - 1
	}
}

// structure_type_decls (run by doc_from_source): type declarations and the
// members of data bodies get the same fields the menus build.
structure_type_decls :: proc(app: ^App) {
	decl_type_names = doc_declared_type_names(app) // data_member_edit.odin
	defer decl_type_names = nil
	stack := make([dynamic]Data_Kind, 0, 8, context.temp_allocator)
	for i in 0 ..< len(app.doc.nodes) {
		n := &app.doc.nodes[i]
		txt := node_text(n^, context.temp_allocator)
		top := len(stack) > 0 ? stack[len(stack) - 1] : Data_Kind.None
		if is_plain_line(n^) {
			out := make([dynamic]Field, 0, 8)
			ok: bool
			if top != .None do ok = emit_member_line(&out, top, txt)
			else do ok = emit_type_decl_line(&out, txt)
			if ok && fields_text(out[:]) == txt {
				for f in n.fields do if len(f.text) > 0 do delete(f.text)
				delete(n.fields)
				n.fields = out
			} else {
				for f in out do if len(f.text) > 0 do delete(f.text)
				delete(out)
			}
		} else {
			split_type_fields(n)
		}
		data_track_braces(&stack, txt)
	}
}

// For tests / debugging: a line's fields as `[text]` pieces (dots as ●).
fields_debug :: proc(n: Node) -> string {
	b := strings.builder_make(context.temp_allocator)
	for f in n.fields {
		if f.slot do fmt.sbprintf(&b, "[●%s]", f.kind)
		else do fmt.sbprintf(&b, "[%s]", f.text)
	}
	return strings.to_string(b)
}

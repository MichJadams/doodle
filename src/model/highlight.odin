package model

// Syntax highlighting: classify every byte of a line of Odin source.
// Works on whole-line text (fields are concatenated first), so a keyword or a
// `name(` call is recognized even when it spans several fields.

Hl :: enum u8 {
	Plain,
	Keyword,  // proc, return, if, for, #force_inline ...
	Type,     // int, string, HWND, Some_Struct
	String,   // "..." `...` '.'
	Number,   // 42, 0xFF, 1.5
	Constant, // true, false, nil, MB_OK
	Comment,  // // ...
	Func,     // name followed by (
	Package,  // name followed by .   (fmt.println, win.MB_OK)
}

@(private = "file")
KEYWORDS := [?]string{
	"package", "import", "foreign", "proc", "struct", "enum", "union", "bit_set", "bit_field",
	"distinct", "map", "matrix", "dynamic", "return", "if", "else", "when", "for", "in",
	"not_in", "switch", "case", "break", "continue", "fallthrough", "defer", "using",
	"or_return", "or_else", "or_break", "or_continue", "do", "where", "cast", "transmute",
	"auto_cast", "context",
}

@(private = "file")
TYPES := [?]string{
	"int", "uint", "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128",
	"uintptr", "f16", "f32", "f64", "complex64", "complex128", "quaternion128", "quaternion256",
	"bool", "b8", "b16", "b32", "b64", "string", "cstring", "string16", "cstring16",
	"rune", "byte", "rawptr", "typeid", "any",
}

@(private = "file")
is_ident_start :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' }
@(private = "file")
is_ident_char :: proc(c: u8) -> bool { return is_ident_start(c) || (c >= '0' && c <= '9') }

// Odin naming conventions: Ada_Case / PascalCase = type, SCREAMING_CASE = constant.
@(private = "file")
classify_ident :: proc(w: string) -> Hl {
	for k in KEYWORDS do if k == w do return .Keyword
	for t in TYPES do if t == w do return .Type
	if w == "true" || w == "false" || w == "nil" do return .Constant
	if w[0] >= 'A' && w[0] <= 'Z' {
		has_lower := false
		for c in transmute([]u8)w do if c >= 'a' && c <= 'z' { has_lower = true; break }
		if !has_lower && len(w) > 1 do return .Constant
		if has_lower do return .Type
	}
	return .Plain
}

@(private = "file")
is_package :: proc(word: string, packages: []string) -> bool {
	if packages == nil do return true
	for p in packages do if p == word do return true
	return false
}

// Is the identifier starting at s[i] in a type position? Looks back over an
// optional `pkg.` qualifier and spaces for `:` (not `::`), `->`, `^` or `]`.
@(private = "file")
in_type_position :: proc(s: string, i: int) -> bool {
	k := i
	if k > 0 && s[k - 1] == '.' { // skip `win.`
		k -= 1
		for k > 0 && is_ident_char(s[k - 1]) do k -= 1
	}
	for k > 0 && s[k - 1] == ' ' do k -= 1
	if k == 0 do return false
	switch s[k - 1] {
	case ':': return k < 2 || s[k - 2] != ':'
	case '>': return k >= 2 && s[k - 2] == '-'
	case '^', ']': return true
	}
	return false
}

// highlight returns one Hl per byte of `s` (temp-allocated by default).
// `packages` are the import names in scope ("win", "fmt"): `name.` is colored as a
// package only for those (so `p.name` field access stays plain). nil = any `name.`.
highlight :: proc(s: string, packages: []string = nil, allocator := context.temp_allocator) -> []Hl {
	out := make([]Hl, len(s), allocator)
	i := 0
	for i < len(s) {
		c := s[i]
		switch {
		case c == '/' && i + 1 < len(s) && s[i + 1] == '/':
			for j in i ..< len(s) do out[j] = .Comment
			return out
		case c == '"' || c == '\'' || c == '`':
			j := i + 1
			for j < len(s) && s[j] != c {
				if s[j] == '\\' && c != '`' do j += 1
				j += 1
			}
			j = min(j + 1, len(s))
			for k in i ..< j do out[k] = .String
			i = j
		case c >= '0' && c <= '9':
			j := i
			for j < len(s) && (is_ident_char(s[j]) || s[j] == '.') do j += 1
			for k in i ..< j do out[k] = .Number
			i = j
		case c == '#' && i + 1 < len(s) && is_ident_start(s[i + 1]):
			j := i + 1
			for j < len(s) && is_ident_char(s[j]) do j += 1
			for k in i ..< j do out[k] = .Keyword // #force_inline, #partial, ...
			i = j
		case is_ident_start(c):
			j := i
			for j < len(s) && is_ident_char(s[j]) do j += 1
			word := s[i:j]
			kind := classify_ident(word)
			builtin_type := false
			for ty in TYPES do if ty == word { builtin_type = true; break }
			// What follows decides calls and package qualifiers (unless it's a keyword).
			k := j
			for k < len(s) && s[k] == ' ' do k += 1
			if kind != .Keyword && !builtin_type && k < len(s) {
				if s[k] == '(' do kind = .Func                                   // MessageBoxW(
				else if s[k] == '.' && j == k && kind == .Plain && is_package(s[i:j], packages) do kind = .Package // win.
			}
			// Type position wins over naming style: `x: RECT`, `-> HWND`, `^Foo`, `[]u8`, `: win.RECT`.
			if kind == .Constant && word != "nil" && word != "true" && word != "false" && in_type_position(s, i) {
				kind = .Type
			}
			for m in i ..< j do out[m] = kind
			i = j
		case:
			i += 1 // punctuation / spaces stay Plain
		}
	}
	return out
}

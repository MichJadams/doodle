package model

// Enumerated arrays: `[Dir]f32` is indexed by a Dir (`arr[.North]`), and
// `for v, d in arr` gives d the type Dir (index_fill.odin, loops.odin).

import "core:strings"

// enum_index_type: the enum type named by `inside` (the text between an array
// type's brackets, in package pkg), or false (a length, `dynamic`, `^`, `?`, ...).
enum_index_type :: proc(app: ^App, inside: string, pkg: string) -> (Var_Type, bool) {
	s := strings.trim_space(inside)
	if s == "" || s == "?" || s == "dynamic" || s == "^" do return {}, false
	if dot := strings.index_byte(s, '.'); dot >= 0 {
		if !is_ident(s[:dot]) || !is_ident(s[dot + 1:]) do return {}, false
	} else if !is_ident(s) {
		return {}, false
	}
	// A type declared in this document (aliases followed): resolve_type doesn't analyse those.
	name, name_pkg := s, pkg
	if pkg == "" {
		for _ in 0 ..< 8 {
			if strings.index_byte(name, '.') >= 0 do break
			rhs, found := doc_type_rhs_type(app, name) // (another file's alias may name a package's type)
			if !found do break
			r := strings.trim_space(rhs.expr)
			for strings.has_prefix(r, "distinct ") do r = strings.trim_space(r[len("distinct "):])
			if strings.has_prefix(r, "enum") do return Var_Type{s, pkg}, true
			dot := strings.index_byte(r, '.')
			if !(is_ident(r) || (dot > 0 && is_ident(r[:dot]) && is_ident(r[dot + 1:]))) do return {}, false
			name, name_pkg = r, rhs.pkg
			if name_pkg != "" do break
		}
	}
	ctx := type_ctx_make(app)
	if resolve_type(&ctx, name, name_pkg).cat != .Enum do return {}, false
	return Var_Type{s, pkg}, true
}

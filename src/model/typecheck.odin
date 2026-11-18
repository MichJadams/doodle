package model

// Lightweight type checking for fill menus: given the type a slot expects
// (Field.hint, e.g. "LPCWSTR" in core:sys/windows), work out what *kind* of
// type it is by following CORE_TYPES aliases/distincts down to a builtin
// (LPCWSTR -> wstring -> cstring16), then decide which fill options can fit:
//   - literals (Number, "...", true/false, nil, ...) by category, following
//     Odin's untyped-constant rules ("..." fits cstring16, true fits BOOL :: distinct b32)
//   - calls by return type: same type after aliases (distinct types must match by name)
// Anything we can't resolve is Unknown and never grayed out.

import "core:strings"

Type_Cat :: enum {
	Unknown, Any, Integer, Float, Rune, Bool, String, CString, CString16,
	Pointer, Slice, Array, Map, Proc, Struct, Enum, Union, BitSet, Typeid,
	Multi, // several return values
}

Resolved_Type :: struct {
	cat:   Type_Cat,
	canon: string, // identity for "same type": builtin name, or "<path>.<Name>" of the first non-alias type
}

// Cache of resolutions for one menu build (temp-allocated).
Type_Ctx :: struct {
	app:   ^App,
	cache: map[string]Resolved_Type,
}

type_ctx_make :: proc(app: ^App) -> Type_Ctx {
	return Type_Ctx{app = app, cache = make(map[string]Resolved_Type, 64, context.temp_allocator)}
}

@(private = "file")
builtin_cat :: proc(name: string) -> (Type_Cat, bool) {
	switch name {
	case "int", "uint", "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128",
	     "i16le", "i32le", "i64le", "i128le", "u16le", "u32le", "u64le", "u128le",
	     "i16be", "i32be", "i64be", "i128be", "u16be", "u32be", "u64be", "u128be",
	     "uintptr", "byte":
		return .Integer, true
	case "f16", "f32", "f64", "f16le", "f32le", "f64le", "f16be", "f32be", "f64be":
		return .Float, true
	case "complex32", "complex64", "complex128", "quaternion64", "quaternion128", "quaternion256":
		return .Float, true
	case "rune":                       return .Rune, true
	case "bool", "b8", "b16", "b32", "b64": return .Bool, true
	case "string", "string16":         return .String, true
	case "cstring":                    return .CString, true
	case "cstring16":                  return .CString16, true
	case "rawptr":                     return .Pointer, true
	case "typeid":                     return .Typeid, true
	case "any":                        return .Any, true
	}
	return .Unknown, false
}

// Import path for a package reference: a document import alias ("win"), or a
// core package whose last path segment is `ref` ("c" -> "core:c").
@(private = "file")
path_for_ref :: proc(ctx: ^Type_Ctx, ref, name: string) -> string {
	imports := collect_imports(ctx.app)
	defer delete(imports)
	for imp in imports do if imp.ref == ref do return imp.path
	for t in CORE_TYPES {
		if t.name != name do continue
		if t.path == strings.concatenate({"core:", ref}, context.temp_allocator) || strings.has_suffix(t.path, strings.concatenate({"/", ref}, context.temp_allocator)) {
			return t.path
		}
	}
	return ""
}

@(private = "file")
find_core_type :: proc(path, name: string) -> (CoreType, bool) {
	for t in CORE_TYPES do if t.path == path && t.name == name do return t, true
	return {}, false
}

// resolve_type works out the category and identity of a type expression
// written in package `pkg` ("" = this document / builtins).
resolve_type :: proc(ctx: ^Type_Ctx, expr: string, pkg: string, depth := 0) -> Resolved_Type {
	t := strings.trim_space(expr)
	if t == "" || depth > 16 do return {}
	key := strings.concatenate({pkg, "|", t}, context.temp_allocator)
	if r, ok := ctx.cache[key]; ok do return r
	r := resolve_uncached(ctx, t, pkg, depth)
	ctx.cache[key] = r
	return r
}

@(private = "file")
resolve_uncached :: proc(ctx: ^Type_Ctx, t: string, pkg: string, depth: int) -> Resolved_Type {
	t := t
	for strings.has_prefix(t, "distinct ") do t = strings.trim_space(t[len("distinct "):])
	switch {
	case strings.has_prefix(t, "$"):                                    return {.Unknown, ""} // polymorphic
	case strings.has_prefix(t, "("):
		return len(split_top_level(t[1:len(t) - 1])) > 1 ? Resolved_Type{.Multi, t} : Resolved_Type{}
	case strings.has_prefix(t, "^"), strings.has_prefix(t, "[^]"):     return {.Pointer, t}
	case strings.has_prefix(t, "[]"), strings.has_prefix(t, "[dynamic]"): return {.Slice, t}
	case strings.has_prefix(t, "map["):                                 return {.Map, t}
	case strings.has_prefix(t, "matrix["), strings.has_prefix(t, "#simd"), strings.has_prefix(t, "["): return {.Array, t}
	case strings.has_prefix(t, "proc"), strings.has_prefix(t, "#type"): return {.Proc, t}
	case strings.has_prefix(t, "bit_set"):                              return {.BitSet, t}
	case strings.has_prefix(t, "struct"):                               return {.Struct, t}
	case strings.has_prefix(t, "union"):                                return {.Union, t}
	case strings.has_prefix(t, "enum"):                                 return {.Enum, t}
	}

	// pkg.Name
	if dot := strings.index_byte(t, '.'); dot > 0 {
		ref, name := t[:dot], t[dot + 1:]
		if ref == "builtin" {
			if cat, ok := builtin_cat(name); ok do return {cat, name}
			return {}
		}
		path := path_for_ref(ctx, ref, name)
		if path == "" do return {}
		return resolve_type(ctx, name, path, depth + 1)
	}

	// A package's own declarations shadow builtin names (core:c has `uint :: builtin.u32`).
	ct: CoreType
	found := false
	if pkg != "" do ct, found = find_core_type(pkg, t)
	if !found {
		if cat, ok := builtin_cat(t); ok do return {cat, t}
		return {} // unknown, or a type declared in this document: not analysed (never grayed)
	}
	canon := strings.concatenate({pkg, ".", t}, context.temp_allocator)
	switch ct.kind {
	case "struct":    return {.Struct, canon}
	case "enum":      return {.Enum, canon}
	case "union":     return {.Union, canon}
	case "bit_set":   return {.BitSet, canon}
	case "bit_field": return {.Struct, canon}
	case "distinct":
		// A new named type: literals follow the underlying category; calls must match by name.
		under := resolve_type(ctx, ct.target, pkg, depth + 1)
		return {under.cat, canon}
	}
	// alias: the same type as its target
	return resolve_type(ctx, ct.target, pkg, depth + 1)
}

// literal_fits: can this literal fill a slot of category `exp`? (Odin untyped constant rules.)
literal_fits :: proc(fill: string, exp: Type_Cat) -> bool {
	if exp == .Unknown || exp == .Any do return true
	switch fill {
	case "__lit_num__":
		return exp == .Integer || exp == .Float || exp == .Rune
	case "__lit_str__", "__lit_rawstr__":
		return exp == .String || exp == .CString || exp == .CString16
	case "__lit_rune__":
		return exp == .Rune || exp == .Integer
	case "__lit_true__", "__lit_false__":
		return exp == .Bool
	case "__lit_nil__":
		#partial switch exp {
		case .Pointer, .Slice, .Map, .Proc, .Union, .CString, .CString16: return true
		}
		return false
	}
	return true
}

// value_fits: can a value of type `got` (e.g. a call's result) fill a slot expecting `exp`?
value_fits :: proc(got, exp: Resolved_Type) -> bool {
	if exp.cat == .Unknown || got.cat == .Unknown do return true
	if got.cat == .Multi do return false
	if exp.cat == .Any do return true
	return got.canon == exp.canon
}

// ret_fits: can a call returning `ret` (written in package `pkg`) fill the slot?
// A proc that returns nothing can't; an unknown return type is given the benefit of the doubt.
ret_fits :: proc(ctx: ^Type_Ctx, ret, pkg: string, exp: Resolved_Type) -> bool {
	if ret == RET_UNKNOWN do return true
	if ret == RET_NONE do return exp.cat == .Unknown
	return value_fits(resolve_type(ctx, ret, pkg), exp)
}

// entry_fits: does a fill-menu leaf fit a slot expecting `exp`?
entry_fits :: proc(ctx: ^Type_Ctx, e: Entry, exp: Resolved_Type) -> bool {
	switch e.fill {
	case "__lit_num__", "__lit_str__", "__lit_rawstr__", "__lit_rune__",
	     "__lit_true__", "__lit_false__", "__lit_nil__":
		return literal_fits(e.fill, exp.cat)
	case "__lit_ref__", "__var__", "__call_import__":
		return true // a variable / unknown proc: can't tell
	case CONST_IMPORT_FILL:
		return const_fits(ctx, e.ret, e.ret_pkg, exp)
	case OP_FILL:
		return op_fits(e.call_name, exp.cat)
	case "__call_import_proc__":
		return ret_fits(ctx, e.ret, e.ret_pkg, exp)
	case "__call_this_pkg__":
		sig := call_signature(ctx.app, "", e.call_name)
		return ret_fits(ctx, sig.ret, "", exp)
	}
	// Everything else is a type name (Type submenu): only a typeid/any slot takes a type.
	return exp.cat == .Typeid || exp.cat == .Any || exp.cat == .Unknown
}

// apply_fit_dims grays out entries that can't fill a slot expecting `exp`.
// Groups are grayed when nothing inside them fits. Returns whether anything fits.
apply_fit_dims :: proc(ctx: ^Type_Ctx, entries: []Entry, exp: Resolved_Type) -> (any_fit: bool) {
	for &e in entries {
		if len(e.children) > 0 {
			f := apply_fit_dims(ctx, e.children, exp)
			e.dim = !f
			any_fit ||= f
			continue
		}
		if e.fill == "" do continue // placeholder like "(no imports yet)": leave as is
		f := entry_fits(ctx, e, exp)
		e.dim = !f
		any_fit ||= f
	}
	return
}

// The type a slot expects, resolved (Unknown when the slot has no hint).
slot_expected_type :: proc(ctx: ^Type_Ctx, f: Field) -> Resolved_Type {
	if f.hint == "" do return {}
	return resolve_type(ctx, f.hint, f.hint_pkg)
}

package model

// Built-in procedures: callable without an import. Checked against
// C:/Odin/base/builtin/builtin.odin (compiler built-ins) and the @builtin
// procedures of base:runtime (core_builtin.odin: make, append, delete, ...).
// The Calls -> Built-in menu lists them in this order; call_signature
// (calls.odin) uses req/variadic/ret for the argument dots.
//   req      = required arguments (optional ones like `allocator := ...` aren't counted)
//   variadic = may take more (procedure groups whose members' arity differs, `..T`)
//   ret      = return type (RET_NONE "" = nothing, RET_UNKNOWN "?" = depends on the arguments)
// Left out: quaternion (its arguments must be named, which positional dots can't
// express), and the per-type members of the groups above (append_elem, make_slice, ...).

Builtin_Arity :: struct { name: string, req: int, variadic: bool, ret: string }

BUILTIN_PROCS := [?]Builtin_Arity{
	// Lengths and sizes
	{"len", 1, false, "int"},
	{"cap", 1, false, "int"},
	{"size_of", 1, false, "int"},
	{"align_of", 1, false, "int"},
	{"offset_of", 1, true, "uintptr"},           // offset_of(T.field) / offset_of(T, field)
	{"offset_of_by_string", 2, false, "uintptr"}, // offset_of_by_string(T, "field")
	{"type_of", 1, false, "?"},
	{"type_info_of", 1, false, "?"},             // ^runtime.Type_Info
	{"typeid_of", 1, false, "typeid"},
	{"card", 1, false, "int"},                   // number of elements in a bit_set
	// Allocation
	{"make", 1, true, "?"},                      // make(T) / make(T, len) / make(T, len, cap)
	{"new", 1, false, "?"},                      // ^T
	{"new_clone", 1, false, "?"},
	{"delete", 1, false, "?"},                   // runtime.Allocator_Error
	{"free", 1, false, "?"},
	{"free_all", 0, false, "?"},
	// Dynamic arrays, slices, maps
	{"append", 2, true, "?"},                    // append(&arr, x, ...)
	{"non_zero_append", 2, true, "?"},
	{"inject_at", 3, true, "?"},                 // inject_at(&arr, index, x, ...)
	{"assign_at", 3, true, "?"},                 // assign_at(&arr, index, x, ...)
	{"pop", 1, false, "?"},
	{"pop_safe", 1, false, "?"},                 // (value, ok)
	{"pop_front", 1, false, "?"},
	{"pop_front_safe", 1, false, "?"},
	{"ordered_remove", 2, false, RET_NONE},
	{"unordered_remove", 2, false, RET_NONE},
	{"remove_range", 3, false, RET_NONE},
	{"clear", 1, false, RET_NONE},
	{"resize", 2, false, "?"},
	{"reserve", 2, false, "?"},
	{"shrink", 1, true, "?"},                    // shrink(&arr) / shrink(&arr, new_cap)
	{"copy", 2, false, "int"},
	{"delete_key", 2, false, "?"},               // (deleted_key, deleted_value)
	{"map_insert", 3, false, "?"},
	{"map_upsert", 3, false, "?"},
	{"map_entry", 2, false, "?"},
	{"raw_data", 1, false, "?"},
	// Math
	{"min", 2, true, "?"},
	{"max", 2, true, "?"},
	{"abs", 1, false, "?"},
	{"clamp", 3, false, "?"},
	{"complex", 2, false, "?"},
	{"real", 1, false, "?"},
	{"imag", 1, false, "?"},
	{"jmag", 1, false, "?"},
	{"kmag", 1, false, "?"},
	{"conj", 1, false, "?"},
	{"swizzle", 3, true, "?"},                   // swizzle(v, 0, 1, ...): at least 2 indices
	// Structs and #soa
	{"expand_values", 1, false, "?"},
	{"compress_values", 1, true, "?"},
	{"soa_zip", 1, true, "?"},
	{"soa_unzip", 1, false, "?"},
	{"container_of", 3, false, "?"},
	// Control
	{"assert", 1, true, RET_NONE},               // assert(cond) / assert(cond, "message")
	{"ensure", 1, true, RET_NONE},               // like assert, but kept in -disable-assert builds
	{"panic", 1, false, RET_NONE},
	{"unimplemented", 0, true, RET_NONE},        // unimplemented() / unimplemented("message")
	{"unreachable", 0, false, RET_NONE},
}

// builtin_proc: the entry for a built-in procedure name.
builtin_proc :: proc(name: string) -> (Builtin_Arity, bool) {
	for b in BUILTIN_PROCS do if b.name == name do return b, true
	return {}, false
}

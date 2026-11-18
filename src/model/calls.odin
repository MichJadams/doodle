package model

// Call signatures: how many argument dots a call gets, and what type each expects.
//  - one orange "value" dot per required parameter, labelled with its type
//    (Field.hint, e.g. "LPCWSTR") so the fill menu can gray out what can't fit
//  - plus a green "args" dot when the proc is variadic (e.g. fmt.println) or its
//    arity is unknown; filling an "args" dot appends another one after it, and
//    unfilled "args" dots are dropped from the saved source.

import "core:strings"

// Return-type markers: RET_NONE = returns nothing (can't be an argument),
// RET_UNKNOWN = can't tell (never grayed out).
RET_NONE    :: ""
RET_UNKNOWN :: "?"

// Arity of built-in procedures (not in CORE_PROCS).
@(private = "file")
Builtin_Arity :: struct { name: string, req: int, variadic: bool, ret: string }
@(private = "file")
BUILTIN_ARITY := [?]Builtin_Arity{
	{"len", 1, false, "int"}, {"cap", 1, false, "int"}, {"size_of", 1, false, "int"},
	{"align_of", 1, false, "int"}, {"offset_of", 2, false, "uintptr"},
	{"type_of", 1, false, "?"}, {"type_info_of", 1, false, "?"},
	{"new", 1, false, "?"}, {"free", 1, false, "?"}, {"delete", 1, false, "?"}, {"clear", 1, false, ""},
	{"raw_data", 1, false, "?"}, {"abs", 1, false, "?"}, {"panic", 1, false, ""},
	{"resize", 2, false, "?"}, {"reserve", 2, false, "?"}, {"clamp", 3, false, "?"},
	{"make", 1, true, "?"},    // make(T) / make(T, len) / make(T, len, cap)
	{"append", 2, true, "?"},  // append(&arr, x, ...)
	{"assert", 1, true, ""},   // assert(cond) / assert(cond, "message")
	{"swizzle", 1, true, "?"}, {"min", 1, true, "?"}, {"max", 1, true, "?"},
}

// One parameter of a proc signature. Strings slice the signature text.
Param :: struct {
	name:     string,
	type:     string, // "" when only a default is given (`x := 1`)
	optional: bool,   // has a default value
	variadic: bool,   // `..T` (type holds T)
}

// parse_params splits the text between a proc's parens into parameters:
//   `a, b: int`      -> a: int, b: int (grouped names share the type)
//   `x := 1`         -> optional, type unknown
//   `x: T = v`       -> optional, type T
//   `args: ..any`    -> variadic, type any
// Directives (#c_vararg, #any_int, ...), `using` and `$` are stripped.
parse_params :: proc(text: string, allocator := context.temp_allocator) -> []Param {
	out := make([dynamic]Param, 0, 4, allocator)
	pending := make([dynamic]string, 0, 2, context.temp_allocator)
	for part in split_top_level(text, context.temp_allocator) {
		s := part
		for strings.has_prefix(s, "#") { // #c_vararg, #any_int, #by_ptr, ...
			sp := strings.index_byte(s, ' ')
			if sp < 0 { s = ""; break }
			s = strings.trim_space(s[sp:])
		}
		if strings.has_prefix(s, "using ") do s = strings.trim_space(s[len("using "):])
		colon := strings.index_byte(s, ':')
		if colon < 0 {
			append(&pending, strings.trim_left(strings.trim_space(s), "$")) // shares the next type
			continue
		}
		name := strings.trim_left(strings.trim_space(s[:colon]), "$")
		rest := s[colon + 1:]
		p := Param{name = name}
		if strings.has_prefix(rest, "=") {
			p.optional = true // name := default
		} else {
			typ := rest
			if eq := strings.index_byte(typ, '='); eq >= 0 {
				p.optional = true
				typ = typ[:eq]
			}
			typ = strings.trim_space(typ)
			if strings.has_prefix(typ, "..") {
				p.variadic = true
				typ = strings.trim_space(typ[2:])
			}
			p.type = typ
		}
		for pn in pending do append(&out, Param{pn, p.type, p.optional, p.variadic})
		clear(&pending)
		append(&out, p)
	}
	// Unnamed parameters (`proc(int, string)`): the "names" are really types.
	for pn in pending do append(&out, Param{type = pn})
	return out[:]
}

// param_arity counts the parameters in the text between a proc's parens.
// Mirrors param_arity in tools/gen_core_procs.py:
//   `a, b: int` -> 2 required; `x := 1` / `x: T = 1` -> optional; `args: ..any` -> variadic.
param_arity :: proc(params: string) -> (req: int, variadic: bool) {
	for p in parse_params(params) {
		if p.variadic do variadic = true
		else if !p.optional do req += 1
	}
	return
}

// split_top_level splits on commas that aren't nested in brackets or string
// literals. Parts are trimmed; empty parts (e.g. an unfilled slot) are dropped.
split_top_level :: proc(s: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, 4, allocator)
	depth := 0
	quote: u8 = 0
	start := 0
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
		case ',':
			if depth == 0 {
				if p := strings.trim_space(s[start:i]); p != "" do append(&out, p)
				start = i + 1
			}
		}
	}
	if p := strings.trim_space(s[start:]); p != "" do append(&out, p)
	return out[:]
}

// paren_span returns the text inside the first (...) at or after `from`, and
// the index just past the closing paren.
@(private = "file")
paren_span :: proc(s: string, from: int) -> (inner: string, after: int, ok: bool) {
	open := strings.index_byte(s[from:], '(')
	if open < 0 do return "", 0, false
	open += from
	depth := 0
	for i in open ..< len(s) {
		switch s[i] {
		case '(': depth += 1
		case ')':
			depth -= 1
			if depth == 0 do return s[open + 1:i], i + 1, true
		}
	}
	return "", 0, false
}

// Everything a call needs to know about the proc it calls.
Call_Sig :: struct {
	req:      int,
	variadic: bool,
	params:   []Param, // parsed parameters ("" types when unknown); may be empty
	ret:      string,  // return type text (RET_NONE "" = returns nothing, RET_UNKNOWN "?" = can't tell)
	pkg:      string,  // import path the types are written in ("" = this document/builtin)
}

// call_signature looks up `name`: `pkg_ref` is the import reference (e.g. "fmt",
// or an alias like "win"); "" means a procedure in this file or a built-in.
// Unknown procs get req 0 + variadic: any number of args.
call_signature :: proc(app: ^App, pkg_ref, name: string) -> Call_Sig {
	if pkg_ref != "" {
		imports := collect_imports(app)
		defer delete(imports)
		path := ""
		for imp in imports do if imp.ref == pkg_ref { path = imp.path; break }
		sig := Call_Sig{variadic = true, pkg = path, ret = RET_UNKNOWN}
		found := false
		for p in CORE_PROCS {
			if p.path != path || p.name != name do continue
			if !found {
				sig = Call_Sig{p.req, p.variadic, parse_params(p.params), p.ret, path}
				found = true
			} else if p.req != sig.req || p.variadic != sig.variadic {
				// Same name in several files (e.g. per-OS): be permissive.
				sig.req = min(sig.req, p.req)
				sig.variadic = true
				sig.params = nil
				sig.ret = RET_UNKNOWN
			}
		}
		return sig
	}
	for b in BUILTIN_ARITY do if b.name == name do return Call_Sig{req = b.req, variadic = b.variadic, ret = b.ret}
	// A procedure declared in this document: read its signature line.
	for n in app.doc.nodes {
		txt := node_text(n, context.temp_allocator)
		at := strings.index(txt, " :: proc")
		if at < 0 || strings.trim_space(txt[:at]) != name do continue
		inner, after, ok := paren_span(txt, at)
		if !ok do break
		sig := Call_Sig{params = parse_params(inner)}
		sig.req, sig.variadic = param_arity(inner)
		if arrow := strings.index(txt[after:], "->"); arrow >= 0 {
			ret := txt[after + arrow + 2:]
			if brace := strings.index_byte(ret, '{'); brace >= 0 do ret = ret[:brace]
			sig.ret = strings.trim_space(ret)
		}
		return sig
	}
	return Call_Sig{variadic = true, ret = RET_UNKNOWN}
}

// call_arity: just the dot counts of call_signature.
call_arity :: proc(app: ^App, pkg_ref, name: string) -> (req: int, variadic: bool) {
	sig := call_signature(app, pkg_ref, name)
	return sig.req, sig.variadic
}

// Keep a copy of `s` alive until the document is reset (for hints that come
// from document text, which can change). Static strings needn't be interned.
intern_hint :: proc(app: ^App, s: string) -> string {
	if s == "" do return ""
	for h in app.hint_pool do if h == s do return h
	c := strings.clone(s)
	append(&app.hint_pool, c)
	return c
}

// inject_call_args inserts the argument list for a call at fields[at]:
//   no params        -> "()"
//   N required       -> "(" ● ", " ● ... ")"   (each ● knows its expected type)
//   variadic/unknown -> required dots, then a green "args" dot that repeats
// Returns how many fields were inserted.
inject_call_args :: proc(app: ^App, fields: ^[dynamic]Field, at: int, sig: Call_Sig) -> int {
	if sig.req == 0 && !sig.variadic {
		inject_at(fields, at, Field{strings.clone("()"), false, false, "", "", ""})
		return 1
	}
	// Expected types of the required params (in order) and of the variadic tail.
	hints := make([dynamic]string, 0, sig.req, context.temp_allocator)
	var_hint := ""
	for p in sig.params {
		if p.variadic do var_hint = p.type
		else if !p.optional do append(&hints, p.type)
	}
	hint_for :: proc(app: ^App, sig: Call_Sig, t: string) -> string {
		// Types from CORE_PROCS are static; types read from this document get interned.
		return sig.pkg == "" ? intern_hint(app, t) : t
	}

	list := make([dynamic]Field, 0, 2 * sig.req + 3, context.temp_allocator)
	append(&list, Field{strings.clone("("), false, false, "", "", ""})
	for i in 0 ..< sig.req {
		if i > 0 do append(&list, Field{strings.clone(", "), false, false, "", "", ""})
		h := i < len(hints) ? hint_for(app, sig, hints[i]) : ""
		append(&list, Field{"", false, true, "value", h, h != "" ? sig.pkg : ""})
	}
	if sig.variadic {
		if sig.req > 0 do append(&list, Field{strings.clone(", "), false, false, "", "", ""})
		h := hint_for(app, sig, var_hint)
		append(&list, Field{"", false, true, "args", h, h != "" ? sig.pkg : ""})
	}
	append(&list, Field{strings.clone(")"), false, false, "", "", ""})
	inject_at(fields, at, ..list[:])
	return len(list)
}

// After an "args" dot at fields[fi] was replaced by `filled` fields, add the
// next ", " + green "args" dot right after them so more args can follow.
// It expects the same type as the one just filled.
append_more_args_slot :: proc(fields: ^[dynamic]Field, fi: int, filled: int, hint := "", hint_pkg := "") {
	at := fi + max(filled, 0)
	inject_at(fields, at, Field{strings.clone(", "), false, false, "", "", ""}, Field{"", false, true, "args", hint, hint_pkg})
}

// node_source is node_text for saving: unfilled "args" dots (and the ", " in
// front of them) are left out, since they are optional extra arguments.
node_source :: proc(n: Node, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for f, i in n.fields {
		if f.slot && f.kind == "args" do continue
		if f.text == ", " && !f.slot && i + 1 < len(n.fields) {
			next := n.fields[i + 1]
			if next.slot && next.kind == "args" do continue
		}
		strings.write_string(&b, f.text)
	}
	return strings.to_string(b)
}

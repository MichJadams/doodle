package model

// Modifiers (Add menu "Modifiers"): they attach to a declaration, so choosing
// one starts a pick (like "Reference", ref_pick.odin): a banner, D-pad Up/Down
// moves between the declarations it can go on (starting at the one nearest the
// cursor), A opens its options, B cancels.
//
//   Attributes          @(private) / @(export, require_results) / @(link_name="...")
//                       on its own line above the declaration (merged into an
//                       existing @(...) line). Only the ones Odin accepts for that
//                       kind of declaration are listed. (Also: A on the purple dot
//                       above a procedure, attr_dots.odin.)
//   Struct directives   Player :: struct #packed { ... }   (#packed, #raw_union, #align(●))
//   Calling convention  callback :: proc "system" (...)    ("odin", "c", "system", ...)
//
// Each one is a keyword field (kind "kw"): Y on it opens the same options for
// its declaration (to add more / change the convention); LT+B removes it.

import "core:fmt"
import "core:strings"

modifier_entries :: proc() -> []Entry {
	return make_slice(
		Entry{label = "Attributes", special = SPECIAL_ATTR},
		Entry{label = "Struct directives", special = SPECIAL_DIRECTIVE},
		Entry{label = "Calling convention", special = SPECIAL_CALLCONV},
	)
}

// ---- What a line declares ----

Decl_Kind :: enum u8 { None, Proc, Proc_Group, Proc_Type, Struct, Type, Const, Var }

@(private = "file")
is_name_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

// classify_decl: what the (trimmed) line declares, if anything.
classify_decl :: proc(t: string) -> Decl_Kind {
	if t == "" do return .None
	switch t[0] {
	case '/', '@', '#', '}', '{', '(':
		return .None
	}
	for p in ([]string{"package ", "import ", "foreign ", "when ", "using "}) do if strings.has_prefix(t, p) do return .None
	k := 0
	for {
		st := k
		for k < len(t) && is_name_byte(t[k]) do k += 1
		if k == st || (t[st] >= '0' && t[st] <= '9') do return .None
		for k < len(t) && t[k] == ' ' do k += 1
		if k < len(t) && t[k] == ',' {
			k += 1
			for k < len(t) && t[k] == ' ' do k += 1
			continue
		}
		break
	}
	rest := t[k:]
	switch {
	case strings.has_prefix(rest, "::"):
		v := strings.trim_left_space(rest[2:])
		for p in ([]string{"#force_inline ", "#force_no_inline "}) do v = strings.trim_prefix(v, p)
		switch {
		case strings.has_prefix(v, "#type"):
			return .Proc_Type
		case strings.has_prefix(v, "proc"):
			after := strings.trim_left_space(v[4:])
			if strings.has_prefix(after, "{") do return .Proc_Group
			if strings.contains(v, "{") || strings.contains(v, "---") || strings.has_suffix(v, "(") do return .Proc
			return .Proc_Type
		case strings.has_prefix(v, "struct"):
			return .Struct
		}
		for p in ([]string{"enum", "union", "bit_set", "bit_field", "distinct"}) do if strings.has_prefix(v, p) do return .Type
		return .Const
	case strings.has_prefix(rest, ":="):
		return .Var
	case strings.has_prefix(rest, ":"):
		// `name : T : value` is a constant, `name: T` / `name: T = v` a variable.
		depth := 0
		for c in transmute([]u8)rest[1:] {
			switch c {
			case '(', '[', '{': depth += 1
			case ')', ']', '}': depth -= 1
			case ':': if depth == 0 do return .Const
			case '=': if depth == 0 do return .Var
			}
		}
		return .Var
	}
	return .None
}

@(private = "file")
line_decl_kind :: proc(app: ^App, ni: int) -> Decl_Kind {
	return classify_decl(strings.trim_space(node_text(app.doc.nodes[ni], context.temp_allocator)))
}

// An attribute line: `@(private)`, `@(link_name="x", require_results)`, `@private`.
is_attr_line :: proc(n: Node) -> bool {
	return strings.has_prefix(strings.trim_space(node_text(n, context.temp_allocator)), "@")
}

// The declaration an attribute line belongs to (the next non-attribute line), or -1.
attr_decl_line :: proc(app: ^App, ni: int) -> int {
	j := ni
	for j < len(app.doc.nodes) && is_attr_line(app.doc.nodes[j]) do j += 1
	if j < len(app.doc.nodes) && line_decl_kind(app, j) != .None do return j
	return -1
}

is_callconv_kw :: proc(f: Field) -> bool {
	return !f.slot && f.kind == KW && len(f.text) >= 2 && f.text[0] == '"'
}

is_directive_kw :: proc(f: Field) -> bool {
	return !f.slot && f.kind == KW && (f.text == "#packed" || f.text == "#raw_union" || f.text == "#align(")
}

// directive_span: the struct directive containing field fi: its keyword field k
// and last field (`)` of #align(●)).
directive_span :: proc(n: Node, fi: int) -> (k, end: int, ok: bool) {
	for f, i in n.fields {
		if !is_directive_kw(f) do continue
		e := i
		if f.text == "#align(" {
			// The matching `)`: the argument can hold parentheses (align_of(int)).
			depth := 1
			scan: for j in i + 1 ..< len(n.fields) {
				g := n.fields[j]
				if g.slot || g.kind == "string" do continue
				quote: u8 = 0
				for c in transmute([]u8)g.text {
					if quote != 0 { if c == quote do quote = 0; continue }
					switch c {
					case '"', '\'', '`': quote = c
					case '(': depth += 1
					case ')':
						depth -= 1
						if depth == 0 { e = j; break scan }
					}
				}
			}
			if depth != 0 do for j in i + 1 ..< len(n.fields) do if !n.fields[j].slot && n.fields[j].text == ")" { e = j; break }
		}
		if fi >= i && fi <= e do return i, e, true
	}
	return
}

// ---- Picking the declaration ----

// mod_candidates: the declarations a modifier of `kind` can go on (line indices).
mod_candidates :: proc(app: ^App, kind: string) -> []int {
	out := make([dynamic]int, 0, 8, context.temp_allocator)
	infos := block_infos(app)
	for i in 0 ..< len(app.doc.nodes) {
		if infos[i].decl_depth != 0 do continue
		dk := line_decl_kind(app, i)
		ok := false
		switch kind {
		case SPECIAL_ATTR:      ok = dk != .None
		case SPECIAL_DIRECTIVE: ok = dk == .Struct
		case SPECIAL_CALLCONV:  ok = dk == .Proc || dk == .Proc_Type
		}
		if ok do append(&out, i)
	}
	return out[:]
}

// start_mod_pick: a Modifiers entry was chosen in the Add menu.
start_mod_pick :: proc(app: ^App, kind: string) {
	app.state = .Editor
	cands := mod_candidates(app, kind)
	if len(cands) == 0 do return
	app.mod_pick_active = true
	app.mod_pick_kind = kind
	// The nearest declaration: positions in half-lines (a dot sits between lines).
	pos := on_dot(app) ? 2 * app.editor_line - 1 : 2 * app.editor_line
	infos := block_infos(app)
	best, best_d := cands[0], max(int)
	for c in cands {
		s, e := 2 * c, 2 * block_close(app, infos, c)
		d := pos < s ? s - pos : (pos > e ? pos - e : 0)
		if d < best_d { best, best_d = c, d }
	}
	mod_pick_focus(app, best)
}

// Highlight declaration line ni (its name).
mod_pick_focus :: proc(app: ^App, ni: int) {
	if ni < 0 || ni >= len(app.doc.nodes) do return
	app.mod_pick_line = ni
	for f, i in app.doc.nodes[ni].fields {
		if f.editable { focus_field_index(app, ni, i); return }
	}
	focus_line(app, ni)
}

// mod_pick_update handles input while picking. Returns true (input consumed).
mod_pick_update :: proc(app: ^App, inp: Input) -> bool {
	if !app.mod_pick_active do return false
	cands := mod_candidates(app, app.mod_pick_kind)
	if len(cands) == 0 {
		app.mod_pick_active = false
		return true
	}
	cur := 0
	for c, i in cands do if c == app.mod_pick_line { cur = i; break }
	switch {
	case inp.cancel:
		app.mod_pick_active = false
		return true
	case inp.confirm:
		kind: Ctrl_Menu
		switch app.mod_pick_kind {
		case SPECIAL_ATTR:      kind = .Attr
		case SPECIAL_DIRECTIVE: kind = .Directive
		case SPECIAL_CALLCONV:  kind = .Callconv
		}
		ctrl_open_menu(app, kind, cands[cur], -1, true)
		return true
	case inp.up:
		cur = max(cur - 1, 0)
	case inp.down:
		cur = min(cur + 1, len(cands) - 1)
	case:
		return true
	}
	mod_pick_focus(app, cands[cur])
	return true
}

// The banner shown while picking.
mod_pick_banner :: proc(app: ^App) -> string {
	what := "a declaration for the attribute"
	switch app.mod_pick_kind {
	case SPECIAL_DIRECTIVE: what = "a struct for the directive"
	case SPECIAL_CALLCONV:  what = "a procedure for the calling convention"
	}
	return fmt.tprintf("Pick %s   -   D-pad Up/Down move   A choose   B cancel", what)
}

// ---- Attributes ----

@(private = "file")
DECL_ALL :: bit_set[Decl_Kind]{.Proc, .Proc_Group, .Proc_Type, .Struct, .Type, .Const, .Var}

@(private = "file")
Attr_Opt :: struct {
	label, id, name: string, // menu label; the attribute as written (without a value); its name
	str_value:       bool,   // takes a string: name=●
	kinds:           bit_set[Decl_Kind],
	local_ok:        bool,   // also allowed on a declaration inside a procedure
}

@(private = "file")
ATTR_OPTS := [?]Attr_Opt{
	{"test", "test", "test", false, {.Proc}, false}, // also: import core:testing, t: ^testing.T (attr_dots.odin)
	{"private", "private", "private", false, DECL_ALL, false},
	{"private=\"file\"", "private=\"file\"", "private", false, DECL_ALL, false},
	{"export", "export", "export", false, {.Proc, .Var}, false},
	{"init", "init", "init", false, {.Proc}, false},
	{"fini", "fini", "fini", false, {.Proc}, false},
	{"require_results", "require_results", "require_results", false, {.Proc}, false},
	{"thread_local", "thread_local", "thread_local", false, {.Var}, true},
	{"link_name=\"...\"", "link_name", "link_name", true, {.Proc, .Var}, false},
	{"deprecated=\"...\"", "deprecated", "deprecated", true, {.Proc}, false},
	{"cold", "cold", "cold", false, {.Proc}, false},
}

// The names of the attributes already on the declaration at line d.
@(private = "file")
attr_names_above :: proc(app: ^App, d: int) -> []string {
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	for j := d - 1; j >= 0 && is_attr_line(app.doc.nodes[j]); j -= 1 {
		for f in app.doc.nodes[j].fields {
			if f.slot || f.kind != KW do continue
			name := f.text
			if eq := strings.index_byte(name, '='); eq >= 0 do name = name[:eq]
			append(&out, strings.trim_space(name))
		}
	}
	return out[:]
}

// Does the procedure declared at line d take parameters / return results?
@(private = "file")
proc_shape :: proc(app: ^App, d: int) -> (params, results: bool) {
	inner: string
	inner, results, _ = proc_params_text(app, d)
	params = inner != ""
	return
}

// proc_params_text: the parameter list of the procedure declared at line d (as
// it will be saved, trimmed; "" = none), and whether it returns results.
proc_params_text :: proc(app: ^App, d: int) -> (inner: string, results, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	for j in d ..< min(d + 64, len(app.doc.nodes)) {
		s := node_source(app.doc.nodes[j], context.temp_allocator)
		strings.write_string(&b, s)
		strings.write_byte(&b, ' ')
		if strings.contains(s, "{") || strings.contains(s, "---") do break
	}
	h := strings.to_string(b)
	at := strings.index(h, "proc")
	if at < 0 do return
	open := strings.index_byte(h[at:], '(')
	if open < 0 do return
	open += at
	depth := 0
	close := -1
	for k in open ..< len(h) {
		if h[k] == '(' do depth += 1
		if h[k] == ')' {
			depth -= 1
			if depth == 0 { close = k; break }
		}
	}
	if close < 0 do return
	inner = strings.trim_space(h[open + 1:close])
	inner = strings.trim_right(inner, ", ")
	rest := strings.trim_left_space(h[close + 1:])
	if strings.has_prefix(rest, "->") {
		r := strings.trim_left_space(rest[2:])
		results = r != "" && !strings.has_prefix(r, "{") && !strings.has_prefix(r, "---")
	}
	ok = true
	return
}

@(private = "file")
contains_str :: proc(list: []string, s: string) -> bool {
	for x in list do if x == s do return true
	return false
}

attr_options :: proc(app: ^App, d: int, out: ^[dynamic]Entry) {
	dk := line_decl_kind(app, d)
	present := attr_names_above(app, d)
	params, results := proc_shape(app, d)
	local := block_infos(app)[d].decl_depth != 0 // inside a procedure: only local attributes
	for o in ATTR_OPTS {
		if dk not_in o.kinds do continue
		if local && !o.local_ok do continue
		dim := contains_str(present, o.name)
		if o.id == "require_results" && !results do dim = true
		if (o.id == "init" || o.id == "fini") && (params || results) do dim = true
		if o.id == "test" && test_attr_dim(app, d) do dim = true
		append(out, Entry{label = strings.clone(o.label), owned_label = true, fill = CTRL_MENU_FILL, call_name = strings.clone(o.id), dim = dim})
	}
}

// An attribute line's `@(` and `)` fields (ok=false: not the @(...) form).
@(private = "file")
attr_parens :: proc(n: Node) -> (open, close: int, ok: bool) {
	open = -1
	for f, i in n.fields {
		if !f.slot && f.kind == "" && strings.trim_space(f.text) == "@(" { open = i; break }
	}
	if open < 0 || len(n.fields) == 0 do return
	close = len(n.fields) - 1
	if n.fields[close].slot || n.fields[close].text != ")" do return
	return open, close, true
}

// apply_attribute adds attribute `id` to the declaration at line d.
apply_attribute :: proc(app: ^App, decl: int, id: string) {
	d := decl
	opt: Attr_Opt
	found := false
	for o in ATTR_OPTS do if o.id == id { opt = o; found = true; break }
	if !found do return
	if line_decl_kind(app, d) not_in opt.kinds || contains_str(attr_names_above(app, d), opt.name) do return
	if !opt.local_ok && block_infos(app)[d].decl_depth != 0 do return // file-scope only

	attr := make([dynamic]Field, 0, 3, context.temp_allocator)
	append(&attr, Field{strings.clone(opt.id), false, false, KW, "", ""})
	if opt.str_value {
		append(&attr, Field{strings.clone("="), false, false, "", "", ""})
		append(&attr, Field{"", false, true, "value", "string", ""})
	}
	line, first := -1, -1
	if d > 0 && is_attr_line(app.doc.nodes[d - 1]) {
		if _, close, ok := attr_parens(app.doc.nodes[d - 1]); ok {
			// Merge: @(a) -> @(a, b)
			inject_at(&app.doc.nodes[d - 1].fields, close, Field{strings.clone(", "), false, false, "", "", ""})
			inject_at(&app.doc.nodes[d - 1].fields, close + 1, ..attr[:])
			line, first = d - 1, close + 1
		}
	}
	if line < 0 {
		n: Node
		ind := line_indent(app.doc.nodes[d])
		append(&n.fields, Field{strings.concatenate({ind, "@("}), false, false, "", "", ""})
		append(&n.fields, ..attr[:])
		append(&n.fields, Field{strings.clone(")"), false, false, "", "", ""})
		inject_at(&app.doc.nodes, d, n)
		line, first = d, 1
		d += 1
	}
	// @(init) / @(fini) procedures must be "contextless".
	if id == "init" || id == "fini" do set_callconv(app, d, "contextless")
	// @(test): import core:testing, take `t: ^testing.T` (attr_dots.odin).
	if id == "test" {
		nd := setup_test_proc(app, d)
		line += nd - d
	}
	focus_field_index(app, line, opt.str_value ? first + 2 : first)
}

@(private = "file")
remove_line :: proc(app: ^App, ni: int) {
	for f in app.doc.nodes[ni].fields do if len(f.text) > 0 do delete(f.text)
	delete(app.doc.nodes[ni].fields)
	ordered_remove(&app.doc.nodes, ni)
}

// remove_attribute: LT+B on (a part of) an attribute: that attribute goes; the
// line goes with its last one.
remove_attribute :: proc(app: ^App, ni, fi: int) {
	n := app.doc.nodes[ni]
	open, close, ok := attr_parens(n)
	spans := make([dynamic][2]int, 0, 4, context.temp_allocator)
	if ok {
		start := open + 1
		for i in open + 1 ..= close {
			if i == close || (!n.fields[i].slot && n.fields[i].text == ", ") {
				if i > start do append(&spans, [2]int{start, i})
				start = i + 1
			}
		}
	}
	which := -1
	for s, k in spans do if fi >= s[0] && fi < s[1] { which = k; break }
	if !ok || which < 0 || len(spans) <= 1 {
		remove_line(app, ni)
		focus_line(app, min(ni, len(app.doc.nodes) - 1))
		normalize_cursor(app)
		return
	}
	s := spans[which]
	a, b := s[0], s[1] + 1 // with the ", " after it
	if which == len(spans) - 1 do a, b = s[0] - 1, s[1] // the last one: with the ", " before it
	fields := &app.doc.nodes[ni].fields
	for i in a ..< b do if len(fields[i].text) > 0 do delete(fields[i].text)
	remove_range(fields, a, b)
	focus_field_index(app, ni, min(a, len(fields) - 2))
}

// ---- Struct directives ----

@(private = "file")
line_has_kw :: proc(n: Node, text: string) -> bool {
	for f in n.fields do if !f.slot && f.kind == KW && f.text == text do return true
	return false
}

directive_options :: proc(app: ^App, d: int, out: ^[dynamic]Entry) {
	n := app.doc.nodes[d]
	packed, raw, align := line_has_kw(n, "#packed"), line_has_kw(n, "#raw_union"), line_has_kw(n, "#align(")
	// #align can't be combined with #packed (odin check: "'#align' cannot be applied with '#packed'").
	append(out, Entry{label = strings.clone("#packed"), owned_label = true, fill = CTRL_MENU_FILL, call_name = strings.clone("#packed"), dim = packed || align})
	append(out, Entry{label = strings.clone("#raw_union"), owned_label = true, fill = CTRL_MENU_FILL, call_name = strings.clone("#raw_union"), dim = raw})
	append(out, Entry{label = strings.clone("#align(N)"), owned_label = true, fill = CTRL_MENU_FILL, call_name = strings.clone("#align("), dim = align || packed})
}

// Where a directive goes in a struct header: right after `struct` (and its
// polymorphic parameters `($T: typeid)`), as a byte offset in the line's text.
@(private = "file")
directive_pos :: proc(text: string) -> int {
	si := strings.index(text, ":: struct")
	if si < 0 do return -1
	p := si + len(":: struct")
	if p < len(text) && text[p] == '(' {
		depth := 0
		for k in p ..< len(text) {
			if text[k] == '(' do depth += 1
			if text[k] == ')' {
				depth -= 1
				if depth == 0 { p = k + 1; break }
			}
		}
	}
	return p
}

// Insert `fs` at byte offset p of the line's text (splitting a fixed field).
// Returns the field index of the first inserted field, or -1.
@(private)
insert_at_offset :: proc(n: ^Node, p: int, fs: []Field) -> int {
	cum := 0
	for f, i in n.fields {
		l := len(f.text)
		if l > 0 && cum <= p && p < cum + l {
			off := p - cum
			if off == 0 {
				inject_at(&n.fields, i, ..fs)
				return i
			}
			if f.slot || f.editable || f.kind != "" do return -1
			left, right := strings.clone(f.text[:off]), strings.clone(f.text[off:])
			delete(n.fields[i].text)
			n.fields[i].text = left
			inject_at(&n.fields, i + 1, ..fs)
			inject_at(&n.fields, i + 1 + len(fs), Field{right, false, false, "", "", ""})
			return i + 1
		}
		cum += l
	}
	if p == cum {
		append(&n.fields, ..fs)
		return len(n.fields) - len(fs)
	}
	return -1
}

// apply_directive adds #packed / #raw_union / #align(●) to the struct at line d.
apply_directive :: proc(app: ^App, d: int, id: string) {
	n := &app.doc.nodes[d]
	if line_has_kw(n^, id) do return
	p := directive_pos(node_text(n^, context.temp_allocator))
	if p < 0 do return
	fs := make([dynamic]Field, 0, 4, context.temp_allocator)
	append(&fs, Field{strings.clone(" "), false, false, "", "", ""})
	append(&fs, Field{strings.clone(id), false, false, KW, "", ""})
	if id == "#align(" {
		append(&fs, Field{"", false, true, "value", "int", ""})
		append(&fs, Field{strings.clone(")"), false, false, "", "", ""})
	}
	at := insert_at_offset(n, p, fs[:])
	if at < 0 {
		for f in fs do if len(f.text) > 0 do delete(f.text)
		return
	}
	focus_field_index(app, d, id == "#align(" ? at + 2 : at + 1)
}

// remove_directive: LT+B on a directive (keyword field k).
remove_directive :: proc(app: ^App, ni, k: int) {
	n := app.doc.nodes[ni]
	_, e, ok := directive_span(n, k)
	if !ok do return
	fields := &app.doc.nodes[ni].fields
	for i in k ..= e do if len(fields[i].text) > 0 do delete(fields[i].text)
	remove_range(fields, k, e + 1)
	// The space in front of it.
	if k > 0 {
		p := &fields[k - 1]
		if !p.slot && !p.editable && p.kind == "" {
			if p.text == " " {
				delete(p.text)
				ordered_remove(fields, k - 1)
			} else if strings.has_suffix(p.text, " ") {
				t := strings.clone(p.text[:len(p.text) - 1])
				delete(p.text)
				p.text = t
			}
		}
	}
	focus_line(app, ni)
	for f, i in app.doc.nodes[ni].fields do if f.editable { focus_field_index(app, ni, i); break }
}

// ---- Calling conventions ----

@(private = "file")
CONVENTIONS := [?]string{"odin", "contextless", "c", "system", "stdcall", "fastcall", "cdecl", "naked", "none"}

// The calling convention written on line n ("" = none).
callconv_of :: proc(n: Node) -> string {
	if k := own_callconv_index(n); k >= 0 do return strings.trim(n.fields[k].text, "\"")
	return ""
}

// own_callconv_index: the procedure's own calling convention keyword - right
// after `:: proc ` (not one inside a parameter's type) - or -1.
own_callconv_index :: proc(n: Node) -> int {
	for f, i in n.fields {
		if !is_callconv_kw(f) || i == 0 do continue
		p := n.fields[i - 1]
		if p.slot || p.editable do continue
		if strings.contains(p.text, "::") && strings.has_suffix(strings.trim_right_space(p.text), "proc") do return i
	}
	return -1
}

callconv_options :: proc(app: ^App, d: int, out: ^[dynamic]Entry) {
	cur := callconv_of(app.doc.nodes[d])
	has_body := line_decl_kind(app, d) == .Proc
	for c in CONVENTIONS {
		label := fmt.aprintf("\"%s\"", c)
		dim := c == cur || (c == "none" && has_body) // "none" procedures can't have a body
		append(out, Entry{label = label, owned_label = true, fill = CTRL_MENU_FILL, call_name = strings.clone(c), dim = dim})
	}
}

// The offset of the `proc` in a fixed text whose parameter list follows it, or -1.
@(private)
proc_before_paren :: proc(t: string) -> int {
	from := 0
	for {
		at := strings.index(t[from:], "proc")
		if at < 0 do return -1
		at += from
		k := at + 4
		for k < len(t) && t[k] == ' ' do k += 1
		if k < len(t) && t[k] == '(' && (at == 0 || !is_name_byte(t[at - 1])) do return at
		from = at + 4
	}
}

// set_callconv writes / replaces the calling convention of the procedure at
// line d. Returns the convention's field index, or -1.
set_callconv :: proc(app: ^App, d: int, name: string) -> int {
	fields := &app.doc.nodes[d].fields
	q := fmt.tprintf("\"%s\"", name)
	if k := own_callconv_index(app.doc.nodes[d]); k >= 0 {
		delete(fields[k].text)
		fields[k].text = strings.clone(q)
		return k
	}
	for f, i in fields {
		// The declaration's own `:: proc(` (not a proc type among the parameters).
		if f.slot || f.editable || f.kind != "" || !strings.contains(f.text, "::") do continue
		at := proc_before_paren(f.text)
		if at < 0 do continue
		a, b := f.text[:at + 4], f.text[at + 4:]
		left := strings.concatenate({a, " "})
		right := strings.has_prefix(b, "(") ? strings.concatenate({" ", b}) : strings.clone(b)
		delete(fields[i].text)
		fields[i].text = left
		inject_at(fields, i + 1, Field{strings.clone(q), false, false, KW, "", ""}, Field{right, false, false, "", "", ""})
		return i + 1
	}
	return -1
}

apply_callconv :: proc(app: ^App, d: int, name: string) {
	if k := set_callconv(app, d, name); k >= 0 do focus_field_index(app, d, k)
}

// remove_callconv: LT+B on a calling convention: `proc "c" (` -> `proc(`.
remove_callconv :: proc(app: ^App, ni, fi: int) {
	fields := &app.doc.nodes[ni].fields
	delete(fields[fi].text)
	ordered_remove(fields, fi)
	p, nx := fi - 1, fi
	if p >= 0 && nx < len(fields) {
		a, b := fields[p], fields[nx]
		if !a.slot && !a.editable && a.kind == "" && !b.slot && !b.editable && b.kind == "" {
			merged := strings.concatenate({strings.trim_right_space(a.text), strings.trim_left_space(b.text)})
			delete(fields[p].text)
			delete(fields[nx].text)
			fields[p].text = merged
			ordered_remove(fields, nx)
		}
	}
	focus_line(app, ni)
	for f, i in app.doc.nodes[ni].fields do if f.editable { focus_field_index(app, ni, i); break }
}

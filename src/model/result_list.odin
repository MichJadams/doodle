package model

// Result lists and return values that grow: procedures with several results.
//
//   divmod :: proc(a, b: int) -> (int, int●) {     ● RES_MORE_KIND: another result (blue)
//       return a / b, a % b●                        ● RET_MORE_KIND: another value (orange)
//
// The extra dot sits right after the last item with no ", " in front of it, so
// the line's text stays valid Odin (`-> int`, `return x`) for everything that
// reads it (call_signature, the type checker, saving). Filling it inserts the
// ", " (more_dot_filled). result_list_sync keeps each list in shape after an
// update:
//   - a result list: one blue dot while it has no result; `T●` with one;
//     `(T1, T2●)` from two on (the parentheses come and go with the count)
//   - a return: once it has a value, the extra dot after the last one; its
//     empty dots expect the enclosing procedure's result types, by position
// LT+B on a result, or on a one-field return value, removes it with its ", "
// (result_list_delete). Both extra dots are optional: never saved
// (is_optional_dot), so `-> (int, int●)` saves as `-> (int, int)`.

import "core:strings"

RES_MORE_KIND :: "res_more"
RET_MORE_KIND :: "ret_more"

is_more_dot :: proc(f: Field) -> bool { return f.slot && (f.kind == RES_MORE_KIND || f.kind == RET_MORE_KIND) }

@(private = "file")
is_fixed :: proc(f: Field) -> bool { return !f.slot && !f.editable }

@(private = "file")
is_list_sep :: proc(f: Field) -> bool { return is_fixed(f) && f.text == ", " }

@(private = "file")
fixed_field :: proc(text: string) -> Field { return Field{strings.clone(text), false, false, "", "", ""} }

@(private = "file")
List_Item :: struct { a, b: int } // fields [a, b)

// ---- Where the lists are ----

// results_span: a procedure header's result list, fields [a, b): between the
// fixed field ending in `-> ` and the fixed field starting with `{`. Named
// results (`(q, r: int)`) and anything else unusual aren't a list.
results_span :: proc(n: Node) -> (a, b: int, ok: bool) {
	arrow := -1
	is_proc := false
	for f, i in n.fields {
		if !is_fixed(f) do continue
		if strings.contains(f.text, "proc") do is_proc = true
		if strings.has_suffix(f.text, "-> ") {
			arrow = i
		} else if arrow >= 0 && strings.has_prefix(strings.trim_left_space(f.text), "{") {
			if !is_proc || i == arrow + 1 do return
			for g in n.fields[arrow + 1:i] {
				if g.slot {
					if g.kind != "type" && g.kind != RES_MORE_KIND do return
				} else if is_fixed(g) {
					if strings.contains_any(g.text, ":={") do return
				}
			}
			return arrow + 1, i, true
		}
	}
	return
}

// return_span: a `return` statement's values, fields [a, b) after the keyword.
return_span :: proc(n: Node) -> (a, b: int, ok: bool) {
	for f, i in n.fields {
		t := strings.trim_space(f.text)
		if !f.slot && !f.editable && t == "" do continue // indentation
		if !is_fixed(f) || t != "return" do return
		for g in n.fields[i + 1:] do if g.kind == COMMENT_KIND || (is_fixed(g) && strings.contains(g.text, "//")) do return
		return i + 1, len(n.fields), true
	}
	return
}

// list_items: the items of the list in fields [a, b), split at top-level ", ";
// the extra dot at the end (more, or -1) and the parentheses around it all
// (results) are not items. Temp-allocated.
@(private = "file")
list_items :: proc(n: Node, a, b: int) -> (items: [dynamic]List_Item, more: int, parens: bool) {
	items = make([dynamic]List_Item, 0, 4, context.temp_allocator)
	more = -1
	a, b := a, b
	if b - a >= 2 && is_fixed(n.fields[a]) && n.fields[a].text == "(" && is_fixed(n.fields[b - 1]) && n.fields[b - 1].text == ")" {
		parens = true
		a += 1
		b -= 1
	}
	if b > a && is_more_dot(n.fields[b - 1]) {
		more = b - 1
		b -= 1
	}
	if b <= a do return
	depth := 0
	start := a
	for i in a ..< b {
		f := n.fields[i]
		if depth == 0 && is_list_sep(f) {
			append(&items, List_Item{start, i})
			start = i + 1
			continue
		}
		if is_fixed(f) do for c in transmute([]u8)f.text {
			switch c {
			case '(', '[', '{': depth += 1
			case ')', ']', '}': depth -= 1
			}
		}
	}
	append(&items, List_Item{start, b})
	return
}

@(private = "file")
lone_empty :: proc(n: Node, it: List_Item) -> bool { return it.b - it.a == 1 && n.fields[it.a].slot }

// ---- Keeping the lists in shape ----

// result_list_sync: after an update (and after loading), every result list and
// return statement in its shape (see the top). Not while a menu, a Reference
// pick or a Y-refill holds a dot open - that dot must stay where it is.
result_list_sync :: proc(app: ^App, force := false) {
	if !force && (app.state != .Editor || app.ref_pick_active || app.ref_pass_active || app.refill_active) do return
	for ni in 0 ..< len(app.doc.nodes) {
		n := app.doc.nodes[ni]
		if a, b, ok := results_span(n); ok {
			shape_results(app, ni, a, b)
		} else if a2, b2, ok2 := return_span(n); ok2 {
			shape_return(app, ni, a2, b2)
		}
	}
}

// Rebuild a result list as: one "type" dot (no results), `T●`, or `(T1, T2●)`.
@(private = "file")
shape_results :: proc(app: ^App, ni, a, b: int) {
	n := &app.doc.nodes[ni]
	items, more, parens := list_items(n^, a, b)
	count := len(items)
	if count == 1 && lone_empty(n^, items[0]) && more < 0 && !parens do return // the empty result dot
	if count >= 1 && !(count == 1 && lone_empty(n^, items[0])) && parens == (count >= 2) && more >= 0 do return

	region := make([dynamic]Field, 0, b - a + 4)
	defer delete(region)
	if count == 0 || (count == 1 && lone_empty(n^, items[0])) {
		append(&region, Field{"", false, true, "type", "", ""})
	} else {
		if count >= 2 do append(&region, fixed_field("("))
		for it, k in items {
			if k > 0 do append(&region, fixed_field(", "))
			for i in it.a ..< it.b {
				append(&region, n.fields[i])
				n.fields[i] = Field{} // moved
			}
		}
		append(&region, Field{"", false, true, RES_MORE_KIND, "", ""})
		if count >= 2 do append(&region, fixed_field(")"))
	}
	replace_region(app, ni, a, b, region[:])
}

// A return with a value gets the extra dot after its last value; its empty dots
// expect the procedure's result types.
@(private = "file")
shape_return :: proc(app: ^App, ni, a, b: int) {
	n := &app.doc.nodes[ni]
	items, more, _ := list_items(n^, a, b)
	filled := 0
	for it in items do if !lone_empty(n^, it) do filled += 1
	if filled > 0 && more < 0 {
		append(&n.fields, Field{"", false, true, RET_MORE_KIND, "", ""})
		more = len(n.fields) - 1
	}
	results := enclosing_results(app, ni)
	want :: proc(results: []string, k: int) -> string { return k < len(results) ? results[k] : "" }
	set_hint :: proc(app: ^App, f: ^Field, h: string) {
		if f.hint == h && f.hint_pkg == "" do return
		f.hint, f.hint_pkg = intern_hint(app, h), ""
	}
	for it, k in items do if lone_empty(n^, it) && n.fields[it.a].kind == "value" do set_hint(app, &n.fields[it.a], want(results, k))
	if more >= 0 do set_hint(app, &n.fields[more], want(results, len(items)))
}

// Replace fields [a, b) of line ni with `region` (moved in). The old fields
// still in [a, b) - parentheses, separators, extra dots - are freed.
@(private = "file")
replace_region :: proc(app: ^App, ni, a, b: int, region: []Field) {
	n := &app.doc.nodes[ni]
	for i in a ..< b do if len(n.fields[i].text) > 0 do delete(n.fields[i].text)
	remove_range(&n.fields, a, b)
	inject_at(&n.fields, a, ..region)
	if app.editor_line == ni do clamp_field(app)
}

// enclosing_results: the result types of the procedure line ni is in, as
// written (`int`, `win32.HWND`); nil when it has none or they're named.
// Temp-allocated.
@(private = "file")
enclosing_results :: proc(app: ^App, ni: int) -> []string {
	for j := ni - 1; j >= 0; j -= 1 {
		t := node_text(app.doc.nodes[j], context.temp_allocator)
		p := strings.index(t, "proc")
		if p < 0 || !(strings.contains(t, ":: proc") || strings.contains(t, ":= proc") || strings.contains(t, "= proc")) || !strings.contains(t, "{") do continue
		// The results come after the parameter list's ")".
		open := strings.index_byte(t[p:], '(')
		if open < 0 do return nil
		depth, close := 0, -1
		for k in p + open ..< len(t) {
			switch t[k] {
			case '(': depth += 1
			case ')':
				depth -= 1
				if depth == 0 { close = k; break }
			}
			if close >= 0 do break
		}
		if close < 0 do return nil
		rest := t[close + 1:]
		arrow := strings.index(rest, "->")
		if arrow < 0 do return nil
		r := rest[arrow + 2:]
		if br := strings.index_byte(r, '{'); br >= 0 do r = r[:br]
		r = strings.trim_space(r)
		if r == "" || strings.contains(r, ":") do return nil
		if strings.has_prefix(r, "(") && strings.has_suffix(r, ")") {
			parts := split_top_level(r[1:len(r) - 1])
			for &s in parts do s = strings.trim_space(s)
			return parts
		}
		out := make([]string, 1, context.temp_allocator)
		out[0] = r
		return out
	}
	return nil
}

// ---- Filling and deleting ----

// more_dot_filled: the extra dot at fields[fi] was just filled (its value now
// starts at fi): put the ", " in front of it. Returns how many fields went in
// before fi (0 or 1). The next update's sync adds a new extra dot after it.
more_dot_filled :: proc(app: ^App, ni, fi: int) -> int {
	if ni < 0 || ni >= len(app.doc.nodes) do return 0
	fields := &app.doc.nodes[ni].fields
	if fi <= 0 || fi > len(fields) do return 0
	prev := fields[fi - 1]
	t := strings.trim_space(prev.text)
	if is_fixed(prev) && (t == "return" || t == "(" || strings.has_suffix(t, "->")) do return 0 // the first value
	inject_at(fields, fi, fixed_field(", "))
	return 1
}

// result_list_delete (LT+B): a result, or a one-field return value, goes with
// its ", "; the extra dots and the empty result dot stay (nothing to delete -
// and not the whole procedure / line either). False when the cursor isn't on
// one of these, or is on a part of a bigger return value (expr_delete etc.).
result_list_delete :: proc(app: ^App) -> bool {
	ni, fi, ok := editor_target(app)
	if !ok do return false
	n := &app.doc.nodes[ni]
	if a, b, rok := results_span(n^); rok && fi >= a && fi < b {
		items, more, _ := list_items(n^, a, b)
		if fi == more do return true
		for it in items do if fi >= it.a && fi < it.b {
			if len(items) == 1 && lone_empty(n^, it) do return true
			lo := remove_item(n, it)
			if a2, b2, ok2 := results_span(n^); ok2 do shape_results(app, ni, a2, b2)
			focus_near(app, ni, lo)
			return true
		}
		return true // a parenthesis or a separator
	}
	if a, b, rok := return_span(n^); rok && fi >= a && fi < b {
		items, more, _ := list_items(n^, a, b)
		if fi == more do return true
		for it in items do if fi >= it.a && fi < it.b {
			if it.b - it.a != 1 do return false // a part of an expression
			lo := remove_item(n, it)
			if _, _, has_more := return_has_more(n^); !has_more do append(&n.fields, Field{"", false, true, RET_MORE_KIND, "", ""}) // `return ●`
			if a2, b2, ok2 := return_span(n^); ok2 do shape_return(app, ni, a2, b2)
			focus_near(app, ni, lo)
			return true
		}
	}
	return false
}

@(private = "file")
return_has_more :: proc(n: Node) -> (a, b: int, ok: bool) {
	a, b = return_span(n) or_return
	_, more, _ := list_items(n, a, b)
	return a, b, more >= 0
}

// Remove an item and one ", " next to it (before it, else after it); returns
// where the removed fields started.
@(private = "file")
remove_item :: proc(n: ^Node, it: List_Item) -> int {
	lo, hi := it.a, it.b
	if lo > 0 && is_list_sep(n.fields[lo - 1]) do lo -= 1
	else if hi < len(n.fields) && is_list_sep(n.fields[hi]) do hi += 1
	for i in lo ..< hi do if len(n.fields[i].text) > 0 do delete(n.fields[i].text)
	remove_range(&n.fields, lo, hi)
	return lo
}

// The cursor onto the first dot / name at or after field fi of line ni (else
// the last one before it).
@(private = "file")
focus_near :: proc(app: ^App, ni, fi: int) {
	fs := app.doc.nodes[ni].fields
	for i in max(fi, 0) ..< len(fs) do if fs[i].slot || fs[i].editable { focus_field_index(app, ni, i); return }
	#reverse for f, i in fs do if f.slot || f.editable { focus_field_index(app, ni, i); return }
}

// ---- Loading ----

// structure_results (loader): `name :: proc(...) -> int {` and `-> (A, B) {`
// written as fixed text get their results as type fields, as the menus build
// them (the sync then adds the extra dot). Named results, `-> !`, where
// clauses and declarations without a body stay as they are.
structure_results :: proc(n: ^Node) {
	at := -1
	#reverse for f, i in n.fields {
		if !is_fixed(f) || !strings.contains(f.text, "->") do continue
		arrow := strings.last_index(f.text, "->")
		if strings.contains(f.text[arrow:], "{") { at = i; break }
	}
	if at < 0 do return
	is_proc := false
	for f in n.fields[:at + 1] do if is_fixed(f) && strings.contains(f.text, "proc") do is_proc = true
	if !is_proc do return
	t := n.fields[at].text
	arrow := strings.last_index(t, "->")
	after := t[arrow + 2:]
	br := strings.index_byte(after, '{')
	r := strings.trim_space(after[:br])
	if r == "" || strings.contains_any(r, ":={!") || strings.contains(r, " where ") do return
	types := make([dynamic]string, 0, 4, context.temp_allocator)
	if strings.has_prefix(r, "(") && strings.has_suffix(r, ")") {
		for p in split_top_level(r[1:len(r) - 1]) {
			s := strings.trim_space(p)
			if s == "" do return
			append(&types, s)
		}
	} else {
		if strings.contains_any(r, "()") do return // `proc() -> int)` inside the parameters
		append(&types, r)
	}
	if len(types) == 0 do return
	region := make([dynamic]Field, 0, 2 * len(types) + 3, context.temp_allocator)
	append(&region, fixed_field(strings.concatenate({strings.trim_right_space(t[:arrow + 2]), " "}, context.temp_allocator)))
	if len(types) >= 2 do append(&region, fixed_field("("))
	for s, k in types {
		if k > 0 do append(&region, fixed_field(", "))
		append(&region, Field{strings.clone(s), true, false, "type", "", ""}) // as set_slot_type fills a type dot
	}
	if len(types) >= 2 do append(&region, fixed_field(")"))
	append(&region, fixed_field(strings.concatenate({" ", strings.trim_left_space(after[br:])}, context.temp_allocator)))
	delete(n.fields[at].text)
	ordered_remove(&n.fields, at)
	inject_at(&n.fields, at, ..region[:])
}

package model

// Y = change the highlighted part:
//   - a call's name       -> pick another proc from the same package (arguments kept)
//   - an argument/operand -> refill it (the fill menu, typed for that parameter);
//                            cancelling puts the original back
//   - a dot               -> fill it (same as A)
//   - a type / an import  -> the edit menu (same as LT+A)

import "core:strings"

// The import reference written before a callee at field cfi: "windows" for
// `windows.MessageBoxW` (menu-built: "windows" "." "MessageBoxW"; loaded:
// "\twindows." "MessageBoxW"), "" for a proc in this file or a built-in.
callee_ref :: proc(n: Node, cfi: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< cfi do strings.write_string(&b, n.fields[i].text)
	s := strings.to_string(b)
	if !strings.has_suffix(s, ".") do return ""
	s = s[:len(s) - 1]
	k := len(s)
	for k > 0 && is_ident_char_byte(s[k - 1]) do k -= 1
	return s[k:]
}

@(private = "file")
is_ident_char_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

// Required parameter types and the variadic type of a signature.
@(private = "file")
sig_hints :: proc(sig: Call_Sig) -> (req: []string, var_hint: string) {
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	for p in sig.params {
		if p.variadic do var_hint = p.type
		else if !p.optional do append(&out, p.type)
	}
	return out[:], var_hint
}

// expected_for: the type the argument/operand spanning fields [fa, fb) of a
// line expects, from the signature of the call it's passed to (or the operator
// it's an operand of). ("", "") when unknown.
expected_for :: proc(app: ^App, n: Node, fa, fb: int) -> (hint, pkg: string) {
	al, ok := find_arg_list(n)
	if !ok || al.open == 0 do return "", ""
	root := parse_expr_unit(n, al.open - 1, al.close + 1)
	h, p, _ := expected_in(app, n, root, fa, fb, "", "")
	return h, p
}

// expected_in: what the part [fa, fb) inside unit u expects, when u itself
// is expected to be `exp` (found = the part is inside u).
expected_in :: proc(app: ^App, n: Node, u: Unit, fa, fb: int, exp, exp_pkg: string) -> (hint, pkg: string, found: bool) {
	if u.fa == fa && u.fb == fb do return exp, exp_pkg, true
	#partial switch u.kind {
	case .Call:
		cfi := u.children[0].fa
		sig := call_signature(app, callee_ref(n, cfi), n.fields[cfi].text)
		req, var_hint := sig_hints(sig)
		for c in u.children[1:] {
			if c.fa <= fa && fb <= c.fb {
				h := c.arg_idx < len(req) ? req[c.arg_idx] : var_hint
				return expected_in(app, n, c, fa, fb, h, h != "" ? sig.pkg : "")
			}
		}
	case .Lit:
		// A struct literal's field value expects the field's type (struct_lit.odin).
		for c in u.children[1:] {
			if c.kind == .Group && len(c.children) == 2 && c.fa <= fa && fb <= c.fb {
				h, p := lit_field_hint(app, n, u, c)
				return expected_in(app, n, c.children[1], fa, fb, h, p)
			}
		}
	case .Op:
		// Operands: by operator; a ternary's condition is a bool (expr.odin).
		for c, i in u.children {
			if c.fa <= fa && fb <= c.fb {
				h, p := op_operand_expected(n, u, i, exp, exp_pkg)
				return expected_in(app, n, c, fa, fb, h, p)
			}
		}
	case .Group:
		// cast(T)x / auto_cast x: the converted value can be anything (expr.odin).
		if len(u.children) == 2 && is_conv_prefix(n.fields[u.children[0].fa]) {
			c := u.children[1]
			if c.fa <= fa && fb <= c.fb do return expected_in(app, n, c, fa, fb, "", "")
		}
	}
	return "", "", false
}

// unit_expected: the type the part u of line ni expects (Y refills it with a
// dot of that type; LT+B leaves one). Interned when written in this file.
unit_expected :: proc(app: ^App, ni: int, u: Unit) -> (hint, pkg: string) {
	hint, pkg = expected_for(app, app.doc.nodes[ni], u.fa, u.fb)
	if hint == "" do hint, pkg = rhs_expected(app, ni, u) // `a.b = value` / `x: T = value` (field_access.odin)
	if hint == "" do hint, pkg = loop_expected(app, ni, u) // a loop's condition / post (loops.odin)
	if pkg == "" do hint = intern_hint(app, hint)
	return hint, hint != "" ? pkg : ""
}

// change_selected: Y.
change_selected :: proc(app: ^App) {
	if app.state != .Editor do return
	ni, fa, fb := -1, 0, 0
	if app.tree_sticky {
		if s, ok := tree_selection(app); ok && s.kind == .Unit do ni, fa, fb = s.ni, s.fa, s.fb
	}
	if ni < 0 {
		lni, u, ok := editor_leaf(app)
		if !ok do return
		ni, fa, fb = lni, u.fa, u.fb
	}
	n := app.doc.nodes[ni]
	u, found := find_unit(n, fa, fb)
	if !found do return
	app.tree_sticky = false
	if conv_change(app, ni, u) do return // a conversion's type: T(x), cast(T)x (expr.odin)
	if branch_change(app, ni, u) do return // if / switch / case keywords, conditions, case values (branch.odin)
	if ctrl_change(app, ni, u) do return // when / #assert / attribute / directive / calling convention (ctrl.odin)
	if loop_change(app, ni, u) do return // for / its label / loop variables, `+=`, break (loops.odin)

	if u.kind == .Callee {
		open_change_call_menu(app, ni, u.fa)
		return
	}
	if u.fb - u.fa == 1 && n.fields[u.fa].kind == "decl" {
		open_decl_form_menu(app, ni, u.fa)
		return
	}
	if u.fb - u.fa == 1 && n.fields[u.fa].slot {
		focus_field_index(app, ni, u.fa)
		open_slot_menu(app) // a dot: same as A
		return
	}
	// The type of a struct literal: refill the whole literal `T{...}` (B puts it back).
	if u.fb - u.fa == 1 && u.fa + 1 < len(n.fields) && !n.fields[u.fa].slot && is_lit_open(n.fields[u.fa + 1]) {
		if close := lit_close_of(n, u.fa + 1); close > u.fa {
			begin_refill(app, ni, Unit{u.fa, close + 1, .Lit, nil, true, 0})
			return
		}
	}
	if u.is_arg {
		begin_refill(app, ni, u)
		return
	}
	// An assignment's target: pick the name (or a field of it) to assign to (field_access.odin).
	if u.fb - u.fa == 1 && is_assign_target(n, u.fa) {
		start_ref_pick(app, ni, u.fa)
		return
	}
	// A filled type or an import: the existing edit menu.
	focus_field_index(app, ni, u.fa)
	edit_selected(app)
}

// ---- Refill an argument ----

// begin_refill turns an argument back into a dot (typed for its parameter) and
// opens the fill menu. The original fields are kept until the fill is chosen;
// cancelling the menu puts them back (refill_restore).
begin_refill :: proc(app: ^App, ni: int, u: Unit) {
	hint, pkg := unit_expected(app, ni, u)
	refill_discard(app)
	fields := &app.doc.nodes[ni].fields
	for i in u.fa ..< u.fb do append(&app.refill_saved, fields[i]) // ownership moves to refill_saved
	remove_range(fields, u.fa, u.fb)
	inject_at(fields, u.fa, Field{"", false, true, "value", hint, hint != "" ? pkg : ""})
	app.refill_active = true
	app.refill_ni = ni
	app.refill_fi = u.fa
	focus_field_index(app, ni, u.fa)
	open_slot_menu(app)
	if app.state != .Radial do refill_restore(app) // nothing to pick: undo
}

// The fill was chosen: the original fields aren't needed any more.
refill_discard :: proc(app: ^App) {
	for f in app.refill_saved do if len(f.text) > 0 do delete(f.text)
	clear(&app.refill_saved)
	app.refill_active = false
}

// The fill menu was cancelled: put the original argument back.
refill_restore :: proc(app: ^App) {
	if !app.refill_active do return
	app.refill_active = false
	ni, fi := app.refill_ni, app.refill_fi
	if ni < 0 || ni >= len(app.doc.nodes) || fi < 0 || fi >= len(app.doc.nodes[ni].fields) {
		refill_discard(app)
		return
	}
	fields := &app.doc.nodes[ni].fields
	if fields[fi].slot {
		ordered_remove(fields, fi)
		inject_at(fields, fi, ..app.refill_saved[:])
		clear(&app.refill_saved) // ownership moved back
	} else {
		refill_discard(app)
	}
	focus_field_index(app, ni, fi)
}

// ---- Change a call's procedure ----

// open_change_call_menu: Y on a call's name -> the other procs it could be:
// the same import's procs (windows.MessageBoxW -> windows.*), or this file's
// procs + built-ins for an unqualified call.
open_change_call_menu :: proc(app: ^App, ni, cfi: int) {
	n := app.doc.nodes[ni]
	if cfi + 1 >= len(n.fields) do return
	ref := callee_ref(n, cfi)
	entries: []Entry
	path := ""
	if ref != "" {
		imports := collect_imports(app)
		defer delete(imports)
		for imp in imports do if imp.ref == ref { path = strings.clone(imp.path, context.temp_allocator); break }
		if path == "" do return
		entries = build_import_proc_menu(app, ref, path)
	} else {
		all := build_call_children(app) // [this package, from an import, built-in]
		keep := make([dynamic]Entry, 0, 2)
		defer delete(keep)
		for e, i in all {
			if i == 1 { free_entries(e.children); continue } // not "from an import": keep the namespace
			append(&keep, e)
		}
		delete(all)
		entries = make([]Entry, len(keep))
		copy(entries, keep[:])
	}
	if len(entries) == 0 do return

	if app.slot_menu != nil do free_entries(app.slot_menu)
	app.slot_menu = entries
	app.change_call = true
	app.change_ni = ni
	app.change_fi = cfi
	clear_nav(app)
	app.return_state = .Editor
	app.state = .Radial
	push_menu(app, "Change procedure", app.slot_menu)
	// The same procs as Call > From import > <path> (or Call's Internal / Built-in): share their heat.
	if path != "" do heat_set_root(app, "Call", "From import", path)
	else do heat_set_root(app, "Call")
}

// apply_change_call renames the call at change_ni/change_fi to `name` and
// resets its arguments: the old ones are removed and the new proc's parameters
// get fresh dots (typed for the new signature), plus the green "add argument"
// dot for a variadic proc. The cursor goes to the first new dot.
apply_change_call :: proc(app: ^App, name: string) {
	ni, cfi := app.change_ni, app.change_fi
	app.change_call = false
	if ni < 0 || ni >= len(app.doc.nodes) do return
	fields := &app.doc.nodes[ni].fields
	if cfi < 0 || cfi + 1 >= len(fields) do return

	// Rename.
	if len(fields[cfi].text) > 0 do delete(fields[cfi].text)
	fields[cfi].text = strings.clone(name)

	// The argument list: "(" at cfi+1 ... matching ")".
	open := cfi + 1
	if !(fields[open].text == "(" || fields[open].text == "( ") do return
	close := -1
	depth := 0
	for i in open ..< len(fields) {
		t := fields[i].text
		if fields[i].slot do continue
		if t == "(" || t == "( " do depth += 1
		else if t == ")" || t == " )" {
			depth -= 1
			if depth == 0 { close = i; break }
		}
	}
	if close < 0 do return

	// Remove every old argument (and separator).
	for i in open + 1 ..< close do if len(fields[i].text) > 0 do delete(fields[i].text)
	remove_range(fields, open + 1, close)

	// Fresh dots for the new signature.
	sig := call_signature(app, callee_ref(app.doc.nodes[ni], cfi), name)
	req, var_hint := sig_hints(sig)
	hint_for :: proc(app: ^App, sig: Call_Sig, t: string) -> string { return sig.pkg == "" ? intern_hint(app, t) : t }
	list := make([dynamic]Field, 0, 2 * len(req) + 2, context.temp_allocator)
	for k in 0 ..< sig.req {
		if k > 0 do append(&list, Field{strings.clone(", "), false, false, "", "", ""})
		h := k < len(req) ? hint_for(app, sig, req[k]) : ""
		append(&list, Field{"", false, true, "value", h, h != "" ? sig.pkg : ""})
	}
	if sig.variadic {
		if sig.req > 0 do append(&list, Field{strings.clone(", "), false, false, "", "", ""})
		h := hint_for(app, sig, var_hint)
		append(&list, Field{"", false, true, "args", h, h != "" ? sig.pkg : ""})
	}
	inject_at(fields, open + 1, ..list[:])
	focus_first_dot_in(app, ni, open + 1, len(list)) // the name itself when there are no parameters
	if len(list) == 0 do focus_field_index(app, ni, cfi)
}

// ---- Declaration forms ----

DECL_FORM_FILL :: "__decl_form__"

// open_decl_form_menu: Y on a declaration's operator -> how to declare it:
//   name := value       the type is inferred from the value
//   name: type = value  you choose the type (then the Type menu opens)
//   name :: value       a constant
open_decl_form_menu :: proc(app: ^App, ni, fi: int) {
	n := app.doc.nodes[ni]
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< fi do strings.write_string(&b, n.fields[i].text)
	name := strings.trim_space(strings.to_string(b))

	out := make([dynamic]Entry, 0, 3)
	defer delete(out)
	option :: proc(out: ^[dynamic]Entry, label, form: string) {
		append(out, Entry{label = strings.clone(label), owned_label = true, fill = DECL_FORM_FILL, call_name = strings.clone(form)})
	}
	option(&out, strings.concatenate({name, " := value   (type inferred)"}, context.temp_allocator), "infer")
	option(&out, strings.concatenate({name, ": type = value   (choose the type)"}, context.temp_allocator), "typed")
	option(&out, strings.concatenate({name, " :: value   (constant)"}, context.temp_allocator), "const")

	if app.slot_menu != nil do free_entries(app.slot_menu)
	app.slot_menu = make([]Entry, len(out))
	copy(app.slot_menu, out[:])
	app.decl_form_active = true
	app.decl_ni, app.decl_fi = ni, fi
	clear_nav(app)
	app.return_state = .Editor
	app.state = .Radial
	push_menu(app, "Declare as", app.slot_menu)
}

// apply_decl_form switches the declaration whose operator is fields[fi] to
// `form` ("infer" / "typed" / "const"). Returns the new type dot's field index
// when it made one (typed), else -1.
apply_decl_form :: proc(app: ^App, ni, fi: int, form: string) -> int {
	if ni < 0 || ni >= len(app.doc.nodes) do return -1
	fields := &app.doc.nodes[ni].fields
	if fi < 0 || fi >= len(fields) || fields[fi].kind != "decl" do return -1
	cur := strings.trim_space(fields[fi].text)

	set_op :: proc(f: ^Field, text: string) {
		if len(f.text) > 0 do delete(f.text)
		f.text = strings.clone(text)
	}

	if form == "typed" {
		if cur == ":" do return -1 // already typed
		set_op(&fields[fi], ": ")
		inject_at(fields, fi + 1, Field{"", false, true, "type", "", ""}, Field{strings.clone(" = "), false, false, "", "", ""})
		return fi + 1
	}

	op := form == "const" ? " :: " : " := "
	if cur == ":" {
		// Drop the type: everything up to the `=` field, and the `=` itself.
		j := fi + 1
		for j < len(fields) && !(!fields[j].slot && strings.has_prefix(strings.trim_left_space(fields[j].text), "=")) do j += 1
		for k in fi + 1 ..< j do if len(fields[k].text) > 0 do delete(fields[k].text)
		remove_range(fields, fi + 1, j)
		eq := fi + 1
		if eq < len(fields) {
			// " = value..." -> keep whatever follows the `=` (a loaded value), else drop the field.
			rest := strings.trim_left_space(strings.trim_left_space(fields[eq].text)[1:])
			if rest == "" {
				delete(fields[eq].text)
				ordered_remove(fields, eq)
			} else {
				set_op(&fields[eq], rest)
			}
		} else {
			// `x: T` had no value: the new form needs one.
			append(fields, Field{"", false, true, "value", "", ""})
		}
	}
	set_op(&fields[fi], op)
	return -1
}

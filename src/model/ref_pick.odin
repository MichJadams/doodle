package model

// Reference pick mode: choosing "Reference" for a dot drops back into the file
// so you can pick the name to use (a variable, parameter, constant, proc ...)
// instead of getting a made-up name.
//   D-pad Left/Right = previous/next name, Up/Down = names on the previous/next line
//   A = use the highlighted name, B = cancel (the dot stays empty / is restored)
// After picking, a small "Pass as" menu says how to pass it:
//   name          the value itself (Odin passes arguments by value)
//   T(name)       converted to the type the dot expects (e.g. windows.LPCWSTR(text):
//                 a `text := windows.L("...")` variable is a [^]u16, which MessageBoxW
//                 won't take as an LPCWSTR without the conversion)
//   &name         a pointer to it (for a ^T parameter)
//   name^         the value a pointer points to

import "core:fmt"
import "core:strings"

REF_AS_FILL :: "__ref_as__"

Ref_Target :: struct {
	ni, fi: int,
}

// ref_candidates: the names you can reference, in file order - every editable
// name field (declared variables, parameters, constants, procs, ...), except
// the package name, import aliases, string text, and call names.
ref_candidates :: proc(app: ^App) -> []Ref_Target {
	out := make([dynamic]Ref_Target, 0, 16, context.temp_allocator)
	tni, tfi := ref_target(app) // loop variables only inside their loop (loops.odin)
	scope := ref_scope_make(app, tni) // locals only where they're in scope (ref_scope.odin)
	// Picking what an assignment assigns to: not a name declared with `::` - a
	// procedure, a type or a constant can't be assigned (field_access.odin).
	assigning := app.ref_pick_active && app.ref_ni >= 0 && app.ref_ni < len(app.doc.nodes) && is_assign_target(app.doc.nodes[app.ref_ni], app.ref_fi)
	for n, ni in app.doc.nodes {
		txt := strings.trim_space(node_text(n, context.temp_allocator))
		if strings.has_prefix(txt, "package ") || strings.has_prefix(txt, "import ") || strings.has_prefix(txt, "foreign ") do continue
		for f, fi in n.fields {
			if !f.editable || f.kind != "" || strings.trim_space(f.text) == "" || strings.contains(f.text, ".") do continue // (a.b: an assignment's field target)
			if fi + 1 < len(n.fields) && !n.fields[fi + 1].slot && (n.fields[fi + 1].text == "(" || n.fields[fi + 1].text == "( ") do continue // a call's name
			if assigning && fi + 1 < len(n.fields) && !n.fields[fi + 1].slot && strings.has_prefix(strings.trim_left_space(n.fields[fi + 1].text), "::") do continue // `name :: ...`
			if branch_name_hidden(app, ni, fi, app.ref_pick_active ? app.ref_ni : app.slot_ni) do continue // only known inside its if / switch (branch.odin)
			if !loop_name_visible(app, ni, fi, tni, tfi) do continue
			if !ref_scope_visible(app, &scope, ni, fi) do continue
			append(&out, Ref_Target{ni, fi})
		}
	}
	return out[:]
}

// start_ref_pick: called when "Reference" is chosen for the dot at (ni, fi).
start_ref_pick :: proc(app: ^App, ni, fi: int) {
	app.ref_pick_active = true
	app.ref_ni, app.ref_fi = ni, fi
	app.state = .Editor
	cands := ref_candidates(app) // after ref_ni / ref_fi: which dot decides the names (an assignment's target: no `::`)
	if len(cands) == 0 {
		ref_pick_cancel(app)
		return
	}
	// Start on the nearest name above the dot (a local declared before it), else the first.
	start := cands[0]
	for c in cands {
		if c.ni < ni || (c.ni == ni && c.fi < fi) do start = c
		else do break
	}
	focus_field_index(app, start.ni, start.fi)
}

// The candidate under the cursor, and its index in the list.
@(private = "file")
ref_current :: proc(app: ^App, cands: []Ref_Target) -> int {
	ni, fi, ok := editor_target(app)
	if !ok do return 0
	for c, i in cands do if c.ni == ni && c.fi == fi do return i
	return 0
}

// ref_pick_update handles input while picking. Returns true (input consumed).
ref_pick_update :: proc(app: ^App, inp: Input) -> bool {
	if !app.ref_pick_active do return false
	cands := ref_candidates(app)
	if len(cands) == 0 {
		ref_pick_cancel(app)
		return true
	}
	cur := ref_current(app, cands)
	switch {
	case inp.cancel:
		ref_pick_cancel(app)
		return true
	case inp.confirm:
		open_pass_as_menu(app, cands[cur])
		return true
	case inp.left:
		cur = (cur - 1 + len(cands)) % len(cands)
	case inp.right:
		cur = (cur + 1) % len(cands)
	case inp.up:
		line := cands[cur].ni
		for k := cur - 1; k >= 0; k -= 1 {
			if cands[k].ni < line {
				// the first name on that previous line
				cur = k
				for cur > 0 && cands[cur - 1].ni == cands[k].ni do cur -= 1
				break
			}
		}
	case inp.down:
		line := cands[cur].ni
		for k in cur + 1 ..< len(cands) do if cands[k].ni > line { cur = k; break }
	case:
		return true
	}
	focus_field_index(app, cands[cur].ni, cands[cur].fi)
	return true
}

// open_pass_as_menu: how to pass the picked name (value / converted / pointer / deref).
open_pass_as_menu :: proc(app: ^App, pick: Ref_Target) {
	name := app.doc.nodes[pick.ni].fields[pick.fi].text
	slot := app.doc.nodes[app.ref_ni].fields[app.ref_fi]
	if !slot.slot { // picking an assignment's target (field_access.odin)
		open_assign_target_menu(app, pick)
		return
	}

	out := make([dynamic]Entry, 0, 4)
	defer delete(out)
	option :: proc(out: ^[dynamic]Entry, label, text: string) {
		append(out, Entry{label = strings.clone(label), owned_label = true, fill = REF_AS_FILL, call_name = strings.clone(text)})
	}
	option(&out, name, name)
	// Converted to the expected type, written as you'd write it in this file (windows.LPCWSTR).
	if slot.hint != "" {
		ty := type_text_here(app, slot.hint, slot.hint_pkg) // `Maybe(^sdl3.FRect)`, `win32.LPCWSTR` (expr.odin)
		conv := fmt.tprintf("%s(%s)", ty, name)
		option(&out, conv, conv)
	}
	option(&out, fmt.tprintf("&%s   (pointer to it)", name), fmt.tprintf("&%s", name))
	option(&out, fmt.tprintf("%s^   (what it points to)", name), fmt.tprintf("%s^", name))

	// A pointer can only fill a dot that expects one.
	ctx := type_ctx_make(app)
	exp := slot_expected_type(&ctx, slot)
	if exp.cat != .Unknown && exp.cat != .Any && exp.cat != .Pointer {
		for &e in out do if strings.has_prefix(e.call_name, "&") do e.dim = true
	}
	append_field_group(app, pick, slot, &out) // "Field of <name>" (field_access.odin)
	append_index_entries(app, pick, slot, &out) // "items[i]" (index_fill.odin)
	loop_pass_as_dims(app, pick, out[:])      // a loop's iterable: only what can be iterated (loops.odin)
	when_pass_as_dims(app, pick, out[:])      // a `when` condition: only constants (when_const.odin)

	if app.slot_menu != nil do free_entries(app.slot_menu)
	app.slot_menu = make([]Entry, len(out))
	copy(app.slot_menu, out[:])
	app.ref_pass_active = true
	clear_nav(app)
	app.return_state = .Editor
	app.state = .Radial
	push_menu(app, "Pass as", app.slot_menu)
}

// The "Pass as" choice: fill the dot with it and leave pick mode.
ref_pass_choose :: proc(app: ^App, text: string) {
	app.ref_pass_active = false
	ref_pick_finish_text(app, text)
}

// "Pass as" cancelled (B): back to picking a name.
ref_pass_cancel :: proc(app: ^App) {
	app.ref_pass_active = false
	app.state = .Editor
}

// Use the picked name: it fills the dot (as fixed text - Y changes it later).
ref_pick_finish :: proc(app: ^App, pick: Ref_Target) {
	ref_pick_finish_text(app, app.doc.nodes[pick.ni].fields[pick.fi].text)
}

// Fill the target dot with `text` (the name, &name, T(name), ...).
ref_pick_finish_text :: proc(app: ^App, text: string) {
	name := strings.clone(text, context.temp_allocator)
	app.ref_pick_active = false
	ni, fi := app.ref_ni, app.ref_fi
	if ni < 0 || ni >= len(app.doc.nodes) || fi < 0 || fi >= len(app.doc.nodes[ni].fields) do return
	f := app.doc.nodes[ni].fields[fi]
	if !f.slot {
		if is_assign_target(app.doc.nodes[ni], fi) do set_assign_target(app, ni, fi, name) // field_access.odin
		app.assign_pick_new = false
		return
	}
	was_args := f.kind == "args"
	was_more := is_more_dot(f) // another result / return value (result_list.odin)
	hint, hint_pkg := f.hint, f.hint_pkg
	set_slot_text(app, ni, fi, name)
	if was_args do append_more_args_slot(&app.doc.nodes[ni].fields, fi, 1, hint, hint_pkg) // offer the next one
	at := fi
	if was_more do at += more_dot_filled(app, ni, fi) // its ", "
	if app.refill_active do refill_discard(app) // Y on an argument: the new name replaces it
	focus_field_index(app, ni, at)
}

// Cancel: back to the dot (or, for Y on a filled argument, its original text).
ref_pick_cancel :: proc(app: ^App) {
	// (Counted while still picking: the candidates depend on what's being picked.)
	nothing := app.assign_pick_new && len(ref_candidates(app)) == 0
	app.ref_pick_active = false
	if app.assign_pick_new { // a new Assignment without a target: it goes again (field_access.odin)
		if nothing do app.notice = "nothing declared to assign to here - declare it first (Declarations > Variable)"
		assign_pick_drop(app, app.ref_ni)
		return
	}
	if app.refill_active {
		refill_restore(app)
		return
	}
	if app.ref_ni >= 0 && app.ref_ni < len(app.doc.nodes) do focus_field_index(app, app.ref_ni, app.ref_fi)
}

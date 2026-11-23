package model

// The button layout (keymap.odin): defaults, resolving presses per bank, the
// conflict rules, holds, the keys file, and hint rewriting.

import "core:strings"
import "core:testing"

@(private = "file")
cleanup :: proc(app: ^App) {
	clear_nav(app)
	delete(app.nav)
	doc_reset(app)
	delete(app.doc.nodes)
	delete(app.recent_imports)
	free_menus(app)
}

@(private = "file")
select_label :: proc(app: ^App, label: string) -> bool {
	v := current_view(app)
	if v == nil do return false
	for e, i in v.entries {
		if e.label == label {
			v.index = i
			update(app, Input{confirm = true})
			return true
		}
	}
	return false
}

// A small file with the cursor on `count` (a name: LT+A edits it, Y changes it).
@(private = "file")
SRC :: "package main\n\nmain :: proc() {\n\tcount := 1\n\tcount += 2\n}\n"

@(private = "file")
setup :: proc(app: ^App) {
	app.state = .Editor
	doc_from_source(app, SRC)
	for n, i in app.doc.nodes {
		if strings.contains(node_text(n, context.temp_allocator), "count := 1") {
			app.editor_line = i
			break
		}
	}
	app.editor_field = 0
	app.editor_dot = false
}

@(test)
test_keymap_defaults :: proc(t: ^testing.T) {
	km := KEYMAP_DEFAULT
	testing.expect(t, keymap_valid(&km), "the default layout is valid")
	testing.expect_value(t, keymap_get(nil, BANK_LT, .A), Action.Edit)
	testing.expect_value(t, keymap_get(nil, BANK_LT, .B), Action.Delete)
	testing.expect_value(t, keymap_get(nil, BANK_LT, .X), Action.Talk)
	testing.expect_value(t, keymap_get(nil, BANK_LT, .Y), Action.Docs)
	testing.expect_value(t, keymap_get(nil, BANK_LT, .Left), Action.IDE_Menu)
	testing.expect_value(t, keymap_get(nil, BANK_LT, .Up), Action.None)
	testing.expect_value(t, keymap_get(nil, BANK_NONE, .A), Action.Select)
	testing.expect_value(t, keymap_get(nil, BANK_NONE, .B), Action.Back)
	testing.expect_value(t, keymap_get(nil, BANK_NONE, .X), Action.None)
	testing.expect_value(t, keymap_get(nil, BANK_NONE, .Y), Action.Change)
	testing.expect_value(t, keymap_get(nil, BANK_RT, .A), Action.Copy)
	testing.expect_value(t, keymap_get(nil, BANK_RT, .B), Action.Files)
	testing.expect_value(t, keymap_get(nil, BANK_RT, .X), Action.Grab)     // lift / drop (grab.odin)
	testing.expect_value(t, keymap_get(nil, BANK_LT, .Right), Action.Run_List)
	testing.expect_value(t, keymap_get(nil, BANK_RT, .Y), Action.Save_As)
	testing.expect_value(t, keymap_get(nil, BANK_RT, .Up), Action.Walk_Prev)
	testing.expect_value(t, keymap_get(nil, BANK_RT, .Left), Action.Walk_Out)
}

@(test)
test_keymap_resolve :: proc(t: ^testing.T) {
	r := keymap_resolve(nil, Input{confirm = true, lt_held = true})
	testing.expect_value(t, r.fired, Actions{.Edit})
	testing.expect(t, !r.rest.confirm, "LT+A is swallowed")
	r = keymap_resolve(nil, Input{confirm = true})
	testing.expect_value(t, r.fired, Actions{})
	testing.expect(t, r.rest.confirm, "plain A stays navigation")
	r = keymap_resolve(nil, Input{cancel = true, rt_held = true})
	testing.expect_value(t, r.fired, Actions{.Files})
	testing.expect(t, !r.rest.cancel, "RT+B is swallowed")
	r = keymap_resolve(nil, Input{left = true, rt_held = true})
	testing.expect_value(t, r.fired, Actions{.Walk_Out})
	r = keymap_resolve(nil, Input{up = true, lt_held = true})
	testing.expect_value(t, r.fired, Actions{})
	testing.expect(t, r.rest.up, "unbound LT+Up still moves the cursor")
	r = keymap_resolve(nil, Input{x = true, lt_held = true})
	testing.expect_value(t, r.fired, Actions{}) // Talk is a hold
	testing.expect(t, !r.rest.x)
	r = keymap_resolve(nil, Input{x = true})
	testing.expect_value(t, r.fired, Actions{})
	testing.expect(t, !r.rest.x, "unbound face buttons are swallowed")
	r = keymap_resolve(nil, Input{cancel = true, lt_held = true, rt_held = true})
	testing.expect_value(t, r.fired, Actions{.Delete}) // both triggers: LT wins
}

@(test)
test_keymap_update_delete_stays_in_editor :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app)
	before := doc_to_source(&app, context.temp_allocator)
	update(&app, Input{cancel = true, lt_held = true})
	testing.expect_value(t, app.state, State.Editor) // LT+B didn't also go back to the main menu
	testing.expect(t, doc_to_source(&app, context.temp_allocator) != before, "LT+B deleted something")
}

@(test)
test_keymap_update_requests :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app)
	update(&app, Input{y = true, rt_held = true})
	testing.expect_value(t, app.requests, Actions{.Save_As})
	testing.expect_value(t, app.state, State.Editor)
	app.requests = {}
	update(&app, Input{cancel = true, rt_held = true})
	testing.expect_value(t, app.requests, Actions{.Files})
	testing.expect_value(t, app.state, State.Editor) // RT+B isn't "back" too
}

@(test)
test_keymap_update_edit_and_menus :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	setup(&app)
	update(&app, Input{confirm = true, lt_held = true}) // LT+A on a name: text tools
	testing.expect_value(t, app.state, State.Radial)
	update(&app, Input{cancel = true})
	clear_nav(&app)
	app.state = .Menu
	update(&app, Input{left = true, lt_held = true}) // the IDE menu works on the main menu too
	testing.expect_value(t, app.state, State.Radial)
	testing.expect(t, select_label(&app, "Key layout"), "the IDE menu has Key layout")
	testing.expect_value(t, app.state, State.Menu) // back where it was opened
	testing.expect(t, .Key_Layout in app.requests)
	testing.expect_value(t, len(app.nav), 0)
}

// Y (Change) through update does what change_selected does.
@(test)
test_keymap_update_change :: proc(t: ^testing.T) {
	a, b: App
	defer cleanup(&a)
	defer cleanup(&b)
	setup(&a)
	setup(&b)
	update(&a, Input{y = true})
	change_selected(&b)
	testing.expect_value(t, a.state, b.state)
	testing.expect_value(t, len(a.nav), len(b.nav))
	testing.expect_value(t, doc_to_source(&a, context.temp_allocator), doc_to_source(&b, context.temp_allocator))
}

@(test)
test_keymap_custom_layout :: proc(t: ^testing.T) {
	km := KEYMAP_DEFAULT
	res, ob, obtn, moved := keymap_assign(&km, BANK_NONE, .X, .Docs) // Docs from LT+Y to plain X
	testing.expect_value(t, res, Assign_Result.Swapped)
	testing.expect_value(t, ob, BANK_LT)
	testing.expect_value(t, obtn, Pad_Button.Y)
	testing.expect_value(t, moved, Action.None)
	keymap_assign(&km, BANK_LT, .Y, .Change) // Change from plain Y to LT+Y
	testing.expect(t, keymap_valid(&km))

	app: App
	defer cleanup(&app)
	setup(&app)
	app.keymap = &km
	update(&app, Input{x = true})
	testing.expect_value(t, app.requests, Actions{.Docs})
	app.requests = {}
	update(&app, Input{y = true}) // plain Y is free now: nothing happens
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, app.requests, Actions{})

	ref: App
	defer cleanup(&ref)
	setup(&ref)
	change_selected(&ref)
	update(&app, Input{y = true, lt_held = true}) // LT+Y changes now
	testing.expect_value(t, app.state, ref.state)
	testing.expect_value(t, len(app.nav), len(ref.nav))
}

@(test)
test_keymap_assign_rules :: proc(t: ^testing.T) {
	km := KEYMAP_DEFAULT
	res, ob, obtn, moved := keymap_assign(&km, BANK_LT, .Y, .Save_As) // swap with Docs
	testing.expect_value(t, res, Assign_Result.Swapped)
	testing.expect_value(t, ob, BANK_RT)
	testing.expect_value(t, obtn, Pad_Button.Y)
	testing.expect_value(t, moved, Action.Docs)
	testing.expect_value(t, km.slots[BANK_RT][.Y], Action.Docs)
	testing.expect_value(t, km.slots[BANK_LT][.Y], Action.Save_As)
	testing.expect(t, keymap_valid(&km))

	km = KEYMAP_DEFAULT
	res, _, _, _ = keymap_assign(&km, BANK_NONE, .A, .Docs)
	testing.expect_value(t, res, Assign_Result.Locked)
	res, _, _, _ = keymap_assign(&km, BANK_RT, .Up, .Talk)
	testing.expect_value(t, res, Assign_Result.Not_Here) // Talk needs a face button
	res, _, _, _ = keymap_assign(&km, BANK_NONE, .X, .Walk_Prev)
	testing.expect_value(t, res, Assign_Result.Not_Here) // walks need a trigger
	res, ob, obtn, moved = keymap_assign(&km, BANK_LT, .X, .Walk_Prev) // would push Talk onto RT+Up
	testing.expect_value(t, res, Assign_Result.Not_Here)
	testing.expect_value(t, moved, Action.Talk)
	testing.expect_value(t, ob, BANK_RT)
	testing.expect_value(t, obtn, Pad_Button.Up)
	res, _, _, moved = keymap_assign(&km, BANK_LT, .B, .None)
	testing.expect_value(t, res, Assign_Result.Needs_Home)
	testing.expect_value(t, moved, Action.Delete)
	res, _, _, moved = keymap_assign(&km, BANK_RT, .B, .Run_Tests)
	testing.expect_value(t, res, Assign_Result.Needs_Home)
	testing.expect_value(t, moved, Action.Files)
	res, _, _, _ = keymap_assign(&km, BANK_LT, .A, .Edit)
	testing.expect_value(t, res, Assign_Result.Same)
	testing.expect_value(t, km, KEYMAP_DEFAULT) // refusals change nothing
	res, _, _, _ = keymap_assign(&km, BANK_LT, .A, .None)
	testing.expect_value(t, res, Assign_Result.Ok)
	testing.expect_value(t, km.slots[BANK_LT][.A], Action.None)
	testing.expect(t, keymap_valid(&km))
}

@(test)
test_keymap_holding :: proc(t: ^testing.T) {
	testing.expect(t, keymap_holding(nil, {.X}, true, false, .Talk))
	testing.expect(t, !keymap_holding(nil, {.X}, false, false, .Talk))
	testing.expect(t, keymap_holding(nil, {.X}, true, true, .Talk)) // RT ignored, as before
	testing.expect(t, !keymap_holding(nil, {.X}, false, true, .Talk))
	testing.expect(t, !keymap_holding(nil, {.Y}, true, false, .Talk))
	km := KEYMAP_DEFAULT
	keymap_assign(&km, BANK_NONE, .Y, .Talk) // Change goes to LT+X
	testing.expect(t, keymap_holding(&km, {.Y}, false, false, .Talk))
	testing.expect(t, !keymap_holding(&km, {.Y}, true, false, .Talk))
}

@(test)
test_keymap_bank_walks :: proc(t: ^testing.T) {
	testing.expect(t, keymap_bank_walks(nil, BANK_RT))
	testing.expect(t, !keymap_bank_walks(nil, BANK_LT))
	testing.expect(t, !keymap_bank_walks(nil, BANK_NONE))
	km := KEYMAP_DEFAULT
	keymap_assign(&km, BANK_LT, .Up, .Walk_Prev) // RT+Up empties
	testing.expect(t, keymap_bank_walks(&km, BANK_LT))
}

@(test)
test_keymap_round_trip :: proc(t: ^testing.T) {
	km := KEYMAP_DEFAULT
	keymap_assign(&km, BANK_NONE, .X, .Docs)
	keymap_assign(&km, BANK_LT, .Up, .Walk_Prev)
	keymap_assign(&km, BANK_RT, .A, .Delete)
	text := keymap_serialize(&km)
	defer delete(text)
	testing.expect(t, strings.has_prefix(text, KEYS_HEADER + "\n"), "header first")
	back, used := keymap_parse(text)
	testing.expect_value(t, used, 18)
	testing.expect_value(t, back, km)
	crlf, _ := strings.replace_all(text, "\n", "\r\n", context.temp_allocator)
	back2, _ := keymap_parse(crlf)
	testing.expect_value(t, back2, km)
	testing.expect(t, keys_text_ok(text))
	testing.expect(t, keys_text_ok(""))
	testing.expect(t, !keys_text_ok("doodle-keys 2\nlt\ta\tedit\n"))
}

@(test)
test_keymap_parse_repairs :: proc(t: ^testing.T) {
	// Duplicates (first wins), a locked slot, Talk on the d-pad, a walk on plain X,
	// unknown names, and no line for Save_As's slot after it moved away.
	text := "doodle-keys 1\n" +
		"plain\tx\tdocs\n" +
		"lt\ty\tdocs\n" +       // duplicate: dropped
		"plain\ta\tdelete\n" +  // locked slot: ignored
		"rt\tup\ttalk\n" +      // Talk can't be on the d-pad
		"plain\ty\twalk_next\n" + // walks need a trigger
		"rt\tleft\tbogus\n" +   // unknown action
		"mid\tx\tedit\n" +      // unknown bank
		"rt\ty\tnone\n" +       // Save_As loses its button...
		"lt\tb\tnone\n"         // ...and Delete too
	km, _ := keymap_parse(text)
	testing.expect(t, keymap_valid(&km), "repaired")
	testing.expect_value(t, km.slots[BANK_NONE][.X], Action.Docs)
	testing.expect_value(t, km.slots[BANK_LT][.Y], Action.None)
	testing.expect_value(t, km.slots[BANK_NONE][.A], Action.Select)
	testing.expect_value(t, km.slots[BANK_RT][.Up], Action.Walk_Prev)  // the Talk line is skipped: default
	testing.expect_value(t, km.slots[BANK_NONE][.Y], Action.Change)    // so is the walk on plain Y
	testing.expect_value(t, km.slots[BANK_RT][.Down], Action.Walk_Next)
	testing.expect_value(t, km.slots[BANK_LT][.X], Action.Talk)
	testing.expect_value(t, km.slots[BANK_RT][.Left], Action.Walk_Out) // not mentioned (bogus line skipped): default
	testing.expect_value(t, km.slots[BANK_RT][.Y], Action.Save_As)     // required: back home
	testing.expect_value(t, km.slots[BANK_LT][.B], Action.Delete)
	testing.expect_value(t, km.slots[BANK_LT][.A], Action.Edit)        // missing line: default

	// A missing line keeps its default unless the file moved that action.
	km2, _ := keymap_parse("doodle-keys 1\nplain\tx\tedit\n")
	testing.expect_value(t, km2.slots[BANK_NONE][.X], Action.Edit)
	testing.expect_value(t, km2.slots[BANK_LT][.A], Action.None)
	testing.expect_value(t, km2.slots[BANK_LT][.Y], Action.Docs)
	testing.expect(t, keymap_valid(&km2))

	// Required actions find another empty slot when their own is taken.
	km3, _ := keymap_parse("doodle-keys 1\nrt\ty\tdocs\nlt\ty\tnone\n")
	testing.expect(t, keymap_valid(&km3))
	testing.expect_value(t, km3.slots[BANK_RT][.Y], Action.Docs)
	sb, sbtn, ok := keymap_find(&km3, .Save_As)
	testing.expect(t, ok && keymap_allows(sb, sbtn, .Save_As))
}

@(test)
test_keymap_names_and_hints :: proc(t: ^testing.T) {
	testing.expect_value(t, slot_name(BANK_LT, .A), "LT+A")
	testing.expect_value(t, slot_name(BANK_NONE, .Y), "Y")
	testing.expect_value(t, slot_name(BANK_RT, .Up), "RT+Up")
	testing.expect_value(t, action_slot_name(nil, .Save_As), "RT+Y")

	h := "Y: add else when    LT+B: remove branch"
	testing.expect_value(t, rebind_hint(nil, h), h)
	testing.expect_value(t, rebind_hint(nil, "A: add a case"), "A: add a case")
	km := KEYMAP_DEFAULT
	keymap_assign(&km, BANK_RT, .A, .Delete) // Copy goes to LT+B
	testing.expect_value(t, rebind_hint(&km, "Y: x    LT+B: delete"), "Y: x    RT+A: delete")
	keymap_assign(&km, BANK_NONE, .Y, .None) // Change has no button
	testing.expect_value(t, rebind_hint(&km, "Y: x    RT+A: y"), "RT+A: y")
	testing.expect_value(t, rebind_hint(&km, "Y: options    LT+B: remove label"), "RT+A: remove label")
}

@(test)
test_keymap_try_leaves_the_keymap_alone :: proc(t: ^testing.T) {
	km := KEYMAP_DEFAULT
	res, ob, obtn, moved := keymap_try(&km, BANK_NONE, .X, .Docs)
	testing.expect_value(t, res, Assign_Result.Swapped)
	testing.expect_value(t, ob, BANK_LT)
	testing.expect_value(t, obtn, Pad_Button.Y)
	testing.expect_value(t, moved, Action.None)
	testing.expect_value(t, km, KEYMAP_DEFAULT)
	res, _, _, moved = keymap_try(&km, BANK_LT, .X, .Walk_Next) // Talk would land on RT+Down
	testing.expect_value(t, res, Assign_Result.Not_Here)
	testing.expect_value(t, moved, Action.Talk)
	res, _, _, moved = keymap_try(&km, BANK_RT, .Y, .Format_File) // Save as would lose its button
	testing.expect_value(t, res, Assign_Result.Needs_Home)
	testing.expect_value(t, moved, Action.Save_As)
	res, _, _, _ = keymap_try(&km, BANK_NONE, .X, .None) // already empty
	testing.expect_value(t, res, Assign_Result.Same)
}

@(test)
test_walk_natural_only_on_rt :: proc(t: ^testing.T) {
	testing.expect(t, walk_natural(BANK_RT, .Left, .Walk_Out))
	testing.expect(t, walk_natural(BANK_RT, .Up, .Walk_Prev))
	testing.expect(t, !walk_natural(BANK_LT, .Left, .Walk_Out)) // an LT walk must show: blank = unbound there
	testing.expect(t, !walk_natural(BANK_RT, .Left, .Walk_In))
}

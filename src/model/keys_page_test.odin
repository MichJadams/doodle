package model

// The Key Layout page (keys_page.odin): its fixed controls, the picker, reset.

import "core:testing"

@(private = "file")
pick_index :: proc(a: Action) -> int {
	for p, i in KEYS_PICK do if p == a do return i
	return -1
}

@(test)
test_keys_page_assign_flow :: proc(t: ^testing.T) {
	km := KEYMAP_DEFAULT
	p := keys_page_new(false, false)
	bank, b := keys_page_slot(&p)
	testing.expect_value(t, bank, BANK_NONE)
	testing.expect_value(t, b, Pad_Button.X) // starts on the free slot
	ev := keys_page_update(&p, &km, Input{confirm = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Opened_Picker)
	testing.expect(t, p.picking)
	testing.expect_value(t, p.pick, 0) // on "(nothing)": the slot's current action
	// Move to Docs (row 0, col 4): Left wraps from the first column to the last.
	ev = keys_page_update(&p, &km, Input{left = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Moved)
	testing.expect_value(t, p.pick, pick_index(.Docs))
	ev = keys_page_update(&p, &km, Input{confirm = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Swapped)
	testing.expect_value(t, ev.action, Action.Docs)
	testing.expect_value(t, ev.moved, Action.None)
	testing.expect_value(t, ev.bank, BANK_LT)
	testing.expect_value(t, ev.button, Pad_Button.Y)
	testing.expect(t, keys_page_changed(ev.kind))
	testing.expect(t, !p.picking)
	testing.expect_value(t, km.slots[BANK_NONE][.X], Action.Docs)
	testing.expect_value(t, km.slots[BANK_LT][.Y], Action.None)
	ev = keys_page_update(&p, &km, Input{cancel = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Done)
}

@(test)
test_keys_page_refusals :: proc(t: ^testing.T) {
	km := KEYMAP_DEFAULT
	p := keys_page_new(false, false)
	p.row = 0 // plain Up
	ev := keys_page_update(&p, &km, Input{confirm = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Locked)
	testing.expect(t, !p.picking)
	ev = keys_page_update(&p, &km, Input{x = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Locked)

	// Talk onto RT+Up: refused, the picker stays open.
	p.bank = BANK_RT
	keys_page_update(&p, &km, Input{confirm = true})
	p.pick = pick_index(.Talk)
	ev = keys_page_update(&p, &km, Input{confirm = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Not_Here)
	testing.expect_value(t, ev.action, Action.Talk)
	testing.expect(t, p.picking)
	ev = keys_page_update(&p, &km, Input{cancel = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Closed_Picker)

	// X on LT+B (Delete, required): refused.
	p.bank, p.row = BANK_LT, 5
	ev = keys_page_update(&p, &km, Input{x = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Needs_Home)
	testing.expect_value(t, ev.action, Action.Delete)
	// X on LT+A (Edit): cleared.
	p.row = 4
	ev = keys_page_update(&p, &km, Input{x = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Cleared)
	testing.expect_value(t, km.slots[BANK_LT][.A], Action.None)
	testing.expect(t, keymap_valid(&km))
}

@(test)
test_keys_page_reset :: proc(t: ^testing.T) {
	km := KEYMAP_DEFAULT
	keymap_assign(&km, BANK_NONE, .X, .Docs)
	p := keys_page_new(false, false)
	ev := keys_page_update(&p, &km, Input{y = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Ask_Reset)
	ev = keys_page_update(&p, &km, Input{down = true}) // ignored while asking
	testing.expect_value(t, ev.kind, Keys_Event_Kind.None)
	testing.expect_value(t, p.row, 6)
	ev = keys_page_update(&p, &km, Input{cancel = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Kept)
	testing.expect_value(t, km.slots[BANK_NONE][.X], Action.Docs)
	keys_page_update(&p, &km, Input{y = true})
	ev = keys_page_update(&p, &km, Input{confirm = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Reset)
	testing.expect_value(t, km, KEYMAP_DEFAULT)
	testing.expect(t, !p.asking_reset)
}

@(test)
test_keys_page_cursor_and_triggers :: proc(t: ^testing.T) {
	km := KEYMAP_DEFAULT
	p := keys_page_new(false, false)
	keys_page_update(&p, &km, Input{up = true})
	testing.expect_value(t, p.row, 5)
	keys_page_update(&p, &km, Input{down = true})
	keys_page_update(&p, &km, Input{down = true})
	keys_page_update(&p, &km, Input{down = true})
	testing.expect_value(t, p.row, 0) // wraps
	keys_page_update(&p, &km, Input{right = true})
	keys_page_update(&p, &km, Input{right = true})
	testing.expect_value(t, p.bank, BANK_LT) // wraps
	keys_page_update(&p, &km, Input{rt_held = true}) // a pull jumps to that card
	testing.expect_value(t, p.bank, BANK_RT)
	keys_page_update(&p, &km, Input{rt_held = true, left = true}) // still held: no jump, Left moves
	testing.expect_value(t, p.bank, BANK_NONE)
	keys_page_update(&p, &km, Input{rt_held = true, lt_held = true})
	testing.expect_value(t, p.bank, BANK_LT)

	// Opened with RT already held (Key layout on an RT combo): no jump.
	q := keys_page_new(false, true)
	keys_page_update(&q, &km, Input{rt_held = true})
	testing.expect_value(t, q.bank, BANK_NONE)
}

@(test)
test_keys_page_events_name_what_was_lost :: proc(t: ^testing.T) {
	km := KEYMAP_DEFAULT
	p := keys_page_new(false, false)
	// LT+X (Talk) <- Format file (no button yet): Talk is overwritten, and the event says so.
	p.bank, p.row = BANK_LT, 6
	keys_page_update(&p, &km, Input{confirm = true})
	p.pick = pick_index(.Format_File)
	ev := keys_page_update(&p, &km, Input{confirm = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Assigned)
	testing.expect_value(t, ev.action, Action.Format_File)
	testing.expect_value(t, ev.moved, Action.Talk)
	// X on LT+A (Edit): cleared, Edit named as lost.
	p.row = 4
	ev = keys_page_update(&p, &km, Input{x = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Cleared)
	testing.expect_value(t, ev.moved, Action.Edit)
	// Plain X (nothing) <- Docs from LT+Y: a swap that brings nothing back.
	p.bank, p.row = BANK_NONE, 6
	keys_page_update(&p, &km, Input{confirm = true})
	p.pick = pick_index(.Docs)
	ev = keys_page_update(&p, &km, Input{confirm = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Swapped)
	testing.expect_value(t, ev.moved, Action.None)
	testing.expect_value(t, ev.bank, BANK_LT) // where Docs came from
	testing.expect_value(t, ev.button, Pad_Button.Y)
}

@(test)
test_keys_page_refused_swap_names_the_pick :: proc(t: ^testing.T) {
	km := KEYMAP_DEFAULT
	p := keys_page_new(false, false)
	// LT+X (Talk) <- Walk: next (RT+Down): the walk fits, but Talk can't go on RT+Down.
	p.bank, p.row = BANK_LT, 6
	keys_page_update(&p, &km, Input{confirm = true})
	p.pick = pick_index(.Walk_Next)
	ev := keys_page_update(&p, &km, Input{confirm = true})
	testing.expect_value(t, ev.kind, Keys_Event_Kind.Not_Here)
	testing.expect_value(t, ev.action, Action.Talk)
	testing.expect_value(t, ev.picked, Action.Walk_Next)
	testing.expect_value(t, ev.bank, BANK_RT)
	testing.expect_value(t, ev.button, Pad_Button.Down)
	testing.expect(t, p.picking)
	testing.expect_value(t, km, KEYMAP_DEFAULT)
}

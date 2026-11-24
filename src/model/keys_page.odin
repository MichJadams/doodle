package model

// The Key Layout page's logic (drawn by app/keys_page.odin). A cursor on one of
// the three bank cards x 8 buttons, a picker of actions for the slot under it,
// and a "reset all?" prompt. Its own controls are fixed (never read from the
// keymap), so a layout can't make the page unusable.

// Rows of a bank card, top to bottom.
KEYS_ROWS := [8]Pad_Button{.Up, .Down, .Left, .Right, .A, .B, .X, .Y}

// The picker: 5 x 5 via grid_nav (grid_cols(22) = 5; the last row holds Grab and Save).
KEYS_PICK := [22]Action{
	.None,      .Edit,         .Delete,    .Change,   .Docs,
	.Copy,      .Talk,         .Save_As,   .Files,    .Prev_File,
	.Run_List,  .Run_Favorite, .Run_Tests, .IDE_Menu, .Format_File,
	.Walk_Prev, .Walk_Next,    .Walk_In,   .Walk_Out, .Key_Layout,
	.Grab,      .Save,
}

Keys_Page :: struct {
	bank, row:        int,  // cursor = KEYS_ROWS[row] in bank
	picking:          bool, // the action picker is open
	pick:             int,  // index into KEYS_PICK
	asking_reset:     bool, // "Reset every button?" is showing
	prev_lt, prev_rt: bool, // trigger state last frame (a pull jumps to that card)
}

Keys_Event_Kind :: enum {
	None, Moved, Opened_Picker, Closed_Picker,
	Assigned, Swapped, Same, Locked, Not_Here, Needs_Home, Cleared,
	Ask_Reset, Reset, Kept, Done,
}

// What a press did. Assigned / Cleared: `action` now on (bank, button), and
// `moved` is the action that was there and now has no button (None if none).
// Swapped: `action` went on the cursor slot and `moved` to (bank, button), where
// `action` was. Not_Here: `action` can't go on (bank, button); `picked` is what
// was chosen (another action when the swap is what's refused). Needs_Home:
// `action` (required) would lose its only button.
Keys_Event :: struct {
	kind:   Keys_Event_Kind,
	action: Action,
	bank:   int,
	button: Pad_Button,
	moved:  Action,
	picked: Action,
}

// keys_page_new starts on plain X (the free slot). lt / rt: triggers already
// held when the page opened (from a trigger combo), so they don't count as a pull.
keys_page_new :: proc(lt, rt: bool) -> Keys_Page {
	return {bank = BANK_NONE, row = 6, prev_lt = lt, prev_rt = rt}
}

keys_page_slot :: proc(p: ^Keys_Page) -> (int, Pad_Button) { return p.bank, KEYS_ROWS[p.row] }

// The keymap changed (the app saves it).
keys_page_changed :: proc(k: Keys_Event_Kind) -> bool {
	return k == .Assigned || k == .Swapped || k == .Cleared || k == .Reset
}

keys_page_update :: proc(p: ^Keys_Page, km: ^Keymap, inp: Input) -> Keys_Event {
	lt_pull := inp.lt_held && !p.prev_lt
	rt_pull := inp.rt_held && !p.prev_rt
	p.prev_lt, p.prev_rt = inp.lt_held, inp.rt_held
	switch {
	case p.asking_reset: return keys_reset_update(p, km, inp)
	case p.picking:      return keys_picker_update(p, km, inp)
	}
	bank, b := keys_page_slot(p)
	switch {
	case lt_pull || rt_pull:
		p.bank = BANK_LT if lt_pull else BANK_RT
		return {kind = .Moved}
	case inp.up || inp.down:
		p.row = (p.row + (inp.up ? -1 : 1) + len(KEYS_ROWS)) % len(KEYS_ROWS)
		return {kind = .Moved}
	case inp.left || inp.right:
		p.bank = (p.bank + (inp.left ? -1 : 1) + BANKS) % BANKS
		return {kind = .Moved}
	case inp.cancel:
		return {kind = .Done}
	case inp.confirm:
		if slot_locked(bank, b) do return {kind = .Locked, bank = bank, button = b}
		p.picking = true
		p.pick = 0
		cur := km.slots[bank][b]
		for a, i in KEYS_PICK do if a == cur do p.pick = i
		return {kind = .Opened_Picker}
	case inp.x:
		old := km.slots[bank][b]
		res, rb, rbtn, moved := keymap_assign(km, bank, b, .None)
		#partial switch res {
		case .Ok:         return {kind = .Cleared, action = .None, bank = bank, button = b, moved = old}
		case .Needs_Home: return {kind = .Needs_Home, action = moved, bank = rb, button = rbtn}
		case .Locked:     return {kind = .Locked, bank = bank, button = b}
		}
		return {kind = .Same, bank = bank, button = b}
	case inp.y:
		p.asking_reset = true
		return {kind = .Ask_Reset}
	}
	return {}
}

@(private = "file")
keys_reset_update :: proc(p: ^Keys_Page, km: ^Keymap, inp: Input) -> Keys_Event {
	if inp.confirm {
		km^ = KEYMAP_DEFAULT
		p.asking_reset = false
		return {kind = .Reset}
	}
	if inp.cancel || inp.y {
		p.asking_reset = false
		return {kind = .Kept}
	}
	return {}
}

@(private = "file")
keys_picker_update :: proc(p: ^Keys_Page, km: ^Keymap, inp: Input) -> Keys_Event {
	if inp.cancel {
		p.picking = false
		return {kind = .Closed_Picker}
	}
	if inp.up || inp.down || inp.left || inp.right {
		p.pick = grid_nav(p.pick, len(KEYS_PICK), inp)
		return {kind = .Moved}
	}
	if !inp.confirm do return {}
	bank, b := keys_page_slot(p)
	a := KEYS_PICK[p.pick]
	old := km.slots[bank][b]
	res, rb, rbtn, moved := keymap_assign(km, bank, b, a)
	switch res {
	case .Ok:
		p.picking = false
		return {kind = .Assigned, action = a, bank = bank, button = b, moved = old}
	case .Swapped:
		p.picking = false
		return {kind = .Swapped, action = a, bank = rb, button = rbtn, moved = moved}
	case .Same:
		p.picking = false
		return {kind = .Same, action = a, bank = bank, button = b}
	case .Not_Here:
		return {kind = .Not_Here, action = moved, bank = rb, button = rbtn, picked = a}
	case .Needs_Home:
		return {kind = .Needs_Home, action = moved, bank = rb, button = rbtn}
	case .Locked:
		p.picking = false
		return {kind = .Locked, bank = bank, button = b}
	}
	return {}
}

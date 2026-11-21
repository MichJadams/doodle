package main

// The Key Layout page (model/keys_page.odin has its logic): three cards, one per
// bank (LT held / no trigger / RT held), each with its button diagram and a row
// per button; A on a row picks the action for that slot. Opened from the main
// menu, the IDE menu or the Key_Layout action. Its controls are fixed, and it
// owns all input while open. Every change is saved at once (keys_store.odin).

import "../gpu"
import "../model"
import "../text"
import "core:fmt"
import "core:math"

g_keys_open:  bool
g_keys:       model.Keys_Page
g_keys_flash: struct { bank: int, b: model.Pad_Button, t: f64 } // the slot a swap moved; glows a moment

KEYS_FLASH_SECS :: 1.4

// keys_page_open: lt / rt held now (opened from a trigger combo) don't count as a pull.
keys_page_open :: proc(inp: model.Input) {
	g_keys = model.keys_page_new(inp.lt_held, inp.rt_held)
	g_keys_flash = {t = -1}
	g_keys_open = true
}

keys_page_close :: proc() { g_keys_open = false }

handle_keys_input :: proc(raw: ^Raw, inp: model.Input) {
	pin := model.Input{
		up = raw.e_up, down = raw.e_down, left = raw.e_left, right = raw.e_right,
		confirm = raw.e_confirm || raw.e_a, cancel = raw.e_cancel || raw.e_b,
		x = raw.e_x, y = raw.e_y,
		lt_held = inp.lt_held, rt_held = inp.rt_held,
	}
	ev := model.keys_page_update(&g_keys, &g_keymap, pin)
	if model.keys_page_changed(ev.kind) do keys_store_save()
	keys_feedback(ev)
	if ev.kind == .Done do keys_page_close()
	// Owns all input: consume every edge (B here must not also quit from the main menu).
	raw.e_confirm, raw.e_cancel, raw.e_a, raw.e_b, raw.e_x, raw.e_y = false, false, false, false, false, false
	raw.e_up, raw.e_down, raw.e_left, raw.e_right = false, false, false, false
	raw.e_rb, raw.e_lb, raw.e_copy = false, false, false
}

// keys_feedback: a status line (and a sound) for what a press did.
keys_feedback :: proc(ev: model.Keys_Event) {
	label := model.ACTION_INFO[ev.action].label
	#partial switch ev.kind {
	case .Assigned, .Cleared:
		set_status(fmt.tprintf("%s: %s%s", model.slot_name(ev.bank, ev.button), label, keys_lost_note(ev.moved)))
		if ev.kind == .Assigned do sfx_pencil()
	case .Swapped:
		if ev.moved == .None {
			// Nothing came back: say where it came from (that slot is empty now).
			bank, b := model.keys_page_slot(&g_keys)
			set_status(fmt.tprintf("%s moved from %s to %s", label, model.slot_name(ev.bank, ev.button), model.slot_name(bank, b)))
		} else {
			set_status(fmt.tprintf("%s moved to %s", model.ACTION_INFO[ev.moved].label, model.slot_name(ev.bank, ev.button)))
		}
		g_keys_flash = {ev.bank, ev.button, g_time}
		sfx_pencil()
	case .Locked:
		set_status("D-pad, A and B (no trigger) always move, select and go back")
	case .Not_Here:
		if ev.picked != .None && ev.picked != ev.action {
			// The pick fits here; the swap would put the old action where it can't go.
			set_status(fmt.tprintf("Can't swap: %s would move to %s, and %s", label,
				model.slot_name(ev.bank, ev.button), keys_slot_rule(ev.action, ev.bank, ev.button)))
			return
		}
		info := model.ACTION_INFO[ev.action]
		switch {
		case info.face_only:    set_status(fmt.tprintf("%s needs a face button (the d-pad splits words while you talk)", info.label))
		case info.trigger_only: set_status("Walking needs a trigger (the highlight follows it)")
		case:                   set_status(fmt.tprintf("%s can't go on %s", info.label, model.slot_name(ev.bank, ev.button)))
		}
	case .Needs_Home:
		set_status(fmt.tprintf("%s needs a button: give it another one first", label))
	case .Reset:
		set_status("Buttons reset to the defaults")
		sfx_paper()
	}
}

// keys_lost_note ends the status line when an action just lost its only button
// (overwriting or clearing is allowed, but it shouldn't go unnoticed).
keys_lost_note :: proc(lost: model.Action) -> string {
	if lost == .None do return ""
	return fmt.tprintf("  -  %s has no button now", model.ACTION_INFO[lost].label)
}

// keys_slot_rule: why `a` can't sit on that slot, as the end of a sentence.
keys_slot_rule :: proc(a: model.Action, bank: int, b: model.Pad_Button) -> string {
	info := model.ACTION_INFO[a]
	switch {
	case info.face_only:    return fmt.tprintf("%s needs a face button", info.label)
	case info.trigger_only: return "walking needs a trigger"
	}
	return fmt.tprintf("%s can't go on %s", info.label, model.slot_name(bank, b))
}

// ---------------- Drawing ----------------

KEYS_DPAD_COL :: gpu.Color{0.55, 0.51, 0.45, 1} // the HUD's d-pad ink
KEYS_CHIP_INK :: gpu.Color{0.97, 0.95, 0.90, 1}
// The veil's sheet, opaque: this is a whole page, and the menu's own hint line
// sits right where the footer goes.
KEYS_PAGE_BG  :: gpu.Color{0.84, 0.80, 0.72, 1}
KEYS_ROW_GAP  :: f32(4)

// The face button colors draw_bank uses.
keys_face_col :: proc(b: model.Pad_Button) -> gpu.Color {
	#partial switch b {
	case .Y: return {0.92, 0.78, 0.25, 1}
	case .A: return {0.30, 0.78, 0.42, 1}
	case .X: return {0.28, 0.52, 0.90, 1}
	case .B: return {0.86, 0.30, 0.30, 1}
	}
	return KEYS_DPAD_COL
}

DPAD_ARROW := [4]string{"^", "v", "<", ">"}

// Where things go for a window size. The title block is pinned near the top (a
// proportional one ran into the cards on tall windows); the cards fill the room
// above the footer and HUD and end under their last row. A short window shrinks
// the diagram, then drops it, before the rows get too small to read.
Keys_Layout :: struct {
	title_y, sub_y: f32,
	top:            f32, // cards
	card_w, card_h: f32,
	diag_s:         f32, // diagram scale; 0 = no diagram
	list_off:       f32, // rows start at top + list_off
	row_h:          f32,
	footer_y:       f32,
}

keys_layout :: proc(fw, fh: f32) -> Keys_Layout {
	HEAD      :: f32(36)  // the card's header line
	DIAG      :: f32(116) // the diagram's height at scale 1 (+-48 and the cursor ring)
	DIAG_W    :: f32(250) // its width at scale 1
	DIAG_MIN  :: f32(0.7) // smaller and the glyphs overflow the buttons
	ROW_IDEAL :: f32(36)
	ROW_MIN   :: f32(22)
	rows := f32(len(model.KEYS_ROWS))

	l: Keys_Layout
	l.title_y = clamp(fh * 0.07, 12, 56)
	l.sub_y = l.title_y + 30
	l.top = l.sub_y + 34
	l.card_w = (fw - 2 * 40 - 2 * 20) / 3
	room := (fh - 185) - l.top // down to the HUD + hint line (as draw_radial)

	fit_w := (l.card_w - 16) / DIAG_W
	s := min(1, fit_w, (room - HEAD - 8 - rows * (ROW_IDEAL + KEYS_ROW_GAP)) / DIAG)
	if s < DIAG_MIN {
		s = DIAG_MIN
		rows_then := (room - HEAD - DIAG * DIAG_MIN - 8) / rows - KEYS_ROW_GAP
		if fit_w < DIAG_MIN || rows_then < ROW_MIN do s = 0
	}
	l.diag_s = s
	l.list_off = HEAD + DIAG * s
	l.row_h = clamp((room - l.list_off - 8) / rows - KEYS_ROW_GAP, 18, 38)
	l.card_h = l.list_off + rows * (l.row_h + KEYS_ROW_GAP) + 4
	l.footer_y = min(fh - 172, l.top + l.card_h + 12)
	return l
}

draw_keys_page :: proc(r: ^gpu.Renderer, w, h: int) {
	fw, fh := f32(w), f32(h)
	l := keys_layout(fw, fh)
	gpu.draw_rect(r, {0, 0, fw, fh}, KEYS_PAGE_BG)
	text.draw_centered(r, g_ui, {0, l.title_y, fw, 36}, "KEY LAYOUT", COL_ACCENT)
	for bk in 0 ..< model.BANKS {
		draw_keys_card(r, bk, 40 + f32(bk) * (l.card_w + 20), &l)
	}

	// The picker / reset prompt cover the cards; the footer goes on top. A narrow
	// window drops the aside rather than cutting a control off.
	footer := "D-pad move   A change   X clear   Y reset all   LT/RT jump   B done     (LB tests, RB run are fixed)"
	if text.measure(g_ui, footer).x > fw - 40 do footer = "D-pad move   A change   X clear   Y reset all   LT/RT jump   B done"
	switch {
	case g_keys.asking_reset:
		draw_keys_reset_prompt(r, fw, &l)
		footer = "A reset   B keep"
	case g_keys.picking:
		draw_keys_picker(r, fw, fh, &l)
		footer = "D-pad move   A assign   B cancel"
	case:
		bank, b := model.keys_page_slot(&g_keys)
		text.draw_centered(r, g_ui, {0, l.sub_y, fw, 24}, fit_label(g_ui, keys_subtitle(bank, b), fw - 80), HINT_COL)
	}
	text.draw_centered(r, g_ui, {0, l.footer_y, fw, 24}, fit_label(g_ui, footer, fw - 40), COL_DIM)
}

// The line under the title: what the slot under the cursor does.
keys_subtitle :: proc(bank: int, b: model.Pad_Button) -> string {
	name := model.slot_name(bank, b)
	if model.slot_locked(bank, b) do return fmt.tprintf("%s: fixed - always moves / selects / goes back", name)
	info := model.ACTION_INFO[model.keymap_get(&g_keymap, bank, b)]
	if info.hint == "" do return fmt.tprintf("%s: %s  -  A picks an action for it", name, info.label)
	return fmt.tprintf("%s: %s  -  %s", name, info.label, info.hint)
}

draw_keys_card :: proc(r: ^gpu.Renderer, bank: int, x: f32, l: ^Keys_Layout) {
	here := bank == g_keys.bank
	card := gpu.Rect{x, l.top, l.card_w, l.card_h}
	gpu.draw_rect(r, card, COL_BG)
	gpu.draw_rect_outline(r, card, 2, here ? COL_ACCENT : COL_RULE)
	text.draw_centered(r, g_ui, {x, l.top + 8, l.card_w, 24}, HUD_LABELS[bank], here ? COL_ACCENT : COL_DIM)

	// The button diagram, as the HUD draws it (never the mic glow).
	if s := l.diag_s; s > 0 {
		cx, cy := x + l.card_w / 2, l.top + 36 + 58 * s
		draw_bank(r, &g_keymap, bank, cx, cy, s, true, false)
		if here && !g_keys.asking_reset {
			pulse := 0.5 + 0.5 * math.sin(f32(g_time) * 4)
			b := model.KEYS_ROWS[g_keys.row]
			sx, sy := bank_slot_pos(cx, cy, s, b)
			ring := (model.is_dpad(b) ? f32(10) : f32(16)) * s + 5 + 2 * pulse
			gpu.draw_circle_outline(r, sx, sy, ring, 2.5, COL_ACCENT)
		}
	}

	list_top := l.top + l.list_off
	for b, row in model.KEYS_ROWS {
		box := gpu.Rect{x + 12, list_top + f32(row) * (l.row_h + KEYS_ROW_GAP), l.card_w - 24, l.row_h}
		draw_keys_row(r, bank, b, here && row == g_keys.row && !g_keys.asking_reset, box)
	}
}

draw_keys_row :: proc(r: ^gpu.Renderer, bank: int, b: model.Pad_Button, cursor: bool, box: gpu.Rect) {
	gpu.draw_rect(r, box, cursor ? COL_HILITE : COL_PANEL)
	if cursor do gpu.draw_rect_outline(r, box, 2, COL_ACCENT)

	// The button chip: a d-pad arrow, or the face button in its color (smaller on short rows).
	chip := min(f32(26), box.h - 2)
	chip_x, mid := box.x + 20, box.y + box.h / 2
	if model.is_dpad(b) {
		cbox := gpu.Rect{chip_x - chip / 2, mid - chip / 2, chip, chip}
		gpu.draw_rect(r, cbox, KEYS_DPAD_COL)
		text.draw_centered(r, g_ui, cbox, DPAD_ARROW[int(b)], KEYS_CHIP_INK)
	} else {
		draw_face(r, g_ui, chip_x, mid, chip / 2 - 1, keys_face_col(b), model.BUTTON_NAME[b])
	}

	a := model.keymap_get(&g_keymap, bank, b)
	locked := model.slot_locked(bank, b)
	if icon, ok := action_icon(a); ok do draw_icon(r, icon, box.x + 52, mid, min(f32(22), box.h - 4), COL_TEXT)
	col := (locked || a == .None) ? COL_DIM : COL_TEXT
	label := fit_label(g_ui, model.ACTION_INFO[a].label, box.w - 130)
	lh := text.line_height(g_ui)
	text.draw_line(r, g_ui, {box.x + 70, mid - lh / 2}, label, col)
	if locked {
		fw := text.measure(g_ui, "fixed").x
		text.draw_line(r, g_ui, {box.x + box.w - fw - 10, mid - lh / 2}, "fixed", COL_DIM)
	}
	keys_draw_flash(r, bank, b, box)
}

// keys_draw_flash: the slot a swap just moved something to glows amber, not the
// cursor's green (it mustn't read as a second selection), with a "moved" tag.
keys_draw_flash :: proc(r: ^gpu.Renderer, bank: int, b: model.Pad_Button, box: gpu.Rect) {
	f := g_keys_flash
	if f.t < 0 || f.bank != bank || f.b != b do return
	age := g_time - f.t
	if age >= KEYS_FLASH_SECS do return
	c := COL_WARN
	c.a = f32(1 - age / KEYS_FLASH_SECS)
	gpu.draw_rect_outline(r, {box.x - 3, box.y - 3, box.w + 6, box.h + 6}, 3, c)
	tw := text.measure(g_ui, "moved").x
	text.draw_line(r, g_ui, {box.x + box.w - tw - 10, box.y + box.h / 2 - text.line_height(g_ui) / 2}, "moved", c)
}

// draw_keys_reset_prompt: a destructive question, so it covers the cards and
// the cursor goes away, instead of only changing the footer.
draw_keys_reset_prompt :: proc(r: ^gpu.Renderer, fw: f32, l: ^Keys_Layout) {
	gpu.draw_rect(r, {0, l.top - 4, fw, l.card_h + 8}, {0.84, 0.80, 0.72, 0.8})
	text.draw_centered(r, g_ui, {0, l.sub_y, fw, 24}, "Reset every button to the defaults?", COL_ACCENT)
	pw, ph := min(f32(620), fw - 80), f32(150)
	box := gpu.Rect{(fw - pw) / 2, l.top + (l.card_h - ph) / 2, pw, ph}
	gpu.draw_rect(r, box, COL_BG)
	gpu.draw_rect_outline(r, box, 2, COL_ACCENT)
	text.draw_centered(r, g_ui, {box.x, box.y + 22, pw, 28}, "Reset every button?", COL_ACCENT)
	text.draw_centered(r, g_ui, {box.x, box.y + 58, pw, 24}, fit_label(g_ui, "Your layout goes back to the one Doodle ships with.", pw - 40), COL_TEXT)
	text.draw_centered(r, g_ui, {box.x, box.y + 102, pw, 24}, "A reset        B keep", COL_DIM)
}

draw_keys_picker :: proc(r: ^gpu.Renderer, fw, fh: f32, l: ^Keys_Layout) {
	gpu.draw_rect(r, {0, 0, fw, fh}, COL_VEIL)
	bank, b := model.keys_page_slot(&g_keys)
	text.draw_centered(r, g_ui, {0, l.title_y, fw, 36}, fmt.tprintf("%s: pick an action", model.slot_name(bank, b)), COL_ACCENT)
	// Under the title: what the chosen action does, or (refused) the whole reason
	// its narrow cell may have had to shorten.
	sel := model.KEYS_PICK[g_keys.pick]
	sub, sub_col := model.ACTION_INFO[sel].hint, HINT_COL
	if n := keys_pick_note(bank, b, sel); !n.ok do sub, sub_col = fmt.tprintf("%s  -  %s", model.ACTION_INFO[sel].label, n.long), COL_WARN
	if sub != "" do text.draw_centered(r, g_ui, {0, l.sub_y, fw, 24}, fit_label(g_ui, sub, fw - 80), sub_col)

	cols := model.grid_cols(len(model.KEYS_PICK))
	gap, vgap := f32(12), f32(8)
	cellw := min(f32(220), (fw - 80 - f32(cols - 1) * gap) / f32(cols))
	cellh := f32(56)
	start_x := (fw - (f32(cols) * cellw + f32(cols - 1) * gap)) * 0.5
	start_y := max(fh * 0.16, l.sub_y + 36)
	for a, i in model.KEYS_PICK {
		box := gpu.Rect{start_x + f32(i % cols) * (cellw + gap), start_y + f32(i / cols) * (cellh + vgap), cellw, cellh}
		active := i == g_keys.pick
		note := keys_pick_note(bank, b, a)
		gpu.draw_rect(r, box, active ? COL_HILITE : COL_PANEL)
		if active do gpu.draw_rect_outline(r, box, 2, COL_ACCENT)
		ink := note.ok ? COL_TEXT : COL_DIM

		// Icon, or the HUD glyph in a small disc.
		ix, iy := box.x + 18, box.y + cellh / 2
		if icon, ok := action_icon(a); ok && draw_icon(r, icon, ix, iy, 22, ink) {
		} else if g := model.ACTION_INFO[a].glyph; g != "" {
			gpu.draw_circle(r, ix, iy, 11, note.ok ? KEYS_DPAD_COL : COL_RULE)
			text.draw_centered(r, g_ui, {ix - 11, iy - 11, 22, 22}, g, KEYS_CHIP_INK)
		}

		tx, tw := box.x + 36, cellw - 44
		text.draw_line(r, g_ui, {tx, box.y + 8}, fit_label(g_ui, model.ACTION_INFO[a].label, tw), ink)
		// A narrow cell gets the short form, so the slot name is never cut off.
		line := note.long if text.measure(g_ui, note.long).x <= tw else note.short
		if line != "" do text.draw_line(r, g_ui, {tx, box.y + 30}, fit_label(g_ui, line, tw), note.col)
	}
}

// What A on a picker cell would do: its second line (long, or short for a
// narrow cell), and ok = false when it would be refused (the cell is dimmed).
Pick_Note :: struct {
	long, short: string,
	col:         gpu.Color,
	ok:          bool,
}

keys_pick_note :: proc(bank: int, b: model.Pad_Button, a: model.Action) -> Pick_Note {
	res, ob, obtn, moved := model.keymap_try(&g_keymap, bank, b, a)
	info := model.ACTION_INFO[a]
	#partial switch res {
	case .Not_Here:
		if moved != a {
			// It fits here, but what's here now can't go where it is.
			push := fmt.tprintf("would push %s to %s", model.ACTION_INFO[moved].label, model.slot_name(ob, obtn))
			return {push, "can't swap", COL_DIM, false}
		}
		if info.face_only do return {"face buttons only", "face only", COL_DIM, false}
		if info.trigger_only do return {"needs a trigger", "trigger only", COL_DIM, false}
		return {"not here", "not here", COL_DIM, false}
	case .Needs_Home:
		return {fmt.tprintf("%s needs this button", model.ACTION_INFO[moved].label), "can't replace", COL_DIM, false}
	case .Locked:
		return {"fixed", "fixed", COL_DIM, false}
	case .Same:
		return {"this button", "this button", COL_ACCENT, true}
	case .Swapped:
		at := model.slot_name(ob, obtn)
		return {fmt.tprintf("now on %s", at), at, COL_DIM, true}
	}
	// No button yet. Run favorite / Run tests still have RB / LB (main.odin).
	#partial switch a {
	case .None:         return {ok = true}
	case .Run_Favorite: return {"RB (fixed)", "RB (fixed)", COL_DIM, true}
	case .Run_Tests:    return {"LB (fixed)", "LB (fixed)", COL_DIM, true}
	}
	return {"no button yet", "no button", COL_DIM, true}
}

package model

// The button layout (Key Layout page, docs/EDITOR_MODEL.md §5). Every editor
// control fits one pattern: a d-pad and the X/Y/A/B buttons, in three banks
// (left trigger held, no trigger, right trigger held). A Keymap says which
// action each of those 24 slots does; model.update turns presses into actions
// through it, and the HUD draws itself from it. Plain d-pad, A and B are locked
// (they move, select and go back everywhere, menus included), so a layout can
// never lock you out. Pure: the app layer loads / saves it (keys_store.odin).

import "core:fmt"
import "core:strings"

Pad_Button :: enum u8 { Up, Down, Left, Right, A, B, X, Y }
Pad_Held   :: bit_set[Pad_Button]

BANK_LT   :: 0 // same numbering as active_bank / the HUD's three cards
BANK_NONE :: 1
BANK_RT   :: 2
BANKS     :: 3

Action :: enum u8 {
	None,
	Move_Up, Move_Down, Move_Left, Move_Right, Select, Back, // fixed: locked slots only
	Edit, Delete, Change, Docs, Copy, Save_As, Run_List, Files,
	Run_Favorite, Run_Tests, Talk, IDE_Menu,
	Walk_Prev, Walk_Next, Walk_In, Walk_Out,
	Format_File, Prev_File, Key_Layout,
}
Actions :: bit_set[Action]

Keymap :: struct {
	slots: [BANKS][Pad_Button]Action,
}

Action_Info :: struct {
	key:          string, // name in doodle_keys.tsv; never renamed once shipped
	label:        string, // page / picker
	glyph:        string, // HUD text, ASCII 32..127
	hint:         string, // one line under the page title
	fixed:        bool,   // locked slots only
	hold:         bool,   // acts while held (Talk)
	face_only:    bool,   // not on the d-pad (Talk: d-pad Down splits words)
	trigger_only: bool,   // only in LT/RT banks (walks: the highlight follows the held trigger)
	required:     bool,   // always exactly one button
}

ACTION_INFO := [Action]Action_Info{
	.None         = {key = "none",         label = "(nothing)"},
	.Move_Up      = {key = "move_up",      label = "Move up",      fixed = true, hint = "move the cursor"},
	.Move_Down    = {key = "move_down",    label = "Move down",    fixed = true, hint = "move the cursor"},
	.Move_Left    = {key = "move_left",    label = "Move left",    fixed = true, hint = "move the cursor"},
	.Move_Right   = {key = "move_right",   label = "Move right",   fixed = true, hint = "move the cursor"},
	.Select       = {key = "select",       label = "Select / add", glyph = "+", fixed = true, hint = "A on a dot adds code, on a slot fills it"},
	.Back         = {key = "back",         label = "Back",         glyph = "<", fixed = true, hint = "back to the main menu (and out of menus)"},
	.Edit         = {key = "edit",         label = "Edit",         glyph = "e", hint = "replace the highlighted part (keypad on numbers, text tools on names)"},
	.Delete       = {key = "delete",       label = "Delete",       glyph = "x", required = true, hint = "delete the highlighted part"},
	.Change       = {key = "change",       label = "Change",       glyph = "*", hint = "change the highlighted part: another proc, refill an argument..."},
	.Docs         = {key = "docs",         label = "Docs",         glyph = "?", hint = "documentation of the highlighted part"},
	.Copy         = {key = "copy",         label = "Copy",         glyph = "C", hint = "copy the statement / block (whole file on a green dot)"},
	.Save_As      = {key = "save_as",      label = "Save as",      glyph = "S", required = true, hint = "name the file and save it"},
	.Run_List     = {key = "run_list",     label = "Run list",     glyph = ">", hint = "pick a command to run"},
	.Files        = {key = "files",        label = "Files",        glyph = "F", required = true, hint = "browse the project's files"},
	.Run_Favorite = {key = "run_favorite", label = "Run favorite", glyph = "R", hint = "save, then run the favorite command (RB too)"},
	.Run_Tests    = {key = "run_tests",    label = "Run tests",    glyph = "T", hint = "save, then run odin test . (LB too)"},
	.Talk         = {key = "talk",         label = "Talk",         glyph = "m", hold = true, face_only = true, hint = "hold to dictate into the highlighted name / string / number"},
	.IDE_Menu     = {key = "ide_menu",     label = "IDE menu",     glyph = "=", hint = "format file, key layout, exit"},
	.Walk_Prev    = {key = "walk_prev",    label = "Walk: previous", glyph = "^", trigger_only = true, hint = "previous part of the code tree"},
	.Walk_Next    = {key = "walk_next",    label = "Walk: next",   glyph = "v", trigger_only = true, hint = "next part of the code tree"},
	.Walk_In      = {key = "walk_in",      label = "Walk: in",     glyph = "}", trigger_only = true, hint = "into the highlighted part"},
	.Walk_Out     = {key = "walk_out",     label = "Walk: out",    glyph = "{", trigger_only = true, hint = "out to the part around it"},
	.Format_File  = {key = "format_file",  label = "Format file",  glyph = "~", hint = "fix indentation and blank lines"},
	.Prev_File    = {key = "prev_file",    label = "Previous file", glyph = "P", hint = "switch back to the file you had before"},
	.Key_Layout   = {key = "key_layout",   label = "Key layout",   glyph = "K", hint = "open this page"},
}

BUTTON_KEY  := [Pad_Button]string{.Up = "up", .Down = "down", .Left = "left", .Right = "right", .A = "a", .B = "b", .X = "x", .Y = "y"}
BUTTON_NAME := [Pad_Button]string{.Up = "Up", .Down = "Down", .Left = "Left", .Right = "Right", .A = "A", .B = "B", .X = "X", .Y = "Y"}
BANK_KEY    := [BANKS]string{"lt", "plain", "rt"}
BANK_PREFIX := [BANKS]string{"LT+", "", "RT+"} // "LT+B" matches the hint text the model writes

// The layout Doodle ships with (and what tests get: App.keymap == nil).
KEYMAP_DEFAULT :: Keymap{slots = {
	BANK_LT   = {.Up = .None, .Down = .None, .Left = .IDE_Menu, .Right = .None, .A = .Edit, .B = .Delete, .X = .Talk, .Y = .Docs},
	BANK_NONE = {.Up = .Move_Up, .Down = .Move_Down, .Left = .Move_Left, .Right = .Move_Right, .A = .Select, .B = .Back, .X = .None, .Y = .Change},
	BANK_RT   = {.Up = .Walk_Prev, .Down = .Walk_Next, .Left = .Walk_Out, .Right = .Walk_In, .A = .Copy, .B = .Files, .X = .Run_List, .Y = .Save_As},
}}

// One shared default for nil lookups (not rebuilt on every call).
@(private = "file")
g_keymap_default := KEYMAP_DEFAULT

@(private = "file")
km_or_default :: proc(km: ^Keymap) -> ^Keymap { return km if km != nil else &g_keymap_default }

is_dpad :: proc(b: Pad_Button) -> bool { return b <= .Right }

// Plain d-pad / A / B: navigation everywhere, never rebindable.
slot_locked :: proc(bank: int, b: Pad_Button) -> bool { return bank == BANK_NONE && b <= .B }

keymap_get :: proc(km: ^Keymap, bank: int, b: Pad_Button) -> Action {
	return km_or_default(km).slots[bank][b]
}

// keymap_find: the slot holding `a` (first match: banks 0..2, buttons in enum order).
keymap_find :: proc(km: ^Keymap, a: Action) -> (bank: int, b: Pad_Button, ok: bool) {
	k := km_or_default(km)
	for bk in 0 ..< BANKS {
		for btn in Pad_Button {
			if k.slots[bk][btn] == a do return bk, btn, true
		}
	}
	return 0, .Up, false
}

// keymap_allows: may `a` sit in this slot? (None is always allowed except on locked slots.)
keymap_allows :: proc(bank: int, b: Pad_Button, a: Action) -> bool {
	if slot_locked(bank, b) do return false
	info := ACTION_INFO[a]
	if info.fixed do return false
	if info.face_only && is_dpad(b) do return false
	if info.trigger_only && bank == BANK_NONE do return false
	return true
}

// A walk on its own RT arrow draws no glyph (the default HUD's RT d-pad stays
// clean). Only RT: in the LT bank a blank arm means "unbound, moves the cursor",
// so a walk there must show.
walk_natural :: proc(bank: int, b: Pad_Button, a: Action) -> bool {
	if bank != BANK_RT do return false
	return (b == .Up && a == .Walk_Prev) || (b == .Down && a == .Walk_Next) ||
		(b == .Left && a == .Walk_Out) || (b == .Right && a == .Walk_In)
}

// slot_name: "LT+A", "Y", "RT+Up". Temp-allocated.
slot_name :: proc(bank: int, b: Pad_Button) -> string {
	return fmt.tprintf("%s%s", BANK_PREFIX[bank], BUTTON_NAME[b])
}

// action_slot_name: where `a` is ("RT+Y"), "" if it has no button. Temp-allocated.
action_slot_name :: proc(km: ^Keymap, a: Action) -> string {
	bank, b, ok := keymap_find(km, a)
	return slot_name(bank, b) if ok else ""
}

// ---- Assigning (conflict rules) ----
// A slot holds one action and each action is in at most one slot. Assigning an
// action that already has a button swaps the two slots, so the set of bound
// actions never shrinks; a required action can't be cleared or overwritten away.

Assign_Result :: enum { Ok, Swapped, Same, Locked, Not_Here, Needs_Home }

// keymap_assign puts `a` in (bank, b). Swapped: the slot's old action `moved`
// went to (ob, obtn). Not_Here: `moved` can't go in (ob, obtn). Needs_Home: the
// slot's required action `moved` would lose its only button.
keymap_assign :: proc(km: ^Keymap, bank: int, b: Pad_Button, a: Action) -> (res: Assign_Result, ob: int, obtn: Pad_Button, moved: Action) {
	if slot_locked(bank, b) do return .Locked, bank, b, .None
	if a != .None && !keymap_allows(bank, b, a) do return .Not_Here, bank, b, a
	old := km.slots[bank][b]
	if old == a do return .Same, bank, b, .None
	if a != .None {
		if fb, fbtn, ok := keymap_find(km, a); ok {
			if old != .None && !keymap_allows(fb, fbtn, old) do return .Not_Here, fb, fbtn, old
			km.slots[fb][fbtn] = old
			km.slots[bank][b] = a
			return .Swapped, fb, fbtn, old
		}
	}
	if ACTION_INFO[old].required do return .Needs_Home, bank, b, old
	km.slots[bank][b] = a
	return .Ok, bank, b, .None
}

// keymap_try: what keymap_assign would do, without changing km (the picker
// greys out choices that would be refused, and says why).
keymap_try :: proc(km: ^Keymap, bank: int, b: Pad_Button, a: Action) -> (res: Assign_Result, ob: int, obtn: Pad_Button, moved: Action) {
	scratch := km^
	return keymap_assign(&scratch, bank, b, a)
}

// keymap_valid: locked slots as shipped, no action twice, every slot allows its
// action, every required action has a button.
keymap_valid :: proc(km: ^Keymap) -> bool {
	seen: Actions
	for bank in 0 ..< BANKS {
		for b in Pad_Button {
			a := km.slots[bank][b]
			if slot_locked(bank, b) {
				if a != g_keymap_default.slots[bank][b] do return false
				continue
			}
			if a == .None do continue
			if a in seen || !keymap_allows(bank, b, a) do return false
			seen += {a}
		}
	}
	for a in Action do if ACTION_INFO[a].required && a not_in seen do return false
	return true
}

// keymap_repair makes any keymap valid (a hand-edited file): locked slots back
// to the defaults, actions a slot can't take and duplicates dropped (the first
// in slot order stays), then each missing required action gets a home.
keymap_repair :: proc(km: ^Keymap) {
	seen: Actions
	for bank in 0 ..< BANKS {
		for b in Pad_Button {
			if slot_locked(bank, b) {
				km.slots[bank][b] = g_keymap_default.slots[bank][b]
				continue
			}
			a := km.slots[bank][b]
			if a == .None do continue
			if a in seen || !keymap_allows(bank, b, a) {
				km.slots[bank][b] = .None
				continue
			}
			seen += {a}
		}
	}
	for a in Action {
		if !ACTION_INFO[a].required || a in seen do continue
		keymap_rehome(km, a)
	}
}

// keymap_rehome gives a missing required action a button: its default slot if
// empty, else the first empty slot that takes it, else its default slot anyway
// (the required defaults LT+B, RT+Y and RT+B are all different, so only a
// non-required action is pushed out).
@(private = "file")
keymap_rehome :: proc(km: ^Keymap, a: Action) {
	db, dbtn, _ := keymap_find(&g_keymap_default, a)
	if km.slots[db][dbtn] == .None {
		km.slots[db][dbtn] = a
		return
	}
	for bank in 0 ..< BANKS {
		for b in Pad_Button {
			if km.slots[bank][b] == .None && keymap_allows(bank, b, a) {
				km.slots[bank][b] = a
				return
			}
		}
	}
	km.slots[db][dbtn] = a
}

// ---- Resolving presses ----

// pad_edges: the pad buttons pressed this frame (A = confirm, B = cancel).
pad_edges :: proc(inp: Input) -> Pad_Held {
	e: Pad_Held
	if inp.up      do e += {.Up}
	if inp.down    do e += {.Down}
	if inp.left    do e += {.Left}
	if inp.right   do e += {.Right}
	if inp.confirm do e += {.A}
	if inp.cancel  do e += {.B}
	if inp.x       do e += {.X}
	if inp.y       do e += {.Y}
	return e
}

// input_clear removes one button's edge from an Input.
input_clear :: proc(inp: ^Input, b: Pad_Button) {
	switch b {
	case .Up:    inp.up = false
	case .Down:  inp.down = false
	case .Left:  inp.left = false
	case .Right: inp.right = false
	case .A:     inp.confirm = false
	case .B:     inp.cancel = false
	case .X:     inp.x = false
	case .Y:     inp.y = false
	}
}

Resolved :: struct {
	fired: Actions, // actions pressed this frame (holds excluded: keymap_holding)
	rest:  Input,   // what's left for navigation (plain d-pad / A / B, unbound trigger + d-pad)
}

// keymap_resolve turns this frame's presses into actions in the held trigger's
// bank (both triggers: LT wins, as active_bank). An unbound trigger + face
// button is swallowed: falling through, a cleared LT+B would act as plain B and
// drop you to the main menu. An unbound trigger + d-pad still moves the cursor.
keymap_resolve :: proc(km: ^Keymap, inp: Input) -> Resolved {
	res := Resolved{rest = inp}
	bank := active_bank(inp)
	edges := pad_edges(inp)
	for b in Pad_Button {
		if b not_in edges do continue
		a := keymap_get(km, bank, b)
		if ACTION_INFO[a].fixed do continue
		if a == .None && is_dpad(b) do continue
		input_clear(&res.rest, b)
		if a != .None && !ACTION_INFO[a].hold do res.fired += {a}
	}
	return res
}

// keymap_holding: is a hold action (Talk) held? Its button is down and its
// bank's trigger is held (plain bank: neither trigger). The other trigger is
// ignored, as the old `lt_held && x_held` rule did.
keymap_holding :: proc(km: ^Keymap, held: Pad_Held, lt, rt: bool, a: Action) -> bool {
	bank, b, ok := keymap_find(km, a)
	if !ok || b not_in held do return false
	switch bank {
	case BANK_LT: return lt
	case BANK_RT: return rt
	}
	return !lt && !rt
}

// keymap_bank_walks: while this bank's trigger is held the editor shows the
// tree-walk highlight (a bank with a walk in it).
keymap_bank_walks :: proc(km: ^Keymap, bank: int) -> bool {
	if bank == BANK_NONE do return false
	k := km_or_default(km)
	for a in k.slots[bank] {
		if a >= .Walk_Prev && a <= .Walk_Out do return true
	}
	return false
}

// ---- Hints ----

// rebind_hint: model hints name the default buttons ("Y: options    LT+B:
// delete"; ctrl.odin, branch.odin, loops.odin). Each 4-space segment starting
// with the default button of Change / Delete / Edit gets that action's current
// button, or is dropped when it has none. Default keymap: s unchanged.
// Temp-allocated (or s itself).
rebind_hint :: proc(km: ^Keymap, s: string) -> string {
	SEP :: "    "
	if s == "" do return s
	REBIND := [?]struct{ prefix: string, a: Action }{{"Y: ", .Change}, {"LT+B: ", .Delete}, {"LT+A: ", .Edit}}
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	rest := s
	for seg in strings.split_iterator(&rest, SEP) {
		kept := seg
		for r in REBIND {
			if !strings.has_prefix(seg, r.prefix) do continue
			name := action_slot_name(km, r.a)
			kept = fmt.tprintf("%s: %s", name, seg[len(r.prefix):]) if name != "" else ""
			break
		}
		if kept != "" do append(&out, kept)
	}
	return strings.join(out[:], SEP, context.temp_allocator)
}

// ---- doodle_keys.tsv ----
//   doodle-keys 1
//   # bank	button	action ...
//   lt	up	none
//   ...
// The 18 editable slots, written by ACTION_INFO.key (reordering the enum never
// breaks a file). Locked slots aren't listed.

KEYS_HEADER :: "doodle-keys 1"

// keys_text_ok: can the app save over a keys file with this text? Not when it
// is another (newer) version of the format.
keys_text_ok :: proc(text: string) -> bool {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" do continue
		return !strings.has_prefix(l, "doodle-keys") || l == KEYS_HEADER
	}
	return true
}

keymap_serialize :: proc(km: ^Keymap, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, KEYS_HEADER)
	strings.write_string(&b, "\n# bank\tbutton\taction   (banks: lt plain rt; plain d-pad / A / B are fixed and not listed)\n")
	for bank in 0 ..< BANKS {
		for btn in Pad_Button {
			if slot_locked(bank, btn) do continue
			fmt.sbprintf(&b, "%s\t%s\t%s\n", BANK_KEY[bank], BUTTON_KEY[btn], ACTION_INFO[km.slots[bank][btn]].key)
		}
	}
	return strings.to_string(b)
}

// keymap_parse reads a keys file (any garbage in it is skipped or repaired).
// `used` = lines applied. A slot the file doesn't mention keeps its default
// action unless the file put that action elsewhere, so old files pick up new
// actions.
keymap_parse :: proc(text: string) -> (km: Keymap, used: int) {
	for bank in 0 ..< BANKS {
		for btn in Pad_Button {
			if slot_locked(bank, btn) do km.slots[bank][btn] = g_keymap_default.slots[bank][btn]
		}
	}
	mentioned: [BANKS]Pad_Held
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' || strings.has_prefix(l, "doodle-keys") do continue
		bank, btn, a, ok := keys_line(l)
		if !ok || slot_locked(bank, btn) do continue
		if a != .None && !keymap_allows(bank, btn, a) do continue // the slot's default stays
		if a != .None {
			if _, _, dup := keymap_find(&km, a); dup do continue // first in file order wins
		}
		km.slots[bank][btn] = a
		mentioned[bank] += {btn}
		used += 1
	}
	for bank in 0 ..< BANKS {
		for btn in Pad_Button {
			if slot_locked(bank, btn) || btn in mentioned[bank] do continue
			def := g_keymap_default.slots[bank][btn]
			if def == .None do continue
			if _, _, placed := keymap_find(&km, def); !placed do km.slots[bank][btn] = def
		}
	}
	keymap_repair(&km)
	return
}

// keys_line parses "bank<TAB>button<TAB>action" (any whitespace between).
@(private = "file")
keys_line :: proc(l: string) -> (bank: int, btn: Pad_Button, a: Action, ok: bool) {
	parts: [3]string
	n := 0
	rest := l
	for f in strings.fields_iterator(&rest) {
		if n == 3 do return
		parts[n] = f
		n += 1
	}
	if n != 3 do return
	bank = -1
	for k, i in BANK_KEY do if k == parts[0] do bank = i
	if bank < 0 do return
	found_b, found_a := false, false
	for k, b in BUTTON_KEY do if k == parts[1] { btn = b; found_b = true }
	for info, act in ACTION_INFO do if info.key == parts[2] { a = act; found_a = true }
	ok = found_b && found_a
	return
}

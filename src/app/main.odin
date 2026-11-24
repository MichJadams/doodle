package main

// Integration layer: SDL/GL rendering + input, driving the pure `model` package.
// Logic lives in ../model (unit-tested). This file is presentation + I/O only.
// Contract: ARCHITECTURE.md §6 / docs/EDITOR_MODEL.md

import "../platform"
import "../gpu"
import "../text"
import "../model"
import "../stt"
import "core:math"
import "core:fmt"
import "core:strings"
import "core:os"
import "core:path/filepath"

WINDOW_W :: 1280
WINDOW_H :: 800 // Steam Deck native resolution

// --- SDL keycodes we care about ---
KEY_ESCAPE    :: 27
KEY_RETURN    :: 13
KEY_SPACE     :: 32
KEY_BACKSPACE :: 8
KEY_UP        :: 0x40000052
KEY_DOWN      :: 0x40000051
KEY_LEFT      :: 0x40000050
KEY_RIGHT     :: 0x4000004F
KEY_LCTRL     :: 0x400000E0
KEY_RCTRL     :: 0x400000E4

// --- Colors ---
// --- Colors: a "paper" theme (warm off-white paper, dark ink) ---
COL_BG     :: gpu.Color{0.965, 0.945, 0.890, 1} // paper
COL_PANEL  :: gpu.Color{0.915, 0.885, 0.815, 1} // a slightly darker sheet (menus, panels)
COL_TEXT   :: gpu.Color{0.17, 0.15, 0.13, 1}    // ink
COL_DIM    :: gpu.Color{0.53, 0.49, 0.43, 1}    // faded ink
COL_ACCENT :: gpu.Color{0.10, 0.52, 0.28, 1}    // green ink (names you can edit, selection outline)
COL_HILITE :: gpu.Color{0.74, 0.83, 0.94, 1}    // selected menu item (dark text on it)
COL_SEL_BG :: gpu.Color{0.62, 0.76, 0.94, 0.55} // highlighted part of the code
COL_RULE   :: gpu.Color{0.80, 0.76, 0.68, 1}    // separator lines
COL_VEIL   :: gpu.Color{0.84, 0.80, 0.72, 0.95} // behind menus / dialogs: a darker sheet that hides the code
COL_ERR    :: gpu.Color{0.78, 0.18, 0.18, 1}    // problems
COL_WARN   :: gpu.Color{0.70, 0.42, 0.00, 1}
COL_DOT    :: gpu.Color{0.15, 0.60, 0.32, 1}    // green insertion dots

HUD_LABELS := [?]string{"L-TRIGGER", "DEFAULT", "R-TRIGGER"}

// UI/chrome font (smaller than the code font) and frame time, set in main().
g_ui:   ^text.Font
g_time: f64

// STT push-to-talk state (for the HUD/editor overlay).
g_recording: bool
g_heard:     string
g_mic_ready: bool            // a field is highlighted + whisper available
g_walk_held: bool            // a trigger whose bank walks the code tree is held (statement-selection highlight)
g_talk_stale: bool           // Talk's button has been down since an overlay was open: it can't start dictation
g_stt_free:  bool            // dictating into a string literal (preserve spaces)
g_stt_parts: [dynamic]string // dictated fragments
g_stt_mode:  model.Dictation_Mode // name / free text / number (model/dictation.odin)
g_stt_ni:    int             // target node/field captured at record start
g_stt_fi:    int
g_vocab:     []string        // per-utterance STT bias vocabulary (freed after)
g_prompt:    string

// Raw per-frame input accumulated from SDL events, converted to model.Input.
Raw :: struct {
	lt, rt:         f32,
	key_lt, key_rt: bool,
	x_held:         bool,
	held:           model.Pad_Held, // pad buttons (or their keyboard stand-ins) down now: holds like Talk

	e_confirm, e_cancel:           bool,
	e_up, e_down, e_left, e_right: bool,
	e_a, e_b:                      bool,  // A and B edges (for LT+A, LT+B)
	e_y:                           bool,
	e_x:                           bool,  // X button edge
	e_rb:                          bool,  // Right bumper edge
	e_lb:                          bool,  // Left bumper edge

	// Text entry (used by the Save-as name box).
	pad_x_held:  bool,      // gamepad X held (dictation), as opposed to the keyboard 'x' key
	typed:       [32]u8,    // filename-safe characters typed this frame (keyboard)
	n_typed:     int,
	e_backspace: bool,      // Backspace pressed (it also raises e_cancel/e_b)
	e_space:     bool,      // Space pressed (it also raises e_confirm/e_a)

	ctrl_held: bool,        // keyboard Ctrl
	e_copy:    bool,        // Ctrl+C
}

main :: proc() {
	win, ok := platform.init("Doodle IDE", WINDOW_W, WINDOW_H)
	if !ok {
		fmt.eprintln("platform.init failed")
		return
	}
	defer platform.shutdown(win)

	r, rok := gpu.init(win)
	if !rok {
		fmt.eprintln("gpu.init failed")
		return
	}
	defer gpu.shutdown(r)

	load_icons()
	defer unload_icons(r)

	sound_init()
	defer sound_shutdown()

	font := load_a_font(r, 28) // code font
	if font == nil {
		fmt.eprintln("could not load any font")
		return
	}
	defer text.shutdown(font)
	defer if g_code != nil do text.shutdown(g_code)
	defer check_shutdown()

	g_ui = load_a_font(r, 18) // UI/chrome font
	if g_ui == nil do g_ui = font
	defer if g_ui != font do text.shutdown(g_ui)

	m: model.App
	m.state = .Menu
	m.os_name = os_name()
	defer model.free_siblings(&m)

	// The global menu heatmap, next to doodle.exe (heat_store.odin).
	heat_store_init(&m)
	defer heat_store_shutdown(&m)

	// The button layout, next to doodle.exe too (keys_store.odin). Before
	// trace_start, so a replay can pin it.
	keys_store_init(&m)
	defer keys_store_shutdown(&m)

	// STT is optional: if whisper isn't built yet, stt_e is nil and PTT is disabled.
	stt_e, _ := stt.init(stt.default_config())
	defer stt.shutdown(stt_e)
	
	// Expose STT engine to file-nav for search speech input.
	g_stt_e = stt_e
	g_app = &m // for file-nav to load an opened file into the editor

	raw: Raw
	events: [dynamic]platform.Event
	defer delete(events)

	// Initialize project directories on startup, and the extra folders New
	// Project can use (roots_store.odin). Before trace_start, so a replay can pin them.
	ensure_projects_dir()
	roots_store_init()
	defer roots_store_shutdown()
	settings_store_init() // main menu -> Settings (settings.odin); also before trace_start
	defer settings_store_shutdown()

	// Record this run / set up a replay (trace.odin; debug builds only).
	trace_start(win, &m) // TRACE hook
	defer trace_stop()   // TRACE hook

	// `doodle.exe path\to\file.odin` (or "Open with" from Explorer) opens that file.
	if f := trace_startup_file(); f != "" { // TRACE hook (was: os.args[1] if it exists)
		filenav_load(f)
	}

	for !m.want_quit {
		g_time = platform.now_seconds()
		reset_edges(&raw)

		clear(&events)
		win.dpad_no_repeat = g_recording // a held d-pad repeats, except while dictating (Down ends a word)
		trace_poll(win, &events) // TRACE hook (was: platform.poll_events)
		for e in events {
			if _, is_quit := e.(platform.Quit_Event); is_quit {
				m.want_quit = true
			}
			handle_event(&raw, e)
		}
		trace_frame_begin(&m) // TRACE hook

		// For the pencil sound: how much code there is before this frame's input.
		code_before := code_size(&m)
		state_before := m.state
		loads_before := g_file_loads

		inp := build_input(&raw)
		down_edge := inp.down
		// Talk is a hold on whichever button the layout gives it (model/keymap.odin).
		talk_down := model.keymap_holding(m.keymap, raw.held, inp.lt_held, inp.rt_held, .Talk)
		mic_hold := !g_keys_open && !g_settings_open && !g_vp_open && talk_down
		// A Talk press made while an overlay is open belongs to the overlay (Talk on
		// plain Y, and Y closes the docs): it stays stale until released.
		if !talk_down do g_talk_stale = false
		else if overlay_open() do g_talk_stale = true
		g_walk_held = !g_recording && model.keymap_bank_walks(m.keymap, model.active_bank(inp))
		// While recording, the d-pad/buttons drive dictation, not navigation.
		if g_recording {
			inp.confirm = false; inp.cancel = false
			inp.up = false; inp.down = false; inp.left = false; inp.right = false
			inp.x = false; inp.y = false
		}

		// Main menu actions handled here (they need disk I/O): A on "Recent Projects"
		// opens the project picker; A on "New Project" asks which folder it goes in
		// (new_project.odin), which then sets up a fresh project folder there.
		new_project := false
		if m.state == .Menu && !g_proj_open && !g_np_open && !g_keys_open && !g_settings_open && raw.e_confirm {
			switch model.MENU_ITEMS[m.menu_index] {
			case "Recent Projects":
				projects_open()
				raw.e_confirm = false; raw.e_a = false
			case "New Project":
				if g_roots_legacy {
					new_project = true // replaying an old recording: model.update resets the doc + enters the editor
				} else {
					new_project_open()
					raw.e_confirm = false; raw.e_a = false
				}
			case "Key Layout":
				keys_page_open(inp)
				raw.e_confirm = false; raw.e_a = false
			case "Settings":
				settings_page_open() // settings.odin
				raw.e_confirm = false; raw.e_a = false
			}
		}

		// Route input to file-nav handler when active (suppresses normal editor input).
		if g_vp_open {
			// "Library not on your PATH" before a run (vendor_path.odin) owns all input.
			handle_vendor_prompt_input(&raw)
		} else if g_save_open {
			// The Save-as / Rename dialog owns all input while it's open (rename is
			// opened from file navigation, so it comes first).
			handle_save_input(&m, &raw)
		} else if g_filenav {
			handle_filenav(&m, &raw, inp)
			// Suppress model.update for editor navigation while in file-nav mode.
		} else if g_keys_open {
			// The Key Layout page owns all input while it's open (its controls are fixed).
			handle_keys_input(&raw, inp)
		} else if g_settings_open {
			// The Settings page owns all input while it's open.
			handle_settings_input(&raw)
		} else if g_proj_open {
			// The project picker owns all input while it's open.
			handle_projects_input(&raw)
		} else if g_np_open {
			// New Project's "where?" list (and its folder browser) owns all input while it's open.
			handle_new_project_input(&m, &raw)
		} else if g_doc_open {
			// The documentation panel (LT+Y) owns all input while it's open.
			handle_doc_input(&raw)
		} else {
			// Every editor action comes from the button layout through model.update
			// (m.requests, then app_requests), so none can fire with an overlay open.
			if m.state == .Editor && !g_run_open && !g_recording && !m.ref_pick_active && !m.mod_pick_active {
				// Fixed, outside the layout: Ctrl+C copies, RB runs the favorite, LB the tests.
				if raw.e_copy { copy_selection(&m); raw.e_copy = false }
				if raw.e_rb   { run_favorite(); raw.e_rb = false }
				if raw.e_lb   { run_tests(); raw.e_lb = false }
			}
			if g_run_open {
				// The run overlay owns all input while it's open.
				handle_run_input(&raw)
			} else {
				// Rebuild from raw so edges consumed above don't leak into the editor.
				model.update(&m, editor_input(&raw))
				app_requests(&m, inp)
			}
		}

		// A message from the editor model (e.g. "nothing declared to assign to").
		if m.notice != "" {
			set_status(m.notice)
			m.notice = ""
		}

		// Menus used this frame: save the heatmap (throttled; heat_store.odin).
		heat_store_tick()

		// New Project: set up a random project name and folder.
		if new_project && m.state == .Editor {
			new_project_setup()
		}

		// Mic is available only when an editable field is highlighted.
		// Names, strings, comments and numbers (any number literal, or a value dot
		// that takes one) - model.dictation_target.
		tni, tfi, dmode := model.dictation_target(&m)
		g_mic_ready = dmode != .None && stt_e != nil && m.state == .Editor

		// Push-to-talk dictation into the highlighted field (not in file-nav mode).
		if mic_hold && !g_talk_stale && g_mic_ready && !g_recording && !overlay_open() {
			// Free-text for string literals (preserve spaces); snake_case for identifiers.
			g_stt_mode = dmode
			// Free text keeps "3.5" / "-2" whole (an identifier would make them 3_5 / 2).
			g_stt_free = dmode == .Free_Text || dmode == .Number
			stt.set_free_text(stt_e, g_stt_free)
			if dmode == .Number {
				stt.set_context(stt_e, "Numbers: 0, 1, 2, 10, 25, 100, 3.5, -2.", nil) // nudge Whisper to write digits
			} else if g_stt_free {
				stt.set_context(stt_e, "", nil)
			} else {
				// Bias dictation toward known identifiers/keywords (fixes "maine"->"main").
				g_vocab = model.collect_vocab(&m)
				g_prompt = build_prompt(g_vocab)
				stt.set_context(stt_e, g_prompt, g_vocab)
			}
			trace_stt_begin(stt_e) // TRACE hook (was: stt.begin)
			g_recording = true
			g_stt_ni = tni
			g_stt_fi = tfi
			clear(&g_stt_parts)
		}
		if g_recording && down_edge {
			append(&g_stt_parts, trace_stt_segment(stt_e)) // TRACE hook (was: stt.segment); d-pad Down = underscore boundary
		}
		if g_recording && !mic_hold {
			append(&g_stt_parts, trace_stt_end(stt_e)) // TRACE hook (was: stt.end)
			final := g_stt_free ? join_spaces(g_stt_parts[:]) : join_identifier(g_stt_parts[:])
			if final != "" && g_stt_mode == .Number {
				// "ten" / "10." / "three point five" -> 10 / 3.5 (model/dictation.odin).
				if num, ok := model.spoken_number(final); ok {
					model.dictate_number(&m, g_stt_ni, g_stt_fi, num)
					if g_heard != "" do delete(g_heard)
					g_heard = num
				} else {
					set_status(fmt.tprintf("Heard \"%s\" - not a number", final))
				}
			} else if final != "" {
				if m.word_edit_active && m.word_ni == g_stt_ni && m.word_fi == g_stt_fi {
					model.word_dictated(&m, final) // word by word: the word / the yellow dot (model/word_edit.odin)
				} else {
					model.rename_field(&m, g_stt_ni, g_stt_fi, final) // a declaration's name: asks whether its uses follow
				}
				if g_heard != "" do delete(g_heard)
				g_heard = strings.clone(final)
			}
			for p in g_stt_parts do delete(p)
			clear(&g_stt_parts)
			delete(final)
			g_recording = false
			if g_vocab != nil { delete(g_vocab); g_vocab = nil }
			if g_prompt != "" { delete(g_prompt); g_prompt = "" }
		}

		// Code was added to the open document (not a file load / new project): pencil.
		in_editor :: proc(s: model.State) -> bool { return s == .Editor || s == .Radial }
		if in_editor(state_before) && in_editor(m.state) && g_file_loads == loads_before && code_size(&m) > code_before {
			sfx_pencil()
		}

		trace_frame_end(&m) // TRACE hook

		w, h := platform.get_size(win)
		ensure_code_font(r, w) // 80 columns fit across; re-baked when the window resizes
		if m.state == .Editor || m.state == .Radial do check_tick(&m) // background `odin check` (checker.odin)
		gpu.begin_frame(r, w, h, COL_BG)
		switch m.state {
		case .Menu:
			draw_menu(r, font, &m, w, h)
			if g_proj_open do draw_projects_overlay(r, w, h)
			if g_np_open do draw_new_project_overlay(r, w, h)
		case .Editor:
			draw_editor(r, font, &m, w, h)
			// FILE NAVIGATION MODE: draw overlay after editor.
			if g_filenav do draw_filenav(r, w, h)
		case .Radial:
			draw_editor(r, font, &m, w, h)
			draw_radial(r, &m, w, h)
		}
		// Draw run overlay if active.
		if g_run_open {
			draw_run_overlay(r, w, h)
		}
		if g_save_open do draw_save_dialog(r, w, h)
		if g_doc_open do draw_doc_panel(r, w, h)
		if g_keys_open do draw_keys_page(r, w, h)
		if g_settings_open do draw_settings_page(r, w, h)
		if g_vp_open do draw_vendor_prompt(r, w, h) // on top: it can come up over the Run list
		// On the Key Layout page the HUD previews the cursor's bank.
		hud_inp := inp
		if g_keys_open {
			hud_inp.lt_held = g_keys.bank == model.BANK_LT
			hud_inp.rt_held = g_keys.bank == model.BANK_RT
		}
		draw_hud(r, &m, hud_inp, w, h)
		// Show run message if recent.
		// Status messages ("copied 6 lines", "ran: odin run .") at the top right.
		if g_run_msg != "" && (g_time - g_run_msg_time) < RUN_MSG_DURATION {
			mw := text.measure(g_ui, g_run_msg).x
			text.draw_line(r, g_ui, {f32(w) - mw - 28, 14}, g_run_msg, COL_ACCENT)
		}
		trace_draw(r, w, h) // TRACE hook
		gpu.end_frame(r)
		trace_after_draw(w, h) // TRACE hook
		platform.present(win)

		free_all(context.temp_allocator)
	}
}

// code_size: characters of real code in the document (placeholder dots excluded).
code_size :: proc(m: ^model.App) -> int {
	n := 0
	for node in m.doc.nodes {
		for f in node.fields do if !f.slot do n += len(f.text)
	}
	return n
}

os_name :: proc() -> string {
	#partial switch ODIN_OS {
	case .Windows: return "windows"
	case .Linux:   return "linux"
	case .Darwin:  return "darwin"
	}
	return ""
}

// load_a_font: the interface font (menus, HUD, labels).
load_a_font :: proc(r: ^gpu.Renderer, px: f32) -> ^text.Font {
	paths := [?]string{
		"assets/fonts/mono.ttf",
		"C:\\Windows\\Fonts\\consola.ttf",
		"C:\\Windows\\Fonts\\segoeui.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	}
	for p in paths {
		if f, fok := text.load_font(r, asset_path(p), px); fok do return f
	}
	return nil
}

// asset_path finds a relative asset path from the working folder, or next to /
// above doodle.exe (bin\doodle.exe -> assets\...), so it works however Doodle is
// started. Absolute paths are returned as they are. Temp-allocated.
asset_path :: proc(rel: string) -> string {
	if filepath.is_abs(rel) || os.exists(rel) do return rel
	exe_dir := filepath.dir(os.args[0])
	for cand in ([]string{fmt.tprintf("%s/%s", exe_dir, rel), fmt.tprintf("%s/../%s", exe_dir, rel)}) {
		if os.exists(cand) do return cand
	}
	return rel
}

// ---------------- Input ----------------

reset_edges :: proc(raw: ^Raw) {
	raw.e_confirm = false
	raw.e_cancel = false
	raw.e_up = false
	raw.e_down = false
	raw.e_left = false
	raw.e_right = false
	raw.e_a = false
	raw.e_b = false
	raw.e_y = false
	raw.e_x = false
	raw.e_rb = false
	raw.e_lb = false
	raw.n_typed = 0
	raw.e_backspace = false
	raw.e_space = false
	raw.e_copy = false
}

// Input for model.update: same as build_input, but navigation is masked while
// dictating (the d-pad/buttons drive dictation then, not navigation).
editor_input :: proc(raw: ^Raw) -> model.Input {
	inp := build_input(raw)
	if g_recording {
		inp.confirm = false; inp.cancel = false
		inp.up = false; inp.down = false; inp.left = false; inp.right = false
		inp.x = false; inp.y = false
	}
	return inp
}

build_input :: proc(raw: ^Raw) -> model.Input {
	return model.Input {
		confirm = raw.e_confirm,
		cancel  = raw.e_cancel,
		up      = raw.e_up,
		down    = raw.e_down,
		left    = raw.e_left,
		right   = raw.e_right,
		lt_held = raw.lt > 0.5 || raw.key_lt,
		rt_held = raw.rt > 0.5 || raw.key_rt,
		x       = raw.e_x,
		y       = raw.e_y,
	}
}

// app_requests performs the layout actions model.update handed back (they need
// disk, the clipboard or an overlay). It only runs right after model.update in
// the editor with no overlay open, so nothing here can open over another overlay.
// At most one overlay opens per frame (the first in enum order).
app_requests :: proc(m: ^model.App, inp: model.Input) {
	req := m.requests
	m.requests = {}
	if .Copy in req         do copy_selection(m)
	if .Save in req         do save_now(m)
	if .Run_Favorite in req do run_favorite()
	if .Run_Tests in req    do run_tests()
	if .Prev_File in req {
		if g_prev_file == "" do set_status("no previous file yet")
		else do filenav_alt_tab() // also works outside file nav
	}
	switch {
	case .Docs in req:       doc_panel_open(m)
	case .Save_As in req:    save_dialog_open()
	case .Run_List in req:   g_run_open = true; g_run_index = 0
	case .Files in req:      filenav_enter()
	case .Key_Layout in req: keys_page_open(inp)
	}
}

// pad_button: the layout button for a gamepad button (false: a shoulder, Start, ...).
pad_button :: proc(b: platform.Button) -> (model.Pad_Button, bool) {
	#partial switch b {
	case .A:     return .A, true
	case .B:     return .B, true
	case .X:     return .X, true
	case .Y:     return .Y, true
	case .Up:    return .Up, true
	case .Down:  return .Down, true
	case .Left:  return .Left, true
	case .Right: return .Right, true
	}
	return .A, false
}

// key_pad_button: the layout button a keyboard key stands in for.
key_pad_button :: proc(sym: i32) -> (model.Pad_Button, bool) {
	switch sym {
	case 'x':                       return .X, true
	case 'y':                       return .Y, true
	case KEY_RETURN, KEY_SPACE:     return .A, true
	case KEY_BACKSPACE, KEY_ESCAPE: return .B, true
	case KEY_UP, 'w':               return .Up, true
	case KEY_DOWN, 's':             return .Down, true
	case KEY_LEFT, 'a':             return .Left, true
	case KEY_RIGHT, 'd':            return .Right, true
	}
	return .A, false
}

handle_event :: proc(raw: ^Raw, e: platform.Event) {
	#partial switch ev in e {
	case platform.Button_Event:
		if pb, ok := pad_button(ev.button); ok {
			if ev.pressed do raw.held += {pb}
			else do raw.held -= {pb}
		}
		if ev.button == .X {
			raw.x_held = ev.pressed
			raw.pad_x_held = ev.pressed
			if ev.pressed do raw.e_x = true
		}
		if ev.pressed {
			#partial switch ev.button {
			case .A:     raw.e_confirm = true; raw.e_a = true
			case .B:     raw.e_cancel = true; raw.e_b = true
			case .Up:    raw.e_up = true
			case .Down:  raw.e_down = true
			case .Left:  raw.e_left = true
			case .Right: raw.e_right = true
			case .Y:     raw.e_y = true
			case .RB:    raw.e_rb = true
			case .LB:    raw.e_lb = true
			}
		}
	case platform.Axis_Event:
		if ev.axis == .LTrigger do raw.lt = ev.value
		if ev.axis == .RTrigger do raw.rt = ev.value
	case platform.Key_Event:
		handle_key(raw, ev.sym, ev.pressed)
	}
}

handle_key :: proc(raw: ^Raw, sym: i32, pressed: bool) {
	if pb, ok := key_pad_button(sym); ok {
		if pressed do raw.held += {pb}
		else do raw.held -= {pb}
	}
	// Trigger emulation (held): q = left trigger, e = right trigger.
	switch sym {
	case 'q': raw.key_lt = pressed
	case 'e': raw.key_rt = pressed
	case 'x':
		raw.x_held = pressed
		if pressed do raw.e_x = true
	case 'y':
		if pressed do raw.e_y = true
	case 'r':
		if pressed do raw.e_rb = true
	case 't':
		if pressed do raw.e_lb = true // keyboard stand-in for LB (run tests)
	case KEY_LCTRL, KEY_RCTRL:
		raw.ctrl_held = pressed
	}
	if !pressed do return
	// Record filename-safe characters for text boxes (Save as). SDL keysyms for
	// letters/digits are their lowercase ASCII codes.
	if raw.ctrl_held && sym == 'c' {
		raw.e_copy = true // Ctrl+C: copy (not typed text)
		return
	}
	is_text := (sym >= 'a' && sym <= 'z') || (sym >= '0' && sym <= '9') || sym == '-' || sym == '.'
	if is_text && !raw.ctrl_held && raw.n_typed < len(raw.typed) {
		raw.typed[raw.n_typed] = u8(sym)
		raw.n_typed += 1
	}
	if sym == KEY_BACKSPACE do raw.e_backspace = true
	if sym == KEY_SPACE do raw.e_space = true
	switch sym {
	case KEY_RETURN, KEY_SPACE: raw.e_confirm = true; raw.e_a = true
	case KEY_BACKSPACE, KEY_ESCAPE: raw.e_cancel = true; raw.e_b = true
	case KEY_UP, 'w':    raw.e_up = true
	case KEY_DOWN, 's':  raw.e_down = true
	case KEY_LEFT, 'a':  raw.e_left = true
	case KEY_RIGHT, 'd': raw.e_right = true
	}
}

// ---------------- Button glyph bindings ----------------
// The HUD draws itself from the button layout (model/keymap.odin), so it always
// shows what each button does now.

// slot_glyph: the text on a slot ("" = nothing drawn). An unbound face button
// shows its letter; a walk on its own RT arrow and the plain d-pad show nothing.
// ASCII only (atlas 32..127).
slot_glyph :: proc(km: ^model.Keymap, bank: int, b: model.Pad_Button) -> string {
	a := model.keymap_get(km, bank, b)
	if a == .None do return model.is_dpad(b) ? "" : model.BUTTON_NAME[b]
	if model.ACTION_INFO[a].fixed && model.is_dpad(b) do return ""
	if model.walk_natural(bank, b, a) do return ""
	return model.ACTION_INFO[a].glyph
}

// action_icon: the icon drawn instead of an action's glyph (when it's loaded).
action_icon :: proc(a: model.Action) -> (Icon, bool) {
	#partial switch a {
	case .Talk:    return .Speech, true
	case .Delete:  return .Delete, true
	case .Save, .Save_As: return .Save, true
	case .Files:   return .Files, true
	case .Copy:    return .Copy, true
	case .Select:  return .Add, true
	case .Back:    return .Back, true
	}
	return {}, false
}

// bank_slot_pos: the center of a button in a bank diagram drawn at (cx, cy).
bank_slot_pos :: proc(cx, cy, scale: f32, b: model.Pad_Button) -> (x, y: f32) {
	dpad_cx, face_cx := cx - 82 * scale, cx + 82 * scale
	off := 46 * scale * 1.4 * 0.30 // the d-pad icon's notches (draw_bank: dsize * 0.30)
	d := 32 * scale
	switch b {
	case .Up:    return dpad_cx, cy - off
	case .Down:  return dpad_cx, cy + off
	case .Left:  return dpad_cx - off, cy
	case .Right: return dpad_cx + off, cy
	case .Y:     return face_cx, cy - d
	case .A:     return face_cx, cy + d
	case .X:     return face_cx - d, cy
	case .B:     return face_cx + d, cy
	}
	return cx, cy
}

// ---------------- Rendering ----------------

draw_menu :: proc(r: ^gpu.Renderer, font: ^text.Font, m: ^model.App, w, h: int) {
	fw, fh := f32(w), f32(h)
	text.draw_centered(r, font, {0, fh * 0.20, fw, 60}, "DOODLE", COL_ACCENT)
	text.draw_centered(r, g_ui, {0, fh * 0.20 + 56, fw, 30}, "Odin IDE  -  gamepad native", COL_DIM)

	// Square-ish, centered grid (same treatment as the radial menus).
	items := model.menu_items(m)
	n := len(items)
	cols := model.grid_cols(n)
	rows := (n + cols - 1) / cols
	gap, vgap := f32(14), f32(12)
	cellw, cellh := f32(240), f32(56)
	grid_w := f32(cols) * cellw + f32(cols - 1) * gap
	start_x := (fw - grid_w) * 0.5
	start_y := fh * 0.44
	for item, i in items {
		col := i % cols
		row := i / cols
		box := gpu.Rect{start_x + f32(col) * (cellw + gap), start_y + f32(row) * (cellh + vgap), cellw, cellh}
		active := i == m.menu_index
		enabled := item == "New Project" || item == "Recent Projects" || item == "Key Layout" || item == "Settings"
		gpu.draw_rect(r, box, active ? COL_HILITE : COL_PANEL)
		if active do gpu.draw_rect_outline(r, box, 2, COL_ACCENT)
		text.draw_centered(r, g_ui, box, item, enabled ? COL_TEXT : COL_DIM)
	}
	_ = rows

	text.draw_centered(r, g_ui, {0, fh * 0.84, fw, 30},
		"D-pad / Arrows to move    A / Enter to select    (Open Folder not wired yet)", COL_DIM)
}

// draw_editor: see editor_view.odin (layout, wrapping, highlighting, scrolling).

HINT_COL :: gpu.Color{0.48, 0.45, 0.40, 1} // expected-type labels next to dots

// The label shown next to a slot dot: its expected type ("LPCWSTR"), "..T" for a
// variadic dot, or "" when unknown. ("..any" is shown too: anything fits.)
slot_hint_label :: proc(f: model.Field) -> string {
	if f.hint == "" do return ""
	if f.kind == "args" do return fmt.tprintf("..%s", f.hint)
	return f.hint
}

// Return colors for a slot dot based on field kind.
slot_dot_color :: proc(kind: string) -> (outer_col, inner_col: gpu.Color) {
	switch kind {
	case "value", model.RET_MORE_KIND: // another return value: a value dot (result_list.odin)
		return {1.00, 0.60, 0.15, 1.0}, {1.00, 0.65, 0.20, 1.0}
	case "type", model.VARIANT_KIND, model.RES_MORE_KIND: // another result: a type dot
		return {0.35, 0.70, 1.00, 1.0}, {0.40, 0.75, 1.00, 1.0}
	case "body":
		return {0.35, 0.85, 0.45, 1.0}, {0.40, 0.90, 0.50, 1.0}
	case "args", model.FIELDS_KIND:
		// Optional extra call argument (variadic) / struct literal field: green = "add another", like insertion dots.
		return {0.20, 0.90, 0.45, 1.0}, {0.25, 0.95, 0.50, 1.0}
	case "params":
		return {0.80, 0.45, 0.95, 1.0}, {0.85, 0.50, 1.00, 1.0}
	case model.CAPTURE_KIND:
		// Capture the call's result in a variable: pink.
		return {0.93, 0.27, 0.60, 1.0}, {0.97, 0.36, 0.67, 1.0}
	case:
		// Generic/default: neutral orange
		return {0.95, 0.55, 0.20, 1.0}, {1.00, 0.60, 0.25, 1.0}
	}
}

// Insertion dots: small and quiet; the one under the cursor is a little bigger and pulses.
draw_green_dot :: proc(r: ^gpu.Renderer, cx, cy: f32) {
	gpu.draw_circle(r, cx, cy, 6, {COL_DOT.r, COL_DOT.g, COL_DOT.b, 0.14})
	gpu.draw_circle(r, cx, cy, 3.5, {COL_DOT.r, COL_DOT.g, COL_DOT.b, 0.80})
}

draw_green_dot_highlighted :: proc(r: ^gpu.Renderer, cx, cy: f32) {
	pulse := 0.5 + 0.5 * math.sin(f32(g_time) * 4.0)
	gpu.draw_circle(r, cx, cy, 7 + 1.5 * pulse, {COL_DOT.r, COL_DOT.g, COL_DOT.b, 0.18 + 0.18 * pulse})
	gpu.draw_circle(r, cx, cy, 4, COL_DOT)
}

draw_orange_dot :: proc(r: ^gpu.Renderer, cx, cy: f32) {
	draw_colored_dot(r, cx, cy, {1.0, 0.55, 0.12, 1.0}, {1.0, 0.65, 0.22, 1})
}

draw_colored_dot :: proc(r: ^gpu.Renderer, cx, cy: f32, outer_col, inner_col: gpu.Color) {
	pulse := 0.5 + 0.5 * math.sin(f32(g_time) * 3.0)
	radius := 5.0 + 1.5 * pulse
	outer := outer_col
	outer.a = 0.18 + 0.20 * pulse
	gpu.draw_circle(r, cx, cy, radius + 4, outer)
	gpu.draw_circle(r, cx, cy, radius, inner_col)
}

// Render the current menu view (top of the navigation stack) as a grid.
// Truncate a label (with a trailing "..") so it fits within maxw pixels.
fit_label :: proc(font: ^text.Font, s: string, maxw: f32) -> string {
	if text.measure(font, s).x <= maxw do return s
	for end := len(s) - 1; end > 1; end -= 1 {
		cand := strings.concatenate({s[:end], ".."}, context.temp_allocator)
		if text.measure(font, cand).x <= maxw do return cand
	}
	return s
}

// The "recently used" section of a menu (already imported / used in this file).
RECENT_BG  :: gpu.Color{0.80, 0.90, 0.87, 1}
RECENT_COL :: gpu.Color{0.08, 0.46, 0.44, 1}

// Menu heatmap (model/heat.odin): cells on the way to things you used before
// get a warm graphite "smudge" border, darker the more they were used.
SMUDGE_COL :: gpu.Color{0.29, 0.23, 0.17, 1}

// draw_smudge: the wear border of a cell (shade 0..1). Plain cells get it on
// their edge; recent / selected cells (which have their own outline) just outside.
draw_smudge :: proc(r: ^gpu.Renderer, box: gpu.Rect, shade: f32, outside: bool) {
	if shade <= 0 do return
	c := SMUDGE_COL
	c.a = 0.18 + (0.85 - 0.18) * clamp(shade, 0, 1)
	width := shade < 0.5 ? f32(1) : f32(2)
	b := box
	if outside do b = {box.x - 2 - width, box.y - 2 - width, box.w + 2 * (2 + width), box.h + 2 * (2 + width)}
	// Not draw_rect_outline: its sides overlap at the corners, which would show as
	// darker dots with a translucent color. Top / bottom full width, sides between.
	gpu.draw_rect(r, {b.x, b.y, b.w, width}, c)
	gpu.draw_rect(r, {b.x, b.y + b.h - width, b.w, width}, c)
	gpu.draw_rect(r, {b.x, b.y + width, width, b.h - 2 * width}, c)
	gpu.draw_rect(r, {b.x + b.w - width, b.y + width, width, b.h - 2 * width}, c)
	// Well-worn plain cells: the faintest darkening of the sheet (<= 4%).
	if !outside && shade > 0.5 {
		gpu.draw_rect(r, box, {c.r, c.g, c.b, 0.04 * (shade - 0.5) * 2})
	}
}

// A flat, alphabetical, 8-wide grid that scrolls vertically.
draw_radial :: proc(r: ^gpu.Renderer, m: ^model.App, w, h: int) {
	v := model.current_view(m)
	if v == nil do return
	fw, fh := f32(w), f32(h)
	gpu.draw_rect(r, {0, 0, fw, fh}, COL_VEIL)
	// Where you are: the menus you came through (Fill > Type > win32. > types > ...).
	if len(m.nav) > 1 {
		parts := make([dynamic]string, 0, len(m.nav), context.temp_allocator)
		for view in m.nav[:len(m.nav) - 1] do append(&parts, view.title)
		trail := strings.concatenate({strings.join(parts[:], "  >  ", context.temp_allocator), "  >"}, context.temp_allocator)
		trail_w := fw - 80
		if text.measure(g_ui, trail).x > trail_w {
			// Too long: keep the end (the nearest menus) and show ".." in front.
			for len(parts) > 1 && text.measure(g_ui, trail).x > trail_w {
				ordered_remove(&parts, 0)
				trail = strings.concatenate({"..  >  ", strings.join(parts[:], "  >  ", context.temp_allocator), "  >"}, context.temp_allocator)
			}
		}
		text.draw_centered(r, g_ui, {0, fh * 0.07 - 34, fw, 28}, trail, COL_DIM)
	}
	text.draw_centered(r, g_ui, {0, fh * 0.07, fw, 36}, v.title, COL_ACCENT)
	// Filling a typed dot: say what it expects (options that can't fit are grayed).
	if m.slot_menu != nil && m.slot_ni >= 0 && m.slot_ni < len(m.doc.nodes) {
		fs := m.doc.nodes[m.slot_ni].fields
		if m.slot_fi >= 0 && m.slot_fi < len(fs) && fs[m.slot_fi].slot {
			if label := slot_hint_label(fs[m.slot_fi]); label != "" {
				text.draw_centered(r, g_ui, {0, fh * 0.07 + 30, fw, 24},
					fmt.tprintf("expects %s  -  grayed options don't fit", label), HINT_COL)
			}
		}
	}

	n := len(v.entries)
	if n == 0 do return
	cols := model.grid_cols(n) // square-ish, capped at GRID_COLS
	// Rows: the "recently used" section (if any) gets its own rows, then the rest.
	rows, recent_rows := model.menu_rows(v)
	sectioned := recent_rows > 0

	margin := f32(40)
	gap := f32(12)
	// Cells are as wide as the longest label needs (220 at least, 480 at most),
	// shrinking only when needed to fit many columns; the grid is centered.
	fit_w := (fw - 2 * margin - f32(cols - 1) * gap) / f32(cols)
	longest := f32(0)
	for e in v.entries do longest = max(longest, text.measure(g_ui, e.label).x)
	cellw := min(clamp(longest + 24, f32(220), f32(480)), fit_w)
	// A label that still doesn't fit: the highlighted one is shown in full below
	// the grid (room kept for it all the while, so the grid doesn't jump).
	full_line := longest > cellw - 10
	cellh := f32(44)
	vgap := f32(8)
	caption_h := sectioned ? f32(24) : 0 // "RECENTLY USED" / "ALL" captions
	grid_w := f32(cols) * cellw + f32(cols - 1) * gap
	start_x := (fw - grid_w) * 0.5
	start_y := fh * 0.14
	bottom := f32(h) - (full_line ? 220 : 185) // leave room for the HUD + hint (+ the full label)

	visible_rows := int((bottom - start_y - 2 * caption_h) / (cellh + vgap))
	if visible_rows < 1 do visible_rows = 1

	sel_row, _ := model.menu_cell(v, v.index)
	// Scroll so the selected row stays visible (keep it roughly centered).
	first_row := sel_row - visible_rows / 2
	max_first := rows - visible_rows
	if max_first < 0 do max_first = 0
	if first_row > max_first do first_row = max_first
	if first_row < 0 do first_row = 0

	// Row positions: captions above the recent section and above the rest.
	row_y :: proc(row, first_row, recent_rows: int, start_y, caption_h, cellh, vgap: f32) -> f32 {
		y := start_y + f32(row - first_row) * (cellh + vgap)
		if recent_rows > 0 && first_row < recent_rows {
			y += caption_h                               // "RECENTLY USED"
			if row >= recent_rows do y += caption_h + 4  // gap + "ALL"
		}
		return y
	}
	if sectioned && first_row < recent_rows {
		text.draw_line(r, g_ui, {start_x, start_y}, "RECENTLY USED", RECENT_COL)
		ay := row_y(recent_rows, first_row, recent_rows, start_y, caption_h, cellh, vgap) - caption_h
		if recent_rows < first_row + visible_rows do text.draw_line(r, g_ui, {start_x, ay}, "ALL", COL_DIM)
	}

	for i in 0 ..< n {
		row, col := model.menu_cell(v, i)
		if row < first_row || row >= first_row + visible_rows do continue
		e := v.entries[i]
		x := start_x + f32(col) * (cellw + gap)
		y := row_y(row, first_row, recent_rows, start_y, caption_h, cellh, vgap)
		box := gpu.Rect{x, y, cellw, cellh}
		active := i == v.index
		recent := i < v.recent
		bg := COL_PANEL
		if recent do bg = RECENT_BG
		if active do bg = COL_HILITE
		gpu.draw_rect(r, box, bg)
		draw_smudge(r, box, model.view_shade(v, i), active || recent)
		if active do gpu.draw_rect_outline(r, box, 2, COL_ACCENT)
		else if recent do gpu.draw_rect_outline(r, box, 1, RECENT_COL)
		col_text := e.dim ? COL_DIM : COL_TEXT
		text.draw_centered(r, g_ui, box, fit_label(g_ui, e.label, cellw - 10), col_text)
	}

	// The highlighted label in full, when its cell cuts it short.
	if full_line && v.index >= 0 && v.index < n {
		if lbl := v.entries[v.index].label; text.measure(g_ui, lbl).x > cellw - 10 {
			text.draw_centered(r, g_ui, {0, f32(h) - 196, fw, 24}, fit_label(g_ui, lbl, fw - 2 * margin), COL_TEXT)
		}
	}

	// Scroll indicators + position.
	hint := fmt.tprintf("%d / %d     D-pad move   + select   < back", v.index + 1, n)
	if first_row > 0 do text.draw_centered(r, g_ui, {0, start_y - 26, fw, 22}, "^ more", COL_DIM)
	if first_row + visible_rows < rows do text.draw_centered(r, g_ui, {0, bottom + 2, fw, 22}, "v more", COL_DIM)
	text.draw_centered(r, g_ui, {0, f32(h) - 172, fw, 24}, hint, COL_DIM)
}

// overlay_open: something owns the input instead of the editor / main menu.
overlay_open :: proc() -> bool {
	return g_filenav || g_save_open || g_doc_open || g_run_open || g_proj_open || g_np_open || g_keys_open || g_settings_open || g_vp_open
}

draw_hud :: proc(r: ^gpu.Renderer, m: ^model.App, inp: model.Input, w, h: int) {
	cur_bank := model.active_bank(inp)

	fw := f32(w)
	hud_h := f32(150)
	top := f32(h) - hud_h
	gpu.draw_rect(r, {0, top, fw, hud_h}, {0.90, 0.86, 0.78, 1})
	gpu.draw_rect(r, {0, top, fw, 2}, COL_RULE)

	// Talk's button pulses only when talking would start (no overlay in the way).
	glow := g_mic_ready && !overlay_open()
	third := fw / 3.0
	cy := top + hud_h * 0.46
	for bank in 0 ..< 3 {
		cx := third * (f32(bank) + 0.5)
		active := bank == cur_bank
		draw_bank(r, m.keymap, bank, cx, cy, active ? 1.15 : 0.82, active, glow)
		text.draw_centered(r, g_ui, {cx - 100, top + hud_h - 30, 200, 24},
			HUD_LABELS[bank], active ? COL_ACCENT : COL_DIM)
	}
}

// draw_bank: one bank's d-pad and face buttons with what the layout puts on
// them. glow: pulse Talk's button while dictation is possible.
draw_bank :: proc(r: ^gpu.Renderer, km: ^model.Keymap, bank: int, cx, cy, scale: f32, active, glow: bool) {
	a := active ? f32(1.0) : f32(0.5)
	dpad_cx := cx - 82 * scale
	face_cx := cx + 82 * scale

	// D-pad plus
	arm := 46.0 * scale
	th := 26.0 * scale
	dcol := gpu.Color{0.55, 0.51, 0.45, a}
	gcol := gpu.Color{0.97, 0.95, 0.90, a}
	dsize := arm * 1.4 // the icon's plus spans ~82% of its square
	DIRS :: [4]model.Pad_Button{.Up, .Down, .Left, .Right}
	if draw_icon(r, .Dpad, dpad_cx, cy, dsize, dcol) {
		// A bound direction covers that arm's arrow notch with a disc and puts
		// its icon or glyph there.
		for dir in DIRS {
			act := model.keymap_get(km, bank, dir)
			icon, has_icon := action_icon(act)
			if model.ACTION_INFO[act].fixed do has_icon = false // plain d-pad: just the arrows
			g := slot_glyph(km, bank, dir)
			if !has_icon && g == "" do continue
			x, y := bank_slot_pos(cx, cy, scale, dir)
			gpu.draw_circle(r, x, y, dsize * 0.11, dcol)
			if has_icon && draw_icon(r, icon, x, y, dsize * 0.22, gcol) do continue
			cell := dsize * 0.26
			text.draw_centered(r, g_ui, {x - cell / 2, y - cell / 2, cell, cell}, g, gcol)
		}
	} else {
		gpu.draw_rect(r, {dpad_cx - th / 2, cy - arm / 2, th, arm}, dcol)
		gpu.draw_rect(r, {dpad_cx - arm / 2, cy - th / 2, arm, th}, dcol)

		// Overlay any bound d-pad direction glyphs.
		half := arm / 2 - th / 2
		arms := [4]gpu.Rect{
			{dpad_cx - th / 2, cy - arm / 2, th, half}, // Up
			{dpad_cx - th / 2, cy + th / 2, th, half},  // Down
			{dpad_cx - arm / 2, cy - th / 2, half, th}, // Left
			{dpad_cx + th / 2, cy - th / 2, half, th},  // Right
		}
		for dir, i in DIRS {
			if g := slot_glyph(km, bank, dir); g != "" do text.draw_centered(r, g_ui, arms[i], g, gcol)
		}
	}

	// Face buttons (Y top, A bottom, X left, B right)
	rad := 16.0 * scale
	// Mic-ready glow on Talk's button (when it's in this bank).
	if glow {
		if tb, tbtn, ok := model.keymap_find(km, .Talk); ok && tb == bank {
			x, y := bank_slot_pos(cx, cy, scale, tbtn)
			pulse := 0.5 + 0.5 * math.sin(f32(g_time) * 5.0)
			gpu.draw_circle_outline(r, x, y, rad + 4 + 2 * pulse, 2.5, {COL_DOT.r, COL_DOT.g, COL_DOT.b, 0.35 + 0.4 * pulse})
		}
	}

	FACE_COLS := [4]struct{ b: model.Pad_Button, col: gpu.Color }{
		{.Y, {0.92, 0.78, 0.25, a}}, {.A, {0.30, 0.78, 0.42, a}},
		{.X, {0.28, 0.52, 0.90, a}}, {.B, {0.86, 0.30, 0.30, a}},
	}
	for f in FACE_COLS {
		x, y := bank_slot_pos(cx, cy, scale, f.b)
		draw_face_btn(r, km, bank, f.b, x, y, rad, f.col, a)
	}
}

// One face button: its action's icon if it has one (dark ink on the light Y/A
// buttons, white on the darker X/B), else its glyph. Without the icon files,
// Talk / Delete fall back to the vector mic / trash can.
draw_face_btn :: proc(r: ^gpu.Renderer, km: ^model.Keymap, bank: int, b: model.Pad_Button, cx, cy, rad: f32, col: gpu.Color, a: f32) {
	icon, has_icon := action_icon(model.keymap_get(km, bank, b))
	if !has_icon {
		draw_face(r, g_ui, cx, cy, rad, col, slot_glyph(km, bank, b))
		return
	}
	ink := (b == .Y || b == .A) ? gpu.Color{0.08, 0.09, 0.11, a} : gpu.Color{0.97, 0.98, 1.0, a}
	gpu.draw_circle(r, cx, cy, rad, col)
	switch {
	case draw_icon(r, icon, cx, cy, rad * 1.55, ink):
	case icon == .Speech: draw_mic_icon(r, cx, cy, rad * 0.82, ink)
	case icon == .Delete: draw_trash_icon(r, cx, cy, rad * 0.82, ink, col)
	case: text.draw_centered(r, g_ui, {cx - rad, cy - rad, rad * 2, rad * 2}, slot_glyph(km, bank, b), {0.08, 0.09, 0.11, 1})
	}
}

// A small vector trash can (handle + lid + slotted body) for the delete control,
// centered on (cx, cy). `slot_col` (the button color) cuts the slots in the body.
draw_trash_icon :: proc(r: ^gpu.Renderer, cx, cy, s: f32, col: gpu.Color, slot_col: gpu.Color) {
	top := cy - s * 0.70
	gpu.draw_rect(r, {cx - s * 0.18, top, s * 0.36, s * 0.14}, col)                 // handle
	gpu.draw_rect(r, {cx - s * 0.52, top + s * 0.14, s * 1.04, s * 0.16}, col)      // lid
	body := gpu.Rect{cx - s * 0.40, top + s * 0.38, s * 0.80, s * 1.02}
	gpu.draw_rect(r, body, col)                                                      // body
	for k in 0 ..< 3 {                                                               // slots
		x := body.x + body.w * (f32(k) + 1) / 4 - s * 0.05
		gpu.draw_rect(r, {x, body.y + s * 0.16, s * 0.10, body.h - s * 0.32}, slot_col)
	}
}

// A small vector microphone (capsule head + stand + base), drawn with primitives.
draw_mic_icon :: proc(r: ^gpu.Renderer, cx, cy, s: f32, col: gpu.Color) {
	bw := s * 0.60 // head width
	bh := s * 0.70 // straight part of the capsule
	top := cy - s * 0.68
	// capsule head (rounded top + bottom)
	gpu.draw_rect(r, {cx - bw / 2, top, bw, bh}, col)
	gpu.draw_circle(r, cx, top, bw / 2, col)
	gpu.draw_circle(r, cx, top + bh, bw / 2, col)
	// stand (vertical neck)
	gpu.draw_rect(r, {cx - s * 0.07, top + bh, s * 0.14, s * 0.42}, col)
	// base
	gpu.draw_rect(r, {cx - s * 0.34, cy + s * 0.60, s * 0.68, s * 0.15}, col)
}

build_prompt :: proc(vocab: []string) -> string {
	joined := strings.join(vocab, " ", context.temp_allocator)
	return strings.concatenate({"lowercase Odin code identifiers: ", joined})
}

join_identifier :: proc(parts: []string) -> string {
	out: [dynamic]u8
	for p in parts {
		if p == "" do continue
		if len(out) > 0 do append(&out, '_')
		append(&out, ..transmute([]u8)p)
	}
	return string(out[:])
}

join_spaces :: proc(parts: []string) -> string {
	out: [dynamic]u8
	for p in parts {
		if p == "" do continue
		if len(out) > 0 do append(&out, ' ')
		append(&out, ..transmute([]u8)p)
	}
	return string(out[:])
}

draw_face :: proc(r: ^gpu.Renderer, font: ^text.Font, cx, cy, rad: f32, col: gpu.Color, label: string) {
	gpu.draw_circle(r, cx, cy, rad, col)
	text.draw_centered(r, font, {cx - rad, cy - rad, rad * 2, rad * 2}, label, {0.08, 0.09, 0.11, 1})
}

// copy_selection puts the highlighted statement / block (or the whole file, on a
// green dot) on the clipboard as formatted Odin source.
copy_selection :: proc(m: ^model.App) {
	src := model.copy_selection_source(m)
	if src == "" {
		set_status("nothing to copy")
		return
	}
	if !trace_replaying() && !platform.set_clipboard_text(src) { // TRACE hook (was: no replay check)
		set_status("copy failed")
		return
	}
	n := strings.count(src, "\n") + 1
	set_status(fmt.tprintf("copied %d line%s", n, n == 1 ? "" : "s"))
}

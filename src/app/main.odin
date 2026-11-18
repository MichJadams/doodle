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

// --- Colors ---
COL_BG     :: gpu.Color{0.09, 0.10, 0.12, 1}
COL_PANEL  :: gpu.Color{0.14, 0.15, 0.18, 1}
COL_TEXT   :: gpu.Color{0.90, 0.92, 0.96, 1}
COL_DIM    :: gpu.Color{0.50, 0.52, 0.58, 1}
COL_ACCENT :: gpu.Color{0.20, 0.85, 0.45, 1}
COL_HILITE :: gpu.Color{0.22, 0.40, 0.70, 1}

HUD_LABELS := [?]string{"L-TRIGGER", "DEFAULT", "R-TRIGGER"}

// UI/chrome font (smaller than the code font) and frame time, set in main().
g_ui:   ^text.Font
g_time: f64

// STT push-to-talk state (for the HUD/editor overlay).
g_recording: bool
g_heard:     string
g_mic_ready: bool            // a field is highlighted + whisper available
g_rt_held:   bool            // right trigger held (statement-selection highlight)
g_stt_parts: [dynamic]string // dictated fragments joined by "_"
g_stt_ni:    int             // target node/field captured at record start
g_stt_fi:    int
g_vocab:     []string        // per-utterance STT bias vocabulary (freed after)
g_prompt:    string

// Raw per-frame input accumulated from SDL events, converted to model.Input.
Raw :: struct {
	lt, rt:         f32,
	key_lt, key_rt: bool,
	x_held:         bool,

	e_confirm, e_cancel:           bool,
	e_up, e_down, e_left, e_right: bool,
	e_y:                           bool,
}

FaceBtn :: enum { A, B, X, Y }
Dir4    :: enum { Up, Down, Left, Right }

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

	font := load_a_font(r, 28) // code font
	if font == nil {
		fmt.eprintln("could not load any font")
		return
	}
	defer text.shutdown(font)

	g_ui = load_a_font(r, 18) // UI/chrome font
	if g_ui == nil do g_ui = font
	defer if g_ui != font do text.shutdown(g_ui)

	m: model.App
	m.state = .Menu
	m.os_name = os_name()

	// STT is optional: if whisper isn't built yet, stt_e is nil and PTT is disabled.
	stt_e, _ := stt.init(stt.default_config())
	defer stt.shutdown(stt_e)

	raw: Raw
	events: [dynamic]platform.Event
	defer delete(events)

	for !m.want_quit {
		g_time = platform.now_seconds()
		reset_edges(&raw)

		clear(&events)
		platform.poll_events(win, &events)
		for e in events {
			if _, is_quit := e.(platform.Quit_Event); is_quit {
				m.want_quit = true
			}
			handle_event(&raw, e)
		}

		inp := build_input(&raw)
		down_edge := inp.down
		mic_hold := inp.lt_held && raw.x_held
		g_rt_held = inp.rt_held
		// While recording, the d-pad/buttons drive dictation, not navigation.
		if g_recording {
			inp.confirm = false; inp.cancel = false
			inp.up = false; inp.down = false; inp.left = false; inp.right = false
		}
		// RT+Y deletes the currently selected statement.
		if inp.rt_held && raw.e_y && m.state == .Editor && m.editor_line < len(m.doc.nodes) {
			model.delete_focused_construct(&m)
		}
		model.update(&m, inp)

		// Mic is available only when an editable field is highlighted.
		tni, tfi, has_target := model.editor_target(&m)
		// Mic is available only on an editable identifier field, not on slots.
		target_editable := has_target && m.doc.nodes[tni].fields[tfi].editable
		g_mic_ready = target_editable && stt_e != nil && m.state == .Editor

		// Push-to-talk dictation into the highlighted field.
		if mic_hold && g_mic_ready && !g_recording {
			// Bias dictation toward known identifiers/keywords (fixes "maine"->"main").
			g_vocab = model.collect_vocab(&m)
			g_prompt = build_prompt(g_vocab)
			stt.set_context(stt_e, g_prompt, g_vocab)
			stt.begin(stt_e)
			g_recording = true
			g_stt_ni = tni
			g_stt_fi = tfi
			clear(&g_stt_parts)
		}
		if g_recording && down_edge {
			append(&g_stt_parts, stt.segment(stt_e)) // d-pad Down = underscore boundary
		}
		if g_recording && !mic_hold {
			append(&g_stt_parts, stt.end(stt_e))
			final := join_identifier(g_stt_parts[:])
			if final != "" {
				model.set_field_text(&m, g_stt_ni, g_stt_fi, final)
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

		w, h := platform.get_size(win)
		gpu.begin_frame(r, w, h, COL_BG)
		switch m.state {
		case .Menu:
			draw_menu(r, font, &m, w, h)
		case .Editor:
			draw_editor(r, font, &m, w, h)
		case .Radial:
			draw_editor(r, font, &m, w, h)
			draw_radial(r, &m, w, h)
		}
		draw_hud(r, &m, inp, w, h)
		gpu.end_frame(r)
		platform.present(win)

		free_all(context.temp_allocator)
	}
}

os_name :: proc() -> string {
	#partial switch ODIN_OS {
	case .Windows: return "windows"
	case .Linux:   return "linux"
	case .Darwin:  return "darwin"
	}
	return ""
}

load_a_font :: proc(r: ^gpu.Renderer, px: f32) -> ^text.Font {
	paths := [?]string{
		"assets/fonts/mono.ttf",
		"C:\\Windows\\Fonts\\consola.ttf",
		"C:\\Windows\\Fonts\\segoeui.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	}
	for p in paths {
		if f, fok := text.load_font(r, p, px); fok do return f
	}
	return nil
}

// ---------------- Input ----------------

reset_edges :: proc(raw: ^Raw) {
	raw.e_confirm = false
	raw.e_cancel = false
	raw.e_up = false
	raw.e_down = false
	raw.e_left = false
	raw.e_right = false
	raw.e_y = false
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
	}
}

handle_event :: proc(raw: ^Raw, e: platform.Event) {
	#partial switch ev in e {
	case platform.Button_Event:
		if ev.button == .X do raw.x_held = ev.pressed
		if ev.pressed {
			#partial switch ev.button {
			case .A:     raw.e_confirm = true
			case .B:     raw.e_cancel = true
			case .Up:    raw.e_up = true
			case .Down:  raw.e_down = true
			case .Left:  raw.e_left = true
			case .Right: raw.e_right = true
			case .Y:     raw.e_y = true
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
	// Trigger emulation (held): q = left trigger, e = right trigger.
	switch sym {
	case 'q': raw.key_lt = pressed
	case 'e': raw.key_rt = pressed
	case 'x':
		raw.x_held = pressed
	case 'y':
		if pressed do raw.e_y = true
	}
	if !pressed do return
	switch sym {
	case KEY_RETURN, KEY_SPACE: raw.e_confirm = true
	case KEY_BACKSPACE, KEY_ESCAPE: raw.e_cancel = true
	case KEY_UP, 'w':    raw.e_up = true
	case KEY_DOWN, 's':  raw.e_down = true
	case KEY_LEFT, 'a':  raw.e_left = true
	case KEY_RIGHT, 'd': raw.e_right = true
	}
}

// ---------------- Button glyph bindings ----------------

// Glyph drawn on a face button for the given bank + context. As we bind
// actions, the on-pad symbol changes (e.g. A -> "+"). ASCII only (atlas 32..127).
face_glyph :: proc(m: ^model.App, bank: int, face: FaceBtn) -> string {
	if bank == 0 && face == .X do return "" // LT + X = talk: drawn as a mic icon, no letter
	if bank == 2 && face == .Y do return "" // RT + Y = delete: drawn as a trash icon, no letter
	if bank == 1 { // middle bank = default (no trigger) context
		switch face {
		case .A: return "+" // select / confirm
		case .B: return "<" // back / cancel
		case .X:
		case .Y:
		}
	}
	switch face {
	case .A: return "A"
	case .B: return "B"
	case .X: return "X"
	case .Y: return "Y"
	}
	return "?"
}

// Glyph overlaid on a d-pad direction ("" = nothing bound).
dpad_glyph :: proc(m: ^model.App, bank: int, dir: Dir4) -> string {
	if bank == 0 && dir == .Left do return "=" // LT + Left = IDE menu
	return ""
}

// ---------------- Rendering ----------------

draw_menu :: proc(r: ^gpu.Renderer, font: ^text.Font, m: ^model.App, w, h: int) {
	fw, fh := f32(w), f32(h)
	text.draw_centered(r, font, {0, fh * 0.20, fw, 60}, "DOODLE", COL_ACCENT)
	text.draw_centered(r, g_ui, {0, fh * 0.20 + 56, fw, 30}, "Odin IDE  -  gamepad native", COL_DIM)

	base_y := fh * 0.42
	for item, i in model.MENU_ITEMS {
		row := gpu.Rect{fw * 0.5 - 220, base_y + f32(i) * 72, 440, 56}
		active := i == m.menu_index
		enabled := i == 0
		gpu.draw_rect(r, row, active ? COL_HILITE : COL_PANEL)
		if active do gpu.draw_rect_outline(r, row, 2, COL_ACCENT)
		text.draw_centered(r, g_ui, row, item, enabled ? COL_TEXT : COL_DIM)
	}

	text.draw_centered(r, g_ui, {0, fh * 0.84, fw, 30},
		"D-pad / Arrows to move    A / Enter to select    (only New Project is wired)", COL_DIM)
}

draw_editor :: proc(r: ^gpu.Renderer, font: ^text.Font, m: ^model.App, w, h: int) {
	pad := f32(28)
	text.draw_line(r, g_ui, {pad, 14}, "untitled.odin", COL_DIM)
	gpu.draw_rect(r, {0, 50, f32(w), 1}, {0.2, 0.22, 0.27, 1})

	lh := text.line_height(font)
	y0 := f32(96)
	x0 := pad + 34
	tni, tfi, has_target := model.editor_target(m)
	
	// Statement highlight when RT held in editor.
	if g_rt_held && m.state == .Editor && m.editor_line >= 0 && m.editor_line < len(m.doc.nodes) {
		start, end := model.construct_range(m, m.editor_line)
		start_y := y0 + f32(start) * lh
		end_y := y0 + f32(end) * lh + lh
		gpu.draw_rect(r, {pad, start_y, f32(w) - pad * 2, end_y - start_y}, {0.22, 0.40, 0.70, 0.25})
	}
	for node, ni in m.doc.nodes {
		x := x0
		y := y0 + f32(ni) * lh
		for field, fi in node.fields {
			if field.slot {
				// Slot: render as orange dot
				dot_w := f32(24) // dot diameter + padding
				dot_cx := x + dot_w / 2
				dot_cy := y + lh / 2
				if has_target && ni == tni && fi == tfi {
					gpu.draw_rect(r, {x - 4, y, dot_w + 8, lh}, {0.22, 0.40, 0.70, 0.55})
					gpu.draw_rect_outline(r, {x - 4, y, dot_w + 8, lh}, 2, COL_ACCENT)
				}
				outer, inner := slot_dot_color(field.kind)
				draw_colored_dot(r, dot_cx, dot_cy, outer, inner)
				x += dot_w
			} else {
				// Regular field: render as text
				wsz := text.measure(font, field.text).x
				if has_target && ni == tni && fi == tfi {
					gpu.draw_rect(r, {x - 4, y, wsz + 8, lh}, {0.22, 0.40, 0.70, 0.55})
					gpu.draw_rect_outline(r, {x - 4, y, wsz + 8, lh}, 2, COL_ACCENT)
				}
				col := field.editable ? COL_ACCENT : COL_TEXT
				text.draw_line(r, font, {x, y}, field.text, col)
				x += wsz
			}
		}
	}
	dot_y := y0 + f32(len(m.doc.nodes)) * lh + lh * 0.4
	draw_green_dot(r, pad + 14, dot_y)

	// STT push-to-talk indicator / last heard word.
	if g_recording {
		text.draw_line(r, g_ui, {f32(w) - 150, 14}, "[REC]", {0.90, 0.30, 0.30, 1})
	} else if g_heard != "" {
		text.draw_line(r, g_ui, {f32(w) - 320, 14}, fmt.tprintf("heard: %s", g_heard), COL_ACCENT)
	}
}

// Return colors for a slot dot based on field kind.
slot_dot_color :: proc(kind: string) -> (outer_col, inner_col: gpu.Color) {
	switch kind {
	case "value":
		return {1.00, 0.60, 0.15, 1.0}, {1.00, 0.65, 0.20, 1.0}
	case "type":
		return {0.35, 0.70, 1.00, 1.0}, {0.40, 0.75, 1.00, 1.0}
	case "body":
		return {0.35, 0.85, 0.45, 1.0}, {0.40, 0.90, 0.50, 1.0}
	case "params":
		return {0.80, 0.45, 0.95, 1.0}, {0.85, 0.50, 1.00, 1.0}
	case:
		// Generic/default: neutral orange
		return {0.95, 0.55, 0.20, 1.0}, {1.00, 0.60, 0.25, 1.0}
	}
}

draw_green_dot :: proc(r: ^gpu.Renderer, cx, cy: f32) {
	draw_colored_dot(r, cx, cy, {0.20, 0.90, 0.45, 1.0}, {0.25, 0.95, 0.50, 1})
}

draw_orange_dot :: proc(r: ^gpu.Renderer, cx, cy: f32) {
	draw_colored_dot(r, cx, cy, {1.0, 0.55, 0.12, 1.0}, {1.0, 0.65, 0.22, 1})
}

draw_colored_dot :: proc(r: ^gpu.Renderer, cx, cy: f32, outer_col, inner_col: gpu.Color) {
	pulse := 0.5 + 0.5 * math.sin(f32(g_time) * 3.0)
	radius := 9.0 + 3.0 * pulse
	outer := outer_col
	outer.a = 0.18 + 0.20 * pulse
	gpu.draw_circle(r, cx, cy, radius + 9, outer)
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

// A flat, alphabetical, 8-wide grid that scrolls vertically.
draw_radial :: proc(r: ^gpu.Renderer, m: ^model.App, w, h: int) {
	v := model.current_view(m)
	if v == nil do return
	fw, fh := f32(w), f32(h)
	gpu.draw_rect(r, {0, 0, fw, fh}, {0, 0, 0, 0.60})
	text.draw_centered(r, g_ui, {0, fh * 0.07, fw, 36}, v.title, COL_ACCENT)

	n := len(v.entries)
	if n == 0 do return
	cols := model.GRID_COLS
	if n < cols do cols = n
	if cols < 1 do cols = 1
	rows := (n + cols - 1) / cols

	margin := f32(40)
	gap := f32(10)
	cellw := (fw - 2 * margin - f32(cols - 1) * gap) / f32(cols)
	cellh := f32(42)
	vgap := f32(8)
	start_x := margin
	start_y := fh * 0.14
	bottom := f32(h) - 185 // leave room for the HUD + hint

	visible_rows := int((bottom - start_y) / (cellh + vgap))
	if visible_rows < 1 do visible_rows = 1

	sel_row := v.index / cols
	// Scroll so the selected row stays visible (keep it roughly centered).
	first_row := sel_row - visible_rows / 2
	max_first := rows - visible_rows
	if max_first < 0 do max_first = 0
	if first_row > max_first do first_row = max_first
	if first_row < 0 do first_row = 0

	for row in first_row ..< min(first_row + visible_rows, rows) {
		for col in 0 ..< cols {
			i := row * cols + col
			if i >= n do break
			e := v.entries[i]
			x := start_x + f32(col) * (cellw + gap)
			y := start_y + f32(row - first_row) * (cellh + vgap)
			box := gpu.Rect{x, y, cellw, cellh}
			active := i == v.index
			gpu.draw_rect(r, box, active ? COL_HILITE : COL_PANEL)
			if active do gpu.draw_rect_outline(r, box, 2, COL_ACCENT)
			col_text := e.dim ? COL_DIM : COL_TEXT
			text.draw_centered(r, g_ui, box, fit_label(g_ui, e.label, cellw - 10), col_text)
		}
	}

	// Scroll indicators + position.
	hint := fmt.tprintf("%d / %d     D-pad move   + select   < back", v.index + 1, n)
	if first_row > 0 do text.draw_centered(r, g_ui, {0, start_y - 26, fw, 22}, "^ more", COL_DIM)
	if first_row + visible_rows < rows do text.draw_centered(r, g_ui, {0, bottom + 2, fw, 22}, "v more", COL_DIM)
	text.draw_centered(r, g_ui, {0, f32(h) - 172, fw, 24}, hint, COL_DIM)
}

draw_hud :: proc(r: ^gpu.Renderer, m: ^model.App, inp: model.Input, w, h: int) {
	cur_bank := model.active_bank(inp)

	fw := f32(w)
	hud_h := f32(150)
	top := f32(h) - hud_h
	gpu.draw_rect(r, {0, top, fw, hud_h}, {0.11, 0.12, 0.15, 1})
	gpu.draw_rect(r, {0, top, fw, 2}, {0.20, 0.22, 0.27, 1})

	third := fw / 3.0
	cy := top + hud_h * 0.46
	for bank in 0 ..< 3 {
		cx := third * (f32(bank) + 0.5)
		active := bank == cur_bank
		draw_bank(r, m, bank, cx, cy, active ? 1.15 : 0.82, active)
		text.draw_centered(r, g_ui, {cx - 100, top + hud_h - 30, 200, 24},
			HUD_LABELS[bank], active ? COL_ACCENT : COL_DIM)
	}
}

draw_bank :: proc(r: ^gpu.Renderer, m: ^model.App, bank: int, cx, cy, scale: f32, active: bool) {
	a := active ? f32(1.0) : f32(0.5)
	dpad_cx := cx - 82 * scale
	face_cx := cx + 82 * scale

	// D-pad plus
	arm := 46.0 * scale
	th := 26.0 * scale
	dcol := gpu.Color{0.75, 0.77, 0.82, a}
	gpu.draw_rect(r, {dpad_cx - th / 2, cy - arm / 2, th, arm}, dcol)
	gpu.draw_rect(r, {dpad_cx - arm / 2, cy - th / 2, arm, th}, dcol)

	// Overlay any bound d-pad direction glyphs.
	gcol := gpu.Color{0.10, 0.11, 0.13, a}
	half := arm / 2 - th / 2
	if g := dpad_glyph(m, bank, .Left);  g != "" do text.draw_centered(r, g_ui, {dpad_cx - arm / 2, cy - th / 2, half, th}, g, gcol)
	if g := dpad_glyph(m, bank, .Right); g != "" do text.draw_centered(r, g_ui, {dpad_cx + th / 2, cy - th / 2, half, th}, g, gcol)
	if g := dpad_glyph(m, bank, .Up);    g != "" do text.draw_centered(r, g_ui, {dpad_cx - th / 2, cy - arm / 2, th, half}, g, gcol)
	if g := dpad_glyph(m, bank, .Down);  g != "" do text.draw_centered(r, g_ui, {dpad_cx - th / 2, cy + th / 2, th, half}, g, gcol)

	// Face buttons (Y top, A bottom, X left, B right)
	d := 32.0 * scale
	rad := 16.0 * scale
	// Mic-ready glow on LT+X (left bank, X button).
	if bank == 0 && g_mic_ready {
		pulse := 0.5 + 0.5 * math.sin(f32(g_time) * 5.0)
		gpu.draw_circle_outline(r, face_cx - d, cy, rad + 4 + 2 * pulse, 2.5, {0.30, 0.95, 0.50, 0.35 + 0.4 * pulse})
	}

	draw_face(r, g_ui, face_cx, cy - d, rad, {0.92, 0.78, 0.25, a}, face_glyph(m, bank, .Y))
	draw_face(r, g_ui, face_cx, cy + d, rad, {0.30, 0.78, 0.42, a}, face_glyph(m, bank, .A))
	draw_face(r, g_ui, face_cx - d, cy, rad, {0.28, 0.52, 0.90, a}, face_glyph(m, bank, .X))
	draw_face(r, g_ui, face_cx + d, cy, rad, {0.86, 0.30, 0.30, a}, face_glyph(m, bank, .B))

	// LT+X (left bank, X) = talk: draw a mic icon.
	if bank == 0 {
		draw_mic_icon(r, face_cx - d, cy, rad * 0.82, {0.97, 0.98, 1.0, a})
	}
	// RT+Y (right bank, Y) = delete: draw a trash icon.
	if bank == 2 {
		draw_trash_icon(r, face_cx, cy - d, rad * 0.78, {0.97, 0.98, 1.0, a})
	}
}

// A small vector trash can (lid + body) for the delete control.
draw_trash_icon :: proc(r: ^gpu.Renderer, cx, cy, s: f32, col: gpu.Color) {
	lid_w := s * 0.95
	gpu.draw_rect(r, {cx - lid_w / 2, cy - s * 0.62, lid_w, s * 0.16}, col)      // lid
	gpu.draw_rect(r, {cx - s * 0.16, cy - s * 0.78, s * 0.32, s * 0.16}, col)    // handle
	gpu.draw_rect(r, {cx - s * 0.40, cy - s * 0.40, s * 0.80, s * 0.98}, col)    // body
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

draw_face :: proc(r: ^gpu.Renderer, font: ^text.Font, cx, cy, rad: f32, col: gpu.Color, label: string) {
	gpu.draw_circle(r, cx, cy, rad, col)
	text.draw_centered(r, font, {cx - rad, cy - rad, rad * 2, rad * 2}, label, {0.08, 0.09, 0.11, 1})
}

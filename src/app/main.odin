package main

// Integration layer: wires packages and runs the main loop.
// Owner: Integrator.  Contract: ARCHITECTURE.md §6 / docs/EDITOR_MODEL.md

import "../platform"
import "../gpu"
import "../text"
import "core:math"
import "core:fmt"

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

// --- Static option lists (package-level so slices stay valid) ---
MENU_ITEMS     := [?]string{"New Project", "Recent Projects", "Open Folder"}
ROOT_OPTS      := [?]string{"File Setup", "Dependencies", "Procedures", "Types", "Values"}
FILESETUP_OPTS := [?]string{"Package declaration", "File tags", "Comments"}
IDE_OPTS       := [?]string{"Exit"}
HUD_LABELS     := [?]string{"L-TRIGGER", "DEFAULT", "R-TRIGGER"}

State :: enum { Menu, Editor, Radial }

GRID_COLS :: 3

// UI/chrome font (smaller than the code font). Set in main().
g_ui: ^text.Font

// Identifies a face button so we can look up its current bound symbol.
FaceBtn :: enum { A, B, X, Y }

// Returns the glyph to draw on a face button for the given bank + app context.
// As we bind actions to buttons, their on-pad symbol changes (e.g. A -> "+").
// NOTE: glyphs must be ASCII (the baked font atlas covers 32..127).
face_glyph :: proc(app: ^App, bank: int, face: FaceBtn) -> string {
	// Middle bank (bank 1) = default context (no trigger held).
	if bank == 1 {
		switch face {
		case .A: return "+" // select / confirm
		case .B: return "<" // back / cancel
		case .X: // unbound for now
		case .Y: // unbound for now
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

Dir4 :: enum { Up, Down, Left, Right }

// Glyph to overlay on a d-pad direction for a bank ("" = nothing bound yet).
dpad_glyph :: proc(app: ^App, bank: int, dir: Dir4) -> string {
	// Left bank (LT held): D-pad Left opens the IDE menu.
	if bank == 0 && dir == .Left do return "="
	return ""
}

// Which control bank is active: 0 = left (LT), 1 = middle (none), 2 = right (RT).
active_bank :: proc(app: ^App) -> int {
	if app.lt > 0.5 || app.key_lt do return 0
	if app.rt > 0.5 || app.key_rt do return 2
	return 1
}

Doc :: struct {
	nodes: [dynamic]string, // each entry is an inserted Odin line/section
}

insert_node :: proc(app: ^App, s: string) {
	append(&app.doc.nodes, s)
}

MenuKind :: enum { Add, Ide }

RadialMenu :: struct {
	kind:    MenuKind,
	title:   string,
	options: []string,
	index:   int,
	level:   int, // 0 = root, 1 = file-setup submenu
}

App :: struct {
	state:      State,
	menu_index:   int,
	doc:          Doc,
	radial:       RadialMenu,
	return_state: State, // where a menu returns to on cancel/complete

	lt, rt:         f32,
	key_lt, key_rt: bool,

	e_confirm, e_cancel:            bool,
	e_up, e_down, e_left, e_right:  bool,
	want_quit:                      bool,
	time:                           f64,
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

	font := load_a_font(r, 28) // code font
	if font == nil {
		fmt.eprintln("could not load any font")
		return
	}
	defer text.shutdown(font)

	g_ui = load_a_font(r, 18) // UI/chrome font
	if g_ui == nil do g_ui = font
	defer if g_ui != font do text.shutdown(g_ui)

	app: App
	app.state = .Menu

	events: [dynamic]platform.Event
	defer delete(events)

	for !app.want_quit {
		app.time = platform.now_seconds()
		reset_edges(&app)

		clear(&events)
		platform.poll_events(win, &events)
		for e in events do handle_event(&app, e)
		update(&app)

		w, h := platform.get_size(win)
		gpu.begin_frame(r, w, h, COL_BG)
		switch app.state {
		case .Menu:
			draw_menu(r, font, &app, w, h)
		case .Editor:
			draw_editor(r, font, &app, w, h)
		case .Radial:
			draw_editor(r, font, &app, w, h)
			draw_radial(r, font, &app, w, h)
		}
		draw_hud(r, font, &app, w, h)
		gpu.end_frame(r)
		platform.present(win)

		free_all(context.temp_allocator)
	}
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
		if f, ok := text.load_font(r, p, px); ok do return f
	}
	return nil
}

reset_edges :: proc(app: ^App) {
	app.e_confirm = false
	app.e_cancel = false
	app.e_up = false
	app.e_down = false
	app.e_left = false
	app.e_right = false
}

handle_event :: proc(app: ^App, e: platform.Event) {
	#partial switch ev in e {
	case platform.Quit_Event:
		app.want_quit = true
	case platform.Button_Event:
		if ev.pressed {
			#partial switch ev.button {
			case .A:     app.e_confirm = true
			case .B:     app.e_cancel = true
			case .Up:    app.e_up = true
			case .Down:  app.e_down = true
			case .Left:  app.e_left = true
			case .Right: app.e_right = true
			}
		}
	case platform.Axis_Event:
		if ev.axis == .LTrigger do app.lt = ev.value
		if ev.axis == .RTrigger do app.rt = ev.value
	case platform.Key_Event:
		handle_key(app, ev.sym, ev.pressed)
	}
}

handle_key :: proc(app: ^App, sym: i32, pressed: bool) {
	// Trigger emulation (held): q = left trigger, e = right trigger.
	switch sym {
	case 'q': app.key_lt = pressed
	case 'e': app.key_rt = pressed
	}
	if !pressed do return
	switch sym {
	case KEY_RETURN, KEY_SPACE:
		app.e_confirm = true
	case KEY_BACKSPACE:
		app.e_cancel = true
	case KEY_ESCAPE:
		if app.state == .Menu do app.want_quit = true
		else do app.e_cancel = true
	case KEY_UP, 'w':
		app.e_up = true
	case KEY_DOWN, 's':
		app.e_down = true
	case KEY_LEFT, 'a':
		app.e_left = true
	case KEY_RIGHT, 'd':
		app.e_right = true
	}
}

update :: proc(app: ^App) {
	// Global binding: LT (left bank) + D-pad Left opens the IDE menu.
	if app.state != .Radial && active_bank(app) == 0 && app.e_left {
		open_ide_menu(app)
		return
	}

	switch app.state {
	case .Menu:
		n := len(MENU_ITEMS)
		if app.e_up   do app.menu_index = (app.menu_index + n - 1) %% n
		if app.e_down do app.menu_index = (app.menu_index + 1) %% n
		if app.e_confirm {
			if app.menu_index == 0 { // New Project
				clear(&app.doc.nodes)
				app.state = .Editor
			}
			// Recent / Open Folder: not wired yet.
		}
	case .Editor:
		if app.e_cancel  do app.state = .Menu
		if app.e_confirm do open_radial_root(app)
	case .Radial:
		n := len(app.radial.options)
		cols := GRID_COLS
		if n < cols do cols = n
		if app.e_right do app.radial.index = min(app.radial.index + 1, n - 1)
		if app.e_left  do app.radial.index = max(app.radial.index - 1, 0)
		if app.e_down && app.radial.index + cols < n do app.radial.index += cols
		if app.e_up   && app.radial.index - cols >= 0 do app.radial.index -= cols
		if app.e_cancel {
			if app.radial.kind == .Add && app.radial.level == 1 do open_radial_root(app)
			else do app.state = app.return_state
		}
		if app.e_confirm do radial_select(app)
	}
}

open_radial_root :: proc(app: ^App) {
	app.return_state = .Editor
	app.state = .Radial
	app.radial.kind = .Add
	app.radial.level = 0
	app.radial.index = 0
	app.radial.title = "Add  (insertion point)"
	app.radial.options = ROOT_OPTS[:]
}

open_ide_menu :: proc(app: ^App) {
	app.return_state = app.state
	app.state = .Radial
	app.radial.kind = .Ide
	app.radial.level = 0
	app.radial.index = 0
	app.radial.title = "IDE MENU"
	app.radial.options = IDE_OPTS[:]
}

radial_select :: proc(app: ^App) {
	if app.radial.kind == .Ide {
		switch app.radial.index {
		case 0: // Exit
			app.want_quit = true
		}
		return
	}
	if app.radial.level == 0 {
		switch app.radial.index {
		case 0: // File Setup -> submenu
			app.radial.level = 1
			app.radial.index = 0
			app.radial.title = "File Setup"
			app.radial.options = FILESETUP_OPTS[:]
		case:
			app.state = app.return_state // other branches not implemented yet
		}
	} else { // File Setup submenu
		switch app.radial.index {
		case 0: insert_node(app, "package main")   // Package declaration
		case 1: insert_node(app, "#+build linux")  // File tags
		case 2: insert_node(app, "// comment")     // Comments
		}
		app.state = app.return_state
	}
}

// ---------------- Rendering ----------------

draw_menu :: proc(r: ^gpu.Renderer, font: ^text.Font, app: ^App, w, h: int) {
	fw, fh := f32(w), f32(h)
	text.draw_centered(r, font, {0, fh * 0.20, fw, 60}, "DOODLE", COL_ACCENT)
	text.draw_centered(r, g_ui, {0, fh * 0.20 + 56, fw, 30}, "Odin IDE  -  gamepad native", COL_DIM)

	base_y := fh * 0.42
	for item, i in MENU_ITEMS {
		row := gpu.Rect{fw * 0.5 - 220, base_y + f32(i) * 72, 440, 56}
		active := i == app.menu_index
		enabled := i == 0
		gpu.draw_rect(r, row, active ? COL_HILITE : COL_PANEL)
		if active do gpu.draw_rect_outline(r, row, 2, COL_ACCENT)
		text.draw_centered(r, g_ui, row, item, enabled ? COL_TEXT : COL_DIM)
	}

	text.draw_centered(r, g_ui, {0, fh * 0.84, fw, 30},
		"D-pad / Arrows to move    A / Enter to select    (only New Project is wired)", COL_DIM)
}

draw_editor :: proc(r: ^gpu.Renderer, font: ^text.Font, app: ^App, w, h: int) {
	pad := f32(28)
	text.draw_line(r, g_ui, {pad, 14}, "untitled.odin", COL_DIM)
	gpu.draw_rect(r, {0, 50, f32(w), 1}, {0.2, 0.22, 0.27, 1})

	lh := text.line_height(font)
	y0 := f32(96)
	x := pad + 34
	for node, i in app.doc.nodes {
		text.draw_line(r, font, {x, y0 + f32(i) * lh}, node, COL_TEXT)
	}
	dot_y := y0 + f32(len(app.doc.nodes)) * lh + lh * 0.4
	draw_green_dot(r, app, pad + 14, dot_y)
}

draw_green_dot :: proc(r: ^gpu.Renderer, app: ^App, cx, cy: f32) {
	pulse := 0.5 + 0.5 * math.sin(f32(app.time) * 3.0)
	radius := 9.0 + 3.0 * pulse
	gpu.draw_circle(r, cx, cy, radius + 9, {0.20, 0.90, 0.45, 0.18 + 0.20 * pulse})
	gpu.draw_circle(r, cx, cy, radius, {0.25, 0.95, 0.50, 1})
}

// The "radial" is now a centered GRID of buttons.
draw_radial :: proc(r: ^gpu.Renderer, font: ^text.Font, app: ^App, w, h: int) {
	fw, fh := f32(w), f32(h)
	gpu.draw_rect(r, {0, 0, fw, fh}, {0, 0, 0, 0.60})
	text.draw_centered(r, g_ui, {0, fh * 0.20, fw, 40}, app.radial.title, COL_ACCENT)

	n := len(app.radial.options)
	cols := GRID_COLS
	if n < cols do cols = n
	rows := (n + cols - 1) / cols

	cellw, cellh, gap := f32(240), f32(64), f32(18)
	grid_w := f32(cols) * cellw + f32(cols - 1) * gap
	grid_h := f32(rows) * cellh + f32(rows - 1) * gap
	start_x := fw * 0.5 - grid_w * 0.5
	start_y := fh * 0.5 - grid_h * 0.5 + 10

	for opt, i in app.radial.options {
		col := i % cols
		row := i / cols
		box := gpu.Rect{start_x + f32(col) * (cellw + gap), start_y + f32(row) * (cellh + gap), cellw, cellh}
		active := i == app.radial.index
		gpu.draw_rect(r, box, active ? COL_HILITE : COL_PANEL)
		if active do gpu.draw_rect_outline(r, box, 2, COL_ACCENT)
		text.draw_centered(r, g_ui, box, opt, COL_TEXT)
	}
	text.draw_centered(r, g_ui, {0, start_y + grid_h + 26, fw, 28}, "D-pad / Arrows to move     + : select     < : back", COL_DIM)
}

draw_hud :: proc(r: ^gpu.Renderer, font: ^text.Font, app: ^App, w, h: int) {
	cur_bank := active_bank(app)

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
		draw_bank(r, font, app, bank, cx, cy, active ? 1.15 : 0.82, active)
		text.draw_centered(r, g_ui, {cx - 100, top + hud_h - 30, 200, 24},
			HUD_LABELS[bank], active ? COL_ACCENT : COL_DIM)
	}
}

draw_bank :: proc(r: ^gpu.Renderer, font: ^text.Font, app: ^App, bank: int, cx, cy, scale: f32, active: bool) {
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
	if g := dpad_glyph(app, bank, .Left);  g != "" do text.draw_centered(r, g_ui, {dpad_cx - arm / 2, cy - th / 2, half, th}, g, gcol)
	if g := dpad_glyph(app, bank, .Right); g != "" do text.draw_centered(r, g_ui, {dpad_cx + th / 2, cy - th / 2, half, th}, g, gcol)
	if g := dpad_glyph(app, bank, .Up);    g != "" do text.draw_centered(r, g_ui, {dpad_cx - th / 2, cy - arm / 2, th, half}, g, gcol)
	if g := dpad_glyph(app, bank, .Down);  g != "" do text.draw_centered(r, g_ui, {dpad_cx - th / 2, cy + th / 2, th, half}, g, gcol)

	// Face buttons (Y top, A bottom, X left, B right)
	d := 32.0 * scale
	rad := 16.0 * scale
	draw_face(r, g_ui, face_cx, cy - d, rad, {0.92, 0.78, 0.25, a}, face_glyph(app, bank, .Y))
	draw_face(r, g_ui, face_cx, cy + d, rad, {0.30, 0.78, 0.42, a}, face_glyph(app, bank, .A))
	draw_face(r, g_ui, face_cx - d, cy, rad, {0.28, 0.52, 0.90, a}, face_glyph(app, bank, .X))
	draw_face(r, g_ui, face_cx + d, cy, rad, {0.86, 0.30, 0.30, a}, face_glyph(app, bank, .B))
}

draw_face :: proc(r: ^gpu.Renderer, font: ^text.Font, cx, cy, rad: f32, col: gpu.Color, label: string) {
	gpu.draw_circle(r, cx, cy, rad, col)
	text.draw_centered(r, font, {cx - rad, cy - rad, rad * 2, rad * 2}, label, {0.08, 0.09, 0.11, 1})
}

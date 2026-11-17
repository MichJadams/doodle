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
HUD_LABELS     := [?]string{"L-TRIGGER", "DEFAULT", "R-TRIGGER"}

State :: enum { Menu, Editor, Radial }

Doc :: struct {
	has_package:  bool,
	package_name: string,
}

RadialMenu :: struct {
	title:   string,
	options: []string,
	index:   int,
	level:   int, // 0 = root, 1 = file-setup submenu
}

App :: struct {
	state:      State,
	menu_index: int,
	doc:        Doc,
	radial:     RadialMenu,

	lt, rt:         f32,
	key_lt, key_rt: bool,

	e_confirm, e_cancel:            bool,
	e_up, e_down, e_left, e_right:  bool,
	want_quit:                      bool,
	time:                           f64,
}

main :: proc() {
	win, ok := platform.init("Olympus IDE", WINDOW_W, WINDOW_H)
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

	font := load_a_font(r)
	if font == nil {
		fmt.eprintln("could not load any font")
		return
	}
	defer text.shutdown(font)

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

load_a_font :: proc(r: ^gpu.Renderer) -> ^text.Font {
	paths := [?]string{
		"assets/fonts/mono.ttf",
		"C:\\Windows\\Fonts\\consola.ttf",
		"C:\\Windows\\Fonts\\segoeui.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	}
	for p in paths {
		if f, ok := text.load_font(r, p, 28); ok do return f
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
	switch app.state {
	case .Menu:
		n := len(MENU_ITEMS)
		if app.e_up   do app.menu_index = (app.menu_index + n - 1) %% n
		if app.e_down do app.menu_index = (app.menu_index + 1) %% n
		if app.e_confirm {
			if app.menu_index == 0 { // New Project
				app.doc = Doc{}
				app.state = .Editor
			}
			// Recent / Open Folder: not wired yet.
		}
	case .Editor:
		if app.e_cancel  do app.state = .Menu
		if app.e_confirm do open_radial_root(app)
	case .Radial:
		n := len(app.radial.options)
		if app.e_left || app.e_up    do app.radial.index = (app.radial.index + n - 1) %% n
		if app.e_right || app.e_down do app.radial.index = (app.radial.index + 1) %% n
		if app.e_cancel {
			if app.radial.level == 1 do open_radial_root(app)
			else do app.state = .Editor
		}
		if app.e_confirm do radial_select(app)
	}
}

open_radial_root :: proc(app: ^App) {
	app.state = .Radial
	app.radial.level = 0
	app.radial.index = 0
	app.radial.title = "Add  (insertion point)"
	app.radial.options = ROOT_OPTS[:]
}

radial_select :: proc(app: ^App) {
	if app.radial.level == 0 {
		switch app.radial.index {
		case 0: // File Setup -> submenu
			app.radial.level = 1
			app.radial.index = 0
			app.radial.title = "File Setup"
			app.radial.options = FILESETUP_OPTS[:]
		case:
			app.state = .Editor // other branches not implemented yet
		}
	} else { // File Setup submenu
		switch app.radial.index {
		case 0: // Package declaration
			app.doc.has_package = true
			app.doc.package_name = "main"
			app.state = .Editor
		case:
			app.state = .Editor
		}
	}
}

// ---------------- Rendering ----------------

draw_menu :: proc(r: ^gpu.Renderer, font: ^text.Font, app: ^App, w, h: int) {
	fw, fh := f32(w), f32(h)
	text.draw_centered(r, font, {0, fh * 0.20, fw, 60}, "OLYMPUS", COL_ACCENT)
	text.draw_centered(r, font, {0, fh * 0.20 + 56, fw, 30}, "Odin IDE  -  gamepad native", COL_DIM)

	base_y := fh * 0.42
	for item, i in MENU_ITEMS {
		row := gpu.Rect{fw * 0.5 - 220, base_y + f32(i) * 72, 440, 56}
		active := i == app.menu_index
		enabled := i == 0
		gpu.draw_rect(r, row, active ? COL_HILITE : COL_PANEL)
		if active do gpu.draw_rect_outline(r, row, 2, COL_ACCENT)
		text.draw_centered(r, font, row, item, enabled ? COL_TEXT : COL_DIM)
	}

	text.draw_centered(r, font, {0, fh * 0.84, fw, 30},
		"D-pad / Arrows to move    A / Enter to select    (only New Project is wired)", COL_DIM)
}

draw_editor :: proc(r: ^gpu.Renderer, font: ^text.Font, app: ^App, w, h: int) {
	pad := f32(28)
	text.draw_line(r, font, {pad, 14}, "untitled.odin", COL_DIM)
	gpu.draw_rect(r, {0, 50, f32(w), 1}, {0.2, 0.22, 0.27, 1})

	y := f32(96)
	x := pad + 34
	if app.doc.has_package {
		line := fmt.tprintf("package %s", app.doc.package_name)
		text.draw_line(r, font, {x, y}, line, COL_TEXT)
		draw_green_dot(r, app, pad + 14, y + 58)
		text.draw_line(r, font, {x, y + 48}, "(next insertion point)", COL_DIM)
	} else {
		draw_green_dot(r, app, pad + 14, y + 16)
		text.draw_line(r, font, {x, y}, "press  A  on the glowing dot to add something", COL_DIM)
	}
}

draw_green_dot :: proc(r: ^gpu.Renderer, app: ^App, cx, cy: f32) {
	pulse := 0.5 + 0.5 * math.sin(f32(app.time) * 3.0)
	radius := 9.0 + 3.0 * pulse
	gpu.draw_circle(r, cx, cy, radius + 9, {0.20, 0.90, 0.45, 0.18 + 0.20 * pulse})
	gpu.draw_circle(r, cx, cy, radius, {0.25, 0.95, 0.50, 1})
}

draw_radial :: proc(r: ^gpu.Renderer, font: ^text.Font, app: ^App, w, h: int) {
	fw, fh := f32(w), f32(h)
	gpu.draw_rect(r, {0, 0, fw, fh}, {0, 0, 0, 0.55})

	cx, cy := fw * 0.5, fh * 0.5
	text.draw_centered(r, font, {0, cy - 200, fw, 36}, app.radial.title, COL_ACCENT)

	n := len(app.radial.options)
	radius := f32(165)
	for opt, i in app.radial.options {
		ang := -math.PI * 0.5 + f32(i) * (2 * math.PI / f32(n))
		ox := cx + math.cos(ang) * radius
		oy := cy + math.sin(ang) * radius
		box := gpu.Rect{ox - 95, oy - 26, 190, 52}
		active := i == app.radial.index
		gpu.draw_rect(r, box, active ? COL_HILITE : COL_PANEL)
		if active do gpu.draw_rect_outline(r, box, 2, COL_ACCENT)
		text.draw_centered(r, font, box, opt, COL_TEXT)
	}
	text.draw_centered(r, font, {cx - 120, cy - 15, 240, 30}, "A: select   B: back", COL_DIM)
}

draw_hud :: proc(r: ^gpu.Renderer, font: ^text.Font, app: ^App, w, h: int) {
	active_bank := 1
	lt_on := app.lt > 0.5 || app.key_lt
	rt_on := app.rt > 0.5 || app.key_rt
	if lt_on      do active_bank = 0
	else if rt_on do active_bank = 2

	fw := f32(w)
	hud_h := f32(150)
	top := f32(h) - hud_h
	gpu.draw_rect(r, {0, top, fw, hud_h}, {0.11, 0.12, 0.15, 1})
	gpu.draw_rect(r, {0, top, fw, 2}, {0.20, 0.22, 0.27, 1})

	third := fw / 3.0
	cy := top + hud_h * 0.46
	for bank in 0 ..< 3 {
		cx := third * (f32(bank) + 0.5)
		active := bank == active_bank
		draw_bank(r, font, cx, cy, active ? 1.15 : 0.82, active)
		text.draw_centered(r, font, {cx - 100, top + hud_h - 30, 200, 24},
			HUD_LABELS[bank], active ? COL_ACCENT : COL_DIM)
	}
}

draw_bank :: proc(r: ^gpu.Renderer, font: ^text.Font, cx, cy, scale: f32, active: bool) {
	a := active ? f32(1.0) : f32(0.5)
	dpad_cx := cx - 82 * scale
	face_cx := cx + 82 * scale

	// D-pad plus
	arm := 46.0 * scale
	th := 26.0 * scale
	dcol := gpu.Color{0.75, 0.77, 0.82, a}
	gpu.draw_rect(r, {dpad_cx - th / 2, cy - arm / 2, th, arm}, dcol)
	gpu.draw_rect(r, {dpad_cx - arm / 2, cy - th / 2, arm, th}, dcol)

	// Face buttons (Y top, A bottom, X left, B right)
	d := 32.0 * scale
	rad := 16.0 * scale
	draw_face(r, font, face_cx, cy - d, rad, {0.92, 0.78, 0.25, a}, "Y")
	draw_face(r, font, face_cx, cy + d, rad, {0.30, 0.78, 0.42, a}, "A")
	draw_face(r, font, face_cx - d, cy, rad, {0.28, 0.52, 0.90, a}, "X")
	draw_face(r, font, face_cx + d, cy, rad, {0.86, 0.30, 0.30, a}, "B")
}

draw_face :: proc(r: ^gpu.Renderer, font: ^text.Font, cx, cy, rad: f32, col: gpu.Color, label: string) {
	gpu.draw_circle(r, cx, cy, rad, col)
	text.draw_centered(r, font, {cx - rad, cy - rad, rad * 2, rad * 2}, label, {0.08, 0.09, 0.11, 1})
}

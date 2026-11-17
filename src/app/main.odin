package main

import "../platform"
import "../gpu"
import "../text"

// Integration layer: wires packages together and runs the main loop.
// Owner: Integrator.  Contract: ARCHITECTURE.md §6

WINDOW_W :: 1280
WINDOW_H :: 800 // matches Steam Deck native resolution

main :: proc() {
	win, ok := platform.init("Olympus IDE", WINDOW_W, WINDOW_H)
	if !ok do return
	defer platform.shutdown(win)

	r, rok := gpu.init(win)
	if !rok do return
	defer gpu.shutdown(r)

	font, fok := text.load_font(r, "assets/fonts/mono.ttf", 18)
	if !fok do return
	defer text.shutdown(font)

	events: [dynamic]platform.Event
	defer delete(events)

	running := true
	for running {
		clear(&events)
		platform.poll_events(win, &events)
		for e in events {
			#partial switch _ in e {
			case platform.Quit_Event:
				running = false
			}
		}

		w, h := platform.get_size(win)
		gpu.begin_frame(r, w, h, {0.09, 0.10, 0.12, 1.0})
		// TODO: draw file tree, editor view (visible_lines), status bar, HUD.
		text.draw_line(r, font, {16, 16}, "Olympus IDE - scaffold", {0.9, 0.9, 0.95, 1.0})
		gpu.end_frame(r)
		platform.present(win)
	}
}

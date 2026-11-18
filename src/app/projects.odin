package main

// Main menu -> Recent Projects: pick a previously saved project and open it.
// Scanning lives in model.list_projects (unit-tested); this file is input + drawing.

import "../model"
import "../gpu"
import "../text"
import "core:fmt"
import "core:strings"
import "core:time"

g_proj_open:  bool            // project picker overlay is active
g_proj_index: int             // selected row
g_proj_list:  []model.Project // scanned on open, newest first

// projects_open rescans the projects folder and shows the picker.
projects_open :: proc() {
	ensure_projects_dir()
	if g_proj_list != nil do model.free_projects(g_proj_list)
	g_proj_list = model.list_projects(g_projects_dir)
	g_proj_index = 0
	g_proj_open = true
}

projects_close :: proc() {
	g_proj_open = false
	if g_proj_list != nil {
		model.free_projects(g_proj_list)
		g_proj_list = nil
	}
}

// open_project loads the project's file into the editor and makes it the
// current project (save target, run cwd, file-nav start folder).
open_project :: proc(p: model.Project) {
	filenav_open_file(p.file) // loads into the editor, sets project dir + current file
	if g_fn_dir != "" do delete(g_fn_dir)
	g_fn_dir = strings.clone(p.dir)
	set_status(fmt.tprintf("opened %s", p.name))
}

// handle_projects_input: Up/Down move (wrapping), A opens, B goes back to the menu.
// Consumes the edges it uses.
handle_projects_input :: proc(raw: ^Raw) {
	n := len(g_proj_list)
	if n > 0 {
		if raw.e_up   do g_proj_index = (g_proj_index - 1 + n) % n
		if raw.e_down do g_proj_index = (g_proj_index + 1) % n
	}
	raw.e_up = false; raw.e_down = false; raw.e_left = false; raw.e_right = false

	if raw.e_confirm || raw.e_a {
		if g_proj_index >= 0 && g_proj_index < n {
			p := g_proj_list[g_proj_index]
			open_project(p) // copies what it needs before the list is freed
		}
		projects_close()
		raw.e_confirm = false; raw.e_a = false
	}
	if raw.e_cancel || raw.e_b {
		projects_close()
		raw.e_cancel = false; raw.e_b = false
	}
}

draw_projects_overlay :: proc(r: ^gpu.Renderer, w, h: int) {
	fw, fh := f32(w), f32(h)
	gpu.draw_rect(r, {0, 0, fw, fh}, {0, 0, 0, 0.75})
	text.draw_centered(r, g_ui, {0, fh * 0.07, fw, 36}, "RECENT PROJECTS", COL_ACCENT)

	n := len(g_proj_list)
	if n == 0 {
		text.draw_centered(r, g_ui, {0, fh * 0.35, fw, 30},
			fmt.tprintf("No saved projects in %s yet - save one with RT+Y", g_projects_dir), COL_DIM)
		text.draw_centered(r, g_ui, {0, f32(h) - 172, fw, 24}, "B back", COL_DIM)
		return
	}

	cellw := min(f32(720), fw - 80)
	cellh := f32(48)
	vgap := f32(8)
	start_x := (fw - cellw) * 0.5
	start_y := fh * 0.15
	bottom := f32(h) - 185 // leave room for the HUD + hint

	visible := max(1, int((bottom - start_y) / (cellh + vgap)))
	// Scroll so the selection stays visible (roughly centered).
	first := clamp(g_proj_index - visible / 2, 0, max(0, n - visible))

	now := time.now()
	for i in first ..< min(first + visible, n) {
		p := g_proj_list[i]
		y := start_y + f32(i - first) * (cellh + vgap)
		box := gpu.Rect{start_x, y, cellw, cellh}
		active := i == g_proj_index
		gpu.draw_rect(r, box, active ? COL_HILITE : COL_PANEL)
		if active do gpu.draw_rect_outline(r, box, 2, COL_ACCENT)

		age := model.age_label(p.mtime, now)
		age_w := text.measure(g_ui, age).x
		text.draw_line(r, g_ui, {box.x + 16, y + 12}, fit_label(g_ui, p.name, cellw - age_w - 56), COL_TEXT)
		text.draw_line(r, g_ui, {box.x + cellw - age_w - 16, y + 12}, age, COL_DIM)
	}

	if first > 0 do text.draw_centered(r, g_ui, {0, start_y - 26, fw, 22}, "^ more", COL_DIM)
	if first + visible < n do text.draw_centered(r, g_ui, {0, bottom + 2, fw, 22}, "v more", COL_DIM)
	hint := fmt.tprintf("%d / %d     D-pad move   A open   B back", g_proj_index + 1, n)
	text.draw_centered(r, g_ui, {0, f32(h) - 172, fw, 24}, hint, COL_DIM)
}

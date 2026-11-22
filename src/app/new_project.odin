package main

// Main menu -> New Project: where should it go?
//
//   In default folder        <the DoodleProjects folder>
//   In <folder>              <an added folder>          (X twice: remove it from the list)
//   + Add another folder...  browse to a folder and add it to the list
//
// The list is saved in doodle_roots.txt (roots_store.odin), so added folders
// stay. "Add another folder" opens a folder browser that starts next to the
// default folder:
//
//   D-pad Up/Down  move          A / Right  open the folder
//   Left           up a level    A on "Use this folder"  add it
//   B              back to the list (on Windows, above a drive root are the drives)

import "../gpu"
import "../model"
import "../text"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

g_np_open:   bool // the "where?" list is showing
g_np_index:  int  // 0 = default folder, 1..len(g_roots) = added folders, then "+ Add another folder"
g_np_remove: int  // row waiting for a second X to remove it (0 = none)

// The folder browser ("+ Add another folder").
g_np_browsing: bool
g_np_dir:      string           // the folder shown (owned); "" = the drive list (Windows)
g_np_rows:     [dynamic]Np_Row  // what's listed (strings owned)
g_np_bindex:   int

Np_Row :: struct {
	label: string,
	path:  string,
	use:   bool, // "Use this folder" (adds g_np_dir)
}

// The rows of the list: the default folder, the added ones, then "add".
@(private = "file")
np_count :: proc() -> int { return len(g_roots) + 2 }
@(private = "file")
np_add_row :: proc() -> int { return len(g_roots) + 1 }

// np_root: the folder for list row i ("" for the "add" row).
@(private = "file")
np_root :: proc(i: int) -> string {
	if i == 0 do return g_projects_dir
	if i >= 1 && i <= len(g_roots) do return g_roots[i - 1]
	return ""
}

new_project_open :: proc() {
	ensure_projects_dir()
	g_np_open = true
	g_np_index = 0
	g_np_remove = 0
	np_browse_close()
}

new_project_close :: proc() {
	np_browse_close()
	g_np_open = false
	g_np_remove = 0
}

// new_project_start: an empty document in the editor, saved (on the first save)
// in a new randomly named folder under `root`.
@(private = "file")
new_project_start :: proc(m: ^model.App, root: string) {
	r := strings.clone(root, context.temp_allocator)
	new_project_close()
	model.new_project(m)
	new_project_setup(r)
}

// handle_new_project_input owns all input while the list (or the browser) is
// open. Consumes the edges it uses.
handle_new_project_input :: proc(m: ^model.App, raw: ^Raw) {
	defer {
		raw.e_confirm = false; raw.e_a = false; raw.e_cancel = false; raw.e_b = false
		raw.e_up = false; raw.e_down = false; raw.e_left = false; raw.e_right = false
		raw.e_x = false; raw.e_y = false
	}
	if g_np_browsing {
		np_browse_input(raw)
		return
	}

	n := np_count()
	if raw.e_up   { g_np_index = (g_np_index - 1 + n) % n; g_np_remove = 0 }
	if raw.e_down { g_np_index = (g_np_index + 1) % n; g_np_remove = 0 }

	switch {
	case raw.e_cancel || raw.e_b:
		new_project_close()
	case raw.e_confirm || raw.e_a:
		g_np_remove = 0
		if g_np_index == np_add_row() {
			np_browse_open()
			return
		}
		root := np_root(g_np_index)
		if g_np_index > 0 && !os.is_dir(root) {
			set_status(fmt.tprintf("folder not found: %s", root))
			return
		}
		new_project_start(m, root)
	case raw.e_x:
		// X on an added folder: asks; X again removes it from the list (the
		// folder and its projects stay on disk).
		if g_np_index < 1 || g_np_index > len(g_roots) do return
		if g_np_remove != g_np_index {
			g_np_remove = g_np_index
			return
		}
		msg := fmt.tprintf("removed %s from the list", g_roots[g_np_index - 1])
		model.roots_remove(&g_roots, g_np_index - 1)
		set_status(np_saved_note(msg, roots_store_save()))
		g_np_remove = 0
		g_np_index = min(g_np_index, np_count() - 1)
	}
}

// --- The folder browser ---

@(private = "file")
np_browse_open :: proc() {
	start := filepath.dir(g_projects_dir) // next to the default folder (the home folder)
	if abs, err := os.get_absolute_path(start, context.temp_allocator); err == nil do start = abs
	g_np_browsing = true
	np_browse_show(start, "")
}

@(private = "file")
np_browse_close :: proc() {
	g_np_browsing = false
	np_free_rows()
	if g_np_dir != "" do delete(g_np_dir)
	g_np_dir = ""
	g_np_bindex = 0
}

@(private = "file")
np_free_rows :: proc() {
	for row in g_np_rows {
		delete(row.label)
		delete(row.path)
	}
	clear(&g_np_rows)
}

// np_browse_show lists `dir` ("" = the drives) and selects `focus` (a row's
// path), else the first row.
@(private = "file")
np_browse_show :: proc(dir, focus: string) {
	d := strings.clone(dir, context.temp_allocator) // dir / focus may point into the rows
	f := strings.clone(focus, context.temp_allocator)
	np_free_rows()
	if g_np_dir != "" do delete(g_np_dir)
	g_np_dir = d == "" ? "" : strings.clone(d)

	if d == "" {
		when ODIN_OS == .Windows {
			for c in 'A' ..= 'Z' {
				drive := fmt.tprintf("%c:/", c)
				if os.is_dir(drive) do append(&g_np_rows, Np_Row{strings.clone(drive), strings.clone(drive), false})
			}
		}
	} else {
		append(&g_np_rows, Np_Row{strings.clone("Use this folder"), strings.clone(d), true})
		fis, err := os.read_directory_by_path(d, -1, context.temp_allocator)
		if err == nil {
			subs := make([dynamic]os.File_Info, 0, len(fis), context.temp_allocator)
			for fi in fis {
				if fi.type != .Directory || strings.has_prefix(fi.name, ".") || strings.has_prefix(fi.name, "$") do continue
				append(&subs, fi)
			}
			slice.sort_by(subs[:], proc(a, b: os.File_Info) -> bool {
				return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator)
			})
			for fi in subs do append(&g_np_rows, Np_Row{strings.clone(fi.name), strings.clone(fi.fullpath), false})
		} else {
			set_status(fmt.tprintf("could not open %s", d))
		}
	}

	g_np_bindex = 0
	if f != "" {
		for row, i in g_np_rows do if !row.use && model.fgrid_same(row.path, f) {
			g_np_bindex = i
			break
		}
	}
}

// np_browse_up: the parent folder, with the folder we came from selected. On
// Windows, above a drive root are the drives.
@(private = "file")
np_browse_up :: proc() {
	if g_np_dir == "" do return
	from := strings.clone(g_np_dir, context.temp_allocator)
	if parent, ok := model.fgrid_parent_of(from); ok {
		np_browse_show(parent, from)
		return
	}
	when ODIN_OS == .Windows do np_browse_show("", from)
}

@(private = "file")
np_browse_input :: proc(raw: ^Raw) {
	n := len(g_np_rows)
	if n > 0 {
		if raw.e_up   do g_np_bindex = (g_np_bindex - 1 + n) % n
		if raw.e_down do g_np_bindex = (g_np_bindex + 1) % n
	}
	switch {
	case raw.e_cancel || raw.e_b:
		np_browse_close()
	case raw.e_left:
		np_browse_up()
	case (raw.e_confirm || raw.e_a || raw.e_right) && g_np_bindex >= 0 && g_np_bindex < n:
		row := g_np_rows[g_np_bindex]
		if !row.use {
			np_browse_show(row.path, "")
		} else if raw.e_confirm || raw.e_a {
			np_add_folder(row.path)
		}
	}
}

// np_add_folder adds `dir` to the list (and saves it), back on the list with
// that folder selected.
@(private = "file")
np_add_folder :: proc(dir: string) {
	d := strings.clone(dir, context.temp_allocator)
	np_browse_close()
	switch model.roots_add(&g_roots, d, g_projects_dir) {
	case .Added:
		saved := roots_store_save()
		g_np_index = len(g_roots)
		set_status(np_saved_note(fmt.tprintf("added %s", d), saved))
	case .Duplicate:
		g_np_index = model.roots_index(g_roots[:], d) + 1
		set_status("that folder is already in the list")
	case .Is_Default:
		g_np_index = 0
		set_status("that's the default folder")
	case .Empty:
	}
}

// np_saved_note: `msg`, plus a warning when the list couldn't be saved (so the
// change lasts only until Doodle closes). A replay never saves: no warning.
@(private = "file")
np_saved_note :: proc(msg: string, saved: bool) -> string {
	if saved || trace_replaying() do return msg
	return fmt.tprintf("%s (only until Doodle closes: doodle_roots.txt can't be saved)", msg)
}

// --- Drawing ---

draw_new_project_overlay :: proc(r: ^gpu.Renderer, w, h: int) {
	if g_np_browsing {
		draw_np_browser(r, w, h)
		return
	}
	fw, fh := f32(w), f32(h)
	gpu.draw_rect(r, {0, 0, fw, fh}, COL_VEIL)
	text.draw_centered(r, g_ui, {0, fh * 0.07, fw, 36}, "NEW PROJECT  -  WHERE?", COL_ACCENT)

	cellw := min(f32(820), fw - 80)
	cellh := f32(64)
	vgap := f32(8)
	start_x := (fw - cellw) * 0.5
	start_y := fh * 0.15
	bottom := f32(h) - 185 // leave room for the HUD + hint

	n := np_count()
	visible := max(1, int((bottom - start_y) / (cellh + vgap)))
	first := clamp(g_np_index - visible / 2, 0, max(0, n - visible))
	lh := text.line_height(g_ui)
	for i in first ..< min(first + visible, n) {
		y := start_y + f32(i - first) * (cellh + vgap)
		box := gpu.Rect{start_x, y, cellw, cellh}
		active := i == g_np_index
		gpu.draw_rect(r, box, active ? COL_HILITE : COL_PANEL)
		if active do gpu.draw_rect_outline(r, box, 2, g_np_remove == i ? COL_ERR : COL_ACCENT)

		if i == np_add_row() {
			draw_icon(r, .Add, box.x + 28, y + cellh * 0.5, 24, COL_ACCENT)
			text.draw_line(r, g_ui, {box.x + 52, y + (cellh - lh) * 0.5}, "Add another folder...", COL_TEXT)
			continue
		}
		root := np_root(i)
		label := i == 0 ? "In default folder" : fmt.tprintf("In %s", model.fgrid_title(root))
		text.draw_line(r, g_ui, {box.x + 16, y + 6}, fit_label(g_ui, label, cellw - 32), COL_TEXT)
		place := root
		col := COL_DIM
		if i > 0 && g_np_remove == i {
			place = "press X again to remove it from the list (the folder stays on disk)"
			col = COL_ERR
		} else if i > 0 && !os.is_dir(root) {
			place = fmt.tprintf("%s  (not found)", root)
			col = COL_WARN
		}
		text.draw_line(r, g_ui, {box.x + 16, y + 6 + lh}, fit_label(g_ui, place, cellw - 32), col)
	}

	if first > 0 do text.draw_centered(r, g_ui, {0, start_y - 26, fw, 22}, "^ more", COL_DIM)
	if first + visible < n do text.draw_centered(r, g_ui, {0, bottom + 2, fw, 22}, "v more", COL_DIM)
	hint := "D-pad move   A create the project here   B back"
	if g_np_index == np_add_row() do hint = "D-pad move   A pick a folder to add   B back"
	else if g_np_index > 0 do hint = "D-pad move   A create the project here   X remove from list   B back"
	text.draw_centered(r, g_ui, {0, f32(h) - 172, fw, 24}, hint, COL_DIM)
}

@(private = "file")
draw_np_browser :: proc(r: ^gpu.Renderer, w, h: int) {
	fw, fh := f32(w), f32(h)
	gpu.draw_rect(r, {0, 0, fw, fh}, COL_VEIL)
	text.draw_centered(r, g_ui, {0, fh * 0.07, fw, 36}, "ADD A PROJECT FOLDER", COL_ACCENT)
	place := g_np_dir == "" ? "Drives" : g_np_dir
	text.draw_centered(r, g_ui, {40, fh * 0.07 + 36, fw - 80, 26}, fit_label(g_ui, place, fw - 80), COL_DIM)

	cellw := min(f32(720), fw - 80)
	cellh := f32(44)
	vgap := f32(6)
	start_x := (fw - cellw) * 0.5
	start_y := fh * 0.07 + 76
	bottom := f32(h) - 185

	n := len(g_np_rows)
	if n == 0 {
		text.draw_centered(r, g_ui, {0, fh * 0.35, fw, 30}, "Nothing here", COL_DIM)
	}
	visible := max(1, int((bottom - start_y) / (cellh + vgap)))
	first := clamp(g_np_bindex - visible / 2, 0, max(0, n - visible))
	lh := text.line_height(g_ui)
	for i in first ..< min(first + visible, n) {
		row := g_np_rows[i]
		y := start_y + f32(i - first) * (cellh + vgap)
		box := gpu.Rect{start_x, y, cellw, cellh}
		active := i == g_np_bindex
		gpu.draw_rect(r, box, active ? COL_HILITE : COL_PANEL)
		if active do gpu.draw_rect_outline(r, box, 2, COL_ACCENT)
		ty := y + (cellh - lh) * 0.5
		if row.use {
			draw_icon(r, .Add, box.x + 26, y + cellh * 0.5, 22, COL_ACCENT)
			text.draw_line(r, g_ui, {box.x + 48, ty}, fit_label(g_ui, fmt.tprintf("Use this folder (%s)", model.fgrid_title(row.path)), cellw - 64), COL_ACCENT)
		} else {
			text.draw_line(r, g_ui, {box.x + 16, ty}, fit_label(g_ui, fmt.tprintf("%s/", row.label), cellw - 32), COL_TEXT)
		}
	}

	if first > 0 do text.draw_centered(r, g_ui, {0, start_y - 24, fw, 22}, "^ more", COL_DIM)
	if first + visible < n do text.draw_centered(r, g_ui, {0, bottom + 2, fw, 22}, "v more", COL_DIM)
	hint := "D-pad move   A open folder   Left up a level   B cancel"
	if g_np_bindex >= 0 && g_np_bindex < n && g_np_rows[g_np_bindex].use do hint = "A add this folder   D-pad move   Left up a level   B cancel"
	text.draw_centered(r, g_ui, {0, f32(h) - 172, fw, 24}, hint, COL_DIM)
}

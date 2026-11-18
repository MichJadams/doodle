package main

// FILE NAVIGATION MODE: transparent file-tree overlay for opening/creating files.
// Activated by RT+B; overlays the editor with a directory listing.
// Controls: B exits, D-pad nav, A opens/enters, X creates, LT+X renames, Y searches.
// Alt-tab: RT+B while in file-nav swaps to previous file.

import "../gpu"
import "../text"
import "../model"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:path/filepath"
import "core:slice"

// --- Globals for file navigation state ---

g_filenav: bool = false // True when file-nav overlay is active.

g_fn_dir:   string      // Current directory being viewed.
g_fn_index: int = 0     // Selected entry index (cursor position).

g_current_file: string  // Path to currently open file (for saving / display).
g_prev_file:    string  // Previously opened file (for alt-tab).

// Directory entry for display.
Fn_Entry :: struct {
	name:   string,
	is_dir: bool,
	path:   string,
}

g_fn_entries: [dynamic]Fn_Entry // Current directory listing (sorted: dirs first, then files).

// Search state (Y button).
g_fn_search_active: bool   = false
g_fn_search_query:  string = ""

// --- File navigation lifecycle ---

// filenav_init initializes file-nav state on first activation.
filenav_init :: proc() {
	if g_fn_dir == "" {
		// Set initial directory: g_project_dir if set, else g_projects_dir, else current working dir.
		if g_project_dir != "" {
			g_fn_dir = g_project_dir
		} else if g_projects_dir != "" {
			g_fn_dir = g_projects_dir
		} else {
			// Fall back to current working directory (use ".").
			g_fn_dir = strings.clone(".")
		}
	}
	filenav_refresh_entries()
}

// filenav_refresh_entries reads the directory and populates g_fn_entries.
// TODO: implement actual directory reading using platform-specific APIs.
// For v1: stub implementation with placeholder entries.
filenav_refresh_entries :: proc() {
	clear(&g_fn_entries)
	
	// STUB: For v1, show placeholder entries to demonstrate the UI.
	// A full implementation would use Windows FindFirstFile/FindNextFile or
	// a portable Odin API once available.
	
	// Add a few example entries (mix of dirs and files).
	sep := os.Path_Separator
	
	// Try to add ".." parent directory.
	parent := filepath.dir(g_fn_dir)
	if parent != g_fn_dir {
		append(&g_fn_entries, Fn_Entry{
			name   = "..",
			is_dir = true,
			path   = parent,
		})
	}
	
	// Add some placeholder entries.
	append(&g_fn_entries, Fn_Entry{
		name   = "src",
		is_dir = true,
		path   = fmt.tprintf("%s%csrc", g_fn_dir, sep),
	})
	append(&g_fn_entries, Fn_Entry{
		name   = "bin",
		is_dir = true,
		path   = fmt.tprintf("%s%cbin", g_fn_dir, sep),
	})
	append(&g_fn_entries, Fn_Entry{
		name   = "main.odin",
		is_dir = false,
		path   = fmt.tprintf("%s%cmain.odin", g_fn_dir, sep),
	})
	append(&g_fn_entries, Fn_Entry{
		name   = "README.md",
		is_dir = false,
		path   = fmt.tprintf("%s%cREADME.md", g_fn_dir, sep),
	})
	
	// Clamp index to valid range.
	if g_fn_index >= len(g_fn_entries) do g_fn_index = max(0, len(g_fn_entries) - 1)
	if g_fn_index < 0 do g_fn_index = 0
}

// filenav_enter activates file-nav mode.
filenav_enter :: proc() {
	g_filenav = true
	filenav_init()
}

// filenav_exit deactivates file-nav mode.
filenav_exit :: proc() {
	g_filenav = false
	g_fn_search_active = false
	if g_fn_search_query != "" {
		delete(g_fn_search_query)
		g_fn_search_query = ""
	}
}

// --- Input handling ---

// handle_filenav processes input while file-nav mode is active.
// Called from main loop; suppresses normal editor input.
handle_filenav :: proc(m: ^model.App, raw: ^Raw, inp: model.Input) {
	// Search mode has priority (Y button activates search).
	if g_fn_search_active {
		handle_filenav_search(raw, inp)
		return
	}
	
	// Y: open search box.
	if raw.e_y {
		g_fn_search_active = true
		raw.e_y = false
		return
	}
	
	// B alone (without RT) exits file-nav mode.
	if raw.e_b && !inp.rt_held {
		filenav_exit()
		raw.e_b = false
		return
	}
	
	// RT + B: alt-tab to previous file.
	if raw.e_b && inp.rt_held {
		filenav_alt_tab()
		raw.e_b = false
		return
	}
	
	n := len(g_fn_entries)
	if n == 0 do return // Empty directory, no navigation possible.
	
	// D-pad Up/Down: move selection (with wrap).
	if raw.e_up {
		g_fn_index -= 1
		if g_fn_index < 0 do g_fn_index = n - 1
		raw.e_up = false
	}
	if raw.e_down {
		g_fn_index += 1
		if g_fn_index >= n do g_fn_index = 0
		raw.e_down = false
	}
	
	// D-pad Left: jump to parent directory.
	if raw.e_left {
		filenav_go_parent()
		raw.e_left = false
	}
	
	// A: enter directory or open file.
	if raw.e_confirm {
		if g_fn_index >= 0 && g_fn_index < n {
			entry := g_fn_entries[g_fn_index]
			if entry.is_dir {
				// Enter directory.
				if g_fn_dir != "" do delete(g_fn_dir)
				g_fn_dir = strings.clone(entry.path)
				g_fn_index = 0
				filenav_refresh_entries()
			} else {
				// Open file: set g_current_file and exit.
				// TODO: actually parse and load the file content into the editor (requires parser).
				filenav_open_file(entry.path)
				filenav_exit()
			}
		}
		raw.e_confirm = false
	}
	
	// X button disabled for v1: no edge detection in Raw struct.
	// TODO: add e_x to Raw struct for proper X button edge detection.
	// X: create new file or folder.
	// LT + X: rename selected file/folder.
}

// filenav_go_parent navigates to the parent directory of the currently selected entry.
filenav_go_parent :: proc() {
	parent := filepath.dir(g_fn_dir)
	if parent != g_fn_dir && parent != "" {
		if g_fn_dir != "" do delete(g_fn_dir)
		g_fn_dir = strings.clone(parent)
		g_fn_index = 0
		filenav_refresh_entries()
	}
}

// filenav_open_file sets the current file and updates alt-tab history.
filenav_open_file :: proc(path: string) {
	if g_current_file != "" {
		// Swap previous file.
		if g_prev_file != "" do delete(g_prev_file)
		g_prev_file = g_current_file
	} else if g_current_file != "" {
		delete(g_current_file)
	}
	g_current_file = strings.clone(path)
}

// filenav_alt_tab swaps to the previously opened file and exits file-nav.
filenav_alt_tab :: proc() {
	if g_prev_file != "" {
		// Swap current and previous.
		tmp := g_current_file
		g_current_file = strings.clone(g_prev_file)
		if g_prev_file != "" do delete(g_prev_file)
		g_prev_file = tmp
		filenav_exit()
	}
	// If no previous file, do nothing (or could beep/show message).
}

// filenav_create_new shows a simple submenu for creating a new file or folder.
// For v1: create with a generated default name (e.g. "new_file.odin", "new_folder").
filenav_create_new :: proc() {
	// TODO: implement a submenu or inline choice (file vs folder).
	// For v1 simplicity: create a new file with a generated name.
	base := "new_file.odin"
	sep := os.Path_Separator
	path := fmt.tprintf("%s%c%s", g_fn_dir, sep, base)
	
	// De-duplicate if the name already exists.
	counter := 1
	for os.exists(path) {
		base = fmt.tprintf("new_file_%d.odin", counter)
		path = fmt.tprintf("%s%c%s", g_fn_dir, sep, base)
		counter += 1
	}
	
	// Create an empty file.
	err := os.write_entire_file(path, []byte{})
	if err == nil {
		filenav_refresh_entries()
		// Select the newly created file.
		for entry, i in g_fn_entries {
			if entry.name == base {
				g_fn_index = i
				break
			}
		}
	}
}

// filenav_rename renames the selected file/folder.
// For v1: rename to a generated new name (e.g. "renamed_<original>").
// TODO: implement an editable overlay for user-specified names.
filenav_rename :: proc(entry: Fn_Entry) {
	// Generate a new name: prepend "renamed_" to the original.
	new_name := fmt.tprintf("renamed_%s", entry.name)
	sep := os.Path_Separator
	new_path := fmt.tprintf("%s%c%s", g_fn_dir, sep, new_name)
	
	// De-duplicate if the name already exists.
	counter := 1
	for os.exists(new_path) {
		new_name = fmt.tprintf("renamed_%s_%d", entry.name, counter)
		new_path = fmt.tprintf("%s%c%s", g_fn_dir, sep, new_name)
		counter += 1
	}
	
	// Rename the file/folder.
	err := os.rename(entry.path, new_path)
	if err == nil {
		filenav_refresh_entries()
		// Try to re-select the renamed entry.
		for e, i in g_fn_entries {
			if e.name == new_name {
				g_fn_index = i
				break
			}
		}
	}
}

// --- Search handling (Y button) ---

// handle_filenav_search processes input while the search box is active.
// For v1: a simple text filter overlay. Speech input is a TODO.
handle_filenav_search :: proc(raw: ^Raw, inp: model.Input) {
	// B exits search mode.
	if raw.e_b {
		g_fn_search_active = false
		if g_fn_search_query != "" {
			delete(g_fn_search_query)
			g_fn_search_query = ""
		}
		raw.e_b = false
		return
	}
	
	// TODO: wire STT for speech input (begin/end dictation into g_fn_search_query).
	// For v1: search is a stub (empty query = show all entries).
	// A more complete implementation would filter g_fn_entries by g_fn_search_query.
}

// --- Rendering ---

// draw_filenav renders the file-nav overlay over the editor.
// Called after draw_editor in the main loop.
draw_filenav :: proc(r: ^gpu.Renderer, w, h: int) {
	if !g_filenav do return
	
	fw, fh := f32(w), f32(h)
	
	// Semi-transparent overlay background.
	gpu.draw_rect(r, {0, 0, fw, fh}, {0, 0, 0, 0.70})
	
	// Title bar.
	title := g_fn_dir != "" ? g_fn_dir : "(no directory)"
	text.draw_centered(r, g_ui, {0, fh * 0.06, fw, 36}, title, COL_ACCENT)
	
	// Search overlay (if active).
	if g_fn_search_active {
		search_y := fh * 0.14
		search_h := f32(50)
		gpu.draw_rect(r, {fw * 0.25, search_y, fw * 0.5, search_h}, COL_PANEL)
		gpu.draw_rect_outline(r, {fw * 0.25, search_y, fw * 0.5, search_h}, 2, COL_ACCENT)
		query_text := g_fn_search_query != "" ? g_fn_search_query : "(search - TODO: speech input)"
		text.draw_centered(r, g_ui, {fw * 0.25, search_y, fw * 0.5, search_h}, query_text, COL_TEXT)
		text.draw_centered(r, g_ui, {0, search_y + search_h + 10, fw, 24}, "Press B to close search", COL_DIM)
		return
	}
	
	// Directory listing (grid layout, similar to draw_radial).
	n := len(g_fn_entries)
	if n == 0 {
		text.draw_centered(r, g_ui, {0, fh * 0.40, fw, 36}, "(empty directory)", COL_DIM)
		text.draw_centered(r, g_ui, {0, fh * 0.46, fw, 24}, "X to create new file", COL_DIM)
		return
	}
	
	cols := 4 // Fixed column count for file listings.
	rows := (n + cols - 1) / cols
	
	margin := f32(60)
	gap := f32(14)
	cellw := (fw - 2 * margin - f32(cols - 1) * gap) / f32(cols)
	cellh := f32(50)
	vgap := f32(12)
	grid_w := f32(cols) * cellw + f32(cols - 1) * gap
	start_x := (fw - grid_w) * 0.5
	start_y := fh * 0.18
	bottom := fh - 200
	
	visible_rows := int((bottom - start_y) / (cellh + vgap))
	if visible_rows < 1 do visible_rows = 1
	
	sel_row := g_fn_index / cols
	first_row := sel_row - visible_rows / 2
	max_first := rows - visible_rows
	if max_first < 0 do max_first = 0
	if first_row > max_first do first_row = max_first
	if first_row < 0 do first_row = 0
	
	for row in first_row ..< min(first_row + visible_rows, rows) {
		for col in 0 ..< cols {
			i := row * cols + col
			if i >= n do break
			entry := g_fn_entries[i]
			x := start_x + f32(col) * (cellw + gap)
			y := start_y + f32(row - first_row) * (cellh + vgap)
			box := gpu.Rect{x, y, cellw, cellh}
			active := i == g_fn_index
			
			// Different colors for directories vs files.
			bg_col := active ? COL_HILITE : COL_PANEL
			text_col := entry.is_dir ? COL_ACCENT : COL_TEXT
			
			gpu.draw_rect(r, box, bg_col)
			if active do gpu.draw_rect_outline(r, box, 2, COL_ACCENT)
			
			// Prefix directories with "/" for clarity.
			label := entry.is_dir ? fmt.tprintf("/%s", entry.name) : entry.name
			text.draw_centered(r, g_ui, box, fit_label(g_ui, label, cellw - 10), text_col)
		}
	}
	
	// Scroll indicators.
	if first_row > 0 {
		text.draw_centered(r, g_ui, {0, start_y - 28, fw, 24}, "^ more", COL_DIM)
	}
	if first_row + visible_rows < rows {
		text.draw_centered(r, g_ui, {0, bottom + 4, fw, 24}, "v more", COL_DIM)
	}
	
	// Hint text.
	hint := fmt.tprintf("%d / %d  |  D-pad move  A open  X new  LT+X rename  Y search  B exit", g_fn_index + 1, n)
	text.draw_centered(r, g_ui, {0, fh - 190, fw, 26}, hint, COL_DIM)
	
	// Current file indicator (if set).
	if g_current_file != "" {
		info := fmt.tprintf("Current: %s", g_current_file)
		text.draw_centered(r, g_ui, {0, fh - 160, fw, 22}, info, COL_ACCENT)
	}
}

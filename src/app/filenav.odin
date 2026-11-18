package main

// FILE NAVIGATION MODE: transparent file-tree overlay for opening/creating files.
// Activated by RT+B; overlays the editor with a directory listing.
// Controls: B exits, D-pad nav, A opens/enters, X creates, LT+X renames, Y searches.
// Alt-tab: RT+B while in file-nav swaps to previous file.

import "../gpu"
import "../text"
import "../model"
import "../stt"
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

g_stt_e: ^stt.Engine = nil // STT engine from main (for search speech input).
g_app:   ^model.App = nil  // the editor doc (for loading an opened file into it).

// Directory entry for display.
Fn_Entry :: struct {
	name:   string,
	is_dir: bool,
	path:   string,
}

g_fn_entries: [dynamic]Fn_Entry // Current directory listing (sorted: dirs first, then files).

// Search state (Y button).
g_fn_search_active:    bool   = false
g_fn_search_query:     string = ""
g_fn_filtered:         [dynamic]Fn_Entry // Filtered entries during search.
g_fn_search_recording: bool   = false    // Recording speech for search query.

// --- File navigation lifecycle ---

// filenav_init initializes file-nav state on first activation.
filenav_init :: proc() {
	if g_fn_dir == "" {
		// Set initial directory: g_project_dir if set, else g_projects_dir, else current working dir.
		if g_project_dir != "" {
			g_fn_dir = strings.clone(g_project_dir)
		} else if g_projects_dir != "" {
			g_fn_dir = strings.clone(g_projects_dir)
		} else {
			// Fall back to current working directory.
			g_fn_dir = strings.clone(".")
		}
	}
	filenav_refresh_entries()
}

// filenav_refresh_entries reads the directory and populates g_fn_entries.
// Uses os.read_directory_by_path + os.is_dir for real disk reading.
filenav_refresh_entries :: proc() {
	// Free old entries
	for entry in g_fn_entries {
		if entry.name != "" do delete(entry.name)
		if entry.path != "" do delete(entry.path)
	}
	clear(&g_fn_entries)
	
	// Add ".." parent directory first
	parent := filepath.dir(g_fn_dir)
	if parent != g_fn_dir && parent != "" {
		append(&g_fn_entries, Fn_Entry{
			name   = strings.clone(".."),
			is_dir = true,
			path   = strings.clone(parent),
		})
	}
	
	// Read directory contents using method (b): os.read_directory_by_path
	fis, err := os.read_directory_by_path(g_fn_dir, -1, context.temp_allocator)
	if err == os.ERROR_NONE && len(fis) > 0 {
		// Separate directories and files
		dirs: [dynamic]os.File_Info
		files: [dynamic]os.File_Info
		defer delete(dirs)
		defer delete(files)
		
		for fi in fis {
			is_dir := os.is_dir(fi.fullpath)
			if is_dir {
				append(&dirs, fi)
			} else {
				append(&files, fi)
			}
		}
		
		// Sort directories by name
		slice.sort_by(dirs[:], proc(a, b: os.File_Info) -> bool {
			return strings.compare(a.name, b.name) < 0
		})
		
		// Sort files by name
		slice.sort_by(files[:], proc(a, b: os.File_Info) -> bool {
			return strings.compare(a.name, b.name) < 0
		})
		
		// Add directories first
		for fi in dirs {
			append(&g_fn_entries, Fn_Entry{
				name   = strings.clone(fi.name),
				is_dir = true,
				path   = strings.clone(fi.fullpath),
			})
		}
		
		// Then add files
		for fi in files {
			append(&g_fn_entries, Fn_Entry{
				name   = strings.clone(fi.name),
				is_dir = false,
				path   = strings.clone(fi.fullpath),
			})
		}
	} else if err != os.ERROR_NONE || len(fis) == 0 {
		// Empty or error: show (empty) message handled in render
	}
	
	// Clamp index to valid range
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
	g_fn_search_recording = false
	if g_fn_search_query != "" {
		delete(g_fn_search_query)
		g_fn_search_query = ""
	}
	// Free filtered entries
	for entry in g_fn_filtered {
		// Don't delete strings - they're references to g_fn_entries
	}
	clear(&g_fn_filtered)
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
		if g_fn_search_query != "" {
			delete(g_fn_search_query)
			g_fn_search_query = ""
		}
		filenav_apply_filter() // Start with all entries
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
	
	// X: create new file/folder (submenu).
	if raw.e_x && !inp.lt_held {
		filenav_create_new()
		raw.e_x = false
		return
	}
	
	// LT + X: rename selected file/folder.
	if raw.e_x && inp.lt_held && n > 0 {
		if g_fn_index >= 0 && g_fn_index < n {
			entry := g_fn_entries[g_fn_index]
			if entry.name != ".." { // Don't rename parent entry
				filenav_rename(entry)
			}
		}
		raw.e_x = false
		return
	}
	
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
				// TODO integrator wires model.load_file
				filenav_open_file(entry.path)
				filenav_exit()
			}
		}
		raw.e_confirm = false
	}
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
	if g_current_file != "" && g_current_file != path {
		// Remember the previous file for alt-tab.
		if g_prev_file != "" do delete(g_prev_file)
		g_prev_file = strings.clone(g_current_file)
	}
	filenav_load(path)
}

// filenav_load makes `path` the current file: loads it into the editor, and points
// the project (save target + run cwd) at the file's folder.
filenav_load :: proc(path: string) {
	set_current_file(path)
	set_project_dir(filepath.dir(path))
	// Load the opened file's content into the editor document.
	if g_app != nil {
		if model.load_file(g_app, path) {
			g_app.state = .Editor
		} else {
			set_status(fmt.tprintf("could not open %s", path))
		}
	}
}

// filenav_alt_tab swaps to the previously opened file and exits file-nav.
filenav_alt_tab :: proc() {
	if g_prev_file != "" {
		// Swap current and previous, and load the previous file into the editor.
		next := g_prev_file
		g_prev_file = g_current_file != "" ? strings.clone(g_current_file) : ""
		filenav_load(next)
		delete(next)
		filenav_exit()
	}
	// If no previous file, do nothing (or could beep/show message).
}

// filenav_create_new shows a simple submenu for creating a new file or folder.
// Toggles between file/folder with subsequent X presses.
// For v1: creates with generated default names.
filenav_create_new :: proc() {
	// Simple implementation: create a new file with a generated name.
	// TODO: add submenu or use A/B to choose file vs folder.
	base := "new_file.odin"
	sep := os.Path_Separator
	path_str := fmt.tprintf("%s%c%s", g_fn_dir, sep, base)
	defer delete(path_str)
	
	// De-duplicate if the name already exists.
	counter := 2
	for os.exists(path_str) {
		delete(path_str)
		base = fmt.tprintf("new_file_%d.odin", counter)
		path_str = fmt.tprintf("%s%c%s", g_fn_dir, sep, base)
		counter += 1
	}
	
	// Create an empty file.
	err := os.write_entire_file(path_str, []byte{})
	if err == os.ERROR_NONE {
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
// TODO: wire STT-based dictation for custom names.
filenav_rename :: proc(entry: Fn_Entry) {
	// Generate a new name: prepend "renamed_" to the original.
	new_name := fmt.tprintf("renamed_%s", entry.name)
	defer delete(new_name)
	sep := os.Path_Separator
	new_path := fmt.tprintf("%s%c%s", g_fn_dir, sep, new_name)
	defer delete(new_path)
	
	// De-duplicate if the name already exists.
	counter := 2
	for os.exists(new_path) {
		delete(new_name)
		delete(new_path)
		new_name = fmt.tprintf("renamed_%s_%d", entry.name, counter)
		new_path = fmt.tprintf("%s%c%s", g_fn_dir, sep, new_name)
		counter += 1
	}
	
	// Rename the file/folder using os.rename.
	err := os.rename(entry.path, new_path)
	if err == os.ERROR_NONE {
		filenav_refresh_entries()
		// Try to re-select the renamed entry.
		for e, i in g_fn_entries {
			if strings.contains(e.name, entry.name) {
				g_fn_index = i
				break
			}
		}
	}
}

// --- Search handling (Y button) ---

// handle_filenav_search processes input while the search box is active.
// Uses speech input via STT for query entry.
handle_filenav_search :: proc(raw: ^Raw, inp: model.Input) {
	// B exits search mode.
	if raw.e_b && !g_fn_search_recording {
		g_fn_search_active = false
		g_fn_search_recording = false
		if g_fn_search_query != "" {
			delete(g_fn_search_query)
			g_fn_search_query = ""
		}
		// Clear filter
		for entry in g_fn_filtered {
			// Strings are references; don't delete
		}
		clear(&g_fn_filtered)
		raw.e_b = false
		return
	}
	
	// X held: start speech recording for search query
	mic_hold := raw.x_held
	if mic_hold && !g_fn_search_recording && g_stt_e != nil {
		// Start recording
		stt.set_free_text(g_stt_e, true) // Free text for search
		stt.set_context(g_stt_e, "", nil)
		stt.begin(g_stt_e)
		g_fn_search_recording = true
	}
	
	// X released: end recording and update query
	if !mic_hold && g_fn_search_recording && g_stt_e != nil {
		result := stt.end(g_stt_e)
		defer delete(result)
		if result != "" {
			if g_fn_search_query != "" do delete(g_fn_search_query)
			g_fn_search_query = strings.clone(result)
			filenav_apply_filter()
		}
		g_fn_search_recording = false
	}
	
	// Navigate filtered results with D-pad
	n := len(g_fn_filtered)
	if n > 0 {
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
		
		// A: open selected filtered entry
		if raw.e_confirm {
			if g_fn_index >= 0 && g_fn_index < n {
				entry := g_fn_filtered[g_fn_index]
				if entry.is_dir {
					// Enter directory
					if g_fn_dir != "" do delete(g_fn_dir)
					g_fn_dir = strings.clone(entry.path)
					g_fn_index = 0
					g_fn_search_active = false
					if g_fn_search_query != "" {
						delete(g_fn_search_query)
						g_fn_search_query = ""
					}
					clear(&g_fn_filtered)
					filenav_refresh_entries()
				} else {
					// Open file
					// TODO integrator wires model.load_file
					filenav_open_file(entry.path)
					g_fn_search_active = false
					if g_fn_search_query != "" {
						delete(g_fn_search_query)
						g_fn_search_query = ""
					}
					clear(&g_fn_filtered)
					filenav_exit()
				}
			}
			raw.e_confirm = false
		}
	}
}

// filenav_apply_filter filters g_fn_entries by g_fn_search_query (case-insensitive).
filenav_apply_filter :: proc() {
	// Clear filtered list (don't delete strings - they're references)
	clear(&g_fn_filtered)
	
	if g_fn_search_query == "" {
		// Empty query: show all entries except ".."
		for entry in g_fn_entries {
			if entry.name != ".." {
				append(&g_fn_filtered, entry)
			}
		}
	} else {
		// Filter by case-insensitive substring match
		query_lower := strings.to_lower(g_fn_search_query, context.temp_allocator)
		for entry in g_fn_entries {
			if entry.name == ".." do continue
			name_lower := strings.to_lower(entry.name, context.temp_allocator)
			if strings.contains(name_lower, query_lower) {
				append(&g_fn_filtered, entry)
			}
		}
	}
	
	// Reset index
	g_fn_index = 0
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
		query_text := g_fn_search_query != "" ? g_fn_search_query : "(hold X to speak query)"
		if g_fn_search_recording {
			query_text = "Listening..."
		}
		text.draw_centered(r, g_ui, {fw * 0.25, search_y, fw * 0.5, search_h}, query_text, COL_TEXT)
		
		// Show filtered results count
		count_text := fmt.tprintf("%d results", len(g_fn_filtered))
		text.draw_centered(r, g_ui, {0, search_y + search_h + 10, fw, 24}, count_text, COL_DIM)
		text.draw_centered(r, g_ui, {0, search_y + search_h + 36, fw, 24}, "B to close search", COL_DIM)
		
		// Draw filtered entries
		filenav_draw_entries(r, w, h, g_fn_filtered[:])
		return
	}
	
	// Draw regular directory listing
	filenav_draw_entries(r, w, h, g_fn_entries[:])
}

// filenav_draw_entries renders a list of entries (used for both normal and search views).
filenav_draw_entries :: proc(r: ^gpu.Renderer, w, h: int, entries: []Fn_Entry) {
	fw, fh := f32(w), f32(h)
	n := len(entries)
	
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
			entry := entries[i]
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

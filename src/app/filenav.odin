package main

// FILE NAVIGATION (RT+B): a grid of folders, one column each (files, then closed
// subfolders as boxes), so files are walked like a grid while it stays clear which
// folder each belongs to. The grid itself lives in model/file_grid.odin.
//
//   D-pad     move (Left at the first column = up a level)
//   A         open a file / drop into a folder (it and its sister folders become the columns)
//   B         up a level (after dropping in), else back to the editor
//   X         new file     LT+X  rename
//   LT+B      delete the highlighted file/folder (asks first; goes to the Recycle Bin)
//   Y         search all files under the root (hold X to say the name)
//   RT+B      switch to the previous file

import "../gpu"
import "../text"
import "../model"
import "../stt"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:path/filepath"
import "core:slice"

// --- State ---

g_filenav: bool = false // file navigation is showing

g_fn_dir:   string // the root folder (search looks under it; going up past it moves it)
g_fn_index: int    // the cursor in g_fn_entries (or in g_fn_filtered while searching)

g_current_file: string // Path to currently open file (for saving / display).
g_file_loads:   int    // counts filenav_load calls
g_prev_file:    string // Previously opened file (for alt-tab).

g_stt_e: ^stt.Engine = nil // STT engine from main (for search speech input).
g_app:   ^model.App = nil  // the editor doc (for loading an opened file into it).

// One row of the flat list: a column tab (is_dir, depth 0) or a cell (depth 1).
Fn_Entry :: struct {
	name:   string,
	path:   string,
	is_dir: bool,
	depth:  int,
}

// Delete confirmation (LT+B): the path waiting for A ("" = none). Owned.
g_fn_delete:       string
g_fn_delete_is_dir: bool
g_fn_delete_count:  int // for a folder: how many files are in it

// The grid in reading order (tab, its cells, next tab, ...; strings owned).
// Drawing uses g_fn_grid; this flat copy is what trace.odin lists and fingerprints.
g_fn_entries: [dynamic]Fn_Entry

g_fn_grid:      model.File_Grid
g_fn_first_grp: int // first column shown (sideways scroll, whole columns; display only)
g_fn_first_row: int // first row shown (shared by all columns; display only)

// Search state (Y).
g_fn_search_active:    bool   = false
g_fn_search_query:     string = ""
g_fn_filtered:         [dynamic]Fn_Entry // matches (strings owned; name = path relative to the root)
g_fn_search_recording: bool   = false

FN_MAX_DEPTH   :: 12
FN_MAX_RESULTS :: 400

// --- Paths ---

// A path for comparisons: forward slashes, lower case (Windows is case-insensitive).
@(private = "file")
norm_path :: proc(p: string) -> string {
	s, _ := strings.replace_all(p, "\\", "/", context.temp_allocator)
	return strings.to_lower(strings.trim_right(s, "/"), context.temp_allocator)
}

@(private = "file")
same_path :: proc(a, b: string) -> bool { return norm_path(a) == norm_path(b) }

// Is `path` in the open document's package folder (its siblings' folder;
// save.odin refresh_siblings)?
@(private = "file")
in_sibling_folder :: proc(path: string) -> bool {
	dir := g_current_file != "" ? filepath.dir(g_current_file) : g_project_dir
	return dir != "" && same_path(filepath.dir(path), dir)
}

// A folder's contents: folders first, then files, each A-Z. Hidden (".") entries
// are skipped. Temp-allocated. (Search walks with it.)
@(private = "file")
list_dir :: proc(dir: string) -> []Fn_Entry {
	out := make([dynamic]Fn_Entry, 0, 16, context.temp_allocator)
	fis, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return out[:]
	for fi in fis {
		if strings.has_prefix(fi.name, ".") do continue
		append(&out, Fn_Entry{name = fi.name, path = fi.fullpath, is_dir = fi.type == .Directory})
	}
	slice.sort_by(out[:], proc(a, b: Fn_Entry) -> bool {
		if a.is_dir != b.is_dir do return a.is_dir
		return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator)
	})
	return out[:]
}

@(private = "file")
free_rows :: proc(rows: ^[dynamic]Fn_Entry) {
	for e in rows {
		delete(e.name)
		delete(e.path)
	}
	clear(rows)
}

// --- The grid ---

// fn_sync mirrors the grid into g_fn_entries / g_fn_index (trace.odin reads them).
@(private = "file")
fn_sync :: proc(rebuild: bool) {
	if rebuild {
		free_rows(&g_fn_entries)
		for grp in g_fn_grid.groups {
			append(&g_fn_entries, Fn_Entry{strings.clone(grp.title), strings.clone(grp.path), true, 0})
			for it in grp.items do append(&g_fn_entries, Fn_Entry{strings.clone(it.name), strings.clone(it.path), it.is_dir, 1})
		}
	}
	if !g_fn_search_active do g_fn_index = model.fgrid_flat_index(&g_fn_grid)
}

// fn_show rebuilds the grid for `view` and selects `focus` (else the first cell).
// focus_first: `focus` is a folder's tab; step onto its first item.
@(private = "file")
fn_show :: proc(view, focus: string, focus_first := false) {
	v := strings.clone(view, context.temp_allocator) // view/focus may point into the grid
	f := strings.clone(focus, context.temp_allocator)
	model.fgrid_build(&g_fn_grid, v, model.fgrid_list_disk)
	g_fn_grid.want_row = 0
	if f == "" || !model.fgrid_select_path(&g_fn_grid, f) {
		g_fn_grid.group = 0
		g_fn_grid.item = len(g_fn_grid.groups) > 0 && len(g_fn_grid.groups[0].items) > 0 ? 0 : -1
	} else if focus_first {
		model.fgrid_move(&g_fn_grid, .Down) // stays on the tab if the folder is empty
	}
	g_fn_first_grp = 0
	g_fn_first_row = 0
	fn_sync(true)
}

// filenav_refresh_entries re-reads the same view from disk, keeping the selection
// by path (else clamped to the same column and row).
filenav_refresh_entries :: proc() {
	it, _, _, ok := model.fgrid_selected(&g_fn_grid)
	keep := ok ? strings.clone(it.path, context.temp_allocator) : ""
	model.fgrid_build(&g_fn_grid, g_fn_grid.view, model.fgrid_list_disk)
	if keep != "" do model.fgrid_select_path(&g_fn_grid, keep)
	fn_sync(true)
}

// Select the cell (or tab) for `path`, if it's on screen.
@(private = "file")
filenav_select_path :: proc(path: string) -> bool {
	ok := model.fgrid_select_path(&g_fn_grid, path)
	fn_sync(false)
	return ok
}

// Up a level: the view becomes its parent, with the folder we left highlighted.
// Climbing past the root moves the root too (the old "parent folder").
// false at the top; the descent count is dropped then, so B can always get out.
@(private = "file")
fn_up_level :: proc() -> bool {
	view, focus, ok := model.fgrid_up(&g_fn_grid)
	if !ok {
		g_fn_grid.descents = 0
		set_status("already at the top")
		return false
	}
	v := strings.clone(view, context.temp_allocator)
	if !model.fgrid_under(v, g_fn_dir) {
		delete(g_fn_dir)
		g_fn_dir = strings.clone(v)
	}
	d := max(0, g_fn_grid.descents - 1)
	fn_show(v, focus)
	g_fn_grid.descents = d
	sfx_paper()
	return true
}

// Drop into the highlighted folder box (or column tab). Only a view that really
// changed counts as a descent: B pops descents, so a phantom one would make B
// overshoot a level (or, at a drive root, never leave).
@(private = "file")
fn_descend :: proc() {
	it, is_tab, is_here, sel := model.fgrid_selected(&g_fn_grid)
	if !sel do return
	if is_here {
		set_status("you're in this folder - Left goes up a level")
		return
	}
	name := strings.clone(it.name, context.temp_allocator)
	view, focus, first, ok := model.fgrid_descend(&g_fn_grid)
	if !ok {
		if is_tab do set_status(fmt.tprintf("can't open %s", name)) // unreadable folder
		return
	}
	old := strings.clone(g_fn_grid.view, context.temp_allocator)
	want := strings.clone(view, context.temp_allocator)
	d := g_fn_grid.descents
	fn_show(want, focus, first)
	if model.fgrid_same(g_fn_grid.view, old) || !model.fgrid_same(g_fn_grid.view, want) {
		g_fn_grid.descents = d // the folder vanished or locked since the last read
		set_status(fmt.tprintf("can't open %s", name))
		return
	}
	g_fn_grid.descents = d + 1
	sfx_paper()
}

// --- Lifecycle ---

// filenav_init: the root is the current file's project folder (the first folder
// under a projects folder - g_project_dir is only the file's own folder, which
// would hide its sister folders); the view shows the current file in its
// folder's column, highlighted.
filenav_init :: proc() {
	if g_fn_dir == "" {
		root := g_project_dir != "" ? g_project_dir : (g_projects_dir != "" ? g_projects_dir : ".")
		if proj, ok := project_root_of(g_current_file); ok do root = proj // under any projects folder (roots_store.odin)
		g_fn_dir = strings.clone(root)
	}
	g_fn_grid.descents = 0
	fn_show(model.fgrid_view_for(g_current_file, g_fn_dir), g_current_file)
}

filenav_enter :: proc() {
	g_filenav = true
	filenav_init()
}

filenav_exit :: proc() {
	g_filenav = false
	filenav_search_close()
	filenav_delete_cancel()
}

// --- Input ---

// The highlighted cell or column tab as an entry, for rename/delete. The "here"
// tab (the view itself) is refused: it's the folder you're standing in.
@(private = "file")
selected_entry :: proc() -> (Fn_Entry, bool) {
	it, _, is_here, ok := model.fgrid_selected(&g_fn_grid)
	if !ok do return {}, false
	if is_here {
		set_status("this is the folder you're in - go up a level first")
		return {}, false
	}
	return Fn_Entry{it.name, it.path, it.is_dir, 0}, true
}

handle_filenav :: proc(m: ^model.App, raw: ^Raw, inp: model.Input) {
	if g_fn_delete != "" { // "Delete ...?" is showing: A deletes, B keeps it
		if raw.e_confirm || raw.e_a do filenav_delete_confirmed()
		else if raw.e_cancel || raw.e_b do filenav_delete_cancel()
		raw.e_confirm = false; raw.e_a = false; raw.e_cancel = false; raw.e_b = false
		raw.e_up = false; raw.e_down = false; raw.e_left = false; raw.e_right = false
		raw.e_x = false; raw.e_y = false
		return
	}
	if g_fn_search_active {
		handle_filenav_search(raw, inp)
		return
	}
	if raw.e_y { // search
		g_fn_search_active = true
		filenav_apply_filter()
		raw.e_y = false
		return
	}
	if raw.e_b && inp.rt_held { // RT+B: switch to the previous file
		filenav_alt_tab()
		raw.e_b = false
		return
	}
	if raw.e_b && inp.lt_held { // LT+B: delete the highlighted file/folder (asks first)
		if e, ok := selected_entry(); ok do filenav_delete_ask(e)
		raw.e_b = false; raw.e_cancel = false
		return
	}
	if raw.e_b { // back up the levels A dropped into, then out to the editor
		if g_fn_grid.descents == 0 || !fn_up_level() do filenav_exit()
		raw.e_b = false; raw.e_cancel = false
		return
	}
	if raw.e_x && !inp.lt_held {
		filenav_create_new()
		raw.e_x = false
		return
	}
	if raw.e_x && inp.lt_held {
		if e, ok := selected_entry(); ok do filenav_rename(e)
		raw.e_x = false
		return
	}
	defer {
		raw.e_up = false; raw.e_down = false; raw.e_left = false; raw.e_right = false
		raw.e_confirm = false; raw.e_a = false
		fn_sync(false)
	}
	// One step per frame, so a diagonal press can't skip a cell.
	moved := model.Fgrid_Move.None
	switch {
	case raw.e_up:    moved = model.fgrid_move(&g_fn_grid, .Up)
	case raw.e_down:  moved = model.fgrid_move(&g_fn_grid, .Down)
	case raw.e_left:  moved = model.fgrid_move(&g_fn_grid, .Left)
	case raw.e_right: moved = model.fgrid_move(&g_fn_grid, .Right)
	}
	if moved == .Up_Level {
		fn_up_level()
		return
	}
	if raw.e_confirm {
		it, _, _, ok := model.fgrid_selected(&g_fn_grid)
		if ok && !it.is_dir {
			path := strings.clone(it.path, context.temp_allocator)
			filenav_open_file(path)
			filenav_exit()
		} else {
			fn_descend()
		}
	}
}

// --- Files ---

// filenav_open_file sets the current file and updates alt-tab history.
filenav_open_file :: proc(path: string) {
	if g_current_file != "" && g_current_file != path {
		// Remember the previous file for alt-tab.
		if g_prev_file != "" do delete(g_prev_file)
		g_prev_file = strings.clone(g_current_file)
	}
	filenav_load(path)
	sfx_paper()
}

// filenav_load makes `path` the current file: loads it into the editor, and points
// the project (save target + run cwd) at the file's folder.
filenav_load :: proc(path: string) {
	g_file_loads += 1 // a load is not "adding code" (main.odin's pencil sound)
	set_current_file(path)
	set_project_dir(filepath.dir(path))
	// Load the opened file's content into the editor document.
	if g_app != nil {
		if model.load_file(g_app, path) {
			model.format_doc(g_app) // Odin-style indentation and spacing (formatter.odin)
			g_app.state = .Editor
		} else {
			set_status(fmt.tprintf("could not open %s", path))
		}
	}
}

// filenav_alt_tab swaps to the previously opened file and exits file-nav.
filenav_alt_tab :: proc() {
	if g_prev_file != "" {
		next := g_prev_file
		g_prev_file = g_current_file != "" ? strings.clone(g_current_file) : ""
		filenav_load(next)
		sfx_paper()
		delete(next)
		filenav_exit()
	}
}

// filenav_create_new creates an empty new_file.odin (new_file_2.odin, ...) in
// the highlighted folder (a tab or box) or the highlighted file's folder, and
// selects it.
filenav_create_new :: proc() {
	target, box := model.fgrid_target_dir(&g_fn_grid)
	dir := strings.clone(target, context.temp_allocator)
	name := "new_file.odin"
	path := fmt.tprintf("%s/%s", dir, name)
	for k := 2; os.exists(path); k += 1 {
		name = fmt.tprintf("new_file_%d.odin", k)
		path = fmt.tprintf("%s/%s", dir, name)
	}
	if !trace_write_ok(path) do return // TRACE hook: a replay creates files only inside its sandbox
	if err := os.write_entire_file(path, []byte{}); err != nil {
		set_status(fmt.tprintf("could not create %s", name))
		return
	}
	if box { // inside a closed folder box: drop into its column so the file shows
		d := g_fn_grid.descents + 1
		fn_show(g_fn_grid.groups[g_fn_grid.group].path, path)
		g_fn_grid.descents = d
		return
	}
	filenav_refresh_entries()
	filenav_select_path(path)
}

// filenav_rename (LT+X) asks for the new name: the Save-as dialog in rename
// mode (save_dialog.odin), prefilled with the current one - type it or hold X
// and say it; A renames.
filenav_rename :: proc(entry: Fn_Entry) {
	rename_dialog_open(entry.path, entry.name, entry.is_dir)
}

// filenav_renamed: the dialog renamed old_path to path - keep the open file and
// the highlight on it. (The view itself can't be renamed: its "here" tab refuses.)
filenav_renamed :: proc(old_path, path: string, is_dir: bool) {
	if same_path(old_path, g_current_file) do set_current_file(path)
	if is_dir && g_current_file != "" && strings.has_prefix(norm_path(g_current_file), strings.concatenate({norm_path(old_path), "/"}, context.temp_allocator)) {
		// The open file was inside the renamed folder.
		set_current_file(fmt.tprintf("%s%s", path, g_current_file[len(old_path):]))
	}
	filenav_refresh_entries()
	filenav_select_path(path)
}

// --- Delete (LT+B) ---

// Count the files under a folder (stops counting at FN_MAX_RESULTS).
@(private = "file")
count_files :: proc(dir: string, depth := 0) -> int {
	if depth > FN_MAX_DEPTH do return 0
	n := 0
	fis, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return 0
	for fi in fis {
		n += fi.type == .Directory ? count_files(fi.fullpath, depth + 1) : 1
		if n >= FN_MAX_RESULTS do break
	}
	return n
}

// filenav_delete_ask shows "Delete <name>?" for the entry; A confirms.
filenav_delete_ask :: proc(entry: Fn_Entry) {
	filenav_delete_cancel()
	g_fn_delete = strings.clone(entry.path)
	g_fn_delete_is_dir = entry.is_dir
	g_fn_delete_count = entry.is_dir ? count_files(entry.path) : 0
}

filenav_delete_cancel :: proc() {
	if g_fn_delete != "" do delete(g_fn_delete)
	g_fn_delete = ""
}

// Is `path` the folder `dir` or inside it?
@(private = "file")
is_under :: proc(path, dir: string) -> bool {
	np, nd := norm_path(path), norm_path(dir)
	return np == nd || strings.has_prefix(np, strings.concatenate({nd, "/"}, context.temp_allocator))
}

// filenav_delete_confirmed moves the pending path to the Recycle Bin. If the open
// file was deleted, the editor keeps its text but it is no longer tied to a file
// (saving asks for a name). The cursor stays at the same column and row.
filenav_delete_confirmed :: proc() {
	path := strings.clone(g_fn_delete, context.temp_allocator)
	name := filepath.base(path)
	filenav_delete_cancel()
	if !(trace_replaying() ? trace_write_ok(path) && os.remove_all(path) == nil : move_to_trash(path)) { // TRACE hook (was: !move_to_trash(path))
		set_status(fmt.tprintf("could not delete %s", name))
		return
	}
	if g_current_file != "" && is_under(g_current_file, path) do set_current_file("")
	if g_prev_file != "" && is_under(g_prev_file, path) {
		delete(g_prev_file)
		g_prev_file = ""
	}
	filenav_refresh_entries() // the deleted path is gone, so the cursor keeps its column and row
	set_status(fmt.tprintf("deleted %s (in the Recycle Bin)", name))
}

// --- Search (Y) ---

@(private = "file")
filenav_search_close :: proc() {
	g_fn_search_active = false
	g_fn_search_recording = false
	if g_fn_search_query != "" {
		delete(g_fn_search_query)
		g_fn_search_query = ""
	}
	free_rows(&g_fn_filtered)
}

// handle_filenav_search: hold X to say what to look for; Up/Down + A to open a
// match; B to go back to the tree.
handle_filenav_search :: proc(raw: ^Raw, inp: model.Input) {
	if raw.e_b && !g_fn_search_recording {
		filenav_search_close()
		filenav_refresh_entries()
		raw.e_b = false
		return
	}
	mic_hold := raw.x_held
	if mic_hold && !g_fn_search_recording && g_stt_e != nil {
		stt.set_free_text(g_stt_e, true)
		stt.set_context(g_stt_e, "", nil)
		trace_stt_begin(g_stt_e) // TRACE hook (was: stt.begin)
		g_fn_search_recording = true
	}
	if !mic_hold && g_fn_search_recording && g_stt_e != nil {
		result := trace_stt_end(g_stt_e) // TRACE hook (was: stt.end)
		defer delete(result)
		if result != "" {
			if g_fn_search_query != "" do delete(g_fn_search_query)
			g_fn_search_query = strings.clone(result)
			filenav_apply_filter()
		}
		g_fn_search_recording = false
	}
	n := len(g_fn_filtered)
	if n == 0 do return
	if raw.e_up do g_fn_index = (g_fn_index - 1 + n) % n
	if raw.e_down do g_fn_index = (g_fn_index + 1) % n
	if raw.e_confirm && g_fn_index >= 0 && g_fn_index < n {
		path := strings.clone(g_fn_filtered[g_fn_index].path, context.temp_allocator)
		filenav_search_close()
		filenav_open_file(path)
		filenav_exit()
	}
	raw.e_up = false; raw.e_down = false; raw.e_confirm = false
}

// filenav_apply_filter: every file under the root (all folders, expanded or
// not) whose name contains the query; shown with its path from the root.
filenav_apply_filter :: proc() {
	free_rows(&g_fn_filtered)
	q := strings.to_lower(g_fn_search_query, context.temp_allocator)
	root, _ := strings.replace_all(g_fn_dir, "\\", "/", context.temp_allocator)
	root = strings.trim_right(root, "/")
	walk :: proc(dir: string, depth: int, q, root: string) {
		if depth > FN_MAX_DEPTH || len(g_fn_filtered) >= FN_MAX_RESULTS do return
		for e in list_dir(dir) {
			if e.is_dir {
				walk(e.path, depth + 1, q, root)
				continue
			}
			if q != "" && !strings.contains(strings.to_lower(e.name, context.temp_allocator), q) do continue
			full, _ := strings.replace_all(e.path, "\\", "/", context.temp_allocator)
			rel := full
			if len(full) > len(root) + 1 && strings.equal_fold(full[:len(root)], root) do rel = full[len(root) + 1:]
			append(&g_fn_filtered, Fn_Entry{strings.clone(rel), strings.clone(e.path), false, 0})
			if len(g_fn_filtered) >= FN_MAX_RESULTS do return
		}
	}
	walk(g_fn_dir, 0, q, root)
	g_fn_index = 0
}

// --- Drawing ---

FN_FOLDER_COL :: gpu.Color{0.15, 0.35, 0.70, 1}
FN_OPEN_FILL  :: gpu.Color{0.84, 0.92, 0.84, 1} // the open file's cell

// Grid metrics (px). One column per folder; every column shares the row positions.
FN_TAB_H     :: f32(32)
FN_CELL_W    :: f32(196)
FN_CELL_H    :: f32(34)
FN_VGAP      :: f32(6)
FN_ROW       :: FN_CELL_H + FN_VGAP
FN_PAD       :: f32(8)
FN_GROUP_W   :: FN_CELL_W + 2 * FN_PAD
FN_GROUP_GAP :: f32(22)
FN_HINT_STEP :: f32(26) // the hint / "open:" lines under the sheet

// draw_filenav: the folder grid (or the search results) on a full-width sheet
// over the (dimmed) editor.
draw_filenav :: proc(r: ^gpu.Renderer, w, h: int) {
	if !g_filenav do return
	fw, fh := f32(w), f32(h)
	gpu.draw_rect(r, {0, 0, fw, fh}, COL_VEIL)

	px, py := f32(24), f32(56)
	hints := hint_lines(fw - px * 2)
	// A narrow window wraps the hint; the sheet gives up the room so the lines
	// below it stay clear of the HUD.
	pw, ph := fw - 48, fh - py - 210 - f32(len(hints) - 1) * FN_HINT_STEP
	gpu.draw_rect(r, {px, py, pw, ph}, COL_BG)
	gpu.draw_rect_outline(r, {px, py, pw, ph}, 1, COL_RULE)

	header := g_fn_search_active ? "SEARCH" : "FILES"
	hx := px + 14
	if draw_icon(r, g_fn_search_active ? .Search : .Files, hx + 11, py + 20, 26, COL_ACCENT) do hx += 28
	text.draw_line(r, g_ui, {hx, py + 10}, header, COL_ACCENT)
	draw_breadcrumb(r, px + 120, py + 10, pw - 220) // room on the right for "^ more"
	gpu.draw_rect(r, {px, py + 40, pw, 1}, COL_RULE)

	if g_fn_search_active {
		list_top := py + 48
		query := g_fn_search_query != "" ? g_fn_search_query : "(hold X and say part of a file name)"
		if g_fn_search_recording do query = "Listening..."
		text.draw_line(r, g_ui, {px + 14, list_top + 2}, fit_label(g_ui, fmt.tprintf("find: %s   (%d)", query, len(g_fn_filtered)), pw - 28), COL_TEXT)
		draw_search_rows(r, px, list_top + 34, pw, py + ph - 8)
	} else {
		draw_grid(r, px, py, pw, ph)
	}

	y := py + ph + 10
	for line in hints {
		text.draw_line(r, g_ui, {px, y}, fit_label(g_ui, line, fw - px * 2), COL_DIM)
		y += FN_HINT_STEP
	}
	if g_current_file != "" {
		text.draw_line(r, g_ui, {px, y}, fit_label(g_ui, fmt.tprintf("open: %s", g_current_file), fw - px * 2), COL_ACCENT)
	}
	if g_fn_delete != "" do draw_delete_confirm(r, w, h)
}

// The button hint, packed into as few lines of width maxw as it takes, so a narrow
// window wraps it instead of cutting off delete / search / prev file.
@(private = "file")
hint_lines :: proc(maxw: f32) -> []string {
	back := g_fn_grid.descents > 0 ? "B up a level" : "B back"
	grid_parts := [?]string{"D-pad move", "A open / drop in", back, "X new file", "LT+X rename", "LT+B delete", "Y search", "RT+B prev file"}
	search_parts := [?]string{"Up/Down move", "A open", "hold X say a name", "B back to the folders"}
	parts := g_fn_search_active ? search_parts[:] : grid_parts[:]
	lines := make([dynamic]string, 0, 2, context.temp_allocator)
	cur := ""
	for part in parts {
		cand := cur == "" ? part : strings.concatenate({cur, "   ", part}, context.temp_allocator)
		if cur != "" && text.measure(g_ui, cand).x > maxw {
			append(&lines, cur)
			cur = part
		} else {
			cur = cand
		}
	}
	append(&lines, cur)
	return lines[:]
}

// The folders from the root down to the view: "root  >  a  >  view", trimmed
// from the front (like the radial menu's trail) when it doesn't fit.
@(private = "file")
draw_breadcrumb :: proc(r: ^gpu.Renderer, x, y, maxw: f32) {
	if g_fn_search_active {
		text.draw_line(r, g_ui, {x, y}, fit_label(g_ui, g_fn_dir, maxw), COL_DIM)
		return
	}
	view := g_fn_grid.view
	parts := make([dynamic]string, 0, 8, context.temp_allocator)
	if model.fgrid_under(view, g_fn_dir) {
		d := filepath.dir(view)
		for _ in 0 ..< 64 {
			inject_at(&parts, 0, model.fgrid_title(d))
			if same_path(d, g_fn_dir) do break
			p, ok := model.fgrid_parent_of(d)
			if !ok do break
			d = p
		}
	}
	name := model.fgrid_title(view) // a drive root reads "C:", not ""
	if g_fn_grid.more_groups > 0 do name = fmt.tprintf("%s  (+%d folders)", name, g_fn_grid.more_groups)
	name = fit_label(g_ui, name, maxw)
	trail := ""
	if len(parts) > 0 do trail = strings.concatenate({strings.join(parts[:], "  >  ", context.temp_allocator), "  >  "}, context.temp_allocator)
	room := maxw - text.measure(g_ui, name).x
	for len(parts) > 0 && text.measure(g_ui, trail).x > room {
		ordered_remove(&parts, 0)
		trail = len(parts) > 0 ? strings.concatenate({"..  >  ", strings.join(parts[:], "  >  ", context.temp_allocator), "  >  "}, context.temp_allocator) : ""
	}
	if trail != "" do text.draw_line(r, g_ui, {x, y}, trail, COL_DIM)
	text.draw_line(r, g_ui, {x + text.measure(g_ui, trail).x, y}, name, COL_ACCENT)
}

// A small folder shape (tab + body) with its top-left at (x, y).
@(private = "file")
draw_folder_glyph :: proc(r: ^gpu.Renderer, x, y: f32) {
	gpu.draw_rect(r, {x, y + 3, 7, 4}, FN_FOLDER_COL)
	gpu.draw_rect(r, {x, y + 6, 16, 11}, FN_FOLDER_COL)
}

// Text vertically centred in a box of height h starting at y.
@(private = "file")
mid_y :: proc(y, h: f32) -> f32 { return y + (h - text.line_height(g_ui)) * 0.5 }

// The columns: tabs in a fixed header row, cells below. Scrolling moves whole
// columns sideways and all rows together, just enough to keep the cursor visible.
@(private = "file")
draw_grid :: proc(r: ^gpu.Renderer, px, py, pw, ph: f32) {
	g := &g_fn_grid
	gx0, gx1 := px + 16, px + pw - 16
	hy := py + 54
	cy0 := hy + FN_TAB_H + 10
	vis_grp := max(1, int((gx1 - gx0 + FN_GROUP_GAP) / (FN_GROUP_W + FN_GROUP_GAP)))
	vis_rows := max(1, int((py + ph - 12 - cy0 + FN_VGAP) / FN_ROW))
	ng := len(g.groups)
	if ng == 0 do return

	g_fn_first_grp = clamp(g_fn_first_grp, g.group - vis_grp + 1, g.group)
	g_fn_first_grp = clamp(g_fn_first_grp, 0, max(0, ng - vis_grp))
	if g.item >= 0 do g_fn_first_row = clamp(g_fn_first_row, g.item - vis_rows + 1, g.item)
	g_fn_first_row = max(0, g_fn_first_row)

	more_below := false
	for gi in g_fn_first_grp ..< min(ng, g_fn_first_grp + vis_grp) {
		fx := gx0 + f32(gi - g_fn_first_grp) * (FN_GROUP_W + FN_GROUP_GAP)
		grp := &g.groups[gi]
		n := len(grp.items)
		shown := clamp(n - g_fn_first_row, 1, vis_rows)
		if n - g_fn_first_row > vis_rows do more_below = true
		gpu.draw_rect_outline(r, {fx, hy + FN_TAB_H, FN_GROUP_W, 10 + f32(shown) * FN_ROW - FN_VGAP + FN_PAD}, 1, COL_RULE)
		draw_tab(r, grp, fx, hy, gi == g.group && g.item < 0)
		if g_fn_first_row >= n {
			if n > 0 do text.draw_line(r, g_ui, {fx + FN_PAD + 10, mid_y(cy0, FN_CELL_H)}, "^", COL_DIM) // its files are above
			if n == 0 {
				msg := grp.unreadable ? "(can't open)" : "(empty)"
				text.draw_line(r, g_ui, {fx + FN_PAD + 10, mid_y(cy0, FN_CELL_H)}, fit_label(g_ui, msg, FN_CELL_W - 16), COL_DIM)
				if grp.here && ng == 1 && !grp.unreadable { // nothing else on screen: say what to do, beside the column
					hx := fx + FN_GROUP_W + FN_GROUP_GAP
					text.draw_line(r, g_ui, {hx, mid_y(cy0, FN_CELL_H)}, fit_label(g_ui, "X makes a new file here", gx1 - hx), COL_DIM)
				}
			}
			continue
		}
		for row in g_fn_first_row ..< min(n, g_fn_first_row + vis_rows) {
			y := cy0 + f32(row - g_fn_first_row) * FN_ROW
			draw_cell(r, grp.items[row], fx + FN_PAD, y, gi == g.group && row == g.item)
		}
	}

	rows_mid := cy0 + f32(vis_rows) * FN_ROW * 0.5 - text.line_height(g_ui) * 0.5
	if g_fn_first_grp > 0 do text.draw_line(r, g_ui, {gx0 - 14, rows_mid}, "<", COL_DIM)
	if g_fn_first_grp + vis_grp < ng do text.draw_line(r, g_ui, {gx1 + 2, rows_mid}, ">", COL_DIM)
	if g_fn_first_row > 0 do text.draw_line(r, g_ui, {gx1 - 60, py + 10}, "^ more", COL_DIM)
	if more_below do text.draw_line(r, g_ui, {gx1 - 60, py + ph - 2 - text.line_height(g_ui)}, "v more", COL_DIM)
}

// A column's tab. The "here" tab (the view's own files) is raised and green,
// like the "you are here" folder in the sketch.
@(private = "file")
draw_tab :: proc(r: ^gpu.Renderer, grp: ^model.Fgrid_Group, fx, hy: f32, selected: bool) {
	rect := gpu.Rect{fx, hy, FN_GROUP_W, FN_TAB_H}
	ink := COL_TEXT
	if grp.here {
		rect = {fx, hy - 8, FN_GROUP_W, FN_TAB_H + 8}
		ink = COL_ACCENT
	}
	gpu.draw_rect(r, rect, selected ? COL_HILITE : (grp.here ? COL_BG : COL_PANEL))
	if selected do gpu.draw_rect_outline(r, rect, 2, COL_ACCENT)
	else do gpu.draw_rect_outline(r, rect, 1, grp.here ? COL_ACCENT : COL_RULE)

	draw_folder_glyph(r, fx + 12, rect.y + (rect.h - 20) * 0.5)
	right := fx + FN_GROUP_W - 10
	if g_current_file != "" && holds_open_file(grp) {
		gpu.draw_circle(r, right - 3.5, rect.y + rect.h * 0.5, 3.5, COL_DOT)
		right -= 14
	}
	if grp.more > 0 {
		more := fmt.tprintf("+%d", grp.more)
		right -= text.measure(g_ui, more).x
		text.draw_line(r, g_ui, {right, mid_y(rect.y, rect.h)}, more, COL_DIM)
		right -= 6
	}
	title := strings.has_suffix(grp.title, "/") ? grp.title : fmt.tprintf("%s/", grp.title) // "/" at the very top
	text.draw_line(r, g_ui, {fx + 34, mid_y(rect.y, rect.h)}, fit_label(g_ui, title, right - fx - 34), ink)
}

// Is the open file in this column? (The "here" column: only directly in the view.)
@(private = "file")
holds_open_file :: proc(grp: ^model.Fgrid_Group) -> bool {
	if grp.here do return same_path(filepath.dir(g_current_file), grp.path)
	return model.fgrid_under(g_current_file, grp.path)
}

// One cell: a file (sheet fill) or a closed folder box (outlined, blue ink).
@(private = "file")
draw_cell :: proc(r: ^gpu.Renderer, it: model.Fgrid_Item, x, y: f32, selected: bool) {
	rect := gpu.Rect{x, y, FN_CELL_W, FN_CELL_H}
	ty := mid_y(y, FN_CELL_H)
	if it.is_dir {
		gpu.draw_rect(r, rect, selected ? COL_HILITE : COL_BG)
		gpu.draw_rect_outline(r, rect, selected ? 2 : 1, selected ? COL_ACCENT : FN_FOLDER_COL)
		draw_folder_glyph(r, x + 10, y + (FN_CELL_H - 20) * 0.5)
		col := selected ? COL_TEXT : FN_FOLDER_COL // readable on the highlight
		text.draw_line(r, g_ui, {x + 32, ty}, fit_label(g_ui, fmt.tprintf("%s/", it.name), FN_CELL_W - 40), col)
		return
	}
	current := g_current_file != "" && same_path(it.path, g_current_file)
	fill := current ? FN_OPEN_FILL : COL_PANEL
	col := strings.has_suffix(it.name, ".odin") ? COL_TEXT : COL_DIM
	if current do col = COL_ACCENT
	if selected {
		fill = COL_HILITE
		col = COL_TEXT
	}
	gpu.draw_rect(r, rect, fill)
	if selected do gpu.draw_rect_outline(r, rect, 2, COL_ACCENT)
	label := current ? fmt.tprintf("%s  *", it.name) : it.name
	text.draw_line(r, g_ui, {x + 10, ty}, fit_label(g_ui, label, FN_CELL_W - 16), col)
}

// Search results: one full-width list in the file-cell style, centred on the cursor.
// The scroll marks sit in a gutter right of the cells, so they never cover a cell
// or the "find:" line.
@(private = "file")
draw_search_rows :: proc(r: ^gpu.Renderer, px, top, pw, bottom: f32) {
	rows := g_fn_filtered[:]
	if len(rows) == 0 {
		text.draw_line(r, g_ui, {px + 14, top + 8}, "(no matching files)", COL_DIM)
		return
	}
	visible := max(1, int((bottom - top + FN_VGAP) / FN_ROW))
	first := clamp(g_fn_index - visible / 2, 0, max(0, len(rows) - visible))
	cw := pw - 44
	for i in first ..< min(first + visible, len(rows)) {
		e := rows[i]
		y := top + f32(i - first) * FN_ROW
		rect := gpu.Rect{px + 16, y, cw, FN_CELL_H}
		current := g_current_file != "" && same_path(e.path, g_current_file)
		fill := current ? FN_OPEN_FILL : COL_PANEL
		col := strings.has_suffix(e.name, ".odin") ? COL_TEXT : COL_DIM
		if current do col = COL_ACCENT
		if i == g_fn_index {
			fill = COL_HILITE
			col = COL_TEXT
		}
		gpu.draw_rect(r, rect, fill)
		if i == g_fn_index do gpu.draw_rect_outline(r, rect, 2, COL_ACCENT)
		label := current ? fmt.tprintf("%s  *", e.name) : e.name
		text.draw_line(r, g_ui, {rect.x + 10, mid_y(y, FN_CELL_H)}, fit_label(g_ui, label, cw - 16), col)
	}
	mark_x := px + 16 + cw + 7
	if first > 0 do text.draw_line(r, g_ui, {mark_x, mid_y(top, FN_CELL_H)}, "^", COL_DIM)
	if first + visible < len(rows) do text.draw_line(r, g_ui, {mark_x, mid_y(top + f32(visible - 1) * FN_ROW, FN_CELL_H)}, "v", COL_DIM)
}

// The "Delete ...?" box, in the middle of the screen.
@(private = "file")
draw_delete_confirm :: proc(r: ^gpu.Renderer, w, h: int) {
	fw, fh := f32(w), f32(h)
	gpu.draw_rect(r, {0, 0, fw, fh}, COL_VEIL)
	pw := min(f32(680), fw - 80)
	ph := f32(200)
	px := (fw - pw) * 0.5
	py := (fh - 150 - ph) * 0.5
	gpu.draw_rect(r, {px, py, pw, ph}, COL_PANEL)
	gpu.draw_rect_outline(r, {px, py, pw, ph}, 2, COL_ERR)

	name := filepath.base(g_fn_delete)
	title := g_fn_delete_is_dir ? fmt.tprintf("Delete folder %s/ ?", name) : fmt.tprintf("Delete %s ?", name)
	title = fit_label(g_ui, title, pw - 90)
	text.draw_centered(r, g_ui, {px, py + 18, pw, 30}, title, COL_ERR)
	draw_icon(r, .Delete, px + pw * 0.5 - text.measure(g_ui, title).x * 0.5 - 22, py + 33, 26, COL_ERR)

	what := "It goes to the Recycle Bin (you can restore it from there)."
	if g_fn_delete_is_dir {
		files := g_fn_delete_count == 1 ? "1 file" : fmt.tprintf("%d%s files", g_fn_delete_count, g_fn_delete_count >= FN_MAX_RESULTS ? "+" : "")
		what = fmt.tprintf("The folder and everything in it (%s) go to the Recycle Bin.", files)
	}
	text.draw_centered(r, g_ui, {px + 20, py + 66, pw - 40, 24}, fit_label(g_ui, what, pw - 40), COL_TEXT)
	if g_current_file != "" && is_under(g_current_file, g_fn_delete) {
		text.draw_centered(r, g_ui, {px + 20, py + 96, pw - 40, 24},
			fit_label(g_ui, "This is the open file: the editor keeps its text, unsaved.", pw - 40), COL_WARN)
	}
	text.draw_centered(r, g_ui, {px, py + ph - 42, pw, 24}, "A delete    B keep it", COL_DIM)
}

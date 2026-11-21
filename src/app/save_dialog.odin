package main

// RT+Y: "Save as" dialog in the middle of the screen. File navigation's LT+X
// opens the same dialog to rename the highlighted file / folder (g_save_rename).
//   gamepad: hold X and say a name, A = save, B = cancel
//   keyboard: type a name, Backspace = delete, Enter = save, Esc = cancel
// The name box starts with the current file's name (or main.odin); the first
// typed/dictated input replaces it. Saving over a *different* existing file asks
// for a second A press.

import "../gpu"
import "../model"
import "../stt"
import "../text"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

g_save_open:      bool
g_save_name:      [dynamic]u8 // the name being edited
g_save_fresh:     bool        // name is still the prefill: next input replaces it
g_save_recording: bool        // holding X: dictating the name
g_save_overwrite: string      // path awaiting overwrite confirmation ("" = none)
g_save_error:     string      // last error shown in the dialog ("" = none)
g_save_rename:    string      // renaming this file / folder instead of saving ("" = Save as)
g_save_rename_dir: bool       // ... and it's a folder
g_save_x_armed:   bool        // X was released since the dialog opened (LT+X opens rename: X is still down)

save_dialog_open :: proc() {
	clear(&g_save_name)
	prefill := g_current_file != "" ? filepath.base(g_current_file) : "main.odin"
	append(&g_save_name, ..transmute([]u8)prefill)
	g_save_fresh = true
	save_dialog_set_overwrite("")
	save_dialog_set_error("")
	save_dialog_set_rename("", false)
	g_save_x_armed = false
	g_save_open = true
}

// rename_dialog_open: file navigation's LT+X - the name box starts with the
// file's / folder's name; A renames it.
rename_dialog_open :: proc(path, name: string, is_dir: bool) {
	save_dialog_open()
	clear(&g_save_name)
	append(&g_save_name, ..transmute([]u8)name)
	save_dialog_set_rename(path, is_dir)
}

@(private = "file")
save_dialog_set_rename :: proc(path: string, is_dir: bool) {
	if g_save_rename != "" do delete(g_save_rename)
	g_save_rename = path == "" ? "" : strings.clone(path)
	g_save_rename_dir = is_dir
}

// The name the box would give: a rename keeps the extension (model.clean_rename).
@(private = "file")
dialog_final_name :: proc(name: string) -> string {
	if g_save_rename != "" do return model.clean_rename(name, filepath.base(g_save_rename), g_save_rename_dir, context.temp_allocator)
	return model.clean_filename(name, context.temp_allocator)
}

save_dialog_close :: proc() {
	if g_save_recording && g_stt_e != nil {
		r := trace_stt_end(g_stt_e) // TRACE hook (was: stt.end)
		delete(r)
	}
	g_save_recording = false
	save_dialog_set_overwrite("")
	save_dialog_set_error("")
	save_dialog_set_rename("", false)
	g_save_open = false
}

@(private = "file")
save_dialog_set_overwrite :: proc(path: string) {
	if g_save_overwrite != "" do delete(g_save_overwrite)
	g_save_overwrite = path == "" ? "" : strings.clone(path)
}

@(private = "file")
save_dialog_set_error :: proc(msg: string) {
	if g_save_error != "" do delete(g_save_error)
	g_save_error = msg == "" ? "" : strings.clone(msg)
}

// Any edit to the name clears pending confirmations/errors.
@(private = "file")
name_edited :: proc() {
	g_save_fresh = false
	save_dialog_set_overwrite("")
	save_dialog_set_error("")
}

// handle_save_input owns all input while the dialog is open (consumes edges).
handle_save_input :: proc(m: ^model.App, raw: ^Raw) {
	defer {
		raw.e_confirm = false; raw.e_a = false; raw.e_cancel = false; raw.e_b = false
		raw.e_up = false; raw.e_down = false; raw.e_left = false; raw.e_right = false
		raw.e_x = false; raw.e_y = false; raw.e_rb = false
	}

	// Gamepad X held: dictate the name (snake_case, e.g. "game loop" -> game_loop).
	if !raw.pad_x_held do g_save_x_armed = true
	if raw.pad_x_held && g_save_x_armed && !g_save_recording && g_stt_e != nil {
		stt.set_free_text(g_stt_e, false)
		stt.set_context(g_stt_e, "", nil)
		trace_stt_begin(g_stt_e) // TRACE hook (was: stt.begin)
		g_save_recording = true
		return
	}
	if g_save_recording {
		if raw.pad_x_held do return // still listening; ignore other buttons
		heard := trace_stt_end(g_stt_e) // TRACE hook (was: stt.end)
		defer delete(heard)
		g_save_recording = false
		if heard != "" {
			clear(&g_save_name)
			append(&g_save_name, ..transmute([]u8)heard)
			name_edited()
		}
		return
	}

	// Keyboard typing. (Space types '_' instead of saving; Backspace deletes
	// instead of cancelling.)
	for c in raw.typed[:raw.n_typed] {
		if g_save_fresh do clear(&g_save_name)
		append(&g_save_name, c)
		name_edited()
	}
	if raw.e_space {
		if g_save_fresh do clear(&g_save_name)
		append(&g_save_name, '_')
		name_edited()
		return
	}
	if raw.e_backspace {
		if len(g_save_name) > 0 do pop(&g_save_name)
		name_edited()
		return
	}

	if raw.e_cancel || raw.e_b {
		save_dialog_close()
		return
	}
	if raw.e_confirm || raw.e_a {
		if g_save_rename != "" do rename_dialog_commit()
		else do save_dialog_commit(m)
	}
}

// rename_dialog_commit renames the file / folder (never over another one).
@(private = "file")
rename_dialog_commit :: proc() {
	old_path := strings.clone(g_save_rename, context.temp_allocator)
	name := dialog_final_name(string(g_save_name[:]))
	if name == "" {
		save_dialog_set_error("Type or say a name first")
		return
	}
	path := fmt.tprintf("%s/%s", filepath.dir(old_path), name)
	if path == old_path || filepath.base(old_path) == name {
		save_dialog_close() // unchanged
		return
	}
	// Another file of that name (a change of case only is the same file on Windows).
	if os.exists(path) && !same_path(path, old_path) {
		save_dialog_set_error(fmt.tprintf("%s already exists", name))
		return
	}
	if !trace_write_ok(path) do return // TRACE hook: a replay renames only inside its sandbox
	if err := os.rename(old_path, path); err != nil {
		save_dialog_set_error(fmt.tprintf("Could not rename: %v", err))
		return
	}
	filenav_renamed(old_path, path, g_save_rename_dir)
	save_dialog_close()
}

// save_dialog_commit validates the name and writes the file.
@(private = "file")
save_dialog_commit :: proc(m: ^model.App) {
	name := model.clean_filename(string(g_save_name[:]), context.temp_allocator)
	if name == "" {
		save_dialog_set_error("Type or say a file name first")
		return
	}
	path := fmt.tprintf("%s/%s", save_folder(), name)

	// Saving over a different file that already exists: confirm with a second A.
	is_current := g_current_file != "" && same_path(g_current_file, path)
	if !is_current && os.exists(path) && g_save_overwrite != path {
		save_dialog_set_overwrite(path)
		return
	}
	if msg := write_doc(m, path); msg != "" {
		save_dialog_set_error(msg)
		return
	}
	save_dialog_close()
}

@(private = "file")
same_path :: proc(a, b: string) -> bool {
	na, _ := strings.replace_all(a, "\\", "/", context.temp_allocator)
	nb, _ := strings.replace_all(b, "\\", "/", context.temp_allocator)
	return strings.equal_fold(na, nb) // Windows paths are case-insensitive
}

draw_save_dialog :: proc(r: ^gpu.Renderer, w, h: int) {
	fw, fh := f32(w), f32(h)
	gpu.draw_rect(r, {0, 0, fw, fh}, COL_VEIL)

	pw := min(f32(760), fw - 80)
	ph := f32(250)
	px := (fw - pw) * 0.5
	py := (fh - 150 - ph) * 0.5 // centered in the area above the HUD
	gpu.draw_rect(r, {px, py, pw, ph}, COL_PANEL)
	gpu.draw_rect_outline(r, {px, py, pw, ph}, 2, COL_ACCENT)

	renaming := g_save_rename != ""
	title := renaming ? fmt.tprintf("RENAME %s", filepath.base(g_save_rename)) : "SAVE AS"
	text.draw_centered(r, g_ui, {px, py + 14, pw, 30}, fit_label(g_ui, title, pw - 80), COL_ACCENT)
	if !renaming do draw_icon(r, .Save, px + pw * 0.5 - text.measure(g_ui, "SAVE AS").x * 0.5 - 22, py + 29, 26, COL_ACCENT)

	// Name box
	bx, by, bw, bh := px + 30, py + 60, pw - 60, f32(48)
	gpu.draw_rect(r, {bx, by, bw, bh}, COL_BG)
	gpu.draw_rect_outline(r, {bx, by, bw, bh}, 2, g_save_recording ? COL_ERR : COL_HILITE)
	name := string(g_save_name[:])
	shown := fit_label(g_ui, name, bw - 40)
	tx := bx + 14
	ty := by + (bh - text.line_height(g_ui)) * 0.5
	if g_save_fresh && name != "" {
		// Prefilled name is "selected": typing replaces it.
		tw := text.measure(g_ui, shown).x
		gpu.draw_rect(r, {tx - 3, ty, tw + 6, text.line_height(g_ui)}, COL_SEL_BG)
	}
	text.draw_line(r, g_ui, {tx, ty}, shown, COL_TEXT)
	if !g_save_fresh && int(g_time * 2) % 2 == 0 { // blinking caret
		cx := tx + text.measure(g_ui, shown).x + 2
		gpu.draw_rect(r, {cx, ty + 2, 2, text.line_height(g_ui) - 4}, COL_TEXT)
	}
	if g_save_recording {
		text.draw_line(r, g_ui, {bx + bw - 70, ty}, "[REC]", COL_ERR)
	}

	// Where it goes (and the final name, if cleaning changed it).
	final := dialog_final_name(name)
	folder := renaming ? filepath.dir(g_save_rename) : save_folder_preview()
	info := fmt.tprintf("in %s", folder)
	if final != "" && final != name do info = fmt.tprintf("%s %s  in %s", renaming ? "renames to" : "saves as", final, folder)
	text.draw_centered(r, g_ui, {px + 20, by + bh + 10, pw - 40, 24}, fit_label(g_ui, info, pw - 40), COL_DIM)

	// Status line: overwrite confirmation or error.
	if g_save_overwrite != "" {
		text.draw_centered(r, g_ui, {px, by + bh + 44, pw, 24},
			fmt.tprintf("%s already exists - press A again to overwrite", filepath.base(g_save_overwrite)),
			COL_WARN)
	} else if g_save_error != "" {
		text.draw_centered(r, g_ui, {px, by + bh + 44, pw, 24}, g_save_error, COL_ERR)
	}

	verb := renaming ? "A rename" : "A save"
	hint := g_stt_e != nil ? fmt.tprintf("%s    B cancel    hold X to say a name    (keyboard: type)", verb) : fmt.tprintf("%s    B cancel    (keyboard: type a name)", verb)
	text.draw_centered(r, g_ui, {px, py + ph - 38, pw, 24}, hint, COL_DIM)
}

// Like save_folder, but never creates anything (safe to call while drawing).
@(private = "file")
save_folder_preview :: proc() -> string {
	if g_current_file != "" do return filepath.dir(g_current_file)
	if g_project_dir != "" do return g_project_dir
	return g_projects_dir
}

package main

// RT+Y: "Save as" dialog in the middle of the screen.
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

save_dialog_open :: proc() {
	clear(&g_save_name)
	prefill := g_current_file != "" ? filepath.base(g_current_file) : "main.odin"
	append(&g_save_name, ..transmute([]u8)prefill)
	g_save_fresh = true
	save_dialog_set_overwrite("")
	save_dialog_set_error("")
	g_save_open = true
}

save_dialog_close :: proc() {
	if g_save_recording && g_stt_e != nil {
		r := stt.end(g_stt_e)
		delete(r)
	}
	g_save_recording = false
	save_dialog_set_overwrite("")
	save_dialog_set_error("")
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
	if raw.pad_x_held && !g_save_recording && g_stt_e != nil {
		stt.set_free_text(g_stt_e, false)
		stt.set_context(g_stt_e, "", nil)
		stt.begin(g_stt_e)
		g_save_recording = true
		return
	}
	if g_save_recording {
		if raw.pad_x_held do return // still listening; ignore other buttons
		heard := stt.end(g_stt_e)
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
		save_dialog_commit(m)
	}
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
	gpu.draw_rect(r, {0, 0, fw, fh}, {0, 0, 0, 0.60})

	pw := min(f32(760), fw - 80)
	ph := f32(250)
	px := (fw - pw) * 0.5
	py := (fh - 150 - ph) * 0.5 // centered in the area above the HUD
	gpu.draw_rect(r, {px, py, pw, ph}, COL_PANEL)
	gpu.draw_rect_outline(r, {px, py, pw, ph}, 2, COL_ACCENT)

	text.draw_centered(r, g_ui, {px, py + 14, pw, 30}, "SAVE AS", COL_ACCENT)

	// Name box
	bx, by, bw, bh := px + 30, py + 60, pw - 60, f32(48)
	gpu.draw_rect(r, {bx, by, bw, bh}, COL_BG)
	gpu.draw_rect_outline(r, {bx, by, bw, bh}, 2, g_save_recording ? gpu.Color{0.90, 0.30, 0.30, 1} : COL_HILITE)
	name := string(g_save_name[:])
	shown := fit_label(g_ui, name, bw - 40)
	tx := bx + 14
	ty := by + (bh - text.line_height(g_ui)) * 0.5
	if g_save_fresh && name != "" {
		// Prefilled name is "selected": typing replaces it.
		tw := text.measure(g_ui, shown).x
		gpu.draw_rect(r, {tx - 3, ty, tw + 6, text.line_height(g_ui)}, {0.22, 0.40, 0.70, 0.55})
	}
	text.draw_line(r, g_ui, {tx, ty}, shown, COL_TEXT)
	if !g_save_fresh && int(g_time * 2) % 2 == 0 { // blinking caret
		cx := tx + text.measure(g_ui, shown).x + 2
		gpu.draw_rect(r, {cx, ty + 2, 2, text.line_height(g_ui) - 4}, COL_TEXT)
	}
	if g_save_recording {
		text.draw_line(r, g_ui, {bx + bw - 70, ty}, "[REC]", {0.90, 0.30, 0.30, 1})
	}

	// Where it goes (and the final name, if cleaning changed it).
	final := model.clean_filename(name, context.temp_allocator)
	info := fmt.tprintf("in %s", save_folder_preview())
	if final != "" && final != name do info = fmt.tprintf("saves as %s  in %s", final, save_folder_preview())
	text.draw_centered(r, g_ui, {px + 20, by + bh + 10, pw - 40, 24}, fit_label(g_ui, info, pw - 40), COL_DIM)

	// Status line: overwrite confirmation or error.
	if g_save_overwrite != "" {
		text.draw_centered(r, g_ui, {px, by + bh + 44, pw, 24},
			fmt.tprintf("%s already exists - press A again to overwrite", filepath.base(g_save_overwrite)),
			{1.00, 0.70, 0.25, 1})
	} else if g_save_error != "" {
		text.draw_centered(r, g_ui, {px, by + bh + 44, pw, 24}, g_save_error, {0.95, 0.35, 0.35, 1})
	}

	hint := g_stt_e != nil ? "A save    B cancel    hold X to say a name    (keyboard: type)" : "A save    B cancel    (keyboard: type a name)"
	text.draw_centered(r, g_ui, {px, py + ph - 38, pw, 24}, hint, COL_DIM)
}

// Like save_folder, but never creates anything (safe to call while drawing).
@(private = "file")
save_folder_preview :: proc() -> string {
	if g_current_file != "" do return filepath.dir(g_current_file)
	if g_project_dir != "" do return g_project_dir
	return g_projects_dir
}

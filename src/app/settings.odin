package main

// Settings (main menu -> Settings): on/off options (model/settings.odin has
// the options and the file format), saved in doodle_settings.txt next to
// doodle.exe like doodle_keys.tsv - right after every change. A missing file
// means the defaults; a file that exists but can't be read, or is a newer
// format, is never overwritten. Failures never stop the editor.
//
//   D-pad Up/Down  move      A / Left / Right  switch the option      B  back
//
// For the trace harness: settings_store_override pins the options for a replay
// (to what the run was recorded with) and stops saving; settings_store_text is
// the current options as text (a recording's meta).

import "../gpu"
import "../model"
import "../text"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

SETTINGS_FILE :: "doodle_settings.txt"

g_settings:        model.Settings
g_settings_path:   string // absolute; "" = no place to save
g_settings_nosave: bool   // newer format / unreadable file / replay: never write it
g_settings_warned: bool   // a settings file problem was reported once

g_settings_open: bool
g_settings_row:  int

// settings_store_init loads the options. Runs before trace_start, so a replay
// can override them.
settings_store_init :: proc() {
	g_settings = model.settings_default()
	dir := heat_exe_dir()
	defer delete(dir)
	if dir == "" do return
	if p, err := os.join_path({dir, SETTINGS_FILE}, context.allocator); err == nil do g_settings_path = p
	if g_settings_path == "" do return
	data, ok := settings_read_file()
	defer delete(data)
	switch {
	case !ok:
		g_settings_nosave = true
		settings_store_warn("could not read the settings (doodle_settings.txt); using the defaults")
	case data == nil: // no file yet: the defaults
	case !model.settings_text_ok(string(data)):
		g_settings_nosave = true
		settings_store_warn("doodle_settings.txt is from a newer Doodle; using the default settings")
	case:
		model.settings_free(&g_settings)
		g_settings = model.settings_parse(string(data))
	}
}

settings_store_shutdown :: proc() {
	model.settings_free(&g_settings)
	if g_settings_path != "" do delete(g_settings_path)
	g_settings_path = ""
}

// settings_read_file: ok = false when the file exists but couldn't be read
// (retried once: another Doodle may be renaming it). Missing: ok, no data.
@(private = "file")
settings_read_file :: proc() -> (data: []byte, ok: bool) {
	for attempt in 0 ..< 2 {
		d, err := os.read_entire_file(g_settings_path, context.allocator)
		if err == nil do return d, true
		if err == .Not_Exist do return nil, true
		if attempt == 0 do time.sleep(50 * time.Millisecond)
	}
	return nil, false
}

// settings_store_save writes <path>.tmp, then renames it over <path>.
settings_store_save :: proc() {
	if g_settings_path == "" || g_settings_nosave do return
	if !trace_write_ok(g_settings_path) do return // TRACE hook: a replay writes only inside its sandbox
	body := model.settings_serialize(&g_settings, context.temp_allocator)
	tmp := strings.concatenate({g_settings_path, ".tmp"}, context.temp_allocator)
	err := os.write_entire_file(tmp, transmute([]byte)body)
	if err == nil {
		err = os.rename(tmp, g_settings_path)
		if err != nil do _ = os.remove(tmp)
	}
	if err != nil do settings_store_warn("could not save the settings (doodle_settings.txt)")
}

@(private = "file")
settings_store_warn :: proc(msg: string) {
	if g_settings_warned do return
	g_settings_warned = true
	fmt.eprintln("doodle:", msg)
	set_status(msg)
}

// settings_store_override pins the options to `text` (a settings file's
// contents; "" = the defaults) and never saves again this session.
settings_store_override :: proc(text: string) {
	g_settings_nosave = true
	model.settings_free(&g_settings)
	g_settings = text == "" ? model.settings_default() : model.settings_parse(text)
}

// settings_store_text: the current options in the file format (a recording's meta).
settings_store_text :: proc(allocator := context.allocator) -> string {
	return model.settings_serialize(&g_settings, allocator)
}

// setting_on: is the option on right now.
setting_on :: proc(s: model.Setting) -> bool { return g_settings.on[s] }

// ---- The page ----

settings_page_open :: proc() {
	g_settings_open = true
	g_settings_row = 0
}

settings_page_close :: proc() { g_settings_open = false }

handle_settings_input :: proc(raw: ^Raw) {
	n := len(model.Setting)
	if raw.e_up   do g_settings_row = (g_settings_row - 1 + n) % n
	if raw.e_down do g_settings_row = (g_settings_row + 1) % n
	if raw.e_confirm || raw.e_a || raw.e_left || raw.e_right {
		s := model.Setting(g_settings_row)
		g_settings.on[s] = !g_settings.on[s]
		settings_store_save()
		sfx_paper()
	}
	if raw.e_cancel || raw.e_b do settings_page_close()
	raw.e_up = false; raw.e_down = false; raw.e_left = false; raw.e_right = false
	raw.e_confirm = false; raw.e_a = false; raw.e_cancel = false; raw.e_b = false
}

draw_settings_page :: proc(r: ^gpu.Renderer, w, h: int) {
	fw, fh := f32(w), f32(h)
	gpu.draw_rect(r, {0, 0, fw, fh}, COL_VEIL)
	text.draw_centered(r, g_ui, {0, fh * 0.07, fw, 36}, "SETTINGS", COL_ACCENT)

	cellw := min(f32(760), fw - 80)
	cellh := f32(48)
	vgap := f32(40) // room for the line saying what the choice does
	start_x := (fw - cellw) * 0.5
	start_y := fh * 0.15
	for info, k in model.SETTING_INFO {
		i := int(k)
		y := start_y + f32(i) * (cellh + vgap)
		box := gpu.Rect{start_x, y, cellw, cellh}
		active := i == g_settings_row
		gpu.draw_rect(r, box, active ? COL_HILITE : COL_PANEL)
		if active do gpu.draw_rect_outline(r, box, 2, COL_ACCENT)
		on := g_settings.on[k]
		value := on ? "On" : "Off"
		vw := text.measure(g_ui, value).x
		text.draw_line(r, g_ui, {box.x + 16, y + 12}, fit_label(g_ui, info.label, cellw - vw - 56), COL_TEXT)
		text.draw_line(r, g_ui, {box.x + cellw - vw - 16, y + 12}, value, on ? COL_ACCENT : COL_DIM)
		text.draw_line(r, g_ui, {box.x + 16, y + cellh + 8}, fit_label(g_ui, on ? info.on : info.off, cellw - 32), COL_DIM)
	}
	text.draw_centered(r, g_ui, {0, f32(h) - 172, fw, 24}, "D-pad move   A switch   B back", COL_DIM)
}

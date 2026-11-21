package main

// The global menu heatmap's file (model/heat.odin): doodle_heat.tsv next to
// doodle.exe, shared by every project. Loaded at startup, saved a moment after a
// use and at quit. A save re-reads the file and adds this session's unsaved uses
// to it (model.heat_merged), so two Doodles running at once don't erase each
// other's heat, then writes <file>.tmp and renames it over the file. A missing
// file just means no heat yet; a file that exists but can't be read (or is a
// newer format) is never overwritten. Failures never stop the editor.
// (Two saves at the very same moment could still race; uses are only lost then.)

import "../model"
import "core:os"
import "core:strings"
import "core:time"

HEAT_FILE       :: "doodle_heat.tsv"
HEAT_SAVE_EVERY :: 2.0 // seconds: at most one save per interval while using menus (and one at quit)

g_heat:        model.Heat
g_heat_path:   string // absolute; "" = no place to save
g_heat_saved:  f64    // g_time of the last save (or attempt)
g_heat_warned: bool   // a heat file problem was reported once
g_heat_nosave: bool   // the file is a format this build doesn't know: never write it

// heat_exe_dir: the folder of the running doodle.exe (absolute). The OS's own
// answer first; else os.args[0] made absolute against the working folder, which
// nothing changes after startup (this runs before anything else could). Owned.
heat_exe_dir :: proc() -> string {
	if p, err := os.get_executable_path(context.allocator); err == nil && p != "" {
		d, _ := os.split_path(p)
		dir := strings.clone(d)
		delete(p)
		return dir
	}
	if len(os.args) > 0 {
		if abs, err := os.get_absolute_path(os.args[0], context.temp_allocator); err == nil {
			d, _ := os.split_path(abs)
			return strings.clone(d)
		}
	}
	return ""
}

// heat_read_file reads the heat file. ok = false when it exists but couldn't be
// read (retried once: another Doodle may be renaming it right now); a missing
// file is ok with no data. Caller deletes data.
heat_read_file :: proc() -> (data: []byte, ok: bool) {
	for attempt in 0 ..< 2 {
		d, err := os.read_entire_file(g_heat_path, context.allocator)
		if err == nil do return d, true
		if err == .Not_Exist do return nil, true
		if attempt == 0 do time.sleep(50 * time.Millisecond)
	}
	return nil, false
}

// heat_store_init loads the heat file and hands the store to the model.
heat_store_init :: proc(m: ^model.App) {
	dir := heat_exe_dir()
	defer delete(dir)
	if dir != "" {
		if p, err := os.join_path({dir, HEAT_FILE}, context.allocator); err == nil do g_heat_path = p
	}
	if g_heat_path != "" {
		// Unreadable now: start without heat; saves re-read the file (and skip while it stays unreadable).
		if data, ok := heat_read_file(); ok && data != nil {
			if model.heat_text_ok(string(data)) do model.heat_parse(string(data), &g_heat)
			else do g_heat_nosave = true // a newer format: leave it alone
			delete(data)
		}
	}
	g_heat.dirty = false
	m.heat = &g_heat
}

// heat_store_tick (once per frame): save when menus were used, at most every HEAT_SAVE_EVERY.
heat_store_tick :: proc() {
	if g_heat.dirty && g_time - g_heat_saved >= HEAT_SAVE_EVERY do heat_store_save()
}

// heat_store_save merges this session's unsaved uses into the file as it is now
// and writes it: <path>.tmp, then renamed over <path> (core:os replaces an
// existing file: MoveFileExW REPLACE_EXISTING / rename(2)). On failure the uses
// stay pending (dirty) and are retried later / at quit.
heat_store_save :: proc() {
	g_heat_saved = g_time // also throttles retries after a failure
	if g_heat_path == "" || g_heat_nosave {
		g_heat.dirty = false // nowhere to save
		return
	}
	data, ok := heat_read_file()
	defer delete(data)
	if !ok {
		heat_store_warn("could not read menu heat (doodle_heat.tsv); not saved")
		return
	}
	if !model.heat_text_ok(string(data)) {
		g_heat_nosave = true
		heat_store_warn("doodle_heat.tsv is from a newer Doodle; menu heat not saved")
		return
	}
	merged := model.heat_merged(&g_heat, string(data))
	text := model.heat_serialize(&merged, context.temp_allocator)
	tmp := strings.concatenate({g_heat_path, ".tmp"}, context.temp_allocator)
	err := os.write_entire_file(tmp, transmute([]byte)text)
	if err == nil {
		err = os.rename(tmp, g_heat_path)
		if err != nil do _ = os.remove(tmp)
	}
	if err != nil {
		model.heat_free(&merged)
		heat_store_warn("could not save menu heat (doodle_heat.tsv)")
		return
	}
	// Saved: show the merged counts (other Doodles' uses too) from now on.
	model.heat_adopt(&g_heat, &merged)
}

// heat_store_warn reports a heat file problem (once per session).
heat_store_warn :: proc(msg: string) {
	if g_heat_warned do return
	g_heat_warned = true
	set_status(msg)
}

// heat_store_shutdown saves what's left and frees the store.
heat_store_shutdown :: proc(m: ^model.App) {
	if g_heat.dirty do heat_store_save()
	m.heat = nil
	model.heat_free(&g_heat)
	delete(g_heat_path)
	g_heat_path = ""
}

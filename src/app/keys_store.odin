package main

// The button layout's file (model/keymap.odin): doodle_keys.tsv next to
// doodle.exe, like doodle_heat.tsv. Loaded at startup and saved right after
// every change on the Key Layout page (it's tiny, so quitting with the page open
// loses nothing; two Doodles: the last save wins). A missing file means the
// defaults; a file that exists but can't be read, or is a newer format, is never
// overwritten. Failures never stop the editor.
//
// For the trace harness: keys_store_override pins the layout for a replay and
// stops saving (as g_heat_nosave does for the heatmap); keys_store_text is the
// current layout as text (for a recording). trace.odin records the layout with
// each run and pins a replay to it, so a replay never depends on, or changes,
// this machine's doodle_keys.tsv.

import "../model"
import "core:os"
import "core:strings"
import "core:time"

KEYS_FILE :: "doodle_keys.tsv"

g_keymap:      model.Keymap
g_keys_path:   string // absolute; "" = no place to save
g_keys_nosave: bool   // newer format / unreadable file / replay: never write it
g_keys_warned: bool   // a keys file problem was reported once
g_keys_pinned: bool   // keys_store_override set the layout (a replay): nothing may change it but the page

// keys_store_init loads the layout and hands it to the model. Runs before
// trace_start, so a replay can override it.
keys_store_init :: proc(m: ^model.App) {
	g_keymap = model.KEYMAP_DEFAULT
	m.keymap = &g_keymap
	dir := heat_exe_dir()
	defer delete(dir)
	if dir == "" do return
	if p, err := os.join_path({dir, KEYS_FILE}, context.allocator); err == nil do g_keys_path = p
	if g_keys_path == "" do return
	data, ok := keys_read_file()
	defer delete(data)
	switch {
	case !ok:
		g_keys_nosave = true
		keys_store_warn("could not read the key layout (doodle_keys.tsv); using the defaults")
	case data == nil: // no file yet: the defaults
	case !model.keys_text_ok(string(data)):
		g_keys_nosave = true
		keys_store_warn("doodle_keys.tsv is from a newer Doodle; using the default buttons")
	case:
		g_keymap, _ = model.keymap_parse(string(data))
	}
}

// keys_read_file: ok = false when the file exists but couldn't be read (retried
// once: another Doodle may be renaming it right now). Missing: ok, no data.
keys_read_file :: proc() -> (data: []byte, ok: bool) {
	for attempt in 0 ..< 2 {
		d, err := os.read_entire_file(g_keys_path, context.allocator)
		if err == nil do return d, true
		if err == .Not_Exist do return nil, true
		if attempt == 0 do time.sleep(50 * time.Millisecond)
	}
	return nil, false
}

// keys_store_save writes <path>.tmp, then renames it over <path>.
keys_store_save :: proc() {
	if g_keys_path == "" || g_keys_nosave do return
	if !trace_write_ok(g_keys_path) do return // TRACE hook: a replay writes only inside its sandbox
	text := model.keymap_serialize(&g_keymap, context.temp_allocator)
	tmp := strings.concatenate({g_keys_path, ".tmp"}, context.temp_allocator)
	err := os.write_entire_file(tmp, transmute([]byte)text)
	if err == nil {
		err = os.rename(tmp, g_keys_path)
		if err != nil do _ = os.remove(tmp)
	}
	if err != nil do keys_store_warn("could not save the key layout (doodle_keys.tsv)")
}

// keys_store_override pins the layout to `text` (a keys file's contents; "" =
// the defaults) and never saves again this session. For the trace harness: a
// replay runs with the layout it was recorded with and leaves the file alone.
keys_store_override :: proc(text: string) {
	g_keys_nosave = true
	g_keys_pinned = true
	g_keymap = model.KEYMAP_DEFAULT
	if text != "" do g_keymap, _ = model.keymap_parse(text)
}

// keys_store_text: the current layout in the file format (for a recording's meta).
keys_store_text :: proc(allocator := context.allocator) -> string {
	return model.keymap_serialize(&g_keymap, allocator)
}

// keys_store_warn reports a keys file problem (once per session).
keys_store_warn :: proc(msg: string) {
	if g_keys_warned do return
	g_keys_warned = true
	set_status(msg)
}

keys_store_shutdown :: proc(m: ^model.App) {
	m.keymap = nil
	delete(g_keys_path)
	g_keys_path = ""
}

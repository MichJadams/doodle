package main

// Extra project folders (model/project_roots.odin): doodle_roots.txt next to
// doodle.exe, like doodle_keys.tsv. Loaded at startup and saved right after
// every change in New Project's folder picker (new_project.odin). A missing
// file means no extra folders; a file that exists but can't be read, or is a
// newer format, is never overwritten. Failures never stop the editor.
//
// The default folder (g_projects_dir, save.odin) is never in the file: it is
// always the first choice.
//
// For the trace harness: roots_store_override pins the list for a replay (to
// stand-in folders inside the sandbox) and stops saving, as keys_store_override
// does for the button layout.

import "../model"
import "core:os"
import "core:strings"
import "core:time"

ROOTS_FILE :: "doodle_roots.txt"

g_roots:        [dynamic]string // the extra folders, in the order they were added (owned)
g_roots_path:   string          // absolute; "" = no place to save
g_roots_nosave: bool            // newer format / unreadable file / replay: never write it
g_roots_warned: bool            // a roots file problem was reported once
g_roots_legacy: bool            // replaying a run recorded before New Project asked where: it doesn't ask

// roots_store_init loads the list. Runs before trace_start, so a replay can
// override it.
roots_store_init :: proc() {
	dir := heat_exe_dir()
	defer delete(dir)
	if dir == "" do return
	if p, err := os.join_path({dir, ROOTS_FILE}, context.allocator); err == nil do g_roots_path = p
	if g_roots_path == "" do return
	data, ok := roots_read_file()
	defer delete(data)
	switch {
	case !ok:
		g_roots_nosave = true
		roots_store_warn("could not read the project folders list (doodle_roots.txt)")
	case data == nil: // no file yet: no extra folders
	case !model.roots_text_ok(string(data)):
		g_roots_nosave = true
		roots_store_warn("doodle_roots.txt is from a newer Doodle; extra project folders are off")
	case:
		g_roots = model.roots_parse(string(data))
	}
}

// roots_read_file: ok = false when the file exists but couldn't be read
// (retried once: another Doodle may be renaming it right now). Missing: ok, no data.
@(private = "file")
roots_read_file :: proc() -> (data: []byte, ok: bool) {
	for attempt in 0 ..< 2 {
		d, err := os.read_entire_file(g_roots_path, context.allocator)
		if err == nil do return d, true
		if err == .Not_Exist do return nil, true
		if attempt == 0 do time.sleep(50 * time.Millisecond)
	}
	return nil, false
}

// roots_store_save writes <path>.tmp, then renames it over <path>. false = not
// saved (no place to save, an unreadable / newer file, a replay, a write error).
roots_store_save :: proc() -> bool {
	if g_roots_path == "" || g_roots_nosave do return false
	if !trace_write_ok(g_roots_path) do return false // TRACE hook: a replay writes only inside its sandbox
	text := model.roots_serialize(g_roots[:], context.temp_allocator)
	tmp := strings.concatenate({g_roots_path, ".tmp"}, context.temp_allocator)
	err := os.write_entire_file(tmp, transmute([]byte)text)
	if err == nil {
		err = os.rename(tmp, g_roots_path)
		if err != nil do _ = os.remove(tmp)
	}
	return err == nil
}

// roots_store_override replaces the list with `roots` (copied) and never saves
// again this session. legacy: New Project goes straight to the editor, as it
// did before it asked where (for replaying old recordings).
roots_store_override :: proc(roots: []string, legacy: bool) {
	g_roots_nosave = true
	g_roots_legacy = legacy
	model.roots_free(&g_roots)
	for r in roots do append(&g_roots, strings.clone(r))
}

// roots_store_warn reports a roots file problem (once per session).
@(private = "file")
roots_store_warn :: proc(msg: string) {
	if g_roots_warned do return
	g_roots_warned = true
	set_status(msg)
}

roots_store_shutdown :: proc() {
	model.roots_free(&g_roots)
	if g_roots_path != "" do delete(g_roots_path)
	g_roots_path = ""
}

// all_roots: the default projects folder, then the extra ones. Temp-allocated.
all_roots :: proc() -> []string {
	out := make([dynamic]string, 0, len(g_roots) + 1, context.temp_allocator)
	if g_projects_dir != "" do append(&out, g_projects_dir)
	append(&out, ..g_roots[:])
	return out[:]
}

// project_root_of: the project folder holding `file` under any root (the first
// folder below the root on its path; model.fgrid_project_root). Roots can nest
// (a folder added inside DoodleProjects): the deepest one wins.
project_root_of :: proc(file: string) -> (root: string, ok: bool) {
	best := -1
	for r in all_roots() {
		if p, pok := model.fgrid_project_root(file, r); pok && len(r) > best {
			root, ok, best = p, true, len(r)
		}
	}
	return
}

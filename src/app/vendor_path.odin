package main

// Vendor libraries for a Run. A project that imports an Odin vendor library
// with a shared library (`import "vendor:sdl3"` -> SDL3.dll in
// <odin>/vendor/sdl3; model/vendor_libs.odin) can't even start unless the
// system finds that file. Before running, Doodle looks at the project's
// imports; when a library can't be found it asks:
//
//   Add to my PATH (permanently)   the user PATH (Windows registry) / a line in
//                                  ~/.profile (Linux, macOS) - the program then
//                                  also runs outside Doodle
//   Just this run                  (not asked again until Doodle restarts)
//   Cancel
//
// The run itself always gets the folders on its PATH / LD_LIBRARY_PATH: a
// changed user PATH reaches only programs started after it, and Doodle (and
// so its runs) started before. Platform parts: vendor_path_windows.odin,
// vendor_path_other.odin.

import "../gpu"
import "../model"
import "../text"
import "core:fmt"
import "core:os"
import "core:strings"

LIB_OS :: model.Lib_OS.Windows when ODIN_OS == .Windows else (model.Lib_OS.Darwin when ODIN_OS == .Darwin else model.Lib_OS.Linux)

// One vendor library the project imports that has a shared library file.
Vendor_Need :: struct {
	import_path: string,   // vendor:sdl3
	dir:         string,   // <odin>\vendor\sdl3 (native separators)
	libs:        []string, // SDL3.dll
	found:       bool,     // the system finds every one of them already
}

// vendor_needs: the project's vendor libraries (its folder's .odin files'
// imports) that come with a shared library on this OS. Temp-allocated.
vendor_needs :: proc(project_dir: string) -> []Vendor_Need {
	out := make([dynamic]Vendor_Need, 0, 4, context.temp_allocator)
	od := odin_dir()
	if od == "" || project_dir == "" do return out[:]
	imports := make([dynamic]string, 0, 4, context.temp_allocator)
	files, err := os.read_directory_by_path(project_dir, -1, context.temp_allocator)
	if err != nil do return out[:]
	for f in files do if f.type != .Directory && strings.has_suffix(f.name, ".odin") {
		if data, rerr := os.read_entire_file(f.fullpath, context.temp_allocator); rerr == nil do model.vendor_imports(string(data), &imports)
	}
	if len(imports) == 0 do return out[:]
	search := lib_search_dirs()
	for imp in imports {
		dir := native_path(model.vendor_lib_dir(od, imp))
		entries, lerr := os.read_directory_by_path(dir, -1, context.temp_allocator)
		if lerr != nil do continue
		libs := make([dynamic]string, 0, 2, context.temp_allocator)
		for e in entries do if e.type != .Directory && model.is_shared_lib(e.name, LIB_OS) do append(&libs, strings.clone(e.name, context.temp_allocator))
		if len(libs) == 0 do continue // a system library (Linux) or a static one: nothing to add
		found := lib_dir_on_path(dir)
		if !found {
			found = true
			for l in libs do if !lib_findable(l, project_dir, search) { found = false; break }
		}
		append(&out, Vendor_Need{imp, dir, libs[:], found})
	}
	return out[:]
}

// Next to the program (`odin run .` builds it in the project folder), or in a
// folder the system searches.
@(private = "file")
lib_findable :: proc(name, project_dir: string, search: []string) -> bool {
	sep := ODIN_OS == .Windows ? "\\" : "/"
	if os.exists(strings.concatenate({project_dir, sep, name}, context.temp_allocator)) do return true
	for d in search do if os.exists(strings.concatenate({strings.trim_right(d, "\\/"), sep, name}, context.temp_allocator)) do return true
	return false
}

@(private = "file")
native_path :: proc(p: string) -> string {
	when ODIN_OS == .Windows {
		s, _ := strings.replace_all(p, "/", "\\", context.temp_allocator)
		return s
	} else {
		return p
	}
}

// ---- Before a run ----

g_vp_open:     bool
g_vp_index:    int
g_vp_cmd:      string          // the run waiting for an answer (owned)
g_vp_dir:      string          // its folder (owned)
g_vp_keep:     bool
g_vp_libdirs:  [dynamic]string // every needed folder, for the run's path (owned)
g_vp_missing:  [dynamic]Vendor_Need // what the prompt asks about (strings owned)
g_vp_declined: [dynamic]string // "Just this run" folders: not asked again this session (owned)

// vendor_run: run cmd in dir with its vendor libraries reachable - asking
// first when one isn't on the system's path (and wasn't waved through).
vendor_run :: proc(cmd, dir: string, keep_open: bool) {
	needs := vendor_needs(dir)
	libdirs := make([dynamic]string, 0, len(needs), context.temp_allocator)
	missing := make([dynamic]Vendor_Need, 0, len(needs), context.temp_allocator)
	for n in needs {
		append(&libdirs, n.dir)
		if n.found do continue
		declined := false
		for d in g_vp_declined do if d == n.dir { declined = true; break }
		if !declined do append(&missing, n)
	}
	if len(missing) == 0 {
		run_launch(cmd, dir, keep_open, libdirs[:])
		return
	}
	vendor_prompt_clear()
	g_vp_cmd = strings.clone(cmd)
	g_vp_dir = strings.clone(dir)
	g_vp_keep = keep_open
	for d in libdirs do append(&g_vp_libdirs, strings.clone(d))
	for m in missing {
		libs := make([]string, len(m.libs))
		for l, i in m.libs do libs[i] = strings.clone(l)
		append(&g_vp_missing, Vendor_Need{strings.clone(m.import_path), strings.clone(m.dir), libs, false})
	}
	g_vp_index = 0
	g_vp_open = true
}

@(private = "file")
vendor_prompt_clear :: proc() {
	if g_vp_cmd != "" do delete(g_vp_cmd)
	if g_vp_dir != "" do delete(g_vp_dir)
	g_vp_cmd, g_vp_dir = "", ""
	for d in g_vp_libdirs do delete(d)
	clear(&g_vp_libdirs)
	for m in g_vp_missing {
		delete(m.import_path)
		delete(m.dir)
		for l in m.libs do delete(l)
		delete(m.libs)
	}
	clear(&g_vp_missing)
}

VP_CHOICES :: [3]string{"Add to my PATH (permanently)" when ODIN_OS == .Windows else "Add to my library path (~/.profile)", "Just this run", "Cancel"}

handle_vendor_prompt_input :: proc(raw: ^Raw) {
	choices := VP_CHOICES
	n := len(choices)
	if raw.e_up   do g_vp_index = (g_vp_index - 1 + n) % n
	if raw.e_down do g_vp_index = (g_vp_index + 1) % n
	choose := -1
	if raw.e_confirm || raw.e_a do choose = g_vp_index
	if raw.e_cancel || raw.e_b do choose = 2
	raw.e_up = false; raw.e_down = false; raw.e_left = false; raw.e_right = false
	raw.e_confirm = false; raw.e_a = false; raw.e_cancel = false; raw.e_b = false
	if choose < 0 do return
	g_vp_open = false
	switch choose {
	case 0:
		msgs := make([dynamic]string, 0, len(g_vp_missing), context.temp_allocator)
		for m in g_vp_missing {
			_, msg := user_path_add(m.dir, m.import_path)
			append(&msgs, msg)
		}
		run_launch(g_vp_cmd, g_vp_dir, g_vp_keep, g_vp_libdirs[:])
		set_status(strings.join(msgs[:], "; ", context.temp_allocator)) // after the "ran: ..." status
	case 1:
		for m in g_vp_missing do append(&g_vp_declined, strings.clone(m.dir))
		run_launch(g_vp_cmd, g_vp_dir, g_vp_keep, g_vp_libdirs[:])
	case:
		set_status("run cancelled")
	}
	vendor_prompt_clear()
}

draw_vendor_prompt :: proc(r: ^gpu.Renderer, w, h: int) {
	fw, fh := f32(w), f32(h)
	gpu.draw_rect(r, {0, 0, fw, fh}, COL_VEIL)
	where_ := ODIN_OS == .Windows ? "PATH" : "library path"
	text.draw_centered(r, g_ui, {0, fh * 0.07, fw, 36}, strings.to_upper(fmt.tprintf("library not on your %s", where_), context.temp_allocator), COL_ACCENT)
	y := fh * 0.15
	maxw := fw - 120
	for m in g_vp_missing {
		line := fmt.tprintf("%s needs %s - it's in %s, which the system can't find yet.", m.import_path, strings.join(m.libs, ", ", context.temp_allocator), m.dir)
		text.draw_centered(r, g_ui, {0, y, fw, 26}, fit_label(g_ui, line, maxw), COL_TEXT)
		y += 30
	}
	text.draw_centered(r, g_ui, {0, y + 4, fw, 26}, fit_label(g_ui, "Doodle adds it for this run either way. Added for good, the program also runs outside Doodle.", maxw), COL_DIM)
	y += 52
	cellw := min(f32(560), fw - 80)
	cellh := f32(46)
	choices := VP_CHOICES
	for c, i in choices {
		box := gpu.Rect{(fw - cellw) * 0.5, y + f32(i) * (cellh + 10), cellw, cellh}
		active := i == g_vp_index
		gpu.draw_rect(r, box, active ? COL_HILITE : COL_PANEL)
		if active do gpu.draw_rect_outline(r, box, 2, COL_ACCENT)
		text.draw_centered(r, g_ui, box, c, COL_TEXT)
	}
	text.draw_centered(r, g_ui, {0, f32(h) - 172, fw, 24}, "D-pad move   A choose   B cancel", COL_DIM)
}

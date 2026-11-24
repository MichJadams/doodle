package main

// Odin's stb libraries on Linux / Steam Deck. `vendor:stb/image`, `/truetype`,
// `/rect_pack`, `/vorbis`, ... are bindings to C code that has to be compiled
// into <odin>/vendor/stb/lib/*.a first. Odin's Windows release ships those
// files built; its Linux release ships only the C source and
// vendor/stb/src/build_stb.sh, and until that has run once every program that
// imports a vendor:stb package fails ("Could not find the compiled STB
// libraries") - `odin check` included.
//
// Doodle builds them:
//   - in Settings > Setup > clang (toolchain.odin), right after Zig is set up
//     (the script needs cc / ar, which SteamOS doesn't have either), and
//   - before a Run of a project that imports vendor:stb while they're missing
//     (a newer Odin unpacked over the old one starts without them), asking:
//
//       Build them now     build_stb.sh runs first, in the run's window
//       Run anyway         (asked again next time)
//       Cancel
//
// Linux only: Windows has them built; macOS has Xcode's tools.

import "../gpu"
import "../model"
import "../text"
import "core:fmt"
import "core:os"
import "core:strings"

STB_OFFERED :: ODIN_OS == .Linux

// odin_root: the folder holding the Odin compiler - odin_dir()'s, else the
// first `odin` on PATH ("" = not found). Temp-allocated.
odin_root :: proc() -> string {
	if od := odin_dir(); od != "" do return od
	for d in strings.split(os.get_env("PATH", context.temp_allocator), ":", context.temp_allocator) {
		if d != "" && os.exists(fmt.tprintf("%s/%s", d, ODIN_EXE_NAME)) do return d
	}
	return ""
}

// stb_built: are <root>/vendor/stb/lib's static libraries there?
stb_built :: proc(root: string) -> bool {
	entries, err := os.read_directory_by_path(fmt.tprintf("%s/vendor/stb/lib", root), -1, context.temp_allocator)
	if err != nil do return false
	for e in entries do if strings.has_suffix(e.name, ".a") do return true
	return false
}

// stb_needed: does the project import a vendor:stb package while the
// libraries aren't built? root: the Odin folder they'd go in.
stb_needed :: proc(project_dir: string) -> (root: string, needed: bool) {
	when !STB_OFFERED do return "", false
	if project_dir == "" do return "", false
	root = odin_root()
	if root == "" || stb_built(root) do return root, false
	imports := make([dynamic]string, 0, 4, context.temp_allocator)
	files, err := os.read_directory_by_path(project_dir, -1, context.temp_allocator)
	if err != nil do return root, false
	for f in files do if f.type != .Directory && strings.has_suffix(f.name, ".odin") {
		if data, rerr := os.read_entire_file(f.fullpath, context.temp_allocator); rerr == nil do model.vendor_imports(string(data), &imports)
	}
	for imp in imports do if imp == "vendor:stb" || strings.has_prefix(imp, "vendor:stb/") do return root, true
	return root, false
}

// stb_build_command: the shell command that builds them (cc / ar from PATH -
// the run script puts Settings > Setup > clang's folder there).
stb_build_command :: proc(root: string) -> string {
	return fmt.tprintf("sh %s", sh_quote(fmt.tprintf("%s/vendor/stb/src/build_stb.sh", root)))
}

// ---- Before a run ----

g_sb_open:  bool
g_sb_index: int
g_sb_root:  string // the Odin folder (owned)
g_sb_cmd:   string // the run waiting for an answer (owned)
g_sb_dir:   string // its folder (owned)
g_sb_keep:  bool

SB_CHOICES :: [3]string{"Build them now (once)", "Run anyway", "Cancel"}

// stb_run: the run, after asking about the stb libraries if they're needed
// and missing (run.odin, before the vendor library check).
stb_run :: proc(cmd, dir: string, keep_open: bool) {
	root, needed := stb_needed(dir)
	if !needed {
		vendor_run(cmd, dir, keep_open)
		return
	}
	stb_prompt_clear()
	g_sb_root = strings.clone(root)
	g_sb_cmd = strings.clone(cmd)
	g_sb_dir = strings.clone(dir)
	g_sb_keep = keep_open
	g_sb_index = 0
	g_sb_open = true
}

@(private = "file")
stb_prompt_clear :: proc() {
	for s in ([]^string{&g_sb_root, &g_sb_cmd, &g_sb_dir}) {
		if s^ != "" do delete(s^)
		s^ = ""
	}
}

handle_stb_prompt_input :: proc(raw: ^Raw) {
	choices := SB_CHOICES
	n := len(choices)
	if raw.e_up   do g_sb_index = (g_sb_index - 1 + n) % n
	if raw.e_down do g_sb_index = (g_sb_index + 1) % n
	choose := -1
	if raw.e_confirm || raw.e_a do choose = g_sb_index
	if raw.e_cancel || raw.e_b do choose = 2
	raw.e_up = false; raw.e_down = false; raw.e_left = false; raw.e_right = false
	raw.e_confirm = false; raw.e_a = false; raw.e_cancel = false; raw.e_b = false
	if choose < 0 do return
	g_sb_open = false
	switch choose {
	case 0:
		// Build first, in the same window, then the run (only if the build worked).
		vendor_run(fmt.tprintf("%s && %s", stb_build_command(g_sb_root), g_sb_cmd), g_sb_dir, g_sb_keep)
	case 1:
		vendor_run(g_sb_cmd, g_sb_dir, g_sb_keep)
	case:
		set_status("run cancelled")
	}
	stb_prompt_clear()
}

draw_stb_prompt :: proc(r: ^gpu.Renderer, w, h: int) {
	fw, fh := f32(w), f32(h)
	gpu.draw_rect(r, {0, 0, fw, fh}, COL_VEIL)
	text.draw_centered(r, g_ui, {0, fh * 0.07, fw, 36}, "STB LIBRARIES NOT BUILT YET", COL_ACCENT)
	maxw := fw - 120
	y := fh * 0.15
	lines := [?]string{
		"This project imports vendor:stb. Odin's Linux release has stb as C source only:",
		fmt.tprintf("it has to be built once into %s/vendor/stb/lib before anything using it can build.", g_sb_root),
	}
	for l in lines {
		text.draw_centered(r, g_ui, {0, y, fw, 26}, fit_label(g_ui, l, maxw), COL_TEXT)
		y += 30
	}
	note := "Building takes a few seconds and shows in the run's window."
	if toolchain_bin() == "" && !find_in_path("cc") do note = "It needs a C compiler - install one first: main menu > Settings > Setup > clang."
	text.draw_centered(r, g_ui, {0, y + 4, fw, 26}, fit_label(g_ui, note, maxw), COL_DIM)
	y += 52
	cellw := min(f32(560), fw - 80)
	cellh := f32(46)
	choices := SB_CHOICES
	for c, i in choices {
		box := gpu.Rect{(fw - cellw) * 0.5, y + f32(i) * (cellh + 10), cellw, cellh}
		active := i == g_sb_index
		gpu.draw_rect(r, box, active ? COL_HILITE : COL_PANEL)
		if active do gpu.draw_rect_outline(r, box, 2, COL_ACCENT)
		text.draw_centered(r, g_ui, box, c, COL_TEXT)
	}
	text.draw_centered(r, g_ui, {0, f32(h) - 172, fw, 24}, "D-pad move   A choose   B cancel", COL_DIM)
}

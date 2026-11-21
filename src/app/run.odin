package main

// Run commands: save and execute shell commands within the current project.

import "../model"
import "../gpu"
import "../text"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:c/libc"

// --- Run command definition ---

Run_Cmd :: struct {
	cmd:      string,
	favorite: bool,
}

// --- Globals ---

g_run_cmds:      [dynamic]Run_Cmd  // List of saved run commands
g_run_open:      bool              // Run overlay is active
g_run_index:     int               // Selected index in run list
g_run_loaded:    bool              // Lazy load flag
g_run_msg:       string            // Last run message
g_run_msg_time:  f64               // Time when message was shown
g_run_submenu:   bool              // Template submenu is open
g_run_tmpl_idx:  int               // Selected template index

RUN_MSG_DURATION :: 2.0 // Show run message for 2 seconds

// Template commands for "+ New command" submenu
TEMPLATES := [?]string{
	"odin run .",
	"odin build . -out:app.exe",
	"odin test .",
	"odin run . -debug",
}

// --- Persistence ---

// run_cmds_path returns the path to the run commands file.
run_cmds_path :: proc() -> string {
	if g_project_dir == "" do return ""
	return fmt.tprintf("%s/.doodle/run.txt", g_project_dir)
}

// load_run_cmds reads saved run commands from disk.
load_run_cmds :: proc() {
	if g_run_loaded do return
	g_run_loaded = true

	for c in g_run_cmds do delete(c.cmd)
	clear(&g_run_cmds)
	
	path := run_cmds_path()
	if path == "" do return
	
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	
	content := string(data)
	lines := strings.split_lines(content, context.temp_allocator)
	
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		
		cmd: Run_Cmd
		if strings.has_prefix(trimmed, "*") {
			cmd.favorite = true
			cmd.cmd = strings.clone(strings.trim_space(trimmed[1:]))
		} else {
			cmd.favorite = false
			cmd.cmd = strings.clone(trimmed)
		}
		append(&g_run_cmds, cmd)
	}
	
	// If no commands were loaded, seed with default
	ensure_default_run()
}

// ensure_default_run seeds a default favorite command if the list is empty.
ensure_default_run :: proc() {
	if len(g_run_cmds) == 0 {
		append(&g_run_cmds, Run_Cmd{strings.clone("odin run ."), true})
	}
}

// save_run_cmds writes run commands to disk.
save_run_cmds :: proc() {
	path := run_cmds_path()
	if path == "" do return
	
	if !trace_write_ok(path) do return // TRACE hook: a replay writes only inside its sandbox

	// Ensure .doodle directory exists
	dir := fmt.tprintf("%s/.doodle", g_project_dir)
	os.make_directory(dir)
	
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	
	for cmd in g_run_cmds {
		if cmd.favorite {
			strings.write_string(&sb, "*")
		}
		strings.write_string(&sb, cmd.cmd)
		strings.write_string(&sb, "\n")
	}
	
	content := strings.to_string(sb)
	_ = os.write_entire_file(path, transmute([]byte)content)
}

// --- Running commands ---

// run_command executes a command with cwd = g_project_dir in a visible console window.
// keep_open leaves the console up even on success (test results are worth reading).
run_command :: proc(cmd: string, keep_open := false) {
	if cmd == "" do return
	
	// Save first so the command runs the code that's on screen.
	if g_app != nil && !save_current(g_app) do return

	// Use g_project_dir as working directory, or current dir if not set
	dir := g_project_dir
	if dir == "" {
		dir = "."
	}
	// cmd.exe wants backslashes; quote the path in case it has spaces.
	win_dir, _ := strings.replace_all(dir, "/", "\\", context.temp_allocator)

	// Make sure `odin` resolves even if Doodle was launched from an environment
	// whose PATH doesn't include the compiler (e.g. a shell started before PATH changed).
	path_prefix := ""
	if od := odin_dir(); od != "" {
		path_prefix = fmt.tprintf("set \"PATH=%s;%%PATH%%\" && ", od)
	}

	// Build command to open a new visible console that stays open:
	// cmd /c start "Doodle Run" cmd /c "set "PATH=<odin>;%PATH%" && cd /d "<dir>" && <cmd> || pause"
	// The console closes by itself when the program ends normally; if the build
	// fails or the program exits with an error, `pause` keeps it open to read.
	tail := keep_open ? "& pause" : "|| pause"
	full_cmd := fmt.tprintf("cmd /c start \"Doodle Run\" cmd /c \"%scd /d \"%s\" && %s %s\"", path_prefix, win_dir, cmd, tail)

	// Convert to C string and execute
	cstr := strings.clone_to_cstring(full_cmd, context.temp_allocator)
	if !trace_replaying() do libc.system(cstr) // TRACE hook (was: unconditional): a replay doesn't run programs

	set_status(fmt.tprintf("ran: %s", cmd))
}

// odin_dir finds the folder holding odin.exe (backslashed, temp-allocated), or "".
// Order: $ODIN_DIR, $ODIN_ROOT, then the default install at C:\Odin.
odin_dir :: proc() -> string {
	when ODIN_OS != .Windows do return ""
	candidates := [?]string{
		os.get_env("ODIN_DIR", context.temp_allocator),
		os.get_env("ODIN_ROOT", context.temp_allocator),
		"C:\\Odin",
	}
	for c in candidates {
		if c == "" do continue
		if os.exists(fmt.tprintf("%s\\odin.exe", c)) {
			d, _ := strings.replace_all(c, "/", "\\", context.temp_allocator)
			return d
		}
	}
	return ""
}

// set_status shows a short message in the bottom-right corner (save/run feedback).
set_status :: proc(msg: string) {
	if g_run_msg != "" do delete(g_run_msg)
	g_run_msg = strings.clone(msg)
	g_run_msg_time = g_time
}

// run_favorite runs the command marked as favorite.
run_favorite :: proc() {
	load_run_cmds()
	ensure_default_run()
	
	for cmd in g_run_cmds {
		if cmd.favorite {
			run_command(cmd.cmd)
			return
		}
	}
	
	// No favorite found (shouldn't happen with ensure_default_run)
	set_status("No favorite command set")
}

// TEST_CMD is what LB runs: the package's @(test) procedures.
TEST_CMD :: "odin test ."

// run_tests saves, then runs the project's tests (LB) in a visible console.
run_tests :: proc() {
	run_command(TEST_CMD, keep_open = true)
}

// toggle_favorite toggles the favorite flag on a command (only one favorite at a time).
toggle_favorite :: proc(idx: int) {
	if idx < 0 || idx >= len(g_run_cmds) do return
	
	// Clear all favorites first
	for &cmd in g_run_cmds {
		cmd.favorite = false
	}
	
	// Set this one as favorite
	g_run_cmds[idx].favorite = true
	save_run_cmds()
}

// add_template adds a template command to the list.
add_template :: proc(tmpl: string) {
	cmd := Run_Cmd{
		cmd = strings.clone(tmpl),
		favorite = false,
	}
	append(&g_run_cmds, cmd)
	save_run_cmds()
}

// --- Input handling ---

// handle_run_input processes input when the run overlay is active.
handle_run_input :: proc(raw: ^Raw) {
	load_run_cmds()
	
	n := len(g_run_cmds) + 1 // +1 for "+ New command"
	
	if g_run_submenu {
		// Handle template submenu
		nt := len(TEMPLATES)
		
		// Navigation
		if raw.e_up {
			g_run_tmpl_idx -= 1
			if g_run_tmpl_idx < 0 do g_run_tmpl_idx = nt - 1
			raw.e_up = false
		}
		if raw.e_down {
			g_run_tmpl_idx += 1
			if g_run_tmpl_idx >= nt do g_run_tmpl_idx = 0
			raw.e_down = false
		}
		
		// Select template
		if raw.e_confirm || raw.e_a {
			add_template(TEMPLATES[g_run_tmpl_idx])
			g_run_submenu = false
			raw.e_confirm = false
			raw.e_a = false
		}
		
		// Back to main list
		if raw.e_cancel || raw.e_b {
			g_run_submenu = false
			raw.e_cancel = false
			raw.e_b = false
		}
		
		return
	}
	
	// Build input for grid navigation
	inp := model.Input{
		up    = raw.e_up,
		down  = raw.e_down,
		left  = raw.e_left,
		right = raw.e_right,
	}
	
	// Update index with grid navigation
	g_run_index = model.grid_nav(g_run_index, n, inp)
	
	// Consume navigation edges
	if raw.e_up do raw.e_up = false
	if raw.e_down do raw.e_down = false
	if raw.e_left do raw.e_left = false
	if raw.e_right do raw.e_right = false
	
	// Y toggles favorite
	if raw.e_y {
		if g_run_index < len(g_run_cmds) {
			toggle_favorite(g_run_index)
		}
		raw.e_y = false
	}
	
	// A/confirm selects
	if raw.e_confirm || raw.e_a {
		if g_run_index < len(g_run_cmds) {
			// Run the selected command
			run_command(g_run_cmds[g_run_index].cmd)
			g_run_open = false
		} else {
			// Open template submenu
			g_run_submenu = true
			g_run_tmpl_idx = 0
		}
		raw.e_confirm = false
		raw.e_a = false
	}
	
	// B/cancel closes
	if raw.e_cancel || raw.e_b {
		g_run_open = false
		raw.e_cancel = false
		raw.e_b = false
	}
}

// --- Drawing ---

// draw_run_overlay renders the run command list as a centered overlay.
draw_run_overlay :: proc(r: ^gpu.Renderer, w, h: int) {
	load_run_cmds()
	
	fw, fh := f32(w), f32(h)
	
	// Semi-transparent background
	gpu.draw_rect(r, {0, 0, fw, fh}, COL_VEIL)
	
	if g_run_submenu {
		// Draw template submenu
		draw_template_submenu(r, w, h)
		return
	}
	
	// Title
	text.draw_centered(r, g_ui, {0, fh * 0.07, fw, 36}, "RUN COMMANDS", COL_ACCENT)
	
	n := len(g_run_cmds) + 1 // +1 for "+ New command"
	if n == 1 {
		// No commands yet, just show "+ New command"
		text.draw_centered(r, g_ui, {0, fh * 0.4, fw, 30}, "+ New command", COL_TEXT)
		return
	}
	
	// Grid layout
	cols := model.grid_cols(n)
	rows := (n + cols - 1) / cols
	
	gap := f32(12)
	vgap := f32(10)
	cellw := f32(280)
	cellh := f32(50)
	
	grid_w := f32(cols) * cellw + f32(cols - 1) * gap
	start_x := (fw - grid_w) * 0.5
	start_y := fh * 0.16
	
	// Draw entries
	for i in 0 ..< n {
		col := i % cols
		row := i / cols
		
		x := start_x + f32(col) * (cellw + gap)
		y := start_y + f32(row) * (cellh + vgap)
		box := gpu.Rect{x, y, cellw, cellh}
		
		active := i == g_run_index
		
		gpu.draw_rect(r, box, active ? COL_HILITE : COL_PANEL)
		if active do gpu.draw_rect_outline(r, box, 2, COL_ACCENT)
		
		if i < len(g_run_cmds) {
			// Regular command
			cmd := g_run_cmds[i]
			label := cmd.cmd
			if cmd.favorite {
				label = fmt.tprintf("* %s", cmd.cmd)
			}
			
			// Fit label to cell width
			label_fitted := fit_run_label(g_ui, label, cellw - 10)
			text.draw_centered(r, g_ui, box, label_fitted, COL_TEXT)
		} else {
			// "+ New command" entry
			text.draw_centered(r, g_ui, box, "+ New command", COL_DIM)
		}
	}
	
	// Hint
	hint := "D-pad move   A select   Y favorite   B back"
	text.draw_centered(r, g_ui, {0, f32(h) - 172, fw, 24}, hint, COL_DIM)
}

// draw_template_submenu renders the template selection submenu.
draw_template_submenu :: proc(r: ^gpu.Renderer, w, h: int) {
	fw, fh := f32(w), f32(h)
	
	// Title
	text.draw_centered(r, g_ui, {0, fh * 0.25, fw, 30}, "Choose a template:", COL_ACCENT)
	
	// List templates vertically
	n := len(TEMPLATES)
	cellh := f32(44)
	vgap := f32(8)
	start_y := fh * 0.35
	cellw := f32(400)
	start_x := (fw - cellw) * 0.5
	
	for tmpl, i in TEMPLATES {
		y := start_y + f32(i) * (cellh + vgap)
		box := gpu.Rect{start_x, y, cellw, cellh}
		
		active := i == g_run_tmpl_idx
		
		gpu.draw_rect(r, box, active ? COL_HILITE : COL_PANEL)
		if active do gpu.draw_rect_outline(r, box, 2, COL_ACCENT)
		
		text.draw_centered(r, g_ui, box, tmpl, COL_TEXT)
	}
	
	// Hint
	hint := "Up/Down select   A confirm   B back"
	text.draw_centered(r, g_ui, {0, f32(h) - 172, fw, 24}, hint, COL_DIM)
}

// fit_run_label truncates a label to fit within maxw pixels.
fit_run_label :: proc(font: ^text.Font, s: string, maxw: f32) -> string {
	if text.measure(font, s).x <= maxw do return s
	for end := len(s) - 1; end > 1; end -= 1 {
		cand := strings.concatenate({s[:end], ".."}, context.temp_allocator)
		if text.measure(font, cand).x <= maxw do return cand
	}
	return s
}

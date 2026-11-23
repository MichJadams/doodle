package main

// Trace harness: record every run, replay it, analyze it (docs/TRACE.md).
//
// DEBUG-ONLY. Compiled in when DOODLE_TRACE is true, which defaults to debug
// builds (`build.bat`, `build.bat run`); `build.bat release` leaves it out.
// Force it either way with -define:DOODLE_TRACE=true / false.
// When it's off, every hook below is a pass-through stub, so the app behaves
// (and compiles) exactly as if the harness didn't exist.
//
// Each run writes  <exe dir>/traces/<UTC stamp>/
//   input.log     exact per-frame input stream (+ STT text, random names, state
//                 fingerprints): what `--replay` feeds back in
//   events.jsonl  one JSON record per action with the screen / menu / selection
//                 before and after (tools/trace.py searches and reports on it)
//   snapshot/     a copy of the projects folder (and the folder of a file opened
//                 from the command line) as they were at startup
//
// Replay:  doodle --replay <last|stamp|dir> [--until FRAME] [--speed X] [--takeover] [--exact]
//   Replays inside a sandbox copy of the snapshot (traces/_replay), so it never
//   touches real files. F6 / Back pause, F7 / Right (paused) step one action,
//   F5 / Start take over; taking over records a new, self-contained trace.
// Recording is skipped with --no-trace or DOODLE_TRACE=0 in the environment.
//
// Hooks in other files are marked "TRACE hook" (grep for it). To remove the
// harness: delete this file, tools/trace.py and docs/TRACE.md, and undo each
// hook as listed in docs/TRACE.md ("Removing the harness").

import "../platform"
import "../model"
import "../stt"
import "../gpu"
import "../text"
import sdl "vendor:sdl2"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:time"
import "core:slice"
import "core:path/filepath"
import "core:encoding/json"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

TRACE :: #config(DOODLE_TRACE, ODIN_DEBUG)

when TRACE {

TRACE_FORMAT      :: "doodle-trace 1"
TRACE_KEEP        :: 40               // recordings kept (oldest deleted at startup)
TRACE_FILE_MAX    :: 4 * 1024 * 1024  // snapshot: bigger files become empty placeholders
TRACE_SNAP_BUDGET :: 32 * 1024 * 1024 // snapshot: bytes copied (unchanged files are hard links to the last snapshot)
TRACE_SNAP_FILES  :: 4000              // snapshot: files copied or linked
TRACE_REPLAY_DIR  :: "_replay"

// SDL keycodes for the replay controls (not used by Doodle itself).
KEY_F5 :: 0x4000003E
KEY_F6 :: 0x4000003F
KEY_F7 :: 0x40000040

Trace_Mode :: enum { Off, Record, Replay }

// A button press as written to events.jsonl.
Trace_Press :: struct {
	b:    string `json:"b"`,    // "pad:A", "key:w", "LT", "RT", "LT-up", "RT-up", "pad:X-up"
	mods: string `json:"mods"`, // triggers held at the moment: "", "LT", "RT", "LT+RT"
	rep:  bool   `json:"rep,omitempty"`, // keyboard auto-repeat
}

// What's on screen (events.jsonl "pre" / "post").
Trace_Ctx :: struct {
	scr:   string   `json:"scr"`,   // main_menu editor menu save_dialog rename filenav filenav_search filenav_delete projects docs run run_templates
	mode:  string   `json:"mode"`,  // comma list: editor modes / why a menu is open
	title: string   `json:"title"`, // menu title (or overlay title)
	trail: []string `json:"trail"`, // menus passed through to get here
	sel:   string   `json:"sel"`,   // highlighted item's label
	idx:   int      `json:"idx"`,
	n:     int      `json:"n"`,     // items in the list
	line:  int      `json:"line"`,  // editor cursor
	field: int      `json:"field"`,
	dot:   bool     `json:"dot"`,
	leaf:  string   `json:"leaf"`,  // text of the highlighted part of the code
	kind:  string   `json:"kind"`,  // its field kind ("type", "value", "decl", ...)
	file:  string   `json:"file"`,  // open file (base name)
	nodes: int      `json:"nodes"`, // document size (lines)
}

Trace_Act :: struct {
	k:     string        `json:"k"`, // "act"
	f:     int           `json:"f"`,
	t:     f64           `json:"t"`,
	press: []Trace_Press `json:"press"`,
	pre:   Trace_Ctx     `json:"pre"`,
	post:  Trace_Ctx     `json:"post"`,
	edit:  bool          `json:"edit"`, // the document changed this frame
}

Trace_List :: struct {
	k:      string   `json:"k"`, // "list": a menu / list became visible (full contents)
	f:      int      `json:"f"`,
	t:      f64      `json:"t"`,
	scr:    string   `json:"scr"`,
	title:  string   `json:"title"`,
	trail:  []string `json:"trail"`,
	items:  []string `json:"items"`,
	recent: int      `json:"recent"`,
	idx:    int      `json:"idx"`,
}

Trace_Mark :: struct {
	k:    string `json:"k"`, // "mark"
	f:    int    `json:"f"`,
	t:    f64    `json:"t"`,
	what: string `json:"what"`, // "stt", "project_name", "takeover", "diverged", "end"
	text: string `json:"text"`,
}

Trace_Meta :: struct {
	k:             string   `json:"k"`, // "meta"
	format:        string   `json:"format"`,
	start_unix:    i64      `json:"start_unix"`,
	args:          []string `json:"args"`,
	cwd:           string   `json:"cwd"`,
	projects:      string   `json:"projects"`,
	start_file:    string   `json:"start_file"`,
	stt:           bool     `json:"stt"`,
	snapshot_ok:   bool     `json:"snapshot_ok"`,
	snapshot_ms:   f64      `json:"snapshot_ms"`,
	derived_from:  string   `json:"derived_from"`,
	derived_until: int      `json:"derived_until"`,
}

// One recorded frame that had something in it (frames with nothing are skipped).
Rec_Frame :: struct {
	frame:    int,
	t:        f64,
	events:   [dynamic]platform.Event,
	has_size: bool,
	size:     [2]i32,
	has_fp:   bool,
	fp:       u64,
	quit:     bool,
}

Rec_Str :: struct {
	frame: int,
	text:  string,
}

Replay :: struct {
	src_dir:      string,              // the trace being replayed
	frames:       [dynamic]Rec_Frame,
	strs:         map[string][dynamic]Rec_Str,
	str_next:     map[string]int,
	meta:         [dynamic]string,     // its "meta ..." lines (copied into a takeover trace)
	until:        int,                 // last recorded frame to replay
	speed:        f64,                 // 0 = as fast as possible; 1 = real time
	exact:        bool,                // also run the empty frames between recorded ones
	auto_takeover: bool,
	shot:         string,              // --screenshot: PNG of the screen when the replay stops
	shot_taken:   bool,
	exit_at_end:  bool,                // quit when the replay ends (automated checks: tools/trace.py verify)
	next:         int,                 // index into frames
	cur:          int,                 // recorded frame number reached
	fed:          int,                 // index fed this loop (-1 = none)
	settle:       bool,                // run one empty frame after a fed one
	empty_left:   int,                 // --exact: empty frames still to run before the next fed one
	paused:       bool,
	step:         bool,
	done:         bool,                // reached --until / the end
	diverged_at:  int,                 // -1 = all fingerprints matched so far
	wall0:        f64,
	sandbox:      string,
	stt_fake:     bool,                // an STT recording "began" during replay
	real_quit:    bool,                // the window was closed (not the recording quitting)
	cur_t:        f64,                 // recorded time of `cur`
	vt:           f64,                 // --speed: replay clock (stops while paused)
	last_wall:    f64,
	ctl_down:     map[i32]bool,        // replay control keys held (ignore auto-repeat)
	take_cur:     int,                 // takeover: first frame number of the live part
	take_loop:    int,                 // ... the loop count then
	take_t:       f64,                 // ... and its time
	take_wall:    f64,
}

Trace :: struct {
	mode:       Trace_Mode,
	live:       bool,          // recording live input (Record, or Replay after takeover)
	dir:        string,        // where this session's trace goes ("" = not on disk yet)
	exe_dir:    string,
	input_f:    ^os.File,
	sem_f:      ^os.File,
	in_buf:     strings.Builder, // lines not yet written (all of them, during a replay)
	sem_buf:    strings.Builder,
	frame:      int,
	t0:         f64,
	frame_has:  bool,          // this frame has input.log lines
	presses:    [dynamic]Trace_Press,
	// Held state, tracked from the events themselves.
	lt, rt:     f32,
	key_lt, key_rt: bool,
	pad_x:      bool,
	keys_down:  map[i32]bool,
	last_size:  [2]i32,
	// Semantic snapshot.
	pre:        Trace_Ctx,
	pre_doc:    u64,
	last_fp:    u64,
	list_sig:   u64,
	meta_lines: [dynamic]string, // this session's "meta ..." lines
	start_file: string,
	win:        ^platform.Window,
	rp:         Replay,
	status:     string,        // shown by trace_draw
}

@(private = "file") g_tr: Trace

// ---------------- Startup / shutdown ----------------

trace_start :: proc(win: ^platform.Window, m: ^model.App) {
	g_tr.win = win
	g_tr.t0 = platform.now_seconds()
	g_tr.frame = -1
	g_tr.rp.diverged_at = -1
	g_tr.rp.fed = -1
	g_tr.exe_dir = heat_exe_dir()
	if g_tr.exe_dir == "" do g_tr.exe_dir = strings.clone(".")
	strings.builder_init(&g_tr.in_buf)
	strings.builder_init(&g_tr.sem_buf)

	replay_arg := ""
	no_trace := false
	if v, found := os.lookup_env("DOODLE_TRACE", context.temp_allocator); found && (v == "0" || v == "off" || v == "false") {
		no_trace = true
	}
	g_tr.rp.until = max(int)
	args := os.args
	for i := 1; i < len(args); i += 1 {
		a := args[i]
		next_arg :: proc(args: []string, i: ^int) -> string {
			if i^ + 1 < len(args) { i^ += 1; return args[i^] }
			return ""
		}
		switch a {
		case "--replay":   replay_arg = next_arg(args, &i)
		case "--until":
			if v, ok := strconv.parse_int(next_arg(args, &i)); ok do g_tr.rp.until = v
			else do fmt.eprintln("trace: --until needs a frame number; replaying to the end")
		case "--speed":
			if v, ok := strconv.parse_f64(next_arg(args, &i)); ok do g_tr.rp.speed = v
			else do fmt.eprintln("trace: --speed needs a number (0 = fast, 1 = real time)")
		case "--takeover": g_tr.rp.auto_takeover = true
		case "--exact":    g_tr.rp.exact = true
		case "--exit-at-end": g_tr.rp.exit_at_end = true
		case "--screenshot":  g_tr.rp.shot = next_arg(args, &i)
		case "--no-trace": no_trace = true
		}
	}

	if replay_arg != "" {
		if replay_begin(replay_arg, m) {
			g_tr.mode = .Replay
			return
		}
		fmt.eprintln("trace: replay failed; starting normally (not recording)")
		return
	}
	if no_trace do return
	record_begin(m)
}

// trace_startup_file: the file to open at startup (the command-line file, or in a
// replay, the recorded one inside the sandbox). "" = none.
trace_startup_file :: proc() -> string {
	if g_tr.mode == .Replay do return g_tr.start_file
	if f := cli_file(); f != "" do return f
	return ""
}

@(private = "file")
cli_file :: proc() -> string {
	// Same rule as before the harness: the first argument, if it exists.
	if len(os.args) > 1 && os.exists(os.args[1]) do return os.args[1]
	return ""
}

trace_stop :: proc() {
	if g_tr.mode == .Off do return
	if g_tr.mode == .Replay {
		// One machine-readable line (tools/trace.py verify reads it).
		rp := &g_tr.rp
		fmt.eprintf("trace: RESULT %s frames=%d reached=%d\n",
			rp.diverged_at >= 0 ? fmt.tprintf("diverged@%d", rp.diverged_at) : (rp.done ? "matched" : "incomplete"),
			len(rp.frames), rp.cur)
	}
	if g_tr.dir != "" {
		emit_mark("end", "")
		fmt.sbprintf(&g_tr.in_buf, "end %d\n", log_frame())
		flush_files()
		if g_tr.input_f != nil do os.close(g_tr.input_f)
		if g_tr.sem_f != nil do os.close(g_tr.sem_f)
		fmt.eprintf("trace: saved %s\n", g_tr.dir)
	}
	g_tr.mode = .Off
}

// trace_replaying: a replay is feeding recorded input (not yet taken over).
// Real side effects (running programs, the clipboard, sounds, the Recycle Bin,
// writes outside the sandbox) are skipped then.
trace_replaying :: proc() -> bool {
	return g_tr.mode == .Replay && !g_tr.live
}

// trace_write_ok: may Doodle write / delete / rename `path`? In a replay session
// (also after taking over) only inside the sandbox; anything goes otherwise.
trace_write_ok :: proc(path: string) -> bool {
	if g_tr.mode != .Replay do return true
	if path_under(path, g_tr.rp.sandbox) do return true
	set_status(fmt.tprintf("(replay) skipped writing outside the sandbox: %s", filepath.base(path)))
	return false
}

// ---------------- Recording ----------------

@(private = "file")
record_begin :: proc(m: ^model.App) {
	root := fmt.tprintf("%s/traces", g_tr.exe_dir)
	os.make_directory_all(root)
	prune_traces(root)
	prev := newest_trace(root, "snapshot/projects") // unchanged files are hard-linked from it

	now := time.now()
	y, mo, d := time.date(now)
	h, mi, s := time.clock_from_time(now)
	stamp := fmt.tprintf("%04d%02d%02d-%02d%02d%02dZ", y, int(mo), d, h, mi, s)
	dir := fmt.tprintf("%s/%s", root, stamp)
	for k := 2; os.exists(dir); k += 1 do dir = fmt.tprintf("%s/%s-%d", root, stamp, k)
	if os.make_directory_all(dir) != nil {
		fmt.eprintf("trace: cannot create %s; not recording\n", dir)
		return
	}

	// Snapshot what a replay needs to see the same files.
	t_snap := time.tick_now()
	snap_ok := true
	opts := Copy_Opts{budget = TRACE_SNAP_BUDGET, files = TRACE_SNAP_FILES, link = true}
	if g_projects_dir != "" && os.is_dir(g_projects_dir) {
		pv := prev != "" ? fmt.tprintf("%s/snapshot/projects", prev) : ""
		if !copy_tree(g_projects_dir, fmt.tprintf("%s/snapshot/projects", dir), pv, &opts, 0, 16) do snap_ok = false
	}
	// The extra project folders (roots_store.odin): just what Recent Projects
	// reads - each project's .odin files - as snapshot/roots/<i>.
	for root, i in g_roots {
		if !os.is_dir(root) do continue
		ro := opts
		ro.root_scan = true
		pv := prev != "" ? fmt.tprintf("%s/snapshot/roots/%d", prev, i) : ""
		if !copy_tree(root, fmt.tprintf("%s/snapshot/roots/%d", dir, i), pv, &ro, 0, 1) do snap_ok = false
		opts.budget, opts.files = ro.budget, ro.files
	}
	start := cli_file()
	start_abs := abs_path(start)
	start_rel := ""
	if start != "" {
		if r, ok := rel_under(start_abs, abs_path(g_projects_dir)); ok {
			start_rel = r
		} else {
			// The folder of a file opened from elsewhere: its .odin files (the rest
			// as empty placeholders, so the listing matches).
			eo := opts
			eo.only_odin = true
			if !copy_tree(filepath.dir(start_abs), fmt.tprintf("%s/snapshot/extra", dir), "", &eo, 0, 0) do snap_ok = false
		}
	}
	snap_ms := time.duration_milliseconds(time.tick_since(t_snap))

	g_tr.dir = strings.clone(dir)
	g_tr.mode = .Record
	g_tr.live = true

	add_meta(fmt.tprintf("meta start_unix %d", time.to_unix_seconds(now)))
	add_meta(fmt.tprintf("meta cwd %s", esc(cwd())))
	add_meta(fmt.tprintf("meta projects %s", esc(abs_path(g_projects_dir))))
	add_meta(fmt.tprintf("meta start_file %s", esc(start_abs)))
	add_meta(fmt.tprintf("meta start_rel %s", esc(start_rel)))
	add_meta(fmt.tprintf("meta stt %d", g_stt_e != nil ? 1 : 0))
	add_meta(fmt.tprintf("meta snapshot_ok %d", snap_ok ? 1 : 0))
	add_meta(fmt.tprintf("meta keymap %s", esc(keys_store_text(context.temp_allocator)))) // the button layout in use
	add_meta(fmt.tprintf("meta roots %s", esc(strings.join(g_roots[:], "\t", context.temp_allocator)))) // extra project folders (tab-separated)
	add_meta(fmt.tprintf("meta settings %s", esc(settings_store_text(context.temp_allocator)))) // main menu -> Settings
	for a in os.args[1:] do add_meta(fmt.tprintf("meta arg %s", esc(a)))
	if !open_files() do return
	write_header(meta_json(stamp, snap_ok, snap_ms, "", 0))
	if !snap_ok do set_status("trace: snapshot incomplete (replays of this run may differ)")
}

@(private = "file")
add_meta :: proc(line: string) {
	append(&g_tr.meta_lines, strings.clone(line))
}

@(private = "file")
meta_json :: proc(stamp: string, snap_ok: bool, snap_ms: f64, from: string, until: int) -> Trace_Meta {
	get :: proc(key: string) -> string {
		for l in g_tr.meta_lines {
			p := strings.split_n(l, " ", 3, context.temp_allocator)
			if len(p) == 3 && p[1] == key do return unesc(p[2])
			if len(p) == 2 && p[1] == key do return ""
		}
		return ""
	}
	args := make([dynamic]string, context.temp_allocator)
	for l in g_tr.meta_lines {
		p := strings.split_n(l, " ", 3, context.temp_allocator)
		if len(p) == 3 && p[1] == "arg" do append(&args, unesc(p[2]))
	}
	su, _ := strconv.parse_i64(get("start_unix"))
	return Trace_Meta{
		k = "meta", format = TRACE_FORMAT, start_unix = su, args = args[:],
		cwd = get("cwd"), projects = get("projects"), start_file = get("start_file"),
		stt = get("stt") == "1", snapshot_ok = snap_ok, snapshot_ms = snap_ms,
		derived_from = from, derived_until = until,
	}
}

@(private = "file")
open_files :: proc() -> bool {
	err1, err2: os.Error
	g_tr.input_f, err1 = os.open(fmt.tprintf("%s/input.log", g_tr.dir), {.Write, .Create, .Trunc})
	g_tr.sem_f, err2 = os.open(fmt.tprintf("%s/events.jsonl", g_tr.dir), {.Write, .Create, .Trunc})
	if err1 != nil || err2 != nil {
		fmt.eprintf("trace: cannot write to %s; not recording\n", g_tr.dir)
		g_tr.mode = .Off
		return false
	}
	return true
}

// write_header puts the format line + meta lines first in input.log and the meta
// record first in events.jsonl (ahead of anything already buffered).
@(private = "file")
write_header :: proc(meta: Trace_Meta) {
	hdr := strings.builder_make(context.temp_allocator)
	strings.write_string(&hdr, TRACE_FORMAT)
	strings.write_byte(&hdr, '\n')
	for l in g_tr.meta_lines {
		strings.write_string(&hdr, l)
		strings.write_byte(&hdr, '\n')
	}
	os.write_string(g_tr.input_f, strings.to_string(hdr))
	if data, err := json.marshal(meta, {}, context.temp_allocator); err == nil {
		os.write(g_tr.sem_f, data)
		os.write_string(g_tr.sem_f, "\n")
	}
	flush_files()
}

@(private = "file")
flush_files :: proc() {
	if g_tr.input_f == nil || g_tr.sem_f == nil do return
	if strings.builder_len(g_tr.in_buf) > 0 {
		os.write_string(g_tr.input_f, strings.to_string(g_tr.in_buf))
		strings.builder_reset(&g_tr.in_buf)
	}
	if strings.builder_len(g_tr.sem_buf) > 0 {
		os.write_string(g_tr.sem_f, strings.to_string(g_tr.sem_buf))
		strings.builder_reset(&g_tr.sem_buf)
	}
}

// prune_traces keeps the newest TRACE_KEEP recordings (never deleting `protect`).
@(private = "file")
prune_traces :: proc(root: string, protect: ..string) {
	fis, err := os.read_all_directory_by_path(root, context.temp_allocator)
	if err != nil do return
	names := make([dynamic]string, context.temp_allocator)
	for fi in fis {
		if fi.type == .Directory && len(fi.name) > 0 && fi.name[0] >= '0' && fi.name[0] <= '9' do append(&names, fi.name)
	}
	slice.sort(names[:])
	extra := len(names) - TRACE_KEEP + 1
	for name in names {
		if extra <= 0 do break
		if slice.contains(protect, name) do continue
		os.remove_all(fmt.tprintf("%s/%s", root, name))
		extra -= 1
	}
}

// newest_trace: the newest recording folder that has `needs` in it ("" = none).
@(private = "file")
newest_trace :: proc(root, needs: string) -> string {
	fis, err := os.read_all_directory_by_path(root, context.temp_allocator)
	if err != nil do return ""
	best := ""
	for fi in fis {
		if fi.type != .Directory || len(fi.name) == 0 || fi.name[0] < '0' || fi.name[0] > '9' do continue
		if !os.exists(fmt.tprintf("%s/%s", fi.fullpath, needs)) do continue
		if fi.name > best do best = fi.name
	}
	return best == "" ? "" : fmt.tprintf("%s/%s", root, best)
}

// log_frame / log_t: the frame number and time written to the trace. A replay
// session uses the recording's numbering and clock (so a takeover trace lines
// up with its source); the live part after a takeover continues from there.
@(private = "file")
log_frame :: proc() -> int {
	if g_tr.mode == .Replay {
		if !g_tr.live do return max(g_tr.rp.cur, 0)
		return g_tr.rp.take_cur + (g_tr.frame - g_tr.rp.take_loop)
	}
	return g_tr.frame
}

@(private = "file")
log_t :: proc() -> f64 {
	now := platform.now_seconds()
	if g_tr.mode == .Replay {
		if !g_tr.live do return g_tr.rp.cur_t
		return g_tr.rp.take_t + (now - g_tr.rp.take_wall)
	}
	return now - g_tr.t0
}

// held_mods: the triggers held now ("", "LT", "RT", "LT+RT"), as the app sees them.
@(private = "file")
held_mods :: proc() -> string {
	l := g_tr.lt > 0.5 || g_tr.key_lt
	r := g_tr.rt > 0.5 || g_tr.key_rt
	switch {
	case l && r: return "LT+RT"
	case l:      return "LT"
	case r:      return "RT"
	}
	return ""
}

// ---------------- Per frame ----------------

// trace_poll replaces platform.poll_events: records the real events, or feeds a
// replay's recorded ones (real input then only drives the replay controls).
trace_poll :: proc(win: ^platform.Window, events: ^[dynamic]platform.Event) {
	g_tr.frame += 1
	g_tr.frame_has = false
	clear(&g_tr.presses)
	g_tr.rp.fed = -1

	if g_tr.mode == .Off {
		platform.poll_events(win, events)
		return
	}
	if g_tr.mode == .Replay && !g_tr.live {
		replay_poll(win, events)
	} else {
		platform.poll_events(win, events)
		for e in events do note_event(e)
	}

	// Window size (the docs panel pages by it).
	if g_tr.live {
		w, h: i32
		sdl.GetWindowSize(win.handle, &w, &h)
		if w != g_tr.last_size.x || h != g_tr.last_size.y {
			g_tr.last_size = {w, h}
			in_line(fmt.tprintf("size %d %d", w, h))
		}
	}
}

// note_event writes one input event to input.log and tracks held buttons/presses.
@(private = "file")
note_event :: proc(e: platform.Event) {
	mods := held_mods
	switch ev in e {
	case platform.Quit_Event:
		in_line("quit")
	case platform.Resize_Event:
	case platform.Text_Event:
	case platform.Button_Event:
		in_line(fmt.tprintf("btn %v %d", ev.button, ev.pressed ? 1 : 0))
		if ev.button == .X do g_tr.pad_x = ev.pressed
		if ev.pressed {
			append(&g_tr.presses, Trace_Press{b = fmt.tprintf("pad:%v", ev.button), mods = mods()})
		} else if ev.button == .X {
			append(&g_tr.presses, Trace_Press{b = "pad:X-up", mods = mods()})
		}
	case platform.Axis_Event:
		// The app only asks "is the trigger past half way" (main.odin build_input)
		// and ignores the sticks, so only crossings are written (exact value, %v
		// round-trips the f32). Keeps the log small and every frame meaningful.
		#partial switch ev.axis {
		case .LTrigger:
			was := g_tr.lt > 0.5
			g_tr.lt = ev.value
			if (g_tr.lt > 0.5) != was {
				in_line(fmt.tprintf("axis %v %v", ev.axis, ev.value))
				append(&g_tr.presses, Trace_Press{b = was ? "LT-up" : "LT", mods = mods()})
			}
		case .RTrigger:
			was := g_tr.rt > 0.5
			g_tr.rt = ev.value
			if (g_tr.rt > 0.5) != was {
				in_line(fmt.tprintf("axis %v %v", ev.axis, ev.value))
				append(&g_tr.presses, Trace_Press{b = was ? "RT-up" : "RT", mods = mods()})
			}
		}
	case platform.Key_Event:
		in_line(fmt.tprintf("key %d %d", ev.sym, ev.pressed ? 1 : 0))
		rep := ev.pressed && g_tr.keys_down[ev.sym]
		if ev.pressed do g_tr.keys_down[ev.sym] = true
		else do delete_key(&g_tr.keys_down, ev.sym)
		switch ev.sym {
		case 'q':
			if !rep && ev.pressed != g_tr.key_lt do append(&g_tr.presses, Trace_Press{b = ev.pressed ? "LT" : "LT-up", mods = mods()})
			g_tr.key_lt = ev.pressed
			return
		case 'e':
			if !rep && ev.pressed != g_tr.key_rt do append(&g_tr.presses, Trace_Press{b = ev.pressed ? "RT" : "RT-up", mods = mods()})
			g_tr.key_rt = ev.pressed
			return
		}
		if ev.pressed {
			append(&g_tr.presses, Trace_Press{b = fmt.tprintf("key:%s", key_name(ev.sym)), mods = mods(), rep = rep})
		} else if ev.sym == 'x' {
			append(&g_tr.presses, Trace_Press{b = "key:x-up", mods = mods()})
		}
	}
}

@(private = "file")
key_name :: proc(sym: i32) -> string {
	switch sym {
	case KEY_RETURN:    return "Return"
	case KEY_SPACE:     return "Space"
	case KEY_BACKSPACE: return "Backspace"
	case KEY_ESCAPE:    return "Escape"
	case KEY_UP:        return "Up"
	case KEY_DOWN:      return "Down"
	case KEY_LEFT:      return "Left"
	case KEY_RIGHT:     return "Right"
	case KEY_LCTRL, KEY_RCTRL: return "Ctrl"
	case KEY_F5:        return "F5"
	case KEY_F6:        return "F6"
	case KEY_F7:        return "F7"
	case 33 ..= 126:    return fmt.tprintf("%c", rune(sym))
	}
	return fmt.tprintf("0x%x", sym)
}

@(private = "file")
in_line :: proc(s: string) {
	if !g_tr.frame_has {
		g_tr.frame_has = true
		fmt.sbprintf(&g_tr.in_buf, "%d t %.4f\n", log_frame(), log_t())
	}
	fmt.sbprintf(&g_tr.in_buf, "%d %s\n", log_frame(), s)
}

// trace_frame_begin: call after this frame's events are applied, before input is
// routed. Remembers what was on screen. Read-only.
trace_frame_begin :: proc(m: ^model.App) {
	if g_tr.mode == .Off do return
	// Copied: input routing can free the strings it points at (menu labels, the
	// save-dialog name) before trace_frame_end writes them.
	g_tr.pre = ctx_clone(screen_ctx(m))
	g_tr.pre_doc = doc_hash(m)
}

@(private = "file")
ctx_clone :: proc(c: Trace_Ctx) -> Trace_Ctx {
	t := context.temp_allocator
	out := c
	out.scr = strings.clone(c.scr, t)
	out.mode = strings.clone(c.mode, t)
	out.title = strings.clone(c.title, t)
	out.sel = strings.clone(c.sel, t)
	out.leaf = strings.clone(c.leaf, t)
	out.kind = strings.clone(c.kind, t)
	out.file = strings.clone(c.file, t)
	trail := make([]string, len(c.trail), t)
	for x, i in c.trail do trail[i] = strings.clone(x, t)
	out.trail = trail
	return out
}

// trace_frame_end: call after input routing (and dictation), before drawing.
// Writes this frame's records; during a replay, checks the state fingerprint.
trace_frame_end :: proc(m: ^model.App) {
	if g_tr.mode == .Off do return
	fp := fingerprint(m)
	t := log_t()
	f := log_frame()

	// Replay: compare with the recording.
	if g_tr.mode == .Replay && !g_tr.live && g_tr.rp.fed >= 0 {
		rf := g_tr.rp.frames[g_tr.rp.fed]
		if rf.has_fp && rf.fp != fp && g_tr.rp.diverged_at < 0 {
			g_tr.rp.diverged_at = rf.frame
			fmt.eprintf("trace: replay diverged from the recording at frame %d\n", rf.frame)
			emit_mark("diverged", fmt.tprintf("%d", rf.frame))
		}
	}

	// The recording quit here (B on the main menu): end the replay instead, so
	// the user lands on that moment. Closing the window still quits.
	if trace_replaying() && m.want_quit && !g_tr.rp.real_quit {
		m.want_quit = false // in an original recording this was the last frame, so the replay ends next poll
	}

	post := screen_ctx(m)
	doc := doc_hash(m)
	if g_tr.frame_has || fp != g_tr.last_fp {
		in_line(fmt.tprintf("fp %016x", fp))
	}
	// Label combos the way the app saw them: triggers as held after all of this
	// frame's events (main.odin builds its input once per frame).
	final_mods := held_mods()
	for &p in g_tr.presses {
		if !strings.has_prefix(p.b, "LT") && !strings.has_prefix(p.b, "RT") do p.mods = final_mods
	}
	if len(g_tr.presses) > 0 || fp != g_tr.last_fp {
		act := Trace_Act{k = "act", f = f, t = t, press = g_tr.presses[:], pre = g_tr.pre, post = post, edit = doc != g_tr.pre_doc}
		emit_json(act)
	}
	g_tr.last_fp = fp

	// A list that just became visible: write its full contents once.
	items, recent := screen_items(m)
	sig := list_sig(post, items)
	if sig != g_tr.list_sig {
		g_tr.list_sig = sig
		if len(items) > 0 {
			emit_json(Trace_List{k = "list", f = f, t = t, scr = post.scr, title = post.title, trail = post.trail, items = items, recent = recent, idx = post.idx})
		}
	}

	if g_tr.live do flush_files()
}

@(private = "file")
emit_json :: proc(v: any) {
	data, err := json.marshal(v, {}, context.temp_allocator)
	if err != nil do return
	strings.write_bytes(&g_tr.sem_buf, data)
	strings.write_byte(&g_tr.sem_buf, '\n')
}

@(private = "file")
emit_mark :: proc(what, txt: string) {
	emit_json(Trace_Mark{k = "mark", f = log_frame(), t = log_t(), what = what, text = txt})
}

// ---------------- Screen context (events.jsonl) ----------------

// screen_ctx reads what's on screen, in the same order main.odin routes input.
// Read-only: it must not change anything a replay depends on.
@(private = "file")
screen_ctx :: proc(m: ^model.App) -> Trace_Ctx {
	c: Trace_Ctx
	if g_current_file != "" do c.file = filepath.base(g_current_file)
	c.nodes = len(m.doc.nodes)
	c.line, c.field, c.dot = m.editor_line, m.editor_field, m.editor_dot
	if ni, u, ok := model.editor_leaf(m); ok {
		fs := m.doc.nodes[ni].fields
		b := strings.builder_make(context.temp_allocator)
		for fi in clamp(u.fa, 0, len(fs)) ..< clamp(u.fb, 0, len(fs)) do strings.write_string(&b, fs[fi].text)
		c.leaf = strings.to_string(b)
		if tni, tfi, tok := model.editor_target(m); tok && tfi >= 0 && tfi < len(m.doc.nodes[tni].fields) {
			c.kind = m.doc.nodes[tni].fields[tfi].kind
		}
	}
	modes := make([dynamic]string, context.temp_allocator)
	if m.ref_pick_active do append(&modes, "ref_pick")
	if m.ref_pass_active do append(&modes, "ref_pass")
	if m.mod_pick_active do append(&modes, "mod_pick")
	if m.rename_active do append(&modes, "rename_prompt")
	if m.replacing do append(&modes, "replace")
	if m.refill_active do append(&modes, "refill")
	if m.change_call do append(&modes, "change_call")
	if m.body_insert_active do append(&modes, "body_insert")
	if m.decl_form_active do append(&modes, "decl_form")
	if m.slot_menu != nil do append(&modes, "slot")
	if m.ctrl_menu != .None do append(&modes, fmt.tprintf("ctrl:%v", m.ctrl_menu))
	if m.tree_sticky do append(&modes, "tree_sticky")
	if g_recording do append(&modes, "dictating")
	if g_save_open && g_save_overwrite != "" do append(&modes, "overwrite_prompt")
	if g_keys_open && g_keys.picking do append(&modes, "picker")
	if g_keys_open && g_keys.asking_reset do append(&modes, "reset_prompt")
	if g_np_open && !g_np_browsing && g_np_remove > 0 do append(&modes, "remove_prompt")
	c.mode = strings.join(modes[:], ",", context.temp_allocator)

	pick :: proc(c: ^Trace_Ctx, labels: []string, idx: int) {
		c.n = len(labels)
		c.idx = idx
		if idx >= 0 && idx < len(labels) do c.sel = labels[idx]
	}
	switch {
	case g_save_open:
		c.scr = g_save_rename != "" ? "rename" : "save_dialog"
		c.title = string(g_save_name[:])
	case g_filenav:
		c.scr = "filenav"
		if g_fn_delete != "" do c.scr = "filenav_delete"
		else if g_fn_search_active do c.scr = "filenav_search"
		c.title = g_fn_search_active ? g_fn_search_query : model.fgrid_title(g_fn_grid.view != "" ? g_fn_grid.view : g_fn_dir)
		items, _ := screen_items(m)
		pick(&c, items, g_fn_index)
	case g_keys_open:
		c.scr = "key_layout"
		bank, b := model.keys_page_slot(&g_keys)
		c.title = model.slot_name(bank, b)
		items, _ := screen_items(m)
		pick(&c, items, g_keys.picking ? g_keys.pick : bank * len(model.KEYS_ROWS) + g_keys.row)
	case g_settings_open:
		c.scr = "settings"
		items, _ := screen_items(m)
		pick(&c, items, g_settings_row)
	case g_proj_open:
		c.scr = "projects"
		items, _ := screen_items(m)
		pick(&c, items, g_proj_index)
	case g_np_open:
		c.scr = g_np_browsing ? "new_project_folder" : "new_project"
		if g_np_browsing do c.title = model.fgrid_title(g_np_dir)
		items, _ := screen_items(m)
		pick(&c, items, g_np_browsing ? g_np_bindex : g_np_index)
	case g_doc_open:
		c.scr = "docs"
		c.title = g_doc.title
		c.idx = g_doc_scroll
	case g_run_open:
		c.scr = g_run_submenu ? "run_templates" : "run"
		items, _ := screen_items(m)
		pick(&c, items, g_run_submenu ? g_run_tmpl_idx : g_run_index)
	case m.state == .Menu:
		c.scr = "main_menu"
		items, _ := screen_items(m)
		pick(&c, items, m.menu_index)
	case m.state == .Radial:
		c.scr = "menu"
		if v := model.current_view(m); v != nil {
			c.title = v.title
			items, _ := screen_items(m)
			pick(&c, items, v.index)
		}
		trail := make([dynamic]string, context.temp_allocator)
		if len(m.nav) > 1 do for v in m.nav[:len(m.nav) - 1] do append(&trail, v.title)
		c.trail = trail[:]
	case:
		c.scr = "editor"
	}
	return c
}

// screen_items: the labels of the list on screen (and how many are "recent").
@(private = "file")
screen_items :: proc(m: ^model.App) -> (items: []string, recent: int) {
	out := make([dynamic]string, context.temp_allocator)
	switch {
	case g_save_open, g_doc_open:
	case g_filenav:
		src := g_fn_search_active ? g_fn_filtered[:] : g_fn_entries[:]
		for e in src do append(&out, e.is_dir ? fmt.tprintf("%s/", e.name) : e.name)
	case g_keys_open:
		if g_keys.picking {
			for a in model.KEYS_PICK do append(&out, model.ACTION_INFO[a].label)
		} else {
			// Every slot, bank by bank: "LT+A: Edit".
			for bank in 0 ..< model.BANKS {
				for b in model.KEYS_ROWS {
					a := model.keymap_get(&g_keymap, bank, b)
					append(&out, fmt.tprintf("%s: %s", model.slot_name(bank, b), model.ACTION_INFO[a].label))
				}
			}
		}
	case g_proj_open:
		for p in g_proj_list do append(&out, p.name)
	case g_np_open:
		if g_np_browsing {
			for row in g_np_rows do append(&out, row.use ? "Use this folder" : fmt.tprintf("%s/", row.label))
		} else {
			append(&out, "In default folder")
			for root in g_roots do append(&out, fmt.tprintf("In %s", model.fgrid_title(root)))
			append(&out, "+ Add another folder")
		}
	case g_run_open:
		if g_run_submenu {
			for t in TEMPLATES do append(&out, t)
		} else {
			for c in g_run_cmds do append(&out, c.cmd)
			append(&out, "+ New command")
		}
	case g_settings_open:
		for info, k in model.SETTING_INFO do append(&out, fmt.tprintf("%s: %s", info.label, g_settings.on[k] ? "On" : "Off"))
	case m.state == .Menu:
		for it in model.menu_items(m) do append(&out, it)
	case m.state == .Radial:
		if v := model.current_view(m); v != nil {
			for e in v.entries do append(&out, e.label)
			recent = v.recent
		}
	}
	return out[:], recent
}

@(private = "file")
list_sig :: proc(c: Trace_Ctx, items: []string) -> u64 {
	h := FNV_OFFSET
	h = fnv(h, c.scr)
	h = fnv(h, c.title)
	for t in c.trail do h = fnv(h, t)
	for it in items do h = fnv(h, it)
	return h
}

// ---------------- Fingerprint ----------------

FNV_OFFSET :: u64(0xcbf29ce484222325)

@(private = "file")
fnv :: proc(h: u64, s: string) -> u64 {
	h := h
	for b in transmute([]u8)s {
		h ~= u64(b)
		h *= 0x100000001b3
	}
	h ~= 0xff // separator
	h *= 0x100000001b3
	return h
}

@(private = "file")
fnv_int :: proc(h: u64, v: int) -> u64 {
	h, x := h, u64(v)
	for _ in 0 ..< 8 {
		h ~= x & 0xff
		h *= 0x100000001b3
		x >>= 8
	}
	return h
}

@(private = "file")
doc_hash :: proc(m: ^model.App) -> u64 {
	h := FNV_OFFSET
	for node in m.doc.nodes {
		for f in node.fields {
			h = fnv(h, f.text)
			h = fnv_int(h, int(f.slot))
		}
		h = fnv(h, "\n")
	}
	return h
}

// fingerprint: everything input can change that a replay must reproduce. Leaves
// out what is nondeterministic but harmless (odin check results, timings) and
// absolute paths (a replay runs in a sandbox), keeping only base names.
@(private = "file")
fingerprint :: proc(m: ^model.App) -> u64 {
	h := doc_hash(m)
	h = fnv_int(h, int(m.state))
	h = fnv_int(h, m.menu_index)
	h = fnv_int(h, len(m.nav))
	for v in m.nav {
		h = fnv(h, v.title)
		h = fnv_int(h, v.index)
		h = fnv_int(h, len(v.entries))
	}
	h = fnv_int(h, m.editor_line)
	h = fnv_int(h, m.editor_field)
	h = fnv_int(h, int(m.editor_dot))
	h = fnv_int(h, int(m.editor_attr))
	flags := [?]bool{
		m.ref_pick_active, m.ref_pass_active, m.mod_pick_active, m.rename_active, m.replacing,
		m.refill_active, m.change_call, m.body_insert_active, m.decl_form_active, m.tree_sticky,
		g_save_open, g_filenav, g_fn_search_active, g_proj_open, g_doc_open, g_run_open, g_run_submenu, g_recording,
	}
	for f in flags do h = fnv_int(h, int(f))
	h = fnv_int(h, int(m.ctrl_menu))
	h = fnv(h, string(g_save_name[:]))
	h = fnv(h, filepath.base(g_save_overwrite))
	h = fnv_int(h, g_fn_index)
	h = fnv_int(h, len(g_fn_entries))
	h = fnv(h, g_fn_search_query)
	h = fnv(h, filepath.base(g_fn_delete))
	h = fnv_int(h, g_proj_index)
	h = fnv_int(h, g_doc_scroll)
	h = fnv_int(h, g_run_index)
	h = fnv_int(h, g_run_tmpl_idx)
	h = fnv(h, filepath.base(g_current_file))
	h = fnv(h, filepath.base(g_project_dir))
	// File navigation grid: which folder is in view and where the cursor is.
	h = fnv(h, filepath.base(g_fn_grid.view))
	h = fnv_int(h, g_fn_grid.descents)
	h = fnv_int(h, g_fn_grid.group)
	h = fnv_int(h, g_fn_grid.item)
	// Settings page and the options - only while it's open, so recordings made
	// before Settings existed keep their fingerprints (the options only change
	// what the page shows, and a replay doesn't run programs).
	if g_settings_open {
		h = fnv_int(h, 1)
		h = fnv_int(h, g_settings_row)
		for on in g_settings.on do h = fnv_int(h, int(on))
	}
	// Key Layout page and the layout itself.
	h = fnv_int(h, int(g_keys_open))
	h = fnv_int(h, g_keys.bank)
	h = fnv_int(h, g_keys.row)
	h = fnv_int(h, int(g_keys.picking))
	h = fnv_int(h, g_keys.pick)
	h = fnv_int(h, int(g_keys.asking_reset))
	for bank in 0 ..< model.BANKS {
		for b in model.Pad_Button do h = fnv_int(h, int(g_keymap.slots[bank][b]))
	}
	// New Project's "where?" list and folder browser. Only mixed in once used,
	// so recordings made before it existed keep their fingerprints.
	if g_np_open || len(g_roots) > 0 {
		h = fnv_int(h, int(g_np_open))
		h = fnv_int(h, g_np_index)
		h = fnv_int(h, g_np_remove)
		h = fnv_int(h, int(g_np_browsing))
		h = fnv_int(h, g_np_bindex)
		h = fnv_int(h, len(g_np_rows))
		h = fnv(h, model.fgrid_title(g_np_dir))
		h = fnv_int(h, len(g_roots))
	}
	return h
}

// ---------------- Values a replay can't recompute ----------------

// trace_str records a value that isn't a pure function of input (a random project
// name); a replay returns the recorded value instead of `live`.
trace_str :: proc(kind: string, live: string) -> string {
	if g_tr.mode == .Off do return live
	v := live
	if trace_replaying() {
		if s, ok := next_str(kind); ok do v = strings.clone(s, context.temp_allocator)
	}
	note_str(kind, v)
	return v
}

trace_stt_begin :: proc(e: ^stt.Engine) {
	if trace_replaying() {
		g_tr.rp.stt_fake = true
		return
	}
	if g_tr.rp.stt_fake do return // began in the replay, before takeover: nothing to record
	stt.begin(e)
}

trace_stt_segment :: proc(e: ^stt.Engine) -> string {
	return stt_result(e, true)
}

trace_stt_end :: proc(e: ^stt.Engine) -> string {
	return stt_result(e, false)
}

@(private = "file")
stt_result :: proc(e: ^stt.Engine, segment: bool) -> string {
	out: string
	switch {
	case trace_replaying():
		s, _ := next_str("stt")
		out = strings.clone(s)
	case g_tr.rp.stt_fake:
		out = strings.clone("") // recording began during the replay: nothing was heard
	case segment:
		out = stt.segment(e)
	case:
		out = stt.end(e)
	}
	if !segment do g_tr.rp.stt_fake = false
	if g_tr.mode != .Off do note_str("stt", out)
	return out
}

@(private = "file")
note_str :: proc(kind, s: string) {
	in_line(fmt.tprintf("str %s %s", kind, esc(s)))
	emit_mark(kind, s)
}

@(private = "file")
next_str :: proc(kind: string) -> (string, bool) {
	q := g_tr.rp.strs[kind]
	i := g_tr.rp.str_next[kind]
	if i >= len(q) {
		fmt.eprintf("trace: replay ran out of recorded '%s' values\n", kind)
		return "", false
	}
	g_tr.rp.str_next[kind] = i + 1
	if q[i].frame != g_tr.rp.cur {
		fmt.eprintf("trace: recorded '%s' came from frame %d, replay is at %d\n", kind, q[i].frame, g_tr.rp.cur)
	}
	return q[i].text, true
}

// ---------------- Replay ----------------

@(private = "file")
replay_begin :: proc(arg: string, m: ^model.App) -> bool {
	src := resolve_trace(arg)
	if src == "" {
		fmt.eprintf("trace: no recording found for '%s' (looked in %s/traces)\n", arg, g_tr.exe_dir)
		return false
	}
	data, err := os.read_entire_file(fmt.tprintf("%s/input.log", src), context.allocator)
	if err != nil {
		fmt.eprintf("trace: cannot read %s/input.log\n", src)
		return false
	}
	defer delete(data)
	if !parse_input_log(string(data)) {
		fmt.eprintf("trace: %s/input.log is not a %s file\n", src, TRACE_FORMAT)
		return false
	}
	g_tr.rp.src_dir = strings.clone(src)

	// Sandbox: a fresh copy of the snapshot, mtimes kept (the project list sorts by them).
	sandbox := fmt.tprintf("%s/traces/%s", g_tr.exe_dir, TRACE_REPLAY_DIR)
	if os.exists(fmt.tprintf("%s/.takeover", sandbox)) {
		// The last replay was taken over: keep that session's files one more time.
		prev_box := fmt.tprintf("%s.prev", sandbox)
		os.remove_all(prev_box)
		os.rename(sandbox, prev_box)
	}
	os.remove_all(sandbox)
	// Real copies, never links: writes in the sandbox must not reach the snapshot.
	opts := Copy_Opts{budget = max(i64), files = max(int)}
	copy_tree(fmt.tprintf("%s/snapshot", src), sandbox, "", &opts, 0, 32)
	os.make_directory_all(fmt.tprintf("%s/projects", sandbox))
	g_tr.rp.sandbox = strings.clone(abs_path(sandbox))

	// Point Doodle at the sandbox.
	if g_projects_dir != "" do delete(g_projects_dir)
	g_projects_dir = fmt.aprintf("%s/projects", g_tr.rp.sandbox)
	start_file := rp_meta("start_file")
	start_rel := rp_meta("start_rel")
	if strings.contains(start_rel, "..") || filepath.is_abs(start_rel) {
		fmt.eprintf("trace: ignoring start file %q (outside the snapshot)\n", start_rel)
		start_rel, start_file = "", ""
	}
	switch {
	case start_rel != "":
		g_tr.start_file = fmt.aprintf("%s/projects/%s", g_tr.rp.sandbox, start_rel)
	case start_file != "":
		g_tr.start_file = fmt.aprintf("%s/extra/%s", g_tr.rp.sandbox, filepath.base(start_file))
	}
	g_heat_nosave = true // a replay must not count menu uses again
	// The button layout the run was recorded with ("" = the defaults, which is
	// what recordings made before layouts existed used). Also stops saving it.
	keys_store_override(rp_meta("keymap"))
	// The extra project folders become sandbox stand-ins (snapshot/roots/<i>).
	// Recordings made before New Project asked where have no "roots": New
	// Project goes straight to the editor, as it did then.
	if rp_has_meta("roots") {
		stand := make([dynamic]string, context.temp_allocator)
		recorded := rp_meta("roots")
		if recorded != "" {
			for _, i in strings.split(recorded, "\t", context.temp_allocator) {
				// Exists only if it was snapshotted (it existed when recorded): a
				// folder that was missing stays missing ("not found").
				append(&stand, fmt.tprintf("%s/roots/%d", g_tr.rp.sandbox, i))
			}
		}
		roots_store_override(stand[:], false)
	} else {
		roots_store_override(nil, true)
	}

	// The Settings the run was recorded with (never saved during a replay).
	// Recordings made before Settings existed had a 4-item main menu.
	if rp_has_meta("settings") {
		settings_store_override(rp_meta("settings"))
	} else {
		settings_store_override("")
		m.menu_legacy = true
	}

	if rp_meta("stt") == "1" && g_stt_e == nil {
		fmt.eprintln("trace: the recording used speech-to-text, which isn't available now; the replay may differ")
	}
	if rp_meta("snapshot_ok") == "0" {
		fmt.eprintln("trace: the recording's snapshot was incomplete; the replay may differ")
	}

	// Copy the source's meta (a takeover trace replays from the same snapshot).
	for l in g_tr.rp.meta {
		if strings.has_prefix(l, "meta derived_") do continue // re-stated at takeover
		append(&g_tr.meta_lines, strings.clone(l))
	}

	g_tr.rp.wall0 = platform.now_seconds()
	g_tr.rp.last_wall = g_tr.rp.wall0
	g_tr.rp.cur = -1
	if g_tr.rp.speed <= 0 do sdl.GL_SetSwapInterval(0) // fast-forward: don't wait for vsync
	fmt.eprintf("trace: replaying %s (%d recorded frames%s)\n", src, len(g_tr.rp.frames),
		g_tr.rp.until < max(int) ? fmt.tprintf(", until frame %d", g_tr.rp.until) : "")
	return true
}

@(private = "file")
rp_has_meta :: proc(key: string) -> bool {
	for l in g_tr.rp.meta {
		p := strings.split_n(l, " ", 3, context.temp_allocator)
		if len(p) >= 2 && p[1] == key do return true
	}
	return false
}

@(private = "file")
rp_meta :: proc(key: string) -> string {
	for l in g_tr.rp.meta {
		p := strings.split_n(l, " ", 3, context.temp_allocator)
		if len(p) >= 2 && p[1] == key do return len(p) == 3 ? unesc(p[2]) : ""
	}
	return ""
}

// resolve_trace: "last" / "latest" = the newest recording; else a folder name in
// traces/, a folder path, or a path to an input.log.
@(private = "file")
resolve_trace :: proc(arg: string) -> string {
	root := fmt.tprintf("%s/traces", g_tr.exe_dir)
	if arg == "last" || arg == "latest" {
		fis, err := os.read_all_directory_by_path(root, context.temp_allocator)
		if err != nil do return ""
		best := ""
		for fi in fis {
			if fi.type != .Directory || len(fi.name) == 0 || fi.name[0] < '0' || fi.name[0] > '9' do continue
			if !os.exists(fmt.tprintf("%s/input.log", fi.fullpath)) do continue
			if fi.name > best do best = fi.name
		}
		return best == "" ? "" : fmt.tprintf("%s/%s", root, best)
	}
	if strings.has_suffix(arg, "input.log") && os.exists(arg) do return filepath.dir(arg)
	if os.exists(fmt.tprintf("%s/input.log", arg)) do return arg
	if os.exists(fmt.tprintf("%s/%s/input.log", root, arg)) do return fmt.tprintf("%s/%s", root, arg)
	return ""
}

@(private = "file")
parse_input_log :: proc(data: string) -> bool {
	lines := strings.split_lines(data, context.temp_allocator)
	if len(lines) == 0 || strings.trim_space(lines[0]) != TRACE_FORMAT do return false
	button_from :: proc(s: string) -> (platform.Button, bool) {
		for b in platform.Button do if fmt.tprintf("%v", b) == s do return b, true
		return {}, false
	}
	axis_from :: proc(s: string) -> (platform.Axis, bool) {
		for a in platform.Axis do if fmt.tprintf("%v", a) == s do return a, true
		return {}, false
	}
	cur: ^Rec_Frame
	for raw_line in lines[1:] {
		line := strings.trim_right(raw_line, "\r")
		if line == "" do continue
		if strings.has_prefix(line, "meta ") {
			append(&g_tr.rp.meta, strings.clone(line))
			continue
		}
		if strings.has_prefix(line, "end ") do continue
		p := strings.split(line, " ", context.temp_allocator)
		if len(p) < 2 do continue
		f, fok := strconv.parse_int(p[0])
		if !fok do continue
		if cur == nil || cur.frame != f {
			append(&g_tr.rp.frames, Rec_Frame{frame = f})
			cur = &g_tr.rp.frames[len(g_tr.rp.frames) - 1]
		}
		switch p[1] {
		case "t":
			if len(p) >= 3 do cur.t, _ = strconv.parse_f64(p[2])
		case "btn":
			if len(p) >= 4 {
				if b, ok := button_from(p[2]); ok do append(&cur.events, platform.Button_Event{b, p[3] == "1"})
			}
		case "axis":
			if len(p) >= 4 {
				if a, ok := axis_from(p[2]); ok {
					v, _ := strconv.parse_f32(p[3])
					append(&cur.events, platform.Axis_Event{a, v})
				}
			}
		case "key":
			if len(p) >= 4 {
				sym, _ := strconv.parse_int(p[2])
				append(&cur.events, platform.Key_Event{i32(sym), p[3] == "1"})
			}
		case "quit":
			cur.quit = true
		case "size":
			if len(p) >= 4 {
				w, _ := strconv.parse_int(p[2])
				h, _ := strconv.parse_int(p[3])
				cur.has_size = true
				cur.size = {i32(w), i32(h)}
			}
		case "fp":
			if len(p) >= 3 {
				v, ok := strconv.parse_u64_of_base(strings.trim_space(p[2]), 16)
				if ok { cur.has_fp = true; cur.fp = v }
			}
		case "str":
			if len(p) >= 3 {
				kind := strings.clone(p[2])
				txt := len(p) >= 4 ? unesc(p[3]) : ""
				if kind not_in g_tr.rp.strs do g_tr.rp.strs[kind] = make([dynamic]Rec_Str)
				q := &g_tr.rp.strs[kind]
				append(q, Rec_Str{frame = f, text = strings.clone(txt)})
			}
		}
	}
	return true
}

@(private = "file")
replay_poll :: proc(win: ^platform.Window, events: ^[dynamic]platform.Event) {
	rp := &g_tr.rp
	// Real input: only the replay controls (and closing the window).
	real := make([dynamic]platform.Event, context.temp_allocator)
	platform.poll_events(win, &real)
	takeover := false
	for e in real {
		#partial switch ev in e {
		case platform.Quit_Event:
			rp.real_quit = true
			append(events, e)
		case platform.Key_Event:
			if !ev.pressed {
				delete_key(&rp.ctl_down, ev.sym)
				continue
			}
			if rp.ctl_down[ev.sym] do continue // auto-repeat
			rp.ctl_down[ev.sym] = true
			switch ev.sym {
			case KEY_F5: takeover = true
			case KEY_F6: rp.paused = !rp.paused
			case KEY_F7: rp.step = true; rp.paused = true
			}
		case platform.Button_Event:
			if !ev.pressed do continue
			#partial switch ev.button {
			case .Start: takeover = true
			case .Back:  rp.paused = !rp.paused
			case .Right: if rp.paused || rp.done do rp.step = true
			}
		}
	}
	if takeover {
		take_over(events)
		return
	}
	// The --speed clock only runs while playing.
	now := platform.now_seconds()
	if !rp.paused && !rp.done do rp.vt += (now - rp.last_wall) * rp.speed
	rp.last_wall = now
	if rp.done {
		rp.step = false
		return
	}
	if rp.paused && !rp.step do return

	if rp.next >= len(rp.frames) || rp.frames[rp.next].frame > rp.until || rp.frames[rp.next].quit {
		finish_replay(events)
		return
	}
	nxt := &rp.frames[rp.next]

	// One empty frame after each fed frame (lets anything that settles a frame
	// later happen as it did), or all of them with --exact.
	if rp.settle && nxt.frame != rp.cur + 1 && !rp.step {
		rp.settle = false
		rp.cur += 1
		if rp.exact do rp.empty_left = nxt.frame - rp.cur - 1
		return
	}
	if rp.empty_left > 0 && !rp.step {
		rp.empty_left -= 1
		rp.cur += 1
		return
	}
	// Real-time pacing.
	if rp.speed > 0 && !rp.step {
		if rp.vt < nxt.t - rp.frames[0].t do return
	}

	// This loop is now recorded frame nxt.frame (log lines use its number).
	rp.cur = nxt.frame
	rp.cur_t = nxt.t
	if nxt.has_size do sdl.SetWindowSize(win.handle, nxt.size.x, nxt.size.y)
	for e in nxt.events {
		append(events, e)
		note_event(e)
	}
	if nxt.has_size {
		g_tr.last_size = nxt.size
		in_line(fmt.tprintf("size %d %d", nxt.size.x, nxt.size.y))
	}
	rp.fed = rp.next
	rp.cur = nxt.frame
	rp.next += 1
	rp.settle = true
	rp.empty_left = 0
	if rp.step && len(g_tr.presses) > 0 {
		rp.step = false // stepping runs to the next frame with a press in it
	}
}

@(private = "file")
finish_replay :: proc(events: ^[dynamic]platform.Event) {
	rp := &g_tr.rp
	if !rp.done {
		rp.done = true
		rp.paused = true
		sdl.GL_SetSwapInterval(1)
		fmt.eprintf("trace: replay reached frame %d%s\n", rp.cur,
			rp.diverged_at >= 0 ? fmt.tprintf(" (diverged at %d)", rp.diverged_at) : " (matched the recording)")
	}
	if rp.auto_takeover do take_over(events)
	if rp.exit_at_end {
		rp.real_quit = true
		append(events, platform.Event(platform.Quit_Event{}))
	}
}

// take_over hands control to the real controller: releases whatever the
// recording was holding, and starts writing a trace (prefix included).
@(private = "file")
take_over :: proc(events: ^[dynamic]platform.Event) {
	if g_tr.live do return
	// Release held input so a trigger held in the recording doesn't stay held.
	release :: proc(events: ^[dynamic]platform.Event, e: platform.Event) {
		append(events, e)
		note_event(e)
	}
	if g_tr.lt != 0 do release(events, platform.Axis_Event{.LTrigger, 0})
	if g_tr.rt != 0 do release(events, platform.Axis_Event{.RTrigger, 0})
	if g_tr.pad_x do release(events, platform.Button_Event{.X, false})
	held := make([dynamic]i32, context.temp_allocator)
	for k in g_tr.keys_down do append(&held, k)
	for k in held do release(events, platform.Key_Event{k, false})

	// Live frames continue the recording's numbering (a gap of one after the
	// settle frame), and its clock.
	rp := &g_tr.rp
	rp.take_cur = max(rp.cur, 0) + 2
	rp.take_loop = g_tr.frame
	rp.take_t = rp.cur_t
	rp.take_wall = platform.now_seconds()
	g_tr.live = true
	sdl.GL_SetSwapInterval(1)
	emit_mark("takeover", fmt.tprintf("%s@%d", filepath.base(rp.src_dir), rp.cur))
	_ = os.write_entire_file(fmt.tprintf("%s/.takeover", rp.sandbox), []byte{}) // the next replay keeps this sandbox as _replay.prev

	// The new trace: same snapshot as the source, all records so far, then live.
	root := fmt.tprintf("%s/traces", g_tr.exe_dir)
	now := time.now()
	y, mo, d := time.date(now)
	h, mi, s := time.clock_from_time(now)
	stamp := fmt.tprintf("%04d%02d%02d-%02d%02d%02dZ", y, int(mo), d, h, mi, s)
	dir := fmt.tprintf("%s/%s", root, stamp)
	for k := 2; os.exists(dir); k += 1 do dir = fmt.tprintf("%s/%s-%d", root, stamp, k)
	// Snapshot first (links: snapshots are never written), then prune, so the
	// recording being replayed can't be deleted before it's copied.
	opts := Copy_Opts{budget = max(i64), files = max(int), link = true}
	copy_tree(fmt.tprintf("%s/snapshot", rp.src_dir), fmt.tprintf("%s/snapshot", dir), "", &opts, 0, 32)
	os.make_directory_all(dir)
	prune_traces(root, filepath.base(rp.src_dir), filepath.base(dir))
	g_tr.dir = strings.clone(dir)
	g_tr.status = fmt.aprintf("SANDBOX: files are only written inside traces/%s", TRACE_REPLAY_DIR)
	add_meta(fmt.tprintf("meta derived_from %s", esc(filepath.base(g_tr.rp.src_dir))))
	add_meta(fmt.tprintf("meta derived_until %d", g_tr.rp.cur))
	if !open_files() do return
	snap_ok := rp_meta("snapshot_ok") != "0"
	write_header(meta_json(stamp, snap_ok, 0, filepath.base(g_tr.rp.src_dir), g_tr.rp.cur))
	flush_files()
	fmt.eprintf("trace: took over at recorded frame %d; recording to %s\n", g_tr.rp.cur, dir)
}

// ---------------- Overlay ----------------

trace_draw :: proc(r: ^gpu.Renderer, w, h: int) {
	if g_tr.mode == .Off || g_ui == nil do return
	ink := gpu.Color{0.17, 0.15, 0.13, 1}
	if g_tr.mode == .Record {
		// A small red "recording" dot, top left.
		gpu.draw_circle(r, 14, 14, 4, {0.78, 0.18, 0.18, 0.55})
		return
	}
	rp := &g_tr.rp
	if rp.done && rp.shot != "" && !rp.shot_taken do return // keep the banner out of the screenshot
	msg: string
	if g_tr.live {
		msg = g_tr.status
	} else {
		total := len(rp.frames) > 0 ? rp.frames[len(rp.frames) - 1].frame : 0
		state := rp.done ? "END" : rp.paused ? "PAUSED" : "PLAYING"
		ctl := rp.done || rp.paused ? "Right/F7 step   Back/F6 resume   Start/F5 take over" : "Back/F6 pause   Start/F5 take over"
		if rp.done do ctl = "Start/F5 take over"
		msg = fmt.tprintf("REPLAY %s  frame %d / %d   %s", state, max(rp.cur, 0), min(total, rp.until), ctl)
	}
	if rp.diverged_at >= 0 do msg = fmt.tprintf("%s   (diverged at frame %d)", msg, rp.diverged_at)
	mw := text.measure(g_ui, msg).x
	gpu.draw_rect(r, {8, 6, mw + 20, 28}, {0.98, 0.90, 0.62, 0.95})
	gpu.draw_rect_outline(r, {8, 6, mw + 20, 28}, 1, {0.70, 0.42, 0.00, 1})
	text.draw_line(r, g_ui, {18, 10}, msg, rp.diverged_at >= 0 ? gpu.Color{0.78, 0.18, 0.18, 1} : ink)
}

// trace_after_draw: call after the frame is drawn, before it's presented. Takes
// the --screenshot when the replay has stopped.
trace_after_draw :: proc(w, h: int) {
	rp := &g_tr.rp
	if g_tr.mode != .Replay || !rp.done || rp.shot == "" || rp.shot_taken || w <= 0 || h <= 0 do return
	rp.shot_taken = true
	px := make([]u8, w * h * 4)
	defer delete(px)
	gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
	gl.ReadPixels(0, 0, i32(w), i32(h), gl.RGBA, gl.UNSIGNED_BYTE, raw_data(px))
	// GL rows start at the bottom; PNG rows at the top.
	row := w * 4
	tmp := make([]u8, row, context.temp_allocator)
	for y in 0 ..< h / 2 {
		a := px[y * row:][:row]
		b := px[(h - 1 - y) * row:][:row]
		copy(tmp, a); copy(a, b); copy(b, tmp)
	}
	for i := 3; i < len(px); i += 4 do px[i] = 255 // opaque
	path := strings.clone_to_cstring(rp.shot, context.temp_allocator)
	if stbi.write_png(path, i32(w), i32(h), 4, raw_data(px), i32(row)) == 0 {
		fmt.eprintf("trace: could not write screenshot %s\n", rp.shot)
	} else {
		fmt.eprintf("trace: screenshot %s\n", rp.shot)
	}
}

// ---------------- Files and paths ----------------

// copy_tree copies src into dst (created), keeping modification times.
// Build output, VCS folders, binaries and files over TRACE_FILE_MAX become empty
// placeholders (and folders past max_depth empty folders), so directory listings
// stay the same. With o.link, a file unchanged since `prev` (same size and time)
// is hard-linked instead of copied. Returns false if anything that could matter
// was left out (budget, depth, symlinks).
Copy_Opts :: struct {
	budget:    i64,  // bytes left to copy
	files:     int,  // files left to copy / link
	link:      bool, // hard-link unchanged files from prev (never for a sandbox)
	only_odin: bool, // copy only .odin files (others become placeholders)
	root_scan: bool, // an extra projects folder: like only_odin, but folders past max_depth stay empty and links are skipped, neither making the snapshot incomplete
}

@(private = "file")
copy_tree :: proc(src, dst, prev: string, o: ^Copy_Opts, depth, max_depth: int) -> bool {
	ok := true
	os.make_directory_all(dst)
	fis, err := os.read_all_directory_by_path(src, context.temp_allocator)
	if err != nil do return false
	for fi in fis {
		d := fmt.tprintf("%s/%s", dst, fi.name)
		pv := prev != "" ? fmt.tprintf("%s/%s", prev, fi.name) : ""
		#partial switch fi.type {
		case .Directory:
			skip := fi.name == ".git" || fi.name == "bin" || fi.name == "node_modules" || fi.name == "traces" || strings.has_prefix(fi.name, TRACE_REPLAY_DIR)
			if skip {
				os.make_directory_all(d) // the name only
			} else if depth >= max_depth {
				os.make_directory_all(d)
				if max_depth > 0 && !o.root_scan do ok = false
			} else if !copy_tree(fi.fullpath, d, pv, o, depth + 1, max_depth) {
				ok = false
			}
		case .Regular:
			ext := strings.to_lower(filepath.ext(fi.name), context.temp_allocator)
			binary := ext == ".exe" || ext == ".dll" || ext == ".pdb" || ext == ".obj" || ext == ".lib" || ext == ".ilk"
			wanted := !binary && (!(o.only_odin || o.root_scan) || ext == ".odin")
			if !wanted || fi.size > TRACE_FILE_MAX || fi.size > o.budget || o.files <= 0 {
				_ = os.write_entire_file(d, []byte{})
				if wanted do ok = false
			} else {
				linked := false
				if o.link && pv != "" {
					if pfi, perr := os.stat(pv, context.temp_allocator); perr == nil && pfi.size == fi.size && pfi.modification_time == fi.modification_time {
						linked = os.link(pv, d) == nil
					}
				}
				if !linked {
					if os.copy_file(d, fi.fullpath) != nil {
						ok = false
						continue
					}
					o.budget -= fi.size
				}
				o.files -= 1
			}
			os.change_times(d, fi.access_time, fi.modification_time)
		case:
			if !o.root_scan do ok = false // symlink / junction / device: left out
		}
	}
	return ok
}

@(private = "file")
abs_path :: proc(p: string) -> string {
	if p == "" do return ""
	a, err := os.get_absolute_path(p, context.temp_allocator)
	if err != nil do return p
	return a
}

@(private = "file")
cwd :: proc() -> string {
	d, err := os.get_working_directory(context.temp_allocator)
	if err != nil do return ""
	return d
}

@(private = "file")
norm :: proc(p: string) -> string {
	s, _ := strings.replace_all(p, "\\", "/", context.temp_allocator)
	when ODIN_OS == .Windows do s = strings.to_lower(s, context.temp_allocator)
	return strings.trim_right(s, "/")
}

// rel_under: path relative to base when it's inside base.
@(private = "file")
rel_under :: proc(path, base: string) -> (string, bool) {
	if path == "" || base == "" do return "", false
	p, b := norm(path), norm(base)
	if !strings.has_prefix(p, b) || len(p) <= len(b) || p[len(b)] != '/' do return "", false
	// Slice the original (not lower-cased) path.
	return strings.trim_left(path[len(base):], "/\\"), true
}

@(private = "file")
path_under :: proc(path, base: string) -> bool {
	_, ok := rel_under(abs_path(path), base)
	return ok || norm(abs_path(path)) == norm(base)
}

// esc / unesc: one-token strings for input.log (no spaces, tabs or newlines).
@(private = "file")
esc :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		switch c {
		case '\\': strings.write_string(&b, "\\\\")
		case ' ':  strings.write_string(&b, "\\s")
		case '\t': strings.write_string(&b, "\\t")
		case '\n': strings.write_string(&b, "\\n")
		case '\r': strings.write_string(&b, "\\r")
		case:      strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
unesc :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] {
			case 's':  strings.write_byte(&b, ' ')
			case 't':  strings.write_byte(&b, '\t')
			case 'n':  strings.write_byte(&b, '\n')
			case 'r':  strings.write_byte(&b, '\r')
			case:      strings.write_byte(&b, s[i])
			}
			continue
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

} else {

// ---------------- Harness compiled out: pass-through stubs ----------------

trace_start        :: #force_inline proc(win: ^platform.Window, m: ^model.App) {}
trace_stop         :: #force_inline proc() {}
trace_frame_begin  :: #force_inline proc(m: ^model.App) {}
trace_frame_end    :: #force_inline proc(m: ^model.App) {}
trace_draw         :: #force_inline proc(r: ^gpu.Renderer, w, h: int) {}
trace_after_draw   :: #force_inline proc(w, h: int) {}
trace_replaying    :: #force_inline proc() -> bool { return false }
trace_write_ok     :: #force_inline proc(path: string) -> bool { return true }
trace_str          :: #force_inline proc(kind: string, live: string) -> string { return live }
trace_poll         :: #force_inline proc(win: ^platform.Window, events: ^[dynamic]platform.Event) { platform.poll_events(win, events) }
trace_stt_begin    :: #force_inline proc(e: ^stt.Engine) { stt.begin(e) }
trace_stt_segment  :: #force_inline proc(e: ^stt.Engine) -> string { return stt.segment(e) }
trace_stt_end      :: #force_inline proc(e: ^stt.Engine) -> string { return stt.end(e) }

trace_startup_file :: proc() -> string {
	if len(os.args) > 1 && os.exists(os.args[1]) do return os.args[1]
	return ""
}

}

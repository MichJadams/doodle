package main

// Settings > SETUP: what Doodle needs from the machine, whether it's there,
// and (A) installing what's missing.
//
//   Doodle              this install: up to date, or A updates it from the
//                       latest GitHub release (updater.odin)
//   Odin compiler       everything: problem highlighting, Run, Build. A downloads
//                       the Odin release Doodle is built with (ODIN_TAG),
//                       checks its SHA-256, and unpacks it into
//                       <data>/odin - %LOCALAPPDATA%\doodle\odin on Windows,
//                       ~/.local/share/doodle/odin on Linux - where odin_dir
//                       (shell.odin) looks. (Linux: then the stb libraries too,
//                       when there's a C compiler.)
//   C++ Build Tools     Windows: Odin links through Microsoft's linker and the
//                       Windows SDK. Found with Microsoft's vswhere. A opens
//                       Microsoft's installer (winget, in its own window: the
//                       license and the admin prompt are the user's to answer),
//                       else the download page; found again once it's done.
//   clang               Linux: toolchain.odin.
//   stb libraries       Linux: stb_build.odin. A builds them.
//   Speech-to-text      whisper-cli and its model (in the release): shown only.
//
// The checks that take a moment (vswhere) and the installs run on threads;
// the page polls the results.

import "core:c/libc"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

ODIN_TAG :: "dev-2026-11" // keep in step with .github/workflows/release-steamos.yml
when ODIN_OS == .Windows {
	ODIN_ASSET  :: "odin-windows-amd64-dev-2026-11.zip"
	ODIN_SHA256 :: "259effedf2997293c8fa4a5e497496f8ebce9f826652d9dd353a9dd2113c31fd"
	ODIN_BYTES  :: 162310651
} else when ODIN_ARCH == .arm64 {
	ODIN_ASSET  :: "odin-linux-arm64-dev-2026-11.tar.gz"
	ODIN_SHA256 :: "5bdba22447ea46a99765235e401c2ad83930f967f987aab1531ed76c3aa7ea3b"
	ODIN_BYTES  :: 74227989
} else {
	ODIN_ASSET  :: "odin-linux-amd64-dev-2026-11.tar.gz"
	ODIN_SHA256 :: "65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618"
	ODIN_BYTES  :: 76175813
}
ODIN_URL :: "https://github.com/odin-lang/Odin/releases/download/" + ODIN_TAG + "/" + ODIN_ASSET
ODIN_INSTALL_OFFERED :: ODIN_OS == .Windows || ODIN_OS == .Linux

Setup_Item :: enum { Doodle, Odin, Build_Tools, Clang, Stb, Speech }

// setup_items: this OS's rows, in order. Temp-allocated.
setup_items :: proc() -> []Setup_Item {
	out := make([dynamic]Setup_Item, 0, 6, context.temp_allocator)
	append(&out, Setup_Item.Doodle)
	append(&out, Setup_Item.Odin)
	when ODIN_OS == .Windows do append(&out, Setup_Item.Build_Tools)
	when TOOLCHAIN_OFFERED do append(&out, Setup_Item.Clang)
	when STB_OFFERED do append(&out, Setup_Item.Stb)
	append(&out, Setup_Item.Speech)
	return out[:]
}

SETUP_LABELS := [Setup_Item]string{
	.Doodle      = "Doodle",
	.Odin        = "Odin compiler",
	.Build_Tools = "Microsoft C++ Build Tools",
	.Clang       = "clang (to build and run programs)",
	.Stb         = "Odin's stb libraries",
	.Speech      = "Speech-to-text",
}

g_stt_ready: bool // the speech engine started (main.odin)

// setup_data_dir: Doodle's per-user folder ("" = none). Temp-allocated.
setup_data_dir :: proc() -> string {
	when ODIN_OS == .Windows {
		if l := os.get_env("LOCALAPPDATA", context.temp_allocator); l != "" do return fmt.tprintf("%s/doodle", l)
		return ""
	} else {
		return toolchain_home()
	}
}

// ---- Jobs (installs on a thread) ----

// One install's state (the thread writes it).
Job :: struct {
	state:  Tc_State, // Unknown (idle) / Working / Failed - atomic
	msg:    string,   // why it failed
	thread: ^thread.Thread,
}

g_odin_job: Job
g_stb_job:  Job

job_state :: proc(j: ^Job) -> Tc_State { return Tc_State(sync.atomic_load(cast(^i32)&j.state)) }
job_set   :: proc(j: ^Job, s: Tc_State) { sync.atomic_store(cast(^i32)&j.state, i32(s)) }

@(private = "file")
job_fail :: proc(j: ^Job, msg: string) {
	if j.msg != "" do delete(j.msg)
	j.msg = strings.clone(msg)
	job_set(j, .Failed)
}

@(private = "file")
job_start :: proc(j: ^Job, body: proc()) {
	if job_state(j) == .Working do return
	if trace_replaying() { set_status("not during a replay"); return } // TRACE hook
	if j.thread != nil { thread.join(j.thread); thread.destroy(j.thread); j.thread = nil }
	job_set(j, .Working)
	j.thread = thread.create_and_start(body)
}

// The last line of a log file ("" if none). Temp-allocated.
@(private = "file")
log_last_line :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	lines := strings.split_lines(strings.trim_space(string(data)), context.temp_allocator)
	return len(lines) > 0 ? lines[len(lines) - 1] : ""
}

// A shell command (cmd.exe on Windows, sh elsewhere), its output in `log`.
@(private = "file")
run_logged :: proc(cmd, log: string) -> bool {
	when ODIN_OS == .Windows {
		full := fmt.tprintf("\"%s > \"%s\" 2>&1\"", cmd, log) // cmd /c strips the outer quotes
	} else {
		full := fmt.tprintf("%s > %s 2>&1", cmd, sh_quote(log))
	}
	return libc.system(strings.clone_to_cstring(full, context.temp_allocator)) == 0
}

// run_cmd: a shell command (cmd.exe on Windows, sh elsewhere); true = it worked.
run_cmd :: proc(cmd: string) -> bool {
	when ODIN_OS == .Windows {
		full := fmt.tprintf("\"%s\"", cmd) // cmd /c strips the outer quotes
	} else {
		full := cmd
	}
	return libc.system(strings.clone_to_cstring(full, context.temp_allocator)) == 0
}

// q: a path or URL quoted for this OS's shell.
q :: proc(s: string) -> string {
	when ODIN_OS == .Windows do return fmt.tprintf("\"%s\"", s)
	else do return sh_quote(s)
}

// sys_tool: the system's own curl / tar. On Windows the ones in System32
// (Windows 10+): another `tar` earlier on PATH - Git for Windows' GNU tar -
// reads "C:" in a path as a remote host. Temp-allocated, quoted.
sys_tool :: proc(name: string) -> string {
	when ODIN_OS == .Windows {
		root := os.get_env("SystemRoot", context.temp_allocator)
		if root == "" do root = `C:\Windows`
		exe := fmt.tprintf(`%s\System32\%s.exe`, root, name)
		if os.exists(exe) do return q(exe)
	}
	return name
}

// sha256_file: the file's SHA-256 in lower-case hex ("" if unreadable). Temp-allocated.
sha256_file :: proc(path: string) -> string {
	f, err := os.open(path)
	if err != nil do return ""
	defer os.close(f)
	ctx: hash.Context
	hash.init(&ctx, .SHA256)
	buf := make([]byte, 1 << 20, context.temp_allocator)
	for {
		n, rerr := os.read(f, buf)
		if n > 0 do hash.update(&ctx, buf[:n])
		if rerr != nil || n <= 0 do break
	}
	digest := make([]byte, hash.DIGEST_SIZES[.SHA256], context.temp_allocator)
	hash.final(&ctx, digest)
	return string(hex.encode(digest, context.temp_allocator))
}

// ---- Install Odin ----

setup_install_odin :: proc() {
	when !ODIN_INSTALL_OFFERED do return
	if setup_data_dir() == "" { job_fail(&g_odin_job, "no user folder to install into"); return }
	job_start(&g_odin_job, odin_job_main)
}

@(private = "file")
odin_part :: proc() -> string { return fmt.tprintf("%s/%s.part", setup_data_dir(), ODIN_ASSET) }

@(private = "file")
odin_job_main :: proc() {
	defer free_all(context.temp_allocator)
	dir := setup_data_dir()
	os.make_directory_all(dir)
	log := fmt.tprintf("%s/install-odin.log", dir)
	part := odin_part()
	// Download (curl comes with Windows 10+ and with SteamOS), check, unpack.
	if !run_logged(fmt.tprintf("%s -fL --retry 2 -o %s %s", sys_tool("curl"), q(part), q(ODIN_URL)), log) {
		os.remove(part)
		job_fail(&g_odin_job, fmt.tprintf("download failed: %s (log: %s)", log_last_line(log), log))
		return
	}
	if got := sha256_file(part); got != ODIN_SHA256 {
		os.remove(part)
		job_fail(&g_odin_job, "the download didn't match Odin's published checksum - try again")
		return
	}
	fresh := fmt.tprintf("%s/odin.new", dir)
	os.remove_all(fresh)
	os.make_directory_all(fresh)
	// tar unpacks .zip too (Windows' own tar is bsdtar).
	if !run_logged(fmt.tprintf("%s -xf %s -C %s", sys_tool("tar"), q(part), q(fresh)), log) {
		os.remove_all(fresh)
		os.remove(part)
		job_fail(&g_odin_job, fmt.tprintf("unpacking failed: %s (log: %s)", log_last_line(log), log))
		return
	}
	os.remove(part)
	// The compiler at the top, or in the archive's one folder.
	top := fresh
	if !os.exists(fmt.tprintf("%s/%s", fresh, ODIN_EXE_NAME)) {
		top = ""
		if entries, err := os.read_directory_by_path(fresh, -1, context.temp_allocator); err == nil {
			for e in entries do if e.type == .Directory && os.exists(fmt.tprintf("%s/%s", e.fullpath, ODIN_EXE_NAME)) { top = e.fullpath; break }
		}
	}
	if top == "" {
		os.remove_all(fresh)
		job_fail(&g_odin_job, "the download had no Odin compiler in it")
		return
	}
	final := fmt.tprintf("%s/odin", dir)
	os.remove_all(final)
	if os.rename(top, final) != nil {
		job_fail(&g_odin_job, fmt.tprintf("couldn't move it into %s", final))
		return
	}
	os.remove_all(fresh)
	when STB_OFFERED {
		// Its stb libraries, if there's something to build them with (stb_build.odin).
		if toolchain_bin() != "" || find_in_path("cc") do stb_build_run(final, log)
	}
	job_set(&g_odin_job, .Unknown)
}

// ---- Build the stb libraries (Linux) ----

setup_build_stb :: proc() {
	when !STB_OFFERED do return
	job_start(&g_stb_job, stb_job_main)
}

@(private = "file")
stb_job_main :: proc() {
	defer free_all(context.temp_allocator)
	root := odin_root()
	if root == "" { job_fail(&g_stb_job, "Odin isn't installed"); return }
	dir := setup_data_dir()
	os.make_directory_all(dir)
	log := fmt.tprintf("%s/build-stb.log", dir)
	if !stb_build_run(root, log) || !stb_built(root) {
		job_fail(&g_stb_job, fmt.tprintf("%s (log: %s)", log_last_line(log), log))
		return
	}
	job_set(&g_stb_job, .Unknown)
}

// stb_build_run: build_stb.sh in `root`, with Doodle's clang folder on PATH.
stb_build_run :: proc(root, log: string) -> bool {
	when ODIN_OS == .Windows do return false
	else {
		path := toolchain_bin()
		prefix := path != "" ? fmt.tprintf("PATH=\"$PATH\":%s ", sh_quote(path)) : ""
		return run_logged(fmt.tprintf("%s%s", prefix, stb_build_command(root)), log)
	}
}

// ---- Microsoft C++ Build Tools (Windows) ----

BT_WINGET_ID :: "Microsoft.VisualStudio.BuildTools"
BT_COMPONENT :: "Microsoft.VisualStudio.Component.VC.Tools.x86.x64" // MSVC's x64 compiler and linker

g_bt_found:    i32 // 0 not looked, 1 found, 2 missing - atomic
g_bt_checking: i32 // a check is running - atomic
g_bt_path:     string // where (guarded by g_bt_mu)
g_bt_mu:       sync.Mutex
g_bt_thread:   ^thread.Thread
g_bt_last:     f64  // when the last check started (g_time)
g_bt_opened:   bool // Doodle opened the installer this session

// bt_check: look again, on a thread (the page calls it every few seconds).
bt_check :: proc() {
	when ODIN_OS != .Windows do return
	if sync.atomic_load(&g_bt_checking) != 0 do return
	if trace_replaying() do return // TRACE hook: nothing outside the replay
	if g_bt_thread != nil { thread.join(g_bt_thread); thread.destroy(g_bt_thread); g_bt_thread = nil }
	sync.atomic_store(&g_bt_checking, 1)
	g_bt_last = g_time
	g_bt_thread = thread.create_and_start(bt_check_main)
}

@(private = "file")
bt_vswhere :: proc() -> string {
	pf := os.get_env("ProgramFiles(x86)", context.temp_allocator)
	if pf == "" do pf = "C:/Program Files (x86)"
	return fmt.tprintf("%s/Microsoft Visual Studio/Installer/vswhere.exe", pf)
}

@(private = "file")
bt_check_main :: proc() {
	defer free_all(context.temp_allocator)
	defer sync.atomic_store(&g_bt_checking, 0)
	found := ""
	vw := bt_vswhere()
	dir := setup_data_dir()
	if os.exists(vw) && dir != "" {
		os.make_directory_all(dir)
		out := fmt.tprintf("%s/vswhere.txt", dir)
		cmd := fmt.tprintf("\"\"%s\" -latest -products * -requires %s -property installationPath > \"%s\" 2>nul\"", vw, BT_COMPONENT, out)
		libc.system(strings.clone_to_cstring(cmd, context.temp_allocator))
		if data, err := os.read_entire_file(out, context.temp_allocator); err == nil do found = strings.trim_space(string(data))
	}
	sync.mutex_lock(&g_bt_mu)
	if g_bt_path != "" do delete(g_bt_path, context.allocator)
	g_bt_path = strings.clone(found, context.allocator)
	sync.mutex_unlock(&g_bt_mu)
	sync.atomic_store(&g_bt_found, found != "" ? 1 : 2)
}

// setup_install_build_tools: Microsoft's installer in its own window.
setup_install_build_tools :: proc() {
	when ODIN_OS != .Windows do return
	if trace_replaying() { set_status("not during a replay"); return } // TRACE hook
	winget := fmt.tprintf("%s\\Microsoft\\WindowsApps\\winget.exe", os.get_env("LOCALAPPDATA", context.temp_allocator))
	cmd: string
	if os.exists(winget) {
		// The C++ workload with its recommended parts (the x64 tools and the
		// Windows SDK); the Visual Studio installer shows its progress.
		cmd = fmt.tprintf("cmd /c start \"Doodle setup: C++ Build Tools\" cmd /c \"\"%s\" install --id %s -e --source winget --override \"--passive --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended\" & echo. & echo Done - you can close this window. & pause\"", winget, BT_WINGET_ID)
	} else {
		cmd = "cmd /c start \"\" \"https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio\""
	}
	libc.system(strings.clone_to_cstring(cmd, context.temp_allocator))
	g_bt_opened = true
	set_status(os.exists(winget) ? "Microsoft's installer is open in its own window" : "opened the Build Tools download page")
}

// ---- The page's rows ----

// setup_refresh: look again (the page opening, and while it's open).
setup_refresh :: proc() {
	if !g_up_looked do update_check() // once per session (updater.odin)
	when TOOLCHAIN_OFFERED do toolchain_refresh()
	when ODIN_OS == .Windows {
		if sync.atomic_load(&g_bt_found) == 0 || g_time - g_bt_last > 4 do bt_check()
	}
}

// setup_action: A on a row.
setup_action :: proc(it: Setup_Item) {
	switch it {
	case .Doodle:
		update_action()
	case .Odin:
		if odin_root() == "" do setup_install_odin()
	case .Build_Tools:
		if sync.atomic_load(&g_bt_found) == 2 do setup_install_build_tools()
	case .Clang:
		toolchain_install()
	case .Stb:
		if root := odin_root(); root != "" && !stb_built(root) do setup_build_stb()
	case .Speech:
	}
}

Setup_Look :: enum { Good, Missing, Busy, Bad, Info }

// setup_row: the row's value, the line under it, and how it looks.
setup_row :: proc(it: Setup_Item) -> (value, about: string, look: Setup_Look) {
	switch it {
	case .Doodle:
		return update_row()
	case .Odin:
		root := odin_root()
		switch {
		case job_state(&g_odin_job) == .Working:
			got := 0
			if fi, err := os.stat(odin_part(), context.temp_allocator); err == nil do got = int(fi.size)
			if got > 0 && got < ODIN_BYTES do return fmt.tprintf("%d%%", got * 100 / ODIN_BYTES), fmt.tprintf("Downloading Odin %s: %d of %d MB", ODIN_TAG, got >> 20, ODIN_BYTES >> 20), .Busy
			return "Working...", got > 0 ? "Checking and unpacking..." : "Starting the download...", .Busy
		case root != "":
			return "Found", fmt.tprintf("In %s", root), .Good
		case job_state(&g_odin_job) == .Failed:
			return "Failed", fmt.tprintf("%s   A: try again", g_odin_job.msg), .Bad
		case !ODIN_INSTALL_OFFERED:
			return "Missing", "Install Odin from odin-lang.org and put it on PATH: problem highlighting and Run need it.", .Missing
		}
		return "Install", fmt.tprintf("Not found: problem highlighting and Run are off. A downloads Odin %s (%d MB) into %s.", ODIN_TAG, ODIN_BYTES >> 20, setup_data_dir()), .Missing
	case .Build_Tools:
		switch sync.atomic_load(&g_bt_found) {
		case 1:
			sync.mutex_lock(&g_bt_mu)
			p := strings.clone(g_bt_path, context.temp_allocator)
			sync.mutex_unlock(&g_bt_mu)
			return "Found", fmt.tprintf("In %s", p), .Good
		case 2:
			if g_bt_opened do return "Installing...", "Finish Microsoft's installer in its window; this turns to Found when it's done.", .Busy
			return "Install", "Not found: Run and Build can't link programs (problem highlighting still works). A opens Microsoft's installer (about 3 GB).", .Missing
		}
		return "Checking...", "Looking for Microsoft's C++ linker and the Windows SDK...", .Busy
	case .Clang:
		value, about = toolchain_row()
		#partial switch tc_get() {
		case .Installed, .System: look = .Good
		case .Working:            look = .Busy
		case .Failed:             look = .Bad
		case:                     look = .Missing
		}
		return
	case .Stb:
		root := odin_root()
		switch {
		case root == "":
			return "-", "Install Odin first.", .Info
		case job_state(&g_stb_job) == .Working:
			return "Building...", fmt.tprintf("Building them in %s/vendor/stb/lib", root), .Busy
		case stb_built(root):
			return "Built", "Programs that import vendor:stb (image, truetype, ...) can build.", .Good
		case job_state(&g_stb_job) == .Failed:
			return "Failed", fmt.tprintf("%s   A: try again", g_stb_job.msg), .Bad
		case toolchain_bin() == "" && !find_in_path("cc"):
			return "Not built", "Programs that import vendor:stb can't build yet. Install clang first, then A builds them.", .Missing
		}
		return "Build", "Programs that import vendor:stb can't build yet. A builds them (a few seconds).", .Missing
	case .Speech:
		if g_stt_ready do return "Ready", "Hold Talk to dictate names, numbers, strings and comments.", .Good
		return "Not set up", "whisper-cli or its model isn't next to Doodle (they come with the release), or there's no microphone.", .Info
	}
	return "", "", .Info
}

// setup_missing: something Doodle needs isn't there (the startup hint).
setup_missing :: proc() -> string {
	if odin_root() == "" do return "Odin isn't installed: main menu > Settings > Setup can install it"
	return ""
}


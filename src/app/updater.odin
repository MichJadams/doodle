package main

// Settings > Setup > Doodle: update to the latest GitHub release, in place.
//
// An installed release has <root>/VERSION ("0.3.0 (abc1234, Odin ..., ...)",
// written by the release workflow) next to <root>/bin/doodle(.exe); which
// package it is comes from the same line ("ubuntu" = the Linux one, "windows"
// = Windows, else SteamOS). Without VERSION it's a build from source: no updates.
//
// Checking: the releases/latest API (once per session, when Settings opens).
// Updating: the package for this install, checksum-checked against the
// release's published SHA-256, unpacked next to <root>, then
//   Linux / SteamOS   swapped in now (rename <root> away, the new one in its
//                     place; a running program's files can be replaced on
//                     Linux). The settings files in bin/ come along. Restart
//                     Doodle to use it.
//   Windows           a running .exe and its DLLs can't be overwritten, so a
//                     small script waits for Doodle to close, copies the new
//                     files over <root> (the settings files aren't in the
//                     package, so they stay), and starts the new Doodle. A
//                     closes Doodle to let it run.

import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"

UPDATE_REPO :: "MichJadams/doodle"

// The files Doodle keeps next to its binary (heat_store, keys_store, roots_store, settings).
KEEP_FILES :: [?]string{"doodle_keys.tsv", "doodle_heat.tsv", "doodle_roots.txt", "doodle_settings.txt"}

Up_State :: enum i32 {
	Idle,        // not looked yet
	Checking,
	Current,     // up to date
	Available,   // a newer release: A installs it
	Working,     // downloading / unpacking / swapping
	Ready,       // Linux: installed, restart to use it
	Staged,      // Windows: unpacked, A closes Doodle to finish
	Failed,      // g_up_msg says why; A tries again
}

g_up_state:  Up_State // atomic (the threads write it)
g_up_msg:    string   // the failure (written before Failed)
g_up_latest: string   // the newest release's tag ("v0.4.0")
g_up_url:    string   // its package for this install
g_up_sha:    string
g_up_size:   int
g_up_part:   string   // where the download goes (for the progress)
g_up_stage:  string   // Windows: the unpacked new version
g_up_thread: ^thread.Thread
g_up_looked: bool     // checked this session

up_get :: proc() -> Up_State { return Up_State(sync.atomic_load(cast(^i32)&g_up_state)) }
up_set :: proc(s: Up_State) { sync.atomic_store(cast(^i32)&g_up_state, i32(s)) }

@(private = "file")
up_fail :: proc(msg: string) {
	if g_up_msg != "" do delete(g_up_msg)
	g_up_msg = strings.clone(msg)
	up_set(.Failed)
}

@(private = "file")
set_owned :: proc(dst: ^string, s: string) {
	if dst^ != "" do delete(dst^)
	dst^ = strings.clone(s)
}

// ---- This install ----

// install_root: <root> of this install (bin/..) and its VERSION line; ok =
// false for a build from source (no VERSION). Temp-allocated.
install_root :: proc() -> (root, version_line: string, ok: bool) {
	exe := heat_exe_dir()
	defer delete(exe)
	if exe == "" do return
	r, _ := filepath.abs(fmt.tprintf("%s/..", exe), context.temp_allocator)
	data, err := os.read_entire_file(fmt.tprintf("%s/VERSION", r), context.temp_allocator)
	if err != nil do return
	line := strings.trim_space(strings.trim_prefix(string(data), "\xef\xbb\xbf"))
	if line == "" do return
	return r, line, true
}

// install_version: "0.3.0" from "0.3.0 (abc1234, ...)".
install_version :: proc(line: string) -> string {
	if sp := strings.index_byte(line, ' '); sp > 0 do return line[:sp]
	return line
}

// install_asset: the release package this install came from.
install_asset :: proc(line: string) -> string {
	when ODIN_OS == .Windows do return "doodle-windows.zip"
	else {
		if strings.contains(line, "ubuntu") do return "doodle-linux.tar.gz"
		return "doodle-steamos.tar.gz"
	}
}

// ---- Checking ----

update_check :: proc() {
	if s := up_get(); s == .Checking || s == .Working do return
	if trace_replaying() do return // TRACE hook: nothing outside the replay
	if _, _, ok := install_root(); !ok do return
	g_up_looked = true
	if g_up_thread != nil { thread.join(g_up_thread); thread.destroy(g_up_thread); g_up_thread = nil }
	up_set(.Checking)
	g_up_thread = thread.create_and_start(check_main)
}

Release_Asset :: struct { name, browser_download_url, digest: string, size: int }
Release_Info :: struct { tag_name: string, assets: []Release_Asset }

@(private = "file")
check_main :: proc() {
	defer free_all(context.temp_allocator)
	_, line, _ := install_root()
	dir := setup_data_dir()
	os.make_directory_all(dir)
	out := fmt.tprintf("%s/latest-release.json", dir)
	os.remove(out)
	api := fmt.tprintf("https://api.github.com/repos/%s/releases/latest", UPDATE_REPO)
	run_cmd(fmt.tprintf("%s -fsSL -o %s %s", sys_tool("curl"), q(out), q(api)))
	data, err := os.read_entire_file(out, context.temp_allocator)
	if err != nil { up_fail("couldn't reach GitHub (no internet?)"); return }
	info: Release_Info
	if json.unmarshal(data, &info, allocator = context.temp_allocator) != nil || info.tag_name == "" {
		up_fail("GitHub's answer didn't make sense")
		return
	}
	want := install_asset(line)
	for a in info.assets do if a.name == want {
		set_owned(&g_up_latest, info.tag_name)
		set_owned(&g_up_url, a.browser_download_url)
		set_owned(&g_up_sha, strings.trim_prefix(a.digest, "sha256:"))
		g_up_size = a.size
		up_set(fmt.tprintf("v%s", install_version(line)) == info.tag_name ? .Current : .Available)
		return
	}
	up_fail(fmt.tprintf("the latest release (%s) has no %s", info.tag_name, want))
}

// ---- Updating ----

update_install :: proc() {
	if up_get() != .Available do return
	if trace_replaying() { set_status("not during a replay"); return } // TRACE hook
	if g_up_thread != nil { thread.join(g_up_thread); thread.destroy(g_up_thread); g_up_thread = nil }
	up_set(.Working)
	g_up_thread = thread.create_and_start(install_main)
}

@(private = "file")
install_main :: proc() {
	defer free_all(context.temp_allocator)
	root, _, ok := install_root()
	if !ok { up_fail("this isn't an installed release"); return }
	parent := filepath.dir(root)
	// Next to <root>: the same disk, so the swap is a rename.
	set_owned(&g_up_part, fmt.tprintf("%s/.doodle-update.download", parent))
	stage := fmt.tprintf("%s/.doodle-update", parent)
	log := fmt.tprintf("%s/.doodle-update.log", parent)
	part := g_up_part
	if !run_cmd(fmt.tprintf("%s -fL --retry 2 -o %s %s > %s 2>&1", sys_tool("curl"), q(part), q(g_up_url), q(log))) {
		os.remove(part)
		up_fail("the download failed (no internet?)")
		return
	}
	if g_up_sha != "" && sha256_file(part) != g_up_sha {
		os.remove(part)
		up_fail("the download didn't match the release's checksum - try again")
		return
	}
	os.remove_all(stage)
	os.make_directory_all(stage)
	if !run_cmd(fmt.tprintf("%s -xf %s -C %s > %s 2>&1", sys_tool("tar"), q(part), q(stage), q(log))) {
		os.remove(part)
		os.remove_all(stage)
		up_fail("unpacking the update failed")
		return
	}
	os.remove(part)
	os.remove(log)
	fresh := new_root_in(stage)
	if fresh == "" {
		os.remove_all(stage)
		up_fail("the update had no Doodle in it")
		return
	}
	when ODIN_OS == .Windows {
		set_owned(&g_up_stage, fresh)
		up_set(.Staged)
	} else {
		if msg := swap_in(root, fresh, parent); msg != "" {
			os.remove_all(stage)
			up_fail(msg)
			return
		}
		os.remove_all(stage)
		up_set(.Ready)
	}
}

// new_root_in: the unpacked package's root (the folder with bin/doodle in it:
// the archive's top folder, or the stage itself). Temp-allocated.
new_root_in :: proc(stage: string) -> string {
	if os.exists(fmt.tprintf("%s/bin/%s", stage, DOODLE_EXE)) do return stage
	entries, err := os.read_directory_by_path(stage, -1, context.temp_allocator)
	if err != nil do return ""
	for e in entries do if e.type == .Directory && os.exists(fmt.tprintf("%s/bin/%s", e.fullpath, DOODLE_EXE)) do return e.fullpath
	return ""
}

DOODLE_EXE :: "doodle.exe" when ODIN_OS == .Windows else "doodle"

// swap_in (Linux): the settings files into the new bin/, then <root> -> a
// side name, the new one -> <root>, and the old one deleted. "" = done; else
// what went wrong (the old install is put back).
swap_in :: proc(root, fresh, parent: string) -> string {
	for f in KEEP_FILES {
		if data, err := os.read_entire_file(fmt.tprintf("%s/bin/%s", root, f), context.temp_allocator); err == nil {
			_ = os.write_entire_file(fmt.tprintf("%s/bin/%s", fresh, f), data)
		}
	}
	old := fmt.tprintf("%s/.doodle-old", parent)
	os.remove_all(old)
	if os.rename(root, old) != nil do return fmt.tprintf("couldn't move %s aside", root)
	if os.rename(fresh, root) != nil {
		_ = os.rename(old, root)
		return fmt.tprintf("couldn't put the new version in %s", root)
	}
	os.remove_all(old)
	return ""
}

// update_finish (Windows, A on "Restart"): the script that copies the new
// version over <root> once Doodle has closed, then starts it; then close.
update_finish :: proc() {
	when ODIN_OS == .Windows {
		if up_get() != .Staged do return
		root, _, ok := install_root()
		if !ok do return
		script := fmt.tprintf("%s/.doodle-update.cmd", filepath.dir(root))
		body := windows_update_script(root, g_up_stage, current_pid())
		if os.write_entire_file(script, transmute([]byte)body) != nil {
			up_fail("couldn't write the update script")
			return
		}
		win_script, _ := strings.replace_all(script, "/", "\\", context.temp_allocator)
		libc.system(strings.clone_to_cstring(fmt.tprintf("start \"\" /min cmd /c \"%s\"", win_script), context.temp_allocator))
		if g_app != nil do g_app.want_quit = true
	}
}

// windows_update_script: wait for Doodle (pid) to close, copy `fresh` over
// `root` (files not in the package - the settings - stay), start Doodle,
// clean up. Temp-allocated.
windows_update_script :: proc(root, fresh: string, pid: int) -> string {
	w :: proc(p: string) -> string { s, _ := strings.replace_all(p, "/", "\\", context.temp_allocator); return s }
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "@echo off\r\n")
	strings.write_string(&b, "rem Doodle's updater (Settings > Setup > Doodle): runs once Doodle has closed.\r\n")
	strings.write_string(&b, ":wait\r\n")
	fmt.sbprintf(&b, "tasklist /FI \"PID eq %d\" 2>nul | find \"%d\" >nul && (timeout /t 1 /nobreak >nul & goto wait)\r\n", pid, pid)
	fmt.sbprintf(&b, "robocopy \"%s\" \"%s\" /E /R:10 /W:1 /NFL /NDL /NJH /NJS >nul\r\n", w(fresh), w(root))
	fmt.sbprintf(&b, "rmdir /s /q \"%s\"\r\n", w(filepath.dir(fresh)))
	fmt.sbprintf(&b, "start \"\" \"%s\\bin\\doodle.exe\"\r\n", w(root))
	// Delete this script without cmd complaining that it can't read the next line.
	strings.write_string(&b, "(goto) 2>nul & del \"%~f0\"\r\n")
	return strings.to_string(b)
}

// The page: A on the Doodle row.
update_action :: proc() {
	switch up_get() {
	case .Idle, .Current, .Failed: update_check()
	case .Available:               update_install()
	case .Ready:                   if g_app != nil do g_app.want_quit = true // start it again to use the new one
	case .Staged:                  update_finish()
	case .Checking, .Working:
	}
}

// update_row: the Doodle row (setup.odin).
update_row :: proc() -> (value, about: string, look: Setup_Look) {
	_, line, ok := install_root()
	if !ok do return "From source", "A build from source: update it with git pull, then build.sh / build.bat.", .Info
	cur := install_version(line)
	switch up_get() {
	case .Idle:
		return "Check", fmt.tprintf("Version %s. A checks GitHub for a newer release.", cur), .Info
	case .Checking:
		return "Checking...", fmt.tprintf("Version %s. Asking GitHub for the latest release...", cur), .Busy
	case .Current:
		return "Up to date", fmt.tprintf("Version %s is the latest release.", cur), .Good
	case .Available:
		return "Update", fmt.tprintf("Version %s; %s is out. A downloads it (%d MB) and installs it.", cur, g_up_latest, g_up_size >> 20), .Missing
	case .Working:
		got := 0
		if g_up_part != "" {
			if fi, err := os.stat(g_up_part, context.temp_allocator); err == nil do got = int(fi.size)
		}
		if got > 0 && got < g_up_size do return fmt.tprintf("%d%%", got * 100 / max(g_up_size, 1)), fmt.tprintf("Downloading %s: %d of %d MB", g_up_latest, got >> 20, g_up_size >> 20), .Busy
		return "Working...", got > 0 ? fmt.tprintf("Checking and unpacking %s...", g_up_latest) : "Starting the download...", .Busy
	case .Ready:
		return "Restart", fmt.tprintf("%s is installed. A quits Doodle; start it again to use it.", g_up_latest), .Good
	case .Staged:
		return "Restart", fmt.tprintf("%s is ready. A closes Doodle, puts it in place and starts it again.", g_up_latest), .Good
	case .Failed:
		return "Failed", fmt.tprintf("%s   A: try again", g_up_msg), .Bad
	}
	return "", "", .Info
}

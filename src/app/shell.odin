package main

// Cross-platform helpers for running shell commands: finding the Odin compiler,
// POSIX quoting, and opening a visible terminal on Linux / macOS.
// Windows keeps using cmd.exe (see run.odin / checker.odin).

import "core:os"
import "core:fmt"
import "core:strings"
import "core:path/filepath"

ODIN_EXE_NAME :: "odin.exe" when ODIN_OS == .Windows else "odin"

// odin_dir finds the folder holding the Odin compiler (native separators,
// temp-allocated), or "" to rely on PATH.
// Order: $ODIN_DIR, $ODIN_ROOT, a toolchain bundled next to Doodle
// (<exe>/toolchain/odin or <exe>/../toolchain/odin), then default installs.
odin_dir :: proc() -> string {
	@(static) exe_dir: string // heat_exe_dir allocates; look it up once
	@(static) exe_dir_done: bool
	if !exe_dir_done {
		exe_dir = heat_exe_dir()
		exe_dir_done = true
	}
	home := os.get_env("HOME", context.temp_allocator)
	candidates := [?]string{
		os.get_env("ODIN_DIR", context.temp_allocator),
		os.get_env("ODIN_ROOT", context.temp_allocator),
		exe_dir != "" ? fmt.tprintf("%s/toolchain/odin", exe_dir) : "",
		exe_dir != "" ? fmt.tprintf("%s/../toolchain/odin", exe_dir) : "",
		"C:\\Odin" when ODIN_OS == .Windows else (home != "" ? fmt.tprintf("%s/odin", home) : ""),
		"" when ODIN_OS == .Windows else "/opt/odin",
	}
	for c in candidates {
		if c == "" do continue
		if os.exists(fmt.tprintf("%s/%s", c, ODIN_EXE_NAME)) {
			when ODIN_OS == .Windows {
				d, _ := strings.replace_all(c, "/", "\\", context.temp_allocator)
				return d
			} else {
				d, _ := filepath.clean(c, context.temp_allocator)
				return d
			}
		}
	}
	return ""
}

// odin_exe: full path to the compiler if odin_dir found one, else "odin" (PATH).
odin_exe :: proc(allocator := context.allocator) -> string {
	if od := odin_dir(); od != "" {
		sep := "\\" when ODIN_OS == .Windows else "/"
		return strings.concatenate({od, sep, ODIN_EXE_NAME}, allocator)
	}
	return strings.clone("odin", allocator)
}

// sh_quote wraps s in POSIX single quotes ('it'\''s' style), safe for sh -c.
sh_quote :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '\'')
	for ch in s {
		if ch == '\'' do strings.write_string(&b, `'\''`)
		else do strings.write_rune(&b, ch)
	}
	strings.write_byte(&b, '\'')
	return strings.to_string(b)
}

// run_script_text builds the sh script a Run executes: cd into the project,
// put Odin on PATH, run the command, and (like the Windows console) wait for
// Enter when it fails, or always when keep_open is set.
run_script_text :: proc(dir, odin_dir, cmd: string, keep_open: bool, lib_dirs: []string = nil, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "#!/bin/sh\n")
	fmt.sbprintf(&b, "cd %s || exit 1\n", sh_quote(dir))
	if odin_dir != "" do fmt.sbprintf(&b, "PATH=%s:\"$PATH\"; export PATH\n", sh_quote(odin_dir))
	// The vendor library folders the project's imports need (vendor_path.odin).
	if len(lib_dirs) > 0 {
		v := "DYLD_LIBRARY_PATH" when ODIN_OS == .Darwin else "LD_LIBRARY_PATH"
		fmt.sbprintf(&b, "%s=%s${%s:+:$%s}; export %s\n", v, sh_quote(strings.join(lib_dirs, ":", context.temp_allocator)), v, v, v)
	}
	fmt.sbprintf(&b, "printf '%%s\\n\\n' %s\n", sh_quote(fmt.tprintf("$ %s", cmd)))
	fmt.sbprintf(&b, "(\n%s\n)\n", cmd) // subshell: an `exit`/`cd` in cmd can't skip the pause
	strings.write_string(&b, "status=$?\n")
	cond := keep_open ? "true" : "[ \"$status\" -ne 0 ]"
	fmt.sbprintf(&b, "if %s; then printf '\\n[exit %%d] Press Enter to close...' \"$status\"; read _; fi\n", cond)
	strings.write_string(&b, "exit $status\n")
	return strings.to_string(b)
}

// Terminal emulators to try, with the flag that precedes the program to run.
// konsole first: it's what SteamOS Desktop Mode ships.
TERMINALS :: [?][2]string{
	{"konsole", "-e"},
	{"gnome-terminal", "--"},
	{"xfce4-terminal", "-x"},
	{"kitty", ""},
	{"alacritty", "-e"},
	{"foot", ""},
	{"wezterm", "start --"},
	{"xterm", "-e"},
	{"x-terminal-emulator", "-e"},
}

// terminal_prefix returns the command prefix that opens a new terminal window
// running whatever follows it, or "" when there's no usable terminal (no
// display, or $DOODLE_TERMINAL=none). $DOODLE_TERMINAL / $TERMINAL override the
// search and are used as-is (e.g. DOODLE_TERMINAL="konsole --hold -e").
terminal_prefix :: proc() -> string {
	override := os.get_env("DOODLE_TERMINAL", context.temp_allocator)
	if override == "none" do return ""
	if override != "" do return override
	when ODIN_OS == .Darwin {
		return "open -a Terminal"
	}
	if os.get_env("DISPLAY", context.temp_allocator) == "" && os.get_env("WAYLAND_DISPLAY", context.temp_allocator) == "" {
		return ""
	}
	if t := os.get_env("TERMINAL", context.temp_allocator); t != "" && find_in_path(t) {
		return fmt.tprintf("%s -e", t)
	}
	for t in TERMINALS {
		if find_in_path(t[0]) do return t[1] == "" ? t[0] : fmt.tprintf("%s %s", t[0], t[1])
	}
	return ""
}

// find_in_path: is `name` an existing file in a $PATH folder (or a path itself)?
find_in_path :: proc(name: string) -> bool {
	if strings.contains_rune(name, '/') do return os.exists(name)
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split_iterator(&path, ":") {
		if dir != "" && os.exists(fmt.tprintf("%s/%s", dir, name)) do return true
	}
	return false
}

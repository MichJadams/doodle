package main

// Settings > Setup > clang (Linux / Steam Deck): Odin's Linux release links
// programs through `clang`, which SteamOS doesn't have (and its root filesystem
// is read-only). Zig's single download carries a complete clang (`zig cc`) that
// needs no root and no system headers, so Doodle can fetch it into the home
// folder and put a `clang` that runs it where its Runs look:
//
//   ~/.local/share/doodle/zig/        Zig (ZIG_VERSION), checksum-checked
//   ~/.local/share/doodle/bin/clang   #!/bin/sh  exec .../zig/zig cc "$@"
//   ~/.local/share/doodle/bin/cc, ar  the same for C / archives (Odin's build_stb.sh)
//
// Runs started from Doodle get that bin folder at the END of PATH (run.odin),
// so a real clang, if there is one, still wins. To use it outside Doodle, add
// ~/.local/share/doodle/bin to PATH. ($XDG_DATA_HOME/doodle instead of
// ~/.local/share/doodle when that's set.) Tested: `odin run` / `odin build`
// of a core:fmt program and a vendor:sdl2 one link and run with only this
// clang on PATH.
//
// The download and unpacking run on a thread; the Settings page shows the
// progress. Windows / macOS: not needed (Odin uses MSVC / Xcode's clang).

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

ZIG_VERSION :: "0.17.1"
when ODIN_ARCH == .arm64 {
	ZIG_URL    :: "https://ziglang.org/download/0.17.1/zig-aarch64-linux-0.17.1.tar.xz"
	ZIG_SHA256 :: "a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795"
	ZIG_BYTES  :: 52977364
} else {
	ZIG_URL    :: "https://ziglang.org/download/0.17.1/zig-x86_64-linux-0.17.1.tar.xz"
	ZIG_SHA256 :: "3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a"
	ZIG_BYTES  :: 57411036
}

// Is the Settings row there at all?
TOOLCHAIN_OFFERED :: ODIN_OS == .Linux

Tc_State :: enum i32 {
	Unknown,     // not looked yet
	System,      // a clang is on PATH already
	Installed,   // ours is there
	Missing,     // neither: A installs
	Working,     // downloading / unpacking (the thread)
	Failed,      // the last try failed: g_tc_msg says why; A tries again
}

g_tc_state:  Tc_State // atomic (the install thread writes it)
g_tc_msg:    string   // the failure reason (written by the thread before Failed)
g_tc_thread: ^thread.Thread

tc_get :: proc() -> Tc_State { return Tc_State(sync.atomic_load(cast(^i32)&g_tc_state)) }
tc_set :: proc(s: Tc_State) { sync.atomic_store(cast(^i32)&g_tc_state, i32(s)) }

// toolchain_home: where it goes ("" = no home folder). Temp-allocated.
toolchain_home :: proc() -> string {
	if x := os.get_env("XDG_DATA_HOME", context.temp_allocator); x != "" do return fmt.tprintf("%s/doodle", x)
	if h := os.get_env("HOME", context.temp_allocator); h != "" do return fmt.tprintf("%s/.local/share/doodle", h)
	return ""
}

// toolchain_bin: the folder with our `clang`, when it's installed (else "").
toolchain_bin :: proc() -> string {
	when !TOOLCHAIN_OFFERED do return ""
	home := toolchain_home()
	if home == "" do return ""
	if os.exists(fmt.tprintf("%s/bin/clang", home)) && os.exists(fmt.tprintf("%s/zig/zig", home)) do return fmt.tprintf("%s/bin", home)
	return ""
}

// toolchain_refresh: look again (opening Settings, after an install).
toolchain_refresh :: proc() {
	if tc_get() == .Working do return
	switch {
	case toolchain_bin() != "":  tc_set(.Installed)
	case find_in_path("clang"):  tc_set(.System)
	case:                        tc_set(.Missing)
	}
}

// toolchain_install starts the download (A on the row).
toolchain_install :: proc() {
	when !TOOLCHAIN_OFFERED do return
	if s := tc_get(); s == .Working || s == .Installed || s == .System do return
	if trace_replaying() { set_status("not during a replay"); return } // TRACE hook
	home := toolchain_home()
	if home == "" { tc_fail("no home folder to install into"); return }
	if g_tc_thread != nil { thread.destroy(g_tc_thread); g_tc_thread = nil }
	tc_set(.Working)
	g_tc_thread = thread.create_and_start(tc_thread_main)
}

@(private = "file")
tc_fail :: proc(msg: string) {
	if g_tc_msg != "" do delete(g_tc_msg)
	g_tc_msg = strings.clone(msg)
	tc_set(.Failed)
}

@(private = "file")
tc_thread_main :: proc() {
	home := toolchain_home()
	script := fmt.tprintf("%s/install-clang.sh", home)
	log := fmt.tprintf("%s/install-clang.log", home)
	os.make_directory_all(home)
	if os.write_entire_file(script, transmute([]byte)toolchain_script(home, ZIG_URL, ZIG_SHA256, odin_root())) != nil {
		tc_fail("couldn't write the install script")
		return
	}
	status := libc.system(strings.clone_to_cstring(fmt.tprintf("sh %s >%s 2>&1", sh_quote(script), sh_quote(log)), context.temp_allocator))
	if status == 0 && toolchain_bin() != "" {
		tc_set(.Installed)
	} else {
		// The log's last line says what went wrong (curl / sha256sum / tar).
		why := "the install failed"
		if data, err := os.read_entire_file(log, context.temp_allocator); err == nil {
			lines := strings.split_lines(strings.trim_space(string(data)), context.temp_allocator)
			if len(lines) > 0 && lines[len(lines) - 1] != "" do why = lines[len(lines) - 1]
		}
		tc_fail(fmt.tprintf("%s (log: %s)", why, log))
	}
	free_all(context.temp_allocator)
}

// toolchain_script: the sh script that installs it into `home`. Download to a
// .part file, check it, unpack beside the old copy, then swap it in - a failure
// half way leaves the old install (or nothing) behind, never a broken one.
toolchain_script :: proc(home, url, sha: string, odin_root := "", allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "#!/bin/sh\nset -eu\n")
	fmt.sbprintf(&b, "cd %s\n", sh_quote(home))
	fmt.sbprintf(&b, "curl -fL --retry 2 -o zig.tar.xz.part %s\n", sh_quote(url))
	fmt.sbprintf(&b, "echo %s | sha256sum -c -\n", sh_quote(fmt.tprintf("%s  zig.tar.xz.part", sha)))
	strings.write_string(&b, "rm -rf zig.new && mkdir zig.new\n")
	strings.write_string(&b, "tar -xJf zig.tar.xz.part -C zig.new --strip-components=1\n")
	strings.write_string(&b, "rm -rf zig && mv zig.new zig && rm -f zig.tar.xz.part\n")
	strings.write_string(&b, "mkdir -p bin\n")
	// bin/clang (what Odin links with), bin/cc and bin/ar (what Odin's
	// vendor/stb/src/build_stb.sh needs, for programs using vendor:stb): Zig's.
	fmt.sbprintf(&b, "cat > bin/cc <<'DOODLE_EOF'\n%sDOODLE_EOF\n", TC_CC_WRAPPER)
	fmt.sbprintf(&b, "cat > bin/ar <<'DOODLE_EOF'\n%sDOODLE_EOF\n", TC_AR_WRAPPER)
	strings.write_string(&b, "cp bin/cc bin/clang\n")
	strings.write_string(&b, "chmod +x bin/clang bin/cc bin/ar\n")
	strings.write_string(&b, "./bin/clang --version\n")
	// Odin's stb libraries (vendor:stb; stb_build.odin), if they aren't built
	// yet - with the cc / ar just installed. Optional: a failure here leaves
	// clang installed (a Run asks again).
	fmt.sbprintf(&b, "ROOT=%s\n", sh_quote(odin_root))
	strings.write_string(&b, TC_STB_STEP)
	return strings.to_string(b)
}

TC_STB_STEP :: `if [ -z "$ROOT" ] && command -v odin >/dev/null 2>&1; then ROOT="$(dirname "$(readlink -f "$(command -v odin)")")"; fi
if [ -n "$ROOT" ] && [ -f "$ROOT/vendor/stb/src/build_stb.sh" ] && ! ls "$ROOT"/vendor/stb/lib/*.a >/dev/null 2>&1; then
	echo "building Odin's stb libraries in $ROOT"
	PATH="$PWD/bin:$PATH" sh "$ROOT/vendor/stb/src/build_stb.sh" || echo "note: couldn't build Odin's stb libraries in $ROOT"
fi
`

// bin/cc and bin/clang: `zig cc`, found next to the script (../zig/zig). Two
// fix-ups: `-l:/path/lib.a` becomes the path (Odin's foreign static libraries),
// and `zig cc -c a.c b.c` (several sources, no -o - build_stb.sh does that),
// which only writes a.o, becomes a run per source.
TC_CC_WRAPPER :: `#!/bin/sh
Z="$(dirname "$0")/../zig/zig"
# Odin links a foreign static library as -l:/full/path/lib.a, which zig cc
# refuses ("cannot use absolute path as a system library"): pass the file itself.
first=1
for a in "$@"; do
	if [ $first = 1 ]; then set --; first=0; fi
	case $a in -l:/*) a=${a#-l:} ;; esac
	set -- "$@" "$a"
done
c=0; o=0; n=0
for a in "$@"; do
	case $a in
	-c) c=1 ;;
	-o) o=1 ;;
	*.c|*.cc|*.cpp|*.cxx|*.m) n=$((n + 1)) ;;
	esac
done
if [ $c = 0 ] || [ $o = 1 ] || [ $n -le 1 ]; then exec "$Z" cc "$@"; fi
for s in "$@"; do
	case $s in *.c|*.cc|*.cpp|*.cxx|*.m) ;; *) continue ;; esac
	(
		first=1
		for a in "$@"; do
			if [ $first = 1 ]; then set --; first=0; fi
			case $a in *.c|*.cc|*.cpp|*.cxx|*.m) [ "$a" = "$s" ] || continue ;; esac
			set -- "$@" "$a"
		done
		exec "$Z" cc "$@"
	) || exit $?
done
`

// bin/ar: `zig ar`.
TC_AR_WRAPPER :: `#!/bin/sh
exec "$(dirname "$0")/../zig/zig" ar "$@"
`

// toolchain_row: the Settings row's value and the line under it.
toolchain_row :: proc() -> (value, about: string) {
	switch tc_get() {
	case .Unknown, .Missing:
		return "Install", fmt.tprintf("SteamOS has no clang, which Odin needs to build and run programs. A downloads Zig %s's clang (about 57 MB) into %s.", ZIG_VERSION, toolchain_home())
	case .System:
		return "Found", "clang is already installed: Run builds and runs programs."
	case .Installed:
		stb := ""
		if root := odin_root(); root != "" && stb_built(root) do stb = " Odin's stb libraries are built too."
		return "Installed", fmt.tprintf("Zig %s's clang, in %s/bin (Runs use it; add that folder to PATH to use it outside Doodle).%s", ZIG_VERSION, toolchain_home(), stb)
	case .Working:
		got := 0
		if fi, err := os.stat(fmt.tprintf("%s/zig.tar.xz.part", toolchain_home()), context.temp_allocator); err == nil do got = int(fi.size)
		if got == 0 do return "Working...", "Starting the download..."
		if got < ZIG_BYTES do return fmt.tprintf("%d%%", got * 100 / ZIG_BYTES), fmt.tprintf("Downloading Zig %s: %d of %d MB", ZIG_VERSION, got >> 20, ZIG_BYTES >> 20)
		return "Working...", fmt.tprintf("Downloaded %d MB; unpacking...", got >> 20)
	case .Failed:
		return "Failed", fmt.tprintf("%s   A: try again", g_tc_msg)
	}
	return "", ""
}

package main

import "core:testing"
import "core:strings"
import "core:os"
import "core:path/filepath"

@(test)
test_sh_quote :: proc(t: ^testing.T) {
	testing.expect_value(t, sh_quote("plain"), "'plain'")
	testing.expect_value(t, sh_quote("/home/deck/My Projects"), "'/home/deck/My Projects'")
	testing.expect_value(t, sh_quote("it's"), `'it'\''s'`)
	testing.expect_value(t, sh_quote("$HOME `x` \"q\""), "'$HOME `x` \"q\"'")
	testing.expect_value(t, sh_quote(""), "''")
}

@(test)
test_run_script_text :: proc(t: ^testing.T) {
	s := run_script_text("/home/deck/it's here", "/home/deck/odin", "odin run .", false)
	testing.expect(t, strings.has_prefix(s, "#!/bin/sh\n"))
	testing.expect(t, strings.contains(s, `cd '/home/deck/it'\''s here' || exit 1`))
	testing.expect(t, strings.contains(s, `PATH='/home/deck/odin':"$PATH"; export PATH`))
	testing.expect(t, strings.contains(s, "\nodin run .\n"))
	testing.expect(t, strings.contains(s, `if [ "$status" -ne 0 ]; then`))

	// keep_open always waits; no odin dir means no PATH line.
	k := run_script_text("/p", "", "odin test .", true)
	testing.expect(t, strings.contains(k, "if true; then"))
	testing.expect(t, !strings.contains(k, "PATH="))
}

// Settings > Setup > clang (toolchain.odin): the clang folder goes LAST on a
// Run's PATH, so a real clang still wins.
@(test)
test_run_script_clang_dir :: proc(t: ^testing.T) {
	s := run_script_text("/p", "/home/deck/odin", "odin run .", false, nil, "/home/deck/.local/share/doodle/bin")
	odin_at := strings.index(s, `PATH='/home/deck/odin':"$PATH"`)
	clang_at := strings.index(s, `PATH="$PATH":'/home/deck/.local/share/doodle/bin'; export PATH`)
	testing.expect(t, odin_at >= 0 && clang_at > odin_at, "odin first, our clang after everything")
}

// The install script: download to .part, check its sha256, unpack beside the
// old copy and swap it in, then write bin/clang running `zig cc`.
@(test)
test_toolchain_script :: proc(t: ^testing.T) {
	s := toolchain_script("/home/deck/my stuff/doodle", "https://ziglang.org/z.tar.xz", "abc123")
	want := []string{
		"set -eu\n",
		"cd '/home/deck/my stuff/doodle'\n",
		"curl -fL --retry 2 -o zig.tar.xz.part 'https://ziglang.org/z.tar.xz'\n",
		"echo 'abc123  zig.tar.xz.part' | sha256sum -c -\n",
		"rm -rf zig && mv zig.new zig && rm -f zig.tar.xz.part\n",
		"cat > bin/cc <<'DOODLE_EOF'\n#!/bin/sh\nZ=\"$(dirname \"$0\")/../zig/zig\"\n",
		"exec \"$Z\" cc \"$@\"\n",
		"DOODLE_EOF\ncat > bin/ar <<'DOODLE_EOF'\n#!/bin/sh\nexec \"$(dirname \"$0\")/../zig/zig\" ar \"$@\"\nDOODLE_EOF\n",
		"cp bin/cc bin/clang\n",
		"chmod +x bin/clang bin/cc bin/ar\n",
	}
	at := 0
	for w in want {
		k := strings.index(s[at:], w)
		if !testing.expectf(t, k >= 0, "missing (in order): %q\n%s", w, s) do return
		at += k + len(w)
	}
}

// The install script also builds Odin's stb libraries when they're missing
// (stb_build.odin), with the cc / ar it just wrote - and goes on if that fails.
@(test)
test_toolchain_script_builds_stb :: proc(t: ^testing.T) {
	s := toolchain_script("/h", "u", "x", "/home/deck/odin")
	testing.expect(t, strings.contains(s, "ROOT='/home/deck/odin'\n"), "the Odin folder")
	testing.expect(t, strings.contains(s, `! ls "$ROOT"/vendor/stb/lib/*.a`), "only when they aren't built")
	testing.expect(t, strings.contains(s, `PATH="$PWD/bin:$PATH" sh "$ROOT/vendor/stb/src/build_stb.sh" || echo`), "with our cc / ar, not fatal")
	testing.expect(t, strings.index(s, "./bin/clang --version") < strings.index(s, "build_stb.sh"), "after clang is in place")
	none := toolchain_script("/h", "u", "x")
	testing.expect(t, strings.contains(none, "ROOT=''\n") && strings.contains(none, `command -v odin`), "no Odin folder known: the one on PATH")
}

@(test)
test_stb_build_command :: proc(t: ^testing.T) {
	testing.expect_value(t, stb_build_command("/home/deck/my odin"), `sh '/home/deck/my odin/vendor/stb/src/build_stb.sh'`)
}

// Settings > Setup checks downloads with this (setup.odin).
@(test)
test_sha256_file :: proc(t: ^testing.T) {
	dir, _ := os.temp_directory(context.temp_allocator)
	p := strings.concatenate({dir, "/doodle_sha_test.txt"}, context.temp_allocator)
	_ = os.write_entire_file(p, transmute([]byte)string("abc"))
	defer os.remove(p)
	testing.expect_value(t, sha256_file(p), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	testing.expect_value(t, sha256_file(strings.concatenate({p, ".missing"}, context.temp_allocator)), "")
}

// The rows: Doodle, then Odin, speech last; Build Tools on Windows, clang + stb on Linux.
@(test)
test_setup_items :: proc(t: ^testing.T) {
	items := setup_items()
	testing.expect(t, len(items) >= 3 && items[0] == .Doodle && items[1] == .Odin && items[len(items) - 1] == .Speech)
	has :: proc(items: []Setup_Item, it: Setup_Item) -> bool { for x in items do if x == it do return true; return false }
	testing.expect_value(t, has(items, .Build_Tools), ODIN_OS == .Windows)
	testing.expect_value(t, has(items, .Clang), ODIN_OS == .Linux)
	testing.expect_value(t, has(items, .Stb), ODIN_OS == .Linux)
}

// ---- Updater (updater.odin) ----

@(test)
test_update_version_and_asset :: proc(t: ^testing.T) {
	testing.expect_value(t, install_version("0.3.0 (abc1234, Odin dev-2026-11, whisper.cpp v1.9.5 base.en)"), "0.3.0")
	testing.expect_value(t, install_version("2026.11.21-7b817c1"), "2026.11.21-7b817c1")
	when ODIN_OS == .Windows {
		testing.expect_value(t, install_asset("0.3.0 (x, windows-x64)"), "doodle-windows.zip")
	} else {
		testing.expect_value(t, install_asset("0.3.0 (x, linux-x64 ubuntu-22.04)"), "doodle-linux.tar.gz")
		testing.expect_value(t, install_asset("0.3.0 (x, Odin dev-2026-11)"), "doodle-steamos.tar.gz")
	}
}

@(private = "file")
put :: proc(path, text: string) {
	os.make_directory_all(filepath.dir(path))
	_ = os.write_entire_file(path, transmute([]byte)text)
}

@(private = "file")
get :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : "<missing>"
}

// The unpacked package: its top folder, or the stage itself.
@(test)
test_update_new_root_in :: proc(t: ^testing.T) {
	tmp, _ := os.temp_directory(context.temp_allocator)
	stage := strings.concatenate({tmp, "/doodle_upd_stage"}, context.temp_allocator)
	os.remove_all(stage)
	defer os.remove_all(stage)
	testing.expect_value(t, new_root_in(stage), "")
	put(strings.concatenate({stage, "/doodle/bin/", DOODLE_EXE}, context.temp_allocator), "new")
	testing.expect(t, strings.has_suffix(new_root_in(stage), "doodle"), "the archive's top folder")
}

// Linux's swap: the new version where the old one was, the settings carried over.
@(test)
test_update_swap_in :: proc(t: ^testing.T) {
	tmp, _ := os.temp_directory(context.temp_allocator)
	parent := strings.concatenate({tmp, "/doodle_upd_swap"}, context.temp_allocator)
	os.remove_all(parent)
	defer os.remove_all(parent)
	root := strings.concatenate({parent, "/doodle"}, context.temp_allocator)
	fresh := strings.concatenate({parent, "/.doodle-update/doodle"}, context.temp_allocator)
	put(strings.concatenate({root, "/bin/doodle"}, context.temp_allocator), "old binary")
	put(strings.concatenate({root, "/bin/doodle_keys.tsv"}, context.temp_allocator), "my buttons")
	put(strings.concatenate({root, "/VERSION"}, context.temp_allocator), "0.2.0")
	put(strings.concatenate({fresh, "/bin/doodle"}, context.temp_allocator), "new binary")
	put(strings.concatenate({fresh, "/VERSION"}, context.temp_allocator), "0.3.0")
	testing.expect_value(t, swap_in(root, fresh, parent), "")
	testing.expect_value(t, get(strings.concatenate({root, "/bin/doodle"}, context.temp_allocator)), "new binary")
	testing.expect_value(t, get(strings.concatenate({root, "/VERSION"}, context.temp_allocator)), "0.3.0")
	testing.expect_value(t, get(strings.concatenate({root, "/bin/doodle_keys.tsv"}, context.temp_allocator)), "my buttons")
	testing.expect(t, !os.exists(strings.concatenate({parent, "/.doodle-old"}, context.temp_allocator)), "the old one is gone")
}

// Windows: wait for this Doodle to close, copy over, start the new one.
@(test)
test_update_windows_script :: proc(t: ^testing.T) {
	s := windows_update_script("C:/Users/me/doodle", "C:/Users/me/.doodle-update/doodle", 4242)
	want := []string{
		`tasklist /FI "PID eq 4242" 2>nul | find "4242" >nul && (timeout /t 1 /nobreak >nul & goto wait)`,
		`robocopy "C:\Users\me\.doodle-update\doodle" "C:\Users\me\doodle" /E`,
		`rmdir /s /q "C:\Users\me\.doodle-update"`,
		`start "" "C:\Users\me\doodle\bin\doodle.exe"`,
	}
	at := 0
	for w in want {
		k := strings.index(s[at:], w)
		if !testing.expectf(t, k >= 0, "missing (in order): %q\n%s", w, s) do return
		at += k + len(w)
	}
}

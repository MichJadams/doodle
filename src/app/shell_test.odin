package main

import "core:testing"
import "core:strings"
import "core:os"

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

// The rows: Odin first, speech last; Build Tools on Windows, clang + stb on Linux.
@(test)
test_setup_items :: proc(t: ^testing.T) {
	items := setup_items()
	testing.expect(t, len(items) >= 2 && items[0] == .Odin && items[len(items) - 1] == .Speech)
	has :: proc(items: []Setup_Item, it: Setup_Item) -> bool { for x in items do if x == it do return true; return false }
	testing.expect_value(t, has(items, .Build_Tools), ODIN_OS == .Windows)
	testing.expect_value(t, has(items, .Clang), ODIN_OS == .Linux)
	testing.expect_value(t, has(items, .Stb), ODIN_OS == .Linux)
}

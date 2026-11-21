package main

import "core:testing"
import "core:strings"

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

package model

import "core:strings"
import "core:testing"

@(test)
test_settings_defaults_and_round_trip :: proc(t: ^testing.T) {
	s := settings_default()
	defer settings_free(&s)
	testing.expect(t, s.on[.Auto_Close_Run], "the run terminal closes by default (as before the setting)")

	s.on[.Auto_Close_Run] = false
	text := settings_serialize(&s, context.temp_allocator)
	testing.expect_value(t, text, "doodle-settings 1\nauto_close_run\toff\n")
	back := settings_parse(text)
	defer settings_free(&back)
	testing.expect(t, !back.on[.Auto_Close_Run], "off survives a save + load")
	testing.expect_value(t, len(back.extra), 0)
}

@(test)
test_settings_parse_keeps_unknown_and_defaults :: proc(t: ^testing.T) {
	// A later Doodle's option is kept; a bad value keeps the default; CRLF is fine.
	s := settings_parse("doodle-settings 1\r\nauto_close_run\tmaybe\r\nfuture_option\ton\r\n# a note\r\n")
	defer settings_free(&s)
	testing.expect(t, s.on[.Auto_Close_Run], "an unknown value keeps the default")
	testing.expect_value(t, len(s.extra), 1)
	text := settings_serialize(&s, context.temp_allocator)
	testing.expect(t, strings.contains(text, "future_option\ton\n"), text)

	empty := settings_parse("")
	defer settings_free(&empty)
	testing.expect(t, empty.on[.Auto_Close_Run], "no file: the defaults")
}

@(test)
test_settings_text_ok :: proc(t: ^testing.T) {
	testing.expect(t, settings_text_ok(""), "no file yet")
	testing.expect(t, settings_text_ok("doodle-settings 1\nauto_close_run\ton\n"), "this format")
	testing.expect(t, !settings_text_ok("doodle-settings 2\nauto_close_run\ton\n"), "a newer format is never overwritten")
	testing.expect(t, !settings_text_ok("something else\n"), "not a settings file")
}

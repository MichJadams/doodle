package model

// Settings (main menu -> Settings): on/off options, saved in doodle_settings.txt
// next to doodle.exe (app/settings.odin). This is the pure part: the options,
// their labels and the file format.
//
//   doodle-settings 1
//   auto_close_run	on
//
// Lines this Doodle doesn't know (a later Doodle's options, same format) are
// kept and written back as they were. A different header is a newer format:
// app/settings.odin then never overwrites the file.

import "core:strings"

SETTINGS_HEADER :: "doodle-settings 1"

Setting :: enum {
	Auto_Close_Run, // the Run console closes when the program ends (an error keeps it open)
}

Setting_Info :: struct {
	key:   string, // in the file
	label: string, // on the Settings page
	on:    string, // what "On" does
	off:   string, // what "Off" does
	dflt:  bool,
}

SETTING_INFO := [Setting]Setting_Info{
	.Auto_Close_Run = {
		key   = "auto_close_run",
		label = "Automatically close the run terminal",
		on    = "Closes when the program ends (an error still keeps it open).",
		off   = "Stays open after the program ends, until you press a key.",
		dflt  = true,
	},
}

Settings :: struct {
	on:    [Setting]bool,
	extra: [dynamic]string, // unknown lines, kept as they are (owned)
}

settings_default :: proc() -> Settings {
	s: Settings
	for info, k in SETTING_INFO do s.on[k] = info.dflt
	return s
}

settings_free :: proc(s: ^Settings) {
	for l in s.extra do delete(l)
	delete(s.extra)
	s.extra = nil
}

// settings_text_ok: can a save overwrite a file with this text? Not when it's
// another (newer) format. Empty text (no file yet) is fine.
settings_text_ok :: proc(text: string) -> bool {
	for line in strings.split_lines(text, context.temp_allocator) {
		l := strings.trim_space(line)
		if l == "" do continue
		return l == SETTINGS_HEADER
	}
	return true
}

// settings_parse reads a settings file: the defaults, with every known key's
// on / off applied (anything else for a value keeps the default); unknown
// lines go to extra. Free with settings_free.
settings_parse :: proc(text: string) -> Settings {
	s := settings_default()
	header_seen := false
	for line in strings.split_lines(text, context.temp_allocator) {
		l := strings.trim_right(line, "\r")
		t := strings.trim_space(l)
		if t == "" do continue
		if !header_seen && t == SETTINGS_HEADER { header_seen = true; continue }
		key, value := t, ""
		if tab := strings.index_byte(t, '\t'); tab >= 0 {
			key, value = strings.trim_space(t[:tab]), strings.trim_space(t[tab + 1:])
		}
		known := false
		for info, k in SETTING_INFO do if info.key == key {
			known = true
			switch value {
			case "on":  s.on[k] = true
			case "off": s.on[k] = false
			}
		}
		if !known && !strings.has_prefix(t, "#") do append(&s.extra, strings.clone(l))
	}
	return s
}

// settings_serialize: the file text (header, every known option, then the
// unknown lines as they were).
settings_serialize :: proc(s: ^Settings, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, SETTINGS_HEADER)
	strings.write_byte(&b, '\n')
	for info, k in SETTING_INFO {
		strings.write_string(&b, info.key)
		strings.write_byte(&b, '\t')
		strings.write_string(&b, s.on[k] ? "on" : "off")
		strings.write_byte(&b, '\n')
	}
	for l in s.extra {
		strings.write_string(&b, l)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

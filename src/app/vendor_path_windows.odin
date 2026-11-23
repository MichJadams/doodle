package main

// Windows side of vendor_path.odin: the user PATH (HKCU\Environment\Path) -
// read it, add a folder to it for good, and the folders Windows searches for a
// DLL right now.

import win "core:sys/windows"
import "core:os"
import "core:strings"
import "../model"

// The user PATH as stored (expand = false: %VARS% kept, for writing it back)
// or expanded (for looking in its folders). ok = false: there's none.
@(private = "file")
user_path_read :: proc(expand: bool) -> (value: string, kind: u32, ok: bool) {
	sub := win.utf8_to_wstring("Environment")
	name := win.utf8_to_wstring("Path")
	flags: u32 = expand ? win.RRF_RT_REG_SZ : (win.RRF_RT_REG_SZ | win.RRF_RT_REG_EXPAND_SZ | win.RRF_NOEXPAND)
	size, typ: u32
	if win.RegGetValueW(win.HKEY_CURRENT_USER, sub, name, flags, &typ, nil, &size) != 0 || size < 2 do return
	buf := make([]u16, size / 2 + 1, context.temp_allocator)
	if win.RegGetValueW(win.HKEY_CURRENT_USER, sub, name, flags, &typ, raw_data(buf), &size) != 0 do return
	n := int(size / 2)
	for n > 0 && buf[n - 1] == 0 do n -= 1 // the terminating NUL(s)
	s, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil do return
	return s, typ, true
}

// lib_dir_on_path: is `dir` on the user PATH (Doodle's own environment may be
// older than it) or on Doodle's PATH?
lib_dir_on_path :: proc(dir: string) -> bool {
	if p, _, ok := user_path_read(true); ok && model.path_list_has(p, dir, .Windows) do return true
	return model.path_list_has(os.get_env("PATH", context.temp_allocator), dir, .Windows)
}

// lib_search_dirs: where Windows looks for a DLL (besides the program's own
// folder): Doodle's PATH and the current user PATH. Temp-allocated.
lib_search_dirs :: proc() -> []string {
	out := make([dynamic]string, 0, 32, context.temp_allocator)
	for e in strings.split(os.get_env("PATH", context.temp_allocator), ";", context.temp_allocator) do if strings.trim_space(e) != "" do append(&out, strings.trim_space(e))
	if p, _, ok := user_path_read(true); ok {
		for e in strings.split(p, ";", context.temp_allocator) do if strings.trim_space(e) != "" do append(&out, strings.trim_space(e))
	}
	return out[:]
}

// user_path_add puts `dir` on the user PATH for good, and tells running
// programs (Explorer: what new terminals and double-clicks start from) the
// environment changed. msg: what happened, for the status line.
user_path_add :: proc(dir, import_path: string) -> (ok: bool, msg: string) {
	if trace_replaying() do return true, "replay: PATH left as it is" // TRACE hook: a replay changes nothing outside its sandbox
	raw, kind, had := user_path_read(false)
	if model.path_list_has(raw, dir, .Windows) do return true, strings.concatenate({dir, " is already on your PATH"}, context.temp_allocator)
	value := model.path_list_add(raw, dir, .Windows)
	if !had do kind = win.REG_EXPAND_SZ
	w := win.utf8_to_utf16(value, context.temp_allocator)
	data := make([]u16, len(w) + 1, context.temp_allocator) // + the terminating NUL
	copy(data, w)
	status := win.RegSetKeyValueW(win.HKEY_CURRENT_USER, win.utf8_to_wstring("Environment"), win.utf8_to_wstring("Path"), kind, raw_data(data), u32(len(data) * 2))
	if status != 0 do return false, "couldn't change your PATH"
	SMTO_ABORTIFHUNG :: 0x0002
	result: win.DWORD_PTR
	win.SendMessageTimeoutW(win.HWND_BROADCAST, win.WM_SETTINGCHANGE, 0, transmute(win.LPARAM)win.utf8_to_wstring("Environment"), SMTO_ABORTIFHUNG, 2000, &result)
	return true, strings.concatenate({"added ", dir, " to your PATH (new terminals and programs see it)"}, context.temp_allocator)
}

#+build !windows
package main

// Linux / macOS side of vendor_path.odin: the library path is LD_LIBRARY_PATH
// (macOS: DYLD_LIBRARY_PATH); "for good" is a line in ~/.profile, read by
// login shells - so it applies from the next login.

import "core:os"
import "core:strings"
import "../model"

@(private = "file")
profile_path :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" do return ""
	return strings.concatenate({home, "/.profile"}, context.temp_allocator)
}

@(private = "file")
profile_text :: proc() -> string {
	p := profile_path()
	if p == "" do return ""
	data, err := os.read_entire_file(p, context.temp_allocator)
	if err != nil do return ""
	return string(data)
}

// lib_dir_on_path: is `dir` on the library path now, or in ~/.profile?
lib_dir_on_path :: proc(dir: string) -> bool {
	if model.path_list_has(os.get_env(model.lib_path_var(LIB_OS), context.temp_allocator), dir, LIB_OS) do return true
	return model.profile_has_dir(profile_text(), dir, LIB_OS)
}

// lib_search_dirs: where the dynamic linker looks: the library path variable,
// then the usual system folders. Temp-allocated.
lib_search_dirs :: proc() -> []string {
	out := make([dynamic]string, 0, 16, context.temp_allocator)
	for e in strings.split(os.get_env(model.lib_path_var(LIB_OS), context.temp_allocator), ":", context.temp_allocator) do if e != "" do append(&out, e)
	when ODIN_OS == .Darwin {
		append(&out, "/usr/local/lib", "/opt/homebrew/lib", "/usr/lib")
	} else {
		append(&out, "/lib", "/usr/lib", "/usr/local/lib", "/lib64", "/usr/lib64", "/lib/x86_64-linux-gnu", "/usr/lib/x86_64-linux-gnu", "/lib/aarch64-linux-gnu", "/usr/lib/aarch64-linux-gnu")
	}
	return out[:]
}

// user_path_add appends the line that adds `dir` to the library path to
// ~/.profile (once). msg: what happened, for the status line.
user_path_add :: proc(dir, import_path: string) -> (ok: bool, msg: string) {
	if trace_replaying() do return true, "replay: ~/.profile left as it is" // TRACE hook
	p := profile_path()
	if p == "" do return false, "no home folder to add it to"
	text := profile_text()
	if model.profile_has_dir(text, dir, LIB_OS) do return true, strings.concatenate({dir, " is already in ~/.profile"}, context.temp_allocator)
	sep := text != "" && !strings.has_suffix(text, "\n") ? "\n" : ""
	body := strings.concatenate({text, sep, model.profile_line(dir, import_path, LIB_OS), "\n"}, context.temp_allocator)
	if err := os.write_entire_file(p, transmute([]byte)body); err != nil do return false, "couldn't write ~/.profile"
	return true, strings.concatenate({"added ", dir, " to ~/.profile (applies from your next login)"}, context.temp_allocator)
}

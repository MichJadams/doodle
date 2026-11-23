package model

// Odin vendor libraries a program needs when it runs (app/vendor_path.odin
// uses this): `import "vendor:sdl3"` needs SDL3.dll on Windows, which only
// lives in <odin>/vendor/sdl3. If the system can't find it the program can't
// even start. This file is the pure part: which vendor imports a file has,
// where their folders are, which files are shared libraries, and the PATH /
// ~/.profile text a folder is added with.

import "core:strings"

Lib_OS :: enum { Windows, Linux, Darwin }

// vendor_imports appends the distinct `vendor:...` paths imported in `text`
// (`import "vendor:sdl3"`, `import sdl "vendor:sdl2/image"`). Not owned.
vendor_imports :: proc(text: string, out: ^[dynamic]string) {
	for line in strings.split_lines(text, context.temp_allocator) {
		s := strings.trim_space(line)
		if !strings.has_prefix(s, "import ") do continue
		q := strings.index_byte(s, '"')
		if q < 0 do continue
		e := strings.index_byte(s[q + 1:], '"')
		if e < 0 do continue
		path := s[q + 1:q + 1 + e]
		if !strings.has_prefix(path, "vendor:") || len(path) == len("vendor:") do continue
		dup := false
		for p in out do if p == path { dup = true; break }
		if !dup do append(out, path)
	}
}

// vendor_lib_dir: the folder of a vendor import - "vendor:sdl2/image" ->
// <odin>/vendor/sdl2/image. Temp-allocated.
vendor_lib_dir :: proc(odin_root, import_path: string) -> string {
	rest := strings.trim_prefix(import_path, "vendor:")
	root := strings.trim_right(odin_root, "/\\")
	return strings.concatenate({root, "/vendor/", rest}, context.temp_allocator)
}

// is_shared_lib: is this file name a shared library on `os` (SDL3.dll /
// libSDL3.so / libSDL3.so.0 / libSDL3.dylib)?
is_shared_lib :: proc(name: string, os: Lib_OS) -> bool {
	n := strings.to_lower(name, context.temp_allocator)
	switch os {
	case .Windows: return strings.has_suffix(n, ".dll")
	case .Linux:   return strings.has_suffix(n, ".so") || strings.contains(n, ".so.")
	case .Darwin:  return strings.has_suffix(n, ".dylib")
	}
	return false
}

// The separator of a PATH-like list on `os`.
path_list_sep :: proc(os: Lib_OS) -> string { return os == .Windows ? ";" : ":" }

// path_list_has: is `dir` one of the entries of a PATH-like list? (Windows:
// any case, / or \, a trailing separator ignored.)
path_list_has :: proc(list, dir: string, os: Lib_OS) -> bool {
	norm :: proc(p: string, os: Lib_OS) -> string {
		s := strings.trim_space(p)
		if os == .Windows {
			s, _ = strings.replace_all(s, "/", "\\", context.temp_allocator)
			s = strings.to_lower(s, context.temp_allocator)
			return strings.trim_right(s, "\\")
		}
		return strings.trim_right(s, "/")
	}
	want := norm(dir, os)
	if want == "" do return false
	for e in strings.split(list, path_list_sep(os), context.temp_allocator) do if norm(e, os) == want do return true
	return false
}

// path_list_add: `list` with `dir` appended (unchanged if it's already there).
// Temp-allocated.
path_list_add :: proc(list, dir: string, os: Lib_OS) -> string {
	if path_list_has(list, dir, os) do return list
	sep := path_list_sep(os)
	l := strings.trim_right(list, sep)
	if strings.trim_space(l) == "" do return strings.clone(dir, context.temp_allocator)
	return strings.concatenate({l, sep, dir}, context.temp_allocator)
}

// ---- ~/.profile (Linux / macOS) ----

PROFILE_MARK :: "# added by Doodle"

// The variable the dynamic linker searches: LD_LIBRARY_PATH (Linux),
// DYLD_LIBRARY_PATH (macOS).
lib_path_var :: proc(os: Lib_OS) -> string { return os == .Darwin ? "DYLD_LIBRARY_PATH" : "LD_LIBRARY_PATH" }

// profile_line: the line that adds `dir` to the library path for every login
// shell (prepended, keeping what was there).
profile_line :: proc(dir, import_path: string, os: Lib_OS) -> string {
	v := lib_path_var(os)
	return strings.concatenate({"export ", v, "=\"", dir, "${", v, ":+:$", v, "}\"  ", PROFILE_MARK, " for ", import_path}, context.temp_allocator)
}

// profile_has_dir: does a profile already put `dir` on the library path (an
// uncommented line naming both)?
profile_has_dir :: proc(text, dir: string, os: Lib_OS) -> bool {
	v := lib_path_var(os)
	for line in strings.split_lines(text, context.temp_allocator) {
		s := strings.trim_space(line)
		if strings.has_prefix(s, "#") do continue
		if strings.contains(s, v) && strings.contains(s, dir) do return true
	}
	return false
}

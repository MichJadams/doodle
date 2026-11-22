package model

// Extra project folders ("roots"): besides the default DoodleProjects folder,
// New Project can create a project in any folder the user has added (main menu
// -> New Project -> "+ Add another folder"). The list is saved one folder per
// line in doodle_roots.txt next to doodle.exe (app/roots_store.odin); this file
// is the pure part: the file format, adding / removing, and listing the saved
// projects of every root for Recent Projects.

import "core:slice"
import "core:strings"
import "core:time"

ROOTS_HEADER :: "doodle-roots 1"

// roots_text_ok: false when the text is from a newer Doodle (a different
// "doodle-roots N" header), whose file must not be overwritten.
roots_text_ok :: proc(text: string) -> bool {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" do continue
		return !strings.has_prefix(l, "doodle-roots") || l == ROOTS_HEADER
	}
	return true
}

// roots_parse: the folders in the file, in order. Blank lines, the header and
// '#' comments are skipped; repeats (same folder, any case / slash style) are
// dropped. Free with roots_free.
roots_parse :: proc(text: string, allocator := context.allocator) -> [dynamic]string {
	out := make([dynamic]string, 0, 4, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l == ROOTS_HEADER || strings.has_prefix(l, "#") do continue
		if roots_index(out[:], l) >= 0 do continue
		append(&out, strings.clone(l, allocator))
	}
	return out
}

roots_serialize :: proc(roots: []string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, ROOTS_HEADER)
	strings.write_byte(&b, '\n')
	for r in roots {
		strings.write_string(&b, r)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// roots_same: the same folder? Slash style and a trailing slash never matter;
// case matters except on Windows (on Linux "Odin" and "odin" are two folders).
roots_same :: proc(a, b: string) -> bool {
	when ODIN_OS == .Windows {
		return fgrid_same(a, b)
	} else {
		na, _ := strings.replace_all(a, "\\", "/", context.temp_allocator)
		nb, _ := strings.replace_all(b, "\\", "/", context.temp_allocator)
		return strings.trim_right(na, "/") == strings.trim_right(nb, "/")
	}
}

// roots_index: where `path` is in `roots` (roots_same), else -1.
roots_index :: proc(roots: []string, path: string) -> int {
	for r, i in roots do if roots_same(r, path) do return i
	return -1
}

Roots_Add_Result :: enum {
	Added,
	Empty,      // no folder given
	Is_Default, // that's the default folder, which is always listed
	Duplicate,  // already in the list
}

// roots_add appends a copy of `path` unless it's empty, the default folder or
// already listed. A trailing slash is trimmed (but not a drive root's: "C:/").
roots_add :: proc(roots: ^[dynamic]string, path, default_root: string, allocator := context.allocator) -> Roots_Add_Result {
	p := strings.trim_space(path)
	for len(p) > 1 && (p[len(p) - 1] == '/' || p[len(p) - 1] == '\\') && p[len(p) - 2] != ':' do p = p[:len(p) - 1]
	switch {
	case p == "":                                        return .Empty
	case default_root != "" && roots_same(p, default_root): return .Is_Default
	case roots_index(roots[:], p) >= 0:                  return .Duplicate
	}
	append(roots, strings.clone(p, allocator))
	return .Added
}

// roots_remove deletes entry i (frees it). Out of range: nothing.
roots_remove :: proc(roots: ^[dynamic]string, i: int, allocator := context.allocator) {
	if i < 0 || i >= len(roots) do return
	delete(roots[i], allocator)
	ordered_remove(roots, i)
}

roots_free :: proc(roots: ^[dynamic]string, allocator := context.allocator) {
	for r in roots do delete(r, allocator)
	delete(roots^)
	roots^ = nil
}

// list_projects_in: the saved projects of every root (list_projects each),
// newest first. A root listed twice is scanned once. Free with free_projects.
list_projects_in :: proc(roots: []string, allocator := context.allocator) -> []Project {
	out := make([dynamic]Project, 0, 8, allocator)
	for root, i in roots {
		if root == "" || roots_index(roots[:i], root) >= 0 do continue
		ps := list_projects(root, allocator)
		append(&out, ..ps)
		delete(ps, allocator) // the strings moved into `out`
	}
	slice.stable_sort_by(out[:], proc(a, b: Project) -> bool {
		return time.diff(b.mtime, a.mtime) > 0 // newer first
	})
	return out[:]
}

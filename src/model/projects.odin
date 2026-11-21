package model

// Discover previously saved projects on disk (for the main menu's Recent Projects).
// A project is a sub-folder of the projects root that contains at least one .odin file.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

Project :: struct {
	name:  string,    // folder name, e.g. "slow-wolf-5364"
	dir:   string,    // full path of the project folder
	file:  string,    // file to open: main.odin if present, else the first .odin alphabetically
	mtime: time.Time, // newest modification time among the project's .odin files
}

// list_projects returns the projects under `root`, most recently modified first.
// Folders with no .odin files (e.g. a New Project that was never saved) are skipped.
// Free the result with free_projects.
list_projects :: proc(root: string, allocator := context.allocator) -> []Project {
	out := make([dynamic]Project, 0, 8, allocator)
	fis, err := os.read_directory_by_path(root, -1, context.temp_allocator)
	if err != nil do return out[:]

	for fi in fis {
		if fi.type != .Directory do continue
		files, ferr := os.read_directory_by_path(fi.fullpath, -1, context.temp_allocator)
		if ferr != nil do continue

		main_file, first_file := "", ""
		newest: time.Time
		for f in files {
			if f.type == .Directory || !strings.has_suffix(f.name, ".odin") do continue
			if first_file == "" || time.diff(newest, f.modification_time) > 0 do newest = f.modification_time
			if first_file == "" || f.fullpath < first_file do first_file = f.fullpath
			if f.name == "main.odin" do main_file = f.fullpath
		}
		if first_file == "" do continue // no .odin files: not a saved project
		pick := main_file != "" ? main_file : first_file
		append(&out, Project{
			name  = strings.clone(fi.name, allocator),
			dir   = strings.clone(fi.fullpath, allocator),
			file  = strings.clone(pick, allocator),
			mtime = newest,
		})
	}

	slice.sort_by(out[:], proc(a, b: Project) -> bool {
		return time.diff(b.mtime, a.mtime) > 0 // newer first
	})
	return out[:]
}

free_projects :: proc(ps: []Project, allocator := context.allocator) {
	for p in ps {
		delete(p.name, allocator)
		delete(p.dir, allocator)
		delete(p.file, allocator)
	}
	delete(ps, allocator)
}

// age_label renders how long ago `t` was, e.g. "just now", "5m ago", "3h ago", "2d ago".
age_label :: proc(t: time.Time, now: time.Time, allocator := context.temp_allocator) -> string {
	secs := int(time.duration_seconds(time.diff(t, now)))
	switch {
	case secs < 60:    return strings.clone("just now", allocator)
	case secs < 3600:  return fmt.aprintf("%dm ago", secs / 60, allocator = allocator)
	case secs < 86400: return fmt.aprintf("%dh ago", secs / 3600, allocator = allocator)
	}
	return fmt.aprintf("%dd ago", secs / 86400, allocator = allocator)
}

// clean_filename turns typed/dictated text into a safe .odin file name:
// spaces -> '_', only [A-Za-z0-9_-.] kept (no path separators), ".odin" appended
// if missing. Returns "" when nothing usable is left. Caller owns the result.
clean_filename :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for c in transmute([]u8)strings.trim_space(s) {
		switch c {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-', '.':
			strings.write_byte(&b, c)
		case ' ', '\t':
			strings.write_byte(&b, '_')
		}
	}
	name := strings.trim(strings.to_string(b), "._")
	if name == "" || name == "odin" {
		strings.builder_destroy(&b)
		return ""
	}
	out := strings.has_suffix(name, ".odin") ? strings.clone(name, allocator) : strings.concatenate({name, ".odin"}, allocator)
	strings.builder_destroy(&b)
	return out
}

// clean_rename: the new name for a file or folder being renamed (file
// navigation, LT+X), "" when nothing usable is left. Same characters as
// clean_filename, but the extension follows the old name: a folder gets none,
// a file keeps its own (`notes.md` -> `todo.md`, `main.odin` -> `game.odin`)
// unless the new name has one.
clean_rename :: proc(s, old_name: string, is_dir: bool, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)strings.trim_space(s) {
		switch c {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-', '.':
			strings.write_byte(&b, c)
		case ' ', '\t':
			strings.write_byte(&b, '_')
		}
	}
	name := strings.trim(strings.to_string(b), "._")
	if name == "" do return ""
	if is_dir do return strings.clone(name, allocator)
	ext := ""
	if dot := strings.last_index_byte(old_name, '.'); dot > 0 do ext = old_name[dot:]
	if ext == "" || strings.contains(name, ".") do return strings.clone(name, allocator)
	if strings.equal_fold(name, ext[1:]) do return "" // just "odin"
	return strings.concatenate({name, ext}, allocator)
}

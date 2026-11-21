package model

// The Import menu's collections: Import -> core / base / vendor / shared.
//  - core, base, vendor: the generated rows in core_tree.odin (CORE_ROWS,
//    BASE_ROWS, VENDOR_ROWS; tools/gen_core_tree.py). base:builtin is not
//    importable and isn't listed.
//  - shared: the Odin install's shared/ folder is user-specific (empty by
//    default), so it is listed when the menu is built: every sub-folder holding
//    .odin files is an `import "shared:<name>"` entry.
// Folders whose name isn't an identifier (vendor:lua/5.4) must be imported
// with a name; IMPORT_NAMES gives the one Doodle inserts (`import lua "vendor:lua/5.4"`).

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// The entries under Import (and Aliased import). Caller owns them (free_entries).
build_import_collections :: proc() -> []Entry {
	return make_slice(
		grp("core", build_core_tree()),
		grp("base", build_rows_tree(BASE_ROWS[:])),
		grp("vendor", build_rows_tree(VENDOR_ROWS[:])),
		grp("shared", build_shared_tree(odin_root())),
	)
}

// odin_root: the Odin install folder - $ODIN_ROOT, else the folder holding
// odin.exe on PATH, else C:/Odin. Temp-allocated.
odin_root :: proc() -> string {
	if v, ok := os.lookup_env("ODIN_ROOT", context.temp_allocator); ok && strings.trim_space(v) != "" {
		return strings.trim_right(strings.trim_space(v), "/\\")
	}
	exe := "odin.exe" when ODIN_OS == .Windows else "odin"
	path := os.get_env("PATH", context.temp_allocator)
	if dirs, err := os.split_path_list(path, context.temp_allocator); err == nil {
		for dir in dirs {
			if dir == "" do continue
			full, _ := filepath.join({dir, exe}, context.temp_allocator)
			if os.is_file(full) do return strings.trim_right(dir, "/\\")
		}
	}
	return "C:/Odin"
}

// build_shared_tree: one entry per package under <odin_root>/shared (nested
// folders as "a/b"), or a single dimmed, non-actionable placeholder when none.
build_shared_tree :: proc(root: string) -> []Entry {
	shared_dir, _ := filepath.join({root, "shared"}, context.temp_allocator)
	names := make([dynamic]string, 0, 8, context.temp_allocator)
	list_shared_packages(shared_dir, "", &names, 0)
	if len(names) == 0 {
		label := strings.concatenate({"(empty: add packages to ", root, "/shared)"})
		return make_slice(Entry{label = label, owned_label = true, dim = true})
	}
	slice.sort(names[:])
	out := make([]Entry, len(names))
	for name, i in names do out[i] = shared_entry(name)
	return out
}

// shared_entry: an import leaf for "shared:<rel>". One allocation holds both
// strings - label = rel, import_path = "shared:<rel>" right after it - so
// free_entries releases it through the owned label (same start pointer).
@(private = "file")
shared_entry :: proc(rel: string) -> Entry {
	buf := strings.concatenate({rel, "shared:", rel})
	return Entry{label = buf[:len(rel)], import_path = buf[len(rel):], owned_label = true}
}

@(private = "file")
list_shared_packages :: proc(dir, rel: string, names: ^[dynamic]string, depth: int) {
	if depth > 4 do return
	files, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return
	has_odin := false
	for fi in files {
		if fi.type != .Directory && strings.has_suffix(fi.name, ".odin") && !strings.has_suffix(fi.name, "_test.odin") {
			has_odin = true
		}
	}
	if has_odin && rel != "" do append(names, rel)
	for fi in files {
		if fi.type != .Directory do continue
		if strings.has_prefix(fi.name, ".") || fi.name == "tests" || fi.name == "examples" do continue
		sub := fi.name if rel == "" else strings.concatenate({rel, "/", fi.name}, context.temp_allocator)
		list_shared_packages(fi.fullpath, sub, names, depth + 1)
	}
}

// import_name_for: the name a package must be imported as when its folder
// name isn't an identifier (vendor:lua/5.4 -> "lua").
import_name_for :: proc(path: string) -> (name: string, ok: bool) {
	for n in IMPORT_NAMES do if n.path == path do return n.name, true
	return "", false
}

// needs_import_alias: a plain `import "<path>"` would not compile (the folder
// name isn't an identifier), so it is always inserted with a name.
needs_import_alias :: proc(path: string) -> bool {
	return !is_ident(path[strings.last_index_any(path, ":/") + 1:])
}

package main

// Project directory management and saving to disk.

import "../model"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:math/rand"
import "core:path/filepath"

// --- Project directory globals (exposed for use by other features) ---

// The default folder for Doodle projects.
// USERPROFILE/DoodleProjects on Windows, or ./DoodleProjects as fallback.
// New Project can also use folders the user added (g_roots, roots_store.odin).
g_projects_dir: string

// Current project's directory (full path), or "" if unsaved/unnamed.
g_project_dir: string

// Current project's name (just the folder name), or "" if unnamed.
g_project_name: string

// --- Initialization ---

// ensure_projects_dir creates the global projects directory if it doesn't exist.
// Call this once at startup or before the first save.
ensure_projects_dir :: proc() {
	if g_projects_dir != "" do return // already initialized
	
	// Get user home directory from USERPROFILE env var (Windows).
	home := os.get_env("USERPROFILE", context.temp_allocator)
	// NOTE: these globals must outlive the frame, so they are heap-allocated
	// (a tprintf here is freed by free_all(temp_allocator) at the end of the frame).
	if home == "" {
		// Fallback to current directory if USERPROFILE is not set.
		g_projects_dir = strings.clone("./DoodleProjects")
	} else {
		g_projects_dir = fmt.aprintf("%s/DoodleProjects", home)
	}
	
	// Create the directory if it doesn't exist (ignore errors if it already exists).
	os.make_directory(g_projects_dir)

	// The fallback is relative; make it absolute (after creating it: on Linux
	// get_absolute_path opens the path), so comparing it with the absolute paths
	// folder listings give (New Project's folders, Recent Projects) works.
	if home == "" {
		if abs, err := os.get_absolute_path(g_projects_dir, context.allocator); err == nil {
			delete(g_projects_dir)
			g_projects_dir = abs
		}
	}
}

// --- Random project name generation ---

// Simple word lists for generating random project names.
adjectives := [?]string{
	"swift", "brave", "calm", "wild", "bright", "deep", "cool", "warm",
	"quiet", "loud", "soft", "hard", "clean", "rough", "smooth", "dark",
	"light", "heavy", "tiny", "huge", "fast", "slow", "sharp", "dull",
}

animals := [?]string{
	"fox", "wolf", "bear", "deer", "hawk", "eagle", "lion", "tiger",
	"otter", "badger", "raven", "owl", "lynx", "moose", "elk", "seal",
	"whale", "shark", "dolphin", "penguin", "panda", "koala", "lemur",
}

// gen_project_name generates a random project name like "swift-fox-1234".
// Returns a filesystem-safe string (lowercase, hyphens, digits).
gen_project_name :: proc() -> string {
	adj := adjectives[rand.int_max(len(adjectives))]
	ani := animals[rand.int_max(len(animals))]
	num := rand.int_max(10000)
	return fmt.tprintf("%s-%s-%04d", adj, ani, num)
}

// --- Project setup ---

// new_project_setup generates a random name, creates the project folder in
// `root` ("" = the default projects folder), and updates the global project
// state. Called when starting a new project.
new_project_setup :: proc(root := "") {
	ensure_projects_dir()
	parent := root != "" ? root : g_projects_dir

	// Generate a random name and create the project directory.
	set_project_dir(fmt.tprintf("%s/%s", parent, trace_str("project_name", gen_project_name()))) // TRACE hook (was: gen_project_name())

	// A brand-new project has no file yet; the first save creates main.odin.
	set_current_file("")

	// Create the project directory (ignore errors if it already exists).
	if trace_write_ok(g_project_dir) do os.make_directory(g_project_dir) // TRACE hook: a replay writes only inside its sandbox (was: os.make_directory(g_project_dir))
}

// set_project_dir points the project (save target + run cwd) at `dir`.
// Takes its own copy; the run-command list is reloaded for the new project.
set_project_dir :: proc(dir: string) {
	if dir == g_project_dir do return
	if g_project_dir != "" do delete(g_project_dir)
	if g_project_name != "" do delete(g_project_name)
	g_project_dir = strings.clone(dir)
	g_project_name = strings.clone(filepath.base(dir))
	g_run_loaded = false // run.txt is per project
	// The siblings follow the project folder only for an unsaved document (else
	// the open file's folder: set_current_file refreshes them).
	if g_current_file == "" do refresh_siblings()
}

// set_current_file records the file the editor is showing ("" = none yet).
set_current_file :: proc(path: string) {
	defer refresh_siblings() // even for the same path (a save): its neighbours may have changed (only changed files are re-read)
	if path == g_current_file do return
	if g_current_file != "" do delete(g_current_file)
	g_current_file = path == "" ? "" : strings.clone(path)
}

// refresh_siblings re-reads the procedures and types in the package's other files (the
// .odin files next to the open one; next to main.odin in the project folder for
// an unsaved document), so they can be used without an import. Cheap when
// nothing changed: model.load_siblings re-parses only files whose size or
// modification time differ from the last refresh.
refresh_siblings :: proc() {
	if g_app == nil do return
	if g_current_file != "" {
		model.load_siblings(g_app, filepath.dir(g_current_file), filepath.base(g_current_file))
	} else {
		model.load_siblings(g_app, g_project_dir, "main.odin")
	}
	g_app.capture_fp = 0 // capture dots depend on what the calls return
}

// editor_title is the header text: the open file, else the project, else untitled.
editor_title :: proc() -> string {
	if g_current_file != "" do return g_current_file
	if g_project_dir != "" do return fmt.tprintf("%s/main.odin  (unsaved)", g_project_dir)
	return "untitled.odin"
}

// --- Saving ---

// save_folder is where a save goes: the open file's folder, else the project
// folder (creating a fresh project if there is none yet).
save_folder :: proc() -> string {
	if g_current_file != "" do return filepath.dir(g_current_file)
	if g_project_dir == "" do new_project_setup()
	os.make_directory(g_project_dir)
	return g_project_dir
}

// write_doc writes the document's source to `path` and makes it the current file.
// Returns "" on success, else a short error message (temp-allocated).
write_doc :: proc(m: ^model.App, path: string) -> string {
	// Formatted (formatter.odin), no editor-only "●" lines, final newline.
	source := model.file_text(m, context.temp_allocator)
	if !trace_write_ok(path) { set_current_file(path); return "" } // TRACE hook: a replay writes only inside its sandbox
	if err := os.write_entire_file(path, transmute([]byte)source); err != nil {
		fmt.eprintf("Failed to save to %s: %v\n", path, err)
		return fmt.tprintf("could not save: %v", err)
	}
	set_current_file(path)
	return ""
}

// save_current saves without asking (used before running): back to the open
// file, or <project>/main.odin if nothing has been saved yet. RT+Y uses the
// Save-as dialog instead (save_dialog.odin). Returns true on success.
// save_now (the Save action, RT+Y by default): save without asking - the open
// file, or main.odin in the project folder for a new project. Renaming is done
// in Files (LT+X).
save_now :: proc(m: ^model.App) {
	first := g_current_file == ""
	if !save_current(m) do return
	name := filepath.base(g_current_file)
	if first do set_status(fmt.tprintf("saved %s in %s - rename it in Files (LT+X)", name, filepath.base(filepath.dir(g_current_file))))
	else do set_status(fmt.tprintf("saved %s", name))
}

save_current :: proc(m: ^model.App) -> bool {
	target := g_current_file
	if target == "" do target = fmt.tprintf("%s/main.odin", save_folder())
	if msg := write_doc(m, target); msg != "" {
		set_status(fmt.tprintf("SAVE FAILED: %s", msg))
		return false
	}
	return true
}

package main

// Project directory management and saving to disk.

import "../model"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:math/rand"
import "core:path/filepath"

// --- Project directory globals (exposed for use by other features) ---

// Root directory for all Doodle projects.
// Default: USERPROFILE/DoodleProjects on Windows, or ./DoodleProjects as fallback.
// TODO: Make this configurable via main-menu settings.
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

// new_project_setup generates a random name, creates the project folder,
// and updates the global project state. Called when starting a new project.
new_project_setup :: proc() {
	ensure_projects_dir()
	
	// Generate a random name and create the project directory.
	set_project_dir(fmt.tprintf("%s/%s", g_projects_dir, gen_project_name()))

	// A brand-new project has no file yet; the first save creates main.odin.
	set_current_file("")

	// Create the project directory (ignore errors if it already exists).
	os.make_directory(g_project_dir)
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
}

// set_current_file records the file the editor is showing ("" = none yet).
set_current_file :: proc(path: string) {
	if path == g_current_file do return
	if g_current_file != "" do delete(g_current_file)
	g_current_file = path == "" ? "" : strings.clone(path)
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
	source := model.doc_to_source(m, context.temp_allocator)
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
save_current :: proc(m: ^model.App) -> bool {
	target := g_current_file
	if target == "" do target = fmt.tprintf("%s/main.odin", save_folder())
	if msg := write_doc(m, target); msg != "" {
		set_status(fmt.tprintf("SAVE FAILED: %s", msg))
		return false
	}
	return true
}

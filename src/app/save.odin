package main

// Project directory management and saving to disk.

import "../model"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:math/rand"

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
	if home == "" {
		// Fallback to current directory if USERPROFILE is not set.
		g_projects_dir = "./DoodleProjects"
	} else {
		g_projects_dir = fmt.tprintf("%s/DoodleProjects", home)
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
	g_project_name = gen_project_name()
	g_project_dir = fmt.tprintf("%s/%s", g_projects_dir, g_project_name)
	
	// Create the project directory (ignore errors if it already exists).
	os.make_directory(g_project_dir)
}

// --- Saving ---

// save_current writes the current document to disk as main.odin.
// If the project has no name yet, it generates one first.
save_current :: proc(m: ^model.App) {
	// If no project directory yet, set it up.
	if g_project_dir == "" {
		new_project_setup()
	}
	
	// Generate the full source text from the document.
	source := model.doc_to_source(m, context.temp_allocator)
	
	// Write to main.odin in the project directory.
	filepath := fmt.tprintf("%s/main.odin", g_project_dir)
	err := os.write_entire_file(filepath, transmute([]byte)source)
	
	if err == nil {
		// Optional: Set a saved confirmation message/timestamp for display.
		// For now, just print to console (silent success).
		fmt.printf("Saved to %s\n", filepath)
	} else {
		fmt.eprintf("Failed to save to %s: %v\n", filepath, err)
	}
}

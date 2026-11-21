package main

// Background compile check: shortly after the document stops changing, run
// `odin check` on it (in a scratch copy of the project folder, so the other
// files of the package count) on a worker thread, and keep the problems it
// reports. The editor shades those lines red and shows the message for the
// line under the cursor (editor_view.odin).

import "../model"
import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"

Check_Job :: struct {
	src:       string, // the document's source as it would be saved
	file_name: string, // e.g. "main.odin"
	project:   string, // folder whose other .odin files are part of the package ("" = none)
	odin_exe:  string,
	output:    string, // what odin check printed (filled by the worker)
}

CHECK_DEBOUNCE :: 0.6 // seconds without edits before checking
CHECK_POLL     :: 0.3 // how often to look for edits

g_check_thread:     ^thread.Thread
g_check_job:        ^Check_Job
g_diags:            []model.Diag // problems for g_diags_src
g_diags_src:        string       // the source those problems are for
g_check_last_src:   string       // the latest source seen (to notice edits)
g_check_changed_at: f64
g_check_polled_at:  f64

// The current problems, if they're for the document as it is now.
current_diags :: proc(m: ^model.App) -> []model.Diag {
	if len(g_diags) == 0 || g_diags_src != g_check_last_src do return nil
	return g_diags
}

// check_tick: call once a frame while editing.
check_tick :: proc(m: ^model.App) {
	// A finished check: take its results.
	if g_check_thread != nil && thread.is_done(g_check_thread) {
		thread.destroy(g_check_thread)
		g_check_thread = nil
		job := g_check_job
		g_check_job = nil
		if g_diags != nil do model.free_diags(g_diags)
		g_diags = model.parse_check_output(job.output, job.file_name)
		if g_diags_src != "" do delete(g_diags_src)
		g_diags_src = job.src // moves
		delete(job.output)
		delete(job.file_name)
		delete(job.project)
		delete(job.odin_exe)
		free(job)
	}

	if g_time - g_check_polled_at < CHECK_POLL do return
	g_check_polled_at = g_time
	src := model.doc_to_source(m, context.temp_allocator)
	if src != g_check_last_src {
		if g_check_last_src != "" do delete(g_check_last_src)
		g_check_last_src = strings.clone(src)
		g_check_changed_at = g_time
		return
	}
	if g_check_thread != nil || src == g_diags_src || len(m.doc.nodes) == 0 do return
	if g_time - g_check_changed_at < CHECK_DEBOUNCE do return

	// Start a check of this source.
	job := new(Check_Job)
	job.src = strings.clone(src)
	job.file_name = strings.clone(g_current_file != "" ? filepath.base(g_current_file) : "main.odin")
	folder := g_current_file != "" ? filepath.dir(g_current_file) : g_project_dir
	job.project = strings.clone(folder)
	od := odin_dir()
	job.odin_exe = od != "" ? fmt.aprintf("%s\\odin.exe", od) : strings.clone("odin")
	g_check_job = job
	g_check_thread = thread.create_and_start_with_poly_data(job, run_check)
}

// check_shutdown waits for a running check and frees everything (app exit).
check_shutdown :: proc() {
	if g_check_thread != nil {
		thread.join(g_check_thread)
		thread.destroy(g_check_thread)
		g_check_thread = nil
	}
	if g_check_job != nil {
		delete(g_check_job.src); delete(g_check_job.output); delete(g_check_job.file_name)
		delete(g_check_job.project); delete(g_check_job.odin_exe)
		free(g_check_job)
	}
	if g_diags != nil do model.free_diags(g_diags)
	if g_diags_src != "" do delete(g_diags_src)
	if g_check_last_src != "" do delete(g_check_last_src)
}

// run_check (worker thread): scratch folder = the project's other .odin files +
// this document; `odin check` it; keep what it printed.
run_check :: proc(job: ^Check_Job) {
	tmp, terr := os.temp_directory(context.temp_allocator)
	if terr != nil do return
	dir := fmt.tprintf("%s/doodle_check", tmp)
	os.make_directory_all(dir)
	// Clear the previous check's files.
	if old, err := os.read_directory_by_path(dir, -1, context.temp_allocator); err == nil {
		for fi in old do if strings.has_suffix(fi.name, ".odin") || strings.has_suffix(fi.name, ".txt") do os.remove(fi.fullpath)
	}
	// The package's other files.
	if job.project != "" {
		if files, err := os.read_directory_by_path(job.project, -1, context.temp_allocator); err == nil {
			for fi in files {
				if !strings.has_suffix(fi.name, ".odin") || strings.equal_fold(fi.name, job.file_name) do continue
				if data, rerr := os.read_entire_file(fi.fullpath, context.temp_allocator); rerr == nil {
					_ = os.write_entire_file(fmt.tprintf("%s/%s", dir, fi.name), data)
				}
			}
		}
	}
	_ = os.write_entire_file(fmt.tprintf("%s/%s", dir, job.file_name), transmute([]byte)job.src)

	out_path := fmt.tprintf("%s/_check_output.txt", dir)
	win_dir, _ := strings.replace_all(dir, "/", "\\", context.temp_allocator)
	win_out, _ := strings.replace_all(out_path, "/", "\\", context.temp_allocator)
	// cmd /c strips the outer quotes: ""odin.exe" check "dir" ... > "out" 2>&1"
	cmd := fmt.tprintf("\"\"%s\" check \"%s\" -no-entry-point > \"%s\" 2>&1\"", job.odin_exe, win_dir, win_out)
	libc.system(strings.clone_to_cstring(cmd, context.temp_allocator))
	if data, err := os.read_entire_file(out_path, context.allocator); err == nil {
		job.output = string(data)
	}
	free_all(context.temp_allocator)
}

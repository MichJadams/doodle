package model

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
write_with_mtime :: proc(path: string, mtime: time.Time) {
	_ = os.write_entire_file(path, transmute([]byte)string("package main\n"))
	_ = os.change_times(path, mtime, mtime)
}

@(test)
test_list_projects_newest_first_and_skips_unsaved :: proc(t: ^testing.T) {
	tmp, terr := os.temp_directory(context.temp_allocator)
	testing.expect(t, terr == nil)
	root := fmt.tprintf("%s/doodle_projects_test_%d", tmp, time.to_unix_nanoseconds(time.now()))
	testing.expect(t, os.make_directory_all(root) == nil)
	defer os.remove_all(root)

	now := time.now()
	hour := time.Hour

	// older project with main.odin + a helper file
	os.make_directory(fmt.tprintf("%s/old-fox", root))
	write_with_mtime(fmt.tprintf("%s/old-fox/main.odin", root), time.time_add(now, -48 * hour))
	write_with_mtime(fmt.tprintf("%s/old-fox/aaa.odin", root), time.time_add(now, -50 * hour))
	// newer project without main.odin: opens the first .odin alphabetically
	os.make_directory(fmt.tprintf("%s/new-owl", root))
	write_with_mtime(fmt.tprintf("%s/new-owl/zeta.odin", root), time.time_add(now, -1 * hour))
	write_with_mtime(fmt.tprintf("%s/new-owl/beta.odin", root), time.time_add(now, -3 * hour))
	// never-saved project (no .odin) and a stray file at the root: both ignored
	os.make_directory(fmt.tprintf("%s/empty-elk", root))
	write_with_mtime(fmt.tprintf("%s/stray.odin", root), now)

	ps := list_projects(root)
	defer free_projects(ps)

	testing.expect_value(t, len(ps), 2)
	if len(ps) != 2 do return
	testing.expect_value(t, ps[0].name, "new-owl")
	testing.expect(t, strings.has_suffix(ps[0].file, "beta.odin"), "no main.odin -> first .odin alphabetically")
	testing.expect_value(t, ps[1].name, "old-fox")
	testing.expect(t, strings.has_suffix(ps[1].file, "main.odin"), "main.odin preferred")
	testing.expect_value(t, age_label(ps[0].mtime, now), "1h ago") // newest file's time counts
	testing.expect_value(t, age_label(ps[1].mtime, now), "2d ago")
}

@(test)
test_list_projects_missing_root :: proc(t: ^testing.T) {
	ps := list_projects("Z:/definitely/not/a/real/doodle/root")
	defer free_projects(ps)
	testing.expect_value(t, len(ps), 0)
}

@(test)
test_age_label :: proc(t: ^testing.T) {
	now := time.now()
	testing.expect_value(t, age_label(now, now), "just now")
	testing.expect_value(t, age_label(time.time_add(now, -5 * time.Minute), now), "5m ago")
	testing.expect_value(t, age_label(time.time_add(now, -3 * time.Hour), now), "3h ago")
}

@(test)
test_clean_filename :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, input, want: string) {
		got := clean_filename(input)
		defer delete(got)
		testing.expectf(t, got == want, "clean_filename(%q) = %q, want %q", input, got, want)
	}
	check(t, "main.odin", "main.odin")
	check(t, "game_loop", "game_loop.odin")
	check(t, "game loop", "game_loop.odin")
	check(t, "  Hero-2 ", "Hero-2.odin")
	check(t, "../../evil/path", "evilpath.odin") // no separators, no leading dots
	check(t, "", "")
	check(t, ".odin", "")
	check(t, "***", "")
}

@(test)
test_clean_rename :: proc(t: ^testing.T) {
	Case :: struct { input, old: string, dir: bool, want: string }
	cases := []Case{
		{"game loop", "new_file.odin", false, "game_loop.odin"},
		{"game_loop.odin", "new_file.odin", false, "game_loop.odin"},
		{"todo", "notes.md", false, "todo.md"},
		{"todo.txt", "notes.md", false, "todo.txt"},
		{"build", "run", false, "build"},
		{"assets", "stuff", true, "assets"},
		{"my sprites.v2", "img", true, "my_sprites.v2"},
		{"odin", "main.odin", false, ""},
		{"  ", "main.odin", false, ""},
		{"..", "main.odin", false, ""},
	}
	for c in cases {
		got := clean_rename(c.input, c.old, c.dir, context.temp_allocator)
		testing.expectf(t, got == c.want, "clean_rename(%q, %q, %v) = %q, want %q", c.input, c.old, c.dir, got, c.want)
	}
}

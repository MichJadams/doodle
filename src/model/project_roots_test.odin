package model

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

@(test)
test_roots_parse_skips_header_comments_blanks_and_repeats :: proc(t: ^testing.T) {
	roots := roots_parse("doodle-roots 1\n\n# a comment\nC:/work/odin\r\n  D:\\games  \nc:\\WORK\\odin\\\n")
	defer roots_free(&roots)
	testing.expect_value(t, len(roots), 2)
	if len(roots) != 2 do return
	testing.expect_value(t, roots[0], "C:/work/odin")
	testing.expect_value(t, roots[1], "D:\\games")
}

@(test)
test_roots_serialize_round_trips :: proc(t: ^testing.T) {
	src := [?]string{"C:/a", "/home/deck/odin"}
	text := roots_serialize(src[:])
	defer delete(text)
	testing.expect_value(t, text, "doodle-roots 1\nC:/a\n/home/deck/odin\n")
	back := roots_parse(text)
	defer roots_free(&back)
	testing.expect_value(t, len(back), 2)
	if len(back) == 2 {
		testing.expect_value(t, back[0], "C:/a")
		testing.expect_value(t, back[1], "/home/deck/odin")
	}
}

@(test)
test_roots_text_ok :: proc(t: ^testing.T) {
	testing.expect(t, roots_text_ok(""))
	testing.expect(t, roots_text_ok("doodle-roots 1\nC:/a\n"))
	testing.expect(t, roots_text_ok("C:/a\n"), "no header (hand-written) is fine")
	testing.expect(t, !roots_text_ok("\ndoodle-roots 2\nC:/a\n"), "a newer format is left alone")
}

@(test)
test_roots_add :: proc(t: ^testing.T) {
	roots: [dynamic]string
	defer roots_free(&roots)
	def := "C:\\Users\\me/DoodleProjects"
	testing.expect_value(t, roots_add(&roots, "C:/work/", def), Roots_Add_Result.Added)
	testing.expect_value(t, roots[0], "C:/work")
	testing.expect_value(t, roots_add(&roots, "c:\\WORK", def), Roots_Add_Result.Duplicate)
	testing.expect_value(t, roots_add(&roots, "C:/users/me/doodleprojects/", def), Roots_Add_Result.Is_Default)
	testing.expect_value(t, roots_add(&roots, "   ", def), Roots_Add_Result.Empty)
	testing.expect_value(t, roots_add(&roots, "D:/", def), Roots_Add_Result.Added)
	testing.expect_value(t, roots[1], "D:/") // a drive root keeps its slash
	testing.expect_value(t, len(roots), 2)

	roots_remove(&roots, 0)
	testing.expect_value(t, len(roots), 1)
	testing.expect_value(t, roots[0], "D:/")
	roots_remove(&roots, 5) // out of range: nothing
	testing.expect_value(t, len(roots), 1)
}

@(private = "file")
write_odin_at :: proc(path: string, mtime: time.Time) {
	_ = os.write_entire_file(path, transmute([]byte)string("package main\n"))
	_ = os.change_times(path, mtime, mtime)
}

@(test)
test_list_projects_in_merges_roots_newest_first :: proc(t: ^testing.T) {
	tmp, terr := os.temp_directory(context.temp_allocator)
	testing.expect(t, terr == nil)
	base := fmt.tprintf("%s/doodle_roots_test_%d", tmp, time.to_unix_nanoseconds(time.now()))
	a := fmt.tprintf("%s/a", base)
	b := fmt.tprintf("%s/b", base)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/old-fox", a)) == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/new-owl", b)) == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/mid-elk", a)) == nil)
	defer os.remove_all(base)

	now := time.now()
	write_odin_at(fmt.tprintf("%s/old-fox/main.odin", a), time.time_add(now, -48 * time.Hour))
	write_odin_at(fmt.tprintf("%s/mid-elk/main.odin", a), time.time_add(now, -5 * time.Hour))
	write_odin_at(fmt.tprintf("%s/new-owl/main.odin", b), time.time_add(now, -1 * time.Hour))

	// b listed twice (another spelling): scanned once. A missing root: skipped.
	roots := [?]string{a, b, "Z:/definitely/not/a/real/doodle/root", fmt.tprintf("%s/", b)}
	ps := list_projects_in(roots[:])
	defer free_projects(ps)
	testing.expect_value(t, len(ps), 3)
	if len(ps) != 3 do return
	testing.expect_value(t, ps[0].name, "new-owl")
	testing.expect_value(t, ps[1].name, "mid-elk")
	testing.expect_value(t, ps[2].name, "old-fox")
}

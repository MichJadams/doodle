package model

import "core:fmt"
import "core:strings"
import "core:testing"

// A fixed, read-only folder tree, so the tests never touch the disk and can run
// in parallel. A trailing "/" marks an empty folder.
@(private = "file")
FAKE_TREE := [?]string {
	"/r/directory a/f1.odin",
	"/r/directory a/f2.odin",
	"/r/directory b/f1.odin",
	"/r/directory b/f2.odin",
	"/r/directory b/f3.odin",
	"/r/directory b/f4.odin",
	"/r/directory c/f1.odin",
	"/r/directory c/f2.odin",
	"/r/directory c/f3.odin",
	"/r/directory c/subdirectory c/x1.odin",
	"/r/directory c/subdirectory c/x2.odin",
	"/r/directory c/subdirectory c/x3.odin",
	"/r/directory c/subdirectory d/y1.odin",
	"/r/directory d/f1.odin",
	"/r/empty/",
	"/r2/main.odin",
	"/r2/A.odin",
	"/r2/a.odin",
	"/r3/a/f1.odin",
	"/r3/a/f2.odin",
	"/r3/a/f3.odin",
	"/r3/b/",
	"/r3/c/g1.odin",
	"/r3/c/g2.odin",
	"/r3/c/g3.odin",
}

// The direct children of `dir` in FAKE_TREE (deduplicated; a folder if more path
// follows). Unknown folders can't be read.
@(private = "file")
fake_list :: proc(dir: string) -> ([]Fgrid_Entry, bool) {
	out := make([dynamic]Fgrid_Entry, context.temp_allocator)
	prefix := strings.concatenate({dir, "/"}, context.temp_allocator)
	known := false
	for p in FAKE_TREE {
		if !strings.has_prefix(p, prefix) do continue
		known = true
		rest := p[len(prefix):]
		if rest == "" do continue
		name, is_dir := rest, false
		if k := strings.index_byte(rest, '/'); k >= 0 do name, is_dir = rest[:k], true
		dup := false
		for e in out do if e.name == name do dup = true
		if !dup do append(&out, Fgrid_Entry{name, strings.concatenate({prefix, name}, context.temp_allocator), is_dir})
	}
	return out[:], known
}

// /bigroot holds one folder with one more file than a column keeps.
@(private = "file")
big_list :: proc(dir: string) -> ([]Fgrid_Entry, bool) {
	out := make([dynamic]Fgrid_Entry, context.temp_allocator)
	switch dir {
	case "/bigroot":
		append(&out, Fgrid_Entry{"big", "/bigroot/big", true})
	case "/bigroot/big":
		for i in 0 ..< FGRID_MAX_ITEMS + 1 {
			name := fmt.tprintf("f%03d.odin", i)
			append(&out, Fgrid_Entry{name, fmt.tprintf("/bigroot/big/%s", name), false})
		}
	case:
		return nil, false
	}
	return out[:], true
}

@(private = "file")
titles :: proc(g: ^File_Grid) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for grp in g.groups do append(&parts, fmt.tprintf("%s%s(%d)", grp.here ? "*" : "", grp.title, len(grp.items)))
	return strings.join(parts[:], " ", context.temp_allocator)
}

@(private = "file")
sel_name :: proc(g: ^File_Grid) -> string {
	it, is_tab, _, ok := fgrid_selected(g)
	if !ok do return "<none>"
	return is_tab ? fmt.tprintf("[%s]", it.name) : it.name
}

// Put the cursor on group gi, item ii (and remember that row, like a real move;
// ii -1 = on the tab row).
@(private = "file")
put :: proc(g: ^File_Grid, gi, ii: int) {
	g.group, g.item = gi, ii
	g.want_row = ii
}

@(test)
test_fgrid_build_columns :: proc(t: ^testing.T) {
	g: File_Grid
	defer fgrid_destroy(&g)
	defer free_all(context.temp_allocator)
	fgrid_build(&g, "/r", fake_list)
	// No files directly in /r: no "here" column.
	testing.expect_value(t, titles(&g), "directory a(2) directory b(4) directory c(5) directory d(1) empty(0)")
	c := g.groups[2]
	testing.expect_value(t, c.items[0].name, "f1.odin")
	testing.expect_value(t, c.items[2].name, "f3.odin")
	testing.expect_value(t, c.items[3].name, "subdirectory c")
	testing.expect(t, c.items[3].is_dir && c.items[4].is_dir && !c.items[2].is_dir)
	testing.expect_value(t, c.items[4].name, "subdirectory d")
}

@(test)
test_fgrid_here_column_and_stable_sort :: proc(t: ^testing.T) {
	g: File_Grid
	defer fgrid_destroy(&g)
	defer free_all(context.temp_allocator)
	for _ in 0 ..< 3 {
		fgrid_build(&g, "/r2", fake_list)
		testing.expect_value(t, titles(&g), "*r2(3)")
		h := g.groups[0]
		testing.expect_value(t, h.items[0].name, "A.odin")
		testing.expect_value(t, h.items[1].name, "a.odin")
		testing.expect_value(t, h.items[2].name, "main.odin")
	}
}

@(test)
test_fgrid_move_keeps_row :: proc(t: ^testing.T) {
	g: File_Grid
	defer fgrid_destroy(&g)
	defer free_all(context.temp_allocator)
	fgrid_build(&g, "/r", fake_list)
	put(&g, 0, 1)
	testing.expect_value(t, fgrid_move(&g, .Right), Fgrid_Move.Moved)
	testing.expect_value(t, g.group, 1)
	testing.expect_value(t, g.item, 1)
	put(&g, 2, 4)
	fgrid_move(&g, .Right) // d has one file: clamp to row 0
	testing.expect_value(t, g.group, 3)
	testing.expect_value(t, g.item, 0)
	fgrid_move(&g, .Left) // back into the taller column: row 4 again
	testing.expect_value(t, g.group, 2)
	testing.expect_value(t, g.item, 4)
}

@(test)
test_fgrid_tabs :: proc(t: ^testing.T) {
	g: File_Grid
	defer fgrid_destroy(&g)
	defer free_all(context.temp_allocator)
	fgrid_build(&g, "/r", fake_list)
	put(&g, 1, 0)
	testing.expect_value(t, fgrid_move(&g, .Up), Fgrid_Move.Moved)
	testing.expect_value(t, sel_name(&g), "[directory b]")
	testing.expect_value(t, fgrid_move(&g, .Up), Fgrid_Move.None)
	g.want_row = 2
	fgrid_move(&g, .Down)
	testing.expect_value(t, g.item, 2)
	put(&g, 1, 3)
	testing.expect_value(t, fgrid_move(&g, .Down), Fgrid_Move.None) // bottom: no wrap
	testing.expect_value(t, g.item, 3)
	put(&g, 1, -1)
	fgrid_move(&g, .Right)
	testing.expect_value(t, sel_name(&g), "[directory c]")
	fgrid_move(&g, .Left)
	testing.expect_value(t, sel_name(&g), "[directory b]")
	put(&g, 3, 0)
	fgrid_move(&g, .Right) // into an empty column: its tab
	testing.expect_value(t, sel_name(&g), "[empty]")
	testing.expect_value(t, fgrid_move(&g, .Down), Fgrid_Move.None)
}

@(test)
test_fgrid_edges :: proc(t: ^testing.T) {
	g: File_Grid
	defer fgrid_destroy(&g)
	defer free_all(context.temp_allocator)
	fgrid_build(&g, "/r", fake_list)
	put(&g, 0, 1)
	testing.expect_value(t, fgrid_move(&g, .Left), Fgrid_Move.Up_Level)
	put(&g, 0, -1)
	testing.expect_value(t, fgrid_move(&g, .Left), Fgrid_Move.Up_Level)
	put(&g, 4, -1)
	testing.expect_value(t, fgrid_move(&g, .Right), Fgrid_Move.None)
	empty: File_Grid
	testing.expect_value(t, fgrid_move(&empty, .Left), Fgrid_Move.Up_Level)
	for d in ([]Fgrid_Dir{.Up, .Down, .Right}) do testing.expect_value(t, fgrid_move(&empty, d), Fgrid_Move.None)
	_, _, _, ok := fgrid_selected(&empty)
	testing.expect(t, !ok)
}

@(test)
test_fgrid_descend_shows_sisters :: proc(t: ^testing.T) {
	g: File_Grid
	defer fgrid_destroy(&g)
	defer free_all(context.temp_allocator)
	fgrid_build(&g, "/r", fake_list)
	put(&g, 2, 3)
	testing.expect_value(t, sel_name(&g), "subdirectory c")
	view, focus, first, ok := fgrid_descend(&g)
	testing.expect(t, ok && first)
	testing.expect_value(t, view, "/r/directory c")
	testing.expect_value(t, focus, "/r/directory c/subdirectory c")
	v, f := strings.clone(view, context.temp_allocator), strings.clone(focus, context.temp_allocator)
	fgrid_build(&g, v, fake_list)
	testing.expect(t, fgrid_select_path(&g, f))
	testing.expect_value(t, sel_name(&g), "[subdirectory c]")
	fgrid_move(&g, .Down)
	testing.expect_value(t, sel_name(&g), "x1.odin")
	testing.expect_value(t, titles(&g), "*directory c(3) subdirectory c(3) subdirectory d(1)")
	// A on a file or on the "here" tab doesn't descend; a column tab does.
	_, _, _, ok = fgrid_descend(&g)
	testing.expect(t, !ok)
	put(&g, 0, -1)
	_, _, _, ok = fgrid_descend(&g)
	testing.expect(t, !ok)
	put(&g, 2, -1)
	view, focus, first, ok = fgrid_descend(&g)
	testing.expect(t, ok && !first && focus == "")
	testing.expect_value(t, view, "/r/directory c/subdirectory d")
}

@(test)
test_fgrid_up_focuses_old_view :: proc(t: ^testing.T) {
	g: File_Grid
	defer fgrid_destroy(&g)
	defer free_all(context.temp_allocator)
	fgrid_build(&g, "/r/directory c", fake_list)
	view, focus, ok := fgrid_up(&g)
	testing.expect(t, ok)
	testing.expect_value(t, view, "/r")
	v, f := strings.clone(view, context.temp_allocator), strings.clone(focus, context.temp_allocator)
	fgrid_build(&g, v, fake_list)
	testing.expect(t, fgrid_select_path(&g, f))
	testing.expect_value(t, sel_name(&g), "[directory c]")
}

@(test)
test_fgrid_parent_of_stops_at_top :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for p in ([]string{"/", "C:/", "r", "", "."}) {
		_, ok := fgrid_parent_of(p)
		testing.expectf(t, !ok, "parent_of(%q) should be the top", p)
	}
	q, ok := fgrid_parent_of("/r/directory c")
	testing.expect(t, ok)
	testing.expect_value(t, q, "/r")
}

@(test)
test_fgrid_build_climbs_from_gone_view :: proc(t: ^testing.T) {
	g: File_Grid
	defer fgrid_destroy(&g)
	defer free_all(context.temp_allocator)
	fgrid_build(&g, "/r/gone/deeper", fake_list)
	testing.expect_value(t, g.view, "/r")
	fgrid_build(&g, g.view, fake_list) // the view may alias g.view
	testing.expect_value(t, g.view, "/r")
	testing.expect_value(t, len(g.groups), 5)
}

@(test)
test_fgrid_view_for :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, fgrid_view_for("/r/a/b/f.odin", "/r"), "/r/a")
	testing.expect_value(t, fgrid_view_for("/r/a/f.odin", "/r"), "/r")
	testing.expect_value(t, fgrid_view_for("/r/f.odin", "/r"), "/r")
	testing.expect_value(t, fgrid_view_for("/x/f.odin", "/r"), "/r")
	testing.expect_value(t, fgrid_view_for("", "/r"), "/r")
}

@(test)
test_fgrid_select_path_ignores_case_and_slashes :: proc(t: ^testing.T) {
	g: File_Grid
	defer fgrid_destroy(&g)
	defer free_all(context.temp_allocator)
	fgrid_build(&g, "/r", fake_list)
	testing.expect(t, fgrid_select_path(&g, "\\R\\Directory B\\F3.ODIN"))
	testing.expect_value(t, sel_name(&g), "f3.odin")
	testing.expect_value(t, g.group, 1)
	testing.expect_value(t, g.want_row, 2)
	testing.expect(t, fgrid_select_path(&g, "/R/DIRECTORY D/"))
	testing.expect_value(t, sel_name(&g), "[directory d]")
	testing.expect(t, !fgrid_select_path(&g, "/r/nowhere.odin"))
}

@(test)
test_fgrid_flat_index_reading_order :: proc(t: ^testing.T) {
	g: File_Grid
	defer fgrid_destroy(&g)
	defer free_all(context.temp_allocator)
	fgrid_build(&g, "/r", fake_list)
	put(&g, 0, -1)
	testing.expect_value(t, fgrid_flat_index(&g), 0)
	put(&g, 0, 1)
	testing.expect_value(t, fgrid_flat_index(&g), 2)
	put(&g, 1, -1)
	testing.expect_value(t, fgrid_flat_index(&g), 3) // a's tab + 2 files
	put(&g, 2, 4)
	testing.expect_value(t, fgrid_flat_index(&g), 3 + 5 + 5)
}

@(test)
test_fgrid_target_dir :: proc(t: ^testing.T) {
	g: File_Grid
	defer fgrid_destroy(&g)
	defer free_all(context.temp_allocator)
	fgrid_build(&g, "/r", fake_list)
	put(&g, 1, -1)
	d, box := fgrid_target_dir(&g)
	testing.expect(t, d == "/r/directory b" && !box)
	put(&g, 1, 2)
	d, box = fgrid_target_dir(&g)
	testing.expect(t, d == "/r/directory b" && !box)
	put(&g, 2, 3)
	d, box = fgrid_target_dir(&g)
	testing.expect(t, d == "/r/directory c/subdirectory c" && box)
	fgrid_build(&g, "/r2", fake_list)
	put(&g, 0, -1)
	d, box = fgrid_target_dir(&g)
	testing.expect(t, d == "/r2" && !box)
}

@(test)
test_fgrid_caps_long_columns :: proc(t: ^testing.T) {
	g: File_Grid
	defer fgrid_destroy(&g)
	defer free_all(context.temp_allocator)
	fgrid_build(&g, "/bigroot", big_list)
	testing.expect_value(t, len(g.groups), 1)
	testing.expect_value(t, len(g.groups[0].items), FGRID_MAX_ITEMS)
	testing.expect_value(t, g.groups[0].more, 1)
}

@(test)
test_fgrid_row_survives_empty_column :: proc(t: ^testing.T) {
	g: File_Grid
	defer fgrid_destroy(&g)
	defer free_all(context.temp_allocator)
	fgrid_build(&g, "/r3", fake_list)
	testing.expect_value(t, titles(&g), "a(3) b(0) c(3)")
	put(&g, 0, 1)
	fgrid_move(&g, .Right) // the empty column: its tab
	testing.expect_value(t, sel_name(&g), "[b]")
	fgrid_move(&g, .Right) // the row comes back
	testing.expect_value(t, sel_name(&g), "g2.odin")
	fgrid_move(&g, .Left)
	fgrid_move(&g, .Left)
	testing.expect_value(t, sel_name(&g), "f2.odin")
	// Up onto a tab on purpose: Left/Right then walk the tab row.
	put(&g, 0, 0)
	fgrid_move(&g, .Up)
	fgrid_move(&g, .Right)
	fgrid_move(&g, .Right)
	testing.expect_value(t, sel_name(&g), "[c]")
	fgrid_move(&g, .Down)
	testing.expect_value(t, sel_name(&g), "g1.odin")
}

// /r4: "locked" is listed but can't be read; "open" can.
@(private = "file")
locked_list :: proc(dir: string) -> ([]Fgrid_Entry, bool) {
	out := make([dynamic]Fgrid_Entry, context.temp_allocator)
	switch dir {
	case "/r4":
		append(&out, Fgrid_Entry{"locked", "/r4/locked", true}, Fgrid_Entry{"open", "/r4/open", true})
	case "/r4/open":
		append(&out, Fgrid_Entry{"x.odin", "/r4/open/x.odin", false})
	case:
		return nil, false
	}
	return out[:], true
}

@(test)
test_fgrid_descend_refuses_unreadable :: proc(t: ^testing.T) {
	g: File_Grid
	defer fgrid_destroy(&g)
	defer free_all(context.temp_allocator)
	fgrid_build(&g, "/r4", locked_list)
	testing.expect(t, g.groups[0].unreadable && !g.groups[1].unreadable)
	put(&g, 0, -1)
	_, _, _, ok := fgrid_descend(&g)
	testing.expect(t, !ok) // the rebuild would land right back on /r4
	put(&g, 1, -1)
	view, _, _, ok2 := fgrid_descend(&g)
	testing.expect(t, ok2)
	testing.expect_value(t, view, "/r4/open")
}

// /r5 before and after its only own file is deleted.
@(private = "file")
r5_before :: proc(dir: string) -> ([]Fgrid_Entry, bool) {
	out := make([dynamic]Fgrid_Entry, context.temp_allocator)
	switch dir {
	case "/r5":
		append(&out, Fgrid_Entry{"main.odin", "/r5/main.odin", false}, Fgrid_Entry{"sub", "/r5/sub", true})
	case "/r5/sub":
	case:
		return nil, false
	}
	return out[:], true
}

@(private = "file")
r5_after :: proc(dir: string) -> ([]Fgrid_Entry, bool) {
	switch dir {
	case "/r5":
		out := make([dynamic]Fgrid_Entry, context.temp_allocator)
		append(&out, Fgrid_Entry{"sub", "/r5/sub", true})
		return out[:], true
	case "/r5/sub":
		return nil, true
	}
	return nil, false
}

@(test)
test_fgrid_keeps_here_column_on_rebuild :: proc(t: ^testing.T) {
	g: File_Grid
	defer fgrid_destroy(&g)
	defer free_all(context.temp_allocator)
	fgrid_build(&g, "/r5", r5_before)
	testing.expect_value(t, titles(&g), "*r5(1) sub(0)")
	put(&g, 0, 0)
	fgrid_build(&g, g.view, r5_after) // main.odin deleted
	testing.expect_value(t, titles(&g), "*r5(0) sub(0)")
	testing.expect_value(t, sel_name(&g), "[r5]") // X here still makes a file in /r5
	d, box := fgrid_target_dir(&g)
	testing.expect(t, d == "/r5" && !box)
	// A fresh view of a folder without own files still has no "here" column.
	fgrid_build(&g, "/r3", fake_list)
	fgrid_build(&g, "/r5", r5_after)
	testing.expect_value(t, titles(&g), "sub(0)")
}

@(test)
test_fgrid_title_at_the_top :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, fgrid_title("C:/"), "C:")
	testing.expect_value(t, fgrid_title("C:\\"), "C:")
	testing.expect_value(t, fgrid_title("/"), "/")
	testing.expect_value(t, fgrid_title("/r/directory a"), "directory a")
	testing.expect_value(t, fgrid_title("/r/directory a/"), "directory a")
}

@(test)
test_fgrid_project_root :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	root, ok := fgrid_project_root("/p/game/render/camera.odin", "/p")
	testing.expect(t, ok)
	testing.expect_value(t, root, "/p/game")
	root, ok = fgrid_project_root("/p/game/main.odin", "/P/")
	testing.expect(t, ok)
	testing.expect_value(t, root, "/p/game")
	for f in ([]string{"/p/loose.odin", "/q/game/main.odin", ""}) {
		_, ok = fgrid_project_root(f, "/p")
		testing.expectf(t, !ok, "project_root(%q) should fail", f)
	}
}

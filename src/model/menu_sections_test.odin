package model

import "core:testing"

@(private = "file")
entries_of :: proc(labels: []string, pinned: int) -> []Entry {
	out := make([]Entry, len(labels), context.temp_allocator)
	for l, i in labels do out[i] = Entry{label = l, fill = "x", pinned = i < pinned}
	return out
}

@(test)
test_recent_section_layout_and_nav :: proc(t: ^testing.T) {
	app: App
	defer { clear_nav(&app); delete(app.nav) }
	// 2 used-in-this-file entries + 14 others (sorted, since there are > 12).
	labels := []string{"used_b", "used_a", "p", "o", "n", "m", "l", "k", "j", "i", "h", "g", "f", "e", "d", "c"}
	push_menu(&app, "procs", entries_of(labels, 2))
	v := current_view(&app)
	testing.expect_value(t, v.recent, 2)
	testing.expect_value(t, v.entries[0].label, "used_b") // pinned keep their order...
	testing.expect_value(t, v.entries[2].label, "c")      // ...the rest are sorted

	cols := grid_cols(len(v.entries)) // 16 entries -> 4 columns
	testing.expect_value(t, cols, 4)
	r, c := menu_cell(v, 1)
	testing.expect(t, r == 0 && c == 1, "recent entries on the first row")
	r, c = menu_cell(v, 2)
	testing.expect(t, r == 1 && c == 0, "the rest starts on a new row")
	rows, recent_rows := menu_rows(v)
	testing.expect(t, rows == 5 && recent_rows == 1)

	// D-pad: right wraps within the 2-entry recent row; down goes into the rest.
	v.index = 1
	v.index = menu_nav(v, Input{right = true})
	testing.expect_value(t, v.index, 0)
	v.index = 1
	v.index = menu_nav(v, Input{down = true})
	testing.expect_value(t, v.index, 3) // row 1, col 1
	v.index = menu_nav(v, Input{up = true})
	testing.expect_value(t, v.index, 1)
	v.index = 0
	v.index = menu_nav(v, Input{up = true}) // wraps to the last row
	r, _ = menu_cell(v, v.index)
	testing.expect_value(t, r, rows - 1)
}

@(test)
test_no_recent_section_is_plain_grid :: proc(t: ^testing.T) {
	app: App
	defer { clear_nav(&app); delete(app.nav) }
	push_menu(&app, "plain", entries_of([]string{"a", "b", "c", "d", "e"}, 0))
	v := current_view(&app)
	testing.expect_value(t, v.recent, 0)
	for inp in ([]Input{{left = true}, {right = true}, {up = true}, {down = true}}) {
		for i in 0 ..< len(v.entries) {
			v.index = i
			testing.expect_value(t, menu_nav(v, inp), grid_nav(i, len(v.entries), inp))
		}
	}
}

// All entries recent (nothing else in the menu): no separate section.
@(test)
test_all_recent_is_not_a_section :: proc(t: ^testing.T) {
	app: App
	defer { clear_nav(&app); delete(app.nav) }
	push_menu(&app, "only used", entries_of([]string{"a", "b"}, 2))
	testing.expect_value(t, current_view(&app).recent, 0)
}

// The real case: a proc already called in the file is the recent section of its package.
@(test)
test_used_proc_is_recent_section :: proc(t: ^testing.T) {
	app: App
	defer {
		clear_nav(&app); delete(app.nav); doc_reset(&app); delete(app.doc.nodes)
		delete(app.recent_imports); free_menus(&app)
	}
	app.state = .Editor
	doc_from_source(&app, "package main\nimport win \"core:sys/windows\"\nmain :: proc() {\n\twin.MessageBoxW(nil, nil, nil, 0)\n}")
	entries := build_import_proc_menu(&app, "win", "core:sys/windows")
	push_menu(&app, "win", entries)
	v := current_view(&app)
	testing.expect_value(t, v.recent, 1)
	testing.expect_value(t, v.entries[0].label, "MessageBoxW")
	clear_nav(&app)
	free_entries(entries)
}

package model

import "core:fmt"
import "core:strings"
import "core:testing"

// ---- helpers ----

// A file importing core:sys/windows as `alias`, with `extra` lines in main, and
// a `name := ●` statement whose value dot is ready to fill. Returns its line.
@(private = "file")
setup :: proc(app: ^App, alias: string, extra := "") -> int {
	app.state = .Editor
	src := strings.concatenate({"package main\n\nimport ", alias, " \"core:sys/windows\"\n\nmain :: proc() {\n", extra, "}"}, context.temp_allocator)
	doc_from_source(app, src)
	body: Node
	append(&body.fields, Field{strings.clone("\t"), false, false, "", "", ""})
	append(&body.fields, Field{"", false, true, "body", "", ""})
	ni := len(app.doc.nodes) - 1
	inject_at(&app.doc.nodes, ni, body)
	make_body_statement(app, ni, 1, "__stmt_decl__")
	return ni
}

@(private = "file")
cleanup :: proc(app: ^App) {
	clear_nav(app)
	delete(app.nav)
	doc_reset(app)
	delete(app.doc.nodes)
	delete(app.recent_imports)
	free_menus(app)
}

// Open the fill menu on the first value dot of line ni.
@(private = "file")
open_value :: proc(app: ^App, ni: int) {
	for f, i in app.doc.nodes[ni].fields {
		if f.slot && f.kind == "value" { focus_field_index(app, ni, i); break }
	}
	update(app, Input{confirm = true})
}

@(private = "file")
pick :: proc(t: ^testing.T, app: ^App, label: string) -> bool {
	v := current_view(app)
	if v == nil do return false
	for e, i in v.entries {
		if e.label == label {
			v.index = i
			update(app, Input{confirm = true})
			return true
		}
	}
	testing.expectf(t, false, "no %q in menu %q", label, v.title)
	return false
}

@(private = "file")
index_of :: proc(v: ^MenuView, label: string) -> int {
	for e, i in v.entries do if e.label == label do return i
	return -1
}

// Labels from `entries` down to the non-pinned leaf `label` with fill `fill`.
@(private = "file")
path_to :: proc(entries: []Entry, label, fill: string, out: ^[dynamic]string) -> bool {
	for e in entries {
		if e.pinned do continue
		append(out, e.label)
		if len(e.children) == 0 && e.label == label && (fill == "" || e.fill == fill) do return true
		if len(e.children) > 0 && path_to(e.children, label, fill, out) do return true
		pop(out)
	}
	return false
}

@(private = "file")
key :: proc(segs: ..string) -> string { return heat_key_of(segs) }

@(private = "file")
count :: proc(h: ^Heat, segs: ..string) -> int { return h.counts[heat_key_of(segs)] or_else 0 }

// ---- tests ----

@(test)
test_heat_counts_every_prefix :: proc(t: ^testing.T) {
	h: Heat
	defer heat_free(&h)
	app: App
	defer cleanup(&app)
	app.heat = &h
	leaf := make_slice(Entry{label = "Leaf", fill = "__lit_true__"}, Entry{label = "Other", fill = "__lit_true__"})
	mid := make_slice(Entry{label = "Mid", children = leaf})
	root := make_slice(Entry{label = "Top", children = mid}, Entry{label = "Side", fill = "__lit_true__"})
	defer free_entries(root)
	push_menu(&app, "Root title", root)
	current_view(&app).index = index_of(current_view(&app), "Top")
	push_menu(&app, "Top", mid)
	push_menu(&app, "Mid", leaf)
	v := current_view(&app)
	v.index = index_of(v, "Leaf")
	heat_record_select(&app, v.entries[v.index])
	testing.expect_value(t, count(&h, "Top"), 1)
	testing.expect_value(t, count(&h, "Top", "Mid"), 1)
	testing.expect_value(t, count(&h, "Top", "Mid", "Leaf"), 1)
	testing.expect_value(t, count(&h, "Root title"), 0) // the root view's title isn't part of the key
	testing.expect_value(t, len(h.counts), 3)
	testing.expect(t, h.dirty)
	// The open views were refreshed: Leaf is worn, Other isn't.
	testing.expect(t, view_shade(v, index_of(v, "Leaf")) > 0)
	testing.expect_value(t, view_shade(v, index_of(v, "Other")), f32(0))
	heat_record_select(&app, v.entries[v.index])
	testing.expect_value(t, count(&h, "Top"), 2)
	testing.expect_value(t, count(&h, "Top", "Mid", "Leaf"), 2)
}

@(test)
test_heat_submenu_push_records_nothing :: proc(t: ^testing.T) {
	h: Heat
	defer heat_free(&h)
	app: App
	defer cleanup(&app)
	app.heat = &h
	ni := setup(&app, "win")
	open_value(&app, ni)
	pick(t, &app, "Constant") // a submenu: pushes, nothing used yet
	pick(t, &app, "win.")
	testing.expect_value(t, len(h.counts), 0)
	testing.expect(t, !h.dirty)
	// Placeholders and Convert forms don't count either.
	testing.expect(t, !heat_is_action(&app, grp_dim("(no imports yet)")))
	testing.expect(t, !heat_is_action(&app, Entry{label = "T(x)", fill = CONV_FORM_FILL}))
	testing.expect(t, !heat_is_action(&app, Entry{label = "7", fill = NUM_KEY_FILL}))
	testing.expect(t, heat_is_action(&app, Entry{label = "true", fill = "__lit_true__"}))
}

@(test)
test_heat_real_flow_and_alias_independence :: proc(t: ^testing.T) {
	h: Heat
	defer heat_free(&h)

	// Project 1 imports core:sys/windows as `win` and inserts MB_OK.
	a: App
	defer cleanup(&a)
	a.heat = &h
	ni := setup(&a, "win")
	open_value(&a, ni)
	pick(t, &a, "Constant")
	pick(t, &a, "win.")
	p := make([dynamic]string, 0, 8, context.temp_allocator)
	if !testing.expect(t, path_to(current_view(&a).entries, "MB_OK", CONST_IMPORT_FILL, &p), "MB_OK should be reachable") do return
	for &s in p do s = strings.clone(s, context.temp_allocator) // the menu (and its labels) is freed on use
	for step in p do pick(t, &a, step)
	testing.expect_value(t, a.state, State.Editor)
	testing.expect(t, strings.contains(node_text(a.doc.nodes[ni], context.temp_allocator), "win.MB_OK"))
	testing.expect_value(t, count(&h, "Constant"), 1)
	testing.expect_value(t, count(&h, "Constant", "core:sys/windows"), 1)
	full := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&full, "Constant", "core:sys/windows")
	append(&full, ..p[:])
	testing.expect_value(t, h.counts[heat_key_of(full[:])] or_else 0, 1)
	testing.expect_value(t, count(&h, "Constant", "win."), 0) // never the alias

	// Project 2 imports it as `windows`: the same trail looks worn.
	b: App
	defer cleanup(&b)
	b.heat = &h
	nb := setup(&b, "windows")
	open_value(&b, nb)
	root := current_view(&b)
	testing.expect(t, view_shade(root, index_of(root, "Constant")) > 0, "Constant should be worn")
	testing.expect_value(t, view_shade(root, index_of(root, "Number")), f32(0))
	pick(t, &b, "Constant")
	consts := current_view(&b)
	testing.expect(t, view_shade(consts, index_of(consts, "windows.")) > 0, "windows. should share win.'s heat")
	pick(t, &b, "windows.")
	if len(p) > 1 {
		pkg := current_view(&b)
		testing.expect(t, view_shade(pkg, index_of(pkg, p[0])) > 0, "the group leading to MB_OK should be worn")
	}
}

@(test)
test_heat_pinned_leaf_wears_canonical_home :: proc(t: ^testing.T) {
	h: Heat
	defer heat_free(&h)
	app: App
	defer cleanup(&app)
	app.heat = &h
	// MB_OK is already used in this file: it's pinned at the package level.
	ni := setup(&app, "win", "\tx := win.MB_OK\n")
	open_value(&app, ni)
	pick(t, &app, "Constant")
	pick(t, &app, "win.")
	v := current_view(&app)
	i := index_of(v, "MB_OK")
	if !testing.expect(t, i >= 0 && v.entries[i].pinned, "MB_OK should be pinned") do return
	pick(t, &app, "MB_OK")
	testing.expect_value(t, count(&h, "Constant"), 1)
	testing.expect_value(t, count(&h, "Constant", "core:sys/windows"), 1) // each prefix once per use
	testing.expect_value(t, count(&h, "Constant", "core:sys/windows", "MB_OK"), 1)

	// Where a project that doesn't use MB_OK shows it.
	infos := consts_info_for_path("core:sys/windows")
	defer delete(infos)
	tree := build_proc_hierarchy("win", infos)
	defer free_entries(tree)
	p := make([dynamic]string, 0, 8, context.temp_allocator)
	if !testing.expect(t, path_to(tree, "MB_OK", "", &p), "MB_OK in the full grouping") do return
	testing.expect(t, len(p) > 1, "MB_OK's home should be in a group")
	full := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&full, "Constant", "core:sys/windows")
	for s in p do append(&full, strings.clone(s, context.temp_allocator))
	for d in 3 ..= len(full) {
		testing.expectf(t, (h.counts[heat_key_of(full[:d])] or_else 0) == 1, "canonical prefix %v should have one use", full[:d])
	}
}

@(test)
test_heat_serialize_parse_round_trip :: proc(t: ^testing.T) {
	h: Heat
	defer heat_free(&h)
	heat_add(&h, key("Constant"), 3)
	heat_add(&h, key("Constant", "core:sys/windows"), 2)
	heat_add(&h, key("Calls", heat_segment("odd\tla\nbel\r")), 1)
	text := heat_serialize(&h, context.temp_allocator)
	testing.expect(t, strings.has_prefix(text, "doodle-heat 1\n"))
	testing.expect(t, strings.contains(text, "2\tConstant\tcore:sys/windows\n"))
	testing.expect(t, strings.contains(text, "1\tCalls\todd la bel \n"), "tabs / newlines in labels become spaces")
	// Sorted: Calls < Constant < Constant\x1f...
	testing.expect(t, strings.index(text, "Calls") < strings.index(text, "3\tConstant\n"))

	g: Heat
	defer heat_free(&g)
	used := heat_parse(text, &g)
	testing.expect_value(t, used, 3)
	testing.expect_value(t, len(g.counts), 3)
	testing.expect_value(t, count(&g, "Constant"), 3)
	testing.expect_value(t, count(&g, "Constant", "core:sys/windows"), 2)
	testing.expect_value(t, count(&g, "Calls", "odd la bel "), 1)
	testing.expect_value(t, heat_serialize(&g, context.temp_allocator), text)

	// Malformed lines are ignored, duplicates summed, CRLF accepted.
	bad := "doodle-heat 1\r\n4\tConstant\r\nnot a line\n-2\tX\nabc\tY\n\t\tZ\n5\t\n7\n2\tConstant\n"
	m: Heat
	defer heat_free(&m)
	testing.expect_value(t, heat_parse(bad, &m), 2)
	testing.expect_value(t, len(m.counts), 1)
	testing.expect_value(t, count(&m, "Constant"), 6)
}

@(test)
test_heat_prune_keeps_most_used :: proc(t: ^testing.T) {
	h: Heat
	defer heat_free(&h)
	heat_add(&h, "a", 5)
	heat_add(&h, "b", 1)
	heat_add(&h, "c", 3)
	heat_add(&h, "d", 1)
	heat_prune(&h, 2)
	testing.expect_value(t, len(h.counts), 2)
	testing.expect(t, "a" in h.counts && "c" in h.counts, "the most-used keys stay")
}

@(test)
test_heat_nil_is_noop :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	ni := setup(&app, "win")
	open_value(&app, ni)
	testing.expect(t, current_view(&app).heat == nil)
	pick(t, &app, "true")
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, heat_count(nil, []string{"true"}), 0)
	testing.expect_value(t, view_shade(nil, 0), f32(0))
}

@(test)
test_heat_view_cache_freed :: proc(t: ^testing.T) {
	h: Heat
	defer heat_free(&h)
	heat_add(&h, key("Top"), 2)
	heat_add(&h, key("Top", "Mid"), 1)
	app: App
	defer cleanup(&app)
	app.heat = &h
	app.state = .Radial
	mid := make_slice(Entry{label = "Mid", fill = "__lit_true__"}, Entry{label = "Cold", fill = "__lit_true__"})
	root := make_slice(Entry{label = "Top", children = mid}, Entry{label = "Side", fill = "__lit_true__"})
	defer free_entries(root)
	for _ in 0 ..< 3 {
		push_menu(&app, "Root", root)
		r := current_view(&app)
		r.index = index_of(r, "Top")
		testing.expect(t, view_shade(r, r.index) > 0)
		testing.expect_value(t, view_shade(r, index_of(r, "Side")), f32(0))
		update(&app, Input{confirm = true}) // into Top (a submenu: no use recorded)
		v := current_view(&app)
		testing.expect(t, view_shade(v, index_of(v, "Mid")) > 0)
		testing.expect(t, view_shade(v, index_of(v, "Mid")) < view_shade(r, r.index), "fewer uses, lighter")
		testing.expect_value(t, view_shade(v, index_of(v, "Cold")), f32(0))
		clear_nav(&app) // frees each view's shades (the leak checker watches)
	}
	testing.expect_value(t, count(&h, "Top"), 2)
}

@(test)
test_heat_shade_curve :: proc(t: ^testing.T) {
	testing.expect_value(t, heat_shade(0), f32(0))
	testing.expect_value(t, heat_shade(-3), f32(0))
	prev := f32(0)
	for c in 1 ..= HEAT_SATURATE {
		s := heat_shade(c)
		testing.expectf(t, s > prev && s <= 1, "shade(%d) = %v should rise", c, s)
		prev = s
	}
	testing.expect_value(t, heat_shade(HEAT_SATURATE), f32(1))
	testing.expect_value(t, heat_shade(100000), f32(1))
}

// ---- review fixes ----

// Path of labels to a non-pinned leaf in an import's constant menu, for a file
// using `used` (e.g. "\tx := win.ERROR_SUCCESS\n").
@(private = "file")
const_path :: proc(t: ^testing.T, used: string, leaf: string) -> []string {
	app: App
	defer cleanup(&app)
	setup(&app, "win", used)
	menu := build_import_const_menu(&app, "win", "core:sys/windows")
	defer free_entries(menu)
	p := make([dynamic]string, 0, 8, context.temp_allocator)
	testing.expectf(t, path_to(menu, leaf, CONST_IMPORT_FILL, &p), "%s should be reachable", leaf)
	for &s in p do s = strings.clone(s, context.temp_allocator)
	return p[:]
}

@(test)
test_heat_grouping_ignores_used_names :: proc(t: ^testing.T) {
	// winerror has 62 constants: using two must not flatten it (60 left) in one
	// project while another shows ERROR_... groups - the trails must match.
	plain := const_path(t, "", "ERROR_ACCESS_DENIED")
	using_two := const_path(t, "\tx := win.ERROR_SUCCESS\n\ty := win.ERROR_ALREADY_EXISTS\n", "ERROR_ACCESS_DENIED")
	testing.expect_value(t, len(using_two), len(plain))
	if len(using_two) == len(plain) do for s, i in plain do testing.expect_value(t, using_two[i], s)
	// The used names themselves are only pinned, not in the groups.
	app: App
	defer cleanup(&app)
	setup(&app, "win", "\tx := win.ERROR_SUCCESS\n")
	menu := build_import_const_menu(&app, "win", "core:sys/windows")
	defer free_entries(menu)
	testing.expect(t, menu[0].pinned && menu[0].label == "ERROR_SUCCESS")
	p := make([dynamic]string, 0, 8, context.temp_allocator)
	testing.expect(t, !path_to(menu, "ERROR_SUCCESS", CONST_IMPORT_FILL, &p), "a used name is left out of the groups")
}

@(test)
test_heat_alpha_buckets_have_distinct_keys :: proc(t: ^testing.T) {
	// A prefix group bigger than FLAT_MAX: every bucket is labeled "w".
	procs := make([dynamic]CoreProc, 0, 100, context.temp_allocator)
	for i in 0 ..< 100 do append(&procs, CoreProc{path = "x", file = "f", name = fmt.tprintf("WM_%03d", i)})
	buckets := build_alpha_buckets("x", procs[:])
	defer free_entries(buckets)
	testing.expect(t, len(buckets) > 2)
	seen := make(map[string]bool, 16, context.temp_allocator)
	for b in buckets {
		testing.expect_value(t, b.label, "w")
		id := entry_heat_id(b)
		testing.expectf(t, id not_in seen, "bucket key %q repeats", id)
		seen[id] = true
	}
	testing.expect_value(t, entry_heat_id(buckets[0]), "WM_000..WM_011")
}

@(test)
test_heat_dim_refused_options_record_nothing :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	for fill in ([]string{LOOP_OPT_FILL, BR_OPT_FILL, CTRL_MENU_FILL}) {
		testing.expectf(t, !heat_is_action(&app, Entry{label = "x", fill = fill, dim = true}), "dim %s is refused", fill)
		testing.expectf(t, heat_is_action(&app, Entry{label = "x", fill = fill}), "%s is an action", fill)
	}
	// Grayed by type fitting: still applied when picked, so still a use.
	testing.expect(t, heat_is_action(&app, Entry{label = "true", fill = "__lit_true__", dim = true}))
}

@(test)
test_heat_root_prefix :: proc(t: ^testing.T) {
	h: Heat
	defer heat_free(&h)
	app: App
	defer cleanup(&app)
	app.heat = &h
	heat_add(&h, key("Call", "From import", "core:sys/windows", "Leaf"), 2)
	root := make_slice(Entry{label = "Leaf", fill = "__call_import_proc__"}, Entry{label = "Cold", fill = "__call_import_proc__"})
	defer free_entries(root)
	for _ in 0 ..< 2 {
		push_menu(&app, "Change procedure", root)
		heat_set_root(&app, "Call", "From import", "core:sys/windows")
		v := current_view(&app)
		testing.expect(t, view_shade(v, index_of(v, "Leaf")) > 0, "the Call trail's heat shows")
		testing.expect_value(t, view_shade(v, index_of(v, "Cold")), f32(0))
		clear_nav(&app) // frees heat_root
	}
	push_menu(&app, "Change procedure", root)
	heat_set_root(&app, "Call", "From import", "core:sys/windows")
	v := current_view(&app)
	v.index = index_of(v, "Leaf")
	heat_record_select(&app, v.entries[v.index])
	testing.expect_value(t, count(&h, "Call"), 1)
	testing.expect_value(t, count(&h, "Call", "From import", "core:sys/windows"), 1)
	testing.expect_value(t, count(&h, "Call", "From import", "core:sys/windows", "Leaf"), 3)
	testing.expect_value(t, count(&h, "Leaf"), 0)
}

@(test)
test_heat_merge_with_file :: proc(t: ^testing.T) {
	h: Heat
	defer heat_free(&h)
	app: App
	defer cleanup(&app)
	app.heat = &h
	// Loaded at startup: A 5.
	heat_parse("doodle-heat 1\n5\tA\n", &h)
	testing.expect_value(t, len(h.pending), 0)
	root := make_slice(Entry{label = "A", fill = "__lit_true__"}, Entry{label = "B", fill = "__lit_true__"})
	defer free_entries(root)
	push_menu(&app, "Root", root)
	v := current_view(&app)
	v.index = 0
	heat_record_select(&app, v.entries[0])
	v.index = 1
	heat_record_select(&app, v.entries[1])
	testing.expect_value(t, count(&h, "A"), 6)
	// Meanwhile another Doodle saved A 7 and C 2.
	merged := heat_merged(&h, "doodle-heat 1\n7\tA\n2\tC\n")
	testing.expect_value(t, count(&merged, "A"), 8)
	testing.expect_value(t, count(&merged, "B"), 1)
	testing.expect_value(t, count(&merged, "C"), 2)
	testing.expect_value(t, count(&h, "A"), 6) // unchanged until saved
	heat_adopt(&h, &merged)
	testing.expect_value(t, count(&h, "A"), 8)
	testing.expect_value(t, count(&h, "C"), 2)
	testing.expect_value(t, len(h.pending), 0)
	testing.expect(t, !h.dirty)
	testing.expect_value(t, len(merged.counts), 0)
	// A save that failed keeps the pending uses: merging again adds them once.
	heat_record_select(&app, v.entries[1])
	again := heat_merged(&h, "doodle-heat 1\n8\tA\n1\tB\n2\tC\n")
	defer heat_free(&again)
	testing.expect_value(t, count(&again, "B"), 2)
	testing.expect_value(t, len(h.pending), 1)

	testing.expect(t, heat_text_ok(""))
	testing.expect(t, heat_text_ok("doodle-heat 1\r\n3\tA\n"))
	testing.expect(t, !heat_text_ok("doodle-heat 2\n3\tA\n"), "a newer format isn't overwritten")
}

// Fill the value dot of line ni expecting `hint` (in `pkg`), then Convert > T(x).
@(private = "file")
open_convert :: proc(t: ^testing.T, app: ^App, ni: int, hint, pkg: string) {
	for &f, i in app.doc.nodes[ni].fields {
		if f.slot && f.kind == "value" {
			f.hint, f.hint_pkg = hint, pkg
			focus_field_index(app, ni, i)
			break
		}
	}
	update(app, Input{confirm = true})
	pick(t, app, "Convert")
	pick(t, app, "T(x)")
}

@(test)
test_heat_convert_pins_wear_type_home :: proc(t: ^testing.T) {
	h: Heat
	defer heat_free(&h)
	// Where HWND lives in the Type menu of a project that doesn't use it.
	infos := types_info_for_path("core:sys/windows")
	defer delete(infos)
	tree := build_proc_hierarchy("win", infos)
	defer free_entries(tree)
	home := make([dynamic]string, 0, 8, context.temp_allocator)
	if !testing.expect(t, path_to(tree, "HWND", "", &home), "HWND in the full grouping") do return
	for &s in home do s = strings.clone(s, context.temp_allocator)
	canon := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&canon, "Convert", "T(x)", "core:sys/windows")
	append(&canon, ..home[:])

	// HWND is used in this file: pinned inside win32. (and left out of its groups).
	{
		app: App
		defer cleanup(&app)
		app.heat = &h
		ni := setup(&app, "win32", "\th: win32.HWND\n")
		open_convert(t, &app, ni, "", "")
		pick(t, &app, "win32.")
		v := current_view(&app)
		i := index_of(v, "HWND")
		if !testing.expect(t, i >= 0 && v.entries[i].pinned, "HWND should be pinned") do return
		pick(t, &app, "HWND")
		testing.expect_value(t, count(&h, "Convert", "T(x)", "core:sys/windows", "HWND"), 1)
		testing.expect_value(t, h.counts[heat_key_of(canon[:])] or_else 0, 1)
	}
	// The expected type, pinned at the top of T(x) as `windows.HWND` (also used here).
	{
		app: App
		defer cleanup(&app)
		app.heat = &h
		ni := setup(&app, "windows", "\th: windows.HWND\n")
		open_convert(t, &app, ni, "HWND", "core:sys/windows")
		v := current_view(&app)
		i := index_of(v, "windows.HWND")
		if !testing.expect(t, i >= 0 && v.entries[i].pinned, "the expected type should be pinned") do return
		testing.expect_value(t, entry_heat_id(v.entries[i]), "core:sys/windows.HWND") // not the alias
		pick(t, &app, "windows.HWND")
		testing.expect_value(t, count(&h, "Convert", "T(x)", "core:sys/windows.HWND"), 1)
		testing.expect_value(t, h.counts[heat_key_of(canon[:])] or_else 0, 2) // the same home, from both
	}
}

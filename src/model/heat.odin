package model

// The global menu heatmap: every time a menu leaf is actually used (WM_SIZE
// inserted, a loop added, ...), each menu on the way to it gets a little more
// "worn". The radial menu draws worn cells with a darker, smudged border, so
// the trail to things you used before stands out in huge packages, in any
// project. The store is global: the app layer loads it from / saves it next to
// doodle.exe (src/app/heat_store.odin); App.heat is nil in tests (no-op).
//
// Keys: the chain of entries chosen from the root view's chosen entry down to
// the cell (the root view's TITLE is not part of it, so "Fill slot > Type" and
// "Edit Type > Type" share heat). A segment is entry_heat_id: Entry.heat_key
// (an import group's import path, so `win.` and `windows.` share heat) or the
// label. In memory segments are joined by HEAT_SEP; in the file by tabs.
//
// File format (heat_serialize / heat_parse):
//   doodle-heat 1
//   <count>\t<seg1>\t<seg2>...      one line per key, keys sorted

import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

Heat :: struct {
	counts:  map[string]int, // key (segments joined by HEAT_SEP) -> uses; keys owned
	pending: map[string]int, // this session's uses not saved yet (merged into the file on save); keys owned
	dirty:   bool,           // changed since the last save (the app layer saves it)
}

HEAT_SEP       :: "\x1f"   // in-memory segment separator (can't appear in a sanitized segment)
HEAT_HEADER    :: "doodle-heat 1"
HEAT_SATURATE  :: 40       // uses at which a cell looks fully worn
HEAT_MAX_KEYS  :: 20000    // heat_merged: what to save: the file's counts as they are now (`disk`, maybe
// written by another Doodle meanwhile) plus this session's unsaved uses, pruned
// to HEAT_MAX_KEYS. h is unchanged; caller frees the result (or heat_adopt's it).
heat_merged :: proc(h: ^Heat, disk: string) -> Heat {
	m: Heat
	heat_parse(disk, &m)
	if h != nil do for k, c in h.pending do heat_add(&m, k, c)
	heat_prune(&m, HEAT_MAX_KEYS)
	m.dirty = false
	return m
}

// heat_adopt (after the merged counts were saved): h takes merged's counts and
// forgets its pending uses (they're in the file now). merged is emptied.
heat_adopt :: proc(h: ^Heat, merged: ^Heat) {
	if h == nil || merged == nil do return
	for k in h.counts do delete(k)
	delete(h.counts)
	for k in h.pending do delete(k)
	delete(h.pending)
	h.counts, h.pending, h.dirty = merged.counts, nil, false
	for k in merged.pending do delete(k)
	delete(merged.pending)
	merged^ = {}
}

// heat_text_ok: can the app save over a heat file with this text? Not when it
// is another (newer) version of the format.
heat_text_ok :: proc(text: string) -> bool {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" do continue
		return !strings.has_prefix(l, "doodle-heat") || l == HEAT_HEADER
	}
	return true
}

// heat_prune keeps the most-used keys beyond this (on save)

// heat_free releases a heat store's keys and map.
heat_free :: proc(h: ^Heat) {
	if h == nil do return
	for k in h.counts do delete(k)
	delete(h.counts)
	for k in h.pending do delete(k)
	delete(h.pending)
	h^ = {}
}

// heat_shade: how worn a cell with `count` uses looks, 0 (unused) .. 1 (HEAT_SATURATE+ uses).
heat_shade :: proc(count: int) -> f32 {
	if count <= 0 do return 0
	s := math.ln(1 + f64(count)) / math.ln(1 + f64(HEAT_SATURATE))
	return f32(clamp(s, 0, 1))
}

// A label / heat_key as a key segment: tabs, newlines and HEAT_SEP become spaces.
heat_segment :: proc(s: string) -> string {
	if strings.index_any(s, "\t\r\n\x1f") < 0 do return s
	b := make([]u8, len(s), context.temp_allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		b[i] = (c == '\t' || c == '\r' || c == '\n' || c == 0x1f) ? ' ' : c
	}
	return string(b)
}

// entry_heat_id: an entry's segment in heat keys (stable across projects).
entry_heat_id :: proc(e: Entry) -> string {
	return heat_segment(e.heat_key != "" ? e.heat_key : e.label)
}

// heat_key_of joins segments into a key (temp-allocated).
heat_key_of :: proc(segs: []string) -> string {
	return strings.join(segs, HEAT_SEP, context.temp_allocator)
}

// heat_count: the uses recorded for a path of segments.
heat_count :: proc(h: ^Heat, segs: []string) -> int {
	if h == nil do return 0
	return h.counts[heat_key_of(segs)] or_else 0
}

// heat_add adds n uses to a key (cloned when new).
heat_add :: proc(h: ^Heat, key: string, n: int) {
	if h == nil do return
	heat_add_to(&h.counts, key, n)
}

@(private = "file")
heat_add_to :: proc(m: ^map[string]int, key: string, n: int) {
	if n <= 0 || key == "" do return
	if p, ok := &m[key]; ok {
		p^ += n
	} else {
		m[strings.clone(key)] = n
	}
}

// heat_bump_prefixes adds one use to every prefix of segs (depth 1..len), each
// key at most once per commit (`done` holds keys already bumped; temp keys).
heat_bump_prefixes :: proc(h: ^Heat, segs: []string, done: ^map[string]bool) {
	for d in 1 ..= len(segs) {
		key := heat_key_of(segs[:d])
		if key in done do continue
		done[key] = true
		heat_add(h, key, 1)
		if h != nil do heat_add_to(&h.pending, key, 1) // for the merge on save
	}
}

// heat_view_shades: the shade of each entry of a view about to be pushed on top
// of `parents` (nil when there is no heat). Caller owns the result.
heat_view_shades :: proc(app: ^App, parents: []MenuView, entries: []Entry) -> []f32 {
	h := app.heat
	if h == nil || len(h.counts) == 0 || len(entries) == 0 do return nil
	b := strings.builder_make(context.temp_allocator)
	if len(app.nav) > 0 do strings.write_string(&b, app.nav[0].heat_root)
	for p in parents {
		if p.index < 0 || p.index >= len(p.entries) do return nil
		strings.write_string(&b, entry_heat_id(p.entries[p.index]))
		strings.write_string(&b, HEAT_SEP)
	}
	plen := strings.builder_len(b)
	out: []f32
	for e, i in entries {
		resize(&b.buf, plen)
		strings.write_string(&b, entry_heat_id(e))
		c := h.counts[strings.to_string(b)] or_else 0
		if c <= 0 do continue
		if out == nil do out = make([]f32, len(entries))
		out[i] = heat_shade(c)
	}
	return out
}

// view_shade: the wear of entry i of a view (0 = none).
view_shade :: proc(v: ^MenuView, i: int) -> f32 {
	if v == nil || i < 0 || i >= len(v.heat) do return 0
	return v.heat[i]
}

// heat_refresh_views recomputes the shades of every open view (after a use).
heat_refresh_views :: proc(app: ^App) {
	for k in 0 ..< len(app.nav) {
		delete(app.nav[k].heat)
		app.nav[k].heat = heat_view_shades(app, app.nav[:k], app.nav[k].entries)
	}
}

// heat_is_action: selecting e does something (not a submenu, a placeholder, a
// keypad key, the Convert form expansion, or a grayed option its menu refuses).
// Menus whose labels are this document's names ("Pass as", "Rename all uses?",
// comment words) aren't recorded. (Leaves grayed by type fitting still work when
// picked, so they still count.)
heat_is_action :: proc(app: ^App, e: Entry) -> bool {
	if app.ref_pass_active || app.rename_active do return false
	if len(e.children) > 0 do return false
	// ctrl_menu_choose / loop_option_choose / branch_fill: "not possible here", the menu stays open.
	if e.dim && (app.ctrl_menu != .None || e.fill == CTRL_MENU_FILL || e.fill == LOOP_OPT_FILL || e.fill == BR_OPT_FILL) do return false
	switch e.fill {
	case CONV_FORM_FILL, NUM_KEY_FILL, REF_AS_FILL, RENAME_FILL, INDEX_FILL:
		return false
	case TXT_FILL:
		return e.call_name == "case" || e.call_name == "esc" // not "wcase:<i>" / "tick:<i>:<j>" (comment words)
	}
	return e.format || e.key_layout || e.quit || e.keyword != "" || e.proc_outline || e.type_construct != "" ||
		e.value_construct != "" || e.special != "" || e.import_path != "" || e.insert != "" || e.fill != ""
}

// heat_record_select (model.odin menu_select, before anything changes): e, the
// selected entry of the top view, is being used. Every prefix of the walked path
// gets one use; a pinned "used in this file" shortcut also wears its canonical
// home (win. > window_messages > WM_ > WM_SIZE), the trail other projects show.
heat_record_select :: proc(app: ^App, e: Entry) {
	h := app.heat
	if h == nil || len(app.nav) == 0 || !heat_is_action(app, e) do return
	segs := make([dynamic]string, 0, len(app.nav) + 4, context.temp_allocator)
	if root := app.nav[0].heat_root; root != "" {
		for s in strings.split(strings.trim_suffix(root, HEAT_SEP), HEAT_SEP, context.temp_allocator) do append(&segs, s)
	}
	for v in app.nav {
		if v.index < 0 || v.index >= len(v.entries) do return
		append(&segs, entry_heat_id(v.entries[v.index]))
	}
	done := make(map[string]bool, 16, context.temp_allocator)
	heat_bump_prefixes(h, segs[:], &done)
	if e.pinned {
		if sub, ok := heat_canonical(app, e); ok {
			canon := make([dynamic]string, 0, len(segs) + len(sub), context.temp_allocator)
			append(&canon, ..segs[:len(segs) - 1])
			append(&canon, ..sub)
			heat_bump_prefixes(h, canon[:], &done)
		}
	}
	h.dirty = true
	heat_refresh_views(app)
}

// ---- The canonical home of a pinned leaf ----

// The qualified name a leaf inserts (`win.MB_OK`), "" for leaves without one.
@(private = "file")
heat_qual :: proc(e: Entry) -> string {
	if e.call_name == "" do return ""
	if e.call_pkg == "" do return e.call_name
	return strings.concatenate({e.call_pkg, ".", e.call_name}, context.temp_allocator)
}

// Is b (a non-pinned leaf) the same item as the pinned leaf a?
@(private = "file")
heat_same_leaf :: proc(a, b: Entry) -> bool {
	if len(b.children) > 0 || b.pinned || a.fill != b.fill do return false
	qa, qb := heat_qual(a), heat_qual(b)
	if qa != "" || qb != "" do return qa == qb
	return a.label == b.label
}

// Depth-first: the segments from `entries` down to the first leaf that is the
// same item as `target` (or, when `name` is set, the first leaf labeled `name`).
@(private = "file")
heat_find :: proc(entries: []Entry, target: Entry, name: string, out: ^[dynamic]string) -> bool {
	for x in entries {
		if x.pinned do continue
		append(out, entry_heat_id(x))
		if len(x.children) > 0 {
			if heat_find(x.children, target, name, out) do return true
		} else if name != "" {
			if x.label == name do return true
		} else if heat_same_leaf(target, x) {
			return true
		}
		pop(out)
	}
	return false
}

// heat_canonical: the path (from the top view) to the non-pinned copy of the
// pinned leaf e. First the top view's own groups (struct literal types, a
// conversion's expected type); then, for an import's procs / constants / types
// (whose used names are left out of the grouping; Convert's type lists too),
// the package's full grouping, which is what every project shows.
heat_canonical :: proc(app: ^App, e: Entry) -> ([]string, bool) {
	v := current_view(app)
	if v == nil do return nil, false
	out := make([dynamic]string, 0, 8, context.temp_allocator)
	if heat_find(v.entries, e, "", &out) do return out[:], true

	// The package and the name in it.
	path, name, lead := "", e.call_name, ""
	if e.heat_key != "" {
		// An alias-qualified pin (heat_key "<import path>.<Name>": Convert's expected
		// type): its home is under the package's group in this same view.
		for x in v.entries {
			k := x.heat_key
			if k == "" || len(x.children) == 0 || len(e.heat_key) <= len(k) + 1 do continue
			if strings.has_prefix(e.heat_key, k) && e.heat_key[len(k)] == '.' {
				path, name, lead = k, e.heat_key[len(k) + 1:], entry_heat_id(x)
				break
			}
		}
	} else {
		// A pin inside a package's group: the group (the parent view's choice) names it.
		top := len(app.nav) - 1
		if top >= 1 {
			p := app.nav[top - 1]
			if p.index >= 0 && p.index < len(p.entries) do path = p.entries[p.index].heat_key
		}
		if path == "" do path = e.ret_pkg
	}
	if path == "" do return nil, false
	infos: []CoreProc
	switch e.fill {
	case "__call_import_proc__": infos = procs_info_for_path(path)
	case CONST_IMPORT_FILL:      infos = consts_info_for_path(path)
	case TYPE_IMPORT_FILL:       infos = types_info_for_path(path)
	case CONV_FILL:
		// A Type-menu leaf turned into a conversion: call_name is the written type (`win32.HWND`).
		infos = types_info_for_path(path)
		if i := strings.last_index_byte(name, '.'); i >= 0 do name = name[i + 1:]
	case:
		return nil, false
	}
	defer delete(infos)
	if name == "" do return nil, false
	tree := build_proc_hierarchy("", infos)
	defer free_entries(tree)
	clear(&out)
	if lead != "" do append(&out, lead)
	if heat_find(tree, e, name, &out) {
		// The segments are labels of `tree`: copy them before it is freed.
		for &s in out do s = strings.clone(s, context.temp_allocator)
		return out[:], true
	}
	return nil, false
}

// heat_set_root: the heat path above the root view's entries for a menu whose
// root is a deeper menu reached another way ("Change procedure" lists one
// import's procs: Call > From import > <path>), so both share heat.
heat_set_root :: proc(app: ^App, segs: ..string) {
	if len(app.nav) == 0 do return
	b := strings.builder_make()
	for s in segs {
		strings.write_string(&b, heat_segment(s))
		strings.write_string(&b, HEAT_SEP)
	}
	v := &app.nav[0]
	delete(v.heat_root)
	v.heat_root = strings.to_string(b)
	heat_refresh_views(app)
}

// ---- Saving / loading (pure: strings in, strings out) ----

// heat_serialize: the file text, keys sorted (stable diffs).
heat_serialize :: proc(h: ^Heat, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, HEAT_HEADER)
	strings.write_byte(&b, '\n')
	if h == nil do return strings.to_string(b)
	keys := make([dynamic]string, 0, len(h.counts), context.temp_allocator)
	for k, c in h.counts do if c > 0 do append(&keys, k)
	slice.sort(keys[:])
	for k in keys {
		strings.write_int(&b, h.counts[k])
		strings.write_byte(&b, '\t')
		for i in 0 ..< len(k) {
			c := k[i]
			strings.write_byte(&b, c == 0x1f ? '\t' : c)
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// heat_parse adds the counts in `text` to h (duplicates are summed). Lines that
// aren't `<count>\t<segments>` with a positive count are ignored. Returns the
// number of lines used.
heat_parse :: proc(text: string, h: ^Heat) -> int {
	if h == nil do return 0
	n := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_right(line, "\r")
		if l == "" || strings.has_prefix(l, "doodle-heat") do continue
		tab := strings.index_byte(l, '\t')
		if tab <= 0 do continue
		count, ok := strconv.parse_int(l[:tab], 10)
		if !ok || count <= 0 do continue
		segs := l[tab + 1:]
		if strings.trim_space(segs) == "" do continue
		key, _ := strings.replace_all(segs, "\t", HEAT_SEP, context.temp_allocator)
		heat_add(h, key, count)
		n += 1
	}
	return n
}

// heat_prune keeps the max_keys most-used keys (ties: alphabetical). A path's
// prefixes have at least its count, so trails are dropped leaf-first.
heat_prune :: proc(h: ^Heat, max_keys: int) {
	if h == nil || len(h.counts) <= max_keys do return
	Kc :: struct { k: string, c: int }
	all := make([dynamic]Kc, 0, len(h.counts), context.temp_allocator)
	for k, c in h.counts do append(&all, Kc{k, c})
	slice.sort_by(all[:], proc(a, b: Kc) -> bool { return a.c != b.c ? a.c > b.c : a.k < b.k })
	for x in all[max(max_keys, 0):] {
		stored, _ := delete_key(&h.counts, x.k)
		delete(stored)
	}
	h.dirty = true
}

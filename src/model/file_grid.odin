package model

// FILE GRID: the model behind file navigation (src/app/filenav.odin).
//
// The view is one folder V. Its columns, left to right: a "here" column with V's
// own files (when it has some, has no subfolders at all, or showed it before this
// rebuild of the same view), then one column
// per subfolder of V, each listing that subfolder's files and then its own
// subfolders as closed boxes. Rows line up across columns, so the cursor moves
// like on a grid while it stays clear which files belong to which folder.
// A on a box drops the view into its column's folder: the box and its sister
// folders become the columns. Nothing here knows the window size, so a move
// comes out the same at any size (and a recorded trace replays the same).

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// One directory entry, as a lister returns it (temp-allocated).
Fgrid_Entry :: struct {
	name, path: string,
	is_dir:     bool,
}

// Lists a folder's direct children (temp-allocated); ok=false if it can't be read.
// Tests pass a fake one, so the grid logic never touches the disk there.
Fgrid_Lister :: #type proc(dir: string) -> (entries: []Fgrid_Entry, ok: bool)

// One cell (strings owned by the grid).
Fgrid_Item :: struct {
	name, path: string,
	is_dir:     bool,
}

// One column: a folder's files A-Z, then its subfolders A-Z.
Fgrid_Group :: struct {
	title, path: string, // owned; path = the folder this column shows
	here:        bool,   // V's own files (the raised top-left tab)
	unreadable:  bool,
	items:       [dynamic]Fgrid_Item,
	more:        int,    // items cut off by FGRID_MAX_ITEMS
}

File_Grid :: struct {
	view:        string, // owned
	groups:      [dynamic]Fgrid_Group,
	more_groups: int,    // subfolders past FGRID_MAX_GROUPS
	group, item: int,    // item -1 = the column's tab
	want_row:    int,    // the row to come back to after passing a shorter column; -1 = the tab row
	descents:    int,    // A-descents this session (B pops them)
}

Fgrid_Dir  :: enum { Up, Down, Left, Right }
Fgrid_Move :: enum { None, Moved, Up_Level }

// Caps keep a rebuild to at most 1 + FGRID_MAX_GROUPS folder reads, even at a
// huge folder like a home directory.
FGRID_MAX_ITEMS  :: 400
FGRID_MAX_GROUPS :: 200

// --- Paths ---

// A path for comparisons (temp): forward slashes, lower case, no trailing slash.
// Same rules as filenav's norm_path (Windows is case-insensitive).
fgrid_norm :: proc(p: string) -> string {
	s, _ := strings.replace_all(p, "\\", "/", context.temp_allocator)
	return strings.to_lower(strings.trim_right(s, "/"), context.temp_allocator)
}

fgrid_same :: proc(a, b: string) -> bool { return fgrid_norm(a) == fgrid_norm(b) }

// Is `p` strictly inside `dir`?
fgrid_under :: proc(p, dir: string) -> bool {
	return strings.has_prefix(fgrid_norm(p), strings.concatenate({fgrid_norm(dir), "/"}, context.temp_allocator))
}

// A folder's display name. filepath.base of a drive root ("C:/") or of a path
// with a trailing slash is empty, so trim first and fall back to the path ("C:").
fgrid_title :: proc(p: string) -> string {
	t := strings.trim_right(p, "/\\")
	if t == "" do return "/"
	b := filepath.base(t)
	return b == "" || b == "." ? t : b
}

// fgrid_project_root: the project folder holding `file` - the first folder under
// `projects` on its path - so file navigation opens on the whole project, not just
// the file's own folder. ok=false when the file isn't inside a project folder.
fgrid_project_root :: proc(file, projects: string) -> (root: string, ok: bool) {
	if file == "" || projects == "" || !fgrid_under(file, projects) do return "", false
	d := filepath.dir(file)
	if fgrid_same(d, projects) do return "", false // loose in the projects folder
	for _ in 0 ..< 64 {
		p, up := fgrid_parent_of(d)
		if !up do return "", false
		if fgrid_same(p, projects) do return d, true
		d = p
	}
	return "", false
}

// The parent folder; ok=false at the top. os.dir cycles on a relative path
// ("r" -> "" -> "." -> ""), so "" and "." count as the top too.
fgrid_parent_of :: proc(p: string) -> (string, bool) {
	q := filepath.dir(p)
	if q == "" || q == "." || fgrid_same(q, p) do return "", false
	return q, true
}

// The real lister. Hidden (".") entries are skipped, as the old tree did.
fgrid_list_disk :: proc(dir: string) -> ([]Fgrid_Entry, bool) {
	fis, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return nil, false
	out := make([dynamic]Fgrid_Entry, 0, len(fis), context.temp_allocator)
	for fi in fis {
		if strings.has_prefix(fi.name, ".") do continue
		append(&out, Fgrid_Entry{fi.name, fi.fullpath, fi.type == .Directory})
	}
	return out[:], true
}

// Files first, then folders, each A-Z. Ties after lower-casing ("A.odin" and
// "a.odin" on Linux) break on the raw name, so the order never depends on luck.
@(private = "file")
sort_entries :: proc(es: []Fgrid_Entry) {
	slice.sort_by(es, proc(a, b: Fgrid_Entry) -> bool {
		if a.is_dir != b.is_dir do return !a.is_dir
		la, lb := strings.to_lower(a.name, context.temp_allocator), strings.to_lower(b.name, context.temp_allocator)
		if la != lb do return la < lb
		return a.name < b.name
	})
}

@(private = "file")
add_item :: proc(grp: ^Fgrid_Group, e: Fgrid_Entry) {
	if len(grp.items) >= FGRID_MAX_ITEMS {
		grp.more += 1
		return
	}
	append(&grp.items, Fgrid_Item{strings.clone(e.name), strings.clone(e.path), e.is_dir})
}

// --- Lifetime ---

// fgrid_clear frees the columns; the view and the cursor stay.
fgrid_clear :: proc(g: ^File_Grid) {
	for &grp in g.groups {
		for it in grp.items {
			delete(it.name)
			delete(it.path)
		}
		delete(grp.items)
		delete(grp.title)
		delete(grp.path)
	}
	clear(&g.groups)
	g.more_groups = 0
}

fgrid_destroy :: proc(g: ^File_Grid) {
	fgrid_clear(g)
	delete(g.groups)
	delete(g.view)
	g^ = {}
}

// fgrid_build rebuilds the columns for `view` (which may alias g.view). If the
// view can't be read (deleted, say), it climbs to the nearest readable folder.
// The cursor is clamped, not re-selected: callers pick what to select.
fgrid_build :: proc(g: ^File_Grid, view: string, list: Fgrid_Lister) {
	v := strings.clone(view, context.temp_allocator)
	top, ok := list(v)
	for i := 0; !ok && i < 64; i += 1 {
		p, up := fgrid_parent_of(v)
		if !up do break
		v = p
		top, ok = list(v)
	}
	// A rebuild of the same view keeps its "here" column even once its last file is
	// gone (deleted, renamed away): X on that tab is how you make a file in V.
	had_here := len(g.groups) > 0 && g.groups[0].here && fgrid_same(g.view, v)
	fgrid_clear(g)
	delete(g.view)
	g.view = strings.clone(v)
	sort_entries(top)
	nfiles := 0
	for e in top do if !e.is_dir do nfiles += 1
	ndirs := len(top) - nfiles
	// Without the "here" column a flat project's own files could never be reached.
	if nfiles > 0 || ndirs == 0 || had_here {
		grp := Fgrid_Group{title = strings.clone(fgrid_title(v)), path = strings.clone(v), here = true, unreadable = !ok}
		for e in top[:nfiles] do add_item(&grp, e)
		append(&g.groups, grp)
	}
	for e, i in top[nfiles:] {
		if i >= FGRID_MAX_GROUPS {
			g.more_groups = ndirs - FGRID_MAX_GROUPS
			break
		}
		grp := Fgrid_Group{title = strings.clone(e.name), path = strings.clone(e.path)}
		sub, sok := list(e.path)
		grp.unreadable = !sok
		sort_entries(sub)
		for s in sub do add_item(&grp, s)
		append(&g.groups, grp)
	}
	fgrid_clamp(g)
}

fgrid_clamp :: proc(g: ^File_Grid) {
	if len(g.groups) == 0 {
		g.group = 0
		g.item = -1
		return
	}
	g.group = clamp(g.group, 0, len(g.groups) - 1)
	g.item = clamp(g.item, -1, len(g.groups[g.group].items) - 1)
}

// --- Cursor ---

// fgrid_move: one D-pad step. Up/Down stay in the column (Up from row 0 = the
// tab); Left/Right keep the row (want_row) clamped to the next column's length.
// Passing an empty column parks the cursor on its tab but keeps want_row, so the
// next column with files gets the row back; only Up onto a tab (want_row -1)
// makes Left/Right walk the tab row. Left from the first column asks the caller
// to go up a level.
fgrid_move :: proc(g: ^File_Grid, dir: Fgrid_Dir) -> Fgrid_Move {
	if len(g.groups) == 0 do return dir == .Left ? .Up_Level : .None
	n := len(g.groups[g.group].items)
	switch dir {
	case .Up:
		if g.item < 0 do return .None
		g.item -= 1
		g.want_row = g.item
		return .Moved
	case .Down:
		if g.item < 0 {
			if n == 0 do return .None
			g.item = min(max(g.want_row, 0), n - 1)
			g.want_row = g.item
			return .Moved
		}
		if g.item + 1 >= n do return .None // a real grid: no wrap
		g.item += 1
		g.want_row = g.item
		return .Moved
	case .Left, .Right:
		t := g.group + (dir == .Left ? -1 : 1)
		if t < 0 do return .Up_Level
		if t >= len(g.groups) do return .None
		tn := len(g.groups[t].items)
		g.item = (g.want_row < 0 || tn == 0) ? -1 : min(g.want_row, tn - 1) // want_row is kept
		g.group = t
		return .Moved
	}
	return .None
}

// The highlighted cell or tab. A tab reads as a folder item for its column.
fgrid_selected :: proc(g: ^File_Grid) -> (it: Fgrid_Item, is_tab, is_here, ok: bool) {
	if len(g.groups) == 0 do return
	grp := g.groups[g.group]
	if g.item < 0 do return Fgrid_Item{grp.title, grp.path, true}, true, grp.here, true
	return grp.items[g.item], false, false, true
}

// Select `path`: a cell if one shows it, else a column tab. Cells win, so the
// "here" tab (which has the view's path) is only picked for the view itself.
fgrid_select_path :: proc(g: ^File_Grid, path: string) -> bool {
	want := fgrid_norm(path)
	for grp, gi in g.groups {
		for it, ii in grp.items {
			if fgrid_norm(it.path) == want {
				g.group, g.item, g.want_row = gi, ii, ii
				return true
			}
		}
	}
	for grp, gi in g.groups {
		if fgrid_norm(grp.path) == want {
			g.group, g.item, g.want_row = gi, -1, -1 // on the tab row; Down = the first item
			return true
		}
	}
	return false
}

// The cursor's position in reading order (tab, items, tab, items, ...): the
// index into filenav's flat g_fn_entries mirror.
fgrid_flat_index :: proc(g: ^File_Grid) -> int {
	if len(g.groups) == 0 do return 0
	k := 0
	for i in 0 ..< g.group do k += 1 + len(g.groups[i].items)
	return k + 1 + g.item
}

// --- Levels ---

// fgrid_descend: what A on the selection drops into. A box S in column G: view G
// (S and its sisters become the columns), focus S, then step onto S's first item.
// A tab G: view G - unless G can't be read: the rebuild would climb straight back
// to this view, and a descent that didn't happen must not be counted (B pops it).
// Returned strings alias grid memory: copy them before a rebuild.
fgrid_descend :: proc(g: ^File_Grid) -> (view, focus: string, focus_first: bool, ok: bool) {
	it, is_tab, is_here, sok := fgrid_selected(g)
	if !sok || is_here do return
	if is_tab {
		if g.groups[g.group].unreadable do return
		return g.groups[g.group].path, "", false, true
	}
	if !it.is_dir do return
	return g.groups[g.group].path, it.path, true, true
}

// fgrid_up: the parent view, with the focus on the tab of the folder we left.
fgrid_up :: proc(g: ^File_Grid) -> (view, focus: string, ok: bool) {
	p, up := fgrid_parent_of(g.view)
	return p, g.view, up
}

// The view that shows `file` as a cell: its folder's parent, so the file sits in
// its folder's column (or the root, for files in the root or outside it).
fgrid_view_for :: proc(file, root: string) -> string {
	if file == "" do return root
	d := filepath.dir(file)
	if fgrid_same(d, root) || !fgrid_under(d, root) do return root
	return filepath.dir(d)
}

// Where X puts a new file. box=true: inside a closed folder box, which needs a
// descent before the new file can be seen.
fgrid_target_dir :: proc(g: ^File_Grid) -> (dir: string, box: bool) {
	it, is_tab, _, ok := fgrid_selected(g)
	if !ok do return g.view, false
	if is_tab do return it.path, false // the "here" tab's path is the view
	if it.is_dir do return it.path, true
	return g.groups[g.group].path, false
}

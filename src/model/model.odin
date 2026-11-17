package model

// Pure application logic: state, document, menu navigation, insertion.
// NO dependencies on gpu/platform/text so it can be unit-tested with `odin test`.
// The app layer translates raw SDL events into `Input` and calls `update`.
// Contract/overview: docs/EDITOR_MODEL.md

State    :: enum { Menu, Editor, Radial }
MenuKind :: enum { Add, Ide }

GRID_COLS :: 3

MENU_ITEMS     := [?]string{"New Project", "Recent Projects", "Open Folder"}
ROOT_OPTS      := [?]string{"File Setup", "Dependencies", "Procedures", "Types", "Values"}
FILESETUP_OPTS := [?]string{"Package declaration", "File tags", "Comments"}
IDE_OPTS       := [?]string{"Exit"}

Doc :: struct {
	nodes: [dynamic]string, // each entry is an inserted Odin line/section
}

RadialMenu :: struct {
	kind:    MenuKind,
	title:   string,
	options: []string,
	index:   int,
	level:   int, // 0 = root, 1 = file-setup submenu
}

App :: struct {
	state:        State,
	menu_index:   int,
	doc:          Doc,
	radial:       RadialMenu,
	return_state: State,
	want_quit:    bool,
}

// One frame of abstract input: button edges (just-pressed) + trigger hold state.
Input :: struct {
	confirm, cancel:              bool,
	up, down, left, right:        bool,
	lt_held, rt_held:             bool,
}

// Which control bank is active: 0 = left (LT), 1 = middle (none), 2 = right (RT).
active_bank :: proc(inp: Input) -> int {
	if inp.lt_held do return 0
	if inp.rt_held do return 2
	return 1
}

insert_node :: proc(app: ^App, s: string) {
	append(&app.doc.nodes, s)
}

open_radial_root :: proc(app: ^App) {
	app.return_state = .Editor
	app.state = .Radial
	app.radial.kind = .Add
	app.radial.level = 0
	app.radial.index = 0
	app.radial.title = "Add  (insertion point)"
	app.radial.options = ROOT_OPTS[:]
}

open_ide_menu :: proc(app: ^App) {
	app.return_state = app.state
	app.state = .Radial
	app.radial.kind = .Ide
	app.radial.level = 0
	app.radial.index = 0
	app.radial.title = "IDE MENU"
	app.radial.options = IDE_OPTS[:]
}

radial_select :: proc(app: ^App) {
	if app.radial.kind == .Ide {
		switch app.radial.index {
		case 0: // Exit
			app.want_quit = true
		}
		return
	}
	if app.radial.level == 0 {
		switch app.radial.index {
		case 0: // File Setup -> submenu
			app.radial.level = 1
			app.radial.index = 0
			app.radial.title = "File Setup"
			app.radial.options = FILESETUP_OPTS[:]
		case:
			app.state = app.return_state // other branches not implemented yet
		}
	} else { // File Setup submenu
		switch app.radial.index {
		case 0: insert_node(app, "package main")  // Package declaration
		case 1: insert_node(app, "#+build linux") // File tags
		case 2: insert_node(app, "// comment")    // Comments
		}
		app.state = app.return_state
	}
}

update :: proc(app: ^App, inp: Input) {
	// Global binding: LT (left bank) + D-pad Left opens the IDE menu.
	if app.state != .Radial && active_bank(inp) == 0 && inp.left {
		open_ide_menu(app)
		return
	}

	switch app.state {
	case .Menu:
		n := len(MENU_ITEMS)
		if inp.up   do app.menu_index = (app.menu_index + n - 1) %% n
		if inp.down do app.menu_index = (app.menu_index + 1) %% n
		if inp.cancel do app.want_quit = true
		if inp.confirm {
			if app.menu_index == 0 { // New Project
				clear(&app.doc.nodes)
				app.state = .Editor
			}
			// Recent / Open Folder: not wired yet.
		}
	case .Editor:
		if inp.cancel  do app.state = .Menu
		if inp.confirm do open_radial_root(app)
	case .Radial:
		n := len(app.radial.options)
		cols := GRID_COLS
		if n < cols do cols = n
		if inp.right do app.radial.index = min(app.radial.index + 1, n - 1)
		if inp.left  do app.radial.index = max(app.radial.index - 1, 0)
		if inp.down && app.radial.index + cols < n do app.radial.index += cols
		if inp.up   && app.radial.index - cols >= 0 do app.radial.index -= cols
		if inp.cancel {
			if app.radial.kind == .Add && app.radial.level == 1 do open_radial_root(app)
			else do app.state = app.return_state
		}
		if inp.confirm do radial_select(app)
	}
}

package model

// Pure application logic: state, document, data-driven menu navigation.
// NO dependencies on gpu/platform/text so it can be unit-tested with `odin test`.
// Menu tree is `Entry` nodes; navigation is a stack of display views.
// Overview: docs/EDITOR_MODEL.md

import "core:slice"
import "core:strings"
import "core:fmt"

State :: enum { Menu, Editor, Radial }

GRID_COLS        :: 3
BUCKET_THRESHOLD :: 12
BUCKET_TARGET    :: 9

MENU_ITEMS := [?]string{"New Project", "Recent Projects", "Open Folder"}

// A menu entry. Exactly one behaviour applies:
//   children non-empty -> submenu
//   import_path set    -> inserts `import "<import_path>"`
//   insert set         -> inserts that literal text
//   keyword set        -> inserts `keyword <ident>`
//   proc_outline       -> inserts a procedure outline (3 nodes)
//   quit               -> exits the app
Entry :: struct {
	label:          string,
	insert:         string, // literal text (e.g. a comment)
	import_path:    string, // e.g. "core:fmt" -> inserts import statement
	keyword:        string, // e.g. "package" -> node = keyword + editable identifier
	ident_default:  string, // default identifier text for keyword leaves
	proc_outline:   bool,   // inserts procedure outline (3 nodes, 1 editable + 3 slots)
	type_construct: string, // "" = not a type; else "struct"/"enum"/"union"/"bit_set"/"distinct"/"alias"
	platform:       string, // "" = all; else comma list of ODIN_OS names
	dim:            bool,
	quit:           bool,
	children:       []Entry,
}

// A node is a line made of fields. Some fields are editable "slots" (identifiers),
// the rest are fixed keywords/punctuation. A field can also be a "slot" (a placeholder
// rendered as an orange dot, with empty text).
Field :: struct {
	text:     string,
	editable: bool,
	slot:     bool, // orange placeholder dot (params/return/body slots, etc.)
}
Node :: struct {
	fields: [dynamic]Field,
}
Doc :: struct {
	nodes: [dynamic]Node,
}

node_text :: proc(n: Node, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for f in n.fields do strings.write_string(&b, f.text)
	return strings.to_string(b)
}

MenuView :: struct {
	title:   string,
	entries: []Entry,         // display list (allocated)
	rest:    []Entry,         // backing for bucket children (allocated, or nil)
	labels:  [dynamic]string, // allocated bucket labels to free on pop
	index:   int,
}

App :: struct {
	state:          State,
	menu_index:     int,
	doc:            Doc,
	nav:            [dynamic]MenuView,
	return_state:   State,
	recent_imports: [dynamic]string, // import paths, most-recent first
	os_name:        string,
	want_quit:      bool,
	editor_line:    int, // index into doc.nodes; == len(nodes) => green insertion dot focused
	editor_field:   int, // selectable-field index within the current line (left/right)

	add_menu: []Entry, // built lazily per-app (no globals -> test-safe)
	ide_menu: []Entry,
}

Input :: struct {
	confirm, cancel:       bool,
	up, down, left, right: bool,
	lt_held, rt_held:      bool,
}

// ---- Menus (built lazily per App) ----

ensure_menus :: proc(app: ^App) {
	if app.add_menu != nil do return
	core := build_core_tree()
	import_src := make_slice(grp("core", core))
	file_setup := make_slice(
		kw_leaf("Package declaration", "package", "main"),
		leaf("File tags", "#+build linux"),
		leaf("Comments", "// comment"),
		grp("Import", import_src),
	)
	procedures := make_slice(
		proc_leaf("Procedure"),
	)
	types := make_slice(
		type_leaf("Struct", "struct"),
		type_leaf("Enum", "enum"),
		type_leaf("Union", "union"),
		type_leaf("Bit set", "bit_set"),
		type_leaf("Distinct type", "distinct"),
		type_leaf("Type alias", "alias"),
	)
	app.add_menu = make_slice(
		grp("File Setup", file_setup),
		grp_dim("Dependencies"),
		grp("Procedures", procedures),
		grp("Types", types),
		grp_dim("Values"),
	)
	app.ide_menu = make_slice(Entry{label = "Exit", quit = true})
}

leaf      :: proc(label, insert: string) -> Entry { return Entry{label = label, insert = insert} }
grp       :: proc(label: string, children: []Entry) -> Entry { return Entry{label = label, children = children} }
grp_dim   :: proc(label: string) -> Entry { return Entry{label = label, dim = true} }
kw_leaf   :: proc(label, keyword, ident: string) -> Entry {
	return Entry{label = label, keyword = keyword, ident_default = ident}
}
proc_leaf :: proc(label: string) -> Entry { return Entry{label = label, proc_outline = true} }
type_leaf :: proc(label, kind: string) -> Entry { return Entry{label = label, type_construct = kind} }

make_slice :: proc(items: ..Entry) -> []Entry {
	s := make([]Entry, len(items))
	copy(s, items)
	return s
}

// Free a menu tree (child slices only; all strings are literals).
free_entries :: proc(entries: []Entry) {
	for e in entries do free_entries(e.children)
	if entries != nil do delete(entries)
}

free_menus :: proc(app: ^App) {
	if app.add_menu != nil { free_entries(app.add_menu); app.add_menu = nil }
	if app.ide_menu != nil { free_entries(app.ide_menu); app.ide_menu = nil }
}

// ---- Build the core tree from the generated flat rows ----

@(private = "file")
TNode :: struct { e: Entry, kids: [dynamic]^TNode }

build_core_tree :: proc() -> []Entry {
	roots: [dynamic]^TNode
	defer delete(roots)
	stack: [dynamic]^TNode
	defer delete(stack)

	for row in CORE_ROWS {
		n := new(TNode)
		n.e = Entry{label = row.label, import_path = row.path, platform = row.platform, dim = row.dim}
		if row.depth == 0 {
			append(&roots, n)
			clear(&stack)
			append(&stack, n)
		} else {
			parent := stack[row.depth - 1]
			append(&parent.kids, n)
			if len(stack) < row.depth + 1 do resize(&stack, row.depth + 1)
			stack[row.depth] = n
		}
	}
	return tnodes_to_entries(roots[:])
}

@(private = "file")
tnodes_to_entries :: proc(nodes: []^TNode) -> []Entry {
	if len(nodes) == 0 do return nil
	out := make([]Entry, len(nodes))
	for n, i in nodes {
		out[i] = n.e
		out[i].children = tnodes_to_entries(n.kids[:])
		delete(n.kids)
		free(n)
	}
	return out
}

// ---- Helpers ----

is_leaf :: proc(e: Entry) -> bool {
	return len(e.children) == 0 && (e.insert != "" || e.import_path != "" || e.keyword != "" || e.proc_outline || e.type_construct != "")
}

// Composed import statement for a leaf (uses the given allocator).
import_text :: proc(path: string, allocator := context.allocator) -> string {
	return strings.concatenate({"import \"", path, "\""}, allocator)
}

platform_ok :: proc(app: ^App, e: Entry) -> bool {
	if e.platform == "" do return true
	s := e.platform
	start := 0
	for i := 0; i <= len(s); i += 1 {
		if i == len(s) || s[i] == ',' {
			if s[start:i] == app.os_name do return true
			start = i + 1
		}
	}
	return false
}

is_imported :: proc(app: ^App, text: string) -> bool {
	for n in app.doc.nodes {
		t := node_text(n, context.temp_allocator)
		if t == text do return true
	}
	return false
}

is_recent :: proc(app: ^App, path: string) -> bool {
	for s in app.recent_imports do if s == path do return true
	return false
}

record_recent :: proc(app: ^App, path: string) {
	for s, i in app.recent_imports {
		if s == path { ordered_remove(&app.recent_imports, i); break }
	}
	inject_at(&app.recent_imports, 0, path)
}

// Append a single fixed (non-editable) line node.
append_text_node :: proc(app: ^App, text: string) {
	n: Node
	append(&n.fields, Field{strings.clone(text), false, false})
	append(&app.doc.nodes, n)
}

// Append `keyword <editable ident>` (e.g. package main).
append_kw_node :: proc(app: ^App, keyword, ident: string) {
	n: Node
	append(&n.fields, Field{strings.concatenate({keyword, " "}), false, false})
	append(&n.fields, Field{strings.clone(ident), true, false})
	append(&app.doc.nodes, n)
}

// Append a procedure outline (3 nodes: signature, body indent, closing brace).
// Name is editable; params/return/body are slots (orange dots).
append_proc_node :: proc(app: ^App, name := "do_thing") {
	// Line 1: <name> :: proc( <params> ) -> <ret> {
	n1: Node
	append(&n1.fields, Field{strings.clone(name), true, false})            // editable name
	append(&n1.fields, Field{strings.clone(" :: proc( "), false, false})  // fixed
	append(&n1.fields, Field{"", false, true})                             // params slot
	append(&n1.fields, Field{strings.clone(" ) -> "), false, false})      // fixed
	append(&n1.fields, Field{"", false, true})                             // return slot
	append(&n1.fields, Field{strings.clone(" {"), false, false})          // fixed
	append(&app.doc.nodes, n1)

	// Line 2: <indent><body>
	n2: Node
	append(&n2.fields, Field{strings.clone("    "), false, false})        // indent
	append(&n2.fields, Field{"", false, true})                             // body slot
	append(&app.doc.nodes, n2)

	// Line 3: }
	n3: Node
	append(&n3.fields, Field{strings.clone("}"), false, false})           // closing brace
	append(&app.doc.nodes, n3)
}

// Append type declaration nodes (struct/enum/union/bit_set/distinct/alias).
append_type_node :: proc(app: ^App, kind: string) {
	switch kind {
	case "struct":
		// Line 1: MyType :: struct {
		n1: Node
		append(&n1.fields, Field{strings.clone("MyType"), true, false})       // editable name
		append(&n1.fields, Field{strings.clone(" :: struct {"), false, false}) // fixed
		append(&app.doc.nodes, n1)
		// Line 2: <indent><body slot>
		n2: Node
		append(&n2.fields, Field{strings.clone("    "), false, false})         // indent
		append(&n2.fields, Field{"", false, true})                              // body slot
		append(&app.doc.nodes, n2)
		// Line 3: }
		n3: Node
		append(&n3.fields, Field{strings.clone("}"), false, false})            // closing brace
		append(&app.doc.nodes, n3)

	case "enum":
		// Line 1: MyType :: enum {
		n1: Node
		append(&n1.fields, Field{strings.clone("MyType"), true, false})       // editable name
		append(&n1.fields, Field{strings.clone(" :: enum {"), false, false})  // fixed
		append(&app.doc.nodes, n1)
		// Line 2: <indent><body slot>
		n2: Node
		append(&n2.fields, Field{strings.clone("    "), false, false})         // indent
		append(&n2.fields, Field{"", false, true})                              // body slot
		append(&app.doc.nodes, n2)
		// Line 3: }
		n3: Node
		append(&n3.fields, Field{strings.clone("}"), false, false})            // closing brace
		append(&app.doc.nodes, n3)

	case "union":
		// Line 1: MyType :: union {
		n1: Node
		append(&n1.fields, Field{strings.clone("MyType"), true, false})       // editable name
		append(&n1.fields, Field{strings.clone(" :: union {"), false, false}) // fixed
		append(&app.doc.nodes, n1)
		// Line 2: <indent><body slot>
		n2: Node
		append(&n2.fields, Field{strings.clone("    "), false, false})         // indent
		append(&n2.fields, Field{"", false, true})                              // body slot
		append(&app.doc.nodes, n2)
		// Line 3: }
		n3: Node
		append(&n3.fields, Field{strings.clone("}"), false, false})            // closing brace
		append(&app.doc.nodes, n3)

	case "bit_set":
		// Single line: MyType :: bit_set[•]
		n: Node
		append(&n.fields, Field{strings.clone("MyType"), true, false})        // editable name
		append(&n.fields, Field{strings.clone(" :: bit_set["), false, false}) // fixed
		append(&n.fields, Field{"", false, true})                               // element type slot
		append(&n.fields, Field{strings.clone("]"), false, false})             // fixed
		append(&app.doc.nodes, n)

	case "distinct":
		// Single line: MyType :: distinct •
		n: Node
		append(&n.fields, Field{strings.clone("MyType"), true, false})        // editable name
		append(&n.fields, Field{strings.clone(" :: distinct "), false, false}) // fixed
		append(&n.fields, Field{"", false, true})                               // base type slot
		append(&app.doc.nodes, n)

	case "alias":
		// Single line: MyType :: •
		n: Node
		append(&n.fields, Field{strings.clone("MyType"), true, false})        // editable name
		append(&n.fields, Field{strings.clone(" :: "), false, false})          // fixed
		append(&n.fields, Field{"", false, true})                               // type slot
		append(&app.doc.nodes, n)
	}
}

// Count selectable fields (editable identifiers + slots).
num_editable :: proc(app: ^App) -> int {
	c := 0
	for n in app.doc.nodes do for f in n.fields do if f.editable || f.slot do c += 1
	return c
}

// Resolve the current editor selection to a selectable field location (editable or slot).
// Count selectable (editable or slot) fields on one line.
selectable_in_node :: proc(app: ^App, ni: int) -> int {
	c := 0
	for f in app.doc.nodes[ni].fields do if f.editable || f.slot do c += 1
	return c
}

// Focus the green insertion dot (past the last line).
focus_dot :: proc(app: ^App) {
	app.editor_line = len(app.doc.nodes)
	app.editor_field = 0
}

clamp_field :: proc(app: ^App) {
	if app.editor_line < len(app.doc.nodes) {
		cnt := selectable_in_node(app, app.editor_line)
		app.editor_field = cnt <= 0 ? 0 : clamp(app.editor_field, 0, cnt - 1)
	} else {
		app.editor_field = 0
	}
}

// Move up/down between lines that have dots (green insertion dot is the bottom stop).
editor_move_line :: proc(app: ^App, dir: int) {
	nlines := len(app.doc.nodes)
	if dir < 0 {
		for i := app.editor_line - 1; i >= 0; i -= 1 {
			if selectable_in_node(app, i) > 0 {
				app.editor_line = i
				clamp_field(app)
				return
			}
		}
		// nothing above: stay put
	} else {
		for i := app.editor_line + 1; i < nlines; i += 1 {
			if selectable_in_node(app, i) > 0 {
				app.editor_line = i
				clamp_field(app)
				return
			}
		}
		focus_dot(app) // nothing below -> green insertion dot
	}
}

// The currently highlighted field: line `editor_line`, the `editor_field`-th
// selectable field on it. ok=false means the green insertion dot is focused.
editor_target :: proc(app: ^App) -> (ni: int, fi: int, ok: bool) {
	if app.editor_line < 0 || app.editor_line >= len(app.doc.nodes) do return 0, 0, false
	cnt := selectable_in_node(app, app.editor_line)
	if cnt == 0 do return 0, 0, false
	k := clamp(app.editor_field, 0, cnt - 1)
	idx := 0
	for f, f_i in app.doc.nodes[app.editor_line].fields {
		if f.editable || f.slot {
			if idx == k do return app.editor_line, f_i, true
			idx += 1
		}
	}
	return 0, 0, false
}

set_field_text :: proc(app: ^App, ni, fi: int, text: string) {
	delete(app.doc.nodes[ni].fields[fi].text)
	app.doc.nodes[ni].fields[fi].text = strings.clone(text)
}

// Common words to bias dictation toward (keywords + frequent identifiers).
COMMON_WORDS := [?]string{
	"main", "package", "proc", "struct", "enum", "union", "import", "return",
	"context", "string", "int", "bool", "true", "false", "append", "make",
	"delete", "len", "cap", "nil", "defer", "for", "player", "health", "update",
	"init", "index", "count", "value", "name", "result",
}

// Vocabulary for STT biasing: common words + identifiers already in the document.
// Returned slice is allocated (free it); its elements reference existing strings.
collect_vocab :: proc(app: ^App) -> []string {
	out: [dynamic]string
	for w in COMMON_WORDS do append(&out, w)
	for n in app.doc.nodes do for f in n.fields do if f.editable do append(&out, f.text)
	return out[:]
}

doc_reset :: proc(app: ^App) {
	for &n in app.doc.nodes {
		for f in n.fields {
			// Only delete non-empty text (slots have empty string literals)
			if len(f.text) > 0 do delete(f.text)
		}
		delete(n.fields)
	}
	clear(&app.doc.nodes)
	app.editor_line = 0
	app.editor_field = 0
}

active_bank :: proc(inp: Input) -> int {
	if inp.lt_held do return 0
	if inp.rt_held do return 2
	return 1
}

@(private = "file")
label_less :: proc(a, b: Entry) -> bool {
	return strings.to_lower(a.label, context.temp_allocator) < strings.to_lower(b.label, context.temp_allocator)
}

@(private = "file")
upper_byte :: proc(b: u8) -> u8 { return (b >= 'a' && b <= 'z') ? b - 32 : b }

// ---- Build a display view: platform filter -> usage-first -> bucket remainder ----

make_view :: proc(app: ^App, title: string, raw: []Entry) -> MenuView {
	v: MenuView
	v.title = title

	filtered: [dynamic]Entry
	defer delete(filtered)
	for e in raw do if platform_ok(app, e) do append(&filtered, e)

	display: [dynamic]Entry
	defer delete(display)
	seen := make(map[string]bool)
	defer delete(seen)

	// 1. Already-imported leaves first (original order).
	for e in filtered {
		if e.import_path != "" && is_imported(app, import_text(e.import_path, context.temp_allocator)) {
			append(&display, e)
			seen[e.import_path] = true
		}
	}
	// 2. Then recently-used leaves, in recency order.
	for path in app.recent_imports {
		for e in filtered {
			if e.import_path == path && !(e.import_path in seen) {
				append(&display, e)
				seen[e.import_path] = true
				break
			}
		}
	}
	// 3. Everything else (groups + remaining leaves), original order.
	other: [dynamic]Entry
	defer delete(other)
	for e in filtered {
		if e.import_path != "" && (e.import_path in seen) do continue
		append(&other, e)
	}

	if len(other) > BUCKET_THRESHOLD {
		v.rest = make([]Entry, len(other))
		copy(v.rest, other[:])
		slice.sort_by(v.rest, label_less)
		n := len(v.rest)
		k := (n + BUCKET_TARGET - 1) / BUCKET_TARGET
		if k < 2 do k = 2
		per := (n + k - 1) / k
		i := 0
		for i < n {
			j := min(i + per, n)
			lab := fmt.aprintf("%c-%c", upper_byte(v.rest[i].label[0]), upper_byte(v.rest[j - 1].label[0]))
			append(&v.labels, lab)
			append(&display, Entry{label = lab, children = v.rest[i:j]})
			i = j
		}
	} else {
		for e in other do append(&display, e)
	}

	v.entries = make([]Entry, len(display))
	copy(v.entries, display[:])
	return v
}

// ---- Navigation ----

push_menu :: proc(app: ^App, title: string, raw: []Entry) {
	append(&app.nav, make_view(app, title, raw))
}

pop_menu :: proc(app: ^App) {
	if len(app.nav) == 0 do return
	v := pop(&app.nav)
	delete(v.entries)
	if v.rest != nil do delete(v.rest)
	for s in v.labels do delete(s)
	delete(v.labels)
}

clear_nav :: proc(app: ^App) {
	for len(app.nav) > 0 do pop_menu(app)
}

open_add_menu :: proc(app: ^App) {
	ensure_menus(app)
	clear_nav(app)
	app.return_state = .Editor
	app.state = .Radial
	push_menu(app, "Add  (insertion point)", app.add_menu)
}

open_ide_menu :: proc(app: ^App) {
	ensure_menus(app)
	clear_nav(app)
	app.return_state = app.state
	app.state = .Radial
	push_menu(app, "IDE MENU", app.ide_menu)
}

current_view :: proc(app: ^App) -> ^MenuView {
	if len(app.nav) == 0 do return nil
	return &app.nav[len(app.nav) - 1]
}

menu_select :: proc(app: ^App) {
	v := current_view(app)
	if v == nil || len(v.entries) == 0 do return
	e := v.entries[v.index]
	if e.quit {
		app.want_quit = true
		return
	}
	if len(e.children) > 0 {
		push_menu(app, e.label, e.children)
		return
	}
	if e.keyword != "" {
		append_kw_node(app, e.keyword, e.ident_default)
	} else if e.proc_outline {
		append_proc_node(app)
	} else if e.type_construct != "" {
		append_type_node(app, e.type_construct)
	} else if e.import_path != "" {
		node := import_text(e.import_path, context.temp_allocator)
		append_text_node(app, node)
		record_recent(app, e.import_path)
	} else if e.insert != "" {
		append_text_node(app, e.insert)
	} else {
		return // placeholder, no-op
	}
	clear_nav(app)
	focus_dot(app) // keep the green dot focused after inserting
	app.state = app.return_state
}

menu_cancel :: proc(app: ^App) {
	pop_menu(app)
	if len(app.nav) == 0 do app.state = app.return_state
}

// ---- Top-level update ----

update :: proc(app: ^App, inp: Input) {
	// Global binding: LT (left bank) + D-pad Left opens the IDE menu.
	if app.state != .Radial && inp.lt_held && inp.left {
		open_ide_menu(app)
		return
	}

	switch app.state {
	case .Menu:
		n := len(MENU_ITEMS)
		if inp.up     do app.menu_index = (app.menu_index + n - 1) %% n
		if inp.down   do app.menu_index = (app.menu_index + 1) %% n
		if inp.cancel do app.want_quit = true
		if inp.confirm {
			if app.menu_index == 0 { // New Project
				doc_reset(app)
				app.state = .Editor
			}
		}
	case .Editor:
		nlines := len(app.doc.nodes)
		if app.editor_line > nlines do app.editor_line = nlines
		// Left/Right move between dots on the current line.
		if app.editor_line < nlines {
			cnt := selectable_in_node(app, app.editor_line)
			if cnt > 0 {
				if inp.left  do app.editor_field = max(0, app.editor_field - 1)
				if inp.right do app.editor_field = min(cnt - 1, app.editor_field + 1)
			}
		}
		// Up/Down move between lines (green insertion dot is the bottom stop).
		if inp.up   do editor_move_line(app, -1)
		if inp.down do editor_move_line(app, +1)
		if inp.cancel do app.state = .Menu
		if inp.confirm && app.editor_line >= nlines do open_add_menu(app) // A on the dot = Add menu
	case .Radial:
		v := current_view(app)
		n := len(v.entries)
		cols := GRID_COLS
		if n < cols do cols = n
		if n > 0 {
			if inp.right do v.index = min(v.index + 1, n - 1)
			if inp.left  do v.index = max(v.index - 1, 0)
			if inp.down && v.index + cols < n do v.index += cols
			if inp.up   && v.index - cols >= 0 do v.index -= cols
		}
		if inp.cancel  do menu_cancel(app)
		if inp.confirm do menu_select(app)
	}
}

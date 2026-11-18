package model

// Pure application logic: state, document, data-driven menu navigation.
// NO dependencies on gpu/platform/text so it can be unit-tested with `odin test`.
// Menu tree is `Entry` nodes; navigation is a stack of display views.
// Overview: docs/EDITOR_MODEL.md

import "core:slice"
import "core:strings"
import "core:fmt"

State :: enum { Menu, Editor, Radial }

GRID_COLS        :: 8  // max columns

// Columns for a menu of n entries: prefer a square-ish grid, capped at GRID_COLS.
grid_cols :: proc(n: int) -> int {
	if n <= 1 do return 1
	c := 1
	for c * c < n do c += 1
	if c > GRID_COLS do c = GRID_COLS
	return c
}

// Grid navigation with wrap-around at edges (shared by all grid menus).
grid_nav :: proc(index, n: int, inp: Input) -> int {
	if n <= 0 do return 0
	cols := grid_cols(n)
	idx := clamp(index, 0, n - 1)
	if inp.left {
		rs := (idx / cols) * cols
		re := min(rs + cols, n) - 1
		idx = idx == rs ? re : idx - 1
	}
	if inp.right {
		rs := (idx / cols) * cols
		re := min(rs + cols, n) - 1
		idx = idx == re ? rs : idx + 1
	}
	if inp.up {
		c := idx % cols
		cand := idx - cols
		if cand < 0 {
			last := c
			for last + cols < n do last += cols
			idx = last
		} else {
			idx = cand
		}
	}
	if inp.down {
		c := idx % cols
		cand := idx + cols
		idx = cand >= n ? c : cand
	}
	return idx
}
BUCKET_THRESHOLD :: 12
BUCKET_TARGET    :: 9
PAGE             :: 12  // Alpha-bucket page size
FLAT_MAX         :: 60  // Show a group flat (scrollable) up to this size; only split beyond it
MIN_PREFIX_SHARE :: 3   // Min procs sharing a prefix to form a group

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
	value_construct: string, // "" = not a value; else "const"/"typed_const"/"config"/"global_typed"/"global_init"
	platform:       string, // "" = all; else comma list of ODIN_OS names
	dim:            bool,
	quit:           bool,
	alias:          bool,   // if true, navigating this group sets import_alias mode
	fill:           string, // "" = none; type name = fill slot with type; "__var__" = instantiate variable
	call_name:      string, // proc or package name for call statements
	call_pkg:       string, // package name for import calls; "" for this-package calls
	owned_label:    bool,   // if true, label was cloned and should be freed
	children:       []Entry,
}

// A node is a line made of fields. Some fields are editable "slots" (identifiers),
// the rest are fixed keywords/punctuation. A field can also be a "slot" (a placeholder
// rendered as an orange dot, with empty text).
Field :: struct {
	text:     string,
	editable: bool,
	slot:     bool,   // orange placeholder dot (params/return/body slots, etc.)
	kind:     string, // only for slots: ""=generic, "params", "type", "value", "body"
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
	import_alias:   bool, // set when navigating aliased import tree
	insert_at:      int, // node index where new constructs are inserted (0=top, len=bottom)
	replacing:      bool, // if true, menu selection replaces the current item instead of inserting
	replace_ni:     int,     // node index being replaced
	replace_fi:     int,     // field index being replaced

	add_menu: []Entry, // built lazily per-app (no globals -> test-safe)
	ide_menu: []Entry,
	slot_menu: []Entry, // built on-demand for slot filling
	slot_ni:   int,     // node index of slot being filled
	slot_fi:   int,     // field index of slot being filled

	name_counter: int, // deterministic name generation counter
}

Input :: struct {
	confirm, cancel:       bool,
	up, down, left, right: bool,
	lt_held, rt_held:      bool,
}

// ---- Menus (built lazily per App) ----

ensure_menus :: proc(app: ^App) {
	if app.add_menu != nil do return
	// NOTE: build a SEPARATE core tree per branch. Sharing one slice would make
	// free_entries() free the same subtree twice (double free).
	import_src := make_slice(grp("core", build_core_tree()))
	file_setup := make_slice(
		kw_leaf("Package declaration", "package", "main"),
		leaf("File tags", "#+build linux"),
		leaf("Comments", "// comment"),
	)
	aliased_import_src := make_slice(grp("core", build_core_tree()))
	dependencies := make_slice(
		grp("Import", import_src),
		Entry{label = "Aliased import", alias = true, children = aliased_import_src},
		leaf("Foreign import", "foreign import libc \"system:c\""),
		leaf("Foreign block", "foreign libc { }"),
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
	values := make_slice(
		value_leaf("Constant", "const"),
		value_leaf("Typed constant", "typed_const"),
		value_leaf("Build-config constant", "config"),
		value_leaf("Global variable (typed)", "global_typed"),
		value_leaf("Global variable (init)", "global_init"),
	)
	app.add_menu = make_slice(
		grp("File Setup", file_setup),
		grp("Dependencies", dependencies),
		grp("Procedures", procedures),
		grp("Types", types),
		grp("Values", values),
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
value_leaf :: proc(label, kind: string) -> Entry { return Entry{label = label, value_construct = kind} }

make_slice :: proc(items: ..Entry) -> []Entry {
	s := make([]Entry, len(items))
	copy(s, items)
	return s
}

// Free a menu tree (child slices only; most strings are literals, but call_name/call_pkg are cloned).
free_entries :: proc(entries: []Entry) {
	for e in entries {
		// Free cloned strings
		if e.owned_label && len(e.label) > 0 do delete(e.label)
		if len(e.call_name) > 0 do delete(e.call_name)
		if len(e.call_pkg) > 0 do delete(e.call_pkg)
		free_entries(e.children)
	}
	if entries != nil do delete(entries)
}

free_menus :: proc(app: ^App) {
	if app.add_menu != nil { free_entries(app.add_menu); app.add_menu = nil }
	if app.ide_menu != nil { free_entries(app.ide_menu); app.ide_menu = nil }
	if app.slot_menu != nil { free_entries(app.slot_menu); app.slot_menu = nil }
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
	return len(e.children) == 0 && (e.insert != "" || e.import_path != "" || e.keyword != "" || e.proc_outline || e.type_construct != "" || e.value_construct != "" || e.fill != "")
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

// Insert a node at app.insert_at and increment insert_at.
doc_insert :: proc(app: ^App, n: Node) {
	if app.insert_at < 0 do app.insert_at = 0
	if app.insert_at > len(app.doc.nodes) do app.insert_at = len(app.doc.nodes)
	inject_at(&app.doc.nodes, app.insert_at, n)
	app.insert_at += 1
}

// Append a single fixed (non-editable) line node.
append_text_node :: proc(app: ^App, text: string) {
	n: Node
	append(&n.fields, Field{strings.clone(text), false, false, ""})
	doc_insert(app, n)
}

// Append `keyword <editable ident>` (e.g. package main).
append_kw_node :: proc(app: ^App, keyword, ident: string) {
	n: Node
	append(&n.fields, Field{strings.concatenate({keyword, " "}), false, false, ""})
	append(&n.fields, Field{strings.clone(ident), true, false, ""})
	doc_insert(app, n)
}

// Append an aliased import: `import <alias> "<path>"` with editable alias.
append_aliased_import_node :: proc(app: ^App, path: string) {
	n: Node
	append(&n.fields, Field{strings.clone("import "), false, false, ""})
	append(&n.fields, Field{strings.clone(alias_default(path)), true, false, ""})
	append(&n.fields, Field{strings.concatenate({" \"", path, "\""}), false, false, ""})
	doc_insert(app, n)
}

// Extract the default alias from an import path (the last segment).
alias_default :: proc(path: string) -> string {
	// Find the last '/' or the ':' if no '/'.
	last_slash := -1
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			last_slash = i
			break
		}
	}
	if last_slash >= 0 do return path[last_slash + 1:]
	// No '/', so look for ':'
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == ':' do return path[i + 1:]
	}
	return path
}

// Append a procedure outline (3 nodes: signature, body indent, closing brace).
// Name is editable; params/return/body are slots (orange dots).
append_proc_node :: proc(app: ^App, name := "") {
	// Line 1: <name> :: proc( <params> ) -> <ret> {
	proc_name: string
	generated := false
	if name != "" {
		proc_name = name
	} else {
		// The FIRST procedure in the file is always "main"; later ones are generated.
		has_proc := false
		for n in app.doc.nodes {
			if strings.contains(node_text(n, context.temp_allocator), ":: proc") {
				has_proc = true
				break
			}
		}
		if has_proc {
			proc_name = generate_ident(app)
			generated = true
		} else {
			proc_name = "main"
		}
	}
	n1: Node
	append(&n1.fields, Field{strings.clone(proc_name), true, false, ""})       // editable name
	if generated do delete(proc_name) // free generated name after clone
	append(&n1.fields, Field{strings.clone(" :: proc( "), false, false, ""})  // fixed
	append(&n1.fields, Field{"", false, true, "params"})                  // params slot
	append(&n1.fields, Field{strings.clone(" ) -> "), false, false, ""}) // fixed
	append(&n1.fields, Field{"", false, true, "type"})                    // return slot
	append(&n1.fields, Field{strings.clone(" {"), false, false, ""})     // fixed
	doc_insert(app, n1)

	// Line 2: <indent><body>
	n2: Node
	append(&n2.fields, Field{strings.clone("    "), false, false, ""})   // indent
	append(&n2.fields, Field{"", false, true, "body"})                    // body slot
	doc_insert(app, n2)

	// Line 3: }
	n3: Node
	append(&n3.fields, Field{strings.clone("}"), false, false, ""})      // closing brace
	doc_insert(app, n3)
}

// Append type declaration nodes (struct/enum/union/bit_set/distinct/alias).
append_type_node :: proc(app: ^App, kind: string) {
	type_name := generate_type(app)
	defer delete(type_name)
	switch kind {
	case "struct":
		// Line 1: <type_name> :: struct {
		n1: Node
		append(&n1.fields, Field{strings.clone(type_name), true, false, ""})       // editable name
		append(&n1.fields, Field{strings.clone(" :: struct {"), false, false, ""}) // fixed
		doc_insert(app, n1)
		// Line 2: <indent><body slot>
		n2: Node
		append(&n2.fields, Field{strings.clone("    "), false, false, ""})         // indent
		append(&n2.fields, Field{"", false, true, "body"})                         // body slot
		doc_insert(app, n2)
		// Line 3: }
		n3: Node
		append(&n3.fields, Field{strings.clone("}"), false, false, ""})            // closing brace
		doc_insert(app, n3)

	case "enum":
		// Line 1: <type_name> :: enum {
		n1: Node
		append(&n1.fields, Field{strings.clone(type_name), true, false, ""})       // editable name
		append(&n1.fields, Field{strings.clone(" :: enum {"), false, false, ""})  // fixed
		doc_insert(app, n1)
		// Line 2: <indent><body slot>
		n2: Node
		append(&n2.fields, Field{strings.clone("    "), false, false, ""})         // indent
		append(&n2.fields, Field{"", false, true, "body"})                         // body slot
		doc_insert(app, n2)
		// Line 3: }
		n3: Node
		append(&n3.fields, Field{strings.clone("}"), false, false, ""})            // closing brace
		doc_insert(app, n3)

	case "union":
		// Line 1: <type_name> :: union {
		n1: Node
		append(&n1.fields, Field{strings.clone(type_name), true, false, ""})       // editable name
		append(&n1.fields, Field{strings.clone(" :: union {"), false, false, ""}) // fixed
		doc_insert(app, n1)
		// Line 2: <indent><body slot>
		n2: Node
		append(&n2.fields, Field{strings.clone("    "), false, false, ""})         // indent
		append(&n2.fields, Field{"", false, true, "body"})                         // body slot
		doc_insert(app, n2)
		// Line 3: }
		n3: Node
		append(&n3.fields, Field{strings.clone("}"), false, false, ""})            // closing brace
		doc_insert(app, n3)

	case "bit_set":
		// Single line: <type_name> :: bit_set[•]
		n: Node
		append(&n.fields, Field{strings.clone(type_name), true, false, ""})        // editable name
		append(&n.fields, Field{strings.clone(" :: bit_set["), false, false, ""}) // fixed
		append(&n.fields, Field{"", false, true, "type"})                          // element type slot
		append(&n.fields, Field{strings.clone("]"), false, false, ""})             // fixed
		doc_insert(app, n)

	case "distinct":
		// Single line: <type_name> :: distinct •
		n: Node
		append(&n.fields, Field{strings.clone(type_name), true, false, ""})        // editable name
		append(&n.fields, Field{strings.clone(" :: distinct "), false, false, ""}) // fixed
		append(&n.fields, Field{"", false, true, "type"})                          // base type slot
		doc_insert(app, n)

	case "alias":
		// Single line: <type_name> :: •
		n: Node
		append(&n.fields, Field{strings.clone(type_name), true, false, ""})        // editable name
		append(&n.fields, Field{strings.clone(" :: "), false, false, ""})          // fixed
		append(&n.fields, Field{"", false, true, "type"})                          // type slot
		doc_insert(app, n)
	}
}

append_value_node :: proc(app: ^App, kind: string) {
	switch kind {
	case "const":
		// Single line: <const_name> :: •
		const_name := generate_const(app)
		defer delete(const_name)
		n: Node
		append(&n.fields, Field{strings.clone(const_name), true, false, ""})    // editable name
		append(&n.fields, Field{strings.clone(" :: "), false, false, ""})      // fixed
		append(&n.fields, Field{"", false, true, "value"})                     // value slot
		doc_insert(app, n)

	case "typed_const":
		// Single line: <const_name> : • : •
		const_name := generate_const(app)
		defer delete(const_name)
		n: Node
		append(&n.fields, Field{strings.clone(const_name), true, false, ""})    // editable name
		append(&n.fields, Field{strings.clone(" : "), false, false, ""})       // fixed
		append(&n.fields, Field{"", false, true, "type"})                      // type slot
		append(&n.fields, Field{strings.clone(" : "), false, false, ""})       // fixed
		append(&n.fields, Field{"", false, true, "value"})                     // value slot
		doc_insert(app, n)

	case "config":
		// Single line: <const_name> :: #config(<const_name>, •)
		const_name := generate_const(app)
		defer delete(const_name)
		n: Node
		append(&n.fields, Field{strings.clone(const_name), true, false, ""})     // editable name
		config_text := fmt.aprintf(" :: #config(%s, ", const_name)
		defer delete(config_text)
		append(&n.fields, Field{strings.clone(config_text), false, false, ""}) // fixed
		append(&n.fields, Field{"", false, true, "value"})                     // default value slot
		append(&n.fields, Field{strings.clone(")"), false, false, ""})         // fixed
		doc_insert(app, n)

	case "global_typed":
		// Single line: <var_name>: •
		var_name := generate_ident(app)
		defer delete(var_name)
		n: Node
		append(&n.fields, Field{strings.clone(var_name), true, false, ""})     // editable name
		append(&n.fields, Field{strings.clone(": "), false, false, ""})        // fixed
		append(&n.fields, Field{"", false, true, "type"})                      // type slot
		doc_insert(app, n)

	case "global_init":
		// Single line: <var_name> := •
		var_name := generate_ident(app)
		defer delete(var_name)
		n: Node
		append(&n.fields, Field{strings.clone(var_name), true, false, ""})     // editable name
		append(&n.fields, Field{strings.clone(" := "), false, false, ""})      // fixed
		append(&n.fields, Field{"", false, true, "value"})                     // value slot
		doc_insert(app, n)
	}
}

// ---- Slot filling ----

// Collect user-defined type names from the document (PascalCase identifiers).
collect_user_types :: proc(app: ^App) -> []string {
	result: [dynamic]string
	for n in app.doc.nodes {
		for f in n.fields {
			if f.editable && len(f.text) > 0 {
				// Check if first character is uppercase (A-Z)
				if f.text[0] >= 'A' && f.text[0] <= 'Z' {
					// Add if not already in list
					already_added := false
					for s in result {
						if s == f.text {
							already_added = true
							break
						}
					}
					if !already_added do append(&result, f.text)
				}
			}
		}
	}
	return result[:]
}

// Collect procedure names from the document (scan for " :: proc(").
collect_proc_names :: proc(app: ^App) -> []string {
	result: [dynamic]string
	for n in app.doc.nodes {
		txt := node_text(n, context.temp_allocator)
		if strings.contains(txt, " :: proc(") {
			// The proc name is the first editable field on this line
			for f in n.fields {
				if f.editable && len(f.text) > 0 {
					// Add if not already in list
					already_added := false
					for s in result {
						if s == f.text {
							already_added = true
							break
						}
					}
					if !already_added do append(&result, f.text)
					break // only the first editable field (the proc name)
				}
			}
		}
	}
	return result[:]
}

// Collect import reference names from the document.
// For plain imports like `import "core:fmt"`, the reference is the last path segment ("fmt").
// For aliased imports like `import win "core:sys/windows"`, the reference is the alias ("win").
collect_import_names :: proc(app: ^App) -> []string {
	result: [dynamic]string
	for n in app.doc.nodes {
		txt := node_text(n, context.temp_allocator)
		if strings.has_prefix(txt, "import ") {
			// Check if it's an aliased import: has an editable field
			has_alias := false
			for f in n.fields {
				if f.editable && len(f.text) > 0 {
					// Aliased import: use the alias
					already_added := false
					for s in result {
						if s == f.text {
							already_added = true
							break
						}
					}
					if !already_added do append(&result, f.text)
					has_alias = true
					break
				}
			}
			if !has_alias {
				// Plain import: extract the last path segment from the import_path
				// txt is "import \"path\"", extract path and get last segment
				start := strings.index(txt, "\"")
				if start >= 0 {
					start += 1
					end := strings.last_index(txt, "\"")
					if end > start {
						path := txt[start:end]
						ref_name := alias_default(path)
						already_added := false
						for s in result {
							if s == ref_name {
								already_added = true
								break
							}
						}
						if !already_added do append(&result, ref_name)
					}
				}
			}
		}
	}
	return result[:]
}

// Import reference with both the reference name and full path.
ImportRef :: struct {
	ref:  string, // reference name (alias or last path segment)
	path: string, // full import path like "core:fmt"
}

// Collect import references and their paths from the document.
collect_imports :: proc(app: ^App) -> []ImportRef {
	result: [dynamic]ImportRef
	for n in app.doc.nodes {
		txt := node_text(n, context.temp_allocator)
		if strings.has_prefix(txt, "import ") {
			// Check if it's an aliased import: has an editable field
			has_alias := false
			for f in n.fields {
				if f.editable && len(f.text) > 0 {
					// Aliased import: extract the alias and path
					start := strings.index(txt, "\"")
					if start >= 0 {
						start += 1
						end := strings.last_index(txt, "\"")
						if end > start {
							path := txt[start:end]
							already_added := false
							for existing in result {
								if existing.ref == f.text && existing.path == path {
									already_added = true
									break
								}
							}
							if !already_added do append(&result, ImportRef{f.text, path})
						}
					}
					has_alias = true
					break
				}
			}
			if !has_alias {
				// Plain import: extract path and get last segment
				start := strings.index(txt, "\"")
				if start >= 0 {
					start += 1
					end := strings.last_index(txt, "\"")
					if end > start {
						path := txt[start:end]
						ref_name := alias_default(path)
						already_added := false
						for existing in result {
							if existing.ref == ref_name && existing.path == path {
								already_added = true
								break
							}
						}
						if !already_added do append(&result, ImportRef{ref_name, path})
					}
				}
			}
		}
	}
	return result[:]
}

// Get procedure names for a given import path.
// Procedure names exported by a package path. Caller owns the returned slice
// (delete it); the name strings reference static CORE_PROCS data (do not free).
procs_for_path :: proc(path: string) -> []string {
	result: [dynamic]string
	for entry in CORE_PROCS {
		if entry.path == path do append(&result, entry.name)
	}
	return result[:]
}

// Get full procedure info for a given import path.
// Returns all CoreProc entries whose .path == path. Caller owns the returned slice
// (delete it); the CoreProc field strings reference static CORE_PROCS data (do not free).
procs_info_for_path :: proc(path: string) -> []CoreProc {
	result: [dynamic]CoreProc
	for entry in CORE_PROCS {
		if entry.path == path do append(&result, entry)
	}
	return result[:]
}

// Collect procedures from a package that are already called in the document.
// Returns a list of procedure names (caller owns slice).
collect_called_procs :: proc(app: ^App, ref: string) -> []string {
	result: [dynamic]string
	// Scan document for calls like ref.proc_name(
	for n in app.doc.nodes {
		txt := node_text(n, context.temp_allocator)
		// Look for ref.name( pattern
		prefix := strings.concatenate({ref, "."}, context.temp_allocator)
		if strings.contains(txt, prefix) {
			// Extract procedure name
			idx := strings.index(txt, prefix)
			if idx >= 0 {
				start := idx + len(prefix)
				// Find the opening paren
				paren_idx := strings.index(txt[start:], "(")
				if paren_idx >= 0 {
					proc_name := txt[start:start+paren_idx]
					// Check if already added
					already := false
					for existing in result {
						if existing == proc_name {
							already = true
							break
						}
					}
					if !already && len(proc_name) > 0 do append(&result, strings.clone(proc_name))
				}
			}
		}
	}
	return result[:]
}

// Create a fill leaf entry.
fill_leaf :: proc(label, fill_type: string) -> Entry {
	return Entry{label = label, fill = fill_type}
}

// Fill a slot with a type.
set_slot_type :: proc(app: ^App, ni, fi: int, type_name: string) {
	if len(app.doc.nodes[ni].fields[fi].text) > 0 {
		delete(app.doc.nodes[ni].fields[fi].text)
	}
	app.doc.nodes[ni].fields[fi] = Field{strings.clone(type_name), true, false, "type"}
}

// Fill a value slot with a literal value.
set_slot_literal :: proc(app: ^App, ni, fi: int, kind_marker: string) {
	fields := &app.doc.nodes[ni].fields
	// Free slot text if present (value slots have empty "")
	if len(fields[fi].text) > 0 {
		delete(fields[fi].text)
	}
	// Remove the slot field
	ordered_remove(fields, fi)
	
	switch kind_marker {
	case "__lit_num__":
		// Replace with a single editable field, default "0"
		f := Field{strings.clone("0"), true, false, ""}
		inject_at(fields, fi, f)
		
	case "__lit_str__":
		// "..." interpreted string
		inject_string_lit(fields, fi, "\"", "\"")

	case "__lit_rawstr__":
		// `...` raw string literal
		inject_string_lit(fields, fi, "`", "`")

	case "__lit_rune__":
		// '...' rune / character literal
		inject_string_lit(fields, fi, "'", "'")
		
	case "__lit_true__":
		// Replace with a single fixed field "true"
		f := Field{strings.clone("true"), false, false, ""}
		inject_at(fields, fi, f)
		
	case "__lit_false__":
		// Replace with a single fixed field "false"
		f := Field{strings.clone("false"), false, false, ""}
		inject_at(fields, fi, f)
		
	case "__lit_nil__":
		// Replace with a single fixed field "nil"
		f := Field{strings.clone("nil"), false, false, ""}
		inject_at(fields, fi, f)
		
	case "__lit_ref__":
		// Replace with a single editable field, default generated name
		ref_name := generate_ident(app)
		defer delete(ref_name)
		f := Field{strings.clone(ref_name), true, false, ""}
		inject_at(fields, fi, f)
	}
}

// Insert `open + <editable free-text> + close` fields at index fi (order preserved).
inject_string_lit :: proc(fields: ^[dynamic]Field, fi: int, open, close: string) {
	inject_at(fields, fi, Field{strings.clone(close), false, false, ""})
	inject_at(fields, fi, Field{strings.clone(""), true, false, "string"}) // free-text content
	inject_at(fields, fi, Field{strings.clone(open), false, false, ""})
}

// Replace a slot with a variable instantiation (name + ": " + type slot).
make_slot_variable :: proc(app: ^App, ni, fi: int) {
	fields := &app.doc.nodes[ni].fields
	// Remove the slot field
	ordered_remove(fields, fi)
	// Inject three fields at the same position
	var_name := generate_ident(app)
	defer delete(var_name)
	f1 := Field{strings.clone(var_name), true, false, ""}  // editable name
	f2 := Field{strings.clone(": "), false, false, ""}    // fixed separator
	f3 := Field{"", false, true, "type"}                   // new type slot
	inject_at(fields, fi, f3)
	inject_at(fields, fi, f2)
	inject_at(fields, fi, f1)
}

// Transform a params slot into a parameter with a type slot and trailing params slot.
make_slot_param :: proc(app: ^App, ni, fi: int) {
	fields := &app.doc.nodes[ni].fields
	// Remove the params slot field
	ordered_remove(fields, fi)
	// Inject five fields at the same position:
	// param name, ": ", type slot, ", ", trailing params slot
	param_name := generate_ident(app)
	defer delete(param_name)
	f1 := Field{strings.clone(param_name), true, false, ""}  // editable param name
	f2 := Field{strings.clone(": "), false, false, ""}    // fixed
	f3 := Field{"", false, true, "type"}                   // type slot
	f4 := Field{strings.clone(", "), false, false, ""}    // separator
	f5 := Field{"", false, true, "params"}                 // new trailing params slot
	inject_at(fields, fi, f5)
	inject_at(fields, fi, f4)
	inject_at(fields, fi, f3)
	inject_at(fields, fi, f2)
	inject_at(fields, fi, f1)
}

// Transform a body slot into a statement and append a new body slot line.
// Get the leading indent from a body slot line (first field should be whitespace).
get_body_indent :: proc(app: ^App, ni: int, allocator := context.allocator) -> string {
	if ni >= len(app.doc.nodes) do return strings.clone("    ", allocator)
	node := &app.doc.nodes[ni]
	if len(node.fields) == 0 do return strings.clone("    ", allocator)
	// First field should be the indent
	first := node.fields[0]
	if !first.editable && !first.slot && len(first.text) > 0 {
		return strings.clone(first.text, allocator)
	}
	return strings.clone("    ", allocator)
}

// Insert a multi-line branching statement at (ni, fi).
make_branch_statement :: proc(app: ^App, ni, fi: int, kind: string) {
	indent := get_body_indent(app, ni)
	defer delete(indent)
	inner_indent := strings.concatenate({indent, "    "})
	defer delete(inner_indent)
	
	fields := &app.doc.nodes[ni].fields
	// Remove the body slot field
	ordered_remove(fields, fi)
	
	switch kind {
	case "__br_if__": // if • {
		// Header: if • {
		f1 := Field{strings.clone("if "), false, false, ""}
		f2 := Field{"", false, true, "value"} // condition slot
		f3 := Field{strings.clone(" {"), false, false, ""}
		inject_at(fields, fi, f3)
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
		
		// Inner body line: <inner_indent><body slot>
		n_body: Node
		append(&n_body.fields, Field{strings.clone(inner_indent), false, false, ""})
		append(&n_body.fields, Field{"", false, true, "body"})
		inject_at(&app.doc.nodes, ni + 1, n_body)
		
		// Closing brace: <indent>}
		n_close: Node
		append(&n_close.fields, Field{strings.clone(indent), false, false, ""})
		append(&n_close.fields, Field{strings.clone("}"), false, false, ""})
		inject_at(&app.doc.nodes, ni + 2, n_close)
		
	case "__br_ifelse__": // if • { / body / } else { / body2 / }
		// Header: if • {
		f1 := Field{strings.clone("if "), false, false, ""}
		f2 := Field{"", false, true, "value"} // condition slot
		f3 := Field{strings.clone(" {"), false, false, ""}
		inject_at(fields, fi, f3)
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
		
		// Inner body line 1: <inner_indent><body slot>
		n_body1: Node
		append(&n_body1.fields, Field{strings.clone(inner_indent), false, false, ""})
		append(&n_body1.fields, Field{"", false, true, "body"})
		inject_at(&app.doc.nodes, ni + 1, n_body1)
		
		// Else line: <indent>} else {
		n_else: Node
		append(&n_else.fields, Field{strings.clone(indent), false, false, ""})
		append(&n_else.fields, Field{strings.clone("} else {"), false, false, ""})
		inject_at(&app.doc.nodes, ni + 2, n_else)
		
		// Inner body line 2: <inner_indent><body slot>
		n_body2: Node
		append(&n_body2.fields, Field{strings.clone(inner_indent), false, false, ""})
		append(&n_body2.fields, Field{"", false, true, "body"})
		inject_at(&app.doc.nodes, ni + 3, n_body2)
		
		// Closing brace: <indent>}
		n_close: Node
		append(&n_close.fields, Field{strings.clone(indent), false, false, ""})
		append(&n_close.fields, Field{strings.clone("}"), false, false, ""})
		inject_at(&app.doc.nodes, ni + 4, n_close)
		
	case "__br_switch__": // switch • {
		// Header: switch • {
		f1 := Field{strings.clone("switch "), false, false, ""}
		f2 := Field{"", false, true, "value"} // expr slot
		f3 := Field{strings.clone(" {"), false, false, ""}
		inject_at(fields, fi, f3)
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
		
		// Inner body line: <inner_indent><body slot>
		n_body: Node
		append(&n_body.fields, Field{strings.clone(inner_indent), false, false, ""})
		append(&n_body.fields, Field{"", false, true, "body"})
		inject_at(&app.doc.nodes, ni + 1, n_body)
		
		// Closing brace: <indent>}
		n_close: Node
		append(&n_close.fields, Field{strings.clone(indent), false, false, ""})
		append(&n_close.fields, Field{strings.clone("}"), false, false, ""})
		inject_at(&app.doc.nodes, ni + 2, n_close)
		
	case "__br_when__": // when • {
		// Header: when • {
		f1 := Field{strings.clone("when "), false, false, ""}
		f2 := Field{"", false, true, "value"} // compile-time condition slot
		f3 := Field{strings.clone(" {"), false, false, ""}
		inject_at(fields, fi, f3)
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
		
		// Inner body line: <inner_indent><body slot>
		n_body: Node
		append(&n_body.fields, Field{strings.clone(inner_indent), false, false, ""})
		append(&n_body.fields, Field{"", false, true, "body"})
		inject_at(&app.doc.nodes, ni + 1, n_body)
		
		// Closing brace: <indent>}
		n_close: Node
		append(&n_close.fields, Field{strings.clone(indent), false, false, ""})
		append(&n_close.fields, Field{strings.clone("}"), false, false, ""})
		inject_at(&app.doc.nodes, ni + 2, n_close)
	}
	
	// Insert a trailing continuation body-slot line after the block
	new_body: Node
	append(&new_body.fields, Field{strings.clone(indent), false, false, ""})
	append(&new_body.fields, Field{"", false, true, "body"})
	// For if/else with 4 inner nodes, insert after ni+4; else after ni+2
	if kind == "__br_ifelse__" {
		inject_at(&app.doc.nodes, ni + 5, new_body)
	} else {
		inject_at(&app.doc.nodes, ni + 3, new_body)
	}
}

// Insert a multi-line loop statement at (ni, fi).
make_loop_statement :: proc(app: ^App, ni, fi: int, kind: string) {
	indent := get_body_indent(app, ni)
	defer delete(indent)
	inner_indent := strings.concatenate({indent, "    "})
	defer delete(inner_indent)
	
	fields := &app.doc.nodes[ni].fields
	// Remove the body slot field
	ordered_remove(fields, fi)
	
	switch kind {
	case "__loop_for__": // for • {
		// Header: for • {
		f1 := Field{strings.clone("for "), false, false, ""}
		f2 := Field{"", false, true, "value"} // condition slot
		f3 := Field{strings.clone(" {"), false, false, ""}
		inject_at(fields, fi, f3)
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
		
		// Inner body line: <inner_indent><body slot>
		n_body: Node
		append(&n_body.fields, Field{strings.clone(inner_indent), false, false, ""})
		append(&n_body.fields, Field{"", false, true, "body"})
		inject_at(&app.doc.nodes, ni + 1, n_body)
		
		// Closing brace: <indent>}
		n_close: Node
		append(&n_close.fields, Field{strings.clone(indent), false, false, ""})
		append(&n_close.fields, Field{strings.clone("}"), false, false, ""})
		inject_at(&app.doc.nodes, ni + 2, n_close)
		
	case "__loop_forin__": // for • in • {
		// Header: for • in • {
		f1 := Field{strings.clone("for "), false, false, ""}
		f2 := Field{"", false, true, "value"} // iter-var slot
		f3 := Field{strings.clone(" in "), false, false, ""}
		f4 := Field{"", false, true, "value"} // range slot
		f5 := Field{strings.clone(" {"), false, false, ""}
		inject_at(fields, fi, f5)
		inject_at(fields, fi, f4)
		inject_at(fields, fi, f3)
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
		
		// Inner body line: <inner_indent><body slot>
		n_body: Node
		append(&n_body.fields, Field{strings.clone(inner_indent), false, false, ""})
		append(&n_body.fields, Field{"", false, true, "body"})
		inject_at(&app.doc.nodes, ni + 1, n_body)
		
		// Closing brace: <indent>}
		n_close: Node
		append(&n_close.fields, Field{strings.clone(indent), false, false, ""})
		append(&n_close.fields, Field{strings.clone("}"), false, false, ""})
		inject_at(&app.doc.nodes, ni + 2, n_close)
		
	case "__loop_forinf__": // for {
		// Header: for {
		f1 := Field{strings.clone("for {"), false, false, ""}
		inject_at(fields, fi, f1)
		
		// Inner body line: <inner_indent><body slot>
		n_body: Node
		append(&n_body.fields, Field{strings.clone(inner_indent), false, false, ""})
		append(&n_body.fields, Field{"", false, true, "body"})
		inject_at(&app.doc.nodes, ni + 1, n_body)
		
		// Closing brace: <indent>}
		n_close: Node
		append(&n_close.fields, Field{strings.clone(indent), false, false, ""})
		append(&n_close.fields, Field{strings.clone("}"), false, false, ""})
		inject_at(&app.doc.nodes, ni + 2, n_close)
	}
	
	// Insert a trailing continuation body-slot line after the block
	new_body: Node
	append(&new_body.fields, Field{strings.clone(indent), false, false, ""})
	append(&new_body.fields, Field{"", false, true, "body"})
	inject_at(&app.doc.nodes, ni + 3, new_body)
}

make_body_statement :: proc(app: ^App, ni, fi: int, kind: string) {
	fields := &app.doc.nodes[ni].fields
	// Remove the body slot field
	ordered_remove(fields, fi)
	
	switch kind {
	case "__stmt_decl__": // Variable (:=) -> name := •
		var_name := generate_ident(app)
		defer delete(var_name)
		f1 := Field{strings.clone(var_name), true, false, ""} // editable name
		f2 := Field{strings.clone(" := "), false, false, ""} // fixed
		f3 := Field{"", false, true, "value"}                 // value slot
		inject_at(fields, fi, f3)
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
		
	case "__stmt_typed__": // Variable (typed) -> name: • = •
		var_name := generate_ident(app)
		defer delete(var_name)
		f1 := Field{strings.clone(var_name), true, false, ""} // editable name
		f2 := Field{strings.clone(": "), false, false, ""}   // fixed
		f3 := Field{"", false, true, "type"}                  // type slot
		f4 := Field{strings.clone(" = "), false, false, ""}  // fixed
		f5 := Field{"", false, true, "value"}                 // value slot
		inject_at(fields, fi, f5)
		inject_at(fields, fi, f4)
		inject_at(fields, fi, f3)
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
		
	case "__stmt_assign__": // Assignment -> name = •
		var_name := generate_ident(app)
		defer delete(var_name)
		f1 := Field{strings.clone(var_name), true, false, ""} // editable name
		f2 := Field{strings.clone(" = "), false, false, ""}  // fixed
		f3 := Field{"", false, true, "value"}                 // value slot
		inject_at(fields, fi, f3)
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
		
	case "__stmt_call__": // Procedure call -> name( • )
		call_name := generate_ident(app)
		defer delete(call_name)
		f1 := Field{strings.clone(call_name), true, false, ""} // editable name
		f2 := Field{strings.clone("( "), false, false, ""}      // fixed
		f3 := Field{"", false, true, "value"}                    // value slot for arg
		f4 := Field{strings.clone(" )"), false, false, ""}      // fixed
		inject_at(fields, fi, f4)
		inject_at(fields, fi, f3)
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
	}
	
	// Insert a new body slot line after the current node
	new_body: Node
	append(&new_body.fields, Field{strings.clone("    "), false, false, ""}) // indent
	append(&new_body.fields, Field{"", false, true, "body"})                  // body slot
	inject_at(&app.doc.nodes, ni + 1, new_body)
}

// Transform a body slot into a multiple declaration: a, b := •, •
make_multi_decl :: proc(app: ^App, ni, fi: int) {
	fields := &app.doc.nodes[ni].fields
	// Remove the body slot field
	ordered_remove(fields, fi)
	
	// Generate two names
	name1 := generate_ident(app)
	defer delete(name1)
	name2 := generate_ident(app)
	defer delete(name2)
	
	// Build fields: name1 + ", " + name2 + " := " + value_slot1 + ", " + value_slot2
	f1 := Field{strings.clone(name1), true, false, ""}  // editable name 1
	f2 := Field{strings.clone(", "), false, false, ""}  // fixed comma
	f3 := Field{strings.clone(name2), true, false, ""}  // editable name 2
	f4 := Field{strings.clone(" := "), false, false, ""} // fixed :=
	f5 := Field{"", false, true, "value"}                 // value slot 1
	f6 := Field{strings.clone(", "), false, false, ""}  // fixed comma
	f7 := Field{"", false, true, "value"}                 // value slot 2
	
	inject_at(fields, fi, f7)
	inject_at(fields, fi, f6)
	inject_at(fields, fi, f5)
	inject_at(fields, fi, f4)
	inject_at(fields, fi, f3)
	inject_at(fields, fi, f2)
	inject_at(fields, fi, f1)
	
	// Insert a new body slot line after the current node
	new_body: Node
	append(&new_body.fields, Field{strings.clone("    "), false, false, ""}) // indent
	append(&new_body.fields, Field{"", false, true, "body"})                  // body slot
	inject_at(&app.doc.nodes, ni + 1, new_body)
}

// Transform a body slot into a call to a procedure in this package.
// Result: name( • ) where name is fixed (non-editable).
make_call_this_package :: proc(app: ^App, ni, fi: int, proc_name: string) {
	fields := &app.doc.nodes[ni].fields
	// Capture whether this was a body slot (determines if we add a trailing line)
	was_body := app.doc.nodes[ni].fields[fi].kind == "body"
	// Remove the slot field
	ordered_remove(fields, fi)
	
	// Insert call statement: name( • )
	f1 := Field{strings.clone(proc_name), false, false, ""} // fixed proc name
	f2 := Field{strings.clone("( "), false, false, ""}      // fixed
	f3 := Field{"", false, true, "value"}                    // value slot for arg
	f4 := Field{strings.clone(" )"), false, false, ""}      // fixed
	inject_at(fields, fi, f4)
	inject_at(fields, fi, f3)
	inject_at(fields, fi, f2)
	inject_at(fields, fi, f1)
	
	// Only add a trailing body slot line if the original slot was a body slot
	if was_body {
		new_body: Node
		append(&new_body.fields, Field{strings.clone("    "), false, false, ""}) // indent
		append(&new_body.fields, Field{"", false, true, "body"})                  // body slot
		inject_at(&app.doc.nodes, ni + 1, new_body)
	}
}

// Transform a body slot into a call to a procedure from an import.
// Result: pkg.name( • ) where pkg is fixed and name is editable.
make_call_import :: proc(app: ^App, ni, fi: int, pkg_name: string) {
	fields := &app.doc.nodes[ni].fields
	// Capture whether this was a body slot (determines if we add a trailing line)
	was_body := app.doc.nodes[ni].fields[fi].kind == "body"
	// Remove the slot field
	ordered_remove(fields, fi)
	
	// Insert call statement: pkg.name( • )
	proc_name := generate_ident(app)
	defer delete(proc_name)
	f1 := Field{strings.clone(pkg_name), false, false, ""}     // fixed package name
	f2 := Field{strings.clone("."), false, false, ""}        // fixed dot
	f3 := Field{strings.clone(proc_name), true, false, ""}    // editable proc name
	f4 := Field{strings.clone("( "), false, false, ""}       // fixed
	f5 := Field{"", false, true, "value"}                     // value slot for arg
	f6 := Field{strings.clone(" )"), false, false, ""}       // fixed
	inject_at(fields, fi, f6)
	inject_at(fields, fi, f5)
	inject_at(fields, fi, f4)
	inject_at(fields, fi, f3)
	inject_at(fields, fi, f2)
	inject_at(fields, fi, f1)
	
	// Only add a trailing body slot line if the original slot was a body slot
	if was_body {
		new_body: Node
		append(&new_body.fields, Field{strings.clone("    "), false, false, ""}) // indent
		append(&new_body.fields, Field{"", false, true, "body"})                  // body slot
		inject_at(&app.doc.nodes, ni + 1, new_body)
	}
}

// Transform a body slot into a call to a specific procedure from an import.
// Result: pkg.proc( • ) where both pkg and proc are fixed (non-editable).
make_import_proc_call :: proc(app: ^App, ni, fi: int, pkg_name, proc_name: string) {
	fields := &app.doc.nodes[ni].fields
	// Capture whether this was a body slot (determines if we add a trailing line)
	was_body := app.doc.nodes[ni].fields[fi].kind == "body"
	// Remove the slot field
	ordered_remove(fields, fi)
	
	// Insert call statement: pkg.proc( • )
	f1 := Field{strings.clone(pkg_name), false, false, ""}     // fixed package name
	f2 := Field{strings.clone("."), false, false, ""}        // fixed dot
	f3 := Field{strings.clone(proc_name), false, false, ""}   // fixed proc name
	f4 := Field{strings.clone("( "), false, false, ""}       // fixed
	f5 := Field{"", false, true, "value"}                     // value slot for arg
	f6 := Field{strings.clone(" )"), false, false, ""}       // fixed
	inject_at(fields, fi, f6)
	inject_at(fields, fi, f5)
	inject_at(fields, fi, f4)
	inject_at(fields, fi, f3)
	inject_at(fields, fi, f2)
	inject_at(fields, fi, f1)
	
	// Only add a trailing body slot line if the original slot was a body slot
	if was_body {
		new_body: Node
		append(&new_body.fields, Field{strings.clone("    "), false, false, ""}) // indent
		append(&new_body.fields, Field{"", false, true, "body"})                  // body slot
		inject_at(&app.doc.nodes, ni + 1, new_body)
	}
}

// Transform a body slot into a jump/cleanup statement.
make_jump_statement :: proc(app: ^App, ni, fi: int, kind: string) {
	fields := &app.doc.nodes[ni].fields
	// Remove the body slot field
	ordered_remove(fields, fi)
	
	switch kind {
	case "__jmp_return__": // return •
		f1 := Field{strings.clone("return "), false, false, ""} // fixed
		f2 := Field{"", false, true, "value"}                     // value slot
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
		
	case "__jmp_break__": // break
		f1 := Field{strings.clone("break"), false, false, ""} // fixed
		inject_at(fields, fi, f1)
		
	case "__jmp_continue__": // continue
		f1 := Field{strings.clone("continue"), false, false, ""} // fixed
		inject_at(fields, fi, f1)
		
	case "__jmp_fallthrough__": // fallthrough
		f1 := Field{strings.clone("fallthrough"), false, false, ""} // fixed
		inject_at(fields, fi, f1)
		
	case "__jmp_defer__": // defer •
		f1 := Field{strings.clone("defer "), false, false, ""} // fixed
		f2 := Field{"", false, true, "value"}                    // value slot
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
	}
	
	// Insert a new body slot line after the current node
	new_body: Node
	append(&new_body.fields, Field{strings.clone("    "), false, false, ""}) // indent
	append(&new_body.fields, Field{"", false, true, "body"})                  // body slot
	inject_at(&app.doc.nodes, ni + 1, new_body)
}

// Transform a body slot into an error handling statement.
make_error_statement :: proc(app: ^App, ni, fi: int, kind: string) {
	fields := &app.doc.nodes[ni].fields
	// Get current indent from the body slot line
	indent := ""
	if len(fields^) > 0 && !fields[0].slot {
		indent = fields[0].text
	}
	// Remove the body slot field
	ordered_remove(fields, fi)
	
	switch kind {
	case "__err_orreturn__": // • or_return
		f1 := Field{"", false, true, "value"}                      // expr slot
		f2 := Field{strings.clone(" or_return"), false, false, ""} // fixed
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
		
		// Insert a new body slot line after the current node
		new_body: Node
		append(&new_body.fields, Field{strings.clone(indent), false, false, ""}) // indent
		append(&new_body.fields, Field{"", false, true, "body"})                 // body slot
		inject_at(&app.doc.nodes, ni + 1, new_body)
		
	case "__err_orelse__": // • or_else •
		f1 := Field{"", false, true, "value"}                      // first expr slot
		f2 := Field{strings.clone(" or_else "), false, false, ""} // fixed
		f3 := Field{"", false, true, "value"}                      // second expr slot
		inject_at(fields, fi, f3)
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
		
		// Insert a new body slot line after the current node
		new_body: Node
		append(&new_body.fields, Field{strings.clone(indent), false, false, ""}) // indent
		append(&new_body.fields, Field{"", false, true, "body"})                 // body slot
		inject_at(&app.doc.nodes, ni + 1, new_body)
		
	case "__err_iferr__": // Multi-line: if • != nil { / indented body / }
		// Header line: if • != nil {
		f1 := Field{strings.clone("if "), false, false, ""}    // fixed
		f2 := Field{"", false, true, "value"}                    // err expr slot
		f3 := Field{strings.clone(" != nil {"), false, false, ""} // fixed
		inject_at(fields, fi, f3)
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
		
		// Inner body slot line (indented)
		inner_indent := strings.concatenate({indent, "    "})
		n2: Node
		append(&n2.fields, Field{inner_indent, false, false, ""})
		append(&n2.fields, Field{"", false, true, "body"})
		inject_at(&app.doc.nodes, ni + 1, n2)
		
		// Closing brace line
		n3: Node
		append(&n3.fields, Field{strings.clone(indent), false, false, ""}) // indent
		append(&n3.fields, Field{strings.clone("}"), false, false, ""})
		inject_at(&app.doc.nodes, ni + 2, n3)
		
		// Trailing continuation body slot line
		new_body: Node
		append(&new_body.fields, Field{strings.clone(indent), false, false, ""}) // indent
		append(&new_body.fields, Field{"", false, true, "body"})                 // body slot
		inject_at(&app.doc.nodes, ni + 3, new_body)
	}
}

// Transform a body slot into a scope/block statement.
make_scope_statement :: proc(app: ^App, ni, fi: int, kind: string) {
	fields := &app.doc.nodes[ni].fields
	// Get current indent from the body slot line
	indent := ""
	if len(fields^) > 0 && !fields[0].slot {
		indent = fields[0].text
	}
	// Remove the body slot field
	ordered_remove(fields, fi)
	
	switch kind {
	case "__scope_block__": // Multi-line: { / indented body / }
		// Header line: {
		f1 := Field{strings.clone("{"), false, false, ""} // fixed
		inject_at(fields, fi, f1)
		
		// Inner body slot line (indented)
		inner_indent := strings.concatenate({indent, "    "})
		n2: Node
		append(&n2.fields, Field{inner_indent, false, false, ""})
		append(&n2.fields, Field{"", false, true, "body"})
		inject_at(&app.doc.nodes, ni + 1, n2)
		
		// Closing brace line
		n3: Node
		append(&n3.fields, Field{strings.clone(indent), false, false, ""}) // indent
		append(&n3.fields, Field{strings.clone("}"), false, false, ""})
		inject_at(&app.doc.nodes, ni + 2, n3)
		
		// Trailing continuation body slot line
		new_body: Node
		append(&new_body.fields, Field{strings.clone(indent), false, false, ""}) // indent
		append(&new_body.fields, Field{"", false, true, "body"})                 // body slot
		inject_at(&app.doc.nodes, ni + 3, new_body)
		
	case "__scope_using__": // using •
		f1 := Field{strings.clone("using "), false, false, ""} // fixed
		f2 := Field{"", false, true, "value"}                     // value slot
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
		
		// Insert a new body slot line after the current node
		new_body: Node
		append(&new_body.fields, Field{strings.clone(indent), false, false, ""}) // indent
		append(&new_body.fields, Field{"", false, true, "body"})                 // body slot
		inject_at(&app.doc.nodes, ni + 1, new_body)
		
	case "__scope_label__": // Multi-line: ‹label›: { / indented body / }
		// Header line: label: {
		label_name := generate_ident(app)
		defer delete(label_name)
		f1 := Field{strings.clone(label_name), true, false, ""} // editable label
		f2 := Field{strings.clone(": {"), false, false, ""}    // fixed
		inject_at(fields, fi, f2)
		inject_at(fields, fi, f1)
		
		// Inner body slot line (indented)
		inner_indent := strings.concatenate({indent, "    "})
		n2: Node
		append(&n2.fields, Field{inner_indent, false, false, ""})
		append(&n2.fields, Field{"", false, true, "body"})
		inject_at(&app.doc.nodes, ni + 1, n2)
		
		// Closing brace line
		n3: Node
		append(&n3.fields, Field{strings.clone(indent), false, false, ""}) // indent
		append(&n3.fields, Field{strings.clone("}"), false, false, ""})
		inject_at(&app.doc.nodes, ni + 2, n3)
		
		// Trailing continuation body slot line
		new_body: Node
		append(&new_body.fields, Field{strings.clone(indent), false, false, ""}) // indent
		append(&new_body.fields, Field{"", false, true, "body"})                 // body slot
		inject_at(&app.doc.nodes, ni + 3, new_body)
	}
}

// Build hierarchical menu for procedures from an imported package.
// Returns children entries (caller doesn't own the returned slice but owns Entry internals).
build_import_proc_menu :: proc(app: ^App, ref: string, path: string) -> []Entry {
	all_procs := procs_info_for_path(path)
	defer delete(all_procs)
	
	if len(all_procs) == 0 do return nil
	
	// Rule 1: Used procedures first
	used := collect_called_procs(app, ref)
	defer {
		for u in used do delete(u)
		delete(used)
	}
	
	// Build used leaves and track which procs to exclude from grouped sections
	used_set: map[string]bool
	defer delete(used_set)
	used_entries: [dynamic]Entry
	defer delete(used_entries)
	
	for u in used {
		used_set[u] = true
		append(&used_entries, Entry{
			label = strings.clone(u),
			fill = "__call_import_proc__",
			call_pkg = strings.clone(ref),
			call_name = strings.clone(u),
			owned_label = true,
		})
	}
	
	// Filter out used procs from grouping
	grouped_procs: [dynamic]CoreProc
	defer delete(grouped_procs)
	for p in all_procs {
		if p.name not_in used_set do append(&grouped_procs, p)
	}
	
	// Build grouped hierarchy
	grouped_children := build_proc_hierarchy(ref, grouped_procs[:])
	defer delete(grouped_children) // Just delete the slice; Entry internals are copied to result
	
	// Combine: used first, then grouped
	result: [dynamic]Entry
	defer delete(result)
	for u in used_entries do append(&result, u)
	for g in grouped_children do append(&result, g)
	
	// Return a proper slice that the caller will own
	if len(result) == 0 do return nil
	final := make([]Entry, len(result))
	copy(final, result[:])
	return final
}

// Build hierarchical grouping for a list of procedures.
// Applies rules 2-6: file grouping, block grouping, prefix splitting, alpha buckets, flat list.
build_proc_hierarchy :: proc(ref: string, procs: []CoreProc) -> []Entry {
	if len(procs) == 0 do return nil
	if len(procs) <= FLAT_MAX {
		// Rule 6: Small enough, return flat sorted leaves
		return build_flat_leaves(ref, procs)
	}
	
	// Rule 2: Group by source file
	file_groups := group_by_file(procs)
	defer {
		for _, v in file_groups do delete(v)
		delete(file_groups)
	}
	
	if len(file_groups) > 1 {
		// Multiple files: create file submenus
		file_entries: [dynamic]Entry
		defer delete(file_entries)
		for file, file_procs in file_groups {
			file_children := build_file_children(ref, file_procs[:])
			// file_children slice will be owned by the Entry's children field
			// and freed when free_entries is called on the parent
			append(&file_entries, Entry{
				label = strings.clone(file),
				owned_label = true,
				children = file_children,
			})
		}
		// Sort file groups alphabetically
		slice.sort_by(file_entries[:], proc(a, b: Entry) -> bool {
			return a.label < b.label
		})
		// Return a proper slice that the caller will own
		final := make([]Entry, len(file_entries))
		copy(final, file_entries[:])
		return final
	}
	
	// Single file: skip file level, go directly to block/prefix/bucket grouping
	return build_file_children(ref, procs)
}

// Build children for a single file's procedures.
// Applies rules 3-6: block grouping, prefix splitting, alpha buckets, flat list.
build_file_children :: proc(ref: string, procs: []CoreProc) -> []Entry {
	if len(procs) == 0 do return nil
	if len(procs) <= FLAT_MAX do return build_flat_leaves(ref, procs)
	
	// Rule 3: Group by foreign block
	block_groups := group_by_block(procs)
	defer {
		for _, v in block_groups do delete(v)
		delete(block_groups)
	}
	
	// Count non-empty blocks
	non_empty_blocks := 0
	for block, _ in block_groups {
		if len(block) > 0 do non_empty_blocks += 1
	}
	
	if non_empty_blocks > 1 {
		// Multiple non-empty blocks: create block submenus
		block_entries: [dynamic]Entry
		defer delete(block_entries)
		for block, block_procs in block_groups {
			if len(block) == 0 do continue // Skip top-level for now
			block_children := build_block_children(ref, block_procs[:])
			append(&block_entries, Entry{
				label = strings.clone(block),
				owned_label = true,
				children = block_children,
			})
		}
		// Add top-level procs if any
		if "" in block_groups {
			top_level := block_groups[""]
			if len(top_level) > 0 {
				top_children := build_block_children(ref, top_level[:])
				append(&block_entries, Entry{
					label = strings.clone("(top-level)"),
					owned_label = true,
					children = top_children,
				})
			}
		}
		// Sort block groups alphabetically
		slice.sort_by(block_entries[:], proc(a, b: Entry) -> bool {
			return a.label < b.label
		})
		// Return a proper slice that the caller will own
		final := make([]Entry, len(block_entries))
		copy(final, block_entries[:])
		return final
	}
	
	// Single block (or all top-level): skip block level, go to prefix/bucket grouping
	return build_block_children(ref, procs)
}

// Build children for a single block's procedures.
// Applies rules 4-6: prefix splitting, alpha buckets, flat list.
build_block_children :: proc(ref: string, procs: []CoreProc) -> []Entry {
	if len(procs) == 0 do return nil
	if len(procs) <= FLAT_MAX do return build_flat_leaves(ref, procs)
	
	// Rule 4: Split by name prefix
	prefix_groups := find_prefix_groups(procs)
	defer {
		for _, v in prefix_groups do delete(v)
		delete(prefix_groups)
	}
	
	if len(prefix_groups) > 0 {
		// We found useful prefix groups
		prefix_entries: [dynamic]Entry
		defer delete(prefix_entries)
		
		// Add prefix groups
		for prefix, prefix_procs in prefix_groups {
			// Build exactly one representation (don't build-then-discard -> leak).
			prefix_children: []Entry
			if len(prefix_procs) > FLAT_MAX {
				prefix_children = build_alpha_buckets(ref, prefix_procs[:])
			} else {
				prefix_children = build_flat_leaves(ref, prefix_procs[:])
			}
			label := strings.concatenate({prefix, "..."}, context.allocator)
			append(&prefix_entries, Entry{
				label = label,
				owned_label = true,
				children = prefix_children,
			})
		}
		
		// Sort prefix groups alphabetically
		slice.sort_by(prefix_entries[:], proc(a, b: Entry) -> bool {
			return a.label < b.label
		})
		
		// Return a proper slice that the caller will own
		final := make([]Entry, len(prefix_entries))
		copy(final, prefix_entries[:])
		return final
	}
	
	// Rule 5: Alphabetical buckets (fallback)
	return build_alpha_buckets(ref, procs)
}

// Build flat sorted leaf entries for procedures.
build_flat_leaves :: proc(ref: string, procs: []CoreProc) -> []Entry {
	if len(procs) == 0 do return nil
	
	// Sort by name
	sorted := make([dynamic]CoreProc, len(procs))
	defer delete(sorted)
	copy(sorted[:], procs)
	slice.sort_by(sorted[:], proc(a, b: CoreProc) -> bool {
		return a.name < b.name
	})
	
	// Build leaves
	result: [dynamic]Entry
	defer delete(result)
	for p in sorted {
		append(&result, Entry{
			label = strings.clone(p.name),
			fill = "__call_import_proc__",
			call_pkg = strings.clone(ref),
			call_name = strings.clone(p.name),
			owned_label = true,
		})
	}
	// Return a proper slice that the caller will own
	final := make([]Entry, len(result))
	copy(final, result[:])
	return final
}

// Build alphabetical bucket submenus for a large list of procedures.
build_alpha_buckets :: proc(ref: string, procs: []CoreProc) -> []Entry {
	if len(procs) <= FLAT_MAX do return build_flat_leaves(ref, procs)
	
	// Sort by name
	sorted := make([dynamic]CoreProc, len(procs))
	defer delete(sorted)
	copy(sorted[:], procs)
	slice.sort_by(sorted[:], proc(a, b: CoreProc) -> bool {
		return a.name < b.name
	})
	
	// Split into buckets of ~PAGE items
	buckets: [dynamic]Entry
	defer delete(buckets)
	for i := 0; i < len(sorted); i += PAGE {
		end := min(i + PAGE, len(sorted))
		bucket_procs := sorted[i:end]
		
		// Create label from first to last
		first_letter := strings.to_lower(bucket_procs[0].name[0:1], context.temp_allocator)
		last_letter := strings.to_lower(bucket_procs[len(bucket_procs)-1].name[0:1], context.temp_allocator)
		label: string
		if first_letter == last_letter {
			label = strings.clone(first_letter)
		} else {
			label = strings.concatenate({first_letter, "-", last_letter}, context.allocator)
		}
		
		bucket_children := build_flat_leaves(ref, bucket_procs)
		append(&buckets, Entry{
			label = label,
			owned_label = true,
			children = bucket_children,
		})
	}
	
	// Return a proper slice that the caller will own
	final := make([]Entry, len(buckets))
	copy(final, buckets[:])
	return final
}

// Group procedures by source file.
group_by_file :: proc(procs: []CoreProc) -> map[string][dynamic]CoreProc {
	result: map[string][dynamic]CoreProc
	for p in procs {
		if p.file not_in result {
			result[p.file] = make([dynamic]CoreProc)
		}
		append(&result[p.file], p)
	}
	return result
}

// Group procedures by foreign block.
group_by_block :: proc(procs: []CoreProc) -> map[string][dynamic]CoreProc {
	result: map[string][dynamic]CoreProc
	for p in procs {
		if p.block not_in result {
			result[p.block] = make([dynamic]CoreProc)
		}
		append(&result[p.block], p)
	}
	return result
}

// Find common prefix groups in procedure names (rule 4).
// Returns map of prefix -> procs sharing that prefix.
// Only includes prefixes shared by >= MIN_PREFIX_SHARE procedures.
// Excludes procedures that don't belong to any qualifying prefix group.
find_prefix_groups :: proc(procs: []CoreProc) -> map[string][dynamic]CoreProc {
	if len(procs) <= FLAT_MAX do return nil
	
	// Count prefix occurrences
	prefix_counts: map[string]int
	defer delete(prefix_counts)
	proc_prefixes: map[string]string // proc name -> its prefix
	defer delete(proc_prefixes)
	
	for p in procs {
		prefix := extract_prefix(p.name)
		if len(prefix) > 0 {
			proc_prefixes[p.name] = prefix
			if prefix not_in prefix_counts {
				prefix_counts[prefix] = 0
			}
			prefix_counts[prefix] += 1
		}
	}
	
	// Keep only prefixes with >= MIN_PREFIX_SHARE occurrences
	qualifying_prefixes: map[string]bool
	defer delete(qualifying_prefixes)
	for prefix, count in prefix_counts {
		if count >= MIN_PREFIX_SHARE {
			qualifying_prefixes[prefix] = true
		}
	}
	
	if len(qualifying_prefixes) == 0 do return nil
	
	// Group procedures by their qualifying prefix
	result: map[string][dynamic]CoreProc
	for p in procs {
		if prefix, ok := proc_prefixes[p.name]; ok && prefix in qualifying_prefixes {
			if prefix not_in result {
				result[prefix] = make([dynamic]CoreProc)
			}
			append(&result[prefix], p)
		}
		// Procs without qualifying prefixes are excluded (handled by fallback)
	}
	
	return result
}

// Extract a prefix from a procedure name.
// For PascalCase: first word (up to next capital or end).
// For snake_case: up to first underscore (inclusive).
extract_prefix :: proc(name: string) -> string {
	if len(name) == 0 do return ""
	
	// Check for snake_case
	if strings.contains(name, "_") {
		idx := strings.index(name, "_")
		if idx > 0 do return name[0:idx+1] // Include the underscore
	}
	
	// PascalCase: find first capital letter after position 0
	for i := 1; i < len(name); i += 1 {
		if name[i] >= 'A' && name[i] <= 'Z' {
			return name[0:i]
		}
	}
	
	// No clear prefix found
	return ""
}

// Build call menu children: Procedure in this package, Procedure from an import, Built-in.
// Returns a slice that the caller owns (and should pass to free_entries).
build_call_children :: proc(app: ^App) -> []Entry {
	call_entries: [dynamic]Entry
	defer delete(call_entries)
	
	// Subcategory 1: Procedure in this package
	proc_names := collect_proc_names(app)
	defer delete(proc_names)
	this_pkg_calls: [dynamic]Entry
	defer delete(this_pkg_calls)
	if len(proc_names) == 0 {
		append(&this_pkg_calls, grp_dim("(no procedures defined)"))
	} else {
		for name in proc_names {
			append(&this_pkg_calls, Entry{
				label = name,
				fill = "__call_this_pkg__",
				call_name = strings.clone(name),
			})
		}
	}
	this_pkg_children := make([]Entry, len(this_pkg_calls))
	copy(this_pkg_children, this_pkg_calls[:])
	append(&call_entries, grp("Procedure in this package", this_pkg_children))
	
	// Subcategory 2: Procedure from an import
	imports := collect_imports(app)
	defer delete(imports)
	import_calls: [dynamic]Entry
	defer delete(import_calls)
	if len(imports) == 0 {
		append(&import_calls, grp_dim("(no imports yet)"))
	} else {
		for imp in imports {
			// Build hierarchical procedure menu for this import
			pkg_children := build_import_proc_menu(app, imp.ref, imp.path)
			
			if len(pkg_children) == 0 {
				// No procedures in table (e.g., non-core import), provide fallback
				pkg_children = make_slice(Entry{
					label = "Other (name it yourself)",
					fill = "__call_import__",
					call_pkg = strings.clone(imp.ref),
				})
			}
			
			// Make this package a group with procedure children
			append(&import_calls, Entry{
				label = imp.ref,
				children = pkg_children,
			})
		}
	}
	import_children := make([]Entry, len(import_calls))
	copy(import_children, import_calls[:])
	append(&call_entries, grp("Procedure from an import", import_children))
	
	// Subcategory 3: Built-in procedures
	builtins := [?]string{
		"len", "cap", "make", "new", "append", "delete", "free",
		"size_of", "align_of", "offset_of", "type_of", "type_info_of",
		"assert", "panic", "clear", "resize", "reserve",
		"raw_data", "swizzle", "min", "max", "abs", "clamp",
	}
	builtin_calls: [dynamic]Entry
	defer delete(builtin_calls)
	for name in builtins {
		append(&builtin_calls, Entry{
			label = strings.clone(name),
			fill = "__call_this_pkg__",
			call_name = strings.clone(name),
			owned_label = true,
		})
	}
	builtin_children := make([]Entry, len(builtin_calls))
	copy(builtin_children, builtin_calls[:])
	append(&call_entries, grp("Built-in", builtin_children))
	
	calls_children := make([]Entry, len(call_entries))
	copy(calls_children, call_entries[:])
	return calls_children
}

// Open the slot filling menu.
open_slot_menu :: proc(app: ^App) {
	ni, fi, ok := editor_target(app)
	if !ok do return
	
	// Record which slot we're filling
	app.slot_ni = ni
	app.slot_fi = fi
	
	// Free any previous slot menu
	if app.slot_menu != nil {
		free_entries(app.slot_menu)
		app.slot_menu = nil
	}
	
	// Branch on slot kind
	slot_kind := app.doc.nodes[ni].fields[fi].kind
	
	if slot_kind == "params" {
		// Build param-specific menu
		app.slot_menu = make_slice(
			Entry{label = "Add parameter", fill = "__param__"},
		)
	} else if slot_kind == "body" {
		// Build body-specific statement menu with categories
		
		// Declarations category
		decls := make_slice(
			Entry{label = "Variable (:=)", fill = "__stmt_decl__"},
			Entry{label = "Variable (typed)", fill = "__stmt_typed__"},
			Entry{label = "Multiple (:=)", fill = "__stmt_multi__"},
		)
		
		// Assignment category
		assignments := make_slice(
			Entry{label = "Assignment", fill = "__stmt_assign__"},
		)
		
		// Calls category
		calls_children := build_call_children(app)
		
		branching := make_slice(
			Entry{label = "If", fill = "__br_if__"},
			Entry{label = "If / Else", fill = "__br_ifelse__"},
			Entry{label = "Switch", fill = "__br_switch__"},
			Entry{label = "When", fill = "__br_when__"},
		)
		loops := make_slice(
			Entry{label = "For (condition)", fill = "__loop_for__"},
			Entry{label = "For ... in", fill = "__loop_forin__"},
			Entry{label = "For (infinite)", fill = "__loop_forinf__"},
		)
		jumps := make_slice(
			Entry{label = "Return", fill = "__jmp_return__"},
			Entry{label = "Break", fill = "__jmp_break__"},
			Entry{label = "Continue", fill = "__jmp_continue__"},
			Entry{label = "Fallthrough", fill = "__jmp_fallthrough__"},
			Entry{label = "Defer", fill = "__jmp_defer__"},
		)
		errors := make_slice(
			Entry{label = "or_return", fill = "__err_orreturn__"},
			Entry{label = "or_else", fill = "__err_orelse__"},
			Entry{label = "if err != nil", fill = "__err_iferr__"},
		)
		scopes := make_slice(
			Entry{label = "Block", fill = "__scope_block__"},
			Entry{label = "Using", fill = "__scope_using__"},
			Entry{label = "Labeled block", fill = "__scope_label__"},
		)
		
		app.slot_menu = make_slice(
			grp("Declarations", decls),
			grp("Assignment", assignments),
			grp("Calls", calls_children),
			grp("Branching", branching),
			grp("Loops", loops),
			grp("Jumps and cleanup", jumps),
			grp("Error handling", errors),
			grp("Scope and blocks", scopes),
		)
	} else if slot_kind == "value" {
		// Build value literal menu for value slots
		// First build the Type submenu (for rare cases like x := int)
		type_entries: [dynamic]Entry
		defer delete(type_entries)
		
		// Basic Odin types
		basic_types := [?]string{
			"int", "i8", "i16", "i32", "i64",
			"u8", "u16", "u32", "u64", "uint", "uintptr",
			"f32", "f64",
			"bool", "string", "cstring", "rune", "byte", "rawptr",
		}
		for t in basic_types {
			append(&type_entries, fill_leaf(t, t))
		}
		
		// User-defined types
		user_types := collect_user_types(app)
		defer delete(user_types)
		for t in user_types {
			append(&type_entries, fill_leaf(t, t))
		}
		
		// Build the slot menu with literal options
		type_children := make([]Entry, len(type_entries))
		copy(type_children, type_entries[:])

		// Odin string/character literal variants (see Odin overview).
		string_children := make_slice(
			Entry{label = "\"...\"  string", fill = "__lit_str__"},
			Entry{label = "`...`  raw", fill = "__lit_rawstr__"},
			Entry{label = "'...'  rune", fill = "__lit_rune__"},
		)

		app.slot_menu = make_slice(
			Entry{label = "Number", fill = "__lit_num__"},
			Entry{label = "String", children = string_children},
			Entry{label = "true", fill = "__lit_true__"},
			Entry{label = "false", fill = "__lit_false__"},
			Entry{label = "nil", fill = "__lit_nil__"},
			Entry{label = "Reference", fill = "__lit_ref__"},
			Entry{label = strings.clone("Call"), owned_label = true, children = build_call_children(app)},
			Entry{label = "Type", children = type_children},
		)
	} else {
		// Generic Type/Variable menu for other slots (kind=="type", kind=="")
		// Build type submenu with basic types + user types
		type_entries: [dynamic]Entry
		defer delete(type_entries)
		
		// Basic Odin types
		basic_types := [?]string{
			"int", "i8", "i16", "i32", "i64",
			"u8", "u16", "u32", "u64", "uint", "uintptr",
			"f32", "f64",
			"bool", "string", "cstring", "rune", "byte", "rawptr",
		}
		for t in basic_types {
			append(&type_entries, fill_leaf(t, t))
		}
		
		// User-defined types
		user_types := collect_user_types(app)
		defer delete(user_types)
		for t in user_types {
			append(&type_entries, fill_leaf(t, t))
		}
		
		// Build the slot menu
		type_children := make([]Entry, len(type_entries))
		copy(type_children, type_entries[:])
		
		app.slot_menu = make_slice(
			Entry{label = "Type", children = type_children},
			Entry{label = "Variable", fill = "__var__"},
		)
	}
	
	// Open the menu
	clear_nav(app)
	app.return_state = .Editor
	app.state = .Radial
	push_menu(app, "Fill slot", app.slot_menu)
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

// ---- Statement-level selection and deletion ----

// Given a node index, return the inclusive range of nodes forming that statement/construct.
// Uses brace matching: a plain line (like `package main`) returns (ni, ni); a construct
// that opens a block (like a procedure header) returns (ni, j) where j is the matching close.
@(private)
brace_delta :: proc(app: ^App, i: int) -> int {
	d := 0
	t := node_text(app.doc.nodes[i], context.temp_allocator)
	for r in t {
		if r == '{' do d += 1
		if r == '}' do d -= 1
	}
	return d
}

// The whole top-level statement/construct that contains node ni. Works for ANY
// line inside a block (header, body, or closing brace) by using brace depth:
// the construct starts at the last top-level line (depth 0) at/before ni and
// ends where that block's brace balance returns to 0.
construct_range :: proc(app: ^App, ni: int) -> (start: int, end: int) {
	n := len(app.doc.nodes)
	if n == 0 do return 0, 0
	idx := ni
	if idx < 0 do idx = 0
	if idx >= n do idx = n - 1

	// start = last index <= idx whose brace depth BEFORE it is 0.
	depth := 0
	start = 0
	for i in 0 ..= idx {
		if depth == 0 do start = i
		depth += brace_delta(app, i)
	}
	// end = from start, forward until the running balance returns to <= 0.
	balance := 0
	end = start
	for j := start; j < n; j += 1 {
		balance += brace_delta(app, j)
		end = j
		if balance <= 0 do break
	}
	return start, end
}

// Delete nodes [start..end] inclusive, freeing memory.
// Delete the whole statement/construct the cursor is on (used by RT+Y).
delete_focused_construct :: proc(app: ^App) {
	if app.editor_line < 0 || app.editor_line >= len(app.doc.nodes) do return
	s, e := construct_range(app, app.editor_line)
	delete_construct(app, s, e)
}

// Move the selection to the previous/next whole statement (used by RT + D-pad).
editor_move_construct :: proc(app: ^App, dir: int) {
	nlines := len(app.doc.nodes)
	if nlines == 0 { app.editor_line = 0; app.editor_field = 0; return }
	if dir > 0 {
		if app.editor_line >= nlines do return // already at the green dot
		_, e := construct_range(app, app.editor_line)
		app.editor_line = e + 1 // start of the next construct, or the green dot
	} else {
		line := app.editor_line
		if line > nlines do line = nlines
		if line <= 0 { app.editor_line = 0; app.editor_field = 0; return }
		prev := line - 1 // last line of the previous construct
		if prev >= nlines do prev = nlines - 1
		s, _ := construct_range(app, prev)
		app.editor_line = s
	}
	app.editor_field = 0
	if app.editor_line < nlines do clamp_field(app)
}

delete_construct :: proc(app: ^App, start, end_param: int) {
	if start < 0 || start >= len(app.doc.nodes) do return
	end := end_param
	if end < start do return
	if end >= len(app.doc.nodes) do end = len(app.doc.nodes) - 1
	// Free all fields and nodes in the range.
	for i := start; i <= end; i += 1 {
		for f in app.doc.nodes[i].fields {
			if len(f.text) > 0 do delete(f.text)
		}
		delete(app.doc.nodes[i].fields)
	}
	// Remove the nodes from the slice.
	remove_range(&app.doc.nodes, start, end + 1)
	// Clamp editor position.
	app.editor_line = min(app.editor_line, len(app.doc.nodes))
	app.editor_field = 0
	clamp_field(app)
}

// Delete the currently highlighted item (LT+B). Pragmatic rule: if the cursor is on a
// top-level single-node statement, delete that node; if on a body-statement line, delete
// just that line; if the line is a block header (contains '{'), delete the whole block.
delete_selected :: proc(app: ^App) {
	if app.editor_line < 0 || app.editor_line >= len(app.doc.nodes) do return
	
	// If the line contains '{', it's a block header -> delete the whole block
	txt := node_text(app.doc.nodes[app.editor_line], context.temp_allocator)
	if strings.contains(txt, "{") {
		s, e := construct_range(app, app.editor_line)
		delete_construct(app, s, e)
		return
	}
	
	// Otherwise delete just this single node
	for f in app.doc.nodes[app.editor_line].fields {
		if len(f.text) > 0 do delete(f.text)
	}
	delete(app.doc.nodes[app.editor_line].fields)
	ordered_remove(&app.doc.nodes, app.editor_line)
	
	// Clamp editor position
	app.editor_line = min(app.editor_line, len(app.doc.nodes))
	app.editor_field = 0
	clamp_field(app)
}

// Edit the currently selected item (LT+A). Reopen the menu that created it for replacement.
edit_selected :: proc(app: ^App) {
	ni, fi, ok := editor_target(app)
	if !ok do return
	
	field := &app.doc.nodes[ni].fields[fi]
	
	// Case 1: Type field -> reopen Type menu
	if field.kind == "type" && !field.slot {
		// Save the target for replacement
		app.replacing = true
		app.replace_ni = ni
		app.replace_fi = fi
		// Open the Type slot menu
		app.slot_ni = ni
		app.slot_fi = fi
		open_type_menu_for_edit(app)
		return
	}
	
	// Case 2: Import node -> reopen Dependencies > Import menu
	txt := node_text(app.doc.nodes[ni], context.temp_allocator)
	if strings.has_prefix(txt, "import ") {
		// Save the target for replacement
		app.replacing = true
		app.replace_ni = ni
		app.replace_fi = -1 // whole node replacement
		// Open the import menu
		ensure_menus(app)
		clear_nav(app)
		app.import_alias = false
		app.return_state = .Editor
		app.state = .Radial
		push_menu(app, "Edit import", app.add_menu)
		// Navigate to Dependencies -> Import
		v := current_view(app)
		for e, i in v.entries {
			if e.label == "Dependencies" {
				v.index = i
				break
			}
		}
		return
	}
	
	// Case 3: Editable identifier -> no-op (dictation handles it)
}

// Open the type menu for editing a type field
open_type_menu_for_edit :: proc(app: ^App) {
	ensure_menus(app)
	app.return_state = .Editor
	app.state = .Radial
	
	// Build type menu
	type_entries: [dynamic]Entry
	defer delete(type_entries)
	
	// Basic Odin types
	basic_types := [?]string{
		"int", "i8", "i16", "i32", "i64",
		"u8", "u16", "u32", "u64", "uint", "uintptr",
		"f32", "f64",
		"bool", "string", "cstring", "rune", "byte", "rawptr",
	}
	for t in basic_types {
		append(&type_entries, fill_leaf(t, t))
	}
	
	// User-defined types
	user_types := collect_user_types(app)
	defer delete(user_types)
	for t in user_types {
		append(&type_entries, fill_leaf(t, t))
	}
	
	type_children := make([]Entry, len(type_entries))
	copy(type_children, type_entries[:])
	
	app.slot_menu = make_slice(Entry{label = "Type", children = type_children})
	push_menu(app, "Edit Type", app.slot_menu)
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
	// Free slot menu if allocated
	if app.slot_menu != nil {
		free_entries(app.slot_menu)
		app.slot_menu = nil
	}
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

	// Large lists are shown as a flat ALPHABETICAL grid (scrollable), not bucketed.
	// Small lists keep their natural/author order.
	if len(other) > BUCKET_THRESHOLD {
		slice.sort_by(other[:], label_less)
	}
	for e in other do append(&display, e)

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
	app.import_alias = false
	// Set insert_at based on current editor position
	if app.editor_line >= len(app.doc.nodes) {
		// Green dot at the bottom
		app.insert_at = len(app.doc.nodes)
	} else {
		// Insert after the current construct
		_, e := construct_range(app, app.editor_line)
		app.insert_at = e + 1
	}
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
		if e.alias do app.import_alias = true
		// For slot filling Type submenu, push directly without make_view to avoid bucketing
		if app.slot_menu != nil && e.label == "Type" {
			// Push the Type submenu directly without make_view
			v_direct: MenuView
			v_direct.title = e.label
			v_direct.entries = make([]Entry, len(e.children))
			copy(v_direct.entries, e.children)
			append(&app.nav, v_direct)
		} else {
			push_menu(app, e.label, e.children)
		}
		return
	}
	if e.keyword != "" {
		append_kw_node(app, e.keyword, e.ident_default)
	} else if e.proc_outline {
		append_proc_node(app)
	} else if e.type_construct != "" {
		append_type_node(app, e.type_construct)
	} else if e.value_construct != "" {
		append_value_node(app, e.value_construct)
	} else if e.import_path != "" {
		// Handle replacement mode (from edit_selected)
		if app.replacing && app.replace_fi < 0 {
			// Replace the entire import node
			ni := app.replace_ni
			// Free the old node
			for f in app.doc.nodes[ni].fields {
				if len(f.text) > 0 do delete(f.text)
			}
			delete(app.doc.nodes[ni].fields)
			// Build the new import node
			n: Node
			if app.import_alias {
				append(&n.fields, Field{strings.clone("import "), false, false, ""})
				append(&n.fields, Field{strings.clone(alias_default(e.import_path)), true, false, ""})
				append(&n.fields, Field{strings.concatenate({" \"", e.import_path, "\""}), false, false, ""})
			} else {
				node_txt := import_text(e.import_path, context.temp_allocator)
				append(&n.fields, Field{strings.clone(node_txt), false, false, ""})
			}
			app.doc.nodes[ni] = n
			record_recent(app, e.import_path)
			app.import_alias = false
			app.replacing = false
			clear_nav(app)
			app.state = app.return_state
			return
		}
		if app.import_alias {
			append_aliased_import_node(app, e.import_path)
		} else {
			node := import_text(e.import_path, context.temp_allocator)
			append_text_node(app, node)
		}
		record_recent(app, e.import_path)
		app.import_alias = false
	} else if e.insert != "" {
		append_text_node(app, e.insert)
	} else if e.fill != "" {
		// Handle replacement mode (from edit_selected)
		if app.replacing {
			if app.replace_fi >= 0 {
				// Replace a field (e.g. a type)
				if len(app.doc.nodes[app.replace_ni].fields[app.replace_fi].text) > 0 {
					delete(app.doc.nodes[app.replace_ni].fields[app.replace_fi].text)
				}
				app.doc.nodes[app.replace_ni].fields[app.replace_fi] = Field{strings.clone(e.fill), true, false, "type"}
			}
			app.replacing = false
			clear_nav(app)
			clamp_field(app)
			app.state = app.return_state
			if app.slot_menu != nil {
				free_entries(app.slot_menu)
				app.slot_menu = nil
			}
			return
		}
		// Handle slot filling
		if e.fill == "__var__" {
			make_slot_variable(app, app.slot_ni, app.slot_fi)
		} else if e.fill == "__param__" {
			make_slot_param(app, app.slot_ni, app.slot_fi)
		} else if e.fill == "__stmt_decl__" || e.fill == "__stmt_typed__" || e.fill == "__stmt_assign__" || e.fill == "__stmt_call__" {
			make_body_statement(app, app.slot_ni, app.slot_fi, e.fill)
		} else if e.fill == "__stmt_multi__" {
			make_multi_decl(app, app.slot_ni, app.slot_fi)
		} else if e.fill == "__lit_num__" || e.fill == "__lit_str__" || e.fill == "__lit_rawstr__" || e.fill == "__lit_rune__" || e.fill == "__lit_true__" || e.fill == "__lit_false__" || e.fill == "__lit_nil__" || e.fill == "__lit_ref__" {
			set_slot_literal(app, app.slot_ni, app.slot_fi, e.fill)
		} else if e.fill == "__call_this_pkg__" {
			make_call_this_package(app, app.slot_ni, app.slot_fi, e.call_name)
		} else if e.fill == "__call_import__" {
			make_call_import(app, app.slot_ni, app.slot_fi, e.call_pkg)
		} else if e.fill == "__call_import_proc__" {
			make_import_proc_call(app, app.slot_ni, app.slot_fi, e.call_pkg, e.call_name)
		} else if e.fill == "__br_if__" || e.fill == "__br_ifelse__" || e.fill == "__br_switch__" || e.fill == "__br_when__" {
			make_branch_statement(app, app.slot_ni, app.slot_fi, e.fill)
		} else if e.fill == "__loop_for__" || e.fill == "__loop_forin__" || e.fill == "__loop_forinf__" {
			make_loop_statement(app, app.slot_ni, app.slot_fi, e.fill)
		} else if e.fill == "__jmp_return__" || e.fill == "__jmp_break__" || e.fill == "__jmp_continue__" || e.fill == "__jmp_fallthrough__" || e.fill == "__jmp_defer__" {
			make_jump_statement(app, app.slot_ni, app.slot_fi, e.fill)
		} else if e.fill == "__err_orreturn__" || e.fill == "__err_orelse__" || e.fill == "__err_iferr__" {
			make_error_statement(app, app.slot_ni, app.slot_fi, e.fill)
		} else if e.fill == "__scope_block__" || e.fill == "__scope_using__" || e.fill == "__scope_label__" {
			make_scope_statement(app, app.slot_ni, app.slot_fi, e.fill)
		} else {
			set_slot_type(app, app.slot_ni, app.slot_fi, e.fill)
		}
		clear_nav(app)
		clamp_field(app)
		app.state = app.return_state
		// Free the slot menu
		if app.slot_menu != nil {
			free_entries(app.slot_menu)
			app.slot_menu = nil
		}
		return
	} else {
		return // placeholder, no-op
	}
	clear_nav(app)
	focus_dot(app) // keep the green dot focused after inserting
	app.state = app.return_state
}

menu_cancel :: proc(app: ^App) {
	pop_menu(app)
	if len(app.nav) == 0 {
		app.state = app.return_state
		// Free slot menu if we're canceling out of it
		if app.slot_menu != nil {
			free_entries(app.slot_menu)
			app.slot_menu = nil
		}
	}
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
		app.menu_index = grid_nav(app.menu_index, len(MENU_ITEMS), inp)
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
		if inp.rt_held {
			// RT + D-pad: move by whole statements (construct granularity).
			if inp.up   || inp.left  do editor_move_construct(app, -1)
			if inp.down || inp.right do editor_move_construct(app, +1)
		} else {
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
		}
		if inp.cancel do app.state = .Menu
		if inp.confirm {
			if app.editor_line >= nlines {
				open_add_menu(app) // A on the green dot = Add menu
			} else {
				// Check if we're on a slot field
				ni, fi, ok := editor_target(app)
				if ok && app.doc.nodes[ni].fields[fi].slot {
					open_slot_menu(app) // A on a slot = Fill menu
				}
			}
		}
	case .Radial:
		v := current_view(app)
		v.index = grid_nav(v.index, len(v.entries), inp)
		if inp.cancel  do menu_cancel(app)
		if inp.confirm do menu_select(app)
	}
}

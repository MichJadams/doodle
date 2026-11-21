package model

// Sibling files: an Odin package is a whole folder, so what the other .odin
// files next to the open one declare at file scope can be used by name, without
// an import. load_siblings reads them (read-only: Doodle never edits them):
//   - procedures: their signature lines (Sibling_Proc). The Calls menu
//     ("Internal procedure") and call_signature (typed dots, capture dots, the
//     typed fill menus) treat them like the procedures in this file.
//   - types: each file is parsed with the editor's own parser (doc_from_source
//     into a scratch App) and its file-scope type declarations are kept as text
//     (Sibling_Type): structs, enums, unions, bit_fields, bit_sets, distinct
//     types, aliases and `#type proc` aliases. doc_type_decls / doc_type_names
//     (Type menus, Convert, bit_set[...]), the Struct literal list, struct
//     fields (p.x menus, literal fields, typed hints), enum members (Enum value,
//     switch cases), union variants (type switch cases), doc_type_rhs (aliases
//     followed by loops / enumerated arrays / indexing) all see them. The open
//     file's own declarations come first: a same-named type there shadows a
//     sibling's.
//   - imports: each file's `import` lines (Sibling_Import). A sibling type's
//     text names packages by that file's references (`strings.Builder`);
//     sibling_type_here reads such a type text from the open document's side.
// A bare-name declaration (`Vec :: point`) is kept as a candidate (kind
// "ident") and decided when looked up (sibling_kind): it's a type alias when
// the name it repeats is a type of any file of the package, the open one
// included, whatever order the files are read in.
// Declarations marked @(private="file"), and every declaration of a file
// tagged `#+private file`, are left out: other files can't see them.
// @(private) / `#+private` (package-private) ones are visible.
// No node index ever points into a sibling: only names and text are kept.
// Each file's scan is cached by path, size and modification time
// (App.sibling_cache): a refresh re-parses only the files that changed.

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// Sibling files bigger than this are skipped (keeps a refresh cheap).
SIBLING_MAX_BYTES :: 1 << 20

Sibling_Proc :: struct {
	name: string, // owned
	sig:  string, // the declaration line(s), joined: `name :: proc(a: int) -> string {` (owned)
	file: string, // base name of the file it's in (owned)
}

Sibling_Type :: struct {
	name: string, // owned
	kind: string, // a Doc_Type kind ("struct", "enum", ..., "alias"), "proc_type" (`#type proc`) or "ident" (`Vec :: point`, see sibling_kind). Static
	text: string, // the declaration after `::` through the end of its block, lines joined with "\n": `struct {\n\tx: f32,\n}` (owned)
	file: string, // base name of the file it's in (owned)
}

// An `import` of a sibling file: `import str "core:strings"` -> {file, "str", "core:strings"}.
Sibling_Import :: struct {
	file: string, // base name of the file (owned)
	ref:  string, // owned
	path: string, // owned
}

// One sibling file's scan, kept between refreshes (App.sibling_cache).
Sibling_File :: struct {
	path:    string, // full path (owned)
	size:    i64,
	mtime:   time.Time,
	procs:   [dynamic]Sibling_Proc,
	types:   [dynamic]Sibling_Type,
	imports: [dynamic]Sibling_Import,
}

// load_siblings: the procedures, types and imports of the other .odin files in
// `dir` (all but `own_file`, the open document's base name). Replaces what was
// loaded before. Only called when the open file changes or is saved, or the
// folder changes (src/app/save.odin refresh_siblings), never per frame. A file
// whose size and modification time haven't changed since the last call isn't
// read again.
load_siblings :: proc(app: ^App, dir, own_file: string) {
	free_sibling_lists(app)
	keep := make([dynamic]Sibling_File, 0, len(app.sibling_cache))
	if dir != "" {
		if files, err := os.read_directory_by_path(dir, -1, context.temp_allocator); err == nil {
			for fi in files {
				if fi.type == .Directory || !strings.has_suffix(fi.name, ".odin") do continue
				f, cached := take_cached_sibling(app, fi.fullpath)
				if cached && f.size == fi.size && f.mtime == fi.modification_time {
					append(&keep, f) // unchanged (the open file's entry is kept too, for when it's a sibling again)
					continue
				}
				if cached do free_sibling_file(&f)
				own := own_file != "" && strings.equal_fold(fi.name, own_file)
				if own || fi.size > SIBLING_MAX_BYTES do continue
				data, rerr := os.read_entire_file(fi.fullpath, context.temp_allocator)
				if rerr != nil do continue
				nf := Sibling_File{path = strings.clone(fi.fullpath), size = fi.size, mtime = fi.modification_time}
				scan_sibling_file(&nf, string(data), filepath.base(fi.name))
				append(&keep, nf)
			}
		}
	}
	// What's left: files no longer there, or another folder's.
	for &f in app.sibling_cache do free_sibling_file(&f)
	delete(app.sibling_cache)
	app.sibling_cache = keep
	for f in app.sibling_cache {
		if own_file != "" && strings.equal_fold(filepath.base(f.path), own_file) do continue
		add_sibling_file(app, f)
	}
}

// The cache entry for `path`, taken out of the cache (the caller keeps or frees it).
@(private = "file")
take_cached_sibling :: proc(app: ^App, path: string) -> (Sibling_File, bool) {
	for f, i in app.sibling_cache {
		if f.path == path {
			unordered_remove(&app.sibling_cache, i)
			return f, true
		}
	}
	return {}, false
}

// scan_sibling_source adds the top-level procedures, types and imports
// declared in `src` (the text of sibling file `file`). Pure: tests use it
// without disk.
scan_sibling_source :: proc(app: ^App, src, file: string) {
	f: Sibling_File
	defer free_sibling_file(&f)
	scan_sibling_file(&f, src, file)
	add_sibling_file(app, f)
}

// scan_sibling_file: what sibling file `file` (text `src`) declares, into f.
// Depends on nothing but the text (so it can be cached per file).
@(private = "file")
scan_sibling_file :: proc(f: ^Sibling_File, src, file: string) {
	if len(src) > SIBLING_MAX_BYTES || file_is_private(src) do return
	scan_sibling_procs(&f.procs, src, file)
	scan_sibling_types(f, src, file)
}

// add_sibling_file appends copies of a file's scan to the App's lists. A type
// a file added earlier already declares keeps that file's declaration.
@(private = "file")
add_sibling_file :: proc(app: ^App, f: Sibling_File) {
	for p in f.procs do append(&app.sibling_procs, Sibling_Proc{strings.clone(p.name), strings.clone(p.sig), strings.clone(p.file)})
	for t in f.types {
		if sibling_type_index(app, t.name) >= 0 do continue
		append(&app.sibling_types, Sibling_Type{strings.clone(t.name), t.kind, strings.clone(t.text), strings.clone(t.file)})
	}
	for imp in f.imports do append(&app.sibling_imports, Sibling_Import{strings.clone(imp.file), strings.clone(imp.ref), strings.clone(imp.path)})
}

// A `#+private file` tag above the package line: nothing in the file is
// visible to the other files.
@(private = "file")
file_is_private :: proc(src: string) -> bool {
	for raw in strings.split_lines(src, context.temp_allocator) {
		line := strings.trim_space(raw)
		if strings.has_prefix(line, "package ") do return false
		if !strings.has_prefix(line, "#+private") do continue
		return strings.trim_space(line[len("#+private"):]) == "file"
	}
	return false
}

// Does attribute text (`@(private="file")`, `@(private = "file", rodata)`) make
// a declaration file-private?
@(private = "file")
attr_file_private :: proc(line: string) -> bool {
	compact, _ := strings.remove_all(line, " ", context.temp_allocator)
	compact, _ = strings.remove_all(compact, "\t", context.temp_allocator)
	return strings.contains(compact, "private=\"file\"")
}

@(private = "file")
scan_sibling_procs :: proc(out: ^[dynamic]Sibling_Proc, src, file: string) {
	lines := strings.split_lines(src, context.temp_allocator)
	file_private := false // an @(private="file") among the attribute lines just above
	for i := 0; i < len(lines); i += 1 {
		line := strings.trim_right(lines[i], "\r")
		if len(line) == 0 || line[0] == ' ' || line[0] == '\t' do continue // top level only
		if strings.has_prefix(line, "//") do continue // a comment between the attributes and the declaration
		if strings.has_prefix(line, "@(") || strings.has_prefix(line, "@private") {
			if attr_file_private(line) do file_private = true // (any of several attribute lines)
			if !strings.contains(line, "::") do continue // an attribute on its own line
		}
		at := strings.index(line, " :: proc")
		if at < 0 {
			file_private = false
			continue
		}
		head := line[:at]
		if strings.has_prefix(head, "@(") { // `@(private) name :: proc...` on one line
			if close := strings.index_byte(head, ')'); close >= 0 do head = head[close + 1:]
		}
		name := strings.trim_space(head)
		private := file_private
		file_private = false
		if private || !is_ident(name) do continue
		// A signature broken over several lines: join until its parentheses close.
		sig := line
		depth := paren_depth(line)
		for depth > 0 && i + 1 < len(lines) {
			i += 1
			next := strings.trim_space(strings.trim_right(lines[i], "\r"))
			sig = strings.concatenate({sig, " ", next}, context.temp_allocator)
			depth += paren_depth(next)
		}
		append(out, Sibling_Proc{strings.clone(name), strings.clone(sig), strings.clone(file)})
	}
}

@(private = "file")
ident_char :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

@(private = "file")
paren_depth :: proc(s: string) -> int {
	d := 0
	for c in transmute([]u8)s {
		if c == '(' do d += 1
		else if c == ')' do d -= 1
	}
	return d
}

// The file-scope type declarations and the imports of `src`, parsed exactly as
// the open file would be (so they're recognised by the same rules as its own
// types). Only this file is looked at: a bare-name declaration whose name isn't
// a type of this file is kept as kind "ident" (decided by sibling_kind).
@(private = "file")
scan_sibling_types :: proc(f: ^Sibling_File, src, file: string) {
	scratch: App
	doc_from_source(&scratch, src)
	defer {
		clear_nav(&scratch)
		delete(scratch.nav)
		doc_reset(&scratch)
		delete(scratch.doc.nodes)
		delete(scratch.recent_imports)
		free_menus(&scratch)
	}
	imports := collect_imports(&scratch)
	defer delete(imports)
	for imp in imports do append(&f.imports, Sibling_Import{strings.clone(file), strings.clone(imp.ref), strings.clone(imp.path)})
	nodes := scratch.doc.nodes[:]
	pts := insertion_points(&scratch, context.temp_allocator)
	kinds := make(map[int]string, 8, context.temp_allocator)
	for d in own_type_decls(&scratch) do kinds[d.ni] = d.kind
	for n, ni in nodes {
		if !pts[ni] do continue
		head := strings.trim_space(node_text(n, context.temp_allocator))
		private := false
		if strings.has_prefix(head, "@") {
			private = attr_file_private(head)
			if strings.has_prefix(head, "@(") {
				close := match_bracket(head, 1)
				if close < 0 do continue
				head = strings.trim_left_space(head[close + 1:])
			} else if sp := strings.index_byte(head, ' '); sp >= 0 {
				head = strings.trim_left_space(head[sp:])
			} else {
				continue
			}
		}
		// Attribute lines above it (comments and blank lines in between skipped).
		for j := ni - 1; j >= 0; j -= 1 {
			above := strings.trim_space(node_text(nodes[j], context.temp_allocator))
			if above == "" || strings.has_prefix(above, "//") do continue
			if !strings.has_prefix(above, "@") || strings.contains(above, "::") do break
			if attr_file_private(above) do private = true
		}
		k := 0
		for k < len(head) && ident_char(head[k]) do k += 1
		name := head[:k]
		if !is_ident(name) do continue
		text, ok := decl_text_from(&scratch, ni)
		if !ok do continue
		kind, is_type := kinds[ni]
		if !is_type {
			switch {
			case strings.has_prefix(text, "#type"): kind = "proc_type"
			case is_ident(text):                    kind = "ident" // `Vec :: point`: point may be another file's type
			case:                                   continue
			}
		}
		if private do continue
		dup := false
		for t in f.types do if t.name == name { dup = true; break }
		if dup do continue
		append(&f.types, Sibling_Type{strings.clone(name), kind, strings.clone(text), strings.clone(file)})
	}
}

// decl_text_from: the declaration starting on line ni (`name :: rhs`, an
// attribute may come first): rhs through the end of its block, lines joined
// with "\n" (as saved), trimmed. Temp-allocated.
decl_text_from :: proc(app: ^App, ni: int) -> (string, bool) {
	if ni < 0 || ni >= len(app.doc.nodes) do return "", false
	end := decl_block_end(app, ni)
	b := strings.builder_make(context.temp_allocator)
	for j in ni ..= end {
		if j > ni do strings.write_byte(&b, '\n')
		strings.write_string(&b, node_source(app.doc.nodes[j], context.temp_allocator))
	}
	s := strings.to_string(b)
	at := strings.index(s, "::")
	if at < 0 do return "", false
	return strings.trim_space(s[at + 2:]), true
}

// The last line of the declaration starting on line ni: where its braces
// balance again (ni itself for a one-line declaration). Unlike construct_range
// it stays inside an enclosing file-scope `when` block.
decl_block_end :: proc(app: ^App, ni: int) -> int {
	balance := 0
	for j in ni ..< len(app.doc.nodes) {
		balance += brace_delta(app, j)
		if balance <= 0 do return j
	}
	return len(app.doc.nodes) - 1
}

@(private = "file")
free_sibling_file :: proc(f: ^Sibling_File) {
	delete(f.path)
	free_sibling_arrays(&f.procs, &f.types, &f.imports)
	f^ = {}
}

@(private = "file")
free_sibling_arrays :: proc(procs: ^[dynamic]Sibling_Proc, types: ^[dynamic]Sibling_Type, imports: ^[dynamic]Sibling_Import) {
	for p in procs {
		delete(p.name)
		delete(p.sig)
		delete(p.file)
	}
	delete(procs^)
	procs^ = nil
	for t in types {
		delete(t.name)
		delete(t.text)
		delete(t.file)
	}
	delete(types^)
	types^ = nil
	for imp in imports {
		delete(imp.file)
		delete(imp.ref)
		delete(imp.path)
	}
	delete(imports^)
	imports^ = nil
}

// The App's sibling lists (what the menus read), not the per-file cache.
@(private = "file")
free_sibling_lists :: proc(app: ^App) {
	free_sibling_arrays(&app.sibling_procs, &app.sibling_types, &app.sibling_imports)
}

// free_siblings frees everything load_siblings / scan_sibling_source made,
// the per-file cache included.
free_siblings :: proc(app: ^App) {
	free_sibling_lists(app)
	for &f in app.sibling_cache do free_sibling_file(&f)
	delete(app.sibling_cache)
	app.sibling_cache = nil
}

// The signature line of a procedure declared in another file of this package.
sibling_sig_line :: proc(app: ^App, name: string) -> (string, bool) {
	for p in app.sibling_procs do if p.name == name do return p.sig, true
	return "", false
}

// ---- Types of the other files ----

// Index of sibling declaration `name` in app.sibling_types (an "ident" one
// too), or -1.
sibling_type_index :: proc(app: ^App, name: string) -> int {
	for t, i in app.sibling_types do if t.name == name do return i
	return -1
}

// sibling_kind: the kind of sibling declaration st as seen from the open
// document. Its own kind, except for a bare-name declaration (`Vec :: point`,
// kind "ident"): an "alias" when the name it repeats is a type - one the open
// document declares (`own` = own_type_decls(app)) or, through more such
// declarations, one of the other files' - "proc_type" when that is a `#type
// proc`, and "" when it's not a type (a constant or procedure alias).
sibling_kind :: proc(app: ^App, st: Sibling_Type, own: []Doc_Type, depth := 0) -> string {
	if st.kind != "ident" do return st.kind
	if depth > 8 do return ""
	for d in own do if d.name == st.text do return "alias"
	i := sibling_type_index(app, st.text)
	if i < 0 do return ""
	k := sibling_kind(app, app.sibling_types[i], own, depth + 1)
	if k == "" || k == "proc_type" do return k
	return "alias"
}

// sibling_type: the type `name` declared in another file of this package
// (kind already decided for a bare-name alias). Callers look in the open file
// first (its declarations shadow these).
sibling_type :: proc(app: ^App, name: string) -> (Sibling_Type, bool) {
	i := sibling_type_index(app, name)
	if i < 0 do return {}, false
	st := app.sibling_types[i]
	if st.kind == "ident" {
		st.kind = sibling_kind(app, st, own_type_decls(app))
		if st.kind == "" do return {}, false
	}
	return st, true
}

// visible_sibling_type: sibling_type, unless the open document declares `name`
// at file scope itself (its declaration shadows the sibling's). For lookups
// whose own-document part doesn't stop at the first `name ::`.
visible_sibling_type :: proc(app: ^App, name: string) -> (Sibling_Type, bool) {
	st, ok := sibling_type(app, name)
	if !ok || own_declares(app, name) do return {}, false
	return st, true
}

// Does the open document declare `name ::` at file scope?
own_declares :: proc(app: ^App, name: string) -> bool {
	return name in own_decl_names(app)
}

// own_decl_names: the names the open document declares at file scope
// (`name :: ...`, an attribute may come first). Temp-allocated set.
own_decl_names :: proc(app: ^App) -> map[string]bool {
	set := make(map[string]bool, 16, context.temp_allocator)
	pts := insertion_points(app, context.temp_allocator)
	for n, ni in app.doc.nodes {
		if !pts[ni] do continue
		t := strings.trim_space(node_text(n, context.temp_allocator))
		if strings.has_prefix(t, "@(") {
			close := match_bracket(t, 1)
			if close < 0 do continue
			t = strings.trim_left_space(t[close + 1:])
		}
		k := 0
		for k < len(t) && ident_char(t[k]) do k += 1
		if k > 0 && strings.has_prefix(strings.trim_left_space(t[k:]), "::") do set[t[:k]] = true
	}
	return set
}

// sibling_type_rhs: what doc_type_rhs gives for a sibling type - the first line
// of its declaration after `::` (`struct {`, `distinct f64`, `[8]int`) - as a
// type seen from the open document (sibling_type_here).
sibling_type_rhs :: proc(app: ^App, name: string) -> (Var_Type, bool) {
	t, ok := sibling_type(app, name)
	if !ok do return {}, false
	return sibling_type_here(app, sibling_rhs_line(t), t.file), true
}

// The first line of a sibling declaration after `::`, as written in its file.
sibling_rhs_line :: proc(t: Sibling_Type) -> string {
	line := t.text
	if nl := strings.index_byte(line, '\n'); nl >= 0 do line = line[:nl]
	return strings.trim_space(line)
}

// The import path sibling file `file` refers to as `ref`, or "".
@(private = "file")
sibling_import_path :: proc(app: ^App, file, ref: string) -> string {
	for imp in app.sibling_imports do if imp.file == file && imp.ref == ref do return imp.path
	return ""
}

// sibling_type_here: type text `expr` written in sibling file `file` ("" = the
// open document: unchanged), as a type seen from the open document. Its package
// references are that file's imports: `strings.Builder` becomes the open
// document's own reference to the same package when it imports it
// (`str.Builder`), else {"Builder", "core:strings"} - a type written inside
// that package, like CORE_FIELDS rows - so fields, elements and hints resolve
// whatever the open file imports. Best effort for a mix (two packages the open
// file doesn't import, or one plus this package's types): the text unchanged.
sibling_type_here :: proc(app: ^App, expr, file: string) -> Var_Type {
	if file == "" || strings.index_byte(expr, '.') < 0 do return Var_Type{expr, ""}
	here := collect_imports(app)
	defer delete(here)
	b := strings.builder_make(context.temp_allocator) // with the open document's references
	stripped := strings.builder_make(context.temp_allocator) // with the away package's `ref.` dropped
	away := "" // a package the open document doesn't import
	mixed := false // a second such package, or also one the open document imports
	plain := make([dynamic]string, 0, 4, context.temp_allocator) // unqualified names
	k := 0
	for k < len(expr) {
		c := expr[k]
		if !ident_char(c) || (k > 0 && (ident_char(expr[k - 1]) || expr[k - 1] == '.')) {
			strings.write_byte(&b, c)
			strings.write_byte(&stripped, c)
			k += 1
			continue
		}
		j := k
		for j < len(expr) && ident_char(expr[j]) do j += 1
		word := expr[k:j]
		qualified := j < len(expr) && expr[j] == '.'
		path := qualified ? sibling_import_path(app, file, word) : ""
		if path == "" {
			if !qualified do append(&plain, word)
			strings.write_string(&b, word)
			strings.write_string(&stripped, word)
			k = j
			continue
		}
		ref := ""
		for imp in here do if imp.path == path { ref = imp.ref; break }
		if ref != "" {
			strings.write_string(&b, ref)
			strings.write_byte(&b, '.')
			mixed = true
		} else {
			strings.write_string(&b, expr[k:j + 1])
			if away != "" && away != path do mixed = true
			away = path
		}
		k = j + 1 // past the `.` (left out of `stripped`)
	}
	if away == "" || mixed do return Var_Type{strings.to_string(b), ""}
	// One of this package's types can't be read inside another package.
	own := own_decl_names(app)
	for w in plain do if w in own || sibling_type_index(app, w) >= 0 do return Var_Type{strings.to_string(b), ""}
	return Var_Type{strings.to_string(stripped), away}
}

// The items between the outer braces of a declaration text (`enum u8 { A, B = 2 }`
// -> the comma-separated items; lines count as separators; `//` comments
// dropped). Temp-allocated. Shared by enum members / union variants.
brace_items :: proc(text: string) -> []string {
	b := strings.builder_make(context.temp_allocator)
	depth := 0
	done := false
	for line in strings.split_lines(text, context.temp_allocator) {
		l := strip_comment(line)
		for k in 0 ..< len(l) {
			c := l[k]
			if c == '{' { depth += 1; if depth == 1 do continue }
			if c == '}' { depth -= 1; if depth == 0 { done = true; break } }
			if depth >= 1 do strings.write_byte(&b, c)
		}
		if done do break
		if depth >= 1 do strings.write_byte(&b, ',')
	}
	out := make([dynamic]string, 0, 8, context.temp_allocator)
	for item in split_top_level(strings.to_string(b)) {
		it := strings.trim_space(item)
		if it != "" do append(&out, it)
	}
	return out[:]
}

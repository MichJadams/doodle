package model

// LT+Y: documentation for the highlighted part, read live from the source.
//
//   1. doc_query works out what the highlighted part names:
//        a call's name           fmt.println   -> core:fmt  println
//        a value / name          win.MB_OK     -> core:sys/windows  MB_OK
//                                 x, MAX, main  -> this package
//        a dot                   its expected type (^testing.T -> core:testing T)
//        a literal (5, "hi", .A) the type expected there
//        a keyword / attribute   when, for, #partial, @(test), "contextless" -> KEYWORD_DOCS
//   2. lookup_doc finds its declaration: in this file (the nearest one above the
//      cursor: locals and parameters too), the other files of its folder, the
//      imported package's folder (core: / base: / vendor: / shared: under the
//      Odin install, or a relative path), or the built-ins (base:builtin and
//      the @builtin procedures of base:runtime). Files for another OS
//      (fmt_js.odin, `#+build js`) are only used when nothing else declares it.
//      The result: the declaration (attributes + header; a struct / enum's
//      whole body) and the comment above it (// lines or a /* */ block, or a
//      trailing // comment on the line).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Doc_Query :: struct {
	name:    string, // the symbol ("println", "T", "x") or keyword ("when", "#partial", "test")
	path:    string, // its package's import path ("core:fmt"); "" = this package / built-in
	keyword: bool,   // a keyword / directive / attribute (KEYWORD_DOCS)
	near:    int,    // 1-based source line of the cursor (picks the nearest local declaration)
}

// What the panel shows. Owned (doc_info_free).
Doc_Info :: struct {
	title:     string,   // "fmt.println"
	location:  string,   // "C:/Odin/core/fmt/fmt_os.odin:84", "this file, line 12", "keyword"
	signature: []string, // the declaration (code)
	doc:       []string, // the comment (prose)
	found:     bool,
}

doc_info_free :: proc(d: ^Doc_Info) {
	delete(d.title)
	delete(d.location)
	for s in d.signature do delete(s)
	delete(d.signature)
	for s in d.doc do delete(s)
	delete(d.doc)
	d^ = {}
}

// ---- 1. What is highlighted ----

// doc_query: the symbol / keyword the highlighted part names (ok=false: nothing,
// e.g. on a green dot).
doc_query :: proc(app: ^App) -> (q: Doc_Query, ok: bool) {
	if app.state != .Editor do return
	if on_attr_dot(app) do return Doc_Query{name = "attributes", keyword = true}, true // the purple dot
	ni, fa, fb := -1, 0, 0
	if app.tree_sticky {
		if s, sok := tree_selection(app); sok && s.kind == .Unit do ni, fa, fb = s.ni, s.fa, s.fb
	}
	if ni < 0 {
		lni, lu, lok := editor_leaf(app)
		if !lok do return
		ni, fa, fb = lni, lu.fa, lu.fb
	}
	n := app.doc.nodes[ni]
	u, found := find_unit(n, fa, fb)
	if !found do return
	q.near = node_line_starts(app)[ni]
	fi := leaf_primary_field(n, u)
	f := n.fields[fi]

	// A dot: the type it expects.
	if f.slot {
		hint, pkg := f.hint, f.hint_pkg
		if hint == "" do hint, pkg = unit_expected(app, ni, u)
		return type_query(app, hint, pkg, q.near)
	}
	// A keyword, directive, attribute or calling convention.
	if !f.editable && (f.kind == KW || f.kind == BR_KW || f.kind == ASSIGN_OP_KIND || f.kind == CONV_KIND) {
		if k := keyword_key(f.text); k != "" {
			q.name, q.keyword = k, true
			return q, true
		}
	}
	// A call's name: its package is written in front of it.
	if u.kind == .Callee {
		name := strings.trim_space(n.fields[u.fa].text)
		if k := strings.last_index_byte(name, '.'); k >= 0 do name = name[k + 1:]
		ref := callee_ref(n, u.fa)
		q.name, q.path = name, import_path_of(app, ref)
		return q, q.name != ""
	}
	// Anything else: the first name in it (`win.MB_OK`, `p.x` -> p, `&x` -> x);
	// a literal: the type expected there.
	b := strings.builder_make(context.temp_allocator)
	for i in u.fa ..< u.fb do if !n.fields[i].slot do strings.write_string(&b, n.fields[i].text)
	ref, name := first_name(strings.to_string(b))
	if name == "" || ref == "" && (name == "true" || name == "false" || name == "nil") {
		hint, pkg := unit_expected(app, ni, u)
		return type_query(app, hint, pkg, q.near)
	}
	if ref != "" {
		if path := import_path_of(app, ref); path != "" {
			q.name, q.path = name, path
			return q, true
		}
		name = ref // `p.x`: the variable p
	}
	if is_keyword_name(name) {
		q.name, q.keyword = name, true
		return q, true
	}
	q.name = name
	return q, true
}

// A type written as text (`^testing.T`, `[]u8`, `win.RECT`) -> its base type.
@(private = "file")
type_query :: proc(app: ^App, hint, pkg: string, near: int) -> (q: Doc_Query, ok: bool) {
	if hint == "" do return
	ref, name := first_name(base_type_text(hint))
	if name == "" do return
	q.near = near
	if ref != "" {
		q.name = name
		q.path = pkg != "" ? pkg : import_path_of(app, ref)
		if q.path == "" do q.name = ref
		return q, true
	}
	q.name, q.path = name, pkg
	return q, true
}

// `^[]win.RECT` -> `win.RECT`; `map[string]int` -> `int`.
@(private = "file")
base_type_text :: proc(t: string) -> string {
	s := strings.trim_space(t)
	for {
		before := s
		for p in ([]string{"^", "..", "#soa", "#simd", "#sparse", "distinct "}) do s = strings.trim_left_space(strings.trim_prefix(s, p))
		if strings.has_prefix(s, "[") || strings.has_prefix(s, "map[") {
			depth := 0
			for c, k in transmute([]u8)s {
				if c == '[' do depth += 1
				if c == ']' {
					depth -= 1
					if depth == 0 { s = s[k + 1:]; break }
				}
			}
		}
		if s == before do break
	}
	return s
}

// The first `name` or `ref.name` in a text (skipping punctuation and literals).
// ref = "" when there's no dot. name = "" when the text starts with a literal.
@(private = "file")
first_name :: proc(text: string) -> (ref, name: string) {
	s := strings.trim_space(text)
	k := 0
	for k < len(s) && !doc_ident_byte(s[k]) {
		switch s[k] {
		case '"', '\'', '`': return // a string / rune literal
		case '.': return // `.Windows`: an implicit enum value
		}
		k += 1
	}
	if k >= len(s) || (s[k] >= '0' && s[k] <= '9') do return // a number
	st := k
	for k < len(s) && doc_ident_byte(s[k]) do k += 1
	first := s[st:k]
	if k + 1 < len(s) && s[k] == '.' && doc_ident_byte(s[k + 1]) && !(s[k + 1] >= '0' && s[k + 1] <= '9') {
		e := k + 1
		for e < len(s) && doc_ident_byte(s[e]) do e += 1
		return first, s[k + 1:e]
	}
	return "", first
}

// The import path a reference names in this file ("" = not an import).
@(private = "file")
import_path_of :: proc(app: ^App, ref: string) -> string {
	if ref == "" do return ""
	imports := collect_imports(app)
	defer delete(imports)
	for imp in imports do if imp.ref == ref do return strings.clone(imp.path, context.temp_allocator)
	return ""
}

// The KEYWORD_DOCS key for a keyword field's text ("" = none).
@(private = "file")
keyword_key :: proc(text: string) -> string {
	t := strings.trim_space(text)
	t = strings.trim_suffix(t, "(") // #align( / cast( / transmute(
	if strings.has_prefix(t, "\"") do return "calling convention" // proc "c" (...)
	if eq := strings.index_byte(t, '='); eq >= 0 && !strings.has_prefix(t, "=") && !strings.has_suffix(t[:eq], "+") && !strings.has_suffix(t[:eq], "-") {
		if t[:eq] != ":" && t[:eq] != "!" && t[:eq] != "<" && t[:eq] != ">" do t = strings.trim_space(t[:eq]) // link_name="x" / private="file"
	}
	switch t {
	case "else if", "else": return "if"
	case "else when": return "when"
	case "=", ":=", "+=", "-=", "*=", "/=", "%=", "|=", "&=", "~=", "<<=", ">>=", "&~=", "%%=": return "assignment"
	}
	if strings.has_prefix(t, "cast") do return "cast"
	if strings.has_prefix(t, "transmute") do return "transmute"
	if strings.has_prefix(t, "auto_cast") do return "auto_cast"
	for k in KEYWORD_DOCS do if k.key == t do return k.key
	return ""
}

@(private = "file")
is_keyword_name :: proc(name: string) -> bool {
	for k in KEYWORD_DOCS do if k.key == name && !k.builtin do return true
	return false
}

// ---- 2. Finding the declaration ----

// lookup_doc finds the documentation for q. current_file: the open file's path
// ("" = not saved yet); dir: its folder (or the project folder); root: the Odin
// install (odin_root()); os_name: "windows" / "linux" / "darwin".
lookup_doc :: proc(app: ^App, q: Doc_Query, current_file, dir, root, os_name: string, allocator := context.allocator) -> Doc_Info {
	context.allocator = allocator
	if q.name == "" do return not_found("(nothing to look up)")
	if q.keyword do return keyword_doc(q.name)

	if q.path == "" {
		// This file (the live document, not what's on disk).
		src := doc_to_source(app, context.temp_allocator)
		lines := strings.split_lines(src, context.temp_allocator)
		if i, ok := find_decl(lines, q.name, q.near, true); ok {
			return make_info(q.name, fmt.tprintf("this file, line %d", i + 1), lines, i, q.name)
		}
		// The rest of the package: the other files in the folder.
		if dir != "" {
			if info, ok := lookup_in_dir(dir, q.name, os_name, q.name, current_file); ok do return info
		}
		// Built-ins: base:builtin, then base:runtime's @builtin procedures.
		if root != "" {
			bdir, _ := filepath.join({root, "base", "builtin"}, context.temp_allocator)
			if info, ok := lookup_in_dir(bdir, q.name, os_name, q.name, ""); ok {
				with_type_doc(&info, q.name)
				return info
			}
			rdir, _ := filepath.join({root, "base", "runtime"}, context.temp_allocator)
			if info, ok := lookup_in_dir(rdir, q.name, os_name, q.name, "", "core_builtin"); ok do return info
		}
		if k := keyword_key(q.name); k != "" do return keyword_doc(k)
		return not_found(q.name)
	}
	pdir := package_dir(q.path, dir, root)
	title := fmt.tprintf("%s.%s", alias_default(q.path), q.name)
	if pdir != "" {
		if info, ok := lookup_in_dir(pdir, q.name, os_name, title, ""); ok do return info
	}
	return not_found(title, q.path)
}

// The folder of an import path: core:fmt -> <root>/core/fmt; ../model -> next to dir.
package_dir :: proc(path, dir, root: string) -> string {
	if c := strings.index_byte(path, ':'); c > 0 {
		coll, rest := path[:c], path[c + 1:]
		switch coll {
		case "core", "base", "vendor", "shared":
			if root == "" do return ""
			p, _ := filepath.join({root, coll, rest}, context.temp_allocator)
			return p
		}
		return ""
	}
	if dir == "" do return ""
	p, _ := filepath.join({dir, path}, context.temp_allocator)
	return p
}

// Search the .odin files of one folder. Files for another OS only count when no
// other file declares the name; `only_prefix`: just the files starting with it.
@(private = "file")
lookup_in_dir :: proc(dir, name, os_name, title, skip_file: string, only_prefix := "") -> (Doc_Info, bool) {
	files, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return {}, false
	fallback_path := ""
	fallback_lines: []string
	fallback_i := -1
	for fi in files {
		if fi.type == .Directory || !strings.has_suffix(fi.name, ".odin") do continue
		if only_prefix != "" && !strings.has_prefix(fi.name, only_prefix) do continue
		if skip_file != "" && same_path(fi.fullpath, skip_file) do continue
		data, rerr := os.read_entire_file(fi.fullpath, context.temp_allocator)
		if rerr != nil do continue
		text := string(data)
		if !strings.contains(text, name) do continue
		lines := strings.split_lines(text, context.temp_allocator)
		i, ok := find_decl(lines, name, -1, false)
		if !ok do continue
		if only_prefix != "" && !has_builtin_attr(lines, i) do continue
		if file_for_os(fi.name, lines, os_name) && !strings.has_suffix(fi.name, "_test.odin") {
			return make_info(title, fmt.tprintf("%s:%d", slashes(fi.fullpath), i + 1), lines, i, name), true
		}
		if fallback_i < 0 {
			fallback_path, fallback_lines, fallback_i = fi.fullpath, lines, i
		}
	}
	if fallback_i >= 0 {
		return make_info(title, fmt.tprintf("%s:%d", slashes(fallback_path), fallback_i + 1), fallback_lines, fallback_i, name), true
	}
	return {}, false
}

@(private = "file")
slashes :: proc(p: string) -> string {
	s, _ := strings.replace_all(p, "\\", "/", context.temp_allocator)
	return s
}

@(private = "file")
same_path :: proc(a, b: string) -> bool {
	return strings.equal_fold(slashes(a), slashes(b))
}

// A runtime procedure the language makes built-in (`@builtin` / `@(builtin)` above it).
@(private = "file")
has_builtin_attr :: proc(lines: []string, i: int) -> bool {
	for j := i - 1; j >= 0; j -= 1 {
		t := strings.trim_space(lines[j])
		if !strings.has_prefix(t, "@") do return false
		if strings.contains(t, "builtin") do return true
	}
	return false
}

// OS names Odin knows in file names (`_windows.odin`) and #+build lines.
@(private = "file")
OS_TAGS := [?]string{"windows", "linux", "darwin", "freebsd", "openbsd", "netbsd", "haiku", "essence", "freestanding", "js", "wasi", "orca"}

@(private = "file")
is_os_tag :: proc(s: string) -> bool {
	for t in OS_TAGS do if t == s do return true
	return false
}

// Is this file compiled for os_name? (Its name's OS suffix and its #+build lines.)
file_for_os :: proc(file_name: string, lines: []string, os_name: string) -> bool {
	if os_name == "" do return true
	base := strings.trim_suffix(file_name, ".odin")
	parts := strings.split(base, "_", context.temp_allocator)
	// name_<os>.odin or name_<os>_<arch>.odin
	for k in max(1, len(parts) - 2) ..< len(parts) {
		if is_os_tag(parts[k]) && parts[k] != os_name do return false
	}
	for line in lines {
		t := strings.trim_space(line)
		if t == "" || strings.has_prefix(t, "//") && !strings.has_prefix(t, "//+") do continue
		if strings.has_prefix(t, "#+ignore") || strings.has_prefix(t, "//+ignore") do return false
		build := ""
		if strings.has_prefix(t, "#+build ") do build = t[len("#+build "):]
		else if strings.has_prefix(t, "//+build ") do build = t[len("//+build "):]
		else if strings.has_prefix(t, "#+") || strings.has_prefix(t, "//+") do continue
		else do break // past the file tags (package line)
		if !build_matches(build, os_name) do return false
	}
	return true
}

// `windows, linux` = either; `linux amd64` = both; `!js` = not.
@(private = "file")
build_matches :: proc(expr, os_name: string) -> bool {
	for alt in strings.split(expr, ",", context.temp_allocator) {
		all := true
		for term in strings.fields(alt, context.temp_allocator) {
			neg := strings.has_prefix(term, "!")
			tag := strings.trim_prefix(term, "!")
			if !is_os_tag(tag) do continue // an architecture etc.: assume yes
			if (tag == os_name) == neg { all = false; break }
		}
		if all do return true
	}
	return false
}

// find_decl: the line declaring `name` (`name ::`, `name :=`, `name: T`; with
// `local`, also a procedure parameter `name: T`). With near >= 1 (1-based) the
// nearest one at or above that line wins (locals shadow file-scope ones), else
// the least indented (file scope before struct fields / locals).
find_decl :: proc(lines: []string, name: string, near: int, local: bool) -> (int, bool) {
	best, best_ind, best_dist := -1, max(int), max(int)
	in_block := false
	for line, i in lines {
		if in_block {
			if strings.contains(line, "*/") do in_block = false
			continue
		}
		t := strings.trim_left_space(line)
		if strings.has_prefix(t, "/*") && !strings.contains(t, "*/") { in_block = true; continue }
		if strings.has_prefix(t, "//") do continue
		hit := decl_names(t, name)
		if !hit && local do hit = param_names(t, name)
		if !hit do continue
		ind := len(line) - len(t)
		if near >= 1 {
			dist := near - 1 - i
			if dist < 0 do dist = max(int) / 2 - dist // below the cursor: only if nothing is above
			if dist < best_dist || (dist == best_dist && ind < best_ind) { best, best_dist, best_ind = i, dist, ind }
		} else if ind < best_ind {
			best, best_ind = i, ind
		}
	}
	return best, best >= 0
}

// Does trimmed line t declare `name`? (`a, name :: ...` too.)
@(private = "file")
decl_names :: proc(t, name: string) -> bool {
	k := 0
	found := false
	for {
		for k < len(t) && t[k] == ' ' do k += 1
		st := k
		for k < len(t) && doc_ident_byte(t[k]) do k += 1
		if k == st do return false
		if t[st:k] == name do found = true
		for k < len(t) && t[k] == ' ' do k += 1
		if k < len(t) && t[k] == ',' { k += 1; continue }
		break
	}
	return found && k < len(t) && t[k] == ':'
}

// Is `name` a parameter in a procedure header on trimmed line t?
@(private = "file")
param_names :: proc(t, name: string) -> bool {
	at := strings.index(t, "proc")
	if at < 0 do return false
	open := strings.index_byte(t[at:], '(')
	if open < 0 do return false
	s := t[at + open + 1:]
	from := 0
	for {
		k := strings.index(s[from:], name)
		if k < 0 do return false
		k += from
		e := k + len(name)
		before_ok := k == 0 || !doc_ident_byte(s[k - 1]) && s[k - 1] != '.'
		after := strings.trim_left_space(s[e:])
		if before_ok && (e >= len(s) || !doc_ident_byte(s[e])) && (strings.has_prefix(after, ":") || strings.has_prefix(after, ",")) do return true
		from = e
		if from >= len(s) do return false
	}
}

// ---- The panel's content ----

@(private = "file")
make_info :: proc(title, location: string, lines: []string, i: int, name: string) -> Doc_Info {
	info: Doc_Info
	info.title = strings.clone(title)
	info.location = strings.clone(location)
	info.found = true
	sig := make([dynamic]string)
	// Attribute lines above it.
	a := i
	for a > 0 && strings.has_prefix(strings.trim_space(lines[a - 1]), "@") do a -= 1
	ind := len(lines[i]) - len(strings.trim_left_space(lines[i]))
	for j in a ..< i do append(&sig, strings.clone(dedent(lines[j], ind)))
	for s in decl_lines(lines, i) do append(&sig, strings.clone(dedent(s, ind)))
	info.signature = sig[:]
	doc := make([dynamic]string)
	for s in doc_comment(lines, a) do append(&doc, strings.clone(s))
	if len(doc) == 0 {
		// A comment at the end of the line: `MAX :: 10 // the most enemies`
		if c := trailing_comment(lines[i]); c != "" do append(&doc, strings.clone(c))
	}
	info.doc = doc[:]
	return info
}

@(private = "file")
dedent :: proc(s: string, ind: int) -> string {
	k := 0
	for k < ind && k < len(s) && (s[k] == '\t' || s[k] == ' ') do k += 1
	return strings.trim_right_space(s[k:])
}

// The declaration's lines: a procedure's header (without its body), a struct /
// enum / union / bit_field / proc group with its body, else up to where its
// brackets close.
@(private = "file")
decl_lines :: proc(lines: []string, i: int) -> []string {
	MAX_LINES :: 40
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	t := strings.trim_space(lines[i])
	colon := strings.index(t, "::")
	rhs := colon >= 0 ? strings.trim_left_space(t[colon + 2:]) : ""
	for p in ([]string{"#force_inline ", "#force_no_inline ", "distinct "}) do rhs = strings.trim_prefix(rhs, p)
	is_proc := strings.has_prefix(rhs, "proc") && !strings.has_prefix(strings.trim_left_space(rhs[4:]), "{")
	paren, brace := 0, 0
	seen_paren := false
	for j in i ..< min(len(lines), i + MAX_LINES) {
		line := lines[j]
		quote: u8 = 0
		for k := 0; k < len(line); k += 1 {
			c := line[k]
			if quote != 0 {
				if c == '\\' && quote != '`' { k += 1; continue }
				if c == quote do quote = 0
				continue
			}
			switch c {
			case '"', '\'', '`': quote = c
			case '/':
				if k + 1 < len(line) && line[k + 1] == '/' do k = len(line)
			case '(':
				paren += 1
				seen_paren = true
			case ')':
				paren -= 1
			case '{':
				if is_proc && paren == 0 && seen_paren {
					// The body starts: the header ends here.
					head := strings.trim_right_space(line[:k])
					if head != "" do append(&out, head)
					return out[:]
				}
				brace += 1
			case '}':
				brace -= 1
			}
		}
		append(&out, line)
		lt := strings.trim_space(line)
		if is_proc {
			if strings.contains(line, "---") do return out[:] // a foreign / builtin declaration
			if seen_paren && paren == 0 && !strings.has_suffix(lt, "->") && !strings.has_suffix(lt, ",") {
				// A procedure type (no body), or `{` alone on the next line.
				return out[:]
			}
		} else if paren <= 0 && brace <= 0 {
			return out[:]
		}
	}
	if len(out) == MAX_LINES do append(&out, "...")
	return out[:]
}

// The comment block right above line a (`//` lines, or a `/* */` block),
// without the comment markers, dedented.
@(private = "file")
doc_comment :: proc(lines: []string, a: int) -> []string {
	out := make([dynamic]string, 0, 8, context.temp_allocator)
	j := a - 1
	if j < 0 do return out[:]
	t := strings.trim_space(lines[j])
	if strings.has_suffix(t, "*/") {
		e := j
		for j >= 0 && !strings.contains(lines[j], "/*") do j -= 1
		if j < 0 do return out[:]
		block := make([dynamic]string, 0, 8, context.temp_allocator)
		for k in j ..= e {
			s := lines[k]
			if k == j do s = s[strings.index(s, "/*") + 2:]
			if k == e {
				if c := strings.last_index(s, "*/"); c >= 0 do s = s[:c]
			}
			append(&block, s)
		}
		return tidy(block[:])
	}
	start := j
	for start >= 0 && strings.has_prefix(strings.trim_space(lines[start]), "//") do start -= 1
	start += 1
	for k in start ..= j {
		s := strings.trim_left_space(lines[k])
		s = strings.trim_prefix(s, "//")
		if strings.has_prefix(s, "+") do continue // //+build (an old file tag)
		append(&out, s)
	}
	return tidy(out[:])
}

// Dedent by the smallest common indentation; drop blank lines at both ends.
@(private = "file")
tidy :: proc(ls: []string) -> []string {
	a, b := 0, len(ls)
	for a < b && strings.trim_space(ls[a]) == "" do a += 1
	for b > a && strings.trim_space(ls[b - 1]) == "" do b -= 1
	ls := ls[a:b]
	common := max(int)
	for s in ls {
		if strings.trim_space(s) == "" do continue
		k := 0
		for k < len(s) && (s[k] == ' ' || s[k] == '\t') do k += 1
		common = min(common, k)
	}
	if common == max(int) do common = 0
	out := make([]string, len(ls), context.temp_allocator)
	for s, i in ls do out[i] = strings.trim_right_space(len(s) >= common ? s[common:] : strings.trim_left_space(s))
	return out
}

// `X :: 1 // the doc` -> "the doc" (a // outside strings).
@(private = "file")
trailing_comment :: proc(line: string) -> string {
	quote: u8 = 0
	for k := 0; k < len(line); k += 1 {
		c := line[k]
		if quote != 0 {
			if c == '\\' && quote != '`' { k += 1; continue }
			if c == quote do quote = 0
			continue
		}
		switch c {
		case '"', '\'', '`': quote = c
		case '/':
			if k + 1 < len(line) && line[k + 1] == '/' do return strings.trim_space(line[k + 2:])
		}
	}
	return ""
}

@(private = "file")
not_found :: proc(title: string, path := "") -> Doc_Info {
	info: Doc_Info
	info.title = strings.clone(title)
	info.location = strings.clone(path != "" ? fmt.tprintf("not found in %s", path) : "not found")
	info.signature = make([]string, 0)
	info.doc = make([]string, 1)
	info.doc[0] = strings.clone("No declaration found for it here, in this folder, or in the built-ins.")
	return info
}

@(private = "file")
keyword_doc :: proc(key: string) -> Doc_Info {
	for k in KEYWORD_DOCS {
		if k.key != key do continue
		info: Doc_Info
		info.title = strings.clone(k.key)
		info.location = strings.clone(k.builtin ? "built-in" : "keyword")
		info.found = true
		sig := make([dynamic]string)
		if k.example != "" do for l in strings.split_lines(k.example, context.temp_allocator) do append(&sig, strings.clone(l))
		info.signature = sig[:]
		doc := make([dynamic]string)
		for l in strings.split_lines(k.text, context.temp_allocator) do append(&doc, strings.clone(l))
		info.doc = doc[:]
		return info
	}
	return not_found(key)
}

// base:builtin has (almost) no comments - just section headers like
// `// Procedures` right above a declaration: use KEYWORD_DOCS' text instead.
@(private = "file")
with_type_doc :: proc(info: ^Doc_Info, name: string) {
	if len(info.doc) > 1 || len(info.doc) == 1 && strings.contains(strings.trim_space(info.doc[0]), " ") do return
	for k in KEYWORD_DOCS {
		if k.key != name || !k.builtin do continue
		for s in info.doc do delete(s)
		delete(info.doc)
		doc := make([dynamic]string)
		for l in strings.split_lines(k.text, context.temp_allocator) do append(&doc, strings.clone(l))
		info.doc = doc[:]
		return
	}
	// A one-word section header isn't documentation.
	for s in info.doc do delete(s)
	delete(info.doc)
	info.doc = make([]string, 0)
}

// ---- Keywords, directives, attributes, built-in types ----

Keyword_Doc :: struct {
	key, example, text: string,
	builtin:            bool, // a built-in type / procedure (base:builtin declares it, without a comment)
}

KEYWORD_DOCS := [?]Keyword_Doc{
	{"if", "if x > 0 {\n} else if x < 0 {\n} else {\n}", "Runs a block when a condition is true. `else if` / `else` add more branches.\nAn init statement can come first: `if v, ok := m[k]; ok { ... }`.", false},
	{"for", "for i in 0 ..< 10 { }\nfor x, i in items { }\nfor cond { }\nfor { }", "Odin's only loop. Ranges (`0 ..< n` excludes n, `0 ..= n` includes it), arrays /\nslices / maps / strings (value, index), a condition, or forever. `#reverse` walks\nbackwards; `break` / `continue` work with labels too.", false},
	{"in", "for x in items { }", "Separates a loop's variables from what it iterates over. Also `x in set` (bit_set /\nmap membership) and `not_in`.", false},
	{"switch", "switch x {\ncase 1, 2:\ncase:\n}", "Picks the first `case` whose value matches. Cases don't fall through (use\n`fallthrough`). `case:` is the default. `switch v in u` switches on a union's type.\n`#partial switch` allows leaving enum / union cases out.", false},
	{"case", "case .A, .B:", "A switch branch: one or more values (or types, in a type switch). `case:` alone is\nthe default branch.", false},
	{"#partial", "#partial switch e {\ncase .A:\n}", "Lets a switch on an enum or union leave some cases out (otherwise every one must\nbe handled).", false},
	{"fallthrough", "", "Continues into the next case of a switch (cases don't fall through by default).", false},
	{"when", "when ODIN_OS == .Windows {\n} else {\n}", "A compile-time if: the condition must be a constant, and only the chosen branch is\ncompiled. At file scope it holds declarations (platform-specific code).", false},
	{"defer", "defer delete(buf)", "Runs a statement when the enclosing scope ends (in reverse order of the defers).\nTypically frees what was just allocated.", false},
	{"return", "return a, b", "Leaves the procedure, giving back its results (named results can be set and a bare\n`return` used).", false},
	{"break", "break\nbreak outer", "Leaves the innermost loop or switch (or the labelled one).", false},
	{"continue", "continue", "Skips to the next iteration of the innermost (or labelled) loop.", false},
	{"proc", "add :: proc(a, b: int) -> int {\n\treturn a + b\n}", "A procedure. Parameters can have defaults (`sep := \" \"`), results can be named.\n`proc{a, b}` is an overloaded group; `#type proc(...)` a procedure type.", false},
	{"struct", "Player :: struct {\n\tname: string,\n\thp:   int,\n}", "A record type. Directives: #packed, #raw_union, #align(N). `using` on a field\npromotes its fields.", false},
	{"enum", "Dir :: enum { North, East, South, West }", "Named constants of an integer type (int by default). Values are written `.North`\nwhere the type is known.", false},
	{"union", "Shape :: union { Circle, Square }", "A value that is one of several types (plus nil, unless #no_nil). Use `switch v in s`\nor `v, ok := s.(Circle)` to get it out.", false},
	{"bit_set", "Flags :: bit_set[Flag]", "A set of enum values (or integers in a range) stored as bits. `incl`, `excl`, `in`,\n`+` `-` `&` for union / difference / intersection.", false},
	{"bit_field", "F :: bit_field u16 {\n\ta: u8 | 4,\n}", "Packs fields into the given bits of a backing integer.", false},
	{"map", "m := make(map[string]int)", "A hash map. `m[k] = v`, `v, ok := m[k]`, `delete_key(&m, k)`, `for k, v in m`.\nCreate with make or a literal; free with delete.", false},
	{"distinct", "Meters :: distinct f64", "A new type with the same representation as another, that doesn't mix with it\nwithout a conversion.", false},
	{"using", "using p: ^Player", "Brings a struct's fields (or a package's names) into scope.", false},
	{"cast", "cast(f32)x", "Converts a value to another type (same as `f32(x)`).", false},
	{"transmute", "transmute(u32)f", "Reinterprets a value's bits as another type of the same size.", false},
	{"auto_cast", "auto_cast x", "Converts to whatever type is expected there.", false},
	{"or_return", "x := f() or_return", "If the last result of f is an error / false / nil, returns it from this procedure;\notherwise gives the other results.", false},
	{"or_else", "v := m[k] or_else 0", "Uses the value if the check succeeded (ok / non-nil), else the given default.", false},
	{"or_break", "x := next() or_break", "Leaves the loop if the check failed.", false},
	{"or_continue", "x := next() or_continue", "Skips to the next iteration if the check failed.", false},
	{"context", "context.allocator", "The implicit context every Odin procedure gets: allocator, temp_allocator, logger,\nuser data... Change a field to affect the procedures called from here.", false},
	{"import", "import \"core:fmt\"\nimport win \"core:sys/windows\"", "Makes another package's declarations available as `name.decl`.", false},
	{"package", "package main", "The package this file belongs to: every .odin file in a folder is one package.", false},
	{"foreign", "foreign lib {\n\tf :: proc() ---\n}", "Declares procedures / variables from a foreign (C) library.", false},
	{"where", "f :: proc(x: $T) where intrinsics.type_is_numeric(T)", "Compile-time conditions on a procedure's or struct's parametric types.", false},
	{"#assert", "#assert(size_of(i32) == 4)", "A compile-time assertion: compiling fails (with the message) when false.", false},
	{"#packed", "S :: struct #packed { }", "Removes the padding between a struct's fields.", false},
	{"#raw_union", "U :: struct #raw_union { }", "All fields share the same memory (a C union).", false},
	{"#align", "S :: struct #align(16) { }", "Sets a struct's minimum alignment.", false},
	{"#reverse", "#reverse for x in items { }", "Iterates a range or array from the end.", false},
	{"#unroll", "#unroll for i in 0 ..< 4 { }", "Unrolls a loop with a constant range at compile time.", false},
	{"calling convention", "cb :: proc \"c\" (x: i32)", "How a procedure is called: \"odin\" (the default, passes the context), \"contextless\"\n(no context), \"c\" / \"system\" / \"stdcall\" / \"fastcall\" (for foreign code and callbacks).", false},
	{"assignment", "x = 5\nx += 1", "`=` sets an existing variable; `:=` declares a new one; `+=` `-=` `*=` `/=` `%=`\n`|=` `&=` `~=` `<<=` `>>=` update it in place.", false},
	{"attributes", "@(test)\n@(private = \"file\")\n@(require_results)", "Attributes go on the line above a declaration. The purple dot above a procedure\nopens the ones that apply to it.", false},
	{"test", "@(test)\nadds_up :: proc(t: ^testing.T) {\n\ttesting.expect_value(t, add(2, 2), 4)\n}", "Makes the procedure a unit test: `odin test .` runs every @(test) procedure of the\npackage. It must take `t: ^testing.T` (core:testing) and return nothing. Check\nwith testing.expect / expect_value / expectf.", false},
	{"private", "@(private)\n@(private = \"file\")", "Hides the declaration from other packages (or, with = \"file\", from other files).", false},
	{"export", "@(export)", "Exports the procedure / variable from the built library (for C and dynamic linking).", false},
	{"init", "@(init)", "Runs the procedure at program start, before main. It must be \"contextless\" and take\nand return nothing.", false},
	{"fini", "@(fini)", "Runs the procedure when the program exits. Like @(init) it must be \"contextless\".", false},
	{"require_results", "@(require_results)", "Makes it an error to ignore the procedure's results.", false},
	{"thread_local", "@(thread_local)", "Each thread gets its own copy of the variable.", false},
	{"link_name", "@(link_name = \"name\")", "The symbol name used when linking (foreign or exported procedures / variables).", false},
	{"deprecated", "@(deprecated = \"use g\")", "Using the procedure gives a warning with the message.", false},
	{"cold", "@(cold)", "Hints that the procedure is rarely called.", false},
	{"int", "", "A signed integer the size of a pointer (64 bits on 64-bit targets). The default\ninteger type.", true},
	{"uint", "", "An unsigned integer the size of a pointer.", true},
	{"i8", "", "A signed 8-bit integer (-128 to 127).", true},
	{"i16", "", "A signed 16-bit integer.", true},
	{"i32", "", "A signed 32-bit integer.", true},
	{"i64", "", "A signed 64-bit integer.", true},
	{"u8", "", "An unsigned 8-bit integer (0 to 255).", true},
	{"byte", "", "An alias for u8.", true},
	{"u16", "", "An unsigned 16-bit integer.", true},
	{"u32", "", "An unsigned 32-bit integer.", true},
	{"u64", "", "An unsigned 64-bit integer.", true},
	{"uintptr", "", "An unsigned integer big enough to hold a pointer.", true},
	{"f32", "", "A 32-bit floating point number.", true},
	{"f64", "", "A 64-bit floating point number (the default for float constants).", true},
	{"bool", "", "true or false.", true},
	{"rune", "", "A Unicode code point (i32). Iterating a string gives runes.", true},
	{"string", "", "UTF-8 text: a pointer and a length (not zero-terminated). Slicing gives bytes;\n`for r in s` gives runes.", true},
	{"cstring", "", "A zero-terminated C string.", true},
	{"rawptr", "", "An untyped pointer (C's void*).", true},
	{"any", "", "Any value plus its type info (used by fmt.println and friends).", true},
	{"typeid", "", "A value identifying a type (`typeid_of(T)`, `$T: typeid` parameters).", true},
	{"len", "", "The number of elements of an array, slice, dynamic array, map or string (bytes),\nor the length of a cstring.", true},
	{"cap", "", "How many elements a dynamic array (or map) can hold before it has to grow.", true},
	{"size_of", "", "The size of a type (or a value's type) in bytes, at compile time.", true},
	{"align_of", "", "The alignment of a type in bytes, at compile time.", true},
	{"offset_of", "", "The byte offset of a field in a struct: offset_of(Player, hp).", true},
	{"type_of", "", "The type of an expression, usable where a type is expected.", true},
	{"typeid_of", "", "The typeid of a type.", true},
	{"type_info_of", "", "The runtime type information (^runtime.Type_Info) of a type.", true},
	{"min", "", "The smallest of its arguments (or the smallest value of a type: min(i32)).", true},
	{"max", "", "The largest of its arguments (or the largest value of a type: max(i32)).", true},
	{"abs", "", "The absolute value.", true},
	{"clamp", "", "clamp(x, lo, hi): x limited to the range [lo, hi].", true},
	{"raw_data", "", "A pointer to the first element of a slice / dynamic array / string.", true},
	{"swizzle", "", "Reorders / picks the components of an array: swizzle(v, 2, 1, 0).", true},
	{"complex", "", "Builds a complex number from its real and imaginary parts.", true},
	{"real", "", "The real part of a complex number.", true},
	{"imag", "", "The imaginary part of a complex number.", true},
	{"conj", "", "The complex conjugate.", true},
}

@(private = "file")
doc_ident_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

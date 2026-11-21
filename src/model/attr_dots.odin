package model

// Purple attribute dots: one above every procedure declared at file scope (and
// inside a file-scope `when`), above its attribute lines if it has any. A
// cursor stop like the green dots (between the green dot before that line and
// the line itself); A on it opens the procedure's Attributes menu - the same
// one Add > Modifiers > Attributes opens after picking the declaration
// (modifiers.odin).
//
//   ●                      green: add a declaration here
//   ◆                      purple: attributes for `adds_up`
//   @(test)
//   adds_up :: proc(t: ^testing.T) {
//
// The "test" attribute also sets the procedure up to be a test (`odin test .`
// runs every @(test) procedure of the package): `import "core:testing"` is added
// if the file has none, and a procedure without parameters gets `t: ^testing.T`.

import "core:fmt"
import "core:strings"

// attr_points: ap[i] is true when a purple attribute dot sits before line i.
attr_points :: proc(app: ^App, allocator := context.temp_allocator) -> []bool {
	n := len(app.doc.nodes)
	ap := make([]bool, n + 1, allocator)
	infos := block_infos(app)
	for i in 0 ..< n {
		if infos[i].decl_depth != 0 || is_attr_line(app.doc.nodes[i]) do continue
		if classify_decl(strings.trim_space(node_text(app.doc.nodes[i], context.temp_allocator))) != .Proc do continue
		ap[attr_group_start(app, i)] = true
	}
	return ap
}

// The first line of declaration d with its attribute lines.
attr_group_start :: proc(app: ^App, d: int) -> int {
	s := d
	for s > 0 && is_attr_line(app.doc.nodes[s - 1]) do s -= 1
	return s
}

// The procedure a purple dot before line i belongs to, or -1.
attr_dot_decl :: proc(app: ^App, i: int) -> int {
	if i < 0 || i >= len(app.doc.nodes) do return -1
	if is_attr_line(app.doc.nodes[i]) do return attr_decl_line(app, i)
	return i
}

// True when the cursor is on a purple attribute dot (still there).
on_attr_dot :: proc(app: ^App) -> bool {
	if !app.editor_dot || !app.editor_attr do return false
	i := app.editor_line
	if i < 0 || i >= len(app.doc.nodes) do return false
	return attr_points(app, context.temp_allocator)[i]
}

// Focus the purple attribute dot before line i.
focus_attr_dot :: proc(app: ^App, i: int) {
	focus_dot_at(app, i)
	app.editor_attr = true
}

// A on a purple dot: the Attributes menu for its procedure.
open_attr_dot_menu :: proc(app: ^App) {
	d := attr_dot_decl(app, app.editor_line)
	if d < 0 do return
	ctrl_open_menu(app, .Attr, d, -1, false)
}

// ---- @(test) ----

// test_attr_dim: can't be a test (Odin wants exactly `proc(t: ^testing.T)`):
// it returns something, takes parameters other than one ^testing.T, or has a
// calling convention other than "odin" (@(init) / @(fini) make it "contextless").
test_attr_dim :: proc(app: ^App, d: int) -> bool {
	inner, has_results, ok := proc_params_text(app, d)
	if !ok do return true
	if has_results do return true
	if cc := callconv_of(app.doc.nodes[d]); cc != "" && cc != "odin" do return true
	return inner != "" && !is_testing_t_param(inner, testing_ref(app))
}

// `t: ^testing.T` (any parameter name; `ref` = the name core:testing is
// imported under, "" = not imported).
@(private = "file")
is_testing_t_param :: proc(inner, ref: string) -> bool {
	if ref == "" do return false
	colon := strings.index_byte(inner, ':')
	if colon < 0 || strings.contains(inner, ",") do return false
	ty := strings.trim_space(inner[colon + 1:])
	return ty == fmt.tprintf("^%s.T", ref)
}

// The import name `core:testing` is used under ("" = not imported).
@(private = "file")
testing_ref :: proc(app: ^App) -> string {
	imports := collect_imports(app)
	defer delete(imports)
	for imp in imports do if imp.path == "core:testing" do return strings.clone(imp.ref, context.temp_allocator)
	return ""
}

// setup_test_proc: after @(test) went on the procedure at line d - the import
// and the `t: ^testing.T` parameter. Returns the procedure's (new) line.
setup_test_proc :: proc(app: ^App, decl: int) -> int {
	d := decl
	ref := testing_ref(app)
	if ref == "" {
		ref = "testing"
		at := import_insert_line(app)
		n: Node
		append(&n.fields, Field{import_text("core:testing"), false, false, "", "", ""})
		inject_at(&app.doc.nodes, at, n)
		if at <= d do d += 1
	}
	inner, _, ok := proc_params_text(app, d)
	if !ok || inner != "" do return d
	ty := fmt.tprintf("^%s.T", ref)
	fields := &app.doc.nodes[d].fields
	// A menu-built header `name :: proc( ● ) -> ● {`: the parameter goes in front
	// of its params dot (as "Add parameter" does: `t: ^testing.T, ●`).
	for f, i in fields {
		if !(f.slot && f.kind == "params") do continue
		inject_at(fields, i, Field{strings.clone("t"), true, false, "", "", ""}, Field{strings.concatenate({": ", ty}), false, false, "", "", ""}, Field{strings.clone(", "), false, false, "", "", ""})
		return d
	}
	// A loaded one `name :: proc() {`: right after the `(`.
	txt := node_text(app.doc.nodes[d], context.temp_allocator)
	at := proc_before_paren(txt)
	if at < 0 do return d
	p := strings.index_byte(txt[at:], '(')
	if p < 0 do return d
	p += at + 1
	fs := [2]Field{{strings.clone("t"), true, false, "", "", ""}, {strings.concatenate({": ", ty}), false, false, "", "", ""}}
	if insert_at_offset(&app.doc.nodes[d], p, fs[:]) < 0 {
		for f in fs do delete(f.text)
	}
	return d
}

// Where a new import line goes: after the last file-scope import, else after
// the package line (with a blank line between), else at the top.
@(private = "file")
import_insert_line :: proc(app: ^App) -> int {
	last_import, pkg := -1, -1
	infos := block_infos(app)
	for n, i in app.doc.nodes {
		if infos[i].depth != 0 do continue
		t := strings.trim_space(node_text(n, context.temp_allocator))
		if strings.has_prefix(t, "import ") do last_import = i
		if pkg < 0 && strings.has_prefix(t, "package ") do pkg = i
	}
	if last_import >= 0 do return last_import + 1
	if pkg >= 0 do return pkg + 1
	return 0
}

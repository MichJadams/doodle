package model

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

@(private = "file")
cleanup :: proc(app: ^App) {
	clear_nav(app)
	delete(app.nav)
	doc_reset(app)
	delete(app.doc.nodes)
	delete(app.recent_imports)
	free_menus(app)
}

@(private = "file")
confirm :: proc(app: ^App) { update(app, Input{confirm = true}) }

@(private = "file")
pick :: proc(app: ^App, label: string) -> bool {
	v := current_view(app)
	if v == nil do return false
	for e, i in v.entries {
		if e.label == label {
			v.index = i
			confirm(app)
			return true
		}
	}
	return false
}

@(private = "file")
has_path :: proc(entries: []Entry, path: string) -> bool {
	for e in entries {
		if e.import_path == path do return true
		if has_path(e.children, path) do return true
	}
	return false
}

// Open groups until the leaf for `path` is visible, then pick it.
@(private = "file")
drill :: proc(app: ^App, path: string) -> bool {
	for _ in 0 ..< 40 {
		v := current_view(app)
		if v == nil do return false
		for e, i in v.entries {
			if e.import_path == path {
				v.index = i
				confirm(app)
				return true
			}
		}
		opened := false
		for e, i in v.entries {
			if len(e.children) > 0 && has_path(e.children, path) {
				v.index = i
				confirm(app)
				opened = true
				break
			}
		}
		if !opened do return false
	}
	return false
}

@(private = "file")
view_labels :: proc(app: ^App) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if v := current_view(app); v != nil do for e in v.entries do append(&out, e.label)
	return out[:]
}

@(private = "file")
open_import_menu :: proc(app: ^App, aliased := false) {
	app.os_name = "windows"
	app.state = .Editor
	confirm(app) // Add root
	pick(app, "Dependencies")
	pick(app, aliased ? "Aliased import" : "Import")
}

@(test)
test_import_menu_lists_collections :: proc(t: ^testing.T) {
	for aliased in ([2]bool{false, true}) {
		app: App
		defer cleanup(&app)
		open_import_menu(&app, aliased)
		labels := view_labels(&app)
		testing.expect_value(t, len(labels), 4)
		if len(labels) == 4 {
			testing.expect_value(t, labels[0], "core")
			testing.expect_value(t, labels[1], "base")
			testing.expect_value(t, labels[2], "vendor")
			testing.expect_value(t, labels[3], "shared")
		}
	}
}

@(test)
test_import_base_lists_importable_packages :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	open_import_menu(&app)
	testing.expect(t, pick(&app, "base"))
	labels := view_labels(&app)
	testing.expect(t, slice.contains(labels, "intrinsics"))
	testing.expect(t, slice.contains(labels, "runtime"))
	testing.expect(t, slice.contains(labels, "sanitizer"))
	testing.expect(t, !slice.contains(labels, "builtin"), "base:builtin is documentation, not importable")
	testing.expect(t, drill(&app, "base:intrinsics"))
	testing.expect_value(t, node_text(app.doc.nodes[0], context.temp_allocator), "import \"base:intrinsics\"")
}

@(test)
test_import_vendor_sdl2_then_call_its_procs :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	open_import_menu(&app)
	testing.expect(t, pick(&app, "vendor"))
	testing.expect(t, drill(&app, "vendor:sdl2"))
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, node_text(app.doc.nodes[0], context.temp_allocator), "import \"vendor:sdl2\"")

	// A procedure, then Calls -> From import -> sdl2 in its body.
	confirm(&app)
	pick(&app, "Procedures")
	pick(&app, "Procedure")
	update(&app, Input{up = true}) // the body dot
	confirm(&app)
	testing.expect(t, pick(&app, "Calls"))
	testing.expect(t, pick(&app, "From import"))
	testing.expect(t, slice.contains(view_labels(&app), "sdl2"), "sdl2 should be listed under From import")
	testing.expect(t, pick(&app, "sdl2"))
	v := current_view(&app)
	found := false
	var_stack := make([dynamic][]Entry, context.temp_allocator)
	append(&var_stack, v.entries)
	for len(var_stack) > 0 && !found {
		es := pop(&var_stack)
		for e in es {
			if e.call_name == "CreateWindow" do found = true
			if len(e.children) > 0 do append(&var_stack, e.children)
		}
	}
	testing.expect(t, found, "sdl2.CreateWindow should be callable from the import")

	// Its signature comes from the generated table.
	sig := call_signature(&app, "sdl2", "CreateWindow")
	testing.expect(t, sig.known)
	testing.expect_value(t, sig.req, 6)
	testing.expect_value(t, sig.ret, "^Window")
}

@(test)
test_vendor_platform_groups_filtered :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	open_import_menu(&app)
	testing.expect(t, pick(&app, "vendor"))
	labels := view_labels(&app)
	testing.expect(t, slice.contains(labels, "directx"), "directx is Windows-only: shown on Windows")
	testing.expect(t, slice.contains(labels, "OpenGL"))
	testing.expect(t, slice.contains(labels, "raylib"))
	testing.expect(t, !slice.contains(labels, "darwin"), "darwin bindings are hidden on Windows")
	testing.expect(t, !slice.contains(labels, "android"), "android bindings are hidden on Windows")
}

@(test)
test_import_lua_gets_a_name :: proc(t: ^testing.T) {
	// `import "vendor:lua/5.4"` doesn't compile ("5.4" isn't an identifier).
	app: App
	defer cleanup(&app)
	open_import_menu(&app)
	testing.expect(t, pick(&app, "vendor"))
	testing.expect(t, drill(&app, "vendor:lua/5.4"))
	testing.expect_value(t, node_text(app.doc.nodes[0], context.temp_allocator), "import lua \"vendor:lua/5.4\"")
	imports := collect_imports(&app)
	defer delete(imports)
	testing.expect_value(t, len(imports), 1)
	if len(imports) == 1 do testing.expect_value(t, imports[0].ref, "lua")
	testing.expect_value(t, alias_default("vendor:sdl2/image"), "image")
	testing.expect(t, !needs_import_alias("vendor:sdl2/image"))
	testing.expect(t, needs_import_alias("vendor:lua/5.4"))
}

@(test)
test_shared_tree_empty_placeholder :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "doodle_shared_*", context.allocator)
	testing.expect(t, err == nil)
	defer { os.remove_all(root); delete(root) }
	entries := build_shared_tree(root)
	defer free_entries(entries)
	testing.expect_value(t, len(entries), 1)
	if len(entries) == 1 {
		testing.expect(t, entries[0].dim)
		testing.expect(t, strings.has_prefix(entries[0].label, "(empty"))
		testing.expect(t, !is_leaf(entries[0]), "the placeholder isn't actionable")
	}
}

@(test)
test_shared_tree_lists_packages :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "doodle_shared_*", context.allocator)
	testing.expect(t, err == nil)
	defer { os.remove_all(root); delete(root) }
	mk :: proc(parts: ..string) -> string {
		p, _ := filepath.join(parts, context.temp_allocator)
		return p
	}
	os.make_directory_all(mk(root, "shared", "utils"))
	os.make_directory_all(mk(root, "shared", "gfx", "sprites"))
	os.make_directory_all(mk(root, "shared", "notes")) // no .odin: not a package
	_ = os.write_entire_file(mk(root, "shared", "utils", "utils.odin"), transmute([]u8)string("package utils\n"))
	_ = os.write_entire_file(mk(root, "shared", "gfx", "sprites", "s.odin"), transmute([]u8)string("package sprites\n"))
	_ = os.write_entire_file(mk(root, "shared", "notes", "readme.txt"), transmute([]u8)string("hi"))

	entries := build_shared_tree(root)
	defer free_entries(entries)
	testing.expect_value(t, len(entries), 2)
	if len(entries) == 2 {
		testing.expect_value(t, entries[0].label, "gfx/sprites")
		testing.expect_value(t, entries[0].import_path, "shared:gfx/sprites")
		testing.expect_value(t, entries[1].label, "utils")
		testing.expect_value(t, entries[1].import_path, "shared:utils")
		testing.expect(t, is_leaf(entries[1]))
	}
}

@(test)
test_odin_root_found :: proc(t: ^testing.T) {
	root := odin_root()
	testing.expect(t, root != "")
}

// ---- Generated tables ----

@(private = "file")
fields_of :: proc(path, type_name: string) -> []CoreField {
	out := make([dynamic]CoreField, context.temp_allocator)
	for f in CORE_FIELDS do if f.path == path && f.type_name == type_name do append(&out, f)
	return out[:]
}

@(private = "file")
expect_fields :: proc(t: ^testing.T, path, type_name: string, want: []CoreField, loc := #caller_location) {
	got := fields_of(path, type_name)
	testing.expect_value(t, len(got), len(want), loc = loc)
	for w, i in want {
		if i >= len(got) do break
		testing.expect_value(t, got[i], CoreField{path, type_name, w.name, w.type, w.using_field}, loc = loc)
	}
}

@(test)
test_core_fields_windows_structs :: proc(t: ^testing.T) {
	W :: "core:sys/windows"
	expect_fields(t, W, "PAINTSTRUCT", {
		{name = "hdc", type = "HDC"},
		{name = "fErase", type = "BOOL"},
		{name = "rcPaint", type = "RECT"},
		{name = "fRestore", type = "BOOL"},
		{name = "fIncUpdate", type = "BOOL"},
		{name = "rgbReserved", type = "[32]BYTE"},
	})
	expect_fields(t, W, "WNDCLASSW", {
		{name = "style", type = "UINT"},
		{name = "lpfnWndProc", type = "WNDPROC"},
		{name = "cbClsExtra", type = "c_int"},
		{name = "cbWndExtra", type = "c_int"},
		{name = "hInstance", type = "HINSTANCE"},
		{name = "hIcon", type = "HICON"},
		{name = "hCursor", type = "HCURSOR"},
		{name = "hbrBackground", type = "HBRUSH"},
		{name = "lpszMenuName", type = "LPCWSTR"},
		{name = "lpszClassName", type = "LPCWSTR"},
	})
	expect_fields(t, W, "RECT", { // `RECT :: struct {left, top, right, bottom: LONG}`
		{name = "left", type = "LONG"},
		{name = "top", type = "LONG"},
		{name = "right", type = "LONG"},
		{name = "bottom", type = "LONG"},
	})
	expect_fields(t, W, "POINT", {{name = "x", type = "LONG"}, {name = "y", type = "LONG"}})
	expect_fields(t, W, "MSG", {
		{name = "hwnd", type = "HWND"},
		{name = "message", type = "UINT"},
		{name = "wParam", type = "WPARAM"},
		{name = "lParam", type = "LPARAM"},
		{name = "time", type = "DWORD"},
		{name = "pt", type = "POINT"},
	})
	// `using _: struct #raw_union {...}`: the anonymous `_` is never listed; the
	// fields it promotes are (Odin accepts `inp.mi` and `INPUT{mi = ...}`).
	expect_fields(t, W, "INPUT", {
		{name = "type", type = "INPUT_TYPE"},
		{name = "mi", type = "MOUSEINPUT"},
		{name = "ki", type = "KEYBDINPUT"},
		{name = "hi", type = "HARDWAREINPUT"},
	})
}

@(test)
test_core_fields_vendor_and_base :: proc(t: ^testing.T) {
	expect_fields(t, "vendor:sdl2", "Rect", {
		{name = "x", type = "c.int"},
		{name = "y", type = "c.int"},
		{name = "w", type = "c.int"},
		{name = "h", type = "c.int"},
	})
	ev := fields_of("vendor:sdl2", "Event") // struct #raw_union
	testing.expect(t, len(ev) > 10)
	if len(ev) > 1 {
		testing.expect_value(t, ev[0].name, "type")
		testing.expect_value(t, ev[0].type, "EventType")
		testing.expect_value(t, ev[1].name, "common")
	}
	expect_fields(t, "base:runtime", "Allocator", {
		{name = "procedure", type = "Allocator_Proc"},
		{name = "data", type = "rawptr"},
	})
}

@(test)
test_core_enum_members :: proc(t: ^testing.T) {
	got := make([dynamic]string, context.temp_allocator)
	for m in CORE_ENUM_MEMBERS do if m.path == "base:runtime" && m.type_name == "Allocator_Mode" do append(&got, m.name)
	want := []string{"Alloc", "Free", "Free_All", "Resize", "Query_Features", "Query_Info", "Alloc_Non_Zeroed", "Resize_Non_Zeroed"}
	testing.expect(t, slice.equal(got[:], want), "base:runtime Allocator_Mode members")

	clear(&got)
	for m in CORE_ENUM_MEMBERS do if m.path == "vendor:sdl2" && m.type_name == "EventType" do append(&got, m.name)
	testing.expect(t, len(got) > 10)
	if len(got) >= 2 {
		testing.expect_value(t, got[0], "FIRSTEVENT") // `FIRSTEVENT = 0, /**< ... */`: values and comments dropped
		testing.expect_value(t, got[1], "QUIT")
	}
}

@(test)
test_core_procs_other_collections :: proc(t: ^testing.T) {
	find :: proc(path, name: string) -> (CoreProc, bool) {
		for p in CORE_PROCS do if p.path == path && p.name == name do return p, true
		return {}, false
	}
	// base:intrinsics procedures are bodiless declarations (`--- `).
	p, ok := find("base:intrinsics", "alloca")
	testing.expect(t, ok, "base:intrinsics alloca")
	testing.expect_value(t, p.req, 2)
	testing.expect_value(t, p.ret, "[^]u8")
	// vendor:vulkan procedures are globals of a proc type.
	p, ok = find("vendor:vulkan", "CreateInstance")
	testing.expect(t, ok, "vendor:vulkan CreateInstance")
	testing.expect_value(t, p.req, 3)
	testing.expect_value(t, p.ret, "Result")
	// vendor:OpenGL wrappers live inside `when` blocks.
	p, ok = find("vendor:OpenGL", "ClearColor")
	testing.expect(t, ok, "vendor:OpenGL ClearColor")
	testing.expect_value(t, p.req, 4)
	// Private procedures aren't listed.
	_, ok = find("core:compress/deflate", "deflate_compress")
	testing.expect(t, !ok, "@(private) procedures are left out")
}

@(test)
test_builtin_procs_signatures :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	sig := call_signature(&app, "", "copy")
	testing.expect(t, sig.known)
	testing.expect_value(t, sig.req, 2)
	testing.expect_value(t, sig.ret, "int")
	sig = call_signature(&app, "", "inject_at")
	testing.expect_value(t, sig.req, 3)
	testing.expect(t, sig.variadic)
	sig = call_signature(&app, "", "card")
	testing.expect_value(t, sig.ret, "int")
	sig = call_signature(&app, "", "unreachable")
	testing.expect_value(t, sig.req, 0)
	testing.expect_value(t, sig.ret, RET_NONE)
	for name in ([]string{"len", "make", "delete", "append", "clear", "min", "max", "abs", "clamp", "offset_of", "type_of", "typeid_of", "swizzle", "complex", "real", "imag", "conj", "expand_values", "raw_data", "card"}) {
		_, ok := builtin_proc(name)
		testing.expectf(t, ok, "built-in %s", name)
	}
}

package model

// Acceptance: the user's Handmade Hero file, built from a NEW empty project
// with controller-equivalent input only.
//
//   - New Project = A on the main menu's "New Project" (update in .Menu).
//   - Every cursor move is a D-pad press (update with up/down/left/right); the
//     helpers only compute WHERE to go, the presses get there or the step fails.
//   - Every menu pick moves the menu highlight with D-pad presses (menu_nav via
//     update) and confirms with A; a grayed entry picked is logged.
//   - A = update(confirm), B = update(cancel), Y = change_selected,
//     LT+B = delete_selected, LT+A = edit_selected (number keypad; text
//     tools on names / strings / comments: Case, Escape, Word case, Backticks),
//     dictation = set_field_text on editor_target (what src/app/main.odin does),
//     only for names, strings and comment text, and only what push-to-talk
//     gives: lowercase snake_case names, spaced words in strings / comments -
//     WHITENESS, "WM_SIZE\n", "HandmadeHeroWindowClass", `static DWORD
//     Operation` and TODO come from the LT+A text tools.
//   - Saving = file_text: format_doc, the source without editor-only "●"
//     lines, a final newline (src/app/save.odin write_doc).
//
// `odin check` of the result runs with DOODLE_ODIN (path to odin.exe), else
// C:/Odin/odin.exe when it exists; the file goes to
// <temp>/doodle_exact_build/main.odin.

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// The user's file exactly (it ends with a newline), with the one deliberate
// deviation: `for win32.GetMessageW(...) > 0 {`.
@(private = "file")
EXACT_TARGET :: "package handmade\n\n" +
	"import win32 \"core:sys/windows\"\n\n" +
	"// Kept local in case your Odin version's gdi32 bindings don't export these\n" +
	"WHITENESS :: 0x00FF0062\n" +
	"BLACKNESS :: 0x00000042\n\n" +
	"// Stands in for Casey's `static DWORD Operation` inside the callback\n" +
	"operation: u32 = WHITENESS\n\n" +
	"main_window_callback :: proc \"system\" (\n" +
	"\twindow: win32.HWND,\n" +
	"\tmessage: win32.UINT,\n" +
	"\tw_param: win32.WPARAM,\n" +
	"\tl_param: win32.LPARAM,\n" +
	") -> win32.LRESULT {\n" +
	"\tresult: win32.LRESULT = 0\n\n" +
	"\tswitch message {\n" +
	"\tcase win32.WM_SIZE:\n" +
	"\t\twin32.OutputDebugStringA(\"WM_SIZE\\n\")\n" +
	"\tcase win32.WM_DESTROY:\n" +
	"\t\twin32.OutputDebugStringA(\"WM_DESTROY\\n\")\n" +
	"\tcase win32.WM_CLOSE:\n" +
	"\t\twin32.OutputDebugStringA(\"WM_CLOSE\\n\")\n" +
	"\tcase win32.WM_ACTIVATEAPP:\n" +
	"\t\twin32.OutputDebugStringA(\"WM_ACTIVATEAPP\\n\")\n" +
	"\tcase win32.WM_PAINT:\n" +
	"\t\tpaint: win32.PAINTSTRUCT\n" +
	"\t\tdevice_context := win32.BeginPaint(window, &paint)\n" +
	"\t\tx := paint.rcPaint.left\n" +
	"\t\ty := paint.rcPaint.top\n" +
	"\t\twidth := paint.rcPaint.right - paint.rcPaint.left\n" +
	"\t\theight := paint.rcPaint.bottom - paint.rcPaint.top\n" +
	"\t\twin32.PatBlt(device_context, x, y, width, height, operation)\n" +
	"\t\toperation = BLACKNESS if operation == WHITENESS else WHITENESS\n" +
	"\t\twin32.EndPaint(window, &paint)\n" +
	"\tcase:\n" +
	"\t\t// Casey logs here too; that gets noisy fast, so I left it out\n" +
	"\t\tresult = win32.DefWindowProcW(window, message, w_param, l_param)\n" +
	"\t}\n\n" +
	"\treturn result\n" +
	"}\n\n" +
	"main :: proc() {\n" +
	"\tinstance := win32.HINSTANCE(win32.GetModuleHandleW(nil))\n\n" +
	"\twindow_class := win32.WNDCLASSW {\n" +
	"\t\tstyle         = win32.CS_OWNDC | win32.CS_HREDRAW | win32.CS_VREDRAW,\n" +
	"\t\tlpfnWndProc   = main_window_callback,\n" +
	"\t\thInstance     = instance,\n" +
	"\t\tlpszClassName = win32.L(\"HandmadeHeroWindowClass\"),\n" +
	"\t}\n\n" +
	"\tif win32.RegisterClassW(&window_class) != 0 {\n" +
	"\t\twindow_handle := win32.CreateWindowExW(\n" +
	"\t\t\t0,\n" +
	"\t\t\twindow_class.lpszClassName,\n" +
	"\t\t\twin32.L(\"HandmadeHero\"),\n" +
	"\t\t\twin32.WS_OVERLAPPEDWINDOW | win32.WS_VISIBLE,\n" +
	"\t\t\twin32.CW_USEDEFAULT, win32.CW_USEDEFAULT,\n" +
	"\t\t\twin32.CW_USEDEFAULT, win32.CW_USEDEFAULT,\n" +
	"\t\t\tnil, nil, instance, nil,\n" +
	"\t\t)\n\n" +
	"\t\tif window_handle != nil {\n" +
	"\t\t\tmessage: win32.MSG\n" +
	"\t\t\tfor win32.GetMessageW(&message, nil, 0, 0) > 0 {\n" +
	"\t\t\t\twin32.TranslateMessage(&message)\n" +
	"\t\t\t\twin32.DispatchMessageW(&message)\n" +
	"\t\t\t}\n" +
	"\t\t} else {\n" +
	"\t\t\t// TODO logging\n" +
	"\t\t}\n" +
	"\t} else {\n" +
	"\t\t// TODO logging\n" +
	"\t}\n" +
	"}\n"

// ---------------------------------------------------------------------------
// The controller.

@(private = "file")
Pad :: struct {
	t:       ^testing.T,
	app:     ^App,
	presses: int,
	notes:   [dynamic]string, // soft findings (grayed picks, ...), logged at the end
}

@(private = "file")
note :: proc(p: ^Pad, format: string, args: ..any) {
	append(&p.notes, fmt.aprintf(format, ..args, allocator = context.temp_allocator))
}

@(private = "file")
press :: proc(p: ^Pad, inp: Input) {
	p.presses += 1
	update(p.app, inp)
}

@(private = "file") press_a :: proc(p: ^Pad) { press(p, Input{confirm = true}) }
@(private = "file") press_y :: proc(p: ^Pad) { p.presses += 1; change_selected(p.app) }     // Y (main.odin)
@(private = "file") press_lt_b :: proc(p: ^Pad) { p.presses += 1; delete_selected(p.app) } // LT+B
@(private = "file") press_lt_a :: proc(p: ^Pad) { p.presses += 1; edit_selected(p.app) }   // LT+A

// B until the editor is back in plain cursor mode.
@(private = "file")
back_out :: proc(p: ^Pad) {
	for _ in 0 ..< 16 {
		if p.app.state == .Editor && !p.app.ref_pick_active && !p.app.mod_pick_active do return
		press(p, Input{cancel = true})
	}
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

@(private = "file")
src :: proc(app: ^App) -> string { return doc_to_source(app, context.temp_allocator) }

@(private = "file")
line_with :: proc(app: ^App, text: string, from := 0) -> int {
	for i in max(from, 0) ..< len(app.doc.nodes) do if strings.contains(node_text(app.doc.nodes[i], context.temp_allocator), text) do return i
	return -1
}

@(private = "file")
line_src :: proc(app: ^App, ni: int) -> string {
	if ni < 0 || ni >= len(app.doc.nodes) do return "<no line>"
	return strings.trim_space(node_source(app.doc.nodes[ni], context.temp_allocator))
}

@(private = "file")
body_line :: proc(app: ^App, from: int) -> int {
	if from < 0 do return -1
	for i in from ..< len(app.doc.nodes) do if is_body_slot_line(app.doc.nodes[i]) do return i
	return -1
}

// ---- D-pad cursor moves ----

// Move the editor cursor with D-pad presses to the green dot before line
// `line` (dot) or onto field fi of line `line`. Fails when it can't get there.
@(private = "file")
dpad_to :: proc(p: ^Pad, line: int, dot: bool, fi := -1, loc := #caller_location) -> bool {
	app := p.app
	back_out(p)
	if !testing.expectf(p.t, app.state == .Editor, "not in the editor", loc = loc) do return false
	if !dot && (line < 0 || line >= len(app.doc.nodes)) {
		testing.expectf(p.t, false, "no line %d", line, loc = loc)
		return false
	}
	// Where focus_* would put the cursor; then restore and walk there.
	sl, sf, sd, sa := app.editor_line, app.editor_field, app.editor_dot, app.editor_attr
	if dot do focus_dot_at(app, line)
	else do focus_field_index(app, line, fi)
	tl, tf, td := app.editor_line, app.editor_field, on_dot(app)
	tk := cursor_stop_key(app)
	app.editor_line, app.editor_field, app.editor_dot, app.editor_attr = sl, sf, sd, sa
	last_dir := 0
	for _ in 0 ..< 4000 {
		ck := cursor_stop_key(app)
		if ck == tk do break
		dir := ck < tk ? 1 : -1
		if last_dir != 0 && dir != last_dir {
			testing.expectf(p.t, false, "D-pad: line %d (dot=%v) is not a cursor stop (%q)", tl, td, line_src(app, tl), loc = loc)
			return false
		}
		last_dir = dir
		before_field := app.editor_field
		press(p, Input{down = dir > 0, up = dir < 0})
		// (Up/Down first step through the rows of a line broken over several rows.)
		if cursor_stop_key(app) == ck && app.editor_field == before_field {
			testing.expectf(p.t, false, "D-pad stuck at line %d on the way to %d", app.editor_line, tl, loc = loc)
			return false
		}
	}
	if td do return true
	for _ in 0 ..< 200 {
		if app.editor_field == tf do return true
		before := app.editor_field
		// A line broken over rows: Up/Down to the target's row, then along it
		// (Left at a row's start wraps to its end - row_nav.odin).
		rows := leaf_rows(app.doc.nodes[app.editor_line])
		cr, tr := rows[clamp(app.editor_field, 0, len(rows) - 1)], rows[clamp(tf, 0, len(rows) - 1)]
		if cr != tr do press(p, Input{down = cr < tr, up = cr > tr})
		else do press(p, Input{right = app.editor_field < tf, left = app.editor_field > tf})
		if app.editor_field == before do break
	}
	testing.expectf(p.t, app.editor_field == tf, "D-pad left/right can't reach field %d of %q", fi, line_src(app, line), loc = loc)
	return app.editor_field == tf
}

// The field index of the nth slot of `kind` on line ni.
@(private = "file")
nth_slot :: proc(app: ^App, ni, nth: int, kind: string) -> int {
	if ni < 0 || ni >= len(app.doc.nodes) do return -1
	seen := 0
	for f, i in app.doc.nodes[ni].fields do if f.slot && f.kind == kind {
		if seen == nth do return i
		seen += 1
	}
	return -1
}

// D-pad to the nth dot of `kind` on line ni, then A.
@(private = "file")
open_dot :: proc(p: ^Pad, ni, nth: int, kind := "value", loc := #caller_location) -> bool {
	fi := nth_slot(p.app, ni, nth, kind)
	if !testing.expectf(p.t, fi >= 0, "no %s dot #%d on %q", kind, nth, line_src(p.app, ni), loc = loc) do return false
	if !dpad_to(p, ni, false, fi, loc) do return false
	tn, tf, ok := editor_target(p.app)
	if !testing.expectf(p.t, ok && tn == ni && tf == fi, "the cursor is not on the dot (%d,%d) of %q", ni, fi, line_src(p.app, ni), loc = loc) do return false
	press_a(p)
	return testing.expectf(p.t, p.app.state == .Radial, "A on the %s dot of %q opened no menu", kind, line_src(p.app, ni), loc = loc)
}

// ---- Menus ----

@(private = "file")
labels :: proc(app: ^App) -> string {
	v := current_view(app)
	if v == nil do return "<no menu>"
	out := make([dynamic]string, context.temp_allocator)
	for e in v.entries do append(&out, e.label)
	return strings.join(out[:], " | ", context.temp_allocator)
}

// Move the menu highlight to entry `target` with D-pad presses (shortest path
// through menu_nav), then A.
@(private = "file")
menu_go :: proc(p: ^Pad, target: int, loc := #caller_location) -> bool {
	v := current_view(p.app)
	n := len(v.entries)
	dirs := [4]Input{{up = true}, {down = true}, {left = true}, {right = true}}
	prev := make([]int, n, context.temp_allocator)
	how := make([]int, n, context.temp_allocator)
	for &x in prev do x = -2
	start := clamp(v.index, 0, n - 1)
	saved := v.index
	prev[start] = -1
	queue := make([dynamic]int, 0, n, context.temp_allocator)
	append(&queue, start)
	for qi := 0; qi < len(queue) && prev[target] == -2; qi += 1 {
		s := queue[qi]
		for d, k in dirs {
			v.index = s
			nx := menu_nav(v, d)
			if nx >= 0 && nx < n && prev[nx] == -2 { prev[nx] = s; how[nx] = k; append(&queue, nx) }
		}
	}
	v.index = saved
	if !testing.expectf(p.t, prev[target] != -2, "menu %q: %q is not reachable with the D-pad", v.title, v.entries[target].label, loc = loc) do return false
	path := make([dynamic]int, 0, 16, context.temp_allocator)
	for s := target; prev[s] != -1; s = prev[s] do append(&path, how[s])
	for i := len(path) - 1; i >= 0; i -= 1 do press(p, dirs[path[i]])
	v = current_view(p.app)
	if !testing.expectf(p.t, v != nil && v.index == target, "menu highlight didn't land on the entry", loc = loc) do return false
	if v.entries[target].dim do note(p, "picked a GRAYED entry %q in menu %q", v.entries[target].label, v.title)
	press_a(p)
	return true
}

// Pick `label` in the open menu.
@(private = "file")
pick :: proc(p: ^Pad, label: string, loc := #caller_location) -> bool {
	v := current_view(p.app)
	if v == nil || p.app.state != .Radial {
		testing.expectf(p.t, false, "no menu open (wanted %q)", label, loc = loc)
		return false
	}
	for e, i in v.entries do if e.label == label do return menu_go(p, i, loc)
	testing.expectf(p.t, false, "no %q in menu %q: %s", label, v.title, labels(p.app), loc = loc)
	return false
}

@(private = "file")
path_to :: proc(entries: []Entry, label, fill: string, out: ^[dynamic]Entry) -> bool {
	for e in entries {
		append(out, e)
		if len(e.children) == 0 && e.label == label && (fill == "" || e.fill == fill) do return true
		if len(e.children) > 0 && path_to(e.children, label, fill, out) do return true
		pop(out)
	}
	return false
}

// From the open menu, walk down (one A per level) to the leaf `label`.
@(private = "file")
pick_leaf :: proc(p: ^Pad, label: string, fill := "", loc := #caller_location) -> bool {
	v := current_view(p.app)
	if !testing.expectf(p.t, v != nil, "no menu open (wanted %q)", label, loc = loc) do return false
	steps := make([dynamic]Entry, 0, 8, context.temp_allocator)
	if !testing.expectf(p.t, path_to(v.entries, label, fill, &steps), "%q should be reachable from menu %q", label, v.title, loc = loc) do return false
	for want in steps {
		v = current_view(p.app)
		if !testing.expectf(p.t, v != nil && p.app.state == .Radial, "menu closed on the way to %q", label, loc = loc) do return false
		found := -1
		for e, i in v.entries {
			same := len(want.children) > 0 ? raw_data(e.children) == raw_data(want.children) : (e.label == want.label && e.fill == want.fill && e.call_name == want.call_name && e.call_pkg == want.call_pkg)
			if same { found = i; break }
		}
		if !testing.expectf(p.t, found >= 0, "step %q not in menu %q", want.label, v.title, loc = loc) do return false
		if !menu_go(p, found, loc) do return false
	}
	return true
}

// ---- Dots and fills ----

// "Reference": left/right through the names, A, then the "Pass as" entry.
@(private = "file")
ref_choose :: proc(p: ^Pad, name: string, loc := #caller_location) -> bool {
	if !testing.expect(p.t, p.app.ref_pick_active, "in Reference pick mode", loc = loc) do return false
	cur :: proc(app: ^App) -> string {
		ni, fi, ok := editor_target(app)
		return ok ? app.doc.nodes[ni].fields[fi].text : "<none>"
	}
	for _ in 0 ..< 64 { if cur(p.app) == name do break; press(p, Input{right = true}) }
	for _ in 0 ..< 64 { if cur(p.app) == name do break; press(p, Input{left = true}) }
	if !testing.expectf(p.t, cur(p.app) == name, "%q should be pickable", name, loc = loc) do return false
	press_a(p)
	return true
}

@(private = "file")
fill_ref :: proc(p: ^Pad, ni: int, name: string, pass_as := "", loc := #caller_location) {
	if !open_dot(p, ni, 0, loc = loc) || !pick(p, "Reference", loc) do return
	if ref_choose(p, name, loc) && p.app.state == .Radial do pick(p, pass_as == "" ? name : pass_as, loc)
}

// Value > Number, then LT+A and the keypad for anything but 0.
@(private = "file")
fill_number :: proc(p: ^Pad, ni: int, keys: ..string, loc := #caller_location) {
	if !open_dot(p, ni, 0, loc = loc) || !pick(p, "Number", loc) do return
	eni, efi, ok := editor_target(p.app)
	if !testing.expectf(p.t, ok && eni == ni && p.app.doc.nodes[eni].fields[efi].text == "0", "the cursor should be on the new 0 (%q)", line_src(p.app, ni), loc = loc) do return
	if len(keys) == 0 do return
	press_lt_a(p)
	if !testing.expectf(p.t, p.app.state == .Radial, "LT+A on a number should open the keypad", loc = loc) do return
	for k in keys do pick(p, k, loc)
	pick(p, "OK", loc)
}

@(private = "file")
fill_nil :: proc(p: ^Pad, ni: int, loc := #caller_location) {
	if open_dot(p, ni, 0, loc = loc) do pick(p, "nil", loc)
}

@(private = "file")
fill_op :: proc(p: ^Pad, ni: int, group, op: string, loc := #caller_location) {
	if open_dot(p, ni, 0, loc = loc) && pick(p, "Operator", loc) && pick(p, group, loc) do pick(p, op, loc)
}

@(private = "file")
fill_const :: proc(p: ^Pad, ni: int, name: string, loc := #caller_location) {
	if open_dot(p, ni, 0, loc = loc) && pick(p, "Constant", loc) do pick_leaf(p, name, CONST_IMPORT_FILL, loc)
}

@(private = "file")
fill_call :: proc(p: ^Pad, ni: int, name: string, loc := #caller_location) {
	if open_dot(p, ni, 0, loc = loc) && pick(p, "Call", loc) && pick(p, "From import", loc) && pick(p, "win32", loc) {
		pick_leaf(p, name, "__call_import_proc__", loc)
	}
}

// Dictation into the highlighted field (main.odin: set_field_text on editor_target).
@(private = "file")
dictate_here :: proc(p: ^Pad, text: string, loc := #caller_location) -> bool {
	ni, fi, ok := editor_target(p.app)
	if !testing.expectf(p.t, ok && p.app.doc.nodes[ni].fields[fi].editable, "the mic needs an editable field under the cursor", loc = loc) do return false
	set_field_text(p.app, ni, fi, text)
	return true
}

// LT+A on the highlighted name / string / comment text, then the text tool
// menu path (text_tools.odin); the menu closes on the tool.
@(private = "file")
text_tools :: proc(p: ^Pad, path: ..string, loc := #caller_location) {
	press_lt_a(p)
	if !testing.expectf(p.t, p.app.state == .Radial, "LT+A should open the text tools", loc = loc) do return
	for l in path do if !pick(p, l, loc) do return
	testing.expectf(p.t, p.app.state == .Editor, "the text tool should close its menu", loc = loc)
}

// String > "..." string, then dictation into its (highlighted) text.
@(private = "file")
fill_string :: proc(p: ^Pad, ni: int, text: string, loc := #caller_location) {
	if !open_dot(p, ni, 0, loc = loc) || !pick(p, "String", loc) || !pick(p, "\"...\"  string", loc) do return
	eni, efi, ok := editor_target(p.app)
	if !ok || p.app.doc.nodes[eni].fields[efi].kind != "string" {
		note(p, "after String > \"...\" the cursor is not on the string's text (%q); moved there with the D-pad", line_src(p.app, ni))
		for f, i in p.app.doc.nodes[ni].fields do if f.editable && f.kind == "string" && f.text == "" { dpad_to(p, ni, false, i, loc); break }
	}
	dictate_here(p, text, loc)
}

// win32.L("text")
@(private = "file")
fill_wide_string :: proc(p: ^Pad, ni: int, text: string, loc := #caller_location) {
	fill_call(p, ni, "L", loc)
	fill_string(p, ni, text, loc)
}

@(private = "file")
fill_type :: proc(p: ^Pad, ni, nth: int, name: string, fill := TYPE_IMPORT_FILL, loc := #caller_location) {
	if open_dot(p, ni, nth, "type", loc) && pick(p, "Type", loc) do pick_leaf(p, name, fill, loc)
}

// D-pad to the nth editable name of line ni and dictate `name`.
@(private = "file")
say_name :: proc(p: ^Pad, ni: int, name: string, nth := 0, loc := #caller_location) {
	if !testing.expectf(p.t, ni >= 0 && ni < len(p.app.doc.nodes), "no line for %q", name, loc = loc) do return
	seen := 0
	for f, i in p.app.doc.nodes[ni].fields do if f.editable && f.kind != "string" && f.kind != COMMENT_KIND {
		if seen == nth {
			if dpad_to(p, ni, false, i, loc) {
				tn, tf, ok := editor_target(p.app)
				if testing.expectf(p.t, ok && tn == ni && tf == i, "cursor not on the name %q of %q", f.text, line_src(p.app, ni), loc = loc) do dictate_here(p, name, loc)
			}
			return
		}
		seen += 1
	}
	testing.expectf(p.t, false, "no editable name #%d on %q", nth, line_src(p.app, ni), loc = loc)
}

// D-pad to a comment's text and dictate it.
@(private = "file")
say_comment :: proc(p: ^Pad, ni: int, text: string, loc := #caller_location) {
	if ni >= 0 && ni < len(p.app.doc.nodes) {
		for f, i in p.app.doc.nodes[ni].fields do if f.editable && f.kind == COMMENT_KIND {
			if dpad_to(p, ni, false, i, loc) do dictate_here(p, text, loc)
			return
		}
	}
	testing.expectf(p.t, false, "no comment text on %q", line_src(p.app, ni), loc = loc)
}

// D-pad to the green dot before line `at`, A, group, leaf.
@(private = "file")
add_at_dot :: proc(p: ^Pad, at: int, group, leaf: string, loc := #caller_location) {
	if dpad_to(p, at, true, -1, loc) {
		press_a(p)
		if pick(p, group, loc) do pick(p, leaf, loc)
	}
}

// The bottom green dot (file scope).
@(private = "file")
add_top :: proc(p: ^Pad, group, leaf: string, loc := #caller_location) {
	add_at_dot(p, len(p.app.doc.nodes), group, leaf, loc)
}

// D-pad to the "●" statement line ni, A, group, leaf. Returns ni.
@(private = "file")
add_in_body :: proc(p: ^Pad, ni: int, group, leaf: string, loc := #caller_location) -> int {
	if !testing.expectf(p.t, ni >= 0 && ni < len(p.app.doc.nodes) && is_body_slot_line(p.app.doc.nodes[ni]), "no statement line at %d", ni, loc = loc) do return -1
	if !dpad_to(p, ni, false, 1, loc) do return -1
	press_a(p)
	if pick(p, group, loc) do pick(p, leaf, loc)
	return ni
}

// D-pad onto the keyword `text` of line ni, Y, option.
@(private = "file")
y_option :: proc(p: ^Pad, ni: int, text, option: string, loc := #caller_location) -> bool {
	if ni >= 0 && ni < len(p.app.doc.nodes) {
		for f, i in p.app.doc.nodes[ni].fields do if !f.slot && strings.trim_space(f.text) == text {
			if !dpad_to(p, ni, false, i, loc) do return false
			press_y(p)
			return pick(p, option, loc)
		}
	}
	testing.expectf(p.t, false, "no %q on %q", text, line_src(p.app, ni), loc = loc)
	return false
}

// Assignment > Assignment on the "●" line ni, Y on the target -> `target`.
@(private = "file")
assign_to :: proc(p: ^Pad, ni: int, target: string, loc := #caller_location) {
	if add_in_body(p, ni, "Assignment", "Assignment", loc) < 0 do return
	for f, i in p.app.doc.nodes[ni].fields do if f.editable {
		if !dpad_to(p, ni, false, i, loc) do return
		break
	}
	press_y(p)
	if ref_choose(p, target, loc) && p.app.state == .Radial do pick(p, target, loc)
}

// Y on top-level argument k of the call on line ni, then `option`.
@(private = "file")
y_arg :: proc(p: ^Pad, ni, k: int, option: string, loc := #caller_location) -> bool {
	al, ok := find_arg_list(p.app.doc.nodes[ni])
	if !testing.expectf(p.t, ok && k <= len(al.seps), "no argument %d on %q", k, line_src(p.app, ni), loc = loc) do return false
	fi := k == 0 ? al.open + 1 : al.seps[k - 1] + 1
	if !dpad_to(p, ni, false, fi, loc) do return false
	press_y(p)
	return pick(p, option, loc)
}

// Saving (src/app/save.odin write_doc): file_text (format_doc, then the
// source without editor-only "●" lines, ending in a newline).
@(private = "file")
save_text :: proc(app: ^App) -> string {
	return file_text(app, context.temp_allocator)
}

// A unified-diff style excerpt of the first difference (a few lines of context).
@(private = "file")
diff_excerpt :: proc(got, want: string) -> string {
	g := strings.split(got, "\n", context.temp_allocator)
	w := strings.split(want, "\n", context.temp_allocator)
	first := 0
	for first < len(g) && first < len(w) && g[first] == w[first] do first += 1
	if first == len(g) && first == len(w) do return "(identical)"
	// The end of the differing region (common suffix).
	eg, ew := len(g), len(w)
	for eg > first && ew > first && g[eg - 1] == w[ew - 1] { eg -= 1; ew -= 1 }
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "@@ -%d,%d +%d,%d @@ (- = expected target, + = saved)\n", first + 1, ew - first, first + 1, eg - first)
	for i in max(0, first - 3) ..< first do fmt.sbprintf(&b, " %q\n", w[i])
	for i in first ..< min(ew, first + 12) do fmt.sbprintf(&b, "-%q\n", w[i])
	for i in first ..< min(eg, first + 12) do fmt.sbprintf(&b, "+%q\n", g[i])
	for i in ew ..< min(len(w), ew + 2) do fmt.sbprintf(&b, " %q\n", w[i])
	return strings.to_string(b)
}

// <temp>/doodle_exact_build/<name>, for a look after the run.
@(private = "file")
write_artifact :: proc(name, text: string) {
	tmp, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({tmp, "doodle_exact_build"}, context.temp_allocator)
	os.make_directory_all(dir)
	file, _ := filepath.join({dir, name}, context.temp_allocator)
	_ = os.write_entire_file(file, transmute([]u8)text)
}

@(private = "file")
check_with_odin :: proc(t: ^testing.T, name, text: string, loc := #caller_location) {
	odin := os.get_env("DOODLE_ODIN", context.temp_allocator)
	if odin == "" && os.exists("C:/Odin/odin.exe") do odin = "C:/Odin/odin.exe"
	if odin == "" { log.warn("odin check skipped (no DOODLE_ODIN)"); return }
	tmp, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({tmp, "doodle_exact_build", name}, context.temp_allocator)
	os.make_directory_all(dir)
	file, _ := filepath.join({dir, "main.odin"}, context.temp_allocator)
	_ = os.write_entire_file(file, transmute([]u8)text)
	state, out, errs, err := os.process_exec(os.Process_Desc{command = []string{odin, "check", dir}}, context.temp_allocator)
	testing.expectf(t, err == nil && state.exit_code == 0, "odin check %s failed (err=%v, exit=%d):\n%s%s", dir, err, state.exit_code, string(out), string(errs), loc = loc)
}

// ---------------------------------------------------------------------------
// The whole file, from New Project.

@(test)
test_handmade_exact_build :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.os_name = "windows"
	pad := Pad{t = t, app = &app}
	p := &pad

	// Main menu > New Project (A): an empty document in the editor.
	app.state = .Menu
	app.menu_index = 0
	testing.expect_value(t, MENU_ITEMS[0], "New Project")
	press_a(p)
	testing.expect_value(t, app.state, State.Editor)
	testing.expect_value(t, len(app.doc.nodes), 0)

	// ---- package handmade ----
	add_top(p, "File Setup", "Package declaration")
	pk := line_with(&app, "package ")
	say_name(p, pk, "handmade")
	testing.expect_value(t, line_src(&app, pk), "package handmade")

	// ---- import win32 "core:sys/windows" ----
	add_top(p, "Dependencies", "Aliased import")
	pick(p, "core")
	for _ in 0 ..< 10 {
		v := current_view(&app)
		if v == nil || app.state != .Radial do break
		hit := -1
		for e, i in v.entries do if e.import_path == "core:sys/windows" { hit = i; break }
		if hit >= 0 { menu_go(p, hit); break }
		if !pick(p, v.title == "core" ? "sys" : "windows") do break
	}
	imp := line_with(&app, "\"core:sys/windows\"")
	say_name(p, imp, "win32")
	testing.expect_value(t, line_src(&app, imp), "import win32 \"core:sys/windows\"")

	// ---- WHITENESS :: 0x00FF0062 / BLACKNESS :: 0x00000042 (keypad) ----
	add_top(p, "Values", "Constant")
	c := len(app.doc.nodes) - 1
	say_name(p, c, "whiteness")
	text_tools(p, "Case", "UPPER_SNAKE")
	fill_number(p, c, "0x", "0", "0", "F", "F", "0", "0", "6", "2")
	add_top(p, "Values", "Constant")
	c = len(app.doc.nodes) - 1
	say_name(p, c, "blackness")
	text_tools(p, "Case", "UPPER_SNAKE")
	fill_number(p, c, "0x", "0", "0", "0", "0", "0", "0", "4", "2")
	testing.expect_value(t, line_src(&app, line_with(&app, "WHITENESS ::")), "WHITENESS :: 0x00FF0062")
	testing.expect_value(t, line_src(&app, line_with(&app, "BLACKNESS ::")), "BLACKNESS :: 0x00000042")

	// ---- operation: u32 = WHITENESS ----
	add_top(p, "Values", "Global variable (typed)")
	g := len(app.doc.nodes) - 1
	say_name(p, g, "operation")
	fill_type(p, g, 0, "u32", "")
	fill_ref(p, g, "WHITENESS")
	testing.expect_value(t, line_src(&app, g), "operation: u32 = WHITENESS")

	// ---- the two file-scope comments, a blank line before the second ----
	add_at_dot(p, line_with(&app, "WHITENESS ::"), "File Setup", "Comments")
	say_comment(p, line_with(&app, "WHITENESS ::") - 1, "Kept local in case your odin version's gdi32 bindings don't export these")
	text_tools(p, "Word case", "odin", "Capitalized")
	add_at_dot(p, line_with(&app, "operation:"), "File Setup", "Comments")
	ci := line_with(&app, "operation:") - 1
	say_comment(p, ci, "Stands in for Casey's static dword operation inside the callback")
	text_tools(p, "Word case", "dword", "UPPER")
	text_tools(p, "Word case", "operation", "Capitalized")
	text_tools(p, "Backticks", "static", "static DWORD Operation")
	add_at_dot(p, ci, "File Setup", "Blank line")

	// ---- main_window_callback :: proc "system" (...) -> win32.LRESULT ----
	add_top(p, "Procedures", "Procedure")
	hdr := line_with(&app, ":: proc")
	say_name(p, hdr, "main_window_callback")
	for prm in ([][2]string{{"window", "HWND"}, {"message", "UINT"}, {"w_param", "WPARAM"}, {"l_param", "LPARAM"}}) {
		if !open_dot(p, hdr, 0, "params") || !pick(p, "Add parameter") do break
		// The cursor lands on the new parameter's name: dictate it.
		dictate_here(p, prm[0])
		fill_type(p, hdr, 0, prm[1])
	}
	fill_type(p, hdr, 0, "LRESULT")
	// Modifiers > Calling convention: D-pad up/down to the header, A, "system".
	add_top(p, "Modifiers", "Calling convention")
	for _ in 0 ..< 16 do if app.mod_pick_active && app.mod_pick_line != hdr do press(p, Input{up = true})
	testing.expect_value(t, app.mod_pick_line, hdr)
	press_a(p)
	pick(p, "\"system\"")

	// result: win32.LRESULT = 0, blank line
	ni := add_in_body(p, body_line(&app, hdr), "Declarations", "Variable (typed)")
	say_name(p, ni, "result")
	fill_type(p, ni, 0, "LRESULT")
	fill_number(p, ni)
	testing.expect_value(t, line_src(&app, ni), "result: win32.LRESULT = 0")
	add_in_body(p, body_line(&app, hdr), "Layout", "Blank line")

	// switch message { case win32.WM_*: ... case: ... }
	s := add_in_body(p, body_line(&app, hdr), "Branching", "Switch")
	fill_ref(p, s, "message")
	consts := []string{"WM_SIZE", "WM_DESTROY", "WM_CLOSE", "WM_ACTIVATEAPP", "WM_PAINT"}
	cl := s + 1
	for name, k in consts {
		if k > 0 {
			y_option(p, cl, "case", "Add case after")
			cl = line_with(&app, "case ", cl + 1)
		}
		fill_const(p, cl, name)
	}
	y_option(p, s, "switch", "Add default case")
	for name in consts[:4] {
		cl = line_with(&app, strings.concatenate({"case win32.", name, ":"}, context.temp_allocator))
		ni = add_in_body(p, body_line(&app, cl), "Calls", "From import")
		if ni < 0 do continue
		if pick(p, "win32") do pick_leaf(p, "OutputDebugStringA", "__call_import_proc__")
		// Dictated "wm size", then Case > UPPER_SNAKE and Escape > \n.
		said, _ := strings.replace_all(strings.to_lower(name, context.temp_allocator), "_", " ", context.temp_allocator)
		fill_string(p, ni, said)
		text_tools(p, "Case", "UPPER_SNAKE")
		text_tools(p, "Escape", `\n`)
	}

	// case win32.WM_PAINT:
	pc := line_with(&app, "case win32.WM_PAINT:")
	ni = add_in_body(p, body_line(&app, pc), "Declarations", "Variable (no value)")
	say_name(p, ni, "paint")
	fill_type(p, ni, 0, "PAINTSTRUCT")
	testing.expect_value(t, line_src(&app, ni), "paint: win32.PAINTSTRUCT")
	ni = add_in_body(p, body_line(&app, ni), "Declarations", "Variable (:=)")
	say_name(p, ni, "device_context")
	fill_call(p, ni, "BeginPaint")
	fill_ref(p, ni, "window")
	fill_ref(p, ni, "paint", "&paint   (pointer to it)")
	testing.expect_value(t, line_src(&app, ni), "device_context := win32.BeginPaint(window, &paint)")
	field_var :: proc(p: ^Pad, at: int, name: string, fields: ..string) -> int {
		ni := add_in_body(p, body_line(p.app, at), "Declarations", "Variable (:=)")
		say_name(p, ni, name)
		if len(fields) == 2 do fill_op(p, ni, "Arithmetic", "a - b")
		for field in fields {
			if open_dot(p, ni, 0) && pick(p, "Reference") && ref_choose(p, "paint") {
				if pick(p, "Field of paint") && pick(p, "rcPaint   RECT") do pick(p, field)
			}
		}
		return ni
	}
	ni = field_var(p, ni, "x", "left   LONG")
	ni = field_var(p, ni, "y", "top   LONG")
	ni = field_var(p, ni, "width", "right   LONG", "left   LONG")
	ni = field_var(p, ni, "height", "bottom   LONG", "top   LONG")
	testing.expect_value(t, line_src(&app, ni), "height := paint.rcPaint.bottom - paint.rcPaint.top")
	ni = add_in_body(p, body_line(&app, ni), "Calls", "From import")
	if pick(p, "win32") do pick_leaf(p, "PatBlt", "__call_import_proc__")
	for name in ([]string{"device_context", "x", "y", "width", "height", "operation"}) do fill_ref(p, ni, name)
	testing.expect_value(t, line_src(&app, ni), "win32.PatBlt(device_context, x, y, width, height, operation)")
	ni = body_line(&app, ni)
	assign_to(p, ni, "operation")
	fill_op(p, ni, "Choose", "a if c else b")
	fill_ref(p, ni, "BLACKNESS")
	fill_op(p, ni, "Compare", "a == b")
	for name in ([]string{"operation", "WHITENESS", "WHITENESS"}) do fill_ref(p, ni, name)
	testing.expect_value(t, line_src(&app, ni), "operation = BLACKNESS if operation == WHITENESS else WHITENESS")
	ni = add_in_body(p, body_line(&app, ni), "Calls", "From import")
	if pick(p, "win32") do pick_leaf(p, "EndPaint", "__call_import_proc__")
	fill_ref(p, ni, "window")
	fill_ref(p, ni, "paint", "&paint   (pointer to it)")
	testing.expect_value(t, line_src(&app, ni), "win32.EndPaint(window, &paint)")

	// case: // comment, result = win32.DefWindowProcW(...)
	d := line_with(&app, "case:")
	ni = add_in_body(p, body_line(&app, d), "Layout", "Comment")
	say_comment(p, ni, "Casey logs here too; that gets noisy fast, so I left it out")
	ni = body_line(&app, d)
	assign_to(p, ni, "result")
	fill_call(p, ni, "DefWindowProcW")
	for name in ([]string{"window", "message", "w_param", "l_param"}) do fill_ref(p, ni, name)
	testing.expect_value(t, line_src(&app, ni), "result = win32.DefWindowProcW(window, message, w_param, l_param)")

	// After the switch: blank line, return result.
	sw_end := line_with(&app, "}", line_with(&app, "result = win32.DefWindowProcW"))
	add_in_body(p, body_line(&app, sw_end), "Layout", "Blank line")
	ni = add_in_body(p, body_line(&app, sw_end), "Jumps and cleanup", "Return")
	fill_ref(p, ni, "result")
	testing.expect_value(t, line_src(&app, ni), "return result")

	// ---- main :: proc() ----
	add_top(p, "Procedures", "Procedure")
	mh := line_with(&app, ":: proc", hdr + 1)
	say_name(p, mh, "main")
	ni = add_in_body(p, body_line(&app, mh), "Declarations", "Variable (:=)")
	say_name(p, ni, "instance")
	if open_dot(p, ni, 0) && pick(p, "Convert") && pick(p, "T(x)") do pick_leaf(p, "HINSTANCE", CONV_FILL)
	fill_call(p, ni, "GetModuleHandleW")
	fill_nil(p, ni)
	testing.expect_value(t, line_src(&app, ni), "instance := win32.HINSTANCE(win32.GetModuleHandleW(nil))")
	add_in_body(p, body_line(&app, mh), "Layout", "Blank line")

	// window_class := win32.WNDCLASSW {...}
	ni = add_in_body(p, body_line(&app, mh), "Declarations", "Variable (:=)")
	say_name(p, ni, "window_class")
	if open_dot(p, ni, 0) && pick(p, "Struct literal") do pick_leaf(p, "WNDCLASSW", LIT_TYPE_FILL)
	if open_dot(p, ni, 0, FIELDS_KIND) do pick(p, "style   UINT")
	fill_op(p, ni, "Bitwise", "a | b")
	fill_const(p, ni, "CS_OWNDC")
	fill_op(p, ni, "Bitwise", "a | b")
	fill_const(p, ni, "CS_HREDRAW")
	fill_const(p, ni, "CS_VREDRAW")
	if open_dot(p, ni, 0, FIELDS_KIND) do pick(p, "lpfnWndProc   WNDPROC")
	fill_ref(p, ni, "main_window_callback")
	if open_dot(p, ni, 0, FIELDS_KIND) do pick(p, "hInstance   HINSTANCE")
	fill_ref(p, ni, "instance")
	if open_dot(p, ni, 0, FIELDS_KIND) do pick(p, "lpszClassName   LPCWSTR")
	fill_wide_string(p, ni, "handmade hero window class")
	text_tools(p, "Case", "PascalCase")
	add_in_body(p, body_line(&app, mh), "Layout", "Blank line")

	// if win32.RegisterClassW(&window_class) != 0 { ... } else { ... }
	ifl := add_in_body(p, body_line(&app, mh), "Branching", "If / Else")
	fill_op(p, ifl, "Compare", "a != b")
	fill_call(p, ifl, "RegisterClassW")
	fill_ref(p, ifl, "window_class", "&window_class   (pointer to it)")
	fill_number(p, ifl)
	testing.expect_value(t, line_src(&app, ifl), "if win32.RegisterClassW(&window_class) != 0 {")
	ni = add_in_body(p, body_line(&app, ifl), "Declarations", "Variable (:=)")
	say_name(p, ni, "window_handle")
	fill_call(p, ni, "CreateWindowExW")
	fill_number(p, ni)
	if open_dot(p, ni, 0) && pick(p, "Reference") && ref_choose(p, "window_class") {
		if pick(p, "Field of window_class") do pick(p, "lpszClassName   LPCWSTR")
	}
	fill_wide_string(p, ni, "handmade hero")
	text_tools(p, "Case", "PascalCase")
	fill_op(p, ni, "Bitwise", "a | b")
	fill_const(p, ni, "WS_OVERLAPPEDWINDOW")
	fill_const(p, ni, "WS_VISIBLE")
	for _ in 0 ..< 4 do fill_const(p, ni, "CW_USEDEFAULT")
	fill_nil(p, ni)
	fill_nil(p, ni)
	fill_ref(p, ni, "instance")
	fill_nil(p, ni)
	for k in ([]int{5, 7, 9, 10, 11}) do y_arg(p, ni, k, "Join with previous row")
	add_in_body(p, body_line(&app, ifl), "Layout", "Blank line")
	inner := add_in_body(p, body_line(&app, ifl), "Branching", "If / Else")
	fill_op(p, inner, "Compare", "a != b")
	fill_ref(p, inner, "window_handle")
	fill_nil(p, inner)
	ni = add_in_body(p, body_line(&app, inner), "Declarations", "Variable (no value)")
	say_name(p, ni, "message")
	fill_type(p, ni, 0, "MSG")
	loop := add_in_body(p, body_line(&app, inner), "Loops", "For (condition)")
	fill_op(p, loop, "Compare", "a > b")
	fill_call(p, loop, "GetMessageW")
	fill_ref(p, loop, "message", "&message   (pointer to it)")
	fill_nil(p, loop)
	fill_number(p, loop)
	fill_number(p, loop)
	fill_number(p, loop)
	testing.expect_value(t, line_src(&app, loop), "for win32.GetMessageW(&message, nil, 0, 0) > 0 {")
	for name in ([]string{"TranslateMessage", "DispatchMessageW"}) {
		ni = add_in_body(p, body_line(&app, loop), "Calls", "From import")
		if pick(p, "win32") do pick_leaf(p, name, "__call_import_proc__")
		fill_ref(p, ni, "message", "&message   (pointer to it)")
	}
	else_line := line_with(&app, "} else {", loop)
	for _ in 0 ..< 2 {
		ni = add_in_body(p, body_line(&app, else_line), "Layout", "Comment")
		say_comment(p, ni, "todo logging")
		text_tools(p, "Word case", "todo", "UPPER")
		else_line = line_with(&app, "} else {", else_line + 1)
	}
	back_out(p)

	// ---- Save as the user would right now (leftover "●" lines and all) ----
	leftovers := 0
	for n in app.doc.nodes do if is_body_slot_line(n) do leftovers += 1
	first_save := save_text(&app)
	if first_save != EXACT_TARGET {
		note(p, "%d empty statement lines (\"●\") are left after building; saving now writes them as blank lines", leftovers)
		note(p, "saving right after building (without LT+B on the leftover statement dots) differs:\n%s", diff_excerpt(first_save, EXACT_TARGET))
		// Opened again and saved again (format_doc runs on load and save).
		again: App
		again.os_name = "windows"
		again.state = .Editor
		doc_from_source(&again, first_save)
		resaved := save_text(&again)
		cleanup(&again)
		if resaved != EXACT_TARGET do note(p, "that file reopened and saved again still differs:\n%s", diff_excerpt(resaved, EXACT_TARGET))
	}

	// ---- LT+B on every leftover "●" statement line, then save ----
	for _ in 0 ..< 64 {
		b := body_line(&app, 0)
		if b < 0 do break
		before := len(app.doc.nodes)
		if !dpad_to(p, b, false, 1) do break
		press_lt_b(p)
		if len(app.doc.nodes) == before { testing.expectf(t, false, "LT+B didn't remove the statement line %d", b); break }
	}
	saved := save_text(&app)
	testing.expectf(t, saved == EXACT_TARGET, "saved file != target:\n%s\n--- saved ---\n%s", diff_excerpt(saved, EXACT_TARGET), saved)
	if saved != EXACT_TARGET && strings.trim_right(saved, "\n") == strings.trim_right(EXACT_TARGET, "\n") {
		note(p, "the saved file differs from the target only in the final newline")
	}

	// Reopening the saved file and saving again changes nothing.
	app.state = .Editor
	doc_from_source(&app, saved)
	reloaded := strings.concatenate({src(&app), "\n"}, context.temp_allocator)
	testing.expectf(t, reloaded == saved, "reload changed it:\n%s", diff_excerpt(reloaded, saved))
	resaved := save_text(&app)
	testing.expectf(t, resaved == saved, "saving after reload changed it:\n%s", diff_excerpt(resaved, saved))

	check_with_odin(t, "built", saved)
	write_artifact("first_save.odin", first_save)
	write_artifact("saved.odin", saved)
	for n in p.notes do log.warnf("FINDING: %s", n)
	delete(p.notes)
	log.infof("built with %d controller inputs", p.presses)
}

// The target, opened verbatim: it saves back byte for byte, format_doc
// (which runs on load and on save) leaves it alone, and it passes odin check.
@(test)
test_handmade_exact_load_round_trip :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.os_name = "windows"
	app.state = .Editor
	doc_from_source(&app, EXACT_TARGET)
	bare := strings.trim_right(EXACT_TARGET, "\n")
	got := strings.clone(src(&app), context.temp_allocator)
	testing.expectf(t, got == bare, "load -> source is not exact:\n%s", diff_excerpt(got, bare))
	got = save_text(&app) // format_doc + save_source + the final newline
	testing.expectf(t, got == EXACT_TARGET, "load -> save is not exact:\n%s", diff_excerpt(got, EXACT_TARGET))
	testing.expectf(t, src(&app) == bare, "format_doc changed the target:\n%s", diff_excerpt(src(&app), bare))
	// A file without the final newline is saved back without one.
	doc_from_source(&app, bare)
	got = save_text(&app)
	testing.expectf(t, got == bare, "load -> save (no final newline) is not exact:\n%s", diff_excerpt(got, bare))
	check_with_odin(t, "target", EXACT_TARGET)
}

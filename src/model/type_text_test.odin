package model

// How an expected type is written in this file (expr.odin type_text_here):
// only the package's own names get its prefix - Maybe is Odin's.

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

@(test)
test_type_text_here :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nimport \"vendor:sdl3\"\nimport win32 \"core:sys/windows\"\n")
	testing.expect_value(t, type_text_here(&app, "Maybe(^FRect)", "vendor:sdl3"), "Maybe(^sdl3.FRect)")
	testing.expect_value(t, type_text_here(&app, "[^]Point", "vendor:sdl3"), "[^]sdl3.Point")
	testing.expect_value(t, type_text_here(&app, "^Renderer", "vendor:sdl3"), "^sdl3.Renderer")
	testing.expect_value(t, type_text_here(&app, "HINSTANCE", "core:sys/windows"), "win32.HINSTANCE")
	testing.expect_value(t, type_text_here(&app, "c.int", "vendor:sdl3"), "c.int") // already qualified
	testing.expect_value(t, type_text_here(&app, "int", ""), "int")
}

// RenderFillRect(renderer, rect: Maybe(^FRect)): Reference > rect offers the
// conversion as `Maybe(^sdl3.FRect)(rect)`, and `&rect` (what SDL wants: a
// ^FRect converts to Maybe(^FRect) by itself) fills the dot.
@(test)
test_pass_as_maybe_pointer :: proc(t: ^testing.T) {
	app: App
	defer cleanup(&app)
	app.state = .Editor
	doc_from_source(&app, "package main\n\nimport \"vendor:sdl3\"\n\nmain :: proc() {\n\trect: sdl3.FRect\n\tsdl3.RenderFillRect(nil, )\n}\n")
	ni := -1
	for n, i in app.doc.nodes do if strings.contains(node_text(n, context.temp_allocator), "RenderFillRect") do ni = i
	fi := -1
	for f, i in app.doc.nodes[ni].fields do if f.slot && strings.contains(f.hint, "Maybe") do fi = i
	if !testing.expect(t, fi >= 0, "the Maybe(^FRect) dot") do return
	focus_field_index(&app, ni, fi)
	update(&app, Input{confirm = true})
	v := current_view(&app)
	for e, i in v.entries do if e.label == "Reference" { v.index = i; update(&app, Input{confirm = true}); break }
	for _ in 0 ..< 8 {
		pni, pfi, ok := editor_target(&app)
		if ok && app.doc.nodes[pni].fields[pfi].text == "rect" do break
		update(&app, Input{up = true})
	}
	update(&app, Input{confirm = true})
	pv := current_view(&app)
	if !testing.expect(t, pv != nil && pv.title == "Pass as", "the Pass as menu") do return
	labels := make([dynamic]string, context.temp_allocator)
	for e in pv.entries do append(&labels, e.label)
	joined := strings.join(labels[:], " | ", context.temp_allocator)
	testing.expectf(t, strings.contains(joined, "Maybe(^sdl3.FRect)(rect)") && !strings.contains(joined, "sdl3.Maybe"), "conversion written with Odin's Maybe: %s", joined)
	for e, i in pv.entries do if strings.has_prefix(e.label, "&rect") {
		testing.expect(t, !e.dim, "&rect fits")
		pv.index = i
		update(&app, Input{confirm = true})
		break
	}
	testing.expect_value(t, strings.trim_space(node_text(app.doc.nodes[ni], context.temp_allocator)), "sdl3.RenderFillRect(nil, &rect)")
}

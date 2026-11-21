package main

// LT+Y: documentation for the highlighted part (model/docs.odin finds it, read
// live from this file, its folder, or the Odin install). A panel over the code:
// the declaration (code font) and its comment; D-pad Up/Down scroll (Left/Right
// a page), B / A / Y closes.

import "../gpu"
import "../model"
import "../text"
import "core:path/filepath"
import "core:strings"

g_doc_open:   bool
g_doc:        model.Doc_Info
g_doc_scroll: int // first row shown

// doc_panel_open looks up the highlighted part and shows the panel.
doc_panel_open :: proc(m: ^model.App) {
	q, ok := model.doc_query(m)
	if !ok {
		set_status("Nothing to look up here (highlight a name, call, type or keyword)")
		return
	}
	dir := g_current_file != "" ? filepath.dir(g_current_file) : g_project_dir
	model.doc_info_free(&g_doc)
	g_doc = model.lookup_doc(m, q, g_current_file, dir, model.odin_root(), os_name())
	g_doc_scroll = 0
	g_doc_open = true
}

doc_panel_close :: proc() {
	g_doc_open = false
	model.doc_info_free(&g_doc)
}

// The panel owns all input while it's open.
handle_doc_input :: proc(raw: ^Raw) {
	page := max(1, g_doc_page_rows - 1)
	if raw.e_up do g_doc_scroll -= 1
	if raw.e_down do g_doc_scroll += 1
	if raw.e_left do g_doc_scroll -= page
	if raw.e_right do g_doc_scroll += page
	g_doc_scroll = clamp(g_doc_scroll, 0, max(0, g_doc_rows - g_doc_page_rows))
	if raw.e_b || raw.e_cancel || raw.e_a || raw.e_confirm || raw.e_y do doc_panel_close()
	raw.e_up, raw.e_down, raw.e_left, raw.e_right = false, false, false, false
	raw.e_a, raw.e_b, raw.e_y, raw.e_confirm, raw.e_cancel = false, false, false, false, false
}

// Rows laid out by the last draw (for scrolling limits).
@(private = "file")
g_doc_rows: int
@(private = "file")
g_doc_page_rows: int = 1

@(private = "file")
Doc_Row :: struct {
	text: string,
	code: bool, // the declaration (code font, shaded)
	gap:  bool, // the space between the declaration and the comment
}

COL_DOC_CODE_BG :: gpu.Color{0.89, 0.86, 0.78, 1}

draw_doc_panel :: proc(r: ^gpu.Renderer, w, h: int) {
	fw, fh := f32(w), f32(h)
	gpu.draw_rect(r, {0, 0, fw, fh}, COL_VEIL)
	pw := min(fw - 80, f32(1100))
	px := (fw - pw) * 0.5
	py := f32(70)
	ph := fh - 150 - 20 - py // above the HUD
	gpu.draw_rect(r, {px, py, pw, ph}, COL_BG)
	gpu.draw_rect_outline(r, {px, py, pw, ph}, 2, COL_RULE)

	pad := f32(22)
	x := px + pad
	inner := pw - 2 * pad
	ulh := text.line_height(g_ui)
	clh := text.line_height(g_code)

	// Header: the name, where it's declared, how to close.
	text.draw_line(r, g_ui, {x, py + 16}, g_doc.title, g_doc.found ? COL_ACCENT : COL_ERR)
	text.draw_line(r, g_ui, {x + text.measure(g_ui, g_doc.title).x + 18, py + 16}, g_doc.location, COL_DIM)
	help := "Up/Down scroll   B close"
	text.draw_line(r, g_ui, {px + pw - pad - text.measure(g_ui, help).x, py + 16}, help, COL_DIM)
	top := py + 16 + ulh + 12
	gpu.draw_rect(r, {x, top - 6, inner, 1}, COL_RULE)

	// Rows: the declaration (wrapped to the panel), a gap, the comment.
	rows := make([dynamic]Doc_Row, 0, 64, context.temp_allocator)
	for s in g_doc.signature {
		for l in wrap_text(g_code, doc_tabs(s), inner - 16) do append(&rows, Doc_Row{l, true, false})
		if s == "" do append(&rows, Doc_Row{"", true, false})
	}
	if len(g_doc.signature) > 0 && len(g_doc.doc) > 0 do append(&rows, Doc_Row{"", false, true})
	for s in g_doc.doc {
		ls := wrap_text(g_ui, doc_tabs(s), inner)
		if len(ls) == 0 do append(&rows, Doc_Row{"", false, false})
		for l in ls do append(&rows, Doc_Row{l, false, false})
	}
	if len(rows) == 0 do append(&rows, Doc_Row{"(no comment above the declaration)", false, false})

	// As many rows as fit, from the scroll position.
	bottom := py + ph - 14
	avail := bottom - top
	row_h :: proc(row: Doc_Row, ulh, clh: f32) -> f32 { return row.gap ? ulh * 0.6 : (row.code ? clh : ulh) }
	fit := 0
	{
		y := f32(0)
		for i in g_doc_scroll ..< len(rows) {
			y += row_h(rows[i], ulh, clh)
			if y > avail do break
			fit += 1
		}
	}
	g_doc_rows = len(rows)
	g_doc_page_rows = max(1, fit)
	if g_doc_scroll > max(0, len(rows) - g_doc_page_rows) do g_doc_scroll = max(0, len(rows) - g_doc_page_rows)
	y := top
	for i in g_doc_scroll ..< min(len(rows), g_doc_scroll + fit) {
		row := rows[i]
		rh := row_h(row, ulh, clh)
		if row.code {
			gpu.draw_rect(r, {x, y, inner, rh}, COL_DOC_CODE_BG)
			text.draw_line(r, g_code, {x + 8, y}, row.text, COL_TEXT)
		} else if !row.gap {
			text.draw_line(r, g_ui, {x, y}, row.text, COL_TEXT)
		}
		y += rh
	}
	// More above / below.
	if g_doc_scroll > 0 do text.draw_centered(r, g_ui, {px, top - 4, pw, 14}, "^", COL_DIM)
	if g_doc_scroll + fit < len(rows) do text.draw_centered(r, g_ui, {px, bottom - 6, pw, 14}, "v", COL_DIM)
}

@(private = "file")
doc_tabs :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "\t", "    ", context.temp_allocator)
	return out
}

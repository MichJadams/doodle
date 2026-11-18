package main

// The code editor view: layout + drawing.
//
//  - Code font is sized so MAX_COLS (80) columns fit across the editor (re-baked on resize).
//  - Each node (one logical line) is laid out into visual rows:
//      * a long call is shown one argument per row (model.call_rows), exactly
//        like it will be saved (model.node_source_lines);
//      * anything still too wide wraps onto continuation rows.
//  - Syntax highlighting from model.highlight; editable fields stay green.
//  - The view scrolls to keep the cursor visible.

import "../gpu"
import "../model"
import "../text"
import "core:fmt"
import "core:math"
import "core:strings"

// ---- Code font ----

g_code:    ^text.Font // code font, sized to the window (see ensure_code_font)
g_code_px: f32

CODE_PX_MAX :: 28
CODE_PX_MIN :: 13

EDITOR_PAD :: f32(28)
GUTTER     :: f32(34) // left of the code: insertion dots
DOT_W      :: f32(24) // a slot dot + padding

editor_x0 :: proc() -> f32 { return EDITOR_PAD + GUTTER }

// ensure_code_font (re)bakes the code font so 80 columns fit in a window `w` wide.
ensure_code_font :: proc(r: ^gpu.Renderer, w: int) {
	avail := f32(w) - editor_x0() - EDITOR_PAD
	want := f32(CODE_PX_MAX)
	if g_code != nil {
		// Monospace advance scales with pixel size: solve for 80 columns.
		adv := text.measure(g_code, "0").x / g_code_px
		if adv > 0 do want = math.floor(avail / (f32(model.MAX_COLS) * adv))
	}
	want = clamp(want, CODE_PX_MIN, CODE_PX_MAX)
	if g_code != nil && want == g_code_px do return
	f := load_a_font(r, want)
	if f == nil do return
	if g_code != nil do text.shutdown(g_code, r)
	g_code, g_code_px = f, want
	// The first bake was only a measuring probe at the max size: re-check once.
	if want == CODE_PX_MAX do ensure_code_font_once(r, w)
}

@(private = "file")
ensure_code_font_once :: proc(r: ^gpu.Renderer, w: int) {
	avail := f32(w) - editor_x0() - EDITOR_PAD
	adv := text.measure(g_code, "0").x / g_code_px
	if adv <= 0 do return
	want := clamp(math.floor(avail / (f32(model.MAX_COLS) * adv)), CODE_PX_MIN, CODE_PX_MAX)
	if want == g_code_px do return
	if f := load_a_font(r, want); f != nil {
		text.shutdown(g_code, r)
		g_code, g_code_px = f, want
	}
}

// ---- Syntax colors ----

HL_COLORS := [model.Hl]gpu.Color{
	.Plain    = COL_TEXT,
	.Keyword  = {0.78, 0.55, 0.95, 1},
	.Type     = {0.35, 0.80, 0.80, 1},
	.String   = {0.80, 0.86, 0.50, 1},
	.Number   = {0.95, 0.70, 0.50, 1},
	.Constant = {0.95, 0.82, 0.45, 1},
	.Comment  = {0.48, 0.53, 0.60, 1},
	.Func     = {0.45, 0.70, 1.00, 1},
	.Package  = {0.92, 0.62, 0.70, 1},
}

// ---- Layout ----

// One drawable piece of a node: a run of same-colored text, or a slot dot.
Item :: struct {
	fi:    int,    // field index (-1 for a "," added by the row plan)
	text:  string, // text to draw (tabs expanded)
	col:   gpu.Color,
	dot:   bool,
	label: string, // a dot's expected-type label
	x, w:  f32,
	row:   int,
}

Node_Layout :: struct {
	items: [dynamic]Item,
	rows:  int,
	y:     f32, // top of the first row (before scrolling)
}

@(private = "file")
expand_tabs :: proc(s: string) -> string {
	if strings.index_byte(s, '\t') < 0 do return s
	out, _ := strings.replace_all(s, "\t", "    ", context.temp_allocator)
	return out
}

// layout_node places a node's fields into rows between x0 and max_x.
layout_node :: proc(n: model.Node, x0, max_x: f32, packages: []string) -> Node_Layout {
	lay := Node_Layout{items = make([dynamic]Item, 0, len(n.fields) * 2, context.temp_allocator), rows = 1}
	font := g_code

	// Syntax colors for every byte of the line, and each field's offset into it.
	line := model.node_text(n, context.temp_allocator)
	hl := model.highlight(line, packages)
	offs := make([]int, len(n.fields) + 1, context.temp_allocator)
	for f, i in n.fields do offs[i + 1] = offs[i] + len(f.text)

	// Natural width (one row) decides whether a call is broken one arg per row.
	natural := x0
	for f in n.fields do natural += field_width(f)
	rows, has_call := model.call_rows(n)
	broken := has_call && (model.needs_break(n) || natural > max_x)

	spans := rows
	if !broken {
		spans = make([]model.Row_Span, 1, context.temp_allocator)
		spans[0] = {start = 0, end = len(n.fields)}
	}
	base_w := text.measure(font, expand_tabs(model.line_indent(n))).x
	unit_w := text.measure(font, "    ").x

	row := 0
	x := x0
	row_start := x0
	place :: proc(lay: ^Node_Layout, it: Item, x, row_start: ^f32, row: ^int, max_x, cont_x: f32) {
		it := it
		if x^ + it.w > max_x && x^ > row_start^ { // wrap onto a continuation row
			row^ += 1
			x^ = cont_x
			row_start^ = cont_x
		}
		it.x, it.row = x^, row^
		append(&lay.items, it)
		x^ += it.w
	}
	cont_x := x0 + base_w + 2 * unit_w

	for span, si in spans {
		if si > 0 { // each planned row starts on a new visual row
			row += 1
			x = x0 + base_w + f32(span.extra_indent) * unit_w
			row_start = x
		}
		for fi in span.start ..< span.end {
			f := n.fields[fi]
			if f.slot {
				label := slot_hint_label(f)
				w := DOT_W + (label != "" ? text.measure(g_ui, label).x + 6 : 0)
				place(&lay, Item{fi = fi, dot = true, label = label, w = w}, &x, &row_start, &row, max_x, cont_x)
				continue
			}
			s := f.text
			if broken && si > 0 && fi == span.start do s = strings.trim_left_space(s) // `\t)` -> `)`
			if broken && si == 0 && fi == span.end - 1 do s = strings.trim_right_space(s) // `( ` -> `(`
			// Split the field into same-color runs.
			base := offs[fi] + (len(f.text) - len(strings.trim_left_space(f.text)) if (broken && si > 0 && fi == span.start) else 0)
			start := 0
			for start < len(s) {
				end := start + 1
				c0 := run_color(f, hl, base + start)
				for end < len(s) && run_color(f, hl, base + end) == c0 do end += 1
				piece := expand_tabs(s[start:end])
				w := text.measure(font, piece).x
				if w > max_x - cont_x && len(piece) > 1 {
					// A single run wider than a row (a long string): break it by characters.
					cut := 0
					for cut < len(piece) {
						k := cut + 1
						for k < len(piece) && text.measure(font, piece[cut:k + 1]).x <= max_x - x do k += 1
						// Prefer breaking after a space (word wrap) when one fits on this row.
						if k < len(piece) {
							if sp := strings.last_index_byte(piece[cut:k], ' '); sp > 0 do k = cut + sp + 1
						}
						sub := piece[cut:k]
						place(&lay, Item{fi = fi, text = sub, col = c0, w = text.measure(font, sub).x}, &x, &row_start, &row, max_x, cont_x)
						cut = k
						if cut < len(piece) && x > row_start { row += 1; x = cont_x; row_start = cont_x }
					}
				} else {
					place(&lay, Item{fi = fi, text = piece, col = c0, w = w}, &x, &row_start, &row, max_x, cont_x)
				}
				start = end
			}
		}
		if span.suffix != "" {
			place(&lay, Item{fi = -1, text = span.suffix, col = COL_TEXT, w = text.measure(font, span.suffix).x}, &x, &row_start, &row, max_x, cont_x)
		}
	}
	lay.rows = row + 1
	return lay
}

// Width of a field on one row (for the "does it fit" decision).
@(private = "file")
field_width :: proc(f: model.Field) -> f32 {
	if f.slot {
		label := slot_hint_label(f)
		return DOT_W + (label != "" ? text.measure(g_ui, label).x + 6 : 0)
	}
	return text.measure(g_code, expand_tabs(f.text)).x
}

// Color of the byte at line offset `at` inside field f.
@(private = "file")
run_color :: proc(f: model.Field, hl: []model.Hl, at: int) -> gpu.Color {
	if f.editable && f.kind != "string" do return COL_ACCENT // names you can rename/dictate
	if f.kind == "string" do return HL_COLORS[.String]
	if at < 0 || at >= len(hl) do return COL_TEXT
	return HL_COLORS[hl[at]]
}

// ---- Drawing ----

g_scroll: f32 // vertical scroll of the code view (pixels)

draw_editor :: proc(r: ^gpu.Renderer, font: ^text.Font, m: ^model.App, w, h: int) {
	_ = font
	pad := EDITOR_PAD
	lh := text.line_height(g_code)
	x0 := editor_x0()
	max_x := f32(w) - pad
	top := f32(56)                // below the title bar
	bottom := f32(h) - 150 - 8    // above the HUD
	y_start := f32(96)

	// Import names in scope, so `win.` is colored as a package but `p.name` isn't.
	imports := model.collect_imports(m)
	defer delete(imports)
	packages := make([]string, len(imports), context.temp_allocator)
	for imp, i in imports do packages[i] = imp.ref

	// Lay out every node, stacking rows.
	n := len(m.doc.nodes)
	lays := make([]Node_Layout, n, context.temp_allocator)
	y := y_start
	for node, ni in m.doc.nodes {
		lays[ni] = layout_node(node, x0, max_x, packages)
		lays[ni].y = y
		y += f32(lays[ni].rows) * lh
	}
	content_end := y

	// Where the cursor is, so the view can follow it.
	tni, tfi, has_target := model.editor_target(m)
	cursor_on_dot := model.on_dot(m)
	cur_y := y_start - lh * 0.3
	if cursor_on_dot {
		if m.editor_line > 0 && m.editor_line <= n {
			prev := lays[m.editor_line - 1]
			cur_y = prev.y + f32(prev.rows) * lh + lh * 0.3
		}
	} else if m.editor_line >= 0 && m.editor_line < n {
		lay := lays[m.editor_line]
		row := 0
		for it in lay.items do if has_target && it.fi == tfi { row = it.row; break }
		cur_y = lay.y + f32(row) * lh
	}
	// Keep the cursor row inside [top, bottom] (with a line of margin).
	if cur_y - g_scroll > bottom - 2 * lh do g_scroll = cur_y - (bottom - 2 * lh)
	if cur_y - g_scroll < top + lh do g_scroll = cur_y - (top + lh)
	g_scroll = clamp(g_scroll, 0, max(0, content_end - (bottom - top)))
	sy := -g_scroll
	visible :: proc(y0, y1, top, bottom: f32) -> bool { return y1 > top && y0 < bottom }

	// Statement highlight when RT held in editor.
	if g_rt_held && m.state == .Editor && !cursor_on_dot && m.editor_line >= 0 && m.editor_line < n {
		start, end := model.construct_range(m, m.editor_line)
		y0 := lays[start].y + sy
		y1 := lays[end].y + f32(lays[end].rows) * lh + sy
		gpu.draw_rect(r, {pad, max(y0, top), f32(w) - pad * 2, min(y1, bottom) - max(y0, top)}, {0.22, 0.40, 0.70, 0.25})
	}

	// Insertion dot before the first construct.
	dots := model.insertion_points(m, context.temp_allocator)
	top_dot_y := y_start - lh * 0.3 + sy
	if visible(top_dot_y - 10, top_dot_y + 10, top, bottom) {
		if cursor_on_dot && m.editor_line == 0 do draw_green_dot_highlighted(r, pad + 14, top_dot_y)
		else do draw_green_dot(r, pad + 14, top_dot_y)
	}

	for node, ni in m.doc.nodes {
		lay := lays[ni]
		ny := lay.y + sy
		if visible(ny, ny + f32(lay.rows) * lh, top, bottom) {
			for it in lay.items {
				iy := ny + f32(it.row) * lh
				if iy + lh <= top || iy >= bottom do continue
				selected := has_target && ni == tni && it.fi == tfi
				if selected {
					gpu.draw_rect(r, {it.x - 3, iy, it.w + 6, lh}, {0.22, 0.40, 0.70, 0.55})
					gpu.draw_rect_outline(r, {it.x - 3, iy, it.w + 6, lh}, 2, COL_ACCENT)
				}
				if it.dot {
					f := node.fields[it.fi]
					outer, inner := slot_dot_color(f.kind)
					draw_colored_dot(r, it.x + DOT_W / 2, iy + lh / 2, outer, inner)
					if it.label != "" {
						text.draw_line(r, g_ui, {it.x + DOT_W + 2, iy + (lh - text.line_height(g_ui)) * 0.5}, it.label, HINT_COL)
					}
				} else {
					text.draw_line(r, g_code, {it.x, iy}, it.text, it.col)
				}
			}
		}
		// The insertion dot after each construct's last line.
		if dots[ni + 1] {
			dot_y := ny + f32(lay.rows) * lh + lh * 0.3
			if visible(dot_y - 10, dot_y + 10, top, bottom) {
				if cursor_on_dot && m.editor_line == ni + 1 do draw_green_dot_highlighted(r, pad + 14, dot_y)
				else do draw_green_dot(r, pad + 14, dot_y)
			}
		}
	}

	// Scroll hints.
	if g_scroll > 0 do text.draw_centered(r, g_ui, {0, top - 4, f32(w), 18}, "^", COL_DIM)
	if content_end - g_scroll > bottom do text.draw_centered(r, g_ui, {0, bottom - 14, f32(w), 18}, "v", COL_DIM)

	// Title bar (drawn last so scrolled code never covers it).
	gpu.draw_rect(r, {0, 0, f32(w), 50}, COL_BG)
	text.draw_line(r, g_ui, {pad, 14}, editor_title(), COL_DIM)
	gpu.draw_rect(r, {0, 50, f32(w), 1}, {0.2, 0.22, 0.27, 1})

	// STT push-to-talk indicator / last heard word.
	if g_recording {
		text.draw_line(r, g_ui, {f32(w) - 150, 14}, "[REC]", {0.90, 0.30, 0.30, 1})
	} else if g_heard != "" {
		text.draw_line(r, g_ui, {f32(w) - 320, 14}, fmt.tprintf("heard: %s", g_heard), COL_ACCENT)
	}
}

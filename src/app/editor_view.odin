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
LINE_NUM_W :: f32(44) // left gutter: line numbers (as in the saved file)
GUTTER     :: f32(22) // then the insertion dots
DOT_W      :: f32(24) // a slot dot + padding
CAPTURE_DX :: f32(34) // how far left of its call a capture dot's center sits

editor_x0 :: proc() -> f32 { return EDITOR_PAD + LINE_NUM_W + GUTTER }

// Where the top-level insertion dots sit (between the line numbers and the code).
dot_x :: proc() -> f32 { return EDITOR_PAD + LINE_NUM_W + 8 }

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
	.Keyword  = {0.55, 0.15, 0.60, 1}, // ink colors that read on paper
	.Type     = {0.00, 0.43, 0.52, 1},
	.String   = {0.33, 0.50, 0.08, 1},
	.Number   = {0.78, 0.33, 0.08, 1},
	.Constant = {0.62, 0.40, 0.00, 1},
	.Comment  = {0.55, 0.52, 0.46, 1},
	.Func     = {0.12, 0.33, 0.72, 1},
	.Package  = {0.70, 0.22, 0.35, 1},
}

// ---- Layout ----

// One drawable piece of a node: a run of same-colored text, or a slot dot.
Item :: struct {
	fi:    int,    // field index (-1 for a "," added by the row plan)
	text:  string, // text to draw (tabs expanded)
	col:   gpu.Color,
	dot:   bool,
	label: string, // a dot's expected-type label
	wstop: int,    // word by word (model/word_edit.odin): 1 + the stop (odd: a word, even: a yellow dot); 0 = not
	x, w:  f32,
	row:   int,
}

Node_Layout :: struct {
	items:    [dynamic]Item,
	rows:     int,
	y:        f32,            // top of the first row (before scrolling)
	num_rows: [dynamic][2]int, // (visual row, saved-file line offset) for the line numbers
}

@(private = "file")
expand_tabs :: proc(s: string) -> string {
	if strings.index_byte(s, '\t') < 0 do return s
	out, _ := strings.replace_all(s, "\t", "    ", context.temp_allocator)
	return out
}

// layout_node places a node's fields into rows between x0 and max_x.
layout_node :: proc(n: model.Node, x0, max_x: f32, packages: []string, word_fi := -1) -> Node_Layout {
	lay := Node_Layout{items = make([dynamic]Item, 0, len(n.fields) * 2, context.temp_allocator), rows = 1}
	lay.num_rows = make([dynamic][2]int, 0, 4, context.temp_allocator)
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
	saved_broken := has_call && model.needs_break(n) // saved one argument per line
	broken := has_call && (saved_broken || natural > max_x)
	line_off := 0

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
		// Line numbers: one per saved line (an unfilled optional "..any" dot isn't saved).
		optional_only := span.is_arg
		for fi in span.start ..< span.end do if !model.is_optional_dot(n.fields[fi]) { optional_only = false; break }
		if si == 0 || (saved_broken && !optional_only) {
			append(&lay.num_rows, [2]int{row, line_off})
			line_off += 1
		}
		for fi in span.start ..< span.end {
			f := n.fields[fi]
			if f.slot && f.kind == model.CAPTURE_KIND {
				// The capture dot sits in the indentation, left of the call (clear of
				// the green between-line dots at the code's edge), so the code doesn't shift.
				append(&lay.items, Item{fi = fi, dot = true, w = DOT_W, x = x - CAPTURE_DX - DOT_W / 2, row = row})
				continue
			}
			if f.slot {
				label := slot_hint_label(f)
				w := DOT_W + (label != "" ? text.measure(g_ui, label).x + 6 : 0)
				place(&lay, Item{fi = fi, dot = true, label = label, w = w}, &x, &row_start, &row, max_x, cont_x)
				continue
			}
			if fi == word_fi {
				// Word by word: each word on its own, a yellow dot in every gap and at both ends.
				toks := model.word_tokens(f.text)
				for k in 0 ..= len(toks) {
					place(&lay, Item{fi = fi, wstop = 2 * k + 1, w = WORD_DOT_W}, &x, &row_start, &row, max_x, cont_x)
					if k == len(toks) do break
					piece := expand_tabs(f.text[toks[k].a:toks[k].b])
					place(&lay, Item{fi = fi, wstop = 2 * k + 2, text = piece, col = run_color(f, hl, offs[fi] + toks[k].a), w = text.measure(font, piece).x}, &x, &row_start, &row, max_x, cont_x)
				}
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

// The purple attribute dot above a procedure (A: its attributes, attr_dots.odin).
COL_ATTR_DOT :: gpu.Color{0.55, 0.22, 0.88, 1}
ATTR_DOT_DX  :: f32(14) // right of the declaration's first column (clear of the green dot)

@(private = "file")
draw_attr_dot :: proc(r: ^gpu.Renderer, cx, cy: f32) {
	gpu.draw_circle(r, cx, cy, 7, {COL_ATTR_DOT.r, COL_ATTR_DOT.g, COL_ATTR_DOT.b, 0.18})
	gpu.draw_circle(r, cx, cy, 4.5, {COL_ATTR_DOT.r, COL_ATTR_DOT.g, COL_ATTR_DOT.b, 0.90})
}

@(private = "file")
draw_attr_dot_highlighted :: proc(r: ^gpu.Renderer, cx, cy: f32) {
	pulse := 0.5 + 0.5 * math.sin(f32(g_time) * 4.0)
	gpu.draw_circle(r, cx, cy, 8.5 + 1.5 * pulse, {COL_ATTR_DOT.r, COL_ATTR_DOT.g, COL_ATTR_DOT.b, 0.20 + 0.18 * pulse})
	gpu.draw_circle(r, cx, cy, 5, COL_ATTR_DOT)
}

// A smaller green dot for insertion points inside functions.
@(private = "file")
draw_body_dot :: proc(r: ^gpu.Renderer, cx, cy: f32) {
	gpu.draw_circle(r, cx, cy, 5, {COL_DOT.r, COL_DOT.g, COL_DOT.b, 0.12})
	gpu.draw_circle(r, cx, cy, 2.5, {COL_DOT.r, COL_DOT.g, COL_DOT.b, 0.70})
}

// A small green dot for the green slots (an empty statement "●", a "..any" argument).
@(private = "file")
draw_small_green_dot :: proc(r: ^gpu.Renderer, cx, cy: f32) {
	gpu.draw_circle(r, cx, cy, 5.5, {COL_DOT.r, COL_DOT.g, COL_DOT.b, 0.16})
	gpu.draw_circle(r, cx, cy, 3, COL_DOT)
}

// draw_error_panel: the compiler's messages for node ni, in a box at the right
// edge of the screen, next to the line (kept inside the code area).
@(private = "file")
draw_error_panel :: proc(r: ^gpu.Renderer, w: int, diags: []model.Diag, starts: []int, ni: int, line_y, top, bottom: f32) {
	pw := min(f32(500), f32(w) * 0.40)
	px := f32(w) - EDITOR_PAD - pw
	inner := pw - 24
	lh := text.line_height(g_ui)

	lines := make([dynamic]string, 0, 8, context.temp_allocator)
	for d in diags {
		if model.node_for_line(starts, d.line) != ni do continue
		for l in wrap_text(g_ui, fmt.tprintf("line %d:%d  %s", d.line, d.col, d.msg), inner) do append(&lines, l)
		append(&lines, "")
	}
	if len(lines) > 0 do pop(&lines)
	ph := f32(len(lines)) * lh + 20
	py := clamp(line_y, top + 4, max(top + 4, bottom - ph - 4))
	gpu.draw_rect(r, {px, py, pw, ph}, {0.99, 0.91, 0.89, 0.98})
	gpu.draw_rect_outline(r, {px, py, pw, ph}, 2, COL_ERR)
	for l, i in lines do text.draw_line(r, g_ui, {px + 12, py + 10 + f32(i) * lh}, l, {0.45, 0.08, 0.08, 1})
}

// wrap_text splits s into lines no wider than maxw (at spaces where possible).
wrap_text :: proc(font: ^text.Font, s: string, maxw: f32) -> []string {
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	rest := s
	for len(rest) > 0 {
		if text.measure(font, rest).x <= maxw { append(&out, rest); break }
		k := 1
		for k < len(rest) && text.measure(font, rest[:k + 1]).x <= maxw do k += 1
		if sp := strings.last_index_byte(rest[:k], ' '); sp > 0 do k = sp
		append(&out, rest[:k])
		rest = strings.trim_left_space(rest[k:])
	}
	return out[:]
}

// Width of a field on one row (for the "does it fit" decision).
@(private = "file")
field_width :: proc(f: model.Field) -> f32 {
	if f.slot && f.kind == model.CAPTURE_KIND do return 0 // drawn in the indentation
	if f.slot {
		label := slot_hint_label(f)
		return DOT_W + (label != "" ? text.measure(g_ui, label).x + 6 : 0)
	}
	return text.measure(g_code, expand_tabs(f.text)).x
}

// Color of the byte at line offset `at` inside field f.
@(private = "file")
run_color :: proc(f: model.Field, hl: []model.Hl, at: int) -> gpu.Color {
	if f.editable && f.kind != "string" && f.kind != model.COMMENT_KIND do return COL_ACCENT // names you can rename/dictate (a comment's text keeps its color)
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
		lays[ni] = layout_node(node, x0, max_x, packages, m.word_edit_active && ni == m.word_ni ? m.word_fi : -1)
		lays[ni].y = y
		y += f32(lays[ni].rows) * lh
	}
	content_end := y

	// What's highlighted: the part under the cursor, or (RT held / just used)
	// the RT tree selection - a part, a whole line, or a block of lines.
	hl, has_hl := model.current_highlight(m, g_walk_held && m.state == .Editor)
	cursor_on_attr := model.on_attr_dot(m) // the purple dot above a procedure (attr_dots.odin)
	cursor_on_dot := model.on_dot(m) && !cursor_on_attr // a green one
	in_hl :: proc(hl: model.Highlight, ni, fi: int) -> bool {
		if ni < hl.ni || ni > hl.end_ni do return false
		if hl.fb < 0 do return true // whole line(s)
		return fi >= hl.fa && fi < hl.fb
	}
	cur_y := y_start - lh * 0.3
	if cursor_on_dot || cursor_on_attr {
		if m.editor_line > 0 && m.editor_line <= n {
			prev := lays[m.editor_line - 1]
			cur_y = prev.y + f32(prev.rows) * lh + lh * 0.3
		}
	} else if m.editor_line >= 0 && m.editor_line < n {
		lay := lays[m.editor_line]
		row := 0
		for it in lay.items do if has_hl && hl.fb >= 0 && it.fi >= hl.fa && it.fi < hl.fb { row = it.row; break }
		cur_y = lay.y + f32(row) * lh
	}
	// Keep the cursor row inside [top, bottom] (with a line of margin).
	if cur_y - g_scroll > bottom - 2 * lh do g_scroll = cur_y - (bottom - 2 * lh)
	if cur_y - g_scroll < top + lh do g_scroll = cur_y - (top + lh)
	g_scroll = clamp(g_scroll, 0, max(0, content_end - (bottom - top)))
	sy := -g_scroll
	visible :: proc(y0, y1, top, bottom: f32) -> bool { return y1 > top && y0 < bottom }

	// Lifted with Grab (model/grab.odin): a glowing orange box around its lines.
	gni, gend, grabbed := model.grab_lines(m)
	if grabbed && gni >= 0 && gend < n {
		y0 := lays[gni].y + sy
		y1 := lays[gend].y + f32(lays[gend].rows) * lh + sy
		if y1 > top && y0 < bottom {
			box := gpu.Rect{pad, max(y0, top), f32(w) - pad * 2, min(y1, bottom) - max(y0, top)}
			pulse := 0.5 + 0.5 * math.sin(f32(g_time) * 4.0)
			// Orange; red for a copy that can't be dropped here (between procedures).
			glow, fill, edge := gpu.Color{1.00, 0.55, 0.10, 1}, gpu.Color{1.00, 0.60, 0.15, 1}, gpu.Color{0.95, 0.50, 0.05, 0.95}
			if model.grab_blocked(m) do glow, fill, edge = {0.90, 0.15, 0.12, 1}, {0.95, 0.20, 0.15, 1}, {0.80, 0.10, 0.08, 0.95}
			for k in 1 ..= 4 { // the glow: fading outlines outside the box
				d := f32(k) * 3
				gpu.draw_rect_outline(r, {box.x - d, box.y - d, box.w + 2 * d, box.h + 2 * d}, 3, {glow.r, glow.g, glow.b, (0.20 + 0.15 * pulse) / f32(k)})
			}
			gpu.draw_rect(r, box, {fill.r, fill.g, fill.b, 0.14 + 0.06 * pulse})
			gpu.draw_rect_outline(r, box, 2, edge)
		}
	}

	// A whole line / block selected with RT: shade its rows.
	if !grabbed && has_hl && hl.fb < 0 && hl.ni >= 0 && hl.end_ni < n {
		y0 := lays[hl.ni].y + sy
		y1 := lays[hl.end_ni].y + f32(lays[hl.end_ni].rows) * lh + sy
		if y1 > top && y0 < bottom {
			box := gpu.Rect{pad, max(y0, top), f32(w) - pad * 2, min(y1, bottom) - max(y0, top)}
			gpu.draw_rect(r, box, {0.22, 0.40, 0.70, 0.25})
			gpu.draw_rect_outline(r, box, 2, {COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 0.6})
		}
	}

	// Insertion dot before the first construct.
	dots := model.dot_points(m, context.temp_allocator) // one green dot per gap
	dot_inds := model.insertion_indents(m, context.temp_allocator) // dots inside a file-scope when sit indented
	top_dot_y := y_start - lh * 0.3 + sy
	if visible(top_dot_y - 10, top_dot_y + 10, top, bottom) {
		if cursor_on_dot && m.editor_line == 0 do draw_green_dot_highlighted(r, dot_x(), top_dot_y)
		else do draw_green_dot(r, dot_x(), top_dot_y)
	}

	// Saved-file line numbers, and the compiler's problems (checker.odin) per node.
	starts := model.node_line_starts(m, context.temp_allocator)
	diags := current_diags(m)
	node_bad := make([]bool, n, context.temp_allocator)
	for d in diags do if k := model.node_for_line(starts, d.line); k >= 0 do node_bad[k] = true

	for node, ni in m.doc.nodes {
		lay := lays[ni]
		ny := lay.y + sy
		if visible(ny, ny + f32(lay.rows) * lh, top, bottom) {
			if node_bad[ni] { // a problem odin check found: shade the line(s) red
				gpu.draw_rect(r, {x0 - 6, ny, max_x - x0 + 12, f32(lay.rows) * lh}, {0.90, 0.25, 0.22, 0.14})
				gpu.draw_rect(r, {x0 - 6, ny, 3, f32(lay.rows) * lh}, COL_ERR)
			}
			for nr in lay.num_rows {
				ry := ny + f32(nr[0]) * lh
				if ry + lh <= top || ry >= bottom do continue
				num := starts[ni] + nr[1]
				col := COL_DIM
				for d in diags do if d.line == num { col = COL_ERR; break }
				label := fmt.tprintf("%d", num)
				lw := text.measure(g_ui, label).x
				text.draw_line(r, g_ui, {pad + LINE_NUM_W - 10 - lw, ry + (lh - text.line_height(g_ui)) * 0.5}, label, col)
			}
			for it in lay.items {
				iy := ny + f32(it.row) * lh
				if iy + lh <= top || iy >= bottom do continue
				// The highlighted part (one field, or several: a whole argument).
				selected := has_hl && hl.fb >= 0 && it.fi >= 0 && in_hl(hl, ni, it.fi)
				if m.word_edit_active && ni == m.word_ni && it.wstop == 0 do selected = false // just the word, not its quotes
				if it.wstop > 0 {
					// Word by word: the cursor's word in the green box, yellow dots in the gaps.
					selected = it.wstop - 1 == m.word_stop && it.wstop % 2 == 0
					if it.wstop % 2 == 1 {
						draw_word_dot(r, it.x + it.w / 2, iy + lh / 2, it.wstop - 1 == m.word_stop)
						continue
					}
				}
				if selected {
					gpu.draw_rect(r, {it.x - 3, iy, it.w + 6, lh}, COL_SEL_BG)
					gpu.draw_rect_outline(r, {it.x - 3, iy, it.w + 6, lh}, 2, COL_ACCENT)
				}
				if it.dot {
					f := node.fields[it.fi]
					outer, inner := slot_dot_color(f.kind)
					if f.kind == "body" || f.kind == "args" || f.kind == model.FIELDS_KIND {
						draw_small_green_dot(r, it.x + DOT_W / 2, iy + lh / 2)
					} else if f.kind == model.CAPTURE_KIND {
						// Steady and smaller than a fill-me dot: an option, not a hole.
						gpu.draw_circle(r, it.x + DOT_W / 2, iy + lh / 2, 8, {outer.r, outer.g, outer.b, 0.20})
						gpu.draw_circle(r, it.x + DOT_W / 2, iy + lh / 2, 4.5, inner)
					} else {
						draw_colored_dot(r, it.x + DOT_W / 2, iy + lh / 2, outer, inner)
					}
					if m.ref_pick_active && ni == m.ref_ni && it.fi == m.ref_fi {
						// The dot a "Reference" pick will fill: a pulsing ring.
						pulse := 0.5 + 0.5 * math.sin(f32(g_time) * 6.0)
						gpu.draw_circle_outline(r, it.x + DOT_W / 2, iy + lh / 2, 11 + 2 * pulse, 2, {0.85, 0.58, 0.05, 0.9})
					}
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
			// Inside a file-scope when: indented like the declarations there.
			ddx := dot_inds[ni + 1] != "" ? text.measure(g_code, expand_tabs(dot_inds[ni + 1])).x : 0
			if visible(dot_y - 10, dot_y + 10, top, bottom) {
				if cursor_on_dot && m.editor_line == ni + 1 do draw_green_dot_highlighted(r, dot_x() + ddx, dot_y)
				else do draw_green_dot(r, dot_x() + ddx, dot_y)
			}
		}
	}

	// The purple attribute dots above procedures (model.attr_points): over the
	// procedure's name (above its attribute lines) - in the middle of the blank
	// line above it if there is one, else on the boundary between the rows (clear
	// of the text either way).
	ap := model.attr_points(m, context.temp_allocator)
	for i in 0 ..< n {
		if !ap[i] do continue
		dot_y := lays[i].y + sy
		if i > 0 && model.is_blank_line(m.doc.nodes[i - 1]) do dot_y = lays[i - 1].y + lh * 0.55 + sy
		if i == 0 do dot_y = y_start - lh * 0.3 + sy
		if !visible(dot_y - 10, dot_y + 10, top, bottom) do continue
		ind_w := text.measure(g_code, expand_tabs(model.line_indent(m.doc.nodes[i]))).x
		ax := x0 + ind_w + ATTR_DOT_DX
		if cursor_on_attr && m.editor_line == i do draw_attr_dot_highlighted(r, ax, dot_y)
		else do draw_attr_dot(r, ax, dot_y)
	}

	// The insertion dots inside functions (model.body_points): in the indentation,
	// on the boundary above line i.
	bp := model.body_points(m, context.temp_allocator)
	for i in 1 ..< n {
		if !bp[i] do continue
		dot_y := lays[i].y + sy
		if !visible(dot_y - 10, dot_y + 10, top, bottom) do continue
		ind_w := text.measure(g_code, expand_tabs(model.body_indent_at(m, i))).x
		// In the indentation; for unindented code, just left of it (not on the text).
		bdx := ind_w >= 20 ? x0 + ind_w - 12 : x0 - 10
		if cursor_on_dot && m.editor_line == i {
			draw_green_dot_highlighted(r, bdx, dot_y)
		} else {
			draw_body_dot(r, bdx, dot_y)
		}
	}

	// Scroll hints.
	if g_scroll > 0 do text.draw_centered(r, g_ui, {0, top - 4, f32(w), 18}, "^", COL_DIM)
	if content_end - g_scroll > bottom do text.draw_centered(r, g_ui, {0, bottom - 14, f32(w), 18}, "v", COL_DIM)

	// The problems on the line under the cursor, at the right of the screen.
	if !cursor_on_dot && !cursor_on_attr && m.editor_line >= 0 && m.editor_line < n && node_bad[m.editor_line] {
		// Just below the line, at the right, so the line itself stays readable.
		below := lays[m.editor_line].y + sy + f32(lays[m.editor_line].rows) * lh + 4
		draw_error_panel(r, w, diags, starts, m.editor_line, below, top, bottom)
	}

	// Title bar (drawn last so scrolled code never covers it).
	gpu.draw_rect(r, {0, 0, f32(w), 50}, COL_BG)
	title := editor_title()
	text.draw_line(r, g_ui, {pad, 14}, title, COL_DIM)
	if len(diags) > 0 {
		label := fmt.tprintf("%d problem%s", len(diags), len(diags) == 1 ? "" : "s")
		text.draw_line(r, g_ui, {pad + text.measure(g_ui, title).x + 24, 14}, label, COL_ERR)
	}
	gpu.draw_rect(r, {0, 50, f32(w), 1}, COL_RULE)

	// "Reference": picking a name in the file.
	if m.ref_pick_active {
		bar := gpu.Rect{0, 51, f32(w), 30}
		gpu.draw_rect(r, bar, {0.99, 0.90, 0.60, 0.97})
		text.draw_centered(r, g_ui, bar, "Pick a name to reference   -   D-pad move   A use it   B cancel", {0.42, 0.28, 0.00, 1})
	}
	// Modifiers (attributes, struct directives, calling conventions): picking a declaration.
	if m.mod_pick_active {
		bar := gpu.Rect{0, 51, f32(w), 30}
		gpu.draw_rect(r, bar, {0.99, 0.90, 0.60, 0.97})
		text.draw_centered(r, g_ui, bar, model.mod_pick_banner(m), {0.42, 0.28, 0.00, 1})
	}
	// What Y / LT+B do on a highlighted keyword (when, #assert, attributes, ...).
	hint := model.rebind_hint(m.keymap, model.ctrl_hint(m))
	if m.word_edit_active do hint = model.word_edit_hint(m) // inside a string, word by word
	if m.grab_active {
		// Lifted (model/grab.odin): only these buttons do anything now.
		hint = "Up/Down move   RT+Up/Down jump   X / A drop   B put back"
		if m.grab_copy do hint = "Up/Down move the copy   RT+Up/Down jump   X / A drop   B no copy"
		if model.grab_blocked(m) do hint = "Outside a procedure: can't drop here   Up/Down move   B no copy"
	}
	if hint != "" && !m.ref_pick_active {
		hw := text.measure(g_ui, hint).x
		// On the title bar's own colour, so a long file path under it doesn't show through.
		gpu.draw_rect(r, {f32(w) - 352 - hw, 8, hw + 24, 34}, COL_BG)
		text.draw_line(r, g_ui, {f32(w) - 340 - hw, 14}, hint, COL_ACCENT)
	}

	// STT push-to-talk indicator / last heard word.
	if g_recording {
		text.draw_line(r, g_ui, {f32(w) - 150, 14}, "[REC]", COL_ERR)
	} else if g_stt_busy {
		// The words are being worked out in the background (stt.end_async): dots that cycle.
		dots := [?]string{"transcribing.", "transcribing..", "transcribing..."}
		text.draw_line(r, g_ui, {f32(w) - 190, 14}, dots[int(g_time * 3) % 3], COL_ACCENT)
	} else if g_heard != "" {
		text.draw_line(r, g_ui, {f32(w) - 320, 14}, fmt.tprintf("heard: %s", g_heard), COL_ACCENT)
	}
}

// Word by word (model/word_edit.odin): the yellow dot in a gap between words.
WORD_DOT_W :: f32(16)
COL_WORD_DOT :: gpu.Color{0.90, 0.68, 0.05, 1}

draw_word_dot :: proc(r: ^gpu.Renderer, cx, cy: f32, on: bool) {
	if on {
		pulse := 0.5 + 0.5 * math.sin(f32(g_time) * 4.0)
		gpu.draw_circle(r, cx, cy, 7 + 1.5 * pulse, {COL_WORD_DOT.r, COL_WORD_DOT.g, COL_WORD_DOT.b, 0.22 + 0.18 * pulse})
		gpu.draw_circle(r, cx, cy, 4, COL_WORD_DOT)
		return
	}
	gpu.draw_circle(r, cx, cy, 3, COL_WORD_DOT)
}

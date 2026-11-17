package text

// Font loading, stb_truetype baked atlas, line layout + draw.
// Owner: Agent B.  Contract: ARCHITECTURE.md §5.3

import "../gpu"
import stbtt "vendor:stb/truetype"
import "core:os"

FIRST_CHAR :: 32
NUM_CHARS  :: 96 // 32..127
ATLAS_W    :: 512
ATLAS_H    :: 512

Font :: struct {
	atlas:       gpu.Texture,
	chars:       [NUM_CHARS]stbtt.bakedchar,
	px_size:     f32,
	ascent:      f32,
	line_height: f32,
	pw, ph:      i32,
}

load_font :: proc(r: ^gpu.Renderer, path: string, px_size: f32) -> (^Font, bool) {
	data, _ := os.read_entire_file(path, context.allocator)
	if data == nil do return nil, false
	defer delete(data)

	f := new(Font)
	f.px_size = px_size
	f.pw = ATLAS_W
	f.ph = ATLAS_H

	info: stbtt.fontinfo
	if !stbtt.InitFont(&info, raw_data(data), 0) {
		free(f)
		return nil, false
	}
	scale := stbtt.ScaleForPixelHeight(&info, px_size)
	asc, desc, gap: i32
	stbtt.GetFontVMetrics(&info, &asc, &desc, &gap)
	f.ascent = f32(asc) * scale
	f.line_height = f32(asc - desc + gap) * scale

	// Bake an 8-bit coverage atlas.
	alpha := make([]u8, int(ATLAS_W * ATLAS_H))
	defer delete(alpha)
	stbtt.BakeFontBitmap(raw_data(data), 0, px_size, raw_data(alpha), ATLAS_W, ATLAS_H, FIRST_CHAR, NUM_CHARS, &f.chars[0])

	// Expand to RGBA: white with coverage as alpha (works with the solid shader).
	rgba := make([]u8, int(ATLAS_W * ATLAS_H * 4))
	defer delete(rgba)
	for i in 0 ..< int(ATLAS_W * ATLAS_H) {
		a := alpha[i]
		rgba[i * 4 + 0] = 255
		rgba[i * 4 + 1] = 255
		rgba[i * 4 + 2] = 255
		rgba[i * 4 + 3] = a
	}
	f.atlas = gpu.texture_create(ATLAS_W, ATLAS_H, rgba, 4)
	return f, true
}

atlas_tex :: proc(f: ^Font) -> ^gpu.Texture { return &f.atlas }
line_height :: proc(f: ^Font) -> f32 { return f.line_height }

measure :: proc(f: ^Font, s: string) -> gpu.Vec2 {
	w: f32 = 0
	for b in transmute([]u8)s {
		if int(b) >= FIRST_CHAR && int(b) < FIRST_CHAR + NUM_CHARS {
			w += f.chars[int(b) - FIRST_CHAR].xadvance
		}
	}
	return {w, f.line_height}
}

// Draw one line of ASCII text. `pos` is the top-left; returns pen end x.
draw_line :: proc(r: ^gpu.Renderer, f: ^Font, pos: gpu.Vec2, s: string, color: gpu.Color) -> f32 {
	xpos := pos.x
	ypos := pos.y + f.ascent
	for b in transmute([]u8)s {
		idx := int(b) - FIRST_CHAR
		if idx < 0 || idx >= NUM_CHARS do continue
		q: stbtt.aligned_quad
		stbtt.GetBakedQuad(&f.chars[0], f.pw, f.ph, i32(idx), &xpos, &ypos, &q, true)
		dst := gpu.Rect{q.x0, q.y0, q.x1 - q.x0, q.y1 - q.y0}
		uv := gpu.Rect{q.s0, q.t0, q.s1 - q.s0, q.t1 - q.t0}
		gpu.draw_glyph(r, dst, &f.atlas, uv, color)
	}
	return xpos
}

// Convenience: measure then draw centered within a rect's x-range at vertical center.
draw_centered :: proc(r: ^gpu.Renderer, f: ^Font, area: gpu.Rect, s: string, color: gpu.Color) {
	sz := measure(f, s)
	x := area.x + (area.w - sz.x) * 0.5
	y := area.y + (area.h - f.line_height) * 0.5
	draw_line(r, f, {x, y}, s, color)
}

shutdown :: proc(f: ^Font) {
	if f != nil do free(f)
}

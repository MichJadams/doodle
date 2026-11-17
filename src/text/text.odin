package text

import "../gpu"

// Font loading, stb_truetype rasterization, glyph atlas, line layout.
// Owner: Agent B.  Contract: ARCHITECTURE.md §5.3

Glyph :: struct {
	uv:      gpu.Rect, // location in atlas (0..1)
	size:    gpu.Vec2, // px
	bearing: gpu.Vec2, // px offset from pen origin
	advance: f32,      // px
}

Font :: struct {
	px_size:     f32,
	line_height: f32,
	ascent:      f32,
	// stbtt_fontinfo, atlas texture, glyph cache map, shelf packer state
	atlas: gpu.Texture,
}

load_font :: proc(r: ^gpu.Renderer, path: string, px_size: f32) -> (^Font, bool) {
	// TODO: read file, stbtt_InitFont, allocate atlas texture.
	return nil, false
}

set_px_size :: proc(f: ^Font, px_size: f32) {
	// TODO: clear cache, re-raster on DPI/zoom change.
}

glyph :: proc(f: ^Font, r: rune) -> Glyph {
	// TODO: lazily rasterize into atlas (shelf pack), cache, return.
	return {}
}

atlas_tex :: proc(f: ^Font) -> ^gpu.Texture { return &f.atlas }

measure :: proc(f: ^Font, s: string) -> gpu.Vec2 { return {} }

line_height :: proc(f: ^Font) -> f32 { return f.line_height }

// Draw one line (no shaping, LTR, pixel-snapped). Returns pen end x.
draw_line :: proc(r: ^gpu.Renderer, f: ^Font, pos: gpu.Vec2, s: string, color: gpu.Color) -> f32 {
	return pos.x
}

shutdown :: proc(f: ^Font) {}

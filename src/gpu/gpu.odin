package gpu

import "../platform"

// GL context, shaders, batched textured-quad renderer.
// Owner: Agent A.  Contract: ARCHITECTURE.md §5.2

Vec2  :: [2]f32
Rect  :: struct { x, y, w, h: f32 }
Color :: [4]f32 // linear RGBA 0..1

Texture :: struct { id: u32, w, h: int }

Renderer :: struct {
	// shader program, VAO/VBO, CPU-side batch buffer, 1x1 white texture
	win: ^platform.Window,
}

init :: proc(win: ^platform.Window) -> (^Renderer, bool) {
	// TODO: load GL procs, compile shader, create buffers + white texture.
	return nil, false
}

begin_frame :: proc(r: ^Renderer, w, h: int, clear: Color) {
	// TODO: set viewport, ortho projection, glClear, reset batch.
}

end_frame :: proc(r: ^Renderer) {
	// TODO: flush remaining batched quads.
}

draw_rect :: proc(r: ^Renderer, dst: Rect, color: Color) {
	// TODO: push a white-textured quad.
}

draw_glyph :: proc(r: ^Renderer, dst: Rect, tex: ^Texture, uv: Rect, color: Color) {
	// TODO: push a glyph quad; flush on texture switch.
}

texture_create :: proc(w, h: int, pixels: []u8, channels: int) -> Texture {
	return {}
}
texture_update :: proc(t: ^Texture, x, y, w, h: int, pixels: []u8) {}

shutdown :: proc(r: ^Renderer) {}

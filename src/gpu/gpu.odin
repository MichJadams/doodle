package gpu

// GL context, shaders, batched textured-quad renderer.
// Owner: Agent A.  Contract: ARCHITECTURE.md §5.2

import "../platform"
import gl "vendor:OpenGL"
import "core:math"

Vec2  :: [2]f32
Rect  :: struct { x, y, w, h: f32 }
Color :: [4]f32 // RGBA 0..1

Texture :: struct { id: u32, w, h: int }

Vertex :: struct {
	pos: Vec2,
	uv:  Vec2,
	col: Color,
}

MAX_VERTS :: 65536

Renderer :: struct {
	program:  u32,
	vao, vbo: u32,
	proj_loc: i32,
	white:    Texture,
	cur_tex:  u32,
	verts:    [dynamic]Vertex,
}

VERT_SRC :: `#version 330 core
layout(location=0) in vec2 aPos;
layout(location=1) in vec2 aUV;
layout(location=2) in vec4 aColor;
uniform mat4 uProj;
out vec2 vUV;
out vec4 vColor;
void main() {
	gl_Position = uProj * vec4(aPos, 0.0, 1.0);
	vUV = aUV;
	vColor = aColor;
}
`

FRAG_SRC :: `#version 330 core
in vec2 vUV;
in vec4 vColor;
out vec4 FragColor;
uniform sampler2D uTex;
void main() {
	FragColor = vColor * texture(uTex, vUV);
}
`

init :: proc(win: ^platform.Window) -> (^Renderer, bool) {
	prog, ok := gl.load_shaders_source(VERT_SRC, FRAG_SRC)
	if !ok do return nil, false

	r := new(Renderer)
	r.program = prog
	r.proj_loc = gl.GetUniformLocation(prog, "uProj")

	gl.GenVertexArrays(1, &r.vao)
	gl.GenBuffers(1, &r.vbo)
	gl.BindVertexArray(r.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, MAX_VERTS * size_of(Vertex), nil, gl.DYNAMIC_DRAW)

	stride := i32(size_of(Vertex))
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, stride, uintptr(offset_of(Vertex, pos)))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, stride, uintptr(offset_of(Vertex, uv)))
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribPointer(2, 4, gl.FLOAT, false, stride, uintptr(offset_of(Vertex, col)))

	// 1x1 white texture for solid shapes.
	white_px := [4]u8{255, 255, 255, 255}
	r.white = texture_create(1, 1, white_px[:], 4)

	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

	r.verts = make([dynamic]Vertex, 0, MAX_VERTS)
	r.cur_tex = r.white.id
	return r, true
}

@(private)
ortho :: proc(l, rgt, b, t: f32) -> [16]f32 {
	m: [16]f32
	m[0] = 2.0 / (rgt - l)
	m[5] = 2.0 / (t - b)
	m[10] = -1.0
	m[12] = -(rgt + l) / (rgt - l)
	m[13] = -(t + b) / (t - b)
	m[15] = 1.0
	return m
}

begin_frame :: proc(r: ^Renderer, w, h: int, clear_color: Color) {
	gl.Viewport(0, 0, i32(w), i32(h))
	gl.ClearColor(clear_color.r, clear_color.g, clear_color.b, clear_color.a)
	gl.Clear(gl.COLOR_BUFFER_BIT)

	gl.UseProgram(r.program)
	// y-down: top=0, bottom=h
	proj := ortho(0, f32(w), f32(h), 0)
	gl.UniformMatrix4fv(r.proj_loc, 1, false, &proj[0])

	clear(&r.verts)
	r.cur_tex = r.white.id
}

@(private)
flush :: proc(r: ^Renderer) {
	n := len(r.verts)
	if n == 0 do return
	gl.BindVertexArray(r.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.vbo)
	gl.BufferSubData(gl.ARRAY_BUFFER, 0, n * size_of(Vertex), rawptr(raw_data(r.verts)))
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, r.cur_tex)
	gl.Uniform1i(gl.GetUniformLocation(r.program, "uTex"), 0)
	gl.DrawArrays(gl.TRIANGLES, 0, i32(n))
	clear(&r.verts)
}

@(private)
use_texture :: proc(r: ^Renderer, tex: u32) {
	if tex != r.cur_tex {
		flush(r)
		r.cur_tex = tex
	}
}

@(private)
push_tri :: proc(r: ^Renderer, a, b, c: Vertex) {
	if len(r.verts) + 3 > MAX_VERTS {
		flush(r)
	}
	append(&r.verts, a, b, c)
}

end_frame :: proc(r: ^Renderer) {
	flush(r)
}

// --- Solid-color primitives (use the white texture) ---

draw_rect :: proc(r: ^Renderer, dst: Rect, color: Color) {
	use_texture(r, r.white.id)
	x0, y0 := dst.x, dst.y
	x1, y1 := dst.x + dst.w, dst.y + dst.h
	uv := Vec2{0.5, 0.5}
	tl := Vertex{{x0, y0}, uv, color}
	tr := Vertex{{x1, y0}, uv, color}
	br := Vertex{{x1, y1}, uv, color}
	bl := Vertex{{x0, y1}, uv, color}
	push_tri(r, tl, tr, br)
	push_tri(r, tl, br, bl)
}

draw_rect_outline :: proc(r: ^Renderer, dst: Rect, thickness: f32, color: Color) {
	t := thickness
	draw_rect(r, {dst.x, dst.y, dst.w, t}, color)                      // top
	draw_rect(r, {dst.x, dst.y + dst.h - t, dst.w, t}, color)          // bottom
	draw_rect(r, {dst.x, dst.y, t, dst.h}, color)                      // left
	draw_rect(r, {dst.x + dst.w - t, dst.y, t, dst.h}, color)          // right
}

draw_circle :: proc(r: ^Renderer, cx, cy, radius: f32, color: Color, segments := 28) {
	use_texture(r, r.white.id)
	uv := Vec2{0.5, 0.5}
	center := Vertex{{cx, cy}, uv, color}
	step := (2.0 * math.PI) / f32(segments)
	for i in 0 ..< segments {
		a0 := f32(i) * step
		a1 := f32(i + 1) * step
		p0 := Vertex{{cx + math.cos(a0) * radius, cy + math.sin(a0) * radius}, uv, color}
		p1 := Vertex{{cx + math.cos(a1) * radius, cy + math.sin(a1) * radius}, uv, color}
		push_tri(r, center, p0, p1)
	}
}

draw_circle_outline :: proc(r: ^Renderer, cx, cy, radius, thickness: f32, color: Color, segments := 28) {
	use_texture(r, r.white.id)
	uv := Vec2{0.5, 0.5}
	inner := radius - thickness
	step := (2.0 * math.PI) / f32(segments)
	for i in 0 ..< segments {
		a0 := f32(i) * step
		a1 := f32(i + 1) * step
		c0 := math.cos(a0); s0 := math.sin(a0)
		c1 := math.cos(a1); s1 := math.sin(a1)
		o0 := Vertex{{cx + c0 * radius, cy + s0 * radius}, uv, color}
		o1 := Vertex{{cx + c1 * radius, cy + s1 * radius}, uv, color}
		i0 := Vertex{{cx + c0 * inner, cy + s0 * inner}, uv, color}
		i1 := Vertex{{cx + c1 * inner, cy + s1 * inner}, uv, color}
		push_tri(r, o0, o1, i1)
		push_tri(r, o0, i1, i0)
	}
}

// --- Textured quad (used by text atlas) ---

draw_glyph :: proc(r: ^Renderer, dst: Rect, tex: ^Texture, uv: Rect, color: Color) {
	use_texture(r, tex.id)
	x0, y0 := dst.x, dst.y
	x1, y1 := dst.x + dst.w, dst.y + dst.h
	u0, v0 := uv.x, uv.y
	u1, v1 := uv.x + uv.w, uv.y + uv.h
	tl := Vertex{{x0, y0}, {u0, v0}, color}
	tr := Vertex{{x1, y0}, {u1, v0}, color}
	br := Vertex{{x1, y1}, {u1, v1}, color}
	bl := Vertex{{x0, y1}, {u0, v1}, color}
	push_tri(r, tl, tr, br)
	push_tri(r, tl, br, bl)
}

texture_create :: proc(w, h: int, pixels: []u8, channels: int) -> Texture {
	t: Texture
	t.w = w; t.h = h
	gl.GenTextures(1, &t.id)
	gl.BindTexture(gl.TEXTURE_2D, t.id)
	internal: i32 = channels == 1 ? i32(gl.RED) : i32(gl.RGBA)
	format: u32 = channels == 1 ? gl.RED : gl.RGBA
	gl.TexImage2D(gl.TEXTURE_2D, 0, internal, i32(w), i32(h), 0, format, gl.UNSIGNED_BYTE, rawptr(raw_data(pixels)))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	return t
}

texture_destroy :: proc(r: ^Renderer, t: ^Texture) {
	if t.id == 0 do return
	flush(r) // anything batched with this texture must be drawn first
	if r.cur_tex == t.id do r.cur_tex = 0
	gl.DeleteTextures(1, &t.id)
	t.id = 0
}

texture_update :: proc(t: ^Texture, x, y, w, h: int, pixels: []u8) {
	gl.BindTexture(gl.TEXTURE_2D, t.id)
	gl.TexSubImage2D(gl.TEXTURE_2D, 0, i32(x), i32(y), i32(w), i32(h), gl.RGBA, gl.UNSIGNED_BYTE, rawptr(raw_data(pixels)))
}

shutdown :: proc(r: ^Renderer) {
	if r == nil do return
	delete(r.verts)
	free(r)
}

package editor

import "../buffer"
import "../gpu"

// Cursors, selection, edit operations, viewport/scroll, virtualization.
// Owner: Agent C.  Contract: ARCHITECTURE.md §5.5

Direction :: enum { Up, Down, Left, Right, Word_Left, Word_Right, Line_Home, Line_End, Page_Up, Page_Down }

Cursor :: struct { pos: buffer.Pos, anchor: buffer.Pos }

View :: struct {
	buf:     ^buffer.Buffer,
	cursors: [dynamic]Cursor,
	scroll:  gpu.Vec2, // px
	path:    string,
	dirty:   bool,
}

open :: proc(path: string) -> (^View, bool) { return nil, false }

move_cursor :: proc(v: ^View, dir: Direction, select: bool) {}
type_text   :: proc(v: ^View, s: string) {}
backspace   :: proc(v: ^View) {}

scroll_to_cursor :: proc(v: ^View, viewport: gpu.Rect, line_h: f32) {}

// Viewport virtualization: inclusive range of lines to draw.
visible_lines :: proc(v: ^View, viewport: gpu.Rect, line_h: f32) -> (first: int, last: int) {
	return 0, 0
}

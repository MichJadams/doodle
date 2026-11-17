package input

import "../platform"
import "../gpu"

// Gamepad state, action mapping, spatial navigation.
// Owner: Agent D.  Contract: ARCHITECTURE.md §5.6

Button :: enum { A, B, X, Y, Up, Down, Left, Right, LB, RB, LT, RT, Start, Back, LStick, RStick, Guide }
Axis   :: enum { LX, LY, RX, RY, LTrigger, RTrigger }

Action :: enum {
	Confirm, Cancel, Nav_Up, Nav_Down, Nav_Left, Nav_Right,
	Next_Panel, Prev_Panel, Command_Palette, Dictate_Hold,
	Scroll_Up, Scroll_Down, Zoom_In, Zoom_Out,
}

Direction :: enum { Up, Down, Left, Right }

State :: struct {
	cur:  [Button]bool,
	prev: [Button]bool,
	axes: [Axis]f32,
}

update     :: proc(st: ^State, events: []platform.Event) {}
is_pressed :: proc(st: ^State, a: Action) -> bool { return false } // edge
is_down    :: proc(st: ^State, a: Action) -> bool { return false } // held
axis       :: proc(st: ^State, a: Axis) -> f32 { return 0 }

// Pick the best focus target rect in a direction (spatial nav). Returns index.
nav_target :: proc(rects: []gpu.Rect, current: int, dir: Direction) -> int { return current }

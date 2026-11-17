package platform

// SDL2 window, event pump, timing, and audio capture.
// Owner: Agent A.  Contract: ARCHITECTURE.md §5.1

Window :: struct {
	// opaque: SDL_Window*, SDL_GLContext, cached size
	width:  int,
	height: int,
}

Quit_Event     :: struct {}
Resize_Event   :: struct { w, h: int }
Gamepad_Button :: struct { button: int, pressed: bool }
Gamepad_Axis   :: struct { axis: int, value: f32 }
Text_Input     :: struct { text: string }

Event :: union {
	Quit_Event,
	Resize_Event,
	Gamepad_Button,
	Gamepad_Axis,
	Text_Input,
}

init :: proc(title: string, w, h: int) -> (^Window, bool) {
	// TODO: SDL_Init, create window with SDL_WINDOW_OPENGL, make GL context.
	return nil, false
}

poll_events :: proc(win: ^Window, out: ^[dynamic]Event) {
	// TODO: pump SDL events into `out`.
}

present :: proc(win: ^Window) {
	// TODO: SDL_GL_SwapWindow
}

get_size :: proc(win: ^Window) -> (int, int) {
	return win.width, win.height
}

now_seconds :: proc() -> f64 {
	// TODO: SDL_GetPerformanceCounter / frequency
	return 0
}

shutdown :: proc(win: ^Window) {
	// TODO: destroy context + window + SDL_Quit
}

// ---- Audio capture (for STT) ----
Audio_Capture :: struct {
	sample_rate: int,
	// opaque SDL audio device id + ring buffer
}

audio_open :: proc(sample_rate: int) -> (^Audio_Capture, bool) {
	return nil, false
}
audio_start :: proc(cap: ^Audio_Capture) {}
audio_stop  :: proc(cap: ^Audio_Capture) {}
audio_read  :: proc(cap: ^Audio_Capture, out: ^[dynamic]f32) -> int { return 0 }

package platform

// SDL2 window, GL context, event pump, timing.
// Owner: Agent A.  Contract: ARCHITECTURE.md §5.1

import sdl "vendor:sdl2"
import gl "vendor:OpenGL"
import "core:strings"

Window :: struct {
	handle:     ^sdl.Window,
	gl_ctx:     sdl.GLContext,
	width:      i32,
	height:     i32,
	controller: ^sdl.GameController,
}

Button :: enum {
	A, B, X, Y,
	Up, Down, Left, Right,
	LB, RB,
	Start, Back, LStick, RStick, Guide,
}

Axis :: enum { LX, LY, RX, RY, LTrigger, RTrigger }

Quit_Event   :: struct {}
Resize_Event :: struct { w, h: int }
Button_Event :: struct { button: Button, pressed: bool }
Axis_Event   :: struct { axis: Axis, value: f32 }
Key_Event    :: struct { sym: i32, pressed: bool }
Text_Event   :: struct { text: string }

Event :: union {
	Quit_Event,
	Resize_Event,
	Button_Event,
	Axis_Event,
	Key_Event,
	Text_Event,
}

init :: proc(title: string, w, h: int) -> (^Window, bool) {
	if sdl.Init(sdl.INIT_VIDEO | sdl.INIT_GAMECONTROLLER) < 0 {
		return nil, false
	}

	sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(sdl.GLprofile.CORE))
	sdl.GL_SetAttribute(.DOUBLEBUFFER, 1)

	win := new(Window)

	ctitle := strings.clone_to_cstring(title)
	defer delete(ctitle)

	win.handle = sdl.CreateWindow(
		ctitle,
		sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED,
		i32(w), i32(h),
		sdl.WINDOW_OPENGL | sdl.WINDOW_RESIZABLE | sdl.WINDOW_SHOWN | sdl.WINDOW_ALLOW_HIGHDPI,
	)
	if win.handle == nil {
		free(win)
		return nil, false
	}

	win.gl_ctx = sdl.GL_CreateContext(win.handle)
	if win.gl_ctx == nil {
		sdl.DestroyWindow(win.handle)
		free(win)
		return nil, false
	}
	sdl.GL_MakeCurrent(win.handle, win.gl_ctx)
	sdl.GL_SetSwapInterval(1)
	gl.load_up_to(3, 3, sdl.gl_set_proc_address)

	win.width = i32(w)
	win.height = i32(h)

	// Open the first available game controller, if any.
	n := sdl.NumJoysticks()
	for i in 0 ..< n {
		if sdl.IsGameController(i) {
			win.controller = sdl.GameControllerOpen(i)
			break
		}
	}

	return win, true
}

@(private)
map_button :: proc(b: sdl.GameControllerButton) -> (Button, bool) {
	#partial switch b {
	case .A:             return .A, true
	case .B:             return .B, true
	case .X:             return .X, true
	case .Y:             return .Y, true
	case .DPAD_UP:       return .Up, true
	case .DPAD_DOWN:     return .Down, true
	case .DPAD_LEFT:     return .Left, true
	case .DPAD_RIGHT:    return .Right, true
	case .LEFTSHOULDER:  return .LB, true
	case .RIGHTSHOULDER: return .RB, true
	case .START:         return .Start, true
	case .BACK:          return .Back, true
	case .LEFTSTICK:     return .LStick, true
	case .RIGHTSTICK:    return .RStick, true
	case .GUIDE:         return .Guide, true
	}
	return .A, false
}

@(private)
map_axis :: proc(a: sdl.GameControllerAxis) -> (Axis, bool) {
	#partial switch a {
	case .LEFTX:        return .LX, true
	case .LEFTY:        return .LY, true
	case .RIGHTX:       return .RX, true
	case .RIGHTY:       return .RY, true
	case .TRIGGERLEFT:  return .LTrigger, true
	case .TRIGGERRIGHT: return .RTrigger, true
	}
	return .LX, false
}

poll_events :: proc(win: ^Window, out: ^[dynamic]Event) {
	e: sdl.Event
	for sdl.PollEvent(&e) {
		#partial switch e.type {
		case .QUIT:
			append(out, Quit_Event{})
		case .KEYDOWN:
			append(out, Key_Event{i32(e.key.keysym.sym), true})
		case .KEYUP:
			append(out, Key_Event{i32(e.key.keysym.sym), false})
		case .CONTROLLERDEVICEADDED:
			if win.controller == nil {
				win.controller = sdl.GameControllerOpen(e.cdevice.which)
			}
		case .CONTROLLERBUTTONDOWN:
			if btn, ok := map_button(sdl.GameControllerButton(e.cbutton.button)); ok {
				append(out, Button_Event{btn, true})
			}
		case .CONTROLLERBUTTONUP:
			if btn, ok := map_button(sdl.GameControllerButton(e.cbutton.button)); ok {
				append(out, Button_Event{btn, false})
			}
		case .CONTROLLERAXISMOTION:
			if ax, ok := map_axis(sdl.GameControllerAxis(e.caxis.axis)); ok {
				append(out, Axis_Event{ax, f32(e.caxis.value) / 32767.0})
			}
		}
	}
}

present :: proc(win: ^Window) {
	sdl.GL_SwapWindow(win.handle)
}

get_size :: proc(win: ^Window) -> (int, int) {
	w, h: i32
	sdl.GL_GetDrawableSize(win.handle, &w, &h)
	win.width = w
	win.height = h
	return int(w), int(h)
}

now_seconds :: proc() -> f64 {
	return f64(sdl.GetTicks64()) / 1000.0
}

shutdown :: proc(win: ^Window) {
	if win == nil do return
	if win.controller != nil do sdl.GameControllerClose(win.controller)
	if win.gl_ctx != nil do sdl.GL_DeleteContext(win.gl_ctx)
	if win.handle != nil do sdl.DestroyWindow(win.handle)
	sdl.Quit()
	free(win)
}

// set_clipboard_text puts `s` on the system clipboard. Returns false on failure.
set_clipboard_text :: proc(s: string) -> bool {
	cs := strings.clone_to_cstring(s, context.temp_allocator)
	return sdl.SetClipboardText(cs) == 0
}

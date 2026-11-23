package platform

// D-pad auto-repeat (dpad_repeat_tick) with made-up times. (Running these
// needs SDL2.dll findable, like any program using vendor:sdl2.)

import "core:testing"

@(private = "file")
presses :: proc(win: ^Window, t: f64) -> int {
	out := make([dynamic]Event, context.temp_allocator)
	dpad_repeat_tick(win, t, &out)
	return len(out)
}

@(test)
test_dpad_repeat :: proc(t: ^testing.T) {
	win: Window
	win.dpad[1] = {held = true, down_at = 10.0, last = 10.0} // Down pressed at t = 10
	testing.expect_value(t, presses(&win, 10.20), 0)         // still within the delay
	testing.expect_value(t, presses(&win, 10.36), 1)         // the first repeat
	testing.expect_value(t, presses(&win, 10.40), 0)         // too soon after it
	testing.expect_value(t, presses(&win, 10.44), 1)         // the next one
	n := 0
	for k in 0 ..< 60 do n += presses(&win, 10.44 + f64(k + 1) / 60.0) // one second of 60 fps frames
	testing.expectf(t, n >= 12 && n <= 15, "about 14 repeats a second, got %d", n)

	win.dpad_no_repeat = true // dictating
	testing.expect_value(t, presses(&win, 20.0), 0)
	win.dpad_no_repeat = false
	win.dpad[1].held = false // released
	testing.expect_value(t, presses(&win, 30.0), 0)
}

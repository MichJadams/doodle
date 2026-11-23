package model

import "core:strings"
import "core:testing"

@(test)
test_vendor_imports :: proc(t: ^testing.T) {
	out := make([dynamic]string, context.temp_allocator)
	vendor_imports("package main\n\nimport \"vendor:sdl3\"\nimport img \"vendor:sdl2/image\"\nimport \"core:fmt\"\nimport \"vendor:sdl3\"\n// import \"vendor:raylib\"\n", &out)
	testing.expect_value(t, len(out), 2)
	if len(out) == 2 {
		testing.expect_value(t, out[0], "vendor:sdl3")
		testing.expect_value(t, out[1], "vendor:sdl2/image")
	}
	testing.expect_value(t, vendor_lib_dir("C:\\Odin\\", "vendor:sdl2/image"), "C:\\Odin/vendor/sdl2/image")
	testing.expect_value(t, vendor_lib_dir("/opt/odin", "vendor:sdl3"), "/opt/odin/vendor/sdl3")
}

@(test)
test_is_shared_lib :: proc(t: ^testing.T) {
	testing.expect(t, is_shared_lib("SDL3.dll", .Windows), "a dll")
	testing.expect(t, !is_shared_lib("SDL3.lib", .Windows), "an import library isn't")
	testing.expect(t, is_shared_lib("libSDL3.so", .Linux) && is_shared_lib("libSDL3.so.0", .Linux), "a .so / versioned .so")
	testing.expect(t, !is_shared_lib("libSDL3.a", .Linux), "a static library isn't")
	testing.expect(t, is_shared_lib("libSDL3.dylib", .Darwin), "a dylib")
}

@(test)
test_path_lists :: proc(t: ^testing.T) {
	win := "C:\\Windows\\system32;C:\\Odin\\vendor\\SDL3\\;C:\\tools"
	testing.expect(t, path_list_has(win, "c:/odin/vendor/sdl3", .Windows), "Windows: any case, / or \\, trailing \\")
	testing.expect(t, !path_list_has(win, "C:\\Odin\\vendor\\sdl2", .Windows), "not there")
	testing.expect_value(t, path_list_add("C:\\a;", "C:\\b", .Windows), "C:\\a;C:\\b")
	testing.expect_value(t, path_list_add("", "C:\\b", .Windows), "C:\\b")
	testing.expect_value(t, path_list_add(win, "C:\\Odin\\vendor\\sdl3", .Windows), win) // already there
	testing.expect(t, path_list_has("/usr/lib:/opt/odin/vendor/sdl3/", "/opt/odin/vendor/sdl3", .Linux), "Linux list")
	testing.expect(t, !path_list_has("/usr/lib", "/USR/LIB", .Linux), "Linux is case-sensitive")
}

@(test)
test_profile_lines :: proc(t: ^testing.T) {
	line := profile_line("/opt/odin/vendor/sdl3", "vendor:sdl3", .Linux)
	testing.expect_value(t, line, "export LD_LIBRARY_PATH=\"/opt/odin/vendor/sdl3${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\"  # added by Doodle for vendor:sdl3")
	profile := strings.concatenate({"# ~/.profile\nexport PATH=$HOME/bin:$PATH\n", line, "\n"}, context.temp_allocator)
	testing.expect(t, profile_has_dir(profile, "/opt/odin/vendor/sdl3", .Linux), "the added line counts")
	testing.expect(t, !profile_has_dir("# export LD_LIBRARY_PATH=/opt/odin/vendor/sdl3\n", "/opt/odin/vendor/sdl3", .Linux), "a commented line doesn't")
	testing.expect(t, strings.has_prefix(profile_line("/x", "vendor:sdl3", .Darwin), "export DYLD_LIBRARY_PATH="), "macOS uses DYLD_LIBRARY_PATH")
}

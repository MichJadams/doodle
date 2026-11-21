package main

// Hand-drawn UI icons (assets/icons). Loaded once at startup as white alpha
// masks, so each draw can tint them to whatever color suits its background.
// If an icon file is missing, draw_icon returns false and callers fall back to
// their old drawing (vector shapes / letters).

import "../gpu"
import "core:strings"
import stbi "vendor:stb/image"

Icon :: enum { Speech, Delete, Save, Files, Dpad, Add, Back, Copy, Search }

// 512px sources; mipmapped, so they stay clean at HUD sizes (~20-60px).
ICON_FILES := [Icon]string{
	.Speech = "assets/icons/speech-to-text-512.png",
	.Delete = "assets/icons/delete-512.png",
	.Save   = "assets/icons/save-512.png",
	.Files  = "assets/icons/navigate-files-512.png",
	.Dpad   = "assets/icons/dpad-512.png",
	.Add    = "assets/icons/add-512.png",
	.Back   = "assets/icons/back-512.png",
	.Copy   = "assets/icons/copy-512.png",
	.Search = "assets/icons/search-512.png",
	// (assets/icons/paste-*.png is there for when Doodle gets a paste command.)
}

g_icons: [Icon]gpu.Texture // id 0 = not loaded

load_icons :: proc() {
	for path, icon in ICON_FILES {
		cpath := strings.clone_to_cstring(asset_path(path), context.temp_allocator)
		w, h, n: i32
		px := stbi.load(cpath, &w, &h, &n, 4)
		if px == nil do continue
		defer stbi.image_free(px)
		pixels := px[:w * h * 4]
		// Keep only the shape (alpha); make the color white so it can be tinted.
		for k := 0; k < len(pixels); k += 4 {
			pixels[k], pixels[k + 1], pixels[k + 2] = 255, 255, 255
		}
		g_icons[icon] = gpu.texture_create_mipmapped(int(w), int(h), pixels)
	}
}

unload_icons :: proc(r: ^gpu.Renderer) {
	for &t in g_icons do gpu.texture_destroy(r, &t)
}

// draw_icon draws `icon` in a size x size square centered on (cx, cy), tinted
// `col`. Returns false (drawing nothing) if the icon isn't loaded.
draw_icon :: proc(r: ^gpu.Renderer, icon: Icon, cx, cy, size: f32, col: gpu.Color) -> bool {
	t := &g_icons[icon]
	if t.id == 0 do return false
	gpu.draw_glyph(r, {cx - size / 2, cy - size / 2, size, size}, t, {0, 0, 1, 1}, col)
	return true
}

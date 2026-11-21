package main

// move_to_trash sends a file or folder (with everything in it) to the Recycle
// Bin, so a delete from the file tree can be undone from Explorer. No Windows
// dialogs are shown. Returns false if it failed.

import win "core:sys/windows"
import "core:path/filepath"
import "core:strings"

move_to_trash :: proc(path: string) -> bool {
	// SHFileOperation wants a full path with backslashes, double-NUL terminated.
	abs, err := filepath.abs(path, context.temp_allocator)
	if err != nil do abs = path
	p, _ := strings.replace_all(abs, "/", "\\", context.temp_allocator)
	p = strings.trim_right(p, "\\")
	w := win.utf8_to_utf16(p, context.temp_allocator)
	buf := make([]u16, len(w) + 2, context.temp_allocator) // zeroed: the two NULs
	copy(buf, w)
	op := win.SHFILEOPSTRUCTW{
		wFunc  = win.FO_DELETE,
		pFrom  = cstring16(raw_data(buf)),
		fFlags = win.FILEOP_FLAGS(win.FOF_ALLOWUNDO | win.FOF_NO_UI),
	}
	return win.SHFileOperationW(&op) == 0 && !bool(op.fAnyOperationsAborted)
}

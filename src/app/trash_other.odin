#+build !windows
package main

// move_to_trash (non-Windows): there's no portable Recycle Bin, so this deletes
// the file or folder outright.

import "core:os"

move_to_trash :: proc(path: string) -> bool {
	if os.is_dir(path) do return os.remove_all(path) == nil
	return os.remove(path) == nil
}

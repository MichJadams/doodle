#+build !windows
package main

import "core:os"

// current_pid: this process's id (updater.odin).
current_pid :: proc() -> int { return int(os.get_pid()) }

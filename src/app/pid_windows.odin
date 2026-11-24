#+build windows
package main

import win32 "core:sys/windows"

// current_pid: this process's id (the Windows updater waits for it to end; updater.odin).
current_pid :: proc() -> int { return int(win32.GetCurrentProcessId()) }

package buffer

// Text storage (gap buffer -> maybe rope), undo/redo, line index.
// Owner: Agent C.  Contract: ARCHITECTURE.md §5.4

Pos   :: struct { line: int, col: int } // 0-based, col in runes
Range :: struct { start, end: Pos }

Buffer :: struct {
	// gap buffer bytes, line-start offsets, undo/redo stacks
}

make_buffer :: proc() -> ^Buffer { return nil }
load_file   :: proc(b: ^Buffer, path: string) -> bool { return false }
save_file   :: proc(b: ^Buffer, path: string) -> bool { return false }
line_count  :: proc(b: ^Buffer) -> int { return 0 }
line        :: proc(b: ^Buffer, i: int) -> string { return "" }
insert      :: proc(b: ^Buffer, at: Pos, text: string) -> Pos { return at }
remove      :: proc(b: ^Buffer, r: Range) {}
undo        :: proc(b: ^Buffer) -> (Pos, bool) { return {}, false }
redo        :: proc(b: ^Buffer) -> (Pos, bool) { return {}, false }

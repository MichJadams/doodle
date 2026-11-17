package project

// File tree (lazy), fuzzy index, background search.
// Owner: Agent G.  Contract: ARCHITECTURE.md §5.10

Node  :: struct { name: string, is_dir: bool, children: []Node }
Match :: struct { path: string, score: int, positions: []int }

open_root    :: proc(path: string) -> bool { return false }
read_dir     :: proc(path: string) -> []Node { return {} }      // one level
start_index  :: proc(root: string) {}                            // worker thread
fuzzy_find   :: proc(query: string, limit: int) -> []Match { return {} }
cancel_index :: proc() {}

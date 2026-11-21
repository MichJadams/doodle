package model

// Compiler diagnostics: the app runs `odin check` on the document in the
// background; these turn its output into per-line problems and map saved-file
// line numbers back to nodes (a long call saved one argument per line spans
// several lines).

import "core:strconv"
import "core:strings"

Diag :: struct {
	line, col: int,    // 1-based, in the saved file
	msg:       string, // e.g. "Cannot assign value 'x' of type '[^]u16' to 'cstring16' ..."
}

// node_line_starts: the saved-file line each node starts on (1-based), plus
// one past the last line at [len(nodes)]. Node i covers lines
// [starts[i], starts[i+1]).
node_line_starts :: proc(app: ^App, allocator := context.temp_allocator) -> []int {
	n := len(app.doc.nodes)
	starts := make([]int, n + 1, allocator)
	line := 1
	for node, i in app.doc.nodes {
		starts[i] = line
		line += len(node_source_lines(node))
	}
	starts[n] = line
	return starts
}

// The node a saved-file line belongs to (-1 if none).
node_for_line :: proc(starts: []int, line: int) -> int {
	for i in 0 ..< len(starts) - 1 do if line >= starts[i] && line < starts[i + 1] do return i
	return -1
}

// parse_check_output reads `odin check` output and returns the problems
// reported for the file named `file_name` (just the base name, e.g.
// "main.odin"). Lines look like:
//   C:/.../main.odin(5:27) Error: Cannot assign value 'x' ...
//   C:/.../main.odin(7:1) Syntax Error: Expected an operand
// The message strings are allocated with `allocator`.
parse_check_output :: proc(output: string, file_name: string, allocator := context.allocator) -> []Diag {
	out := make([dynamic]Diag, 0, 4, allocator)
	for raw in strings.split_lines(output, context.temp_allocator) {
		line := strings.trim_right(raw, "\r ")
		paren := strings.index(line, ".odin(")
		if paren < 0 do continue
		path := line[:paren + len(".odin")]
		base := path
		if k := strings.last_index_any(path, "/\\"); k >= 0 do base = path[k + 1:]
		if !strings.equal_fold(base, file_name) do continue
		close := strings.index_byte(line[paren:], ')')
		if close < 0 do continue
		pos := line[paren + len(".odin("):paren + close]
		colon := strings.index_byte(pos, ':')
		if colon < 0 do continue
		ln, ok1 := strconv.parse_int(pos[:colon])
		col, _ := strconv.parse_int(pos[colon + 1:])
		if !ok1 do continue
		rest := strings.trim_space(line[paren + close + 1:])
		msg := rest
		for tag in ([]string{"Syntax Error:", "Error:", "Warning:"}) {
			if strings.has_prefix(rest, tag) {
				msg = strings.trim_space(rest[len(tag):])
				if tag == "Syntax Error:" do msg = strings.concatenate({"Syntax: ", msg}, context.temp_allocator)
				if tag == "Warning:" do msg = strings.concatenate({"Warning: ", msg}, context.temp_allocator)
				break
			}
		}
		append(&out, Diag{ln, col, strings.clone(msg, allocator)})
	}
	return out[:]
}

free_diags :: proc(ds: []Diag, allocator := context.allocator) {
	for d in ds do delete(d.msg, allocator)
	delete(ds, allocator)
}

package model

// Serialize the document to Odin source code.

import "core:strings"

// fixup_line applies corrections to make unfilled constructs compile.
// - Normalize empty params: ( ) or (  ) -> ()
// - Drop -> before { when only whitespace in between
// - Trim trailing spaces
fixup_line :: proc(line: string, allocator := context.allocator) -> string {
	// Use a string builder for clean memory management
	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)
	
	// Start with the input line
	working := line
	// A comment line is text: only its trailing whitespace goes.
	if strings.has_prefix(strings.trim_left_space(working), "//") do return strings.clone(strings.trim_right_space(working), allocator)

	// Step 1: Normalize empty params "(  )" -> "()"
	if strings.contains(working, "(  )") {
		strings.builder_reset(&b)
		for i := 0; i < len(working); {
			if i + 3 < len(working) && working[i:i+4] == "(  )" {
				strings.write_string(&b, "()")
				i += 4
			} else {
				strings.write_byte(&b, working[i])
				i += 1
			}
		}
		working = strings.to_string(b)
	}
	
	// Step 2: Normalize "( )" -> "()"
	if strings.contains(working, "( )") {
		strings.builder_reset(&b)
		for i := 0; i < len(working); {
			if i + 2 < len(working) && working[i:i+3] == "( )" {
				strings.write_string(&b, "()")
				i += 3
			} else {
				strings.write_byte(&b, working[i])
				i += 1
			}
		}
		working = strings.to_string(b)
	}
	
	// Step 3: Drop "-> " before "{" when only whitespace in between
	if idx := strings.index(working, ") -> "); idx >= 0 {
		after := working[idx + 5:]  // after ") -> "
		if brace_idx := strings.index(after, "{"); brace_idx >= 0 {
			between := after[:brace_idx]
			if strings.trim_space(between) == "" {
				// Rebuild without the "-> " and trim extra spaces
				strings.builder_reset(&b)
				strings.write_string(&b, working[:idx + 1]) // up to and including ")"
				strings.write_string(&b, " ")  // single space
				strings.write_string(&b, strings.trim_left_space(after))  // rest without leading spaces
				working = strings.to_string(b)
			}
		}
	}
	
	// Step 4: Trim trailing whitespace
	working = strings.trim_right_space(working)
	
	// Clone the final result
	return strings.clone(working, allocator)
}

// doc_to_source converts the app's document into full Odin source text.
// Each node becomes one line, or several when a long call is broken one
// argument per line (see format.odin); lines are joined with "\n".
// Caller owns the returned string.
doc_to_source :: proc(app: ^App, allocator := context.allocator) -> string {
	return nodes_to_source(app, 0, len(app.doc.nodes) - 1, allocator)
}

// file_text: exactly what a file save writes (src/app/save.odin write_doc) -
// the formatted document (format_doc runs first), without the editor-only "●"
// statement lines (save_source), ending in "\n" unless the opened file had no
// final newline. Caller owns the result.
file_text :: proc(app: ^App, allocator := context.allocator) -> string {
	format_doc(app)
	body := save_source(app, context.temp_allocator)
	if app.doc.no_final_newline || len(body) == 0 do return strings.clone(body, allocator)
	return strings.concatenate({body, "\n"}, allocator)
}

// save_source: what a file save writes - doc_to_source minus the editor-only
// "●" statement lines that sit next to real statements in their block. A "●"
// that is a block's only content stays (as the blank line inside `{ }`), so
// empty bodies keep round-tripping. The live document is not changed.
save_source :: proc(app: ^App, allocator := context.allocator) -> string {
	opens :: proc(app: ^App, i: int) -> bool {
		if i < 0 do return false
		n := app.doc.nodes[i]
		if is_comment_line(n) do return false
		s := strings.trim_space(node_text(n, context.temp_allocator))
		return strings.has_suffix(s, "{") || (strings.has_prefix(s, "case") && strings.has_suffix(s, ":"))
	}
	closes :: proc(app: ^App, i: int) -> bool {
		if i >= len(app.doc.nodes) do return true
		s := strings.trim_space(node_text(app.doc.nodes[i], context.temp_allocator))
		return strings.has_prefix(s, "}") || strings.has_prefix(s, "case")
	}
	b := strings.builder_make(allocator)
	first := true
	for n, i in app.doc.nodes {
		if is_body_slot_line(n) && !(opens(app, i - 1) && closes(app, i + 1)) do continue
		if !first do strings.write_string(&b, "\n")
		first = false
		strings.write_string(&b, nodes_to_source(app, i, i, context.temp_allocator))
	}
	return strings.to_string(b)
}

// nodes_to_source: the saved source of nodes [start, end] (inclusive), e.g. one
// statement or block for copying to the clipboard. Caller owns the result.
nodes_to_source :: proc(app: ^App, start, end: int, allocator := context.allocator) -> string {
	if len(app.doc.nodes) == 0 || start > end do return ""
	s := clamp(start, 0, len(app.doc.nodes) - 1)
	e := clamp(end, 0, len(app.doc.nodes) - 1)

	b := strings.builder_make(allocator)
	for i in s ..= e {
		// node_source_lines drops unfilled optional-arg dots and breaks long calls
		// one argument per line (format.odin).
		for line, li in node_source_lines(app.doc.nodes[i]) {
			if li > 0 do strings.write_string(&b, "\n")
			strings.write_string(&b, fixup_line(line, context.temp_allocator))
		}
		if i < e do strings.write_string(&b, "\n")
	}
	return strings.to_string(b)
}

// copy_selection_source: what "copy" puts on the clipboard - the highlighted
// statement / block (a whole proc when on its header), or the whole file when
// the cursor is on a green insertion dot. Temp-allocated.
copy_selection_source :: proc(app: ^App) -> string {
	if on_dot(app) || app.editor_line < 0 || app.editor_line >= len(app.doc.nodes) {
		return nodes_to_source(app, 0, len(app.doc.nodes) - 1, context.temp_allocator)
	}
	// The line itself, through the end of the block it opens (if any).
	s, e := app.editor_line, app.editor_line
	if brace_delta(app, s) > 0 {
		balance := 0
		for j in s ..< len(app.doc.nodes) {
			balance += brace_delta(app, j)
			e = j
			if balance <= 0 do break
		}
	}
	return nodes_to_source(app, s, e, context.temp_allocator)
}

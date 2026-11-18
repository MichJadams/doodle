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
// Each node becomes one line; lines are joined with "\n".
// Caller owns the returned string.
doc_to_source :: proc(app: ^App, allocator := context.allocator) -> string {
	if len(app.doc.nodes) == 0 do return ""
	
	b := strings.builder_make(allocator)
	for n, i in app.doc.nodes {
		// node_source_lines drops unfilled optional-arg dots and breaks long calls
		// one argument per line (format.odin).
		for line, li in node_source_lines(n) {
			if li > 0 do strings.write_string(&b, "\n")
			strings.write_string(&b, fixup_line(line, context.temp_allocator))
		}
		if i < len(app.doc.nodes) - 1 {
			strings.write_string(&b, "\n")
		}
	}
	return strings.to_string(b)
}

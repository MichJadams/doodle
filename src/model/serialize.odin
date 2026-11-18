package model

// Serialize the document to Odin source code.

import "core:strings"

// doc_to_source converts the app's document into full Odin source text.
// Each node becomes one line; lines are joined with "\n".
// Caller owns the returned string.
doc_to_source :: proc(app: ^App, allocator := context.allocator) -> string {
	if len(app.doc.nodes) == 0 do return ""
	
	b := strings.builder_make(allocator)
	for n, i in app.doc.nodes {
		line := node_text(n, context.temp_allocator)
		strings.write_string(&b, line)
		if i < len(app.doc.nodes) - 1 {
			strings.write_string(&b, "\n")
		}
	}
	return strings.to_string(b)
}

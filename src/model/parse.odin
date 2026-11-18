package model

// Parse existing Odin source files back into Doodle's document model.

import "core:os"
import "core:strings"
import "core:unicode/utf8"

// doc_from_source parses Odin source text into nodes, replacing app.doc.
// Parsing is line-based and pragmatic (not a full Odin parser):
//   - Each line becomes exactly one Node
//   - Recognized patterns have editable identifiers; the rest is fixed
//   - Exact round-trip: concatenating fields equals the original line
doc_from_source :: proc(app: ^App, src: string) {
	doc_reset(app)
	
	// Trim a single trailing newline from src
	text := src
	if len(text) > 0 && text[len(text)-1] == '\n' {
		text = text[:len(text)-1]
	}
	
	// Split on newline
	lines := strings.split_lines(text, context.temp_allocator)
	
	for line in lines {
		// Strip trailing carriage return
		stripped := line
		if len(stripped) > 0 && stripped[len(stripped)-1] == '\r' {
			stripped = stripped[:len(stripped)-1]
		}
		
		node := parse_line(stripped)
		append(&app.doc.nodes, node)
	}
}

// parse_line creates a Node from a single line of source.
// Recognizes:
//   - `package <name>` -> fixed "package " + editable "<name>"
//   - Non-indented `<ident> :: <rest>` -> editable "<ident>" + fixed " :: <rest>"
//   - Everything else -> one fixed field with the whole line
@(private = "file")
parse_line :: proc(line: string) -> Node {
	node: Node
	node.fields = make([dynamic]Field)
	
	// Check for package declaration: exactly "package <name>"
	if strings.has_prefix(line, "package ") {
		// Two fields: fixed "package " + editable name
		append(&node.fields, Field{
			text = strings.clone("package "),
			editable = false,
			slot = false,
			kind = "",
		})
		name := line[len("package "):]
		append(&node.fields, Field{
			text = strings.clone(name),
			editable = true,
			slot = false,
			kind = "",
		})
		return node
	}
	
	// Check for top-level declaration: non-indented "<ident> :: <rest>"
	// Must start with a non-whitespace character (not indented)
	if len(line) > 0 && !is_whitespace(rune(line[0])) {
		// Find " :: " pattern
		idx := strings.index(line, " :: ")
		if idx > 0 {
			// Extract identifier (everything before " :: ")
			ident := line[:idx]
			// Check that ident is a valid identifier (letters, digits, underscore)
			if is_valid_identifier(ident) {
				// Two fields: editable ident + fixed " :: <rest>"
				append(&node.fields, Field{
					text = strings.clone(ident),
					editable = true,
					slot = false,
					kind = "",
				})
				rest := line[idx:]
				append(&node.fields, Field{
					text = strings.clone(rest),
					editable = false,
					slot = false,
					kind = "",
				})
				return node
			}
		}
	}
	
	// Everything else: one fixed field with the whole line
	append(&node.fields, Field{
		text = strings.clone(line),
		editable = false,
		slot = false,
		kind = "",
	})
	return node
}

// is_whitespace checks if a rune is whitespace
@(private = "file")
is_whitespace :: proc(r: rune) -> bool {
	return r == ' ' || r == '\t' || r == '\n' || r == '\r'
}

// is_valid_identifier checks if a string is a valid Odin identifier
@(private = "file")
is_valid_identifier :: proc(s: string) -> bool {
	if len(s) == 0 do return false
	
	// First character must be letter or underscore
	r, size := utf8.decode_rune_in_string(s)
	if !is_letter(r) && r != '_' do return false
	
	// Rest can be letters, digits, or underscores
	offset := size
	for offset < len(s) {
		r, size = utf8.decode_rune_in_string(s[offset:])
		if !is_letter(r) && !is_digit(r) && r != '_' do return false
		offset += size
	}
	
	return true
}

// is_letter checks if a rune is a letter
@(private = "file")
is_letter :: proc(r: rune) -> bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
}

// is_digit checks if a rune is a digit
@(private = "file")
is_digit :: proc(r: rune) -> bool {
	return r >= '0' && r <= '9'
}

// load_file reads an Odin file and parses it into app.doc.
// Returns true on success, false on error (e.g., file not found).
load_file :: proc(app: ^App, path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return false
	
	doc_from_source(app, string(data))
	return true
}

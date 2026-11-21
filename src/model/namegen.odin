package model

// Name generator for inserted constructs: adjective_animal style with uniqueness.

import "core:strings"
import "core:fmt"

// Curated adjective list (20)
ADJECTIVES := [?]string{
	"brave", "calm", "clever", "swift", "quiet",
	"bright", "bold", "gentle", "lucky", "mighty",
	"nimble", "proud", "sly", "wise", "eager",
	"fuzzy", "jolly", "keen", "merry", "spry",
}

// Curated animal list (20)
ANIMALS := [?]string{
	"otter", "lynx", "finch", "heron", "bison",
	"gecko", "panda", "raven", "tapir", "koala",
	"moose", "quail", "viper", "wren", "yak",
	"zebra", "crane", "ferret", "hare", "ibis",
}

// Internal helper: pick adjective and animal using the counter.
pick_words :: proc(counter: int) -> (adj: string, animal: string) {
	adj_idx := counter % len(ADJECTIVES)
	animal_idx := (counter / len(ADJECTIVES)) % len(ANIMALS)
	return ADJECTIVES[adj_idx], ANIMALS[animal_idx]
}

// Check if a name is already used in the document as an editable field, or
// declared by another file of the package (a type or procedure there: the same
// name here would be a redeclaration, siblings.odin).
is_name_used :: proc(app: ^App, name: string) -> bool {
	for &node in app.doc.nodes {
		for &field in node.fields {
			if field.editable && field.text == name {
				return true
			}
		}
	}
	for t in app.sibling_types do if t.name == name do return true
	for p in app.sibling_procs do if p.name == name do return true
	return false
}

// Generate a unique snake_case identifier (brave_otter).
generate_ident :: proc(app: ^App) -> string {
	for {
		adj, animal := pick_words(app.name_counter)
		name := fmt.aprintf("%s_%s", adj, animal)
		app.name_counter += 1
		
		if !is_name_used(app, name) {
			return name
		}
		// If collision, counter already incremented; try next
		delete(name)
	}
}

// Generate a unique PascalCase type name (BraveOtter).
generate_type :: proc(app: ^App) -> string {
	for {
		adj, animal := pick_words(app.name_counter)
		// Capitalize first letter of each word
		name := fmt.aprintf("%c%s%c%s", 
			adj[0] - 32, adj[1:], 
			animal[0] - 32, animal[1:])
		app.name_counter += 1
		
		if !is_name_used(app, name) {
			return name
		}
		delete(name)
	}
}

// Generate a unique UPPER_SNAKE constant name (BRAVE_OTTER).
generate_const :: proc(app: ^App) -> string {
	for {
		adj, animal := pick_words(app.name_counter)
		// Convert to uppercase
		adj_upper := strings.to_upper(adj, context.temp_allocator)
		animal_upper := strings.to_upper(animal, context.temp_allocator)
		name := fmt.aprintf("%s_%s", adj_upper, animal_upper)
		app.name_counter += 1
		
		if !is_name_used(app, name) {
			return name
		}
		delete(name)
	}
}

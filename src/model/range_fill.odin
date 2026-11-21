package model

// "Range" value fill: `lo ..< hi` (up to hi) or `lo ..= hi` (through hi), both
// ends dots typed like the dot they replace. Used by case values
// (`case 0..<10:`, `case 'a'..='z':`) and for-in ranges.

import "core:strings"

RANGE_FILL :: "__val_range__" // call_name: "excl" (..<) / "incl" (..=)

// make_slot_range replaces the value dot at (ni, fi) with `● ..< ●` / `● ..= ●`.
make_slot_range :: proc(app: ^App, ni, fi: int, inclusive: bool) {
	fields := &app.doc.nodes[ni].fields
	if fi < 0 || fi >= len(fields) do return
	slot := fields[fi]
	hint, pkg := slot.hint, slot.hint_pkg
	if len(slot.text) > 0 do delete(slot.text)
	ordered_remove(fields, fi)
	inject_at(fields, fi,
		Field{"", false, true, "value", hint, pkg},
		Field{strings.clone(inclusive ? "..=" : "..<"), false, false, "", "", ""},
		Field{"", false, true, "value", hint, pkg},
	)
}

// A range operator field (`..<`, `..=`, possibly with spaces around it).
is_range_op :: proc(f: Field) -> bool {
	if f.slot || f.editable do return false
	t := strings.trim_space(f.text)
	return t == "..<" || t == "..="
}

// Can a range of this category be written (and fill a case value / loop range)?
range_fits :: proc(exp: Resolved_Type) -> bool {
	#partial switch exp.cat {
	case .Unknown, .Any, .Integer, .Rune, .Float, .Enum: return true
	}
	return false
}

// range_entry: the "Range" group (its leaves grayed when `exp` can't be a range).
range_entry :: proc(exp: Resolved_Type) -> Entry {
	fits := range_fits(exp)
	return Entry{label = "Range", dim = !fits, children = make_slice(
		Entry{label = "a ..< b  (up to b)", fill = RANGE_FILL, call_name = strings.clone("excl"), dim = !fits},
		Entry{label = "a ..= b  (through b)", fill = RANGE_FILL, call_name = strings.clone("incl"), dim = !fits},
	)}
}

// insert_range_entry adds "Range" to the open value menu, after "Number".
insert_range_entry :: proc(app: ^App, exp: Resolved_Type) {
	old := app.slot_menu
	for e in old do if e.label == "Range" do return
	at := len(old)
	for e, i in old do if e.label == "Number" { at = i + 1; break }
	out := make([]Entry, len(old) + 1)
	copy(out[:at], old[:at])
	out[at] = range_entry(exp)
	copy(out[at + 1:], old[at:])
	delete(old)
	app.slot_menu = out
}

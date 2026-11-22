package model

// Push-to-talk (LT+X): what the highlighted part takes, and how the words are read.
//
//   a name                 snake_case identifier ("brave otter" -> brave_otter)
//   a string / comment     free text (spaces kept)
//   a number               a number: digits as heard ("10", "3.5", "-2") or
//                          spoken ("ten", "twenty five", "three point five",
//                          "minus two", "one thousand two hundred") -> 10, 25, 3.5, -2, 1200.
//                          Any number literal: built from the menus (Value > Number)
//                          or loaded from a file (`y = 0`), and an empty value dot
//                          that can take a number (`y = ●` in a struct literal).
//
// (The app does the recording, src/app/main.odin; dictation_target says where
// it goes, dictate_number writes a number.)

import "core:strings"

Dictation_Mode :: enum u8 {
	None,       // the mic isn't available here
	Identifier, // a name
	Free_Text,  // a string's or comment's text
	Number,     // a number literal / a value dot that takes one
}

// dictation_target: the field push-to-talk writes into, and how.
dictation_target :: proc(app: ^App) -> (ni, fi: int, mode: Dictation_Mode) {
	if app.state != .Editor do return
	tni, tfi, ok := editor_target(app)
	if !ok do return
	f := app.doc.nodes[tni].fields[tfi]
	switch {
	case is_number_literal_field(f):
		return tni, tfi, .Number
	case f.slot && (f.kind == "value" || f.kind == RET_MORE_KIND) && dot_takes_number(app, f):
		return tni, tfi, .Number
	case f.editable && (f.kind == "string" || f.kind == COMMENT_KIND):
		return tni, tfi, .Free_Text
	case f.editable:
		return tni, tfi, .Identifier
	}
	return
}

// A number literal field: one built from the menus (editable "0") or loaded
// from a file (fixed text "10", "0x1F", "3.5", "1_000", "-2").
is_number_literal_field :: proc(f: Field) -> bool {
	if f.slot || f.kind != "" do return false
	return is_number_text(strings.trim_space(f.text))
}

is_number_text :: proc(t: string) -> bool {
	s := strings.trim_prefix(t, "-")
	if s == "" || s[0] < '0' || s[0] > '9' do return false
	if strings.has_prefix(s, "0x") || strings.has_prefix(s, "0b") || strings.has_prefix(s, "0o") {
		if len(s) == 2 do return false
		for c in transmute([]u8)s[2:] {
			ok := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == '_'
			if !ok do return false
		}
		return true
	}
	dots := 0
	for c, k in transmute([]u8)s {
		switch {
		case c >= '0' && c <= '9', c == '_':
		case c == '.':
			dots += 1
			if dots > 1 || k + 1 < len(s) && s[k + 1] == '.' do return false // `0..<n` isn't a number
		case (c == 'e' || c == 'E') && k > 0:
		case (c == '+' || c == '-') && k > 0 && (s[k - 1] == 'e' || s[k - 1] == 'E'):
		case: return false
		}
	}
	return true
}

// A value dot whose expected type takes a number (or isn't known).
@(private = "file")
dot_takes_number :: proc(app: ^App, f: Field) -> bool {
	if f.hint == "" do return true
	ctx := type_ctx_make(app)
	#partial switch slot_expected_type(&ctx, f).cat {
	case .Integer, .Float, .Unknown, .Any: return true
	}
	return false
}

// dictate_number writes a heard number (spoken_number's result) into field fi
// of line ni: a number literal gets the new value (and stays editable, so LT+A's
// keypad works on it too); a value dot becomes the number.
dictate_number :: proc(app: ^App, ni, fi: int, value: string) -> bool {
	if ni < 0 || ni >= len(app.doc.nodes) || fi < 0 || fi >= len(app.doc.nodes[ni].fields) do return false
	if !is_number_text(value) do return false
	f := &app.doc.nodes[ni].fields[fi]
	switch {
	case f.slot && (f.kind == "value" || f.kind == RET_MORE_KIND):
		was_more := f.kind == RET_MORE_KIND
		set_slot_literal(app, ni, fi, "__lit_num__") // an editable "0" in its place
		set_field_text(app, ni, fi, value)
		if was_more {
			fi := fi + more_dot_filled(app, ni, fi) // another return value: its ", " (result_list.odin)
			focus_field_index(app, ni, fi)
			return true
		}
	case is_number_literal_field(f^):
		f.editable = true
		set_field_text(app, ni, fi, value)
	case:
		return false
	}
	focus_field_index(app, ni, fi)
	return true
}

// ---- Spoken numbers ----

@(private = "file")
SMALL := [?]string{"zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"}
@(private = "file")
TENS := [?]string{"", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"}

@(private = "file")
small_value :: proc(w: string) -> (int, bool) {
	switch w {
	case "oh", "o", "nought", "naught": return 0, true
	case "fourty": return 40, true
	}
	for s, i in SMALL do if s == w do return i, true
	for s, i in TENS do if s != "" && s == w do return i * 10, true
	return 0, false
}

// spoken_number: what Whisper heard -> a number literal ("" / false when it
// isn't one). "10." -> 10, "Twenty-five" -> 25, "three point one four" -> 3.14,
// "minus 2" -> -2, "1,000" -> 1000, "one thousand two hundred" -> 1200.
spoken_number :: proc(heard: string, allocator := context.allocator) -> (string, bool) {
	raw := strings.trim_right(strings.trim_space(heard), ".!?, ")
	s := strings.to_lower(raw, context.temp_allocator)
	if s == "" do return "", false
	// Digits as heard ("10", "3.5", "-2", "1,000", "- 2", "0x1F" - case kept).
	compact, _ := strings.replace_all(raw, ",", "", context.temp_allocator)
	compact, _ = strings.replace_all(compact, " ", "", context.temp_allocator)
	if is_number_text(compact) do return strings.clone(compact, allocator), true

	words := strings.fields(strings.to_string(normalize_words(s)), context.temp_allocator)
	if len(words) == 0 do return "", false
	neg := false
	if words[0] == "minus" || words[0] == "negative" || words[0] == "-" {
		neg = true
		words = words[1:]
	}
	if len(words) == 0 do return "", false
	// The whole part, then an optional "point" and digits.
	point := len(words)
	for w, i in words do if w == "point" || w == "dot" { point = i; break }
	whole, ok := cardinal(words[:point])
	if !ok do return "", false
	b := strings.builder_make(context.temp_allocator)
	if neg do strings.write_byte(&b, '-')
	strings.write_int(&b, whole)
	if point < len(words) {
		frac := words[point + 1:]
		if len(frac) == 0 do return "", false
		strings.write_byte(&b, '.')
		for w in frac {
			if d, dok := digit_word(w); dok {
				strings.write_string(&b, d)
			} else {
				return "", false
			}
		}
	}
	return strings.clone(strings.to_string(b), allocator), true
}

// "twenty-five" -> "twenty five", digits stay ("2 point 5").
@(private = "file")
normalize_words :: proc(s: string) -> strings.Builder {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '.' :
			strings.write_byte(&b, c)
		case c == '-' && strings.builder_len(b) == 0:
			strings.write_byte(&b, '-') // a leading minus sign
		case:
			strings.write_byte(&b, ' ')
		}
	}
	return b
}

// A digit after "point": "five" / "5" / "25" (digits as heard).
@(private = "file")
digit_word :: proc(w: string) -> (string, bool) {
	if v, ok := small_value(w); ok && v < 10 do return SMALL_DIGITS[v], true
	for c in transmute([]u8)w do if c < '0' || c > '9' do return "", false
	return w, w != ""
}

@(private = "file")
SMALL_DIGITS := [10]string{"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}

// An English cardinal number: "one thousand two hundred and five" -> 1205.
// Digits are accepted too ("2 hundred"). Empty -> 0 (".5" is "point five").
@(private = "file")
cardinal :: proc(words: []string) -> (int, bool) {
	if len(words) == 0 do return 0, true
	total, group := 0, 0
	seen := false
	last := 0 // what came last in this group: 0 nothing, 1 a unit / teen / digits, 2 a tens word
	for w in words {
		switch w {
		case "and", "a":
			continue
		case "hundred":
			if last == 2 do return 0, false // "twenty hundred"
			group = (group == 0 ? 1 : group) * 100
			last = 0
		case "thousand", "million", "billion":
			mul := w == "thousand" ? 1_000 : (w == "million" ? 1_000_000 : 1_000_000_000)
			total += (group == 0 ? 1 : group) * mul
			group = 0
			last = 0
		case:
			if v, ok := small_value(w); ok {
				is_tens := v >= 20
				// "twenty five" is fine; "one two" / "twenty thirty" / "five twenty" aren't one number.
				if last == 1 || last == 2 && (is_tens || v == 0 || v >= 10) do return 0, false
				group += v
				last = is_tens ? 2 : 1
			} else {
				if last != 0 do return 0, false
				n := 0
				for c in transmute([]u8)w {
					if c < '0' || c > '9' do return 0, false
					n = n * 10 + int(c - '0')
				}
				group += n
				last = 1
			}
		}
		seen = true
	}
	return total + group, seen
}

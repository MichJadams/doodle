package model

// Edit word by word (Y / LT+A on a string's or a comment's text > "Edit word
// by word"): the cursor goes inside the text and steps over its words, with a
// yellow dot in every gap (and at both ends).
//
//   Left / Right    word, dot, word, dot ...
//   A / RT+X / Y    on a word: Change word (UPPER / Capitalized / lower,
//                   `backticks`, Replace with > a special, Delete)
//                   on a yellow dot: Insert > format verbs (%v %d %s ...),
//                   escapes (\n \t \" ...), symbols (` ( ) : ! ...)
//   RT+B / LT+B     delete the word
//   Talk (LT+X)     on a word: say its replacement; on a dot: say words to insert
//   B               done (back to the whole field)
//
// The words: runs of non-space text, with format verbs (%v, %08.3f, %%), escapes
// (\n, \x41) and {{ }} {:v} split out even when glued to a word ("hello\n" is
// "hello" and "\n"). Inserting a special adds a space on the side it needs, except
// escapes and closing punctuation (`. , ! ? : ; ) ]`), which stick to the word
// before, and `( [`, which stick to the word after.
//
// While word editing every other button is ignored (like Grab). The app draws
// the text word by word (src/app/editor_view.odin).

import "core:strings"

WORD_FILL :: "__word__" // call_name = "ins" / "rep" / "case" / "tick" / "del", call_pkg = the text / case

Word_Tok :: struct { a, b: int } // byte range in the field's text

// word_tokens: the words of s (see the top).
word_tokens :: proc(s: string, allocator := context.temp_allocator) -> []Word_Tok {
	out := make([dynamic]Word_Tok, 0, 8, allocator)
	i := 0
	for i < len(s) {
		if s[i] == ' ' || s[i] == '\t' { i += 1; continue }
		if n := word_special_len(s, i); n > 0 {
			append(&out, Word_Tok{i, i + n})
			i += n
			continue
		}
		j := i + 1
		for j < len(s) && s[j] != ' ' && s[j] != '\t' && word_special_len(s, j) == 0 do j += 1
		append(&out, Word_Tok{i, j})
		i = j
	}
	return out[:]
}

@(private = "file")
is_hex :: proc(c: u8) -> bool { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') }
@(private = "file")
is_letter :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }

// The length of the format verb / escape / brace token starting at s[i] (0: none).
@(private = "file")
word_special_len :: proc(s: string, i: int) -> int {
	c := s[i]
	rest := len(s) - i
	switch c {
	case '\\':
		if rest < 2 do return 0
		want := 0
		switch s[i + 1] {
		case 'x': want = 2
		case 'u': want = 4
		case 'U': want = 8
		}
		n := 2
		for n < 2 + want && i + n < len(s) && is_hex(s[i + n]) do n += 1
		return n
	case '%':
		if rest < 2 do return 0
		if s[i + 1] == '%' do return 2
		k := i + 1
		for k < len(s) && strings.index_byte("+-#0123456789.*[]", s[k]) >= 0 do k += 1
		if k < len(s) && is_letter(s[k]) do return k + 1 - i
		return 0
	case '{':
		if rest >= 2 && s[i + 1] == '{' do return 2
		if rest >= 3 && s[i + 1] == ':' {
			for k := i + 2; k < len(s); k += 1 {
				if s[k] == '}' do return k + 1 - i
				if s[k] == ' ' || s[k] == '{' do return 0
			}
		}
	case '}':
		if rest >= 2 && s[i + 1] == '}' do return 2
	}
	return 0
}

// ---- The mode ----

// word_edit_ok: field fi of line ni is text word editing works on.
word_edit_ok :: proc(app: ^App, ni, fi: int) -> bool {
	if ni < 0 || ni >= len(app.doc.nodes) || fi < 0 || fi >= len(app.doc.nodes[ni].fields) do return false
	f := app.doc.nodes[ni].fields[fi]
	return f.editable && !f.slot && (f.kind == "string" || f.kind == COMMENT_KIND)
}

// word_edit_start: into the text of field fi on line ni, on its first word.
word_edit_start :: proc(app: ^App, ni, fi: int) -> bool {
	if !word_edit_ok(app, ni, fi) do return false
	app.word_edit_active = true
	app.word_ni, app.word_fi = ni, fi
	app.word_nth = 0 // which text field of the line it is (the syncs can add fields before it)
	for k in 0 ..< fi do if word_edit_ok(app, ni, k) do app.word_nth += 1
	app.word_stop = len(word_tokens(app.doc.nodes[ni].fields[fi].text)) > 0 ? 1 : 0
	app.tree_sticky = false
	focus_field_index(app, ni, fi)
	return true
}

// word_edit_sync (end of update): find the field again (a capture dot or a
// result's parentheses may have gone in before it); gone -> word editing ends.
word_edit_sync :: proc(app: ^App) {
	if !app.word_edit_active do return
	if app.word_ni >= 0 && app.word_ni < len(app.doc.nodes) {
		nth := 0
		for _, k in app.doc.nodes[app.word_ni].fields do if word_edit_ok(app, app.word_ni, k) {
			if nth == app.word_nth { app.word_fi = k; return }
			nth += 1
		}
	}
	app.word_edit_active = false
}

word_edit_end :: proc(app: ^App) {
	if !app.word_edit_active do return
	app.word_edit_active = false
	if word_edit_ok(app, app.word_ni, app.word_fi) do focus_field_index(app, app.word_ni, app.word_fi)
}

// word_edit_text: the text being edited ("" when not word editing).
word_edit_text :: proc(app: ^App) -> string {
	if !app.word_edit_active || !word_edit_ok(app, app.word_ni, app.word_fi) do return ""
	return app.doc.nodes[app.word_ni].fields[app.word_fi].text
}

// word_edit_on: the cursor's word (word >= 0) or yellow dot (dot >= 0; dot k is
// before word k, dot len(words) after the last).
word_edit_on :: proc(app: ^App) -> (word, dot: int) {
	if app.word_stop % 2 == 1 do return app.word_stop / 2, -1
	return -1, app.word_stop / 2
}

// word_edit_update: input while word editing. True = used (all of it is).
word_edit_update :: proc(app: ^App, inp: Input, keys: Resolved) -> bool {
	if !app.word_edit_active do return false
	if !word_edit_ok(app, app.word_ni, app.word_fi) {
		app.word_edit_active = false // the document changed under it (a file was opened)
		return false
	}
	ntok := len(word_tokens(word_edit_text(app)))
	app.word_stop = clamp(app.word_stop, 0, 2 * ntok)
	word, _ := word_edit_on(app)
	trig := inp.lt_held || inp.rt_held
	switch {
	case inp.rt_held && inp.cancel, .Delete in keys.fired:
		if word >= 0 do word_delete(app, word)
	case inp.rt_held && inp.x, keys.rest.confirm, inp.y && !trig:
		word_menu_open(app)
	case keys.rest.cancel:
		word_edit_end(app)
	case keys.rest.left:
		app.word_stop = max(app.word_stop - 1, 0)
	case keys.rest.right:
		app.word_stop = min(app.word_stop + 1, 2 * ntok)
	}
	return true
}

// ---- Edits ----

@(private = "file")
word_set :: proc(app: ^App, t: string) {
	set_field_text(app, app.word_ni, app.word_fi, t)
}

// The stop of the word starting at byte `at` (else the nearest one before it).
@(private = "file")
word_focus_at :: proc(app: ^App, at: int) {
	toks := word_tokens(word_edit_text(app))
	app.word_stop = 0
	for t, k in toks do if t.a <= at do app.word_stop = 2 * k + 1
}

// word_delete removes word k and the space after it (or before it, at the end).
word_delete :: proc(app: ^App, k: int) {
	s := word_edit_text(app)
	toks := word_tokens(s)
	if k < 0 || k >= len(toks) do return
	a, b := toks[k].a, toks[k].b
	e := b
	for e < len(s) && (s[e] == ' ' || s[e] == '\t') do e += 1
	if e == b || e == len(s) {
		// Nothing after it to take (glued, or the last word): the space before it.
		for a > 0 && (s[a - 1] == ' ' || s[a - 1] == '\t') do a -= 1
		if e == len(s) do b = e
	} else {
		b = e
	}
	word_set(app, strings.concatenate({s[:a], s[b:]}, context.temp_allocator))
	n := len(toks) - 1
	app.word_stop = n == 0 ? 0 : 2 * min(k, n - 1) + 1
}

// word_replace puts `with` in place of word k.
word_replace :: proc(app: ^App, k: int, with: string) {
	s := word_edit_text(app)
	toks := word_tokens(s)
	if k < 0 || k >= len(toks) do return
	a := toks[k].a
	word_set(app, strings.concatenate({s[:a], with, s[toks[k].b:]}, context.temp_allocator))
	word_focus_at(app, a)
}

@(private = "file")
GLUE_LEFT := [?]string{".", ",", "!", "?", ":", ";", ")", "]"}
@(private = "file")
GLUE_RIGHT := [?]string{"(", "["}

// word_insert puts `t` at yellow dot k (spacing: see the top).
word_insert :: proc(app: ^App, k: int, t: string) {
	if t == "" do return
	s := word_edit_text(app)
	toks := word_tokens(s)
	k := clamp(k, 0, len(toks))
	left, right := strings.has_prefix(t, `\`), false
	for g in GLUE_LEFT do if t == g do left = true
	for g in GLUE_RIGHT do if t == g do right = true
	at, ins, start := 0, t, 0
	switch {
	case len(toks) == 0:
		at = len(s)
		if strings.trim_space(s) == "" do at = 0
		ins = t
	case left && k > 0:
		at = toks[k - 1].b
	case right && k < len(toks):
		at = toks[k].a
	case k > 0:
		at = toks[k - 1].b
		ins = strings.concatenate({" ", t}, context.temp_allocator)
		start = 1
	case:
		at = toks[0].a
		ins = strings.concatenate({t, " "}, context.temp_allocator)
	}
	word_set(app, strings.concatenate({s[:at], ins, s[at:]}, context.temp_allocator))
	word_focus_at(app, at + start)
}

// word_dictated (the app, after push-to-talk while word editing): on a word,
// it's replaced; on a dot, the words go in there.
word_dictated :: proc(app: ^App, heard: string) {
	if !app.word_edit_active || heard == "" do return
	word, dot := word_edit_on(app)
	if word >= 0 do word_replace(app, word, heard)
	else do word_insert(app, dot, heard)
}

// ---- Menus ----

@(private = "file")
wtool :: proc(label, op, arg: string) -> Entry {
	return Entry{label = strings.clone(label), owned_label = true, fill = WORD_FILL, call_name = strings.clone(op), call_pkg = strings.clone(arg)}
}

@(private = "file")
wgroup :: proc(label: string, children: []Entry) -> Entry {
	return Entry{label = strings.clone(label), owned_label = true, children = children}
}

@(private = "file")
Special :: struct { text, about: string }

@(private = "file") SP_GENERAL := [?]Special{
	{"%v", "the value in a default format"},
	{"%#v", "expanded %v, with newlines and indentation"},
	{"%w", "an Odin-syntax representation of the value"},
	{"%T", "an Odin-syntax representation of its type"},
	{"%%", "a literal percent sign"},
	{"{{", "a literal open brace"},
	{"}}", "a literal close brace"},
	{"{:v}", "same as %v (Python-like)"},
}
@(private = "file") SP_BOOL := [?]Special{{"%t", "the word true or false"}}
@(private = "file") SP_INT := [?]Special{
	{"%b", "base 2"},
	{"%c", "the character for the Unicode code point"},
	{"%r", "same as %c"},
	{"%o", "base 8"},
	{"%d", "base 10"},
	{"%i", "base 10"},
	{"%z", "base 12"},
	{"%x", "base 16, lower-case a-f"},
	{"%X", "base 16, upper-case A-F"},
	{"%U", "Unicode format: U+1234"},
	{"%m", "bytes in the best unit, e.g. 123.45mib"},
	{"%M", "bytes in the best unit, e.g. 123.45MiB"},
}
@(private = "file") SP_FLOAT := [?]Special{
	{"%e", "scientific, e.g. -1.23456e+78"},
	{"%E", "scientific, e.g. -1.23456E+78"},
	{"%f", "decimal point, no exponent: 123.456"},
	{"%F", "same as %f"},
	{"%g", "%f with default maximum precision"},
	{"%G", "same as %g"},
	{"%h", "hexadecimal (lower-case), 0h prefix"},
	{"%H", "hexadecimal (upper-case), 0H prefix"},
}
@(private = "file") SP_STRING := [?]Special{
	{"%s", "the uninterpreted bytes"},
	{"%q", "double-quoted, escaped with Odin syntax"},
	{"%x", "base 16, lower-case, two per byte"},
	{"%X", "base 16, upper-case, two per byte"},
}
@(private = "file") SP_SLICE := [?]Special{{"%p", "address of the 0th element, base 16, 0x"}}
@(private = "file") SP_POINTER := [?]Special{
	{"%p", "base 16 (upper-case), leading 0x"},
	{"%b", "as an integer, base 2"},
	{"%d", "as an integer, base 10"},
	{"%o", "as an integer, base 8"},
	{"%z", "as an integer, base 12"},
	{"%x", "as an integer, base 16 lower-case"},
	{"%X", "as an integer, base 16 upper-case"},
}
@(private = "file") SP_ENUM := [?]Special{
	{"%s", "the name of the enum field"},
	{"%i", "as a number"},
	{"%d", "as a number"},
	{"%f", "as a number"},
}
@(private = "file") SP_ESCAPE := [?]Special{
	{`\n`, "new line"},
	{`\t`, "tab"},
	{`\r`, "carriage return"},
	{`\"`, "double quote"},
	{`\\`, "backslash"},
	{`\e`, "escape (terminal colors)"},
	{`\0`, "zero byte"},
}
@(private = "file") SP_SYMBOL := [?]string{
	"`", "'", "(", ")", "[", "]", "{", "}", "<", ">", ":", ";", ",", ".", "!", "?",
	"-", "_", "=", "+", "*", "/", "&", "|", "#", "@", "$", "^", "~", "%",
}

// The specials for the text being edited: a raw `...` string has no escapes and
// can't hold a backtick; a comment gets the symbols only.
@(private = "file")
special_groups :: proc(app: ^App, op: string) -> []Entry {
	ni, fi := app.word_ni, app.word_fi
	comment := app.doc.nodes[ni].fields[fi].kind == COMMENT_KIND
	raw := !comment && fi > 0 && strings.has_suffix(app.doc.nodes[ni].fields[fi - 1].text, "`")
	out := make([dynamic]Entry, 0, 12)
	add :: proc(out: ^[dynamic]Entry, label, op: string, sp: []Special) {
		es := make([]Entry, len(sp))
		for s, i in sp do es[i] = wtool(strings.concatenate({s.text, "   ", s.about}, context.temp_allocator), op, s.text)
		append(out, wgroup(label, es))
	}
	if !comment {
		add(&out, "General", op, SP_GENERAL[:])
		add(&out, "Boolean", op, SP_BOOL[:])
		add(&out, "Integer", op, SP_INT[:])
		add(&out, "Float / complex", op, SP_FLOAT[:])
		add(&out, "String / bytes", op, SP_STRING[:])
		add(&out, "Slice / array", op, SP_SLICE[:])
		add(&out, "Pointer", op, SP_POINTER[:])
		add(&out, "Enum", op, SP_ENUM[:])
		if !raw do add(&out, "Escapes", op, SP_ESCAPE[:])
	}
	syms := make([dynamic]Entry, 0, len(SP_SYMBOL))
	for s in SP_SYMBOL {
		if raw && s == "`" do continue
		append(&syms, wtool(s, op, s))
	}
	append(&out, wgroup("Symbols", syms[:]))
	return out[:]
}

// word_menu_open: on a word, Change word; on a yellow dot, Insert.
word_menu_open :: proc(app: ^App) {
	word, _ := word_edit_on(app)
	menu: []Entry
	title := "Insert"
	if word >= 0 {
		title = "Change word"
		ni, fi := app.word_ni, app.word_fi
		raw := app.doc.nodes[ni].fields[fi].kind != COMMENT_KIND && fi > 0 && strings.has_suffix(app.doc.nodes[ni].fields[fi - 1].text, "`")
		items := make([dynamic]Entry, 0, 6)
		append(&items, wtool("UPPER", "case", "upper"), wtool("Capitalized", "case", "cap"), wtool("lower", "case", "lower"))
		if !raw do append(&items, wtool("`backticks`", "tick", ""))
		append(&items, wgroup("Replace with", special_groups(app, "rep")))
		append(&items, wtool("Delete", "del", ""))
		menu = items[:]
	} else {
		menu = special_groups(app, "ins")
	}
	if app.slot_menu != nil do free_entries(app.slot_menu)
	app.slot_menu = menu
	app.slot_ni, app.slot_fi = app.word_ni, app.word_fi
	clear_nav(app)
	app.return_state = .Editor
	app.state = .Radial
	v := MenuView{title = title, entries = make([]Entry, len(menu))}
	copy(v.entries, menu)
	push_view(app, v)
}

// word_menu_push (menu_select): a group of the word menus opens in its own
// order (no alphabetical grid for the long ones).
word_menu_push :: proc(app: ^App, e: Entry) {
	v := MenuView{title = e.label, entries = make([]Entry, len(e.children))}
	copy(v.entries, e.children)
	push_view(app, v)
}

// word_tool (menu_select): do the picked item, close the menu, stay word editing.
word_tool :: proc(app: ^App, e: Entry) {
	clear_nav(app)
	app.state = .Editor
	if app.word_edit_active && word_edit_ok(app, app.word_ni, app.word_fi) {
		word, dot := word_edit_on(app)
		toks := word_tokens(word_edit_text(app))
		w := word >= 0 && word < len(toks) ? word_edit_text(app)[toks[word].a:toks[word].b] : ""
		switch e.call_name {
		case "ins": word_insert(app, dot, e.call_pkg)
		case "rep": if word >= 0 do word_replace(app, word, e.call_pkg)
		case "del": if word >= 0 do word_delete(app, word)
		case "tick": if word >= 0 do word_replace(app, word, strings.concatenate({"`", w, "`"}, context.temp_allocator))
		case "case":
			if word >= 0 {
				nw := w
				switch e.call_pkg {
				case "upper": nw = strings.to_upper(w, context.temp_allocator)
				case "lower": nw = strings.to_lower(w, context.temp_allocator)
				case "cap":
					low := strings.to_lower(w, context.temp_allocator)
					nw = strings.concatenate({strings.to_upper(low[:1], context.temp_allocator), low[1:]}, context.temp_allocator)
				}
				word_replace(app, word, nw)
			}
		}
		focus_field_index(app, app.word_ni, app.word_fi)
	}
	if app.slot_menu != nil { free_entries(app.slot_menu); app.slot_menu = nil }
}

// word_edit_hint: the buttons, for the title bar.
word_edit_hint :: proc(app: ^App) -> string {
	if !app.word_edit_active do return ""
	word, _ := word_edit_on(app)
	if word >= 0 do return "A change   RT+B delete   B done"
	return "A insert   LT+X say words   B done"
}

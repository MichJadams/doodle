package model

// LT+A on a name, a string's text or a comment's text: text tools for what
// push-to-talk dictation can't produce (src/app/main.odin dictates lowercase
// snake_case names, and strings / comments as spaced words):
//
//   name     Case > snake_case / UPPER_SNAKE / Ada_Case / camelCase / PascalCase
//            ("whiteness" -> WHITENESS)
//   string   Case > ... the same, and Joined ("handmade hero window class"
//            -> HandmadeHeroWindowClass with PascalCase; "wm size" -> WM_SIZE)
//            Escape > \n \t \r \0 \\ \"   (appended: WM_SIZE\n)
//   comment  Word case > <word> > UPPER / Capitalized / lower   (dword -> DWORD)
//            Backticks > <first word> > <first .. last word>    (`static DWORD Operation`)
//
// Every tool goes through set_field_text, then the menu closes and the cursor
// stays on the field (B closes it without a change).

import "core:strings"

TXT_FILL :: "__txt__" // call_name = the tool ("case", "esc", "wcase:<i>", "tick:<i>:<j>"), call_pkg = its argument

Case_Style :: enum { Snake, Upper_Snake, Ada_Case, Camel, Pascal, Joined }

@(private = "file")
CASE_LABELS := [Case_Style]string {
	.Snake       = "snake_case",
	.Upper_Snake = "UPPER_SNAKE",
	.Ada_Case    = "Ada_Case",
	.Camel       = "camelCase",
	.Pascal      = "PascalCase",
	.Joined      = "Joined",
}

@(private = "file")
ESCAPES := [?]string{`\n`, `\t`, `\r`, `\0`, `\\`, `\"`}

@(private = "file")
is_lower :: proc(c: u8) -> bool { return c >= 'a' && c <= 'z' }
@(private = "file")
is_upper :: proc(c: u8) -> bool { return c >= 'A' && c <= 'Z' }

// The words of s: split at spaces, '_', '-', and lower -> Upper boundaries.
case_words :: proc(s: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, 8, allocator)
	start := -1
	for i in 0 ..< len(s) {
		c := s[i]
		if c == ' ' || c == '_' || c == '-' || c == '\t' {
			if start >= 0 do append(&out, s[start:i])
			start = -1
			continue
		}
		if start >= 0 && is_upper(c) && is_lower(s[i - 1]) {
			append(&out, s[start:i])
			start = i
			continue
		}
		if start < 0 do start = i
	}
	if start >= 0 do append(&out, s[start:])
	return out[:]
}

@(private = "file")
capitalized :: proc(w: string, allocator := context.temp_allocator) -> string {
	if w == "" do return ""
	low := strings.to_lower(w, context.temp_allocator)
	head := strings.to_upper(low[:1], context.temp_allocator)
	return strings.concatenate({head, low[1:]}, allocator)
}

// recase: s in the given style ("handmade hero" -> HandmadeHero with .Pascal).
recase :: proc(s: string, style: Case_Style, allocator := context.allocator) -> string {
	words := case_words(s)
	parts := make([]string, len(words), context.temp_allocator)
	sep := ""
	for w, i in words {
		switch style {
		case .Snake:       parts[i] = strings.to_lower(w, context.temp_allocator); sep = "_"
		case .Upper_Snake: parts[i] = strings.to_upper(w, context.temp_allocator); sep = "_"
		case .Ada_Case:    parts[i] = capitalized(w); sep = "_"
		case .Camel:       parts[i] = i == 0 ? strings.to_lower(w, context.temp_allocator) : capitalized(w)
		case .Pascal:      parts[i] = capitalized(w)
		case .Joined:      parts[i] = w
		}
	}
	return strings.join(parts, sep, allocator)
}

// The words of a comment (split at spaces only, punctuation kept).
@(private = "file")
comment_words :: proc(s: string) -> []string {
	return strings.fields(s, context.temp_allocator)
}

// A menu label per word, unique ("the", "the (2)").
@(private = "file")
word_labels :: proc(words: []string) -> []string {
	out := make([]string, len(words), context.temp_allocator)
	for w, i in words {
		n := 1
		for k in 0 ..< i do if words[k] == w do n += 1
		out[i] = n == 1 ? w : strings.concatenate({w, " (", itoa(n), ")"}, context.temp_allocator)
	}
	return out
}

@(private = "file")
itoa :: proc(n: int) -> string {
	if n == 0 do return "0"
	buf: [20]u8
	i := len(buf)
	v := n
	for v > 0 { i -= 1; buf[i] = u8('0' + v % 10); v /= 10 }
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

@(private = "file")
tool :: proc(label, op, arg: string) -> Entry {
	return Entry{label = strings.clone(label), owned_label = true, fill = TXT_FILL, call_name = strings.clone(op), call_pkg = arg == "" ? "" : strings.clone(arg)}
}

@(private = "file")
group :: proc(label: string, children: []Entry) -> Entry {
	return Entry{label = strings.clone(label), owned_label = true, children = children}
}

@(private = "file")
case_entries :: proc(with_joined: bool) -> []Entry {
	out := make([dynamic]Entry, 0, 6)
	for style in Case_Style {
		if style == .Joined && !with_joined do continue
		append(&out, tool(CASE_LABELS[style], "case", CASE_LABELS[style]))
	}
	return out[:]
}

// text_tools_menu: the LT+A menu for field fi of line ni (nil when it has none).
text_tools_menu :: proc(app: ^App, ni, fi: int) -> []Entry {
	f := app.doc.nodes[ni].fields[fi]
	if f.slot || !f.editable do return nil
	switch f.kind {
	case "string":
		esc := make([]Entry, len(ESCAPES))
		for e, i in ESCAPES do esc[i] = tool(e, "esc", e)
		return make_slice(group("Case", case_entries(true)), group("Escape", esc))
	case COMMENT_KIND:
		words := comment_words(f.text)
		if len(words) == 0 do return nil
		labels := word_labels(words)
		wcase := make([]Entry, len(words))
		ticks := make([]Entry, len(words))
		for w, i in words {
			op := strings.concatenate({"wcase:", itoa(i)}, context.temp_allocator)
			wcase[i] = group(labels[i], make_slice(tool("UPPER", op, "upper"), tool("Capitalized", op, "cap"), tool("lower", op, "lower")))
			ends := make([]Entry, min(len(words) - i, 6))
			for j in i ..< i + len(ends) {
				phrase := strings.join(words[i:j + 1], " ", context.temp_allocator)
				ends[j - i] = tool(phrase, strings.concatenate({"tick:", itoa(i), ":", itoa(j)}, context.temp_allocator), "")
			}
			ticks[i] = group(labels[i], ends)
		}
		return make_slice(group("Word case", wcase), group("Backticks", ticks))
	case "":
		if is_number_field(f) do return nil
		return make_slice(group("Case", case_entries(false)))
	}
	return nil
}

// open_text_tools (model.odin edit_selected, LT+A): false when the field has none.
open_text_tools :: proc(app: ^App, ni, fi: int) -> bool {
	menu := text_tools_menu(app, ni, fi)
	if menu == nil do return false
	if app.slot_menu != nil do free_entries(app.slot_menu)
	app.slot_menu = menu
	app.slot_ni, app.slot_fi = ni, fi
	clear_nav(app)
	app.return_state = .Editor
	app.state = .Radial
	v := MenuView{title = "Text", entries = make([]Entry, len(menu))}
	copy(v.entries, menu)
	push_view(app, v)
	return true
}

// The field text after applying tool `op` / `arg` (returns t when it doesn't apply).
text_tool_apply :: proc(t, op, arg: string, allocator := context.temp_allocator) -> string {
	switch {
	case op == "case":
		for style in Case_Style do if CASE_LABELS[style] == arg do return recase(t, style, allocator)
	case op == "esc":
		return strings.concatenate({t, arg}, allocator)
	case strings.has_prefix(op, "wcase:"):
		i := atoi(op[len("wcase:"):])
		words := comment_words(t)
		if i < 0 || i >= len(words) do return t
		w := words[i]
		nw := w
		switch arg {
		case "upper": nw = strings.to_upper(w, context.temp_allocator)
		case "lower": nw = strings.to_lower(w, context.temp_allocator)
		case "cap":   nw = capitalized(w)
		}
		return replace_words(t, i, i, nw, allocator)
	case strings.has_prefix(op, "tick:"):
		rest := op[len("tick:"):]
		colon := strings.index_byte(rest, ':')
		if colon < 0 do return t
		i, j := atoi(rest[:colon]), atoi(rest[colon + 1:])
		words := comment_words(t)
		if i < 0 || j < i || j >= len(words) do return t
		phrase := strings.join(words[i:j + 1], " ", context.temp_allocator)
		return replace_words(t, i, j, strings.concatenate({"`", phrase, "`"}, context.temp_allocator), allocator)
	}
	return t
}

@(private = "file")
atoi :: proc(s: string) -> int {
	if s == "" do return -1
	n := 0
	for c in transmute([]u8)s {
		if c < '0' || c > '9' do return -1
		n = n * 10 + int(c - '0')
	}
	return n
}

// t with its words i..j (space-separated) replaced by `with`; the spacing elsewhere kept.
@(private = "file")
replace_words :: proc(t: string, i, j: int, with: string, allocator := context.temp_allocator) -> string {
	k, wi := 0, 0
	a, b := -1, -1
	for k < len(t) {
		for k < len(t) && (t[k] == ' ' || t[k] == '\t') do k += 1
		if k >= len(t) do break
		s := k
		for k < len(t) && t[k] != ' ' && t[k] != '\t' do k += 1
		if wi == i do a = s
		if wi == j { b = k; break }
		wi += 1
	}
	if a < 0 || b < 0 do return strings.clone(t, allocator)
	return strings.concatenate({t[:a], with, t[b:]}, allocator)
}

// text_tool (model.odin menu_select): apply the picked tool, close the menu.
text_tool :: proc(app: ^App, e: Entry) {
	ni, fi := app.slot_ni, app.slot_fi
	ok := ni >= 0 && ni < len(app.doc.nodes) && fi >= 0 && fi < len(app.doc.nodes[ni].fields) && app.doc.nodes[ni].fields[fi].editable
	nt, changed := "", false
	if ok {
		t := app.doc.nodes[ni].fields[fi].text
		nt = text_tool_apply(t, e.call_name, e.call_pkg)
		changed = nt != t
	}
	clear_nav(app)
	app.state = .Editor
	if app.slot_menu != nil { free_entries(app.slot_menu); app.slot_menu = nil }
	if ok do focus_field_index(app, ni, fi)
	// A declaration's new name: asks whether its uses follow (rename.odin).
	if changed do rename_field(app, ni, fi, nt)
}

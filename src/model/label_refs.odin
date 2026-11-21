package model

// Labels of loops and labeled blocks (loops.odin):
//   - unique per procedure (Odin: "Duplicate label"), siblings included;
//   - the `break outer` / `continue outer` naming one follow a rename (LT+A);
//   - removing a label rewrites them to a bare `break` / `continue`, and is
//     refused (dimmed) when that would change what they jump out of (a loop or
//     switch in between, or a labeled block, which a bare break can't leave).

import "core:strings"

// proc_has_label: is `name` a label anywhere in the procedure around line ni (line ni itself aside)?
proc_has_label :: proc(app: ^App, ni: int, name: string) -> bool {
	nn := len(app.doc.nodes)
	stack := make([dynamic]int, 0, 16, context.temp_allocator)
	for i in 0 ..< min(ni, nn) {
		for c in line_brace_seq(node_text(app.doc.nodes[i], context.temp_allocator)) {
			if c == '{' do append(&stack, i)
			else if len(stack) > 0 do pop(&stack)
		}
	}
	start := -1
	for k := len(stack) - 1; k >= 0; k -= 1 {
		t := node_text(app.doc.nodes[stack[k]], context.temp_allocator)
		if strings.contains(t, "proc(") || strings.contains(t, "proc \"") || strings.contains(t, ":: proc") { start = stack[k]; break }
	}
	if start < 0 do start = len(stack) > 0 ? stack[0] : max(ni, 0)
	depth := 0
	for j in start ..< nn {
		if j != ni {
			lbl, _ := split_label(strings.trim_space(strip_comment(node_text(app.doc.nodes[j], context.temp_allocator))))
			if lbl == name do return true
			for f in app.doc.nodes[j].fields do if f.kind == LABEL_KIND && !f.slot && f.text == name do return true
		}
		for c in line_brace_seq(node_text(app.doc.nodes[j], context.temp_allocator)) {
			depth += c == '{' ? 1 : -1
		}
		if j > start && depth <= 0 do break
		if j == start && depth <= 0 && j >= ni do break
	}
	return false
}

// The label field after a break / continue keyword at fs[k], or -1.
jump_label_field :: proc(fs: []Field, k: int) -> int {
	for m in k + 1 ..< len(fs) {
		f := fs[m]
		if f.slot do return -1
		if strings.trim_space(f.text) == "" do continue
		return m
	}
	return -1
}

// label_jump_refs: the break / continue inside the block line ni opens that
// name `name`: (line, keyword field) pairs.
label_jump_refs :: proc(app: ^App, ni: int, name: string) -> [][2]int {
	out := make([dynamic][2]int, 0, 4, context.temp_allocator)
	if name == "" || ni < 0 || ni >= len(app.doc.nodes) do return out[:]
	end := loop_block_end(app, ni)
	for j in ni + 1 ..= min(end, len(app.doc.nodes) - 1) {
		fs := app.doc.nodes[j].fields[:]
		for f, k in fs {
			if !is_jump_kw(f) do continue
			if m := jump_label_field(fs, k); m >= 0 && strings.trim_space(fs[m].text) == name do append(&out, [2]int{j, k})
		}
	}
	return out[:]
}

// The header text of line i (trimmed, comment and label stripped).
@(private = "file")
header_rest :: proc(app: ^App, i: int) -> string {
	_, rest := split_label(strings.trim_space(strip_comment(node_text(app.doc.nodes[i], context.temp_allocator))))
	return rest
}

// label_removal_blocked: removing the label of the loop / labeled block at
// line ni would leave a jump naming it that can't become a bare one.
label_removal_blocked :: proc(app: ^App, ni: int, name: string) -> bool {
	refs := label_jump_refs(app, ni, name)
	if len(refs) == 0 do return false
	if _, is_block := labeled_block(app.doc.nodes[ni]); is_block do return true // a bare break can't leave a block
	for r in refs {
		// The blocks opened between the header and the jump, still open at it.
		stack := make([dynamic]int, 0, 8, context.temp_allocator)
		for i in ni + 1 ..< r[0] {
			for c in line_brace_seq(node_text(app.doc.nodes[i], context.temp_allocator)) {
				if c == '{' do append(&stack, i)
				else if len(stack) > 0 do pop(&stack)
			}
		}
		is_break := app.doc.nodes[r[0]].fields[r[1]].text == "break"
		for s in stack {
			rest := header_rest(app, s)
			if _, is_loop := loop_text(rest); is_loop do return true
			if is_break && (strings.has_prefix(rest, "switch") || strings.has_prefix(rest, "#partial switch")) do return true
		}
	}
	return false
}

// label_unname_jumps: `break outer` -> `break` for the jumps naming the label of line ni.
label_unname_jumps :: proc(app: ^App, ni: int, name: string) {
	refs := label_jump_refs(app, ni, name)
	for r in refs {
		fields := &app.doc.nodes[r[0]].fields
		m := jump_label_field(fields[:], r[1])
		if m < 0 do continue
		for i in r[1] + 1 ..= m do if len(fields[i].text) > 0 do delete(fields[i].text)
		remove_range(fields, r[1] + 1, m + 1)
	}
}

// label_rename_jumps (set_field_text): field fi of line ni, a loop's or a
// labeled block's label, is renamed from old to new: so are its jumps.
label_rename_jumps :: proc(app: ^App, ni, fi: int, old, new: string) {
	if ni < 0 || ni >= len(app.doc.nodes) || old == new || old == "" do return
	n := app.doc.nodes[ni]
	is_label := false
	if lb, ok := labeled_block(n); ok && lb == fi do is_label = true
	if h, ok := loop_hdr(n); ok && h.label == fi do is_label = true
	if !is_label do return
	for r in label_jump_refs(app, ni, old) {
		fields := &app.doc.nodes[r[0]].fields
		m := jump_label_field(fields[:], r[1])
		if m < 0 do continue
		delete(fields[m].text)
		fields[m].text = strings.clone(new)
	}
}

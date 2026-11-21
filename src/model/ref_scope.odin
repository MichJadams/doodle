package model

// Which declared names Reference offers for a dot on line `at`: file-scope
// names always; a procedure's locals only inside that procedure, declared
// before the dot, and not inside a block that has ended (an if body, another
// case clause, ...) - the same scope walk as var_types.odin's var_type_depth.
// (Loop variables and if / switch names: loops.odin, branch.odin.)

Ref_Scope :: struct {
	at:      int,
	start:   int,    // the body start of the procedure `at` is in, -1 when none
	visible: []bool, // per line start..at: a declaration there is in scope at `at`
	top:     []int,  // per line: the top-level construct it belongs to
	procs:   map[int]bool, // top-level construct start -> is a procedure
}

ref_scope_make :: proc(app: ^App, at: int) -> Ref_Scope {
	n := len(app.doc.nodes)
	s := Ref_Scope{at = at, start = -1}
	s.top = make([]int, n, context.temp_allocator)
	s.procs = make(map[int]bool, 16, context.temp_allocator)
	depth, cur := 0, 0
	for i in 0 ..< n {
		if depth <= 0 { cur = i; depth = 0 }
		s.top[i] = cur
		depth += brace_delta(app, i)
	}
	if at < 0 || at >= n do return s
	p := s.top[at]
	if !scope_is_proc(app, &s, p) || at <= p do return s
	s.start = p
	d := make([]int, at - p + 1, context.temp_allocator)
	for j in p ..< at do d[j - p + 1] = d[j - p] + brace_delta(app, j)
	s.visible = make([]bool, at - p + 1, context.temp_allocator)
	min_d := d[at - p]
	for j := at - 1; j > p; j -= 1 {
		min_d = min(min_d, d[j - p + 1])
		if j + 1 < at do min_d = min(min_d, d[j + 1 - p] - leading_closes(app, j + 1))
		s.visible[j - p] = d[j - p] <= min_d
		if d[j - p] == min_d && is_case_line(app, j) do min_d -= 1 // another case clause
	}
	return s
}

@(private = "file")
scope_is_proc :: proc(app: ^App, s: ^Ref_Scope, p: int) -> bool {
	if r, found := s.procs[p]; found do return r
	r := false
	if brace_delta(app, p) > 0 { // (a construct that opens no block isn't a procedure)
		st, _, ok := enclosing_proc(app, p)
		r = ok && st == p
	}
	s.procs[p] = r
	return r
}

// ref_scope_visible: is the name at field fi of line ni in scope at s.at?
ref_scope_visible :: proc(app: ^App, s: ^Ref_Scope, ni, fi: int) -> bool {
	if ni < 0 || ni >= len(s.top) do return true
	p := s.top[ni]
	if !scope_is_proc(app, s, p) do return true // file scope
	if ni == p {
		// A procedure's header: its name is file scope, its parameters only inside it.
		if s.start == p do return true
		for f, i in app.doc.nodes[ni].fields {
			if i >= fi do return true // before `proc`: the name
			if !f.slot && contains_word_proc(f.text) do return false
		}
		return true
	}
	if s.start != p do return false // a local of another procedure (or the dot isn't in one)
	if ni == s.at do return true
	if ni > s.at do return false // declared after the dot
	if s.visible[ni - p] do return true
	// An else if's setup names reach its chain's later branches (branch_name_hidden decides).
	if l, ok := br_line_at(app, ni); ok && l.kind == .Else_If && l.setup_a >= 0 && fi >= l.setup_a && fi < l.setup_b do return true
	return false
}

@(private = "file")
contains_word_proc :: proc(t: string) -> bool {
	for i := 0; i + 4 <= len(t); i += 1 {
		if t[i:i + 4] != "proc" do continue
		before := i == 0 || !is_ident_byte(t[i - 1])
		after := i + 4 == len(t) || !is_ident_byte(t[i + 4])
		if before && after do return true
	}
	return false
}

@(private = "file")
is_ident_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

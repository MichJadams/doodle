# 05 — Statements inside procedures: the statement menu

> Odin sources: src/model/body_dots.odin, model.odin (open_slot_menu, menu_select, menu_cancel, make_body_statement, make_multi_decl, make_call_*, make_jump_statement, make_error_statement, make_scope_statement, build_call_children), calls.odin, branch.odin, branch_parse.odin, loops.odin, loop_parse.odin, loop_unroll.odin, label_refs.odin, struct_lit.odin, field_access.odin, index_fill.odin, range_fill.odin, assign_ops.odin, capture.odin, result_list.odin, stmt_layout.odin, plus the parts of change.odin, ref_pick.odin, ref_scope.odin, format.odin, formatter.odin, serialize.odin, parse.odin, block_delete.odin, block_comment.odin, ctrl.odin, when_const.odin, heat.odin and builtin_procs.odin that serve statements. Baseline: Doodle @ 34a2ad1. Claims marked "probe" were checked by running throwaway tests against a copy of src/model outside the repo; they are not pinned by repo tests.

## Purpose

Inside a procedure body you never type a statement. The cursor stops on green
insertion dots between statements. **A** on one opens the *statement menu*, a
category menu of every statement form that makes sense *at that spot*. Picking a
form inserts the finished statement shape with generated names and empty "dots"
for whatever is still missing. The menu reacts to its surroundings. It offers
"Else if / Else" right after an `if` chain and "Case / Default case" inside a
`switch`. It grays out `break` outside loops, adds `break outer` for labels in
scope, and keeps `fallthrough` only where Odin allows it. The dots left behind are
typed from the code: call arguments from the callee's signature, a `case` value
from the switched value, a `return` value from the procedure's results. Each
statement is also a structure you edit with **Y**: add `else`, make a loop
`#reverse`, change `+=` to `-=`. Loading a file rebuilds the same structures, so
code typed elsewhere is just as editable. All of this exists so a whole program
can be written on a gamepad.

Legend used in the examples: `●` = a required empty dot (orange for values, blue
for types; an if/switch *setup* dot is a neutral orange, written `●setup`); `○` = an
optional dot that is never saved (green "add argument" / "add field" dots,
blue/orange "another result/value" dots); `◆` = the blue *variant* dot of a type
switch's `case`; `◉` = the pink capture dot; a line holding only `●` is an
editor-only *statement line* (its dot is green). `●int` means a dot whose
expected type (`hint`) is `int`: the UI draws that hint as small grey text right
after the dot (an `args` dot shows `..` + hint, e.g. `..any`; a dot with no hint
shows nothing) (src/app/main.odin `slot_hint_label`, `slot_dot_color`).

## Features

### 1. Insertion points inside bodies (green dots) and the "●" statement line

- **Trigger:** The D-pad moves the cursor Up/Down through lines. Green dots sit *between* lines inside code blocks. **A** on a green dot inside a function opens the statement menu. **A** on a top-level green dot opens the Add menu instead (doc 04).
- **Behavior:**
  - `body_points` marks a dot before line *i* when line *i* is inside a code block, *i* > 0, and neither line *i* nor line *i−1* is a `●` statement line. There is one dot above a run of blank lines and one on the first real line after it. There is no dot between two blank lines, none between a blank line and a closing `}`, and none inside a `/* */` comment.
  - A `{` opens a *code* block when its line contains `proc(`, `proc "` or `:: proc`, or when it sits inside code already, or when it closes a multi-line header (`) -> T {`). A data body (struct/enum/…) gets dots too, but they offer members (doc 04).
  - `}` lines are not cursor stops. Test `test_body_dots_are_cursor_stops` pins the walk from `main :: proc() {` downward: `dot9 9 dot10 10 dot11 11 dot12 dot13 13`.
  - **A** on a body dot (`open_body_insert`) inserts a *temporary* line at that spot: the computed indent plus a `body` slot. It then opens the statement menu for that slot.
    - **Picking** a statement keeps the line. `body_insert_done` then removes the extra `●` line that statements normally add after themselves, so exactly one statement (or one block) appears.
    - **B** (`body_insert_cancel`) removes the line and puts the cursor back on the dot. The document is byte-identical to before.
  - Indentation of the new statement (`body_indent_at`):
    1. Next to case labels (`branch_body_indent`): right after a `switch … {` line, the switch's own indent (a `case` goes there); right after or right before a `case` line, the case's indent + one unit.
    2. Otherwise, if the next line is neither blank nor starts with `}`, the next line's indent.
    3. Otherwise, if the previous line opens a block (net `{` > 0, or it ends with `{`, e.g. `} else {`, and is not a `//` comment): the previous line's indent + one unit.
    4. Otherwise the previous line's indent (or one unit at line 0).

    The unit is a tab, or 4 spaces if the document's first indented line starts with a space (`doc_indent_unit`). This only matters while editing: **every save runs `format_doc`, which re-indents every line with tabs** (one per brace depth, `case` labels one level less), so a 4-space file is saved tab-indented (verified at baseline with a probe: inserting `for {` into a 4-space file saves `\tx := 1\n\tfor {\n\n\t}`).
    - "Indent" is read as the leading whitespace of the line's *text* (`line_indent`). A line that starts with an empty dot (`● or_return`, `● or_else ●`) therefore reads as indent + one space, and a statement inserted next to it copies that extra space (probe: successive inserts gave `\t ● or_else ●`, `\t  using ●`). `format_doc` normalizes it on save.
  - Empty block holding blank line(s) (an empty function saved and reloaded): the new statement *replaces* the blank line. Cancel puts the blank line back (`body_insert_reused` / `body_insert_blank`).
  - **The `●` statement line.** Menu-built blocks (a new procedure, `if`, `for`, `case` …) contain a line holding only a `body` slot. **A** on it (or **Y**, which on any dot does what A does: change.odin `change_selected`) opens the same statement menu. Filling it adds a new `●` line after the new statement (or after its whole block), so you can keep adding. These lines are editor-only. On save they are dropped, except when one is the only content between an opener (a line ending in `{`, or a `case …:` label) and a closer (a line starting with `}` or `case`): then it is saved as an empty line, giving `{\n\n}` or `case 1:\n\n` (`save_source`).
    - **Not stable across a second save.** Reloaded, that empty line is a real blank line (no dot), and the next save's `format_doc` deletes blank lines just after `{` / just before `}`. Probe at baseline: loading `main :: proc() {\n\n}` and saving gives `main :: proc() {\n}`. The empty body still shows one green dot either way.
- **Rules & edge cases:** If the menu fails to open, the temporary line is removed at once. Else if / Else / Case / Default case chosen at a green dot free the temporary line themselves (`end_body_insert` + `free_line` in `add_branch_after_chain` / `add_case_at`); any other choice that didn't use it is cancelled by the `body_insert_cancel` at the end of `branch_fill`. Formatting never removes lines holding dots (a `●` line is not a "blank line" for `is_blank_line`).
  - **Exception to "exactly one statement":** Layout ▸ Multi-line comment inserted at a green dot leaves a stray `●` line after `*/` (its lines hold no braces, so `body_insert_done` looks for the trailing `●` right after `/*` and finds the comment text instead). Confirmed by probe; it is editor-only and dropped on save.
- **Rationale:** "exactly one new line, at the dot, indented like its neighbours; no extra empty statement line" (`test_declare_variable_between_statements`). Cancel must be a perfect no-op (`test_body_dot_inside_nested_block_and_cancel`).
- **Source:** body_dots.odin `body_points`, `body_indent_at`, `open_body_insert`, `body_insert_done`, `body_insert_cancel`, `remove_node`; model.odin `update` (A dispatch), `menu_cancel`; serialize.odin `save_source`; branch.odin `branch_body_indent`.

### 2. The statement menu: categories, order, context extras

- **Trigger:** **A** on a body dot, or **A**/**Y** on a `body` slot (`●` line). The menu title is **"Fill slot"** (`open_slot_menu`, slot kind `"body"`). A body slot has no hint, so the type gray-out pass (`apply_fit_dims`) never runs on this menu; its dims come only from the context passes below.
- **Behavior:** The base root menu, in this order:

  | # | Group | Leaves (in order) |
  |---|---|---|
  | 1 | **Declarations** | Variable (:=) · Variable (typed) · Variable (no value) · Multiple (:=) |
  | 2 | **Assignment** | Assignment · Implicit Context ▸ · `+=` `-=` `*=` `/=` `%=` `%%=` `\|=` `&=` `~=` `&~=` `<<=` `>>=` `&&=` `\|\|=` (displayed sorted, see below) |
  | 3 | **Calls** | Internal procedure ▸ · From import ▸ · Built-in ▸ |
  | 4 | **Branching** | If · If / Else · If with setup · Switch · Switch (conditions) · Partial switch · Type switch · When |
  | 5 | **Loops** | For (condition) · For (C-style) · For (infinite) · For ... in · For x, i in · For i in 0..<n · For i in 0..=n · For &x in · #reverse for · #unroll for · Labeled for |
  | 6 | **Jumps and cleanup** | Return · Break · Continue · Fallthrough · Defer (+ labeled Break/Continue entries, see §20) |
  | 7 | **Error handling** | or_return · or_else · if err != nil |
  | 8 | **Scope and blocks** | Block · Using · Labeled block |
  | 9 | **Compile-time** | #assert · When (appended by `ctrl_extend_body_menu`) |
  | 10 | **Layout** | Comment · Multi-line comment · Blank line (appended by `layout_extend_body_menu`) |

  Context passes run after the base menu, in this order:
  1. `ctrl_extend_body_menu` appends Compile-time.
  2. `branch_extend_body_menu` does three things:
     - Prepends **Else if** and **Else** (Else only if the chain has none) when the line above is the closing `}` of an `if` chain.
     - Prepends **Case** and **Default case** (Default only if the switch has none) when the dot is at the end of a case clause.
     - **Replaces the whole menu** with just `Case | Default case` when the dot is between `switch … {` and its first case.
     - Removes **Fallthrough** everywhere except at the end of a case clause that is not the last clause, and never in a type switch.
  3. `loop_extend_body_menu` grays Break/Continue and appends the labeled jumps.
  4. `layout_extend_body_menu` appends Layout, but only if "Declarations" is present (not in the cases-only menu).

  **Display order rule (all menus):** `make_view` first lifts `pinned` entries (and, in the Add menu, imported/recent imports) into a "recently used" section at the top, in author order. It keeps author order for the rest when there are at most 12 of them. Above `BUCKET_THRESHOLD = 12` it sorts them alphabetically by lower-cased label (byte order, so punctuation sorts before letters). The rule is deliberate ("Large lists are shown as a flat ALPHABETICAL grid (scrollable), not bucketed. Small lists keep their natural/author order", model.odin `make_view`), and the author keeps the root statement menu under the threshold on purpose: Layout is one group "so the menu stays short enough to keep its order" (stmt_layout.odin `layout_extend_body_menu`). So:
  - The **Assignment** group (16 entries) is shown as `%%= | %= | &&= | &= | &~= | *= | += | -= | /= | <<= | >>= | Assignment | Implicit Context | |= | ||= | ~=`.
  - **Built-in** (58 procedures) is alphabetical.
  - The **root** menu has 10 groups; it is alphabetical whenever three or more extras apply (13+ entries), i.e. an `if` chain that ends a case clause (any switch kind). With all four extras the baseline shows (re-verified by probe): `Assignment | Branching | Calls | Case | Compile-time | Declarations | Default case | Else | Else if | Error handling | Jumps and cleanup | Layout | Loops | Scope and blocks`.
  - Otherwise it keeps author order: `Else if | Else | Declarations | …` or `Case | Default case | Declarations | …` (two extras = 12 entries, not sorted).
- **Rules & edge cases:**
  - **Grayed entries in fill menus are advisory.** Picking one still inserts it: `menu_select` has no dim check on the slot-fill path. Verified at baseline: a gray Break outside any loop inserts `break` (probe), and a gray Number in an `if` condition inserts `if 0 {`. This is **deliberate for type-fit dims**: heat.odin `heat_is_action` says "Leaves grayed by type fitting still work when picked, so they still count", and docs/EDITOR_MODEL.md §3.7 says the same. The Break/Continue scope dims, the iterability dims, the `#unroll`/`when` constant dims, and the dims in "Pass as" / "Assign to" / Field of go through the same unchecked path (also advisory); no comment states intent for those.
  - Only the **Y option menus** refuse a dim pick. These are the if/switch/case options (`BR_OPT_FILL`, `branch_fill`), the Loop / Labeled block / Operator / break-continue menus (`LOOP_OPT_FILL`, `loop_option_choose`), and the `when`/`#assert` options (`CTRL_MENU_FILL`, `ctrl_menu_choose`). There the menu simply stays open, and no heat is recorded.
  - B pops one menu level. At the root it closes the menu and runs all cancel hooks (temp line removed, refills restored).
  - "Calls" has `heat_key = "Call"`, so its wear (menu heatmap, doc 03 F13) is shared with the value menu's "Call".
- **Source:** model.odin `open_slot_menu`, `make_view`, `menu_select`, `menu_cancel`; branch.odin `branch_extend_body_menu`, `branching_entries`; loops.odin `loop_menu_entries`, `assign_menu_entries`, `loop_extend_body_menu`; ctrl.odin `ctrl_extend_body_menu`; stmt_layout.odin `layout_extend_body_menu`, `layout_group`.

### 3. Declarations

- **Trigger:** Statement menu ▸ Declarations ▸ leaf.
- **Behavior:** Names come from `generate_ident`, which yields `adjective_animal` names unique in the file (e.g. `brave_otter`). After the insert the **cursor is on the new name**, ready to be renamed by voice or text tools (doc 08).

  | Leaf | Inserted fields | Shown as |
  |---|---|---|
  | Variable (:=) | name(editable) · ` := ` (kind `decl`) · value dot | `brave_otter := ●` |
  | Variable (typed) | name · `: ` (`decl`) · type dot · ` = ` · value dot | `brave_otter: ● = ●` |
  | Variable (no value) | name · `: ` (`decl`) · type dot | `brave_otter: ●` (zero value) |
  | Multiple (:=) | name · `, ` · name · ` := ` (plain fixed) · value dot · `, ` · value dot | `brave_otter, calm_otter := ●, ●` |

  - **Typed value hint:** after any fill on the line (and after a type is replaced through LT+A), `sync_typed_decl_value_hint` sets the hint of the empty value dot in `name: T = ●` to `T`, so the value menu grays what can't be a `T`. While the type is still a dot, the hint is empty. (A value dot that comes back from loading `x: T =` has no hint. The sync is only called after a fill on the line, after an LT+A type replacement, and after LT+B on a literal's fields dot (`menu_select`, `lit_fields_dot_delete`), so that dot stays untyped unless the type is changed.)
  - **LT+B on `= ●`** (the empty value of a typed declaration) gives `name: T`, i.e. a zero-value declaration (`lit_delete_selected`); the cursor goes to the type.
  - **Y on the declaration operator** (a `decl` field) opens **"Declare as"**. The labels use the line's real name(s) (everything before the operator, trimmed), e.g. for `calm_otter: ● = ●`:
    `calm_otter := value   (type inferred)` · `calm_otter: type = value   (choose the type)` · `calm_otter :: value   (constant)` (verified by probe). Nothing is dimmed; picking the current form is a no-op.
    - Choosing *typed* turns the operator into `: `, inserts a type dot and ` = ` and opens the Type menu at once (B there leaves the `● = ` in place).
    - Choosing infer/const from `name: T = v` drops the type and keeps the value. From `name: T` (no value), it appends a value dot.
- **Rules & edge cases:** "Multiple (:=)" uses a plain fixed ` := `, not kind `decl`, so Y does not offer Declare as on it (see Open questions). A *loaded* `a, b := f()` does get a `decl` operator (parse.odin `emit_names_prefix` → `emit_decl_rest`), so Declare as works on loaded multi-declarations. Capturing a call result (§9) also makes a `decl` ` := `.
- **Source:** model.odin `make_body_statement` (`__stmt_decl__`, `__stmt_typed__`), `make_multi_decl`; struct_lit.odin `make_zero_decl` (`ZERO_DECL_FILL`); field_access.odin `sync_typed_decl_value_hint`; change.odin `open_decl_form_menu`, `apply_decl_form`.

### 4. Assignment: picking the target from what exists

- **Trigger:** Assignment ▸ **Assignment**, or Assignment ▸ any compound operator (`+=` …).
- **Behavior:**
  - **The line is built.** The new line is an empty editable target, an operator field (kind `assign_op`, text ` = ` / ` += ` …) and a value dot: `● = ●`.
  - **The target pick starts at once** (`assign_pick_start`, *Reference pick mode*, doc 06). The cursor jumps to the last candidate before the new line in file order (the nearest declared name above), else the first candidate.
    - D-pad Left/Right: previous/next candidate, wrapping around. Up/Down: first candidate on the previous/next line that has one.
    - Candidates are editable name fields of kind `""` that can be assigned. Excluded: names declared with `::` (procedures, types, constants; only while picking an assignment target), call names (a name followed by `(`), anything on `package` / `import` / `foreign` lines, string/comment/label fields (non-empty `kind`), and names containing `.`. Names out of scope are excluded too: locals of ended blocks and of sibling case clauses (ref_scope.odin), loop variables outside their loop, if/switch setup names and type-switch variables outside their statement. Nothing checks that a candidate is an identifier, so editable number literals (a menu-built or dictated `0`, the `0` / `1` of a menu-built C-style header) are candidates too (probe of `ref_candidates`), so the pick can land on `0` and produce `0 = ●` (that last step is code reading: the `assigning` filter only rejects `::` names; doc 06 F15 and its open question 20).
  - **A** on a name opens **"Assign to"**:
    - the name itself;
    - `name^   (what it points to)` when it is a pointer;
    - **Field of name ▸** when its type is a struct (nested to depth 3; each struct-typed field's submenu starts with the field itself, e.g. `p.pos`).
  - **Choosing a target** fills it as one editable field (`count`, `p.pos.x`). The value dot's hint becomes the target's type (`set_assign_target`); for a value that is already a call, its argument dots keep their own hints. The cursor ends on the **target** (not the value dot).
  - Example (pinned by `test_assignment_picks_a_declared_name`): with `count := 0` and `ratio: f32 = 1` above, Assignment starts on `ratio`; Up moves to `count`; A → "Assign to" → `count` → `count = ●` with the dot expecting `int`.
- **Rules & edge cases:**
  - **B while picking** removes the new line, and the cursor goes back to the `●` line or green dot it came from (`ref_pick_cancel`, `assign_pick_drop`). The document is byte-identical to before (`test_assignment_cancel_takes_the_line_away`).
  - **Nothing to pick:** when no candidate exists, the pick ends immediately on choosing Assignment (no B needed): the line is removed and the status line shows **"nothing declared to assign to here - declare it first (Declarations > Variable)"** (verified by probe on an empty `main`). This is the only notice string in this area.
  - **B in "Assign to"** goes back to picking.
  - **For `op=` statements**, targets whose type can't take the operator are dimmed in "Assign to" (`assign_target_dims`; advisory like every fill dim). Example: `+=` dims a `[]int` target (category Slice); `test_fix_assign_ops` pins `%%=` dimming an `f32` target.
  - **Y on an existing target** (`is_assign_target`: an editable first name followed by ` = ` or an `assign_op` field, or a C-style loop's post target) re-opens the same pick. Here the line already exists, so B only ends the pick.
  - **The setup menu's "Assignment"** (§10) is different: it writes a generated name (`brave_otter = ●`) with no pick.
  - **Implicit Context ▸** lists the non-underscore fields of `base:runtime.Context`, labelled `name   Type` (`allocator   Allocator`, `temp_allocator   Allocator`, `assertion_failure_proc   Assertion_Failure_Proc`, `logger   Logger`, `random_generator   Random_Generator`, `user_ptr   rawptr`, `user_index   int`). It inserts `context.logger = ●` with the dot expecting the field's type (pkg `base:runtime`). No pick follows.
- **Rationale:** "Odin assigns only to what exists (a new name would be a declaration)" (field_access.odin header).
- **Source:** model.odin `make_body_statement` (`__stmt_assign__`); loops.odin `make_assign_op_statement`, `make_ctx_assign_statement`, `context_field_entries`; field_access.odin `assign_pick_start`, `assign_pick_drop`, `open_assign_target_menu`, `set_assign_target`, `is_assign_target`; ref_pick.odin `ref_candidates`, `ref_pick_update`, `ref_pick_cancel`; assign_ops.odin `assign_target_dims`.

### 5. Compound operators filtered by type (Y on an operator)

- **Trigger:** **Y** on an `assign_op` field (`x += 1`, a loaded `x = f()`, a C-style loop's post `i += 1`). HUD hint: `Y: change operator`.
- **Behavior:** Opens **"Operator"**. It lists all 15 of `= += -= *= /= %= %%= |= &= ~= &~= <<= >>= &&= ||=`, sorted for display (15 > 12): `%%= | %= | &&= | &= | &~= | *= | += | -= | /= | <<= | = | >>= | |= | ||= | ~=`. The current operator and those the target's type category can't take are dimmed (the category comes from the field just before the operator, `assign_target_cat`). Choosing one rewrites the field text to ` op ` and leaves the cursor on the operator. If the value is still an empty dot (and is the line's last field), its hint is reset:
  - for `<<=` / `>>=`: no hint (any integer);
  - otherwise: the target's type.
- **Fit table** (`assign_op_fits`, by target category; Unknown/Any fit everything):

  | Operators | Allowed categories |
  |---|---|
  | `=` | all |
  | `%=` `%%=` `<<=` `>>=` | Integer, Rune |
  | `\|=` `&=` `~=` `&~=` | Integer, Rune, Bool, BitSet |
  | `&&=` `\|\|=` | Bool |
  | `+=` `-=` | Integer, Rune, Float, BitSet, Array (element-wise) |
  | `*=` `/=` | Integer, Rune, Float, Array |

  Example (from the baseline): on `f += 1` with `f: f32`, only `*= | -= | /= | =` are lit (`+=` is current).
- **Rules & edge cases:** The dim is a refusal here (an options menu). A loaded `x = f(...)` gets an `assign_op` field too (`emit_names_prefix`), so Y works on it. Several targets (`a, b = …`) keep a fixed `=`.
- **Source:** loops.odin `ASSIGN_OPS`, `open_assign_op_menu`, `set_assign_op`, `loop_option_choose`; assign_ops.odin `assign_op_fits`, `assign_target_cat`.

### 6. Calls: Internal procedure / From import / Built-in

- **Trigger:** Statement menu ▸ **Calls** ▸ subgroup ▸ leaf. The value menu has the same tree under **Call**, built by the same `build_call_children`.
- **Behavior:**
  - **Internal procedure:** every line of this file whose text contains ` :: proc(` (the name is the line's first editable field), then the procedures of the package's other files (doc 07 §9), without duplicates. The current procedure is included, so recursion is possible. With none: a dimmed placeholder `(no procedures defined)` (picking a placeholder does nothing).
    - Edge case: the match is the literal text ` :: proc(`, so a procedure declared with a calling convention (`callback :: proc "system" (`) is **not** listed, although `call_signature` would find its signature.
  - **From import:** one group per import, labelled by its reference (alias or last path segment; blank `_` imports are skipped; heat key = the import path). Inside it:
    - procedures this file already calls through that reference, **pinned first**;
    - then the package's full procedure list grouped by file / foreign block / name prefix (`Get...`) / alphabetical buckets once a list exceeds 60 (`FLAT_MAX`, doc 07), with the pinned ones removed from the groups (`remove_named_leaves`), so group shapes don't depend on the file;
    - an import with no table rows offers `Other (name it yourself)`, which inserts `pkg.brave_otter(○)` with an editable name and an "any number of arguments" dot.

    With no imports: a dimmed placeholder `(no imports yet)`.
  - **Built-in:** the 58 built-ins of `BUILTIN_PROCS` (len, cap, size_of, make, new, delete, append, inject_at, pop, min, max, clamp, assert, panic, …), shown alphabetical (58 > 12). `BUILTIN_PROCS` stores only {name, required count, variadic, return type}, no parameter types, so a built-in's argument dots are **untyped** (probe: `len` gives `len(●)` with no hint, so nothing in its value menu is grayed).
  - **Inserted shape:** `name(` + argument dots + `)`.
    - A known procedure's name is **fixed text**. It is changed with Y, not edited.
    - An import call is `pkg` `.` `Name` as three fields.
    - A statement call adds the usual trailing `●` line (dropped at a green dot).
  - **Cursor:** after the insert it lands on the first argument dot. For example, `helper(a: int, s: string) -> int` gives `◉helper(●int, ●string)` with the cursor on `●int` (the pink capture dot appears because `helper` returns a value, §9).
- **Rules & edge cases:**
  - **Y on the call's name** opens **"Change procedure"**: the same import's procedures, or for an unqualified call the Internal + Built-in groups.
    - Picking one renames the call and **resets the arguments**: old arguments are removed and fresh typed dots made (`apply_change_call`). The cursor goes to the first new dot, or to the name if there are no parameters.
    - Its heat root is `Call > From import > <path>` (or `Call`).
  - **Y on a filled argument** turns it back into a dot typed for that parameter and opens the value menu (`begin_refill`). B puts the original back exactly (`refill_restore`).
- **Source:** model.odin `build_call_children`, `collect_proc_names`, `collect_imports`, `build_import_proc_menu`, `make_call_this_package`, `make_call_import`, `make_import_proc_call`; builtin_procs.odin; change.odin `open_change_call_menu`, `apply_change_call`, `begin_refill`, `refill_restore`.

### 7. Call argument dots typed from the signature; the variadic "args" dot

- **Trigger:** Any call insertion. Also loading a call from a file, and filling a green "args" dot.
- **Behavior:**
  - **Signature lookup.** `call_signature(pkg_ref, name)` gives {required count, variadic, params, return type, package, known}. It looks in this order:
    1. an import's rows in the generated `CORE_PROCS` table (alias → import path); a name defined several times with different arity (per-OS files) becomes permissive: min required, variadic, unknown return;
    2. `BUILTIN_PROCS`;
    3. a `name :: proc(...)` line in this document;
    4. a sibling file's signature line.

    An unknown procedure gets 0 required + variadic + unknown return.
  - **Parameter parsing.** `parse_params` splits at top-level commas:
    - `a, b: int` gives two ints;
    - `x := 1` and `x: T = v` are optional;
    - `args: ..any` is variadic;
    - directives `#c_vararg #any_int …`, `using` and `$` are stripped;
    - unnamed `proc(int, string)` takes the names as types.

    Pinned by `test_param_arity`, e.g. `"fmt: string, args: ..any, flush := true"` gives (1, variadic).
  - **Dots inserted** (`inject_call_args`):
    - **no parameters:** `(` `)` as *two* fields, so the call's name stays a separate selectable part;
    - **N required:** `(● , ● …)`, each value dot's `hint` = that parameter's type text and `hint_pkg` = the import path it is written in (e.g. `LPCWSTR` / `core:sys/windows`); optional parameters get no dot;
    - **variadic or unknown:** after the required dots, a green **"args"** dot (`○`) whose hint is the variadic element type. The UI labels it `..` + that hint (`..any` for `fmt.println`); an unknown procedure's args dot has no hint and no label.
  - **Filling an args dot** appends `, ○` after the new value (same hint), so the list can keep growing (`append_more_args_slot`). Unfilled args dots and the `, ` before them are never saved (`node_source`).
  - Examples (calls_test.odin):
    - `win.MessageBoxW` gives `win.MessageBoxW(●, ●, ●, ●)` (4 dots, no args dot);
    - `fmt.println` gives `fmt.println(○)`, saved as `fmt.println()`; after String then Number: `fmt.println("", 0, ○)`, saved `fmt.println("", 0)`;
    - `fmt.printf` gives one value dot, then an args dot;
    - `len` gives `len(●)`.
- **Rules & edge cases:**
  - **Grayed fills.** A dot's hint grays value-menu entries that can't produce that type (`apply_fit_dims`, doc 06).
  - **Reloaded calls.** A call loaded from a file (`parse_call_statement` + `attach_call_signature`):
    - an empty argument (`f(a, , c)`) always comes back as a dot; the steps below run only when the callee is **known** (core table, built-in, this file, a sibling file). An unknown callee gets no typing, no added dots and no args dot;
    - its empty arguments are typed by position;
    - **missing required arguments get dots appended**;
    - a variadic procedure gets its args dot;
    - an operator argument made of `● | ●` operands gets those operand dots typed with the argument's type when the operator preserves type (`same_type_operands`).
- **Source:** calls.odin (`parse_params`, `param_arity`, `call_signature`, `sig_from_decl`, `inject_call_args`, `append_more_args_slot`, `node_source`, `intern_hint`); parse.odin `parse_call_statement`, `emit_args`, `attach_call_signature`.

### 8. One argument per row; grouped rows (Join with previous row / Own row)

- **Trigger:** Automatic for long calls. **Y** on an argument of a call that is shown broken offers up to two extra entries in its refill menu. They are appended last, but the value menu always has more than 12 entries (12 base + "Built-in constants" + "Enum value"), so they are *displayed* in alphabetical position like everything else.
- **Behavior:**
  - **When a call breaks.** A line whose saved text exceeds `MAX_COLS = 80` columns (tab = 4) and holds a call argument list is shown and saved with one argument per row, trailing commas, and `)` on its own line (`call_rows`, `node_source_lines`):
    ```odin
    win.MessageBoxW(
        nil,
        "This is Handmade Hero.",
        win.L("Handmade Hero"),
        win.MB_OK | win.MB_ICONINFORMATION,
    )
    ```
  - **Exceptions that stay on one line** (`needs_break`): if/switch headers and case labels, loop headers, compound assignments (`x += f(...)`), compound values (a ternary, `cast(T)f(a)`), and `#assert(...)`.
  - **Unfilled arguments on broken rows.** An unfilled *required* argument keeps a bare `,` row so it reloads in the right position. An unfilled optional dot's row is skipped.
  - **Grouped rows.** Y on argument *k* of a broken call adds:
    - **Join with previous row** when *k* > 0 and the previous separator ends a row;
    - **Own row** unless the argument already sits alone.

    Picking either restores the argument and changes the row marks (`set_arg_row`): the `, ` that ends a row has hint `"rowend"` (`ARG_ROW_END`), and the call's `(` has hint `"argrows:N"` with N = argument count. If every argument ends up on its own row, the marks are cleared.
  - Target shape (Handmade program):
    ```odin
    window_handle := win32.CreateWindowExW(
        0,
        ...
        win32.CW_USEDEFAULT, win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT, win32.CW_USEDEFAULT,
        nil, nil, instance, nil,
    )
    ```
- **Rules & edge cases:**
  - Loading a call written with several arguments on some rows records the same marks (`record_arg_rows`; only when the `(` ends its line, `)` starts the last line, every middle row ends in `,`, and at least one row holds two or more arguments). They are kept only if the argument count still matches; dots added for missing arguments are re-stamped as own rows.
  - A call that carries row marks is always shown and saved broken, whatever its width (`needs_break` → `has_arg_rows`).
  - Loading normalizes call text: arguments are re-joined with `, ` and spaces inside the parentheses are dropped (probe: `fmt.println(1,2)` → `fmt.println(1, 2)`, `fmt.println( 3 )` → `fmt.println(3)`), and a call written over several lines without row marks is re-laid out by width. A comment inside a multi-line call makes the parser leave its lines as plain text.
  - A short call that is not broken offers neither entry.
  - D-pad Up/Down move between rows of a broken line before leaving it. Left on a row's first part wraps to the row's last dot (`row_nav.odin`, doc 02).
- **Source:** format.odin `find_arg_list`, `call_rows`, `needs_break`, `node_source_lines`, `ARG_ROW_END`, `arg_rows_hint`, `has_arg_rows`; stmt_layout.odin `arg_row_extend_menu`, `arg_row_choose`, `set_arg_row`; parse.odin `record_arg_rows`.

### 9. Capture dots (pink): keep a call's result

- **Trigger:** **A** on the pink dot shown in the indentation in front of a bare call statement whose procedure returns something.
- **Behavior:**
  - **When the dot exists.** `sync_capture_dots` runs after every input, only while plainly editing (no menu, pick, refill, …) and only when the document fingerprint changed. It adds a `capture` slot right after the indentation of each line inside a block (never at file scope) that is a *bare call*, and removes it where that no longer holds. A new call statement gets its dot at the end of the same update that inserted it (probe: `len(●)` appeared as `◉len(●)` immediately), and the cursor stays on the same part (`editor_field` is shifted). A bare call is: only indentation, an optional `pkg.`, then `name(...)` and nothing after it, where the callee is known and returns a value (`call_result_count` > 0).
  - **How many results.** `result_count`: `int` → 1; `(int, bool)` → 2; `(a, b: int, ok: bool)` → 3; a result list containing `#optional_…` → 1.
  - **A on the dot** (`capture_call_result`; no menu opens) turns `◉ len(s)` into `brave_otter := len(s)` and `◉ pair()` into `brave_otter, calm_otter := pair()`. The ` := ` is a `decl` field. The cursor goes to the first new name.
  - The dot is drawn smaller and steady ("an option, not a hole"). It has no text, so it never reaches the saved source.
- **Rules & edge cases:**
  - **LT+B on a captured name** (`uncapture`): on `n := len(s)` or `x: string = strings.clone(s)` it removes the declaration and leaves the bare call; its capture dot comes back with the cursor on it. With several names, the deleted one becomes `_` until none are left. A struct literal value is not a call result.
  - **When the dot follows the call.** Renaming the callee to a procedure that returns nothing removes the dot (`test_capture_dot_follows_the_callee`). Built-ins with unknown return `"?"` (e.g. `append`) get no dot.
- **Source:** capture.odin (`CAPTURE_KIND`, `call_result_count`, `result_count`, `sync_capture_dots`, `add_capture_dot`, `capture_call_result`, `uncapture`); model.odin `update` (deferred sync), `open_slot_menu` (capture short-circuit); src/app/main.odin `slot_dot_color` (pink `{0.93,0.27,0.60}`).

### 10. Branching: If, If / Else, If with setup

- **Trigger:** Branching ▸ leaf.
- **Behavior:** Keywords are fields of kind `brkw`, so they are selectable and Y/LT+B act on them. A condition dot has hint `bool`. The cursor goes to the first unfilled dot (`focus_first_dot`).
  ```odin
  if ● {            // If
      ●
  }
  if ● {            // If / Else
      ●
  } else {
      ●
  }
  if ●setup; ● {    // If with setup (cursor on the setup dot)
      ●
  }
  ```
  The cursor lands on the first non-statement dot of the header line, else of the next line: the condition (If, If / Else), the setup dot (If with setup), the value dot (Switch, Partial switch, Type switch), or the `case ●` dot on the next line for Switch (conditions), whose header has no dot (probe-verified).

  **A on a setup dot** (`●setup`, kind `setup`) offers `Variable (:=) | Two names (:=) | Assignment | Call`:
  - `brave_otter := ●` (cursor on the value dot)
  - `brave_otter, ok := ●` (`ok` is a literal editable name; cursor on the value dot)
  - `brave_otter = ●` (a generated target, no pick)
  - `Call ▸` the same Internal / From import / Built-in tree as §6; no trailing line is added because the slot is not a `body` slot.

  The ` := ` / ` = ` here are plain fixed text (no Declare as).

  Pinned by `test_branch_if_with_setup_and_index`: If with setup → Two names (:=) → rename the generated first name to `v` → value dot: Reference ▸ `m` ▸ `m[key]   int` (cursor on the key dot, hint `string`) → String `"key"` → condition dot: Reference ▸ `ok` gives `if v, ok := m["key"]; ok {`, with `v: int` and `ok: bool` inside (see §27). Names declared in a setup are typed and offered by Reference only inside the `if` and its `else if`/`else` branches (`branch_declares`, `branch_name_hidden`).
- **Rules & edge cases:** The `else` line's fields are `<indent>} ` (one fixed field) + kw `else` + ` {`, so `}` and `else` share the line; `else if` is a single keyword field `"else if"`. A closing brace line is one fixed field `<indent>}`. Bodies are indented with the header's indent + one unit of the same style (`indent_unit`).
- **Source:** branch.odin `branching_entries`, `branch_make`, `branch_slot_menu` (`SETUP_KIND`), `fill_setup`, `branch_declares`, `branch_name_hidden`.

### 11. If chains: Y options, Else if / Else at the dot, LT+B

- **Trigger:**
  - **Y** on `if` / `else if` / `else`.
  - **A** on the green dot right after the chain's closing `}`. HUD hint: `A: add a statement, else if or else`.
- **Behavior:**
  - **Y on `if` or `else if`.** Menu title "If" or "Else if". Entries:
    - `Add else if`
    - `Add else` — dimmed when the chain has an else
    - `Add setup` / `Remove setup`
    - `Change condition`
  - **Y on `else`.** Menu title "Else", one entry: `Add else if`.
  - **Where Add else if goes.** Right after the branch Y was pressed on, i.e. before the next branch or the chain's closing line. On an `else` it goes before the else. The cursor moves to the new condition dot.
  - **Add else** goes at the end. The cursor moves to its body `●`.
  - **Change condition** refills the whole condition through a `bool` dot; B restores it.
  - **Add setup** inserts `●setup; ` before the condition and opens the setup menu.
  - **At the dot after the chain**, Else if / Else are prepended to the statement menu (the line right above must be exactly `}` closing an `if` chain: `chain_closed_by`). The temporary line of a green dot is discarded: the branch line is inserted before the chain's closing `}`. (From a `●` statement line after the chain, that `●` line stays where it is.) Else if goes before an existing else. Cursor: Else if → its condition dot; Else → its body `●`. Pinned by `test_branch_else_from_green_dot`.
  - **HUD hints:**
    - on `if`: `Y: add else if / else / setup, change condition    LT+B: delete`
    - on `else if`: `… LT+B: remove branch`
    - on `else`: `Y: add else if    LT+B: remove branch`
- **Rules & edge cases (LT+B, `branch_delete`):**
  - on `if`: the whole chain goes (block_delete.odin);
  - on `else if` / `else`: only that branch, through the line before the next branch;
  - anywhere inside the condition: the condition becomes an empty `bool` dot (the bodies stay; `test_fix_ltb_condition_keeps_construct`); already a dot: nothing;
  - inside a setup: the setup and its `; ` go (HUD `LT+B: remove setup`);
  - anywhere else on an `if` / `else if` / `else` line (e.g. the ` {`): nothing.
- **Source:** branch.odin `open_options`, `apply_option`, `insert_branch`, `add_branch_after_chain`, `chain_closed_by`, `if_chain`, `if_chain_header`, `branch_delete`, `branch_hint`, `refill`, `add_setup`, `remove_setup`.

### 12. Switch, Switch (conditions), Partial switch; case clauses and ranges

- **Trigger:** Branching ▸ Switch / Switch (conditions) / Partial switch. **Y** on `switch`, `#partial` or `case`. **A** on dots inside a switch body.
- **Behavior:**
  ```odin
  switch ● {          // Switch            (#partial switch ● { for Partial switch)
  case ●:
      ●
  }
  switch {            // Switch (conditions): case dots expect bool
  case ●:
      ●
  }
  ```
  - **Case dot typing.** Each empty case value dot expects the switched value's type. `branch_sync` re-derives this after every input, so filling `switch x` with `x: int` turns `case ●` into an int dot. For `switch {` the case dots expect `bool`.
  - **Case value menu** (`branch_adjust_menu`, value switches only; a `switch {` case dot gets just the plain value menu with its `bool` gray-out):
    - it gains **Range** right after Number (`a ..< b  (up to b)` / `a ..= b  (through b)`), dimmed unless the expected type is integer, rune, float or enum (or unknown);
    - enum values, built-in constants and import constants already used by another case are **dimmed** (`.North` used → dimmed for the next case). Number/String literals are not checked.
  - **Y on `switch`.** Menu title "Switch". Entries:
    - `Add case`
    - `Add default case` — dimmed if one exists
    - `Make #partial` / `Remove #partial`
    - for a type switch: `By reference` / `By value`
    - for a value switch with a value (`switch x {`): `Add setup` / `Remove setup` and `Change value`. A `switch {` (conditions) gets neither.
  - **Add case** goes at the end, before a default case if the last clause is one; the cursor goes to the new case dot. **Add default case** goes at the end; the cursor goes to its body `●`.
  - **Y on `case`.** Menu title "Case". Entries:
    - `Add value` — not on `case:`; inserts `, ●` before `:` and opens its menu at once
    - `Add case after`
    - `Add default case` — dimmed if one exists
  - **Y on a case value** refills it with a correctly typed dot; B restores it.
  - **Dots in a switch body:**
    - between `switch … {` and the first case: **only** `Case | Default case` (HUD `A: add a case`); the inserted case takes that spot;
    - at the end of a clause: Case / Default case are prepended (HUD `A: add a statement or a case`).
  - **Saved forms.** A case with an unfilled value is saved as `case :` and reloads as a dot. The default is `case:`.
- **Rules & edge cases (LT+B):**
  - on `switch`: the whole switch;
  - anywhere in the switched value: the value becomes an empty, untyped value dot (the clauses stay); already a dot: nothing;
  - inside a setup (including its `; `): the setup goes;
  - on `#partial`: just `#partial `;
  - on `case` (or anywhere on a default case): that clause;
  - on one of several case values: that value and its separator (`case 1, 2:` → `case 1:`);
  - on a sole case value: back to a dot.

  HUD hints:
  - on `switch`: `Y: add case / default, #partial, change value    LT+B: delete`
  - on `#partial`: `Y: add case, #partial    LT+B: remove #partial`
  - on `case`: `Y: add value / case    LT+B: delete case`
  - on a case value: `Y: change value    LT+B: remove it`
- **Source:** branch.odin `branch_make` (`BR_SWITCH_FILL`, `BR_SWITCH_BOOL_FILL`, `BR_PARTIAL_FILL`), `switch_ctx`, `switch_cases`, `case_dot`, `switch_case_hint`, `branch_prepare_slot`, `branch_sync`, `branch_adjust_menu`, `used_case_values`, `dim_used`, `insert_case`, `add_case_at`, `has_default_case`; range_fill.odin.

### 13. Type switch

- **Trigger:** Branching ▸ Type switch.
- **Behavior:**
  - **Inserted shape:** `switch brave_otter in ● {` / `case ◆:` / `●` / `}`. The variable is an editable generated name, and the cursor is on the value dot.
  - **The case dot** (kind `variant`) opens a menu of the switched union's variants, from this file or a sibling file. Variants used in other cases are dimmed. Then come `nil` (dimmed if used) and `Type ▸` (the full type menu). Example: `Circle | Square | nil | Type`.
  - **Variable type per clause.** Inside a clause naming exactly one type, the variable has that type (`v.r` works under `case Circle:`). In `case:` or a multi-type case it has the union type. Outside the switch it is unknown.
  - **Y on `switch`** adds `By reference` / `By value`, which toggles `switch &v in x {`.
  - **Fallthrough** is never offered in a type switch.
- **Rules & edge cases:** LT+B on the variable does nothing (rename it with LT+A). There is no setup and no Change value for type switches. Loaded `case` values of a type switch become `type` fields (`branch_line_roles`).
- **Source:** branch.odin (`VARIANT_KIND`, `union_variants`, `type_switch_var`, `branch_slot_menu`); branch_parse.odin `branch_line_roles`, `is_type_switch_text`.

### 14. When (inside a body)

- **Trigger:** Branching ▸ When, or Compile-time ▸ When (same fill `__br_when__`).
- **Behavior:** Inserts `when ● {` (`when` is kind `kw`, condition hint `bool`) / `●` / `}`, cursor on the condition. **Y on `when`** opens "When": `Add else when | Add else | Change condition` (Add else dimmed when the chain has one; on an `else` line no Change condition). HUD: `Y: add else / else when, change condition    LT+B: delete`. The condition's value menu dims every call (`when_extend_value_menu`), and Reference ▸ Pass as dims non-constants. The body line is indented with `indent + "    "` even in a tab file (probe: `\t    ●`), normalized on save. Owned by doc 04 (compile-time control); listed here because it is a statement leaf.
- **Source:** model.odin `make_branch_statement`; ctrl.odin; when_const.odin.

### 15. Loops: every `for` shape

- **Trigger:** Statement menu ▸ Loops ▸ leaf. Odin has only `for`; each leaf is a shape:

  | Leaf | Inserted header (dots as `●`) | Cursor after insert |
  |---|---|---|
  | For (condition) | `for ●bool {` | the condition dot |
  | For (C-style) | `for i := 0; i < ●int; i += 1 {` | `i` (init name) |
  | For (infinite) | `for {` | `for` |
  | For ... in | `for item in ● {` | `item` |
  | For x, i in | `for item, index in ● {` | `item` |
  | For i in 0..<n | `for i in 0..<●int {` | `i` |
  | For i in 0..=n | `for i in 0..=●int {` | `i` |
  | For &x in | `for &item in ● {` | `item` |
  | #reverse for | `#reverse for item in ● {` | `item` |
  | #unroll for | `#unroll for i in 0..<●int {` | `i` |
  | Labeled for | `outer: for item in ● {` | `outer` |

  Each header is followed by a body line `●`, a closing `}`, and the usual trailing `●` line.
- **Behavior:**
  - **Header fields:** `[indent] [label(kind label) ": "] [#reverse/#unroll (kw) " "] for(kw) …`. The rest depends on the form:
    - while: `" " cond " {"`
    - infinite: `" {"`
    - for-in: `" " ["&"] var1 [", " ["&"] var2] " in " iterable " {"`
    - C-style: `" " init "; " cond "; " post " {"` (just `;` before ` {` when post is empty)

    The C-style init is `name " := " value` and the post is `target assign_op value`; the `0`, `1` and loop variables are editable fields.
  - **Name defaults** (`fresh_name`):
    - loop variables: `item`; `index`; `i`, then `j`, then `k`; else `base_2`, `base_3`, …
    - labels: `outer`, unique per procedure (`proc_has_label`).

    A name counts as taken if it is visible at that line or already on the same header.
  - **In C-style loops** the `i` of the condition is fixed text. Renaming the init variable carries it along through the rename prompt (doc 08), which rewrites whole-word uses in fixed fields.
  - **Range shapes** reuse the shared Range fill, then set the low end to editable `0` and type the high-end dot `int`.
- **Rules & edge cases:** The infinite loop has no stop on its line other than `for`. Loop variables are typed and scoped by `loop_header_declares` (§18).
- **Source:** loops.odin `loop_menu_entries`, `loop_fill`, `make_loop`, `inject_block`, `fresh_name`, `Loop_Hdr`, `loop_hdr`.

### 16. Loop options (Y on `for`, its directive or its label)

- **Trigger:** **Y** on `for`, `#reverse`/`#unroll`, or the label. HUD: `Y: loop options    LT+B: delete loop` (on `for`).
- **Behavior:** Opens the **"Loop"** menu. Its entries depend on the form:
  - **every form:** `Add label` / `Remove label` (dimmed when a jump needs the label, §19)
  - **infinite:** `Add condition` (inserts ` ●bool`)
  - **while:** `Change condition` · `Remove condition` (it becomes infinite)
  - **C-style:**
    - `Remove init` / `Add init`; Add init restores `v := 0`, reusing the post's variable name
    - `Change condition` + `Remove condition`, or `Add condition`
    - `Remove post` / `Add post`; Add post gives `v += 1` with the init's variable and restores `; `; Remove post leaves `;`
  - **for-in:**
    - `Add #reverse` / `Remove #reverse`
    - `Add #unroll` / `Remove #unroll`
    - `Add 2nd variable` (named `value` for a map, else `index`) / `Remove 2nd variable`
    - `By reference` / `By value`
    - `Change iterable`

  Dims (refusals) in the for-in menu, by iterable kind:

  | Option | Dimmed when the iterable is … |
  |---|---|
  | Add #reverse | a range, a map, or not iterable |
  | Add #unroll | a slice, dynamic array or map; not iterable; any `&` variable; a range or string that is not built from constants (`unroll_iter_const`) |
  | By reference | the loop can't take `&` (`ref_var` < 0): string, range, not iterable, or `#unroll` |

  For a map, By reference applies to the *value* (2nd variable). When a `&` is present the entry reads `By value` (never dimmed) and removes it.

  A loop has at most one directive: on a `#reverse` loop the menu shows `Remove #reverse` and `Add #unroll`, and choosing Add #unroll *replaces* the directive text (and vice versa).

  Probe at baseline, `outer: for x in items` (`items: []int`) with a `break outer` in an inner loop: `Remove label (dim) | Add #reverse | Add #unroll (dim) | Add 2nd variable | By reference | Change iterable`.

  Examples: on `for k in m` (map): `Add #reverse (dim) | Add #unroll (dim) | … | By reference (dim)`. On `for i in 0..<3`: `Add #unroll` is lit.
  - **Y on a loop variable** toggles `&` directly, with no menu (HUD `Y: by reference on/off`). It is refused where not allowed.
  - **Change condition / Change iterable** refill through a dot (B restores).
- **Source:** loops.odin `loop_change`, `open_loop_options`, `loop_apply`, `toggle_by_ref`, `ref_var`, `remove_condition`, `iter_allowed`, `loop_hint`; loop_unroll.odin `unroll_iter_const`.

### 17. The iterable dot: Range and iterability gray-out

- **Trigger:** **A** on a for-in loop's empty iterable dot.
- **Behavior:**
  - **The menu.** The value menu gains **Range** (shared entry), and every leaf is dimmed unless this loop can iterate what it would produce (`iter_dims`; a group is dimmed if nothing inside fits).
  - **Kinds** come from `iter_info`, which follows aliases and distinct types through this file, sibling files and the core tables:
    - `[dynamic]T` → Dynamic
    - `[]T` → Slice
    - `[N]T` / `[Enum]T` → Array (index type = the enum)
    - `map[K]V` → Map
    - `string` / `string16` → String (element `rune`)
    - a range → Range
    - pointers, multi-pointers `[^]T`, procs, structs, enums, unions, bit_sets, bit_fields, matrices → None

    A Reference or an unknown proc is Unknown, which is always allowed. What each value-menu leaf would produce (`entry_iter_kind`): string literals → String; Range → Range; Reference and "Other (name it yourself)" → Unknown; constants and calls → by their type / return type; numbers, bools, `nil`, operators, enum values, conversions, struct literals and types → None (dimmed).
  - **Loop modifiers restrict iteration:**
    - `&item`: not String, Range or Map;
    - `&` on the 2nd variable: Map only;
    - `#reverse`: not Range or Map;
    - `#unroll`: not Slice, Dynamic or Map.

    Example: on `for &item in ●`, Range and String are dimmed; Reference and Call stay lit.
  - **Reference ▸ Pass as** on an iterable dot: the bare name is dimmed if it can't be iterated, `&name` is always dimmed, and `name^` is dimmed unless the pointee iterates (`loop_pass_as_dims`).
  - **#unroll constants** (`loop_unroll.odin`):
    - on a range-end dot of an `#unroll` loop, calls are dimmed, and Pass as dims non-constant names (`count := 3`; `N :: 3` stays) and any field or element;
    - on the iterable dot of an `#unroll` loop, calls returning `string`/`cstring` and string *variables* are dimmed.
- **Source:** loops.odin `loop_extend_value_menu`, `is_iterable_dot`, `iter_dims`, `entry_iter_kind`, `iter_info`, `iter_types`, `loop_pass_as_dims`; loop_unroll.odin `unroll_extend_value_menu`, `unroll_pass_as_dims`, `unroll_const_expr`, `unroll_const_name`; enum_index.odin.

### 18. Loop variables: types and scope; LT+B on loop parts

- **Behavior:**
  - **Types** (`loop_header_declares` → `iter_types`):
    - `for item, index in items` (`[dynamic]Item`): `item: Item`, `index: int`
    - map: `key: K`, `value: V`
    - string: `ch: rune`, `i: int`
    - range: the low end's type, or `int` for an int literal
    - `[Dir]f32`: the index is a `Dir`
    - C-style `i := 0`: `int`

    Example: `for part, index in strings.split(...)` gives `part: string`.
  - **Scope.** Variables are visible (and offered by Reference) only inside their loop. A C-style variable is also visible in its own condition and post. A loop's own variable is not offered for its own iterable.
  - **LT+B** (`loop_delete`):

    | On … | Result |
    |---|---|
    | `for` | the whole loop |
    | the label | label removed (if allowed); its jumps become bare |
    | the directive | directive removed |
    | 2nd variable | that variable removed |
    | 1st variable, when a 2nd exists | becomes `_` (`for _, index in …`; a `&` on it is dropped) |
    | 1st variable, alone | nothing |
    | the iterable | back to an untyped dot; already a dot: nothing |
    | while condition | back to a `bool` dot; if already a dot, the loop becomes infinite |
    | a C-style part (init / condition / post) | that part becomes empty (Remove post also turns `; ` into `;`) |

    LT+B on the label of a labeled *block* removes the label (same as Y ▸ Remove label, refused while a jump names it).
- **Source:** loops.odin `loop_header_declares`, `init_declares`, `loop_name_visible`, `loop_delete`, `loop_line_units`, `loop_expected`.

### 19. Labels: labeled loops and labeled blocks

- **Trigger:** Loops ▸ Labeled for. Scope and blocks ▸ Labeled block. Y ▸ Add label.
- **Behavior:**
  - **Uniqueness.** *New* labels are unique per procedure, siblings included (Odin: "Duplicate label"); fresh loop labels are `outer`, `outer_2`, … (`fresh_name` + `proc_has_label`). A Labeled block's generated `adjective_animal` name is unique in the file (`generate_ident`). Renaming a label (LT+A / dictation) to a name already used is not refused: `proc_has_label` is only called by `fresh_name`.
  - **Renaming.** A label rename (LT+A) rewrites the `break outer` / `continue outer` inside its block (`label_rename_jumps`).
  - **Removing.** "Remove label" / LT+B rewrites those jumps to bare `break` / `continue`.
  - **When removal is refused** (dimmed, and LT+B is a no-op): if a jump naming the label sits inside an inner loop, or a `break` sits inside an inner switch, between the header and the jump. For a labeled *block* it is refused whenever any jump names it, because a bare `break` can't leave a block. HUD then shows `Y: options    (a jump needs the label: it stays)` or `Y: loop options    (a jump needs the label: it stays)`.
  - **Labeled block:** `brave_otter: {` / `●` / `}`. The label (kind `label`, editable) is a generated `adjective_animal` name; the rest of the header is one fixed field `: {`. Y on it opens "Labeled block" ▸ `Remove label`, which turns the line into a plain `{`. HUD on that label: `Y: options    LT+B: remove label`, or `Y: options    (a jump needs the label: it stays)`.
  - Probe at baseline: in `blk: { … }` the Jumps group reads `Return | Break (dim) | Break blk | Continue (dim) | Defer`; inside `outer: for … { for … { ● } }` it reads `Return | Break | Break outer | Continue | Continue outer | Defer`.
- **Source:** label_refs.odin (`proc_has_label`, `label_jump_refs`, `label_removal_blocked`, `label_unname_jumps`, `label_rename_jumps`); loops.odin `labeled_block`, `loop_apply` (`label+`, `label-`); model.odin `make_scope_statement` (`__scope_label__`).

### 20. Jumps and cleanup

- **Trigger:** Statement menu ▸ Jumps and cleanup.
- **Behavior:**
  - **Return** → `return ●` (fixed `return `). See §21 for the extra value dots and typing.
  - **Break** / **Continue** → keyword field `break` / `continue` (kind `kw`).
    - Break is dimmed unless inside a loop or switch; Continue is dimmed unless inside a loop (`jump_scope`, which walks enclosing braces up to the procedure header).
    - For each label in scope, innermost first, the menu appends `Break <label>`, and `Continue <label>` for loop labels only. A labeled block gets `Break blk` but no `Continue blk`.
    - Inserting `Break outer` gives `break` `" "` `outer`.
  - **Fallthrough** → fixed `fallthrough`. Only present at the end of a non-last case clause of a switch that is not a type switch (`switch x {` or `switch {`) (§2).
  - **Defer** → `defer ●` (an untyped value dot, cursor on it; normally filled with a Call, which then gets its argument dots).
  - The cursor after Return / Defer is on the dot; after Break / Continue / Fallthrough (no dot) on the line's first part.
  - **Y on `break`/`continue`** opens a menu titled `break`/`continue`: the bare word plus `<word> <label>` for each label in scope (loop labels only for continue), none dimmed (probe: `break | break outer`). Choosing one rewrites the label part. HUD: `Y: choose label    LT+B: delete`. LT+B deletes the statement line.
  - Loaded `break` / `continue` / `break lbl` lines get the same fields (loop_parse.odin), so Y works on them.
- **Rules & edge cases:** Gray Break/Continue can still be picked (advisory, §2). Example from the baseline: `Return | Break (dim) | Continue (dim) | Defer` in `main` outside any loop. Inside `outer: for` → `switch` → end of `case 1:` (not last): `Return | Break | Break outer | Continue | Continue outer | Fallthrough | Defer`.
- **Source:** model.odin `make_jump_statement` (return, fallthrough, defer); loops.odin `make_jump`, `jump_scope`, `loop_extend_body_menu`, `open_jump_menu`, `set_jump`; branch.odin (Fallthrough filter).

### 21. Return values and multi-result procedures

- **Trigger:** Return statements; a procedure header's result list (the header itself is doc 04).
- **Behavior:**
  - **`result_list_sync`** runs after every update (deferred in `update`) and after load (`force`). It skips updates that end with a menu open or during a Reference pick / Pass as / refill, because those hold a field index.
    - **Result lists:** no results → one blue type dot; one → `T○`; two or more → `(T1, T2○)`. The parentheses appear and disappear with the count.
    - **Return statements:** once a return has a value, an orange `○` "another value" dot follows the last value.
    - **Typing:** every empty value dot (and the extra dot) is typed **by position** from the enclosing procedure's results.

    Example: in `divmod :: proc(a, b: int) -> (int, int)`, Return gives `return ●` (hint `int`). Filling it gives `return 0○` (extra dot hint `int`), then `return 0, 0○` (extra dot hint empty: past the results). Saved: `return 0, 0`.
  - **Filling an extra dot** inserts its `, ` (`more_dot_filled`).
  - **LT+B on a return value:**
    - on a one-field value: removes it with its `, `;
    - on a part of a bigger expression: falls through to the expression deletes (doc 06);
    - on the extra dot: nothing;
    - on a valueless return (loaded `return`, or an unfilled `return ●`): **deletes the statement**, since its dot is the only stop.
  - **Capturing** a multi-result call (§9) declares one name per result.
- **Rules & edge cases:** Named results `-> (q, r: int)`, `-> !`, `where` clauses and forward declarations are not structured. A `return` line with a `//` comment is not treated as a return list (`return_span`). A `return f(x)` that is one call is left to the call parser, so its arguments stay typed: `return fmt.println("hi", ○)○`. A loaded bare `return` has only the orange extra dot (`return ○`, hint = first result). The extra dots are optional and never saved, and an unfilled `return ●` saves as `return`.
- **Source:** result_list.odin (`results_span`, `return_span`, `result_list_sync`, `shape_results`, `shape_return`, `enclosing_results`, `more_dot_filled`, `result_list_delete`, `structure_results`); parse.odin `parse_return_statement`; model.odin `menu_select` (`was_more`).

### 22. Error handling group

- **Trigger:** Statement menu ▸ Error handling.
- **Behavior:** Cursor on the first dot.
  - **or_return** → `● or_return`
  - **or_else** → `● or_else ●`
  - **if err != nil** → `if ● != nil {` / `●` / `}`. The header is plain fixed text `if ` + dot + ` != nil {`, *not* a structured `if` (no `brkw` field, so no Y options and no Else if / Else at the dot after it). After a save and reload it becomes a structured `if` (probe).
- **Rules & edge cases:**
  - There are no `or_break` / `or_continue` leaves. docs.odin and highlight.odin know them, but the statement menu doesn't offer them.
  - `● or_return` as a whole statement is valid Odin only when the operand is a call. `● or_else ●` as a whole statement is never valid: its result is unused.
  - The operand dots are untyped, and the `if ● != nil {` body is indented `indent + "    "` even in tab files.
  - **Unfilled, they don't survive a save:** probe at baseline, `● or_return` saves as `\t or_return` and `● or_else ●` as `\t or_else` (the empty dot leaves its leading space). Both reload as plain text with no dots. Their leading space also leaks into the indent of statements inserted next to them (§1).
  - In practice, `or_return` reaches real code through loaded statements such as `x := f() or_return`: the call parser keeps any tail after a one-line call (only an `or_…` tail after a multi-line call) as a fixed field.

  See Open questions.
- **Source:** model.odin `make_error_statement`; parse.odin `parse_call_statement` (tail).

### 23. Scope and blocks

- **Trigger:** Statement menu ▸ Scope and blocks.
- **Behavior:**
  - **Block** → `{` / `●` / `}`. The `{` line has no name or dot, so the cursor stays on the `{` line itself (probe-verified).
  - **Using** → `using ●` (an untyped value dot, cursor on it). Odin's statement `using x` brings the fields of struct value `x` (or a package's names) into scope.
  - **Labeled block** → `brave_otter: {` / `●` / `}` (§19); cursor on the label.
  - Block and Labeled block nest their own `●` line; inner indentation is `indent + "    "` even in tab files (probe: `\t    ●`), normalized to tabs by `format_doc` on save.
  - Saved unfilled, `using ●` becomes `using` and reloads as plain text (no dot).
- **Source:** model.odin `make_scope_statement`.

### 24. Compile-time group in bodies

- **Trigger:** Statement menu ▸ Compile-time ▸ `#assert` / `When`.
- **Behavior:** `#assert(●bool, ○string)` (fields: kw `#assert`, `(`, condition dot, `, `, message dot, `)`); the cursor goes to the condition dot. The message dot is optional (kind `args`, hint `string`) and is never saved while empty, nor is the `, ` before it: an untouched one saves as `#assert()` and reloads as plain text. **Y on `#assert`** opens "#assert": `Change condition | Add message` (Add message dimmed once a message is filled). HUD: `Y: change condition / add message    LT+B: delete`. An `#assert` line always stays on one line (`needs_break`). Details in doc 04.
- **Source:** ctrl.odin `ctrl_extend_body_menu`, `make_assert_statement`.

### 25. Layout: comments and blank lines in bodies

- **Trigger:** Statement menu ▸ Layout ▸ Comment / Multi-line comment / Blank line.
- **Behavior:**
  - **Comment** → `// brave otter`: fixed `// ` + editable text (kind `comment`), placeholder = a generated name with spaces. The cursor lands on the text for dictation. Apostrophes, backticks and braces are just text.
  - **Multi-line comment** → `/*` / `brave otter` / `*/`: the markers at the statement's indent, the text line one tab deeper, and the cursor on the text (probe: `\t/*`, `\t\tbrave otter`, `\t*/`). At a green dot it leaves the stray `●` line described in §1. Y / LT+B on its lines: doc 01 §17 and doc 02 §17-18 (block_comment.odin).
  - **Blank line** → an empty line (just the indentation, which trims away on save). From a `●` line, the cursor moves on to the new `●` line that follows. From a green dot, the cursor goes to the green dot right after the blank line (both probe-verified).
  - **Loaded comments.** Whole-line `// text` comments load with the same editable text. Empty `//` and `//+tag` lines stay fixed text. Comment text is never offered by Reference.
  - **LT+B** on a comment deletes that line. LT+B on a green dot directly above or below a blank line deletes that blank line; on any other dot it does nothing.
  - **Formatting.** `format_doc` keeps single blank lines between statements but removes blank lines just inside `{` or just before `}`.
- **Source:** stmt_layout.odin (`layout_fill`, `parse_comment_line`, `comment_placeholder`, `layout_delete`); block_comment.odin; formatter.odin.

### 26. Struct literals with named fields

- **Trigger:** Value menu ▸ **Struct literal** (in any value dot: a declaration's value, an argument, a field value). Doc 06 owns the value menu; the statement-level behavior is here.
- **Behavior:**
  - **Choosing the type.** The type list:
    1. the dot's expected type first, if it is a struct, pinned and written as this file writes it (`win32.WNDCLASSW`; heat key `<path>.<Name>`);
    2. one `ref.` group per import, with that package's struct types (polymorphic structs excluded);
    3. this file's `X :: struct` types;
    4. sibling files' structs not shadowed here.

    With none: `(no struct types)`. Choosing a type inserts `T{○}`: the type (fixed), `{` (kind `lit`), a green **fields** dot, `}` (kind `lit`). The cursor goes to the fields dot.
  - **A on the fields dot** lists the fields not set yet, labelled `name   Type` (`style   UINT | lpfnWndProc   WNDPROC | …`). Promoted `using` fields are excluded. With none left: `(all fields set)`; when the type's fields are unknown: `(fields unknown)`.
  - **Picking a field** inserts `name = ●`. The name has kind `litkey` (fixed, not editable) and the dot expects the field's type; the cursor goes to that value dot. While fields remain, `, ○` follows.
  - **Saving.**
    - An untouched literal saves as `T{}`.
    - A long literal saves one field per row with `=` signs aligned, `T {` and a trailing `}`:
      ```odin
      window_class := win32.WNDCLASSW {
          style         = win32.CS_OWNDC | win32.CS_HREDRAW | win32.CS_VREDRAW,
          lpfnWndProc   = main_window_callback,
      }
      ```
  - **Editing.**
    - LT+B on a field's name or value removes that field with one `, `, and the fields dot returns. A literal loaded one field per row that loses its last field goes back to `T{}` (one line).
    - LT+B on the fields dot of an empty `T{○}` turns it back into a value dot (untyped, except that the value of `x: T = …` gets `T` again through `sync_typed_decl_value_hint`); with fields set, it does nothing.
    - Y on a field's value refills it with that field's type.
    - Y on the literal's type refills the whole literal (B restores).
  - **Pointer parameters.** A dot expecting a pointer (`^WNDCLASSW`) dims Struct literal; pass `&name` instead.
- **Rules & edge cases (loader):**
  - A literal is structured when it is a *whole* value with named fields, either one line or one field per line with `}` alone. As a statement (`parse_lit_statement`), the text before the type must be `return` or end in `=` (`lhs :=`, `lhs =`, `lhs: T =`, also `lhs op=`), but not `==`/`!=`/`<=`/`>=`, contain no `( { [` or quotes, and not start with `for`/`if`/`when`/`switch`. A whole call argument or value is also accepted (`lit_emit_expr`). The type may be `T`, `pkg.T` or a parameterized `T(int)`.
  - Positional literals (`[3]int{1, 2, 3}`, `Inner{1, 2}`) and irregular spacing (`Inner{a = 1,b = 2}`) stay text.
  - Loaded multi-line literals keep their layout (hint `"break"` on `{`). If their `=` signs were aligned, hint_pkg is `"aligned"` and they are re-aligned after edits.
  - `attach_lit_hints` types empty values (`message = ` reloads as a `UINT` dot) and adds a fields dot where fields are left.
- **Source:** struct_lit.odin (all); format.odin `node_source_lines` (alignment); block_delete.odin `lit_fields_dot_delete`.

### 27. Field access chains, indexing, ranges (values built by Reference)

- **Trigger:** Value dot ▸ **Reference** ▸ pick a name ▸ **"Pass as"** menu (doc 06 owns Reference; these are its statement-relevant extensions).
- **Behavior:**
  - **Pass as entries** (menu title "Pass as"; its dims are advisory; B returns to picking the name):
    - `name`
    - `T(name)` — when the dot has an expected type, `T` written as this file would write it (`win32.LPCWSTR(text)`)
    - `&name   (pointer to it)` — dimmed when the dot expects a known non-pointer type
    - `name^   (what it points to)` — always offered
  - **Field of `<name>` ▸** (struct-typed names; pointers dereferenced):
    - one entry per field, `rcPaint   RECT`;
    - a struct-typed field opens a submenu starting with the field itself (`paint.rcPaint`), nested up to depth 3; pointer fields are leaves;
    - fields that can't fill the dot are dimmed, but a struct field stays lit if something inside it fits;
    - when the dot expects a pointer, `&paint.rcPaint` entries are added.

    The dot is filled with the whole path as one value (`x := paint.rcPaint.left`, typed `LONG` in `core:sys/windows`).
  - **Indexing:** when the name (or a field) can be indexed, the menu adds `items[i]   T` (`m[key]   V` for maps). Arrays, slices, dynamic arrays, maps and strings qualify (a string element is `u8`), following aliases. Choosing it fills `items[` ● `]`, with the key dot typed from the map's key type (`int` otherwise; the enum for `[Dir]T`), and puts the cursor on the key dot.
  - **Comma-ok:** `v, ok := m[k]` and `v, ok := x.(T)` type `v` as the element / `T` and `ok` as `bool` (`comma_ok_type`).
  - **Range** (case values, loop iterables): `●..<●` / `●..=●` (the operator is one fixed field with no spaces, so `0..<10`), both ends typed like the replaced dot (`make_slot_range`). It is inserted into the value menu right after Number (`insert_range_entry`).
- **Source:** field_access.odin (`append_field_group`, `field_entries`, `picked_type`); index_fill.odin; range_fill.odin; ref_pick.odin `open_pass_as_menu`.

### 28. Loading statements back (round-trip)

- **Trigger:** Opening a file (`doc_from_source`). Line-based, not a full Odin parser.
- **Behavior:**
  - **Parser order** (first match wins):
    1. block comment
    2. `// comment` line
    3. ctrl line (when / #assert / attributes)
    4. **branch line** (`parse_branch_line`)
    5. **loop line** (`parse_loop_line`: also `break`/`continue [label]` and `label: {`)
    6. multi-value `return a, b`
    7. **call statement**: `[defer |return |lhs := |lhs = |lhs: T = ]callee(args)[tail]`, possibly over several lines (callee = `ident(.ident)*`, not a keyword such as `cast`/`proc`/`if`; a `{` tail means a struct literal and a ternary tail is left to expr.odin)
    8. declaration inside a file-scope when
    9. **struct-literal statement**
    10. `return …`
    11. **assignment** `a.b.c op value` for any `ASSIGN_OPS` operator
    12. generic `parse_line`: declarations with editable names and a `decl` operator; else one fixed field

    The branch, loop, assignment and comment parsers reject their result unless `node_text(node) == line` (exact round-trip). The struct-literal parser instead re-renders the node and compares it with the source lines. A rejected line falls through to the next parser. **The call-statement and return parsers do not check**: they rebuild the line in Doodle's spacing. Arguments and values are re-joined with `, `, spaces inside the parentheses go, `return  x` becomes `return x`, and multi-line calls are re-laid out (probe: `fmt.println(1,2)` loads as `fmt.println(1, 2)`).
  - **Open values.** A line ending in an operator with nothing after it (`x :=`, `x +=`, `x: T =`, top-level `X ::`) is parsed with a placeholder. The placeholder then becomes an empty value dot, so unfilled values round-trip (`open_value_line`).
  - **Post-passes:**
    - `attach_call_signature` (types call dots, adds missing and args dots)
    - `attach_lit_hints`
    - `attach_nested_call_hints`
    - `structure_results`
    - `result_list_sync(force)`

    `branch_sync` and `sync_capture_dots` run on the next update.
  - **Branch lines.**
    - `if`, `} else if`, `} else`, `[#partial ]switch`, `case` become keyword fields.
    - A setup's names become editable.
    - A type switch's `v` (or `&v`) becomes an editable name.
    - Case values are split at top-level `, `.
    - `lo..<hi` / `lo ..= hi` split into lo, operator, hi.
    - Index expressions `m[k]` split into `m[`, k, `]`.
    - A trailing `// comment` stays with the line.
    - `case 1: fmt.println("one")` keeps the inline statement as trailing text.
  - **Loop lines.** The whole line must open exactly one block, at its end, and must contain no `//` (a loop line with a trailing comment stays plain text). The text between `for ` and ` {` must be non-empty and have no leading or trailing spaces. Variables, labels, directives, a range's ends and C-style parts are structured: init `name := v`, post `target op v` with an `assign_op` field. Empty C-style parts are allowed: `for ; arr[0] < 10; {`, `for i := 0; ; i += 1 {`. Loaded loop variables are editable names, labels are `label` fields, `for`/`#reverse`/`#unroll`/`break`/`continue` are `kw` fields; a jump's label is plain fixed text.
  - **Struct-literal statements** must have no `//` on the first line; multi-line ones need `T {`/`T{` to end the first line, one `name = value,` per line (trailing comma required, no comments) and `}` alone.
  - **Assignment lines** (`parse_assign_statement`): the target must be identifiers joined by `.` (no indexing), exactly one space on each side of the operator, no `//`.
  - **Loaded forms come back structured and save unchanged:**
    - `if v, ok := m["key"]; ok {`
    - `} else if x > 0 { // positive`
    - `case 'a'..='z', ':':`
    - `#partial switch v in shape {`
    - `switch y := x * 2; y {`
    - `for k, &v in m {`
    - `for i in 0 ..< 10 {`
    - `outer: #reverse for &x, i in arr {`
    - `lbl: {` / `break lbl`
    - `for win32.GetMessageW(&message, nil, 0, 0) > 0 {`

    Pinned by `test_branch_load_round_trip`, `test_loops_load_round_trip`, `test_bl_every_form_round_trip`, `test_accept_every_example_round_trip`.
- **Rules & edge cases:** Some unfilled shapes do not reload structured: unfilled loop parts, `defer ●`, `using ●`, `#assert(●)`, and the Error handling forms. See Open questions.
- **Source:** parse.odin `doc_from_source`, `parse_call_statement`, `emit_expr`, `emit_names_prefix`, `emit_decl_rest`, `open_value_line`, `open_value_to_dot`; branch_parse.odin; loop_parse.odin; struct_lit.odin `parse_lit_statement`, `lit_emit_expr`; field_access.odin `parse_assign_statement`; stmt_layout.odin `parse_comment_line`; result_list.odin `structure_results`.

### 29. HUD hints for statements (exact strings)

The top-right hint line (`ctrl_hint`, remapped by the keymap) shows:

| Where | Hint |
|---|---|
| dot between `switch {` and first case | `A: add a case` |
| dot at the end of a case clause | `A: add a statement or a case` |
| dot right after an if chain | `A: add a statement, else if or else` |
| `if` | `Y: add else if / else / setup, change condition    LT+B: delete` |
| `else if` | `Y: add else if / else / setup, change condition    LT+B: remove branch` |
| `else` | `Y: add else if    LT+B: remove branch` |
| `switch` / `#partial` | `Y: add case / default, #partial, change value    LT+B: delete` / `Y: add case, #partial    LT+B: remove #partial` |
| `case` / a case value | `Y: add value / case    LT+B: delete case` / `Y: change value    LT+B: remove it` |
| inside a setup | `LT+B: remove setup` |
| `for` / label / directive | `Y: loop options    LT+B: delete loop` / `Y: loop options    LT+B: remove label` / `Y: loop options    LT+B: remove it` |
| loop label a jump still needs | `Y: loop options    (a jump needs the label: it stays)` |
| labeled block's label | `Y: options    LT+B: remove label` / (needed) `Y: options    (a jump needs the label: it stays)` |
| 1st / 2nd loop variable | `Y: by reference on/off` / `Y: by reference on/off    LT+B: remove` |
| `assign_op` field | `Y: change operator` |
| `break` / `continue` | `Y: choose label    LT+B: delete` |
| `when` / `else when` / `else` (of a when) | `Y: add else / else when, change condition    LT+B: delete` / `… LT+B: remove branch` / `Y: add else when    LT+B: remove branch` |
| `#assert` | `Y: change condition / add message    LT+B: delete` |

Precedence (`ctrl_hint`): the purple attribute dot, then a `/* */` comment, then `branch_hint`, then `loop_hint`, then the compile-time keywords. Many positions (a plain call, a declaration, a capture dot) show no hint. `rebind_hint` rewrites the `Y: ` / `LT+B: ` / `LT+A: ` prefixes to the user's current bindings, and drops a segment whose action is unbound.

Default bindings (doc 03, keymap.odin `KEYMAP_DEFAULT`): Y = Change, LT+A = Edit (rename / text tools / type menu), LT+B = Delete, RT+X = Refactor menu (`Grab` / `Copy line`, for moving statements, doc 02), RT+A = Copy.

## Invariants & constraints to carry forward

1. **HARD (with a deliberate exception).** A node's field texts concatenate to exactly the line text it stands for (`node_text`). Kinds and hints are metadata beside the text, never part of it. The branch, loop, assignment and comment loaders check `node_text(node) == line` and otherwise leave the line as plain text; the struct-literal loader checks the re-rendered lines. **Exception:** the call-statement and return loaders normalize spacing (`f(a,b)` → `f(a, b)`, `f( 3 )` → `f(3)`), so a hand-written call line may change on load. `test_load_restores_unfilled_argument_dot` pins this ("The filled arguments are kept (in Doodle's spacing)").
2. **HARD for Doodle-formatted code.** Load → `doc_to_source`, and load → `format_doc` → `doc_to_source`, reproduce the input byte for byte (pinned by `test_loops_load_round_trip`, `test_branch_load_round_trip`, `test_bl_every_form_round_trip`, `test_accept_every_example_round_trip`, `test_literals_round_trip`, `test_one_arg_per_line_round_trip`). Every save runs `format_doc` (tab indentation, blank-line rules), so code that isn't Doodle-formatted changes on its first save. Known gap: the blank line that stands for an empty body (`{\n\n}`) is dropped on the second save (§1).
3. **HARD.** Inserting at a green dot adds exactly the new statement (or block), with no stray `●` line (`test_declare_variable_between_statements`, `test_body_dot_inside_nested_block_and_cancel`). Known exception: Multi-line comment (§1). Cancelling (B) leaves the document byte-identical, with the cursor back on the dot (`test_body_dot_inside_nested_block_and_cancel`, `test_empty_function_has_one_dot`).
4. **Design rule (SOFT).** Every inserted form has a default for everything: generated unique names, editable `0`/`1` literals, and dots for what can't be defaulted (typed when the expected type is known). No free-text entry is *required*; only the comment text and an "Other (name it yourself)" callee are meant to be dictated or edited.
5. **HARD.** Optional dots (`args`, `fields`, `res_more`, `ret_more` via `is_optional_dot`; `capture` and every other dot have empty text) never appear in saved text. Neither does the `, ` in front of an unfilled optional dot (`node_source`, `range_source`). Editor-only `●` lines are dropped on save unless one is the only content between an opener (`{` / `case …:`) and a closer; then it is saved as one blank line (`save_source`).
6. **SOFT (best effort).** Dots carry their expected type (`hint` + `hint_pkg`) when it is known. It comes from the signature, declaration, switched value, procedure result, field, map key, or assignment target, and it is kept in sync after edits (`branch_sync`, `sync_typed_decl_value_hint`, `result_list_sync`, `set_assign_op`, `set_assign_target`). Known untyped dots: built-in call arguments, setup values, `defer ●` / `using ●` / Error handling operands, a dot left by LT+B on a switch value or an iterable, and a reloaded `if ● {` condition.
7. **HARD for the menu's Assignment / `op=` leaves.** Their target is picked from existing, assignable names only (not `::` declarations, not out-of-scope names), and a line whose target is never picked is removed (`ref_candidates` `assigning` filter, `assign_pick_drop`; pinned by `test_assignment_picks_a_declared_name`, `test_assignment_cancel_takes_the_line_away`). Not covered: the setup menu's Assignment (generated name), Implicit Context (`context.<field>`), and loaded assignment lines.
8. **HARD.** Statement-menu content depends on position (`branch_extend_body_menu`, `loop_extend_body_menu`; pinned by `test_branch_else_from_green_dot`, `test_branch_case_dots_in_switch_body`, `test_fix_fallthrough_positions`, `test_bl_statement_menu_groups`, `test_loops_jumps`):
   - Else if/Else only after an `if` chain, and Else only once;
   - only Case/Default between `switch {` and the first case;
   - Default case only once;
   - Fallthrough only at the end of a non-last clause of a non-type switch;
   - labeled jumps only for labels in scope; Continue never for block labels.
9. **HARD.** Y option menus refuse dimmed entries (menu stays open; `branch_fill`, `loop_option_choose`, `ctrl_menu_choose` each return early on `e.dim`). **Deliberately advisory:** dims in fill menus still insert (heat.odin `heat_is_action`: "Leaves grayed by type fitting still work when picked"). This includes the Break/Continue scope dims and the Pass as / Assign to dims, which share the same path.
10. **HARD.** *New* labels are unique per procedure (`fresh_name` → `proc_has_label`; `test_fix_unique_labels`). Renaming a label carries its jumps (`label_rename_jumps`). Removing a label rewrites its jumps to bare ones, and is refused when that would change their target (`label_removal_blocked`; `test_fix_remove_used_label`, `test_accept_remove_used_label`). A manual rename to a duplicate label is not prevented.
11. **HARD.** Names introduced by setups, type switches and loops are typed and offered by Reference only inside their construct (`branch_name_hidden`, `loop_name_visible`; `test_branch_type_switch_variable_scope`, `test_loops_variable_types_and_scope`, `test_fix_else_if_setup`). Locals of one case clause are not offered in a sibling clause (ref_scope.odin).
12. **HARD.** Loop headers, if/switch headers, case labels, compound assignments (`op=` other than `=`), compound values (ternary, `cast(T)f(a)`) and `#assert` are saved on one line however long (the loader reads them that way; `needs_break`). Long calls and long struct literals break one item per row, and calls/literals loaded broken stay broken.
13. **HARD.** A capture dot exists exactly on bare call statements inside a block whose procedure is known to return ≥1 value (`wants_capture_dot`; `test_capture_*`). Syncs that move field indexes are never run while a menu, pick, refill, Declare-as, call change, LT+A replacement or green-dot insert holds a field index (`sync_capture_dots`, `result_list_sync`, `branch_sync` guards).
14. **SOFT.** A known callee's name is fixed text (change it with Y, which re-derives the argument dots). Only "Other (name it yourself)" import calls have an editable callee.
15. **SOFT.** After an insert, the cursor goes where the user most likely acts next. Mechanically, the generic path (`menu_select`) puts it on the first name or dot of the new line, and branching uses `focus_first_dot`:
    - the new name (declarations, most loops, labeled forms)
    - the first dot (if/switch, calls, Return/Defer/Using, `#assert`, Error handling, For (condition))
    - the target, once an Assignment pick finishes
    - the comment text
    - the next `●` / next green dot (blank line)
    - the line itself when it has no name or dot (`for {`, `{`, `break`)
16. **HARD (by design).** Menus with more than 12 non-pinned entries are displayed alphabetically; smaller menus keep authored order (`make_view`). The root statement menu is kept at ≤ 12 on purpose, except when 3–4 context extras apply.

## Data model & formats

- **Node / Field.** A line is a `Node` with an ordered list of `Field`s, each with:
  - `text`
  - `editable` (a name or literal the user can rename)
  - `slot` (a dot, empty text)
  - `kind`
  - `hint` (expected type text, not owned or interned)
  - `hint_pkg` (import path the hint is written in)

  Multi-line calls/literals are still one node (doc 01).
- **Field kinds in this area:**
  - **dots:** `body` (statement slot), `value`, `type`, `args` (optional extra argument), `setup`, `variant`, `fields` (struct-literal add-field), `capture`, `res_more`, `ret_more`, `params`
  - **non-dots:** `decl` (`:=`, `: `), `assign_op`, `brkw` (if/else/switch/#partial/case keywords), `kw` (for/#reverse/#unroll/break/continue/when/#assert), `label`, `lit` (`{`/`}` of a literal), `litkey`, `comment`, `string`

  Hint sentinels:
  - on a literal's `{`: hint `"break"` (keep one field per row); hint_pkg `"aligned"`
  - on a call's `(`: `"argrows:N"`
  - on a `, `: `"rowend"`
- **Menu Entry** fields used here:
  - `label`, `children`, `dim`, `pinned`, `heat_key`
  - `fill` — a marker string naming the action
  - `call_name` / `call_pkg` — the callee, option id, or `"ni fi"` target for loop options
  - `ret` / `ret_pkg` — return type or field type

  Fill markers:
  - statements: `__stmt_decl__`, `__stmt_typed__`, `__stmt_zero__`, `__stmt_multi__`, `__stmt_assign__`, `__stmt_assign_op__`, `__stmt_ctx_assign__`
  - calls: `__call_this_pkg__`, `__call_import__`, `__call_import_proc__`
  - branching: `__br_if__`, `__br_ifelse__`, `__br_ifsetup__`, `__br_switch__`, `__br_switch_bool__`, `__br_partial__`, `__br_typeswitch__`, `__br_when__`, `__br_elseif__`, `__br_else__`, `__br_case__`, `__br_default__`, `__br_setup__`, `__br_variant__`, `__br_opt__`
  - loops: `__loop_for__`, `__loop_forinf__`, `__loop_cstyle__`, `__loop_forin__`, `__loop_forin2__`, `__loop_range__`, `__loop_rangeincl__`, `__loop_byref__`, `__loop_reverse__`, `__loop_unroll__`, `__loop_labeled__`, `__loop_iter_range__`, `__loop_jump__`, `__loop_opt__`
  - jumps, errors, scopes: `__jmp_return__`, `__jmp_break__`, `__jmp_continue__`, `__jmp_fallthrough__`, `__jmp_defer__`, `__err_orreturn__`, `__err_orelse__`, `__err_iferr__`, `__scope_block__`, `__scope_using__`, `__scope_label__`
  - layout: `__stmt_comment__`, `__stmt_blank__`, `__stmt_block_comment__`, `__arg_row__`
  - compile-time: `__ct_assert__` (and `__br_when__`); option menus `__ctrl_menu__`
  - values: `__lit_type__`, `__lit_field__`, `__val_range__`, `__index__`, `__ref_as__`, `__decl_form__`
  - legacy, unused by the menus: `__stmt_call__`
- **Parsed structures** (read on demand from fields, never stored):
  - `Br_Line {kind If/Else_If/Else/Switch/Case; kw; partial; setup_a,b; expr_a,b; tvar; tvar_ref; open; default_case}`
  - `Loop_Hdr {label; label_sep; directive; kw; open; form Infinite/Cond/In/CStyle; var1,var2; ref1,ref2; vsep; in_sep; semi1,2; cond/iter/init/post ranges}`
  - `Loop_Text` (the same, from text)
  - `Call_Sig {req; variadic; params []Param{name,type,optional,variadic}; ret ("" none, "?" unknown); pkg; known}`
  - `Iter_Kind {Unknown, None, Array, Slice, Dynamic, Map, String, Range}`
  - `Jump_Scope {in_loop; in_switch; labels []{name,is_loop}}`
  - `Switch_Ctx {s; in_clause; at_end; final}`
- **Transient App state** for multi-step statement edits: these flags let B undo exactly.
  - `body_insert_active/ni/reused/blank`
  - `refill_active/ni/fi/saved` (original fields kept for B)
  - `ref_pick_active`, `ref_pass_active`, `ref_ni/fi`
  - `assign_pick_new`
  - `change_call/ni/fi`
  - `decl_form_active/decl_ni/fi`
  - `slot_ni/fi`
  - `notice` (one-shot status text)
- **Generated tables** (doc 07): `CORE_PROCS {path,file,block,name,params,req,variadic,ret}`, `CORE_TYPES`, `CORE_FIELDS`, `CORE_CONSTS`, plus the hand-written `BUILTIN_PROCS {name, req, variadic, ret}`.
- **Persisted formats:** none specific to this area. Statements live only in the `.odin` file; menu wear goes to `doodle_heat.tsv` (doc 03 F14).

## Tests that pin this behavior

| Test (file) | Asserts |
|---|---|
| `test_body_dots_positions`, `test_body_dots_are_cursor_stops` (body_dots_test) | dot positions inside bodies (not at top level); `}` isn't a stop |
| `test_declare_variable_between_statements`, `test_body_dot_inside_nested_block_and_cancel`, `test_empty_function_has_one_dot`, `test_blank_lines_between_statements_get_one_dot` | one line added, indentation, no stray `●`; cancel is a no-op; blank-line handling |
| `test_bl_statement_menu_groups` (branch_loop_integration_test), `test_branch_menu_has_all_forms` | exact Branching/Loops leaf lists; Break dimmed outside loops; no Fallthrough outside cases |
| `test_branch_if_chain`, `test_branch_else_from_green_dot` (branch_test) | Y options, Add else dimmed once present, else-if placement, LT+B per branch, dot menu `Else if \| Else \| Declarations …` |
| `test_branch_if_with_setup_and_index`, `test_branch_switch_setup_and_value` | setup menu labels, `m[key]` index, setup scope/types, remove/add setup, Change value + B restore |
| `test_branch_switch_value_cases`, `test_branch_enum_partial_switch`, `test_branch_case_dots_in_switch_body`, `test_branch_handmade_switch` | case typing, Range, used values dimmed, default once, `case :` dot, cases-only menu |
| `test_branch_type_switch`, `test_branch_type_switch_variable_scope`, `test_fix_by_reference_type_switch` | variants menu, per-clause variable type, by reference |
| `test_fix_fallthrough_positions`, `test_fix_ltb_condition_keeps_construct`, `test_fix_else_if_setup` (branch_loop_fixes_test) | fallthrough rule; LT+B blanks conditions; else-if setup scope |
| `test_loops_build_every_form`, `test_loops_load_round_trip`, `test_loops_options` (loops_test) | every loop shape's text; reload structure; each option and LT+B |
| `test_loops_variable_types_and_scope`, `test_loops_iterable_pass_as`, `test_loops_iterable_respects_modifiers`, `test_loops_iterable_range_and_refill` | variable types/scope; iterability gray-outs; Range; refill + B |
| `test_loops_jumps`, `test_fix_unique_labels`, `test_fix_remove_used_label`, `test_accept_remove_used_label` | labeled jumps in scope; label uniqueness; refusing a needed label |
| `test_fix_unroll_constants`, `test_fix_assign_ops`, `test_loops_compound_assignment` | #unroll constant rules; operator dims by type |
| `test_assignment_picks_a_declared_name`, `test_assignment_cancel_takes_the_line_away` (assign_pick_test) | target pick starts at once, candidates exclude constants/procs, value typed from target, B removes the line |
| `test_param_arity`, `test_call_arity_sources`, `test_messageboxw_call_has_four_arg_dots`, `test_println_keeps_offering_arg_dots`, `test_printf_has_format_dot_then_green_dot` (calls_test) | signature parsing; dot counts; args dot regrows; unfilled args not saved |
| `test_load_restores_unfilled_argument_dot`, `test_one_arg_per_line_round_trip` (parse_calls_test) | calls reload with dots in place; one-per-row round-trip |
| `test_layout_arg_rows` (stmt_layout_test) | Join with previous row / Own row availability and resulting text |
| `test_capture_*` (capture_test) | capture dot presence rules, result capture, multi-result names, uncapture |
| `test_result_list_from_menus`, `test_return_values_from_menus`, `test_result_list_loader`, `test_delete_bare_return` (result_list_test) | result-list parentheses, typed return dots, LT+B rules |
| `test_build_window_class`, `test_literal_edit_and_delete`, `test_literals_round_trip` (struct_lit_test) | field list labels, alignment, LT+B/Y on fields, which literals load structured |
| `test_build_wm_paint_statements`, `test_field_menu_gray_out`, `test_assignment_to_a_field` (field_access_test) | Field of menus, gray-out, `&path` |
| `test_layout_comment_in_body`, `test_layout_blank_lines_in_body` | Comment/Blank line in bodies |
| `test_error_or_return_inserts_or_return`, `test_error_or_else_inserts_or_else`, `test_error_if_err_inserts_multiline` (model_test) | Error handling leaves insert their text (shallow) |
| `test_accept_*` (branch_loop_acceptance_test) | one test per table row, each built by pad and `odin check`ed when `DOODLE_ODIN` is set |
| `test_handmade_accept_build_program` (handmade_acceptance_test) | most of the Handmade Hero day-3 Win32 program built by pad (window class literal, calls, Reference / Pass as / Field of, the WM_PAINT statements); it leaves out the `switch message`, the ternary, the conversion and comments inside procedures |
| `test_layout_handmade_from_empty_project` (stmt_layout_test) | the complete program from an empty project: `switch message` with `case win32.WM_PAINT:` …, `CreateWindowExW` with grouped rows, `for win32.GetMessageW(&message, nil, 0, 0) > 0 {`, if/else with `// TODO logging` comments; saved byte-exact |
| `test_block_comment_in_a_function` (block_comment_test) | Layout ▸ Multi-line comment in a body, saved at the body's indentation |

Testing style: tests drive the model through `update(app, Input{confirm/cancel/up/…})` and menu picks by label, exactly as the controller does (doc 11).

## Carrying this to Rust

**(a) Transfers unchanged (language-agnostic):**
- Green dots between statements, and the editor-only `●` line in empty blocks. The temp-line insert/cancel protocol, with byte-identical cancel.
- The categorized statement menu, plus position-dependent extras that are prepended or replace the menu (else-branches after an `if`, arms inside a `match`).
- Generated names with the cursor on them, typed dots everywhere, and the hint label on each dot.
- Y as "change this part", with a per-construct options menu where impossible options stay visible but dimmed. LT+B as "remove this part", scaled to what is highlighted.
- "Pick an existing name" for assignment targets, Pass-as transforms, and "Field of" chains.
- Capture dots on result-producing call statements. Growing lists (arguments, struct fields, return/tuple items) with optional "add another" dots that are never saved.
- Exact round-trip of loaded code (Doodle relaxes this for call lines, which it normalizes; a CST makes it exact everywhere), and one-item-per-row layout for long calls/literals, including grouped rows.

**(b) Odin pieces → Rust analogs:**

| Odin (this area) | Rust |
|---|---|
| `x := v`, `x: T = v`, `x: T` | `let x = v;`, `let x: T = v;`. Odin's `x: T` is *zero-initialized*; Rust has no implicit zero value: use `let x = T::default();` (needs `Default`) or `let x: T;` (deferred init, which the compiler requires to be assigned on every path before use). "Declare as" adds `let mut`, `const X: T = v;` (type required; allowed inside fn bodies), `static` |
| `a, b := f()` / Multiple | `let (a, b) = f();` (tuple pattern) |
| Assignment / `op=` | requires `let mut` (or `&mut` place): extend the target pick (see (c)) |
| Odin operator list | Rust: `= += -= *= /= %= &= \|= ^= <<= >>=` (no `%%=`, `&~=`, `&&=`, `\|\|=`; xor is `^=`). Fit by trait (`AddAssign<Rhs>` …), e.g. `String += &str` |
| Calls: Internal / From import / Built-in | Calls: this crate's fns, `use`d paths / external crates, **macros** (`println!`, `vec!`, `assert!`, `format!` …), plus **Method on ▸** (receiver first, then its methods incl. trait methods with auto-`use`) |
| `if` / `else if` / `else`, If with setup | `if` / `else if` / `else`; setup → `if let Some(v) = m.get(&k) {`, `let … else {`; `if cfg!(…)` |
| `switch` / `case` / `#partial` / `case:` | `match x { pat => {}, … }`; `case a, b` → `a \| b`; ranges `0..=9` (and exclusive `0..9` patterns, stable since Rust 1.80); `case:` → `_ =>`. Rust `match` must always be exhaustive, so `#partial` has no toggle: offer "add `_ => {}` arm" / "add missing arms" instead. Guards `if cond` as an arm option. "Switch (conditions)" → `match () { _ if a => …, _ => … }` is unidiomatic: map it to an `if / else if` chain |
| type switch over a union | `match` on an enum with variant patterns (`Shape::Circle(c) =>`); variants menu from the enum; "Add missing arms" via rust-analyzer |
| `fallthrough` | none (offer merging patterns with `\|`) |
| for (condition) / infinite / C-style | `while cond {`, `loop {`; C-style has no analog (offer `for i in 0..n` / `.step_by()`) |
| for-in shapes, `&x`, `#reverse` | `for x in &v`, `for x in v.iter_mut()` (or `for x in &mut v`), `for (i, x) in v.iter().enumerate()` (note: Rust puts the index *first*; Odin's `for x, i in v` puts it second), `for (k, v) in &m`, `for c in s.chars()`, `for i in 0..n` / `0..=n`, `.rev()` (works on ranges too, unlike Odin's `#reverse` as Doodle models it) |
| `#unroll` | no direct analog (drop, or offer `seq!`-style macro if a crate is present) |
| labels `outer:` / `break outer` | `'outer: loop {` / `break 'outer` / `continue 'outer`; labeled blocks `'a: { … break 'a value; }` |
| `defer` | no keyword: scope guard (`scopeguard::defer!` if in Cargo.toml) or `drop(x)` |
| `or_return` | `?` (needs fn returning `Result`/`Option`: dim with reason, offer "change return type") |
| `or_else` | `.unwrap_or(v)` / `.unwrap_or_else(\|\| …)` / `.ok_or(e)?` |
| or_break / or_continue (Odin, not offered) | `let Some(x) = it else { break };` |
| `when` / `#assert` | `#[cfg(…)]` on statements, `if cfg!(…)`; `const _: () = assert!(…);` |
| struct literal `T{a = 1}` | `T { a: 1, ..Default::default() }`; field shorthand `T { a }`; functional update `..other` as a menu entry |
| `m[k]` comma-ok | `m.get(&k)` → `Option<&V>`; `m[&k]` panics (offer both, labelled) |
| multi-result `-> (A, B)` | tuple return; capture with tuple pattern; `return (a, b)` / tail expression |
| `using` | Odin's statement `using x` (a struct value's fields usable unqualified) has **no Rust equivalent**. Only the namespace case maps: `use path::*;` or `use Enum::*;` inside a fn body |

**(c) Rust concepts this area needs that Odin lacks:**
- **Mutability and borrows.**
  - The target pick should list only `mut` bindings and `&mut` places. A non-`mut` local appears dimmed with the reason "not mutable" and an option **Make `x` mutable** (adds `mut` to its `let`).
  - Pass-as becomes `x`, `&x`, `&mut x`, `x.clone()`, `*x`, `x.into()`, `T::from(x)`, `x as T`, each dimmed by expected type.
  - A **moved** value is dimmed with "moved at line N". The reliable source is `cargo check` (rustc borrowck) diagnostics; rust-analyzer's own borrow checking is partial.
- **Statements vs. expressions.** Blocks have a *tail expression* (no `;`), which is the block's value.
  - Model a distinct "tail" slot at the end of each block, offering "Return value of block" and "Make statement (add `;`)".
  - `return x;` vs. tail `x` is a Y option on return.
  - `;` rendering: every non-block statement gets `;`; block-like expressions (`if`/`match`/`loop`/`for`/`while`/`{}`) as statements don't.
- **Patterns.** `let`, `if let`, `while let`, `for`, `match` all take patterns. A pattern dot needs its own menu: binding, `_`, tuple, struct `T { a, .. }`, enum variant with sub-dots, literal, range, `ref`/`mut` binding, `@` binding, slice patterns. This replaces Odin's simple loop variables/setup names.
- **Option/Result flow.** The `?` operator, `match` on `Ok/Err`, `if let Ok(v)`, `let … else`: an "Error handling" group that is actually valid Rust, driven by the enclosing fn's return type.
- **Closures.** `let f = |x| …;`, `move` closures, and closures as call arguments (`.map(|x| ●)`): a value-menu entry whose body is a dot or a block.
- **Macros.** Macro calls look like calls with a format-string first argument. `{}` placeholders could drive argument dots (count placeholders → dots).
- **Method chains and iterators.** `v.iter().filter(…).map(…).collect::<Vec<_>>()`: a chain is a sequence of method calls, each picked from the receiver type's methods. Turbofish appears as a type dot when inference needs it.
- **Modules and visibility.** "Internal procedure" becomes items reachable from the current module (`crate::…`, `super::…`, re-exports, `pub` visibility). Picking an item not in scope adds a `use`.
- **async.** `.await` as a Pass-as transform on futures; `async {}` blocks in Scope and blocks.
- **unsafe.** An `unsafe { }` block in Scope and blocks, required when calling `unsafe fn`: dim with reason or auto-wrap.

**(d) Implementation advice:**
- **Don't port the line-based parser.** Use a lossless syntax tree (`ra_ap_syntax`/rowan, or tree-sitter-rust) so invariant 1 (exact round-trip) holds by construction. Doodle's "fields" become a projection of CST tokens/nodes. Keep the *editing* model line/row-oriented for the controller, but derive it from the CST.
- **Use rust-analyzer** (as a library via `ra_ap_*` crates, or over LSP) as the type oracle:
  - expected types for dots: signature help, and the expected-type data behind completions;
  - binding types (inlay hints/hover);
  - iterator `Item` types;
  - in-scope names for Reference (scope resolution, not text scanning);
  - methods/fields for "Method on"/"Field of" (completions);
  - missing match arms, and valid labels/loops for `break`/`continue`.

  Use `cargo check --message-format=json` for diagnostics after edits.
- **Keep Doodle's best-effort fallback.** When the oracle doesn't know, the type is `Unknown` and nothing is dimmed. Doodle makes Y-option dims hard (impossible structural edits) and fill dims advisory on purpose (type inference is best-effort, so a wrong gray must never block the user). Keep that split unless the Rust oracle is authoritative.
- **Don't copy Doodle's unfilled-save gaps.** In Doodle some unfilled shapes save as text that reloads without dots (`for  {`, `defer`, `using`, ` or_return`) or that Odin rejects. With a CST, keep unfilled holes representable on reload (e.g. a recognizable placeholder such as `todo!()` / `_` in value position, or a sidecar), or refuse to save them.
- **Keep the multi-step edit protocol explicit** (temp line; refill with saved original; pick-then-pass-as) so every B is an exact undo. Never run "sync" passes that renumber fields while a menu or pick holds a position.

## Open questions & known gaps

- **Unfilled loop parts don't reload structured** (verified by loading at baseline):
  - `for  {` (an unfilled while condition)
  - `for item in  {` (unfilled iterable)
  - `for i := 0; i < ; i += 1 {` (unfilled C-style condition)

  These load as plain text: `loop_parse.odin` rejects an empty or space-padded middle. The same holds for `outer: for item in  {`. `for i in 0..< {` loads as a loop but the missing high end gets **no dot** (`iter_into` → `expr_into("")` appends nothing). Re-verified at baseline with a probe test run in a copy of src/model outside the repo (menu-built loops of every shape saved unfilled, then reloaded). No repo test pins this. A loop saved before its dots are filled therefore loses its structure on reopen.
  - Also reloading as plain text with no dot (same probe): `defer ●` → `defer`, `using ●` → `using`, `#assert(●, ○)` → `#assert()`, `● or_return` → ` or_return`, `● or_else ●` → ` or_else`.
  - By contrast `if  {`, `switch  {`, `case :` (value or type switch), `x +=`, `y :=`, `x: T =`, top-level `X ::`, bare `return` and empty call arguments `f(, x)` reload with their dots.
- **Lost hints on reload:** confirmed by probe. A reloaded `if ● {` condition dot has no `bool` hint (`emit_expr("")` makes an untyped dot; only case dots are re-synced by `branch_sync`). Consequence: its value menu grays nothing (`open_slot_menu` runs `apply_fit_dims` only when `hint != ""`). Y on `if` ▸ Change condition swaps in a fresh `bool` dot. LT+B on the already-empty dot does nothing, but once the condition is filled, LT+B turns it back into a `bool` dot. The same holds for a reloaded `x: T =` value dot (no hint unless the type is changed with LT+A, §3).
- **Advisory dims:** resolved, deliberate. In fill menus dimmed entries still insert, and heat.odin `heat_is_action` and docs/EDITOR_MODEL.md §3.7 state this on purpose for type-fit dims. Scope dims (Break/Continue outside loops) go through the same path; whether those were meant to be advisory too is not stated.
- **Alphabetical sort:** resolved, intended as a general rule (`make_view` comment). The author keeps the root statement menu at ≤ 12 on purpose (`layout_extend_body_menu`: "One group, so the menu stays short enough to keep its order"). The consequences are still worth knowing: the Assignment group (16 entries) and the Operator menu (15) show in byte order (`Assignment` sits between `>>=` and `Implicit Context`), and the root reorders when an `if` chain ends a case clause (3–4 extras).
- **Error handling group is weak:**
  - `● or_else ●` as a standalone statement and `● or_return` with a non-call operand don't compile;
  - `if err != nil` is fixed text, not a structured `if` (no Y options, no else; LT+B removes it as a block). On reload it *does* become a structured `if` (probe: both `if err != nil {` and the unfilled `if  != nil {` load with an `if` keyword field, the latter as `if ● != nil {`), so the same text behaves differently before and after a save;
  - its operand dots are untyped, and unfilled forms save as invalid text (§22);
  - no `or_break` / `or_continue`.

  No comment or test states the intended scope of this group. `make_error_statement` is the only code. Only shallow tests cover it, checking that the text appears (model_test.odin `test_error_or_return_inserts_or_return`, `test_error_or_else_inserts_or_else`, `test_error_if_err_inserts_multiline`). It reads like an early placeholder that the later structured-code work (branch.odin, loops.odin) never revisited (inference, unverified).
- **Inconsistent defaults:**
  - Labeled block uses a generated `adjective_animal` label while Labeled for uses `outer`;
  - "Multiple (:=)" uses a non-`decl` ` := `, so there is no Declare-as;
  - the setup menu's "Assignment" assigns to a *generated* name, unlike the main Assignment, which forces a pick.
- **Indentation quirks** (verified by probe):
  - `make_body_statement` / `make_multi_decl` / `make_call_*` / `make_zero_decl` / `make_jump_statement` (Return, Fallthrough, Defer) add the trailing `●` line with a hard-coded 4-space indent. It is only visible when inserting from a `●` line, because at a green dot that line is removed;
  - When / Block / Labeled block / if err != nil indent their body with `indent + "    "` even in tab-indented files (`\t    ●`);
  - a line starting with an empty dot reads as one space deeper, and that extra space propagates to neighbours inserted next to it (§1).

  All of this is harmless for the saved file: `file_text` runs `format_doc`, which rewrites every line's indentation with tabs, so mixed indentation exists only in the editor until the next save (or IDE menu ▸ Format). It looks unintended (the loop and branch code uses `indent_unit` correctly) but has no visible effect on disk.
- **Empty bodies lose their blank line on the second save:** a menu-built empty block saves as `{\n\n}`. Reloaded and saved again, `format_doc` drops the blank line: `{\n}` (probe). This breaks byte-identical re-saves of Doodle's own output for empty blocks.
- **Stray line after Multi-line comment:** inserted at a green dot, it leaves a stray `●` line after `*/` (block comments have no braces, so `body_insert_done` doesn't find it). Confirmed by probe; it is editor-only and dropped on save.
- **Internal procedure misses procedures with a calling convention:** `collect_proc_names` matches the text ` :: proc(`, so `cb :: proc "system" (` is not offered as a call target (§6).
- **Cursor after inserts:** probe-verified for Block (stays on the `{` line), Blank line from a dot (the green dot after the blank line), Blank line from a `●` line (the new `●`), Switch (conditions) (the `case` dot), `#assert` (the condition). No repo test pins these positions.
- **Legacy code:** `make_loop_statement` (model.odin) and the `__stmt_call__` fill are unused by the menus (only a test calls the former).
- **Data-flow checks Odin doesn't need:** `#unroll` constant checks and type inference are text-based approximations (`unroll_const_expr` treats `f(…)` as non-constant except conversions to basic types). A Rust port should replace them with real analysis.

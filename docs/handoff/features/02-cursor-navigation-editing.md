# 02 — Cursor, navigation, selection and the generic edit actions

> Odin sources: src/model/selection.odin, src/model/row_nav.odin, src/model/body_dots.odin, src/model/attr_dots.odin,
> src/model/capture.odin, src/model/block_delete.odin, src/model/grab.odin, src/model/change.odin,
> src/model/model.odin (update, editor_* procs, delete_selected, edit_selected, menu_cancel), src/model/keymap.odin,
> src/model/expr.odin (expr_delete, unit_chain), src/model/stmt_layout.odin (layout_delete), src/model/serialize.odin
> (copy_selection_source), src/platform/platform.odin (d-pad repeat), src/app/main.odin (input wiring),
> src/app/editor_view.odin (highlight / grab drawing and hints). Baseline: Doodle @ 34a2ad1.

## Purpose

Doodle has no text caret. The cursor sits on a *stop*: either an insertion dot between lines or one *leaf* (a name,
a placeholder dot, a keyword, a call's name, an argument) of a line. The plain d-pad moves between stops. Holding RT
walks a small syntax tree (procedure, then statement, then the parts of the statement) so you can select bigger
pieces. A handful of generic actions then work on whatever is highlighted. Delete, Change, Edit, Refactor (Grab / Copy line)
and Copy each pick the right behaviour for the kind of part under the cursor. This is what makes a whole program
editable with eight buttons and two triggers: the user never positions a character, only picks *which part* and
*which action*, and every action knows how to keep the code well-formed. B always backs out, and almost every
menu-driven change can be cancelled back to exactly what was there before (the exceptions, the Number keypad and
the type menu opened by Declare as > typed, are listed in §20).

This doc covers how the cursor moves and what the generic actions do. It does not cover the contents of the menus
they open. Those are in 04 (file-scope constructs), 05 (statements), 06 (type-driven menus) and 08 (text entry/voice).
The button layout and HUD are in 03.

## Features

Vocabulary used below (paraphrasing doc 01): the document is a list of **lines** (`Node`), each a list of
**fields** (`Field{text, editable, slot, kind, hint, hint_pkg}`) whose texts concatenate to the source line. A
**slot** field has empty text and is drawn as a dot. A field is **selectable** when it is editable, a slot, or has one
of the kinds `decl` (`:=`, `:`, `::`), `kw` (when, #assert, attributes, directives, calling conventions), `brkw`
(if/else/switch/case/#partial), `assign_op` (` = `, ` += `), `conv` (`cast(T)`), `import_path`, `comment_mark`
(`/*`, `*/`). (selection.odin `selectable`.) Dot colours, for orientation (src/app/main.odin `slot_dot_color`,
src/app/editor_view.odin `draw_editor`):
- **green**: an insertion point between lines (file scope, or inside a body, drawn smaller), and the small green
  in-line dots of kind `body` (the empty `●` statement line), `args` (the "add argument" dot of a variadic call) and
  `fields` (a struct literal's "add field" dot);
- **purple** (a filled circle a bit bigger than a green dot, `COL_ATTR_DOT`, drawn right of the green dot): the
  attributes of the procedure below;
- **pink**, steady and smaller: capture the call's result (kind `capture`);
- **orange**: an unfilled `value` slot, another return value (`ret_more`), and any slot kind without its own colour
  (`""`, `setup`, ...);
- **blue**: an unfilled `type` slot, another result type (`res_more`), a type-switch variant (`variant`);
- **violet**: the `params` dot of a procedure header ("Add parameter").

### 1. The cursor and its stops

- **Trigger**: always present in the editor (`App.state == .Editor`).
- **Behavior**: the cursor is four fields on `App` (model.odin):
  - `editor_line`: a line index, or `len(nodes)` for the bottom green dot.
  - `editor_dot`: true when the cursor is on the dot *before* `editor_line` rather than on the line.
  - `editor_attr`: true (together with `editor_dot`) when that dot is the purple attribute dot, not the green one.
  - `editor_field`: on a line, the index of the highlighted **leaf** among `line_leaves(line)`. It is 0 on dots.

  `on_dot` is `editor_dot || editor_line >= len(nodes)`. The set of stops is recomputed from the document on every
  press (`editor_stops`). Going through boundaries `i = 0 ..= n`, it emits:
  1. a green dot before line `i` if `dot_points[i]` (file scope) or `body_points[i]` (inside a body);
  2. a purple dot before line `i` if `attr_points[i]`;
  3. line `i` itself if it has at least one leaf (`selectable_in_node > 0`).

  The order key is `stop_key = line*3 + (dot ? (attr ? 1 : 0) : 2)`: green dot, then purple dot, then the line.
  These are never stops: blank lines, lines that are only `}`, and any line with no selectable field. A
  `} else {` line *is* a stop (its `else` keyword is a `brkw` leaf). Fixed text is never a leaf either: in a loaded
  `return v` the `v` is fixed text, so the line's only leaf is its extra-value dot (`ret_more`). Probe at baseline
  (re-run for this doc): loaded `foo :: proc(a: int, b: int) -> int {` has the leaves `foo | a | b | int | ●res_more`
  (the parameter types are fixed text; the result type is a leaf); loaded `x := a + b` has `x | := | a + b` (one
  `Value`); loaded `y := foo(1, 2)` has `y | := | foo | 1 | 2`.
- **Rules & edge cases**: after any structural change the cursor is snapped back onto a stop by `normalize_cursor`.
  The order of checks is:
  1. a negative line becomes 0; past the end goes to the bottom dot;
  2. not on a dot, and the line has leaves: keep the cursor and clamp the field;
  3. a purple dot that is still there keeps the cursor;
  4. a green or body dot before this line takes the cursor (this can move the cursor *up* onto the dot above a line
     that has no leaves);
  5. otherwise `editor_dot` is cleared and the cursor moves to the next stop down (`editor_move_line(+1)`); the
     bottom dot always exists, so there is always one.

  `clamp_field` clamps `editor_field` to `[0, leaves-1]`, or 0 on dots.
- **Source**: model.odin `editor_stops`, `stop_key`, `cursor_stop_key`, `normalize_cursor`, `clamp_field`, `on_dot`,
  `focus_dot`, `focus_dot_at`, `focus_line`; selection.odin `focus_field_index`, `focus_kth_selectable`.

### 2. D-pad Up / Down: between stops

- **Trigger**: plain d-pad Up/Down in the editor. LT+Up/LT+Down do the same because those slots are unbound by default
  (see §6).
- **Behavior**:
  - If the line is shown broken over several rows, row navigation comes first (§4).
  - Otherwise the cursor goes to the previous or next entry of `editor_stops` by `stop_key`, and `editor_dot` and
    `editor_attr` are set from the stop.
  - `editor_field` is **kept as a leaf index** and clamped to the new line. It is not a visual column.
  - Landing on a dot resets the field to 0. In practice the "column" survives only between two line stops with no
    dot between them, which is rare because bodies have a dot between every pair of statements.
  - Probe at baseline (re-run): in
    ```odin
    if x > 0 {
        x = 2
    } else {
        y := foo2(x)
    }
    ```
    from leaf 3 (`x`) of `y := foo2(x)`, Up goes to the body dot above `y := ...`, then to the `} else {` line (on
    its only leaf, `else`: the field is reset by the dot), then to the body dot at the end of the if branch (before
    `} else {`), then to `x = 2` at leaf 0.
- **Rules & edge cases**: at the top dot (Up) or bottom dot (Down) nothing happens; there is no wrap. Both Up and Down
  in one frame are processed in that order. The walk order for a small file is pinned by
  `test_dots_reachable_between_constructs`:

  ```
  ● (top)  package main  ● (between)  ◆ (purple)  main :: proc() {  ●-line  ● (bottom)
  ```

  The `}` line is skipped. There is no body dot next to the menu-built empty `●` statement line.
- **Source**: model.odin `update` (the `for dir in [-1,+1]` loop), `editor_move_line`.

### 3. D-pad Left / Right: the leaves of a line

- **Trigger**: plain d-pad Left/Right while on a line. On any dot Left and Right do nothing.
- **Behavior**:
  - Right goes to the next leaf. It stops at the last leaf and does not wrap.
  - Left goes to the previous leaf in the same visual row. From the first leaf of a row it **wraps to the last
    slot dot of that row**, or to the row's last leaf if the row has no dot.
  - On a one-row line, Left on the first part therefore jumps to the line's last dot, e.g. the trailing "add
    argument" dot of `fmt.println("hi", ●)` (`test_row_nav_left_wraps_to_end_dot`). A further Left walks back
    normally. With no dot on the row it jumps to the last leaf (probe: Left on `y` of `y := foo2(x)` lands on `x`).
    "Last dot" means the last leaf of the row whose `leaf_primary_field` is a slot. With a capture dot present
    (leaf 0), Left from the callee first lands on the capture dot, and Left from the capture dot wraps to the last
    dot; if the capture dot is the row's only dot, Left on it stays put.
  - Left and Right are both read in one frame (Left first); on a dot both do nothing.
  - Leaves are a depth-first flattening of the line's unit tree (§12). The capture dot, when present, is always
    leaf 0. Example from selection.odin, pinned by `test_dpad_highlights_name_and_every_argument`:

    ```
    windows.MessageBoxW(nil, windows.L("Testing"), windows.L("Testing again"), )
    read, then Right, 8 times:  MessageBoxW | nil | L | "Testing" | L | "Testing again" | ● | ●
    ```

    `windows.` is not a leaf. A whole string literal `"Testing"` is one leaf (quotes and text). The line has only
    **one** trailing dot: the empty 4th argument `uType` (a `value` slot typed `UINT`; `MessageBoxW` is not
    variadic, so there is no "args" dot). The test prints it twice because Right stops at the last leaf and the
    eighth read happens after a Right that could not move. Probe at baseline (re-run) of the real leaf list:
    before the first `update` it is `MessageBoxW | nil | L | "Testing" | L | "Testing again" | ●`; after the first
    `update`, `sync_capture_dots` adds the pink capture dot as leaf 0 (`MessageBoxW` returns `i32`) and shifts
    `editor_field` by one, so the cursor keeps reading the same parts.
  - Leaf kinds:
    - `Field`: a selectable single field.
    - `Callee`: a call's name.
    - `Value`: a filled operand with no structure (`nil`, a loaded number `1`, `win.MB_OK`, a literal's type name,
      a literal key). A loaded `a + b` right-hand side is one `Value`, because loaded expressions keep fixed text
      unless the loader structures them (doc 01): `parse_expr` finds no selectable field in it.
    - `Str`: a string literal.
- **Rules & edge cases**: the leaf a part acts through (`leaf_primary_field`) is its first slot field, else its first
  editable field, else its first field.
- **Source**: model.odin `update`; row_nav.odin `row_left`; selection.odin `line_leaves`, `leaf_primary_field`,
  `editor_leaf`, `editor_target`.

### 4. Rows of a long line (calls and procedure headers broken over lines)

- **Trigger**: a line whose saved source is wider than `MAX_COLS = 80` columns, counting a tab as `TAB_COLS = 4`
  (format.odin `needs_break`, `text_cols`).
  - Exempt: if/switch headers, case labels, loop headers, `x += f(...)`, compound values (`x = a if c else b`,
    `cast(T)f(a)`), and `#assert(...)`.
  - Also broken whatever the width: struct literals loaded one field per line, and calls loaded with grouped
    argument rows.
- **Behavior**:
  - `call_rows` lays the line out as: row 0 = everything up to and including `(`; one row per argument (indented
    one level, suffix `,`), or one row per recorded group for a call loaded with grouped rows; a last row from `)`
    to the end of the line. The list used is the outermost call's argument list, or, for a menu-built procedure
    header (one with a `params` dot), the parameter list (one parameter per row).
  - Each leaf belongs to a row (`leaf_rows`).
  - **Up/Down move between rows first.** Up goes to the first leaf of the nearest earlier row. Down goes to the first
    leaf of the next row. Only when there is no row further that way does the cursor leave the line.
  - Entering a broken line from above starts on row 0. Entering from below starts on the first leaf of its **last**
    row, so Up/Down read the rows in order.
  - A one-row line keeps the column index.
  - Left wraps within its row (§3). On an argument row with a single leaf, Left therefore stays put; on a row like
    `windows.L("x"),` Left from `L` wraps to `"x"`.
  - The editor additionally soft-wraps rows that still do not fit the window; that is drawing only and does not
    create rows for navigation.
- **Rules & edge cases**: `row_move` and `row_enter` do nothing on a dot. Rows without leaves (typically the `)` row
  of a call) are never landed on; a header's last row (`) -> int {`) can hold the result leaf. Y on a direct
  argument of a broken call (not a literal or a header) appends `"Join with previous row"` (when the argument
  starts a row and is not the first) and/or `"Own row"` (when it shares a row) to the refill menu
  (stmt_layout.odin `arg_row_extend_menu`, doc 05/10).
- **Rationale**: "so Up/Down read the rows in order" (row_nav.odin `row_enter`).
- **Source**: row_nav.odin `leaf_rows`, `row_left`, `row_move`, `row_enter`; format.odin `needs_break`, `call_rows`.
  Test: `test_row_nav_up_down_through_broken_call`.

### 5. Holding a direction repeats

- **Trigger**: holding a **pad** d-pad direction.
- **Behavior**:
  - One move on press. After `DPAD_REPEAT_DELAY = 0.35 s` the platform layer emits another press every
    `DPAD_REPEAT_EVERY = 0.07 s`, about 14 per second.
  - Repeats are ordinary `Button_Event{pressed=true}` events, so everything downstream treats them as presses. That
    covers cursor moves, menus, the file browser, RT walks (RT stays held, the d-pad repeats) and sliding a lifted
    block.
  - Keyboard arrows repeat through OS key-repeat instead.
- **Rules & edge cases**:
  - Off while dictating (`win.dpad_no_repeat = g_recording`), because d-pad Down ends a word there (doc 08).
  - Unplugging the controller clears all holds.
  - Face buttons never repeat.
- **Rationale**: the commit message (d6e415a) says the repeats are made as events so "recordings log them and replays
  move the same number of steps".
- **Source**: platform.odin `Dpad_Hold`, `dpad_repeat_tick`, `poll_events`; main.odin main loop. Test:
  platform_test.odin `test_dpad_repeat`.

### 6. How a press becomes an editor action

- **Trigger**: any input in the editor.
- **Behavior**:
  - The app builds an abstract `Input`: edges `confirm` (A), `cancel` (B), `up/down/left/right`, `x`, `y`, plus
    levels `lt_held`/`rt_held` (analog trigger > 0.5, or keyboard `q`/`e`). Keyboard stand-ins (main.odin
    `handle_key`): arrows or W/A/S/D, Return/Space = A, Backspace/Escape = B, `x`/`y` keys = X/Y, `r` = RB,
    `t` = LB, Ctrl+C = copy.
  - While dictating (`g_recording` or `g_stt_busy`) the app clears every edge before `model.update`
    (`editor_input`), so the editor does not move until the words are in.
  - `model.update` runs `keymap_resolve` on the bank of the held trigger. Both triggers held means LT wins.
  - `IDE_Menu` (LT+Left) is checked first, before anything else in the Editor state, and also works from the main
    menu: it opens the `"IDE MENU"` even while something is lifted or a pick is running (probe: LT+Left while a
    Grab is lifted opens the IDE menu; B returns to the still-lifted block).
  - Bound slots fire an `Action` and their button is removed from `rest`. A *hold* action (`Talk`) is removed from
    `rest` but never fired; the app polls it with `keymap_holding`.
  - Plain d-pad/A/B are *locked* (`Move_*`, `Select`, `Back`) and stay in `rest` as navigation.
  - Plain X is unbound by default, so a plain X press is swallowed (it does nothing outside a Grab).
  - **An unbound trigger + face button is swallowed** (a cleared LT+B must not fall through to plain B = back to the
    main menu). **An unbound trigger + d-pad still moves the cursor.**
  - Default layout (keymap.odin `KEYMAP_DEFAULT`):

    | Bank | Up | Down | Left | Right | A | B | X | Y |
    |---|---|---|---|---|---|---|---|---|
    | LT | (move) | (move) | IDE menu | Run list | **Edit** | **Delete** | Talk (hold) | Docs |
    | plain | move | move | move | move | Select | Back | (swallowed) | **Change** |
    | RT | **Walk prev** | **Walk next** | **Walk out** | **Walk in** | **Copy** | Files | **Refactor (Grab)** | Save |

    Not bound by default (available in the Key Layout picker): `Save_As`, `Run_Favorite`, `Run_Tests`,
    `Format_File`, `Prev_File`, `Key_Layout`. RB / LB (and keys `r` / `t`) run the favorite / the tests outside the
    layout (main.odin).
  - Order inside `update` for the editor state:
    1. `ref_pick_update` (§16)
    2. `grab_update` (§13)
    3. `word_edit_update` (doc 08)
    4. `mod_pick_update` (§16)

    The first of these that is active consumes the whole frame. Note that `ref_pick_update` and `mod_pick_update`
    read the raw `Input` (so LT+B there acts as B), while `grab_update` reads both raw and resolved input (§13).
    After them, `keymap_run` fires the actions in `Action` enum order (Edit, Delete, Change, Docs, Copy, ..., the
    walks, Format_File, ..., Grab, Save) and stops as soon as one leaves the editor state. Then come plain
    Left/Right, Up/Down, B, A.
  - Plain **B** with nothing open sets `state = .Menu` (main menu; the document stays loaded).
  - Plain **A** acts by where the cursor is:
    - purple dot: Attributes menu (§9);
    - green dot: the statement menu if the boundary is a body dot and not a file-scope insertion point
      (`!insertion_points[line] && body_points[line]`, §8), else the Add menu (§7);
    - slot leaf: its fill menu (`open_slot_menu`; a capture dot captures at once, §10);
    - filled, non-slot leaf: **nothing**.
  - In menus (`State.Radial`) the keymap is skipped. Menus only see plain d-pad/A/B (grid navigation with
    wrap-around, doc 03), read from the *raw* input: a trigger is ignored there, so LT+B in a menu acts as B
    (probe: LT+B in the Refactor menu closes it) and X / Y do nothing.
  - Actions needing disk, clipboard or overlays are put in `App.requests` (`Docs`, `Copy`, `Save`, `Save_As`,
    `Run_List`, `Files`, `Run_Favorite`, `Run_Tests`, `Prev_File`, `Key_Layout`), and `src/app` performs them right
    after `update` (`app_requests`): Copy, Save, Run favorite, Run tests and Prev file always; then at most one
    overlay, the first of Docs, Save as, Run list, Files, Key layout. `Format_File` runs in the model
    (`format_doc`); `Talk` is a hold the app polls itself.
  - After every `update` these syncs run, in this order: `result_list_sync`, `branch_sync`, `ctrl_sync`,
    `sync_capture_dots`, `word_edit_sync`. In Odin they are `defer`s.
- **Rules & edge cases**: the hint line at the top right names default buttons ("Y: ...", "LT+B: ...", "LT+A: ...").
  `rebind_hint` splits it at 4-space separators; a segment that starts with `"Y: "`, `"LT+B: "` or `"LT+A: "` gets
  the current button of Change / Delete / Edit instead, or is dropped when that action is unbound. Other segments
  (e.g. `"A: attributes ..."`) are kept as written. With the default layout the text is unchanged. Walk actions are
  `trigger_only` (they cannot sit in the plain bank); `Talk` is `face_only`. Delete, Save and Files are `required`
  (always exactly one button).
- **Which hint shows** (editor_view.odin, ctrl.odin `ctrl_hint`), first match: the Grab hints while lifted (§13);
  the word-by-word hint while in a text (doc 08); otherwise `ctrl_hint`, which tries the purple dot
  (`"A: attributes  (test, private, ...)"`), a `/* */` comment (`"Y: add a line    LT+B: delete line"` on a text
  line, `"Y: add a line    LT+B: delete comment"` on a marker), `branch_hint` and `loop_hint` (doc 05), then
  `"Y: add attribute    LT+B: remove it"` on an `@(...)` line, `"Y: add directive    LT+B: remove it"` on a
  struct directive, and the `when` / `else when` / `else` / `#assert` / calling-convention keyword hints. No hint in
  menus, during a modifier pick, or (not drawn) during a reference pick.
- **Source**: keymap.odin `keymap_resolve`, `pad_edges`, `active_bank`, `ACTION_INFO`, `rebind_hint`; model.odin
  `update`, `keymap_run`; main.odin `build_input`, `editor_input`, `handle_event`, `handle_key`, `app_requests`.
  Tests: keymap_test.odin `test_keymap_resolve`, `test_keymap_update_delete_stays_in_editor`,
  `test_keymap_update_change`, `test_keymap_assign_rules` (locked slots, "walks need a trigger", "Talk needs a face
  button").

### 7. Green insertion dots at file scope

- **Trigger**: d-pad onto a green dot between top-level constructs, the top dot (before line 0) or the bottom dot.
  Then A.
- **Behavior**: `insertion_points[i]` is true for every line at declaration depth 0. Braces of a file-scope `when`
  do not count, so its declarations get dots (ctrl.odin `block_infos`, `decl_depth`; such dots are drawn indented
  like the declarations, `insertion_indents`). Lines inside a `/* */` comment are excluded. `pts[n]` (the bottom
  dot) is always set; `pts[0]` is set in practice because line 0 is at depth 0. **One dot per gap**
  (`dot_points`): `pts[i]` is dropped when `pts[i-1]` is set and line `i-1` is blank, so of the dots around a run of
  blank lines only the one right after the upper construct is kept (`package main`, blank, `import`, blank,
  `main :: proc() {}` gives 4 dots in total: top, after package, after import, end; `test_one_dot_per_gap`).
  `insertion_points` itself still marks every file-scope line (other code relies on it). A opens the Add menu
  titled `"Add  (insertion point)"` with `insert_at` = this boundary. After an insertion the cursor lands on the
  green dot just after the inserted construct (`test_insert_at_middle_dot`).
- **Rules & edge cases**:
  - There is a green dot between an `@(...)` attribute line and its procedure (both are file-scope lines).
  - LT+B on a green dot (file-scope or body) deletes an adjacent blank line: the one at/after the dot first, else
    the one before it. If there is none, LT+B does nothing (`test_delete_on_dot_is_noop`, `test_fix_dot_after_blank`).
  - Y and LT+A on a dot do nothing.
  - RT+X on a dot opens Refactor for the construct that contains the line *after* the dot (§12 "where a walk
    starts"). Probes at baseline: on the top dot that is `package main`, so Grab answers `"Nothing here to move"`;
    on the bottom dot it is the last top-level construct; on the body dot before a closing `}` it is the whole
    enclosing block (at the end of a procedure body: the whole procedure).
  - Copy (RT+A) on any dot copies the whole file (§15).
- **Source**: model.odin `insertion_points`, `dot_points`, `open_add_menu`; stmt_layout.odin `layout_delete`. Tests:
  `test_one_dot_per_gap`, `test_insertion_points`, `test_insert_at_top_dot`.

### 8. Green dots inside bodies (nested-body dots)

- **Trigger**: d-pad onto a dot inside a procedure body or any nested block, then A. Inside a data body (struct /
  enum / union / bit_field) the same dots offer members (doc 04).
- **Behavior**:
  - `body_points[i]` puts a dot before every line inside a code or data block: above the first statement, between
    statements, and below the last one (before the `}`), at every nesting level. That includes before a `} else {`
    line, i.e. at the end of the if-branch.
  - Braces are tracked per line, outside strings and `//` comments, with a stack recording whether each `{` opens
    code. A `{` opens code if it is inside code already, or the line contains `proc(`, `proc "`, or `:: proc`, or it
    is a `) -> T {` line that ends a multi-line header. A `{` opens data if `data_kind_of_line` says so.
  - **A on a body dot**:
    1. A temporary line `indent + ●(body slot)` is inserted at the boundary and `open_slot_menu` opens on its dot.
       The menu title is `"Fill slot"`; in a code body its entries are the statement groups (doc 05), in a data
       body the member entries (probe: a struct body dot offers `Field`, `Using field`, `Layout`; doc 04).
    2. Picking a statement keeps the line. `body_insert_done` removes the extra trailing `●` line a statement
       normally adds, skipping over the new block if the statement opened one.
    3. **B removes the temporary line and puts the cursor back on the same dot.** The file is byte-identical.
    4. If the menu could not open, the insert is cancelled at once.
  - Indentation of the new line (`body_indent_at`), first rule that applies:
    1. next to `case` labels, branch.odin decides (`branch_body_indent`);
    2. the next line's indentation, unless that line is blank or starts with `}`;
    3. else the previous line's, one unit deeper if that line opens a block (`brace_delta > 0`, or it ends with
       `{` and is not a `//` comment);
    4. else (boundary 0) one unit.

    The unit (`doc_indent_unit`) is a tab if the document's first indented line starts with a tab, otherwise
    (spaces, or no indented line at all) 4 spaces.
- **Rules & edge cases**:
  - No body dot next to an empty `●` statement line, since that line already offers the menu.
  - No dot between two blank lines, and none between a blank line and a closing `}`. So an empty function saved
    as `{\n\n}` shows exactly one dot.
  - Blank lines between statements get one dot above them and one right after them.
  - An empty block that only contains blank lines: A *reuses* the blank line (it is removed and its text kept), so
    the new statement takes its place. Precisely: the line after the dot is blank, the line before it opens a block,
    and only blank lines follow up to a line starting with `}`. Cancel puts the blank line back.
  - Body dots are computed for any `{` the stack marks as code or data, so a dot also sits before the `}` line and
    before a `} else {` line, but never before line 0.
  - Body dots never appear inside `/* */` comments.
- **Source**: body_dots.odin `body_points`, `opens_code`, `multi_line_header_end`, `body_indent_at`,
  `doc_indent_unit`, `open_body_insert`, `body_insert_done`, `body_insert_cancel`, `is_blank_line`,
  `is_body_slot_line`. Tests: body_dots_test.odin (all six); integrate_fixes_test.odin `test_fix_dot_after_blank`.

### 9. Purple attribute dots

- **Trigger**: d-pad onto the purple dot. It sits on the boundary above every file-scope procedure (including one
  inside a file-scope `when`), above that procedure's `@(...)` lines if it has any. Then A.
- **Behavior**: the stop order on that boundary is green dot, then purple dot, then the line. A opens the
  procedure's `"Attributes"` menu, the same one Add > Modifiers > Attributes opens (doc 04). For a file-scope
  procedure the entries are, in order (modifiers.odin `ATTR_OPTS`, `attr_options`): `test`, `private`,
  `private="file"`, `export`, `init`, `fini`, `require_results`, `link_name="..."`, `deprecated="..."`, `cold`.
  Grayed: any attribute whose name is already above the procedure (`private` grays both `private` entries),
  `require_results` without results, `init` / `fini` with parameters or results, and `test` when the procedure
  returns something, takes anything but one `^testing.T`, or has a calling convention other than `"odin"`
  (`test_attr_dim`). Choosing a grayed entry does nothing and the menu stays open (ctrl.odin
  `ctrl_menu_choose`). Choosing one adds it to the existing `@(...)` line (`@(private, require_results)`) or
  makes one. B closes it and **the cursor stays on the purple dot**. Hint line:
  `"A: attributes  (test, private, ...)"`. Docs (LT+Y) on it shows the "attributes" keyword doc.
- **Rules & edge cases**:
  - Not shown for non-procedure declarations (also not for procedure groups `proc{...}`: `classify_decl` must say
    `.Proc`).
  - `on_attr_dot` re-checks that the dot still exists. If the procedure is gone, `normalize_cursor` moves the
    cursor off it.
  - LT+B, Y and LT+A on it do nothing. Copy on it copies the whole file. RT+X on it lifts the construct that starts
    on the line below the dot: for a procedure with `@(...)` lines that is **only the first attribute line**
    (probe at baseline; attribute lines are their own walk roots, §12).
- **Source**: attr_dots.odin `attr_points`, `attr_group_start`, `attr_dot_decl`, `on_attr_dot`, `focus_attr_dot`,
  `open_attr_dot_menu`; ctrl.odin `ctrl_hint`. Tests: attr_dots_test.odin `test_attr_points_above_procedures`,
  `test_attr_dot_is_a_cursor_stop`, `test_attr_dot_opens_attributes`, `test_attr_dots_not_on_other_declarations`.

### 10. Pink capture dots (as stops) and uncapture

- **Trigger**: a pink dot appears as **leaf 0** of a bare call statement inside a block, when the called procedure is
  known to return something. A on it captures the result.
  - "Bare" means: only indentation, the capture dot and at most one `pkg.` before `name(...)`, and nothing after
    the `)`. The callee must be a plain identifier (not a dot), and a struct literal `T{...}` is not a call.
  - "Inside a block" means not a file-scope insertion point (`!insertion_points[ni]`), so lines in a file-scope
    `when` never get one.
  - The procedure must be known (`call_signature(...).known`) with a known, non-empty result. The return count
    comes from `result_count`: `int` is 1, `(int, bool)` is 2, `(a, b: int, ok: bool)` is 3 (top-level commas + 1),
    and anything with `#optional_...` is 1.
- **Behavior**: A captures immediately, with no menu:

  ```odin
  ● len(name)        ->   brave_otter := len(name)        // cursor on the new editable name
  ● pair()           ->   calm_lynx, bold_heron := pair()  // one generated name per result
  ```

  The new names come from namegen.odin `generate_ident` (unique `adjective_animal` names from a counter, skipping
  names already used in the file or sibling files; the ones above are illustrative), joined
  with `, `, followed by a ` := ` field of kind `decl`; the cursor goes on the first new name, the RT path is
  cleared and the fingerprint reset so the next sync re-checks.

  The dot is a slot of kind `capture` with empty text, so it is never saved. `sync_capture_dots` keeps exactly the
  wanting lines dotted after every `update`:
  - it only runs when `state == .Editor` and none of `refill_active`, `change_call`, `ref_pick_active`,
    `ref_pass_active`, `decl_form_active`, `body_insert_active`, `replacing` is set, because those hold field
    indexes (it does run while a Grab is lifted);
  - it skips the work when an FNV-1a fingerprint of the document is unchanged;
  - it splits a loaded `"\twindows."` field so the dot sits after the indentation;
  - it shifts `editor_field` so the cursor stays on the same leaf, and clears the RT `tree_path`.

  **LT+B on a captured name** (`uncapture`) undoes it, but only when the name is a plain editable name (kind `""`)
  before a `:=` or `:` operator (not `::`) and the value is a bare call:
  - `n := len(s)` and `x: string = strings.clone(s)` become the bare call, the capture dot comes back, and the
    cursor goes onto it. The `pkg.` prefix is kept (in a field of its own).
  - With several names, the deleted one becomes `_`. When no real name is left, the declaration goes:
    `a, b := pair()` → `_, b := pair()` → `pair()`.
  - `y := 5` is not a call, so LT+B deletes the whole statement.
- **Rules & edge cases**:
  - The capture dot is a D-pad leaf but **not** an RT-walk unit. The walk visits code only (`line_units` excludes it).
  - A struct literal `T{...}` is not a call.
  - Renaming the callee to a proc that returns nothing removes the dot on the next sync.
- **Source**: capture.odin (all procs); model.odin `open_slot_menu` (capture branch). Tests: capture_test.odin (all).

### 11. A on a slot, and where the cursor goes after edits

- **Behavior**:
  - A on any in-line slot opens its fill menu. Every such menu is pushed with the title `"Fill slot"`; only the
    entries differ by slot kind (`open_slot_menu`): a `body` dot gets the statement groups, a `value` / `args` /
    `ret_more` dot gets `Number`, `String`, `true`, `false`, `nil`, `Reference`, `Call`, `Struct literal`,
    `Constant`, `Operator`, `Convert`, `Type` (+ extensions), a `params` dot gets the single entry
    `Add parameter`, a `fields` dot the unset literal fields, a `type` / `""` dot `Type` and `Variable`; data-body,
    setup and variant dots have their own (contents in 04/05/06). A capture dot captures without a menu (§10).
    Fills that cannot produce the dot's hinted type are grayed; `Reference` is grayed when no name can be picked.
    Order shown (model.odin `make_view`): a menu with more than `BUCKET_THRESHOLD = 12` ordinary entries is sorted
    case-insensitively, a smaller one keeps the order written in the code. The value menu has 12 base entries plus
    extensions, so it shows sorted (probe on `count := 5`: `Built-in constants`, `Call`, `Constant`, `Convert`,
    `Enum value` (grayed), `false`, `nil`, `Number`, `Operator`, `Reference`, `String`, `Struct literal`, `true`,
    `Type`). Menus pushed with `push_view` (Refactor, Number keypad, Text) are never sorted.
  - After a fill the cursor goes back to **the same index among the line's editable fields and dots** (`sel_k`,
    counted before the fill; `focus_kth_selectable`). Because a callee written by a fill is fixed text, filling a
    dot with a call usually lands on the call's first argument dot. `focus_first_dot_in` (first unfilled dot inside
    the new content) is used only by Change procedure (§18 row 6), despite its comment mentioning `MessageBoxW(`.
  - After a delete the cursor is normalized at the deleted position (§1). Probes at baseline (re-run): deleting a
    statement lands on the next statement's first leaf; deleting the last statement of a block lands on the body
    dot before its `}`; deleting a procedure followed by a blank line lands on the next stop, the purple dot of the
    next procedure; deleting a procedure directly followed by another lands on that procedure's name.
  - After an Add-menu insertion the cursor is on the green dot after the inserted construct.
- **Source**: model.odin `menu_select` (slot-fill tail), `open_slot_menu`; selection.odin `focus_kth_selectable`,
  `focus_first_dot_in`.

### 12. RT walks: the per-line syntax tree, Walk prev/next/in/out

- **Trigger**: RT + d-pad by default. `Walk_Prev` = RT+Up, `Walk_Next` = RT+Down, `Walk_In` = RT+Right,
  `Walk_Out` = RT+Left. While the trigger of a bank containing a walk is held (and not dictating), the editor
  draws the walk selection instead of the leaf (`keymap_bank_walks`, `g_walk_held`). **Just holding RT highlights
  the statement on the cursor's line, or the block that line opens.**
- **Behavior**: the walk moves through a tree with three node kinds (`Sel`):
  - `Block{ni, end_ni}`: a construct that opens a brace on line `ni` and closes it on `end_ni`. The end is found by
    brace balance, so an if/else-if/else chain is one Block.
  - `Line{ni}`: a single line.
  - `Unit{ni, fa, fb}`: fields `[fa, fb)` of a line.

  Children of each kind:
  - Roots (`tree_roots`): one `Line` or `Block` per top-level construct; whitespace-only lines are skipped.
  - `Block` (`tree_children`): first its header line (as a `Line`), then each statement as `Line` or `Block`
    (nested blocks stay grouped). Blank lines and lines that are exactly `}` are skipped. A `} else {` line is a
    `Line` child.
  - `Line`: its `line_units` (below).
  - `Unit`: its sub-units (a call's name and arguments, an operator's operands, a literal's elements).

  Moves (`tree_move`):
  - **Walk_In** pushes the first child (no-op if there are none).
  - **Walk_Out** pops (no-op at the root level).
  - **Walk_Prev/Next** move to the previous/next sibling, **clamped with no wrap**. The siblings of a root are the
    roots.

  After each move the real cursor is synced to the selection (`tree_sync_cursor`), so the view scrolls and
  ordinary actions follow: for a Unit, the leaf containing its first field; for a Line or Block, leaf 0 of its first
  line (which can be a capture dot). The new cursor position is remembered as the path's anchor. If the current
  node is no longer found among its siblings (a stale path), Walk_Prev/Next do nothing.
- **Where a walk starts** (`tree_ensure`): the path is kept while `(editor_line, editor_field, editor_dot,
  len(nodes))` equals what it was after the last walk move and the path's last node still lies inside the document.
  If any of them changed, the path is rebuilt. `tree_ensure` runs lazily, from `tree_move`, `tree_selection`
  (Refactor, Y, Docs) and `current_highlight` (every drawn frame). The rebuild
  descends from the roots through the constructs containing the cursor line and **stops at the entry whose first
  line is the cursor line**: that line's statement, or the block it opens. The enclosing constructs stay above it
  in the path, so Walk_Out widens step by step (statement → loop/if → procedure). Other starting points:
  - on a `}` line or a blank line inside a block: the innermost block around it;
  - on a dot: the line after the dot (so the body dot before a closing `}` starts at the block that `}` closes);
  - on the bottom dot: the last line (usually the `}` of the last construct, so that construct);
  - nothing found (e.g. a blank line at file scope): the last root.

  The descent is capped at 64 levels.

  A rebuild clears the sticky flag (§14). Tests: tree_start_test.odin.
- **The unit tree of a line** (`line_units`, `parse_expr`):
  - **Headers.** Branch, loop and `when` headers have their own unit lists (branch.odin, loops.odin,
    when_cond.odin; doc 05).
  - **Call statements**, `[x := ][pkg.]f(args)`: the selectable fields before the callee each become a `Field`
    (the capture dot excluded). Then come the call's children, flattened to the top level: the `Callee` followed by
    one unit per argument, split at top-level `, `. A struct literal's children are flattened the same way. Then the
    selectable fields after the `)`.
  - **Other lines** (no call, call at field 0, or a compound right-hand side, `value_is_compound`): each
    selectable field before the right-hand side (`stmt_rhs_start`) becomes a `Field` (capture dot excluded). The
    right-hand side becomes **one** unit, parsed with `is_arg = true` so Y refills it. A line with no right-hand
    side is just its selectable fields.
  - "Call" here means the outermost list found by `find_arg_list`: a `(` / `( ` field ... `)` / ` )` field, or a
    struct literal's `{` ... `}` fields. Parentheses glued into a bigger fixed text do not count. (A loaded
    procedure header comes out as plain `Field` leaves: probe, §1.)
  - `@(...)` attribute lines and `/* */` comment lines are lines of their own, so in the walk they are separate
    roots / children from the declaration they belong to.
  - **`parse_expr`** applies these rules in this order:
    1. empty → `Value`;
    2. one field → `Field` if selectable, else `Value`;
    3. a ternary `a if c else b` / `c ? a : b` → `Op` with 3 operands;
    4. top-level binary operator fields (` | `, ` + `, ` == `, ... written with surrounding spaces, as the menus
       insert them; list in selection.odin `BINARY_OPS`) → `Op` with n operands;
    5. a `cast(T)` / `transmute(T)` / `auto_cast` prefix → `Group[prefix, value]`;
    6. `T{...}` → `Lit[type Value, each element]`, where an element `name = value` is `Group[name Value, value]`
       (only the value is `is_arg`); other elements are parsed without `is_arg`;
    7. `name(...)` with the `)` last → `Call[Callee, args...]`, each arg with its `arg_idx`, split at top-level
       `, ` (`arg_ranges`; empty ranges are skipped);
    8. starts and ends with a quote field (`"`, `` ` ``, `'`) → `Str`;
    9. otherwise a `Group` of the selectable fields, or a `Value` if there are none. Loaded `a + b` is one
       `Value` either way: its operator is not a separate ` + ` operator field, and its text is fixed, so rule 2 or
       rule 9 yields a `Value`.

    Units in argument or operand positions carry `is_arg`. Binary operators are recognised only as their own field
    written ` op ` (with spaces), from `| & ~ &~ << >> + - * / % == != < <= > >= && ||`.
- **Example** (test_rt_tree_navigation). The cursor starts on `package main`:
  1. RT+Down twice reaches `main :: proc() {...}`, a Block.
  2. RT+Right selects the header line. RT+Down selects the `MessageBoxW` statement.
  3. RT+Right selects `MessageBoxW` (the Callee).
  4. RT+Down twice selects `windows.L("Testing")` (a Call unit, argument 1).
  5. RT+Right selects `L`. RT+Down selects `"Testing"`. RT+Left goes back out to `windows.L("Testing")`.
- **Source**: selection.odin `Sel`, `tree_roots`, `tree_children`, `find_unit`, `tree_ensure`,
  `tree_remember_cursor`, `tree_selection`, `tree_sync_cursor`, `tree_move`, `line_units`, `parse_expr`,
  `arg_ranges`; model.odin `keymap_run`.

### 13. Refactor menu (RT+X): Grab and Copy line

- **Trigger**: the `Grab` action (RT+X by default; key-layout label "Refactor", glyph `G`). It opens a menu titled
  `"Refactor"` with two entries, in this order: **`Grab`** and **`Copy line`**. B closes the menu and nothing is
  lifted. The menu does not open in an empty document (no walk selection).
- **What is lifted** (`grab_start`):
  - The deepest `Line` or `Block` on the current walk path. A walked-to `Unit` lifts its statement.
  - A block's header line lifts the whole block.
  - With no prior walk, the path built from the cursor applies (§12): the statement on the cursor line, or the
    procedure when on its header, or the construct after a dot (on the body dot before a `}`: the whole block that
    `}` closes, §7).
  - Refused for a `package ...` line and for any line starting with `}` (`} else {`). The notice is
    `"Nothing here to move"`.
  - `@(...)` attribute lines are separate walk roots, so lifting a procedure from its header does **not** take its
    attribute lines along. Probe at baseline: with `first :: proc() {}`, then `@(private)` above
    `second :: proc() {}`, Grab on `second` then Up jumps `second` past the `@(private)` line, which is left
    dangling at the end of the file. Lifting from the purple dot lifts only the attribute line (§9).
  - **Copy line** clones the lifted lines and inserts the copy right below the original. **The copy is what moves.**
  - The cursor follows the first lifted line (`focus_line_start`) so the view scrolls with it.
  - The lifted lines get a pulsing **orange** box (glow + fill + outline). A blocked copy is drawn **red**. While
    something is lifted the blue RT shading of a whole-line selection is not drawn.
- **Controls while lifted** (`grab_update` consumes **all** editor input; every other button is ignored, e.g. LT+B
  or LT+Y do nothing, `test_grab_cancel_puts_it_back`). One action per frame, checked in this order:

  | Input | Effect |
  |---|---|
  | the Grab action again, **any X press** (raw `inp.x`, so plain X, RT+X and LT+X alike), or plain A | **drop** (refused while blocked, with notice `"A copy from inside a procedure can only be dropped inside a procedure"`) |
  | plain B | **put back**: undo every move exactly |
  | `Walk_Prev` / `Walk_Next` (RT+Up / RT+Down) | **jump** past the whole neighbouring sibling (`grab_jump`); never enters or leaves blocks |
  | plain Up / Down (or an unbound-trigger d-pad, e.g. LT+Up) | **step** (`grab_step`) |
  | Left / Right / everything else | nothing |

  Exceptions (code-derived, partly probed): `IDE_Menu` (LT+Left) is handled before `grab_update` and opens the IDE
  menu with the block still lifted (probe); LT+X (Talk) drops the block (probe) and, since the app starts dictation
  on the same press when a name is under the cursor, may also start recording; the app-level fixed keys Ctrl+C
  (copy), RB / `r` (save + run favorite) and LB / `t` (save + run tests) are not blocked by a lift (main.odin checks
  picks and dictation, not `grab_active`). If the document changes under the lift (a file is opened), the lift
  silently ends.

  Hint line (exact strings):
  - normal: `"Up/Down move   RT+Up/Down jump   X / A drop   B put back"`
  - Copy line: `"Up/Down move the copy   RT+Up/Down jump   X / A drop   B no copy"`
  - blocked: `"Outside a procedure: can't drop here   Up/Down move   B no copy"`
- **Step rules** (`grab_step`). The siblings are the lifted construct's siblings in the walk tree, without the
  block's header line.
  - The next sibling in that direction is an **enterable block**: the lines move **into** it. Going Down puts them
    just under the block's header; going Up puts them just above its `}`. They are re-indented to the header's
    indentation + `\t`. Enterable blocks:
    - a header starting with `for`, `if`, `else`, `when` (an optional `label: ` prefix is allowed);
    - a bare `{`;
    - for a copy from inside a procedure only, a procedure block (`::` + `proc` + ending `{`).
  - Any other sibling is **jumped**: the two swap, and blank lines between them stay in the middle.
  - At the first or last position of its block, it **leaves the block**. Down puts it just below the `}`; Up puts
    it just above the header. It is re-indented to the parent's indentation. Leaving is allowed only when:
    - it was not lifted at top level;
    - the parent header ends with `{`;
    - for a move (not a copy), the parent is not the procedure it was lifted from.
  - **Never**:
    - out of its own procedure (a move);
    - into a `switch` (not enterable), a multi-line struct literal or a local type;
    - in front of a switch's first `case` (`grab_jump` refuses index 0 upward under a `switch` header);
    - above `package`.
  - Top-level constructs (`grab_top`) only jump past other top-level constructs. A switch's `case` lines are plain
    siblings inside the switch block, so a statement lifted from a case body steps past `case` lines into other
    clauses (but not above the first `case`) and leaves the switch below its `}` at the bottom edge
    (code-derived, not pinned by a test).
  - "The procedure it may not leave" is `grab_proc = path[0]`, the **top-level** construct of the walk path. For a
    procedure inside a file-scope `when`, that is the `when` block, so a move could leave the procedure into the
    `when` (code-derived, not probed).
  - A step or jump that is not possible does nothing (no notice).
- **Copy line specifics**:
  - A copy from inside a procedure may leave that procedure, slide past other top-level constructs and enter
    another procedure.
  - While it sits between procedures, `grab_blocked` is true: it is drawn red and drops are refused.
  - B removes the copy wherever it is, and the cursor goes to the original's first line.
  - A top-level copy only moves among top-level constructs (it may land next to the original, e.g. a duplicate
    procedure).
- **Undo**: every move is recorded as a rotation `Grab_Op{lo, hi, first, sel}` (lines `[lo, hi]` rotated so the
  first `first` go to the end). A jump is two rotations (a no-op rotation is not recorded). Re-indents are not
  recorded. Cancel replays the inverse rotations in reverse order, then re-indents the lines to the indentation
  saved at lift time (first line gets it, the others keep their indentation relative to the first). That brings
  back the **exact original document** for normally indented code (`test_grab_into_and_out_of_a_block` compares
  the whole file); a line indented *less* than the first lifted line loses its relative indentation (its leading
  tabs are trimmed and it gets the base).
- **Re-indent rule** (`reindent_lifted`): entering a block gives the first line the header's indentation + `"\t"`
  (always a tab: probe in a 4-space file gives `"    \ty := 2"`); leaving gives it the parent header's indentation.
- **After a drop**: `tree_select_lines` makes the dropped construct the RT selection with `tree_sticky = true`. It
  stays highlighted (whole lines shaded), and RT+X lifts it again, until the cursor moves. B on a moved (not copied)
  block ends the same way, with the put-back construct selected (`grab_cancel` calls `grab_drop`). A drop keeps no
  undo information: once dropped, the move can only be reversed by grabbing it again.
- **Examples** (grab_test.odin):

  ```odin
  // lift `y := 2`, Up, Up, Up, Down:
  x := 0              x := 0              x := 0             x := 0
  if x > 0 {          if x > 0 {          y := 2             if x > 0 {
      x = 1               y := 2   (Up2)  if x > 0 {             y := 2   (Down: in again, under header)
      y := 2  (Up1)       x = 1               x = 1              x = 1
  }                   }                   }   (Up3: out)     }
  ```
- **Rationale**: grab.odin header and commit cee37be: "Never out of the procedure it came from, never into a switch,
  struct literal or local type; top-level constructs only swap with each other and never pass `package`."
- **Source**: grab.odin (all procs); editor_view.odin (box colours, hint strings); model.odin `menu_select`
  (`REFACTOR_FILL`), `update` (IDE menu before `grab_update`); main.odin main loop (fixed keys). Tests:
  grab_test.odin (all 11), tree_start_test.odin `test_grab_starts_at_the_cursor_line`.

### 14. What is highlighted, and the sticky selection

- **Behavior**: `current_highlight(app, rt_held)` returns lines `[ni, end_ni]` and fields `[fa, fb)`, where
  `fb = -1` means whole lines. While the walk trigger is held, or while `tree_sticky` is set, it is the walk
  selection: a Block or Line shades whole rows, a Unit highlights its fields. Otherwise it is the leaf under the
  cursor.
  - `tree_move` sets `tree_sticky = true` **only when the selection is a Unit**. After RT is released, a walked-to
    part (e.g. a whole argument `windows.L("Testing")`) **stays highlighted**, while a walked-to Line or Block falls
    back to the leaf highlight (probe: after RT+Down onto a statement and release, the highlight is leaf 0 of that
    line). The path itself survives until the cursor moves.
  - A plain d-pad move invalidates the path. Stickiness is cleared lazily: the next `tree_ensure` (the next drawn
    frame's `current_highlight`, or Y / Docs / Refactor) sees the changed cursor, rebuilds the path and clears
    `tree_sticky`. Y also clears it itself after using it (change.odin), and so does entering word-by-word.
  - The highlight drawn: a Unit or leaf gets a box around each of its fields; a Line or Block gets blue shading over
    its whole rows (only while the walk trigger is held, or when `tree_select_lines` made it sticky after a drop).
- **What each action acts on**:
  - **Change (Y)** and **Docs (LT+Y)** use the sticky Unit when there is one, else the leaf.
    `test_rt_tree_navigation`: after walking to `windows.L("Testing")`, Y refills the whole argument, giving
    `MessageBoxW(nil, nil, ...)`.
  - **Delete (LT+B)** and **Edit (LT+A)** always use the **leaf under the cursor**. After a walk that is the
    selection's *first* leaf (see Open questions). Probe at baseline (re-run): after walking to
    `windows.L("Testing")` (sticky, cursor on `L`), LT+B deleted the **whole `MessageBoxW` statement**, and LT+A
    did nothing (the callee `L` has no Edit menu).
  - **Refactor** uses the walk path (§13).
  - **Copy (RT+A)** uses the cursor line (§15).
- **Source**: selection.odin `Highlight`, `current_highlight`, `tree_select_lines`; change.odin `change_selected`;
  docs.odin `doc_query`; editor_view.odin (shading).

### 15. Copy to the clipboard (RT+A, Ctrl+C)

- **Trigger**: the `Copy` action (RT+A), or Ctrl+C on a keyboard (fixed, outside the layout). RT+A goes through the
  model's `keymap_run`, so it does nothing while a reference / modifier pick, word-by-word or a Grab consumes the
  input, or while dictating (edges are cleared). Ctrl+C is handled in main.odin only in the Editor state with no
  run overlay, no dictation and no reference / modifier pick (it does work while a block is lifted).
- **Behavior**: `copy_selection_source` copies:
  - on **any** dot (green, body or purple): the whole file;
  - otherwise: the cursor line, plus, if that line opens a block, everything through the block's end (a procedure
    header copies the whole procedure).

  The text is serialized as source (`nodes_to_source`: unfilled optional dots dropped, long calls broken). Status
  line: `"copied N line"` / `"copied N lines"` (N counts the *saved* lines, so a broken call counts each row),
  `"nothing to copy"` (empty document), or `"copy failed"`. A trace replay never touches the real clipboard. Copy
  works from the cursor line, not the walk path: after walking to a Unit it copies that Unit's whole statement;
  after walking to a Block, the cursor sits on its header, so the whole block. A `} else {` line copies only that
  line (its brace balance is 0).
- **Source**: serialize.odin `copy_selection_source`; main.odin `copy_selection`, `app_requests`. Test: format_test.odin
  `test_copy_selection_source`.

### 16. Pick modes that borrow the d-pad

These are transient cursor modes. They are documented in their own areas, but their navigation is part of this one.
Each draws a banner and consumes all input while active.

- **Reference pick** (ref_pick.odin; entered from Fill slot > "Reference", from Y on an assignment target, or
  automatically after adding an Assignment).
  - The cursor jumps between candidate names in scope. Left/Right go to the previous/next candidate **with
    wrap-around**. Up goes to the first candidate of the nearest earlier line that has one; Down goes to the first
    candidate on a later line (clamped, no wrap).
  - A opens `"Pass as"` (for a dot) or `"Assign to"` (for an assignment target). B cancels (§20).
  - It starts on the last candidate before the target dot in document order (a name declared above it), else the
    first candidate. With no candidate at all the pick cancels at once.
  - Input is read raw: any B (even LT+B) cancels, any A confirms; everything else is ignored.
  - Banner: `"Pick a name to reference   -   D-pad move   A use it   B cancel"`. The dot being filled gets a
    pulsing ring; the top-right hint line is hidden meanwhile.
- **Modifier pick** (modifiers.odin `mod_pick_update`): Up/Down step through the declarations a modifier can attach
  to (clamped). A opens its options (`"Attributes"`, `"Struct directives"` or `"Calling convention"`). B stops
  picking. Banner: `"Pick <what>   -   D-pad Up/Down move   A choose   B cancel"`, with `<what>` =
  `a declaration for the attribute`, `a struct for the directive`, or `a procedure for the calling convention`.
- **Word by word** (word_edit.odin): yellow dots between the words of a string or comment (doc 08).

### 17. Delete (LT+B): what deleting each kind of part does

- **Trigger**: the `Delete` action (LT+B by default; `required`, so it always has a button). It acts on the leaf
  under the cursor (`editor_target`), never on a sticky Unit. It never also triggers Back
  (`test_keymap_update_delete_stays_in_editor`).
- **Behavior**: `delete_selected` tries a chain of handlers **from finest to coarsest; the first that claims the
  press wins**. In order:

  | # | Cursor on | Result | Handler |
  |---|---|---|---|
  | 1 | a line of a multi-line `/* */` comment | a text line goes (if ≥2 text lines); on the last text line or on `/*`/`*/` the whole comment goes | block_comment.odin `block_comment_delete` |
  | 2 | a green dot (file-scope or body) next to a blank line; or anywhere on a `//` comment line | that blank line (at/after the dot first, else the one before); or that comment line, whatever its text | stmt_layout.odin `layout_delete` |
  | 3 | any other dot (green, body, bottom, purple) | **nothing** | model.odin |
  | 4 | a procedure result in `-> T` / `-> (A, B)`, or a one-field value of `return a, b` | that item and one adjacent `, `. Parens and the extra "more" dots are re-shaped. `-> int` becomes no result, with the cursor on the empty result dot. On the "more" dot, a parenthesis, a separator, or a lone empty result dot: nothing. A `return` with no filled value falls through (the statement goes); a part of a multi-field return value falls through to row 8 | result_list.odin `result_list_delete` |
  | 5 | if/else-if/switch condition or switch value | back to its dot (a `bool` dot for if); already a dot: nothing. The if itself stays | branch.odin `branch_delete` |
  |   | `else if` / `else` keyword | that branch only (up to the next branch); cursor to the `if` keyword | |
  |   | an if / else-if / switch setup `x := f();` | the setup only | |
  |   | `#partial` | removed | |
  |   | `case` keyword, or anywhere on a `case:` (default) line | that case clause (up to the next case); cursor to the `switch` keyword | |
  |   | one of several case values `case 1, 2:` | that value and one separator | |
  |   | a lone case value | its typed dot (already a dot: nothing) | |
  |   | a type switch's variable | nothing (kept; LT+A renames it) | |
  |   | any other part of an if / else / switch / case line | nothing | |
  |   | `if` / `switch` keyword | falls through: whole statement incl. all branches (row 14) | |
  | 6 | anywhere on an `@(...)` line / a struct directive / a calling convention / a `when` condition / an `#assert` message | that attribute (the line goes with its last one) / directive / convention / back to a `bool` dot (already a dot: nothing) / back to the empty message dot | ctrl.odin `ctrl_delete`, when_cond.odin `when_cond_delete` |
  |   | elsewhere on a `when` / `else when` / `else` line | `when`: the whole when-chain. `else when` / `else`: that branch | |
  |   | the `#assert` keyword, or its condition when that is a single part | falls through: the line goes (row 15; code-derived) | |
  | 7 | loop header part | label (also of a labeled `{` block), `#reverse`/`#unroll`, 2nd variable → removed. 1st variable when a 2nd exists → `_` (alone: nothing). The iterable (any part of it, e.g. `10` in `0 ..< 10`) → an untyped dot (already a dot: nothing). A condition → a `bool` dot, and LT+B on that dot removes the condition (`for {`). C-style init/cond/post → removed. Any other header part: nothing. On `for` itself → falls through: whole loop | loops.odin `loop_delete` |
  | 8 | the type of a conversion `T(x)` / `cast(T)x` | unwrap to `x` | expr.odin `expr_delete` |
  |   | an operand of an operator or ternary, the value of a conversion, or an argument of a call that is **not the line's own top-level call** (`x := f(g(●))`, and also `"Testing"` in `windows.MessageBoxW(nil, windows.L("Testing"))`) | a dot typed for that position (`unit_expected`). Probe: LT+B on `"Testing"` gives `windows.L(●)` with the cursor on the dot | |
  |   | the name of a call that is such a part (e.g. `f` in `x := a + f(b)`, or `h` in `foo(g(h(x)))`) | the whole call becomes one typed dot | |
  |   | such a dot in a chain of 3+ operands `a \| ● \| c` | that operand and one adjacent operator: `a \| c` | |
  |   | such a dot in a 2-operand operator or ternary | the whole operator becomes one dot | |
  |   | such a dot as a conversion's value | the conversion goes (leaving the dot) | |
  |   | a dot that is a nested call's argument | nothing (already a dot) | |
  | 9 | a name declared from a bare call (`n := len(s)`) | uncapture (§10) | capture.odin `uncapture` |
  | 10 | a `$T` parameter of a polymorphic struct / a member of any one-line data body (`enum {A, B}`, `struct {a: int}`, ...) / one name of `x, y: f32` (one-line, or a multi-line struct/bit_field member line) | just that parameter / member / name (`$K, $V: typeid` minus V keeps `$K: typeid`; an emptied one-line body becomes `{}`). On the shared type of a one-line member, the whole member: `struct { a: int, x, y: f32 }` → `struct { a: int }`. On a multi-line member line with one name, or on its type: falls through (the line goes) | data_types.odin `delete_type_part`, data_member_edit.odin `delete_shared_member_name` |
  | 11 | the green "fields" dot of an empty literal `T{●}` | back to the value dot it came from (`x: T = ●` re-hinted). With fields set: nothing | block_delete.odin `lit_fields_dot_delete` |
  | 12 | the `●` of a typed declaration `name: T = ●` / one field of a struct literal | `name: T` / that field and its comma. The fields dot is re-added; a one-per-line literal emptied becomes `T{}` | struct_lit.odin `lit_delete_selected` |
  | 13 | the name or `::`/`:=` of a file-scope declaration that has `@(...)` lines, or sits inside a file-scope `when` | with its attribute lines / just that declaration (not the whole `when`) | ctrl.odin `ctrl_delete_declaration` |
  | 14 | any line containing `{` or `}` | file scope: the **whole construct** (`construct_range`) unless the line is balanced. In a body: a line opening a block → through its matching close; a line starting with `}` → the statement whose block it closes; a balanced line (`q := T{a = 1}`, `return T{}`) → just that line | block_delete.odin `block_delete_range`, model.odin `delete_construct` |
  | 15 | anything else | **just this line** | model.odin |

- **Rules & edge cases** (re-probed at baseline for this doc, and traced through `expr_delete` / `unit_chain`):
  - LT+B on any *direct* part of the **statement's own top-level call** deletes the **whole statement**: an
    argument (probe: `nil` of `windows.MessageBoxW(nil, ...)`), the callee, an empty argument dot, the "add
    argument" dot, or the *name* of a nested call used directly as one of its arguments (probe: `L` of
    `windows.L("Testing")`). Why: `unit_chain` puts the statement's call on top, and `expr_delete` only acts when
    the parent is an operator, a conversion, or a call at depth ≥ 2. The arguments *of* that nested call are at
    depth 2 and do become typed dots (row 8). The same holds for `x := f(a)`: LT+B on `a` deletes the line. Use Y
    to replace an argument instead.
  - LT+B on a declared name whose value is not a bare call (`x := a + b`), or on its `:=`, deletes the statement.
  - LT+B on `package main` deletes it with no guard. LT+B on an import deletes the import line
    (`test_delete_selected_single_import`).
  - LT+B on an ordinary procedure **parameter name** in a header deletes the **whole procedure** (row 14; there is
    no parameter handler). Probe: LT+B on `a` in `foo :: proc(a: int, b: int) -> int {` removed all of `foo`.
    See Open questions.
  - There is **no undo**. Deletes are immediate. (The demoted `src/buffer` package has `undo` / `redo` stubs that
    return false; nothing calls them.)
- **Rationale**: block_delete.odin says a body line deletes "only the statement the line belongs to ... never the
  whole enclosing procedure". expr.odin says LT+B turns a part into "a dot of the type it expects", so the hole is
  immediately refillable with type-checked options.
- **Source**: model.odin `delete_selected`, `delete_construct`, `construct_range`, `brace_delta`, plus the handlers
  named in the table; expr.odin `unit_chain`, `part_to_dot`. Tests: model_test.odin
  `test_delete_selected_single_import`, `test_delete_selected_proc_body_line`,
  `test_delete_selected_block_header_deletes_whole_block`, `test_delete_on_dot_is_noop`; capture_test.odin
  `test_delete_captured_name_leaves_the_call`, `test_delete_typed_captured_name_keeps_package`,
  `test_delete_one_of_several_names`, `test_delete_other_names_still_deletes_the_line`; integrate_fixes_test.odin
  `test_fix_chain_dot_delete`, `test_fix_dot_after_blank`; review_fixes_test.odin `test_review_delete_*`.

### 18. Change (Y): what Y offers on each kind of part

- **Trigger**: the `Change` action (plain Y by default). Target: the sticky walk Unit if any, else the leaf under the
  cursor. On a dot between lines (green, body or purple) Y does **nothing** (probe). `tree_sticky` is cleared once
  the target is found, so a second Y acts on the leaf. Y only works in the Editor state (in menus X/Y do nothing).
- **Behavior**: `change_selected` tries, in order:

  | # | Part | Y does | Cancel (B) |
  |---|---|---|---|
  | 1 | a line of a `/* */` comment | inserts a new text line after it (before `*/` when on `*/`), cursor on it for dictation | n/a |
  | 2 | the type of a conversion `T(x)` / `cast(T)` / `transmute(T)` | `"Convert"` menu: all forms, the expected type pinned, unfit types grayed. The choice rewrites the conversion keeping `x` | unchanged |
  | 3 | `if` / `else if` / `else` / `switch` / `#partial` / `case` keyword | that construct's options menu, titled `"If"` / `"Else if"` / `"Else"` / `"Switch"` / `"Case"` (doc 05) | unchanged |
  |   | an if/switch condition, or one case value | refill (row 11 behaviour, branch.odin's own `refill`) with the condition's / case's dot | original back |
  |   | a dot on such a line | falls through to row 8 (same as A) | |
  | 4 | a `when` condition / `when` / `else when` / `else` keyword | condition refill / `"When"` menu: `Add else when`, `Add else` (grayed if there is one), `Change condition` (not on `else`) | unchanged (`test_review_change_condition_cancel`) |
  |   | `#assert` | `"#assert"` menu: `Change condition`, `Add message` (grayed when it has one) | |
  |   | a calling convention / struct directive / an `@(...)` line | `"Calling convention"` / `"Struct directives"` / `"Attributes"` menu (doc 04) | |
  | 5 | an assignment operator ` = `, ` += ` | `"Operator"` menu of assignment operators; the current one and type-unfit ones grayed (`&&=` for an int) | unchanged |
  |   | `break` / `continue`; a loop's `for`, label or directive; a labeled block's label | jump menu (titled with the word, listing it alone and with each label in scope) / `"Loop"` options menu (doc 05). Grayed options cannot be chosen (the menu stays open) | |
  |   | a `for-in` loop variable | toggles by-reference `&v` (removes an existing `&`; adds one only on the variable the iterable allows: the element, a map's value; never for strings, ranges or `#unroll`) | n/a |
  | 6 | a call's name (`Callee`) | `"Change procedure"`. For `pkg.f`: that import's procs (nothing happens if `pkg` is not an import of this file). For an unqualified call: this package's procs and built-ins (the "from an import" group is left out). Picking renames the call and **resets all arguments** to fresh dots typed for the new signature: one per *required* parameter (parameters with defaults get none), plus an "args" dot if variadic (`test_y_on_proc_name_to_fewer_params_resets_arguments`: `MessageBeep` leaves one `UINT` dot). The cursor goes to the first new dot (`focus_first_dot_in`), or the name if there are no parameters. (change.odin's header comment still says "arguments kept"; the code resets them.) | unchanged |
  | 7 | a declaration operator `:=` / `:` / `::` | `"Declare as"` with exactly: `<name> := value   (type inferred)`, `<name>: type = value   (choose the type)`, `<name> :: value   (constant)`, none grayed. "typed" turns the operator into `: ` and inserts a `type` dot and ` = ` before the value, then opens that dot's `"Fill slot"` menu (`Type`, `Variable`) at once; on an already typed declaration it does nothing. Going back from typed (infer / const) drops the type and keeps the value; `x: T` with no value gets a value dot | unchanged. **But B in the type menu that "typed" opened does not revert**: probe at baseline, `x := 5` → typed → B leaves `x: ● = 5` |
  | 8 | any slot dot inside a line (orange, capture, fields, more-results) | **same as A** (its fill menu; a capture dot captures) | per menu |
  | 9 | the type of a struct literal `T{...}` | refill the **whole literal** with a value dot expecting the declared type | literal back |
  | 10 | a string literal (exactly its quotes and its editable text) | `"Text"` menu: **`Replace value`** first if it sits in a value position (`is_arg`; choosing it does the row 11 refill), then `Case`, `Escape`, `Edit word by word` | unchanged |
  | 11 | any other part in an argument / operand / right-hand-side position (`is_arg`): `nil`, `3`, `a + b`, `windows.L("x")`, the `5` of `count := 5` | **refill** (`begin_refill`, below) | **original fields restored exactly** |
  | 12 | an assignment target (`x` in `x = 3`, `x += 1`) | reference pick of a declared name or one of its fields (§16) | target unchanged |
  | 13 | anything else | falls back to Edit (§19) on that part's first field. Probes: a declared name (`count` of `count := 5`) → `"Text"` with `Case`; a filled type (`int` of `w: int = 7`) → `"Edit Type"`; an import path → `"Edit import"`; a struct member name → nothing. A number in a value position never gets here (row 11); use LT+A for the keypad | per menu |

  **Refill mechanics** (`begin_refill`):
  1. Compute the expected type with `unit_expected`, from the first source that knows:
     - `expected_for`: only on a line with an outermost call or literal not at field 0; it walks down from that
       unit (`expected_in`) using the parameter type of each enclosing call's signature (by `arg_idx` among the
       *required* parameters; past them, the variadic type), the struct literal field's type, the operator's rule
       (`op_operand_expected`; a ternary's condition is `bool`), and "anything" for a cast's value;
     - else `rhs_expected` (field_access.odin): `a.b = ●`, `x: T = ●`;
     - else `loop_expected` (loops.odin): a loop's condition or post.

     A hint written in this file is interned (`intern_hint`).
  2. Move the part's fields into `refill_saved`. Ownership moves; nothing is freed.
  3. Put a `value` slot with that hint in their place.
  4. Open `"Fill slot"`. Unfit fills are dimmed (`test_y_on_argument_refills_and_cancel_restores`: refilling
     `hWnd` dims `Number`).
  5. Choosing a fill discards the saved fields. B restores them verbatim, with the cursor back on them. If the menu
     could not open, the fields are restored at once.
- **Example**:

  ```odin
  windows.MessageBoxW(nil, ...)   Y on `nil`  -> windows.MessageBoxW(●HWND, ...) + Fill slot; B -> back to `nil`
  windows.MessageBoxW(...)        Y on `MessageBoxW`, pick MessageBoxExW
                                  -> windows.MessageBoxExW(●HWND, ●LPCWSTR, ●LPCWSTR, ●UINT, ●WORD)
  ```
- **Source**: change.odin `change_selected`, `begin_refill`, `refill_restore`, `refill_discard`, `unit_expected`,
  `expected_for`, `expected_in`, `open_change_call_menu`, `apply_change_call`, `open_decl_form_menu`,
  `apply_decl_form`; expr.odin `conv_change`; branch.odin `branch_change`; ctrl.odin `ctrl_change`; loops.odin
  `loop_change`; block_comment.odin `block_comment_change`; text_tools.odin `open_text_tools`. Tests:
  selection_test.odin; review_fixes_test.odin `test_review_change_literal_type`; integrate_fixes_test.odin
  `test_fix_mixed_chain_operand_expected`.

### 19. Edit (LT+A): what Edit offers on each kind of part

- **Trigger**: the `Edit` action (LT+A by default). It acts on the leaf's primary field (`editor_target`), never on
  a sticky Unit. Edit *replaces* or *reshapes* a filled part. It never refills a position (that is Y).
- **Behavior** (`edit_selected`, in order):
  - **A filled type field** (kind `type`, e.g. a result type, a declared type): `"Edit Type"` with a `Type`
    submenu, plus `Drop <wrapper>` (e.g. `Drop [8]`) when the type is wrapped. Runs in replace mode; the choice
    overwrites that field.
  - **A number**: the `"Number"` keypad, entries in this order (not sorted): `1`–`9`, `0`, `A`–`F`, `0x`, `.`,
    `Del`, `OK`, with keys that cannot apply dimmed (A–F before `0x`, ...). A loaded number literal (fixed text)
    becomes editable first, unless it is negative. Each key edits the number in place (`Del` on one digit or on
    `0x` gives `0`; `0x` only applies to `0`; `.` only once and not in hex); OK or B closes. **B does not revert
    keys already pressed.**
  - **Any part of a line whose text starts with `import `**: `"Edit import"`, the whole Add menu (probe: `File Setup`,
    `Dependencies`, `Procedures`, `Types`, `Values`, `Compile-time`, `Modifiers`) with `Dependencies`
    pre-highlighted. Picking an import path replaces the whole import line (an alias is added when needed).
  - **Text tools** (`open_text_tools`, title `"Text"`; doc 08). The entries depend on the field (probes):
    - a string's text: `Case`, `Escape`, `Edit word by word`;
    - a `//` comment's text: `Word case`, `Backticks`, `Edit word by word` (only `Edit word by word` when empty);
    - a plain editable name (kind `""`, e.g. `count`): `Case` only.

    Any other editable kind (probe: a struct member name `x` in `x, y: f32`) gets nothing. B closes with no
    change. Applying `Case` to a declaration's name asks `"Rename <old> to <new>?"` (doc 08).
  - **Anything else**: nothing. That covers dots, keywords, `:=`, assignment operators, a call's name and fixed
    text.
- **Source**: model.odin `edit_selected`, `open_type_menu_for_edit`; expr.odin `number_keypad_open`, `number_key`;
  text_tools.odin. Tests: `test_edit_selected_type_field`, keymap_test.odin `test_keymap_update_edit_and_menus`.

### 20. Cancel / B everywhere

B is never an edit. In menus it pops **one** level (`menu_cancel` → `pop_menu`). Only when the last level closes does
the mode-specific restore run. Tests use `for app.state == .Radial do update(app, Input{cancel = true})`.

| Context | What B restores / does |
|---|---|
| Editor, nothing open | back to the main menu (document stays loaded) |
| Add menu / Fill slot opened with A | closes; nothing changed |
| Statement menu from a body dot | temporary line removed, a reused blank line put back, cursor on the same dot (file byte-identical) |
| Y refill (argument, value, condition, case value, literal type) | the original fields, exactly; cursor on them |
| Change procedure, Declare as, Convert, assignment-operator / loop / branch options | nothing changed |
| The type menu that Declare as > typed opened | closes; the new type dot **stays** (`x: ● = 5`, probe) |
| LT+A Edit Type / Edit import | replace mode cleared; nothing changed |
| Text tools | closes without change |
| Number keypad | closes; digits already applied stay |
| Compile-time / modifier options | closes; if opened from a modifier pick, back to picking |
| Attributes from a purple dot | closes; cursor stays on the purple dot |
| Refactor menu | closes; nothing lifted |
| Lifted (Grab) | every move and re-indent undone exactly; the RT selection is the put-back construct |
| Lifted (Copy line) | the copy is removed; cursor on the original |
| Reference pick | back to the still-empty dot in the editor (the Fill slot menu is not reopened). From a Y-refill: original restored. For a just-added Assignment: that new line is removed, with notice `"nothing declared to assign to here - declare it first (Declarations > Variable)"` if there was nothing to pick |
| "Pass as" / "Assign to" menu | back to picking the name |
| Modifier pick | stops picking |
| `"Rename <old> to <new>?"` prompt (doc 08) | only the edited occurrence changes |
| IDE menu (LT+Left) | back to the state it was opened from (`return_state`), e.g. still lifted |

B in a menu is read raw, so LT+B / RT+B there also act as B (probe). A plain B with nothing open in the editor
never deletes anything; it is the main-menu exit, which is why an unbound trigger + B is swallowed instead of
falling through (§6).

Source: model.odin `menu_cancel`; change.odin `refill_restore`; body_dots.odin `body_insert_cancel`; grab.odin
`grab_cancel`; ctrl.odin `ctrl_menu_cancel`; ref_pick.odin `ref_pick_cancel`, `ref_pass_cancel`; field_access.odin
`assign_pick_drop`.

## Invariants & constraints to carry forward

1. **HARD**: no caret. The cursor is always exactly one stop: a dot between lines (green or purple) or one leaf of a
   line. After every structural change it is snapped onto a valid stop (`normalize_cursor` / `clamp_field`).
2. **HARD**: stops are derived from the document on demand. On each boundary the order is green dot, purple dot,
   line (`stop_key`; `test_dots_reachable_between_constructs`, `test_attr_dot_is_a_cursor_stop`). Up/Down never
   wrap (same test: Up on the top dot stays); Right never wraps (`min(cnt-1, ...)` in `update`); Left wraps only
   within a visual row (`test_row_nav_left_wraps_to_end_dot`).
3. **HARD**: one green dot per file-scope gap (`test_one_dot_per_gap`). Body dots sit above, between and below
   statements at every nesting level, but never next to an empty `●` statement line, between two blank lines, or
   between a blank line and `}` (`test_empty_function_has_one_dot`).
4. **HARD**: Up/Down walk the rows of a line broken over several rows before leaving it, entering from below on its
   last row (`test_row_nav_up_down_through_broken_call`).
5. **HARD**: a held d-pad repeats as ordinary press events (0.35 s delay, then every 0.07 s), except while
   dictating. Recordings and replays see identical presses (`test_dpad_repeat`).
6. **HARD**: plain d-pad, A and B are locked navigation everywhere, menus included. An unbound trigger+face button
   is swallowed; an unbound trigger+d-pad still moves (`test_keymap_resolve`). Locked slots refuse other actions,
   walks must be on a trigger, Talk on a face button (`test_keymap_assign_rules`).
7. **HARD**: the logic is pure and driven by an abstract `Input` (`update(app, Input)`). Every behaviour in this doc
   is testable headlessly by feeding presses.
8. **HARD**: a walk starts at the cursor's own statement (or the block its line opens), not the enclosing procedure,
   and continues where it left off while the cursor has not moved (tree_start_test.odin).
9. **HARD**: a walked-to *part* stays selected after RT is released (sticky), and Y / Docs act on it
   (`test_rt_tree_navigation`). A plain d-pad move ends it: enforced by the anchor check in `tree_ensure`; the
   test's last assertion (`!tree_sticky` after a Right) passes trivially because the Y before it already cleared
   the flag, so this half is not really pinned.
10. **HARD (with Doodle's exceptions)**: while something is lifted, every editor input other than
    step/jump/drop/put-back is ignored (`test_grab_cancel_puts_it_back` presses LT+B mid-grab). Doodle leaks: the
    IDE menu (LT+Left) still opens, LT+X (Talk) drops, and the app's fixed keys (Ctrl+C, RB, LB) still act (§13).
    The Rust version should make the lift modal for every input, or decide each exception on purpose.
11. **HARD**: B on a lift restores the document exactly, re-indentation included (rotation log), and a cancelled
    Copy line leaves the document as it was (`test_copy_line_cancel`).
12. **HARD**: lifted code never leaves its procedure (a move), never enters a switch, a multi-line literal or a
    local type, never goes above a switch's first `case` or above `package`. A copy from inside a procedure can
    only be dropped inside a procedure. Enforcing code: grab.odin `enterable`, `leavable`, `grab_jump`,
    `grab_blocked`. Pinned by tests: never out of the procedure (`test_grab_into_a_for_loop`), never above
    `package` (`test_grab_top_level`), blocked copy drop (`test_copy_line_into_another_procedure`). The switch,
    literal and local-type fences have no test.
13. **HARD**: B after a Y-refill restores the exact original fields (`test_y_on_argument_refills_and_cancel_restores`,
    `test_review_change_condition_cancel`), and cancelling a body-dot insert leaves the file byte-identical
    (`test_body_dot_inside_nested_block_and_cancel`, `test_empty_function_has_one_dot`).
14. **HARD**: editor-only fields (capture dots, unfilled optional dots, the `●` statement line) never reach saved
    source (`test_capture_dots_on_bare_calls_that_return` compares the saved text; serialize.odin drops a `●`
    line, except that a `●` line directly between a block opener (`{` or a `case ...:` label) and its closer (`}`
    or the next `case`) is written as an empty line, giving `{\n\n}`). Capture dots are re-synced after every
    update while keeping the cursor on the same leaf (capture.odin `sync_capture_dots`; implicitly pinned by
    `test_dpad_highlights_name_and_every_argument`, whose reads would be off by one otherwise;
    `test_capture_dot_is_first_stop_on_its_line` pins leaf 0).
15. **HARD**: Delete is a chain of handlers from the finest part to the whole construct; first match wins. Inside a
    body a balanced line never takes its enclosing procedure with it (block_delete.odin `block_delete_range`). A
    part that is an operand, a conversion's value, or an argument of a call other than the line's own top-level
    call becomes a **typed dot** rather than disappearing (`test_fix_chain_dot_delete`, expr_test.odin).
16. **HARD**: Y on an in-line dot equals A. Y / LT+A on a between-lines dot do nothing. LT+B on a between-lines dot
    only removes an adjacent blank line (`test_delete_on_dot_is_noop`, `test_fix_dot_after_blank`). (LT+B on an
    *in-line* dot is a normal part delete: rows 4 to 12 of §17.)
17. **SOFT**: moving into or out of a block re-indents the lifted lines (first line gets the new base, others keep
    their relative indent). Doodle always appends a tab when entering, even in a 4-space file (probe:
    `"    \ty := 2"`), until the next format; a Rust port should use the document's indent unit.
18. **SOFT**: hints name the default buttons and are rewritten to the current layout (`rebind_hint`). The grab hint
    strings are hard-coded.
19. **SOFT**: the "column" carried by Up/Down is a leaf index, reset by every dot. There is no visual-column memory.
20. **SOFT**: no confirmation and no undo for Delete (or for anything else). Safety comes from fine-grained deletes
    and from *menu-driven* changes being cancellable. Given how coarse some deletes are (a parameter takes its whole
    procedure, a direct argument its whole statement), a Rust port should add an undo stack; a document revision
    counter (Carrying to Rust, d) makes snapshots cheap to key.

## Data model & formats

- **Cursor** (on `App`): `editor_line: int`, `editor_field: int` (leaf index), `editor_dot: bool`,
  `editor_attr: bool`. `Cursor_Stop{line, dot, attr}` and `stop_key(line, dot, attr) = line*3 + (dot ? (attr?1:0) : 2)`.
- **Unit** (temp, rebuilt per query): `{fa, fb: field range; kind: Unit_Kind; children: []Unit; is_arg: bool;
  arg_idx: int}`. `Unit_Kind = Field | Callee | Value | Str | Call | Op | Group | Lit`. Leaves are
  `Field/Callee/Value/Str`. `Call/Op/Group/Lit` are expanded for the D-pad.
- **Sel** (walk node): `{kind: Block | Line | Unit; ni, end_ni: int; fa, fb: int}`.
- **Walk state**: `tree_path: [dynamic]Sel` (root → current), plus the anchor it was built for (`tree_line`,
  `tree_field`, `tree_dot`, `tree_nodes`) and `tree_sticky: bool`.
- **Highlight**: `{ni, end_ni, fa, fb}`, where `fb = -1` means whole lines.
- **Grab state**:
  - `grab_active`, `grab_copy`;
  - `grab_sel: Sel` (Line or Block), the lifted lines;
  - `grab_top: bool`, `grab_proc: Sel`, the procedure it may not leave (in fact `path[0]`, the top-level construct);
  - `grab_indent: string`, the original indentation of the first lifted line (owned);
  - `grab_ops: [dynamic]Grab_Op{lo, hi, first, sel}`.
- **Refill state**: `refill_active`, `refill_ni`, `refill_fi`, `refill_saved: [dynamic]Field` (owned originals).
  Change-call state: `change_call`, `change_ni`, `change_fi`. Decl form: `decl_form_active`, `decl_ni`, `decl_fi`.
  Replace mode (LT+A): `replacing`, `replace_ni`, `replace_fi` (`-1` = whole line).
- **Body insert state**: `body_insert_active`, `body_insert_ni`, `body_insert_reused`, `body_insert_blank` (text of
  a reused blank line).
- **Capture**: `capture_fp: u64` (FNV-1a over field texts + slot flags, 0 forces a re-sync).
- **Input**: `{confirm, cancel, up, down, left, right, x, y: bool edges; lt_held, rt_held: bool levels}`.
  `Resolved{fired: Actions, rest: Input}`. `notice: string` is a one-shot status message. `requests: Actions` are
  actions the app layer performs.
- **Keymap**: `slots: [3 banks][Up,Down,Left,Right,A,B,X,Y]Action`, persisted as `doodle_keys.tsv` (doc 03).
- **Field kinds this area reads**: selectable kinds `decl`, `kw`, `brkw`, `assign_op`, `conv`, `import_path`,
  `comment_mark`. Slot kinds: `""`, `params`, `type`, `value`, `body`, `args`, `capture`, `fields`, `ret_more`,
  `res_more`, `setup`, `variant`. Others: `comment`, `litkey`, `lit`, `tern`, `label`, `string`, `poly`, `member`.
- **Constants**: `MAX_COLS = 80`, `TAB_COLS = 4`, `DPAD_REPEAT_DELAY = 0.35`, `DPAD_REPEAT_EVERY = 0.07`, the
  analog trigger threshold `0.5`, walk descent cap 64 levels.
- **Menu titles this area opens** (exact strings): `"Add  (insertion point)"` (two spaces), `"Fill slot"`,
  `"Attributes"`, `"Refactor"`, `"Change procedure"`, `"Declare as"`, `"Convert"`, `"Operator"`, `"Loop"`, `"If"`,
  `"Else if"`, `"Else"`, `"Switch"`, `"Case"`, `"When"`, `"#assert"`, `"Calling convention"`,
  `"Struct directives"`, `"Text"`, `"Number"`, `"Edit Type"`, `"Edit import"`, `"Pass as"`, `"Assign to"`,
  `"IDE MENU"`; the jump menu is titled `break` / `continue`.
- **Notices / status strings**: `"Nothing here to move"`, `"A copy from inside a procedure can only be dropped
  inside a procedure"`, `"nothing declared to assign to here - declare it first (Declarations > Variable)"`,
  `"copied N line"` / `"copied N lines"`, `"nothing to copy"`, `"copy failed"`. Hints: see §6, §9, §13.

## Tests that pin this behavior

| Test (file) | Asserts |
|---|---|
| `test_dpad_highlights_name_and_every_argument` (selection_test) | Right steps through `MessageBoxW \| nil \| L \| "Testing" \| L \| "Testing again" \| ● \| ●` (the last `●` twice: Right stops at the end); implicitly, the capture-dot sync keeps the cursor on the same part |
| `test_rt_tree_navigation` (selection_test) | Walk roots → block → header → statement → callee → argument call → its parts → out; sticky part stays highlighted after release; Y refills the whole part; `!tree_sticky` after a plain move (trivially true: Y already cleared it) |
| `test_y_on_argument_refills_and_cancel_restores` (selection_test) | Y on `nil` → HWND-typed dot, `Number` dimmed; B restores text and cursor; a second Y + `Reference` replaces it |
| `test_y_on_proc_name_changes_it_and_resets_arguments`, `..._to_fewer_params_...` (selection_test) | Change procedure renames and re-dots the arguments with the new signature's hints |
| `test_y_on_string_inside_nested_call` (selection_test) | Y on a string argument → `Replace value` first; the dot expects `string` |
| `test_walk_starts_at_the_cursor_line`, `test_walk_start_on_a_block_line`, `test_grab_starts_at_the_cursor_line` (tree_start_test) | Walk start, widening with Walk_Out, resume without cursor move, `}` → enclosing block |
| `test_row_nav_up_down_through_broken_call`, `test_row_nav_left_wraps_to_end_dot`, `test_one_dot_per_gap` (row_nav_test) | Row navigation, Left wrap, one dot per gap |
| `test_dots_reachable_between_constructs`, `test_insert_at_middle_dot`, `test_insert_at_top_dot`, `test_delete_on_dot_is_noop`, `test_insertion_points` (model_test) | Stop order incl. purple dot; insertion positions; LT+B on a dot |
| `test_delete_selected_single_import`, `..._proc_body_line`, `..._block_header_deletes_whole_block` (model_test) | Line vs block deletion |
| `test_edit_selected_type_field` (model_test) | LT+A on a type → replace mode on that field |
| `test_body_dots_positions`, `test_body_dots_are_cursor_stops` (body_dots_test) | Exact body dot boundaries; trail `dot9 9 dot10 10 dot11 11 dot12 dot13 13` |
| `test_declare_variable_between_statements`, `test_body_dot_inside_nested_block_and_cancel`, `test_empty_function_has_one_dot`, `test_blank_lines_between_statements_get_one_dot` (body_dots_test) | Insert at a body dot (one new line, right indent), cancel is byte-identical, blank-line reuse |
| attr_dots_test (`..._is_a_cursor_stop`, `..._opens_attributes`) | Purple dot order, menu, B stays on it |
| capture_test (all) | Which lines get a capture dot, leaf 0, A captures (1 or 2 names), loaded indent kept, sync follows callee, uncapture variants |
| grab_test (all 11) | Slide, put back, into/out of blocks, jump, nested for, top level, drop with X/A, Refactor menu, Copy line into another procedure, blocked drop + notice, copy cancel, top-level copy |
| `test_keymap_resolve`, `test_keymap_update_delete_stays_in_editor`, `test_keymap_update_change`, `test_keymap_assign_rules` (keymap_test) | Bank resolution and swallowing; LT+B ≠ Back; Y via update = `change_selected`; locked slots, walks only on a trigger, Talk only on a face button |
| `test_delete_captured_name_leaves_the_call`, `test_delete_typed_captured_name_keeps_package`, `test_delete_one_of_several_names`, `test_delete_other_names_still_deletes_the_line` (capture_test) | Uncapture variants (listed separately because §17 row 9 depends on them) |
| `test_fix_chain_dot_delete`, `test_fix_dot_after_blank` (integrate_fixes_test) | Operand → dot → operand gone; LT+B on a dot removes the blank line |
| `test_review_delete_literal_line_parts`, `test_review_delete_shared_member_names`, `test_review_delete_part_of_attributed_declaration`, `test_review_change_condition_cancel`, `test_review_change_literal_type` (review_fixes_test) | Fine-grained deletes; Y on a literal's type; cancel restores |
| expr_test.odin (conversion / ternary sections) | LT+B unwraps `T(x)`, nested argument → typed dot, ternary collapse |
| `test_copy_selection_source` (format_test) | Line / block / whole proc / whole file on a dot |
| `test_dpad_repeat` (platform_test) | Repeat timing, ~14/s, off while dictating, off when released |

## Carrying this to Rust

**(a) What transfers unchanged.** The whole interaction design is language-agnostic and should be copied as-is:
- stops instead of a caret (dots between lines, leaves within a line), and the green → purple → line order;
- Up/Down between stops, Left/Right between leaves with the row-end wrap, rows of broken lines, hold-to-repeat timing;
- the three banks with locked plain d-pad/A/B, swallowing rules, and the default layout;
- the RT walk over Block → Line → Unit, starting at the cursor's statement, sticky for parts;
- Delete as a finest-first handler chain where parts become typed holes;
- Y = "change this part": refill with a typed hole, B restores exactly;
- LT+A = "edit this filled thing";
- the Refactor menu with Grab / Copy line, step/jump/drop/put-back, the rotation undo log and the scope fences;
- capture dots / uncapture;
- B semantics per mode (§20);
- a pure model driven by an abstract `Input`, so every rule is a unit test.

**(b) Odin-specific pieces → Rust.**
- `bit_set[Pad_Button]` / `Actions` → `enumset::EnumSet` or `bitflags`.
- `[Action]Action_Info` enumerated arrays → `match` in a `const fn info(self)`, or `enum_map`.
- `union` events → `enum`.
- Field `kind` strings (`"decl"`, `"capture"`, ...) → a `FieldKind` enum. Positional `Field{...}` literals →
  constructors.
- The `defer`red post-update syncs → `fn update(&mut self, i: Input) { self.update_inner(i); self.post_sync(); }`.
  Odin runs defers on every early `return`; a wrapper keeps that guarantee.
- `p := grab_place(app) or_return` in `grab_step` (which returns `bool`) → `let Some(p) = self.grab_place() else
  { return false; };` (let-else). A bare `?` only works if the Rust function itself returns `Option` / `Result`.
- `#reverse for` → `.iter().rev()`. `#partial switch` → `match` with `_ => {}`.
- `inject_at` / `ordered_remove` / `remove_range` → `Vec::insert` / `remove` / `drain(a..b)` / `splice`.
  `rotate_lines(lo, hi, first)` → `nodes[lo..=hi].rotate_left(first)`; its undo is `rotate_right(first)` on the
  same range.
- Manual `delete(f.text)` / `strings.clone` → owned `String`. `refill_saved` "ownership moves" →
  `let saved: Vec<Field> = fields.splice(u.fa..u.fb, [hole]).collect();` (the `Splice` iterator yields the
  removed fields; collect it before touching `fields` again), and the restore is
  `fields.splice(fi..fi + 1, saved);`.
- `context.temp_allocator` units and leaves → owned `Vec<Unit>` (or a per-frame `bumpalo` arena, or per-revision
  caches).
- The many `*_active` bools and parallel `*_ni`/`*_fi` ints on `App` → `Option<GrabState>`, `Option<Refill>`,
  `Option<BodyInsert>`, or one `enum Mode { Normal, Grab(..), RefPick(..), WordEdit(..), ModPick(..) }`, so illegal
  combinations cannot exist.
- `@(private="file")` → a module-private `fn`.
- `@(test)` + `testing.expect_value` → `#[test]` + `assert_eq!`.

**(c) Rust concepts Odin lacks, and how this UI extends to them.**
- **Expression-oriented blocks**: `let x = if c { a } else { b };`, `match`, closures and `async {}` put multi-line
  blocks *inside* a statement's expression. The walk tree needs a Unit that may span lines (or a Block child under
  a Unit). Grab's "enterable" set should become `if`/`else`/`loop`/`while`/`for`/bare `{}`/`unsafe {}` bodies and
  match-arm block bodies. Statements must not go between match arms, the analog of "not into a switch".
- **Match arms** are siblings with dots between them (add arm). LT+B on an arm deletes just that arm, the analog of
  a case clause.
- **Method chains** `a.iter().map(f).collect()`: the Callee is the method name. Y offers the receiver type's
  inherent and trait methods in scope, adding the `use` for a trait if needed. Long chains break one `.call()` per
  row; row navigation applies unchanged.
- **Macros**: `println!`/`format!`/`vec!`/`assert_eq!` behave like calls (format string + typed arguments). Unknown
  macro bodies are opaque `Value` leaves.
- **Ownership / borrows**: refill typed for `&T` / `&mut T` / `T` should offer pass-as variants (`x`, `&x`,
  `&mut x`, `x.clone()`, `x.into()`), the analog of Doodle's "Pass as". Grab may move a statement above a `let` it
  needs or past a borrow's end. Run diagnostics after each drop and show the result; optionally gray drop positions
  where the moved code's free variables are out of scope.
- **Option/Result**: keep A on a capture dot immediate (`let name = call();`). Put `?`, `.unwrap()`, `.expect("…")`,
  `if let`, `match` on Y of the call. Uncapture of `let x = f();` gives `f();`. For a `#[must_use]` result keep or
  offer `let _ = f();`.
- **Declarations**: "Declare as" becomes `let x = v` / `let x: T = v` / `let mut x = v` / `const X: T = v` /
  `static X: T = v`. `const` and `static` always need the type and a constant-evaluable value, so gray them (with
  the reason) when the value is not const, and give "typed" a cancel that removes the type hole again (Doodle's
  leaves `x: ● = v`, §18 row 7). Patterns `let (a, b) = pair();` reuse the "deleted name → `_`" rule.
- **Visibility and attributes**: `pub` / `pub(crate)` behave like Doodle's keyword fields (Y = options, LT+B =
  remove). Purple dots go above every item (fn, struct, enum, impl, trait, mod, const) and offer `#[derive(..)]`,
  `#[cfg(..)]`, `#[test]`, `#[inline]`, `#[must_use]`, `#[allow(..)]`, filtered and grayed per item kind the way
  Doodle's `ATTR_OPTS` carries a kind set: `derive` only on struct / enum / union, `inline` only on fns, `#[test]`
  grayed for a fn with parameters, generics, or a return type other than `()` / `Result<(), E>` (the analog of
  `test_attr_dim`). `#[test]` should set up `#[cfg(test)] mod tests { use super::*; }`, the analog of @(test)
  adding `core:testing`. Attributes must move with their item when it is grabbed (Doodle's do not, §13).
- **Generics and lifetimes**: `<T: Trait>`, `<'a>` and `where` clauses are fine-grained deletable units, like `$T`
  params.
- **Modules / `use`**: `use` lines are the import analog. LT+A on one gives a path picker.
- **Traits / impl blocks** are bodies whose dots offer items (fn, const, type), like data bodies offering members.

**(d) Implementation advice.**
- Parse with a lossless, error-tolerant CST. **`ra_ap_syntax`** (rowan, what rust-analyzer uses) or **tree-sitter-rust**.
  Do not use `syn`, which drops comments and whitespace. Doodle's line-of-fields model then becomes a *projection*
  of the CST: each displayed line's leaves are CST tokens that are holes, identifiers or keywords. The navigation
  rules above can stay line-based.
- Use **rust-analyzer** as the oracle:
  - signature help for parameter types (`expected_for`);
  - the expected type at a hole (completion's expected type) for graying menu entries;
  - method resolution for "Change procedure";
  - hover/docs for LT+Y;
  - assists: `extract_variable` ≈ capture, `inline_local_variable` ≈ uncapture, `remove_unused_param` for the
    parameter-delete gap. rust-analyzer has no general "change signature" assist (as far as this author knows);
    deleting a used parameter needs your own call-site rewrite (each call's matching argument → removed).

  Its experimental `moveItem` request is close to Grab's jump, but Grab's enter/leave-block stepping and exact undo
  log are worth keeping in-house. Embed via `ra_ap_ide`, or run rust-analyzer as an LSP subprocess.
- Invalidate walk paths and stop caches on a **document revision counter**, not "same cursor and same line count"
  (see Open questions).
- Use `rustfmt` for formatting. Its `max_width` (100) can replace Doodle's 80-column break threshold.

## Open questions & known gaps

Status of each item: *confirmed* = re-probed at baseline for this doc (throwaway tests run against a scratch copy
of src/model outside the repo, since deleted) and traced in the code; *code* = read from the code, not run.

- **Delete vs. sticky selection mismatch** (confirmed): Y and Docs act on a sticky walk Unit, but Delete and Edit
  act on the leaf under the cursor, which is the Unit's first leaf after a walk. Walking to `windows.L("Testing")`
  and pressing LT+B deleted the **whole `MessageBoxW` statement**, not the argument; LT+A did nothing. Almost
  certainly unintended. The Rust version should make Delete (and Edit) honour the sticky selection.
- **No per-argument delete for a statement's own call** (confirmed): LT+B on a direct argument, the callee, an empty
  argument dot, the "add argument" dot, or the name of a nested call that is a direct argument deletes the
  statement; the arguments *of* such a nested call do become typed dots (`windows.L(●)`). Cause: `expr_delete`
  requires the part's parent to be an operator, a conversion, or a call at depth ≥ 2 in `unit_chain`. Probably an
  unintended asymmetry; Y-refill is the workaround. The Rust version should give every argument the "becomes a
  typed hole" delete, and a second LT+B on an optional / variadic hole removes it.
- **Deleting a procedure parameter deletes the procedure** (confirmed): there is no handler for ordinary parameters
  in a header, so LT+B on `a` in `foo :: proc(a: int, b: int) -> int {` falls through to `construct_range` and the
  whole procedure goes. (Only `$T` parameters of polymorphic structs and results have handlers.)
- **No undo/redo** anywhere (code: no undo in src/model; the demoted src/buffer has stubs returning false).
  `package main` can be deleted with no guard (code: no handler claims it, so row 15 removes the line).
- **Loaded-code granularity limits stops** (confirmed): a loaded `x := a + b` right-hand side is one `Value` leaf,
  loaded parameter types are not stops, a loaded `return v` value is not a stop (its only leaf is the "more"
  dot), and loaded numbers are `Value` leaves (doc 01). The Rust version's CST projection should make every
  expression node reachable.
- **Walk path invalidation** (code): `tree_ensure` only compares `(editor_line, editor_field, editor_dot,
  len(nodes))` plus a bounds check on the last node. An edit that changes field indexes without moving the cursor
  or the line count leaves a stale path (stale `fa`/`fb` in a Unit; `find_unit` then fails, so Walk_In does
  nothing and Prev/Next do nothing). The capture sync, capture and uncapture clear `tree_path` explicitly; Y only
  clears `tree_sticky`. Fragile.
- **X while lifted** (confirmed): `grab_update` treats **any** raw X press as drop, including LT+X (Talk by
  default); the app may start dictation on the same press (code).
- **The lift is not fully modal** (confirmed for the IDE menu, code for the rest): LT+Left opens the IDE menu with
  the block still lifted; Ctrl+C, RB and LB act during a lift.
- **Attributes are left behind by Grab** (confirmed): `@(...)` lines are separate walk roots, so a lifted procedure
  moves without them, and one Up can leave `@(private)` dangling at the end of the file. Copy line on a procedure
  also copies no attributes (code).
- **Declare as > typed > B** (confirmed) leaves an unfilled type dot (`x: ● = 5`) instead of reverting.
- **`grab_proc` is the top-level construct** (code): for a procedure inside a file-scope `when`, the fence is the
  `when` block, not the procedure.
- Re-indent on entering a block always adds `\t`, even in 4-space documents, until the next format (confirmed:
  `"    \ty := 2"`).
- The grab hint string hard-codes "RT+Up/Down" and "X / A" regardless of the key layout (code: editor_view.odin).
- `editor_move_construct` and `delete_focused_construct` (model.odin) are legacy RT behaviours from before the walk
  tree. They are only referenced by tests (`test_editor_move_construct_steps_by_statement`,
  `test_delete_focused_construct_removes_whole_proc`, `test_delete_on_dot_is_noop`) and could be dropped (code:
  no other caller in src/).
- change.odin's header comment says Y on a call's name keeps the arguments; `apply_change_call` resets them. And
  selection.odin's `focus_first_dot_in` comment cites `MessageBoxW(` fills, but only Change procedure calls it.
- Up/Down column memory is a leaf index that resets at every dot, so it rarely persists. A visual-column memory
  might feel better on a controller; this is an open design choice.
- The change.odin header says Y on "a type / an import → the edit menu". The code matches, by falling back to
  `edit_selected` (row 13). The older UX.md (stick/d-pad "move by token / word", a caret in text) is superseded by
  this model.

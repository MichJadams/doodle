# 01 — Document model, projection, load/save round-trip, formatting and highlighting

> Odin sources: src/model/model.odin, src/model/parse.odin, src/model/serialize.odin, src/model/format.odin,
> src/model/formatter.odin, src/model/block_split.odin, src/model/highlight.odin, src/model/namegen.odin,
> src/model/stmt_layout.odin, src/model/block_comment.odin, src/model/menu_sections.odin, src/model/calls.odin
> (node_source, intern_hint), src/model/selection.odin (line_leaves), src/model/body_dots.odin (body insert),
> src/app/save.odin (write_doc), src/app/filenav.odin (filenav_load), src/app/main.odin and
> src/app/editor_view.odin (dot colors, menu grid drawing). Baseline: Doodle @ 34a2ad1.

## Purpose

Doodle is a *projectional* editor: you never type source characters. The program lives in memory as a list
of **nodes** (one logical source line each), and every node is a list of **fields**. Some fields are fixed
text, some are names you may rename or dictate into, and some are **dots**: typed placeholders you fill
from a menu with the controller. This doc covers how that representation is built, how menus (the only
way to change it) are structured and navigated, how an existing `.odin` file is loaded into nodes and
saved back (byte-for-byte for Doodle-formatted code, with the exceptions listed in invariant 2), how the
document is formatted, how lines are syntax-highlighted, and how default
names are generated. Everything else in the handoff (cursor, constructs, type-driven menus, voice) operates
on this model. The two constraints that shape it: **a gamepad can only pick, not type**, so every construct
must arrive complete with defaults and dots; and **the file on disk is plain source the user owns**, so
whatever Doodle loads it must write back unchanged unless the user changed it.

## Features

### 1. The document is lines made of fields (the projection)

- **Trigger**: Always. Every frame the editor draws `app.doc.nodes`. Every edit (a menu pick, a rename, a
  delete) changes fields or nodes. Nothing else is stored.
- **Behavior**:
  - A `Doc` is `nodes: [dynamic]Node` plus one flag, `no_final_newline`. A `Node` is `fields: [dynamic]Field`.
    A `Field` is `{text, editable, slot, kind, hint, hint_pkg}` (see Data model).
  - The text of a line is the concatenation of its fields' `text` (`node_text`). A dot (slot) has empty text,
    so an unfilled construct's text simply has "holes".
  - There is **no separate AST**. Structure (blocks, construct ranges, which lines are inside a procedure,
    where green dots go, call argument lists) is re-derived from the field texts and kinds whenever needed,
    by brace counting and pattern checks (`construct_range`, `brace_delta`, `insertion_points`,
    `find_arg_list`, `line_units`, ...). Edits never have to keep two representations in sync.
  - Example, a menu-built procedure (Add > Procedures > Procedure, `append_proc_node`):

    ```
    fields:  ["main" editable] [" :: proc( "] [●params] [" ) -> "] [●type] [" {"]
             ["    "] [●body]
             ["}"]
    shown:   main :: proc( ● ) -> ● {
                 ●
             }
    saved:   main :: proc() {
                                  <- the block's only "●" line is written as an empty line
             }
    ```

  - Example, a loaded statement (`\tx := fmt.tprintf("%d", 5)`; fields 0-5 are pinned by
    `test_load_call_statement_shapes`, the rest is read from `emit_expr`):
    `["\t"] ["x" editable] [" := " kind=decl] ["fmt."] ["tprintf"] ["("] ["\""] ["%d" editable kind=string]
    ["\""] [", "] ["5"] [")"]` (plus `[", "] [●args]` before `)` because `tprintf` is variadic). Note the
    loaded callee is split `["fmt."] ["tprintf"]`, while a menu-built call is `["fmt"] ["."] ["tprintf"]`
    (`make_import_proc_call`): loaded and menu-built shapes are close but not identical (invariant 4).
- **Rules & edge cases**:
  - Field text is the *only* source of truth for saving. A field's `kind` and `hint` carry meaning for
    menus, cursor stops and layout, but never add text.
  - Indentation is just leading whitespace in the first field(s). Menu-built lines use 4 spaces; `format_doc`
    rewrites all indentation to tabs (feature 13). The editor draws a tab as 4 spaces.
  - A line whose text Doodle does not recognize is one fixed field holding the whole line. It has no
    selectable part, so the cursor skips it, but it saves exactly as loaded (feature 9).
  - What the D-pad can stop on within a line is derived, not stored: `line_leaves` (selection.odin) turns
    the fields into units (names, dots, a call's name, each argument, operands). Detail in doc 02.
  - The text scans that derive structure are not one shared tokenizer, and they disagree at the edges:
    `brace_delta` (model.odin; used by `construct_range`, Copy, body inserts) returns 0 for a line whose
    first non-space is `//` and for `/* */` lines, but otherwise counts every `{` / `}` byte, **including
    ones inside strings and trailing `// comments`**; `line_balance` (formatter.odin) also counts `(` `[`,
    skips string/rune literals and stops at `//`; `track_blocks` (parse.odin) skips literals and stops at
    `//`. A Rust port should use one lexer for all of them.
- **Rationale**: (EDITOR_MODEL.md §1, §7) "The textual Odin source is a *rendering* of the underlying
  structure." A line-of-fields model keeps that rendering trivially exact: concatenate.
- **Source**: src/model/model.odin (`Field`, `Node`, `Doc`, `node_text`, `construct_range`, `brace_delta`),
  src/model/selection.odin (`line_units`, `line_leaves`, `selectable`).

### 2. Dots: typed placeholders, their kinds and colors

- **Trigger**: A construct is inserted (its unfilled parts are dots), or a file is loaded (unfilled values
  saved as nothing come back as dots; feature 10).
- **Behavior**: A dot is a field with `slot = true`, `text = ""`, a `kind` saying what it accepts, and an
  optional `hint` (the expected type, e.g. `LPCWSTR`) with `hint_pkg` (the import path the hint is written in,
  `""` = this file / builtin). A on a dot opens the "Fill slot" menu for its kind (`open_slot_menu`; the menu
  machinery is feature 5, the per-kind menu contents are docs 05-07); A on a pink capture dot needs no menu
  (it captures the call's result at once, `capture_call_result`). The editor draws the hint as a small gray
  label right of the dot (HINT_COL 0.48,0.45,0.40; `args` dots show it as `..T`).
  Slot kinds and colors (src/app/main.odin `slot_dot_color`; RGB 0..1, outer ring / inner fill):

  | kind (constant) | what it is | color |
  |---|---|---|
  | `"value"` | an expression goes here (argument, initializer, condition, operand) | orange (1.00,0.60,0.15)/(1.00,0.65,0.20) |
  | `"ret_more"` (`RET_MORE_KIND`) | optional "another return value" after a `return`'s values | orange (as value) |
  | `"type"` | a type goes here | blue (0.35,0.70,1.00)/(0.40,0.75,1.00) |
  | `"variant"` (`VARIANT_KIND`) | a type switch `case` label (a union variant) | blue |
  | `"res_more"` (`RES_MORE_KIND`) | optional "another result type" in a proc header | blue |
  | `"body"` | a statement line placeholder, the "●" line inside a block | drawn as a small green dot (COL_DOT 0.15,0.60,0.32) |
  | `"args"` | optional "add another argument" of a variadic / unknown call | small green dot |
  | `"fields"` (`FIELDS_KIND`) | optional "add a field" inside a struct literal `T{...}` | small green dot |
  | `"params"` | "add a parameter" in a proc header | purple (0.80,0.45,0.95)/(0.85,0.50,1.00) |
  | `"capture"` (`CAPTURE_KIND`) | optional "capture this call's result in a new variable" | pink (0.93,0.27,0.60)/(0.97,0.36,0.67), steady (no pulse), smaller (halo r=8 at 20% alpha, core r=4.5), drawn `CAPTURE_DX = 34` px left of the call, in the indentation, so the code doesn't shift |
  | `"setup"` (`SETUP_KIND`) | the setup statement of `if ●; cond {` / `switch ●; x {` | default neutral orange (0.95,0.55,0.20) |

  Not slots, but also "dots" in the UI: **green insertion dots** between lines (where a new construct or
  statement can go; COL_DOT, the one under the cursor pulses), the **purple attribute dot** above each file-scope
  procedure (COL_ATTR_DOT 0.55,0.22,0.88; doc 04), and **yellow word dots** between words while editing a
  string word by word (COL_WORD_DOT 0.90,0.68,0.05; doc 08). Insertion dots are not fields; they are computed
  from the node list (`insertion_points`, `dot_points`, `body_points`; doc 02).
- **Rules & edge cases**:
  - **Optional dots** (`is_optional_dot`: `args`, `fields`, `res_more`, `ret_more`) are never saved, and
    neither is the `", "` field just before one (`node_source`, `range_source`).
  - **Required dots** (`value`, `type`, `params`, `body`, `variant`, `setup`) save as nothing (their text is
    `""`); the loader puts them back where it can (feature 10) - which is only some forms; many are lost on
    reload (invariant 5).
  - A capture dot is not in `is_optional_dot`, but its text is empty so it saves as nothing too; the separator
    rule doesn't concern it because it sits in front of the call. It is the first D-pad stop on its line; it is
    added and removed automatically (feature 3), so after loading it appears on the first `update` in the
    editor.
- **Source**: src/model/model.odin (`Field` comment), src/model/struct_lit.odin (`is_optional_dot`),
  src/model/result_list.odin, src/model/capture.odin, src/model/branch.odin, src/app/main.odin
  (`slot_dot_color`, `slot_hint_label`), src/app/editor_view.odin (`layout_node`, `run_color`).

### 3. Derived dots are re-synced after every input

- **Trigger**: Every call of `model.update` (the app calls it every frame, input or not, unless an app
  overlay owns the input that frame).
- **Behavior**: `update` ends with five deferred passes (Odin runs them last-registered-first, so in this
  order): `result_list_sync` (result lists and return values get their extra dot and parentheses),
  `branch_sync` (empty `case` dots expect the switched value's type), `ctrl_sync` (`#assert` keeps at most one
  message dot), `sync_capture_dots` (a pink capture dot is added in front of a bare call statement inside a
  block - only indentation and at most `pkg.` before the call, nothing after `)` - whose procedure is known to
  return something, and removed when it stops being one; skipped while the document fingerprint `capture_fp`
  is unchanged; A on it turns `● len(name)` into `brave_otter := len(name)` with the cursor on the new name),
  `word_edit_sync` (word-by-word editing re-finds its field).
- **Rules & edge cases**:
  - The passes mostly add/remove optional dots and set hints, but **`result_list_sync` does change saved
    text**: it reshapes a procedure's result list to "one blue dot / `T●` / `(T1, T2●)`", so the parentheses
    come and go with the count. A loaded `f :: proc() -> (int) {` saves as `f :: proc() -> int {` (verified
    by running a scratch copy of src/model at 34a2ad1). `ctrl_sync` removes surplus `, ●args` dots of an
    `#assert` (optional dots only).
  - They don't run while a menu is open. Every pass except `word_edit_sync` returns early unless
    `state == .Editor`; additionally `result_list_sync` skips while a Reference pick / "Pass as" / refill is
    pending, `branch_sync` while a refill / Reference pick is pending, and `sync_capture_dots` while a refill,
    "Change procedure", Reference pick, "Pass as", "Declare as", body insert or replacement is pending. So
    dots catch up on the first frame back in the editor.
  - The loader runs `result_list_sync(app, force = true)` once at the end of `doc_from_source` (force skips
    the state checks).
- **Rationale**: Dots that depend on context (a call's return type, a switch's subject) stay correct after any
  edit without every edit having to know about them.
- **Source**: src/model/model.odin (`update`), src/model/capture.odin, src/model/result_list.odin,
  src/model/branch.odin, src/model/ctrl.odin, src/model/word_edit.odin.

### 4. The App state machine and its modes

- **Trigger**: `update(app, input)` dispatches on `app.state`; sub-modes are flags on `App`.
- **Behavior**: `State :: enum { Menu, Editor, Radial }`.
  - **Menu** = the main menu (a grid of `MENU_ITEMS`: "New Project", "Recent Projects", "Open Folder",
    "Key Layout", "Settings"; a replay of an older recording, `menu_legacy`, gets the first 4). 5 items →
    `grid_cols(5) = 3` (a row of 3, then 2). D-pad moves with `grid_nav`; B sets `want_quit` (the app exits
    at once, no confirmation; verified); A on index 0 resets the document and enters the editor
    (`new_project`). The app layer (src/app/main.odin main loop) intercepts A first on "New Project"
    (asks which folder: `new_project_open`; only a legacy replay lets the model's `new_project` run),
    "Recent Projects" (`projects_open`), "Key Layout" (`keys_page_open`) and "Settings"
    (`settings_page_open`); doc 09. "Open Folder" is not intercepted and the model only acts on index 0, so A
    on it does nothing; `draw_menu` draws it in faded ink, and the footer reads
    `D-pad / Arrows to move    A / Enter to select    (Open Folder not wired yet)`.
  - **Editor** = the code view. Input order inside `.Editor`: `ref_pick_update` (picking a name for
    "Reference"), `grab_update` (a lifted statement is sliding), `word_edit_update` (inside a string's
    words), `mod_pick_update` (picking the declaration a modifier attaches to); then the button layout's
    actions (`keymap_run`, doc 03); then plain d-pad / A / B. B returns to the main menu (state = `.Menu`;
    the document stays in memory). A on the purple dot opens the procedure's attributes; A on a green dot
    inside a function opens the statement menu on a temporary "●" line (`open_body_insert`); A on any other
    green dot opens the Add menu; A on a dot opens the Fill menu; A on anything else does nothing.
  - **Radial** = a menu view is open (the name is historical: it is a flat grid, feature 6). Only plain
    d-pad / A / B reach menus; X/Y and the keymap are ignored there, and so are the trigger holds (LT+Left in
    a menu simply moves left). Every frame: `menu_nav`, then B (`menu_cancel`), then A (`menu_select`).
    `return_state` is the state to return to
    when the last view closes (`.Editor`, or whatever state the IDE menu was opened from).
  - The IDE menu (`open_ide_menu`, title "IDE MENU": "Format file", "Key layout", "Exit"; 3 entries → 2
    columns) is global: the `IDE_Menu` keymap action (LT+Left by default) opens it from the main menu too
    (not from inside another menu: `.Radial` skips the keymap). "Format file" closes the menu, returns to
    `return_state` and runs `format_doc`; "Key layout" closes it and adds the `Key_Layout` request (the app
    opens the Key Layout page); "Exit" sets `want_quit` immediately, without asking and without saving.
  - `IDE_Menu` is checked in `update` **before** the editor's sub-mode handlers, so it also opens while a
    Reference pick, a grab, word-by-word editing or a modifier pick is in progress; those flags stay set and
    the mode resumes when the IDE menu closes back to `.Editor` (from code reading).
- **Sub-mode flags** (all on `App`, model.odin):

  | Flag(s) | Active when | Ends / B does |
  |---|---|---|
  | `replacing`, `replace_ni`, `replace_fi` (`-1` = whole node) | LT+A (Edit) reopened the menu that built a type field ("Edit Type") or an import ("Edit import", opened at the Add menu root with "Dependencies" highlighted), or Y on the type of a conversion opened "Convert" (`conv_change`, expr.odin), so the pick replaces it | pick replaces; B at root clears it |
  | `import_alias` | navigating Dependencies > Aliased import's tree | cleared after the pick / on reopen |
  | `slot_menu` (non-nil), `slot_ni`, `slot_fi` | the Fill menu for the dot at (ni, fi) is open | freed after a fill or B at root |
  | `refill_active`, `refill_saved`, `refill_ni/fi` | Y on a filled argument: it became a dot, the original fields are saved | B at root puts the original back (`refill_restore`) |
  | `change_call`, `change_ni/fi` | Y on a call's name: "Change procedure" menu | B clears it |
  | `body_insert_active`, `body_insert_ni`, `body_insert_reused`, `body_insert_blank` | A on a green dot inside a function inserted a temporary "●" line (reusing a blank line of an empty block) | B removes the line and restores the blank line (`body_insert_cancel`); a fill keeps it and drops the extra trailing "●" line (`body_insert_done`) |
  | `ref_pick_active`, `ref_ni/fi` | "Reference": choosing a name in the file for the dot | owns input until picked / cancelled |
  | `ref_pass_active` | the "Pass as" menu after a reference pick | B goes back to picking |
  | `decl_form_active`, `decl_ni/fi` | Y on a declaration operator: "Declare as" menu | B clears |
  | `rename_active`, `rename_*`, `rename_hits` | the prompt titled `Rename <old> to <new>?` (entries "Rename all N uses" or "Rename the other use" (rendered `Rename the other use%!(EXTRA 1)` at baseline, doc 08 F19), then "Only this one") after renaming a declaration | B: only this one changes |
  | `ctrl_menu` (`Ctrl_Menu`: None, When_Chain, Assert, Attr, Directive, Callconv), `ctrl_ni/fi`, `ctrl_from_pick` | a compile-time / modifier options menu is open | B returns to picking if opened from a pick |
  | `mod_pick_active`, `mod_pick_kind`, `mod_pick_line` | choosing which declaration an attribute / directive / calling convention attaches to | owns input |
  | `grab_active`, `grab_copy`, `grab_sel`, `grab_ops`, ... | Refactor > Grab / Copy line: lines lifted and sliding | B undoes every move exactly |
  | `word_edit_active`, `word_ni/fi`, `word_stop`, `word_nth` | editing a string / comment word by word | own exit |
  | `assign_pick_new` | choosing the target of an Assignment just added | B removes the new line |
  | `tree_sticky`, `tree_path`, `tree_*` | the RT tree walk selection stays highlighted after RT is released | moving the cursor rebuilds it |

  Plus outputs to the app layer: `notice` (a static status-line message the app shows once and clears; the
  three in use are `nothing declared to assign to here - declare it first (Declarations > Variable)`
  (ref_pick.odin), `Nothing here to move` and
  `A copy from inside a procedure can only be dropped inside a procedure` (grab.odin)), `requests` (a bit set
  of keymap actions needing disk/clipboard/overlays: Docs, Copy, Save, Save_As, Run_List, Files,
  Run_Favorite, Run_Tests, Prev_File, Key_Layout; `app_requests` performs and clears them right after
  `update`), `want_quit`.
  The app layer has its own overlays that own all input before the model sees it (file navigation, save
  dialog, docs panel, run list, project picker, new-project list, Key Layout page, Settings page, library
  prompts, dictation). Those belong to docs 03, 08, 09.
- **Rules & edge cases**: Flags are not a single enum; several combine, so `menu_select` resolves a picked
  `fill` leaf by checking them in this fixed order (first match wins): `ctrl_menu != .None` (options menu) →
  `fill == LOOP_OPT_FILL` → `rename_active` → `decl_form_active` → `ref_pass_active` → `change_call` →
  `replacing` → otherwise an ordinary slot fill (which itself first tries `layout_fill`, `branch_fill`, then
  `"__lit_ref__"`, then the marker table). `doc_reset` clears most per-document flags (slot menu, refill,
  change_call, body insert, Reference pick, Pass as, Declare as, rename, ctrl menu, modifier pick, RT tree,
  cursor) but **not** `grab_*`, `word_edit_*`, `replacing`, `assign_pick_new` or `name_counter`.
- **Source**: src/model/model.odin (`State`, `App`, `update`, `keymap_run`, `menu_cancel`, `doc_reset`,
  `new_project`, `MENU_ITEMS`, `menu_items`), src/app/main.odin (main loop input routing, `draw_menu`).

### 5. Generic menu machinery: entries and the view stack

- **Trigger**: Any menu: Add (A on a file-scope green dot), Fill slot (A on a dot), IDE menu, Edit menus
  (LT+A), option menus (Y), keypad, text tools.
- **Behavior**:
  - A menu is a tree of `Entry` values. An entry is either a **group** (`children` non-empty: A opens it) or a
    **leaf** whose behavior is chosen by which field is set. `menu_select` checks, after the in-menu specials
    and `format` / `key_layout` / `quit` / groups, in this order: `keyword` + `ident_default`
    (`keyword <editable ident>`, e.g. File Setup > "Package declaration" → `package main`), `proc_outline`,
    `type_construct`, `value_construct`, `special` (Compile-time / Modifiers, handed to `ctrl_add_select`),
    `import_path` (insert `import "<path>"`; aliased - `import <alias> "<path>"` with
    `alias = alias_default(path)` - when the "Aliased import" tree was entered or `needs_import_alias(path)`;
    then `record_recent`), `insert` (a layout marker `COMMENT_INSERT` / `BLOCK_COMMENT_INSERT` /
    `BLANK_INSERT` → `layout_add_insert`; else text that `parse_foreign_line` accepts → a structured
    `foreign import` / `foreign <name> {` line; else one fixed line, e.g. "File tags" → `#+build linux`),
    `fill` (a marker string such as `"__stmt_decl__"` naming what to put in the dot). An entry with none of
    these is a **placeholder** (e.g. `grp_dim("(no procedures defined)")`, "(no imports yet)"): A does nothing.
    (`is_leaf` itself only tests `insert`, `import_path`, `keyword`, `proc_outline`, `type_construct`,
    `value_construct`, `fill`; it is used only by tests.)
  - Other entry data: `label`, `dim` (grayed), `platform` (comma list of OS names; hidden elsewhere),
    `alias` (opening it sets `import_alias`), `call_name` / `call_pkg` / `ret` / `ret_pkg` (payload for call
    and type fills), `pinned` (listed first, feature 7), `heat_key` (identity for the usage heatmap, doc 03 F13; drawing: doc 10 F17).
  - Navigation is a stack `app.nav` of `MenuView {title, entries, index, recent, heat, heat_root}`.
    `push_menu(title, raw)` builds a display view with `make_view` (feature 7) and pushes it; `push_view`
    pushes a prepared view (used to keep author order, e.g. the Fill menu's "Type" submenu); `pop_menu`;
    `clear_nav`.
  - **A** (`menu_select`): records heat, then dispatches: special fills that act inside the menu (Convert form
    expansion, keypad keys, Refactor, word tools, text tools), `format` (close, then `format_doc`),
    `key_layout` (close, request the page), `quit` (`want_quit`), a group (push its children), then the
    leaf behaviors above. A group's children are pushed with `push_menu` (through `make_view`), except a
    group labeled exactly "Type" while `slot_menu` is set (the Fill / Edit Type menus), which is pushed as is
    with `push_view` to keep its order, and groups while word-by-word editing (`word_menu_push`). After an
    **Add-menu insertion** (keyword, outline, type, value, import, insert) the menus close, `insert_at` has
    advanced past the new lines, an insertion inside a file-scope `when` is indented (`ctrl_indent_inserted`),
    and the cursor is put on the green dot right after what was inserted (`focus_dot_at(app.insert_at)`).
    Replacing an import (`replacing && replace_fi < 0`) rebuilds that node in place instead and returns to the
    editor. After a **fill** see Data model > "Fill markers".
  - **B** (`menu_cancel`): pops one view. If that was the last view: an options menu (`ctrl_menu != .None`)
    closes back to the editor and, only if it had been opened from a modifier pick, back into that pick
    (`ctrl_menu_cancel`); "Pass as" goes back to picking the name; otherwise the state returns to
    `return_state` and every pending operation is undone: `decl_form_active` off, rename prompt cleared,
    `replacing` off, `refill_restore` (argument put back), `change_call` off, `body_insert_cancel` (temporary
    line removed), Fill menu freed. B inside a submenu only goes up one level and changes nothing.
  - The drawn menu (`draw_radial`, over a veil that hides the code) shows: a breadcrumb of the titles above
    (`Fill slot  >  Call  >`, cut from the left with `..  >  ` when too long), the view title (green), while a
    Fill menu's dot is still a typed dot the line `expects <hint>  -  grayed options don't fit` (`..T` for an
    `args` dot), the grid (selected cell highlighted with a green outline; recently-used cells tinted with a
    thin outline; grayed labels in faded ink; worn shading from the heatmap, doc 10), `^ more` / `v more`,
    and `<index+1> / <n>     D-pad move   + select   < back`.
- **Rules & edge cases**:
  - Titles in use: "Add  (insertion point)" (two spaces), "Fill slot", "Edit Type", "Edit import", "IDE MENU",
    "Change procedure", "Declare as", "Convert", "Assign to", "Pass as", `Rename <old> to <new>?`, "Number"
    (the LT+A keypad), "Refactor", "Text" (LT+A text tools), plus the options-menu titles of ctrl.odin,
    branch.odin, loops.odin; submenus use the entry's label as title.
  - Views pushed with `push_view` (author order, no `make_view` sorting / sections): the Fill "Type"
    submenu, "Number", "Refactor", "Text" and the word-by-word menus.
  - Fill / option / edit menus are rebuilt for each opening (`slot_menu` is built per dot from the
    document's current state), so their content reacts to the code: names in scope, imports, expected type
    (docs 05-07). The Add menu and the IDE menu are built once per App (`ensure_menus`, lazily on first use)
    and reused; only their display views (`make_view` ordering, usage-first) are recomputed per push.
  - The Add menu root, in author order (7 entries, so never sorted): "File Setup", "Dependencies",
    "Procedures", "Types", "Values", "Compile-time", "Modifiers" (contents: doc 04). Its insertion point
    `insert_at` is the green dot's line (`open_add_menu`; when the cursor is on a line instead it would be the
    line after that line's construct, but the editor only opens the Add menu from a green dot). When that
    point is inside a file-scope `when`, "Dependencies" is grayed (`ctrl_add_menu_opened`); being a group, it
    still opens.
- **Source**: src/model/model.odin (`Entry`, `MenuView`, `ensure_menus`, `leaf`/`grp`/`grp_dim`/`kw_leaf`/
  `proc_leaf`/`type_leaf`/`value_leaf`, `is_leaf`, `push_menu`, `push_view`, `pop_menu`, `clear_nav`,
  `open_add_menu`, `open_ide_menu`, `menu_select`, `menu_cancel`), src/app/main.odin (`draw_radial`).

### 6. Menu grid layout and D-pad navigation (wrap-around)

- **Trigger**: Any open menu (`.Radial`), and the main menu.
- **Behavior**:
  - Columns: `grid_cols(n)` = the smallest `c` with `c*c >= n`, capped at `GRID_COLS = 8` (1→1, 4→2, 6→3,
    9→3, 16→4, 64 and up→8). Rows fill left to right; the grid scrolls vertically.
  - `grid_nav(index, n, input)`: Left on a row's first cell goes to that row's last cell, otherwise one left;
    Right on a row's last cell goes to the row's first cell; Up from the top row goes to the bottom-most
    cell of the same column; Down past the last cell of a column goes to that column's top cell.
  - With a "recently used" section (feature 7) the grid has two blocks of rows: the section's
    `ceil(recent/cols)` rows, then the rest starting on a new row (`menu_cell`, `menu_rows`). `menu_nav`:
    Left/Right wrap within the current row (its real length), Up/Down wrap over all rows of both blocks, and
    the column is clamped to the target row's length. Without a section it equals `grid_nav` exactly.
- **Rules & edge cases**: The selected row is kept roughly centered when scrolling. Cell width fits the
  longest label (220..480 px); a label still too long is shown in full below the grid when highlighted.
- **Rationale**: Commit bf5ec80 "wrap-around navigation (edges roll over row/column) + square-preferring
  column count"; commit 79a7b87 replaced alphabetical bucketing with a flat, vertically scrollable grid.
- **Source**: src/model/model.odin (`GRID_COLS`, `grid_cols`, `grid_nav`), src/model/menu_sections.odin
  (`menu_cell`, `menu_rows`, `menu_nav`), src/app/main.odin (`draw_radial`, `draw_menu`).

### 7. Menu ordering: platform filter, usage first, "RECENTLY USED", alphabetical when long

- **Trigger**: Every `push_menu` (`make_view`).
- **Behavior**, in order:
  1. Drop entries whose `platform` list does not contain `app.os_name` (`platform_ok`).
  2. Import leaves already imported by this file (a node whose whole text is `import "<path>"`), in author order.
  3. Import leaves imported recently this session (`recent_imports`, most recent first; `record_recent`).
  4. `pinned` entries (e.g. procedures / constants / types of a package already used in this file), author order.
  5. Everything else. If there are more than `BUCKET_THRESHOLD = 12` of them they are sorted by label,
     case-insensitively (`label_less`); 12 or fewer keep author order.
  Steps 2-4 form the **recently used** section (`v.recent` = their count), drawn with a "RECENTLY USED"
  caption and the rest under "ALL", but only when step 5 is non-empty (all-recent menus are a plain grid).
- **Rules & edge cases**:
  - The Fill menu's "Type" submenu, word menus and a few others bypass `make_view` to keep their order.
  - "Already imported" only matches plain imports (`import "core:fmt"`), not aliased ones.
  - `BUCKET_TARGET`, `MenuView.rest` and `MenuView.labels` are leftovers of the removed bucketing (unused).
- **Rationale**: Usage first means the thing you used last is one press away; small menus keep the order
  their author chose because it is meaningful (e.g. Number, String, true, false, nil ...).
- **Source**: src/model/model.odin (`make_view`, `platform_ok`, `is_imported`, `record_recent`,
  `BUCKET_THRESHOLD`), src/model/menu_sections.odin.

### 8. Big name lists: grouping a package's names into a stable hierarchy

- **Trigger**: Calls > From import > *package*, Constant / Type / Struct literal lists of a package (docs 06,
  07) all build their tree with `build_proc_hierarchy`.
- **Behavior** (`build_import_proc_menu` + `build_proc_hierarchy`):
  1. Names already called / used in this file come first as pinned leaves (they become the recently-used
     section), in file order. For calls, `collect_called_procs` finds, per line, only the **first** `ref.` and
     takes the text up to the next `(` as the name (so `x := win.MB_OK + f(1)` would pin a junk leaf
     `MB_OK + f`; from code reading).
  2. The **full** name list of the package is grouped, then the used names are removed from the groups
     (`remove_named_leaves`, empty groups dropped). Groups therefore look the same in every file.
  3. `<= FLAT_MAX (60)` names: one flat, name-sorted list.
  4. Otherwise group by source file (one submenu per file name, e.g. `user32`) when there is more than one file;
     inside a file, group by foreign block when more than one non-empty block (the block-less ones under
     "(top-level)"); inside that, if still > 60, **prefix groups** (`extract_prefix`): a name containing `_`
     at index > 0 → the text up to and including the first `_` (`WM_`); otherwise the text before the second
     capital letter (`GetWindowText` → `Get`, `getValue` → `get`, and `HWND` → `H`); a prefix needs
     `MIN_PREFIX_SHARE = 3` names; label `"<prefix>..."`. Names whose prefix is not shared are listed beside
     the groups (or in an `other...` group of alpha buckets if more than 60). A prefix group over 60 is split
     into **alpha buckets**. If no prefix qualifies at all, the whole list becomes alpha buckets.
  5. Alpha buckets: name-sorted chunks of `PAGE = 12`, labeled by lowercase first letters `"a"` or `"a-c"`;
     their heat identity is `"<first>..<last>"` because labels repeat (all `w` inside `WM_...`).
  All group levels are sorted by label with a plain byte comparison (case-sensitive), leaves by name. When a
  level is then pushed through `make_view` and has more than 12 non-pinned entries, the display re-sorts it
  case-insensitively (feature 7), so the visible order of big lists is case-insensitive.
  The same Calls tree also has "Internal procedure" (this file's procedures - the first editable field of
  every line containing ` :: proc(` - then the sibling files' procedures; else the grayed placeholder
  "(no procedures defined)"), "From import" (one group per import reference, its `heat_key` = the import
  path so aliases share heat) and "Built-in" (`BUILTIN_PROCS`) (`build_call_children`).
- **Rules & edge cases**: A package with no table rows gets one leaf "Other (name it yourself)" (inserts
  `pkg.<generated name>(●)` - fields `pkg`, `.`, the editable name, `(`, a green `args` dot, `)` - because an
  unknown procedure takes any number of arguments). No imports: a grayed "(no imports yet)" placeholder.
  Blank imports (`import _ "p"`) are skipped (`collect_imports`).
- **Rationale**: (remove_named_leaves comment) "group labels and shapes - the menu trails, and their heat -
  don't depend on what a file already uses." Commit ccae370: only split above FLAT_MAX.
- **Source**: src/model/model.odin (`build_import_proc_menu`, `remove_named_leaves`, `build_proc_hierarchy`,
  `build_file_children`, `build_block_children`, `build_flat_leaves`, `build_alpha_buckets`,
  `find_prefix_groups`, `extract_prefix`, `build_call_children`).

### 9. Grayed (dim) entries

- **Trigger**: A menu opened for a dot with an expected type, or a context where some options can't apply.
- **Behavior**: `dim = true` draws the label in faded ink. For a dot with a `hint`, `open_slot_menu` resolves
  the expected type and, when it resolves to something other than Unknown, runs `apply_fit_dims`: each leaf
  that can't produce that type is dimmed, and a group is dimmed when nothing inside fits. After that pass
  (which resets dims), "Reference" is dimmed when the file has no candidate names (`ref_candidates`), then
  `branch_adjust_menu` (case values other cases already use), `when_extend_value_menu` (calls in a `when`
  condition) and the loop / keypad / assignment-operator passes add their own dims (docs 05-07).
- **Rules & edge cases**: In ordinary Fill menus graying is **advice**: a grayed leaf still works when picked
  (heat.odin: "Leaves grayed by type fitting still work when picked"). Option menus (compile-time / modifier
  options, loop options, branch options) **refuse** a grayed pick: "not possible here: the menu stays open".
  A grayed group still opens. Placeholders without `fill` are never touched by fitting.
- **Source**: src/model/typecheck.odin (`apply_fit_dims`, `entry_fits`), src/model/model.odin
  (`open_slot_menu`), src/model/heat.odin (`heat_is_action`), src/model/ctrl.odin, loops.odin, branch.odin.

### 10. Loading an existing `.odin` file

- **Trigger**: Opening a file from file navigation, Recent Projects, Previous file (doc 09), or the command
  line (`doodle.exe path\to\file.odin`, "Open with"): all go through `filenav_load`, which first makes the
  path the current file and its folder the project folder, then calls `model.load_file` then
  `model.format_doc` (feature 13), then enters the editor. Nothing about the previous document is saved or
  asked first.
- **Behavior** (`doc_from_source`, line-based, "pragmatic, not a full Odin parser"):
  1. `doc_reset`. Strip exactly one trailing `"\n"`; if the text is non-empty and did not end in `"\n"`, set
     `no_final_newline`. Split on `"\n"` and strip a trailing `"\r"` from each line.
  2. Pre-pass line roles: `ctrl_line_roles` (when / `#assert` / attribute lines), `branch_line_roles` (case
     labels of type switches). A stack of open braces tracks whether the current block is a **data** body
     (struct / enum / union / bit_field, and anything nested in one; `track_blocks`, braces inside literals
     and after `//` ignored, lines of a structured `/* */` comment skipped). The flag `in_data` keeps the
     branch, loop, assignment and declaration parsers (`parse_branch_line`, `parse_loop_line`,
     `parse_assign_statement`, `parse_line`'s `is_declaration`) from reading member lines as statements; the
     call, struct-literal and return parsers don't receive it.
  3. **Open values**: a line ending in ` :=`, ` =`, ` +=` (any assignment operator, preceded by a space),
     `x: T =`, or a top-level (unindented) `NAME ::`, that contains no `//`, has more than 3 non-space
     characters, and whose next non-blank line is not indented deeper, gets ` __doodle_open_value__` appended,
     is parsed normally, and the placeholder becomes an unfilled `value` dot (`open_value_line`,
     `open_value_to_dot`). Pinned by `test_integration_reload_open_values` (`clever_otter =`, `log :=`,
     `x: int =`, `y +=`, `context.logger =`, and `x :=` followed by a deeper `1` getting no dot).
  4. Each line goes through a chain of parsers; the first that accepts wins:
     `parse_block_comment` (a `/*` alone on a line through a `*/` alone on a line: one node per line, markers
     kind `comment_mark`, text lines editable kind `comment`) → `parse_comment_line` (a whole-line `// text`:
     `[indent]["// " or "//"][text editable, kind comment]`; empty comments and `//+` tags stay fixed) →
     `parse_ctrl_line` (when / else when / `#assert` / `@(...)`) → `parse_branch_line` (if / else / switch /
     case) → `parse_loop_line` (for loops, break / continue, labeled blocks) → `parse_return_statement`
     (2+ values) → `parse_call_statement` → declaration inside a file-scope when (`parse_indented_line`) →
     `parse_lit_statement` (`x := T{a = 1, ...}`, one or several lines, only if it reproduces them exactly) →
     `parse_return_statement` → `parse_assign_statement` (`a.b = v`, `x = v`) → `parse_line`.
  5. `parse_line`: `import "p"` / `import alias "p"` (same fields as the menu: `import_node`, the path a stop of
     kind `import_path`, the alias editable), `foreign import name "p"` and `foreign name {` (name editable),
     `package <name>` (`"package "` + editable name), a non-indented `ident :: rest` (ident editable; proc
     parameter names editable; a constant's value structured if it is clearly a value: literals, `true` /
     `false` / `nil`, a call, an operator expression with spaced operators; types and bare names stay text),
     a declaration `x := ...` / `a, b := ...` / `x: T = ...` (names editable, operator kind `decl`, the type of
     a typed declaration a `type` field, a string value's text editable), else **one fixed field holding the
     whole line**.
  6. Post-passes: `structure_type_decls` (type declarations and data-body members get the menu's fields,
     doc 04), `split_modifiers` (calling conventions, struct directives become `kw` fields),
     `attach_call_signature` for each parsed call, `attach_lit_hints`, `attach_nested_call_hints`,
     `structure_results`, `result_list_sync(force)`.
- **Calls** (`parse_call_statement`): `[indent] [defer |return |lhs := |lhs = ] callee(args) [tail]` with
  `callee` = a dotted name `a.b.c` immediately followed by `(` (not one of `NOT_CALLEES`: proc if for switch
  when cast transmute auto_cast struct union enum map matrix bit_set bit_field distinct return defer); `lhs` is
  a name list, optionally typed (`x: windows.LPCWSTR = f()`). The argument list may run over
  up to 64 lines (Doodle's one-argument-per-line format) and is **joined into one node**. Arguments are split
  at top-level commas, each structured by `emit_expr` (binary operators written with spaces, ternaries,
  casts, struct literals, nested calls, simple strings with editable text) and re-joined with `", "`; an empty
  argument becomes a `value` dot. Then, once all imports are known, `attach_call_signature` types the dots from
  the callee's signature (`hint`, `hint_pkg`), adds dots for missing required arguments, and a green `args`
  dot for a variadic procedure. Calls to procedures Doodle doesn't know get no dots.
  A line is not taken as a call statement (later parsers get it) if a `{` follows the closing `)` (a struct
  literal such as `Stack(int){top = 1}`), if the call is part of a ternary, or if a `//` starts before the
  call closes on its first line. A multi-line call is additionally not joined if a `//` comment is inside it
  or if text other than `or_...` follows its closing `)`. A one-line call keeps whatever follows `)` -
  including a trailing `// comment` - as one fixed tail field (`p.update(1) // a method-ish call` round-trips
  in `test_load_call_statement_shapes`). If the call was written with
  several arguments on some rows (3+ lines, every middle row ends in `,`), that grouping is remembered
  (`record_arg_rows`: `", "` fields ending a row get `hint = "rowend"`, the `"("` field gets
  `hint = "argrows:<N>"`) so it saves back the same way (feature 12).
- **Examples** (field shapes as `text kind`, `ed` = editable; pinned by load_decls_test.odin, the open-value
  rows by `test_integration_reload_open_values`, the MessageBoxW row by
  `test_load_adds_dots_for_missing_arguments`):

  ```
  import "core:fmt"          -> "import " | "\"core:fmt\"" import_path
  import win "core:sys/windows" -> "import " | "win" ed | " " | "\"core:sys/windows\"" import_path
  import "core:fmt" // printing -> one fixed field (anything after the path: left as text)
  CLEVER_OTTER :: ""         -> "CLEVER_OTTER" ed | " :: " | "\"" | "" ed string | "\""
  BOTH :: A | B              -> "BOTH" ed | " :: " | "A" | " | " | "B"
  Alias :: Other             -> "Alias" ed | " :: Other"
  BRAVE_OTTER ::             -> "BRAVE_OTTER" ed | " :: " | ● value
  clever_otter =             -> name | assign_op | ● value
  x: int =                   -> name | decl | type | " = " | ● value
  win.MessageBoxW(nil)       -> ... "(" "nil" ", " ●LPCWSTR ", " ●LPCWSTR ", " ●UINT ")"  (missing args added)
  ```
- **Rules & edge cases**:
  - Lines are kept exactly, except: call statements come back in Doodle's spacing (`foo( a,b )` → `foo(a, b)`,
    `MessageBoxW( nil, ...,  )` → `MessageBoxW(nil, ..., )`), multi-line calls and multi-line struct literals
    become one node, and `"\r"` is dropped (CRLF files save as LF). (Saving adds more normalizations:
    feature 11 and invariant 2.)
  - A `/* */` comment is only structured when `/*` and `*/` are each **alone** on their line. Otherwise
    (`/* see` ... `*/`) the lines in between go through the ordinary parser chain as if they were code: a
    call-like line inside is respaced, and the formatter re-indents the lines (verified: `/* see\n\tfoo( a,b )\n*/`
    saves as `/* see\nfoo(a, b)\n*/`).
  - `doc_from_source` itself never splits one-line blocks; the `format_doc` that `filenav_load` runs does
    (feature 14). So `if x { y() }` is one fixed line right after `doc_from_source`, and three structured lines
    once the file is opened in the app.
  - Identifiers are ASCII only (`is_valid_identifier`); a top-level declaration needs ` :: ` with spaces.
  - `load_file` returns false (and the app shows `could not open <path>`) when the file can't be read; the
    document is left as it was, but `filenav_load` has already made `<path>` the current file, so a later
    Save would write the old document there (from code reading of src/app/filenav.odin).
  - Loading an empty string produces one blank node (format_doc removes it); saving an empty document writes
    an empty file (no final newline).
  - `load_file` ends with `normalize_cursor` (`doc_reset` had put the cursor at line 0), so the cursor lands
    on the first stop.
- **Rationale**: Commit 49a0a03: "imports, constants and empty cases load as the menus build them ... The
  menus and the loader share import_node." Loaded code must be as editable as menu-built code.
- **Source**: src/model/parse.odin (`doc_from_source`, `load_file`, `parse_line`, `parse_call_statement`,
  `record_arg_rows`, `emit_args`, `emit_expr`, `emit_open_operator`, `split_args_keep_empty`,
  `attach_call_signature`, `open_value_line`, `open_value_to_dot`, `emit_names_prefix`, `emit_decl_rest`,
  `emit_proc_params`, `is_const_value`, `parse_foreign_line`, `parse_import_line`, `track_blocks`),
  src/model/stmt_layout.odin (`parse_comment_line`), src/model/block_comment.odin (`parse_block_comment`),
  src/app/filenav.odin (`filenav_load`).

### 11. Saving: `file_text`

- **Trigger**: The Save action (RT+Y by default; doc 03), Save as, and every Run (`run_command` saves first
  with `save_current` and does not run if that fails). The app writes `model.file_text(m)` to the path
  (`write_doc`, src/app/save.odin). Save (`save_now`) writes to the open file, or - for a document never
  saved - to `<project folder>/main.odin`, creating a fresh randomly named project folder
  (`swift-fox-1234` style) under the projects directory if there is none. Status: `saved <name>`, or for that
  first save `saved <name> in <folder> - rename it in Files (LT+X)` (the string is literal: in the default
  layout Files is actually RT+B and LT+X is Talk); failure `SAVE FAILED: could not save: <os error>`.
- **Behavior**: `file_text` = `format_doc(app)` (this **reformats the live document**), then `save_source`,
  then append `"\n"` unless `doc.no_final_newline` or the body is empty.
  - `save_source`: every node in order, joined with `"\n"`, **except editor-only "●" lines** (a line that is
    only indentation + a `body` dot, `is_body_slot_line`) unless the line before opens a block (non-comment,
    ends with `{`, or `case ...:`) **and** the line after closes one (starts with `}` or `case`, or end of
    file). Such a block's only "●" is written as an empty line so an empty body round-trips.
  - Each node becomes `node_source_lines` (one line, or several for a broken call; feature 12), and each line
    passes through `fixup_line`.
  - `node_source`: concatenated field texts, skipping optional dots and the `", "` before one; a menu-built
    proc header with parameters is written tidy (`proc( ` → `proc(`, ` ) -> ` → `) -> `, the `", "` before the
    trailing params dot dropped).
  - `fixup_line`: a comment line (first non-space is `//`) only loses trailing whitespace. Any other line:
    every `(  )` → `()`, every `( )` → `()`, then the **first** `) -> ` if followed only by spaces then `{` →
    `) {`, then trailing whitespace trimmed. These are plain text replacements: they also hit string
    literals, trailing `// comments` after code and `/* */` comment text (verified:
    `fmt.println("( )") // x ( )` saves as `fmt.println("()") // x ()`, and a `/* */` text line `call f( ) here`
    saves as `call f() here`).
- **Examples**: `main :: proc(  ) ->  {` → `main :: proc() {`; `main :: proc(  ) -> int {` →
  `main :: proc() -> int {`; an unfilled `x := ●` → `x :=`; a new file with only `package x` → `package x\n`;
  an opened file without a final newline is saved without one.
- **Rules & edge cases**:
  - Unfilled required dots save as nothing, so a file with unfilled dots usually doesn't compile
    (`x :=`, `foo(a, )`). fixup_line only makes the *empty procedure outline* compile. The loader restores
    some of those dots (feature 10) - but not all: see invariant 5 for which unfilled constructs come back as
    plain text, so saving half-finished work is only partly safe.
  - `format_doc` runs on the live document as part of `file_text`, so every save also re-indents and
    re-spaces what is on screen; the cursor is kept on the same line.
  - The live document keeps its "●" lines (only the written text drops them).
  - A brand-new empty proc saves as `main :: proc() {\n\n}`; reopened and formatted it becomes
    `main :: proc() {\n}` (format_doc removes a blank line just inside braces).
- **Rationale**: (serialize.odin) "fixup_line applies corrections to make unfilled constructs compile";
  (save_source) "A '●' that is a block's only content stays ... so empty bodies keep round-tripping."
- **Source**: src/model/serialize.odin (`fixup_line`, `doc_to_source`, `file_text`, `save_source`,
  `nodes_to_source`, `copy_selection_source`), src/model/calls.odin (`node_source`), src/app/save.odin
  (`write_doc`, `save_now`, `save_current`).

### 12. Long calls are shown and saved one argument per row

- **Trigger**: A node with a call argument list (or a menu-built proc header with parameters) whose saved text
  is wider than `MAX_COLS = 80` columns (a tab counts `TAB_COLS = 4`), or that was loaded with grouped rows, or
  a struct literal loaded one field per line.
- **Behavior**: `call_rows` plans rows: the head (`win.MessageBoxW(`), one row per argument (indented one more
  level, suffix `,`), and the tail (`)` and anything after). The argument list is the line's first
  top-level `(` ... `)` (or a struct literal's `{` ... `}`) found by `find_arg_list`, or a menu-built
  header's parameter list (`header_arg_list`). The **same plan** drives the editor and the saved
  file, so every saved break is visible (the editor can add visual-only ones, below):

  ```odin
  win.MessageBoxW(
      nil,
      "This is Handmade Hero.",
      win.L("Handmade Hero"),
      win.MB_OK | win.MB_ICONINFORMATION,
  )
  ```

  - `needs_break` is false for if / switch headers, case labels, loop headers, `x += f(...)`, compound values
    (ternary, `cast(T)f(a)`), and `#assert(...)`; true for a struct literal loaded broken (`LIT_BREAK`) that
    still has fields, for a call with recorded grouped rows, else when the width exceeds 80.
  - Grouped rows (`ARG_ROW_END` marks on `", "`) put several arguments on one row
    (`win32.CW_USEDEFAULT, win32.CW_USEDEFAULT,`). The mark on `"("` records the argument count; once the
    count changes the grouping is ignored. Y on an argument of a call that is saved broken (not a proc header,
    not a struct literal) appends to the end of its refill menu "Join with previous row" (when the argument
    starts a row and isn't the first) and/or "Own row" (when it shares a row) (`arg_row_extend_menu`); the
    choice puts the argument back unchanged and sets the marks (`arg_row_choose`, `set_arg_row`, which first
    marks every separator when the call had no grouping); when every argument is on its own row again the
    marks are removed.
  - In a broken call an unfilled optional dot's row is omitted; an unfilled **required** argument keeps its row
    as a bare `,` so reloading puts the dot back in the right position.
  - A struct literal broken for width (or loaded with aligned `=`; `hint_pkg = "aligned"`) pads its keys so
    the `=` signs align; another loaded literal keeps its own spacing. A literal broken for width whose `{`
    directly follows the type gets a space in its head row (`Point{` → `Point {`).
  - A broken menu-built proc header gets one parameter per row; the trailing `params` dot's row is omitted.
  - The editor can show **more** breaks than the file has: `layout_node` also breaks a call one argument per
    row when its on-screen width (which includes dots and their type labels) doesn't fit the window, even
    though the saved line stays whole; and it wraps any row still wider than the screen onto continuation
    rows (indent + 2 units; a single over-long run such as a long string is cut at a space when possible).
    The gutter shows saved-file line numbers (one per saved line), so these visual-only rows have no number.
    The code font is re-sized so that 80 columns fit the window (`ensure_code_font`, 13..28 px).
- **Rules & edge cases**: Indent unit of the argument rows follows the line's indentation: 4 spaces if it
  starts with a space, else a tab. The width test is `text_cols(node_source(n)) > 80` over the whole line
  including its indentation, tabs counting 4, other bytes 1 (so multi-byte UTF-8 counts more than once). A
  short call loaded in multi-line form is saved joined (`foo(\n1,\n2,\n)` → `foo(1, 2)`), because
  `record_arg_rows` only keeps a layout in which some row holds several arguments.
- **Source**: src/model/format.odin (`MAX_COLS`, `TAB_COLS`, `text_cols`, `find_arg_list`, `call_rows`,
  `proc_header_parens`, `range_source`, `needs_break`, `node_source_lines`, `has_arg_rows`, `ARG_ROW_END`,
  `arg_rows_hint`), src/model/stmt_layout.odin (`arg_row_extend_menu`, `set_arg_row`),
  src/app/editor_view.odin (`layout_node`).

### 13. Formatting the document (`format_doc`)

- **Trigger**: On open (filenav_load), on every save (`file_text`), IDE menu (LT+Left by default) >
  "Format file", or the Format_File keymap action (not on any button in the default layout; doc 03).
- **Behavior**:
  0. `split_one_line_blocks` (feature 14).
  1. **Indentation**: walk lines keeping a depth = running balance of `{ ( [` minus `} ) ]` outside string /
     rune literals and `//` comments (`line_balance`; so a multi-line call the loader didn't join is indented
     by its parentheses). A line's level = depth − (number of `}` `)` `]` it starts with); `case ` / `case:` labels one
     level less; a run of `//` comments directly above a `case` sits at the case's level; level ≥ 0. The line's
     indentation becomes that many **tabs** (`set_indent`; a fixed first field absorbs the indent, otherwise
     it's a new field). Lines of a `/* */` comment don't count braces, and its text lines keep their own
     indentation. Blank lines become a single empty field.
  2. **Blank lines**:
     - a blank line is kept (as one) unless it is at the start, follows another blank, follows a line ending in
       `{`, precedes a line starting with `}`, or only blanks follow it;
     - at top level, each construct has a kind: Package (`package `), Import (`import `, `foreign import `),
       Comment (`//`, `@` attribute lines, `/* */` lines), Block (opens more than it closes), Single. A comment's
       effective kind comes from the first non-comment, non-attribute line after it: **Block if that line opens
       more than it closes, else Single** - never Package or Import - and it stays Comment if a blank line comes
       first. One blank line is inserted before a construct when the previous construct isn't a comment and
       the kinds differ or either is a Block. Nothing is inserted between a comment and what it documents.
       Consequence (verified): a `//` comment directly above an `import` is treated as Single, so a blank line
       is inserted between the previous import and the comment, splitting the import group.
  3. The cursor stays on the same line (`old_to_new` map; a dropped blank maps to the next kept line), then
     `normalize_cursor`.
- **Example** (simplified from `test_format_indents_and_spaces`). Before:

  ```odin
  package main
  import "core:fmt"
  import "core:sys/windows"
  main :: proc() {
  if true {
  fmt.println(1)
  }

  }
  MAX :: 5
  MIN :: 1
  ```

  After (indentation is tabs):

  ```odin
  package main

  import "core:fmt"
  import "core:sys/windows"

  main :: proc() {
  	if true {
  		fmt.println(1)
  	}
  }

  MAX :: 5
  MIN :: 1
  ```
- **Rules & edge cases**: Idempotent (`fmt(fmt(x)) == fmt(x)`, pinned by
  `test_format_is_stable_and_collapses_blanks`). Lines holding dots are never removed (`is_blank_line` is
  false for a line with a slot or a `comment` field, so a "●" line or an empty comment line is not blank).
  Spaces-indented files become tab-indented. Blank lines between consecutive Single constructs that the user
  put there are kept, never added. Apart from the one-line-block split (feature 14), the formatter only
  touches leading whitespace and whole blank lines: it
  never changes spacing inside a line and never re-wraps (call breaking is the serializer's job, feature 12).
  Only `editor_line` is remapped; the cursor's dot / field are re-validated by `normalize_cursor`.
- **Source**: src/model/formatter.odin (`format_doc`, `line_balance`, `set_indent`, `Top_Kind`).

### 14. Splitting one-line blocks

- **Trigger**: The first step of every `format_doc`.
- **Behavior**: A line with no dots that is a block statement written on one line (starts with `if `, `for `,
  `for{`, `switch `, `#partial switch `, `when `, `#reverse `, `#unroll `, or `label:` before one of those or
  before `{`; ends with `}`; balanced; no `//` or `/*`) is rewritten as header `{`, each body statement (split
  at top-level `;`) one tab deeper (nested one-line blocks split recursively), and `}`; a following `else`
  merges into `} else {`. The new lines are parsed (with the file's imports prepended so calls get typed) and
  accepted only if they produce exactly that many nodes and every header line comes out structured
  (`loop_hdr`, `br_line`, `labeled_block`, `when_kw_index`); otherwise the line stays as written.
- **Example**: `for i in 0..<3 { a(); b() }` → `for i in 0..<3 {` / `\ta()` / `\tb()` / `}`.
- **Rules & edge cases**: Refused when the body starts with `case` (switch with case clauses on one line) or
  something other than `else` follows the closing brace. Struct literals (`Point{1, 2}`, a `{` not preceded by a
  space) are not blocks.
- **Source**: src/model/block_split.odin (`split_one_line_blocks`, `split_inline_block`, `split_block`,
  `block_open`, `split_statements`, `header_structured`).

### 15. Syntax highlighting

- **Trigger**: Drawing each node (src/app/editor_view.odin `layout_node`).
- **Behavior**: `highlight(line_text, packages)` returns one class per **byte** of the whole line (fields are
  concatenated first, so a keyword split across fields is still found). Classes `Hl`: Plain, Keyword, Type,
  String, Number, Constant, Comment, Func, Package. Scan rules:
  - `//` → Comment to end of line.
  - `"`, `'`, `` ` `` → String to the matching quote (backslash escapes, except in backticks).
  - a digit → Number over identifier characters and `.`.
  - `#ident` → Keyword (`#partial`, `#force_inline`, `#assert`, ...).
  - an identifier: Keyword if in the keyword list (package import foreign proc struct enum union bit_set
    bit_field distinct map matrix dynamic return if else when for in not_in switch case break continue
    fallthrough defer using or_return or_else or_break or_continue do where cast transmute auto_cast context);
    Type if a builtin type (int uint i8..i128 u8..u128 uintptr f16 f32 f64 complex64 complex128 quaternion128
    quaternion256 bool b8 b16 b32 b64 string cstring string16 cstring16 rune byte rawptr typeid any);
    Constant for `true` / `false` / `nil` and ALL_CAPS words longer than one letter; Type for capitalized words
    with a lowercase letter (Ada_Case / PascalCase). Then, unless it's a keyword or builtin type: followed (after
    spaces) by `(` → Func; immediately followed by `.`, still Plain, and in the import names in scope →
    Package (`packages == nil` = any). An ALL_CAPS word in a type position (after `:` but not `::`, after `->`,
    `^` or `]`, looking back over a `pkg.` qualifier) → Type (`x: HWND`, `-> LRESULT`).
  - everything else Plain.
- **Rules & edge cases**: The editor passes the file's import references (aliases or default names,
  `collect_imports`) so `p.name` stays plain while `fmt.` is a package. In a file with **no** imports that
  list is empty, and an empty Odin slice is `nil`, which `highlight` reads as "any `name.` is a package"
  (verified: `make([]string, 0)` compares equal to nil), so `p.` is then colored as a Package. A single
  capital letter (`T`) is Plain (Constant needs length > 1, Type needs a lowercase letter); a digit inside an
  identifier is part of the identifier; `true` / `false` / `nil` stay Constant even in type position.
  Editable names are drawn in green ink (COL_ACCENT 0.10,0.52,0.28) regardless
  of class; a `string` field in the String color; comment text keeps its highlight color. Colors (paper
  theme): Keyword (0.55,0.15,0.60), Type (0.00,0.43,0.52), String (0.33,0.50,0.08), Number (0.78,0.33,0.08),
  Constant (0.62,0.40,0.00), Comment (0.55,0.52,0.46), Func (0.12,0.33,0.72), Package (0.70,0.22,0.35),
  Plain = ink (0.17,0.15,0.13).
- **Source**: src/model/highlight.odin (`Hl`, `KEYWORDS`, `TYPES`, `classify_ident`, `in_type_position`,
  `highlight`), src/app/editor_view.odin (`HL_COLORS`, `run_color`).

### 16. Generated names

- **Trigger**: Any insertion that needs a name: a variable, a parameter, a procedure (after the first), a type,
  a constant, a labeled block's label (Scope and blocks > Labeled block), an unknown call's name ("Other (name
  it yourself)"), comment placeholder text. (`set_slot_literal`'s `"__lit_ref__"` branch would also generate
  one, but `menu_select` routes "Reference" to the name pick before reaching it, so that path is dead.)
  **Loop variables and loop labels don't use this generator**: loops.odin `fresh_name` picks conventional
  names - `item`, `index`, `i` (then `j`, `k`), label `outer` - and, if taken in scope, appends `_2` ... `_99`.
- **Behavior**: 20 adjectives (brave calm clever swift quiet bright bold gentle lucky mighty nimble proud sly
  wise eager fuzzy jolly keen merry spry) × 20 animals (otter lynx finch heron bison gecko panda raven tapir
  koala moose quail viper wren yak zebra crane ferret hare ibis). One counter per App (`name_counter`, shared by
  all three styles, never reset by loading): adjective = `counter % 20`, animal = `(counter / 20) % 20`, so the
  sequence is brave_otter, calm_otter, clever_otter, swift_otter, ... spry_otter, brave_lynx, ...
  - `generate_ident` → snake_case `brave_otter` (variables, procedures, parameters, labels).
  - `generate_type` → PascalCase `BraveOtter` (structs, enums, unions, bit sets, distinct, aliases).
  - `generate_const` → UPPER_SNAKE `BRAVE_OTTER` (Values > Constant / Typed constant / Build-config constant).
  - `comment_placeholder` → the ident with spaces: `brave otter`.
  - **The first procedure in a file is `main`** (no node text contains `:: proc` yet); later ones are generated.
    Only this document is checked: a new file in a package whose other file already has `main` still gets
    `main` (a redeclaration; from code reading of `append_proc_node`, its only caller passes no name).
- **Rules & edge cases**: On collision (`is_name_used`: an **editable** field of this document with that exact
  text, or a type / procedure declared in another file of the package) the counter advances to the next
  combination; the adjective_animal generator has no `_2` suffix (EDITOR_MODEL.md §4 says `_2`, `_3`; only
  `fresh_name` does that). Names in non-editable text are not checked. Each style has only 400
  combinations; if all are used the loop never ends. The counter is per App, so names depend on what was
  generated earlier in the session, not only on the current file.
- **Rationale**: EDITOR_MODEL.md §1: "Names are generated, not typed ... You only name things when you *want*
  to." Commit 3b3fe59: first procedure defaults to `main`.
- **Source**: src/model/namegen.odin (`ADJECTIVES`, `ANIMALS`, `pick_words`, `is_name_used`, `generate_ident`,
  `generate_type`, `generate_const`), src/model/model.odin (`append_proc_node`), src/model/stmt_layout.odin
  (`comment_placeholder`).

### 17. Comments and blank lines are document lines

- **Trigger**: Add > File Setup > Comments > "Single-line comment" / "Multi-line comment", File Setup >
  "Blank line"; inside a function, statement menu > Layout > "Comment" / "Multi-line comment" / "Blank line"
  (doc 05); or loading such lines.
- **Behavior**:
  - `// text`: fields `["// "] [text editable, kind comment]` (plus indentation). The default text is a
    placeholder (`comment_placeholder`: a generated name with spaces, `brave otter`) meant to be replaced by
    dictation. From the statement menu (Layout > Comment) the cursor lands on that text. From File Setup >
    Comments the generic Add-menu path runs instead, so the cursor lands on the **green dot after** the new
    comment (verified), and the user moves up onto the text.
  - `/* ... */`: three or more nodes: `/*` (kind `comment_mark`), one editable text line per line (kind
    `comment`, indented one tab more than the markers), `*/`. Inside a function it replaces the statement dot
    and the cursor lands on its text line; from File Setup the cursor lands on the green dot after it. Y on
    any of its lines adds a text line (placeholder text, focused) after it (after `/*` when on `/*`, before
    `*/` when on `*/`); LT+B on a text line removes that line, unless it is the only text line - then, as on
    a marker, the whole comment goes. Hint shown (`block_comment_hint`): `Y: add a line    LT+B: delete line`
    on a text line, `Y: add a line    LT+B: delete comment` on a marker. No green dots inside it; its braces
    don't count for blocks or indentation; its text lines keep their own indentation when formatting.
  - Blank line: a node with one empty fixed field. From the statement menu inside a function: the cursor moves
    on to the next "●" line (or, when inserted at a green dot, to the dot after it). LT+B on a green dot
    deletes the blank line right after the dot, or, if that line isn't blank, the blank line right before it
    (`layout_delete`, checked after the `/* */` delete and before everything else). LT+B on a `//` comment
    line deletes just that line.
- **Rules & edge cases**: Comment text is free text: `fixup_line` never touches a line that starts with `//`
  (pinned by `test_layout_comment_text_round_trip`), and braces in a whole-line comment don't count
  (`brace_delta` returns 0 for it; `line_balance` stops at `//`). But `fixup_line` does rewrite `( )` inside
  `/* */` text lines and inside trailing comments after code (feature 11). Empty comments (`//` alone) and
  `//+` build tags are one fixed field (no editable text). A trailing `// comment` after code makes the line
  unparsed text in most parsers (kept verbatim), except a one-line call statement, which keeps it as a fixed
  tail field (feature 10).
- **Source**: src/model/stmt_layout.odin (`COMMENT_KIND`, `COMMENT_INSERT`, `BLANK_INSERT`,
  `is_comment_line`, `parse_comment_line`, `layout_add_insert`, `layout_fill`, `layout_delete`),
  src/model/block_comment.odin (all), src/model/body_dots.odin (`is_blank_line`, `is_body_slot_line`).

### 18. Copying source

- **Trigger**: The Copy action (RT+A by default; doc 03), or Ctrl+C on a keyboard (fixed in the app layer,
  outside the layout; only in the editor with no overlay, dictation, Reference pick or modifier pick).
- **Behavior**: `copy_selection_source`: on a green dot, the whole file (`nodes_to_source` of every node);
  on a line, that line through the end of the block it opens, by `brace_delta` (a whole procedure when on its
  header; just the line on a `}` line). It uses the cursor line, not a sticky RT selection. Text is
  produced by the same `node_source_lines` + `fixup_line` path as saving (but without `format_doc`, without
  a final newline and without dropping "●" lines, which come out as empty lines). The app puts it on the
  clipboard (`copy_selection`) with status `copied <n> line` / `copied <n> lines`, or `nothing to copy`
  (empty text) / `copy failed`.
- **Source**: src/model/serialize.odin (`copy_selection_source`, `nodes_to_source`).

### 19. Undo

- **There is no undo.** No history of document states exists in src/model. The ARCHITECTURE.md `buffer`
  package with an undo stack is an unused stub (src/buffer/buffer.odin returns false). The safety nets are:
  B at a menu's root restores whatever the menu had provisionally changed (refill, temporary statement line,
  replacement), B while grabbing undoes every move (`grab_ops`), B after adding an Assignment before its target
  is picked removes the line. LT+B deletions are immediate. Unsaved edits live only in memory; the file on disk
  changes only on Save / Save as / Run. There is no "unsaved changes" flag: closing the window, IDE menu >
  Exit, B on the main menu, New Project, or opening another file all drop unsaved edits without asking.

## Invariants & constraints to carry forward

1. **HARD** — The saved text of a line is the concatenation of its fields' texts (minus optional dots and their
   separators), passed through `fixup_line`. Every field-producing parser promises "the fields concatenate back
   to exactly `text`" (`emit_names_prefix`, `emit_proc_params`, `parse_comment_line`). Hidden state never adds
   characters of its own, but it does shape the layout: the `rowend` / `argrows:N` / `break` / `aligned` marks
   in `hint` / `hint_pkg` decide line breaks, row indentation and `=` padding (feature 12), and a menu-built
   proc header is tidied (`proc( ` → `proc(`).
2. **HARD** (pinned by test_parse_round_trip, test_handmade_exact_load_round_trip,
   test_integration_combo_round_trip, the load_decls tests) — Round trip: for Doodle-formatted Odin,
   `doc_to_source(doc_from_source(src)) == src` without its final newline, and
   `file_text(doc_from_source(src)) == src` byte for byte, including the final-newline state. Known
   exceptions, i.e. text that does change on load + save: spacing inside call arguments (`foo( a,b )`), joined
   multi-line calls (re-broken by width / kept groupings only), CRLF → LF, trailing whitespace on every line
   (trimmed by `fixup_line`), `( )` / `(  )` → `()` and `) -> {` → `) {` anywhere outside whole-line `//`
   comments (inside strings, trailing comments and `/* */` text too), single-result parentheses
   (`-> (int)` → `-> int`, `result_list_sync`), and the body of a `/* */` comment whose markers aren't alone on
   their lines (re-parsed as code and re-indented). Everything above was verified by running a scratch copy
   of src/model at 34a2ad1.
3. **HARD** — Lines the loader can't structure are kept as one fixed field and saved unchanged apart from the
   whole-document rules that apply to every line (formatting: indentation and blank lines; `fixup_line`'s
   rewrites and trailing-whitespace trim).
4. **SOFT (a goal, followed closely but not exactly)** — A loaded line gets the field shape (kinds, editable
   parts, dots) the menu would have built; menus and loader share builders where possible (`import_node`,
   `emit_expr`), and load_decls_test.odin pins imports, foreign lines, constants and `case :`. Known
   deviations: a loaded callee is `["pkg."]["name"]`, a menu-built one `["pkg"]["."]["name"]`; a loaded number
   is fixed text (LT+A's keypad makes it editable), a menu-built one an editable `0`; a loaded procedure
   header is `name | " :: proc(" | param names editable | rest as text` with **no** `params` dot and no
   result dot unless it has a result (then a `res_more` dot), while a menu-built one is
   `name | " :: proc( " | ●params | " ) -> " | ●type | " {"`.
5. **SOFT (only partly true)** — Unfilled required dots save as nothing (HARD) and optional dots never save
   (HARD). But loading restores only some of them. Restored (pinned by tests): empty call arguments and
   missing required arguments, typed from the signature; `x :=`, `x =`, `x op=`, `x: T =` (typed) and top-level
   `NAME ::`; `case :`; operator operands (`● | ●` saved as ` | `); `if ● {` / `switch ● {` conditions
   (verified). **Not** restored - the line comes back as fixed text, the dot is gone (verified by building
   each statement in a new `main`, saving and reloading a scratch copy of src/model at 34a2ad1):
   a new procedure's `params` and return-type dots (`main :: proc( ● ) -> ● {` saves as `main :: proc() {`);
   Variable (typed) with both dots unfilled (`brave_otter:  =` reloads as `name | ":  " decl | "= " | ●value`,
   type dot lost); Variable (no value) `brave_otter:` (whole line fixed, name no longer editable); Multiple
   (:=) `a, b := ,` (value dots lost); `defer`, `using`, ` or_return`, ` or_else` (fixed text); `for  {`,
   `for item in  {`, C-style `for i := 0; i < ; i += 1 {`, `when  {` (fixed text); `return ●` reloads with
   only the optional "another value" dot.
6. **HARD** (test_fix_file_text) — Editor-only "●" statement lines are never written, except as the empty
   line of an otherwise empty block; the live document keeps them.
7. **HARD** (test_format_is_stable_and_collapses_blanks, test_format_keeps_statement_dots) — `format_doc` is
   idempotent and never removes a line that holds a dot. Indentation = depth of `{ ( [` in tabs; brackets in
   string / rune literals, `//` comments and structured `/* */` comments don't count.
8. **HARD, with a visual-only extra** — Every line break of the saved file is shown in the editor: the editor and
   the serializer use the same row plan (`call_rows`, `needs_break`; width limit 80 columns, tab = 4). The editor
   may add breaks the file doesn't have (a call too wide for the window once dots and type labels are drawn,
   and continuation rows), and its gutter numbers saved lines only.
9. **HARD** (test_fix_file_text, test_handmade_exact_load_round_trip) — A file without a final newline is
   saved without one; an empty document is saved as an empty file; anything else ends with exactly one `"\n"`.
10. **HARD** — The model is pure logic driven by an abstract `Input` (button edges + trigger holds); it does no
    rendering and never writes files. It does read the file system in a few places: `load_file`,
    `load_siblings` (the package's other files), the `shared:` collection listing when the Add menu is first
    built (`build_import_collections`), and the docs / file-grid / project listings. Every feature is testable
    headless (docs/TESTING.md).
11. **HARD** — Structure is derived from text on demand (brace counting, line patterns); there is no second
    representation to keep in sync (only caches: the RT `tree_path`, `capture_fp`). Context-dependent dots are
    re-synced at the end of every `update` while the editor is active (not while a menu is open; feature 3).
12. **HARD, two exceptions** — Every inserted construct is complete: names are generated, unfilled parts are
    dots. Exceptions: a string / rune literal's text starts empty (a valid `""`), and Assignment's target is an
    empty editable field for the moment between insertion and the immediate name pick (B or "nothing
    declared" removes the line).
13. **HARD** (test_name_generator_*) — Generated names are unique among the document's editable fields and the
    package's sibling types / procedures (not among names inside fixed text); style follows the declaration
    (snake / Pascal / UPPER_SNAKE). The first procedure is `main` (SOFT as a convention, HARD in
    test_first_proc_is_main).
14. **HARD** (keymap.odin `slot_locked`, test_menu_wrap_navigation) — Menus: plain D-pad / A / B always work
    and are not remappable; B pops exactly one level; B at the root undoes the provisional change the menu
    made (an options menu / "Pass as" go back to their pick instead). Grid columns = ceil(sqrt(n)) capped at 8,
    wrap-around.
15. **SOFT** — Small menus (≤ 12 entries) keep author order; larger ones are alphabetical; usage-first section on top.
16. **HARD** — Large package name lists are grouped from the **full** list, then used names are removed and
    pinned on top, so group trails are identical in every file (heat stability, doc 03 F13).
17. **SOFT** — Type-fit graying advises, it does not forbid (except in option menus that say so).
18. **HARD** — Highlighting is a pure function of (line text, import names in scope), per byte.
19. **SOFT** — No undo; nothing is written to disk without an explicit Save / Save as / Run.

## Data model & formats

**Field** (`model.odin`): `text: string` (owned; `""` for dots), `editable: bool` (a name / string / comment
text you can rename or dictate), `slot: bool` (a dot), `kind: string`, `hint: string`, `hint_pkg: string`.
`hint` / `hint_pkg` mean "expected type, written in this import path" on dots, but are **overloaded** as layout
marks on fixed fields: `"rowend"` (`ARG_ROW_END`) on a `", "` ending an argument row, `"argrows:N"` on a call's
`"("`, `"break"` (`LIT_BREAK`) on a struct literal's `"{"` loaded one field per line, with `hint_pkg =
"aligned"` (`LIT_ALIGNED`) when its `=` signs were aligned.

**Every field kind in use** (non-slot kinds; slot kinds are in feature 2):

| kind (constant, file) | on | meaning / what acts on it |
|---|---|---|
| `""` | fixed text or an editable name | plain |
| `"type"` | a filled type (editable) | LT+A reopens the Type menu (`edit_selected`) |
| `"decl"` | ` := ` / `: ` of a declaration | Y: "Declare as" (change.odin) |
| `"string"` | a string literal's text (editable) | dictation free text, text tools, word by word |
| `"comment"` (`COMMENT_KIND`, stmt_layout.odin) | `//` or `/* */` comment text (editable) | dictation |
| `"comment_mark"` (`COMMENT_MARK`, block_comment.odin) | `/*`, `*/` | a stop; LT+B deletes the comment |
| `"import_path"` (`IMPORT_PATH_KIND`, model.odin) | `"core:fmt"` of an import / foreign import | a stop; LT+A swaps the package (`edit_selected` only checks that the line text starts with `import `, so it works for plain and aliased imports, not for `foreign import`) |
| `"kw"` (`KW`, ctrl.odin) | `when`, `else`, `#assert`, attributes, directives, calling conventions, loop keywords | Y options, LT+B removes |
| `"brkw"` (`BR_KW`, branch.odin) | `if`, `else if`, `else`, `switch`, `#partial`, `case` | Y options, LT+B |
| `"label"` (`LABEL_KIND`, loops.odin) | a statement label (editable) | renaming updates its break / continue |
| `"assign_op"` (`ASSIGN_OP_KIND`, loops.odin) | ` = `, ` += `, ... | Y: other operators |
| `"tern"` (`TERN_KIND`, expr.odin) | ` if ` / ` else ` / ` ? ` / ` : ` / ` when ` of a ternary | part of an operator unit |
| `"conv"` (`CONV_KIND`, expr.odin) | `cast(T)`, `transmute(T)`, `auto_cast ` | Y: other form / type |
| `"lit"` (`LIT_KIND`, struct_lit.odin) | a struct literal's `{` / `}` | literal structure |
| `"litkey"` (`LIT_KEY_KIND`) | a field name inside a struct literal (fixed) | literal rows / alignment |
| `"member"` (data_types.odin) | a member name in a struct / enum / union / bit_field body (editable) | doc 04 |
| `"poly"` (data_types.odin) | a `$T` parameter name (editable) | doc 04 / 06 |

Selectable on a line (`selectable`): editable, slot, `decl`, `kw`, `brkw`, `assign_op`, `conv`, `import_path`,
`comment_mark`; plus calls' names and arguments as units (selection.odin).

**Node**: `fields: [dynamic]Field`. **Doc**: `nodes`, `no_final_newline`.

**Entry** (menu item): see feature 5. **MenuView**: `title`, `entries` (display list), `index`, `recent`,
`heat` (per-entry wear 0..1), `heat_root`; `rest` / `labels` unused. **Input**: `confirm, cancel, up, down,
left, right` (press edges), `lt_held, rt_held` (holds), `x, y` (presses).

**Row_Span** (format.odin): `{start, end, extra_indent, suffix, is_arg}` = one visual / saved row of a node.
**Arg_List**: `{open, close, seps[]}` field indices of the outermost call's parens and top-level `", "`.

**Fill markers handled in model.odin** (`Entry.fill`; other areas add many more, each a `*_FILL` constant):
`__var__`, `__param__`, `__stmt_decl__`, `__stmt_typed__`, `__stmt_assign__`, `__stmt_call__`,
`__stmt_multi__`, `__lit_num__` (editable `0`), `__lit_str__` (`"` + editable empty string + `"`),
`__lit_rawstr__` (backticks), `__lit_rune__` (`'`), `__lit_true__` / `__lit_false__` / `__lit_nil__` (fixed
word), `__lit_ref__` (Reference pick), `__call_this_pkg__`, `__call_import__`, `__call_import_proc__`,
`__br_when__`, `__jmp_return__` / `__jmp_break__` /
`__jmp_continue__` / `__jmp_fallthrough__` / `__jmp_defer__`, `__err_orreturn__` / `__err_orelse__` /
`__err_iferr__`, `__scope_block__` / `__scope_using__` / `__scope_label__`; a fill that matches nothing is
treated as a type name (`set_slot_type`). Dead code to skip when porting: `__stmt_call__` is handled but no
menu offers it; the loop markers `__loop_for__` / `__loop_forin__` / `__loop_forinf__` are routed to
loops.odin `loop_fill` → `make_loop` (`is_loop_fill` is tested first), so model.odin's `make_loop_statement`
has no caller. Statement fills add a trailing "●" line (removed again when the statement was inserted from a
green dot, `body_insert_done`; `make_body_statement` gives that line a hard-coded 4-space indent, which the
next `format_doc` fixes). After a fill: `sync_typed_decl_value_hint` (a `x: T = ●` value dot expects the new
`T`); a used `args` dot is re-offered after the new argument (`append_more_args_slot`); a used "another
result / value" dot gets its `", "` (`more_dot_filled`); a pending refill is discarded; the menus close; and
the cursor goes to the k-th editable-or-slot field of the line, where k is the number of such fields before
the filled dot - i.e. onto the first name or dot of what replaced it, or, when the fill left none (`true`,
`nil`, a fixed call), onto the next name / dot after it on the line (`focus_kth_selectable`). An Assignment
(`__stmt_assign__`, or an `x op= ●` fill) then starts the target pick (`assign_pick_start`).

**Serializer layers** (use the same names in Rust):

| proc | output |
|---|---|
| `node_text` | raw concatenation (what highlight sees) |
| `node_source` | one line for saving: optional dots dropped, proc header tidied |
| `node_source_lines` | one or several saved lines (broken calls) |
| `nodes_to_source(a, b)` | lines a..b, each `fixup_line`d, joined by `\n` |
| `doc_to_source` | all nodes (tests, no final newline, "●" lines become empty lines) |
| `save_source` | all nodes minus editor-only "●" lines |
| `file_text` | `format_doc` + `save_source` + final-newline rule (exactly what is written) |

**Persisted format**: the `.odin` file itself, bytes passed through as read (no encoding checks; UTF-8 in
practice), LF line endings (CRLF is converted), tab indentation after formatting, no trailing whitespace, one
final newline unless the opened file had none (or the document is empty). Nothing about dots, kinds or hints
is persisted; everything is recovered from the text on load (as far as the loader can: invariant 5).

## Tests that pin this behavior

| Test (file) | Asserts |
|---|---|
| `test_parse_round_trip` (model_test.odin) | `doc_to_source(doc_from_source(src)) == src` |
| `test_parse_package_line`, `test_parse_top_level_declaration` (model_test.odin) | `package main` = fixed + editable; `foo :: proc() {` = editable `foo` + fixed rest |
| `test_parse_various_lines` (model_test.odin) | import path kind, comment fields, call name its own field, variadic `args` dot, `}` one fixed field, `node_source` unchanged |
| `test_parse_trailing_newline` (model_test.odin) | one trailing newline stripped on load |
| `test_serialize_empty_proc`, `test_serialize_proc_with_return` (model_test.odin) | menu outline saves as `main :: proc() {`, keeps `-> int` |
| `test_fixup_line_*` (model_test.odin) | `( )`/`(  )` → `()`, empty `->` dropped, trailing spaces trimmed |
| `test_grid_cols_prefers_square`, `test_menu_wrap_navigation` (model_test.odin) | column counts; wrap at all four edges |
| `test_usage_first`, `test_make_view_filters_platforms`, `test_no_bucketing_for_small_menu`, `test_bucketing_for_large_menu` (model_test.odin) | already-imported first; OS filter; ≤ 12 author order; 30 entries flat and sorted |
| `test_import_menu_hierarchical`, `test_used_procs_first`, `test_small_package_flat` (model_test.odin) | package grouping, pinned used procs, flat small packages |
| `test_name_generator_*`, `test_first_proc_is_main` (model_test.odin) | snake / Pascal / UPPER_SNAKE, uniqueness over 11 procs, first proc `main` |
| `test_recent_section_layout_and_nav`, `test_no_recent_section_is_plain_grid`, `test_all_recent_is_not_a_section`, `test_used_proc_is_recent_section` (menu_sections_test.odin) | section rows and D-pad |
| `test_load_restores_unfilled_argument_dot`, `test_load_adds_dots_for_missing_arguments`, `test_one_arg_per_line_round_trip`, `test_load_call_statement_shapes`, `test_comment_inside_multiline_call_is_left_alone` (parse_calls_test.odin) | call parsing, typed dots, spacing normalization, multi-line join and exact re-save |
| `test_load_import_and_string_constant`, `test_load_aliased_import`, `test_load_constant_values`, `test_load_empty_case`, `test_load_empty_constant`, `test_foreign_lines` (load_decls_test.odin) | exact field shapes of loaded lines, `file_text` exact |
| `test_format_indents_and_spaces`, `test_format_is_stable_and_collapses_blanks`, `test_format_switch_struct_and_multiline_call`, `test_format_keeps_statement_dots` (formatter_test.odin) | formatter rules, idempotence, "●" lines survive |
| `test_long_call_saved_one_arg_per_line`, `test_short_call_stays_on_one_line`, `test_broken_variadic_call_drops_unfilled_green_dot`, `test_call_rows_plan`, `test_text_cols`, `test_highlight`, `test_copy_selection_source` (format_test.odin) | row plan, 80-column break, highlight classes, copy ranges |
| `test_block_comment_from_file_setup`, `test_block_comment_in_a_function`, `test_block_comment_loader` (block_comment_test.odin) | `/* */` building, Y / LT+B, loader, no dots inside, braces ignored |
| `test_layout_blank_lines_in_body`, `test_layout_file_scope_comment_and_blank`, `test_layout_comment_text_round_trip`, `test_layout_arg_rows` (stmt_layout_test.odin) | blank lines kept / dropped, comments verbatim, Join / Own row |
| `test_fix_file_text` (integrate_fixes_test.odin) | "●" lines dropped on save, block's only "●" as blank line, final-newline rule |
| `test_integration_handmade_loads_with_all_features`, `test_integration_combo_round_trip`, `test_integration_reload_empty_operator_operands`, `test_integration_reload_open_values` (integration_test.odin) | real files round-trip and format unchanged; unfilled operands / values reload as typed dots |
| `test_handmade_exact_load_round_trip`, `test_handmade_exact_build` (handmade_exact_build_test.odin) | a real program loads and saves byte-exact (with and without final newline) and passes `odin check`; the same file built from New Project with controller inputs only |
| `test_walk_starts_at_the_cursor_line` (tree_start_test.odin) | derived structure (RT walk) from a loaded file (doc 02) |

Not covered by any test: saving and reloading each menu-built construct with its dots unfilled (the losses
listed in invariant 5), `fixup_line` inside strings / trailing comments / `/* */` text, and result-list
parenthesis normalization. A Rust port should add a property test: for every menu entry, build it in an
empty function, `file_text`, reload, and assert the same field shapes (dots included).

The testing pattern to copy: construct an `App`, call `doc_from_source` or drive `update(&app, Input{...})`
with synthetic presses, then assert on `doc.nodes` field shapes (a compact "text/kind/ed" string per line is
very effective) and on `file_text`. docs/TESTING.md: "Prefer asserting on `model.App` fields".

## Carrying this to Rust

**(a) What transfers unchanged**

- The projection: document = `Vec<Line>`, line = `Vec<Field>`, field = text + editable + slot + kind + hint.
  Saved text = concatenation. Dots with kinds, colors and expected-type labels. Optional vs required dots.
- The round-trip contract (invariants 1-9) as the target, made to hold where Doodle only approximates it:
  loaded files save back byte-exact (without Doodle's exceptions listed in invariant 2); unrecognized code is
  kept verbatim; unfilled required dots save as nothing (or as a placeholder, see d) and **all** of them come
  back on load (Doodle loses many, invariant 5); editor-only statement lines never reach disk.
- The menu machinery: entry tree, view stack, B pops one level and B at root undoes the provisional change,
  square-ish grid with wrap-around, usage-first and "RECENTLY USED", author order ≤ 12 / alphabetical above,
  stable grouping of big name lists (file → block/module → prefix → alpha buckets of 12), advisory graying.
- The pure-model / thin-app split, headless tests through an abstract `Input`, re-sync passes after each input.
- Name generation (the three styles map 1:1 to Rust's conventions: snake_case for fns, locals, fields,
  modules and `macro_rules!` names; UpperCamelCase for types, traits, enum variants and type parameters;
  SCREAMING_SNAKE_CASE for `const` / `static`; lifetimes are short lowercase `'a`). The "first fn is `main`"
  rule only makes sense for `src/main.rs` / `src/bin/*.rs`, not for library modules.
- Formatting on open and on save; what-you-see-is-what-is-saved row layout for long argument lists (every
  saved break visible; extra visual-only wraps allowed).

**(b) Odin-specific pieces and their Rust analog**

| Odin in Doodle | Rust |
|---|---|
| `kind: string` with magic values (`"value"`, `KW`, ...) | `enum FieldKind { Plain, Type, Decl, Str, Comment, ..., Slot(SlotKind) }` |
| `Entry.fill: string` markers (`"__stmt_decl__"`) and "exactly one behaviour applies" | `enum EntryAction { Submenu(Vec<Entry>), Insert(..), Fill(Fill), Placeholder, ... }`; `enum Fill` with payloads (`CallImport { pkg, name, ret }`) instead of `call_name`/`call_pkg` side fields |
| ~40 bool / int mode flags on `App` | an enum of modes with per-mode data (`Mode::Menu(MenuCtx { purpose: Fill{..} / Replace{..} / Refill{saved} / BodyInsert{..} ... })`), so B-at-root undo is a `match` on the purpose |
| `-1` / `ok bool` sentinels, `(ni, fi, ok)` returns | `Option<(usize, usize)>` |
| `defer` sync passes in `update` | an explicit `fn after_input(&mut self)` called at the end of `update` |
| `context.temp_allocator`, manual `delete`, `owned_label`, `hint_pool` interning | owned `String`/`Vec`; `Rc<str>` or `Arc<str>` for hints; optionally a per-frame `bumpalo` arena |
| `inject_at`, `ordered_remove`, `remove_range` | `Vec::insert`, `Vec::splice`, `Vec::remove`, `Vec::drain` |
| `bit_set[Action]` (`requests`) | `enumset::EnumSet<Action>` or `bitflags` |
| `when ODIN_OS` / `os_name` | `cfg!(target_os = ...)` / `std::env::consts::OS` |
| generated `CORE_*` tables (`core_procs.odin`) | rust-analyzer queries at runtime, or tables generated ahead of time from rustdoc JSON (`cargo +nightly rustdoc -- -Z unstable-options --output-format json`; nightly-only, format still unstable) |
| a package = every `.odin` file in a folder, names shared without imports (`sibling_procs` / `sibling_types`) | a crate = a module tree declared with `mod`; another file's items need a path or `use` (`crate::foo::bar`) and `pub` visibility, so "names from sibling files" must come with the path / `use` that makes them reachable |
| calling conventions (`proc "c"`), `foreign` blocks | `extern "C" fn`; `unsafe extern "C" { ... }` blocks (the `unsafe` is required from edition 2024) |
| `@(private="file")` | private items in a module |
| `odin test src/model` / `-define:ODIN_TEST_NAMES` | `cargo test -p model`, `cargo test <name>` |
| `odin check` diagnostics | `cargo check --message-format=json` |

**(c) Rust concepts this area will need, and how the projection extends**

- **Lines vs. expressions**: Rust is expression-oriented (closures with block bodies, `match` arms, `if` as a
  value, builder chains). A closure or `match` inside an argument breaks "one node = one line". Keep lines as
  the unit, but allow a multi-line construct to own a *range* of lines (Doodle already does this for blocks and
  broken calls), and give closures a `body` dot that opens nested statement lines.
- **Semicolons and tail expressions**: a block's last expression without `;` is its value. Add a slot kind
  "tail" (expected type = the fn's return type) and let `fixup` / the serializer own `;` placement so the user
  never manages them.
- **Ownership / borrowing**: value dots need fills for `&x`, `&mut x`, `x.clone()`, moves; gray options by
  borrow-check feasibility only as advice (like Doodle's type fitting).
- **Pattern matching**: `match` arms are like Doodle's `case` lines (a `variant` dot per arm); add a
  "pattern" slot kind with fills for enum variants (with bindings), literals, `_`, ranges, `Some(●)` /
  `Ok(●)`.
- **Option / Result and `?`**: the "Error handling" group maps to `?` (only valid inside a fn returning
  `Result` / `Option` or another `Try` type: gray it elsewhere), `.unwrap_or(●)`, `if let Some(●) = ● {`, and
  let-else `let Some(●) = ● else { ● };` (the `else` block must diverge - `return`, `break`, `continue`,
  `panic!` - and the statement ends with `;`).
- **Traits / impl blocks**: `impl T {` and `impl Trait for T {` bodies are data-like containers (as Doodle's
  struct bodies get member menus): their green dots offer fn / const / type items; for a trait impl, offer the
  missing required items first, gray the ones already present.
- **Generics, lifetimes, where clauses**: Doodle's `poly` kind (`$T`) generalizes to generic params; add
  "lifetime" (`'a`) and "bound" slot kinds; a `where` line is its own node.
- **Macros**: treat `name!(...)` as a call whose callee ends in `!` (variadic `args` dot for `println!`,
  `vec!`, `format!`); a format string's text is a `string` field with dictation. Macro invocations may use
  `()`, `[]` or `{}` (`vec![..]`), so the argument-list finder must accept all three. The number of
  positional `{}` placeholders in a format string must match the arguments (a compile error otherwise), so
  the "required arguments" of `format!`-family macros come from parsing the format string. A macro's input
  is a token tree, not expressions: structure only well-known macros; `macro_rules!` stays verbatim.
- **Attributes / derives**: Doodle's purple attribute dot above procedures generalizes to items:
  `#[derive(..)]` options grayed when a field type can't derive them; `#[test]`, `#[cfg(..)]`.
- **Modules / visibility / use paths**: `use a::b::{c, d};` lines are the imports (path a stop, LT+A swaps);
  `pub` / `pub(crate)` is a `kw`-style toggle on items; `mod foo;` relates sibling files (doc 07 §9-11 for siblings, doc 09 for files).
- **async / await**: `.await` as a postfix operator fill (only inside `async` fns / blocks); `async fn` as a
  modifier like a calling convention.
- Highlighting needs extra classes: Lifetime, Macro, Attribute, and Self/self.

**(d) Implementation advice for this area**

- Don't copy the line-based parser. Use a lossless, error-tolerant CST: `ra_ap_syntax` (rust-analyzer's rowan
  trees; every byte including whitespace and comments is in the tree, so concatenation equals the source by
  construction) or tree-sitter-rust (error-tolerant too, but whitespace is not a node: keep it from the
  source by byte ranges). Project CST nodes onto `Line`/`Field` with byte ranges; a region you can't
  structure stays one fixed field, exactly like Doodle's fallback. This also removes Doodle's
  loader gaps (invariant 5) and its comment / string blind spots, because comments and literals are tokens.
- Use rust-analyzer (`ra_ap_ide`, or the LSP) as the type oracle for dot hints and fit-graying, completions
  for "names in scope", and `cargo check --message-format=json` for diagnostics.
- Placeholders: Doodle saves unfilled dots as nothing and relies on its loader, which only partly works
  (invariant 5). In Rust consider saving an unfilled value dot as a macro call that compiles and is
  unambiguous on load, e.g. `todo!("●")` (a bare `todo!()` the user wrote on purpose would otherwise turn
  into a dot); `todo!()` has type `!`, so it fits any expected type (rustc warns about unreachable code after
  it). An unfilled type can be saved as `_` only where Rust allows type inference (`let` bindings, closure
  parameters, turbofish); in item signatures (fn parameters / return types, struct fields, `const` /
  `static`) `_` is error E0121, so there either omit the part (return type: omit `-> `, as `fixup_line`
  does) or keep "nothing" and restore the dot from the CST's error nodes. Never rewrite inside string
  literals or comments (Doodle's `fixup_line` does, see gaps).
- Formatting: implement the layout rules natively (they must keep dots and "●" lines, which rustfmt can't) but
  follow rustfmt's output for real code: 4-space indentation, `max_width = 100` (not 80), trailing commas in
  vertical lists. rustfmt's default `use_small_heuristics` also breaks a call whose argument list is longer
  than `fn_call_width` (60) even when the whole line fits in 100, and similar limits exist for struct
  literals (`struct_lit_width` 18) and chains (`chain_width` 60), so copy those widths, not just
  `max_width`. Verify with `rustfmt --check` in tests so saved files are rustfmt-stable.
- Highlighting: derive classes from CST token kinds (or tree-sitter highlight queries) rather than a regex
  scanner; keep it a pure function so it can be unit-tested per byte like `test_highlight`.
- Name generation: also avoid Rust keywords and every name rust-analyzer reports in scope; fall back to a
  numeric suffix instead of looping forever.

## Open questions & known gaps

- **`fixup_line` rewrites inside string literals and comments**: `fmt.println("( )") // x ( )` saves as
  `fmt.println("()") // x ()`, `") -> {"` inside a string becomes `") {"`, and a `/* */` text line
  `call f( ) here` becomes `call f() here` (verified by running a scratch copy of the model against the code
  at 34a2ad1). It only skips lines that start with `//`.
- **Many unfilled constructs lose their dots on save + reload** (invariant 5 has the verified list): a new
  procedure's params / return dots, Variable (typed) with both dots unfilled (`brave_otter:  =`, not valid
  Odin, reloads without its type dot), Variable (no value), Multiple (:=), `defer`, `using`, `or_return`,
  `or_else`, `for` / `for in` / C-style `for` / `when` headers with an empty part. They come back as fixed text
  with no dot, so the missing part can't be filled from the controller any more (deleting the line with LT+B
  and re-adding it works). Saving half-finished work and reopening it is therefore lossy in Doodle; the
  Rust version should make every dot recoverable.
- **A `/* */` comment whose `/*` or `*/` shares its line with text is parsed as code** (its inner lines can be
  respaced as calls and are re-indented; verified).
- **A `//` comment directly above an `import` splits the import group** (the formatter gives the comment the
  kind Single and inserts a blank line before it; verified).
- **Single-result parentheses are dropped on save** (`-> (int)` → `-> int`, `result_list_sync`; verified).
  Harmless for Odin, but it is a change the user didn't make.
- **A failed load still changes the current file** (`filenav_load` calls `set_current_file` before
  `load_file`), so the next Save writes the old document to the path that couldn't be opened (from code
  reading).
- **The first procedure of a new file is always `main`**, even when another file of the package already
  declares `main` (from code reading).
- **`collect_called_procs` can pin a junk "used" entry** when a line has `ref.NAME` followed later by an
  unrelated `(` (from code reading).
- **The first-save status string says `rename it in Files (LT+X)`** but Files is RT+B in the default layout
  (LT+X is Talk); the string is hard-coded instead of using `action_slot_name`.
- **Unfilled dots generally make the saved file not compile** (`x :=`, `foo(a, )`); only the empty proc outline
  is fixed up. A background `odin check` (doc 07 §14) will flag them.
- **CRLF files are saved with LF** silently; tabs replace space indentation on first format; trailing
  whitespace is trimmed from every line (verified).
- **No undo, and no unsaved-changes tracking**: opening another file (file navigation, Previous file) replaces
  the document without saving or asking, and IDE menu > Exit, B on the main menu and closing the window quit
  without asking (src/app/filenav.odin `filenav_load`, model.odin `menu_select` `quit`, `update` `.Menu`;
  verified for the model side). Worth adding a dirty flag and an undo stack (snapshots of `Vec<Line>` are
  cheap) in the Rust version.
- **Name generator**: no `_2` suffix for adjective_animal names despite EDITOR_MODEL.md (only loops'
  `fresh_name` has one); infinite loop if all 400 combinations of a style are taken; collision check ignores
  names inside non-editable text (e.g. a loaded line Doodle kept as text).
- **In a file without imports, every `name.` is highlighted as a package** (an empty import list is `nil`,
  which `highlight` treats as "any"; verified).
- **Block-comment text is syntax-highlighted as code** (`highlight` sees a line without `//`, so a keyword word
  in a `/* */` comment is colored as a keyword); `//` comments are fine.
- `text_cols` counts bytes, so non-ASCII text breaks lines early. Identifiers are ASCII-only on load.
- `make_view` treats only plain `import "path"` lines as "already imported" (aliased imports don't float up);
  `recent_imports` is per session, not persisted.
- `BUCKET_TARGET`, `MenuView.rest`, `MenuView.labels` are dead leftovers of the old bucketing; also dead:
  model.odin `make_loop_statement` (loops go through loops.odin `make_loop`), the `__stmt_call__` fill
  (offered by no menu) and the `__lit_ref__` branch of `set_slot_literal`.
- `State.Radial` / `draw_radial` and EDITOR_MODEL.md §3's radial diagram describe a radial menu; the real menu
  is a flat grid. docs/UX.md (modal free-text editing, LSP navigation) and ARCHITECTURE.md's buffer / editor /
  lsp packages are superseded by the projectional model.
- Main menu "Open Folder" is not wired (A on it does nothing; the menu footer says so).
- A brand-new empty procedure is not byte-stable across one reload (`{\n\n}` becomes `{\n}` after the open-time
  format); harmless, but the Rust version could write `{\n}` directly.

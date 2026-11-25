# 04 — File-scope constructs: the Add menu

> Odin sources: src/model/model.odin (`ensure_menus`, `open_add_menu`, `menu_select`, `menu_cancel`, `append_proc_node`, `append_type_node`, `append_value_node`, `import_node`, `alias_default`, `make_slot_param`, `edit_selected`, `open_slot_menu`, `insertion_points`, `dot_points`), src/model/data_types.odin, src/model/data_member_edit.odin, src/model/ctrl.odin, src/model/ctrl_parse.odin, src/model/when_cond.odin, src/model/when_const.odin, src/model/modifiers.odin, src/model/attr_dots.odin, src/model/collections.odin, src/model/result_list.odin, src/model/block_comment.odin, src/model/stmt_layout.odin (File Setup leaves), src/model/change.odin (Declare as), src/model/parse.odin (loader side), src/model/serialize.odin + src/model/calls.odin `node_source` (saving), src/model/namegen.odin, src/model/types_menu.odin, src/model/core_tree.odin (generated, head only), src/app/main.odin `slot_dot_color`, src/app/editor_view.odin. Baseline: Doodle @ 34a2ad1.

## Purpose

This area is everything you can put at the top level of a source file: the package line, comments, imports, procedures, type declarations, constants and globals, compile-time `when` blocks and `#assert`s, and modifiers on existing declarations (attributes, struct directives, calling conventions). The user never types these. They press **A** on a green insertion dot between top-level declarations, pick a leaf from the 7-group **Add menu**, and get a complete skeleton with generated names and typed holes ("dots") to fill next. On a gamepad you can't type `struct {`, so the file's structure has to come from menus. Every skeleton is shaped so that the menus offered for its holes can react to the code around them (a bit_set's dot lists the file's enums, a `when` condition grays calls, `@(test)` is grayed for procedures that can't be tests). Code loaded from disk is re-structured into the same fields wherever the loader recognizes the shape (exactly so for type declarations, invariant 2), so editing a hand-written file mostly works the same as editing a menu-built one. Unrecognized lines stay fixed text.

## Features

### 1. Opening the Add menu (A on a file-scope green dot)

- **Trigger**: In the editor, put the cursor on a green insertion dot at file scope and press **A** (plain bank, "Select"). File-scope dots sit at the top of the file, between every pair of top-level declarations, at the bottom, and between the declarations inside a file-scope `when` block.
- **Behavior**: Opens a grid menu titled exactly `Add  (insertion point)` (two spaces). It has seven groups in this order: `File Setup`, `Dependencies`, `Procedures`, `Types`, `Values`, `Compile-time`, `Modifiers`. The grid has 3 columns: `grid_cols(n)` is the smallest c with c² ≥ n, capped at 8. The D-pad moves with wrap-around and A opens a group. The whole tree, labels exact and in authored order (`ensure_menus`, `compile_time_entries`, `modifier_entries`):
  ```
  File Setup    : Package declaration | File tags | Comments ▸ (Single-line comment | Multi-line comment) | Blank line
  Dependencies  : Import ▸ | Aliased import ▸ | Foreign import | Foreign block      (▸ = core | base | vendor | shared)
  Procedures    : Procedure
  Types         : Struct | Polymorphic struct | Enum | Union | Bit set | Bit field | Distinct type | Type alias
  Values        : Constant | Typed constant | Build-config constant | Global variable (typed) | Global variable (init)
  Compile-time  : When block | Static assertion
  Modifiers     : Attributes | Struct directives | Calling convention
  ```
  A leaf inserts its construct at the dot (`insert_at` = the dot's line index), and then:
  - Package, comment, blank line, import, foreign, procedure, type and value leaves leave the cursor on the green dot just after what was inserted (`focus_dot_at(insert_at)`).
  - `When block` / `Static assertion` put the cursor on the new condition dot.
  - `Modifiers` leaves start a pick mode (feature 26).
- **Rules & edge cases**:
  - Which menu A opens depends on where the dot is (`update`, `.Editor` branch). A dot that is not a file-scope insertion point but sits inside a function body opens the **statement menu** (doc 05). A dot inside a struct/enum/union/bit_field body opens the **member menu** (feature 15). Only file-scope dots open the Add menu. A file-scope `when` counts as file scope: its braces are "see-through" (`block_infos`, `Block_Info.decl_depth`). No dots appear inside a `/* */` comment (`inside_block_comment`).
  - `dot_points` shows only one dot per gap around a blank line. The dot directly below the declaration above the blank line stays.
  - **B** pops one menu level. B at the root closes the menu and inserts nothing (`menu_cancel`).
  - When the dot is inside a file-scope `when`, `Dependencies` is drawn grayed (`ctrl_add_menu_opened`; test `test_imports_dimmed_inside_when`, message "imports can't go in a when"). The gray is only advisory: `menu_select` never checks `dim` for Add-menu entries, so A still opens the group and inserts an indented import inside the `when`. Odin really does reject that: `odin check` gives `Syntax Error: Cannot use 'import' within a 'when' statement. Prefer using the file suffixes (e.g. foo_windows.odin) or '#+build' tags` (verified against the installed compiler). `foreign import` and `foreign` blocks *are* legal inside a `when` (core:c/libc does this in every file), so the gray is too broad for those two leaves. A Rust port should refuse plain imports there and keep the foreign ones.
  - Everything inserted at a dot inside a file-scope `when` is indented by the `when`'s depth (`ctrl_indent_inserted`, `decl_indent_at`). The indent unit is a tab, unless the first indented line in the document uses spaces (then 4 spaces; `indent_unit_of`). `format_doc` re-indents everything with tabs. It runs on every save (`file_text`) and on every load from disk in the app (src/app/filenav.odin `filenav_load`); `doc_from_source` by itself does not format.
  - Each real leaf use adds wear to its menu path (`heat_record_select`). Submenus don't count. See docs 03 and 10.
- **Rationale**: In a projectional editor the green dot is the only place new structure can appear. The menu lists only what is valid there (EDITOR_MODEL.md §1–2).
- **Source**: model.odin `open_add_menu`, `ensure_menus`, `menu_select`, `menu_cancel`, `update`; ctrl.odin `ctrl_add_menu_opened`, `ctrl_indent_inserted`, `block_infos`; body_dots.odin `body_points`.

### 2. Generated default names

- **Trigger**: Any leaf that declares something.
- **Behavior**: Names come from 20 adjectives × 20 animals (`brave calm clever swift quiet bright bold gentle lucky mighty nimble proud sly wise eager fuzzy jolly keen merry spry` × `otter lynx finch heron bison gecko panda raven tapir koala moose quail viper wren yak zebra crane ferret hare ibis`). One counter per App picks adjective `counter % 20` and animal `(counter/20) % 20`, and goes up on every attempt. The case depends on what is being named:
  - values, globals, parameters and struct fields: `brave_otter`
  - types and enum members: `BraveOtter`
  - constants: `BRAVE_OTTER`
  - comment placeholders: words, `brave otter`
  - A name is skipped if any editable field in the document already has that text, or if a type or procedure in a sibling file of the package already uses it.
- **Rules & edge cases**: The first `Procedure` in a file is named `main`, without using the counter. "First" means no line in the document contains `:: proc` yet; sibling files are not checked. All later procedures get generated names. A fresh document typically produces `BRAVE_OTTER`, `CALM_OTTER`, `CLEVER_OTTER`, `swift_otter`, and so on. The counter lives on the App and is not reset by `doc_reset`, so it keeps counting across loaded files. Names that do *not* come from this generator: `main`, the polymorphic-parameter names (`T U V W K E P Q`, `N M L SIZE COUNT`, feature 14, which are only checked against the same header line), the `t` added by `@(test)` (feature 29) and import aliases (`alias_default`, feature 6).
- **Rationale**: "Names are generated, not typed" (EDITOR_MODEL.md §1). You rename only when you want to (dictation or text tools, doc 08).
- **Source**: namegen.odin `generate_ident`, `generate_type`, `generate_const`, `is_name_used`; stmt_layout.odin `comment_placeholder`.

### 3. File Setup > Package declaration

- **Trigger**: Add > `File Setup` > `Package declaration`.
- **Behavior**: Inserts `package main` as the fields `[package ][main]`. `main` is editable. The menu has no package-name choice; rename by dictation.
- **Rules & edge cases**: It is inserted at whatever dot you chose, not forced to the top. A new project starts as an **empty** document. EDITOR_MODEL.md says the package line is "Auto-added", but the code does not do that (`new_project` → `doc_reset`), so the user's first action is normally this leaf. The loader gives every `package X` line the same two fields.
- **Source**: model.odin `kw_leaf`, `append_kw_node`; parse.odin `parse_line`.

### 4. File Setup > File tags

- **Trigger**: Add > `File Setup` > `File tags`.
- **Behavior**: Inserts the fixed line `#+build linux` (one non-editable field).
- **Rules & edge cases**: There is no choice of tag. The line has no selectable part, so the D-pad never stops on it (`editor_stops` only lists lines with at least one leaf). Odin requires file tags above the `package` line (`Syntax Error: Lines starting with #+ (file tags) are only allowed before the package line.`, verified with `odin check`); the menu does not enforce that, so the user has to choose the top dot. EDITOR_MODEL.md's other tags (`#+private`, `#+feature`, `#+ignore`) are not offered. The line can still be reached with the RT tree walk (`tree_roots` lists every non-blank line; `tree_sync_cursor` puts the cursor on it with `editor_dot = false`), and LT+B there falls through `delete_selected` to "delete just this single node". That path is code-read only; no test covers it.
- **Source**: model.odin `ensure_menus` (`leaf("File tags", "#+build linux")`), `append_text_node`.

### 5. File Setup > Comments, Blank line

- **Trigger**: Add > `File Setup` > `Comments` > `Single-line comment` | `Multi-line comment`; Add > `File Setup` > `Blank line`.
- **Behavior**:
  - Single-line comment: `// brave otter`, as `[// ][brave otter]`. The text is editable (kind `comment`) and dictation fills it.
  - Multi-line comment: three lines: `/*` (a marker stop), `\tbrave otter` (editable text), `*/` (a marker stop).
  - Blank line: one empty fixed field.
- **Rules & edge cases**:
  - LT+B on a single-line comment deletes it.
  - On a multi-line comment: Y on any line adds a text line after it (before `*/` when on the closing marker), with a new generated placeholder, and the cursor goes to it. LT+B on a text line deletes that line, and deletes the whole comment if it was the last text line. LT+B on a marker deletes the whole comment. HUD hint (`block_comment_hint`): `Y: add a line    LT+B: delete line` on a text line, `Y: add a line    LT+B: delete comment` on `/*` or `*/`.
  - After any of these three leaves the cursor is on the green dot after the insertion (for the multi-line comment, the dot after `*/`), not on the text. Dictating into the text means moving up onto it first.
  - The loader gives a `// text` line the same `[indent][// ][text]` fields (`parse_comment_line`). Empty comments and `//+` lines stay one fixed field. A `/*` … `*/` comment is structured only when both markers are alone on their lines (`parse_block_comment`).
  - LT+B on the green dot right above or right below a blank line deletes that blank line.
  - A comment's braces don't count as code.
  - `format_doc` keeps a comment attached to the declaration below it and collapses runs of blank lines into one.
  - The same items exist inside functions (statement menu > `Layout`, doc 05) and inside data bodies (feature 15).
- **Source**: stmt_layout.odin `layout_add_insert`, `COMMENT_INSERT`, `BLANK_INSERT`, `layout_delete`; block_comment.odin (all); formatter.odin `format_doc`.

### 6. Dependencies > Import / Aliased import (the package tree)

- **Trigger**: Add > `Dependencies` > `Import` or `Aliased import`.
- **Behavior**: Both open the same tree with four collections, in order: `core`, `base`, `vendor`, `shared`.
  - `core`, `base` and `vendor` come from generated flat rows (`CORE_ROWS`, `BASE_ROWS`, `VENDOR_ROWS`, each `{depth, label, path, platform, dim}`), built into a tree.
    - A package that has sub-packages becomes a group. Its first child is a leaf `import <name>` for the package itself, e.g. `c` → `import c`, `libc`.
    - Sub-packages that are only imported inside their parent's tree sit under a grayed group `internals`.
    - Single-child chains are collapsed (`intrusive/list`).
  - `base` lists `intrinsics`, `runtime` and `sanitizer`. `base:builtin` is left out because it only documents built-ins and can't be imported.
  - `shared` is scanned when the menu is built. `ensure_menus` builds the Add menu once per App and caches it, so in practice the scan happens once per run (`build_import_collections` is called twice, once for `Import` and once for `Aliased import`, because the two subtrees must not share memory). It lists every folder under `<odin_root>/shared`, up to 4 levels deep, that holds a `.odin` file other than `*_test.odin`, skipping dot-folders, `tests` and `examples`, sorted by byte order. Labels are relative paths (`gfx/sprites`) and paths are `shared:gfx/sprites`. With no packages it shows one grayed, non-actionable placeholder: `(empty: add packages to <root>/shared)`.
  - `odin_root` is `$ODIN_ROOT`, else the folder holding `odin(.exe)` on PATH, else `C:/Odin`.
  - Picking a leaf:
    - `Import` inserts `import "core:fmt"`.
    - `Aliased import` inserts `import fmt "core:fmt"` with the alias editable.
- **Rules & edge cases**:
  - **Ordering in every view** (`make_view`): entries for another OS are hidden (`Entry.platform` is a comma list compared to `app.os_name`; e.g. `vendor:darwin` and `android` are hidden on Windows). Then come:
    1. leaves already imported in this file
    2. imports used this session, most recent first (`recent_imports`, not persisted)
    3. pinned entries

    Together these form a separate "recently used" section on its own grid rows (only drawn as a separate section when something follows it). After that come the remaining entries, sorted alphabetically (case-insensitive) when there are more than 12, otherwise in authored order. Two consequences: in a group with more than 12 children the `import <name>` leaf is sorted among its siblings instead of staying first; and "already imported" (`is_imported`) compares whole lines with `import "<path>"`, so a package imported *with an alias* is not pulled to the front.
  - **Default alias** (`alias_default`):
    1. The `IMPORT_NAMES` override for folders that aren't identifiers, e.g. `vendor:lua/5.4` → `lua`, `vendor:libc-shim` → `libc_shim`, `core:odin/doc-format` → `doc_format`.
    2. Otherwise the last path segment.
    3. A version-number folder takes its parent's name (`shared:foo/1.0` → `foo`).
    4. Other non-identifier characters become `_`, with a leading `_` before a digit.
  - A path whose last segment isn't an identifier is **always** inserted with a name, even from plain `Import` (`needs_import_alias`), because `import "vendor:lua/5.4"` doesn't compile.
  - Duplicate imports are not prevented: picking `fmt` twice inserts two lines (probe-confirmed; `menu_select` has no duplicate check). Odin rejects the result: `Error: Redeclaration of 'fmt' in this scope` (verified with `odin check`).
  - The `import_alias` flag is set when you enter `Aliased import` and is only cleared when the Add menu reopens (`open_add_menu`), when `Edit import` opens, or when an *import* leaf is used. `menu_cancel` (B) leaves it alone. So B out of `Aliased import`, then `Import > core > fmt`, inserts `import fmt "core:fmt"` (probe-confirmed bug, consistent with the code).
  - Imports drive other menus: each import adds a `<ref>.` group to every Type menu, to Call > From import, and to Constant (doc 06).
- **Rationale**: Imports are chosen from what is actually installed (the generated tables), filtered to the current platform. The user never types a path.
- **Source**: model.odin `ensure_menus`, `build_core_tree`, `build_rows_tree`, `import_node`, `append_aliased_import_node`, `alias_default`, `make_view`, `record_recent`, `platform_ok`; collections.odin (all); core_tree.odin (generated by tools/gen_core_tree.py).

### 7. Import line structure and swapping a package (LT+A / Y on an import)

- **Trigger**: Cursor on any part of an `import` line (its alias or its `"core:fmt"` path), then **LT+A** (Edit) or **Y** (Change).
- **Behavior**: An import line has the fields `[import ][alias?][ ]["path"]`. The quoted path has kind `import_path`: it is a cursor stop but not editable. LT+A or Y opens a menu titled `Edit import`. This is the **whole Add menu** with `Dependencies` pre-highlighted. Navigating `Dependencies > Import|Aliased import > …` and picking a leaf replaces the line in place (`replacing`, `replace_fi = -1`). B closes it with no change.
- **Rules & edge cases**:
  - A swap through `Aliased import` always gets the **default** alias for the new path; a custom alias is lost (`import str "core:strings"` → `import fmt "core:fmt"`). A swap through plain `Import` drops the alias, unless the path needs one.
  - LT+A on the alias field also opens `Edit import`, not the text tools; dictation still renames the alias.
  - Picking a non-import leaf from `Edit import` (e.g. `Types > Struct`) inserts that construct at the stale `insert_at` and leaves `replacing` set (probe-confirmed bug). Code-read consequence: the next pick in any fill menu (A on a dot, then a fill leaf) goes into `menu_select`'s "replacement mode" branch with `replace_fi = -1`, which fills nothing, clears `replacing` and closes the menu. That pick is silently lost. B at the root of any menu also clears `replacing` (`menu_cancel`).
  - Y on the path or the alias also ends in `Edit import`: `change_selected` finds nothing more specific and calls `edit_selected`.
  - The loader parses `import "p"` and `import a "p"` (nothing after them) into the same fields. A trailing comment keeps the whole line as plain text.
- **Source**: model.odin `edit_selected` (import branch), `menu_select` (replace branch), `IMPORT_PATH_KIND`; change.odin `change_selected`; parse.odin `parse_import_line`; load_decls_test.odin.

### 8. Dependencies > Foreign import / Foreign block

- **Trigger**: Add > `Dependencies` > `Foreign import` | `Foreign block`.
- **Behavior**:
  - Foreign import inserts `foreign import libc "system:c"` as `[foreign import ][libc][ ]["system:c"]`, with the name editable and the path an `import_path` stop.
  - Foreign block inserts `foreign libc { }` on one line, `[foreign ][libc][ { }]`, with the name editable.
- **Rules & edge cases**:
  - Both are stops (the name is editable), so LT+B deletes them (`test_foreign_lines`). The loader builds the same fields (`parse_foreign_line`): `foreign import <ident> "<path>"` with nothing after it, and `foreign <ident>` followed by text starting with `{` (`foreign libc {`, `foreign libc { }`; everything from the `{` on is one fixed field). Other forms (a comment after a foreign import, `foreign import { … }` lists) stay one fixed field.
  - The foreign path can't be swapped: LT+A on it does nothing (the line doesn't start with `import `, and the path isn't editable text).
  - Both are legal Odin inside a file-scope `when` (see feature 1), even though `Dependencies` is grayed there.
  - The one-line block has no dots inside, and a loaded multi-line `foreign libc {` block has none either. Procedures can't be added to a foreign block from the menus.
- **Source**: model.odin `menu_select` → parse.odin `parse_foreign_line`; load_decls_test.odin `test_foreign_lines`.

### 9. Procedures > Procedure (outline)

- **Trigger**: Add > `Procedures` > `Procedure`. This is the only leaf in the group. EDITOR_MODEL.md's procedure group, polymorphic procedure and procedure type are not offered.
- **Behavior**: Inserts three lines:
  ```odin
  main :: proc( ● ) -> ● {      // [main][ :: proc( ][●params][ ) -> ][●type][ {]
      ●                         // [    ][●body]
  }                             // [}]
  ```
  The `params` dot is violet. The result-type dot is blue. The body dot is green; A on it opens the statement menu (doc 05). An untouched outline saves as `main :: proc() {` / empty line / `}`: `fixup_line` turns `( )` into `()` and drops `-> ` before `{`, and an only-content `●` line saves as a blank line.
- **Rules & edge cases**:
  - A purple attribute dot appears above the new procedure (feature 30).
  - LT+B on the name, or on the header line outside the result list, deletes the whole procedure.
  - Inside a file-scope `when`, the header and closing brace are indented (`ctrl_test.odin`).
- **Source**: model.odin `append_proc_node`; serialize.odin `fixup_line`, `save_source`; calls.odin `node_source`.

### 10. Procedure parameters (the violet params dot)

- **Trigger**: A on the `params` dot of a procedure header.
- **Behavior**: Opens the `Fill slot` menu with a single entry, `Add parameter`. Picking it replaces the dot with `brave_otter: ●, ●`: an editable name, `: `, a blue type dot, `, `, and a new trailing params dot. The cursor goes to the new name, ready for dictation. A tidy save writes `name :: proc(brave_otter: int, calm_otter: f32) {`: it trims the paren padding and drops the `, ` before the trailing params dot.
- **Rules & edge cases**:
  - No menu option removes a parameter. A probe showed that **LT+B on a parameter name deletes the entire procedure**: none of the finer deletes in `delete_selected` matches a parameter, the header line has braces, so `block_delete_range` takes the whole construct. The same fall-through applies to LT+B on the params dot itself (code-read). Treat this as a gap, not a spec.
  - The `t: ^testing.T` parameter added by `@(test)` (feature 29) goes before the params dot in the same shape. Its type is fixed text, not a type field.
  - The loader makes parameter names of loaded headers editable (`emit_proc_params`), but a loaded header has no params dot, and the loaded parameter *types* stay fixed text (not `type` fields), so Y/LT+A can't change them. A loaded `proc()` with no parameters gets no parameter fields at all.
- **Source**: model.odin `open_slot_menu` (`"params"`), `make_slot_param`; format.odin `proc_header_parens`; calls.odin `node_source`.

### 11. Procedure results: the growing result list (blue "more" dot)

- **Trigger**: A on the result dot of a header (`-> ●`).
- **Behavior**: The menu is the generic type menu: `Type`, `Variable`. After a result type is filled, `result_list_sync`, which runs after every update, keeps the list in one of three shapes:
  - No result: one blue `type` dot.
  - One result: `int●`. The extra dot (kind `res_more`, blue) sits right after the type with **no** `, `.
  - Two or more: `(int, int●)`. Parentheses appear at two results and go away at one.

  Filling the extra dot inserts the `, ` in front of the new type (`more_dot_filled`). LT+B on a result removes it together with one adjacent `, ` (the one before it, else the one after it). LT+B on the last result brings back the empty result dot, and the save drops `-> `. LT+B on the extra dot, on the empty result dot, or on a parenthesis or separator does nothing (it is consumed so the whole procedure isn't deleted).
- **Rules & edge cases**:
  - The extra dot is optional and is never saved (`is_optional_dot`): `-> (int, int●)` saves as `-> (int, int)`.
  - The sync does nothing while a menu, a Reference pick or a Y-refill holds a dot open.
  - Choosing `Variable` gives `-> brave_otter: ●`, a named result, which the sync then leaves alone (`results_span` refuses a list whose fixed text holds `:`). It saves as `-> brave_otter: int {`, which Odin rejects (`Syntax Error: Expected ';', got :`; a named result needs parentheses). See Open questions.
  - Loaded headers `-> int {` and `-> (A, B) {` are structured the same way (`structure_results`). These stay as text: named results `(q, r: int)`, `-> !`, `where` clauses, bodiless declarations, and a proc-typed parameter's `->`. Unlike the other loader passes, `structure_results` rebuilds the text instead of slicing it: it writes exactly one space after `->`, `, ` between results and one space before `{`. So `->int{` or `-> (A,B) {` come back as `-> int {` / `-> (A, B) {` (no round-trip check).
- **Rationale**: The extra dot has no `, ` before it "so the line's text stays valid Odin (`-> int`, `return x`) for everything that reads it (call_signature, the type checker, saving)" (result_list.odin header).
- **Source**: result_list.odin (`results_span`, `shape_results`, `more_dot_filled`, `result_list_delete`, `structure_results`); result_list_test.odin.

### 12. Return values (orange "more" dot), seen from the procedure

- **Trigger**: A `return` statement inside the procedure (built in the statement menu, doc 05).
- **Behavior**: A return with a value gets an orange `ret_more` dot after its last value. Its empty value dots expect the procedure's result types by position. In `divmod :: proc(a, b: int) -> (int, int)`, the first `return ●` dot expects `int`; after `0` is filled, the orange dot expects the second `int`; past the last result the hint is empty. LT+B removes a one-field value with its `, `. LT+B on a return with no value deletes the statement. A bare `return` loads as `return ●` where the dot is the orange `ret_more` dot (`parse_return_statement`).
- **Source**: result_list.odin `shape_return`, `enclosing_results`; parse.odin `parse_return_statement`.

### 13. Types > Struct / Enum / Union (data bodies)

- **Trigger**: Add > `Types` > `Struct` | `Enum` | `Union`. The Types group order is pinned by a test: `Struct`, `Polymorphic struct`, `Enum`, `Union`, `Bit set`, `Bit field`, `Distinct type`, `Type alias`.
- **Behavior**: Each inserts three lines with a PascalCase editable name:
  ```odin
  BraveOtter :: struct {     // or ` :: enum {` / ` :: union {`
      ●                      // body dot (green): opens the MEMBER menu (feature 15)
  }
  ```
  An empty body saves as `{` / blank line / `}`. After a reload, the blank line is dropped by format, and a green dot still sits inside.
- **Rules & edge cases**:
  - Enums are inserted without a backing type. A loaded `enum u8 {` keeps `u8` as a type field.
  - LT+B on the type's name deletes the whole declaration, including its attribute lines (feature 32).
- **Source**: model.odin `append_type_node`; data_types.odin.

### 14. Types > Polymorphic struct, Bit set, Bit field, Distinct type, Type alias

- **Trigger**: The remaining Types leaves.
- **Behavior** (defaults, with dots shown as ●):
  ```odin
  BraveOtter :: struct($T: typeid●) {   // T editable (kind "poly"); ● = violet params dot
      ●
  }
  BraveOtter :: bit_set[●]              // blue type dot
  BraveOtter :: bit_field ● {           // blue backing-type dot
      ●
  }
  BraveOtter :: distinct ●              // blue type dot
  BraveOtter :: ●                       // type alias: blue type dot
  ```
  - **Poly params dot** → `Type param` | `Value param`:
    - `Type param` adds `, $U: typeid` before the dot, using the first unused name of `T U V W K E P Q`.
    - `Value param` adds `, $N: ●`, using the first unused name of `N M L SIZE COUNT`, plus a type dot.
    - The cursor goes to the new name.
    - Inside the struct, every Type menu also lists the struct's own `$` names (`poly_params_in_scope`). Outside it, they are not listed.
  - **bit_set dot** → the file's enums first (siblings included), then `0..<N range` (inserts `0..<●` with an int value dot), then `Type` (the full type menu).
  - **bit_field backing dot** → `Type` only. In that Type menu, `Composite` is grayed, as is every basic type that is not an integer: `f32`, `f64`, `bool`, `string`, `cstring`, `rune` and `rawptr` are grayed, `byte` is allowed (`dim_non_integers` via `resolve_type`). Import groups are skipped, and the file's own types resolve to "unknown", which is never grayed (typecheck.odin `resolve_uncached`). The graying exists only on the *unfilled* backing dot: Y/LT+A on a filled backing type opens `Edit Type` (`open_type_menu_for_edit`), which does not call `dim_non_integers`, so `f32` is offered there ungrayed. As everywhere outside options menus, the gray is advisory (picking `f32` still works).
  - **Distinct / alias dots** → the generic `Type` / `Variable` menu.
- **Rules & edge cases**:
  - LT+B on a poly parameter's name removes just that parameter: `$K, $V: typeid` without V becomes `$K: typeid`. Removing the last one gives `Stack :: struct {`, the params dot goes away, and parameters can't be added back.
  - A poly **union** (`union($T: typeid)`) loads and gets a params dot, but the Add menu has no leaf for it.
  - Unfilled holes in these single-line forms save as invalid Odin (`bit_set[]`, `distinct`, `BraveOtter ::`) and do **not** come back as dots on reload. See invariant 6.
- **Source**: data_types.odin `append_data_header`, `types_slot_menu`, `apply_types_fill`, `next_poly_name`, `dim_non_integers`, `delete_type_part`; types_menu.odin `build_type_entries`.

### 15. Member dots inside data bodies

- **Trigger**: A on the body `●` line of a struct/enum/union/bit_field, or on any green dot between members or before the closing `}`.
- **Behavior**: Opens `Fill slot` with members instead of statements, plus a `Layout` group (`Comment`, `Multi-line comment`, `Blank line`):

  | Body | Entries | Inserts (on the dot's line) |
  |---|---|---|
  | struct | `Field`, `Using field`, `Layout` | `brave_otter: ●,` / `using brave_otter: ●,` |
  | enum | `Member`, `Member = value`, `Layout` | `BraveOtter,` / `BraveOtter = ●,` (int value dot) |
  | union | `Variant`, `Layout` | `●,` (blue type dot) |
  | bit_field | `Field`, `Layout` | `brave_otter: ● \| ●,` (type dot + int bit-width dot) |

  The member replaces the dot line, and no new `●` line is added (the green dots between members do that job). The cursor lands on the new member's name, or on the variant's type dot.
- **Rules & edge cases**:
  - If the member line above lacks its comma (a hand-written `hp: int`), it gets one (`ensure_prev_member_comma`).
  - Member names have kind `member`. They are not references (Reference pick skips them), and renaming one never offers "rename all uses".
  - Which body a dot is in is decided per brace by the keyword before it (`data_kind_of_line`). So `f :: proc(s: struct { a: int }) {` opens a code body, and an identifier like `some_enum` is not the `enum` keyword (`test_anonymous_struct_param_body_is_code`).
  - B on the member menu inserts nothing.
  - LT+B on a member line in a multi-line body deletes that line.
- **Source**: data_types.odin `member_entries`, `types_slot_menu` (`"body"`), `apply_types_fill`; data_member_edit.odin `ensure_prev_member_comma`; stmt_layout.odin `layout_group`; body_dots.odin.

### 16. Composite type builder ([N]T, []T, [dynamic]T, map[K]V, ^T, [^]T)

- **Trigger**: In any Type menu (fill or edit), `Type` > `Composite`.
- **Behavior**: Entries, in order: `[N]T array`, `[]T slice`, `[dynamic]T`, `map[K]V`, `^T pointer`, `[^]T multi-ptr`. Each replaces the type dot with fixed parts plus new dots:
  - `[●]●`: an int value dot, then a type dot
  - `[]●`, `[dynamic]●`, `^●`, `[^]●`
  - `map[●]●`: a key type dot, then a value type dot

  Nesting works by filling an inner dot with another composite. Example: `[8]` + `[8]` + `int` gives `Grid :: [8][8]int`; `map[string]^int` as a parameter type. The full Type menu contents are in doc 06: `<ref>.` import groups, `Composite`, `$T` params in scope, the file's and siblings' types, then `int i8 i16 i32 i64 u8 u16 u32 u64 uint uintptr f32 f64 bool string cstring rune byte rawptr`. A Type submenu keeps its authored order and is never sorted or bucketed.
- **Rules & edge cases**:
  - Applying a composite to an already-filled type (Y or LT+A → `Edit Type` → `Type` → `Composite`) **replaces** it: `int` becomes `[●]●`. There is no "wrap".
  - The loader splits composite type text back into the same parts (`emit_type`, `split_type_fields`). `matrix[2, 2]f32` stays one fixed field.
- **Source**: data_types.odin `composite_type_group`, `apply_types_fill`, `emit_type`; types_menu.odin `build_type_entries`.

### 17. Changing a filled type; "Drop [8]" unwrapping

- **Trigger**: Y or LT+A on a filled type field (an editable field of kind `type`).
- **Behavior**: Opens the `Edit Type` menu. It has a `Type` entry, plus `Drop <wrapper>` when the type sits directly inside a composite. The label is the wrapper's text: `Drop [8]`, `Drop ^`, `Drop map[string]`, `Drop []`, `Drop [dynamic]`, `Drop [^]`. Drop removes only the immediate wrapper's fields. For example, `Grid :: [8]^map[string]int` with the cursor on `int`: Drop `map[string]` → `[8]^int`, then Drop `^`, then Drop `[8]` → `Grid :: int`.
- **Rules & edge cases**:
  - A map's key type has no Drop entry; only the type directly after the closing `]` does. A plain type shows just `Type`.
  - Picking a type replaces the field. On a typed declaration, the value dot's hint follows the new type (`sync_typed_decl_value_hint`).
  - B restores nothing because nothing was removed: `replacing` is cleared.
- **Source**: model.odin `edit_selected`, `open_type_menu_for_edit`; data_types.odin `wrapper_span`, `unwrap_entry`, `TY_UNWRAP`.

### 18. Editing members: shared name lists and one-line bodies (LT+B)

- **Trigger**: LT+B on a member name.
- **Behavior**:
  - In a multi-line struct or bit_field body, a line like `\tx, y, z: f32,`: LT+B on `y` gives `\tx, z: f32,`. Only that name and one separator go, and the type stays for the rest. On a single-name line, or with the cursor on the type, the whole line goes.
  - In a one-line body `Dir :: enum { North, South, East }`: LT+B on `South` gives `{ North, East }`. In a shared list `struct { x, y: f32 }`, the last name takes only itself and the separator before it. An emptied body becomes `{}` (`One :: union {}`). The line is re-read through the type parser so its structure stays right (`reread_decl`).
- **Source**: data_types.odin `delete_type_part`; data_member_edit.odin `delete_shared_member_name`, `is_bare_name`, `span_has_type`.

### 19. Loading type declarations (structure_type_decls)

- **Trigger**: Any file load (`doc_from_source`).
- **Behavior**: Lines that the line parser left plain (`name` + ` :: rest`, or one fixed field), together with member lines inside data bodies, are re-emitted with exactly the fields the menus build. This covers:
  - `@(private) Player :: struct {` (the attribute is kept as a fixed prefix)
  - struct tags `` `json:"name"` `` and `#subtype` (kept as text)
  - enum backing types and `= value`, where the value is editable when it's a plain number or name, else fixed (`1 << 2`)
  - `bit_set[Dir; u8]`, `bit_set[0..<8]`
  - `distinct win.HANDLE`
  - poly params with a trailing params dot
  - aliases: composite right-hand sides (`[`, `^`, `map[`, `#soa`, `#simd`, `matrix[` prefixes), a built-in type name (`Alias :: int`, `:: rawptr`, …), `pkg.Name` where `Name` is a type in the generated CORE_TYPES table, and bare names of types declared in this file or in siblings (`Alias :: Player`, resolved to a fixpoint, so chains and forward references work)

  The result is only used when its fields concatenate back to exactly the original line. Only "plain" lines are re-read (`is_plain_line`: one fixed field, or `name` + ` :: rest`, optionally after a when-indent field). Lines that already have structure only get filled composite `type` fields split into parts (`split_type_fields`, e.g. the `[8]int` in `x: [8]int = …`). After this pass, `split_modifiers` turns `#packed` / `#raw_union` / `#align(` in struct headers into keyword fields. The `#align` argument becomes an editable field when it is all digits (`#align(16)`), otherwise fixed text (`#align(align_of(int))`); it never becomes a dot again.
- **Rules & edge cases**:
  - Constants are not types (`NOT_A_TYPE :: 0x00FF0062` → value structured as a filled constant).
  - A local `Local :: enum { A, B }` inside a proc is structured too.
  - `format_doc` indents members by one tab.
- **Source**: data_types.odin `structure_type_decls`, `emit_type_decl_line`, `emit_member_line`, `is_plain_line`; data_member_edit.odin `doc_declared_type_names`.

### 20. Values group: Constant, Typed constant, Build-config constant, Globals

- **Trigger**: Add > `Values` > one of `Constant`, `Typed constant`, `Build-config constant`, `Global variable (typed)`, `Global variable (init)`.
- **Behavior** (with field layouts):

  | Leaf | Inserted | Fields |
  |---|---|---|
  | Constant | `BRAVE_OTTER :: ●` | name, ` :: `, orange value dot |
  | Typed constant | `BRAVE_OTTER : ● : ●` | name, ` : `, blue type dot, ` : `, orange value dot |
  | Build-config constant | `BRAVE_OTTER :: #config(BRAVE_OTTER, ●)` | name, fixed ` :: #config(BRAVE_OTTER, `, value dot (the default), `)` |
  | Global variable (typed) | `brave_otter: ● = ●` | name, `: ` (kind `decl`), type dot, ` = `, value dot |
  | Global variable (init) | `brave_otter := ●` | name, ` := ` (kind `decl`), value dot |

  The value-dot menu (Number, String, true, false, nil, Reference, Call, Struct literal, Constant, Built-in constants, Enum value, Operator, Convert, Type) and its type-fit graying are described in doc 06. It has more than 12 entries, so it is displayed alphabetically (`make_view`).
- **Rules & edge cases**:
  - A typed global's value dot expects the declared type: `operation: u32 = ●` gets hint `u32` (`sync_typed_decl_value_hint`). LT+B on that empty value dot leaves `operation: u32` (`lit_delete_selected`).
  - The **Typed constant**'s value dot is *not* given the type's hint (its ` : ` is not a `decl` field). This is a gap.
  - The `#config` key is fixed text. Renaming the constant offers the rename prompt (doc 08), whose single hit is the key. Its label currently reads `Rename the other use%!(EXTRA 1)`, a formatting bug in rename.odin.
  - `Constant`'s ` :: ` (and the Typed constant's ` : `s and the `#config` text) are plain fixed fields, so the cursor never stops on them and there is no Y on them. Only variables get "Declare as" (feature 22).
  - The `#config` default and the Typed constant's value dot have no type hint, so the value menu grays nothing by type there.
  - Inside a file-scope `when`, the line is indented (`ctrl_test.odin`).
- **Source**: model.odin `append_value_node`; field_access.odin `sync_typed_decl_value_hint`; struct_lit.odin `lit_delete_selected`.

### 21. Editable declaration values (loaded code)

- **Trigger**: Loading a file that contains declarations.
- **Behavior**:
  - `g: int = 5`: the value is its own part. Y refills it with a value dot that expects `int`; B puts `5` back; picking `Number` gives `g: int = 0`.
  - A string value (`x := "abc def"`, `l: string = "label"`) has editable text. Y opens the text tools with `Replace value` first, and word-by-word editing is available (doc 08).
  - A top-level (unindented) constant whose right side is clearly a value is structured like a filled Constant dot. That covers literals, negative numbers, `true`/`false`/`nil`, a whole-value call, and operator expressions with spaces (`A | B`). Example: `CLEVER_OTTER :: ""` gives an editable empty string. `Alias :: Other`, type forms, `proc`, `cast`/`transmute`/`auto_cast`, and anything containing `//` stay as text (`is_const_value`). A number stays one fixed field (`N :: 42` → `[N][ :: ][42]`); LT+A on it opens the number keypad (doc 06/08), not a text editor.
  - A declaration ending in an operator with nothing after it (`NAME ::`, `x :=`, `x: T =`, `x +=`) loads with an unfilled value dot, unless the next non-blank line is indented deeper (`open_value_line`). The `NAME ::` form only counts on an unindented line, so an unfilled constant inside a file-scope `when` does not get its dot back. Lines containing `//` never qualify.
- **Source**: parse.odin `parse_line`, `is_const_value`, `emit_decl_rest`, `open_value_line`; decl_value_test.odin; load_decls_test.odin.

### 22. "Declare as" (Y on a declaration operator)

- **Trigger**: Y on a declaration's `:=`, `:` or `::` field of kind `decl`. Such fields come from menu-built globals and local declarations, and from loaded `x := v` / `x: T = v` / `x: T` lines. The operator is a D-pad stop.
- **Behavior**: Opens the menu titled `Declare as` with three entries. Each label has the current name substituted and exactly three spaces before the parenthesis:
  1. `brave_otter := value   (type inferred)`
  2. `brave_otter: type = value   (choose the type)`
  3. `brave_otter :: value   (constant)`
  - Typed: the operator becomes `: `, and a type dot plus ` = ` are inserted. The type dot's menu opens **immediately**. Example: `brave_otter:  = windows.L("Testing")` → `Type > windows. > LPCWSTR` → `brave_otter: windows.LPCWSTR = windows.L("Testing")`.
  - Inferred / constant: if the declaration was typed, the type and the `=` are removed and the value is kept. If it had no value (`x: T`), a value dot is appended. Then the operator becomes ` := ` / ` :: `.
- **Rules & edge cases**:
  - No entry is ever grayed. Choosing typed on a typed declaration is a no-op.
  - B changes nothing.
  - The operator keeps kind `decl` after `::`, so a converted constant can be turned back. A menu-built or loaded `NAME :: v` constant never had a `decl` field, so this menu isn't reachable from it.
- **Source**: change.odin `open_decl_form_menu`, `apply_decl_form`; model.odin `menu_select` (`decl_form_active`); decl_form_test.odin.

### 23. Compile-time > When block (file scope)

- **Trigger**: Add > `Compile-time` > `When block`.
- **Behavior**: Inserts two lines, `when ● {` and `}`, as `[when (kw)][ ][●value hint "bool"][ {]` and `[}]`. There is no body line, because file-scope dots appear inside the block. The cursor goes to the condition dot. The green dots inside the `when` open the **Add menu** (declarations, not statements). Whatever is inserted there is indented one level, including a nested `When block`. The tested path for building `when ODIN_OS == .Windows {`:
  1. A on the condition → `Operator` > `Compare` > `a == b`
  2. A on the left operand → `Built-in constants` > `ODIN_OS` (the right operand now expects `Odin_OS_Type`)
  3. A on the right operand → `Enum value` > `.Windows`
- **Rules & edge cases**:
  - Unfilled, it saves as `when  {` and reloads as plain text with no dot (invariant 6).
  - Inside a procedure, the statement menu offers `Compile-time` > `#assert` / `When`, and `Branching` > `When` (doc 05). A `when` inside a procedure holds statements, gets `●` body lines, and has no file-scope dots.
  - The loader (`ctrl_line_roles`, `parse_ctrl_line`) makes `when X {`, `} else when X {` and `} else {` into keyword fields with a structured condition (only when the condition round-trips). Indented `name :: …` declarations inside a file-scope `when` are parsed with their indentation as a separate field.
- **Source**: ctrl.odin `compile_time_entries`, `ctrl_add_select`, `insert_when_block`, `block_infos`, `decl_indent_at`, `insertion_indents`; ctrl_parse.odin.

### 24. When conditions must be constant; editing a when chain

- **Trigger**: A on a dot inside a `when`/`else when` condition (including operator operands built there, and a ternary's `when` condition); Y or LT+B on `when`, `else when`, `else` or the condition.
- **Behavior**:
  - **Constant-only menus.** In a condition, the value menu grays every call leaf (`__call_import__`, `__call_import_proc__`, `__call_this_pkg__`), and grays any group left with nothing usable. `Reference` > `Pass as` grays names that aren't constants (`n := 5`), and grays fields and elements of values. `N :: 5`, `ODIN_*` built-ins, `true`/`false` and `pkg.CONST` stay available. `Number` is grayed by type fit because the dot expects `bool` (doc 06). These grays are advisory like all fill-menu grays: neither `menu_select` nor `ref_pass_choose` refuses a grayed entry, so a call can still be put into a condition.
  - **Y on `when` or `else when`** → menu titled `When`: `Add else when`, `Add else` (grayed when the chain already has an `else`), `Change condition`. **Y on `else`** → `Add else when`, `Add else` (grayed). Results of each choice:
    - `Add else when` inserts `} else when ● {` before the `else` if there is one, else at the end of the chain. The cursor goes to its condition.
    - `Add else` inserts `} else {` at the end of the chain. The cursor goes to the dot inside it.
    - `Change condition` turns the condition back into a bool dot and opens its menu; B restores the original condition.
  - **Y on the whole condition** refills it the same way (`when_cond_change`). The condition is one *unit* of the line (`when_line_units`), but D-pad Left/Right steps through its leaves, so a compound condition like `ODIN_OS == .Windows` is selected as a whole only with the RT tree walk. A single-part condition (`ODIN_DEBUG`) is its own leaf, so plain Y on it works. Y on one operand of a compound condition refills just that operand (the usual argument refill, doc 06).
  - **LT+B** on `when` deletes the whole chain; on `else when` or `else`, just that branch (and the cursor goes back to the chain's `when` keyword); inside the condition, the whole condition goes back to a `bool` dot. Removing a branch deletes from its line up to the line before the next branch (or the chain's closing `}`), so its declarations go with it.
  - A new branch of a chain *inside a procedure* also gets a `●` statement line (`add_when_branch`, `chain_in_code`), and `Add else` puts the cursor on that line instead of on a green dot.
  - HUD hints (`ctrl_hint`): `Y: add else / else when, change condition    LT+B: delete` on `when`; the same with `remove branch` on `else when`; `Y: add else when    LT+B: remove branch` on `else`.
- **Rationale**: Odin rejects non-constant conditions ("Expected a constant boolean condition…", when_const.odin header).
- **Source**: when_const.odin `in_when_cond`, `when_extend_value_menu`, `when_pass_as_dims`; when_cond.odin; ctrl.odin `ctrl_open_menu` (`.When_Chain`), `add_when_branch`, `remove_when_branch`, `delete_when_chain`, `reset_condition`, `ctrl_delete`, `ctrl_hint`.

### 25. Compile-time > Static assertion (#assert)

- **Trigger**: Add > `Compile-time` > `Static assertion`.
- **Behavior**: Inserts `#assert(●, ●)` as `[#assert (kw)][(][●value hint "bool"][, ][●args hint "string"][)]`. The cursor goes to the condition. The message dot is optional (green, kind `args`). An unfilled message and its `, ` aren't saved, so a fresh line saves as `#assert()`. Tested build: `Operator > Compare > a == b`, `Call > Built-in > size_of`, `Type > Player`, `Number` → `#assert(size_of(Player) == 8)`, then the message `String > "..."  string` → `#assert(size_of(Player) == 8, "Player is 8 bytes")`.
- **Rules & edge cases**:
  - **Y on `#assert`** → menu titled `#assert`: `Change condition`, `Add message` (grayed when a message is already filled). `Add message` goes straight into the message dot's menu, adding the dot back first if needed.
  - **LT+B on `#assert`** deletes the line. LT+B inside the message removes the message and brings back the optional dot.
  - `ctrl_sync` keeps at most one optional dot, so filling the message never offers a third argument.
  - The loader structures `#assert(...)` and adds the optional message dot when the message is missing.
  - HUD: `Y: change condition / add message    LT+B: delete`.
  - Unfilled `#assert()` reloads as plain text.
- **Source**: ctrl.odin `insert_static_assert`, `ctrl_sync`, `assert_message`, `add_assert_message`, `remove_assert_message`, `reset_assert_condition`; ctrl_parse.odin.

### 26. Modifiers: the declaration pick mode

- **Trigger**: Add > `Modifiers` > `Attributes` | `Struct directives` | `Calling convention`.
- **Behavior**: The menu closes and a **pick** starts on the candidate declarations:
  - Attributes: any file-scope declaration.
  - Struct directives: structs only.
  - Calling convention: procedures and `#type proc` types.

  Candidates must be at file scope (`decl_depth == 0`, which includes declarations inside a file-scope `when`). The first highlighted candidate is the one nearest the cursor: positions are counted in half-lines (dot before line L = 2L−1, line L = 2L), a declaration covers its whole block, and ties go to the earlier one. A banner reads exactly `Pick a declaration for the attribute   -   D-pad Up/Down move   A choose   B cancel` (with `a struct for the directive` / `a procedure for the calling convention`). Up and Down step through candidates and stop at the ends; A opens the options menu; B ends the pick. Every other input is swallowed.
- **Rules & edge cases**:
  - With no candidates, nothing happens: no banner and no notice (probe-confirmed; `start_mod_pick` returns before setting `mod_pick_active`).
  - While picking, `mod_pick_update` runs before the keymap in `update`, so every button except the global IDE-menu combo is swallowed. The highlighted candidate is shown by putting the cursor on its first editable field (normally the name).
  - A declaration whose attribute is on the *same* line (`@(private) Player :: struct {`, which the loader keeps as one fixed `@(private) ` prefix) is never a candidate, because `classify_decl` returns `None` for any line starting with `@`.
  - B in the options menu returns to picking, on the same declaration (`ctrl_from_pick`). Choosing an option ends the pick.
  - A grayed option in any modifier or compile-time options menu is refused, and the menu stays open (`ctrl_menu_choose`).
- **Rationale**: "Modifiers attach to a declaration, so choosing one starts a pick (like Reference)" (modifiers.odin header).
- **Source**: modifiers.odin `modifier_entries`, `mod_candidates`, `start_mod_pick`, `mod_pick_update`, `mod_pick_banner`, `classify_decl`; ctrl.odin `ctrl_open_menu`, `ctrl_menu_choose`, `ctrl_menu_cancel`.

### 27. Attributes

- **Trigger**: The pick mode's A, a purple dot's A (feature 30), or Y on an existing attribute line.
- **Behavior**: Opens a menu titled `Attributes`. Options appear in this fixed order, and options that don't apply to the declaration's kind are **hidden**, not grayed:

  | Label | Inserted | Allowed on | Grayed when |
  |---|---|---|---|
  | `test` | `test` | Proc | not test-shaped (feature 29), or already present |
  | `private` | `private` | all kinds | `private` or `private="file"` present |
  | `private="file"` | `private="file"` | all kinds | same as above (they share the name) |
  | `export` | `export` | Proc, Var | present |
  | `init` | `init` | Proc | present; has params or results |
  | `fini` | `fini` | Proc | present; has params or results |
  | `require_results` | `require_results` | Proc | present; returns nothing |
  | `thread_local` | `thread_local` | Var (also local vars) | present |
  | `link_name="..."` | `link_name=●` (string dot) | Proc, Var | present |
  | `deprecated="..."` | `deprecated=●` (string dot) | Proc | present |
  | `cold` | `cold` | Proc | present |

  Declaration kinds come from `classify_decl`: Proc, Proc_Group, Proc_Type, Struct, Type (enum/union/bit_set/bit_field/distinct), Const (including `A :: [8]int` aliases), Var. So a Proc sees these 10 rows (`test`, `private`, `private="file"`, `export`, `init`, `fini`, `require_results`, `link_name="..."`, `deprecated="..."`, `cold`); a Var sees `private`, `private="file"`, `export`, `thread_local`, `link_name="..."`; every other kind (Const, Struct, Type, Proc_Group, Proc_Type) sees only `private` / `private="file"` (`test_attribute_pick_and_apply`: "constants: only private"). Applying an attribute:
  - It merges into an `@(...)` line directly above the declaration (`@(a)` → `@(a, b)`, appended at the end), or creates `@(id)` above it at the declaration's indentation. Only an `@(…)` line merges; a bare `@name` line above gets a new `@(id)` line inserted between it and the declaration. The cursor goes to the new keyword, or to the string dot for `="..."` attributes.
  - The fields of a `link_name` / `deprecated` attribute are `[link_name (kw)][=][●value hint "string"]`; filling the dot with `String > "..."  string` gives `link_name="get_one"`.
  - `init` / `fini` also set the calling convention to `"contextless"`, replacing any existing one: `@(init)\nmain :: proc "contextless" () {`. Odin requires this (`Error: @(init) procedures must be declared as "contextless"`, verified with `odin check`). Nothing stops the user from changing the convention again afterwards with Y.
  - LT+B on one attribute removes it with its separator (the `, ` after it, or the one before it for the last attribute), and removes the line along with its last attribute. LT+B on the `@(` or `)` parts, or anywhere on an `@name` line, removes the whole line.
  - Y on an attribute's keyword reopens `Attributes` for the declaration below the attribute lines (`attr_decl_line`; nothing happens if no declaration follows). Y on a `link_name`/`deprecated` *string text* opens the text tools instead (doc 08), because only `kw` fields reach `ctrl_change`.
  - HUD: `Y: add attribute    LT+B: remove it`.
  - The loader structures `@(a, b="x")` and `@name`. String-valued attributes get an editable text: `link_name`, `link_prefix`, `link_suffix`, `link_section`, `deprecated`, `objc_name`, `require_target_feature`, `enable_target_feature`.
- **Rules & edge cases**:
  - For a declaration inside a procedure (reachable only via Y on a loaded local attribute line), only `local_ok` attributes are offered (`thread_local`, so only for a local variable). For a local procedure or constant the option list is empty and `ctrl_open_menu` opens nothing.
  - The loader only structures an attribute line that is exactly `@(…)` or `@ident` to the end of the line (no trailing comment). A string attribute's value is editable only when it is a plain quoted string with no `"` or `\` inside; otherwise `name="…"` is one keyword field. `private="file"` is always one keyword field.
  - An attribute on the same line as its declaration (`@(private) Player :: struct {`) is kept as a fixed prefix (feature 19) and is not an attribute line for the menus. Code-read hazard: `is_attr_line` only checks that the trimmed text starts with `@`, so LT+B anywhere on such a line goes to `remove_attribute`, which can't find a separate `@(` field and removes the whole line, leaving the struct's body and `}` behind. No test covers this.
- **Rationale**: "Only the ones Odin accepts for that kind of declaration are listed" (modifiers.odin). "`@(init)` / `@(fini)` procedures must be 'contextless'."
- **Source**: modifiers.odin `ATTR_OPTS`, `attr_options`, `apply_attribute`, `remove_attribute`, `attr_names_above`, `proc_shape`; ctrl_parse.odin `attr_fields`, `STRING_ATTRS`.

### 28. Struct directives and calling conventions

- **Trigger**: Pick mode (or Y on an existing directive or convention keyword).
- **Behavior**:
  - **Struct directives** (menu `Struct directives`): `#packed`, `#raw_union`, `#align(N)`.
    - Graying: `#packed` is grayed if present or if `#align` is present. `#align(N)` is grayed if present or if `#packed` is present. `#raw_union` is grayed if present. `#raw_union` combines with either: `struct #raw_union #packed` and `struct #raw_union #align(8)` both pass `odin check` (verified), while `#packed #align(8)` fails with `Error: '#align' cannot be applied with '#packed'`.
    - Each one is inserted right after `struct`, after any `(…)` poly params, so the newest comes first: `Player :: struct #raw_union #packed {`. It is a `" "` field plus a keyword field (kind `kw`), spliced into the fixed header text (`insert_at_offset`).
    - `#packed` / `#raw_union` leave the cursor on the new keyword. `#align(N)` inserts `#align(●)` with an int dot (`value`, hint `int`), and the cursor goes to that dot.
    - LT+B anywhere in a directive, including its number, removes the whole directive and the space before it; the cursor goes to the struct's name.
    - HUD hint on a directive: `Y: add directive    LT+B: remove it`. Y on any directive keyword reopens `Struct directives` for that struct.
  - **Calling convention** (menu `Calling convention`): `"odin"`, `"contextless"`, `"c"`, `"system"`, `"stdcall"`, `"fastcall"`, `"cdecl"`, `"naked"`, `"none"` (the labels include the quotes).
    - Graying: the current convention is grayed, and `"none"` is grayed when the line classifies as `Proc` (a body `{` or a `---` bodiless declaration). A `Proc_Type` (`#type proc`, or `:: proc(…)` with no body) may take `"none"`. Odin's own error for the case it prevents: `Procedures with the calling convention "none" are not allowed a body` (verified).
    - Inserted as a keyword field after `proc`: `get :: proc "system" () -> int {`. A menu-built header's ` :: proc( ` splits into ` :: proc `, `"c"`, ` ( `. The cursor goes to the new convention.
    - Y on the convention changes it (replaces the keyword text). LT+B removes it and re-merges the text (`proc "c" (` → `proc(`), cursor to the procedure's name. HUD hint: `Y: change convention    LT+B: remove it`.
    - Only the declaration's own convention is a keyword; a `proc "c" (x: i32)` used as a parameter type stays text.
- **Rationale**: "#align can't be combined with #packed (odin check: \"'#align' cannot be applied with '#packed'\")"; "\"none\" procedures can't have a body" (modifiers.odin).
- **Source**: modifiers.odin `directive_options`, `apply_directive`, `directive_pos`, `remove_directive`, `CONVENTIONS`, `callconv_options`, `set_callconv`, `remove_callconv`, `own_callconv_index`; ctrl_parse.odin `split_modifiers`.

### 29. @(test) and the auto-import of core:testing

- **Trigger**: `test` in an Attributes menu on a procedure.
- **Behavior**:
  1. Adds `@(test)`.
  2. If no `core:testing` import exists, inserts `import "core:testing"` after the last file-scope import, else directly after the `package` line, else at line 0. If it is imported under an alias (`import tst "core:testing"`), the alias is used.
  3. If the procedure has **no** parameters, adds an editable `t` plus the fixed text `: ^testing.T` (or `^tst.T`). In a menu-built header it goes before the params dot (`t: ^testing.T, ●`, saved `proc(t: ^testing.T)`); in a loaded header, right after the `(`.

  Saved result for a loaded proc:
  ```odin
  import "core:fmt"
  import "core:testing"

  @(test)
  adds_up :: proc(t: ^testing.T) {
  ```
- **Rules & edge cases**: `test` is grayed when any of these holds:
  - the header can't be read
  - the procedure returns anything
  - its calling convention is set and isn't `"odin"` (so after `@(init)`, `test` is grayed)
  - it takes parameters other than exactly one `name: ^<testing-ref>.T`, where the reference must match how `core:testing` is imported (`x: ^strings.T` doesn't count)
  - it already has `test`

  The auto-inserted import line is one plain fixed field (not `import_node`), so it isn't a D-pad stop until the file is reloaded (gap).
- **Rationale**: "`odin test .` runs every @(test) procedure of the package"; Odin wants exactly `proc(t: ^testing.T)` (attr_dots.odin). Running tests is in doc 09.
- **Source**: attr_dots.odin `test_attr_dim`, `is_testing_t_param`, `testing_ref`, `setup_test_proc`, `import_insert_line`; modifiers.odin `apply_attribute`.

### 30. Purple attribute dots

- **Trigger**: The cursor reaches a purple dot. There is one above every file-scope **procedure** (`classify_decl == .Proc`), above its attribute lines if it has any. Procedures inside a file-scope `when` get one too. Proc groups, proc types, structs and local procedures don't.
- **Behavior**: The purple dot is a cursor stop between the green dot and the line. Moving down: green dot → purple dot → the line (`stop_key = line*3 + {0 green, 1 purple, 2 line}`). A opens that procedure's `Attributes` menu directly, with no pick. B closes it and leaves the cursor on the purple dot. HUD hint: `A: attributes  (test, private, ...)` (two spaces before the parenthesis). It is drawn in purple (0.55, 0.22, 0.88) at x = the line's indentation width + 14 px (`ATTR_DOT_DX`, "clear of the green dot"), vertically in the middle of the blank line above when there is one, else on the boundary between the rows; it pulses when selected.
- **Rules & edge cases**:
  - LT+B on a purple dot does nothing (an earlier bug deleted the blank line above it).
  - If its procedure goes away, the cursor snaps to another stop (`normalize_cursor`).
- **Source**: attr_dots.odin `attr_points`, `on_attr_dot`, `focus_attr_dot`, `open_attr_dot_menu`; model.odin `editor_stops`, `stop_key`; src/app/editor_view.odin (`COL_ATTR_DOT`, `ATTR_DOT_DX`).

### 31. Saving file-scope constructs

- **Trigger**: Save (doc 09), or `Format file`.
- **Behavior**: `file_text` runs `format_doc` first:
  - indentation by brace depth, with tabs
  - one blank line after `package`
  - imports and `foreign import`s grouped, with one blank line after them
  - one blank line between different kinds of top-level construct, and around every multi-line construct
  - comments and `@` lines kept attached to what follows

  Then each node is written through `node_source`: unfilled optional dots (`args`, `fields`, `res_more`, `ret_more`) and the `, ` before them are dropped, menu-built proc headers are tidied, and `fixup_line` normalizes `( )` → `()`, drops an empty `-> `, and trims trailing spaces. A `●` statement line is dropped next to real statements and kept as a blank line when it is a block's only content.
- **Source**: serialize.odin `file_text`, `save_source`, `fixup_line`; formatter.odin `format_doc`; calls.odin `node_source`.

### 32. Deleting a declaration with its attributes, or inside a file-scope when

- **Trigger**: LT+B on a declaration's name or its `::`/`:=`/`:` operator.
- **Behavior**: For a file-scope declaration that has attribute lines above it, the declaration (through its closing brace) is deleted together with those lines. For a declaration inside a file-scope `when`, only that declaration goes, not the whole `when`. This runs after the finer deletes (enum member, literal field, `$T` param) have had their chance.
- **Source**: ctrl.odin `ctrl_delete_declaration`, `delete_declaration`; model.odin `delete_selected` (dispatch order).

## Invariants & constraints to carry forward

1. **HARD**: A node's fields concatenate to exactly its source line (`node_text`). `structure_type_decls` and `parse_ctrl_line` only replace a line's fields when the new fields re-concatenate to the original text (explicit checks: `fields_text(out) == txt`, `expr_fields`); `split_modifiers` and `split_type_fields` only cut existing text into pieces. Two documented exceptions: call statements come back "in Doodle's format" (parse.odin header, doc 05), and `structure_results` rebuilds `-> T {` with normalized spacing (feature 11). Pinned by the round-trip tests `test_load_type_decls_round_trip`, `test_load_modifiers_and_compile_time`, `test_result_list_loader`, `test_decl_value_loads_and_saves_unchanged`.
2. **HARD for type declarations, SOFT elsewhere**: Menu-built and loaded constructs have identical field structure. `test_build_every_type_from_menus` builds every Types leaf from the menus, saves, reloads and compares each field's (text, editable, slot, kind) (`same_structure`). It does not hold for procedure headers (a loaded header has no params dot and its parameter types are fixed text, feature 10) or for unfilled holes (invariant 6).
3. **HARD**: The Add menu lists exactly these labels, in this order: groups `File Setup, Dependencies, Procedures, Types, Values, Compile-time, Modifiers`; Types `Struct, Polymorphic struct, Enum, Union, Bit set, Bit field, Distinct type, Type alias` (pinned by `test_types_menu_entries`); collections `core, base, vendor, shared` (pinned by `test_import_menu_lists_collections`). The seven top-level groups and the other groups' orders are fixed in `ensure_menus` (no test pins the top level as a list). Heat (doc 03/10) shades cells but never reorders them.
4. **HARD (by construction of each leaf, not one central check)**: Every declaring leaf inserts generated names and typed holes, never an empty shell (File tags and Blank line are fixed text by design). The user is immediately on a stop next to it: the green dot after it for most leaves, the condition dot for `When block` / `Static assertion`, or a pick for Modifiers.
5. **HARD**: Optional dots (`args`, `fields`, `res_more`, `ret_more`) are never saved. Required unfilled dots save as nothing at their position.
6. **SOFT (only partly true; carry the intent, fix the gap)**: An unfilled hole should survive save/load. Today these round-trip: `NAME ::` / `x :=` / `x: T =` (value dot), an empty block body (green dot inside), the `#assert` message dot, the result list. These do **not** come back as dots (probe-confirmed): Typed constant `X :  :`, `#config(X, )`, the typed global's type dot `x:  =`, `bit_set[]`, `bit_field  {`, `distinct`, an alias `X ::` (reloads as a **constant** value dot), `when  {`, `#assert()`, `#align()`. Several of these are invalid Odin.
7. **HARD**: File-scope `when` braces are see-through for declaration dots. Procedure, data and solid braces are not (`block_infos`). Declarations inserted inside a `when` are indented to its depth.
8. **HARD**: Modifiers apply only to file-scope declarations, including those inside a file-scope `when` (`mod_candidates`, `apply_attribute` checks `decl_depth`). The one exception is Y on a loaded attribute line of a local variable, which offers `thread_local` (`local_ok`). Options that don't fit the declaration's kind are **hidden**; options that fit the kind but not the declaration's current state are **grayed**, and choosing a grayed option is refused, leaving the menu open (`ctrl_menu_choose`: `if e.dim do return`).
9. **HARD at the moment the option is chosen; not maintained afterwards**: `#packed` and `#align` gray each other. `"none"` is grayed for a procedure with a body. Choosing `init`/`fini` sets `"contextless"`. `test` is grayed unless the procedure returns nothing, has no convention other than `"odin"`, and takes either no parameters or exactly one `name: ^<testing ref>.T` (`test_attr_dim`). Nothing re-checks later edits: Y can change the convention of an `@(init)` procedure, and `Add parameter` still works on an `@(test)` procedure. Loaded code is never checked. All four rules mirror real `odin check` errors (verified for the first three).
10. **SOFT (advisory gray)**: A `when` condition steers toward compile-time constants: calls are grayed, and non-constant references are grayed in Pass as. Neither is refused (see invariant 13), so a call can still be put into a condition.
11. **HARD**: The result list's extra dot sits directly after the last type with no separator. Parentheses exist exactly when there are 2 or more results (`result_list_sync` after every update; `test_result_list_from_menus`).
12. **HARD**: Member names (kind `member`) and `$T` names (kind `poly`) are names, not references (`test_load_type_decls_round_trip` checks `hp`, `North`, `K` aren't `ref_candidates`; `rename_uses` ignores `member`). Names from the counter generator never collide with any editable field in the file or with a sibling's type or procedure (`is_name_used`). Not covered by that rule: `main` for the first procedure, poly names (checked only against their own line) and the `t` of `@(test)`.
13. **SOFT**: Grayed groups and leaves outside options menus (e.g. `Dependencies` inside a `when`, type-fit grays, when-condition grays) are advisory; picking still works. Only the options menus of ctrl.odin, branch.odin and loops.odin refuse a grayed entry. The heat recorder treats type-fit-grayed leaves as real uses (`heat_is_action`).
14. **HARD**: Inside a `/* */` comment there are no green dots, and its braces never count for nesting or indentation (`inside_block_comment`, `block_infos`, `brace_delta`, `format_doc`; pinned by `test_block_comment_loader`).
15. **SOFT**: Each Y that refills a part keeps the original until a fill is chosen, and B restores it (`begin_refill` / `refill_range_with_dot` + `refill_restore` in `menu_cancel`: Y on a value, `Change condition`, Y on the condition). Pinned only for values (`test_decl_value_typed_refill`). LT+A on a filled type removes nothing until a pick, so B there has nothing to restore.

## Data model & formats

- **Entry** (a menu node; model.odin). Exactly one behavior applies:
  - `children` → submenu
  - `keyword` + `ident_default` → `keyword <editable ident>`
  - `proc_outline` → procedure
  - `type_construct` ∈ {struct, poly_struct, enum, union, bit_set, bit_field, distinct, alias}
  - `value_construct` ∈ {const, typed_const, config, global_typed, global_init}
  - `special` ∈ {when_block, static_assert, mod_attr, mod_directive, mod_callconv}
  - `import_path` → import
  - `insert` → literal text, or the markers `"// comment"`, `"\x00blank line"`, `"\x00multi-line comment"`, or a foreign line
  - `fill` → a slot-fill marker (`__param__`, `__var__`, `__ty_*__`, `__ctrl_menu__`, `__decl_form__`, …)

  Other fields: `label`, `dim`, `platform` (comma list of OS names), `alias` (entering it sets import-alias mode), `pinned`, `heat_key`, `call_name` (option id / form), `call_pkg`, `owned_label`.
- **Field kinds used by this area**, with dot colors from src/app/main.odin `slot_dot_color`:

  | kind | slot? | color | meaning |
  |---|---|---|---|
  | `""` editable | no | — | a name (declaration, param, alias, package) |
  | `type` | dot / filled | blue | a type hole / a filled type (editable, Y/LT+A edits) |
  | `value` | dot | orange | a value hole (`hint` = expected type, e.g. `bool`, `int`, `string`) |
  | `params` | dot | violet (0.80, 0.45, 0.95) | add parameter / add `$T` param |
  | `body` | dot | green (small) | statement or member line |
  | `args` | dot | green (small) | optional (`#assert` message) |
  | `string` | editable | — | the text between the quotes of a string value (constant strings, `link_name="…"`): dictation and text tools |
  | `res_more` / `ret_more` | dot | blue / orange | another result / another return value (optional) |
  | `member` | editable | — | struct/bit_field field, enum member name |
  | `poly` | editable | — | `$T` parameter name |
  | `decl` | fixed, selectable | — | `:=` / `:` / `::` (Y → Declare as) |
  | `kw` | fixed, selectable | — | `when`, `else when`, `else`, `#assert`, attribute names, directives, `"c"` conventions |
  | `import_path` | fixed, selectable | — | `"core:fmt"` (LT+A/Y swaps) |
  | `comment`, `comment_mark` | editable / selectable | — | comment text; `/*` `*/` markers |

- **Doc**: a list of `Node`s (one source line each, except that a call written one argument per line loads as one node; doc 05), each a list of `Field {text, editable, slot, kind, hint, hint_pkg}`, plus `no_final_newline`. What the cursor can stop on in a line is any field that is editable, a slot, or of kind `decl`, `kw`, `import_path` or `comment_mark` (plus kinds from other areas; selection.odin `selectable`).
- **Decl_Kind** (`classify_decl` on trimmed line text):
  - `None`: lines starting with `/ @ # } { (`; `package/import/foreign/when/using` lines; `x = 5`; `case …`.
  - After a name list:
    - `::` followed by `#type` → `Proc_Type`
    - `:: proc{` → `Proc_Group`
    - `:: proc` with `{`, `---` or a trailing `(` → `Proc`; any other `:: proc` → `Proc_Type`
    - `:: struct` → `Struct`
    - `:: enum`, `union`, `bit_set`, `bit_field`, `distinct` → `Type`
    - any other `::` → `Const`
    - `:=` → `Var`
    - `: T : v` → `Const`; `: T` or `: T = v` → `Var`
  - `#force_inline ` / `#force_no_inline ` prefixes are skipped.
- **Data_Kind**: None, Struct, Enum, Union, Bit_Field. Decided per `{` by the earliest of those keywords as a whole word in the text since the previous brace.
- **Block_Info** per line: `depth`, `after`, `decl_depth` (excludes see-through when-braces), `chain` (the `when` header line of its chain, or −1).
- **Ctrl_Menu**: None, When_Chain, Assert, Attr, Directive, Callconv. App state for the pick: `mod_pick_active`, `mod_pick_kind`, `mod_pick_line`, `ctrl_ni/ctrl_fi`, `ctrl_from_pick`.
- **Generated tables** (tools/gen_core_tree.py → core_tree.odin): `CoreRow {depth, label, path ("" = group), platform, dim}` for each collection, and `IMPORT_NAMES {path, name}`. The types, procs, fields and enum-member tables used by the menus are doc 07's subject.
- **Built-in compile-time constants** (ctrl.odin `BUILTIN_CONSTS`): name, type, category, common. Common: ODIN_OS, ODIN_ARCH, ODIN_DEBUG, ODIN_OPTIMIZATION_MODE, ODIN_ENDIAN, ODIN_BUILD_MODE, ODIN_NO_CRT, ODIN_TEST, ODIN_VENDOR, ODIN_VERSION. The rest are under `More`. Compiler enum members (e.g. `Odin_OS_Type`: Unknown, Windows, Darwin, Linux, FreeBSD, OpenBSD, NetBSD, WASI, JS, Orca, Freestanding) are hard-coded.
- **Persisted**: nothing specific to this area besides the Odin source itself. `recent_imports` lives only for the session. Heat is in `doodle_heat.tsv` (doc 03/10).

## Tests that pin this behavior

- data_types_test.odin:
  - `test_types_menu_entries`: Types labels and order.
  - `test_build_every_type_from_menus`: menus build exactly the reference source (struct, poly struct, enum, union, bit_set, bit_field, distinct, aliases); reload gives identical fields and text.
  - `test_load_type_decls_round_trip`: exact field shapes for tags, shared names, `using`, nested composites, one-line bodies, `#align(8)` after poly params, `bit_set[Dir; u8]`, `matrix`; constants aren't types; members aren't references.
  - `test_member_dots_and_delete`: struct dots offer `Field`/`Using field` and not statements; no extra `●` line; B inserts nothing.
  - `test_enum_union_bit_field_members`: `Member = value` int hint; `Variant`; bit_field `Field`; backing type grays `f32`.
  - `test_poly_struct_params`, `test_composite_types_in_any_type_dot`, `test_one_line_member_delete`, `test_bit_set_range`, `test_unwrap_composite`, `test_anonymous_struct_param_body_is_code`.
- ctrl_test.odin:
  - `test_when_block_with_os_condition`: when built from menus; dots inside it open the Add menu; indented constant; round trip.
  - `test_when_else_branches`: `Add else`, `Add else when` ordering, `Add else` grayed, LT+B per branch and for the chain, `Change condition`.
  - `test_declarations_inside_file_scope_when`, `test_imports_dimmed_inside_when`, `test_static_assert_size_of`, `test_assert_and_when_in_a_procedure`, `test_enum_values`.
- modifiers_test.odin:
  - `test_classify_decl`.
  - `test_attribute_pick_and_apply`: nearest pick, banner, Up/Down, B returns to picking, merge into `@(require_results, link_name="get_one")`, LT+B order.
  - `test_attribute_kinds`: `thread_local`; `@(init)` makes `"contextless"`; deleting a declaration deletes its attributes.
  - `test_struct_directives`, `test_calling_convention`, `test_load_modifiers_and_compile_time`.
- attr_dots_test.odin:
  - `test_attr_points_above_procedures`, `test_attr_dot_is_a_cursor_stop`, `test_attr_dot_opens_attributes`.
  - `test_attr_test_on_loaded_proc`, `test_attr_test_on_menu_built_proc`, `test_attr_test_uses_import_alias`, `test_attr_test_dimmed_for_non_test_shapes`.
  - `test_attr_dots_not_on_other_declarations`, `test_attr_review_fixes`.
- decl_form_test.odin: `test_operator_is_highlightable`, `test_declare_with_a_type` (exact labels; straight into the Type menu), `test_back_to_inferred_and_constant` (B changes nothing), `test_menu_built_declaration_forms`.
- decl_value_test.odin: `test_decl_value_loads_and_saves_unchanged`, `test_decl_value_typed_refill`, `test_decl_value_string`.
- collections_test.odin: `test_import_menu_lists_collections`, `test_import_base_lists_importable_packages`, `test_import_vendor_sdl2_then_call_its_procs`, `test_vendor_platform_groups_filtered`, `test_import_lua_gets_a_name`, `test_shared_tree_empty_placeholder`, `test_shared_tree_lists_packages`, `test_odin_root_found`.
- data_types_test.odin also: `test_format_indents_members` (members indented one tab, still structured after formatting).
- review_fixes_test.odin: `test_review_attribute_on_type_line` (`@(private) Player :: struct {` loads as `[@(private) ][Player][ :: struct {]` and counts as a type), `test_review_delete_part_of_attributed_declaration` (LT+B on an enum member / `$V` of an attributed or when-nested declaration removes just that part).
- load_decls_test.odin: `test_load_import_and_string_constant` (LT+A on the path opens the Import menu with `replacing`), `test_load_aliased_import`, `test_load_constant_values`, `test_load_empty_constant`, `test_foreign_lines`.
- result_list_test.odin: `test_result_list_from_menus`, `test_return_values_from_menus`, `test_result_list_loader`, `test_result_list_loader_leaves_others`, `test_delete_bare_return`.
- block_comment_test.odin: `test_block_comment_from_file_setup` (Y adds a line, LT+B on a text line / on a marker), `test_block_comment_loader` (braces inside don't count, no green dots inside, saves unchanged), `test_block_comment_in_a_function` (the Layout variant, doc 05).
- model_test.odin: `test_params_slot_opens_param_menu`, `test_add_parameter_transforms_slot`.
- handmade_acceptance_test.odin `test_handmade_accept_file_scope`: aliased import renamed to `win32`, hex constants, typed global `operation: u32 = WHITENESS` with a `u32`-hinted value dot.

Test style to copy: drive `update(app, Input{…})` with synthetic button edges, `pick(label)` from `current_view`, then assert on `node_text`, `fields_debug` (`[text]` / `[●kind]`) and `file_text`. Also missing today and worth adding in Rust: removing a parameter; unfilled holes round-tripping; no duplicate imports; the alias mode resetting on B; `Edit import` refusing non-import leaves; deleting a no-stop line via the tree walk; LT+B on a same-line-attribute declaration; the 7-group top-level order.

## Carrying this to Rust

**(a) What transfers unchanged**
- A green dot between items, A → a 7-group Add menu with stable labels, a skeleton with generated names and typed holes, and the cursor left on the next useful stop.
- Fixed-order groups. Hiding what doesn't apply versus graying what could apply but doesn't right now. Grayed option-menu entries refuse and keep the menu open.
- Pick mode for modifiers: banner, nearest candidate, Up/Down, A, and B back to picking.
- A purple per-item attribute dot above functions.
- The Y/LT+A/LT+B vocabulary on keywords: Y opens "options for this keyword", LT+B removes exactly that modifier, branch or name.
- Growing lists with a trailing "add another" dot that never writes text: the violet params dot for parameters and generic params (a required slot that saves as nothing, its `, ` dropped by the tidy save), and the optional `res_more`/`ret_more` dots for results and return values. Data-body members grow through the green dots between member lines instead.
- Composite type builder with nesting and a "Drop wrapper" unwrap.
- Constant-only menus in compile-time positions.
- Loader and menus producing identical node structure, pinned by build-from-menus → save → reload → compare tests.

**(b) Odin pieces and their Rust analogs**

| Odin (this area) | Rust |
|---|---|
| `package main` / package = folder | crate + module tree; the Package leaf becomes "Module" (`mod foo;` creating `foo.rs`); sibling files are `mod`s |
| `#+build linux` file tag | `#![cfg(target_os = "linux")]` inner attribute, or `#[cfg]` on `mod` |
| Import / Aliased import, core/base/vendor/shared | `use std::fmt;` / `use std::collections::HashMap as Map;`; tree = std/core/alloc (from rustdoc JSON) + crates in `Cargo.toml` (+ "Add dependency" → `cargo add`) |
| `foreign import` + `foreign` block | `#[link(name = "c")] unsafe extern "C" { fn puts(s: *const c_char) -> c_int; }` (edition 2024 requires the `unsafe` before `extern`; items inside may be marked `safe fn` / `unsafe fn`), with dots inside the block to add fns (Doodle lacks these) |
| Procedure, params dot, result list | `fn name(●) -> ● { ● }`; 0 results = no `->`, 1 = `-> T`, 2+ = tuple `-> (T1, T2)` (the paren rule maps directly) |
| Calling conventions | ABI strings: `extern "C" fn`, `"system"`, `"stdcall"`, `"fastcall"`, `"cdecl"`, `"Rust"`, `"C-unwind"`, `"win64"`, `"sysv64"`, …; `stdcall`/`fastcall`/`cdecl`/`thiscall` are 32-bit-x86 conventions, and recent rustc warns about or rejects them on other targets (check the toolchain you target), so gray them by target the way Doodle hides imports by `platform`. Plus qualifiers `pub`, `const`, `async`, `unsafe` as a "Qualifiers" modifier group |
| struct / poly struct `$T`, `$N: int` | `struct S<T> { }`, const generics `<const N: usize>`; "Type param" / "Const param" / "Lifetime param" on the params dot. Unlike Odin, an *unused* type or lifetime parameter is a compile error in Rust (E0392 "parameter `T` is never used"), so the skeleton `struct S<T> { ● }` doesn't compile until a field uses `T`. Either insert a `_marker: PhantomData<T>` field with the param, or accept the error until the first field is filled. Unused const params are fine |
| enum (C-like), `Member = value` | `enum E { A, B = 5 }`. A unit-only enum may set explicit discriminants and be cast with `e as i32` without any `#[repr]`; `#[repr(u8)]` etc. fixes the size (the analog of Odin's `enum u8 {`) and is required only for explicit discriminants on enums that also have data-carrying variants |
| union (tagged) | `enum` with tuple variants: `Variant` → `Name(●)`; add `Struct variant` |
| bit_set | `bitflags!` / `enumset` crate (offer the file's enums first, like Doodle) |
| bit_field | manual shifts or a bitfield crate; probably drop or defer |
| distinct | newtype `struct Meters(f64);` (+ derives) |
| type alias | `type Grid = [[i32; 8]; 8];` |
| `[N]T`, `[]T`, `[dynamic]T`, `map[K]V`, `^T`, `[^]T` | `[T; N]`, `&[T]` / `Box<[T]>`, `Vec<T>`, `HashMap<K, V>`, `&T` / `&mut T` / `Box<T>` / `Rc<T>` / `Arc<T>`, `*const T` / `*mut T` |
| Constant / Typed constant | `const NAME: T = ●;` (the type is **mandatory**: Rust's Values menu has no untyped constant) |
| Global (typed / init) | `static NAME: T = ●;` (the type is mandatory, so "Global variable (init)" has no direct analog), `static mut` (gray unless `unsafe` is wanted; references to it are denied by default in edition 2024), `LazyLock`/`OnceLock` for non-const init |
| `#config(NAME, default)` | `cfg!(feature = "x")`, `option_env!("X")`, Cargo features |
| `when` at file scope | `#[cfg(...)]` on items, or `cfg_if!` |
| `#assert(cond, msg)` | `const _: () = assert!(cond, "msg");` (the message must be a plain string literal in const context, which matches Doodle's plain-string message dot) |
| Attributes `@(...)` | `#[...]`: `@(test)` → `#[test]`; `require_results` → `#[must_use]`; `deprecated="…"` → `#[deprecated(note = "…")]`; `cold` → `#[cold]`; `export` → `#[unsafe(no_mangle)]` and `link_name` on a fn with a body → `#[unsafe(export_name = "…")]` (edition 2024 requires the `unsafe(…)` wrapper); `#[link_name = "…"]` exists only for items inside an `extern` block (the import side); `thread_local` → the `thread_local!` macro; `private`/`private="file"` → visibility (`pub`, `pub(crate)`, private by default; Rust has no file-private level beyond "private to this module"); `init`/`fini` → no std analog (hide) |
| Struct directives | `#[repr(C)]`, `#[repr(packed)]` / `#[repr(packed(N))]`, `#[repr(align(N))]`, `#[repr(transparent)]`, `#[repr(u8)]` (Rust also rejects `packed` + `align` on one type, E0587: keep the mutual graying). `#raw_union` is not a repr in Rust: it maps to a separate `union U { a: u32, b: f32 }` item (field reads are `unsafe`), so offer it as a Types leaf |
| `@(test)` auto-imports `core:testing`, adds `t` | `#[test]` may annotate any free fn (it is only compiled for `cargo test`); by convention tests live in `#[cfg(test)] mod tests { use super::*; … }`, so offer to create/move into that module (the analog of the auto-import). Gray `test` when the fn takes parameters, is generic, is `async` or `unsafe`, or returns something other than `()` or a `Result<(), E>`-like `Termination` type |
| `using` field | no analog: hide (or offer `Deref` impl generation later) |

**(c) Rust concepts this area will need that Odin lacks**
- **impl blocks and traits** need new Add leaves: `Impl block` (`impl ● { ● }`, the dot offering the file's types), `Trait impl` (`impl ● for ● {}`, which should pre-fill the required items from the trait, the way Doodle fills a call's required argument dots), `Trait` (`trait Name { ● }` whose member menu offers `fn` signature / provided fn / associated type / const). Inside an impl, the member menu offers methods with `self` receivers (`&self`, `&mut self`, `self`), like Doodle's data-body member menus.
- **Derives**: a `Derive` modifier with a checklist (Debug, Clone, Copy, PartialEq, Eq, Hash, Default, PartialOrd, Ord), graying `Copy` unless `Clone` is present and every field is Copy (ask rust-analyzer), `Eq` without `PartialEq`, etc. This follows the same hide-versus-gray rule.
- **Visibility** (`pub`, `pub(crate)`, `pub(super)`) as a modifier on every item. This replaces `@(private)`.
- **Lifetimes / generics / where clauses**: the params dot grows a "Lifetime param" entry, and a `where ●` "more" dot after the signature.
- **Modules and `use` paths**: Dependencies becomes "Use / Module / Extern crate / Cargo dependency". Swapping a `use` path is the analog of LT+A on an import path. Keep the user's `as` alias, which Doodle loses.
- **Option/Result**: results menus should offer `Option<●>` and `Result<●, ●>` as composites. The `?` operator belongs to expression/statement editing (docs 05 and 06), and should only be offered inside a fn whose return type is `Option`/`Result` (the result list above is what tells you).
- **Macros**: `macro_rules!` items are out of scope for a menu skeleton, but known item macros (`thread_local!`, `lazy_static!`, `bitflags!`) can be leaves.
- **async/unsafe/const fn**: qualifiers via a "Qualifiers" modifier (pick mode, grayed combinations such as `const async`).

**(d) Implementation advice**
- Use a lossless concrete syntax tree, either `ra_ap_syntax` (rust-analyzer's rowan CST) or tree-sitter-rust, instead of Doodle's line-based parser. Keep Doodle's contract that the editor's parts concatenate back to the exact source text (invariant 1) by mapping "fields" onto CST tokens.
- Decide the **hole encoding** up front, because invariant 6 is Doodle's weakest point. Rust must parse to be analyzed, so encode holes reversibly: `todo!()` in expression positions; a recognizable placeholder in type and item positions (for example a `/*●*/` comment plus `()`, or an editor-only sidecar). Have the loader turn them back into dots, and test every Add leaf with build → save → reload → same structure.
- Use rust-analyzer (LSP or `ra_ap_ide`) as the type oracle for each hole's expected type (Doodle's `hint`), for "which attributes or derives apply", and for trait-required items. Use `cargo check --message-format=json` for diagnostics. Generate the std module tree and item tables from rustdoc's JSON output (the analog of tools/gen_core_tree.py). That output is unstable: it needs a nightly toolchain (`rustdoc -Z unstable-options --output-format json`, or the prebuilt `rust-docs-json` rustup component on nightly), and its format version changes, so generate the tables offline and check the generated Rust tables into the repo, as Doodle does with core_tree.odin. Get the crate list from `cargo metadata`. Filter `std::os::*` by target, as Doodle filters by `platform`.
- Run `rustfmt` on save as the analog of `format_doc`. Keep the editor's own node structure, and re-derive it from the CST after formatting.

## Open questions & known gaps

1. **LT+B on a procedure parameter deletes the whole procedure** (probe: `main :: proc(brave_otter: ●, ●)` → LT+B on `brave_otter` removed all 3 lines). There is no "remove parameter". The Rust version needs a per-parameter delete, like `result_list_delete` does for results.
2. **Unfilled holes in many leaves don't survive save/load** (invariant 6). Several save as invalid Odin: `X :  :`, `#config(X, )`, `x:  =`, `bit_set[]`, `bit_field  {`, `distinct`, `X ::` (reloads as a constant), `when  {`, `#assert()`, `#align()`.
3. **Sticky alias mode**: B out of `Aliased import` and then `Import > …` still inserts an aliased import (`import fmt "core:fmt"`).
4. **`Edit import` is the whole Add menu.** Choosing a non-import leaf inserts at a stale position and leaves `replacing = true`, which then swallows the next fill-menu pick (feature 7). A swap also discards a custom alias.
5. **Duplicate imports** are allowed. Imports aren't sorted or deduplicated anywhere. Odin rejects a duplicate (`Redeclaration of 'fmt' in this scope`), so the Rust port should gray already-imported paths (or `use` items) in the Import tree.
6. **`Dependencies` grayed inside a `when` is advisory only.** The import gets inserted, indented, inside the `when`. Grays outside options menus are never enforced. Resolved: Odin really forbids it (`Syntax Error: Cannot use 'import' within a 'when' statement…`, checked with the installed `odin check`), but `foreign import` and `foreign` blocks are allowed there, so the gray is both unenforced and too broad.
7. **The auto-added `import "core:testing"`** (from `@(test)`) is a single fixed field, so it isn't a cursor stop until reload. `#+build linux` (File tags) is never a stop. Code-read: both can still be selected with the RT tree walk (`tree_roots` includes every non-blank line and `tree_sync_cursor` puts the cursor on the line), and LT+B there deletes the line through `delete_selected`'s final single-node delete. No test covers this.
8. **Typed constant**: the value dot doesn't get the declared type as its hint, and the ` : ` operators aren't `decl` fields, so there is no Declare as.
9. **`#config` key** is fixed text duplicating the name. It only follows a rename through the rename prompt, whose 1-use label currently reads `Rename the other use%!(EXTRA 1)` (rename.odin `fmt.tprintf` with no verb). That bug belongs to doc 08.
10. **Foreign blocks** have no insertion dots, so procedures can't be added from the menus. A foreign import's path can't be swapped.
11. **Procedures group** offers only `Procedure`. Proc groups, polymorphic procs (`$T` params) and `#type proc` are recognized when loaded but can't be inserted. There is no `Polymorphic union` leaf either.
12. **First procedure is always `main`**, even when a sibling file already declares `main` (generated names check siblings; `main` doesn't).
13. **`Variable` is offered on every generic type dot** (result type, struct field type, distinct, alias). It produces `name: ●`, which only makes sense as a named result, and even there Doodle writes it without the parentheses Odin requires (`-> brave_otter: int {` is a syntax error, verified). Every position it creates is invalid Odin.
14. **Composite on a filled type replaces it** (no wrap). Unwrap only drops the immediate wrapper of the selected type, never from a map key.
15. **The package line is not auto-added** for new projects. EDITOR_MODEL.md §3.1 says it is; the code does not do it.
16. Removing all `$T` params of a polymorphic struct deletes the params dot permanently. It can't be made polymorphic again from the menus.
17. Modifier pick with no candidates gives no feedback at all. A notice would help.
18. `@(init)`/`@(fini)` silently replace an existing calling convention with `"contextless"`.
19. EDITOR_MODEL.md §3 ("Radial menu taxonomy") shows a radial menu, but the implementation is a grid (`grid_cols`); only the state enum is still named `.Radial`. Its table lists items such as procedure groups, file tags other than `#+build`, and doc comments that the code doesn't implement. Prefer the code.
20. **Attribute on the declaration's own line** (`@(private) Player :: struct {`): loaded fine and recognized as a type, but it isn't a modifier candidate, gets no purple dot even for a procedure, shows the attribute-line HUD hint, and LT+B anywhere on it removes only that header line (feature 27; code-read, untested).
21. **Edit Type on a filled bit_field backing type doesn't gray non-integers** (only the unfilled dot does, feature 14).
22. **`structure_results` normalizes spacing** in loaded result lists instead of keeping the exact text (feature 11), the one loader pass in this area without a round-trip check.
23. **File tags are not forced above `package`.** Odin rejects a `#+` line below the package line; the leaf inserts wherever the dot is.

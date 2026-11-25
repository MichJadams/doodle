# 06 — Type-driven menus: how edit options react to the underlying code

> Odin sources: src/model/typecheck.odin, var_types.odin, ref_pick.odin, ref_scope.odin, expr.odin, consts_menu.odin, types_menu.odin, enum_index.odin, calls.odin, change.odin, assign_ops.odin, when_const.odin, loop_unroll.odin, rename.odin, label_refs.odin, index_fill.odin, field_access.odin, builtin_procs.odin, range_fill.odin, struct_lit.odin (menu parts), ctrl.odin (Built-in constants / Enum value), loops.odin and branch.odin (iterable / case-value parts), model.odin (`open_slot_menu`, `menu_select`, `menu_cancel`, `make_view`), parse.odin (`attach_call_signature`), dictation.odin (`dot_takes_number`), stmt_layout.odin (`arg_row_extend_menu`), text_tools.odin (`open_text_tools`), heat.odin (`heat_is_action`), menu_sections.odin, src/app/main.odin and src/app/editor_view.odin (`slot_hint_label`, banner, ring). Baseline: Doodle @ 34a2ad1. Claims marked "(probe)" were checked by running throwaway tests against a copy of src/model outside the repo (`odin test`); they are not pinned by repo tests.

## Purpose

On a gamepad you can't type an expression, so every value is chosen from a menu. Doodle keeps those menus short enough to use by making them depend on where the cursor is: each empty value "dot" knows the type it expects, and the fill menu grays out what can't produce that type. The names it offers are the ones in scope at that line, and the adapters it offers ("Pass as", "Field of", `items[i]`, `T(x)`) depend on the picked name's type. It also respects constant-only positions (`when`, `#unroll`) and offers only the compound operators the target's type allows. Renaming a declaration offers to rename its uses within the declaration's scope. All of this runs on a small, text-based type oracle (document text plus tables generated from the Odin install), not a compiler. When the oracle can't tell, it never grays anything. This area is the main thing the owner wants carried over to Rust.

## Features

### F1. The pipeline at a glance (the menu function)

- **Trigger**: A on an orange value dot, or Y on a filled argument or operand (the part becomes a dot again first). Default bindings are in doc 03.
- **Behavior**: the menu is a pure function of the dot's position and the document:

```
build_fill_menu(doc, dot) -> MenuView:          # model.odin open_slot_menu, in this exact order
    prepare(dot)                                  # branch_prepare_slot: a case dot re-reads the switched value's type
    scope := names_visible_at(dot.line)           # file scope + locals before the dot, not in ended blocks
    imps  := imports_of(doc)                      # alias -> import path
    sibs  := declarations of the package's other files (procs, types)
    menu  := base_value_groups(doc, dot, imps, sibs)          # the 12 groups of F6, in authoring order
    menu  := insert_after("Constant", Built-in constants, Enum value)   # ctrl_extend_value_menu (always)
    if dot is a for-in iterable:                  # loop_extend_value_menu (before the type pass!)
        insert_after("Number", Range); gray leaves this loop can't iterate (F25)
        if the loop is #unroll: gray string-returning calls (F24)
    if dot is an #unroll range end: gray every call (F24)
    exp := resolve(dot.hint, dot.hint_pkg)        # Resolved_Type; Unknown when no hint / can't resolve
    if dot.hint != "" and exp != Unknown:
        gray(menu, leaf -> !fits(leaf, exp))      # F4; recomputes every leaf's dim; a group is gray iff no child fits
    if scope is empty: gray("Reference")
    if dot is a case value (switch with a value): gray values other cases use; insert_after("Number", Range)
    if dot is a value dot in a when-cond: gray every call (never un-grays anything)
    if dot is a Y-refilled argument of a call saved one-argument-per-row: append "Join with previous row" / "Own row"
    view  := order(menu)                          # pinned "used in this file" first; >12 others -> A-Z
    show(view, title = "Fill slot",
         subtitle = hint ? "expects <hint label>  -  grayed options don't fit" : none)
```

  The chosen leaf rewrites the dot. New sub-dots inherit or derive expected types (operands, ternary branches, call arguments, struct-literal fields), so the process repeats one level down. "Reference" does not fill directly. It switches to an in-file name picker (F15), then a "Pass as" menu (F16) that the picked name's type shapes in the same way.
- **Rules & edge cases**: Unknown expected type means no graying pass at all (an `any` expected type does run the pass; see F4 for the one thing it grays). Gray means "won't fit"; picking it still works (F5). The menu the user sees is a sorted view (F18), not the authoring order. Because the type pass recomputes every leaf's `dim`, anything grayed *before* it (iterable and `#unroll` dims) would be overwritten if the dot also had a hint; iterable and range-end dots carry no hint today, so this never happens (gap 12). Grays applied *after* it (Reference, used case values, `when` calls) only ever add gray.
- **Source**: src/model/model.odin `open_slot_menu`, `menu_select`, `make_view`; src/model/typecheck.odin `apply_fit_dims`, `slot_expected_type`; ctrl.odin `ctrl_extend_value_menu`; loops.odin `loop_extend_value_menu`; loop_unroll.odin `unroll_extend_value_menu`; branch.odin `branch_adjust_menu`; when_const.odin `when_extend_value_menu`; stmt_layout.odin `arg_row_extend_menu`.

### F2. Every dot carries an expected type (`Field.hint` + `Field.hint_pkg`)

- **Trigger**: implicit. Every construct that creates a value dot stamps it. Loading a file stamps dots too.
- **Behavior**: a slot field has `hint` (the type expression as written in its package, e.g. `LPCWSTR`) and `hint_pkg` (that package's import path, e.g. `core:sys/windows`; `""` = this file or a builtin). Who sets it:

| Where the dot is | Expected type | Source |
|---|---|---|
| Argument of a call | The parameter's type, by position among required params; the variadic dot (`args`, green) gets the `..T` element type. Optional params (with defaults) get no dot. | calls.odin `inject_call_args`, `call_signature`; parse.odin `attach_call_signature` (load); expr.odin `attach_nested_call_hints` (calls nested in expressions, on load) |
| Next variadic dot after filling one | Same type as the one just filled | calls.odin `append_more_args_slot` |
| Operand of `a \| b`, `a & b`, `a ~ b`, `a &~ b`, `~a`, `+ - * / %`, `-a` | The operator dot's own type | consts_menu.odin `make_slot_operator` |
| Left operand of `<<` / `>>` | The operator dot's own type | same |
| Right operand of `<<` / `>>` | none (any integer) | same |
| Operands of `== != < <= > >=` | none (anything) | same |
| Operands of `&&`, `\|\|`, `!a` | `bool` | same |
| Ternary branches / condition | The dot's own type / `bool` | expr.odin `make_slot_ternary` |
| Inside a conversion `T(●)`, `cast(T)●` | none (any value) | expr.odin `make_slot_conversion` |
| Both ends of a range `● ..< ●` | The dot's own type | range_fill.odin `make_slot_range` |
| Struct literal field value `name = ●` | The field's type | struct_lit.odin `lit_add_field`, `attach_lit_hints` (load) |
| `x: T = ●` | `T`. Re-synced after every fill or type change. Empty while the type is still a dot. | field_access.odin `sync_typed_decl_value_hint` |
| `target = ●`, `target op= ●` | The target's type, set when the target is picked (`set_assign_target` does this for every operator, `<<=`/`>>=` included (probe); gap 17). Y on the operator re-sets it: none for `<<=`/`>>=`, else the target's type, and only while the value is one empty dot ending the line. A Y-refill of the value expects none for `<<=`/`>>=` (`rhs_expected`). | field_access.odin `set_assign_target`, `rhs_expected`; loops.odin `set_assign_op` |
| `context.<field> = ●` | The field's type in `base:runtime` | loops.odin `context_field_entries` |
| `if ●`, `for ● {`, C-style condition, `when ●`, else-when | `bool` | branch.odin `cond_dot`; loops.odin `make_loop`; ctrl.odin; when_cond.odin |
| `case ●:` value | The switched value's type; `bool` for `switch {` | branch.odin `switch_case_hint`, `branch_prepare_slot`, `branch_sync` (every input) |
| `return ●` | The enclosing procedure's result type at that position | result_list.odin `result_list_sync` |
| Index key `items[●]` | The map's key type, an enum for `[Dir]T`, else `int` | index_fill.odin `ref_pass_index` |
| Other side of `ODIN_OS == ●` | The built-in constant's enum type (`Odin_OS_Type`, pkg `base:runtime`) | ctrl.odin `ctrl_fill` |
| `x := ●`, `X :: ●` | none (the value decides the type) | model.odin `make_body_statement` |
| A part turned back into a dot (Y refill, LT+B) | Recomputed from its position (F21) | change.odin `unit_expected` |

  Hints read from document text are interned (`intern_hint`) so they outlive the per-frame text; table strings are static.
- **Rules & edge cases**: built-in procedures (`len`, `append`, ...) have arity but no parameter types, so their dots carry no hint. A built-in name wins over a same-named procedure of this file (`call_signature` checks `builtin_proc` first). An unknown procedure (not in tables, not in this file or its siblings) gets `req 0, variadic` (one untyped green dot). For a proc name with several table rows of different arity (per-OS files), the lookup is permissive: min arity, variadic, unknown return, and the parameter list is dropped, so none of its dots get a hint. Rows of the same arity keep the first row's parameters and return type. This file's procs are found by a line containing ` :: proc` whose text before it is the name; the return type is the text after `->` up to `{`.
- **Source**: as listed. src/model/model.odin `Field`.

### F3. Showing the expectation

- **Trigger**: always, while editing and while a fill menu is open.
- **Behavior**: an unfilled dot draws its hint as a small gray label right after the dot (`● LPCWSTR`); a variadic (`args`) dot draws `..T` (`..any` for `fmt.println`). A dot without a hint draws no label. While a fill menu for a hinted dot is open, the line under the menu title reads `expects LPCWSTR  -  grayed options don't fit` (for a variadic dot: `expects ..any  -  ...`); without a hint there is no such line. Leaves that describe typed things carry the type in their label, separated by three spaces: struct fields `style   UINT`, index entries `items[i]   f32`, context fields `logger   Logger`.
- **Rules & edge cases**: the label is the hint as written in its package (`HINSTANCE`, not `win32.HINSTANCE`). LT+Y on a dot shows the documentation of the expected type (doc 07).
- **Source**: src/app/main.odin `slot_hint_label` and the radial title drawing; src/app/editor_view.odin (dot labels).

### F4. Resolving a type to a kind, and deciding what fits

- **Trigger**: every graying decision.
- **Behavior**: `resolve_type(expr, pkg)` returns `{cat: Type_Cat, canon: string}`. `canon` is the identity used for "same type":
  - Strip leading `distinct `. `$T` gives Unknown (polymorphic). `(A, B)` with ≥2 top-level parts gives Multi; a parenthesized single part (`(res: T)`) gives Unknown. `^T`/`[^]T` give Pointer, `[]T`/`[dynamic]T` give Slice, `map[` gives Map, any other `[` (`[N]T`, `[Enum]T`) and `matrix[`/`#simd` give Array, `proc`/`#type` give Proc, and `bit_set`/`struct`/`union`/`enum` literals give their category. For all of these, canon is the text itself. These are plain prefix tests on the text, so a type *named* e.g. `procedure_x` would be taken for a Proc (gap 16).
  - `ref.Name` (split at the first `.`): if `ref` is `builtin`, use the builtin table. Otherwise `ref` is looked up first among this document's import aliases (even while resolving text written inside a library; gap 14), then as any CORE_TYPES package whose path is `core:ref`, `base:ref` or ends in `/ref` and that declares `Name` (this is how library text such as `c.uint` resolves). Then resolve `Name` in that package. No match gives Unknown.
  - A bare name in package `pkg` that the generated `CORE_TYPES` table has (`pkg|name`) is resolved through that row, so a package's own declarations shadow builtins (`core:c` has `uint :: builtin.u32`). For `struct`/`enum`/`union`/`bit_set`, canon is `pkg.Name`. `bit_field` gives Struct. `distinct` keeps the category of its target but takes canon `pkg.Name`, so it is a new nominal type. `alias` resolves to its target, keeping the target's identity.
  - Otherwise a builtin name gives its category, with canon = the builtin name. Anything else, **including every type declared in this document or a sibling file**, is Unknown.
  - The recursion depth limit is 16, with a memo per menu build (`Type_Ctx`, keyed `pkg|expr`) and a lazy global index `path|name -> row` over CORE_TYPES.
  - Example chains: `LPCWSTR -> wstring -> cstring16` gives CString16 with canon `cstring16`. `HWND :: distinct HANDLE :: distinct LPVOID -> rawptr` gives Pointer with canon `core:sys/windows.HWND`. `UINT -> c_uint -> c.uint -> builtin.u32` gives Integer with canon `u32`. `BOOL :: distinct b32` gives Bool.
- **Fit rules** (each returns true when the expected category is Unknown or Any, with one exception: a call to a procedure that returns nothing is gray on an `any` dot too, because `ret_fits` lets `RET_NONE` fit only Unknown (probe: `assert` is gray on `fmt.println`'s `..any` dot)):

| Leaf | Fits when expected category is... |
|---|---|
| Number (`0`) | Integer, Float, Rune (Odin untyped constant) |
| `"..."` / raw string | String, CString, CString16 |
| `'...'` rune | Rune, Integer |
| `true` / `false` | Bool (distinct bools like `BOOL` too) |
| `nil` | Pointer, Slice (incl. dynamic), Map, Proc, Union, CString, CString16 |
| Imported constant | Untyped `#int` acts as Number. `#float` needs Float. `#string`, `#rune` and `#bool` act as the matching literal. A typed constant needs the same canon (`TRUE: BOOL` doesn't fit `UINT`). `?` fits everything. |
| Call (import / this file / built-in) | Return type has the same canon. Import procs resolve their return text in the table's package; this file's procs and built-ins resolve it with pkg `""` (document spelling, so a type declared in this package is Unknown and fits). Returns nothing (`RET_NONE`) only fits Unknown. Unknown return (`?`) always fits. Multi never fits, and that includes `(res: T, err: E) #optional_*` returns such as `strings.clone` (probe: gray on a `string` dot; gap 2). Built-ins are strict where they are typed: `len`/`cap`/`size_of`/`copy` return `int`, so they are gray on a `u32` dot. |
| Call "Other (name it yourself)", Reference, Variable | Always (a name or proc of unknown type) |
| Operator | Bitwise (`a \| b`, `a & b`, `a ~ b`, `a &~ b`, `~a`): Integer or BitSet. Shift: Integer. `+ - * /` and unary `-`: Integer, Float, Rune, plus binary `-` on BitSet. `%`: Integer. Compare and Logic: Bool. Choose (ternary): always. |
| Convert form (T(x) / cast / transmute) or auto_cast | Always. In a form's type list, a type fits when its canon (resolved in document spelling) equals the expected canon; a type the oracle can't resolve (this package's own types) fits. |
| Struct literal type | An import's struct leaf: expected is Struct with canon `path.Name`. This file's and sibling files' structs resolve to Unknown and **always fit** (probe: `Point` is lit on an `LPCWSTR` dot). |
| Built-in constant | Bool, string and int constants act as literals. Enum- or bit_set-typed ones need the same category (any enum). |
| Enum value | Always (built for this dot) |
| Anything else (type names in the Type menu) | Only a `typeid` or `any` slot |

  `value_fits(got, exp)` = Unknown on either side → true; got Multi → false; exp Any → true; else `got.canon == exp.canon`.
- **Rules & edge cases**: identity is nominal for package types and distinct types. `GetModuleHandleW` returns `HMODULE`, which doesn't fit an `HWND` dot. `INVALID_HANDLE_VALUE: HANDLE` doesn't fit `HWND`. Composite identity is the literal text, which can produce a *false* gray: a this-file proc returning `^win32.RECT` is gray on a dot expecting `^RECT` written in `core:sys/windows` (canon `^win32.RECT` vs `^RECT`; probe; gap 11). A type the oracle can't resolve never grays anything ("Anything we can't resolve is Unknown and never grayed out").
- **Rationale**: graying is a hint, not a compiler. A false "doesn't fit" would hide a valid choice, so uncertainty always falls on the permissive side.
- **Source**: src/model/typecheck.odin `resolve_type`, `resolve_uncached`, `builtin_cat`, `path_for_ref`, `literal_fits`, `value_fits`, `ret_fits`, `entry_fits`, `core_type_index`; consts_menu.odin `const_fits`, `op_fits`; expr.odin `conv_fits`; struct_lit.odin `lit_type_fits`; ctrl.odin `ctrl_entry_fits`.

### F5. Graying: advisory vs refused

- **Trigger**: any menu.
- **Behavior**: `apply_fit_dims` walks the tree. A leaf gets `dim = !fits`. A group gets `dim = true` when none of its children fit, so the user can see from the top level whether a branch is worth opening. Placeholder leaves (no fill, e.g. `(no imports yet)`) are left as they are and never count as fitting. Two kinds of gray exist:
  1. **Advisory (type-fit) gray**: everything in the fill menu, Convert type lists, Pass as, Field of, index entries, Assign to, case values and type-switch variants already used, and `when` / `#unroll` constness dims. Picking a grayed leaf **still performs the fill** (`menu_select` has no dim check on fills). Picking a grayed group still opens it. A grayed fill-menu leaf that is picked still wears the menu heatmap (doc 03 F13; heat.odin: "Leaves grayed by type fitting still work when picked, so they still count"); Pass as, Assign to, index entries and the rename prompt are never recorded in the heatmap at all (their labels are this document's names).
  2. **Refusal gray**: options menus opened by Y on a keyword or operator (loop options, the assignment-operator menu, the break/continue menu: all `__loop_opt__`; if/switch options: `__br_opt__`; compile-time/modifier menus: `ctrl_menu`). `loop_option_choose`, `branch_fill` and `ctrl_menu_choose` return early on a dim entry, so "the menu stays open" and nothing happens.

  Special cases: a dim "Reference" (no names in scope) closes the menu and leaves the dot as it was (or puts a Y-refilled original back). A dim keypad key changes nothing (that is why it is dim); `Del` and `OK` are never dim.
- **Rationale**: the code comments say type-fit grays are hints; the user may know better (an unresolvable alias, a deliberate conversion later).
- **Source**: src/model/typecheck.odin `apply_fit_dims`; model.odin `menu_select`; heat.odin `heat_is_action` ("Leaves grayed by type fitting still work when picked"); loops.odin `loop_option_choose`; branch.odin `branch_fill`; ctrl.odin `ctrl_menu_choose`; expr.odin `keypad_dims`.

### F6. The value menu ("Fill slot"): groups and defaults

- **Trigger**: A (or Y) on a dot of kind `value`, `args` (variadic, green) or `ret_more` (another return value).
- **Behavior**: authoring order is: `Number`, `String` (group), `true`, `false`, `nil`, `Reference`, `Call` (group), `Struct literal` (group), `Constant` (group), `Built-in constants` and `Enum value` (inserted right after Constant), `Operator` (group), `Convert` (group), `Type` (group). On a loop's iterable dot or a case value dot, `Range` is inserted after `Number`. On a Y-refilled argument of a call that is saved one argument per row, `Join with previous row` and/or `Own row` are appended at the end (stmt_layout.odin; row layout belongs to doc 05/10). Because the root always has at least 14 entries (more than 12), the view sorts it case-insensitively (F18), so the user sees: `Built-in constants, Call, Constant, Convert, Enum value, false, [Join with previous row,] nil, Number, Operator, [Own row,] [Range,] Reference, String, Struct literal, true, Type` (probe: exactly `Built-in constants | Call | Constant | Convert | Enum value | false | nil | Number | Operator | Reference | String | Struct literal | true | Type` on `fmt.println`'s dot). What each inserts (● = new dot):

| Leaf | Result | Notes |
|---|---|---|
| Number | editable `0` | LT+A opens the keypad (F20). Dictation can set it (doc 08). |
| String > `"..."  string` | `"` + editable empty text (field kind `string`) + `"` | the text is free text |
| String > `` `...`  raw `` | `` ` `` + text + `` ` `` | |
| String > `'...'  rune` | `'` + text + `'` | |
| true / false / nil | fixed text | |
| Reference | starts the name pick (F15) | |
| Call > ... | F7 | |
| Struct literal > T | `T{●}` (green "fields" dot) | F8 |
| Constant > `win.` > ... > MB_OK | `win.MB_OK` (fixed text) | F9 |
| Built-in constants > ODIN_OS | `ODIN_OS` | F10 |
| Enum value > `.North` | `.North` (or `{.VIDEO}` for a bit_set) | F10 |
| Operator > ... | `● op ●` | F11 |
| Convert > ... | `T(●)`, `cast(T)●`, `transmute(T)●`, `auto_cast ●` | F12 |
| Type > ... | the type's text as an editable type field (`x := int` is legal Odin); a Composite leaf builds `[●]●`, `[]●`, `map[●]●`, `^●`, ... | F13 |
| Range > `a ..< b  (up to b)` / `a ..= b  (through b)` | `● ..< ●` / `● ..= ●` (ends typed like the dot) | F14 |

  After a fill, the cursor returns to the same index among the line's selectable parts, which is the first part of what was inserted. On a variadic `args` dot, a fresh `, ●` with the same hint is appended. If the dot was a refill (Y), the saved original is discarded.
- **Rules & edge cases**: B at the root closes the menu and undoes a pending Y-refill (F21). B in a submenu goes up one level. A on a placeholder does nothing. A `capture` dot opens no menu (it captures a call result; doc 05). Other dot kinds get other menus: body dots get statements (doc 05), type dots get `Type` and `Variable`, `params` dots get `Add parameter`, data-body dots get members (doc 04), struct-literal `fields` dots get the unset fields (F8), an if/switch setup dot gets `Variable (:=)`, `Two names (:=)`, `Assignment`, `Call`, and a type switch's case dot gets the union's variants (F25).
- **Source**: src/model/model.odin `open_slot_menu`, `set_slot_literal`, `inject_string_lit`, `menu_select`.

### F7. Call group: procedures typed by return type, arguments typed by parameters

- **Trigger**: Fill slot > Call (the statement menu's "Calls" is the same tree).
- **Behavior**: three subgroups in fixed order:
  - `Internal procedure`: this file's procedures in file order (lines containing ` :: proc(`, first editable name) plus the package's sibling-file procedures not already listed (shown A-Z once there are more than 12). When there are none, a dim placeholder reads `(no procedures defined)`. Picking one inserts `name(●, ●)` (name fixed) with one dot per required parameter, typed from the declaration line's parameter list. A proc with no parameters gets `(` `)` as two fields, so its name stays selectable. A variadic proc adds a green `args` dot.
  - `From import`: one group per import (blank `_` imports skipped), labeled with the bare reference (`win`, `fmt`). If there are no imports, a dim placeholder reads `(no imports yet)`. Inside a group: first, procs already called in this file (pinned; how "called" is detected is F18 and gap 3), then the package's full proc list, grouped by `build_proc_hierarchy`:
    - ≤ 60 procs (`FLAT_MAX`): a flat list sorted by name.
    - otherwise, if they come from more than one source file: one group per file, labeled with the file name, sorted. Inside a file (or when there is one file), ≤ 60 is flat; otherwise, if more than one non-empty `foreign` block: one group per block plus `(top-level)`, sorted.
    - inside a block: ≤ 60 is flat; otherwise name-prefix groups for prefixes shared by ≥ 3 names (`MIN_PREFIX_SHARE`): snake_case up to and including the first `_` (`MB_...`), else the first PascalCase word (`Get...`). A prefix group with > 60 names is split into alphabetical buckets. Names with no shared prefix are listed beside the groups (≤ 60) or under an `other...` group of buckets. Everything at that level is sorted by label.
    - no shared prefixes at all: alphabetical buckets of 12 (`PAGE`), labeled by first and last initial (`a-c`, or `w` when equal).
    If the table doesn't know the package (no proc rows for its path), a single `Other (name it yourself)` leaf inserts `pkg.<generated_name>(●)` with an editable name and one untyped variadic dot. A known proc inserts `pkg.Proc(●T1, ●T2, ...)` with `pkg` and `Proc` fixed.
  - `Built-in`: the BUILTIN_PROCS list, 58 entries in authoring order (`len, cap, size_of, align_of, offset_of, ..., make, new, delete, append, ..., min, max, abs, clamp, ..., assert, ensure, panic, unimplemented, unreachable`); since that is more than 12, the view shows them A-Z (`abs, align_of, append, assert, assign_at, cap, card, clamp, ...`; probe). Each carries `req`, `variadic` and `ret` (`int`, `uintptr`, `typeid`, `?`, or nothing). Picking one inserts `name(●, ...)` with untyped dots.
- **Rules & edge cases**: graying is by return type (F4). From the tests: on an `LPCWSTR` dot, `win.L` (returns `cstring16`) and `utf8_to_wstring` (returns `wstring`) stay lit. `MessageBoxW` (returns `INT`) and `ensure_winsock_initialized` (returns nothing) are gray. The proc group `utf16_to_utf8` has an unknown return type, so it is lit. Inside a `when` condition every call leaf is grayed (F23).
- **Source**: src/model/model.odin `build_call_children`, `build_import_proc_menu`, `collect_called_procs`, `build_proc_hierarchy`, `make_call_this_package`, `make_import_proc_call`, `make_call_import`; calls.odin `call_signature`, `sig_from_decl`, `parse_params`, `inject_call_args`; builtin_procs.odin `BUILTIN_PROCS`.

### F8. Struct literal with typed fields

- **Trigger**: Fill slot > Struct literal.
- **Behavior**: the list is: the dot's expected type first, pinned and written as this file spells it (`win32.WNDCLASSW`), if it is a struct; then one group per import with its non-polymorphic struct types (`win32.`); then this file's structs; then sibling files' structs not shadowed by this file. If there are none, a dim placeholder reads `(no struct types)`. Choosing inserts `T{●}`, with the cursor on the green fields dot. A on the fields dot lists the fields not set yet, each labeled `name   Type` (`style   UINT`). Picking one gives `name = ●Type`, followed by another `, ●` while fields remain. If every field is set, the dim placeholder reads `(all fields set)`; if the fields are unknown, `(fields unknown)`.
- **Rules & edge cases**: an import's struct types are grayed unless their identity equals the expected struct; this file's and sibling structs are never grayed (they resolve to Unknown; F4). The expected type is pinned only when it isn't a pointer, is a struct whose fields Doodle knows, and (for a package type) the package is imported here; otherwise there is no pin. Polymorphic structs (`struct($T: typeid)`) are never listed (`Queue{}` doesn't compile). Import struct groups are not "used in this file"-pinned (unlike Constant and Type). Promoted `using` fields aren't settable by name. Unfilled fields dots aren't saved, so an untouched literal is `T{}`. Y on the type name refills the whole literal. Y on a field's value refills it typed with the field's type (`lit_field_hint`).
- **Source**: src/model/struct_lit.odin `build_struct_lit_entries`, `lit_type_fits`, `build_lit_field_menu`, `lit_add_field`, `lit_field_hint`.

### F9. Constant group (imported constants)

- **Trigger**: Fill slot > Constant.
- **Behavior**: one group per import that has constants, labeled `win.`. Inside: constants already used in this file are pinned first (`WM_PAINT`). Then all of the package's constants, grouped the same way as procs (by file and prefix: `MB_...`, `WM_...`; then alphabetical buckets). If no import has constants, a dim placeholder reads `(no imported constants)`. A leaf inserts `win.MB_OK`.
- **Rules & edge cases**: the constant's `kind` from the table decides fit (F4). On a `UINT` dot, `MB_OK` (`#int`) is lit and `TRUE` (`BOOL`) is gray. On an `LPCWSTR` dot, `MB_OK` is gray.
- **Source**: src/model/consts_menu.odin `build_const_entries`, `build_import_const_menu`, `const_fits`.

### F10. Built-in constants and Enum value

- **Trigger**: Fill slot > Built-in constants / Enum value.
- **Behavior**:
  - Built-in constants: `ODIN_OS, ODIN_ARCH, ODIN_DEBUG, ODIN_OPTIMIZATION_MODE, ODIN_ENDIAN, ODIN_BUILD_MODE, ODIN_NO_CRT, ODIN_TEST, ODIN_VENDOR, ODIN_VERSION` (11 entries with `More`, so shown in this authoring order), then `More` (the other 24, listed `ODIN_OS_STRING` ... `ODIN_VALGRIND_SUPPORT` in the table and shown A-Z because they are more than 12). Each has a type and category (`bool`, `string`, `int`, a compiler enum such as `Odin_OS_Type`, or the bit_set `Odin_Sanitizer_Flags`). Picking an enum-typed one right beside ` == `/` != ` (the other operand two fields away, an empty unhinted value dot; e.g. `ODIN_ARCH != ●`) gives that dot the enum's type (pkg `base:runtime`), so its Enum value group lists `.Unknown, .amd64, .i386, .arm32, .arm64, ...`.
  - Enum value: the members of the dot's enum, each inserting `.Member`. The enum type comes from the dot's hint when it names an enum with members: compiler enums (`Odin_OS_Type`, ...; a `runtime.` prefix is ignored), a `CORE_ENUM_MEMBERS` row (`ref.Name` through this file's imports, or a bare name in the hint's package), or an enum declared in this file or a sibling. Otherwise it comes from the operand on the other side of an adjacent ` == `/` != `: a built-in enum constant, or a name declared `name: T` anywhere in the document (the first such declaration; not scope-aware). For a bit_set dot (e.g. sdl's `InitFlags`, `distinct bit_set[InitFlag; Uint32]`; distinct/alias rows and this package's declarations are followed), each member of the element enum is offered as a one-member set `{.VIDEO}` (join more with Operator > Bitwise > `a | b`). If no enum is found, the group is grayed with a single placeholder `(no enum type here)`.
- **Rules & edge cases**: in a `when` condition expecting `bool`, `ODIN_OS` is gray ("ODIN_OS isn't a bool", test_fix_when_condition). Enum-typed built-ins fit *any* enum dot (gap 10). Enum value leaves always fit the dot they were built for. Enum values for an enumerated-array key work the same way (F17). The enum lookup does not follow alias/distinct rows (gap 9).
- **Source**: src/model/ctrl.odin `BUILTIN_CONSTS`, `build_builtin_const_entries`, `enum_members`, `enum_type_for_dot`, `operand_enum_type`, `bit_set_elem`, `build_enum_value_entries`, `ctrl_extend_value_menu`, `ctrl_fill`.

### F11. Operators and their operands

- **Trigger**: Fill slot > Operator > group > leaf.
- **Behavior**: the groups, in order, with these exact labels:
  - `Bitwise`: `a | b`, `a & b`, `a ~ b  (xor)`, `a &~ b`, `~a`, `a << b`, `a >> b`
  - `Arithmetic`: `a + b`, `a - b`, `a * b`, `a / b`, `a % b`, `-a`
  - `Compare`: `a == b`, `a != b`, `a < b`, `a <= b`, `a > b`, `a >= b`
  - `Logic`: `a && b`, `a || b`, `!a`
  - `Choose`: `a if c else b`, `c ? a : b`, `a when c else b` (F12a)

  A binary leaf replaces the dot with `●` ` op ` `●`. A unary leaf gives `op●`. Operand typing is listed in F2. Example: `●UINT` → `a | b` → `●UINT | ●UINT`. An operand can itself become an operator, which flattens into a chain `a | b | c` (one operator unit).
- **Rules & edge cases**: groups gray by `op_fits` (F4). On an `LPCWSTR` dot, Bitwise and Arithmetic are gray and Choose is lit. When the expected type of a part inside a flattened chain is recomputed (F21), it is regrouped by Odin precedence (`||`=1, `&&`=2, comparisons=3, `+ - | ~`=4, `* / % %% & &~ << >>`=5). A comparison's operands expect nothing, `&&`/`||` operands expect `bool`, and a shift count expects nothing. `%%` is not offered as an operator leaf (it is offered as `%%=`).
- **Source**: src/model/consts_menu.odin `OPERATORS`, `build_operator_entries`, `make_slot_operator`, `op_fits`; expr.odin `op_operand_expected`, `op_prec`.

### F12a. Ternaries (Operator > Choose)

- **Trigger**: Fill slot > Operator > Choose > form.
- **Behavior**: `a if c else b` → `●T if ●bool else ●T`. `c ? a : b` → `●bool ? ●T : ●T`. `a when c else b` → `●T when ●bool else ●T`, where `T` is the dot's expected type. The keywords are fixed fields of kind `tern`.
- **Rules & edge cases**: from the tests, on `operation = ●u32` the hints become `u32,bool,u32`. A Number is gray in the condition and `true` is gray in a branch. A `when` ternary's condition must be constant (F23). LT+B on a part leaves a typed dot. LT+B on that dot removes the whole ternary, leaving one dot of the original type.
- **Source**: src/model/expr.odin `make_slot_ternary`, `tern_split`, `tern_cond_index`.

### F12. Conversions (Convert)

- **Trigger**: Fill slot > Convert; Y on `T` of `T(x)` or on `cast(T)` (opens a menu titled `Convert`).
- **Behavior**: forms `T(x)`, `cast(T)x`, `transmute(T)x`, `auto_cast x` (in that order; the menu shows exactly these 4 labels). Opening a form builds its type list on demand (the submenu's title is the form's label, e.g. `T(x)`): when the dot has a hint, the expected type is pinned first, written as this file spells it (`type_text_here`: `HINSTANCE` in `core:sys/windows` → `win32.HINSTANCE`; `Maybe(^FRect)` in `vendor:sdl3` → `Maybe(^sdl3.FRect)`; when the hint's package isn't imported here, the hint is used as written). After it comes the whole Type menu (F13) minus composite constructors. Types whose canon differs from the expected one are grayed. For an `HMODULE` dot, `HINSTANCE` is gray (HMODULE is a distinct type), and `BOOL` and `bool` are gray. Results: `win32.HINSTANCE(●)`, where the inner dot takes any value. `cast(uintptr)●` and `transmute(u32)●` are a single fixed field plus the value. `auto_cast ●`.
- **Rules & edge cases**: the forms are always lit (auto_cast and "type not chosen yet" fit). Y on the conversion's type re-opens Convert. A new choice rewrites form and type and keeps the value (`cast(uintptr)instance` → T(x) > uintptr → `uintptr(instance)`). B changes nothing. LT+B on the type unwraps the value. A loaded `T(x)` counts as a conversion when `T` names a type: an imported type, a builtin, or a type or alias declared in this package. Its value's type is then `T`.
- **Rationale**: type lists are built lazily because "three copies of every imported type would make each value dot slow to open".
- **Source**: src/model/expr.odin `build_convert_entries`, `conv_expand`, `conv_type_entries`, `conv_retarget`, `type_text_here`, `make_slot_conversion`, `conv_change`, `conv_rewrite`, `conv_fits`; var_types.odin `conversion_type`.

### F13. Type group (types as values)

- **Trigger**: Fill slot > Type (also every type dot, and LT+A on a type, which opens `Edit Type`).
- **Behavior**: first one group per import (`win.`), with types already used in this file pinned first, then the full grouped list. Then `Composite` (`[N]T array`, `[]T slice`, `[dynamic]T`, `map[K]V`, `^T pointer`, `[^]T multi-ptr`). Then the enclosing polymorphic struct's `$T` parameters, this package's types, and Odin basic types (`int i8 i16 i32 i64 u8 u16 u32 u64 uint uintptr f32 f64 bool string cstring rune byte rawptr`). This submenu is pushed without view sorting, so it keeps that order.
- **Rules & edge cases**: in a value dot, type leaves fit only `typeid`/`any`, so on an `LPCWSTR` dot the whole Type group is gray. Type declarations and composite construction are doc 04.
- **Source**: src/model/types_menu.odin `build_type_entries`, `build_import_type_menu`, `collect_used_names`; data_types.odin `composite_type_group`, `poly_params_in_scope`, `doc_type_names`.

### F14. Range (contextual)

- **Trigger**: a case value dot, or a for-in loop's iterable dot.
- **Behavior**: `Range` > `a ..< b  (up to b)` / `a ..= b  (through b)` → `● ..< ●` / `● ..= ●`, with both ends typed like the dot. On a case dot, ranges fit Integer, Rune, Float, Enum, Unknown and Any; otherwise the group and both leaves are gray. On an iterable dot the group is built lit and then grayed only by the loop's own rules (a `#reverse` loop can't iterate a range; F25). `Range` is never inserted twice.
- **Source**: src/model/range_fill.odin `range_entry`, `range_fits`, `insert_range_entry`, `make_slot_range`; branch.odin `branch_adjust_menu`; loops.odin `loop_extend_value_menu`.

### F15. Reference: picking a name in scope with the D-pad

- **Trigger**: Fill slot > Reference; Y on an assignment target; automatically after adding an Assignment statement.
- **Behavior**: the menu closes and the editor enters pick mode. A banner reads `Pick a name to reference   -   D-pad move   A use it   B cancel`, and the target dot gets a pulsing ring. Candidates are editable name fields in file order, keeping those that are:
  - of kind `""`, non-empty, containing no `.`, and not a call's name;
  - not on `package` / `import` / `foreign` lines (so import aliases and package names are excluded);
  - **visible at the dot**:
    - file-scope names are always visible, including those declared later in the file;
    - a procedure's name is file scope, but its parameters are visible only inside it;
    - a local is visible only when the dot is in the same procedure, the local is declared on or before the dot's line, and it isn't inside a block that ended before the dot;
    - loop variables are visible only inside their loop (and the C-style condition and post);
    - if/switch setup names and a type-switch variable are visible only inside that statement (an else-if's setup names reach the rest of the chain);
  - when picking an assignment target, not declared with `::` (constants, procedures and types can't be assigned).

  The cursor starts on the last candidate before the dot in file order (an earlier line, or earlier on the dot's own line), or on the first candidate when none precedes it. Left/Right go to the previous/next candidate and wrap. Up goes to the first candidate on the nearest earlier line that has one (no wrap). Down goes to the first candidate on the next such line (no wrap). Every other input is swallowed while picking (the pick mode consumes it), except the global IDE-menu binding (LT+Left by default), which `update` checks first. A opens "Pass as" (F16), or "Assign to" for an assignment target (F19). B cancels and the dot stays empty (the cursor returns to it). For a Y-refill, B puts the original back. For a just-added Assignment, B removes the line, and if nothing could be picked the notice reads `nothing declared to assign to here - declare it first (Declarations > Variable)`.
- **Scope walk (the algorithm)**: let `d[k]` be the brace depth before line `start+k`, counted from the procedure's opening line. Walk upward from the dot (`at-1` down to `start+1`) keeping `min_d`. Initially `min_d` is the depth at the dot. At line `j`, set `min_d = min(min_d, depth after j)`, and also `min(min_d, depth before j+1 minus the number of leading }s on line j+1)`, so that `} else {` counts as closing the block above it. Line `j` is visible iff `d[j] <= min_d`. When line `j` is a `case` line at depth `min_d`, decrement `min_d`, because the other clauses of the same switch are out of scope. The same walk gives types (F22), so the nearest match wins and shadowing works.
- **Rules & edge cases**: "Reference" is grayed when there are no candidates (by scope only; never because no candidate's type fits). A loaded file's names are pickable, and loading still round-trips. Local constants (`N :: 3` inside a proc) load as plain text and aren't offered (but the constness check of F23 still sees them). Names on the dot's own line count as visible (`ref_scope_visible`: `if ni == s.at do return true`; needed for C-style loop headers and if-setups), so at `x := y` the candidates are `main y x` (probe; gap 6). **Number literals are offered as names** (probe at baseline against a scratch copy of src/model): `ref_candidates` filters on "editable, kind `""`, non-empty, no `.`, not a call's name" and never checks that the text is an identifier, while a number built by Value > Number (an editable `0`), set with the keypad or dictated into a value dot is exactly such a field. So after `x := 0` (menu-built), a Reference at the next line lists `main x 0 y`; inside a menu-built `for i := 0; i < ●; i += 1 {` the candidates are `main i 0 i 1` (the loop's `0` and `1` are editable `fname` fields of the C-style header; the `i` appears twice, once for the init and once for the post, because both are declaring fields). Picking `0` gives `Pass as` > `0` etc. A *loaded* number is fixed text and is not offered (a loaded `for i := 0; i < 10; i += 1` lists only `main i i`). A port should only offer identifiers that declare a name, once per declaration. The test fixture shows a dot in `greet` gets `MAX_HP Player greet who times count label` (a struct's field names are excluded).
- **Source**: src/model/ref_pick.odin `ref_candidates`, `start_ref_pick`, `ref_pick_update`, `ref_pick_cancel`, `ref_pick_finish_text`; ref_scope.odin `ref_scope_make`, `ref_scope_visible`; loops.odin `loop_name_visible`, `ref_target`; branch.odin `branch_name_hidden`; src/app/editor_view.odin (banner, ring).

### F16. "Pass as": how to use the picked name

- **Trigger**: A on a candidate during a value pick.
- **Behavior**: a menu titled `Pass as` with, in order:
  1. `name`: the value itself.
  2. `T(name)`: converted to the dot's expected type as spelled in this file (`windows.LPCWSTR(brave_otter)`, `Maybe(^sdl3.FRect)(rect)`). Shown only when the dot has a hint.
  3. `&name   (pointer to it)`: grayed when the expected type is known and isn't Pointer or Any.
  4. `name^   (what it points to)`.
  5. `Field of name` (group, F17), when the name's type is a struct.
  6. `name[i]   Elem` / `name[key]   Elem` (F17), when the type can be indexed.

  The choice fills the dot as fixed text (Y changes it later), and the cursor lands on it. On a variadic dot, another `, ●` follows. If the pick was a Y-refill, the saved original is discarded. B goes back to picking, not out of the feature.
- **Rules & edge cases**: the picked name's type comes from its own declaration line if it is declared there, else as seen from the dot (`picked_type`). The bare `name`, `T(name)` and `name^` are never type-grayed; only `&name` is. Extra dims apply in special positions: for a loop iterable, the name is grayed if it can't be iterated by this loop, `&name` is always gray, and `name^` is grayed by its pointee (doc 05). In `when` conditions and `#unroll` ranges, non-constant names and all fields and elements are grayed (F23, F24). Test (`test_pass_as_converts_for_messageboxw`): `brave_otter := windows.L("Testing")` passed to `MessageBoxW`'s `LPCWSTR` dot offers exactly `brave_otter | windows.LPCWSTR(brave_otter) | &brave_otter   (pointer to it) | brave_otter^   (what it points to)`, with `&` gray; picking the conversion gives `windows.MessageBoxW(nil, windows.LPCWSTR(brave_otter), brave_otter, windows.MB_OK)` (saved one argument per line because it exceeds 80 columns).
- **Rationale**: this came from the owner's real compile error. The variable's type didn't match the parameter, so the conversion is offered next to it (ref_pick.odin header comment, which calls `windows.L`'s result a `[^]u16`; in the current tables `L` returns `cstring16`, the same canon as `LPCWSTR`, so today the conversion is just always available, not needed).
- **Source**: src/model/ref_pick.odin `open_pass_as_menu`, `ref_pass_choose`, `ref_pass_cancel`; field_access.odin `picked_type`.

### F17. Field of / index access

- **Trigger**: Pass as > `Field of p` / `items[i]   T`.
- **Behavior**:
  - **Field of p**: one entry per field of p's struct type, labeled `name   Type` (the type as written in its package). Pointers auto-dereference (one level). Aliases and distinct types are followed, `using` fields are promoted (and listed here, unlike in struct literals), `_` fields are never listed, and `Stack(int)` substitutes poly params. A leaf `left   LONG` fills `p.rcPaint.left` as one value. A struct-typed field is a nested group (labeled `rcPaint   RECT`) whose first entry is the field itself (`paint.rcPaint`), plus `&paint.rcPaint` when the dot expects a pointer, then its own fields. Nesting goes at most 3 levels deep (`MAX_FIELD_MENU_DEPTH`), and pointer-typed fields aren't expanded (self-referencing nodes would explode the menu). Leaves whose type doesn't fit are gray. A struct field stays lit while anything inside it fits. When the dot expects a pointer, `&f   ^T` leaves are added after each non-struct field (lit when `T` matches the pointee; `rawptr` takes anything). Non-struct fields that can be indexed also get a `p.items[i]   T` entry right after them. The whole `Field of p` group is gray when nothing in it fits, and it is absent when p's type isn't a struct Doodle knows.
  - **Index**: `index_types` gives `map[K]V` → key K, element V. `[N]T` / `[]T` / `[dynamic]T` / `[^]T` → key `int` (probe for `[^]u16`), or the enum for `[Dir]T`. `string` → key `int`, element `u8`. Aliases and distinct types are followed (table rows, this file, siblings; depth ≤ 6). The label is `items[i]   Elem`, or `m[key]   V` for a map. The leaf fills `items[●Key]` (`items[` fixed, a value dot hinted with the key type, `]` fixed) and the cursor lands on the key dot; on a variadic dot another `, ●` follows. The entry is gray when the element type doesn't fit.
- **Rules & edge cases** (test `test_field_menu_gray_out`): `PatBlt`'s `INT` x dot: `rcPaint   RECT` lit (it leads to LONGs), `fErase   BOOL`, `rgbReserved   [32]BYTE`, `hdc   HDC` gray; inside, `paint.rcPaint` gray, `left   LONG` lit. `InvalidateRect`'s `^RECT` dot: `&paint.rcPaint` lit. `y = arr[●Dir]` then Enum value > `.North` → `y = arr[.North]`.
- **Source**: src/model/field_access.odin `append_field_group`, `field_entries`, `type_fits`, `ptr_fits`; var_types.odin `struct_fields`, `field_type`, `is_struct_type`; index_fill.odin `index_types`, `index_entry`, `append_index_entries`, `ref_pass_index`; enum_index.odin `enum_index_type`.

### F18. Ordering: "used in this file" pins, sections, sorting

- **Trigger**: every menu view.
- **Behavior**: a view is built in this order:
  1. Leaves whose import is already in the file (Add menu only).
  2. Recently used imports.
  3. **Pinned** entries in authoring order. These are procs already called (`collect_called_procs`: per line, the text between the *first* `ref.` and the next `(`, with no identifier or word-boundary check; so `x := win.MB_OK + int(win.GetLastError())` pins a bogus leaf `MB_OK + int`, and `h: win.HWND = win.GetActiveWindow()` pins `HWND = win.GetActiveWindow` (probe; gap 3)), types and constants already used (`collect_used_names`: `ref.Name` as a whole identifier, not preceded by an identifier byte, that the package declares), and the expected type in Convert and Struct literal lists.
  4. Everything else.

  Items 1 to 3 form a separate "RECENTLY USED" section with its own grid rows (only when something follows it). If "everything else" has more than 12 entries (`BUCKET_THRESHOLD`), it is sorted alphabetically (case-insensitive, by label). Otherwise authoring order is kept. Exceptions that skip the view ordering entirely: the `Type` submenu of a fill menu (F13), the number keypad (F20) and the text tools. An import's list is grouped from the package's full name list and then has the used names removed, so group shapes and trails are the same in every project (they share heatmap wear; doc 03 F13).
- **Source**: src/model/model.odin `make_view`, `remove_named_leaves`, `collect_called_procs`; types_menu.odin `collect_used_names`; menu_sections.odin `menu_rows`.

### F19. Assignment targets ("Assign to") and the value's type

- **Trigger**: adding Assignment > `Assignment` or `+=` etc. (the pick starts at once); Y on an assignment's target.
- **Behavior**: the pick (F15) offers only assignable names (not declared with `::`). A opens `Assign to`: the name itself; `name^   (what it points to)` if its type starts with `^`; and `Field of name` if it's a struct (every field, nested, none type-grayed). The choice becomes the target (one editable field, e.g. `class.style`), and the empty value dot right after the operator gets the target's type (`expr_type_at` of the target text), even for `<<=`/`>>=` (probe; gap 17). A value that is already filled (e.g. a call) keeps its own dots' hints. For `class` → `Field of class` → `style   UINT`, the line becomes `class.style = ●UINT`, and `true` is then gray.
- **Rules & edge cases**: for `x op= ●`, targets whose type can't take `op` are dimmed (advisory; F20b). B in "Assign to" goes back to picking. B in the pick removes a just-added assignment line.
- **Source**: src/model/field_access.odin `assign_pick_start`, `open_assign_target_menu`, `set_assign_target`, `is_assign_target`, `assign_pick_drop`, `rhs_expected`.

### F20b. Compound assignment operators per type

- **Trigger**: Y on an assignment's operator (menu title `Operator`); picking the target of an operator statement.
- **Behavior**: all of Odin's operators are offered (`ASSIGN_OPS` = `= += -= *= /= %= %%= |= &= ~= &~= <<= >>= &&= ||=`; 15 entries, so the view shows them sorted by byte value: `%%= %= &&= &= &~= *= += -= /= <<= = >>= |= ||= ~=` (probe)). The target's category comes from `expr_type_at` of the field just before the operator. Options the target's category can't take are refused (dim; the menu stays open), and so is the current operator:

| Operator | Target category allowed |
|---|---|
| `=` | any |
| `%=` `%%=` `<<=` `>>=` | Integer, Rune |
| `\|=` `&=` `~=` `&~=` | Integer, Rune, Bool, BitSet |
| `&&=` `\|\|=` | Bool |
| `+=` `-=` | Integer, Rune, Float, BitSet, Array (element-wise) |
| `*=` `/=` | Integer, Rune, Float, Array |

  Unknown/Any allows everything. Changing to `<<=`/`>>=` clears the value dot's hint (the shift amount can be any integer). Other operators set it to the target's type. Both happen only when the value is a single empty dot ending the line; a filled value is left alone.
- **Rules & edge cases** (tests `test_fix_assign_ops`, `test_loops_compound_assignment`): on `ratio: f32`, `%= |= <<= %%= &&=` are dim and `+= = /=` lit. On a string, `+=` is dim. On a bool, `|=` and `||=` are lit and `+=` is dim. On `n := 1` with `n += 2`, the menu shows `&&=`, `+=` (current) and `||=` dim (probe). A new `%%=` statement (Assignment > `%%=`): in its `Assign to` menu, `ratio` is dim (advisory: it can still be picked). The Assignment group of the statement menu lists `Assignment`, `Implicit Context` (the `context.<field> = ●` group) and the 14 compound operators (doc 05).
- **Source**: src/model/assign_ops.odin `assign_op_fits`, `assign_target_cat`, `assign_target_dims`; loops.odin `open_assign_op_menu`, `set_assign_op`, `ASSIGN_OPS`.

### F20. Number keypad

- **Trigger**: LT+A on a number literal (menu-built, or loaded and non-negative).
- **Behavior**: a menu titled `Number` with keys in fixed order (no sorting): `1 2 3 4 5 6 7 8 9 0 A B C D E F 0x . Del OK`. Each key edits the field in place, and the keypad stays open. `0x` only applies to a lone `0`. `A`–`F` need `0x`. `.` applies only once and not in hex. A digit replaces a lone `0`. `Del` drops the last character; deleting the last digit (or the `x` of a bare `0x`) gives `0`. Keys that would change nothing are grayed (`Del` and `OK` never are). OK or B closes it, and the edits already made stay. Example: `0` → `0x 0 0 F F 0 0 6 2` → `0x00FF0062`. A number loaded from a file is fixed text; LT+A makes it editable first, unless it starts with `-`.
- **Source**: src/model/expr.odin `number_keypad_open`, `keypad_apply`, `keypad_dims`, `number_key`.

### F21. Y refills a part typed for its position; LT+B leaves a typed dot

- **Trigger**: Y on an argument, operand, ternary part, struct-literal value, or statement value; LT+B on such a part.
- **Behavior**: `unit_expected` computes the part's expected type by walking the line's expression tree from the statement's call. For a call, the parameter by position. For a struct literal, the field. For an operator, F11's precedence rules. For a ternary, the condition is bool and the branches are the parent's type. For a conversion, anything. If that yields nothing, `rhs_expected` is used: the declared type of `x: T = ...` or the target's type for `=` and `op=` (except shifts), then descending into operators. If that also yields nothing, `loop_expected` is used: a loop condition is `bool` and a C-style post value is the target's type. Y moves the original fields aside, puts a typed dot in their place and opens the fill menu (if no menu opens, the original goes straight back). Choosing anything discards the original. B at the root puts it back exactly. Y on a string-literal argument opens the text tools (title `Text`) with `Replace value` first; `Replace value` then does the refill. For a call saved one argument per row, the refill's Fill slot menu also offers `Join with previous row` / `Own row` (F6). The order in which Y decides what a part is (`change_selected`): a conversion's type (F12), if/switch parts, compile-time parts, loop parts and assignment operators (F20b), a call's name (F21b), a declaration operator (F21b), a dot (same as A), a struct literal's type (refill the whole literal), a string literal (text tools), an argument/operand (refill), an assignment target (F19), else the edit menu (LT+A). LT+B on a part leaves a typed dot. LT+B on such a dot removes the enclosing operator or ternary, leaving one dot of the parent's type. In a chain of 3+ operands, only that operand and one adjacent operator are removed. LT+B on a conversion's type, or on the empty dot inside a conversion, unwraps it (the value stays). LT+B on an empty argument dot of a call nested in an expression does nothing (LT+B on that call's name removes the call).
- **Rules & edge cases**: a loaded `paint.rcPaint.left` argument is one unit. Y on it gives a dot typed `INT` (PatBlt's x), and B restores the text byte-for-byte.
- **Source**: src/model/change.odin `change_selected`, `begin_refill`, `refill_restore`, `refill_discard`, `unit_expected`, `expected_for`, `expected_in`; field_access.odin `rhs_expected`; loops.odin `loop_expected`; expr.odin `expr_delete`, `part_to_dot`; text_tools.odin `refill_string`.

### F21b. Y on a call's name: Change procedure; Y on a declaration operator: Declare as

- **Trigger**: Y on a call's name; Y on `:=` / `:` / `::` of a declaration.
- **Behavior**:
  - `Change procedure` lists the same import's procs (the same tree as Call > From import > that package, used-in-this-file pins included), or, for an unqualified call, `Internal procedure` and `Built-in`. Its heatmap trail is shared with `Call > From import > <path>` (or `Call`). Choosing a proc renames the call and **replaces all arguments** with fresh dots typed for the new signature (plus a variadic dot). The cursor goes to the first new dot, or stays on the name when there are no parameters. (The file header comment of change.odin still says "arguments kept"; the code replaces them.) For a qualified call whose package isn't imported or isn't in the tables, Y on the name opens nothing.
  - `Declare as` offers `<name> := value   (type inferred)`, `<name>: type = value   (choose the type)`, `<name> :: value   (constant)` (no option is grayed, not even the current form). Choosing "typed" on an untyped declaration inserts `: ● = ` (a type dot) and opens the type's fill menu immediately; on an already typed one it does nothing. Choosing `:=` or `::` on a typed declaration drops the type (and adds an empty value dot if `x: T` had no value). Once a type is chosen, the value dot expects it (F2).
- **Rules & edge cases**: Change procedure doesn't gray by return type (gap 13). B on either menu changes nothing.
- **Source**: src/model/change.odin `open_change_call_menu`, `apply_change_call`, `open_decl_form_menu`, `apply_decl_form`.

### F22. The name/expression type oracle (`var_type_at`, `expr_type_at`)

- **Trigger**: internal. Used by Pass as, Field of, index, assignment hints, enum detection, loop iterables, case dots, and constness.
- **Behavior**: `var_type_at(line, name)` → `{expr, pkg}` (a type expression and the package it is written in). It uses the scope walk (F15) inside the procedure: branch setups, loop headers, ordinary declaration lines, then parameters, then file scope. The first match wins. A declaration line gives a type as follows:
  - `name: T`, `name: T = v` and `X : T : v` give `T` (a leading `using ` is ignored).
  - `name := v` and `name :: v` give `expr_type(v)`; `a, b := x, y` gives the matching value's type; `name :: #config(...)` is declared but untyped.
  - `a, b := f()` gives the idx-th result of `f`'s `(T1, T2)` / `(a: T1, b: T2)` return list.
  - `v, ok := m[k]` gives the map value type and `bool`; `v, ok := x.(T)` gives `T` and `bool`.
  - `name :: proc` gives `proc`.
  - type declarations aren't values.

  `expr_type_at(text)`:
  - A ternary gives its first branch's type (`a` in `a if c else b`, `a` in `c ? a : b`).
  - The first top-level binary operator found, scanning in the order `|| && == != <= >= < > | ~ &~ & << >> + - * / % %%`: comparisons and `&&`/`||` give `bool`; any other gives the left operand's type, or the right operand's when the left is unknown.
  - `&x` gives `^T`, and `x^` gives what x points to.
  - `"..."` and raw strings give `string`, `'.'` gives `rune`, a number gives `int`, or `f64` if it contains `.` and isn't `0x...`. `true`/`false` give `bool`. `nil` and `auto_cast x` give nothing.
  - `cast(T)x`/`transmute(T)x` give `T`. `T{...}` gives `T`.
  - `make(T, ...)` gives `T`.
  - A call to a conversion `T(x)` gives `T`.
  - A call gives its single return type; for `(res: T, err: E) #optional_...` that is the first result (`strings.clone(s)` gives `string`; probe). Other multi-result calls give nothing.
  - `x[i]` gives the element type.
  - `a.b.c` follows fields, auto-dereferencing pointers.
  - `pkg.CONST` gives the constant's typed kind (untyped `#int` etc. give nothing).
  - The depth limit is 10.
- **Rules & edge cases**: a local inside a block that has ended returns unknown (`inner` after its `if`). Loop variables are typed from the iterable: element and index (`int`, or the enum for `[Dir]T`), map key and value, a range's low end (`int` for a literal), a string's `rune` and `int` index; `[^]T` can't be iterated. A type-switch variable inside `case T:` with a single type is `T`, otherwise (several types, `nil`, `case:`) the union. File scope means this document's top-level lines only; a sibling file's global *variable* is not typed. Type declarations in sibling files are read in their own file's import names and translated (`sibling_type_here`).
- **Source**: src/model/var_types.odin `var_type_at`, `var_type_depth`, `line_declares`, `decl_text_declares`, `expr_type_at`, `expr_type_depth`, `enclosing_proc`, `call_ret_text`, `conversion_type`; index_fill.odin `comma_ok_type`; loops.odin `loop_header_declares`, `iter_types`, `iter_info`; branch.odin `branch_declares`.

### F23. Constant-only positions: `when` conditions

- **Trigger**: a dot inside the condition of a `when ● {` / `} else when ● {` header, or of a `a when ● else b` ternary, including operands of an operator built there.
- **Behavior**: on a `value` dot there (not an `args` dot), the value menu grays every call leaf (`Other (name it yourself)` included), and each group left with nothing lit. In Pass as, each of `name`, `T(name)`, `&name`, `name^` is judged by `unroll_const_expr` on the text it would insert, so `&N` and `N^` stay lit for a constant `N` (the punctuation is ignored), and `T(N)` is lit only when `T` is a basic type (`win32.UINT(N)` is gray, `u32(N)` lit). Field of and index entries are always gray there. A name counts as constant when it is one of these:
  - `true`, `false` or `nil`;
  - an `ODIN_*` built-in;
  - `pkg.NAME` found in the package's constants;
  - a nearest in-scope declaration `name :: v`;
  - a file-scope `N :: v` whose value isn't a type, procedure or composite.

  Loop variables, if/switch names, parameters, `:=` and `:` declarations are not. `pkg.x` where `pkg` isn't an import (a field of a value) is not. An expression is constant when every word in it is: string and number literals and `.Enum` values are allowed, and `word(` is allowed only for conversions to `int uint i8..i128 u8..u128 uintptr byte f16 f32 f64 rune bool string` (`CONV_TYPES`). Local constants (`N :: 3` inside a procedure) do count as constants here, even though Reference doesn't offer them.
- **Rationale**: Odin requires constant `when` conditions ("Expected a constant boolean condition ...", when_const.odin header).
- **Source**: src/model/when_const.odin `in_when_cond`, `when_extend_value_menu`, `when_pass_as_dims`; loop_unroll.odin `unroll_const_name`, `unroll_const_expr`.

### F24. Constant-only positions: `#unroll for`

- **Trigger**: an `#unroll for` loop's range-end dots or iterable dot; Y on `for` > `Add #unroll`.
- **Behavior**: on a range end, calls are gray in the value menu. In Pass as, non-constant names, `&x`, `x^`, fields and elements are gray. On the iterable, calls whose return text is exactly `string` or `cstring` are gray (an alias of string isn't detected), and so is a non-constant name of string type in Pass as (arrays, even from calls, are fine). `Add #unroll` is refused (dim) unless the loop's range or string is constant. `#unroll` also never iterates slices, dynamic arrays or maps (doc 05).
- **Rules & edge cases** (test `test_fix_unroll_constants`): `count := 3` is dim and `N :: 3` lit; `text := "hello"` is dim and `TEXT :: "hi"` lit; `for i in 0..<count` makes "Add #unroll" dim, while `0..<4` leaves it lit.
- **Source**: src/model/loop_unroll.odin `unroll_extend_value_menu`, `unroll_pass_as_dims`, `unroll_iter_const`, `is_unroll_range_end_dot`.

### F25. Iterables and case values (type-driven parts)

- **Trigger**: a for-in iterable dot; a case value dot; a type-switch case dot.
- **Behavior**: iterable dots get `Range`, and every leaf is grayed unless it can be iterated by *this* loop. `&x` needs addressable elements (not a string, range or map key), `#reverse` excludes maps and ranges, and `#unroll` excludes slices, dynamic arrays and maps. A leaf's iterability comes from its return type or constant kind (`iter_info`): string literals and `#string` constants are strings, `Range` is a range, Reference and `Other (name it yourself)` are Unknown (lit), and numbers, bools, nil, operators, enum values, struct literals and types can't be iterated. Case value dots expect the switched value's type (`bool` for `switch {`, which gets neither `Range` nor used-value grays), gray values other cases already use, and get `Range`. "Already used" is checked only for Enum value, Built-in constant and imported Constant leaves (compared by their inserted text, `.North` / `ODIN_OS` / `win.MB_OK`); a Number already used by another case is not detected. Type-switch case dots list the union's variants (used ones gray, advisory), then `nil` and `Type`; variants are found only for unions declared in this file or a sibling, not for imported unions. Details are in doc 05.
- **Source**: src/model/loops.odin `loop_extend_value_menu`, `iter_allowed`, `iter_dims`, `entry_iter_kind`, `loop_pass_as_dims`; branch.odin `branch_prepare_slot`, `branch_adjust_menu`, `used_case_values`, `branch_slot_menu`.

### F26. Rename with propagation (scope-aware prompt)

- **Trigger**: changing the name a declaration introduces by voice (doc 08) or by LT+A text tools (Case conversions).
- **Behavior**: the name changes immediately. If the field declares the name (a parameter, a loop/if/switch variable, or a name left of `:`/`:=`/`::` on a declaration line) and the name has uses in its scope, a menu opens titled `Rename brave_otter to window_title?` with options `Rename all N uses` (or `Rename the other use` when N = 1; at baseline that one renders as `Rename the other use%!(EXTRA 1)`, a format-string bug described in doc 08 F19) and `Only this one`. N counts whole-word occurrences. "Rename all" rewrites the occurrences. "Only this one" or B keeps just the declaration change. Both old and new name must be identifiers; string, comment, struct-literal key, label and `member` fields never prompt. Scope rules (`rename_scope`):
  - file-scope declarations (lines at a file-scope insertion point) cover the whole file;
  - parameters, and names declared on a line that opens a block (loop / if / switch headers), cover `construct_range` of that line, which is the whole **top-level** construct around it: for a parameter, its procedure; for a loop or if header inside a procedure, the whole procedure, including the lines before the header (gap 7);
  - other locals run from the declaration to the end of the enclosing block.

  An inner redeclaration shadows the name until the end of its own reach (computed with the same rules, so a redeclared loop/if name skips to the end of the procedure). Uses are whole words in code: not in strings or comments, not right after a `.` (a field or a package member; the name *before* a `.` does count, so `a.a` holds one use of `a`), and not a `{name = ` / `(name = ` / `, name = ` key.
- **Rules & edge cases**: renaming a use (not a declaration) never asks. Sibling files are never changed. Labels are different: renaming a loop or block label silently rewrites its `break label` / `continue label` inside that block (label_refs.odin `label_rename_jumps`, run by `set_field_text`). New labels get a name unique in the procedure (`fresh_name` + `proc_has_label`), but renaming a label is not checked for uniqueness.
- **Source**: src/model/rename.odin `rename_field`, `rename_uses`, `field_declares`, `rename_scope`, `code_word_hits`, `rename_offer`, `rename_choose`; label_refs.odin `label_rename_jumps`, `proc_has_label`; model.odin `set_field_text`.

### F27. Other type-aware affordances (pointers to other docs)

- **Capture dots**: a bare call statement whose procedure returns values gets a pink dot. A on it turns `● len(s)` into `brave_otter := len(s)`, or `a, b := f()` for two results. The call's return type decides this (doc 05; capture.odin `call_result_count`).
- **Dictation of numbers**: push-to-talk on a value dot treats speech as a number only when the dot takes a number (Integer, Float, Unknown or Any) (doc 08; dictation.odin `dot_takes_number`).
- **Typed dots on load**: a loaded file gets the same typed dots as a menu-built one. Missing required argument dots are added, and variadic dots and operand hints are restored (doc 01; parse.odin `attach_call_signature`, `same_type_operands`).

## Invariants & constraints to carry forward

1. **HARD** — Unknown never grays. If the expected type or the candidate's type can't be resolved, the option stays lit: `open_slot_menu` skips the pass when the expected type is Unknown, and `value_fits`, `literal_fits`, `const_fits`, `op_fits`, `ctrl_entry_fits` and `lit_type_fits` return true on Unknown. An `any` expected type is "anything fits" too, with one deliberate exception: a call that returns nothing is gray (`ret_fits`). Pinned by `test_resolve_windows_types` (unknown name → Unknown), `test_lptext_grays_out_bool_and_number` ("Reference ... unknown type, never grayed"; the proc group with unknown return stays lit) and `test_println_any_grays_nothing` (Number, String, true, nil and the Call group stay lit on `..any`). Known violations of the spirit (false grays from textual composite identity, `#optional_*` returns) are gaps 2 and 11.
2. **HARD** — Type-fit gray is advisory: picking a grayed leaf still applies it (`menu_select` never checks `dim` for fills). Only explicit options menus (loop, branch, compile-time, assignment-operator) refuse dim entries, and then "the menu stays open". No repo test asserts that a grayed fill works; `handmade_exact_build_test` logs grayed picks as soft findings and keeps building.
3. **HARD** — A group is grayed iff none of its leaves fit (`apply_fit_dims`; `iter_dims`; `when_dim_calls` and `dim_tree` only add gray). Placeholders never count as fitting. Pinned indirectly (`Call` lit / `Type` gray on LPCWSTR; `Bitwise` gray on LPCWSTR).
4. **HARD** — Every value dot a construct creates carries the expected type it can know (F2), both when built from menus and when loaded from text (`test_expr_nested_call_dots_typed_on_load`, `test_messageboxw_dots_know_their_types`).
5. **HARD** — Identity is nominal for named and distinct types and transparent for aliases (`test_resolve_windows_types`: `UINT` canon `u32`, `HWND` canon `core:sys/windows.HWND`).
6. **HARD** — Literal fit follows the language's untyped-constant rules, not the literal's default type. A Number fits a float slot, a rune fits an integer slot, `"..."` fits `cstring16`, and `true` fits `distinct b32` (`literal_fits`; pinned: rune lit on UINT in `test_hwnd_and_uint_slots`, String lit on LPCWSTR in `test_lptext_grays_out_bool_and_number`). In Rust these rules differ (see "Carrying this to Rust"); carry the principle (follow the target language's literal-typing rules), not Odin's table.
7. **HARD** — Reference offers only names in scope at the dot: file scope always; locals of the same procedure declared at or before the dot and not in an ended block; loop and branch names only inside their statement (`test_fix_reference_scope`). (Doodle counts every name on the dot's own line as visible, which a C-style header or if-setup needs but which also offers `x` inside `x := ●`; gap 6. Copy only the header case.)
8. **HARD** — B always restores: a Y-refill puts the original fields back exactly (`test_reference_via_y_refill`, convert tests compare the whole source). B in Pass as or Assign to returns to picking, not to the document.
9. **HARD** — After any fill, saved text plus a reload produces the same structure (tests call `expect_stable`/round-trip after menu edits). Menus never write text the loader can't read back.
10. **HARD** — Constant-only positions dim non-constant choices (`when` conditions, `#unroll` range ends and strings; `test_fix_when_condition`, `test_fix_unroll_constants`). These dims are advisory, like type-fit dims; only `Add #unroll` in the loop options is refused.
11. **HARD** — Compound operators are limited by the target's type category (`test_fix_assign_ops`). The current operator is dim in its own Y menu (`test_loops_compound_assignment`).
12. **HARD** — Rename only offers to propagate from a declaration, only within its scope, and never touches strings, comments, members or literal keys (`test_rename_*`, `test_code_word_hits`). Doodle's scope for loop/if/switch header names is too wide (gap 7); a Rust version must get this exactly right.
13. **SOFT** — Menus show "used in this file" names first, and import groupings are built from the full name list so the same trail exists in every project.
14. **SOFT** — Expensive lists are built lazily (Convert forms) and lookups are indexed or memoized per menu build. Opening a dot must feel instant.
15. **SOFT** — Expected types are written in the user's own spelling (`win32.HINSTANCE`, not `HINSTANCE` or `core:sys/windows.HINSTANCE`) wherever they're inserted into code (`type_text_here`, `doc_type_text`). The small label next to a dot and the `expects ...` subtitle show the hint as written in its package (`HINSTANCE`).
16. **SOFT** — The oracle stays a fast approximation over text and tables. Correctness is checked by the real compiler (`odin check` in tests, doc 11 §7; in the app, doc 07 §14), not by the menus.

## Data model & formats

- **Field** (one piece of a line; doc 01): `text`, `editable`, `slot`, `kind` (value-dot kinds here: `value`, `args`, `ret_more`; others: `type`, `body`, `params`, `fields`, `capture`, `setup`, `variant`, `tern`, `conv`, `litkey`, `lit`, `decl`, `assign_op`, `label`, `string`, ...), `hint` (expected type text), `hint_pkg` (import path that text is written in; `""` = this file/builtin).
- **Entry** (a menu cell): `label`, `fill` (the action marker below), `call_name`/`call_pkg` (what to insert: proc or constant name and import ref; for Convert, the type text), `ret`/`ret_pkg` (a proc's return type text or a constant's kind, and the package it's written in; for Convert, the form), `dim`, `pinned`, `heat_key`, `children`.
- **Fill markers** used in this area: `__lit_num__`, `__lit_str__`, `__lit_rawstr__`, `__lit_rune__`, `__lit_true__`, `__lit_false__`, `__lit_nil__`, `__lit_ref__` (Reference), `__var__`, `__call_this_pkg__` (this package's procs and built-ins), `__call_import__` (Other (name it yourself)), `__call_import_proc__`, `__const_import__`, `__op__`, `__conv__`, `__conv_form__`, `__type_import__`, a basic/this-package type's own name (e.g. `int`), `__ty_*` (Composite constructors), `__lit_type__`, `__lit_field__`, `__builtin_const__`, `__enum_value__`, `__val_range__`, `__ref_as__` (Pass as / Assign to), `__index__`, `__rename__`, `__num_key__`, `__decl_form__`, `__br_variant__` (type-switch case), `__arg_row__` (Join with previous row / Own row), `__stmt_assign_op__` / `__stmt_ctx_assign__` (Assignment group), and the refusable options markers `__loop_opt__`, `__br_opt__`, `__ctrl_menu__`.
- **Type_Cat**: `Unknown, Any, Integer, Float, Rune, Bool, String, CString, CString16, Pointer, Slice, Array, Map, Proc, Struct, Enum, Union, BitSet, Typeid, Multi`. Builtins: all int widths and endian variants, `uintptr` and `byte` are Integer. `f16/f32/f64`, the endian floats, complex and quaternion types are Float. `rune` is Rune. `bool`/`b8..b64` are Bool. `string`/`string16` are String. `cstring` is CString, `cstring16` is CString16, `rawptr` is Pointer, `typeid` is Typeid and `any` is Any.
- **Resolved_Type** `{cat, canon}`; **Type_Ctx** (per-build memo plus an import alias map).
- **Var_Type** `{expr, pkg}`; **Struct_Field** `{name, type: Var_Type, promoted}`.
- **Call_Sig** `{req, variadic, params: []Param, ret, pkg, known}`; **Param** `{name, type, optional, variadic}`. `ret` is `""` for "returns nothing" and `"?"` for unknown.
- **Ref_Target** `{ni, fi}`; **Ref_Scope** `{at, start, visible[], top[], procs}`; **Rename_Hit** `{ni, fi}`; **Iter_Kind** `Unknown, None, Array, Slice, Dynamic, Map, String, Range`; **Op_Class** `Bitwise, Shift, Arith, Modulo, Compare, Logic, Choose`; **Builtin_Const** `{name, type, cat, common}`; **Builtin_Arity** `{name, req, variadic, ret}`.
- **App state for this area**: `slot_ni/slot_fi/slot_menu` (the dot being filled), `ref_pick_active`, `ref_pass_active`, `ref_ni/ref_fi`, `refill_active`, `refill_saved`, `refill_ni/fi`, `change_call`, `decl_form_active`, `rename_active`, `rename_old/new/hits`, `assign_pick_new`, `replacing`, `hint_pool`, `notice`.
- **Generated tables** (built from the Odin install by tools/gen_core_procs.py; doc 07): `CORE_PROCS {path, file, block, name, req, variadic, params, ret}`, `CORE_TYPES {path, file, kind (struct/enum/union/bit_set/bit_field/distinct/alias), name, target}`, `CORE_CONSTS {path, file, name, kind (#int/#float/#string/#rune/#bool/type/?)}`, `CORE_FIELDS {path, type_name, name, type, using_field}`, `CORE_ENUM_MEMBERS {path, type_name, name}`. CORE_TYPES (~14k rows) and CORE_FIELDS (~29k rows) lookups go through lazily built, process-lifetime hash indexes (`core_type_index`: `path|name` → first row; `core_field_range`: `path|type_name` → row range). CORE_PROCS, CORE_CONSTS and CORE_ENUM_MEMBERS are scanned linearly per lookup. A polymorphic struct row has its parameter list in `target` (e.g. `($T: typeid)`); plain structs have `target == ""`. Example rows: `{"core:sys/windows", "types", "distinct", "HWND", "HANDLE"}`, `{"core:sys/windows", "util", "", "L", 1, false, "value: string", "cstring16"}`, `{"core:strings", "strings", "", "clone", 1, false, "s: string, allocator := context.allocator, loc := #caller_location", "(res: string, err: runtime.Allocator_Error) #optional_allocator_error"}`.
- **Persisted**: nothing specific to this area. The heatmap of menu use is doc 03 (F13-F14).

## Tests that pin this behavior

| Test (file) | Asserts |
|---|---|
| `test_messageboxw_dots_know_their_types` (typecheck_test.odin) | `MessageBoxW` gets 4 dots hinted `HWND, LPCWSTR, LPCWSTR, UINT`, with pkg `core:sys/windows` |
| `test_resolve_windows_types` (typecheck_test.odin) | Alias/distinct chains: LPCWSTR→CString16, HWND→Pointer with nominal canon, UINT→`u32`, BOOL→Bool, `win.RECT`→Struct, unknown→Unknown |
| `test_lptext_grays_out_bool_and_number` (typecheck_test.odin) | On LPCWSTR: true/false/Number gray; String, nil, Reference, Call lit; `L` lit; `MessageBoxW` gray (INT); no-return gray; proc group lit; Type gray |
| `test_hwnd_and_uint_slots` (typecheck_test.odin) | HWND: nil lit, string/number gray, `CreateWindowExW` lit, `GetModuleHandleW` gray (distinct); UINT: rune lit, string/nil gray |
| `test_println_any_grays_nothing` (typecheck_test.odin) | On `..any`, Number, String, true, nil and the Call group stay lit (calls returning nothing, e.g. `assert`, are still gray; probe); the next variadic dot keeps the hint `any` |
| `test_local_proc_params_have_types` (typecheck_test.odin) | Calls to this file's procs get typed dots |
| `test_constants_and_operators_are_grayed_by_type` (consts_test.odin) | Untyped `#int` fits UINT; `a == b` gray on UINT; Bitwise/Arithmetic gray on LPCWSTR, Choose lit; HANDLE constant gray on HWND |
| `test_used_constant_is_pinned_first` (consts_test.odin), `test_used_import_type_is_pinned_first` (types_menu_test.odin) | Used names come first |
| `test_expr_ternary_built_from_menus` (expr_test.odin) | Ternary hints `u32,bool,u32`; Y and LT+B on parts keep types; round-trips; `odin check` passes |
| `test_expr_convert_built_from_menus`, `test_expr_convert_load` (expr_test.odin) | Convert forms list; expected type pinned first; distinct types gray; Y retypes keeping the value; LT+B unwraps; loaded `Meters(f)` is a conversion |
| `test_expr_number_keypad` (expr_test.odin) | Keypad dims and edits to `0x00FF0062` |
| `test_reference_picks_a_name_from_the_file`, `test_reference_cancel_leaves_dot_empty`, `test_reference_via_y_refill`, `test_reference_dimmed_without_names` (ref_pick_test.odin) | Start position, D-pad semantics, Pass as, B behavior |
| `test_pass_as_converts_for_messageboxw` (ref_pick_test.odin) | Exact Pass as labels; `&` gray for LPCWSTR |
| `test_fix_reference_scope` (branch_loop_fixes_test.odin) | Case clauses, other procedures, ended blocks, later locals are hidden |
| `test_type_text_here`, `test_pass_as_maybe_pointer` (type_text_test.odin) | Spelling expected types in this file's import names |
| `test_field_menu_gray_out`, `test_loaded_field_path_is_one_unit`, `test_assignment_to_a_field`, `test_var_types` (field_access_test.odin) | Field menus and grays, field-path typing, assignment hints, every declaration form's type |
| `test_assignment_picks_a_declared_name`, `test_assignment_cancel_takes_the_line_away` (assign_pick_test.odin) | Only assignable names; B removes the new line |
| `test_fix_assign_ops` (branch_loop_fixes_test.odin), `test_loops_compound_assignment` (loops_test.odin) | Operator dims per type; current operator dim; `Assign to` dims a target that can't take the operator |
| `test_fix_unroll_constants`, `test_fix_when_condition` (branch_loop_fixes_test.odin) | Constness dims; `Add #unroll` refused over a non-constant range/string; `ODIN_OS` gray in a `when` condition |
| `test_fix_enum_array_index_key` (branch_loop_fixes_test.odin) | `index_types` of `[Dir]f32` / `[N]int` / `[4]int`; `arr[●Dir]` key typing and Enum value → `y = arr[.North]` |
| `test_messageboxw_with_or_of_constants` (consts_test.odin) | `a \| b` on UINT gives two UINT dots; the full `win.MessageBoxW(nil, "", win.L(""), win.MB_OK \| win.MB_ICONINFORMATION)` |
| `test_parse_params` (typecheck_test.odin) | Parameter-list parsing: grouped names, `#any_int`, defaults, `..any` |
| `test_loaded_names_are_pickable`, `test_reference_reaches_typed_unindented_local` (ref_pick_test.odin) | Candidate list and order; Up/Down between lines |
| `test_enum_values` (ctrl_test.odin), `test_branch_switch_value_cases` (branch_test.odin) | Enum members from this file, a package, or compiler enums; comparison-side enum; case dots typed |
| `test_rename_constant_everywhere`, `test_rename_local_respects_scope_and_shadowing`, `test_rename_parameter_and_decline`, `test_rename_no_prompt_for_a_use`, `test_code_word_hits` (rename_test.odin) | Prompt labels, scope, shadowing, strings and comments untouched |

The pattern to copy: drive the pure model with abstract inputs (`update(app, Input{confirm=true})`, `pick(label)`), assert menu labels and `dim` flags, and assert the exact resulting source. Then reload it and compare, and run the real compiler on the output (doc 11).

## Carrying this to Rust

**(a) What transfers unchanged**
- The whole interaction contract. Every hole carries an expected type. The menu for a hole is `f(position, expected type, names in scope, dependencies, sibling modules, const-context)`. Gray means "won't fit" but stays pickable, while Unknown never grays. A group is gray iff nothing inside fits. The expectation is shown on the hole and under the menu title.
- The menu taxonomy: literals, Reference, Call, Struct literal, Constant, Enum value, Operator, Choose, Convert, Type, Range. The "used in this file" pins, stable grouping, and sorting past 12 entries.
- Reference as an in-file D-pad pick over in-scope names, then a typed "Pass as" adapter menu, with B stepping back one stage at a time.
- Y refills a part typed for its position and B restores it exactly. LT+B leaves a typed hole, and LT+B on a hole collapses the enclosing operator.
- Rename-with-propagation as a prompt (`Rename all N uses` / `Only this one`), scope-correct.
- Constness, operator-per-type rules, and the round-trip and compile tests.

**(b) Odin-specific pieces and their Rust analog**

| Odin (Doodle) | Rust |
|---|---|
| Type_Cat by text + CORE_* tables | rust-analyzer types (`hir::Type`): ADT/struct/enum/union, scalar, ref/ptr, slice/array, tuple, fn/closure, `dyn`/`impl Trait`, generic param, never, unit |
| `distinct T` (nominal) vs alias (transparent) | newtype `struct M(f64)` (nominal) vs `type A = B;` (transparent) |
| Untyped constants (`0` fits f32, rune fits int) | Literal inference: `{integer}` fits any integer type, `{float}` any float; an integer literal does **not** fit `f32`, and `'c'` is only `char`. `"s"` is `&'static str` and does not fit `String`, so offer `String::from("…")`, `"…".to_string()` or `.into()`; it does fit `&str`, `impl AsRef<str>` and `impl Into<String>`. `b'a'` is `u8`, `b"…"` is `&[u8; N]`. Coercions matter for "fits": `&String` → `&str`, `&Vec<T>` → `&[T]`, `&mut T` → `&T` (deref coercion), `!` → anything. |
| `nil` | `None` (Option), `std::ptr::null()` / `null_mut()` (raw pointers); no null references |
| `T(x)`, `cast(T)x`, `transmute(T)x`, `auto_cast x` | `T::from(x)` / `x.into()` (From/Into), `x as T` (primitive casts only: numeric ↔ numeric, `bool`/`char` → integer, `u8` → `char`, fieldless enum → integer, raw pointer ↔ raw pointer / `usize`, `&T` → `*const T`, fn item → fn pointer), `T::try_from(x)?` / `.try_into()`, `unsafe { std::mem::transmute::<_, T>(x) }` (put it in a gray-by-default "unsafe" group) |
| `a if c else b` / `c ? a : b` | `if c { a } else { b }`; `a when c else b` → `if cfg!(…) { a } else { b }` (note: both branches must still type-check in Rust; for code that only exists on one target use `#[cfg(…)]` on items/statements) |
| `when` (constant condition) | `#[cfg(…)]` / `cfg!(…)`. The constness analog is any const context: `const`/`static` items, array lengths `[T; N]`, const generic args, `match` patterns. In these, gray calls to non-`const fn`s and non-const names. |
| `#unroll for` | none (the optimizer unrolls); keep the generic "constant-only hole" mechanism for const contexts |
| Compound ops by category | `+=` etc. fit iff the target implements `AddAssign<Rhs>`, `SubAssign`, `MulAssign`, `DivAssign`, `RemAssign`, `BitAndAssign`, `BitOrAssign`, `BitXorAssign`, `ShlAssign`, `ShrAssign`, **and** the target is a mutable place (a `let mut` binding, a field of one, or `*r` for `r: &mut T`). Plain `=` also needs a mutable place (or a `let x;` assigned once). Rust has no `&&=`, `\|\|=`, `%%=` or `&~=`. `String += &str` is valid (`AddAssign<&str>`), unlike Odin. |
| Operators by category | By trait: `std::ops::{Add, Sub, Mul, Div, Rem, BitAnd, BitOr, BitXor, Shl, Shr, Neg, Not}`. `==`/`!=` need `PartialEq<Rhs>`, ordering needs `PartialOrd<Rhs>`. `&&`/`\|\|` are not overloadable and take only `bool`. `^` is xor and `!` is both logical and bitwise not. There is no `&~` (write `a & !b`). |
| `.North` enum value, `{.A}` bit_set | `Dir::North` (or `use Dir::*`); tuple and struct variants make sub-holes: `Some(●)`, `Ok(●)`, `Shape::Circle { r: ● }`. Bit sets come from the `bitflags`/`enumset` crates (`Flags::A \| Flags::B`). |
| `T{field = ●}` | `T { field: ●, … }`. Unlike Odin (where omitted fields are zero), a stable-Rust struct expression must set **every** field unless it ends with `..base` (e.g. `..Default::default()` when `T: Default`); a bare `..` is pattern syntax (struct-expression `..` with default field values is an unstable feature). So the "add field" hole must keep the literal marked incomplete until all fields are set, or offer `..Default::default()`. Fields not visible from this module (`pub`) can't be set at all. Also tuple structs `T(●, ●)`, field-init shorthand `T { x }`, and constructors `T::new(●)` |
| `&x`, `x^`, auto-deref on fields | `&x`, `&mut x`, `*x`; field access auto-derefs (through `&`, `Box`, any `Deref`); method calls auto-ref *and* auto-deref the receiver |
| `v, ok := m[k]`, `x.(T)` | `if let Some(v) = m.get(&k)`, `if let Enum::V(v) = x` / downcast |
| `or_return` | `?` (as a Pass as adapter when the name is `Result`/`Option` and the fn returns a compatible one) |
| Variadic `..any` (fmt.println) | Rust has no variadics except macros: `println!("{}", ●)`, `format!`, `vec![●, ●]`. Keep the repeating green argument hole for macro args. |
| Multi-return `(a, b)` and capture | Tuples: `let (a, b) = f();` |
| `ODIN_OS`, `ODIN_DEBUG` | `cfg!(target_os = "…")`, `cfg!(debug_assertions)`, `std::env::consts::OS`; associated consts (`i32::MAX`, `u8::BITS`) and module consts (`std::f64::consts::PI`; `f64::consts::PI` without `std::` does not resolve) |
| Import alias `win.` | Paths and `use` items. Menus group by crate (Cargo.toml dependencies + std/core/alloc) and module. Picking an un-`use`d item inserts the `use` or a qualified path. |
| Sibling files of a package | The module tree: same-module items are visible; other modules need `crate::`/`super::` paths and `pub` visibility |
| `odin check` | `cargo check --message-format=json` |

**(c) Rust concepts this area will need that Odin lacks**
- **Methods and traits**: the single biggest addition. Pass as gains a `Method of x` group: inherent and trait methods whose return type fits, with receivers auto-ref'd and auto-deref'd and argument holes typed. Expected types can be bounds (`impl Into<String>`, `T: Display`): "fits" means "implements". Methods from traits not in scope should appear in a separate, marked group, and choosing one adds the `use`.
- **Ownership and borrowing**: Pass as offers `x`, `&x`, `&mut x`, `x.clone()` (if Clone), `*x` (if Copy behind a reference), `x.as_ref()`, `x.as_str()`, `&x[..]`, `x.iter()`. Gray `&mut x` when `x` isn't `let mut`, and offer "make it mut" as a fix. Gray a name used after a move where the analyzer or `cargo check` can tell.
- **Option/Result**: adapters `Some(x)`, `Ok(x)`, `x?`, `x.unwrap()`, `x.expect("…")`, `x.unwrap_or(●)`, `x.ok_or(●)`; the Enum value group lists `None`, `Some(●)`, `Ok(●)`, `Err(●)` when the expected type is Option/Result.
- **Pattern matching**: match-arm holes list the variants not yet covered (the analog of gray used case values), with `_` last; destructuring patterns get typed sub-holes.
- **Closures**: when the expected type is `Fn*`/`impl FnMut(A) -> B`, offer `|a| ●` with the parameter typed and the body hole expecting `B`.
- **Generics and lifetimes**: generic params and lifetimes in scope join the Type menu (as Doodle does for `$T`).
- **Macros**: a `Macros` subgroup in Call (`println!`, `format!`, `vec!`, `assert!`, `assert_eq!`, `write!`).
- **Derives and attributes**: whether an operator fits can depend on `#[derive(PartialEq, Clone, Copy, Default)]`; when it is the only reason a choice is gray, offer to add the derive.
- **async**: `.await` adapter for futures inside `async fn`.
- **Iterators**: iterable holes fit `IntoIterator` types. Adapters `.iter()`, `.iter_mut()` / `&mut v` (the analog of `for &x in`), `.into_iter()` (consumes, moves the collection), `.enumerate()` (the analog of `for x, i in`, but it yields `(i, x)`: index first), `.rev()` (`#reverse`; needs `DoubleEndedIterator`, so not on a `HashMap`), and ranges `a..b` / `a..=b`. Map iteration yields `(k, v)` tuples, so the loop pattern hole becomes `(k, v)`.

**(d) Implementation advice**
- Use rust-analyzer as the type oracle: embedded via the `ra_ap_*` crates (`ra_ap_ide`, `ra_ap_hir`), or spoken to as an LSP server. Embedding gives direct access to what Doodle computes by hand. Its completion engine already derives an expected type and name for a position (`CompletionContext::expected_type` in `ide-completion`; from memory this struct is crate-private, while the public `CompletionItem` relevance carries a type-match flag (`CompletionRelevance::type_match`: exact / could-unify); verify against the pinned version). `hir::Semantics` gives the scope at a node (`Semantics::scope` → `SemanticsScope::process_all_names`), which is all names visible there (locals, params, items, generic params, `use`d names) with shadowing done right. `hir::Type` has unify and coerce checks (`could_unify_with`, `could_coerce_to`), field listing, method iteration and trait-implementation queries (`impls_trait`). These names are from memory and the `ra_ap_*` API changes between releases (recent versions add a lifetime parameter to `Type`), so pin a version and check every name. Over plain LSP you only get type-match indirectly, through completion sort order (and types through hover / inlay hints).
- Define a small `TypeOracle` trait so the UI never depends on rust-analyzer directly and tests can use a fake:

```rust
enum Fit { Yes, No, Unknown }                         // Unknown => never gray
trait TypeOracle {
    fn expected_at(&self, hole: HoleId) -> Option<Ty>;
    fn names_in_scope(&self, hole: HoleId) -> Vec<ScopeName>;   // file order, with decl site
    fn fits(&self, value: &ValueChoice, expected: &Ty) -> Fit; // literal / call / path / adapter
    fn fields(&self, ty: &Ty) -> Vec<(String, Ty)>;
    fn methods(&self, ty: &Ty, hole: HoleId) -> Vec<MethodInfo>;
    fn implements(&self, ty: &Ty, trait_path: &str, args: &[Ty]) -> Fit;
    fn in_const_context(&self, hole: HoleId) -> bool;
    fn is_const(&self, choice: &ValueChoice) -> Fit;
}
fn build_fill_menu(o: &dyn TypeOracle, hole: HoleId) -> Menu { /* F1 pipeline */ }
```

- Keep Doodle's degradation rule: while rust-analyzer is still loading or fails on a file, every query returns Unknown and the editor stays fully usable with nothing grayed.
- Build big lists lazily (per opened submenu) and memoize per menu build. Doodle needed hash indexes and lazy Convert lists to keep opening a dot instant, and a crate graph is far larger than Odin's core tables.
- Use a real syntax tree (tree-sitter-rust or rust-analyzer's own `syntax` crate) for positions and holes instead of Doodle's brace-depth line walk. The F15 scope walk exists only because Doodle has no AST; rust-analyzer's scopes replace it.
- Use rust-analyzer's rename (scope- and shadowing-correct, workspace-wide) but keep the prompt. Default to the open file and offer "also N uses in other files" as a separate option, since Doodle never touches other files silently.

## Open questions & known gaps

1. **Types declared in the document or sibling files never gray anything.** `resolve_type` returns Unknown for them ("a type declared in this document: not analysed (never grayed)"). A dot expecting `Meters :: distinct f64` or `Id :: u32` grays no literal or call. Fields, struct-literal pins, enums and index types for such types do work through other paths (`struct_fields`, `enum_members`, `index_types`, `enum_index_type`).
2. **`#optional_*` multi-results look like Multi to `ret_fits`** (confirmed by probe). `strings.clone`'s table return is `(res: string, err: runtime.Allocator_Error) #optional_allocator_error`; `resolve_uncached` strips the first and last characters and splits at top-level commas, gets two parts, and returns Multi, so `strings.clone` is gray on a `string` dot. Meanwhile `call_ret_text` (variable typing) takes the first result: `expr_type_at("strings.clone(s)")` is `string`. Same for every `(T, bool) #optional_ok` proc. Inconsistent and unpinned; in Odin such a call *can* be used as a single value, so the gray is a false "won't fit".
3. **`collect_called_procs` pins bogus leaves** (confirmed by probe). Per line it takes the text between the *first* `ref.` and the next `(`, with no identifier, word-boundary or string/comment check. `x := win.MB_OK + int(win.GetLastError())` pins `MB_OK + int`; `h: win.HWND = win.GetActiveWindow()` pins `HWND = win.GetActiveWindow`. The real call on such a line is never pinned, `mywin.f(` also matches `win.`, and picking a bogus leaf would insert `win.MB_OK + int(●)` as a "call". Such leaves have return text `""` (RET_NONE), so they are at least gray on typed dots. Use real call sites.
4. **Built-in procedures have no parameter types**, so `len(●)` and `append(●, ●)` take anything, and most built-in returns are `?`, so they never gray.
5. The bare `name` in Pass as is never type-grayed, and Reference candidates are filtered by scope only, never by type.
6. `ref_scope_visible` treats every name on the dot's own line as visible (`if ni == s.at do return true`). That is what lets a C-style loop's condition and post (`for i := 0; i < ●; ...`, also gated by `loop_name_visible`) and an if/switch setup's condition (`if v := f(); v > ●`) see names declared earlier on the same line. The side effect: a declaration's own name is offered to its own initializer. At `x := y` the candidates are `main y x` (probe), so `x := ●` offers `x`, which doesn't compile unless an outer `x` happens to exist. The correct rule: on the dot's own line, only names declared in an earlier clause of the same header.
7. **`rename_scope` is too wide for loop / if / switch header names** (confirmed by probe). It uses `construct_range`, the whole top-level construct (the procedure), while the comment says "that block". With a global `i := 7` and, inside `main`, `a := i` followed by `for i in 0..<3 { b := i }`, renaming the loop's `i` counts both `a := i` (the global, before the loop) and `b := i`, so "Rename all" would wrongly rewrite `a := i`. The reverse failure: with a local `i := 7` declared before the loop in the same procedure, the scan meets that line first, treats it as a shadowing redeclaration whose reach is the rest of the procedure, and finds 0 uses, so renaming the loop variable gives no prompt and its uses inside the loop keep the old name (probe). Parameters are fine (their construct really is the procedure).
8. Local `N :: 3` constants inside a procedure load as plain text and aren't offered by Reference (stated in `test_fix_unroll_constants`).
9. `enum_members` doesn't follow alias or distinct rows to an enum (only `bit_set_elem` does), so a hint that aliases an enum may show `(no enum type here)`.
10. `ctrl_entry_fits` lets any enum-typed built-in constant fit any enum slot (`ODIN_OS` on an `Odin_Arch_Type` dot is lit).
11. **Composite identity is textual, which produces false grays.** `[]u8` vs `[]byte` differ; `^RECT` written in two different packages compares equal; and the same pointer type spelled from two places differs: a this-file proc returning `^win32.RECT` is gray on `InvalidateRect`'s `^RECT` dot (canon `^win32.RECT` vs `^RECT`; probe). This breaks the "uncertainty is permissive" rule. A real type system (rust-analyzer) avoids it.
12. `apply_fit_dims` runs after `loop_extend_value_menu`/`unroll_extend_value_menu` and would overwrite their dims if an iterable dot ever carried a hint. `RANGE_FILL` isn't in `entry_fits`, so it would be treated as a type name (gray) if such a hinted pass ran. Harmless today (iterable and range-end dots have no hint) but fragile.
13. "Change procedure" (Y on a call's name) doesn't gray procs by return type, even when the call is an argument with a known expected type.
14. `path_for_ref` consults the document's import aliases even while resolving text written inside a library package, so a document alias that collides with a core package's last segment could misresolve.
15. docs/UX.md (draft) planned to use `ols` (the Odin LSP) for symbols, scopes and rename ("This leans on `ols` (LSP) to know where functions, structs, and scopes are"; "Cursor on symbol -> Y (palette) -> rename -> dictate new name -> LSP applies"). The code instead implements its own text-based scope walk and table-driven resolver, which superseded that plan. For Rust, using rust-analyzer is the natural return to the LSP-backed plan.
16. `resolve_uncached` classifies by text prefix before looking names up, so a named type starting with `proc`, `struct`, `enum`, `union`, `bit_set`, `map[` or `matrix[` (e.g. a lowercase `procedure_info`) gets the wrong category.
17. **Picking a new `x <<= ●` / `x >>= ●` statement's target types the value dot with the target's type** (confirmed by probe: `flags: u32` gives hint `u32`). `set_assign_target` doesn't look at the operator, while `set_assign_op` (Y on the operator) and `rhs_expected` (Y-refill) correctly leave a shift amount untyped. The effect: on a `u8` target, a call or constant typed as another integer type is grayed although the shift amount doesn't need the target's type (advisory only; it can still be picked).
18. `operand_enum_type` (Enum value next to `==`) finds the first `name: T` anywhere in the document, not the declaration in scope at the dot, so a shadowed name can give the wrong enum.
19. Some parts of the model's own comments are stale: change.odin's header says Change procedure keeps the arguments (it replaces them), and ref_pick.odin's header says `windows.L` returns a `[^]u16` (the current table says `cstring16`). Trust the code.
20. **Reference offers number literals and duplicate loop names** (confirmed by probe; F15). Any editable
    kind-`""` field counts as a name, so menu-built, keypad-edited or dictated numbers (`0`, `25`) and the editable
    `0` / `1` of a menu-built C-style loop header are candidates, and a C-style loop variable is listed twice
    (init and post). This also resolves doc 05's open question about C-style header literals.

# Doodle — Editor Model (Projectional / Structured)

> MAJOR DESIGN DECISION: Doodle is **not** a free-text code editor. It is a
> **projectional (structured) editor**: you build an Odin program by inserting
> and configuring *nodes*, not by typing characters. The textual Odin source is
> a *rendering* of the underlying structure (and what we ultimately save/compile).
>
> This is what makes **gamepad-only authoring** feasible: there is no need to
> type most of the program — you pick constructs from menus and tweak values.

## 1. Guiding principles

1. **Gamepad-only authorable.** A complete, compilable program can be created
   without a keyboard.
2. **Everything has a default.** Inserting any construct yields valid Odin
   immediately — no empty required fields.
3. **Names are generated, not typed.** Identifiers default to
   `adjective_animal` (e.g. `brave_otter`, `calm_lynx`). You only name things
   when you *want* to — highlight a name and change it (voice or on-screen kbd).
4. **Insertion points are explicit.** A **glowing green dot** marks every place
   you can add something. Press **A** on a dot to open a **radial menu** of
   constructs valid at that location.

## 2. Insertion points — the "green dot"

- A green dot sits at every valid insertion slot (top of file, inside a struct
  body, inside a proc body, between statements, etc.).
- The dot **glows/pulses** so it's obvious.
- **A** on a dot opens the **radial menu** (see §3).
- After inserting a node, new green dots appear wherever further insertion is
  valid (e.g., inside the new proc body, after the new declaration).

### 2.1 Attribute dots (purple)

A **purple dot** sits above every procedure declared at file scope (also inside
a file-scope `when`), above its `@(...)` lines if it has any, just right of the
green dot on that boundary. The D-pad stops on it between the green dot and the
procedure. **A** on it opens that procedure's **Attributes** menu (the same one
Add > Modifiers > Attributes opens; only attributes valid for it are offered,
impossible ones are grayed). src/model/attr_dots.odin.

**test** makes the procedure a unit test for `odin test .` (a Run command):
it adds `@(test)`, adds `import "core:testing"` if the file doesn't import it
(an existing alias is used: `^tst.T`), and gives a procedure without parameters
an editable `t: ^testing.T`. It is grayed for procedures that return something
or take other parameters.

## 3. Radial menu taxonomy

Top-level radial options (context-filtered to what's valid at the dot):

```
            ( Procedure )
                  |
( Types ) ---  (DOT)  --- ( Dependencies )
                  |
            ( File Setup )
                  |
            ( Values )
```

Each opens a sub-radial. Full taxonomy (functionality stubbed until scheduled):

### 3.1 File Setup
| Item | Example | Notes |
|------|---------|-------|
| Package declaration | `package main` | Required, must come first. Auto-added. |
| File tags | `#+build linux`, `#+private`, `#+feature dynamic-literals`, `#+ignore` | Above package; control platform build / visibility / optional features. |
| Comments / doc comments | `// ...`, `/* ... */` | Comment directly above a decl is its doc. |
| Blank line | | Spacing the formatter keeps (e.g. before a commented declaration). |

Comments and blank lines work inside procedures too (statement menu > **Layout**
> Comment / Blank line). A comment's text is an editable field filled by
dictation as free text (backticks, apostrophes, braces are just text); loaded
`// ...` lines get the same field. LT+B on a comment deletes it; LT+B on the
green dot next to a blank line deletes the blank line. format_doc keeps single
blank lines between statements, but not just after `{` or before `}`.
Y on an argument of a call saved one argument per row offers **Join with
previous row** / **Own row** (`nil, nil, instance, nil,` rows; src/model/stmt_layout.odin).

### 3.2 Dependencies
| Item | Example |
|------|---------|
| Import | `import "core:fmt"` |
| Aliased import | `import str "core:strings"` |
| Foreign import (C lib) | `foreign import libc "system:c"` |
| Foreign block (C procs) | `foreign libc { puts :: proc(s: cstring) -> i32 --- }` |

Import and Aliased import open the same package tree: **core** (standard library),
**base** (intrinsics, runtime, sanitizer; `base:builtin` only documents the
predeclared names and is not importable), **vendor** (sdl2, OpenGL, vulkan,
raylib, directx, stb, ...; packages for another OS are hidden) and **shared**
(the sub-folders of `<Odin root>/shared` that hold `.odin` files, listed when the
menu opens; a dimmed placeholder when there are none). The core/base/vendor rows
and the procedure, type, constant, struct-field and enum-member tables are
generated from the Odin install by `tools/gen_core_tree.py` and
`tools/gen_core_procs.py` (into `src/model/core_*.odin`). Packages whose folder
name isn't an identifier (`vendor:lua/5.4`) are always inserted with a name:
`import lua "vendor:lua/5.4"`.

### 3.3 Procedures (behavior)
| Item | Example |
|------|---------|
| Procedure | `do_thing :: proc(x: int) -> int { return x }` |
| Procedure group (overload) | `print_any :: proc{print_int, print_string}` |
| Polymorphic procedure | `max_of :: proc(a, b: $T) -> T { ... }` |
| Procedure type | `Callback :: #type proc(x: int)` |

### 3.4 Types (data shapes)
| Item | Example |
|------|---------|
| Struct | `Player :: struct { hp: int }` |
| Polymorphic struct | `Stack :: struct($T: typeid) { items: [dynamic]T }` |
| Enum | `Dir :: enum { North, South }` |
| Union | `Shape :: union { Circle, Square }` |
| Bit set | `Flags :: bit_set[Dir]` |
| Bit field | `Packed :: bit_field u32 { a: u8 | 4 }` |
| Distinct type | `Meters :: distinct f64` |
| Type alias | `Grid :: [8][8]int`, `Lookup :: map[string]int` |

Inside a struct / enum / union / bit_field body the green dots offer members
(Field, Using field / Member, Member = value / Variant / Field `name: T | bits`)
instead of statements. Every Type menu has a **Composite** group (`[N]T`, `[]T`,
`[dynamic]T`, `map[K]V`, `^T`, `[^]T`) whose parts are dots again, so types nest;
inside a polymorphic struct its `$T` parameters are offered as types. Y on a type
inside a composite also offers "Drop [8]" etc. to unwrap it. (src/model/data_types.odin)

**The package's other files.** An Odin package is a whole folder, so the
`.odin` files next to the open one (next to `main.odin` in the project folder
for an unsaved document) are read whenever the open file changes
(src/app/save.odin `refresh_siblings` -> `model.load_siblings`; files over 1 MB
are skipped; never on the per-frame path). Their procedures (signature lines)
appear under Calls > "Internal procedure" and type the call's dots. Their
file-scope types are parsed with the editor's own parser and kept as text
(src/model/siblings.odin): structs, enums, unions, bit_fields, bit_sets,
distinct types, aliases and `#type proc` aliases. They behave like this file's
types, in the same menu sections and inserted by bare name (`point{●}`,
`p: point`, no import): Type menus (Fill > Type, Convert, bit_set[...]), the
Struct literal list (polymorphic structs excluded) and its fields dot, member
access (Reference > Field of p, typed hints `x   f32`), Enum value menus and
switch cases, type-switch variants, aliases followed by loops / enumerated
arrays / indexing, and `Alias :: point` in this file reads as a type alias.
This file's declarations come first: a same-named type here shadows the
sibling's. `@(private="file")` declarations and files tagged `#+private file`
are invisible to other files; `@(private)` / `#+private` (package-private) ones
are visible. Sibling files are read-only here: rename, go-to and data-member
edits only touch the open file, and generated names avoid the siblings' names.

### 3.5 Values
| Item | Example |
|------|---------|
| Constant | `MAX_HP :: 100` |
| Typed constant | `MAX_HP : int : 100` |
| Build-config constant | `DEBUG :: #config(DEBUG, false)` |
| Global variable | `score: int` or `score := 0` |

### 3.6 Expressions (value dots)
| Menu | Builds | Notes |
|------|--------|-------|
| Operator > Choose > `a if c else b` | `● if ● else ●` | also `c ? a : b`, `a when c else b`; branches expect the dot's type, the condition a bool |
| Convert > T(x) > *type* | `T(●)` | the dot's expected type is pinned first; types that can't produce it are grayed |
| Convert > cast(T)x / transmute(T)x > *type* | `cast(T)●` | Y on `cast(T)` / on T of `T(x)` picks another form or type, the value is kept |
| Convert > auto_cast x | `auto_cast ●` | |

An operand of an operator can be an operator again (`a | b | c`). Y on a part
refills it (typed for its position); LT+B on a part turns it into a dot, on such
a dot the whole operator / ternary / conversion becomes one dot (in a chain of
3+ operands, `a | ● | c`, just that operand and one operator go); LT+B on the type
of a conversion unwraps the value. A loaded `T(x)` is a conversion when T names
a type (core/vendor tables, this package's types and aliases, builtin types); its
value's type is T. LT+A on a number opens a keypad (digits, A-F, `0x`, `.`, Del) so
`0x00FF0062` needs no keyboard. (src/model/expr.odin)

LT+A on a name, a string or a comment opens text tools for what dictation can't
say: Case (snake_case, UPPER_SNAKE, Ada_Case, camelCase, PascalCase; Joined for
strings), Escape (`\n`, `\t`, ... appended to a string), and for comments Word
case (one word UPPER / Capitalized / lower) and Backticks (wrap words in
`` `...` ``). (src/model/text_tools.odin)

A save (src/app/save.odin) writes model.file_text: formatted, without the
editor-only "●" statement lines next to real statements, and ending in a newline
unless the opened file had none.

### 3.7 Menu heatmap (worn borders)

Menus remember what you use, globally (every project): each time a menu leaf
is really used (a constant inserted, a statement added; not opening a submenu, a
placeholder, a grayed option its menu refuses, keypad keys or a Convert form;
leaves grayed only by type fitting still apply, so they count), every menu cell on the way
to it gets one more use, and the radial menu draws used cells with a warm
graphite "smudge" border that darkens with use (alpha and width grow; recent /
selected cells get it as a ring just outside their own outline). After using
`Fill slot > Constant > win. > window_messages > WM_ > WM_SIZE`, the same trail
looks worn next time in any file. (src/model/heat.odin, drawn in src/app/main.odin)

- **Key**: the chain of entries chosen from the root menu's entry down to the
  cell, without the root menu's title (`Fill slot > Type` and `Edit Type > Type`
  share heat). A segment is the entry's `heat_key` when set, else its label.
  Import package groups are labeled with the file's alias (`win.` / `windows.`),
  so their `heat_key` is the import path (`core:sys/windows`) and heat is shared.
  Other `heat_key`s: alpha buckets (all labeled `w` inside `WM_...`) use their
  first..last names; alias-qualified pins (a struct literal's / conversion's
  expected type, `win32.HWND`) use `<import path>.<Name>`; enum values include
  their enum (`core:sys/windows.SHOW_WINDOW_CMD.None`); the statement menu's
  "Calls" shares the value menu's "Call". "Change procedure" lists one import's
  procs at its root, so its keys start with `Call > From import > <path>`
  (MenuView.heat_root).
- **Same trails everywhere**: an import's procs / constants / types are grouped
  from the package's full name list and the names used in this file are then
  taken out (they're pinned at the top), so the groups don't depend on the file.
- **Pinned shortcuts**: a "used in this file" leaf listed at the package level
  also wears its real home (`win. > window_messages > WM_ > WM_SIZE`), the trail
  a project that doesn't use it shows (also for Convert's type lists).
- **Shade**: `log(1+uses) / log(1+HEAT_SATURATE)`, clamped to 0..1 (40 uses = fully worn).
- **File**: `doodle_heat.tsv` next to `doodle.exe` (the exe folder, from the OS),
  loaded at startup (missing = no heat), saved a moment after a use (at most every
  2 s) and at quit. A save re-reads the file and adds this session's unsaved uses
  (so several Doodles running at once don't erase each other's heat), writes `.tmp`
  and renames it over; a failed save is retried. A file that exists but can't be
  read, or has another format version, is never overwritten. Format: a `doodle-heat 1`
  header, then one sorted line per key: `<count>\t<segment>\t<segment>...` (tab-separated).
  Malformed lines are ignored, duplicate keys summed; beyond 20000 keys the
  least-used are dropped on save. Delete the file to reset the heat.

## 4. Name generation

- Adjective list + animal list -> `adjective_animal`, snake_case (idiomatic Odin).
- Collision handling: append `_2`, `_3`, ... if generated name already used.
- Type names get PascalCase variant (`BraveOtter`) where Odin convention wants it
  (structs/enums/unions), identifiers get snake_case.
- A generated name is **highlightable**; highlighting + confirm enters rename
  (voice dictation -> identifier heuristics, or on-screen keyboard).

## 5. The triple button-bank HUD (bottom of screen) — CORE UI

At the bottom of the screen sit **three identical control glyph sets**, each a
**D-pad outline + Y/X/A/B face buttons** (8 assignable inputs per set):

```
   [ LEFT BANK ]        [ MIDDLE BANK ]        [ RIGHT BANK ]
    (dpad + YXAB)         (dpad + YXAB)          (dpad + YXAB)
```

- **No trigger held** -> the **MIDDLE** bank is active and normal-sized.
- **Left trigger held** -> the **LEFT** bank enlarges and becomes active.
- **Right trigger held** -> the **RIGHT** bank enlarges and becomes active.
- Only one bank is active at a time; the active bank is enlarged + highlighted,
  the others are dimmed/smaller.

Each of the 8 slots per bank is an **assignable action**, labeled with its
current meaning. This gives **24 context actions** reachable via trigger + 1
button, with a constant on-screen legend (no memorization). The HUD is always
drawn from the current layout, so it shows what each button does right now.

### Key Layout page (rearranging the buttons)
Open it from the main menu (**Key Layout**) or from the IDE menu (LT+Left,
**Key layout**). It shows the three banks as three cards: the button diagram on
top, then one row per button (Up, Down, Left, Right, A, B, X, Y) with the action
on it. The line under the title says what the highlighted button does.

| On the page | |
|---|---|
| D-pad | move between buttons (Up/Down) and cards (Left/Right) |
| LT / RT pull | jump to that trigger's card |
| A | pick an action for this button (a grid of every action) |
| X | clear this button |
| Y | reset every button to the defaults (asks first: A reset, B keep) |
| B | done |

These controls are fixed, whatever the layout says. The HUD at the bottom
previews the card under the cursor and changes as soon as you assign something.
In the picker, each action shows where it is now ("now on LT+A", "this
button", "RB (fixed)"); a choice the rules below would refuse is greyed out with
the reason ("needs a trigger", or "would push Talk to RT+Down" for a swap that
would move this button's action somewhere it can't go). On a short window the
diagrams shrink, then disappear, so the rows still fit.

Rules, so a layout can never lock you out:
- **Plain d-pad, A and B are fixed.** They move, select and go back everywhere,
  menus included. LB (run tests) and RB (run favorite) are fixed shortcuts too;
  the picker can also put Run tests / Run favorite on a button.
- **One button per action.** Picking an action that's already on another
  button **swaps** the two: what was here moves there (that row flashes amber
  and says "moved"; the status line names both buttons).
- **Overwriting can leave an action without a button.** Picking an action that
  has no button yet (Format file, say) for a button that holds another one
  replaces it, and the status line says so ("LT+X: Format file - Talk has no
  button now"). Clearing a button with X works the same way. Pick it again for
  some button to get it back.
- **Delete, Save as and Files always have a button.** Clearing or overwriting
  their button is refused; give them another one first.
- **Talk needs a face button** (X/Y/A/B): while you talk, d-pad Down splits words.
  It's held with its card's trigger (on the plain card: with no trigger). A
  press that closes a panel (Talk on plain Y, and Y closes the docs) never
  starts dictation; let go and press again.
- **Walks need a trigger.** Walk previous / next / in / out (RT+d-pad by
  default) highlight blocks and lines only while their trigger is held.
- A trigger + button with nothing on it does nothing (it never falls through
  to the plain button, so a cleared LT+B can't send you to the main menu).
  A trigger + d-pad with nothing on it still moves the cursor.

Actions you can place: Edit, Delete, Change, Docs, Copy, Talk, Save as, Files,
Previous file, Run list, Run favorite, Run tests, IDE menu, Format file, the four
walks, and Key layout. The hints at the top right ("Y: options    LT+B:
delete") follow the layout. File navigation, the save dialog, the run list, the
docs panel and menus keep their own fixed controls.

The layout is saved right after every change to `doodle_keys.tsv` next to
`doodle.exe` (like `doodle_heat.tsv`), one `bank  button  action` line per
slot; a hand-edited file is repaired on load. A file from a newer Doodle, or
one that can't be read, is left alone and the defaults are used. A trace replay
(docs/TRACE.md) plays with the default layout and never writes the file.

### LT+Y: documentation ("?")
LT+Y shows the documentation of the highlighted part in a panel over the code:
its declaration (a procedure's header, a struct / enum with its body) and the
comment above it, read live from the source (src/model/docs.odin). What it
looks up: a call's name (in its package), a name or `pkg.Name` value, the type a
dot or a literal (`5`, `"hi"`, `true`) expects, or a keyword / directive /
attribute / calling convention (a built-in text). Where: this file (the nearest
declaration above the cursor, so locals and parameters too), the other files of
its folder, the imported package's folder (core: / base: / vendor: / shared:
under the Odin install, or a relative import), then the built-ins (base:builtin,
base:runtime's @builtin procedures). Files for another OS (`fmt_js.odin`,
`#+build js`) are only used when nothing else declares it. D-pad Up/Down
scroll (Left/Right a page); B, A or Y closes.

### Rendering
- Dpad = plus/cross outline. Face buttons = 4 circles in the YXAB cross layout
  (Y top, A bottom, X left, B right — Xbox/Deck layout).
- Each slot shows a short label (the action bound to it in the current context).
- Active bank scale ~1.3x, inactive ~0.85x, smooth tween on trigger press.

## 6. Application flow (v1)

1. **Launch -> main menu**: `New Project`, `Recent Projects`, `Open Folder`,
   `Key Layout` (§5).
   - v1 wires **New Project** only.
2. **New Project -> where?** A short list: **In default folder** (the
   `DoodleProjects` folder, path shown underneath), one row per folder you added,
   and **+ Add another folder...**, which opens a folder browser (D-pad Up/Down
   move, A / Right open a folder, Left up a level, A on "Use this folder" adds
   it, B cancels; on Windows the drives are above a drive root). Added folders
   are saved in `doodle_roots.txt` next to `doodle.exe`, one per line, and show
   up every time; X twice on one removes it from the list (the folder stays on
   disk). Recent Projects lists the projects of every folder.
   A on a folder -> **new file view**: empty document with a single glowing
   **green dot** at the top and the triple button-bank HUD at the bottom. The
   project gets a random name and is saved under the chosen folder.
3. **A on the dot -> radial menu** (File Setup / Dependencies / Procedures /
   Types / Values).
4. **First implemented construct: File Setup -> Package declaration**, which
   inserts `package main` (default name `main`, editable).

## 7. Implications for package design (updates ARCHITECTURE.md)

- `buffer`/`editor` (free-text) are **demoted** for now. The real model is a
  **document tree** (`doc` package, TBD): nodes = AST-ish constructs, each with
  defaults, a renderer to Odin text, and a set of valid child insertion slots.
- `ui` grows: green-dot widget, radial menu, triple button-bank HUD, rename.
- `input` grows: trigger-bank selection, action slots per context.
- Text rendering (`text`) is still needed to render code + labels.
- Free-text editing may return later for proc *bodies* (a hybrid), but the
  scaffolding of a program is projectional.

## 8. Build order (first milestones)
1. SDL2 window + GL context + rect/circle renderer + input (triggers/buttons).
2. Triple button-bank HUD with trigger switching (shapes only).  <-- big visible win
3. stb_truetype text rendering (labels, code).
4. Main menu -> New Project -> empty file + green dot.
5. Green dot -> radial menu (File Setup branch).
6. **Package declaration insert + name edit.**  <-- first real construct
7. Then iterate the rest of the taxonomy in §3.

## File navigation (RT+B)

RT+B in the editor opens file navigation: a full-width sheet that shows
folders as a **grid**. You walk files like grid cells, and you can still see
which folder each file belongs to.

- **Columns are folders.** Each column has a tab with the folder's name. Below
  the tab are the folder's files (A-Z), then its subfolders (A-Z) as closed
  outlined **boxes** in blue ink.
- **The "here" column.** The folder you are looking at is drawn first, as a
  raised green tab at the top left, holding that folder's own files. (It is
  left out when the folder only holds subfolders, but it stays, empty, when
  you delete its last file, so X on its tab can still make a file there.)
  Every other column is one of its subfolders.
- **Rows line up across columns.** Left/Right keep your row. Moving through a
  shorter column, or an empty one (the cursor rests on its tab), doesn't lose
  it: you get it back in the next tall column. Up from the first file goes to
  the column's tab, and from there Left/Right walk along the tabs.
- **Dropping into a folder.** A on a folder box drops the view down a level.
  The box's parent becomes the "here" column, and the box and its sister
  subfolders become the columns, with the cursor on the box's first file.
  A on a column tab drops into that folder. The path from the root is shown at
  the top, for example `game  >  render`. A folder that can't be opened shows
  `(can't open)`, and A on it just says so.
- **Going back up.** B goes back up one level for each time you dropped in,
  then returns to the editor. Left from the first column also goes up a level.
  Going up past the starting folder moves the starting folder up too.
- **Opening.** File navigation opens on the current file's project (its folder
  under the projects folder). The view shows the file's folder as a column next
  to its sister folders, with the file highlighted and marked `*`. A green dot
  on a tab means the open file is in that folder.
- **Long folders** scroll up and down. All columns scroll together and
  `^ more` / `v more` show when there are rows off screen. Many folders scroll
  sideways a whole column at a time, with `<` / `>` at the edges. A column keeps
  at most 400 entries (the rest show as `+N` on its tab).

| Button | Does |
|---|---|
| D-pad | move (Left at the first column = up a level) |
| A | open a file / drop into a folder |
| B | up a level (after dropping in), else back to the editor |
| X | new file (`new_file.odin`) in the highlighted folder, or next to the highlighted file. In a closed box, the view drops into it so the new file shows |
| LT+X | rename the highlighted file or folder |
| LT+B | delete the highlighted file or folder (asks first; it goes to the Recycle Bin) |
| Y | search every file under the starting folder (hold X and say part of the name; B goes back to the grid) |
| RT+B | switch to the previous file |

The "here" folder can't be renamed, deleted or dropped into from inside
itself: go up a level first. On a narrow window the button hint wraps onto a
second line. The grid logic is in `src/model/file_grid.odin` (unit-tested).
The drawing and buttons are in `src/app/filenav.odin`.

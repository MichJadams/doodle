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

### 3.2 Dependencies
| Item | Example |
|------|---------|
| Import | `import "core:fmt"` |
| Aliased import | `import str "core:strings"` |
| Foreign import (C lib) | `foreign import libc "system:c"` |
| Foreign block (C procs) | `foreign libc { puts :: proc(s: cstring) -> i32 --- }` |

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

### 3.5 Values
| Item | Example |
|------|---------|
| Constant | `MAX_HP :: 100` |
| Typed constant | `MAX_HP : int : 100` |
| Build-config constant | `DEBUG :: #config(DEBUG, false)` |
| Global variable | `score: int` or `score := 0` |

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
button, with a constant on-screen legend (no memorization). As the app grows we
assign values/actions to these slots per mode/context.

### Rendering
- Dpad = plus/cross outline. Face buttons = 4 circles in the YXAB cross layout
  (Y top, A bottom, X left, B right — Xbox/Deck layout).
- Each slot shows a short label (the action bound to it in the current context).
- Active bank scale ~1.3x, inactive ~0.85x, smooth tween on trigger press.

## 6. Application flow (v1)

1. **Launch -> main menu**: `New Project`, `Recent Projects`, `Open Folder`.
   - v1 wires **New Project** only.
2. **New Project -> new file view**: empty document with a single glowing
   **green dot** at the top and the triple button-bank HUD at the bottom.
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

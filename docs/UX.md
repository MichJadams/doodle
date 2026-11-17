# Doodle IDE — User Experience & Interaction Model

> STATUS: DRAFT for discussion. This defines how the IDE *feels* to use with a
> gamepad + voice. It drives the `input` and `ui` package designs, so we want it
> settled before building those. Nothing here is final — it's a starting point.

## 1. The core problem

A keyboard has ~100 discrete inputs; a gamepad has ~17. Editing code is
inherently about **precise text entry and precise navigation**. The whole UX
challenge is: *how do you make a 17-button device feel fast for an activity
designed around 100 keys?* Our three levers:

1. **Modes** — the controller means different things in different contexts.
2. **Spatial + structural navigation** — move by code structure, not characters.
3. **Voice** — offload text/identifier entry to speech (the hard part for a pad).

## 2. Proposed interaction pillars

### Pillar A — Modal controller (like a game's context actions)
The same buttons do different things depending on the active **mode**:

- **Navigate mode** (default): move focus between panels, files, symbols, lines.
- **Edit mode**: cursor is in text; sticks/d-pad move the caret structurally.
- **Command mode**: radial/palette of actions.
- **Dictate mode**: hold-to-talk; speech becomes text/commands.

A persistent **glyph HUD** along the bottom always shows what each button does
right now (this is the single most important affordance — never make the user
guess).

### Pillar B — Structural navigation over character navigation
Moving one character at a time with a stick is misery. Instead, navigation
snaps to **meaningful units**, escalating with modifier:

| Input | Motion |
|-------|--------|
| Left stick / d-pad | move by token / word |
| + Left trigger (held) | move by line / block |
| Right stick | scroll viewport (smooth) |
| Bumpers (LB/RB) | jump between symbols (func/struct/proc) via LSP |
| A on a symbol | go to definition |

This leans on `ols` (LSP) to know where functions, structs, and scopes are, so
"jump to next proc" is one button.

### Pillar C — Voice for text entry
- **Hold RT = dictate.** Release = transcribe + insert.
- **Identifier mode**: say "my player speed" -> `my_player_speed` (snake_case by
  default, configurable to camelCase). Post-processing turns spoken words into
  valid Odin identifiers.
- **Command mode voice**: "new proc", "rename symbol", "go to line 240".
- Voice is **augmentation, not requirement** — everything is also doable via the
  on-screen keyboard, just slower.

### Pillar D — On-screen keyboard as the fallback
For symbols, short edits, or when quiet: a **radial / grid gamepad keyboard**
optimized for code (brackets, operators, common Odin keywords on quick-access
rings). Think Steam's text entry but tuned for programming.

## 3. Screen layout (proposed)

```
┌───────────────────────────────────────────────────────────┐
│ Tab bar: open files                                        │
├───────────┬───────────────────────────────────────────────┤
│ File tree │  Editor canvas (virtualized, GPU text)         │
│ (focusable│                                                │
│  panel)   │   ...code...                                   │
│           │                                                │
├───────────┴───────────────────────────────────────────────┤
│ Status / diagnostics line                                  │
├───────────────────────────────────────────────────────────┤
│ GLYPH HUD:  (A) Confirm  (B) Back  (Y) Palette  (RT) Dictate│
└───────────────────────────────────────────────────────────┘
```

- **Panels** are the top-level focus targets (tree, editor, palette, search).
- LB/RB cycle panels; the focused panel gets a bright **focus ring**.
- Designed to be readable at **arm's length on the Deck's 7" screen** AND on a
  desktop monitor (scalable UI).

## 4. Example flows (storyboard these next)

1. **Open a file and jump to a function**
   Tree focused -> stick to file -> A to open -> RB to editor -> bumpers to jump
   to the target proc -> A to enter edit mode.
2. **Add a new variable by voice**
   In edit mode at a line -> hold RT -> say "player health is 100" -> release ->
   inserts `player_health := 100` (identifier-mode heuristics + value parse).
3. **Rename a symbol**
   Cursor on symbol -> Y (palette) -> "rename" -> dictate new name -> LSP applies.
4. **Fuzzy-open across a large project**
   Y -> "find file" -> dictate or type partial -> list -> stick to pick -> A.

## 5. Open questions (need your input)

1. **Mode switching**: explicit (a button toggles Navigate/Edit) or implicit
   (entering a text field = edit)? Hybrid?
2. **Primary text entry**: voice-first with keyboard fallback, or keyboard-first
   with voice as a shortcut? (Affects how much we invest in the on-screen kbd.)
3. **How much structural nav** vs. raw caret movement do you want? Are you happy
   navigating by tokens/symbols, or do you need character-level control often?
4. **Deck usage**: handheld (Gaming Mode, no desktop) as a first-class target, or
   is "docked with the IDE in Desktop Mode" acceptable for v1?
5. **Identifier casing default**: snake_case (idiomatic Odin) confirmed?
6. **Do you want chording** (button combos) or strictly modal (one meaning at a
   time + HUD)? Chording is faster but higher learning curve.
7. **Accessibility angle**: is minimizing physical keyboard use a hard goal
   (e.g., RSI/comfort), which would push us harder toward voice + structural nav?

## 6. What this unblocks
Answering §5 lets us finalize:
- `input/mapping.odin` default bindings and the `Action` set.
- The `ui` focus/panel/palette/HUD widgets.
- The dictation grammar + identifier post-processing in `stt`.

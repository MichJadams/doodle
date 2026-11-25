# 03 — Controller input, the three-bank HUD, Key Layout, menu controls, heatmap, settings and sound

> Odin sources: src/model/keymap.odin, src/model/keys_page.odin, src/model/heat.odin, src/model/settings.odin,
> src/model/menu_sections.odin, src/model/model.odin (Input, grid_cols, grid_nav, active_bank, update,
> keymap_run, menu_select, menu_cancel, make_view, open_ide_menu), src/platform/platform.odin,
> src/app/main.odin (Raw, handle_event, handle_key, build_input, app_requests, draw_hud, draw_bank,
> draw_radial, draw_smudge, draw_menu), src/app/keys_page.odin, src/app/keys_store.odin,
> src/app/heat_store.odin, src/app/settings.odin, src/app/sound.odin, src/app/run.odin (set_status, run list),
> src/app/editor_view.odin (top-right hint line), src/app/docs_panel.odin, src/app/icons.odin,
> src/app/save.odin (save status), src/app/save_dialog.odin, src/app/filenav.odin (fixed overlay controls),
> src/app/setup.odin (SETUP rows), src/model/grab.odin / word_edit.odin / ref_pick.odin / modifiers.odin
> (editor sub-modes that read raw buttons), src/model/ctrl.odin (`ctrl_hint`).
> Tests: src/model/keymap_test.odin, keys_page_test.odin, heat_test.odin, settings_test.odin,
> menu_sections_test.odin, model_test.odin (menu/grid tests), src/platform/platform_test.odin.
> Baseline: Doodle @ 34a2ad1.

## Purpose

Doodle is driven entirely by a gamepad (a keyboard is an optional stand-in). A pad has 8 "main" inputs
(d-pad + A/B/X/Y) and two analog triggers; Doodle multiplies them into **three banks** (left trigger held,
no trigger, right trigger held) of 8 slots each, so 24 actions are one trigger + one button away. A **HUD
at the bottom of every screen** always draws all three banks with what each button does *right now*, so
nothing has to be memorised. The **Key Layout page** lets the user rearrange the 18 rebindable slots
under rules that make lock-out impossible. Menus (the "radial" menus that offer the code constructs valid
at the cursor) use only d-pad/A/B and wrap at their edges; a global **menu heatmap** darkens the cells on
trails the user has used before. A tiny Settings page and two paper/pencil sound effects complete the area.

The rest of the editor (what the actions *do* to code) is specified in docs 02, 04-09; this doc owns the
input pipeline, the binding table, the HUD and the generic menu/overlay controls.

## Features

### F1. Input pipeline: SDL events -> Raw -> model.Input (edges + held triggers)

- **Trigger**: every frame, in every screen.
- **Behavior**:
  - `platform.poll_events` (src/platform/platform.odin) turns SDL2 events into a small tagged union.
    The union declares `Quit_Event`, `Resize_Event`, `Button_Event{button, pressed}`,
    `Axis_Event{axis, value}`, `Key_Event{sym, pressed}`, `Text_Event`, but `poll_events` only ever
    produces **Quit, Button, Axis and Key** events: `Resize_Event` and `Text_Event` are never emitted
    (the window size is polled every frame with `platform.get_size` = the GL drawable size, and text
    entry comes from KEYDOWN keysyms, F17). KEYDOWN repeats from the OS are passed through as ordinary
    presses. Controller buttons are mapped by `map_button`
    (A B X Y, DPAD_UP/DOWN/LEFT/RIGHT, LEFTSHOULDER=LB, RIGHTSHOULDER=RB, START, BACK, LEFTSTICK,
    RIGHTSTICK, GUIDE). Axes are `value / 32767.0` (so triggers are 0..1, sticks about -1..1).
  - The first available game controller is opened at startup (`platform.init`: the first joystick index
    for which `IsGameController` is true); `CONTROLLERDEVICEADDED` opens one only if `win.controller` is
    nil; `CONTROLLERDEVICEREMOVED` only clears the d-pad auto-repeat state (`win.dpad = {}`). It does
    **not** close the handle or set `win.controller` back to nil, so by the code a re-plugged pad is
    never reopened (see Open questions).
  - `main.handle_event` / `handle_key` (src/app/main.odin) accumulate a per-frame `Raw` record:
    - analog trigger values `lt`, `rt` (last value seen) and keyboard stand-ins `key_lt`, `key_rt`;
    - `held: Pad_Held` = the set of the 8 pad buttons (or their keyboard stand-ins) currently down
      (used only for hold actions such as Talk);
    - **edges** (pressed this frame): `e_confirm`+`e_a` (A), `e_cancel`+`e_b` (B), `e_up/down/left/right`,
      `e_x`, `e_y`, `e_lb`, `e_rb`, plus keyboard-only `typed[32]`, `e_backspace`, `e_space`, `e_copy`
      (Ctrl+C), `ctrl_held`, and `x_held`/`pad_x_held` (X held; pad-only variant).
    - `reset_edges` clears all edges at the start of each frame; holds persist.
  - `build_input` converts Raw into the pure `model.Input`:
    `{confirm, cancel, up, down, left, right, lt_held, rt_held, x, y}` where
    **`lt_held = raw.lt > 0.5 || raw.key_lt`** and **`rt_held = raw.rt > 0.5 || raw.key_rt`**.
    The trigger state is the value after *all* of the frame's events, so "pull LT and press A in the same
    frame" is LT+A; "release LT and press A in the same frame" is plain A.
  - The model never sees SDL. Everything below the app layer (keymap resolution, menus, Key Layout page
    logic, heat, settings parsing) is driven by `model.Input` and is unit-tested with synthetic inputs.
- **Rules & edge cases**:
  - **Sticks are not used.** Axis events for LX/LY/RX/RY are emitted but ignored; the trace recorder does
    not even record them (docs/TRACE.md). **LStick, RStick, Guide are ignored.** **Start and Back are used
    only by the debug trace replayer** (Back = pause/resume, Start = take over, Right while paused = step;
    src/app/trace.odin). The Steam Deck back paddles (L4/R4/L5/R5) are not used (README.md). On the Deck
    the README requires launching Doodle from Steam (as a non-Steam game, even in Desktop Mode): outside
    Steam, Steam's desktop layout turns the triggers and trackpads into mouse clicks and Doodle may see no
    gamepad. Mouse and touch input are not handled at all.
  - **LB and RB** are not part of the keymap: they are fixed shortcuts (F8).
  - Only one gamepad is used (the first opened).
  - While dictating (`g_recording`) or while the words are being transcribed (`g_stt_busy`), all navigation
    edges (A, B, d-pad, X, Y) are masked out of the editor's input (`editor_input`), because the d-pad
    drives dictation then (see doc 08).
  - `src/input/*.odin` (an `input.State`/`Action` mapping with Confirm/Cancel/Command_Palette/Dictate_Hold,
    every proc an empty body) is a **dead stub** from the original architecture (ARCHITECTURE.md §5.6).
    The only importer is `src/ui/ui.odin`, itself an unused stub; neither `src/app` nor `src/model`
    imports either, and the build (`build.bat`: `odin build src\app`) never compiles them. The real
    input model is `model.Input` + `model.Keymap`. Do not port `src/input` or `src/ui`.
- **Rationale**: docs/TESTING.md — "Driven by an abstract `model.Input` (button edges + trigger-hold flags)
  instead of raw SDL events. This is what we unit-test."
- **Source**: src/platform/platform.odin (`poll_events`, `map_button`, `map_axis`), src/app/main.odin
  (`Raw`, `reset_edges`, `handle_event`, `handle_key`, `build_input`, `editor_input`), src/model/model.odin
  (`Input`).

### F2. D-pad auto-repeat

- **Trigger**: holding a gamepad d-pad direction.
- **Behavior**: after **0.35 s** (`DPAD_REPEAT_DELAY`) the held direction emits a synthetic press every
  **0.07 s** (`DPAD_REPEAT_EVERY`), nominally ~14 per second, like a held keyboard arrow. Because the check
  runs once per frame and `last` is set to that frame's time, at 60 fps a repeat lands on every 5th frame
  (0.083 s), i.e. ~12 per second; `test_dpad_repeat` accepts 12-15 per second. Repeats are
  ordinary `Button_Event{dir, pressed=true}` events appended by `dpad_repeat_tick` once per poll (per
  frame), so they work identically in the editor, menus, pages, and inside trigger combos (holding RT+Down
  repeats Walk: next). Keyboard arrows repeat through the OS's own key repeat (each repeat is a KEYDOWN).
- **Rules & edge cases**:
  - Disabled while dictating: `win.dpad_no_repeat = g_recording` (d-pad Down ends a word while talking).
    While suppressed, `last` is not advanced, so if the direction is still held when recording stops the
    next repeat fires on the very next frame.
  - Each direction is tracked separately (`dpad[4]` of `{held, down_at, last}`); release stops it. Only
    gamepad d-pad buttons repeat this way (not face buttons, not triggers).
  - Controller removal clears the repeat state.
  - Granularity is one frame (repeat time is checked each poll); at most one repeat per direction per frame.
- **Rationale**: platform.odin comment — "The repeats are ordinary press events, so the trace records them
  and a replay feeds the same moves back."
- **Source**: src/platform/platform.odin (`Dpad_Hold`, `dpad_repeat_tick`, `DPAD_REPEAT_DELAY/EVERY`);
  test `test_dpad_repeat` (src/platform/platform_test.odin).

### F3. Banks and bank selection

- **Trigger**: holding LT and/or RT (analog > 0.5, or keyboard `q` / `e`).
- **Behavior**: `active_bank(inp)` returns **0 = LT bank** if `lt_held`, else **2 = RT bank** if `rt_held`,
  else **1 = plain ("DEFAULT") bank**. **Both triggers held: LT wins.** The HUD enlarges the active bank
  immediately (no tween). Bank constants: `BANK_LT = 0, BANK_NONE = 1, BANK_RT = 2, BANKS = 3`; the HUD
  draws them left-to-right in that order.
- **Rules & edge cases**: the bank is evaluated per frame for edge presses; there is no "latching" of a
  trigger. Trigger pulls alone do nothing in the editor (except showing the walk highlight when the bank
  contains a walk action, F6) — but on the Key Layout page a *pull* (rising edge) jumps to that card (F10).
  Banks only matter where the keymap is consulted: the editor (and, for the IDE-menu combo only, the
  main menu). Menus (F12), overlays (F19) and the main menu's own items (F8) read raw buttons and mostly
  ignore the triggers.
- **Source**: src/model/model.odin (`active_bank`), src/model/keymap.odin (`BANK_*`).

### F4. The complete default binding table

`KEYMAP_DEFAULT` (src/model/keymap.odin). 3 banks x 8 buttons. "Locked" slots can never be rebound.
"HUD shows" is exactly what `slot_glyph`/`action_icon`/`draw_bank` (src/app/main.odin) draw by default.

| Bank | Button | Action (label) | HUD shows | Notes |
|---|---|---|---|---|
| LT | Up | (nothing) | nothing on that arm | unbound trigger+d-pad still **moves the cursor** |
| LT | Down | (nothing) | nothing | idem |
| LT | Left | IDE menu | disc with `=` | global: works on the main menu too |
| LT | Right | Run list | disc with `>` | opens the Run list overlay |
| LT | A | Edit | `e` | replace / text tools / keypad (doc 02, 08) |
| LT | B | Delete | trash icon (fallback: vector trash can) | **required** |
| LT | X | Talk | speech icon (fallback: vector mic); pulses when dictation is possible | **hold**, face-only (doc 08) |
| LT | Y | Docs | `?` | documentation panel |
| none | Up/Down/Left/Right | Move up/down/left/right | bare d-pad arrows | **locked** |
| none | A | Select / add | "add" icon (fallback `+`) | **locked** |
| none | B | Back | "back" icon (fallback `<`) | **locked** |
| none | X | (nothing) | the letter `X` | the one free plain slot |
| none | Y | Change | `*` | context options of the highlighted part (doc 02, 05, 06) |
| RT | Up | Walk: previous | nothing (a "natural" walk) | trigger-only |
| RT | Down | Walk: next | nothing | trigger-only |
| RT | Left | Walk: out | nothing | trigger-only |
| RT | Right | Walk: in | nothing | trigger-only |
| RT | A | Copy | copy icon (fallback `C`) | clipboard |
| RT | B | Files | files icon (fallback `F`) | **required**; file navigation (doc 09) |
| RT | X | Refactor (action `Grab`) | `G` | Grab / Copy line menu (doc 02) |
| RT | Y | Save | save icon (fallback `S`) | **required** |

Outside the keymap (fixed, never rebindable): **LB = Run tests**, **RB = Run favorite** (editor only, F8),
keyboard **Ctrl+C = Copy** (editor only). Sticks, Start, Back, Guide, stick clicks: unused (F1).

Actions with **no button by default**: Save as, Run favorite, Run tests, Format file, Previous file, Key
layout. Free slots by default: LT+Up, LT+Down, plain X. (18 rebindable slots = 8 LT + plain X/Y + 8 RT.)

### F5. Actions and their flags (ACTION_INFO)

Every `Action` has: `key` (its name in doodle_keys.tsv — "never renamed once shipped"), `label` (Key Layout
page/picker), `glyph` (HUD text, ASCII 32..127 only), `hint` (one line under the Key Layout page title),
and flags `fixed`, `hold`, `face_only`, `trigger_only`, `required`. The enum order is internal (the file
uses `key`); `Grab` and `Save` were appended later.

| Action | key | label | glyph | icon | flags | default slot | hint (verbatim) |
|---|---|---|---|---|---|---|---|
| None | `none` | (nothing) | — | — | — | LT+Up, LT+Down, X | — |
| Move_Up/Down/Left/Right | `move_up` ... | Move up / down / left / right | (none) | — | fixed | plain d-pad | move the cursor |
| Select | `select` | Select / add | `+` | Add | fixed | plain A | A on a dot adds code, on a slot fills it |
| Back | `back` | Back | `<` | Back | fixed | plain B | back to the main menu (and out of menus) |
| Edit | `edit` | Edit | `e` | — | — | LT+A | replace the highlighted part (keypad on numbers, text tools on names) |
| Delete | `delete` | Delete | `x` | Delete | **required** | LT+B | delete the highlighted part |
| Change | `change` | Change | `*` | — | — | Y | change the highlighted part: another proc, refill an argument... |
| Docs | `docs` | Docs | `?` | — | — | LT+Y | documentation of the highlighted part |
| Copy | `copy` | Copy | `C` | Copy | — | RT+A | copy the statement / block (whole file on a green dot) |
| Save_As | `save_as` | Save as | `N` | Save | — | none | save under a new name (renaming: Files > LT+X) |
| Run_List | `run_list` | Run list | `>` | — | — | LT+Right | pick a command to run |
| Files | `files` | Files | `F` | Files | **required** | RT+B | browse the project's files |
| Run_Favorite | `run_favorite` | Run favorite | `R` | — | — | none (RB) | save, then run the favorite command (RB too) |
| Run_Tests | `run_tests` | Run tests | `T` | — | — | none (LB) | save, then run odin test . (LB too) |
| Talk | `talk` | Talk | `m` | Speech | **hold, face_only** | LT+X | hold to dictate into the highlighted name / string / number |
| IDE_Menu | `ide_menu` | IDE menu | `=` | — | — | LT+Left | format file, key layout, exit |
| Walk_Prev | `walk_prev` | Walk: previous | `^` | — | **trigger_only** | RT+Up | previous part of the code tree |
| Walk_Next | `walk_next` | Walk: next | `v` | — | **trigger_only** | RT+Down | next part of the code tree |
| Walk_In | `walk_in` | Walk: in | `}` | — | **trigger_only** | RT+Right | into the highlighted part |
| Walk_Out | `walk_out` | Walk: out | `{` | — | **trigger_only** | RT+Left | out to the part around it |
| Format_File | `format_file` | Format file | `~` | — | — | none | fix indentation and blank lines |
| Prev_File | `prev_file` | Previous file | `P` | — | — | none | switch back to the file you had before |
| Key_Layout | `key_layout` | Key layout | `K` | — | — | none | open this page |
| Grab | `grab` | Refactor | `G` | — | — | RT+X | Refactor menu: Grab (move the highlighted statement / block) or Copy line (move a copy); press again to drop, B puts it back |
| Save | `save` | Save | `S` | Save | **required** | RT+Y | save the file (a new project: main.odin in its folder); rename it in Files with LT+X |

Flag meanings (src/model/keymap.odin `Action_Info`):
- **fixed**: may sit only on the locked slots (plain d-pad/A/B). Never offered in the picker.
- **hold**: acts while held, not on press; `keymap_resolve` never puts it in `fired` (Talk).
- **face_only**: not allowed on any d-pad slot (Talk: "the d-pad splits words while you talk").
- **trigger_only**: only allowed in the LT or RT bank (walks: "the highlight follows the held trigger").
- **required**: always exactly one button (Delete, Files, Save).

Where each action is executed (`model.keymap_run`, in **enum order**, stopping as soon as one leaves the
editor state): inside the model — Edit (`edit_selected`), Delete (`delete_selected`), Change
(`change_selected`), the four walks (`tree_move`), Format file (`format_doc`), Grab (`open_refactor_menu`);
IDE menu is handled before the state switch (it is global). The rest need disk / clipboard / an overlay and
are put in `app.requests` for the app layer (`app_requests` in main.odin): Copy, Save, Run favorite, Run
tests, Previous file (all performed), then **at most one overlay** per frame, first match in this order:
Docs, Save as, Run list, Files, Key layout. Talk is polled as a hold by the app (F7).

App-layer status strings for these: Copy → `copied N line` / `copied N lines` (N = newlines + 1) /
`nothing to copy` / `copy failed` (clipboard refused; during a replay the clipboard isn't touched);
Previous file with no history → `no previous file yet`; Docs with nothing under the cursor →
`Nothing to look up here (highlight a name, call, type or keyword)`. Save (src/app/save.odin
`save_now`) → `saved <file>`; the first save of a new project → `saved main.odin in <folder> - rename it
in Files (LT+X)`; failure → `SAVE FAILED: <reason>`. Run favorite / Run tests save first (a failed save
stops the run) and then report `ran: <cmd>` (or `ran (no terminal): <cmd> -> .doodle/run.log` on a
POSIX system with no terminal emulator, `run: couldn't write the run script`); with no favorite
`No favorite command set` (shouldn't happen: a default favorite is seeded). Previous file with history
calls `filenav_alt_tab` even outside file navigation (paper sound, F16).

### F6. Resolving a frame's presses (keymap_resolve)

- **Trigger**: `model.update` in every state except `.Radial` (menus).
- **Behavior**: for each button with an edge this frame, look up `slots[active_bank][button]`:
  - a **fixed** action (plain d-pad/A/B) → left in `rest` as navigation;
  - **None on a d-pad** slot (e.g. LT+Up by default) → left in `rest`: **an unbound trigger + d-pad still
    moves the cursor**;
  - otherwise the edge is **removed from `rest`** (swallowed), and if the action is non-None and not a hold
    it is added to `fired`.
  - Result `Resolved{fired: Actions (a set), rest: Input}`. The editor navigates with `rest` only.
- **Rules & edge cases**:
  - **An unbound trigger + face button is swallowed**, never falling through to the plain meaning
    ("falling through, a cleared LT+B would act as plain B and drop you to the main menu").
  - Unbound **plain X** is swallowed too (does nothing).
  - LT+B deletes and stays in the editor (pinned by `test_keymap_update_delete_stays_in_editor`); RT+B
    requests Files and is not also "back" (`test_keymap_update_requests`).
  - `IDE_Menu` in `fired` opens the IDE menu immediately and returns (works from the main menu too).
    Because this check runs before the editor sub-modes below, the IDE-menu combo opens the IDE menu
    even while Grab, word-by-word editing, reference picking or modifier-target picking is active (their
    state is left as it was; B on the IDE menu returns to it).
  - Editor sub-modes consume **all** input **before** `keymap_run` (so no keymap action other than the
    IDE menu runs while one is active), are tried in this order, and may interpret raw buttons themselves
    (src/model/model.odin `update`, `.Editor` case):
    1. Reference picking (`ref_pick_update`) reads the **raw** `Input`, so triggers are ignored there
       (LT+A = A, LT+B = B); X/Y do nothing. Left/Right wrap through the candidate names, Up/Down jump to
       the previous / next line that has one (no wrap), A opens "Pass as", B cancels.
    2. Grab (`grab_update`, src/model/grab.odin): drops on the Grab action **or raw X in any bank**
       (`inp.x`) or plain A (`keys.rest.confirm`; LT+A is Edit and is swallowed); plain B puts it back;
       Walk prev/next jump; plain or unbound-trigger Up/Down step; everything else is swallowed. A blocked
       drop posts `A copy from inside a procedure can only be dropped inside a procedure`.
    3. Word-by-word string editing (`word_edit_update`, src/model/word_edit.odin): **RT+B** (raw
       `rt_held && cancel`, whatever the layout) or the Delete action removes the word under the cursor;
       **RT+X** (raw), plain A, or **raw Y with no trigger** opens the word menu; plain B ends; plain
       Left/Right move between words and gaps; Up/Down are swallowed. So in this mode RT+B no longer opens
       Files and RT+X no longer opens Refactor, and Y opens the word menu even if Change was moved.
    4. Modifier-target picking (`mod_pick_update`, src/model/modifiers.odin) also reads the raw `Input`
       (triggers ignored): Up/Down (clamped, no wrap), A opens that declaration's options menu, B cancels.
    The app-layer fixed shortcuts (LB, RB, Ctrl+C) are blocked during 1 and 4 but still work during 2
    and 3 (F8). See docs 02/08.
  - **Walk highlight**: `keymap_bank_walks(km, bank)` is true for a trigger bank that contains any walk.
    While such a trigger is held (and not dictating) the app sets `g_walk_held`, and the editor draws the
    code-tree selection highlight (doc 02). Moving a walk to LT makes LT show the highlight.
- **Source**: src/model/keymap.odin (`pad_edges`, `input_clear`, `keymap_resolve`, `keymap_bank_walks`),
  src/model/model.odin (`update`, `keymap_run`), src/app/main.odin (`app_requests`, `g_walk_held`).

### F7. Hold actions (Talk) and the "stale press" rule

- **Trigger**: holding Talk's button (default LT+X) while a dictation target is highlighted.
- **Behavior**: `keymap_holding(km, raw.held, lt, rt, .Talk)` is true when Talk's button is in `held` and
  its bank's trigger is held: LT bank → `lt` (RT is ignored, so LT+RT+X still talks); RT bank → `rt`;
  plain bank → neither trigger held. The app starts recording when the hold is true **and** an editable
  target is highlighted (name / string / comment / number: `model.dictation_target`) **and** STT is
  available **and** the state is the editor **and** no overlay is open (`overlay_open()`: file nav, save
  dialog, docs panel, Run list, project picker, New Project, Key Layout, Settings, vendor/stb prompts)
  **and** the press isn't stale **and** no recording/transcription is already running; it stops when the
  hold becomes false (letting go of either the button or the trigger). Details of dictation: doc 08.
- **Rules & edge cases**:
  - `mic_hold` is additionally forced false while the Key Layout page, Settings page, vendor-library
    prompt or stb prompt is open (so an ongoing recording would stop); the start condition above already
    excludes every overlay.
  - **Stale press**: if the Talk hold is true on any frame while an overlay is open (checked before that
    frame's input is routed, so a press that *closes* the overlay counts: e.g. Talk rebound to plain Y,
    and Y closes the docs panel), `g_talk_stale` is set and dictation can't start until the hold becomes
    false (button or trigger let go) and is made again.
  - The HUD pulses a green ring around Talk's button only when dictation would actually start
    (`g_mic_ready && !overlay_open()`), F9.
  - The save dialog and file-search use their own fixed "hold X" dictation (not the Talk binding, no
    trigger): the save/rename dialog listens only to the **gamepad** X (`raw.pad_x_held`; keyboard `x`
    types an x) and only after X has been released once since the dialog opened (`g_save_x_armed`:
    LT+X opens rename with X still down); file search uses `raw.x_held` (gamepad X **or** keyboard `x`).
- **Source**: src/model/keymap.odin (`keymap_holding`), src/app/main.odin (main loop: `talk_down`,
  `mic_hold`, `g_talk_stale`, `g_mic_ready`); test `test_keymap_holding`.

### F8. Fixed shortcuts outside the keymap (LB, RB, Ctrl+C) and the main menu / IDE menu

- **Trigger / Behavior**:
  - **LB** → `run_tests()` = save, then run `odin test .` in a console that always stays open.
  - **RB** → `run_favorite()` = save, then run the Run list's favorite command (a default exists).
  - **Ctrl+C** (keyboard) → copy the selection, like the Copy action.
  - These fire only when state is the editor and no overlay is open (they sit in the last branch of the
    main loop's overlay chain, and additionally require no Run overlay), not dictating/transcribing, not
    picking a reference or a modifier target. They do fire during Grab and word-by-word editing. They do
    nothing in menus, file nav, dialogs or pages, and not on the main menu.
  - **Main menu** (state `.Menu`, title `DOODLE` in the code font at 20% height, subtitle
    `Odin IDE  -  gamepad native`): items in order `New Project`, `Recent Projects`, `Open Folder`,
    `Key Layout`, `Settings` (5 items → `grid_cols(5)` = 3 columns: 3 + 2; cells 240 x 56, gaps 14 / 12,
    grid top at 44% height). `Open Folder` is drawn dim and does nothing. D-pad moves with `grid_nav` wrap
    (F12). A on `New Project` opens New Project's "where?" list, `Recent Projects` the project picker,
    `Key Layout` the Key Layout page, `Settings` the Settings page (all handled in the app's main loop,
    which consumes the A). **B quits Doodle immediately** (`test_menu_cancel_quits`; no confirmation).
    Bottom hint: `D-pad / Arrows to move    A / Enter to select    (Open Folder not wired yet)`.
    The main menu does not go through the keymap except for the IDE-menu combo: it uses the unfiltered
    `Input`, so **LT/RT + A acts as A, LT/RT + B quits**, and trigger + d-pad moves (see Open questions).
    (A replay of a recording made before Settings existed gets the old 4-item menu, `menu_legacy`, so its
    recorded presses land on the same cells.)
  - **IDE menu** (default LT+Left; global): a menu titled `IDE MENU` with `Format file`, `Key layout`,
    `Exit` (3 items → 2 columns: 2 + 1). B returns to the state it was opened from (editor or main menu).
    `Format file` returns to that state and formats the open document (formatter, doc 01 §13); `Key layout`
    returns to that state and asks the app to open the Key Layout page (`requests += {.Key_Layout}`);
    `Exit` sets `want_quit` and the app exits at the end of the frame, with **no unsaved-changes prompt**.
    Before/after for Format file (test `test_ide_menu_format_file`):
    ```odin
    // before
    package main
    main :: proc() {
    x := 1
    }
    ```
    ```odin
    // after: a blank line after the package clause, the body indented with a tab
    package main

    main :: proc() {
    	x := 1
    }
    ```
- **Rules & edge cases**: In the editor, plain B goes to the main menu (`nav.cancel → state = .Menu`), so
  B, B from the editor quits. There is no "unsaved changes?" prompt in this path, nor on IDE menu > Exit,
  nor when the window is closed (SDL quit event); nothing is auto-saved on quit except the menu heat (F14).
- **Source**: src/app/main.odin (main loop "Fixed, outside the layout", `draw_menu`), src/app/run.odin
  (`run_tests`, `run_favorite`, `TEST_CMD`), src/model/model.odin (`MENU_ITEMS`, `ensure_menus` ide_menu,
  `open_ide_menu`, `menu_select` format/key_layout/quit branches); tests `test_ide_menu_exit`,
  `test_ide_menu_cancel_returns`, `test_keymap_update_edit_and_menus`.

### F9. The three-bank HUD

- **Trigger**: always drawn, on every screen (main menu, editor, menus, file nav, dialogs, pages), after
  every page and overlay; only the status line (F18) and the debug trace overlay are drawn on top of it.
- **Behavior** (`draw_hud`, `draw_bank`, `draw_face_btn`, `slot_glyph`, `action_icon`):
  - A band **150 px high** across the bottom (color ≈ (0.90, 0.86, 0.78)), with a 2 px rule on top.
  - Three bank diagrams centered at 1/6, 3/6, 5/6 of the width, vertical center at 46% of the band; under
    each a label: **`L-TRIGGER`**, **`DEFAULT`**, **`R-TRIGGER`**.
  - The **active bank** (F3) is drawn at scale **1.15**, full opacity, label in the accent green; the other
    two at scale **0.82**, 50% opacity, label dim. Switching is instant.
  - Each diagram: a d-pad (an icon, `assets/icons/dpad-512.png`, sized `46*scale*1.4`) centered
    `82*scale` left of the bank center, and four face buttons (radius `16*scale`) centered `82*scale`
    right, laid out **Y top, A bottom, X left, B right** at `32*scale` from the cluster center. Face colors:
    **Y yellow (0.92,0.78,0.25), A green (0.30,0.78,0.42), X blue (0.28,0.52,0.90), B red (0.86,0.30,0.30)**.
  - **What a slot shows**:
    - an **unbound face button** shows its own letter (`A`/`B`/`X`/`Y`);
    - an **unbound d-pad direction** shows nothing (the bare arrow notch);
    - a **fixed** action on the d-pad (the plain bank's moves) shows nothing;
    - a walk on its **natural RT arrow** (RT+Up = Walk: previous, RT+Down = next, RT+Left = out, RT+Right =
      in) shows nothing — only in the RT bank (`walk_natural`): in the LT bank a blank arm means "unbound,
      moves the cursor", so a walk there must show its glyph;
    - otherwise the action's **icon** if it has one and the icon file loaded (Talk → speech, Delete →
      trash, Save and Save as → save, Files → files, Copy → copy, Select → add, Back → back), else its
      **glyph**. Icons on face buttons are dark ink on Y/A, white on X/B. Without icon files, Talk and Delete
      fall back to a vector microphone / trash can; others to the glyph.
    - A bound d-pad direction gets a small dark disc over its arrow notch (radius `dsize*0.11`) with the
      icon (`dsize*0.22`) or glyph on it in light ink. A fixed action on the d-pad never shows its icon.
    - Without the d-pad icon file the d-pad is drawn as a plus of two rectangles (arm `46*scale`, thickness
      `26*scale`) and bound directions show their **glyph only** (no icons) on the arm.
    - Face-button text (glyph or unbound letter) is always dark ink.
  - **Mic glow**: a pulsing green ring around Talk's button (in whichever bank holds Talk) while
    `g_mic_ready && !overlay_open()` (a dictation target is highlighted in the editor, STT is available,
    no overlay). It does not check the stale-press flag or whether a recording is already running.
  - On the **Key Layout page** the HUD previews the bank under the page cursor (it fakes `lt_held`/`rt_held`
    from the cursor's card), and changes as soon as a slot is reassigned.
- **Rules & edge cases**:
  - The HUD is **drawn from the current keymap**, never hard-coded: rebinding changes the HUD at once.
  - It is **not context-sensitive**: it shows the layout even in menus/overlays where most bindings are
    inert. Overlays show their own fixed-control hint line just above the HUD (at `h - 172`).
  - Glyphs must be ASCII 32..127 (the font atlas).
  - Menus and pages leave `~185 px` at the bottom for the HUD plus one hint line.
- **Rationale**: EDITOR_MODEL.md §5 "This gives 24 context actions reachable via trigger + 1 button, with a
  constant on-screen legend (no memorization)." UX.md: "A persistent glyph HUD along the bottom always
  shows what each button does right now (this is the single most important affordance — never make the
  user guess)."
- **Source**: src/app/main.odin (`HUD_LABELS`, `draw_hud`, `draw_bank`, `draw_face_btn`, `slot_glyph`,
  `action_icon`, `bank_slot_pos`, `draw_trash_icon`, `draw_mic_icon`), src/app/icons.odin,
  src/model/keymap.odin (`walk_natural`); test `test_walk_natural_only_on_rt`.

ASCII sketch of the default HUD with no trigger held:

```
   (LT bank, small, dim)            (plain bank, large)              (RT bank, small, dim)
      .         [?]                    .          [*]                    .          [S]
   [=] + [>] [m]   [x]              .  +  .    [X]   [<]              .  +  .    [G]   [F]
      .         [e]                    .          [+]                    .          [C]
    L-TRIGGER                        DEFAULT                          R-TRIGGER
 ( [m]=speech icon, [x]=trash icon, [S]=save icon, [F]=files icon, [C]=copy icon, [+]=add icon, [<]=back icon )
```

### F10. The Key Layout page

- **Trigger**: main menu → `Key Layout`; IDE menu → `Key layout`; or the `Key_Layout` action if bound.
  `keys_page_open(inp)` records whether LT/RT were already held when it opened (so a trigger combo that
  opened it doesn't count as a "pull").
- **Behavior** (logic in src/model/keys_page.odin, drawing in src/app/keys_page.odin):
  - Opaque page titled **`KEY LAYOUT`**. Three cards side by side (LT, DEFAULT, RT; header = the HUD
    label). Each card: the bank diagram as the HUD draws it (never the mic glow), with a pulsing accent ring
    around the cursor's button, then **8 rows in this order: Up, Down, Left, Right, A, B, X, Y** (`KEYS_ROWS`).
    A row shows a chip (grey square with `^ v < >` for d-pad, colored face circle with its letter), the
    action's icon if any, the action label (dim when locked or `(nothing)`), and a right-aligned `fixed`
    tag on locked rows.
  - The cursor **starts on the plain bank's X row** (the free slot).
  - Line under the title (subtitle), for the slot under the cursor:
    - locked: `<slot>: fixed - always moves / selects / goes back`
    - action without hint (`(nothing)`): `<slot>: <label>  -  A picks an action for it`
    - else `<slot>: <label>  -  <hint>` (e.g. `LT+B: Delete  -  delete the highlighted part`).
    Slot names: `slot_name` = `LT+` / `` / `RT+` + `Up|Down|Left|Right|A|B|X|Y` (e.g. `LT+A`, `Y`, `RT+Up`).
  - **Fixed controls** (never read from the keymap):

    | Input | Effect |
    |---|---|
    | D-pad Up/Down | previous/next row, **wraps** (Up from Up → Y) |
    | D-pad Left/Right | previous/next card, **wraps** (DEFAULT → Right → RT → Right → LT) |
    | LT pull / RT pull (rising edge) | jump to that card (both pulled in one frame: LT); a pull takes priority over a d-pad/face press in the same frame; pulls are tracked but ignored while the picker or reset prompt is open |
    | A | open the action picker for this slot (refused on a locked slot) |
    | X | clear this slot (assign `(nothing)`) |
    | Y | ask "reset all?" |
    | B | done (close the page) |

    Footer: `D-pad move   A change   X clear   Y reset all   LT/RT jump   B done     (LB tests, RB run are fixed)`
    (the parenthesised part is dropped when the window is too narrow).
  - **Picker** (A): a veil over the page titled `<slot>: pick an action`, a 5-column grid (`grid_cols(22)`)
    of the 22 placeable actions in this exact order (`KEYS_PICK`):

    ```
    (nothing)       Edit           Delete      Change     Docs
    Copy            Talk           Save as     Files      Previous file
    Run list        Run favorite   Run tests   IDE menu   Format file
    Walk: previous  Walk: next     Walk: in    Walk: out  Key layout
    Refactor        Save
    ```
    The picker opens with the slot's **current action highlighted**. D-pad moves with `grid_nav` wrap
    (F12); A assigns; **B cancels (closes the picker, nothing changed)**. Footer: `D-pad move   A assign   B cancel`.
    Each cell: the action's icon (or its glyph in a small disc), its label, and a second line saying what
    A would do (`keys_pick_note`, computed with the non-mutating `keymap_try`):

    | Outcome of A | second line (long / short for narrow cells) | cell |
    |---|---|---|
    | already on this slot | `this button` (accent) | normal |
    | on another slot → swap | `now on <slot>` / `<slot>` | normal |
    | no button yet, `(nothing)` | (none) | normal |
    | no button yet, Run favorite | `RB (fixed)` | normal |
    | no button yet, Run tests | `LB (fixed)` | normal |
    | no button yet, other | `no button yet` / `no button` | normal |
    | refused: face-only on d-pad | `face buttons only` / `face only` | **grayed** |
    | refused: trigger-only on plain | `needs a trigger` / `trigger only` | **grayed** |
    | refused: swap would push this slot's action where it can't go | `would push <Action> to <slot>` / `can't swap` | **grayed** |
    | refused: would remove the only button of a required action | `<Action> needs this button` / `can't replace` | **grayed** |
    | other refusal (`Not_Here` with no face/trigger flag) | `not here` | grayed |
    | `Locked` (unreachable: the picker never opens on a locked slot) | `fixed` | grayed |

    Note colours: `this button` in the accent green, every other note in dim ink; a refused cell's label is
    dim and its glyph disc is drawn in the rule colour instead of the d-pad grey. Cells are 56 px high,
    `min(220, fit)` wide, grid top at `max(16% height, subtitle + 36)`.

    The subtitle under the picker title shows the highlighted action's hint, or, if it would be refused,
    `<Label>  -  <long reason>` in warning amber (so a reason shortened in a narrow cell is shown in full).
    **Refused choices can still be highlighted; pressing A on them is refused with a status message and the
    picker stays open.**
  - **Reset prompt** (Y): covers the cards; subtitle `Reset every button to the defaults?`; a box with
    `Reset every button?`, `Your layout goes back to the one Doodle ships with.`, `A reset        B keep`.
    A resets to `KEYMAP_DEFAULT`; **B or Y keeps** the layout; d-pad is ignored. Footer `A reset   B keep`.
  - **Swap flash**: after a swap, the row of the *other* slot (where the picked action used to be) glows
    amber (`COL_WARN`) with a `moved` tag, fading linearly over **1.4 s** (deliberately not the cursor's
    green: "it mustn't read as a second selection"). That row now holds the displaced action, or is empty
    when nothing came back (`moved == None`). Only one flash at a time; a new swap replaces it.
  - **Every change is saved immediately** (F11) and the page owns all input while open (it consumes every
    edge including LB/RB/Ctrl+C, so B here can't also quit the main menu).
  - **Status line feedback** (`keys_feedback`, exact strings):
    - Assigned: `<slot>: <Label>` (+ pencil sound); Cleared: `<slot>: (nothing)` (no sound); either one,
      when the slot held an action before (it now has no button, since an action is on at most one slot),
      appends `  -  <Old> has no button now` (e.g. `LT+X: Format file  -  Talk has no button now`).
    - Swapped, something came back: `<Displaced> moved to <slot>` (e.g. assigning Save to LT+Y:
      `Docs moved to RT+Y`); nothing came back: `<Label> moved from <old slot> to <this slot>`.
      Pencil sound + flash.
    - Locked (A or X on a plain d-pad/A/B row): `D-pad, A and B (no trigger) always move, select and go back`
    - Not here, the pick itself: Talk → `Talk needs a face button (the d-pad splits words while you talk)`;
      walks → `Walking needs a trigger (the highlight follows it)`; else `<Label> can't go on <slot>`.
    - Not here, the swap: `Can't swap: <Displaced> would move to <slot>, and <reason>` where reason is
      `<Displaced> needs a face button` / `walking needs a trigger` / `<Displaced> can't go on <slot>`
      (e.g. `Can't swap: Talk would move to RT+Down, and Talk needs a face button`).
    - Needs home (X or overwrite on Delete/Files/Save): `<Required> needs a button: give it another one first`.
    - Reset: `Buttons reset to the defaults` (+ paper sound). Same / Kept / Moved / Opened_Picker /
      Closed_Picker / Ask_Reset / Done: no message. `Same` (A on the action already there) closes the
      picker silently.
    - If the keys file could not be read or is a newer format (F11), changes still apply for this session
      but are silently not saved (the one warning was shown at startup).
- **Rules & edge cases (the assignment rules, `keymap_assign`)**: a slot holds one action; each action is in
  at most one slot.
  1. Locked slot → `Locked`.
  2. The action isn't allowed here (fixed / face-only on d-pad / trigger-only on plain) → `Not_Here` (the
     action, this slot).
  3. Already here → `Same`.
  4. The action already has a button elsewhere → **swap**: this slot's old action moves to the other slot,
     *unless* the old action isn't allowed there → `Not_Here` (the old action, the other slot). Swapping
     never fails for "required" reasons, because a swap never loses an action.
  5. The action has no button and this slot holds a **required** action → `Needs_Home` (it would lose its
     only button). Clearing (assigning None) a required slot is the same.
  6. Otherwise overwrite → `Ok` (the old action may now have no button — allowed, but reported).
  - Refusals change nothing (pinned: `testing.expect_value(t, km, KEYMAP_DEFAULT) // refusals change nothing`).
  - **Lock-out prevention**: plain d-pad/A/B are locked; the page's own controls are fixed; the page is
    always reachable from the main menu (B from the editor → main menu → Key Layout); required actions can't
    be lost; unbound trigger+face presses are swallowed; any file is repaired on load (F11).
- **Source**: src/model/keymap.odin (`slot_locked`, `keymap_allows`, `keymap_assign`, `keymap_try`,
  `slot_name`), src/model/keys_page.odin (`KEYS_ROWS`, `KEYS_PICK`, `Keys_Page`, `Keys_Event`,
  `keys_page_new`, `keys_page_update`, `keys_reset_update`, `keys_picker_update`, `keys_page_changed`),
  src/app/keys_page.odin (`handle_keys_input`, `keys_feedback`, `keys_lost_note`, `keys_slot_rule`,
  `keys_layout`, `draw_keys_page`, `keys_subtitle`, `draw_keys_card`, `draw_keys_row`, `keys_draw_flash`,
  `draw_keys_reset_prompt`, `draw_keys_picker`, `keys_pick_note`).
- **Layout detail** (`keys_layout`): title pinned near the top (`clamp(h*0.07, 12, 56)`); cards fill the room
  above the footer and HUD; the diagram scales down to 0.7 and is dropped entirely when rows would be
  shorter than 22 px; row height 18..38 px. Narrow cells use the short notes so the slot name is never cut.

### F11. Persisting the layout: doodle_keys.tsv

- **Trigger**: loaded at startup (before the trace recorder starts, so a replay can override it); saved
  right after every Assigned / Swapped / Cleared / Reset on the page (`keys_page_changed`). Nothing else
  writes it (not at quit).
- **Behavior**: the file lives **next to the executable** (exe dir from the OS, fallback: absolute
  `argv[0]`'s dir). Format (`keymap_serialize`; this is exactly the default layout's file):
  ```
  doodle-keys 1
  # bank	button	action   (banks: lt plain rt; plain d-pad / A / B are fixed and not listed)
  lt	up	none
  lt	down	none
  lt	left	ide_menu
  lt	right	run_list
  lt	a	edit
  lt	b	delete
  lt	x	talk
  lt	y	docs
  plain	x	none
  plain	y	change
  rt	up	walk_prev
  rt	down	walk_next
  rt	left	walk_out
  rt	right	walk_in
  rt	a	copy
  rt	b	files
  rt	x	grab
  rt	y	save
  ```
  Banks `lt plain rt`, buttons `up down left right a b x y`, actions by `ACTION_INFO.key`; fields separated
  by tabs (parser accepts any whitespace). 18 lines; locked slots are never listed.
- **Parsing / repair** (`keymap_parse`, then `keymap_repair`):
  1. Start with locked slots = defaults, every other slot = None.
  2. Skip blank lines, `#` lines, and any line starting with `doodle-keys`. A line must have exactly 3
     fields with a known bank, button and action, else it's skipped. Skip lines for locked slots; skip an
     action not allowed in that slot (the slot keeps its default later); skip an action already placed
     (**first in file order wins**). Otherwise set it and mark the slot "mentioned" (an explicit `none`
     counts as mentioned). `used` counts applied lines.
  3. For each unmentioned editable slot: put its default action there **unless that action was placed
     elsewhere** (so files from older versions pick up new actions in their default slots).
  4. `keymap_repair`: locked slots forced to defaults; disallowed or duplicate actions dropped (first in slot
     order stays); each missing required action is **re-homed**: its default slot if empty, else the first
     empty slot (banks LT, plain, RT; buttons Up..Y) that allows it, else its default slot anyway (pushing
     out whatever is there). Required actions are processed in enum order (Delete, Files, Save) against
     the `seen` set computed *before* any re-homing. The code comment claims only a non-required action can
     be pushed out "because the required defaults LT+B, RT+B, RT+Y are distinct", but that only holds while
     an empty slot exists; see Open questions for the full-file edge case where this loses Save.
  - Example (test `test_keymap_old_save_as_layout`): an old file `rt	y	save_as` keeps Save as on RT+Y,
    and Save, whose default RT+Y is taken, gets the first empty slot that allows it, which is **LT+Up**
    (the test only asserts "not RT+Y").
- **Safety rules** (src/app/keys_store.odin):
  - Missing file → defaults (no warning). Read failure → retried once after 50 ms ("another Doodle may be
    renaming it"); still failing → defaults and **never overwrite**: status
    `could not read the key layout (doodle_keys.tsv); using the defaults`.
  - First non-blank line starts with `doodle-keys` but isn't exactly `doodle-keys 1` (a newer format) →
    defaults, never overwrite: `doodle_keys.tsv is from a newer Doodle; using the default buttons`.
    (`keys_text_ok`: a first line that doesn't start with `doodle-keys` at all is accepted and repaired.)
  - Save = write `<path>.tmp`, rename over `<path>` (remove the tmp on failure). Failure →
    `could not save the key layout (doodle_keys.tsv)`. A single flag (`g_keys_warned`) gates all keys
    warnings: only the **first** keys-file warning of a session is shown (on the status line only; the
    keys and heat stores don't print to stderr, the settings store does).
  - No exe directory could be determined → nothing is loaded or saved, silently.
  - Two Doodles: the last save wins (no merge).
  - Trace replays: the real file is still read at startup (`keys_store_init` runs before `trace_start`),
    then `keys_store_override` replaces the layout with the one recorded in the trace (`meta keymap`;
    empty = the defaults, for recordings older than layouts) and turns saving off for the session, doc 11.
    (docs/EDITOR_MODEL.md §5 still says a replay "plays with the default layout"; the code pins the
    recorded one.)
- **Source**: src/model/keymap.odin (`KEYS_HEADER`, `keys_text_ok`, `keymap_serialize`, `keymap_parse`,
  `keys_line`, `keymap_valid`, `keymap_repair`, `keymap_rehome`), src/app/keys_store.odin.

### F12. Generic menu controls (the "radial" menus)

All construct menus (Add, Fill slot, Change, Refactor, IDE menu, attribute menus, ... — contents in docs
04-07) share one navigation and drawing scheme. State `.Radial`; a stack of `MenuView`s (`app.nav`).

- **Trigger**: any action that opens a menu (A on a dot or slot, Y, LT+A, LT+Left, RT+X, ...).
- **Behavior / controls**:
  - **Menus only know plain d-pad, A and B.** `keymap_resolve` is skipped in `.Radial`; trigger state is
    ignored (LT+A in a menu = A, LT+B = B, LT+Left = Left, so the IDE-menu combo just moves left), and X,
    Y, LB, RB, Ctrl+C and Talk do nothing (LB/RB/Ctrl+C and dictation all require the editor state).
    Several directions in one frame are applied in the order Left, Right, Up, Down.
  - **D-pad** moves in a grid with **wrap-around** (`grid_nav` / `menu_nav`):
    - Columns: `grid_cols(n)` = smallest `c` with `c*c >= n`, capped at **8** (`GRID_COLS`); n ≤ 1 → 1.
      (1→1, 4→2, 5→3, 6→3, 9→3, 16→4, 22→5, 64→8, 100→8.)
    - Left at a row's first cell → its last cell; Right at the last → first (rows may be short).
    - Down from the bottom row (or into a missing cell of a short last row) → the **top of the same column**.
    - Up from the top row → the **bottom-most existing cell of the same column**.
  - **A** = select: a submenu pushes a new view (breadcrumb grows); a leaf performs its action and closes
    the menu stack (returns to the editor or wherever it was opened), unless that menu keeps itself open
    (refused grayed options, keypads, ...: docs 05/06).
  - **B** = back one level; at the root it closes the menu and returns to `return_state`, undoing pending
    work: a pending replace is dropped, a Y-refilled argument is restored, a temporary body-insertion line
    is removed, a pending rename prompt keeps only this change; compile-time/modifier menus go back to
    picking; "Pass as" goes back to picking the name (`menu_cancel`; details in docs 02/05/06).
  - D-pad auto-repeat applies (holding Down scrolls fast).
- **Sections** ("RECENTLY USED" / "ALL"): `make_view` first drops entries whose `platform` list (comma
  separated OS names) doesn't include this OS (`platform_ok`), then orders entries as (1) already-imported imports,
  (2) recently used imports (most recent first), (3) pinned entries ("used in this file"), then (4)
  everything else — **sorted alphabetically (case-insensitive) when more than 12** (`BUCKET_THRESHOLD`),
  author order otherwise. If (1)-(3) are non-empty *and* something follows, they form the recent section
  (`MenuView.recent`) and the rest **starts on a new row**. `menu_nav` then treats rows of the two sections
  separately: Left/Right wrap within the row; Up/Down wrap over all rows (Up from the first row → the
  last row, Down from the last → the first); the column is clamped to the target row's length. Both
  sections use the same column count, `grid_cols(total entries)`. Without a section (`recent` is 0, or
  every entry is recent) `menu_nav` ≡ `grid_nav`. A submenu's view title is the chosen entry's label.
  Exception: when filling a slot, the `Type` submenu is pushed as-is (no `make_view`: no platform filter,
  no sorting, no sections).
- **Drawing** (`draw_radial`): a veil hides the code. Above the title (only when the stack has more than
  one view) a dim **breadcrumb** of the titles of the views below the top one, joined by `  >  ` and
  ending `  >`; wider than the window minus 80 px → leading entries dropped one at a time and `..  >  `
  prefixed (at least one entry is kept). Title in accent green at 7% height; cells start at 14% height.
  When filling a typed slot, a line under the title: `expects <T>  -  grayed options don't fit`
  (`..T` for a variadic dot; nothing when the slot's type is unknown). Cells: height 44, gaps 12 (h) / 8 (v); width = longest label + 24, clamped to
  **220..480 px**, shrunk only to fit the column count; grid centered. Selected cell: highlight fill + 2 px
  accent outline. Recent cells: teal-tinted fill + 1 px teal outline, captions `RECENTLY USED` (teal) and
  `ALL` (dim). **Grayed (dim) entries** are drawn in faded ink but stay selectable (what A does on them is
  defined by their menu: docs 05/06). Heat smudge borders: F13.
- **Long labels**: each cell label is truncated to fit `cellw - 10` with a trailing `..` (`fit_label`: drop
  bytes from the end until `prefix + ".."` fits; if even a 2-byte prefix doesn't fit, the label is drawn
  uncut). If any label in the view is cut, the grid reserves a line under itself and, when the
  **highlighted** label is one of the cut ones, it is shown in full there (centered, at `h - 196`); the
  space is reserved for the whole view so the grid doesn't jump.
- **Scrolling**: only as many rows as fit above `h - 185` (`h - 220` with the full-label line). The view
  scrolls so the selected row stays **roughly centered** (`first_row = sel_row - visible/2`, clamped);
  `^ more` above / `v more` below when rows are hidden.
- **Footer**: `<i> / <n>     D-pad move   + select   < back` (the `+` and `<` echo the A/B glyphs of the HUD).
- **Source**: src/model/model.odin (`GRID_COLS`, `grid_cols`, `grid_nav`, `BUCKET_THRESHOLD`, `make_view`,
  `push_menu`, `push_view`, `pop_menu`, `menu_select`, `menu_cancel`, `update` `.Radial` case),
  src/model/menu_sections.odin (`menu_cell`, `menu_rows`, `menu_nav`), src/app/main.odin (`draw_radial`,
  `fit_label`, `RECENT_BG`, `RECENT_COL`); tests `test_grid_cols_prefers_square`, `test_menu_wrap_navigation`,
  `test_recent_section_layout_and_nav`, `test_no_recent_section_is_plain_grid`, `test_all_recent_is_not_a_section`.

### F13. The menu heatmap (worn borders)

- **Trigger**: pressing A on a menu entry that actually *does* something (a "use").
- **Behavior**: every menu cell on the path to the used leaf gets one more use, globally (all projects).
  The radial menu draws used cells with a warm graphite "smudge" border that darkens and thickens with use,
  so trails you've used before stand out in huge packages.
  - **What counts as a use** (`heat_is_action`, called first thing in `menu_select`): the entry is a leaf
    with an action (format, key_layout, quit, keyword, proc outline, type/value construct, special, import,
    insert, or any fill), **except**: submenus (opening one records nothing); the "Pass as" and "Rename all
    uses?" menus (their labels are this document's names); grayed options in compile-time / loop / branch /
    ctrl option menus (refused: "not possible here", the menu stays open); Convert's form expansion
    (`T(x)`), keypad keys, "Pass as" / rename / index / word-tool fills; text-tool entries except `case` and
    `esc`. **Leaves grayed only by type fitting still count** (they still apply when picked).
  - **Key construction**: the chain of `entry_heat_id`s chosen from the **root view's chosen entry** down to
    the used cell — **the root view's title is not part of it**, so `Fill slot > Type` and `Edit Type > Type`
    share heat. `entry_heat_id(e)` = `e.heat_key` if set, else `e.label`, with tabs/CR/LF/0x1F turned into
    spaces. `heat_key` exists where the label isn't a stable identity:
    - an import's package group is labeled with this file's alias (`win.` / `windows.`) but keyed by its
      **import path** (`core:sys/windows`), so heat is shared across aliases and projects;
    - alpha buckets (all labeled e.g. `w`) are keyed `FIRST..LAST` (`WM_000..WM_011`);
    - alias-qualified pins (a struct literal's / conversion's expected type) are keyed
      `<import path>.<Name>` (`core:sys/windows.HWND`); enum values include their enum and package
      (`core:sys/windows.SHOW_WINDOW_CMD.None`, src/model/ctrl.odin), so `.None` of one enum isn't
      another's;
    - the statement menu's `Calls` is keyed `Call` (shares the value menu's `Call`).
    - A menu whose root is a deeper menu reached another way sets a **heat root** (`heat_set_root`):
      "Change procedure" (one import's procs) keys start `Call > From import > <path>` (or `Call`).
  - **Every prefix** of the path (depth 1..len) gets +1, each key at most once per use.
  - **Pinned shortcut**: when the used leaf is a pinned "used in this file" copy, its **canonical home** (the
    path a project not using it would show, e.g. `win. > window_messages > WM_ > WM_SIZE`) is bumped too
    (`heat_canonical`: search the current view's groups, else rebuild the package's full grouping for
    procs/constants/types/conversions and search it). Prefixes shared with the walked path are not double
    counted.
  - After a use, every open view's shades are recomputed (`heat_refresh_views`).
- **Shading**: `shade(count) = clamp(ln(1+count) / ln(1+40), 0, 1)` (`HEAT_SATURATE = 40`; 0 for count ≤ 0;
  strictly rising, 1.0 at 40+ uses). Drawn by `draw_smudge` in color (0.29, 0.23, 0.17):
  alpha `0.18 + 0.67*shade`, border width 1 px if shade < 0.5 else 2 px; plain cells get the border on
  their edge (and, above shade 0.5, a fill darkening of `0.04*(shade-0.5)*2` alpha); selected or recent
  cells (which have their own outline) get it as a ring whose inner edge is 2 px outside the cell.
  Shades are cached per view (`MenuView.heat`, nil when there is no heat at all). Sides are drawn as 4 non-overlapping rects (no
  darker corner dots with translucent color).
- **Rules & edge cases**: heat is a pure no-op when `app.heat` is nil (tests). Shades are computed when a
  view is pushed (`push_view` → `heat_view_shades`) and freed when popped.
- **Rationale**: heat.odin header — "so the trail to things you used before stands out in huge packages, in
  any project". The "same trails everywhere" requirement drives grouping by the package's full name list
  with used names removed (doc 07).
- **Source**: src/model/heat.odin (all procs), src/model/model.odin (`push_view`, `menu_select`),
  src/app/main.odin (`SMUDGE_COL`, `draw_smudge`).

### F14. Persisting heat: doodle_heat.tsv (merge on save)

- **Trigger**: loaded at startup; saved at most every **2.0 s** while dirty (`heat_store_tick`, each frame:
  saves when `dirty` and at least 2 s have passed since the last save *attempt*, so the first use after a
  quiet period is saved in the same frame) and once at quit if still dirty (`heat_store_shutdown`).
- **Format**:
  ```
  doodle-heat 1
  <count>\t<seg1>\t<seg2>...        one line per key, keys sorted (byte order)
  ```
  e.g. `2	Constant	core:sys/windows`. In memory segments are joined by `\x1f`; in the file by tabs.
  Parsing ignores the header line, blank lines, lines without a tab at position > 0, non-integer or ≤ 0
  counts, and empty segment lists; CRLF is accepted; **duplicate keys are summed**.
- **Merge on save** (`heat_store_save`): re-read the file *as it is now* (another Doodle may have written
  it), parse it, add this session's **pending** uses (every bump also goes into `pending`), prune to the
  **20000** most-used keys (ties alphabetical; since a prefix always has at least its leaf's count, trails
  are dropped leaf-first), serialize, write `<path>.tmp`, rename over. On success the in-memory store
  **adopts** the merged counts (so it now shows other instances' uses too) and clears `pending`. On failure
  the pending uses stay and are retried (throttled).
- **Safety**: missing file → no heat. Unreadable at startup → start empty, no message; each later save
  re-reads the file and skips while it stays unreadable (`could not read menu heat (doodle_heat.tsv); not
  saved`), keeping the uses pending. Newer format (first non-blank line starts with `doodle-heat` but isn't
  `doodle-heat 1`): found **at startup** → start empty and never write it, **silently** (`g_heat_nosave`
  makes every later save return early, so the warning below is never reached); found **at a save** (the
  file was replaced while running) → stop saving with `doodle_heat.tsv is from a newer Doodle; menu heat
  not saved`. Write or rename failure → `could not save menu heat (doodle_heat.tsv)`, uses stay pending.
  One flag (`g_heat_warned`) gates all heat warnings: only the first one per session is shown. With no
  place to save (no exe dir, or `nosave`) a save just clears `dirty`. Delete the file to reset.
  Replays: the real file is loaded at startup (before the trace starts), uses during the replay still
  change the in-memory counts (and thus the shading), but `g_heat_nosave` is set so nothing is ever saved.
- **Source**: src/model/heat.odin (`HEAT_HEADER`, `HEAT_MAX_KEYS`, `heat_merged`, `heat_adopt`,
  `heat_text_ok`, `heat_serialize`, `heat_parse`, `heat_prune`), src/app/heat_store.odin.

### F15. Settings page and doodle_settings.txt

- **Trigger**: main menu → `Settings` (not reachable from the editor).
- **Behavior**: veil + title `SETTINGS` (accent, 7% height). One row per option, then a `SETUP` heading
  with machine-setup rows, labels verbatim and in this order (`setup_items`, `SETUP_LABELS`,
  src/app/setup.odin): `Doodle` (the updater), `Odin compiler`, `Microsoft C++ Build Tools` (Windows only),
  `clang (to build and run programs)` (Linux only), `Odin's stb libraries` (Linux only), `Speech-to-text`;
  their values, colours and install actions: docs 09/11. Each row: a 48 px box (at most 760 px wide,
  centered, from 15% height, 40 px between rows) with the label left, the value right, and one dim
  explanation line under the box. The cursor row is highlighted with the accent outline; the page opens
  on the first row.
  - The only option (`Setting.Auto_Close_Run`): label **`Automatically close the run terminal`**, default
    **On**. Value `On` (accent) / `Off` (dim). Explanation: On → `Closes when the program ends (an error
    still keeps it open).`; Off → `Stays open after the program ends, until you press a key.` It affects
    Run favorite and Run list commands; **Run tests always keeps its console open**.
  - Controls (fixed, raw buttons, triggers ignored): **Up/Down** move (wrap over options + setup rows); on
    an option row **A, Left or Right** toggles it, saves immediately and plays the paper sound (the toggle
    applies for the session even when saving is off); on a SETUP row **A** runs its install/update action
    (Left/Right do nothing there); **B** closes. Movement is applied before A in the same frame. Footer
    (at `h - 172`): `D-pad move   A switch / install   B back`. The SETUP rows are re-checked every few
    seconds while the page is open (`setup_refresh`).
- **File** `doodle_settings.txt` next to the executable:
  ```
  doodle-settings 1
  auto_close_run	on
  ```
  Parse: defaults first; blank lines skipped; the header is recognised once (a second header line is
  treated as an unknown line); each line (trimmed) is split at the first tab into key/value (no tab: the
  whole line is the key, value empty); a known key with value exactly `on`/`off` applies, any other value
  keeps the default **and the line is dropped** (it is rewritten with the default on the next save);
  **unknown non-`#` lines are kept as they were (only a trailing CR removed) and written back after the
  known options** (forward compatibility); `#` lines are dropped (not preserved).
  Serialize: header, every known option (`key\ton|off`, in `Setting` enum order), then the kept lines; LF
  line ends. The exact default text is `doodle-settings 1\nauto_close_run\ton\n`
  (`test_settings_defaults_and_round_trip` pins the `off` variant).
  `settings_text_ok` is stricter than keys/heat: the first non-blank line must be exactly the header
  (any other first line → never overwritten). Same tmp+rename save, read-retry, once-per-session warnings
  (`could not read the settings (doodle_settings.txt); using the defaults`,
  `doodle_settings.txt is from a newer Doodle; using the default settings`,
  `could not save the settings (doodle_settings.txt)`; also printed to stderr). Replays pin settings.
- **Source**: src/model/settings.odin, src/app/settings.odin (`settings_store_*`, `handle_settings_input`,
  `draw_settings_page`, `setting_on`), src/app/run.odin (`run_command` uses `setting_on(.Auto_Close_Run)`),
  src/app/setup.odin.

### F16. Sound effects

- **Trigger / Behavior** (src/app/sound.odin): a tiny SDL audio mixer playing short random slices of longer
  recordings (`assets/sounds/paper-crumple.wav`, `pencil-1.wav`, `pencil-2.wav`; mono, 16-bit, 44100 Hz).
  - **Pencil scribble** (`sfx_pencil`, 0.35-0.6 s, gain 0.6, random one of the two pencil clips): when code
    was added to the open document this frame (state before and after is the editor or a construct menu,
    not the main menu; no file was loaded this frame; and the count of non-placeholder characters grew); on the Key Layout page after an
    Assigned or a Swapped.
  - **Paper crumple** (`sfx_paper`, 0.22-0.38 s, gain 0.55): switching files (opening a file from file nav,
    previous-file alt-tab), going up or down a folder level in file nav, Key Layout reset, toggling a setting.
- **Rules & edge cases**: the slice start is the loudest of up to 10 random tries (stops early at ≥ 80% of
  the clip's RMS) so slices aren't silent; 15 ms fade-in, 90 ms fade-out (linear envelope); **a new sound
  in the same group fades out the one playing** (its end is pulled in to now + 90 ms; no pile-ups during
  fast edits); 8 voices, and a sound requested while all 8 are busy is dropped. The mixer is mono S16 at
  44100 Hz with 512-sample buffers; voices are summed and clamped. A WAV that isn't exactly 44100 Hz,
  mono, 16-bit little-endian is skipped (if one pencil clip is missing the other is used). No audio
  device or no loadable file → silent no-op. Silent during trace replays. No volume setting, no mute
  option. Key Layout clears (X) make no sound.
- **Source**: src/app/sound.odin (`sound_init`, `sfx_paper`, `sfx_pencil`, `play_slice`, `sfx_mix`);
  callers in src/app/main.odin, keys_page.odin, settings.odin, filenav.odin.

### F17. Keyboard fallback

- **Trigger**: any keyboard key (SDL keycodes); works alongside the pad.
- **Behavior** (`handle_key`, `key_pad_button`):

  | Key | Acts as |
  |---|---|
  | `q` (held) | LT held |
  | `e` (held) | RT held |
  | `w` / Up arrow | d-pad Up |
  | `a` / Left arrow | d-pad **Left** (not the A button!) |
  | `s` / Down arrow | d-pad Down |
  | `d` / Right arrow | d-pad Right |
  | Return, Space | A |
  | Backspace, Escape | B |
  | `x` | X (edge + held, so `q`+`x` held = Talk) |
  | `y` | Y |
  | `r` | RB (run favorite) |
  | `t` | LB (run tests) |
  | Ctrl+C | Copy (editor) |

  Keys also feed `raw.held` (so keyboard holds work for Talk). Text boxes additionally receive typed
  characters: `a`-`z`, `0`-`9`, `-`, `.` (when Ctrl isn't held, max 32 per frame). In the save/rename
  dialog Space types `_` (instead of confirming) and Backspace deletes a character (instead of cancelling).
  Debug trace replays add F5 (take over), F6 (pause/resume), F7 (step).
- **Rules & edge cases**: the letter keys used for navigation also type in text boxes (each dialog decides).
  There is no keyboard stand-in for Start/Back/stick input.
- **Source**: src/app/main.odin (`KEY_*`, `key_pad_button`, `handle_key`), docs/TRACE.md (keyboard table).

### F18. Top-right hint line, status line and banners

- **Hint line** (editor only, src/app/editor_view.odin): in the 50 px title bar, right-aligned with its
  right edge ~340 px from the window's right edge (leaving room for `[REC]` / `transcribing...` /
  `heard: <text>` and status), on the title bar's color, accent text. Content, by priority:
  1. while Grab is active: `Up/Down move   RT+Up/Down jump   X / A drop   B put back`; Copy line:
     `Up/Down move the copy   RT+Up/Down jump   X / A drop   B no copy`; blocked:
     `Outside a procedure: can't drop here   Up/Down move   B no copy`;
  2. else while editing a string word by word: `A change   RT+B delete   B done` (on a word) or
     `A insert   LT+X say words   B done` (on a gap);
  3. else `rebind_hint(keymap, ctrl_hint(app))`: the model's context hint for the highlighted keyword
     (`when`, `#assert`, `if`, `switch`, `case`, loops, labels, attributes, directives, calling conventions,
     block comments, the purple attribute dot), e.g. `Y: add else / else when, change condition    LT+B: delete`.
     The purple dot's hint is `A: attributes  (test, private, ...)` (two spaces: one segment, not rebound).
     `ctrl_hint` returns nothing while picking a modifier target or outside the editor state.
  Not drawn while picking a reference (a banner replaces it). Drawn on a title-bar-coloured box
  (`w - 352 - hw`, y 8, `hw + 24` x 34) so a long file path under it doesn't show through. In the same
  title row, right side: `[REC]` (error red, at `w - 150`) while recording, else a cycling
  `transcribing.` / `transcribing..` / `transcribing...` (at `w - 190`) while the words are worked out,
  else `heard: <text>` (accent, at `w - 320`) for the last dictation.
- **`rebind_hint`** makes model hints follow the layout: the hint is split on exactly **4 spaces**; each
  segment starting with `Y: ` (Change), `LT+B: ` (Delete) or `LT+A: ` (Edit) gets that action's **current**
  slot name, or is **dropped** if the action has no button; other segments are unchanged. Default keymap →
  unchanged. Example: with Delete moved to RT+A, `Y: x    LT+B: delete` → `Y: x    RT+A: delete`; with
  Change also unbound, `Y: options    LT+B: remove label` → `RT+A: remove label`. Hints without such a
  prefix (`A: add a case`) pass through. No current model hint uses `LT+A: `; the rule exists for future
  hints. Only these three actions are rewritten; hard-coded combos elsewhere are not (Open questions).
- **Status line** (`set_status(msg, seconds = 2.0)`, src/app/run.odin): one message at the **top right**
  (y = 14, right-aligned 28 px from the edge), accent color, shown for `seconds` (2 s default,
  `RUN_MSG_DURATION`; the startup "something is missing" setup hint uses 8 s), on every screen, drawn
  after the HUD. It shares the title row with the hint line and `[REC]` / `heard:` and is not
  coordinated with them (long texts can overlap). The model posts messages through `app.notice`
  (static text), which the app moves to the status line every frame. A new message replaces the old one.
  (The `set_status` doc comment says "bottom-right corner"; the code draws it top right.)
- **Banners** (a 30 px pale-yellow bar right under the 50 px title bar, dark amber text): reference picking
  `Pick a name to reference   -   D-pad move   A use it   B cancel`; modifier target picking
  `Pick a declaration for the attribute   -   D-pad Up/Down move   A choose   B cancel` (or `Pick a struct
  for the directive   -   ...` / `Pick a procedure for the calling convention   -   ...`).
- **Source**: src/app/editor_view.odin (end of `draw_editor`), src/model/keymap.odin (`rebind_hint`),
  src/model/ctrl.odin (`ctrl_hint`), branch.odin / loops.odin / block_comment.odin (hint texts),
  src/model/word_edit.odin (`word_edit_hint`), src/model/modifiers.odin (`mod_pick_banner`),
  src/app/run.odin (`set_status`); test `test_keymap_names_and_hints`.

### F19. Context-specific fixed controls (overlays)

Every overlay owns all input while open (the editor gets nothing) and uses **fixed** controls that ignore
the keymap; each shows its own hint line just above the HUD. Overlay priority when several flags are set:
stb prompt > vendor-library prompt > save/rename dialog > file navigation > Key Layout > Settings >
project picker > New Project > docs panel > (editor: Run list).

| Overlay | Controls (verbatim hint where one is drawn) | Detail doc |
|---|---|---|
| Docs panel (LT+Y) | Up/Down scroll one row, Left/Right a page; **A, B or Y closes**. Header hint `Up/Down scroll   B close` | 07 |
| Run list (LT+Right) | grid of commands + `+ New command` (grid_nav wrap); A runs (and closes) or opens templates; Y makes the highlighted one the single favorite (shown `* cmd`); B closes. `D-pad move   A select   Y favorite   B back`. Templates: Up/Down (wrap), A adds, B back: `Up/Down select   A confirm   B back` | 09 |
| File navigation (RT+B) | D-pad move (one step per frame); A open / drop in; B up a level then back; X new file; LT+X rename; LT+B delete (asks: `A delete    B keep it`); Y search (hold X to say a name); RT+B previous file. These trigger combos are **hard-wired** here (raw `lt_held`/`rt_held`), not read from the keymap. Hint (wrapped to fit): `D-pad move   A open / drop in   B back` (or `B up a level` after dropping in) `   X new file   LT+X rename   LT+B delete   Y search   RT+B prev file`; search: `Up/Down move   A open   hold X say a name   B back to the folders` | 09 |
| Save as / Rename dialog | A save / rename; B cancel; hold **gamepad** X (released once since opening) to dictate a snake_case name; keyboard types (Space types `_`, Backspace deletes). Hint: `A save    B cancel    hold X to say a name    (keyboard: type)` (`A rename` when renaming; without STT `A save    B cancel    (keyboard: type a name)`) | 09 |
| Project picker | `<i> / <n>     D-pad move   A open   B back` | 09 |
| New Project "where?" | hint by row: `D-pad move   A create the project here   B back` (default folder), `D-pad move   A create the project here   X remove from list   B back` (an added folder; X twice removes, the row reads `press X again to remove it from the list (the folder stays on disk)`), `D-pad move   A pick a folder to add   B back` (the add row); folder browser `D-pad move   A open folder   Left up a level   B cancel` | 09 |
| Vendor library / stb prompts | `D-pad move   A choose   B cancel` | 09 |
| Key Layout page | F10 | — |
| Settings page | F15 | — |

## Invariants & constraints to carry forward

1. **HARD** — The model never sees platform events: it is driven by an abstract per-frame `Input`
   (button edges + `lt_held`/`rt_held`), so all control logic is unit-testable without a window
   (enforced by package boundaries: src/model imports no SDL/GL/platform package; every test in this
   area drives `update` / `keymap_resolve` / `keys_page_update` with synthetic `Input`s).
2. **HARD** — Three banks x 8 buttons (d-pad 4 + A/B/X/Y). Bank = LT if LT held, else RT if RT held, else
   plain; **both triggers → LT** (pinned: `test_keymap_resolve` LT+RT+B → Delete). Trigger "held" =
   analog value > 0.5 (or keyboard stand-in); the 0.5 threshold lives in the app's `build_input` and is
   not unit-tested.
3. **HARD** — Plain d-pad, A and B are **locked** to move / select / back everywhere; no layout, file or
   page can change them (`slot_locked`, `keymap_valid`, `keymap_repair`).
4. **HARD** — A slot holds one action; an action has at most one slot. Assigning an action that already has
   a slot **swaps**; refusals change nothing.
5. **HARD** — Delete, Files and Save are **required**: always exactly one button; clearing/overwriting
   their only slot is refused (`Needs_Home`); a loaded file missing one gets it re-homed (pinned by
   `test_keymap_assign_rules`, `test_keymap_parse_repairs`). Port it so re-homing can never push out
   another required action (Doodle's `keymap_rehome` can, in one pathological hand-edited file: Open
   questions).
6. **HARD** — Talk is a **hold** and **face-button only**; walks are **trigger-bank only**; fixed actions
   only on locked slots (`keymap_allows`).
7. **HARD** — In the editor, a trigger + an unbound **face** button does nothing (never falls through to
   the plain meaning); a trigger + an unbound **d-pad** direction still moves the cursor (pinned:
   `test_keymap_resolve`, `test_keymap_update_delete_stays_in_editor`). Menus (8), overlays and the main
   menu don't use the keymap and treat trigger + button as the plain button.
8. **HARD** — Menus use only plain d-pad/A/B semantics (triggers ignored; X/Y inert); grids wrap on all
   four edges; columns = ceil(sqrt(n)) capped at 8.
9. **HARD** — The HUD is always drawn from the live keymap (never hard-coded labels); the Key Layout page
   previews the cursor's bank in it. (App-layer drawing, not unit-tested; only `walk_natural` is.)
10. **HARD** — The Key Layout page's own controls are fixed and it is always reachable from the main menu,
    so no layout can lock the user out.
11. **HARD** — Keymap file: action names (`ACTION_INFO.key`) are never renamed once shipped; unknown or
    invalid lines are skipped; a mentioned slot keeps the file's value, an unmentioned slot gets its default
    unless that action was placed elsewhere; then repair. Tests pin round-trip (18 lines used) and CRLF.
12. **HARD** — Persisted files (keys, heat, settings): missing = defaults; unreadable or newer-format
    files are **never overwritten**; saves are write-tmp-then-rename; problems are reported at most once
    per file per session and never stop the editor (pinned in part: `keys_text_ok` / `heat_text_ok` /
    `settings_text_ok` tests; the store code itself is app-layer and untested). **SOFT / owner
    decision** — the location: Doodle puts them next to the executable.
13. **HARD** — Heat keys never include the root view's title, use stable identities (`heat_key`: import
    path rather than alias, etc.), and bump every prefix once per use; only real uses count (submenus,
    refused grayed options, keypads, name-bearing menus don't).
14. **HARD** — Heat saves merge with the file's current contents (pending uses only) so concurrent instances
    don't erase each other; prune keeps the 20000 most-used keys.
15. **HARD** — Unknown settings lines survive a load/save round trip.
16. **SOFT** — Model hint strings are written with the *default* button names (`Y: `, `LT+B: `, `LT+A: `)
    separated by 4 spaces, and rewritten for the live layout at draw time (`rebind_hint`).
17. **SOFT** — Every overlay owns all input and consumes every edge it sees (so one press never acts twice,
    e.g. B closing the page and also quitting the main menu). At most one overlay opens per frame.
18. **SOFT** — A Talk press that began while an overlay was open is stale until released.
19. **SOFT** — HUD glyphs are single ASCII characters; icons are optional (always a glyph fallback).
20. **SOFT** — Feedback is immediate and textual: every Key Layout outcome has a status sentence naming the
    buttons involved; refusals are visible *before* pressing (grayed cell + reason).
21. **SOFT** — Sounds are optional, short, de-duplicated per group, and never play during replays.

## Data model & formats

- `Pad_Button` = enum {Up, Down, Left, Right, A, B, X, Y} (d-pad first: `is_dpad(b) = b <= Right`;
  locked = plain bank and `b <= B`). `Pad_Held` = set of Pad_Button.
- Banks: `BANK_LT=0`, `BANK_NONE=1`, `BANK_RT=2`. Names: `BANK_KEY = {"lt","plain","rt"}`,
  `BANK_PREFIX = {"LT+","","RT+"}`, `BUTTON_KEY` lowercase, `BUTTON_NAME` capitalised.
- `Action` = enum (28 values, see F5); `Actions` = set of Action.
- `Action_Info` = {key, label, glyph, hint, fixed, hold, face_only, trigger_only, required}.
- `Keymap` = `slots[3][Pad_Button]Action`. The model holds a pointer; nil means `KEYMAP_DEFAULT`.
- `Assign_Result` = {Ok, Swapped, Same, Locked, Not_Here, Needs_Home} plus (other bank, other button,
  moved action) — in Rust make this an enum with payloads.
- `Resolved` = {fired: Actions, rest: Input}.
- `Input` = {confirm, cancel, up, down, left, right, lt_held, rt_held, x, y} (all bools; edges except the
  two `*_held`).
- `Keys_Page` = {bank, row, picking, pick, asking_reset, prev_lt, prev_rt}. `Keys_Event` = {kind, action,
  bank, button, moved, picked}; kinds: None, Moved, Opened_Picker, Closed_Picker, Assigned, Swapped, Same,
  Locked, Not_Here, Needs_Home, Cleared, Ask_Reset, Reset, Kept, Done. "Changed" (save) = Assigned,
  Swapped, Cleared, Reset.
- `MenuView` = {title, entries, index, recent (size of the recent section), heat (per-entry shade or none),
  heat_root (root view only)}; `Entry` has `label`, `heat_key`, `dim`, `pinned`, `children` and one
  behaviour field (doc 01/06).
- `Heat` = {counts: map key→int, pending: map key→int (unsaved uses), dirty}. Key = segments joined by
  `\x1f`. Constants: `HEAT_SATURATE=40`, `HEAT_MAX_KEYS=20000`, save throttle 2.0 s.
- `Settings` = {on: [Setting]bool, extra: unknown lines}; `Setting_Info` = {key, label, on, off, dflt}.
- Files (all next to the executable; all UTF-8 text, LF written, CRLF accepted):
  - `doodle_keys.tsv`: header `doodle-keys 1`, comment line, 18 `bank\tbutton\taction` lines (F11).
  - `doodle_heat.tsv`: header `doodle-heat 1`, sorted `count\tseg\tseg...` lines (F14).
  - `doodle_settings.txt`: header `doodle-settings 1`, `key\ton|off` lines, then preserved unknown lines (F15).
- Timing constants: trigger threshold 0.5; d-pad repeat 0.35 s delay / 0.07 s period; status 2 s;
  swap flash 1.4 s; heat save every ≥ 2 s; file read retry after 50 ms.

## Tests that pin this behavior

| Test (file) | Asserts |
|---|---|
| `test_keymap_defaults` (keymap_test.odin) | default layout is `keymap_valid`; 17 of the default slots in F4 (all LT except Down, plain A/B/X/Y, RT A/B/X/Y/Up/Left) |
| `test_keymap_resolve` (keymap_test.odin) | LT+A fires Edit and is swallowed; plain A stays navigation; RT+B fires Files; RT+Left fires Walk_Out; unbound LT+Up still moves; LT+X (Talk) fires nothing and is swallowed; unbound plain X swallowed; LT+RT+B → Delete (LT wins) |
| `test_keymap_update_delete_stays_in_editor` | LT+B deletes and doesn't go back to the main menu |
| `test_keymap_update_requests` | RT+Y requests Save; RT+B requests Files and stays in the editor |
| `test_keymap_update_edit_and_menus` | LT+A on a name opens a menu; LT+Left opens the IDE menu from the main menu; `Key layout` returns to the main menu and requests the page |
| `test_keymap_update_change` | Y through `update` = `change_selected` |
| `test_keymap_custom_layout` | Docs moved to plain X; Change moved to LT+Y; old plain Y does nothing |
| `test_keymap_assign_rules` | swap, Locked, Not_Here (Talk on d-pad, walk on plain, swap pushing Talk to RT+Up), Needs_Home (clear LT+B; overwrite RT+B), Same, refusals change nothing, Ok clears |
| `test_keymap_holding` | Talk held only with its trigger; RT ignored for an LT Talk; plain-bank Talk requires no trigger |
| `test_keymap_bank_walks` | RT walks by default; moving a walk to LT makes LT walk |
| `test_keymap_round_trip` | serialize → parse gives the same keymap, 18 lines used, CRLF ok; header checks |
| `test_keymap_parse_repairs` | duplicates (first wins), locked slot ignored, disallowed lines skipped, unknown names skipped, required actions re-homed, missing lines keep defaults unless moved |
| `test_keymap_names_and_hints` | `slot_name`, `action_slot_name`, `rebind_hint` rewriting / dropping segments |
| `test_keymap_try_leaves_the_keymap_alone` | `keymap_try` predicts without mutating |
| `test_walk_natural_only_on_rt` | natural-walk glyph suppression only in RT |
| `test_keymap_old_save_as_layout` | old file with Save as on RT+Y → Save gets another free button |
| `test_keys_page_assign_flow` (keys_page_test.odin) | starts on plain X; picker opens on current action; Left wraps; swap event fields; B = Done |
| `test_keys_page_refusals` | A/X on locked row → Locked; Talk on RT+Up refused and picker stays open; X on LT+B → Needs_Home; X on LT+A → Cleared |
| `test_keys_page_reset` | Y asks; d-pad ignored while asking; B keeps; A resets to defaults |
| `test_keys_page_cursor_and_triggers` | row/card wrap; trigger pull jumps; held trigger doesn't re-jump; LT wins; opening with RT held isn't a pull |
| `test_keys_page_events_name_what_was_lost` | overwrite/clear events name the action that lost its button; swap-from-empty event |
| `test_keys_page_refused_swap_names_the_pick` | refused swap reports the displaced action, the pick and the target slot |
| `test_grid_cols_prefers_square`, `test_menu_wrap_navigation` (model_test.odin) | column count; wrap on all four edges |
| `test_menu_cancel_quits`, `test_ide_menu_exit`, `test_ide_menu_format_file`, `test_ide_menu_cancel_returns` | main menu B quits; IDE menu entries and B |
| `test_recent_section_layout_and_nav` etc. (menu_sections_test.odin) | recent section rows, nav within sections, plain grid equivalence, all-recent isn't a section |
| `test_heat_counts_every_prefix` (heat_test.odin) | every prefix +1, root title excluded, open views refreshed |
| `test_heat_submenu_push_records_nothing` | submenus/placeholders/Convert forms/keypad don't count |
| `test_heat_real_flow_and_alias_independence` | `win.` and `windows.` share heat via the import path |
| `test_heat_pinned_leaf_wears_canonical_home`, `test_heat_convert_pins_wear_type_home` | pinned leaves wear their canonical home, once per prefix |
| `test_heat_serialize_parse_round_trip` | format, sorting, sanitising, malformed lines, duplicates summed, CRLF |
| `test_heat_prune_keeps_most_used`, `test_heat_shade_curve`, `test_heat_nil_is_noop`, `test_heat_view_cache_freed` | prune, log curve, nil store, shades freed |
| `test_heat_grouping_ignores_used_names`, `test_heat_alpha_buckets_have_distinct_keys` | trails identical across files; bucket keys distinct |
| `test_heat_dim_refused_options_record_nothing`, `test_heat_root_prefix`, `test_heat_merge_with_file` | refused options; heat root; merge with a concurrently written file, adopt, failed-save retry |
| `test_settings_defaults_and_round_trip`, `test_settings_parse_keeps_unknown_and_defaults`, `test_settings_text_ok` (settings_test.odin) | default on; exact serialized text; unknown lines kept; bad value keeps default; header strictness |
| `test_dpad_repeat` (src/platform/platform_test.odin) | no repeat before 0.35 s, then one per ≥ 0.07 s (12-15 per second at 60 fps), none while dictating or released |

## Carrying this to Rust

### (a) What transfers unchanged

- The whole interaction model: 3 banks x 8 buttons, locked plain d-pad/A/B, the default table (F4) with
  `odin test .` / `odin run` replaced by their cargo equivalents, LB/RB fixed run shortcuts, a HUD drawn from
  the live keymap, the Key Layout page (fixed controls, picker order, refusal reasons, swap/overwrite/clear
  rules, required actions, reset prompt, immediate save), the "unbound trigger + face is swallowed / unbound
  trigger + d-pad moves" rule, hold actions with the stale-press rule.
- Menu mechanics: square-ish grids capped at 8 columns, wrap on all edges, recent section on its own rows,
  sort > 12 entries, `..` truncation with the highlighted label shown in full, centered scrolling, breadcrumb,
  footer `i / n     D-pad move   + select   < back`.
- Heat: prefix bumping, stable keys, log shade, merge-on-save, prune; settings with unknown-line
  preservation; the "never overwrite unreadable/newer files" policy; tmp-then-rename saves.
- Status line + top-right context hint with `rebind_hint`; paper/pencil sounds with group fade-out.
- Rename the files and headers for the new product (e.g. `<ide>_keys.tsv`, `<ide>-keys 1`) but keep their
  shapes; never rename an action key once shipped.

### (b) Odin-specific pieces and their Rust analog

| Odin | Rust |
|---|---|
| `Pad_Button :: enum u8`, `bit_set[Pad_Button]`, `bit_set[Action]` | a fieldless `#[repr(u8)] enum` with `#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]`; sets as a hand-rolled `u8`/`u32` mask, or `enumset::EnumSet` (then derive `EnumSetType, Debug, Hash` instead: `EnumSetType` itself supplies Copy/Clone/PartialEq/Eq and conflicts with deriving them again). `bitflags` fits less well: its flags are constants, not the enum. |
| `[Action]Action_Info` enumerated array, `[BANKS][Pad_Button]Action` | `impl Action { const fn info(self) -> ActionInfo }` (a `match`) or `enum_map::EnumMap`; `[[Action; 8]; 3]` indexed by `b as usize` (or `EnumMap<PadButton, Action>`) |
| `Assign_Result` + 3 extra return values | `enum Assign { Ok, Swapped { other: Slot, moved: Action }, Same, Locked, NotHere { slot: Slot, action: Action }, NeedsHome { action: Action } }` |
| `keymap_find` returning `(bank, b, ok)` | `fn find(&self, a: Action) -> Option<Slot>` |
| nil `^Keymap` = defaults | the model owns a `Keymap` (`Default` impl = shipped layout); tests use `Keymap::default()` |
| `KEYMAP_DEFAULT ::` constant | `const DEFAULT: Keymap` (arrays of `Copy` enums are const-constructible) |
| `keymap_try` copying `km^` | `let mut scratch = *km;` with `#[derive(Clone, Copy)] struct Keymap` |
| temp-allocated strings (`fmt.tprintf`) | `String` / `format!`, or `Cow<'static, str>` for static labels |
| `union` events (`platform.Event`) | `enum Event { Quit, Resize{..}, Button{..}, Axis{..}, Key{..}, Text(String) }` |
| `#partial switch` | `match` with `_ =>` |
| `or_else 0` on maps | `.get(k).copied().unwrap_or(0)` |
| global `g_*` app state | fields of an `App`/`Ui` struct passed `&mut`; avoid `static mut` |
| `proc "c"` audio callback + `LockAudioDevice` | `sdl2::audio::AudioCallback` impl (the device lock guards it), or `cpal`/`rodio` with `Arc<Mutex<Mixer>>` |
| `when ODIN_OS == .Windows` | `#[cfg(windows)]` / `cfg!(...)` |
| `defer` | `Drop` guards / end-of-scope |
| `os.read_entire_file` / `os.rename` / `os.get_executable_path` | `std::fs::read` / `std::fs::rename` (replaces existing on Windows and Unix) / `std::env::current_exe()` |
| `core:math/rand` | `fastrand` or `rand` |
| `@(test)` + `odin test src/model` | `#[cfg(test)] mod tests` + `cargo test -p <model crate>` |

### (c) Rust concepts this area needs that Odin lacks, and how the UI pattern extends

- **Keep the keymap small; extend menus, not buttons.** Rust has far more constructs (traits/impls,
  lifetimes, borrows/`mut`, ownership moves, pattern matching, `Option`/`Result`/`?`, closures, macros,
  modules/`use`/visibility, derives/attributes, async). In Doodle every construct-specific choice lives in
  a menu reached by the *same* few actions: A on a dot/slot (Add/Fill), **Y = Change** (context options of
  the highlighted part), **LT+A = Edit** (replace / text tools), **LT+B = Delete**, **LT+Y = Docs**, RT
  walks over the code tree, RT+X Refactor. A Rust port should follow the same rule: e.g. toggling `&`/`&mut`
  /owned, adding a lifetime, `?` vs `match` on a `Result`, adding `#[derive(..)]`, `pub`/`pub(crate)` are
  entries in the Y menu of the highlighted part, with refused options grayed with a reason — not new buttons.
- Free capacity exists if something is truly frequent: three unbound slots (LT+Up, LT+Down, plain X) and
  six unbound actions. Suggestions (not in Doodle): a "Quick fix" action applying a compiler/rust-analyzer
  machine-applicable suggestion; "Expand macro" belongs under Docs or Change rather than its own button.
- **Docs (LT+Y)** maps naturally onto rust-analyzer hover (signature + doc comment); **Walks** map onto
  syntax-tree parent/child/sibling navigation (rowan nodes), which is richer in Rust (expressions nest
  deeper) — keep the four walks.
- **Heat keys** must be project-independent: use the item's **canonical path** (`std::collections::HashMap`,
  `serde::Serialize`) as `heat_key` instead of the `use` alias / re-export path, the analog of Doodle's
  import-path-over-alias rule. Macros (`println!`, `vec!`) and derives get stable keys the same way.
- **Run shortcuts**: LB = `cargo test`, RB = the favorite (default `cargo run`); Run list templates become
  `cargo run`, `cargo build --release`, `cargo test`, `cargo clippy`, `cargo run --example ...`. Format file
  → rustfmt (or the IDE's own formatter; doc 01 §13 and its Rust notes).
- **Dictation casing** for Talk targets differs by item kind (snake_case fns/vars, UpperCamelCase types and
  traits, SCREAMING_SNAKE consts) — doc 08; the hold/face-only rules here are unchanged.
- **async/closures** don't change controls; their constructs live in menus (docs 05/06).

### (d) Implementation advice for this area

- Input: use the **SDL2 GameController API** (`sdl2` crate, `GameControllerSubsystem`) or its SDL3
  successor, the **Gamepad API** (`sdl3` crate), rather than raw HID, so the Steam Deck (via Steam Input)
  and XInput pads present the same A/B/X/Y + triggers mapping Doodle relies on (`gilrs` is a pure-Rust
  alternative; verify trigger axes and Deck behaviour). Normalise triggers to 0..1 and use > 0.5.
  Implement d-pad auto-repeat yourself as synthetic press events at the same timings. Handle hot-plug
  properly (close the removed controller, forget it, release its held buttons/triggers, open the next
  one on "device added"), which Doodle does not do (Open questions).
- Structure: a `model` crate with no SDL/GL dependency, containing `Input`, `Keymap`, `keymap_resolve`,
  `KeysPage::update -> KeysEvent`, menus, heat, settings parse/serialize; an `app` crate for SDL, drawing,
  files, sound. Doodle's model package does use `core:os` elsewhere (loading files, docs lookup), but this
  area's model code is strings-in / strings-out (`keymap_parse`, `heat_merged`, `settings_parse`); keep it
  that way so it tests without a disk. Port the tests in "Tests that pin this behavior" first; they are
  the executable spec.
- Represent `Resolved.rest` as a filtered copy of `Input` exactly like Doodle so editor navigation code only
  ever sees unbound/locked presses.
- Keep text formats hand-parsed and garbage-tolerant (no serde needed); write tmp + `fs::rename`; read-retry
  once after 50 ms.
- Draw HUD glyphs with a glyph atlas (e.g. `fontdue`/`ab_glyph`) and keep the ASCII single-character glyph
  fallback for every action so missing icons never leave a blank button.
- Do **not** port `src/input` / `src/ui` (dead stubs) or the "Open Folder" main-menu item (unwired) unless
  implemented.
- Truncate labels on `char` boundaries (`s.char_indices()`), never by byte index: slicing a `&str` inside
  a multi-byte character panics in Rust, where Doodle's byte-wise `fit_label` merely mis-renders.

## Open questions & known gaps

- **Main menu B with a trigger held quits.** Confirmed in code: in the `.Menu` state `update` uses the
  unfiltered `inp.cancel` (src/model/model.odin `update`, `.Menu` case), and only the IDE-menu action is
  resolved there, so LT+B / RT+B on the main menu quit like plain B; likewise LT/RT+A opens the item
  (the app's main loop checks raw `e_confirm`). No test covers the trigger case (`test_menu_cancel_quits`
  only presses plain B). It contradicts the stated rationale of `keymap_resolve` ("a cleared LT+B would
  act as plain B and drop you to the main menu"), so it is most likely an oversight; the git history
  doesn't say. Recommendation for the Rust port: on the main menu, swallow trigger + face presses like
  the editor does, and decide whether B on the main menu should confirm before quitting.
- **Docs disagree with code** (code wins): EDITOR_MODEL.md §5 says the required actions are Delete, *Save
  as*, Files — the code has **Delete, Files, Save** (Save as is optional since Save was added).
  EDITOR_MODEL.md §5 "Rendering" says active ~1.3x / inactive ~0.85x with a smooth tween — the code uses
  **1.15 / 0.82, instant**. EDITOR_MODEL.md §5's list of placeable actions omits Refactor (Grab) and
  Save, and it says a trace replay "plays with the default layout" — the code pins the layout recorded in
  the trace. EDITOR_MODEL.md §6 lists 4 main-menu items (no Settings). The `set_status` comment says
  "bottom-right corner" but it draws at the **top right**. docs/UX.md (draft) proposes stick navigation,
  bumpers cycling panels, RT = dictate, Y = command palette, an edit/navigate mode split: all superseded.
- **Hard-coded combos and hints that don't follow the layout** (all confirmed in code): Grab's hint
  `RT+Up/Down jump` and `X / A drop` is a literal in src/app/editor_view.odin (the jump itself does follow
  the Walk prev/next bindings, but the drop also fires on raw X in *any* bank, e.g. LT+X); word-by-word's
  hint `RT+B delete` / `LT+X say words` (src/model/word_edit.odin `word_edit_hint`) and its raw RT+B /
  RT+X / plain-Y handling (which override Files / Refactor / a moved Change in that mode); ACTION_INFO
  hints for Save as and Save mentioning `Files > LT+X` / `in Files with LT+X`, Run favorite `(RB too)`,
  Run tests `(LB too)`; `save_now`'s status `rename it in Files (LT+X)`; file navigation's fixed LT+X /
  LT+B / RT+B (src/app/filenav.odin `handle_filenav`, `hint_lines`). `rebind_hint` only rewrites `Y: `,
  `LT+B: `, `LT+A: `. A Rust port should derive every combo shown to the user from the live keymap, or
  state explicitly that a mode's controls are fixed.
- **Both triggers + Talk on RT**: `keymap_resolve` uses the LT bank when both triggers are held, but
  `keymap_holding` for a Talk bound in the RT bank checks only `rt`, so it counts as held (and the LT
  action on the same button fires on the press too). This follows the proc's stated rule ("the other
  trigger is ignored, as the old `lt_held && x_held` rule did"), which is pinned only for the LT side
  (`test_keymap_holding`: LT+RT+X talks). For the RT side it is untested and arguably inconsistent with
  `active_bank`; a Rust port may require "Talk's trigger held and its bank active" instead.
- **Controller hot-plug** (code reading; untested at runtime): on `CONTROLLERDEVICEREMOVED` only the d-pad
  repeat state is cleared. `win.controller` keeps the stale handle (never closed or set to nil), so
  `CONTROLLERDEVICEADDED`, which opens a pad only when `win.controller == nil`, never reopens a re-plugged
  pad; and the app's `raw.held` and `raw.lt` / `raw.rt` keep their last values, so a trigger or Talk
  button held at the moment of unplugging stays "held" (its bank stays active, or Talk keeps recording)
  until a new event for it arrives. For a trigger that can only be an axis event from an opened
  controller (keyboard `q`/`e` set separate flags and can't clear `raw.lt`/`raw.rt`); a stuck button
  is cleared by pressing and releasing its keyboard stand-in.
- **Re-homing can drop another required action** (code reading; no test): `keymap_rehome` falls back to
  "its default slot anyway" when no slot is empty. If a hand-edited file fills all 18 editable slots with
  distinct allowed actions, omits Delete, and puts Save on LT+B (Delete's default), then Delete overwrites
  Save, and Save is never re-homed because `keymap_repair` computed `seen` before re-homing. Result: an
  invalid layout with Save unbound (`keymap_valid` is not re-checked after parsing). In Rust, loop the
  repair until `valid()` or only push out a non-required occupant.
- The HUD is not context-aware (shows the layout even where only A/B/d-pad work, e.g. in menus).
- Settings has a single option; no volume/mute, no HUD scale, no repeat-rate setting.
- Files live next to the executable; on read-only installs nothing is saved (silently, after one warning
  per file). A Rust port may prefer a per-user config dir — an owner decision. Note that Doodle already
  has a per-user folder for other things (`setup_data_dir` in src/app/setup.odin: `%LOCALAPPDATA%/doodle`
  on Windows, the toolchain home elsewhere; Settings > Setup installs Odin and updates there), so moving
  the three settings files there would be consistent with the code base.
- During a replay heat counts are updated in memory but never saved (intended), and sounds are muted.
  Heat is not pinned by the trace: a replay starts from this machine's `doodle_heat.tsv`, so smudge
  shading during a replay can differ from the recording (visual only; heat never changes what a press does).
- Two Doodles editing the Key Layout concurrently: last save wins (documented, not merged).
- `fit_label` truncates by bytes (fine for ASCII labels; a Rust port with Unicode labels must truncate on
  char boundaries).

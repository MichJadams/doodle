# 10 — Rendering, layout and the cozy feel

> Odin sources: src/app/editor_view.odin (all), src/app/main.odin (colors, frame loop, `load_a_font`, `asset_path`,
> `draw_menu`, `draw_radial`, `fit_label`, `draw_smudge`, `draw_hud`, `draw_bank`, `draw_face_btn`, dot drawing
> procs, `slot_dot_color`, `slot_hint_label`, `code_size`), src/gpu/gpu.odin, src/text/text.odin,
> src/platform/platform.odin, src/app/icons.odin, src/app/sound.odin, src/app/docs_panel.odin, src/app/filenav.odin
> (drawing half), src/app/save_dialog.odin, src/app/run.odin (`set_status`, `draw_run_overlay`),
> src/app/keys_page.odin (drawing), src/app/settings.odin, src/app/projects.odin, src/app/new_project.odin,
> src/app/vendor_path.odin, src/app/stb_build.odin, src/app/checker.odin (`current_diags`), src/app/trace.odin
> (`trace_draw`, `trace_after_draw`), src/model/highlight.odin, src/model/format.odin (`MAX_COLS`, `call_rows`,
> `needs_break`, `node_source_lines`), src/model/diagnostics.odin (`node_line_starts`), src/model/heat.odin
> (`heat_shade`), src/model/menu_sections.odin, assets/fonts/README.txt, assets/sounds/README.txt, assets/icons/,
> docs/screenshots/editor.png and home.png. Demoted stubs checked: src/ui/ui.odin, src/editor/editor.odin,
> src/buffer/buffer.odin, src/input/, src/lsp/, src/project/.
> Baseline: Doodle @ 34a2ad1.

## Purpose

This area is everything you *see and hear*: how a projectional document of nodes and fields becomes rows of
colored ink on a paper-colored sheet, where the insertion dots and fill-me slots are drawn and how they pulse,
how the cursor's part is boxed, how menus and overlays are laid out, how the three-bank HUD is drawn at the
bottom of every screen, and the small sounds (a pencil scribble when code is added, a paper crumple when you
switch files). In a gamepad IDE the screen is the only legend: nothing can be typed, so every place you can act
must be *visible* (a dot, a colored slot, a green editable name), every button must be labeled on screen, and
everything must stay readable at arm's length on a 7-inch 1280x800 Steam Deck screen. The "cozy" feel (warm
paper, soft ink, slow pulses, hand-drawn icons, worn menu cells, pencil sounds) is a deliberate product
choice: the README sells Doodle as "A cozy little IDE".

What the dots *mean* and what pressing things *does* lives in other docs: document model (01), cursor and
editing (02), controller/HUD semantics and keymap (03), menus' contents (04-07), voice (08), files and run (09).
This doc owns the pixels, the layout rules, the animation and the audio.

## Features

### F1. Window, frame loop and draw order

- **Trigger**: program start; every frame.
- **Behavior**:
  - Window: title `Doodle IDE`, **1280x800** (the Steam Deck's native resolution, `WINDOW_W`/`WINDOW_H`),
    centered, flags OPENGL | RESIZABLE | SHOWN | ALLOW_HIGHDPI. SDL is initialized with VIDEO | GAMECONTROLLER
    only; the AUDIO subsystem is started separately by `sound_init` (F22), so a machine without audio still runs.
    OpenGL **3.3 core**, double-buffered, **vsync on** (`GL_SetSwapInterval(1)`). The first game controller found
    is opened; a controller plugged in later is opened on `CONTROLLERDEVICEADDED` only if none is open yet
    (platform.odin `init`, `poll_events`).
  - **Startup order** (src/app/main.odin `main`, before the first frame): `platform.init` (window + first
    controller; failure prints `platform.init failed` and exits) → `gpu.init` (`gpu.init failed`) → `load_icons`
    → `sound_init` → code font baked at 28 px (`load_a_font`; none found = `could not load any font`, exit) → UI
    font at 18 px → `App` created with `state = .Menu` and `os_name` set → heat store (`doodle_heat.tsv`) → keys
    store (`doodle_keys.tsv`) → `stt.init` (optional: no engine = Talk never offered, doc 08 F4) → default projects
    folder created (`ensure_projects_dir`) → roots store (`doodle_roots.txt`) → settings store
    (`doodle_settings.txt`) → `trace_start` (debug builds; doc 11) → the command-line file, if any, is loaded
    (doc 09 F7) → frame loop. The ordering constraint that matters: every per-user file (keys, roots, settings)
    is read **before** `trace_start`, because a replay overrides them with the recorded values
    (`*_store_override`) and must find them loaded; and the command-line file is resolved through the trace
    layer (`trace_startup_file`) so a replay opens the sandbox copy. On exit the deferred shutdowns run in reverse
    order: trace stop, settings store, roots store, STT, keys store (those three stores only free memory: their
    files were already saved after each change), the heat store (the one store that **saves at quit**, when it has
    unsaved uses), the sibling cache, the UI font, the background-check thread (joined, so quitting waits for a
    running `odin check`), the code fonts, sound, icons, GPU, window.
  - The size is **polled every frame** with `GL_GetDrawableSize` (drawable pixels); no resize event is used
    (`Resize_Event` and `Text_Event` exist in the `Event` union but are never produced). All layout is in drawable
    pixels; there is no UI scale factor.
  - **Frame loop is continuous, not event-driven**: each iteration samples `g_time` (SDL ticks in seconds),
    polls all pending events (non-blocking `SDL_PollEvent`), updates the model, then redraws the whole screen and
    swaps; vsync paces it (60 Hz on the Deck). The loop never sleeps on purpose (the only sleeps are a 50 ms retry
    when reading a settings/keys/heat/roots file fails). All animation is a pure function of `g_time`.
    Input of a frame is applied before that frame is drawn.
  - **Per frame**: `reset_edges` → (first frame only, not in a replay: if something is missing, the Setup hint
    as an 8 s status, F14) → poll → build `model.Input` → main-menu actions that need disk I/O → route to
    whichever overlay owns input, else `model.update` + `app_requests` → move `app.notice` to the status line →
    `heat_store_tick` (throttled heat save) → dictation bookkeeping → pencil sound check (F22) →
    `ensure_code_font(w)` (F4) → background `odin check` tick (editor states only) → `begin_frame` (clear to
    paper) → draw → `end_frame` → (replay screenshot hook) → present → `free_all(context.temp_allocator)` (every
    layout string/array of the frame is temp memory).
  - **Draw order = z-order** (later covers earlier):
    1. the state's screen: `.Menu` → main menu (F18), then the Recent Projects / New Project overlays;
       `.Editor` → editor (F7-F14), then file navigation; `.Radial` → editor, then the construct menu (F16);
    2. Run list, Save as / Rename dialog, Docs panel, Key Layout page, Settings page, "library not on your PATH"
       prompt, "stb libraries not built" prompt (in that order; the last two can come up over the Run list);
    3. the **HUD** (F15), always, on every screen, over every overlay;
    4. the **status message** (F14), top right, over everything;
    5. the debug trace banner / recording dot (F23).
  - On the Deck the window shows full screen at 1280x800 (README "Screen size" row: "Full screen at the Deck's
    native 1280×800"). The code never asks for full screen (no fullscreen flag, no toggle anywhere): it creates the
    same 1280x800 resizable window everywhere. That Steam's Game Mode compositor is what makes it full screen
    (README: launch it "from Game Mode" as a non-Steam game) is an inference, not something the code does; in
    Desktop Mode it is an ordinary window.
- **Rules & edge cases**: a missing font aborts startup (`could not load any font`); missing icons/sounds/audio
  device only degrade (fallback drawings, silence). The UI font falls back to the code-size font if an 18 px bake
  fails.
- **Rationale**: ARCHITECTURE.md §6 "Target frame budget: 6.9 ms (144 Hz) on desktop, 16.6 ms (60 Hz) on Deck";
  README: same layout on Windows and the Deck.
- **Source**: src/app/main.odin (`main`, `WINDOW_W`, `WINDOW_H`), src/platform/platform.odin (`init`,
  `poll_events`, `get_size`, `now_seconds`, `present`).

### F2. The low-level renderer: one shader, batched textured triangles

- **Trigger**: every draw call of every screen.
- **Behavior** (src/gpu/gpu.odin):
  - One GLSL 330 program. Vertex = `pos: vec2, uv: vec2, color: vec4` (8 floats). Fragment =
    `vColor * texture(uTex, vUV)`. Projection is an orthographic matrix with **y down**, origin top-left,
    in pixels (`ortho(0, w, h, 0)`).
  - **Everything is a textured triangle.** Solid shapes sample a 1x1 white texture (uv 0.5,0.5); text samples a
    font atlas that is white RGB with coverage in alpha; icons are white alpha masks (F21). So one shader tints
    everything by vertex color, and alpha blending (`SRC_ALPHA, ONE_MINUS_SRC_ALPHA`) does the rest.
  - **Batching**: vertices accumulate in a CPU array (capacity `MAX_VERTS = 65536`) and are uploaded with
    `BufferSubData` into one dynamic VBO and drawn with one `DrawArrays(TRIANGLES)`. A flush happens when the
    bound texture changes (`use_texture`), when the buffer would overflow, at `end_frame`, and before a texture is
    destroyed (`texture_destroy`, used when a font is re-baked).
  - Primitives: `draw_rect` (2 triangles), `draw_rect_outline` (4 rects: top, bottom, left, right — corners
    overlap; the thickness grows *inward* from the rect's edge), `draw_circle` (28-segment triangle fan),
    `draw_circle_outline(cx, cy, radius, thickness)` (28-segment ring of quads; `radius` is the ring's **outer**
    edge, the inner edge is `radius - thickness`), `draw_glyph` (a textured quad with a uv sub-rect). Textures: `texture_create` (R8 or RGBA8, LINEAR, CLAMP),
    `texture_create_mipmapped` (RGBA + mip chain, LINEAR_MIPMAP_LINEAR, for icons drawn far below 512 px),
    `texture_update`, `texture_destroy`.
  - `begin_frame` sets the viewport, clears to the paper color (F5) and resets the batch.
- **Rules & edge cases**: there is **no scissor/clipping**. Visible ranges are culled by hand, and overlap is
  handled by draw order (the editor's title bar is drawn *after* the code so scrolled rows never show above it; the
  HUD is drawn after everything so code rows half under it are hidden). Translucent outlines drawn with
  `draw_rect_outline` show darker corner dots (the overlapping corners blend twice) — visible on the grab glow
  (F12) and the block band's 0.6-alpha outline (F11); the heat smudge avoids it (F17). Because text (font atlas),
  icons and solid shapes (white texture) are different textures, every switch between them flushes the batch:
  in practice a frame is many small draw calls, not one.
- **Source**: src/gpu/gpu.odin (`init`, `begin_frame`, `flush`, `use_texture`, `push_tri`, `end_frame`,
  `draw_rect`, `draw_rect_outline`, `draw_circle`, `draw_circle_outline`, `draw_glyph`, `texture_*`).

### F3. Fonts and text drawing

- **Trigger**: startup (two fonts), window width changes (code font re-bake, F4), every text draw.
- **Behavior** (src/text/text.odin, src/app/main.odin `load_a_font`):
  - **Font search order** (first that loads wins), each path resolved by `asset_path` (as given if absolute or
    present in the working folder, else `<exe dir>/<rel>`, else `<exe dir>/../<rel>`):
    1. `assets/fonts/mono.ttf` (the user's own monospace font, e.g. JetBrains Mono renamed),
    2. `C:\Windows\Fonts\consola.ttf` (Consolas),
    3. `C:\Windows\Fonts\segoeui.ttf` (Segoe UI),
    4. `assets/fonts/DejaVuSansMono.ttf` (bundled DejaVu Sans Mono 2.37, so Linux and the Deck always have one),
    5. `/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf`, 6. `/usr/share/fonts/TTF/DejaVuSansMono.ttf`.
    In practice (no `mono.ttf`): **Consolas on Windows, the bundled DejaVu Sans Mono on the Deck/Linux** — the
    same list is used for every font and size, so code and chrome always share one face. (The editor screenshot
    is Consolas: 26 px code rows ~30.4 px apart.)
  - **Three fonts are live**: a 28 px font loaded at startup (`font` in `main`; its only visible use is the main
    menu's `DOODLE` title — it is also passed to `draw_editor`, which ignores it), the **UI/chrome font `g_ui` at
    18 px** (menus, HUD labels, line numbers, hints, status, dot labels, dialogs), and the **code font `g_code`**
    sized to the window (F4; also used for the docs panel's declaration rows).
  - **Atlas**: `stbtt_BakeFontBitmap` bakes the 96 codes **32..127 (ASCII only)** into a **512x512** 8-bit
    coverage bitmap, expanded to RGBA (white + alpha) and uploaded once. Metrics: `ascent` and
    `line_height = (ascent - descent + lineGap) * scale` with `scale = ScaleForPixelHeight(px)`.
  - `measure(s)` = sum of the baked `xadvance` of every byte in range (no kerning); height = line height.
    `draw_line(pos, s, color)` draws from the top-left `pos` with the baseline at `pos.y + ascent`; quads come from
    `GetBakedQuad` (integer-snapped). `draw_centered(rect, s)` centers horizontally and vertically (by line height).
  - Helpers in app: `fit_label(font, s, maxw)` drops trailing characters and appends `..` until it fits (returns
    `s` unchanged if even 2 chars + `..` don't fit); `wrap_text(font, s, maxw)` breaks at the last space that fits,
    else at the last character that fits; `expand_tabs` replaces each tab with 4 spaces for display.
- **Rules & edge cases**: bytes outside 32..127 are **silently skipped** by both `measure` and `draw_line`, so any
  UTF-8 character in a string or comment is invisible on screen (the saved text keeps it). Every HUD glyph and
  every UI string must therefore be ASCII (keymap.odin: "HUD text, ASCII 32..127"). Segoe UI in the list is not
  monospace; if it is the font found, the code still lays out (everything is measured) but columns no longer align.
- **Source**: src/text/text.odin (`load_font`, `measure`, `draw_line`, `draw_centered`, `shutdown`),
  src/app/main.odin (`load_a_font`, `asset_path`, `fit_label`), src/app/editor_view.odin (`wrap_text`,
  `expand_tabs`), assets/fonts/README.txt.

### F4. Code font fitted to 80 columns, re-baked on resize

- **Trigger**: every frame, before drawing (`ensure_code_font(r, w)`).
- **Behavior**: the code font's pixel size is chosen so that **`MAX_COLS = 80` columns** of `0` fit between the
  code's left edge and the right padding:
  `avail = w - editor_x0() - EDITOR_PAD` (= `w - 122`), `adv = measure("0") / current_px` (advance per pixel of
  size, monospace), `want = floor(avail / (80 * adv))`, clamped to **13..28 px** (`CODE_PX_MIN`, `CODE_PX_MAX`).
  If `want` equals the current size nothing happens; otherwise a new font is baked and the old atlas destroyed
  (if the bake fails, the old font stays). The very first bake is a probe at 28 px; whenever the chosen size is
  28 it re-checks once (`ensure_code_font_once`), so startup ends at the fitted size. Only the window **width**
  matters; height never changes the code font.
  - "Size" is stb's pixel height (`ScaleForPixelHeight`: ascender minus descender from `hhea`), not the em, so
    `adv` is the advance divided by (ascent - descent). Computed from the shipped/OS fonts' tables: **Consolas**
    `adv` = 1126/2048 = 0.5498 → **26 px at 1280 px** wide; **DejaVu Sans Mono** `adv` = 1233/2384 = 0.5172 →
    27.99 → **27 px at 1280** (just under the 28 ceiling).
- **Rules & edge cases**: the UI font never rescales (always 18 px). The 13 px floor is reached below ~738 px of
  window width with Consolas (~701 px with DejaVu); then 80 columns no longer fit and long lines wrap (F8). The
  28 px ceiling is reached at >= ~1354 px with Consolas (>= ~1281 px with DejaVu); wider windows show more than 80
  columns. The same 80 is the formatter's break width (`model.MAX_COLS`: "break a call whose line is longer than
  this"). So at the normal window size a *call* longer than 80 columns is shown and saved broken (F8), but a
  saved line can still need more than one screen row: a long line with no argument list to break (a long string
  assignment) wraps on screen; lines that `needs_break` exempts (if/switch/loop headers, `#assert`, compound
  values) stay one saved line and are broken or wrapped only on screen; and unfilled slots take
  `DOT_W` + their label's width, which is not counted in the 80 columns.
- **Rationale**: editor_view.odin header: "Code font is sized so MAX_COLS (80) columns fit across the editor
  (re-baked on resize)"; format.odin: "The same row plan drives the editor ... and doc_to_source, so what you see is
  what gets saved."
- **Source**: src/app/editor_view.odin (`ensure_code_font`, `ensure_code_font_once`, `CODE_PX_MAX`, `CODE_PX_MIN`),
  src/model/format.odin (`MAX_COLS`, `TAB_COLS`, `text_cols`).

### F5. The paper palette and its ink conventions

- **Trigger**: everywhere.
- **Behavior**: a warm "paper" theme: off-white cream paper, dark brown-black ink, faded ink for secondary text,
  green ink for "you can act here", pale blue for "this is selected", red only for problems. All colors are RGBA
  floats 0..1 (hex given for convenience; full table in "Data model & formats").

  | Name | RGBA | Hex | Used for |
  |---|---|---|---|
  | `COL_BG` paper | 0.965, 0.945, 0.890, 1 | #F6F1E3 | clear color, title bar, sheets, name boxes |
  | `COL_PANEL` darker sheet | 0.915, 0.885, 0.815, 1 | #E9E2D0 | unselected menu cells, list rows, dialogs |
  | `COL_TEXT` ink | 0.17, 0.15, 0.13, 1 | #2B2621 | normal text, plain code |
  | `COL_DIM` faded ink | 0.53, 0.49, 0.43, 1 | #877D6E | title path, line numbers, hints, grayed entries, scroll marks |
  | `COL_ACCENT` green ink | 0.10, 0.52, 0.28, 1 | #1A8547 | editable names, selection outline, titles, active labels, status |
  | `COL_HILITE` | 0.74, 0.83, 0.94, 1 | #BDD4F0 | the selected menu cell / list row (dark text on it) |
  | `COL_SEL_BG` | 0.62, 0.76, 0.94, 0.55 | #9EC2F0 @55% | the highlighted part of the code |
  | `COL_RULE` | 0.80, 0.76, 0.68, 1 | #CCC2AD | separator lines, sheet outlines |
  | `COL_VEIL` | 0.84, 0.80, 0.72, 0.95 | #D6CCB8 @95% | full-screen veil behind menus and dialogs (hides the code) |
  | `COL_ERR` | 0.78, 0.18, 0.18, 1 | #C72E2E | problems, `[REC]`, destructive confirmations |
  | `COL_WARN` | 0.70, 0.42, 0.00, 1 | #B36B00 | warnings in dialogs, "moved" flash, refused picker notes |
  | `COL_DOT` | 0.15, 0.60, 0.32, 1 | #269952 | green insertion dots, mic glow, open-file marker |
  | `HINT_COL` | 0.48, 0.45, 0.40, 1 | #7A7366 | expected-type labels next to dots, sub-titles |
  | HUD band | 0.90, 0.86, 0.78, 1 | #E6DBC7 | the bottom HUD strip |

- **Rules & edge cases (conventions that carry meaning)**:
  - **Selected** = `COL_HILITE` fill + **2 px `COL_ACCENT` outline**, on every grid cell, list row, file cell,
    settings row and Key Layout row. In code it is `COL_SEL_BG` + 2 px `COL_ACCENT` outline (F11).
  - **Green ink on a name** = editable (rename / dictate) — F6.
  - **Grayed** = drawn in `COL_DIM` but still present and selectable (never hidden); the main menu's
    `Open Folder` is grayed and does nothing.
  - **Red** is reserved for problems and destructive questions; amber (`COL_WARN`) for "careful" notes.
  - No pure black or white anywhere: the darkest ink is the face-button glyph/icon ink (0.08, 0.09, 0.11), the
    lightest the icon ink on X/B (0.97, 0.98, 1.0) and the chip ink (0.97, 0.95, 0.90).
- **Rationale**: main.odin "a 'paper' theme (warm off-white paper, dark ink)"; HL colors "ink colors that read on
  paper"; README "A cozy little IDE".
- **Source**: src/app/main.odin (`COL_*`, `HINT_COL`, `RECENT_*`, `SMUDGE_COL`), src/app/editor_view.odin (`HL_COLORS`).

### F6. Syntax highlighting and the green editable ink

- **Trigger**: every code row drawn (and the docs panel's declaration rows are drawn in plain ink, not highlighted).
- **Behavior**:
  - `model.highlight(line, packages)` classifies **every byte of a whole line** (the node's fields concatenated,
    so a keyword or `name(` that spans fields is still recognized) into one of 9 classes, scanning left to right:
    - `//` to end of line → **Comment**;
    - `"..."`, `'...'`, `` `...` `` → **String** (backslash escapes skipped except inside backticks; unterminated
      runs to end of line);
    - a digit then any identifier chars or `.` → **Number** (`42`, `0xFF`, `1.5`);
    - `#ident` → **Keyword** (`#force_inline`, `#partial`);
    - an identifier: in the keyword list → **Keyword** (`package import foreign proc struct enum union bit_set
      bit_field distinct map matrix dynamic return if else when for in not_in switch case break continue
      fallthrough defer using or_return or_else or_break or_continue do where cast transmute auto_cast context`);
      in the builtin type list → **Type** (`int uint i8..i128 u8..u128 uintptr f16 f32 f64 complex64 complex128
      quaternion128 quaternion256 bool b8..b64 string cstring string16 cstring16 rune byte rawptr typeid any`);
      `true false nil` → **Constant**; starts uppercase and has a lowercase letter → **Type** (Ada_Case /
      PascalCase); starts uppercase, no lowercase letter, length > 1 → **Constant** (SCREAMING_CASE); a single
      capital letter (`T`, a common generic name) stays **Plain**. Identifiers are ASCII only (`[A-Za-z_][A-Za-z0-9_]*`);
    - then, for non-keyword, non-builtin-type identifiers, what follows decides: optional spaces then `(` →
      **Func**; an immediate `.` (no space) on a Plain word that is one of the file's import names → **Package**
      (`packages == nil` means any `name.`);
    - a Constant-styled word in a **type position** (after `:` but not `::`, after `->`, `^` or `]`, looking back
      over an optional `pkg.` and spaces) becomes **Type** (`x: RECT`, `-> HWND`, `^POINT`, `[]RECT`,
      `: win.RECT`; `nil`/`true`/`false` never do). Without the type-position rule, `MB_OK` stays Constant;
    - everything else (punctuation, spaces, operators) → **Plain**. `/* ... */` is **not** recognized (only
      `//`), so a block comment's markers are plain ink.
  - The editor passes the import names in scope (`collect_imports`), so `win.` is a package but `p.name` is not.
  - **Run color** per byte (`run_color`), in this priority:
    1. the field is **editable** and is not a string and not comment text → **`COL_ACCENT` green** (the name you
       can rename or dictate: a declaration's name, a parameter, an alias — whatever its class);
    2. the field's kind is `string` → the String color;
    3. otherwise the class color from `HL_COLORS`.
  - Fields are split into maximal runs of one color, each drawn as one text item (F8).

  | Class | RGBA | Hex | Example |
  |---|---|---|---|
  | Plain | = `COL_TEXT` | #2B2621 | `:=`, `{`, field access |
  | Keyword | 0.55, 0.15, 0.60 | #8C2699 | `proc`, `return`, `#partial` |
  | Type | 0.00, 0.43, 0.52 | #006E85 | `int`, `Snack`, `win.RECT` |
  | String | 0.33, 0.50, 0.08 | #548014 | `"core:fmt"` |
  | Number | 0.78, 0.33, 0.08 | #C75414 | `0`, `0xFF` |
  | Constant | 0.62, 0.40, 0.00 | #9E6600 | `nil`, `MB_OK` |
  | Comment | 0.55, 0.52, 0.46 | #8C8575 | `// note` |
  | Func | 0.12, 0.33, 0.72 | #1F54B8 | `MessageBoxW(` |
  | Package | 0.70, 0.22, 0.35 | #B33859 | `win.`, `fmt.` |

- **Rules & edge cases**: the highlighter is stateless per line: a multi-line `/* ... */` comment's text lines are
  editable comment fields, so they skip the green rule and get *code* classes (a word like `for` inside the comment
  turns purple). A `// text` line is fine: its line text includes the `//`, so the whole text is Comment-colored.
  Example (docs/screenshots/editor.png): `Snack :: struct {` shows `Snack` green (editable declaration name),
  `struct` purple; `pick_snack :: proc(snacks: []Snack) -> Snack {` shows `pick_snack` and the parameter
  `snacks` green, `[]Snack` and `-> Snack` teal (references, not editable); `best := snacks[0]` shows `best` green
  and `0` orange. In the screenshot the struct members `name:  string,` / `cozy:  int,` are dark ink — the
  screenshot predates editable member names: the current loader gives each member name an editable `member`
  field (data_types.odin `emit_member` → `put_name(..., "member")`), so today `name` and `cozy` draw green
  (`string`, `int` teal either way).
- **Source**: src/model/highlight.odin (`Hl`, `highlight`, `classify_ident`, `in_type_position`, `is_package`),
  src/app/editor_view.odin (`HL_COLORS`, `run_color`), src/model/model.odin (`collect_imports`).

### F7. The editor screen layout

- **Trigger**: state `.Editor` (and under every construct menu, `.Radial`).
- **Behavior**: a fixed geometry (all values in px; `w`, `h` = drawable size):

  ```
  y=0    +----------------------------------------------------------------------------------+
         | snacks\main.odin   2 problems           <context hint, green>     <status/[REC]>  |  title bar, 50 px, paper
  y=50   +----------------------------------------------------------------------------------+  1 px COL_RULE
  y=51   | (yellow banner, 30 px: only while picking a reference / a declaration)           |
  y=56   top of the code area                     ^   (more above)
  y=96   first row
           12  •  best := snacks[0]
           ^   ^  ^
           |   |  code from x0 = 94 to w - 28
           |   top-level insertion dots at x = 80
           line numbers right-aligned at x = 62 (gutter 28..72)
  y=h-158 bottom of the code area                 v   (more below)
  y=h-150 +---------------------------------------------------------------------------------+  2 px COL_RULE
         |      [LT bank]                 [plain bank]                 [RT bank]            |  HUD, 150 px
         |      L-TRIGGER                    DEFAULT                    R-TRIGGER           |
  y=h    +----------------------------------------------------------------------------------+
  ```

  - Constants: `EDITOR_PAD 28`, `LINE_NUM_W 44`, `GUTTER 22`, `editor_x0 = 28+44+22 = 94`, `dot_x = 28+44+8 = 80`,
    `DOT_W 24`, `CAPTURE_DX 34`, code area `top = 56`, `bottom = h - 158`, first row at `y_start = 96`,
    `max_x = w - 28`. Row height = the code font's line height `lh`.
  - **Title bar** (drawn last): paper rect `0..50`, the title at (28, 14) in `COL_DIM` — the current file's full
    path, else `<project dir>/main.odin  (unsaved)`, else `untitled.odin` (`editor_title`) — then, if the checker
    reported problems, `N problem` / `N problems` in `COL_ERR` 24 px after the title; a 1 px `COL_RULE` line at y=50.
  - **Line numbers** (UI font) are the **saved file's** line numbers (`node_line_starts`), right-aligned so their right
    edge is at x=62, vertically centered in their row; `COL_DIM`, or `COL_ERR` when a problem is on that exact line.
    Every node gets one, blank lines included (the screenshot numbers 1..18 with no gaps). Precisely, they number
    the lines of `doc_to_source` (each node's `node_source_lines`), which is also exactly the text the background
    checker compiles, so red numbers always match compiler messages. The file actually written to disk
    (`save_source`) additionally drops editor-only `●` statement lines that sit next to real statements; while
    such a line exists, numbers below it are one higher than in the file on disk.
  - **Scroll marks**: `^` centered at the top of the code area when scrolled down; `v` centered just above `bottom`
    when content continues below; both `COL_DIM`.
  - Nodes stack vertically: node *i* starts where node *i-1*'s rows end. The whole document is laid out every
    frame (F8); only rows intersecting `[top, bottom)` are drawn.
- **Rules & edge cases**: rows partly under the title bar or the HUD are drawn and then covered by them (no
  clipping). The title path is never truncated; the context hint has its own paper backing so a long path doesn't
  show through it (F14).
- **Rationale**: "Title bar (drawn last so scrolled code never covers it)"; line numbers "(as in the saved file)" so
  compiler messages and the screen agree.
- **Source**: src/app/editor_view.odin (`draw_editor`, constants), src/app/save.odin (`editor_title`),
  src/model/diagnostics.odin (`node_line_starts`).

### F8. Laying out one node into visual rows (long lines, broken calls, wrapping)

- **Trigger**: every frame, for every node (`layout_node(node, x0, max_x, packages, word_fi)`).
- **Behavior**: a node (one logical line) becomes a list of **items** (a same-colored text run, or a dot), each with
  an `x`, a width and a visual row index:
  1. **Decide whether to break a call** one argument per row. `model.call_rows(node)` gives the row plan of the
     outermost argument list — a call's `( ... )`, a struct literal's `{ ... }`, or (taking precedence) a
     menu-built procedure header's parameter list: a head span ending with `(`/`{`, one span per argument
     (`extra_indent = 1`, `suffix = ","`, `is_arg`), and a tail span starting at `)`/`}`. A call loaded with
     several arguments per row keeps that grouping (its `(` field's hint `argrows:N` and `ARG_ROW_END` separators;
     one span per recorded row). The node is shown broken if it has such a list **and** either the saved file
     breaks it (`needs_break`: source longer than 80 columns, a struct literal loaded one field per line, a call
     loaded with grouped rows — but never for if/switch headers and case labels, loop headers / `x += f(...)`,
     compound values like `x := cast(T)f(a)`, or `#assert(...)`) **or** its natural one-row width (`x0` + sum of
     field widths) is wider than `max_x`. The second case means an exempt line (say a long `if` header with a
     call) is broken **on screen only** and saved on one line.
  2. **Broken layout**: every span starts a new visual row at `x0 + indent_w + extra_indent * width("    ")` where
     `indent_w` is the drawn width of the line's own indentation; the first field of a continuation span is
     left-trimmed (`\t)` → `)`), the last field of the head span right-trimmed (`( ` → `(`); each argument row ends
     with its `,` suffix drawn in `COL_TEXT` (`fi = -1`, not selectable). Example, Odin:

     ```
     win.MessageBoxW(nil, "This is Handmade Hero.", win.L("Handmade Hero"), win.MB_OK | win.MB_ICONINFORMATION)
     ```
     is drawn (and saved) as
     ```
     win.MessageBoxW(
         nil,
         "This is Handmade Hero.",
         win.L("Handmade Hero"),
         win.MB_OK | win.MB_ICONINFORMATION,
     )
     ```
  3. **Wrapping** anything still too wide: an item that would cross `max_x` (and is not the first on its row) moves
     to a **continuation row** starting at `cont_x = x0 + indent_w + 2 * width("    ")` (two levels deeper than the
     line). A single color run wider than a whole continuation row (a long string) is split by characters,
     preferring to break just after the last space that fits.
  4. **Dots inside a line** (slots) are items of width `DOT_W = 24`, plus the expected-type label's width + 6 when
     the slot has a hint (`slot_hint_label`: the type `LPCWSTR`; `..T` for a variadic `args` dot; `""` when unknown).
     The **capture dot** (pink, F10) is the exception: it is placed in the indentation, `CAPTURE_DX = 34` px left of
     the call's first character, and takes **no width**, so adding it never shifts the code.
  5. **Word-by-word string editing** (08): the edited field is split into word tokens with a yellow word dot
     (`WORD_DOT_W = 16`) before, between and after them; each word is its own selectable item.
  6. **Line numbers per row** (`num_rows`): the first span always gets the node's first line number; when the node
     is broken *in the saved file*, each further span gets the next number, except a span holding only an unfilled
     optional dot (`..any`, "add field", "another result"), which is not saved. Continuation rows from wrapping, and
     rows broken only for screen width, get no number (the saved file has them on one line).
- **Rules & edge cases**: tabs display as 4 spaces (`TAB_COLS = 4` for column counting). The row plan is shared with
  the serializer (`node_source_lines` calls the same `call_rows` + `needs_break`), so a line saved broken is shown
  with the same rows. It is the same *split*, not byte-identical text: the saver also drops unfilled optional
  dots and the `, ` before them, aligns the `=` of `name = value` rows in a struct literal (menu-built ones, or
  ones loaded already aligned; padding the keys), and
  writes tabs; the screen shows the fields as they are. Wrapping never splits inside a dot. The character-split of
  an over-long run measures from the current pen x, so the first piece fills the rest of the current row.
- **Rationale**: format.odin: "a node is one logical line, but a long call is shown and saved with one argument per
  line (Odin style, trailing commas) ... The same row plan drives the editor (which also wraps rows that still don't
  fit on screen) and doc_to_source, so what you see is what gets saved." Capture dot: "sits in the indentation, left
  of the call ... so the code doesn't shift."
- **Source**: src/app/editor_view.odin (`Item`, `Node_Layout`, `layout_node`, `field_width`, `run_color`),
  src/model/format.odin (`Row_Span`, `call_rows`, `needs_break`, `node_source_lines`, `find_arg_list`),
  src/model/struct_lit.odin (`is_optional_dot`), src/model/word_edit.odin (`word_tokens`).

### F9. Scrolling to keep the cursor visible

- **Trigger**: every editor frame, after layout.
- **Behavior**: the cursor's y is computed: on an insertion or attribute dot, `0.3 * lh` below the previous node's
  last row (or `0.3 * lh` above the first row for the top dot) — the attribute dot is drawn elsewhere (F10) but
  scrolls as if it sat there; on a line, the top of the row holding the first highlighted item (row 0 when the
  highlight is a whole line or block). The vertical scroll `g_scroll` is moved just enough to keep that y within
  `[top + lh, bottom - 2*lh]`, then clamped to `[0, max(0, content_end - (bottom - top))]`. Drawing subtracts
  `g_scroll`.
- **Rules & edge cases**: the scroll **jumps** (no easing). There is no free scrolling: the view only follows the
  cursor. `g_scroll` is view state kept in the app layer across frames, computed during drawing (not in the model).
  Menus and lists scroll their own way: construct menus, Recent Projects, New Project, its folder browser and Files
  search keep the selected row roughly centered (`sel - visible/2`, clamped; F16, F19). The Files folder grid
  instead scrolls *just enough* to keep the cursor visible (columns sideways, rows together). The Run list and
  the Settings page do not scroll at all.
- **Source**: src/app/editor_view.odin (`draw_editor`, `g_scroll`).

### F10. Dots: the visual vocabulary

- **Trigger**: wherever the model reports a place to act (dot semantics in 01/02/04/05).
- **Behavior**: every dot is two concentric discs, a translucent halo and an opaque core. Insertion dots are
  quiet and only the one under the cursor pulses; fill-me slots pulse all the time; options (capture) stay still.
  `p = 0.5 + 0.5*sin(g_time * k)` (0..1). Radii in px, alpha in 0..1:

  | Dot | Where | Normal | Under the cursor |
  |---|---|---|---|
  | **Top-level insertion** (green `COL_DOT`) | x = 80 (+ the indentation width for dots inside a file-scope `when`), y = 0.3*lh below the previous node (0.3*lh above the first row for the top dot) | halo r6 a.14, core r3.5 a.80 | `k=4`: halo r(7+1.5p) a(.18+.18p), core r4 a1 |
  | **Body insertion** (inside procedures, every nesting level) | on the row boundary above line i, x = x0 + indent - 12 if the indent is >= 20 px, else x0 - 10 | halo r5 a.12, core r2.5 a.70 | same as top-level highlighted |
  | **Attribute dot** (purple 0.55,0.22,0.88) above a procedure | x = x0 + indent + 14; y = middle of the blank line above (0.55*lh), else the row boundary (the top dot's y for line 0) | halo r7 a.18, core r4.5 a.90 | `k=4`: halo r(8.5+1.5p) a(.20+.18p), core r5 a1 |
  | **Fill-me slot** in a line (value, type, params, generic) | inline item, center of its 24 px cell | `k=3`, always pulsing: core r(5+1.5p) inner color, halo r(core+4) outer color a(.18+.20p) | same, plus the selection box (F11) |
  | **"Add another" slot** (`body`, `args`, `fields`) | inline | steady small green: halo r5.5 a.16, core r3 `COL_DOT` | same + selection box |
  | **Capture dot** (pink) | in the indentation, 34 px left of the call | steady: halo r8 a.20 outer, core r4.5 inner | same + selection box |
  | **Word dot** (yellow 0.90,0.68,0.05) | gaps between words while editing a string word by word | core r3 | `k=4`: halo r(7+1.5p) a(.22+.18p), core r4 |
  | **Reference target ring** | around the slot a Reference pick will fill (while picking, F14 banner) | `k=6`: ring outer radius 11+2p, 2 px, amber (0.85,0.58,0.05,0.9) | (same; the cursor is elsewhere while picking) |

  Slot colors by field kind (`slot_dot_color`, outer / inner):

  | Kind | Outer | Inner | Meaning |
  |---|---|---|---|
  | `value`, `ret_more` | 1.00,0.60,0.15 (#FF9926) | 1.00,0.65,0.20 | orange: an expression goes here |
  | `type`, `variant`, `res_more` | 0.35,0.70,1.00 (#59B3FF) | 0.40,0.75,1.00 | blue: a type goes here |
  | `params` | 0.80,0.45,0.95 (#CC73F2) | 0.85,0.50,1.00 | violet: parameters |
  | `capture` | 0.93,0.27,0.60 (#ED4599) | 0.97,0.36,0.67 | pink: capture the call's result |
  | `body`, `args`, `fields` | (table has greens, but they are drawn as the small steady `COL_DOT`) | | green: add another |
  | anything else | 0.95,0.55,0.20 (#F28C33) | 1.00,0.60,0.25 | neutral orange |

  - A slot with a hint draws its **expected-type label** right after the dot in the UI font, `HINT_COL`
    (e.g. `● LPCWSTR`, `● ..any`).
- **Rules & edge cases**: a slot field is always drawn as a dot, never as text; dots cannot be copied or saved
  (unfilled optional dots and their `, ` are left out of the saved line; an editor-only `●` statement line is
  dropped on save when it sits next to real statements, and kept as the blank line when it is a block's only
  content, serialize.odin `save_source`; 01). All pulses share the global clock, so every pulsing
  thing on screen breathes in sync. Green always means "add here / add another"; orange/blue/violet mean "this hole
  must be filled"; the color tells the *kind* of thing the menu will offer.
- **Rationale**: main.odin: "Insertion dots: small and quiet; the one under the cursor is a little bigger and
  pulses." Capture: "Steady and smaller than a fill-me dot: an option, not a hole." The yellow word dots are yellow,
  not green, so they don't read as insertion points in code.
- **Source**: src/app/main.odin (`draw_green_dot`, `draw_green_dot_highlighted`, `draw_colored_dot`,
  `draw_orange_dot`, `slot_dot_color`, `slot_hint_label`, `HINT_COL`), src/app/editor_view.odin (`draw_body_dot`,
  `draw_small_green_dot`, `draw_attr_dot`, `draw_attr_dot_highlighted`, `draw_word_dot`, `COL_ATTR_DOT`,
  `COL_WORD_DOT`, the dot passes in `draw_editor`), src/model (`dot_points`, `insertion_indents`, `body_points`,
  `body_indent_at`, `attr_points`).

### F11. Showing the highlighted part, lines and blocks

- **Trigger**: the cursor is on a part of a line, or a trigger whose bank walks the code tree is held (RT by
  default) / the walk selection is sticky (02).
- **Behavior** (`model.current_highlight` → `Highlight{ni, end_ni, fa, fb}`):
  - **A part** (`fb >= 0`: fields `[fa, fb)` of node `ni`): each item of those fields gets a box from `x-3` to
    `x+w+3`, full row height: `COL_SEL_BG` fill + 2 px `COL_ACCENT` outline. A part spanning several fields (a whole
    argument like `win.L("x")`) is a row of adjacent boxes; a part that wraps gets boxes on each row.
  - **Whole line(s) / a block** (`fb < 0`, lines `ni..end_ni`): one band from x=28 to `w-28` over all their rows
    (clamped to the code area): fill (0.22,0.40,0.70,0.25) + 2 px `COL_ACCENT` outline at alpha 0.6.
  - **On an insertion or attribute dot** (between lines) nothing is boxed (`editor_leaf` returns nothing while
    `editor_dot` is set); the dot itself pulses (F10). A **fill-me slot** inside a line is a part like any other:
    its 24 px cell (plus label) gets the box, and the dot keeps pulsing inside it.
  - Boxes are per *item* (same-color run), so a part made of several runs is several adjacent boxes whose
    6 px overlaps show the inner outlines.
  - **Word by word**: only the cursor's word gets the box (quotes and the other fields don't); the cursor's gap gets
    the pulsing yellow dot.
- **Rules & edge cases**: the band is not drawn while something is lifted with Grab (F12 replaces it).
- **Source**: src/app/editor_view.odin (`draw_editor`: `in_hl`, selection pass), src/model/selection.odin
  (`Highlight`, `current_highlight`, `tree_selection`).

### F12. The Grab glow (moving lines)

- **Trigger**: Refactor > Grab / Copy line is active (02).
- **Behavior**: the lifted lines get a glowing box spanning x=28..`w-28`, clamped to the code area:
  four fading outlines outside it (`k = 1..4`, offset `3k` px, 3 px thick, alpha `(0.20 + 0.15p)/k`), a fill at
  alpha `0.14 + 0.06p`, and a 2 px edge; `p` pulses at `k=4`. **Orange** (glow 1.00,0.55,0.10; fill 1.00,0.60,0.15;
  edge 0.95,0.50,0.05,0.95) normally; **red** (0.90,0.15,0.12 / 0.95,0.20,0.15 / 0.80,0.10,0.08,0.95) when a copy
  can't be dropped where it is (`grab_blocked`: a Copy line taken from inside a procedure, now between
  procedures). The top-right hint changes (F14). Dropping a blocked copy (X, A or the Grab action) does nothing but
  post the status `A copy from inside a procedure can only be dropped inside a procedure` (model/grab.odin
  `grab_update`).
- **Source**: src/app/editor_view.odin (`draw_editor` grab block), src/model/grab.odin (`grab_lines`, `grab_blocked`).

### F13. Problems from the compiler: red wash, red numbers, error panel

- **Trigger**: a background `odin check` (debounced 0.6 s after the source stops changing, polled every 0.3 s,
  editor states only) reported diagnostics for this file (09 runs it; this doc covers display).
- **Behavior**:
  - Each node containing a diagnosed saved line gets a **red wash** behind all its rows (x from `x0-6` to
    `max_x+6`, color 0.90,0.25,0.22 at alpha 0.14) and a **3 px `COL_ERR` bar** at its left edge.
  - The exact diagnosed line numbers turn `COL_ERR`.
  - The title bar shows `N problem(s)` in `COL_ERR`.
  - When the cursor is **on a line** (not on a dot) of a node with problems, an **error panel** is drawn at the
    right edge, 4 px *below* that node's last row (so the line stays readable), its top clamped to
    `[top + 4, bottom - panel_h - 4]`: width `min(500, 0.40*w)`, right edge at `w-28`; fill (0.99,0.91,0.89,0.98),
    2 px `COL_ERR` outline, text in dark red (0.45,0.08,0.08) in the UI font, 12 px left padding and 10 px top
    padding (text wrapped to `width - 24`; height = lines × UI line height + 20); one entry per diagnostic of that
    node,
    `line L:C  <message>` word-wrapped, a blank line between entries. Messages come from the compiler with the
    `Error:` tag stripped, `Syntax Error:` → `Syntax: ...`, `Warning:` → `Warning: ...`.
- **Rules & edge cases**: diagnostics are **only shown when they belong to the document exactly as it is now**
  (`current_diags` compares the checked source with the latest source seen by the 0.3 s poll): an edit hides them
  at the next poll and they stay hidden until a check of the new source finishes. Warnings are drawn exactly like
  errors (red) and are counted in `N problems`. The column is shown in the text but not used to shade a sub-line
  span. Only compiler lines of the form `<this file>.odin(L:C) ...` are kept (other files of the package and
  the compiler's source-excerpt / caret lines are dropped).
- **Source**: src/app/editor_view.odin (`draw_editor` problem pass, `draw_error_panel`, `wrap_text`),
  src/app/checker.odin (`current_diags`, `check_tick`, `CHECK_DEBOUNCE`, `CHECK_POLL`), src/model/diagnostics.odin
  (`Diag`, `parse_check_output`, `node_line_starts`, `node_for_line`).

### F14. Title-bar text: context hint, voice indicators, status line, banners

- **Trigger**: editor frames (hint, voice, banners); every frame (status line).
- **Behavior** (exact positions; all at y=14 in the UI font unless noted):
  - **Context hint** (right side of the title bar): its text (priority: Grab hints, then the word-by-word hint, then
    the model's `ctrl_hint` passed through `rebind_hint`; contents in 03 F18) is drawn in `COL_ACCENT` with its right
    edge ~340 px from the window's right edge: a paper rect `{w - 352 - hw, 8, hw + 24, 34}` first, text at
    `x = w - 340 - hw`. Grab texts: `Up/Down move   RT+Up/Down jump   X / A drop   B put back`; copy:
    `Up/Down move the copy   RT+Up/Down jump   X / A drop   B no copy`; blocked:
    `Outside a procedure: can't drop here   Up/Down move   B no copy`. Word-by-word texts (word_edit.odin
    `word_edit_hint`): on a word `A change   RT+B delete   B done`, on a yellow gap `A insert   LT+X say words
    B done` (3 spaces between items, as everywhere). Not drawn while picking a reference (the banner says it all);
    not suppressed while picking a declaration for a modifier. `rebind_hint` only rewrites segments that start with
    `Y: `, `LT+B: ` or `LT+A: ` (Change / Delete / Edit) to the action's current button, dropping the segment when
    the action has no button; the Grab and word-by-word texts are literals and are not rewritten (the Grab hint's
    `RT+Up/Down jump` names the default Walk buttons and goes stale if Walk is moved).
  - **Voice** (08): while recording `[REC]` in `COL_ERR` at `x = w-150`; while the words are being worked out
    `transcribing.` / `transcribing..` / `transcribing...` cycling 3 times a second at `x = w-190` in `COL_ACCENT`;
    otherwise the last result `heard: <text>` at `x = w-320` in `COL_ACCENT` (stays until the next dictation).
  - **Status line** (`set_status(msg, seconds = 2.0)`): one message, right-aligned 28 px from the right edge,
    `COL_ACCENT`, shown for `seconds` (the startup "something is missing" Setup hint uses 8 s). The model posts
    `app.notice` (static text), which the app moves into the status line each frame; a new message replaces the
    old one. Drawn after the HUD, on every screen (main menu, menus, overlays too). No backing rect. Examples
    posted by the app layer: `copied 6 lines` / `copied 1 line`, `nothing to copy`, `copy failed`,
    `no previous file yet`, `Heard "<text>" - not a number`, `opened <project>`, `Nothing to look up here
    (highlight a name, call, type or keyword)`, `already at the top`, `deleted <name> (in the Recycle Bin)`; their
    meaning lives in the docs of the features that post them.
  - **Banners** (editor): a full-width bar `{0, 51, w, 30}` in pale yellow (0.99,0.90,0.60,0.97) with centered
    dark-amber text (0.42,0.28,0.00): `Pick a name to reference   -   D-pad move   A use it   B cancel`, or
    `Pick a declaration for the attribute   -   D-pad Up/Down move   A choose   B cancel` (`a struct for the
    directive` / `a procedure for the calling convention`).
- **Rules & edge cases**: the hint, status, `[REC]` and `heard:` all share the y=14 strip and can overlap (the
  status has no background). The hint's paper backing exists "so a long file path under it doesn't show through".
  The hint, voice indicators and banners are drawn by `draw_editor`, so in state `.Radial` they are drawn and
  then covered by the construct menu's 95% veil (F16): while a menu is open, `[REC]`, `heard:` and the hint are
  effectively invisible; only the status line (drawn last) shows. Files search has its own `Listening...` (F19).
- **Source**: src/app/editor_view.odin (end of `draw_editor`), src/app/run.odin (`set_status`, `g_run_msg*`,
  `RUN_MSG_DURATION`), src/app/main.odin (status draw in `main`), src/model/keymap.odin (`rebind_hint`),
  src/model/ctrl.odin (`ctrl_hint`), src/model/word_edit.odin (`word_edit_hint`), src/model/modifiers.odin
  (`mod_pick_banner`).

### F15. Drawing the three-bank HUD

- **Trigger**: every frame, every screen (semantics, bindings and glyph rules: 03 F9).
- **Behavior**:
  - Band: `{0, h-150, w, 150}` in (0.90,0.86,0.78), 2 px `COL_RULE` on top.
  - Three banks centered at `w/6`, `w/2`, `5w/6`, vertical center `h - 150 + 69` (46% of the band). Labels
    `L-TRIGGER`, `DEFAULT`, `R-TRIGGER` centered in `{cx-100, h-30, 200, 24}`.
  - The **active bank** (LT held → left, RT held → right, else middle) is drawn at **scale 1.15**, alpha 1, label
    `COL_ACCENT`; the other two at **scale 0.82**, alpha 0.5, label `COL_DIM`. The switch is **instant**.
  - Per bank (scale `s`): d-pad centered at `cx - 82s`, face cluster at `cx + 82s`.
    - D-pad: the hand-drawn `dpad` icon, `64.4s` square (`46s * 1.4`), tinted (0.55,0.51,0.45,a). A bound
      direction gets a disc of radius `0.11 * size` in the same ink over that arm's notch (offset `0.30 * size` from
      the center) with the action's icon (size `0.22 * size`) or ASCII glyph (in a `0.26 * size` cell) in light ink
      (0.97,0.95,0.90,a). Without the icon file: a plus of two rects (arm `46s`, thickness `26s`) with glyphs on the
      arms.
    - What a slot shows (`slot_glyph`): an unbound d-pad direction shows nothing; an unbound face button shows
      its letter (`X` on the default bank's free X); a *fixed* action on a d-pad direction (the plain bank's
      Move_* arrows) shows nothing (no disc: the icon's own arrow notches say it); a Walk action on its
      own natural RT arrow (`walk_natural`) shows nothing; otherwise the action's ASCII glyph from
      `ACTION_INFO` (e.g. Select `+`, Back `<`, Change `*`, Edit `e`, Copy `C`, Run list `>`), or its icon when
      `action_icon` has one (Talk → speech, Delete → trash, Save / Save as → floppy, Files → folder, Copy → copy,
      Select → add, Back → back) and it loaded.
    - Face buttons: discs of radius `16s` at `±32s`: **Y top (0.92,0.78,0.25)**, **A bottom (0.30,0.78,0.42)**,
      **X left (0.28,0.52,0.90)**, **B right (0.86,0.30,0.30)**, alpha `a`. Content: the action's icon at
      `1.55 * radius`, dark ink (0.08,0.09,0.11,a) on Y/A, near-white (0.97,0.98,1.0,a) on X/B; else the glyph in
      dark ink (0.08,0.09,0.11) — note the glyph is drawn at full alpha even on a dimmed bank, so letters stay
      crisp on the half-transparent discs; when an icon file is missing, Talk / Delete fall back to a vector
      microphone / trash can drawn from rects and circles (`0.82 * radius`), other actions to the glyph.
    - **Mic glow**: while dictation could start (state `.Editor` — not in a construct menu — a dictatable part is
      highlighted per `model.dictation_target`, Whisper loaded, no overlay open), a ring around Talk's button in
      whichever bank holds it, active or not: outer radius `r + 4 + 2p`, 2.5 px, `COL_DOT` at alpha `0.35 + 0.4p`,
      `k = 5`. Never on the Key Layout page's diagrams.
  - On the Key Layout page the HUD previews the bank of the page cursor's card.
- **Rules & edge cases**: drawn from the live keymap every frame (rebinding shows at once). Menus and pages keep
  their content above `h - 185` so the HUD plus one hint line fit.
- **Rationale**: UX.md: "A persistent glyph HUD along the bottom always shows what each button does right now (this
  is the single most important affordance — never make the user guess)."
- **Source**: src/app/main.odin (`HUD_LABELS`, `draw_hud`, `draw_bank`, `bank_slot_pos`, `draw_face_btn`,
  `draw_face`, `slot_glyph`, `action_icon`, `draw_mic_icon`, `draw_trash_icon`).

### F16. Drawing construct menus (the grid called "radial")

- **Trigger**: state `.Radial` (any Add / Fill / Change / Edit / IDE menu; contents in 04-07, controls in 03 F12).
- **Behavior**:
  - The editor is drawn first, then a full-screen `COL_VEIL` (95% opaque: the code is hidden but the sheet still
    feels like the same paper).
  - **Breadcrumb** above the title when nested: the titles of the views passed through joined by `  >  ` and ending
    `  >` (e.g. `Fill slot  >  Constant  >  win.  >`), `COL_DIM`, centered in a full-width 28 px box whose top is
    at `0.07h - 34`; if wider than `w-80`, leading titles are dropped one at a time and `..  >  ` is prefixed
    (at least the nearest title is kept).
  - **Title** (the current view's title) centered in a full-width 36 px box whose top is at `0.07h`, in
    `COL_ACCENT`. When the menu is filling a slot (`slot_menu` set) whose field has an expected-type label, a line
    under it (24 px box at `0.07h + 30`) in `HINT_COL`: `expects <T>  -  grayed options don't fit` (`..T` for a
    variadic dot; `..any` when anything fits).
  - A view with **no entries** shows only the veil, breadcrumb, title and expects-line: no grid, no footer.
  - **Grid**: columns `grid_cols(n)` = smallest `c` with `c*c >= n`, capped at 8 (1→1, 4→2, 5..9→3, 16→4, 64+→8).
    Cell height 44, horizontal gap 12, vertical gap 8, side margin 40. **Cell width = longest label + 24, clamped to
    220..480**, then shrunk only if the columns would not fit (`(w - 80 - (cols-1)*12) / cols`). The grid is centered;
    it starts at `0.14h`.
  - **Cells** (drawn in this order: fill, heat smudge (F17), outline, label): fill `COL_PANEL`; "recently used"
    cells fill (0.80,0.90,0.87) with a 1 px teal (0.08,0.46,0.44) outline; the selected cell `COL_HILITE` + 2 px
    `COL_ACCENT` outline (a selected recent cell looks like any selected cell). Label centered, cut to
    `cell width - 10` with `..` (`fit_label`); grayed (`dim`) entries in `COL_DIM`, others `COL_TEXT`.
  - **Sections**: when the view has a recent section, captions `RECENTLY USED` (teal, left-aligned at the grid's
    left edge, at the grid top) above it and `ALL` (`COL_DIM`) above the rest (caption height 24, +4 gap); the rest
    starts on a new row. The column count is `grid_cols(total entries)` for both sections. Captions and their
    offsets exist only while the view is scrolled to show the recent rows (`first_row < recent_rows`); scrolled
    further down, the grid is drawn without captions (`ALL` is also skipped when its row is below the visible
    rows). Two caption heights are subtracted from the room when counting visible rows.
  - **Full label**: if any label had to be cut, room is reserved under the grid all the time (the grid's bottom
    moves from `h-185` to `h-220`), and the selected entry's full label (itself cut to `w-80`) is drawn centered at
    `h-196` whenever it is the one that was cut.
  - **Scrolling**: visible rows = `(bottom - 0.14h - 2*caption_h) / (44 + 8)` (at least 1); the first row keeps
    the selected row roughly centered (`sel_row - visible/2`, clamped); `^ more` (22 px box at `0.14h - 26`) /
    `v more` (at `bottom + 2`) centered, in `COL_DIM`, when rows are hidden.
  - **Footer** (24 px box at `h-172`) in `COL_DIM`: `<i> / <n>     D-pad move   + select   < back` (1-based index,
    5 spaces after the count). `+` and `<` are the ASCII glyphs of the Select and Back actions (`ACTION_INFO`); on
    the HUD those buttons show the add / back icons instead when the icons are loaded (`action_icon`). The
    screenshots still show `+` and `<` on A and B while other icons are present, so they predate that mapping.
- **Rules & edge cases**: grayed entries are shown, never hidden, and stay selectable (what A does on them is the
  menu's business, 06). The name "radial" is historical: the first slice (commit 5d2bea9) had a "green-dot
  radial"; e8dfe4a made menus grids; 79a7b87 replaced alphabetical bucketing with the flat, 8-wide, vertically
  scrolling grid (main.odin: "A flat, alphabetical, 8-wide grid that scrolls vertically"); bf5ec80 made the
  column count square-preferring (`grid_cols`).
- **Rationale**: commit 63c2e8c: "Menu boxes are as wide as the menu's longest label needs (220 to 480 px ...) so
  short menus like Reference > Pass as show `win32.LPCWSTR(name)` ... in full. When a label still doesn't fit, the
  highlighted entry's full text is shown under the grid (room kept for it, so the grid doesn't jump)."
- **Source**: src/app/main.odin (`draw_radial`, `fit_label`, `RECENT_BG`, `RECENT_COL`), src/model/model.odin
  (`GRID_COLS`, `grid_cols`, `MenuView`, `current_view`), src/model/menu_sections.odin (`menu_cell`, `menu_rows`).

### F17. Worn menu cells (the heatmap smudge)

- **Trigger**: drawing any construct-menu cell whose trail has been used (how uses are counted, keyed and saved to
  `doodle_heat.tsv`: 03 F13-F14).
- **Behavior**: `shade = clamp(ln(1 + uses) / ln(1 + 40), 0, 1)` (0 for no uses; full at 40). The border color is a
  warm graphite (0.29,0.23,0.17) with alpha `0.18 + 0.67 * shade`; width 1 px when `shade < 0.5`, 2 px otherwise.
  Plain cells get the border on their own edge, and above 0.5 a faint darkening fill of alpha
  `0.04 * (shade - 0.5) * 2` (at most 4%). Selected and recent cells, which already have an outline, get the smudge
  as a ring outside the cell, separated from it by a 2 px gap (the ring's outer edge is `2 + width` px out). The four sides are drawn as non-overlapping rects (top and bottom full
  width, sides between them).
- **Rules & edge cases**: purely visual; no shade, no border. Trails are identical in every project, so the same
  path looks worn wherever you go.
- **Rationale**: main.odin: "cells on the way to things you used before get a warm graphite 'smudge' border, darker
  the more they were used"; "Not draw_rect_outline: its sides overlap at the corners, which would show as darker
  dots with a translucent color."
- **Source**: src/app/main.odin (`SMUDGE_COL`, `draw_smudge`), src/model/heat.odin (`heat_shade`, `view_shade`,
  `HEAT_SATURATE`).

### F18. The main menu screen

- **Trigger**: state `.Menu` (startup, Back from the editor).
- **Behavior**: on paper: `DOODLE` centered at `0.20h` (60 px tall box) in the 28 px font, `COL_ACCENT`; below it
  `Odin IDE  -  gamepad native` in `COL_DIM`. A centered grid of `New Project`, `Recent Projects`, `Open Folder`,
  `Key Layout`, `Settings` (3 columns: 3 + 2), cells 240x56, gaps 14 / 12, starting at `0.44h`; selected cell
  `COL_HILITE` + 2 px accent outline, others `COL_PANEL`; `Open Folder` in `COL_DIM` (not wired), the others in ink.
  A hint `D-pad / Arrows to move    A / Enter to select    (Open Folder not wired yet)` at `0.84h`. The HUD is drawn
  below as on every screen.
- **Rules & edge cases**: at the default 800 px height the hint's box (y 672..702) falls inside the HUD band
  (650..800), and the HUD is drawn later, so the hint is fully covered; it only shows on windows at least ~1125 px
  tall (`0.84h + 30 <= h - 150`). This follows directly from the coordinates (home.png agrees: no hint visible);
  nothing in the code or docs says whether it is intended. The Recent Projects and New Project overlays draw over
  this screen (F19); Key Layout and Settings draw later in the overlay order. When replaying an old recording
  (`menu_legacy`), `menu_items` drops `Settings` (4 items → 2 columns). The menu uses the same wrap-around
  `grid_nav` as construct menus; B on the main menu quits. docs/screenshots/home.png predates `Key Layout` and
  `Settings` (it shows 3 items in 2 columns).
- **Source**: src/app/main.odin (`draw_menu`), src/model/model.odin (`MENU_ITEMS`, `menu_items`).

### F19. Overlay and page chrome (one consistent look)

- **Trigger**: any overlay that owns input (behaviors in 03, 09).
- **Behavior** — the shared conventions:
  - A full-screen `COL_VEIL` first (Key Layout uses an opaque version, (0.84,0.80,0.72,1), "this is a whole page").
  - An UPPERCASE title centered in a 36 px box at `0.07h` in `COL_ACCENT` (`RUN COMMANDS`, `RECENT PROJECTS`,
    `SETTINGS`, `NEW PROJECT  -  WHERE?`, `ADD A PROJECT FOLDER`, `KEY LAYOUT` (its top is clamped to 12..56 px),
    `LIBRARY NOT ON YOUR PATH` (Windows) / `LIBRARY NOT ON YOUR LIBRARY PATH` (any other OS),
    `STB LIBRARIES NOT BUILT YET`). Exceptions: the Run list's template submenu (`Choose a template:` at `0.25h`),
    Files (its own header on the sheet), the docs panel (the looked-up name) and the Save/Rename dialog (title
    inside its box).
  - Content from about `0.15h`, kept above `h-185` where the list scrolls (Recent Projects, New Project and its
    browser); lists scroll to keep the selection roughly centered, with `^ more` / `v more`; rows use `COL_PANEL`,
    the selected one `COL_HILITE` + 2 px accent outline. The Run list and Settings do not scroll and can run under
    the HUD.
  - The overlay's own fixed controls as one hint line centered at **`h-172`** in `COL_DIM`, just above the HUD:
    Run list `D-pad move   A select   Y favorite   B back`; template submenu `Up/Down select   A confirm   B back`;
    Settings `D-pad move   A switch / install   B back`; Recent Projects `<i> / <n>     D-pad move   A open   B back`
    (just `B back` when empty); New Project `D-pad move   A create the project here   B back` (on an added folder
    `D-pad move   A create the project here   X remove from list   B back`, on the add row `D-pad move   A pick a
    folder to add   B back`); its browser `D-pad move   A open folder   Left up a level   B cancel` (on the "use"
    row `A add this folder   D-pad move   Left up a level   B cancel`); the library-path and stb prompts
    `D-pad move   A choose   B cancel`. Exceptions: Files puts its hints under its sheet; the Save/Rename dialog and
    the Files delete box put theirs inside the box; the docs panel puts `Up/Down scroll   B close` in its header;
    the Key Layout footer sits at `min(h-172, cards' bottom + 12)`.
  - Dialog boxes are centered in the area above the HUD: `y = (h - 150 - box_h) / 2` (Save/Rename, Files delete).
    Each overlay draws its own veil, so a dialog over Files (Rename) stacks two veils.
- **Specific screens** (visual specifics only):
  - **Files (RT+B)**: a full-width paper sheet `{24, 56, w-48, h-266 - (hint lines - 1)*26}` with a 1 px
    `COL_RULE` outline; header `FILES` or `SEARCH` in accent with the files / search icon (26 px), a breadcrumb at
    x+120 `root  >  a  >  view` (the view in accent, the rest dim, front-trimmed with `..  >  `; the view's name
    gets `  (+N folders)` when more sibling folders exist than columns; in search mode the breadcrumb is just the
    root folder, dim), a rule at +40. One column per folder (196 px cells + 8 px padding each side, 22 px between
    columns), outlined 1 px `COL_RULE`: a tab (32 px tall, a tiny blue folder glyph and the folder name with a
    trailing `/`; the "here" tab — the view's own files — raised by 8 px, paper-filled with a green outline and
    green title; any tab holding the open file gets a small 3.5 px `COL_DOT` disc at its right; `+N` dim when the
    column has more entries than shown; a selected tab is `COL_HILITE` + 2 px accent) above cells of 196x34 (6 px
    gaps). File cells: `COL_PANEL`, `.odin` names in ink, others dim; the open file filled pale green
    (0.84,0.92,0.84) with accent text and a trailing `  *`. Folder cells: paper with a 1 px blue (0.15,0.35,0.70)
    outline, a tiny folder glyph and the name + `/` in the same blue. A selected cell of either kind is
    `COL_HILITE` + 2 px accent with ink text. `(empty)`, `(can't open)`, `^` (the column's files are scrolled
    above), and, when the only column is an empty "here" folder, `X makes a new file here` beside it. Scroll marks
    `<` `>` at the grid's sides and `^ more` / `v more` at the sheet's top/bottom right. Search: `find: <query>
    (N)` (3 spaces before the count) in ink, `(hold X and say part of a file name)` as the empty query,
    `Listening...` while recording, rows in the file-cell style across the sheet, centered on the cursor, `^`/`v`
    in a gutter at their right, `(no matching files)`. Under the sheet the button hints in `COL_DIM`, packed with 3
    spaces between parts into as many lines as the width needs (`FN_HINT_STEP` 26 px; the sheet shrinks so they
    stay above the HUD): grid `D-pad move   A open / drop in   B back` (`B up a level` after dropping into a
    folder) `   X new file   LT+X rename   LT+B delete   Y search   RT+B prev file`; search `Up/Down move   A open
    hold X say a name   B back to the folders`; then `open: <path>` in accent.
  - **Delete confirmation** (Files, LT+B): its own veil, then a `min(680, w-80)`x200 `COL_PANEL` box with a 2 px
    **red** outline, red title `Delete <name> ?` / `Delete folder <name>/ ?` with the trash icon (26 px) left of
    it, the consequence in ink — `It goes to the Recycle Bin (you can restore it from there).` or `The folder and
    everything in it (N files) go to the Recycle Bin.` (`1 file`; `400+ files` at the count cap) — an amber note
    `This is the open file: the editor keeps its text, unsaved.` when the open file is in it, and
    `A delete    B keep it` (4 spaces) in `COL_DIM` near the box's bottom.
  - **Docs panel (LT+Y)**: a paper sheet `min(w-80, 1100)` wide, centered, from y=70 to `h-170` (20 px above the
    HUD) with a 2 px `COL_RULE` outline, 22 px padding; header = the name in accent (red if not found), its
    location dimmed 18 px after it, `Up/Down scroll   B close` right-aligned; a rule; the declaration in the
    **code font** on a darker band (0.89,0.86,0.78), wrapped to the panel width - 16 and indented 8 px; a gap of
    0.6 UI line; the comment in the UI font, wrapped; `(no comment above the declaration)` only when there is
    neither a declaration nor a comment; `^` / `v` when scrolled. Tabs display as 4 spaces. Left/Right scroll a
    page; A and Y close it too (not shown in the hint).
  - **Save as / Rename**: a 760x250 `COL_PANEL` dialog, 2 px accent outline, title `SAVE AS` (with the save icon) or
    `RENAME <file>`; a 48 px paper name box with a 2 px `COL_HILITE` border (`COL_ERR` while recording, plus
    `[REC]`); a prefilled name is shown "selected" (`COL_SEL_BG` behind it: typing replaces it); otherwise a 2 px
    caret blinking at 1 Hz (on 0.5 s, off 0.5 s); `in <folder>` dimmed, or `saves as <name>  in <folder>` /
    `renames to <name>  in <folder>` when cleaning changed the typed name; amber
    `<name> already exists - press A again to overwrite`; red errors. Its hint inside the box: `A save    B cancel
    hold X to say a name    (keyboard: type)` (`A rename` when renaming; without speech-to-text
    `A save    B cancel    (keyboard: type a name)`), 4 spaces between parts.
  - **Run list**: grid (`grid_cols`) of 280x50 cells, gaps 12/10, starting at `0.16h`, each command's text cut with
    `..` to the cell, favorite prefixed `* `, a last dim `+ New command` cell; with no commands at all only
    `+ New command` in ink at `0.4h` and no hint. Template submenu (replaces the grid, keeps the veil): `Choose a
    template:` in accent at `0.25h` and a 400x44 list (8 px gaps) from `0.35h`.
  - **Settings**: 760x48 rows with 40 px between them for a dim description line; value `On` in accent, `Off` dim;
    a `SETUP` caption; setup values colored by state (good = accent, bad/missing = red, busy/info = dim).
  - **Recent Projects**: `min(720, w-80)`x48 rows (8 px gaps), name on the left (`<name>   (in <folder>)` for a
    project in an added folder), age (`model.age_label`) right-aligned and dim; empty state (dim, at `0.35h`)
    `No saved projects in <dir> yet - save one with <slot>` where `<slot>` is Save as's current button.
  - **New Project**: `min(820, w-80)`x64 two-line rows: `In default folder` / `In <folder>` in ink, the path
    under it dim (`<path>  (not found)` amber when missing; after one X on an added folder the line reads
    `press X again to remove it from the list (the folder stays on disk)` in red and the selection outline turns
    red); the last row `Add another folder...` with the add icon (24 px, accent). Its folder browser: title
    `ADD A PROJECT FOLDER`, the current folder (or `Drives`) dim under it, 44 px rows of `<name>/`, a first
    `Use this folder (<name>)` row in accent with the add icon, `Nothing here` when empty.
  - **Key Layout page**: three bank cards (paper, 2 px outline, accent for the cursor's card) each with the HUD's
    bank diagram (scale fitted, dropped on short windows) and one row per button with a colored chip; the cursor's
    button pulses a ring on the diagram (`k=4`); a slot that just received a swapped action **glows amber** for
    1.4 s, fading linearly, with a `moved` tag ("not the cursor's green: it mustn't read as a second selection"); the
    reset question covers the cards ("a destructive question, so it covers the cards and the cursor goes away");
    refused picker cells are dimmed with a short reason. Exact strings: footer `D-pad move   A change   X clear
    Y reset all   LT/RT jump   B done     (LB tests, RB run are fixed)` (the parenthesized aside is dropped when
    it doesn't fit), `A reset   B keep` during the reset question, `D-pad move   A assign   B cancel` in the
    picker; subtitle (`HINT_COL`) `<slot>: <action>  -  <hint>`, `<slot>: fixed - always moves / selects / goes
    back` on a locked slot; reset box `Reset every button?` / `Your layout goes back to the one Doodle ships
    with.` / `A reset        B keep`; picker title `<slot>: pick an action`, each cell's second line one of
    `this button` (accent), `now on <slot>`, `no button yet`, `RB (fixed)` / `LB (fixed)`, or (refused, dimmed)
    `would push <action> to <slot>`, `face buttons only`, `needs a trigger`, `not here`, `<action> needs this
    button`, `fixed` (short forms `can't swap`, `face only`, `trigger only`, `can't replace` in narrow cells);
    a refused selection's reason also replaces the subtitle in `COL_WARN`. The diagram on the cards is drawn at
    full alpha with no mic glow; the cursor ring is 2.5 px accent, radius `(10 on a d-pad arm | 16) * s + 5 + 2p`.
- **Source**: src/app/filenav.odin (`draw_filenav`, `hint_lines`, `draw_breadcrumb`, `draw_grid`, `draw_tab`,
  `draw_cell`, `draw_search_rows`, `draw_delete_confirm`, `FN_*`), src/app/docs_panel.odin (`draw_doc_panel`),
  src/app/save_dialog.odin (`draw_save_dialog`), src/app/run.odin (`draw_run_overlay`, `draw_template_submenu`),
  src/app/settings.odin (`draw_settings_page`), src/app/projects.odin (`draw_projects_overlay`),
  src/app/new_project.odin (`draw_new_project_overlay`, `draw_np_browser`), src/app/keys_page.odin
  (`draw_keys_page`, `keys_layout`, `draw_keys_card`, `draw_keys_row`, `keys_draw_flash`, `draw_keys_reset_prompt`,
  `draw_keys_picker`), src/app/vendor_path.odin, src/app/stb_build.odin.

### F20. Glow and pulse animations (catalog)

- **Trigger**: continuous; every animation is `f(g_time)` with no per-object state except the Key Layout flash.
- **Behavior**: `p = 0.5 + 0.5 * sin(g_time * k)`.

  | What | k (rad/s) | Period | Effect |
  |---|---|---|---|
  | Fill-me slot dots (always) | 3 | ~2.1 s | core radius 5..6.5 (halo 4 px wider), halo alpha 0.18..0.38 |
  | Cursor's green / body / attribute / word dot | 4 | ~1.6 s | halo grows 1.5 px, alpha +0.18 |
  | Grab box glow | 4 | ~1.6 s | glow alpha (0.20..0.35) / k for the k-th ring, fill 0.14..0.20 |
  | Key Layout cursor ring | 4 | ~1.6 s | ring radius +2 |
  | Mic-ready ring on Talk's HUD button | 5 | ~1.3 s | radius `r+4` .. `r+6`, alpha 0.35..0.75 |
  | Reference-pick ring | 6 | ~1.0 s | outer radius 11..13 |
  | Save dialog caret | — | 1 s | `int(t*2) % 2 == 0` → visible |
  | `transcribing...` dots | — | 1 s | `int(t*3) % 3` picks 1, 2 or 3 dots (each shown 1/3 s) |
  | Key Layout "moved" flash | — | 1.4 s once | amber outline + tag, alpha `1 - age/1.4` |

- **Rules & edge cases**: nothing tweens position or size; scrolling and HUD bank scaling jump. There are no
  flashing reds: problems are steady.
- **Source**: as listed in F10-F19.

### F21. Icons

- **Trigger**: startup load; drawn in the HUD, the Key Layout page and a few overlays.
- **Behavior**:
  - Hand-drawn, wobbly-edged "stamp" pictograms with paper grain (assets/icons/preview.png shows five of them —
    speech-to-text, delete, save, navigate-files, dpad — in orange #EC5B2B on cream). Each icon exists as `<name>.svg` (orange fill), `<name>-currentColor.svg`, and PNGs at 64 and
    512 px. Doodle loads the **512 px PNGs**, forces RGB to white keeping alpha (a mask), uploads them **mipmapped**,
    and tints them per draw (`draw_icon(icon, cx, cy, size, color)` → a textured quad).
  - Icons and their uses (`Icon` enum → file):

    | Icon | File | Used for |
    |---|---|---|
    | Speech | speech-to-text-512.png (speech bubble with wavy lines) | Talk on the HUD / Key Layout |
    | Delete | delete-512.png (trash can) | Delete action; Files delete confirmation title |
    | Save | save-512.png (floppy disk) | Save and Save as actions; `SAVE AS` dialog title |
    | Files | navigate-files-512.png (folder with arrow) | Files action; `FILES` header |
    | Dpad | dpad-512.png (cross) | every HUD / Key Layout d-pad |
    | Add | add-512.png | Select action (A); `Add another folder...`, `Use this folder (...)` rows |
    | Back | back-512.png | Back action (B) |
    | Copy | copy-512.png | Copy action |
    | Search | search-512.png | `SEARCH` header in Files |
    | (paste) | paste-*.png | shipped, unused ("for when Doodle gets a paste command") |

- **Rules & edge cases**: `draw_icon` returns false when an icon didn't load; every caller then falls back (vector
  mic / trash can, the plain plus d-pad, or the ASCII glyph); headers and rows simply omit the icon. Icon ink: dark on light buttons (Y, A), near-white on
  dark ones (X, B), `COL_TEXT` / `COL_DIM` in lists, accent in headers, red in the delete box.
- **Rationale**: icons.odin: "Loaded once at startup as white alpha masks, so each draw can tint them to whatever
  color suits its background"; "512px sources; mipmapped, so they stay clean at HUD sizes (~20-60px)."
- **Source**: src/app/icons.odin (`Icon`, `ICON_FILES`, `load_icons`, `unload_icons`, `draw_icon`),
  src/app/main.odin (`action_icon`, fallbacks), assets/icons/.

### F22. Sounds: pencil scribble and paper crumple

- **Trigger and exact conditions**:
  - **Pencil** (`sfx_pencil`): at the end of a frame's input handling, when the state was `.Editor` or `.Radial`
    both **before and after** the frame, **no file was loaded** this frame (`g_file_loads` unchanged), and the
    **code size grew**: `code_size` = total bytes of all non-slot fields of all nodes. So: inserting a construct,
    filling a slot, a dictated name that is longer, a format that adds characters → pencil; deleting, shortening,
    moving the cursor, opening a menu, starting a New Project (state was `.Menu`), opening a file → silence. Also on
    the Key Layout page when an action is **assigned** or **swapped** onto a button.
  - **Paper** (`sfx_paper`): opening a file from Files or its search (`filenav_open_file`), opening a project from
    Recent Projects (same proc), switching to the previous file (`filenav_alt_tab`, from Files or the Prev_File
    action), going **up** a folder level or **dropping into** a folder in Files, toggling a setting, resetting the Key
    Layout. Not on the startup file given on the command line (it uses `filenav_load` directly).
- **Behavior** (a tiny mixer):
  - Clips: `assets/sounds/pencil-1.wav`, `pencil-2.wav`, `paper-crumple.wav`, required format **mono, 16-bit
    little-endian, 44100 Hz** (anything else is skipped); made by `tools/convert_sounds.py` (downmix, resample, peak
    normalize to ~-1 dB). Licenses: CC BY 4.0 / CC BY 3.0 / CC0 (assets/sounds/README.txt).
  - Each play is a **random slice** of a longer recording: pencil 0.35..0.6 s at gain 0.6 (randomly pencil-1 or -2,
    the other if one is missing); paper 0.22..0.38 s at gain 0.55. The slice start is the loudest of up to 10 random
    tries, stopping early at one with RMS >= 80% of the whole clip's RMS (no near-silent slices).
  - Envelope: 15 ms linear fade-in ("no click"), 90 ms fade-out at the end ("slices trail off rather than cut").
  - Two groups (Paper, Pencil); **a new sound fades out the one already playing in its group** (its end is moved to
    now + 90 ms), so fast edits don't pile up. 8 voices; if none is free the new sound is dropped.
  - SDL audio device: mono S16 44100 Hz, 512-sample buffer, a callback that sums active voices with clamping; the
    voice table is modified only under the device lock.
- **Rules & edge cases**: optional — no audio device or no clips → every call is a no-op. Silent during trace
  replays. No volume control or mute setting.
- **Rationale**: sound.odin header: "Paper crumpling when switching files, pencil scribbles when code is added.
  Optional." main.odin: "Code was added to the open document (not a file load / new project): pencil."
- **Source**: src/app/sound.odin (`sound_init`, `sfx_paper`, `sfx_pencil`, `play_slice`, `rms`, `sfx_mix`,
  `FADE_IN`, `FADE_OUT`), src/app/main.odin (`code_size`, pencil check in `main`), src/app/filenav.odin
  (`filenav_open_file`, `filenav_alt_tab`, `fn_up_level`, `fn_descend`, `g_file_loads`), src/app/keys_page.odin
  (`keys_feedback`), src/app/settings.odin (`handle_settings_input`), src/app/projects.odin.

### F23. Developer overlays: trace banner, recording dot, screenshots

- **Trigger**: debug builds with the trace harness (docs/TRACE.md); not in release builds.
- **Behavior**: while recording (every debug run, unless `--no-trace` / `DOODLE_TRACE=0`), a small red dot (r4,
  (0.78,0.18,0.18) at alpha 0.55) at (14,14) — over the title bar's path. While replaying, a pale-yellow banner at
  the top left (`{8, 6, text_w+20, 28}`, fill (0.98,0.90,0.62,0.95), 1 px amber (0.70,0.42,0.00) outline, text at
  (18,10)): `REPLAY PLAYING|PAUSED|END  frame N / M   <controls>` with controls `Back/F6 pause   Start/F5 take
  over` (playing), `Right/F7 step   Back/F6 resume   Start/F5 take over` (paused), `Start/F5 take over` (end);
  once the replay stopped matching, `   (diverged at frame N)` is appended and the whole banner text turns red. In
  a live (taken-over) session the banner shows the harness's status text instead. `--screenshot F` reads the framebuffer after the last replayed frame (`glReadPixels`, rows flipped,
  alpha forced to 255) and writes a PNG; the banner is hidden for that frame.
- **Rationale**: TRACE.md: `script ... --shot PNG` "Use it to check UI changes without a controller."
- **Source**: src/app/trace.odin (`trace_draw`, `trace_after_draw`).

## Invariants & constraints to carry forward

1. **HARD** (code + tests) — What you see is what gets saved: the editor's row split for long calls and the
   serializer's line split come from the same functions (`layout_node` and `node_source_lines` both call
   `call_rows` + `needs_break`), so a line saved broken is shown with the same rows (the saver additionally drops
   unfilled optional dots and aligns struct-literal `=`; F8). The saved form is pinned by format_test.odin
   (`test_long_call_saved_one_arg_per_line`, `test_call_rows_plan`, ...); nothing tests the display side.
2. **HARD** (code + test) — Line numbers are the checked source's line numbers (`node_line_starts` over
   `node_source_lines`); a node saved on several lines numbers each of them, screen-only rows get none.
   (test_node_line_starts.) They equal the file on disk except below an editor-only `●` statement line, which
   `save_source` drops (F7).
3. **HARD** (code) — The code font is re-fitted every frame so 80 columns fit, within 13..28 px; the formatter breaks
   at the same 80.
4. **HARD** (code) — The model package has no rendering dependencies (model.odin: "NO dependencies on
   gpu/platform/text so it can be unit-tested"; it imports only `core:`/`base:` packages). Drawing never mutates
   the document; it does write app view state (`g_scroll`, list scroll positions, `g_doc_scroll`) and, through
   `current_highlight` → `tree_ensure`, may lazily rebuild the model's RT selection path.
5. **HARD** (code) for the HUD — The HUD, the Key Layout page and the `<slot>` names in a few hints are drawn from
   the live keymap each frame. **SOFT / partial** for title-bar hints: `rebind_hint` rewrites only the `Y: `,
   `LT+B: `, `LT+A: ` segments of model hints; the Grab and word-by-word hints are literals, and overlays' fixed
   controls are hard-coded strings (they really are fixed).
6. **HARD** (code) — The HUD is drawn on every screen, on top of every overlay (it is drawn after all of them, every
   frame). **SOFT** (convention, with exceptions listed in F19) — overlays keep content above `h-185` and put their
   control hint at `h-172`.
7. **HARD** (code) — Diagnostics are shown only for the exact current source; stale ones are hidden.
8. **HARD** (code) — Text atlas is ASCII 32..127; glyph strings (HUD, labels) must be ASCII. (Carry forward the
   *rule* "UI text must render in the shipped font", not the ASCII limitation.)
9. **HARD** (tests) — `grid_cols` is square-ish and capped at 8; recent sections start their own rows.
   (test_grid_cols_prefers_square, menu_sections_test)
10. **HARD** (test) — Heat shade is `ln(1+n)/ln(1+40)` clamped, strictly rising to 1 at 40. (test_heat_shade_curve)
11. **SOFT** — Selected = pale blue fill + 2 px green outline, everywhere; in code, translucent blue + green outline.
12. **SOFT** — Green ink on a name means "editable" (rename / dictate); green dots mean "add here / add another";
    orange / blue / violet pulsing dots mean "a hole to fill" with the color naming what kind; the steady pink
    capture dot is an option, not a hole; purple = attributes; yellow = word gaps inside a string being edited.
13. **SOFT** — Grayed means shown in faded ink, still selectable; never hide options.
14. **SOFT** — Only the cursor's insertion dot pulses; fill-me slots always pulse; options stay still. All pulses
    use one global clock.
15. **SOFT** — Red is only for problems and destructive confirmations; nothing flashes.
16. **SOFT** — Draw order is z-order; the title bar is drawn after the code; the status line after the HUD.
17. **SOFT** — Sounds are optional, short, faded, grouped (a new one fades out its group), never block, and are
    silent during replays. Pencil = code grew in the editor without a file load; paper = switching files/folders.
18. **SOFT** — Menu cells are sized to their labels (220..480 px) and never jump: room for the full selected label is
    reserved whenever any label is cut.
19. **SOFT** — The view follows the cursor with a margin: the cursor row's top stays within
    `[top + lh, bottom - 2*lh]`, i.e. one free row above it and one below it; no free scrolling.

## Data model & formats

**View-side types (app layer, all per-frame temporaries except where noted)**

- `Item` (one drawable piece of a node): `fi` (field index; -1 for a row-plan `,`), `text` (tabs expanded), `col`
  (color), `dot` (bool), `label` (a dot's expected-type label), `wstop` (word-by-word: 1 + stop index; odd = a yellow
  dot, even = a word; 0 = not word editing), `x`, `w`, `row`.
- `Node_Layout`: `items`, `rows` (visual row count), `y` (top of the first row, before scroll), `num_rows` (pairs of
  visual row → saved-line offset for line numbers).
- `Row_Span` (model, format.odin): `start, end` (field range), `extra_indent`, `suffix` (`","`), `is_arg`.
- `Highlight` (model, selection.odin): `ni, end_ni` (node range), `fa, fb` (field range; `fb < 0` = whole lines).
- Persistent view state (globals in the app): `g_code`, `g_code_px` (code font), `g_ui` (UI font), `g_scroll`,
  `g_time`, `g_run_msg` / `g_run_msg_time` / `g_run_msg_hold` (status line), `g_heard`, `g_recording`,
  `g_stt_busy`, `g_mic_ready`, `g_walk_held`, `g_keys_flash`, per-overlay scroll positions.

**Renderer types** (gpu.odin): `Color` = `[4]f32` RGBA 0..1; `Rect {x, y, w, h}`; `Vertex {pos: vec2, uv: vec2,
col: vec4}`; `Texture {id, w, h}`; `Renderer {program, vao, vbo, proj_loc, white, cur_tex, verts}`; `MAX_VERTS =
65536`. **Font** (text.odin): `atlas`, `chars[96]` (stb baked chars), `px_size`, `ascent`, `line_height`; atlas 512x512,
chars 32..127.

**Enumerations**

- `Hl` (highlight classes): `Plain, Keyword, Type, String, Number, Constant, Comment, Func, Package`.
- Slot field kinds with a distinct look: `value`, `ret_more` (orange); `type`, `variant`, `res_more` (blue); `params`
  (violet); `capture` (pink, in the indentation); `body`, `args`, `fields` (small steady green); anything else
  (neutral orange). Dots not attached to fields: top-level insertion, body insertion (green), attribute (purple),
  word (yellow), reference ring (amber).
- `Icon`: `Speech, Delete, Save, Files, Dpad, Add, Back, Copy, Search`.
- `Sfx`: `Crumple, Pencil1, Pencil2`; `Sfx_Group`: `Paper, Pencil`.
- `State` (what screen is drawn): `Menu, Editor, Radial`.

**Full color table** (RGBA floats; besides F5/F6/F10):

| Name | RGBA | Where |
|---|---|---|
| `RECENT_BG` | 0.80, 0.90, 0.87, 1 | recently-used menu cells |
| `RECENT_COL` | 0.08, 0.46, 0.44, 1 | their outline, `RECENTLY USED` caption |
| `SMUDGE_COL` | 0.29, 0.23, 0.17 (alpha by shade) | heat border |
| `COL_ATTR_DOT` | 0.55, 0.22, 0.88, 1 | attribute dot |
| `COL_WORD_DOT` | 0.90, 0.68, 0.05, 1 | word-by-word dots |
| `COL_DOC_CODE_BG` | 0.89, 0.86, 0.78, 1 | docs panel declaration band |
| `KEYS_PAGE_BG` | 0.84, 0.80, 0.72, 1 | Key Layout page |
| `KEYS_DPAD_COL` / chip ink | 0.55, 0.51, 0.45 / 0.97, 0.95, 0.90 | d-pad ink, glyph ink on discs |
| face Y / A / X / B | 0.92,0.78,0.25 / 0.30,0.78,0.42 / 0.28,0.52,0.90 / 0.86,0.30,0.30 | HUD and Key Layout |
| icon ink dark / light | 0.08, 0.09, 0.11 / 0.97, 0.98, 1.0 | icons on face buttons |
| `FN_FOLDER_COL` | 0.15, 0.35, 0.70, 1 | folder cells and glyphs |
| `FN_OPEN_FILL` | 0.84, 0.92, 0.84, 1 | the open file's cell |
| banner fill / text | 0.99, 0.90, 0.60, 0.97 / 0.42, 0.28, 0.00 | reference / declaration picking |
| error panel fill / text | 0.99, 0.91, 0.89, 0.98 / 0.45, 0.08, 0.08 | problems at the right |
| red wash | 0.90, 0.25, 0.22, 0.14 | lines with problems |
| block band | 0.22, 0.40, 0.70, 0.25 | whole-line / block selection |
| grab orange glow / fill / edge | 1.00,0.55,0.10 / 1.00,0.60,0.15 / 0.95,0.50,0.05,0.95 | lifted lines |
| grab red glow / fill / edge | 0.90,0.15,0.12 / 0.95,0.20,0.15 / 0.80,0.10,0.08,0.95 | can't drop here |
| ref ring | 0.85, 0.58, 0.05, 0.9 | reference target |
| trace banner / outline | 0.98, 0.90, 0.62, 0.95 / 0.70, 0.42, 0.00 | replay banner |

**Key metrics** (px): window 1280x800; title bar 50; HUD 150; editor pad 28, line-number gutter 44, gutter 22, code
x0 94, dot x 80, slot cell 24, capture offset 34, word dot cell 16, attribute dot offset 14; code font 13..28; UI font
18; menu cells 44 high, 220..480 wide, gaps 12/8, margin 40, max 8 columns; overlay hint at `h-172`, content bottom
`h-185`; HUD bank centers at w/6, w/2, 5w/6, scale 1.15 active / 0.82 inactive, d-pad offset 82, face offset 32,
face radius 16; status hold 2 s.

**Asset files**: `assets/fonts/` (`DejaVuSansMono.ttf`, `DejaVu-LICENSE.txt`, README; optional user `mono.ttf`),
`assets/icons/` (`<name>.svg`, `<name>-currentColor.svg`, `<name>-64.png`, `<name>-512.png`, `preview.png`),
`assets/sounds/` (three WAVs, README with attributions). No persisted files belong to this area (menu heat:
`doodle_heat.tsv`, 03 F14).

**Package status (what to port, what not)**: in use for rendering: `platform` (SDL window, events, d-pad repeat,
clipboard), `gpu`, `text`, and the drawing code in `app`. **Demoted / dead stubs, not imported by the app**:
`src/ui/ui.odin` (a focus/HUD context sketch; the file is truncated mid-declaration and would not compile, harmless
because nothing imports it), `src/editor/editor.odin` and `src/buffer/buffer.odin` (free-text cursor/gap-buffer
stubs returning zero values; superseded by the projectional document, EDITOR_MODEL.md §7 "`buffer`/`editor`
(free-text) are demoted"), `src/input/` (an action-mapping sketch superseded by model/keymap.odin), `src/lsp/` and
`src/project/` (stubs). ARCHITECTURE.md §5.3's text contract (lazily rasterized glyphs, `set_px_size`, shelf-packed
atlas, Unicode `glyph(rune)`) was never implemented; the real `text` package bakes ASCII once per size.

## Tests that pin this behavior

Rendering itself has no automated tests (TESTING.md: "Future: rendering/golden tests ... Not needed yet"). The pure
pieces it depends on are pinned:

| Test | File | Asserts |
|---|---|---|
| `test_long_call_saved_one_arg_per_line` | src/model/format_test.odin | a >80-column `win.MessageBoxW(...)` needs a break and is saved head / one indented argument per line with trailing commas / `)` |
| `test_short_call_stays_on_one_line` | src/model/format_test.odin | a short call is not broken and saves on one line |
| `test_broken_variadic_call_drops_unfilled_green_dot` | src/model/format_test.odin | a broken `fmt.println` saves 4 lines; the unfilled `..any` dot row is left out |
| `test_call_rows_plan` | src/model/format_test.odin | row plan = head, 4 args (`extra_indent 1`, suffix `,`), tail starting at `)` |
| `test_text_cols` | src/model/format_test.odin | a tab counts `TAB_COLS` (4) columns |
| `test_highlight` | src/model/format_test.odin | classes for `win` (Package), `MessageBoxW` (Func), `nil`/`MB_OK` (Constant), strings, numbers, comments, `:=` (Plain); with imports given, `p.` stays Plain; `int`, `RECT`, `bool` in a header are Type, `main` Plain |
| `test_node_line_starts` | src/model/diagnostics_test.odin | a call saved over 6 lines shifts the next node's line number; `node_for_line` maps lines back |
| `test_parse_check_output` | src/model/diagnostics_test.odin | compiler lines → `Diag{line, col, msg}` for this file only |
| `test_heat_shade_curve` | src/model/heat_test.odin | shade 0 for <= 0, strictly rising, exactly 1 at 40 and beyond |
| `test_grid_cols_prefers_square` | src/model/model_test.odin | 1→1, 4→2, 6→3, 9→3, 16→4, 64→8, 100→8 |
| `test_recent_section_layout_and_nav`, `test_no_recent_section_is_plain_grid`, `test_all_recent_is_not_a_section` | src/model/menu_sections_test.odin | recent entries on their own first row(s), the rest from a new row; navigation wraps per section |
| `test_word_tokens` | src/model/word_edit_test.odin | the word split that places yellow word dots |
| `test_dpad_highlights_name_and_every_argument`, `test_rt_tree_navigation` | src/model/selection_test.odin | which fields a highlight covers (what gets boxed) |
| `test_dpad_repeat` | src/platform/platform_test.odin | held d-pad repeats after 0.35 s every 0.07 s, about 14/s at 60 fps; not while dictating (not run by build scripts) |

What to add in the Rust version: unit tests for the pure layout (`layout_node` with a fake monospace measurer: broken
vs wrapped rows, continuation indent, line-number rows, capture dot width 0), for `ensure_code_font`'s size choice,
for menu cell sizing (`220..480`, full-label line), and screenshot (golden image) tests driven by the replay harness.

## Carrying this to Rust

### (a) What transfers unchanged

- The whole visual language: the paper palette and its meanings (F5), green-editable ink, the dot vocabulary with
  per-kind colors, sizes and pulse rules (F10), the selection box and line/block bands (F11), the grab glow (F12),
  the red wash + right-hand error panel + red line numbers + "N problems" (F13), the title bar with the context hint,
  voice indicators and status line, yellow banners (F14), the HUD geometry and bank scaling (F15), the menu grid
  with label-sized cells, breadcrumb, `expects T  -  grayed options don't fit`, recent section, full-label line and
  scroll marks (F16), the heat smudge (F17), the shared overlay chrome (F19), the animation catalog (F20), tinted
  hand-drawn icons (F21) and the two sound effects with their exact triggers (F22).
- Layout rules: fit N columns by re-baking the code font; one shared row plan for display and save; one argument per
  row for long calls; continuation rows two indents deeper; line numbers = saved lines; scroll so one free row
  stays above and below the cursor row.
- Engineering shape: a pure model with no rendering dependency; a renderer that is one batched, tinted-quad shader;
  rendering as a function of (model, small view state, time); continuous vsync loop on the Deck at 1280x800.
- Every string that carries meaning (titles, hints, `heard:`, `transcribing...`) — reword for Rust where the content
  is Odin-specific (`Odin IDE  -  gamepad native` → a Rust tagline; `odin check` → `cargo check`).

### (b) Odin-specific pieces and their Rust analogs

| Odin | Rust |
|---|---|
| `vendor:sdl2` window, GL context, game controller, audio, clipboard | `sdl2` crate (feature `bundled` or `static-link`) or `sdl3`; alternatively `winit` + `gilrs` + `cpal` + `arboard` (SDL is the safer choice for Steam Input on the Deck: same game-controller DB, one dependency for audio too) |
| `vendor:OpenGL` 3.3 core | `glow` (identical design, smallest port) or `wgpu` (Vulkan on the Deck, D3D12/Vulkan on Windows; `PresentMode::Fifo` = vsync) |
| `vendor:stb/truetype` `BakeFontBitmap` (ASCII, fixed atlas) | `fontdue` or `ab_glyph` rasterizing on demand into a shelf-packed atlas (`etagere`); `cosmic-text` + `glyphon` if full shaping/fallback is wanted |
| `vendor:stb/image` load / `stb_image_write` | `image` (or `png`) crate; `resvg` + `tiny-skia` to rasterize the SVG icons at the exact pixel size instead of mipmapping 512 px PNGs |
| `proc "c"` audio callback with `context = runtime.default_context()` | a struct implementing `sdl2::audio::AudioCallback` (or a `cpal` stream closure); `LockAudioDevice`/`defer Unlock` → the `AudioDevice::lock()` guard (Drop unlocks); better: send "play" commands over a lock-free channel (`ringbuf`, `crossbeam`) |
| `[Enum]T` enumerated arrays (`HL_COLORS`, `ICON_FILES`, `SFX_FILES`, `g_icons`) | `enum_map::EnumMap<Hl, Rgba>` or a `match` in a `const fn color(self)`; `strum` for iteration |
| `Color :: [4]f32` with `.r .g .b .a` swizzles and `{c.r, c.g, c.b, 0.18}` | `#[derive(Clone, Copy, PartialEq)] struct Rgba { r: f32, g: f32, b: f32, a: f32 }` (Rust has no grouped field declarations) with `const fn with_alpha(self, a: f32) -> Self` |
| global `g_*` view state | one `struct Ui { code_font, ui_font, scroll: f32, time: f64, status: Status, ... }` owned by the main loop and passed `&mut` |
| `context.temp_allocator` + `free_all` each frame | reuse cleared `Vec`s across frames, or a per-frame `bumpalo::Bump` reset at frame end; items can borrow from the document: `struct Item<'a> { text: Cow<'a, str>, x: f32, w: f32, row: u32, /* ... */ }` (borrowed when the field text is drawn as is, owned when tabs were expanded) |
| `when ODIN_OS == .Windows` (font paths) | `cfg!(windows)` / `#[cfg(target_os = "linux")]` |
| `defer` (font shutdown, unlock) | `Drop` impls (fonts own their GL textures; a `Texture` drop needs the GL context, so keep destruction explicit or hold `Rc<glow::Context>`) |
| `union Event` | `enum Event { Quit, Button { button: Button, pressed: bool }, Axis { axis: Axis, value: f32 }, Key { sym: i32, pressed: bool } }` (drop the never-produced `Resize`/`Text` variants, or actually produce them) |
| byte-indexed strings (`s[start:end]`, `transmute([]u8)s`) | `&str` slicing **must land on char boundaries** or it panics: split runs with `char_indices`, measure with `unicode-width` for column math |
| `#partial switch` | `match` with `_ =>` |
| `@(private = "file")` | non-`pub` items in a module |

### (c) Rust concepts this area needs that Odin lacks, and how the visual language extends

- **Unicode everywhere**: Rust sources routinely contain non-ASCII text in strings, comments and doc comments, and
  identifiers may be Unicode. The ASCII-only atlas must become a glyph cache with a fallback font chain; column
  fitting must use display width (`unicode-width`), not bytes.
- **Highlight classes** to add (suggested, in the same ink family; rust-analyzer semantic tokens give them for free):
  `Lifetime` (`'a`, `'static` — note the Odin rule treats `'` as a char-literal quote, which breaks on lifetimes),
  `Macro` (`println!`, `vec!` — a Func-like color with the `!`; Odin's rule would leave `println` Plain because
  `!` is not `(`), `Attribute` (`#[derive(Debug)]`, `#![allow(..)]` — Odin's `#ident` rule needs a letter right after
  `#`, so `#[` leaves the `#` plain, then `derive(` reads as a Func and `Debug` as a Type), `EnumMember` (`Some`,
  `None`, `Ok` — CamelCase but not types; the Odin naming heuristic would call `None` a Type and `Some(`/`Ok(` a
  Func), `SelfKw` (`self`, `Self`), and module paths (`std::collections::` — the Rust analog of Odin's `pkg.`
  Package class, with `::` instead of `.`). Keep the rule that **editable names are green** regardless of class.
- **Lexical states** the per-line highlighter cannot handle: nested block comments `/* /* */ */`, raw strings
  `r#"..."#` spanning lines, byte/char literals vs lifetimes. Use a real lexer (`ra_ap_rustc_lexer` — rustc's own
  lexer as republished for rust-analyzer — or `ra_ap_syntax`, or `tree-sitter` + `tree-sitter-rust` with its
  `highlights.scm` query) over the whole file and map tokens back to fields.
- **New dot kinds** (suggested colors following the existing grammar: holes pulse, "add another" is small steady
  green, options are steady): a **pattern** hole in `match` arms / `let` patterns (e.g. teal), a **lifetime** hole,
  a **generic parameter / trait bound** hole (blue family, it is a type position), **closure parameters** `|●|`
  (violet like `params`), a **match-arm insertion** dot (green), a **`?` / `.await` postfix option** (steady, like
  capture). Rust attributes (`#[test]`, `#[derive(..)]`, `#[cfg(..)]`, `#[inline]`) map directly onto Doodle's
  **purple attribute dot** above a declaration.
- **Deeper nesting**: `impl` / `trait` / `mod` blocks put functions one level deeper than Odin's file-scope procs;
  the body-dot placement rule (in the indentation, on the row boundary) already scales with nesting.
- **Generics and long types**: expected-type labels next to dots can be long (`Option<HashMap<String, Vec<u8>>>`).
  Doodle draws the full label; the Rust version should cap a label's width with `..` and show the full type in the
  menu's `expects T` line.
- **Diagnostics**: `cargo check --message-format=json` gives level (error / warning / note / help), exact spans and
  suggested fixes. Extend F13: amber wash + amber line number for warnings (`COL_WARN`), red for errors; shade the
  exact span's fields (the column Doodle ignores); show `help:` children in the panel; a machine-applicable
  suggestion can become a menu option (06).
- **Doc comments are Markdown**: the docs panel (F19) should render code fences in the code font on the declaration
  band, inline code in the code font, headings in accent; rust-analyzer's hover returns exactly this Markdown.
- **Formatting width**: rustfmt's default `max_width` is 100, not 80. Keep fitting the *font* to 80 columns
  (readability on the Deck) and let the row plan follow rustfmt's width for saved breaks: lines of 81-100 columns are
  then shown broken or wrapped for the screen but saved on one line, which Doodle's layout already supports (no line
  numbers on screen-only rows). Decide this explicitly (see open questions).
- **Ownership in the renderer**: the frame's layout borrows the document immutably while drawing; view state that
  changes during draw (`g_scroll`) must live outside the document (a `&mut Ui`), which also keeps the model pure.

### (d) Implementation advice for this area

- Split rendering into **layout (pure)** and **paint**:
  `fn layout_node(node: &Node, x0: f32, max_x: f32, code: &impl Measure, ui: &impl Measure) -> NodeLayout` with
  `trait Measure { fn width(&self, s: &str) -> f32; fn line_height(&self) -> f32; }` — two measurers, because
  Doodle measures code runs with the code font but slot labels with the UI font — so wrapping, broken calls and
  line-number rows are unit-tested with a fake monospace measurer. Doodle has no tests for this code; the Rust
  version should.
- Keep the **single tinted-quad pipeline**. Put the UI font, code font and icons in one atlas (or a texture array)
  to avoid a flush per text/rect switch; use scissor rects for the code area instead of relying on draw order.
- Lay out only what changed (cache `NodeLayout` per node keyed by a revision counter) — Doodle re-lays out every
  node every frame, fine for small files but O(document) per frame.
- **Frame pacing**: keep vsync, but stop redrawing when nothing animates and no input arrived (the cursor's dot and
  fill-me slots pulse, so either cap idle redraw at ~30 fps or pause animation after some seconds of inactivity);
  continuous 60 fps redraw costs battery on the Deck.
- Add a **UI scale** (drawable size / logical size, or a setting) so the 18 px UI font is readable on HiDPI monitors;
  keep all the metrics in this doc as logical pixels.
- Use **rust-analyzer** semantic tokens as the highlight oracle (with a lexer fallback while it warms up), and
  `cargo check --message-format=json` (or rust-analyzer's diagnostics) for F13.
- Recommended stack: `sdl2`/`sdl3` (window, gamepad, audio, clipboard) + `glow` + `fontdue` + `etagere` +
  `unicode-width` + `image`/`resvg` + `hound` (WAV) + `rand`. Alternative: `winit` + `wgpu` + `glyphon`/`cosmic-text`
  + `gilrs` + `cpal`.
- Ship a bundled monospace font with good Unicode coverage (DejaVu Sans Mono, JetBrains Mono, or Iosevka) and keep
  the "drop your own `mono.ttf` in assets/fonts" override; drop proportional fonts (Segoe UI) from the fallback list.
- Reuse the trace/replay screenshot hook for golden-image tests of key screens (editor, a menu, the HUD in each bank).

## Open questions & known gaps

- **HUD tween**: docs/EDITOR_MODEL.md §5 "Rendering" says "Active bank scale ~1.3x, inactive ~0.85x, smooth tween on
  trigger press"; the code switches **instantly** between 1.15 and 0.82. The docs are aspirational; the code is the
  spec unless the owner wants the tween back.
- **Main menu hint hidden**: `D-pad / Arrows to move ...` is drawn at `0.84h`, inside the HUD band at 800 px, and is
  covered (certain from the coordinates and draw order; home.png shows no hint); only visible on windows >= ~1125 px
  tall. Nothing says whether this is intended; it also still says `(Open Folder not wired yet)`. For Rust: move it
  above the HUD or drop it (the HUD already labels the buttons).
- **Screenshots are stale**: home.png predates `Key Layout` / `Settings` (3 menu items); editor.png predates
  editable struct-member names (it shows `name`/`cozy` in ink; today they are green) and the current default
  layout (its RT bank has `>` on X, today X there is Refactor/Grab; its LT Y shows the letter `Y`, today Docs `?`);
  A/B show `+`/`<` glyphs instead of the add/back icons. Use the code, not the pictures, for exact content.
- **Line numbers vs the file on disk**: numbers follow `doc_to_source` (what the checker compiles); an editor-only
  `●` statement line next to real statements is counted on screen but not written by `save_source` (F7).
- **Grab hint can go stale**: it hard-codes `RT+Up/Down jump`, but jumping is the Walk_Prev / Walk_Next actions,
  which the Key Layout page can move (F14).
- **Top-right collisions**: the status message has no backing and shares y=14 with the context hint, `[REC]`,
  `transcribing...` and `heard:`; a long status can overlap the hint. The title path is never truncated.
- **Invisible Unicode**: non-ASCII bytes are dropped from display (strings, comments, file names in Files).
- **Stateless highlighting**: multi-line comment text gets code colors; warnings look like errors; diagnostic
  columns are not used to shade spans.
- **No DPI scaling**: the UI font is a fixed 18 px; on HiDPI desktops chrome is small. Only the code font adapts.
- **Full screen on the Deck** is not done by the code (no fullscreen flag, no toggle); README promises "Full screen
  at the Deck's native 1280×800", presumably via Steam Game Mode's compositor (inferred, unverified on hardware).
- **Menus hide the title bar**: while a construct menu is open, `[REC]` / `transcribing...` / `heard:` and the
  context hint are under the 95% veil (F14).
- **Continuous redraw** at vsync even when idle; the whole document is re-laid out every frame.
- **Run list grid** and the Settings page do not scroll; many run commands or setup rows can run under the HUD.
- **Pencil trigger is size-based**: renaming to a longer name or a format that adds characters scribbles; a
  same-length change is silent; deletes are always silent (possibly intended: "code added").
- **Fallback font list** includes proportional Segoe UI.
- **Dead code**: `src/ui/ui.odin` is truncated (would not compile if imported); `editor`, `buffer`, `input`, `lsp`,
  `project` are unused stubs; `draw_editor`'s `font` parameter, `draw_orange_dot`, `gpu.texture_update` and
  `text.atlas_tex` are unused; `Resize_Event` / `Text_Event` are never produced; the `paste` icon is shipped but
  unused; `platform_test.odin` and `shell_test.odin` are not run by `build.bat test` / `build.sh test` (nor by CI,
  which runs only `src/model` and `src/stt`). The `Item.wstop` comment in editor_view.odin says "odd: a word, even: a
  yellow dot", but the code does the opposite (odd = dot), as this doc describes.
- **Minor renderer details**: `flush` re-queries the `uTex` uniform location each flush; translucent
  `draw_rect_outline` corners double-blend (only the smudge avoids it).
- **Decide for Rust**: the column count the font fits (80 for Deck readability vs rustfmt's 100), whether warnings
  get their own color, and whether to add a volume/mute setting.

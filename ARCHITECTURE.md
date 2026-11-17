# Olympus IDE — Architecture

A gamepad-navigable IDE for the **Odin** programming language, written **in Odin**.
Targets **Windows** and **Steam Deck (Linux)**. Voice input via local **Whisper**.

> This document is the **source of truth** for module boundaries and interface
> contracts. Agents MUST NOT change a package's public interface without updating
> this file first (and ideally flagging it in a PR description).

---

## 1. Design goals (ranked)

1. **Gamepad-first** — everything reachable without keyboard/mouse.
2. **Fast, crisp text** — GPU glyph atlas, viewport virtualization, 60–144 Hz scroll.
3. **Large projects** — lazy loading, background indexing, bounded memory.
4. **Cross-platform** — Windows + Steam Deck from one codebase.
5. **Voice (STT)** — local Whisper for dictating identifiers and commands.
6. **Parallel development** — clean package boundaries, stable contracts.

Non-goals (v1): complex-script text shaping (RTL/CJK combining), remote dev,
debugger UI, plugin system.

---

## 2. Technology stack

| Concern              | Choice                                             |
|----------------------|----------------------------------------------------|
| Language             | Odin                                               |
| Window/input/audio   | SDL2 (`vendor:sdl2`)                               |
| GPU API              | OpenGL 3.3 core (`vendor:OpenGL`) via SDL GL ctx    |
| Glyph rasterization  | stb_truetype (`vendor:stb/truetype`)               |
| STT                  | whisper.cpp (local), C-API binding or subprocess   |
| Audio capture        | SDL2 audio                                          |
| Odin intelligence    | `ols` language server, JSON-RPC over stdio         |

---

## 3. Package map & ownership

Odin package == directory. Each package has ONE public responsibility and a
narrow interface. Suggested agent ownership in parentheses.

```
src/
  platform/  SDL2 window, event pump, timing, audio capture       (Agent A)
  gpu/       GL context, shaders, batched textured-quad renderer   (Agent A)
  text/      font load, stb_truetype raster, glyph atlas, layout   (Agent B)
  buffer/    text storage (gap/rope), undo/redo, line index        (Agent C)
  editor/    cursors, selection, edit ops, viewport/scroll         (Agent C)
  input/     gamepad state, action map, spatial navigation         (Agent D)
  ui/        focus model, panels, command palette, glyph HUD        (Agent D)
  stt/       whisper integration, push-to-talk, dictation modes     (Agent E)
  lsp/       ols JSON-RPC client, completion/diagnostics/defs       (Agent F)
  project/   file tree, fuzzy index, background search              (Agent G)
  app/       wiring + main loop (integration owner)                 (Integrator)
```

### Dependency rules (enforced by review)

- `app` may import everything. Nothing imports `app`.
- `ui` imports `gpu`, `text`, `input`. `ui` does NOT import `editor` directly;
  the `app` layer passes editor state into UI draw calls.
- `editor` imports `buffer` only. `editor` knows nothing about GPU/UI.
- `text` imports `gpu` (to upload atlas textures) and `platform` (file IO).
- `gpu` imports `platform` (for the GL-loaded window/context).
- `stt`, `lsp`, `project` are **leaf services**: they import `platform` at most
  and expose plain data + callbacks. They never touch `gpu`/`ui`.
- No cyclic imports. If you need one, the design is wrong — raise it in a PR.

Data generally flows: **platform → (gpu, audio, fs) → text/editor/services → ui → frame**.

---

## 4. Core data types (shared vocabulary)

These live in small shared files to avoid duplication. Keep them POD-ish.

```odin
// src/gpu  (geometry primitives reused widely)
Vec2  :: [2]f32
Rect  :: struct { x, y, w, h: f32 }
Color :: [4]f32   // linear 0..1 RGBA
```

```odin
// src/buffer
Pos :: struct { line: int, col: int }   // 0-based, col in runes
Range :: struct { start, end: Pos }
```

---

## 5. Package contracts (v0 interfaces)

> These are the stubs that ship in the scaffold. Signatures may grow, but the
> *shape* is the contract. Breaking changes require an edit to this section.

### 5.1 platform
```odin
Window :: struct { /* opaque: SDL_Window*, SDL_GLContext, size */ }

Event :: union {
    Quit_Event,
    Resize_Event,       // { w, h: int }
    Gamepad_Button,     // { button: Button, pressed: bool }
    Gamepad_Axis,       // { axis: Axis, value: f32 }  (-1..1)
    Text_Input,         // { text: string }  (soft keyboard / dictation)
}

init       :: proc(title: string, w, h: int) -> (^Window, bool)
poll_events :: proc(win: ^Window, out: ^[dynamic]Event)
present     :: proc(win: ^Window)                 // gl swap
get_size   :: proc(win: ^Window) -> (int, int)
now_seconds :: proc() -> f64
shutdown   :: proc(win: ^Window)

// Audio capture for STT
Audio_Capture :: struct { /* opaque SDL audio device, ring buffer */ }
audio_open   :: proc(sample_rate: int) -> (^Audio_Capture, bool)
audio_start  :: proc(cap: ^Audio_Capture)
audio_stop   :: proc(cap: ^Audio_Capture)
audio_read   :: proc(cap: ^Audio_Capture, out: ^[dynamic]f32) -> int  // mono f32
```

### 5.2 gpu
```odin
Texture :: struct { id: u32, w, h: int }
Renderer :: struct { /* shader, VAO/VBO, batch buffers, white tex */ }

init        :: proc(win: ^platform.Window) -> (^Renderer, bool)
begin_frame :: proc(r: ^Renderer, w, h: int, clear: Color)
end_frame   :: proc(r: ^Renderer)                 // flush + draw
draw_rect   :: proc(r: ^Renderer, dst: Rect, color: Color)
draw_glyph  :: proc(r: ^Renderer, dst: Rect, tex: ^Texture, uv: Rect, color: Color)
texture_create :: proc(w, h: int, pixels: []u8, channels: int) -> Texture
texture_update :: proc(t: ^Texture, x, y, w, h: int, pixels: []u8)
shutdown    :: proc(r: ^Renderer)
```
`gpu` batches quads by texture and flushes on `end_frame` (and on texture switch).

### 5.3 text
```odin
Glyph :: struct {
    uv:      Rect,     // location in atlas (0..1)
    size:    Vec2,     // px
    bearing: Vec2,     // px offset from pen
    advance: f32,      // px
}
Font  :: struct { /* stbtt_fontinfo, px size, line_height, ascent, atlas */ }

load_font   :: proc(r: ^gpu.Renderer, path: string, px_size: f32) -> (^Font, bool)
set_px_size :: proc(f: ^Font, px_size: f32)        // re-raster on DPI/zoom change
glyph       :: proc(f: ^Font, r: rune) -> Glyph    // lazily rasterizes into atlas
atlas_tex   :: proc(f: ^Font) -> ^gpu.Texture
measure     :: proc(f: ^Font, s: string) -> Vec2   // advance width, line height
line_height :: proc(f: ^Font) -> f32
// draw a single line of text; returns pen end x
draw_line   :: proc(r: ^gpu.Renderer, f: ^Font, pos: Vec2, s: string, color: Color) -> f32
shutdown    :: proc(f: ^Font)
```
v1 layout = monospace advance, left-to-right, no shaping. Pixel-snapped pens for
crisp glyphs. Atlas grows/evicts via simple shelf packing.

### 5.4 buffer
```odin
Buffer :: struct { /* gap buffer or rope + line-start index + undo stack */ }

make_buffer :: proc() -> ^Buffer
load_file   :: proc(b: ^Buffer, path: string) -> bool
save_file   :: proc(b: ^Buffer, path: string) -> bool
line_count  :: proc(b: ^Buffer) -> int
line        :: proc(b: ^Buffer, i: int) -> string   // without newline
insert      :: proc(b: ^Buffer, at: Pos, text: string) -> Pos  // returns new pos
remove      :: proc(b: ^Buffer, r: Range)
undo        :: proc(b: ^Buffer) -> (Pos, bool)
redo        :: proc(b: ^Buffer) -> (Pos, bool)
```
Edits are grouped into undo transactions by the `editor` package.

### 5.5 editor
```odin
Cursor :: struct { pos: Pos, anchor: Pos }   // anchor==pos means no selection
View :: struct {
    buf:        ^buffer.Buffer,
    cursors:    [dynamic]Cursor,
    scroll:     Vec2,     // px
    path:       string,
    dirty:      bool,
}

open        :: proc(path: string) -> (^View, bool)
move_cursor :: proc(v: ^View, dir: Direction, select: bool)   // char/word/line/page
type_text   :: proc(v: ^View, s: string)
backspace   :: proc(v: ^View)
scroll_to_cursor :: proc(v: ^View, viewport: Rect, line_h: f32)
visible_lines :: proc(v: ^View, viewport: Rect, line_h: f32) -> (first, last: int)
```
`visible_lines` powers viewport virtualization — only these lines are drawn.

### 5.6 input
```odin
Button :: enum { A, B, X, Y, Up, Down, Left, Right, LB, RB, LT, RT,
                 Start, Back, LStick, RStick, Guide }
Axis   :: enum { LX, LY, RX, RY, LTrigger, RTrigger }

Action :: enum {
    Confirm, Cancel, Nav_Up, Nav_Down, Nav_Left, Nav_Right,
    Next_Panel, Prev_Panel, Command_Palette, Dictate_Hold,
    Scroll_Up, Scroll_Down, Zoom_In, Zoom_Out, /* ... */
}

State :: struct { /* current + previous button/axis snapshot */ }

update       :: proc(st: ^State, events: []platform.Event)
is_pressed   :: proc(st: ^State, a: Action) -> bool   // edge (just pressed)
is_down      :: proc(st: ^State, a: Action) -> bool   // held
axis         :: proc(st: ^State, a: Axis) -> f32
// spatial navigation: pick the best focus target in a direction
nav_target   :: proc(rects: []Rect, current: int, dir: Direction) -> int
```
Default mapping lives in `input/mapping.odin` and is user-overridable later.

### 5.7 ui
```odin
Ctx :: struct { r: ^gpu.Renderer, font: ^text.Font, input: ^input.State,
                focus_id: u64, hot_id: u64 }

begin   :: proc(ctx: ^Ctx)
end     :: proc(ctx: ^Ctx)
panel   :: proc(ctx: ^Ctx, id: u64, bounds: Rect)
button  :: proc(ctx: ^Ctx, id: u64, bounds: Rect, label: string) -> bool
focus_ring :: proc(ctx: ^Ctx, bounds: Rect)             // draws selection ring
command_palette :: proc(ctx: ^Ctx, items: []string) -> (chosen: int, done: bool)
glyph_hud :: proc(ctx: ^Ctx, hints: []Hint)             // controller button hints
```
UI is gamepad-focus-driven: a single focused widget per panel, A=confirm,
B=cancel, d-pad/stick = spatial move via `input.nav_target`.

### 5.8 stt
```odin
Engine :: struct { /* whisper_context or subprocess handle */ }
Mode   :: enum { Command, Identifier, FreeText }

init        :: proc(model_path: string) -> (^Engine, bool)
begin_ptt   :: proc(e: ^Engine, cap: ^platform.Audio_Capture, mode: Mode)
end_ptt     :: proc(e: ^Engine) -> string     // blocking transcribe of captured audio
// async variant later: poll_result :: proc(e) -> (string, bool)
shutdown    :: proc(e: ^Engine)
```
Identifier mode post-processes output (strip spaces, snake_case/camelCase
heuristics) to produce valid Odin identifiers from dictation.

### 5.9 lsp
```odin
Client :: struct { /* child process stdio, request id map, callbacks */ }
Diagnostic :: struct { range: Range, severity: int, message: string }
Completion :: struct { label, insert: string, kind: int }

start        :: proc(ols_path, root_uri: string) -> (^Client, bool)
did_open     :: proc(c: ^Client, uri, text: string)
did_change   :: proc(c: ^Client, uri, text: string, version: int)
request_completion :: proc(c: ^Client, uri: string, at: Pos) -> []Completion
poll         :: proc(c: ^Client)   // pumps responses, fires callbacks
on_diagnostics :: proc(c: ^Client, cb: proc(uri: string, diags: []Diagnostic))
shutdown     :: proc(c: ^Client)
```

### 5.10 project
```odin
Node :: struct { name: string, is_dir: bool, children: []Node }   // lazy
Match :: struct { path: string, score: int, positions: []int }

open_root     :: proc(path: string) -> bool
read_dir      :: proc(path: string) -> []Node          // one level (lazy tree)
start_index   :: proc(root: string)                    // background worker
fuzzy_find    :: proc(query: string, limit: int) -> []Match
cancel_index  :: proc()
```
Indexing runs on a worker thread; UI queries are non-blocking snapshots.

---

## 6. Main loop (app)

```
init platform (window + GL)        -> platform
init gpu renderer                  -> gpu
load font / atlas                  -> text
start lsp (ols), project index     -> lsp, project
loop:
    poll_events                    -> []Event
    input.update(events)
    if Dictate_Hold just pressed:  stt.begin_ptt(...)
    if Dictate_Hold released:      text = stt.end_ptt(); editor.type_text(text)
    handle actions -> editor / ui / navigation
    lsp.poll(); drain project results
    gpu.begin_frame(clear)
      ui.begin()
        draw file tree (virtualized), editor view (visible_lines only),
        status bar, command palette if open, glyph HUD
      ui.end()
    gpu.end_frame()
    platform.present()
```

Target frame budget: 6.9 ms (144 Hz) on desktop, 16.6 ms (60 Hz) on Deck.

---

## 7. Multi-agent workflow

- **Branch/worktree per agent**: `git worktree add ../olympus-<area> feat/<area>`.
- Each agent owns one package dir; cross-package needs go through the interfaces
  in §5. If you must change another package's interface, update §5 in the same PR.
- `app/` is integration-only; one integrator merges and wires.
- Every package ships a `*_test.odin` with at least smoke tests.
- CI builds Windows + Linux and runs `odin test` per package.

See `docs/MULTI_AGENT.md` for the concrete commands.

---

## 8. Open questions (tracked on the Excalidraw board)

- Whisper: link C API vs run as subprocess (isolation vs latency).
- Shaping depth: stay stb-only vs add HarfBuzz for full Unicode later.
- Buffer impl: gap buffer (simpler) vs rope (better for huge files) — start gap,
  revisit if large-file editing stutters.

# Trace harness: record, replay and analyze runs

**Status:** debug-only developer tool. It's compiled into debug builds (`build.bat`,
`build.bat run`) and left out of `build.bat release`, which contains none of its code.

Every debug run of Doodle records what you did. You can then:

- **find a moment** ("the menu that was all W's") and **replay** the run up to it,
  then step forward one action at a time or take over and keep going;
- **analyze** which buttons, combos and menu items you use most, how many presses
  things take to reach, and where you back out or undo, to decide what should be
  easier to reach;
- **verify** that a replay still reproduces a run (a cheap regression test).

## Quick start

```sh
build.bat run                                   # use Doodle; the run is recorded
python -I tools/trace.py list                   # recent recordings
python -I tools/trace.py report last            # buttons / menus / mistakes in the last run
python -I tools/trace.py find last --menu-all-prefix W     # when was a menu all W's?
python -I tools/trace.py show last --around 1234           # the actions around frame 1234
bin\doodle.exe --replay last --until 1234       # replay up to frame 1234, then pause
python -I tools/trace.py verify all             # replay every recording, check they still match
```

## Recording

Each run writes `bin/traces/<UTC stamp>/`, for example `bin/traces/20261120-233007Z/`.
The folder is git-ignored and only the newest 40 recordings are kept.

| File | What |
|---|---|
| `input.log` | The exact input stream, frame by frame, plus anything a replay can't recompute (speech-to-text text, the random project name) and a state fingerprint. `--replay` reads this. |
| `events.jsonl` | One JSON record per action: buttons pressed, plus the screen, menu and selection before and after. `tools/trace.py` reads this. |
| `snapshot/` | A copy of `DoodleProjects` as it was at startup, so a replay sees the same files. If you opened a file from the command line, its folder's `.odin` files are copied too. For each folder added in New Project, its projects' own `.odin` files are copied (`snapshot/roots/<i>`). Build output, `.git`, binaries and files over 4 MB become empty placeholders, which keeps folder listings identical. Files that haven't changed since the previous recording are hard links to it, so a snapshot usually takes a few milliseconds and almost no disk. Limits: 32 MB copied and 4000 files; past those, the snapshot is marked incomplete. |

A small red dot in the top-left corner means the run is being recorded.

Turn recording off for one run with `bin\doodle.exe --no-trace`, or with
`set DOODLE_TRACE=0` in the environment.

## Replaying

```
bin\doodle.exe --replay <last | stamp | folder | path\to\input.log> [options]
  --until FRAME   stop at this recorded frame (default: the end of the recording)
  --speed X       0 = as fast as possible (default); 1 = real time; 4 = 4x
  --takeover      take over automatically when the replay stops
  --exact         also run the empty frames between recorded ones (slower; normally unnecessary)
  --exit-at-end   quit when the replay stops (for automated checks)
  --screenshot F  save a PNG of the screen when the replay stops (F = path)
```

While replaying, the real controller only drives the replay:

| Gamepad | Keyboard | |
|---|---|---|
| Back | F6 | pause / resume |
| Right (while paused) | F7 | step to the next recorded action |
| Start | F5 | **take over**: from here on it's a normal session |

When the replay reaches `--until` (or the end), it pauses there.

**The sandbox.** A replay never touches your real files. It copies the recording's
`snapshot/` into `bin/traces/_replay/` (real copies, never links), points the
projects folder (and the command-line file) there, and runs inside it. Saves,
renames, new files, run commands (`run.txt`) and deletes all happen in the sandbox.
Several things are always skipped during a replay:

- running programs (RB / LB / the run list);
- the clipboard;
- sounds;
- the Recycle Bin (a delete just removes the file from the sandbox);
- any write outside the sandbox;
- heatmap updates;
- reading or writing your `doodle_keys.tsv`. A replay uses the button layout the run was recorded with (`meta keymap`; recordings made before the Key Layout page existed use the defaults).
- reading or writing your `doodle_roots.txt` (New Project's extra folders). A replay uses empty stand-ins in the sandbox (`roots/<i>`) for the folders the run was recorded with (`meta roots`), holding the snapshot of their projects' `.odin` files. Recordings made before New Project asked where skip the question, as they did then.

**Taking over.** Held buttons from the recording are released, and the session
continues live. Programs, the clipboard and sounds work again. Files are still only
written inside `bin/traces/_replay/` (the banner says so), so a replay session can
never change a real file, even after you take over.

The next replay keeps that session's files as `bin/traces/_replay.prev/` (one
session back). Taking over starts a new recording that contains the replayed part
too, so it's self-contained: replaying it reproduces the whole thing. It uses the
source recording's frame numbers and clock, so frame 1234 means the same moment in
both. The live part continues from there. Its `input.log` has
`meta derived_from <stamp>` and `meta derived_until <frame>`.

**If the recording quit** (B on the main menu), the replay stops at that moment
instead of quitting. Closing the window does quit.

**Stepping** (F7 / Right while paused) runs to the next recorded frame with a press
in it. **`--speed`** pacing stops while paused.

**Fingerprints.** Every recorded frame with input in it (or where the state changed)
stores a hash of the state that input can change: the document, cursor, menus,
overlays, file names and the dialog text. A replay compares hashes after each frame.
The first mismatch is printed and shown in the banner: "diverged at frame N".
Things that can make a replay diverge:

- Speech-to-text isn't available when you replay a run that used it. The recorded
  text is injected, but Doodle only offers dictation when the engine exists.
- An incomplete snapshot (warned at record time).
- Browsing outside the projects folder in file navigation. Those reads hit the
  real disk, and writes there are skipped.
- Browsing for a folder to add in New Project ("+ Add another folder"). It reads
  the real disk, starting next to the projects folder (the sandbox, in a replay).
- Opening a file inside a project in an added folder, below the project's top
  level: only each project's own `.odin` files are snapshotted (`snapshot/roots/<i>`).
- Doodle's own code changed since the recording. That's what `verify` is for.

## Analysis tool

`tools/trace.py` (stdlib Python, run as `python -I tools/trace.py <command> ...`)
reads `events.jsonl` and `input.log`. A `<trace>` is `last`, a stamp, a folder or
`input.log` path, or `all` where noted. Every command takes `--traces DIR`
(default `bin/traces`). `python -I tools/trace.py <command> --help` lists the options.

| Command | What |
|---|---|
| `list` | Recent recordings: start time, duration, presses, files touched, `derived_from`, clean end |
| `report <trace\|all> [--top N]` | Button / combo usage per screen, what the presses meant, menu picks with their cost in presses, time per screen, mistake signals (with frames), suggestions |
| `find <trace\|all> [predicates]` | Matching moments plus the `--replay ... --until F` command. Predicates: `--menu-all-prefix`, `--menu-title`, `--item`, `--scr`, `--sel`, `--press`, `--mode`, `--leaf`, `--text`, `--expr` (Python, `r` = record) |
| `show <trace> [--around F]` | Readable timeline, one line per action, plus lists and marks |
| `verify <trace\|all>` | Replays each recording with `--exit-at-end` and checks the `trace: RESULT` line. Exit code 1 if any diverged |
| `replay <trace> [--until F] ...` | Launches `bin/doodle.exe --replay` with the same options |
| `script <name> <steps...> [--projects DIR] [--open REL] [--shot PNG] [--run]` | Writes a replayable fixture `bin/traces/script-<name>` from scripted presses, then optionally replays it and saves a screenshot. Use it to check UI changes without a controller. |

`script` steps, separated by spaces:

| Step | Meaning |
|---|---|
| `A`, `B`, `X`, `Y`, `Up`, `Down`, `Left`, `Right`, `LB`, `RB` | a gamepad tap |
| `LT+B`, `RT+Y`, `LT+Left` | trigger held, button tapped |
| `LT`, `RT` | a bare trigger pull |
| `hold:LT+X:40` | hold for 40 frames |
| `text:hello` | keyboard typing (dialogs) |
| `key:Return` | one keyboard key |
| `wait:30` | 30 idle frames |

For example:

```sh
python -I tools/trace.py script filenav "RT+B Down Right A" --projects C:\some\projects --open demo/main.odin --shot out.png
```

`script-*` folders aren't counted as recordings: `last`, `all` and pruning skip them.

What each button means on each screen ("LT+B in the editor = delete") is the
`BINDINGS` table near the top of `tools/trace.py`. Update it when the bindings
change.

## events.jsonl

One JSON object per line. `k` gives the kind:

- **`meta`** (first line): `format`, `start_unix`, `args`, `cwd`, `projects`,
  `start_file`, `stt`, `snapshot_ok`, `snapshot_ms`, `derived_from`, `derived_until`.
- **`act`**: something happened this frame (a press, or a state change).
  - `f` is the frame and `t` is the seconds since start.
  - `press` is a list of `{b, mods, rep}`:
    - `b` is `pad:A`, `pad:Up`, `pad:RB`, `key:w`, `key:Return`, ..., `LT` / `RT`
      (trigger pressed), `LT-up` / `RT-up`, `pad:X-up` / `key:x-up` (releasing
      talk).
    - `mods` is the triggers held (`""`, `LT`, `RT`, `LT+RT`) as the app saw them: after all of that frame's events.
    - `rep` marks keyboard auto-repeat.
  - `pre` and `post` describe the screen before and after the frame's input. Each
    has these fields:

    | Field | Meaning |
    |---|---|
    | `scr` | `main_menu`, `editor`, `menu`, `save_dialog`, `rename`, `filenav`, `filenav_search`, `filenav_delete`, `key_layout`, `projects`, `docs`, `run`, `run_templates` |
    | `mode` | Comma list. Editor modes: `ref_pick`, `mod_pick`, `rename_prompt`, `dictating`, `tree_sticky`. Why a menu is open: `replace`, `refill`, `change_call`, `body_insert`, `decl_form`, `slot`, `ctrl:<kind>`. |
    | `title` | Menu title, file-nav folder or search, save-dialog text, or doc title |
    | `trail` | Titles of the menus passed through to get here |
    | `sel`, `idx`, `n` | Highlighted item, its index, and the item count |
    | `line`, `field`, `dot` | Editor cursor |
    | `leaf` | Highlighted code text |
    | `kind` | Its field kind |
    | `file` | Open file's base name |
    | `nodes` | Document lines |

  - `edit` is true when the document changed.
- **`list`**: a list became visible, with its full contents: `scr`, `title`,
  `trail`, `items`, `recent` (the first `recent` items are "recently used"), and `idx`.
- **`mark`**: `what` is `stt` (dictated text), `project_name`, `takeover`,
  `diverged` or `end`, with `text`.

Keyboard keys map to the same actions as the gamepad (see `handle_key` in
`src/app/main.odin`):

| Key | Action |
|---|---|
| `q` / `e` | LT / RT |
| `w a s d` / arrows | d-pad |
| Return / Space | A |
| Backspace / Escape | B |
| `x`, `y` | X, Y |
| `r` / `t` | RB / LB |

## input.log

A text file with one record per line. Line 1 is `doodle-trace 1`. Then come
`meta <key> <value>` lines:

- `start_unix`, `cwd`, `projects`, `start_file`, `start_rel`, `stt`, `snapshot_ok`
- `keymap`: the button layout in use, in the `doodle_keys.tsv` format (newlines escaped)
- `roots`: New Project's extra folders, tab-separated (empty: none; missing: a recording from before New Project asked where)
- `arg` (repeated)
- `derived_from`, `derived_until` (if a key appears twice, the last one wins)

The rest are `<frame> <kind> ...` lines, and a final `end <frame>` after a clean exit:

| Kind | Fields |
|---|---|
| `t` | seconds since start (first line of each recorded frame) |
| `btn` | `<Button> <0/1>` (`platform.Button` names: A B X Y Up Down Left Right LB RB Start Back ...) |
| `axis` | `<Axis> <value>`: LTrigger / RTrigger, written only when a trigger crosses half way (all the app checks); exact f32 value. The sticks aren't recorded (the app ignores them). |
| `key` | `<SDL keycode> <0/1>` |
| `size` | `<w> <h>` window size |
| `quit` | window closed |
| `str` | `<kind> <text>` (`stt`, `project_name`) |
| `fp` | `<hex>` state fingerprint after the frame (16 hex digits) |

Strings are one token: `\s` = space, `\t`, `\n`, `\r`, `\\`. Frames with nothing in
them aren't written. A replay runs one empty frame after each recorded one, which
is all the app ever needs, because nothing in Doodle changes without input.
`--exact` runs every frame instead.

## How it's built

Everything lives in `src/app/trace.odin`, inside `when TRACE { ... } else { stubs }`,
where `TRACE :: #config(DOODLE_TRACE, ODIN_DEBUG)`. With the harness off, each hook
is a pass-through stub, so the app compiles and behaves exactly as without it.
Code inside the false `when` branch isn't even type-checked. Force it either way with
`-define:DOODLE_TRACE=true` or `false`.

## Removing the harness

1. Delete `src/app/trace.odin`, `tools/trace.py` and this file.
2. Remove the `trace` lines from `build.bat` / `build.sh` and the pointer in `README.md`.
3. Undo each hook. `grep -rn "TRACE hook" src` lists them, and each one's comment
   says what it was:

| File | Hook | Put back |
|---|---|---|
| `main.odin` | `trace_start(win, &m)` / `defer trace_stop()` | delete |
| `keys_store.odin` | `if !trace_write_ok(g_keys_path) do return` in `keys_store_save` | delete (and `keys_store_override` / `g_keys_pinned` if you like) |
| `roots_store.odin` | `if !trace_write_ok(g_roots_path) do return` in `roots_store_save` | delete (and `roots_store_override` / `g_roots_legacy` with its branch in `main.odin` if you like) |
| `filenav.odin` | `if !trace_write_ok(path) do return` in `filenav_create_new` | delete |
| `run.odin` | `if !trace_write_ok(path) do return` in `save_run_cmds` | delete |
| `main.odin` | `if f := trace_startup_file(); f != ""` | `if len(os.args) > 1 && os.exists(os.args[1])` with `filenav_load(os.args[1])` |
| `main.odin` | `trace_poll(win, &events)` | `platform.poll_events(win, &events)` |
| `main.odin` | `trace_frame_begin(&m)`, `trace_frame_end(&m)`, `trace_draw(r, w, h)`, `trace_after_draw(w, h)` | delete |
| `main.odin`, `filenav.odin`, `save_dialog.odin` | `trace_stt_begin/segment/end(e)` | `stt.begin/segment/end(e)` |
| `main.odin` | `!trace_replaying() && !platform.set_clipboard_text(src)` | `!platform.set_clipboard_text(src)` |
| `filenav.odin` | `!(trace_replaying() ? ... : move_to_trash(path))` | `!move_to_trash(path)` |
| `save_dialog.odin` | `if !trace_write_ok(path) do return` | delete |
| `save.odin` | `trace_str("project_name", gen_project_name())` | `gen_project_name()` |
| `save.odin` | `if trace_write_ok(g_project_dir) do os.make_directory(g_project_dir)` in `new_project_setup` | `os.make_directory(g_project_dir)` |
| `save.odin` | `if !trace_write_ok(path) { ... }` in `write_doc` | delete |
| `run.odin` | `if !trace_replaying() do libc.system(cstr)` | `libc.system(cstr)` |
| `sound.odin` | `if trace_replaying() do return` in `play_slice` | delete |

# 11 — Engineering practices: architecture, testing, trace harness, code generation, build/CI and conventions

> Odin sources: ARCHITECTURE.md, docs/TESTING.md, docs/TRACE.md, docs/MULTI_AGENT.md, README.md,
> src/model/model.odin (`App`, `Input`, `update`, `keymap_run`, `ensure_menus`), src/model/keymap.odin
> (`KEYMAP_DEFAULT`, `keymap_serialize`, `keymap_parse`), src/model/settings.odin, src/model/project_roots.odin,
> src/model/heat.odin, src/model/file_grid.odin (`Fgrid_Lister`), src/model/typecheck.odin and var_types.odin
> (lazy `sync.Once` indexes), src/app/main.odin (main loop, `build_input`, `editor_input`, `app_requests`),
> src/app/trace.odin, src/app/keys_store.odin, roots_store.odin, heat_store.odin, settings.odin, updater.odin
> (the `VERSION` file contract: `install_root`, `install_asset`; `KEEP_FILES`), src/app/setup.odin (`ODIN_TAG`),
> src/app/checker.odin, src/model/data_types.odin (`decl_type_names`), src/platform/platform.odin (`dpad_repeat_tick`),
> the test files src/model/model_test.odin, handmade_acceptance_test.odin, handmade_exact_build_test.odin,
> integration_test.odin, review_fixes_test.odin, integrate_fixes_test.odin, branch_loop_*_test.odin,
> src/stt/stt_test.odin, src/app/shell_test.odin, src/platform/platform_test.odin, tools/trace.py,
> tools/gen_core_procs.py, tools/gen_core_tree.py, tools/odin_collections.py, tools/deck_install.sh,
> tools/convert_sounds.py, tools/stt/setup_whisper.sh, build.bat, build.sh, .github/workflows/release-steamos.yml,
> .zed/tasks.json, .gitignore, .gitattributes, and the git history (91 commits, 2026-11-17 to 2026-11-24).
> Baseline: Doodle @ 34a2ad1.

## Purpose

This area is about how Doodle is built, not what the player sees. A gamepad IDE is mostly hidden state: menus,
dots, cursor modes, and overlays. Each of those only shows up after a particular sequence of presses, so manual
testing with a controller is slow and easy to get wrong. Doodle solves this with four practices. First, every
decision lives in a pure model that a test can drive like a controller, with no window. Second, a debug-only trace
harness records every real session, can replay it bit-for-bit in a sandbox, and mines it for UX problems. Third,
the language knowledge in the menus is generated from the installed compiler, not written by hand. Fourth, a
manual release workflow builds and checks self-contained packages for SteamOS, Linux and Windows. The Rust IDE
should carry all four forward. This doc describes each one precisely and says what its Rust equivalent should be.

## Features

### 1. Pure model, thin app (the package split)

- **Trigger**: Every change. Logic goes in `src/model`, and `src/app` only translates devices, draws, and does I/O.
- **Behavior**:
  - `src/model` (Odin `package model`; about 24.5k hand-written lines in 64 files, plus about 189k generated
    lines in `core_*.odin`) holds everything the user can make happen. That covers the `App` state machine, the
    document, the menus, the cursor, the keymap, and every editing feature. It also holds the *pure halves* of
    app-side pages: the file-grid navigation logic (file_grid.odin), the Key Layout page cursor/picker
    (keys_page.odin), the Settings options and file format (settings.odin), project listing (projects.odin), and
    the extra-roots list (project_roots.odin). Finally it holds the parse/serialize code for every persisted file
    (keymap, heat, settings, roots). Its imports are `core:*` plus `base:runtime` (only typecheck.odin and
    var_types.odin, for `runtime.heap_allocator()`): no `vendor:`, and no platform, gpu, text or stt package.
    (`core:time` is imported only for the `time.Time` type and `time.diff`; `core:sys/windows` appears only
    inside a test's source string.)
  - `src/app` (Odin `package main`, about 9k lines) owns the SDL event loop, the GL drawing, the overlays (save
    dialog, file navigation, run list, docs panel, key layout page drawing, settings and setup pages, project
    pickers), all disk *writes*, child processes (`odin run/check`, terminals, whisper), the clipboard, sounds,
    worker threads, self-update, and the trace harness.
  - Leaf packages: `platform` (SDL2 window, events, audio capture, clipboard, d-pad auto-repeat; 227 lines),
    `gpu` (GL 3.3 batched quads; 264), `text` (stb_truetype glyph atlas; 107), `stt` (whisper-cli subprocess
    plus SDL audio; 518), and `stt_probe` (a 27-line standalone mic/whisper check:
    `odin build src/stt_probe -out:bin/stt_probe.exe`).
  - Actual import graph: `app` imports `model`, `platform`, `gpu`, `text` and `stt`; `gpu` imports
    `platform`; `text` imports `gpu`; `stt` imports `vendor:sdl2` only; `model` imports nothing internal.
    Nothing imports `app`.
- **Rules & edge cases**:
  - The model *may read* the disk (loading a file: parse.odin; sibling files: siblings.odin; docs lookups:
    docs.odin; `shared:` collection listing: collections.odin; project listing: projects.odin; the real
    directory lister `fgrid_list_disk`: file_grid.odin), and it reads two environment variables
    (`ODIN_ROOT`, then `PATH`, in collections.odin `odin_root`, falling back to `C:/Odin`), but it
    **never writes**. A grep of non-generated, non-test model files for `os.write*`/`remove`/`rename`/
    `make_directory` finds nothing.
  - The model has **no clock and no randomness**. A grep for `time.now`/`tick`/`rand.` in non-test model files
    finds nothing. Time comes in as a parameter (`age_label(t, now)` in projects.odin), and "random" project
    names are made in the app (`gen_project_name`, src/app/save.odin) and recorded by the trace.
  - ARCHITECTURE.md §3 still lists `buffer/`, `editor/`, `input/`, `ui/`, `lsp/` and `project/` (and has no
    `model` package at all), §5 gives each a "v0 interface", and docs/MULTI_AGENT.md calls those interfaces
    "frozen". They are 13 to 52-line stubs that `app` never imports: the editor became projectional (doc 00,
    "Superseded ideas"). **The code wins**: treat ARCHITECTURE.md §1 (goals), §2 (stack, except its
    "Odin intelligence: `ols` language server" row, which was never built) and the rule "`app` may import
    everything; nothing imports `app`; no cycles" as current, and the rest of §3 plus §4 to §8 as historical.
- **Rationale**: docs/TESTING.md says: "Doodle is a GUI app, so we keep the testable logic separate from
  rendering/IO", and "This split means we can test 'press A on File Setup then Package declaration inserts
  `package main`' without opening a window." The split was introduced in commit 909df86 ("extract pure logic
  into src/model (no SDL/GL), 9 unit tests").
- **Source**: src/model/model.odin header; src/app/main.odin header ("Integration layer ... This file is
  presentation + I/O only"); ARCHITECTURE.md §3.

### 2. The abstract `model.Input` and the per-frame contract

- **Trigger**: Once per frame, `src/app/main.odin` turns that frame's SDL events into one `model.Input` and
  calls `model.update(&m, inp)`.
- **Behavior**:
  - `Input` has ten booleans: `confirm, cancel, up, down, left, right` (edges: true only in the frame of the
    press), `lt_held, rt_held` (levels: a trigger past 0.5, or keyboard `q`/`e` held), and `x, y` (edges). It has
    no LB/RB, Start, Back or sticks. LB/RB and Ctrl+C are fixed app-side shortcuts (LB = run tests, RB = run
    favorite, Ctrl+C = copy), handled in main.odin only when `m.state == .Editor` and no run list, dictation,
    transcription, Reference pick or modifier pick is active. (Run favorite and Run tests also exist as
    rebindable keymap actions, unbound by default; their hints say "(RB too)" / "(LB too)".) Start/Back are
    used only by the trace replayer (feature 11).
  - The app keeps a `Raw` struct (trigger values, held pad buttons as a `Pad_Held` bit set, per-frame edge
    flags, typed characters). `build_input(&raw)` makes the `Input`. `editor_input(&raw)` is the same, but
    masks all navigation while dictating or transcribing.
  - `update(app, inp)` first resolves the frame's presses through the keymap (`keymap_resolve`, skipped in
    `.Radial` because menus only know plain A/B/d-pad). If the IDE-menu action fired, it opens the IDE menu
    and returns, in any state including the main menu. Then comes one big state switch (`.Menu`, `.Editor`,
    `.Radial`). In the editor, modal sub-states get first refusal in a fixed order: `ref_pick_update`,
    `grab_update`, `word_edit_update`, `mod_pick_update`. Then `keymap_run` performs the fired actions (in
    enum order, stopping once one leaves the editor), and the plain d-pad/A/B that is left (`keys.rest`)
    moves the cursor or opens menus (plain B in the editor goes back to the main menu). `update` ends with a
    chain of five `defer` re-syncs of derived dots (`result_list_sync`, `branch_sync`, `ctrl_sync`,
    `sync_capture_dots`, `word_edit_sync`; doc 01 §3).
  - **Effects the model can't perform go back out as data.** `App.requests: Actions` (a bit set) collects the
    keymap actions that need disk, the clipboard or an overlay: `.Docs, .Copy, .Save, .Save_As, .Run_List,
    .Files, .Run_Favorite, .Run_Tests, .Prev_File, .Key_Layout`. The app runs them in `app_requests` right after
    `update` and clears the set. `.Copy`, `.Save`, `.Run_Favorite`, `.Run_Tests` and `.Prev_File` all run
    (Prev_File with no previous file sets the status `no previous file yet`). Of the overlay-opening requests
    (`.Docs`, `.Save_As`, `.Run_List`, `.Files`, `.Key_Layout`), at most one runs per frame: the first in
    enum order, via a `switch`. `App.notice` (a static string) is the status-line message channel: the app
    shows it with `set_status` and clears it.
  - Overlay ownership: when an app overlay is open, it owns all input and `model.update` is **not called** that
    frame. The order is: stb prompt, vendor-path prompt, save/rename dialog, file nav, key layout, settings,
    projects, new project, docs panel, then the run list. Only when none of these is open does the editor get
    `model.update`. One more app-side interception comes before that routing: on the main menu (`.Menu`, no
    picker/page open), A on "Recent Projects", "New Project", "Key Layout" or "Settings" is consumed by the
    app (they need disk I/O or an app page). Only a replay of a pre-New-Project-dialog recording
    (`g_roots_legacy`) lets "New Project" fall through to `model.update`'s `new_project`.
  - Keyboard stand-ins (for development without a pad): `q`/`e` = LT/RT, `w a s d` and arrows = d-pad,
    Return/Space = A, Backspace/Escape = B, `x`/`y` = X/Y, `r`/`t` = RB/LB (`handle_key`, docs/TRACE.md).
- **Rules & edge cases**: d-pad auto-repeat (first repeat after 0.35 s, then every 0.07 s) is generated in the
  *platform* layer as ordinary `Button_Event{pressed=true}` events (`dpad_repeat_tick`, commit d6e415a). The
  model therefore never sees time, and recordings capture the repeats as real presses. Repeat is off while
  dictating, because d-pad Down ends a word then. Each frame ends with `free_all(context.temp_allocator)`, so
  scratch allocations last one frame.
- **Rationale**: "Driven by an abstract `model.Input` (button edges + trigger-hold flags) instead of raw SDL
  events. This is what we unit-test." (docs/TESTING.md). For the requests channel, keymap_run's comment says:
  "The ones that need disk, the clipboard or an overlay go to the app layer in app.requests." For overlays,
  main.odin says: "Every editor action comes from the button layout through model.update ... so none can fire
  with an overlay open."
- **Source**: src/model/model.odin (`Input`, `update`, `keymap_run`); src/app/main.odin (`Raw`, `build_input`,
  `editor_input`, `app_requests`, main loop); src/platform/platform.odin (`dpad_repeat_tick`,
  `DPAD_REPEAT_DELAY`, `DPAD_REPEAT_EVERY`). Controls themselves: doc 03.

### 3. Test-safe state: no mutable globals in the model; services as data

- **Trigger**: Any model feature that needs configuration, a service, or a cache.
- **Behavior**:
  - All model state lives in `App`, and a zero-value `App{}` is a valid, empty app. Menus are built lazily
    per App by `ensure_menus` (the `App.add_menu` field comment: "built lazily per-app (no globals ->
    test-safe)").
  - Services owned by the app layer are **nullable pointers with a default**. `App.keymap: ^Keymap` (nil means
    `KEYMAP_DEFAULT`) and `App.heat: ^Heat` (nil means no heat recorded, a no-op). Tests leave both nil.
  - The platform is data: `App.os_name` ("windows", "linux", ...) filters platform-tagged menu entries
    (`platform_ok`). Tests that touch tagged entries (10 test files, including the exact build) set
    `app.os_name = "windows"` so menus match the Windows-first tables on any host; the rest leave it `""`,
    which hides every tagged entry.
  - I/O seams are function parameters. `fgrid_build(&g, view, list: Fgrid_Lister)` takes a directory lister,
    and tests pass `fake_list` (file_grid_test.odin), so the file-navigation grid is tested with no disk.
  - Read-only caches over the big generated tables are process-wide, built once with `sync.Once` on
    `runtime.heap_allocator()`, "outside any tracked allocator" (`core_type_index` in typecheck.odin,
    `core_field_range` in var_types.odin). They are immutable after the first build, so they are safe under the
    parallel test runner and don't show up as per-test leaks.
  - What "no mutable globals" means precisely at baseline: Odin package-level tables declared with `:=`
    (`ACTION_INFO`, `MENU_ITEMS`, `KEYWORDS`, `OPERATORS`, ...) are syntactically mutable but never written;
    keymap.odin has a file-private `g_keymap_default := KEYMAP_DEFAULT` that `km_or_default` hands out by
    pointer and nothing writes; the two `sync.Once` caches above are write-once. The **one** real mutable
    global is `@(thread_local) decl_type_names: map[string]bool` in data_types.odin, a temp-allocated scratch
    map set only while `structure_type_decls` runs; its comment says why it is thread-local: "tests load
    documents on several threads". Nothing machine-checks the rule; it is a review convention.
- **Rules & edge cases**: `odin test` runs tests on many threads (the runner logs "Starting test runner with 10
  threads" on the dev machine). Any mutable global would make tests flaky. Non-test model code has exactly two
  compile-time OS switches: collections.odin `odin_root` (`"odin.exe" when ODIN_OS == .Windows else "odin"`)
  and project_roots.odin `roots_same` (`when ODIN_OS == .Windows`: case-insensitive folder names). The second
  one made two tests written with Windows paths fail on the Linux release runners, and commit 3383de7 fixed
  the *tests* to use per-OS paths. Rule: when model behavior really is OS-specific, the tests must cover each
  OS's cases.
- **Rationale**: "App.heat is nil in tests (no-op)" (heat.odin); "nil = KEYMAP_DEFAULT (tests, temporary Apps)"
  (model.odin `App.keymap`); "Nothing here knows the window size, so a move comes out the same at any size (and
  a recorded trace replays the same)" (file_grid.odin header).
- **Source**: src/model/model.odin (`App`, `ensure_menus`); keymap.odin (`km_or_default`, `g_keymap_default`);
  heat.odin; file_grid.odin (`Fgrid_Lister`, `fgrid_list_disk`); typecheck.odin; var_types.odin;
  data_types.odin (`decl_type_names`); collections.odin (`odin_root`); project_roots_test.odin.

### 4. Unit tests drive `update()` with synthetic presses

- **Trigger**: `build.bat test` / `./build.sh test` / `odin test src/model`.
- **Behavior**:
  - Tests live next to the code as `*_test.odin` in the same package (57 test files in src/model, about 23.4k
    lines, roughly 1:1 with the hand-written model code). They use `core:testing` and the `@(test)` attribute.
    At baseline the runner reports `Finished 594 tests in 10.55s. All tests were successful.` (re-run during
    fact-checking: 594 tests in 11.1 s, no memory warnings). 594 is exactly the number of lines that *start*
    with `@(test)`; a plain grep finds 613 because 19 more occurrences sit in comments, menu data and test
    source strings (attr_dots.odin and attr_dots_test.odin, which build `@(test)` procedures, plus docs.odin,
    docs_test.odin, modifiers.odin, model_test.odin and sibling_types_test.odin). Separately, `src/stt` has 8
    tests, `src/app/shell_test.odin` 12, and `src/platform/platform_test.odin` 1 (see gaps).
  - Shape of a test (model_test.odin `test_add_package_inserts_text`, lightly paraphrased: the file wraps
    `update(&app, Input{confirm = true})` in a file-private `confirm(&app)` helper, and also asserts
    `len(app.nav) == 0` and `len(app.doc.nodes) == 1`):
    ```odin
    app: App
    defer cleanup(&app)
    app.state = .Editor
    update(&app, Input{confirm = true}) // A on the green dot: Add menu
    testing.expect_value(t, app.state, State.Radial)
    update(&app, Input{confirm = true}) // File Setup
    update(&app, Input{confirm = true}) // Package declaration
    testing.expect_value(t, node_text(app.doc.nodes[0], context.temp_allocator), "package main")
    ```
    Combos are just fields set together, for example `update(&app, Input{left = true, lt_held = true})` is
    LT+Left (IDE menu).
  - Starting points: `app.state = .Menu` (main menu) or `.Editor` (empty document), or
    `doc_from_source(&app, text)` to load source. Results are read back with `doc_to_source(&app,
    context.temp_allocator)` (or `node_text`/`node_source` per line) and with `App` fields (`state`,
    `len(app.nav)`, `current_view(app).entries`, `.index`, `.dim`, `editor_line/field/dot`, mode flags such as
    `ref_pick_active`, and `notice`).
  - The standard file-private helpers (copied into each test file as `@(private = "file")`; 46 files define
    their own `cleanup`):
    - `cleanup(app)`: `clear_nav`, `delete(app.nav)`, `doc_reset`, `delete(app.doc.nodes)`,
      `delete(app.recent_imports)`, `free_menus`. A few copies free more (decl_value_test.odin also frees
      `app.slot_menu`).
    - `pick(t, app, label)`: find the label in the open menu, set `v.index`, press A. On failure it reports
      `no "<label>" in menu "<title>"`; the richer copies (13 files define `labels`) append `labels(app)`,
      the menu's labels joined with ` | `.
    - `dimmed(t, app, label)`: whether that entry of the open menu is grayed out (`Entry.dim`), failing with
      the label list if it doesn't exist. This is how graying rules are asserted.
    - `pick_leaf(t, app, label, fill)`: walk down to a leaf through nested groups. Each step is matched by
      *identity* (`raw_data(e.children)`, or label plus `fill` plus `call_name` plus `call_pkg`), not by
      position or label, because views reorder and labels repeat.
    - `back_out(app)`: up to 16 B presses until `state == .Editor` with no Reference pick or modifier pick.
    - `line_with(app, text)` and `focus_text`. `focus_dot_at` / `focus_field_index` are model procs that put the
      cursor anywhere directly (a test seam).
    - Every helper that asserts takes `loc := #caller_location` and passes it to `testing.expectf(..., loc =
      loc)`, so a failure points at the calling line (`cleanup` and `back_out` don't assert and don't).
  - Tests are named for behavior (`test_reference_cancel_leaves_dot_empty`, `test_keymap_old_save_as_layout`).
- **Rules & edge cases**:
  - Unit tests may teleport (set `v.index`, call `focus_*`). The controller-exact tests (feature 6) may not.
  - Helper copies are per file (`@(private = "file")`, so 46 files can each define `cleanup`/`pick` without
    a name clash inside the one `model` package). The likely reason, not written down anywhere (inferred), is
    that parallel feature branches could each own a test file without touching a shared helper file. The cost
    is duplicated, slowly diverging helpers (see the `pick` and `cleanup` variants above).
  - docs/TESTING.md's example (`defer delete(app.doc.nodes)`, asserting on `radial.index/level/kind`) predates
    the current `App` and the `cleanup` helpers. The code is the reference.
  - Guidance that still holds (docs/TESTING.md): "When you add a construct/insertion, add a test that it inserts
    the expected default text and leaves the app in the right state."
- **Source**: src/model/model_test.odin; src/model/assign_pick_test.odin (helpers); docs/TESTING.md.

### 5. Round-trip, format and integration tests

- **Trigger**: Every feature that adds a construct the loader must recognize (doc 01 §10, "loader/menu
  symmetry").
- **Behavior**:
  - *Verbatim round trip*: `doc_from_source(&app, X)`, then `doc_to_source(&app) == X`, then `format_doc(&app)`,
    and the source is still `X`. Example: integration_test.odin `test_integration_combo_round_trip`, which also
    checks that the loaded fields have the *kinds* the menus would have produced (`#packed` is a keyword, `hp` is
    a `member`, `$T` a `poly` name) and that the type oracle reads the loaded file (`var_type_at`,
    `expr_type_at`).
  - *Corpus round trips*: `test_accept_every_example_round_trip` and `test_accept_one_liners_round_trip`
    (branch_loop_acceptance_test.odin) load a file with every example of a table and save it back unchanged.
  - *Integration files* exist per merge: integration_test.odin ("Cross-feature checks after merging the gen /
    types / ctrl / fields builders"), and branch_loop_integration_test.odin (branching and loops together).
  - *Table-driven cases*: a local `Case :: struct {...}` array inside the test
    (`test_integration_reload_empty_operator_operands`, `test_integration_reload_open_values`).
- **Rules & edge cases**: Round trip is byte-exact, including the final newline state (`Doc.no_final_newline`,
  doc 01 §11).
- **Source**: src/model/integration_test.odin; src/model/branch_loop_acceptance_test.odin; doc 01.

### 6. Acceptance tests: a real program built with controller-equivalent input

- **Trigger**: The owner's north-star program. That is a Handmade Hero day-3 Win32 window (`package handmade`,
  `import win32 "core:sys/windows"`, a `proc "system"` window callback with a `switch message`, a `WNDCLASSW`
  struct literal, and a `GetMessageW` loop), plus one test per row of the Branching and Loops tables.
- **Behavior**:
  - `handmade_acceptance_test.odin` (4 tests: `test_handmade_accept_file_scope`, `..._build_program`,
    `..._load_verbatim`, `..._load_formatted`) builds the program from the menus the way the controller would:
    A on dots, menu picks, Reference / Pass as / Field of, Struct literal, Modifiers > Calling convention, Y and
    LT+B. Menu highlights (`v.index = i`) and the cursor (`focus_dot`, `focus_field_index`) are set directly
    (teleport). It also checks the target loads verbatim and formatted, and asserts graying on the way (for
    example `GetMessageW` is dimmed at a `for` condition dot because it returns an `INT`).
  - `branch_loop_acceptance_test.odin` (22 tests): "one controller-driven test per row, each building exactly
    the row's example inside `main` ... checking the saved text and the names the construct introduces (type,
    scope, Reference pick), then running `odin check` on the program."
  - `stmt_layout_test.odin` `test_layout_handmade_from_empty_project` builds the complete file from an empty
    project (and runs its `odin_check` helper on it as `handmade_layout` when `DOODLE_ODIN` is set).
  - `handmade_exact_build_test.odin` `test_handmade_exact_build` is the strictest test. It starts from the main
    menu, and **every move is a real input**:
    - It uses a `Pad` struct `{t, app, presses, notes}`. `press(p, inp)` counts and calls `update`.
    - `dpad_to(p, line, dot, fi)` first backs out to plain cursor mode, computes where `focus_*` *would* put
      the cursor, restores the cursor, then walks there: Up/Down presses until `cursor_stop_key` matches the
      target's, then (for a field) Up/Down between the rows of a line broken over several rows and
      Left/Right along the row. It fails with `D-pad: line N (dot=..) is not a cursor stop` if it must reverse
      direction, `D-pad stuck at line N on the way to M` if a press doesn't move, and `D-pad left/right can't
      reach field ...`. So every target must be reachable by d-pad.
    - `open_dot(p, ni, nth, kind)` d-pads to the nth slot of `kind` on a line and presses A, failing if no
      menu opened. Higher-level fills are built from it: `fill_ref` (Reference, then the name chosen with
      Left/Right presses, then the "Pass as" entry), `fill_number` (Value > Number, then LT+A and keypad picks
      ending in `OK`), `fill_nil`, `fill_op`, `fill_const`, `fill_call` (Call > From import > win32 > leaf).
    - `menu_go(p, target)` runs a BFS over `menu_nav` (the real grid navigation, called with each of the four
      directions) from the current highlight to find the shortest d-pad path, presses it, then presses A. It
      fails with `menu "<title>": "<label>" is not reachable with the D-pad` or `menu highlight didn't land on
      the entry`. A grayed entry picked is recorded as a note: `picked a GRAYED entry %q in menu %q`.
    - Y, LT+B and LT+A call `change_selected`, `delete_selected` and `edit_selected` directly (the editor
      actions those default bindings fire).
    - Dictation is `set_field_text` on the highlighted field, and only with what push-to-talk can produce:
      lowercase snake_case names, or spaced words in strings and comments. Casing such as `WHITENESS` or
      `HandmadeHeroWindowClass` must come from the LT+A text tools (`Case > UPPER_SNAKE`,
      `Word case > todo > UPPER`).
    - Saving is `save_text` = `format_doc` + `file_text` (the source without editor-only `●` lines, plus the
      final newline), the same as src/app/save.odin `write_doc`.
  - Assertions: the saved file equals `EXACT_TARGET` byte for byte. Reloading it gives the same source, and
    saving again changes nothing. When the first save differs (leftover `●` statement lines), the test logs
    `FINDING:` notes with a diff excerpt (`diff_excerpt`: an `@@ -a,b +c,d @@ (- = expected target, + =
    saved)` hunk) instead of failing, and also notes whether that file reopened and saved again still
    differs. It then d-pads to each leftover `●` line, removes it with LT+B (failing with `LT+B didn't remove
    the statement line N` if nothing happened), and asserts. It logs `built with N controller inputs` (2185 at
    baseline, confirmed by a re-run; that run logged no `FINDING:` lines, so at baseline the first save
    already equals the target). It writes artifacts to `<temp>/doodle_exact_build/first_save.odin` and
    `saved.odin`, and the compiler-check copies to `<temp>/doodle_exact_build/built/main.odin` and
    `.../target/main.odin` (the file header's `<temp>/doodle_exact_build/main.odin` is out of date).
  - `test_handmade_exact_load_round_trip`: the target loads verbatim, saves byte-exact, `format_doc` leaves it
    alone, a copy without the final newline saves without one, and it passes `odin check`.
- **Rules & edge cases**: The exact target has one deliberate deviation from the user's original:
  `for win32.GetMessageW(&message, nil, 0, 0) > 0 {` (integration_test.odin's `HANDMADE` keeps the original
  `for win32.GetMessageW(&message, nil, 0, 0) {`). The reason is in handmade_acceptance_test.odin: in this
  Odin `GetMessageW` returns an `INT`, so the original fails `odin check` ("Non-boolean condition"), and the
  editor deliberately grays non-bool values at a `for` condition dot. Soft findings never fail the test. They
  are `log.warnf` output for the developer.
- **Rationale**: The file header lists the rules ("Every cursor move is a D-pad press ... the helpers only
  compute WHERE to go, the presses get there or the step fails"). This is the executable form of principle P2,
  "gamepad-only authorable, proven by a real program" (doc 00).
- **Source**: src/model/handmade_exact_build_test.odin (`Pad`, `press`, `dpad_to`, `menu_go`, `pick_leaf`,
  `save_text`, `check_with_odin`, `write_artifact`); handmade_acceptance_test.odin;
  branch_loop_acceptance_test.odin.

### 7. Compiler checks inside tests (environment-gated)

- **Trigger**: Acceptance and regression tests call `check_with_odin` (handmade_exact_build_test.odin) or a
  local file-private `odin_check` helper (branch_loop_acceptance_test.odin, branch_loop_fixes_test.odin,
  expr_test.odin, stmt_layout_test.odin).
- **Behavior**: These helpers write the produced program to `<dir>/<name>/main.odin` and run
  `os.process_exec({odin, "check", dir})` (expr_test.odin adds `-thread-count:1`). The test fails with
  `odin check <dir> failed (err=..., exit=N):` plus the compiler's stdout and stderr (the `odin_check`
  copies also append `--- source ---` and the program) if the exit code isn't 0. The compiler is found as
  follows:
  - handmade_exact_build: `$DOODLE_ODIN`, else `C:/Odin/odin.exe` if it exists. Otherwise it logs
    `odin check skipped (no DOODLE_ODIN)` and passes.
  - the branch/loop/expr helpers: only `$DOODLE_ODIN`. Output goes to `$DOODLE_CHECK_DIR` (default
    `<temp>/doodle_accept_check/<test>/main.odin`). branch_loop_integration_test.odin also honors
    `DOODLE_CHECK_DIR` for writing the programs for a manual `odin check`.
  - In each `odin_check` file a file-private `check_mutex: sync.Mutex` serializes the compiler runs, because
    tests run in parallel (it's per file, so runs from different files can still overlap; `check_with_odin`
    has no mutex).
- **Rules & edge cases**: **So yes, the test suite invokes the real compiler, but only where one is configured.**
  On the dev machine `C:\Odin` exists, so the exact build is checked. In CI the Odin install lives elsewhere
  (`/opt/odin`, or `C:\odin-dist\...` on Windows) and `DOODLE_ODIN` is not set, so every compiler check is
  skipped in CI (see Open questions). The skip is silent for the `odin_check` helpers; `check_with_odin` logs
  the warning `odin check skipped (no DOODLE_ODIN)`. A different gate reads the compiler's *library*: docs
  tests such as docs_test.odin `test_doc_lookup_odin_install` find the install through the model's
  `odin_root` (`$ODIN_ROOT`, then the folder of `odin`/`odin.exe` on `PATH`, then `C:/Odin`) and return early
  when `<root>/core/fmt` is missing; in CI `odin` is on `PATH`, so those do run there. The STT test
  `test_async_transcribes_in_order` likewise returns early unless `third_party/whisper.cpp/samples/jfk.wav`
  (made by tools/stt/setup_whisper.sh), whisper-cli and a model exist.
- **Source**: the helpers named above; src/model/docs_test.odin; src/model/collections.odin (`odin_root`);
  src/stt/stt_test.odin.

### 8. Regression tests per review finding, and performance tests

- **Trigger**: After a multi-feature merge or a review pass, each finding gets one test named for it.
- **Behavior**:
  - review_fixes_test.odin ("Regression tests for the review findings fixed after the four-feature merge ...
    Each test names its finding"; 28 tests, with comment headers such as `// ---- #1 / #2: ...`).
  - integrate_fixes_test.odin (15, "fixed together with the exact Handmade build").
  - branch_loop_fixes_test.odin (15, "one test per finding, driven like the controller").
  - Performance budget as a test: `test_review_struct_literal_graying_is_fast` loads a file importing
    `core:sys/windows`, `vendor:sdl2` and `vendor:vulkan`, opens a value dot expecting `win32.RECT`, and asserts
    the menu opened in under **300 ms** (`time.now()` / `time.since` around the single `update` that presses
    A; failure text `opening the dot took <duration>`). It also checks the graying under "Struct literal"
    (`RECT` lit, `POINT` dim). The clock is read by the *test*, never by the model.
- **Rationale**: The large generated tables made naive lookups slow (comments in typecheck.odin and var_types.odin
  cite "a linear scan per lookup made menus with many entries slow"), so speed is pinned by a test.
- **Source**: the three files above.

### 9. Leak discipline

- **Trigger**: Every test. `odin test` wraps each test's allocator in a tracking allocator.
- **Behavior**:
  - The Odin test runner reports per-test leaks and bad frees ("Memory tracking is enabled. Tests will log their
    memory usage if there's an issue."). docs/TESTING.md sets the bar: "All tests should report
    `All tests were successful.` with no leak warnings."
  - Ownership is written into the data model as comments: `Field.hint: ... Not owned`; `App.hint_pool:
    owned Field.hint strings read from document text (freed by doc_reset)`; `Entry.owned_label`; `heat_key ...
    Owned when non-empty`; `MenuView.labels: allocated bucket labels to free on pop`. Every test frees through
    `cleanup` (feature 4).
  - Scratch work uses `context.temp_allocator`: freed per frame in the app (`free_all` at the end of the main
    loop) and per test by the runner.
  - Process-lifetime caches deliberately use `runtime.heap_allocator()` outside the tracker (feature 3).
  - History shows this is enforced in practice: "Fix leak in build_block_children" (3d66bc6), "Drop leaky global
    proc cache: procs_for_path scans CORE_PROCS directly (caller frees); fix test leak" (0e7b0c4), "Fix
    double-free: build a separate core import tree for Import and Aliased import branches" (78b18de), and "test(decl-value): don't
    free the refill list twice (doc_reset already does) ... The test runner's memory tracker reported a bad free,
    which failed the Windows release build" (0c289ea). Commit bodies report "Tests: 191 model + 6 stt, no leaks."
- **Rules & edge cases**: With Odin's defaults (`ODIN_TEST_TRACK_MEMORY=true`,
  `ODIN_TEST_FAIL_ON_BAD_MEMORY=false`, core/testing/runner.odin of the installed dev-2026-11 compiler) a leak
  or a bad free is logged as a **warning**, not a failure. The runner installs
  `mem.tracking_allocator_bad_free_callback_add_to_array` as each test's bad-free callback, and the tracking
  allocator does *not* forward a free of an unknown pointer to the real heap, so a plain double free is
  recorded and reported, not a crash. "No leak warnings" is therefore a convention enforced by reading the
  output. The build scripts and CI don't pass `-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`. Commit 0c289ea
  says the reported bad free "failed the Windows release build". That is consistent with the double free
  hitting a block that had been reallocated in between (then the "second" free releases someone else's live
  memory and the Windows heap can fault later), but the failing job's log isn't in the repo (unverified).
  The fix removed `refill_discard(app)` / `delete(app.refill_saved)` from decl_value_test.odin's `cleanup`,
  because `doc_reset` already frees them.
- **Source**: docs/TESTING.md; src/model/model.odin field comments; git log (`git show 0c289ea`); Odin's
  core/testing/runner.odin and core/mem/tracking_allocator.odin.

### 10. Trace harness: recording every debug run

- **Trigger**: Any debug build run (`build.bat`, `build.bat run`, `./build.sh run`). It is skipped with
  `--no-trace` or `DOODLE_TRACE=0` (`off`/`false` also work) in the environment.
- **Behavior**:
  - At startup (`trace_start`, after the keys, roots, settings and heat stores load so it can record or pin
    them), `record_begin` prunes old recordings and creates `<exe dir>/traces/<UTC stamp>/`, for example
    `bin/traces/20261120-233007Z/`, with `-2`, `-3` suffixes on a clash.
  - **Snapshot** (`copy_tree` with `Copy_Opts`): copies the projects folder to `snapshot/projects` (depth up
    to 16). Each extra project root (doc 09) goes to `snapshot/roots/<i>` with `root_scan`: only `.odin`
    files, the root's own files plus each project folder's top level (depth 1). A file opened from the command
    line from outside the projects folder brings its folder's top-level `.odin` files to `snapshot/extra`
    (`only_odin`, depth 0). Modification times are preserved (`os.change_times`). Folders named `.git`,
    `bin`, `node_modules`, `traces` or starting with `_replay` are recreated as **empty folders**; binaries
    (`.exe .dll .pdb .obj .lib .ilk`), non-`.odin` files in the `.odin`-only modes, and files over 4 MB
    become **empty placeholder files**, so listings stay identical. Files unchanged since the newest
    previous snapshot that has a `snapshot/projects` (same size and mtime) are **hard-linked** to it, so a
    snapshot usually takes milliseconds; links count against the file budget but not the byte budget.
    Budgets are 32 MB copied and 4000 files. The snapshot is marked incomplete when a *wanted* file had to
    become a placeholder (over 4 MB, or past a budget), a folder past the depth limit was left empty (not for
    roots or the depth-0 `extra` folder), a copy failed, or a symlink/junction/device was skipped (not for
    roots). Then `meta snapshot_ok 0`
    is written and the status line says `trace: snapshot incomplete (replays of this run may differ)`.
  - **Meta**: `meta start_unix`, `cwd`, `projects`, `start_file`, `start_rel`, `stt` (0/1), `snapshot_ok`,
    `keymap` (the full doodle_keys.tsv text), `roots` (tab-separated), `settings`, plus one `meta arg` per
    command-line argument.
  - **Per frame**: `trace_poll` replaces `platform.poll_events` and writes each input event. `trace_frame_begin`
    snapshots the screen context before input is routed. `trace_frame_end` writes the state fingerprint, an
    `act` record (presses plus `pre`/`post` screen context plus `edit`), and a `list` record when a new list
    becomes visible. Frames with nothing in them are not written.
  - A small red dot is drawn top-left while recording (`trace_draw`). Only the newest 40 recordings are kept
    (`TRACE_KEEP`). Pruning only touches folder names starting with a digit, so `script-*` fixtures and the
    `_replay*` sandboxes survive.
  - At exit (`trace_stop`): `end <frame>` in input.log and an `end` mark in events.jsonl, then
    `trace: saved <dir>` on stderr. If the folder or files can't be created, stderr says
    `trace: cannot create <dir>; not recording` or `trace: cannot write to <dir>; not recording` and the run
    continues unrecorded.
  - While recording, buffered lines are flushed to disk at the end of every frame, so a crash loses at most
    the current frame.
- **Rules & edge cases**:
  - Triggers are recorded only when they cross half-way, because that is all the app checks. Sticks are never
    recorded, because the app ignores them. Window size is recorded (`size w h`) because the docs panel pages by
    it.
  - Keyboard `q`/`e` presses appear in events.jsonl as `LT`/`RT`. For every press that is not itself a trigger
    edge, `mods` is the trigger state *after* all of the frame's events, "as the app saw them" (trigger
    edges keep the state at their own moment). `Resize_Event` and `Text_Event` are not written; the window
    size is polled instead.
  - An `fp` line is written for a frame that had input lines or whose fingerprint changed; an `act` record
    when it had presses or the fingerprint changed; a `list` record when the visible list's signature
    (FNV of `scr`, `title`, `trail` and the items) changed and the list is non-empty.
  - `trace_frame_begin` and `screen_ctx` must be read-only ("it must not change anything a replay depends on").
- **Rationale**: docs/TRACE.md lists the uses: find a moment and replay to it, analyze usage to decide what
  should be easier to reach, and "verify that a replay still reproduces a run (a cheap regression test)".
- **Source**: src/app/trace.odin (`trace_start`, `record_begin`, `copy_tree`, `Copy_Opts`, `prune_traces`,
  `trace_poll`, `note_event`, `trace_frame_end`, `screen_ctx`); docs/TRACE.md.

### 11. Replay in a sandbox

- **Trigger**: `bin\doodle.exe --replay <last | stamp | folder | path\to\input.log> [--until FRAME] [--speed X]
  [--takeover] [--exact] [--exit-at-end] [--screenshot F]`, or `build.bat replay [trace] [options]` (default
  `last`), or `python -I tools/trace.py replay <trace> ...`.
- **Behavior**:
  - `replay_begin` resolves the trace (`last`/`latest` is the newest stamp folder) and parses `input.log`. It
    then builds the **sandbox**: `bin/traces/_replay/`, a fresh *real copy* (never hard links) of the
    recording's `snapshot/`, with mtimes kept "(the project list sorts by them)". If the previous sandbox has a
    `.takeover` marker, it is kept once as `_replay.prev`.
  - It points `g_projects_dir` at `_replay/projects`. The start file comes from `start_rel` (rejected if it
    contains `..` or is absolute, with stderr `trace: ignoring start file "<rel>" (outside the snapshot)`) or
    from `extra/<base name of start_file>`.
  - stderr reports, in order of the checks: `trace: no recording found for '<arg>' (looked in <exe
    dir>/traces)`, `trace: cannot read <dir>/input.log`, `trace: <dir>/input.log is not a doodle-trace 1
    file` (each of these makes `trace_start` print `trace: replay failed; starting normally (not
    recording)` and run a normal, unrecorded session); then warnings `trace: the recording used
    speech-to-text, which isn't available now; the replay may differ` and `trace: the recording's snapshot
    was incomplete; the replay may differ`; then `trace: replaying <dir> (<n> recorded frames[, until frame
    F])`. Bad option values print `trace: --until needs a frame number; replaying to the end` or
    `trace: --speed needs a number (0 = fast, 1 = real time)`.
  - It **pins** everything per-user from the recording: the keymap (`keys_store_override(meta keymap)`), the extra
    roots (sandbox stand-ins `_replay/roots/<i>`), and the settings. The heatmap is never saved
    (`g_heat_nosave`). None of these files is read or written during a replay.
  - With `--speed` 0 (the default) it runs as fast as possible (vsync off). `1` is real time, `4` is 4x.
  - During playback, real input drives only the replay. **Back/F6** pause or resume; **Right** (only while
    paused or at the end) and **F7** (any time: it also pauses) step to the next recorded frame with a press in
    it; **Start/F5** takes over. Held control keys don't auto-repeat. Closing the window quits.
  - The banner (a pale yellow box, top left) reads `REPLAY <PLAYING|PAUSED|END>  frame <cur> / <last>   <controls>`,
    where `<last>` is the last recorded frame (capped at `--until`) and `<controls>` is
    `Back/F6 pause   Start/F5 take over` while playing, `Right/F7 step   Back/F6 resume   Start/F5 take over`
    while paused, and `Start/F5 take over` at the end. After a divergence it appends
    `   (diverged at frame N)` and the **whole** banner text turns red.
  - A replay feeds each recorded frame's events, then runs **one empty "settle" frame** after it. `--exact` runs
    every empty frame in between: "nothing in Doodle changes without input".
  - **Side effects are suppressed** while `trace_replaying()` (a replay that hasn't been taken over): running
    programs (`libc.system` in run.odin), the clipboard, sounds, the Recycle Bin (a delete just removes the
    sandbox file, and only if `trace_write_ok` allows it), the Settings > Setup installs, the self-updater's
    check and install, and the vendor-library PATH edit (status `not during a replay`,
    `replay: PATH left as it is`, `replay: ~/.profile left as it is`). The startup "install Odin" hint is not
    shown either. The heatmap is never saved (`g_heat_nosave`). Independently of takeover, every guarded file
    write outside the sandbox is refused: `trace_write_ok(path)` returns false and the status line says
    `(replay) skipped writing outside the sandbox: <base name>`.
  - Not suppressed: the background `odin check` (checker.odin) still writes its scratch copy to
    `<temp>/doodle_check/` and runs the compiler. Its results are deliberately outside the fingerprint.
  - If the recording quit with B on the main menu, the replay stops there instead of quitting
    (`trace_frame_end` clears `want_quit` unless the real window was closed). A recorded `quit` (window
    closed) frame is never fed: the replay finishes just before it.
  - On reaching `--until` or the end (`finish_replay`), it pauses, restores vsync and prints
    `trace: replay reached frame N (matched the recording)` or `... (diverged at N)`. `--takeover` hands over
    automatically. `--exit-at-end` quits; `trace_stop` then prints
    `trace: RESULT <matched|diverged@N|incomplete> frames=<n> reached=<f>` to stderr (`frames` is the number
    of recorded frames *with content*, `reached` the recorded frame number reached; `incomplete` means the
    end was never reached, for example the window was closed). `--screenshot F` writes a PNG of the final
    frame (`glReadPixels`, rows flipped, alpha forced opaque, the banner kept out of the shot) and prints
    `trace: screenshot F` or `trace: could not write screenshot F`.
  - **Take over** (`take_over`): releases anything the recording held (triggers, X, keys) and goes live, with
    vsync back on. Because `trace_replaying()` is now false, *every* guard keyed on it lifts: programs,
    clipboard, sound, the Recycle Bin, Setup installs, the updater and the PATH edit work again. Only writes
    guarded by `trace_write_ok` (saves, new files, renames, `run.txt`, new project folders, the per-user
    stores) stay inside the sandbox, and the per-user stores and heatmap stay pinned (`*_nosave`). The banner
    says `SANDBOX: files are only written inside traces/_replay`, a `.takeover` marker is written into the
    sandbox, and stderr says `trace: took over at recorded frame N; recording to <dir>`. It starts a new,
    **self-contained** recording: the source's `snapshot/` is copied in (the code comment says "links", but
    `copy_tree` is called with no `prev` folder, so nothing is hard-linked; budgets are unlimited), all
    records so far are kept, the source's frame numbers and clock carry on (live frames start at the last
    replayed frame + 2, one gap for the settle frame), the source's meta lines are kept except old
    `derived_*` ones, and `meta derived_from <stamp>` / `meta derived_until <frame>` are added. Pruning runs
    with the source and the new folder protected.
- **Rules & edge cases**: Known causes of divergence are STT not being available at replay time, an incomplete
  snapshot, browsing outside the projects folder, the "+ Add another folder" browser (reads the real disk),
  opening files below a project's top level in an added root, and Doodle's own code having changed since the
  recording (that is what `verify` checks).
- **Source**: src/app/trace.odin (`replay_begin`, `resolve_trace`, `parse_input_log`, `replay_poll`,
  `finish_replay`, `take_over`, `trace_replaying`, `trace_write_ok`, `trace_draw`, `trace_after_draw`);
  docs/TRACE.md.

### 12. Fingerprints, divergence and backward-compatible recordings

- **Trigger**: Every recorded frame that had input or a state change. During a replay, every fed frame.
- **Behavior**:
  - `fingerprint(m)` is a 64-bit FNV-1a hash (offset `0xcbf29ce484222325`, prime `0x100000001b3`, a `0xff`
    separator after each string, ints hashed as 8 little-endian bytes).
  - It hashes, in this order: the document (`doc_hash`: every field's text and slot flag, a `"\n"` after each
    line), `state`, `menu_index`, the menu stack (its length, then each view's title, index and entry count),
    the cursor (`editor_line/field/dot/attr`), 18 flags (`ref_pick_active, ref_pass_active, mod_pick_active,
    rename_active, replacing, refill_active, change_call, body_insert_active, decl_form_active, tree_sticky`
    plus the app's `g_save_open, g_filenav, g_fn_search_active, g_proj_open, g_doc_open, g_run_open,
    g_run_submenu, g_recording`), `ctrl_menu`, then the app overlays: save-dialog text, the base name of the
    pending overwrite, file-nav index / entry count / search query / base name of the pending delete,
    project picker index, docs scroll, run list and template indexes, the **base names** of the current file
    and project, the file-nav grid (view base name, `descents`, `group`, `item`), the Key Layout page
    (open, bank, row, picking, pick, asking_reset) and the whole current keymap (always hashed), then the
    conditional parts below.
  - Not hashed at baseline: `grab_active` / `grab_copy`, `word_edit_active`, `slot_menu` and `g_stt_busy`
    (they appear in `screen_ctx` modes but not in the fingerprint). Their *effects* on the document and
    cursor are hashed, so a divergence usually still shows up a frame later.
  - It leaves out what is nondeterministic but harmless (`odin check` results, timings) and absolute paths.
  - The recorder writes `<frame> fp <16 hex>`. The replayer compares after each fed frame and reports the
    **first** mismatch: stderr `trace: replay diverged from the recording at frame N`, a `diverged` mark, and
    the red banner.
  - **Backward compatibility is a design rule.** New state is mixed into the hash **only while its feature is
    open**, each behind a distinct tag value: the vendor-library prompt (`fnv_int(h, 2)` + index, only while
    `g_vp_open`), the stb prompt (tag 3 + index, while `g_sb_open`), the Settings page (tag 1 + row + every
    option, while `g_settings_open`), and New Project's list (its open flag, indexes, browsing state, row
    count, folder title and root count, mixed in while it's open *or* once any extra root exists), "so
    recordings made before ... keep their fingerprints".
  - Behavior that changed is gated by the *absence* of a meta key. A recording with no `meta settings` gets
    `App.menu_legacy = true`, the old 4-item main menu ("a 5th item changes the grid (2x2 -> 3+2), so its presses
    would land elsewhere"). One with no `meta roots` uses the old New Project flow (`g_roots_legacy`). One whose
    `meta keymap` is missing or empty gets `keys_store_override("")`, which is `KEYMAP_DEFAULT` (what
    recordings made before the Key Layout page used).
- **Rules & edge cases**: The fingerprint only covers state that input can change *and* that is replayed. A
  feature that adds overlay state to the app must add it here, with the "only while open" guard, or regressions
  in it will go unnoticed by `verify`. The rule is not always followed: the Grab feature (cee37be) added only a
  `screen_ctx` mode, not fingerprint state (see the "Not hashed" list above).
- **Source**: src/app/trace.odin (`fnv`, `fnv_int`, `doc_hash`, `fingerprint`, `trace_frame_end`,
  `replay_begin`); src/model/model.odin (`menu_items`, `menu_legacy`).

### 13. Values a replay can't recompute

- **Trigger**: Anything not a pure function of input: speech-to-text results and the random project name.
- **Behavior**:
  - `trace_str(kind, live)` records `<frame> str <kind> <escaped text>` and an events.jsonl `mark`. During a
    replay it returns the recorded value instead of `live`. It is used as `trace_str("project_name",
    gen_project_name())` in save.odin.
  - STT: `trace_stt_begin/segment/end` (blocking: dialogs, Files search) and
    `trace_stt_segment_async/end_async/poll` (the editor's background transcription, commit d6d998b). Recorded:
    each text in the frame it arrived in a poll. Replayed: the engine is never touched, and `poll` hands back the
    recorded text once the replay reaches its frame.
  - For `trace_str` and the blocking STT calls (`next_str`), a value recorded in a different frame is still
    used but prints `trace: recorded '<kind>' came from frame F, replay is at G`; running out prints
    `trace: replay ran out of recorded '<kind>' values` and yields `""` (`trace_str` then keeps the live
    value). The async `trace_stt_poll` never warns: it simply returns nothing until the replay reaches the
    recorded frame. Every recorded value is also written as a `str` line plus an events.jsonl `mark`, during
    replays too.
  - Dictation started during a replay and then taken over yields empty texts (`stt_fake`), since nothing was
    heard.
- **Rules & edge cases**: An older recording whose text arrived in the same frame as the press replays the same,
  because poll runs right after queueing in that frame.
- **Source**: src/app/trace.odin (`trace_str`, `trace_stt_*`, `stt_queue`, `stt_result`, `note_str`,
  `next_str`); src/app/save.odin.

### 14. `verify`: replay every recording as a regression suite

- **Trigger**: `python -I tools/trace.py verify <trace|all> [--exe PATH] [--timeout S]` (default timeout 120 s).
- **Behavior**: For each recording with an `input.log` (oldest first), it runs
  `bin/doodle(.exe) --replay <abs dir> --exit-at-end` with cwd at the repo and parses the
  `trace: RESULT (\S+) frames=(\d+) reached=(\d+)` line from stderr. It first prints
  `replaying N recording(s); each briefly opens a Doodle window`, then a table
  (`stamp | result | frames | reached | time`) and `N ok, M not ok`, and exits 1 if any result isn't
  `matched`. A run without a RESULT line shows `failed (exit <code>: <last stderr line, 60 chars>)`, a
  timeout `failed (timeout <S>s)`. No candidates prints `no recordings with input.log`; a missing exe gives
  `trace.py: no exe at <path> (build.bat first)`. `all` (like `last`) only considers folders whose names
  start with a digit, so `script-*` fixtures are never verified.
- **Rules & edge cases**: It needs a debug build, a display and a GPU. Recordings live in `bin/` (git-ignored), so
  the "suite" is the developer's own last 40 sessions, not a committed corpus. No CI job runs it.
- **Source**: tools/trace.py (`cmd_verify`, `RESULT_RE`); src/app/trace.odin (`trace_stop`).

### 15. Analysis: report, find, show, list

- **Trigger**: `python -I tools/trace.py <list|report|find|show> ...`. Every command accepts
  `--traces DIR` (default `<repo>/bin/traces`). A `<trace>` is `last`, a stamp, a folder, an `input.log` path,
  or `all` where allowed.
- **Behavior**:
  - `list [--limit N]` (default 20, newest first): a table with columns
    `stamp | started (local) | dur | acts | presses | files | derived_from | clean end`. `acts` counts
    `act` records with at least one press; `presses` counts buttons, trigger pulls, typed and other keys;
    `files` is the number of distinct `post.file` base names; `clean end` is `yes` when there is an `end` mark
    or `end` line, else `NO`. Without an events.jsonl it falls back to input.log (frames with presses, press
    count, last `t`) and adds ` (no events.jsonl)`. No recordings prints `no recordings in <dir>`.
  - `replay <trace> [--until F] [--speed X] [--takeover] [--exact] [--exit-at-end] [--exe PATH]` prints the
    equivalent `bin\doodle.exe --replay <stamp or path> ...` line, then runs it.
  - `report <trace|all> [--top N]` (default 15) first prints `report over N trace(s): <last 5 stamps>` (and
    how many were skipped for having no actions), then six sections: `(a) Button usage` (presses by combo, auto-repeats
    skipped), `(b) What the presses meant (ranked)`, `(c) Menu picks` (each final pick with its menu path and
    its **cost in presses** since the chain started), `(d) Time per screen`, `(e) Mistake signals` (each with
    a frame, so you can replay to it), and `(f) Suggestions`.
  - The mistake signals are `A then B (picked wrong?)` (B within 1.5 s of A on the same screen),
    `3+ B presses in a row`, `d-pad oscillation` (3 or more alternating opposite moves), `delete then re-add`
    (within 3 s at the same line), `menu backed out without a pick`, `save dialog cancelled`,
    `repeated dictation` (same field within 10 s), and `replay diverged`.
  - Suggestions (`suggestions`): the two final picks with the highest total press cost, each if used 3+ times
    or costing 3+ presses on average ("consider a button, pinning it, or the recent section"), the most-used trigger combo with 3+
    uses ("if it's a core action consider a single-button binding or swapping it with a rarely used one"),
    the menu most often backed out of ("check its labels / order"), d-pad oscillation seen 2+ times
    ("consider wrap-around, paging or putting frequent items first"), editor bindings never used
    ("candidates to rebind"), and the four least-used ones. With none it prints
    `nothing stands out yet; record more sessions`.
  - `find <trace|all>` takes ANDed predicates: `--menu-all-prefix S` (a visible list whose non-empty items all
    start with S), `--menu-title`, `--item`, `--scr`, `--sel`, `--press COMBO`, `--mode`, `--leaf`, `--text`,
    `--expr PY` (`eval` with `r` = record and `s` = screen state; "only run it on your own recordings"), and
    `--first`, `--limit` (default 50). Text matches are case-insensitive substring tests. It prints matches
    plus the exact `--replay ... --until F` command.
  - `show <trace> [--around F] [--from F --to F] [--context N]` (default context 10 acts each side) prints a
    readable timeline.
  - Menu-pick cost: a "chain" starts when a menu opens; every button press inside counts; a pick (A, Return
    or Space with no trigger held and not an auto-repeat, on `scr == "menu"`) that opens a deeper submenu
    is counted under "submenus opened", and a final pick records the chain's cost and the item's
    `idx/n`. Section (c) prints the picks twice: by count, and as "frequent and expensive"
    (count x average cost).
- **Rules & edge cases**: Button *meanings* come from the hand-maintained `BINDINGS` table near the top of
  tools/trace.py. It maps context (a screen, `screen[mode]`, or `screen[dot]`) to combo to meaning. `Dpad`
  stands for any direction, and an exact combo beats `LT+Dpad`. For the editor, `use_layout` replaces the
  defaults with the layout the recording started with (`meta keymap`), translating action keys through
  `LAYOUT_ACTIONS` and always adding the fixed `A`/`B`/`Dpad`/`RB`/`LB` meanings. docs/TRACE.md says: "Update
  it when the bindings change." At baseline it is stale (see Open questions). Keyboard presses are mapped to
  pad names first (`KEY_MAP`: `w a s d`/arrows = d-pad, Return/Space = A, Backspace/Escape = B, `x`, `y`,
  `r` = RB, `t` = LB); on `save_dialog`/`rename` screens letter keys count as typed text.
- **Rationale**: "analyze which buttons, combos and menu items you use most, how many presses things take to
  reach, and where you back out or undo, to decide what should be easier to reach" (docs/TRACE.md). The trace
  is a UX research instrument, not only a bug tool (doc 00 P18).
- **Source**: tools/trace.py (`cmd_list`, `analyze`, `cmd_report`, `suggestions`, `cmd_find`, `matches`,
  `cmd_show`, `BINDINGS`, `use_layout`, thresholds `AB_WINDOW`, `READD_WINDOW`, `STT_WINDOW`, `OSC_MIN`,
  `B_RUN_MIN`).

### 16. Scripted fixtures and screenshots (UI checks without a controller)

- **Trigger**: `python -I tools/trace.py script <name> <steps...> [--projects DIR] [--open REL] [--size W H]
  [--run] [--shot PNG] [--exe PATH] [--timeout S]`.
- **Behavior**:
  - It writes a synthetic recording to `bin/traces/script-<name>/`: an `input.log` with header
    `doodle-trace 1`, `meta start_unix/projects/start_file/start_rel`, `meta stt 0`, `meta snapshot_ok 1`, and
    empty `meta roots` and `meta settings` (so the current flows apply). Frame `0 t 0` and `0 size 1280 800` (or
    `--size`) come first. `--projects` is copied into `snapshot/projects` (ignoring `.git`, `bin` and `*.exe`).
  - Step grammar (space-separated, at 60 frames/s, starting at frame 10):
    - `A B X Y Up Down Left Right LB RB Start Back`: pressed in one frame, released in the next, then 4 idle
      frames.
    - `LT+B`, `RT+Y`, `LT+Left`: the trigger axis goes to 1.0 at frame F, the button is pressed at F+2 and
      released at F+3, and the axis goes back to 0.0 at F+4 (then 4 idle frames).
    - `LT` / `RT`: a bare trigger pull (1.0 at frame F, 0.0 at F+3).
    - `hold:LT+X:40`: the button stays down for 40 frames (talk).
    - `text:hello`: keyboard keys, lowercased (space = 32), each pressed and released in consecutive frames
      with 2 idle frames after.
    - `key:Return`: one key (`Return Escape Backspace Space Tab Up Down Left Right` or a single character),
      then 3 idle frames.
    - `wait:30`: 30 idle frames.
    - Anything else exits with `trace.py: unknown button 'Q' in 'Q' (use A B X Y ..., LT+X, text:..., key:...,
      wait:N)` (or `unknown trigger`, `unknown key`).
  - The fixture name is sanitized to `[A-Za-z0-9_.-]` and an existing `script-<name>` folder is replaced.
    Without `--run`/`--shot` the tool prints `wrote <dir>` and `replay: bin\doodle.exe --replay
    script-<name>`. `--run` replays it with `--exit-at-end`; `--shot PNG` alone also triggers the replay and
    saves a PNG of the final screen. The tool echoes the replay's `trace:` lines.
  - Example: `python -I tools/trace.py script filenav "RT+B Down Right A" --projects C:\some\projects --open
    demo/main.odin --shot out.png`.
- **Rules & edge cases**: Fixtures carry no `fp` lines, so they can't diverge. They are for seeing a screen, not
  for asserting state. There is no `meta keymap`, so they use the default layout. They aren't counted as
  recordings (not `last`, not `all`, never pruned).
- **Source**: tools/trace.py (`script_lines`, `cmd_script`, `PAD_BUTTONS`, `SDL_KEYS`).

### 17. The harness is compiled out of release builds

- **Trigger**: `build.bat release` / `./build.sh release` / CI. These pass `-define:DOODLE_TRACE=false`.
- **Behavior**:
  - `TRACE :: #config(DOODLE_TRACE, ODIN_DEBUG)`. All of trace.odin sits inside `when TRACE { ... } else {
    stubs }`.
  - With it off, each hook is a `#force_inline` pass-through stub: `trace_poll` calls `platform.poll_events`,
    `trace_write_ok` returns true, `trace_replaying` returns false, `trace_str` returns `live`, and the STT hooks
    call the `stt` procs. Code in the false `when` branch "isn't even type-checked".
  - Every hook site in other files carries a `// TRACE hook` comment, so `grep -rn "TRACE hook" src` lists
    them. At baseline that grep finds **39** marked lines in **14** files besides trace.odin (filenav,
    keys_store, main, roots_store, run, save, save_dialog, settings, setup, sound, toolchain, updater,
    vendor_path_other, vendor_path_windows). Only 13 of them carry the full form `// TRACE hook (was:
    <original code>)`; the other 26 are a bare `// TRACE hook` or `// TRACE hook: <reason>` (for example
    `if !trace_write_ok(path) do return // TRACE hook: a replay writes only inside its sandbox`), where the
    undo is "delete the line" or "drop the guard". docs/TRACE.md "Removing the harness" has a 17-row table
    that predates the hooks in settings.odin, setup.odin, toolchain.odin, updater.odin, vendor_path_*.odin
    and the async-STT / setup-hint hooks in main.odin, so the grep is the authoritative list.
  - One "stub" is a real proc rather than a `#force_inline` pass-through: `trace_startup_file` in the `else`
    branch keeps the pre-harness rule (open `os.args[1]` if that path exists).
  - CI verifies the release binary contains no recorder:
    `grep -aq 'doodle-trace 1' bin/doodle` (PowerShell `Select-String ... -SimpleMatch 'doodle-trace 1'` on
    Windows). If found, it fails with `action recording is compiled in`.
- **Rationale**: The comment says "DEBUG-ONLY ... When it's off, every hook below is a pass-through stub, so the
  app behaves (and compiles) exactly as if the harness didn't exist." The workflow says "No action recording in
  releases ... off explicitly, whatever other flags this line gets later." Both the explicit define and the
  grep check arrived in commit d6d998b; earlier releases were already trace-free only implicitly, because
  they were built without `-debug` (so `ODIN_DEBUG`, the default, was false).
- **Source**: src/app/trace.odin (top and the `else` branch); docs/TRACE.md; release-steamos.yml (Build steps).

### 18. Language tables generated from the compiler install

- **Trigger**: A developer runs, by hand, `python tools/gen_core_tree.py [ODIN_ROOT] [OUT_FILE]` and
  `python tools/gen_core_procs.py [ODIN_ROOT]` (`ODIN_ROOT` defaults to `$ODIN_ROOT`, else `C:\Odin`;
  tools/odin_collections.py, which also holds the shared folder rules: `SKIP_DIRS` = tests, examples,
  example, `_gen`; `base:builtin` is not importable; the user's `shared:` collection is listed at runtime
  instead). The tables were last regenerated in commit 7032779 (2026-11-21; core_procs.odin and
  core_tree.odin last changed in 7ed74ee).
- **Behavior**: The scripts scan the `core:`, `base:` and `vendor:` collections of the installed Odin with
  regex-based, comment-stripping line scanners (not a real parser). They emit **committed Odin source tables**
  in `src/model/` with the header `// AUTO-GENERATED by tools/gen_core_procs.py -- do not edit.` (core_tree.odin
  says `// AUTO-GENERATED by tools/gen_core_tree.py -- do not edit by hand.`):

  | File | Table(s) | Rows at baseline | Size |
  |---|---|---|---|
  | core_tree.odin | `CORE_ROWS`, `BASE_ROWS`, `VENDOR_ROWS` (`{depth, label, path, platform, dim}`), `IMPORT_NAMES` | 436 | 24 KB |
  | core_procs.odin | `CORE_PROCS {path, file, block, name, req, variadic, params, ret}` | 74,682 | 9.9 MB |
  | core_types.odin | `CORE_TYPES {path, file, kind, name, target}` | 14,257 | 1.2 MB |
  | core_consts.odin | `CORE_CONSTS {path, file, name, kind}` | 22,563 | 1.5 MB |
  | core_fields.odin | `CORE_FIELDS {path, type_name, name, type, using_field}` | 29,341 | 2.5 MB |
  | core_enums.odin | `CORE_ENUM_MEMBERS {path, type_name, name}` | 48,084 | 2.7 MB |

  (The 436 for core_tree.odin counts all row lines: the three `CoreRow` tables plus `IMPORT_NAMES`.)

  Output is **deterministic**: procedure, type and constant rows are de-duplicated and `sorted(...)`; field
  and enum-member rows are grouped by sorted `(path, type_name)` with each type's members kept in
  declaration order (core_enums.odin says "in declaration order"). Where a name is declared per-OS, "the
  Windows variant wins, else the first one". The procs/types/consts/fields/enums scan is Windows-centric:
  vendor packages that don't build on Windows (darwin/*, android/*, x11, egl, wasm) are excluded from those
  tables but still listed, platform-tagged, in the Import tree. Also excluded: test files, tests/examples
  folders, `package main` folders, `#+private` files, `@(private)` declarations, names starting with `_`,
  and `main`. Runtime-dependent shaping (bucketing, usage-first order, the user's
  `shared:` collection) is done in the model, not baked in. What each column means and how the menus use the
  tables is covered in doc 07.
- **Rules & edge cases**:
  - Generation is **not** part of the build or CI. The tables must match the pinned compiler, which is named in
    two other places that must be kept in step by hand: `ODIN_TAG :: "dev-2026-11" // keep in step with
    .github/workflows/release-steamos.yml` (src/app/setup.odin, the version Settings > Setup installs) and
    `env.ODIN_TAG: dev-2026-11 # keep in step with the Odin you build with locally` (the workflow).
  - Never read the generated files whole (up to 75k lines). Use `grep` or `head`. Lookups go through lazily
    built hash indexes (feature 3).
- **Rationale**: Principle P26 (doc 00), "language knowledge comes from the real toolchain". Shipping the tables
  in the binary makes menus instant and offline.
- **Source**: tools/gen_core_procs.py (module docstring, `write_table`, `main`); tools/gen_core_tree.py;
  tools/odin_collections.py; doc 07.

### 19. Build modes and scripts

- **Trigger**: `build.bat [run [file.odin] | replay [trace] [options] | test | release]` (Windows) or
  `./build.sh [run | replay [trace] [options] | test | release]` (Linux/Deck). There are also Zed tasks.
- **Behavior**:

  | Mode | Command (Windows; Linux is the same with `/` and no `.exe`) | Notes |
  |---|---|---|
  | (none) | `odin build src\app -out:bin\doodle.exe -debug` | debug build; trace on (`ODIN_DEBUG`) |
  | `run [file]` | debug build, then `bin\doodle.exe [file]` | build.sh `run` takes no file |
  | `replay [trace] [opts]` | debug build, then `--replay last` or `--replay %2 ... %9` | build.sh: `--replay "${1:-last}" "${@:2}"` |
  | `test` | `odin test src\model` (stops on failure), then `odin test src\stt` with `bin\` prepended to `PATH` (SDL2.dll) | no debug build |
  | `release` | `odin build src\app -out:bin\doodle.exe -o:speed -no-bounds-check -define:DOODLE_TRACE=false` | no trace |

  build.bat also:
  - prepends `C:\Odin` to `PATH` when `odin` isn't found;
  - copies `SDL2.dll` from `$(odin root)vendor\sdl2\` into `bin\` once (only if `bin\SDL2.dll` is missing,
    in every mode);
  - when the debug build fails and `doodle.exe` is running, prints
    `Doodle is still running - close it so bin\doodle.exe can be rebuilt.`
  - and warns in a comment never to name a variable `ODIN_ROOT` ("reserved by the Odin compiler and overriding
    it breaks `odin build`"; commit dd1a6f0).

  build.sh has none of these: no `PATH` fallback, no SDL copy (Linux uses the system `libSDL2`), and `run`
  takes no file argument. It runs with `set -euo pipefail` and `exec`s the binary for `run`/`replay`.

  `.zed/tasks.json` defines `Doodle: build & run`, `Doodle: build & open current file` (`run $ZED_FILE`),
  `Doodle: run (no build)`, `Doodle: build`, and `Doodle: test`. Four call `build.bat`; `run (no build)`
  starts `bin\doodle.exe` directly. All use Windows paths (`\\`), so they are Windows-only.
- **Rules & edge cases**: Build output (`/bin/`, `*.exe`, `*.pdb`, `*.obj`, `*.o`, `*.a`, `*.lib`, `*.ilk`) and
  `*.bin` (model files) are git-ignored, as are vendored `.dll/.so/.dylib` under `vendor/`, `/third_party/`
  (the whisper.cpp checkout and models from tools/stt/setup_whisper.sh), `bin/_stt_*`, `DoodleProjects/`,
  `test_project_temp/`, `/tmp/`, `/_gen_*.py`, and editor/OS clutter (`.vscode/`, `.idea/`, `.DS_Store`,
  `Thumbs.db`). `tools/__pycache__/` is not ignored and shows up as untracked after running the tools.
  `odin test` without `-out:` leaves its test binary (named after the package folder) behind, ignored by
  `*.exe`; the untracked `src/model.exe` (2026-11-19) is such a leftover: it contains the Odin test
  runner's `ODIN_TEST_*` option strings and model test names. `.gitattributes` forces LF for `*.sh` and `*.yml` "so they run
  on Linux / SteamOS / CI". There are no lint, vet or style flags (`-vet`, `-strict-style` are unused).
- **Source**: build.bat; build.sh; .zed/tasks.json; .gitignore; .gitattributes.

### 20. CI: the manual release matrix

- **Trigger**: `gh workflow run release-steamos.yml -f version=0.1.0 [-f prerelease=true] [-f publish=false]
  [-f run_tests=false]`, or the Actions tab, "Release (SteamOS + Linux + Windows)". It is `workflow_dispatch`
  only. **There is no CI on push or pull request.**
- **Behavior**:
  - Inputs are `version` (blank gives `YYYY.MM.DD-<sha7>`; the tag is `v<version>`), `prerelease` (false),
    `run_tests` (true), and `publish` (true; false keeps packages as run artifacts). Env pins:
    `ODIN_TAG=dev-2026-11`, `WHISPER_TAG=v1.9.5`, `WHISPER_MODEL=base.en`, and `WHISPER_MODEL_SHA256`.
  - `version` job: works out the version once "so the builds can't disagree".
  - **build-steamos**: `runs-on: ubuntu-latest` in container `registry.gitlab.steamos.cloud/steamrt/sniper/sdk:latest`
    (Valve's Steam Linux Runtime 3.0 SDK, "so the binary runs on SteamOS, the Steam Linux runtime, and ordinary
    Linux desktops"). It runs under `shell: bash` because the container's `sh` is dash.
  - **build-linux**: `ubuntu-22.04` (glibc 2.35: Ubuntu 22.04+, Debian 12, Mint 21), the same steps outside the
    container, with `libsdl2-dev`.
  - **build-windows**: `windows-latest`, `pwsh`, no tools step (it uses the runner's preinstalled CMake,
    MSVC and `dumpbin`).
  - Each build job, in order:
    1. Install tools (Linux jobs only: `patchelf curl make cmake git binutils`, plus `clang libsdl2-dev` on
       Ubuntu). It symlinks the newest versioned `clang-N` to `clang` if needed (Odin links through clang).
    2. Install Odin `ODIN_TAG` from the GitHub release archive. On Linux it builds `vendor:stb`'s static libs
       with `build_stb.sh` if they are missing.
    3. Test (if `run_tests`): `odin test src/model`, then `odin test src/stt`; a failure stops the job (bash
       `-e`; explicit `$LASTEXITCODE` checks on Windows). Windows prepends Odin's `vendor\sdl2` to `PATH`
       between the two, because the stt test program needs `SDL2.dll` to start (commit b9d551c: "On the
       Windows runner it exited before printing anything").
    4. Fetch whisper.cpp `WHISPER_TAG` and build `whisper-cli` (cached by tag, platform and flags). The build is
       portable x86-64: `GGML_NATIVE=OFF`, AVX/AVX2/FMA/F16C on, `GGML_AVX512=OFF`, `GGML_OPENMP=OFF`, static
       libs, static libstdc++/libgcc on Linux, and the static MSVC runtime on Windows
       (`-DCMAKE_POLICY_DEFAULT_CMP0091=NEW -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`; commit 69c6b60). The
       model download is cached by name and SHA-256.
    5. **Check whisper-cli**: verify the model's SHA-256 (Windows: `model checksum mismatch: <hash>`). On the
       two Linux jobs only, fail if `objdump -d` shows any `%zmm` register (`whisper-cli uses AVX-512`; "No
       AVX-512 (zmm registers) may sneak in, or it crashes on the Deck"). All three run a **real
       transcription** of whisper.cpp's `samples/jfk.wav` (`-nt -np -t 4`), which must contain
       `ask not what your country` (case-insensitive).
    6. **Build** the release (`-o:speed -no-bounds-check -define:DOODLE_TRACE=false`) and check the binary does
       not contain `doodle-trace 1`.
    7. **Package** as `dist/doodle/{bin/, models/ggml-base.en.bin, assets/, licenses/whisper.cpp-LICENSE,
       VERSION}`:
       - Linux: copy the `libSDL2` that `ldd` resolves and `patchelf --set-rpath '$ORIGIN'`. If that SDL2 is
         sdl2-compat (it references `libSDL3.so.0`), also bundle SDL3 and give the shim an `$ORIGIN` runpath.
       - Windows: `SDL2.dll` from `odin root`.
    8. **Check bundled libraries**:
       - Linux: `LD_DEBUG=libs python3 -c "import ctypes; ctypes.CDLL(...)"`, which must load every SDL library
         from `dist/doodle/bin/`, and `ldd` on the binary must resolve SDL there.
       - Windows: `dumpbin /dependents` on both exes. Every DLL must be in the package, an `api-ms-win-*` API
         set, or in `System32`, and never `vcruntime*`/`msvcp*` ("users may not have it").
    9. **Archive**: write `VERSION` as `<version> (<sha7>, Odin <ODIN_TAG>, whisper.cpp <WHISPER_TAG>
       <WHISPER_MODEL>[, linux-x64 ubuntu-22.04 | , windows-x64])`, then make `doodle-steamos-<v>.tar.gz`,
       `doodle-linux-<v>.tar.gz` or `doodle-windows-<v>.zip`, and upload it as an artifact.
  - **release** job (if `publish`; needs all three builds, `contents: write`): downloads all artifacts and runs
    `gh release create v<version>` with `--title "Doodle v<version>"`, `--generate-notes`,
    `--target $GITHUB_SHA`, optionally `--prerelease`. It attaches each package **plus a
    fixed-name copy** (`doodle-steamos.tar.gz`, `doodle-linux.tar.gz`, `doodle-windows.zip`) so
    `.../releases/latest/download/<name>` always works.
- **Rules & edge cases**:
  - The `VERSION` line is a contract with the self-updater. src/app/updater.odin `install_root` reads
    `<bin>/../VERSION` to know it is an installed release; without it, it's a source build and the Setup row
    says `From source` / `A build from source: update it with git pull, then build.sh / build.bat.`. Which
    package to fetch (`install_asset`): a Windows build always fetches `doodle-windows.zip` (decided at
    compile time, `when ODIN_OS == .Windows`, not from the line); otherwise a line containing `ubuntu`
    fetches `doodle-linux.tar.gz` and anything else `doodle-steamos.tar.gz`. (The file header's "windows" =
    Windows describes the line, but the code never reads that word.) The asset's SHA-256 comes from the
    GitHub release API's `digest` field (`sha256:` prefix stripped).
  - Existing tags at baseline: `v0.1.1`, `v0.2.0`, `v2026.11.21-7b817c1`.
  - CI history shows how these checks were earned: SDL3 bundling for the runtime's sdl2-compat (4430269), the
    static MSVC runtime caught by the DLL check (69c6b60), Linux-path tests failing only on Linux runners
    (3383de7), and a test bad-free failing the Windows job (0c289ea).
- **Source**: .github/workflows/release-steamos.yml; src/app/updater.odin header; README.md ("SteamOS release
  builds").

### 21. Steam Deck install and update packaging

- **Trigger**: On the Deck (Desktop Mode):
  `curl -fsSL https://raw.githubusercontent.com/<owner>/doodle/master/tools/deck_install.sh | bash`, or
  `tools/deck_install.sh [tag]`. Later updates go through Settings > Setup > Doodle.
- **Behavior**: deck_install.sh (`set -euo pipefail`) downloads `releases/latest/download/doodle-steamos.tar.gz`
  (the latest non-prerelease) or `releases/download/<tag>/doodle-steamos.tar.gz` into
  `${DOODLE_DIR:-~/Applications/doodle}`. It checks `doodle/bin/doodle` is executable (else `bad package`),
  **keeps**
  `doodle_keys.tsv`, `doodle_heat.tsv`, `doodle_roots.txt` and `doodle_settings.txt` from the old `bin/`,
  replaces the folder, restores them, and prints `Installed <VERSION> -> <dest>/bin/doodle`. The self-updater
  keeps the same four files (`KEEP_FILES`): on Linux/SteamOS it copies them into the unpacked package before
  renaming the old install aside and the new one into place; on Windows a helper script copies the new files
  over the running install after Doodle closes, and the four files survive because the package doesn't
  contain them. Users add `~/Applications/doodle/bin/doodle` to Steam as a non-Steam
  game, because launching from outside Steam can leave Steam's desktop layout turning the triggers into mouse
  clicks.
- **Rules & edge cases**: Projects default to `~/DoodleProjects`, never the install folder an update replaces (a
  real bug fixed in d6d998b). The runtime toolchain installs (Odin, Zig's clang, stb libs) are doc 09's Setup
  page. They exist because SteamOS has no clang, a read-only root, and Game Mode doesn't read `~/.bashrc`.
- **Source**: tools/deck_install.sh; src/app/updater.odin (`KEEP_FILES`); README.md "Steam Deck: what's
  different". Toolchain setup: doc 09.

### 22. Persistence conventions (pure format + thin store)

- **Trigger**: Any per-user file. Today these are `doodle_keys.tsv` (doc 03), `doodle_heat.tsv` (docs 01/03),
  `doodle_roots.txt` (doc 09) and `doodle_settings.txt` (doc 03/09), all next to the executable
  (`heat_exe_dir`). Project-local files are `<project>/.doodle/run.txt` and `run.log` (doc 09).
- **Behavior**, the same recipe for every file:
  - **Model half**: a header constant `X_HEADER :: "doodle-<kind> 1"`; `x_parse(text)`, which is lenient (blank
    lines, `#` comments and garbage lines are skipped; duplicates resolved first-wins; the keymap is repaired);
    `x_serialize(...)`, which writes the header first; and `x_text_ok(text)`, false when the first non-blank
    line is a *different* `doodle-<kind>` header (a newer format). These are unit-tested (`test_*_round_trip`,
    `test_*_text_ok`, `test_*_parse_*`).
  - **App half** (`src/app/<x>_store.odin`; the settings store lives in src/app/settings.odin):
    `x_store_init` runs **before `trace_start`**, so a replay can override it. A missing file means defaults,
    silently. An unreadable or newer-format file sets `g_x_nosave = true` (never overwritten), and the
    problem is reported once per session on the status line (`x_store_warn`). Exact strings:
    `could not read the key layout (doodle_keys.tsv); using the defaults`,
    `doodle_keys.tsv is from a newer Doodle; using the default buttons`,
    `could not read the project folders list (doodle_roots.txt)`,
    `doodle_roots.txt is from a newer Doodle; extra project folders are off`,
    `could not read the settings (doodle_settings.txt); using the defaults`,
    `doodle_settings.txt is from a newer Doodle; using the default settings`, and on save failures
    `could not save the key layout (doodle_keys.tsv)` / `could not save the settings (doodle_settings.txt)` /
    `could not save menu heat (doodle_heat.tsv)`. Heat differs slightly: an unreadable heat file at startup
    just starts empty (each save re-reads the file and skips with
    `could not read menu heat (doodle_heat.tsv); not saved` while it stays unreadable); only a newer format
    sets `g_heat_nosave` (`doodle_heat.tsv is from a newer Doodle; menu heat not saved`). In all four
    stores a read that fails (other than "file doesn't exist") is retried once after 50 ms ("another Doodle
    may be renaming it right now"). Failures never stop the editor.
  - Keys, roots and settings: `x_store_save` returns early unless `trace_write_ok(path)`, then writes
    `<file>.tmp` and renames it over the file. `x_store_override(...)` pins a recording's value and stops
    saving; `x_store_text()` gives the meta for a recording. Heat has neither: it isn't recorded in the
    meta, and a replay just sets `g_heat_nosave`.
  - Keys, roots and settings save right after each change. Heat saves at most every 2 s and at quit, re-reading
    the file and merging this session's pending counts, then writing `<file>.tmp` and renaming it over the
    file, so two Doodles don't erase each other.
  - File identifiers are stable strings: "never renamed once shipped" (`ACTION_INFO.key`). The enum order is
    internal ("reordering the enum never breaks a file"). Settings lines this version doesn't know are kept and
    written back. An old keys file picks up a new action's default slot.
- **Rules & edge cases**: `run.txt` has no versioned header and is the exception. Details of each format are in
  docs 00 (P19) and 03.
- **Source**: src/model/keymap.odin (`KEYS_HEADER`, `keys_text_ok`, `keymap_serialize`, `keymap_parse`),
  settings.odin, project_roots.odin, heat.odin; src/app/keys_store.odin, roots_store.odin, heat_store.odin,
  settings.odin (headers).

### 23. Platform-specific code

- **Trigger**: Code that differs between Windows and Linux/SteamOS.
- **Behavior**: There are file pairs: `pid_windows.odin` / `pid_other.odin`, `trash_windows.odin` /
  `trash_other.odin`, `vendor_path_windows.odin` / `vendor_path_other.odin`. The `_other` files start with
  `#+build !windows`; the `_windows` files are selected by Odin's file-name suffix rule (only
  `pid_windows.odin` also has an explicit `#+build windows`). Smaller differences use `when ODIN_OS ==
  .Windows` inline (38 sites in src/app, 2 in non-test model code, 4 in src/stt). The model mostly takes the
  OS as data (`App.os_name`, set from `os_name()` in main.odin: `"windows"`, `"linux"`, `"darwin"` or `""`;
  menu entries with a comma-separated `platform` tag are shown only when it matches, `platform_ok`). Unit
  tests of OS-sensitive model logic cover both OSes' rules (`when ODIN_OS` in the test, commit 3383de7).
  Pure app-side helpers are tested in `src/app/shell_test.odin` (12 tests: `test_sh_quote`,
  `test_run_script_text`, `test_run_script_clang_dir`, `test_toolchain_script`,
  `test_toolchain_script_builds_stb`, `test_stb_build_command`, `test_sha256_file`, `test_setup_items`,
  `test_update_version_and_asset`, `test_update_new_root_in`, `test_update_swap_in`,
  `test_update_windows_script`).
- **Source**: the files named; src/model/project_roots.odin `roots_same`; src/app/shell_test.odin.

### 24. Source, comment and doc conventions

- **Trigger**: Every new file, feature and commit.
- **Behavior**:
  - **File headers**: every source file opens with a comment block that explains the feature *from the user's
    side*. It uses the buttons that act on it, small ASCII before/after examples with `●` for dots, and
    cross-references in parentheses (`(grab.odin)`, `(app/keys_page.odin)`). Example: dictation.odin begins
    "Push-to-talk (LT+X): what the highlighted part takes, and how the words are read", followed by a table of
    targets. Comments explain *why*, often quoting the compiler error a rule avoids. Pure halves say so: "This is
    the pure part: the options, their labels and the file format".
  - **Docs**: docs/EDITOR_MODEL.md is the main feature doc. README.md holds user-facing install notes, the Deck
    differences table and release usage. docs/TRACE.md, docs/STT.md and docs/INSTALL.md are tool docs.
    docs/UX.md, ARCHITECTURE.md §3 to §8 and MULTI_AGENT.md are historical. The voice is plain second person,
    short sentences, user-visible behavior first, and exact button names.
  - **Commits**: the subject uses a conventional-commit type with an optional scope. Seen at baseline:
    `feat:` (14), `ci:` (6), `feat(editor)` (3), `feat(run)`, `feat(menus)`, `docs:`, `ci(windows)` (2 each),
    `test(roots)`, `test(decl-value)`, `fix(menus)`, `fix(loader)`, `feat(stt)`, `feat(setup)`,
    `feat(settings)`, `feat(projects)`, `feat(input)`, `feat(filenav)`, `feat(runnable)` (42 of the 91
    subjects). The subject says what
    the user gets ("RT+X grabs code to move it; RT walks start at the cursor line"). The body has plain
    sentences or `-` bullets describing behavior (controls, edge cases, refusals), then technical notes ("Trace
    modes record 'grab'. Grab / drop is in the Key Layout picker (now 21 actions)"). The last line is a
    `Co-Authored-By:` trailer (every commit from 2d27703 on, except the hand-written `Update readme`). On the
    first two days (2026-11-17/18) free-form subjects ("Implement ...", "Merge feat/x + feat/y: ... 111 model
    tests") and conventional ones were mixed; from 2026-11-20 on every subject is conventional except
    `Update readme` (2830135).
  - **Branching**: early work (2026-11-17/18) used parallel feature branches merged to `master`
    (`feat/branch-loop`, `feat/jump-err-scope`, `feat/select`, `feat/calls`, `feat/parse`, `feat/dot-color`,
    `feat/typed-calls-editor`, ...). The integration-and-review pattern (a cross-feature integration test file,
    then a review whose findings became named regression tests, features 5 and 8) is described by the test
    file headers ("after the four-feature merge", "after merging the gen / types / ctrl / fields builders"),
    but those merges are not in git: integration_test.odin, branch_loop_integration_test.odin,
    review_fixes_test.odin, integrate_fixes_test.odin, branch_loop_fixes_test.odin and the exact-build test all
    arrived in one bulk commit, 7ed74ee ("Commits the accumulated local work"). Later work is direct commits
    on `master`.
- **Source**: file headers throughout src/model and src/app; `git log`; docs/.

### 25. How a feature lands (the recipe the history shows)

- **Trigger**: Adding a user-visible feature. Commit cee37be ("RT+X grabs code to move it") is the template.
- **Behavior**: The files touched, in that commit and its peers:
  1. **A new model file** with a user-facing header (`src/model/grab.odin`, 313 lines), plus new `App` fields
     with ownership comments, and dispatch in `update` (`if grab_update(app, inp, keys) do return`).
  2. **The keymap**, if it needs a button: a new `Action` *appended* to the enum, an `ACTION_INFO` entry with a
     never-renamed `key`, label, glyph and hint, a slot in `KEYMAP_DEFAULT`, and the Key Layout picker
     (`KEYS_PICK` in keys_page.odin, now 22 actions). Then `keymap_test.odin` and old-file compatibility
     (`test_keymap_old_save_as_layout`, from the peer commit 4289c7d: an old file with `rt y save_as` keeps
     Save as there and Save gets another button, "so old recordings, which pin their layout, replay the
     same").
  3. **Tests**: a new `<feature>_test.odin` (grab_test.odin, 234 lines) driven by presses, plus adjustments to
     neighbors (tree_start_test.odin).
  4. **The app**: drawing in `editor_view.odin` (the orange box, the top hint strip), plus any `requests`
     handling.
  5. **The trace**: a new mode in `screen_ctx` (cee37be added the one line for `grab`; `grab_copy` came with
     the Refactor menu in d6d998b), new state in `fingerprint` when the feature adds replayable state (with
     the "only while open" guard for app overlays; cee37be did *not* do this, see feature 12), and
     `trace_write_ok` / `trace_replaying` guards on any new write or outside effect (marked `TRACE hook`).
     trace.odin changed in 6 of the 14 `feat` commits after the one that added it (7ed74ee).
  6. **Docs**: a section in docs/EDITOR_MODEL.md and, for bindings, `BINDINGS` in tools/trace.py; README for
     user-facing setup. **In practice these lag.** EDITOR_MODEL.md changed in only 4 commits, and `BINDINGS`
     last changed in f544db5. For most features the commit body and the file header are the real spec.
  7. **Verify**: `build.bat test` (no leak warnings), `tools/trace.py script ... --shot` for a screenshot of the
     new UI, `tools/trace.py verify all` to check old recordings still replay, and then the commit. (This is
     the loop the tools are built for; the history only records test counts in some commit bodies, such as
     "Tests: 191 model + 6 stt, no leaks.", and d6d998b's "Trace replays stay compatible.", not which of these
     steps ran.)
- **Source**: `git show --stat cee37be 4289c7d df22753 f544db5`.

## Invariants & constraints to carry forward

(Where a rule is HARD, the evidence is named: a test that pins it, code that enforces it, or, where nothing
machine-checks it, "convention" so the Rust version knows to add the check.)

1. **HARD**: The model package has no window, GPU, font or audio dependency, and the whole editor can be driven by
   `update(&app, Input{...})` in a test. All 594 model tests run without a window, in about 10 s. (Evidence: the
   model's import list, and `odin test src/model` running headless in CI.)
2. **HARD**: `Input` is a small, device-independent value of per-frame edges plus trigger-hold levels. Devices
   (pad, keyboard stand-ins, auto-repeat) are translated *before* the model. (Code: `model.Input` has ten bools;
   `build_input`; `dpad_repeat_tick` pinned by `test_dpad_repeat`.)
3. **HARD**: The model never writes files, never reads the clock, and never uses randomness. Time and random values
   come in as parameters or recorded strings. It may read files and the `ODIN_ROOT`/`PATH` environment.
   (Convention, verified by grep at baseline; nothing machine-checks it.)
4. **HARD**: Effects the model can't perform are returned as data (`App.requests` bit set, `App.notice`) and
   performed by the app right after `update`. At most one overlay opens per frame. (Code: `keymap_run`,
   `app_requests`' `switch`; `test_keymap_update_requests`.)
5. **HARD**: When an app overlay is open it owns the input, and the editor model is not updated that frame.
   (Code: the `if/else if` routing chain in main.odin.)
6. **HARD** (convention): No global state that changes during a run in the model. Services are nullable pointers
   with defaults (`keymap`, `heat`). The OS is data (`os_name`). I/O seams are function parameters
   (`Fgrid_Lister`). Shared caches are immutable, built once. The single exception at baseline is the
   `@(thread_local)` scratch map `decl_type_names` (data_types.odin); thread-local is the minimum for a
   parallel test runner.
7. **SOFT** (in Doodle; make it HARD in Rust): Every test frees what it allocates (the cleanup helper).
   Ownership of every heap field is documented at the field. The bar is "no leak warnings", but Odin's runner
   only *warns* on leaks and bad frees by default and nothing passes `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`, so
   the bar is kept by reading the output.
8. **HARD**: The north-star program is built from an empty project with controller-equivalent input only. Cursor
   moves are d-pad presses and menu picks are d-pad paths plus A. The saved file must equal the target byte for
   byte, reload unchanged, and pass the real compiler check when available. (Pinned by
   `test_handmade_exact_build`.)
9. **HARD**: Load then save is byte-exact (including the final-newline state), and formatting a formatted file is a
   no-op. (Pinned for the corpus by `test_handmade_exact_load_round_trip`, `test_integration_combo_round_trip`,
   `test_accept_every_example_round_trip`, `test_accept_one_liners_round_trip`; not proven for arbitrary
   files.)
10. **HARD** (design rule; checked only by `verify`): Nothing in the editor changes without input. A replay needs
    only the recorded events, the recorded strings (STT text, random names), the snapshot, and one settle frame
    after each recorded frame. Known exceptions are kept out of the fingerprint or recorded: background
    `odin check` diagnostics, STT results (recorded), and the Setup/updater status threads (not run in a
    replay).
11. **SOFT** (aspiration; not complete at baseline): The fingerprint covers the replayable state input can
    change, and excludes nondeterministic background results and absolute paths. Grab, word-by-word mode,
    `slot_menu` and `g_stt_busy` are not hashed (feature 12).
12. **SOFT**: New features keep old recordings replaying with identical fingerprints. New state is hashed only
    while its feature is open, and changed flows are gated on the absence of a meta key.
13. **HARD** (code: `trace_write_ok`, `trace_replaying` guards): Until takeover, a replay doesn't run programs,
    use the clipboard, play sounds, use the Recycle Bin, run Setup installs or the updater, or edit `PATH`.
    During the whole replay session, including after takeover, every guarded file write (saves, new files,
    renames, `run.txt`, new project folders, the per-user files) stays inside the sandbox, and the heatmap and
    per-user files are never saved. After takeover the `trace_replaying()` guards lift, so Setup installs, the
    updater, the PATH edit and the Recycle Bin can act on the real machine again, and the background checker
    writes `<temp>/doodle_check/` throughout. (docs/TRACE.md's "can never change a real file, even after you
    take over" overstates this.)
14. **HARD**: The harness is compiled out of release builds, and CI fails if the recorder's format string is in the
    release binary. (Code: `TRACE :: #config(DOODLE_TRACE, ODIN_DEBUG)`; the CI Build step's grep, which only
    runs when someone cuts a release.)
15. **SOFT**: Each trace hook is marked `// TRACE hook` so the harness can be found and removed mechanically;
    the full `(was: ...)` form, which says what to put back, is used on only 13 of the 39 sites.
16. **SOFT**: Language tables are generated from the pinned compiler install, deterministic, committed, and marked
    "do not edit". The pinned version is named in the workflow, in Setup, and implicitly in the tables.
17. **HARD**: Release packages are self-contained (runtime libs bundled with `$ORIGIN` / next to the exe, no VC++
    runtime, whisper-cli plus model) and checked by CI for load paths (Linux `LD_DEBUG`/`ldd`, Windows
    `dumpbin /dependents`), CPU features (no AVX-512 `%zmm`, Linux jobs only) and a real transcription (all
    three jobs).
18. **HARD**: Per-user files have a versioned header, lenient parsing, stable string keys, and are never
    overwritten when unreadable or newer. They survive reinstalls and self-updates. (Pinned by
    `test_keymap_round_trip`, `test_keymap_parse_repairs`, `test_keymap_old_save_as_layout`,
    `test_settings_text_ok`, `test_roots_text_ok`, `test_heat_merge_with_file`; enforced by the stores'
    `g_*_nosave` flags, deck_install.sh and `KEEP_FILES`. `run.txt` is the exception: no header.)
19. **SOFT**: Conventional commits with scopes; behavior-first bodies; a `Co-Authored-By` trailer; file headers
    written from the user's side.
20. **SOFT**: Tests that need external tools (compiler, whisper, the Odin library sources) skip when the tool
    isn't configured (silently, except `check_with_odin`'s `odin check skipped (no DOODLE_ODIN)` warning), and
    serialize their compiler runs with a file-level `check_mutex` (the four `odin_check` copies;
    `check_with_odin` has none, and its two tests may run `odin check` concurrently).
21. **SOFT**: Performance-critical interactions get a timing test (opening a heavily-typed dot in under 300 ms).

## Data model & formats

**`model.Input`** (src/model/model.odin): `confirm, cancel, up, down, left, right, x, y` are edges;
`lt_held, rt_held` are levels.

**Effect channels on `App`**: `requests: bit_set[Action]` (`Docs, Copy, Save, Save_As, Run_List, Files,
Run_Favorite, Run_Tests, Prev_File, Key_Layout`), cleared by the app; `notice: string` (static text), cleared by
the app.

**Trace folder** `bin/traces/<YYYYMMDD-HHMMSSZ>[-k]/`:
- `input.log` (replay input)
- `events.jsonl` (analysis)
- `snapshot/projects/...`, `snapshot/roots/<i>/...`, `snapshot/extra/...`

Sandboxes: `bin/traces/_replay/` (with `projects/`, `roots/<i>`, `extra/`, and a `.takeover` marker after a
takeover) and `bin/traces/_replay.prev/`. Fixtures: `bin/traces/script-<name>/`.

**`input.log` grammar**:
```
doodle-trace 1
meta <key> <one-token value>          # start_unix cwd projects start_file start_rel stt snapshot_ok keymap roots settings arg derived_from derived_until
<frame> t <seconds since start, %.4f> # first line of each written frame
<frame> btn <Button> <0|1>            # platform.Button names: A B X Y Up Down Left Right LB RB Start Back LStick RStick Guide
<frame> axis <LTrigger|RTrigger> <f32> # only when a trigger crosses 0.5
<frame> key <SDL keycode> <0|1>
<frame> size <w> <h>
<frame> quit
<frame> str <stt|project_name> <one-token text>
<frame> fp <16 hex digits>            # state fingerprint after the frame
end <frame>                           # clean exit
```
One-token escaping: `\s` space, `\t`, `\n`, `\r`, `\\` (any other `\x` unescapes to `x`). An empty meta value
is written by the recorder as `meta <key> ` (trailing space; `meta roots ` = "no extra folders") and by
`trace.py script` as `meta roots` with no value; both read back as `""`, while a *missing* key means "recorded
before this existed" (feature 12). Every meta key is
written once except `arg`; a takeover trace re-states `derived_*` instead of copying the source's. docs/TRACE.md
says that if a key appears twice the last one wins, which is what tools/trace.py does (a dict), but the
replayer's `rp_meta` returns the **first** match. The parser skips blank lines, `end` lines, lines whose first
token isn't an integer, and unknown kinds; a file whose first line isn't exactly `doodle-trace 1` is refused.
Lines for the same frame number are grouped into one `Rec_Frame`.

**`events.jsonl` records** (one JSON object per line, field `k`):
- `meta` (first line): `format` (`"doodle-trace 1"`), `start_unix`, `args`, `cwd`, `projects`, `start_file`,
  `stt`, `snapshot_ok`, `snapshot_ms`, `derived_from`, `derived_until`.
- `act`: `f` (frame), `t`, `press` (`[{b, mods, rep}]`), `pre`, `post`, `edit`.
  - `b` is one of `pad:<Button>` (any `platform.Button` name, `pad:A` ... `pad:RB`, `pad:Start`, ...),
    `pad:X-up`, `key:<name>` (`Return Space Backspace Escape Up Down Left Right Ctrl F5 F6 F7`, the character
    itself for codes 33..126, else `0x<hex>`), `key:x-up`, `LT`, `RT`, `LT-up`, `RT-up`.
  - `mods` is `""`, `LT`, `RT` or `LT+RT`.
  - `rep` marks keyboard auto-repeat (omitted when false).
- `list`: `f`, `t`, `scr`, `title`, `trail`, `items`, `recent`, `idx`.
- `mark`: `f`, `t`, `what` (`stt`, `project_name`, `takeover`, `diverged`, `end`) and `text` (`takeover`'s
  text is `<source stamp>@<frame>`, `diverged`'s the frame number).

What `items` holds per screen (`screen_items`): menu entry labels (`recent` = the size of the
recently-used section); file-nav names with `/` after folders (the filtered list while searching); on Key
Layout, every slot as `LT+A: Edit` (or the picker's action labels while picking); project names; New
Project's `In default folder`, `In <folder>` per root, `+ Add another folder` (or the browser's folders and
`Use this folder`); run commands plus `+ New command` (or the templates); the stb / vendor prompt choices;
Settings rows as `<label>: On|Off`; the main menu items. The save dialog and the docs panel have no list.

`pre`/`post` context fields: `scr`, `mode`, `title`, `trail`, `sel`, `idx`, `n`, `line`, `field`, `dot`, `leaf`,
`kind`, `file`, `nodes`. Values emitted by `screen_ctx` at baseline (the code has more than docs/TRACE.md lists):
- `scr`: `main_menu`, `editor`, `menu`, `save_dialog`, `rename`, `filenav`, `filenav_search`, `filenav_delete`,
  `key_layout`, `stb_build`, `vendor_path`, `settings`, `projects`, `new_project`, `new_project_folder`, `docs`,
  `run`, `run_templates`.
- `mode` (comma list): `ref_pick`, `ref_pass`, `mod_pick`, `rename_prompt`, `replace`, `refill`, `change_call`,
  `body_insert`, `decl_form`, `slot`, `ctrl:<Ctrl_Menu>`, `tree_sticky`, `grab`, `grab_copy`, `words`,
  `dictating`, `transcribing`, `overwrite_prompt`, `picker`, `reset_prompt`, `remove_prompt`.

**Replay result line** (stderr): `trace: RESULT <matched|diverged@N|incomplete> frames=<recorded frames> reached=<frame>`.

**Trace constants**: `TRACE_KEEP 40`, `TRACE_FILE_MAX 4 MiB`, `TRACE_SNAP_BUDGET 32 MiB`, `TRACE_SNAP_FILES 4000`,
`TRACE_REPLAY_DIR "_replay"`. Replay control keys: F5 `0x4000003E`, F6 `0x4000003F`, F7 `0x40000040`.

**Fingerprint**: FNV-1a 64 as in feature 12.

**Environment variables**:

| Variable | Used by | Meaning |
|---|---|---|
| `DOODLE_TRACE` | app (runtime) | `0`/`off`/`false` = don't record this run |
| `-define:DOODLE_TRACE=` | compiler | force the harness in or out (default `ODIN_DEBUG`) |
| `DOODLE_ODIN` | tests | path to `odin` for `odin check` in acceptance tests |
| `DOODLE_CHECK_DIR` | tests | where acceptance programs are written |
| `ODIN_ROOT` | tools/gen_*.py; also the model's `odin_root` and the app's Odin search | Odin install to scan (generators default to `C:\Odin`); at runtime, the first place to look for Odin's library sources |
| `ODIN_DIR` | app (Linux Odin search, README) | another place to look for an Odin install |
| `DOODLE_TERMINAL`, `TERMINAL` | app (run) | terminal for Run on Linux (doc 09) |
| `DOODLE_DIR` | deck_install.sh | install folder (default `~/Applications/doodle`) |

**Per-user files** (next to the binary): `doodle_keys.tsv` (`doodle-keys 1`), `doodle_heat.tsv`
(`doodle-heat 1`), `doodle_roots.txt` (`doodle-roots 1`), `doodle_settings.txt` (`doodle-settings 1`).

**Release**: `VERSION` line format (feature 20); package layout
`doodle/{bin/, models/ggml-base.en.bin, assets/{fonts,icons,sounds,stt}, licenses/, VERSION}`; asset names
`doodle-{steamos,linux}-<v>.tar.gz`, `doodle-windows-<v>.zip`, plus the fixed-name copies.

**Asset pipeline**: tools/convert_sounds.py converts WAV/AIFF to mono 16-bit 44.1 kHz WAV, peak-normalized to 0.89
(about -1 dB), stdlib only. Icons are committed as SVG plus 64 and 512 px PNGs. The DejaVu Sans Mono font ships
with its license. The Python tools are stdlib-only; tools/trace.py is documented to run as `python -I` (isolated
mode), the generators as plain `python`.

## Tests that pin this behavior

| Test | File | What it asserts |
|---|---|---|
| `test_add_package_inserts_text` | model_test.odin | A, A, A from an empty editor gives `package main`, `state == .Editor`, empty menu stack |
| `test_ide_menu_exit`, `test_ide_menu_cancel_returns` | model_test.odin | combos as `Input{left, lt_held}`; B restores the state with no menu left |
| `test_handmade_exact_build` | handmade_exact_build_test.odin | the whole program from New Project with d-pad-exact input; byte-exact save; reload/resave stable; `odin check` when available |
| `test_handmade_exact_load_round_trip` | handmade_exact_build_test.odin | verbatim load/save, format no-op, no-final-newline preserved, `odin check` |
| `test_handmade_accept_file_scope`, `..._build_program`, `..._load_verbatim`, `..._load_formatted` | handmade_acceptance_test.odin | menu-built program equals the target (with graying checks on the way); loader symmetry |
| `test_accept_loop_*`, `test_accept_br_*`, `test_accept_every_example_round_trip` | branch_loop_acceptance_test.odin | one controller-driven test per table row plus `odin check`; corpus round trip |
| `test_integration_combo_round_trip` | integration_test.odin | multi-feature file round-trips and keeps field kinds; the oracle reads it |
| `test_review_struct_literal_graying_is_fast` | review_fixes_test.odin | opening a typed dot takes under 300 ms with big imports |
| `test_layout_handmade_from_empty_project` | stmt_layout_test.odin | the full file built from an empty project |
| `test_keymap_round_trip`, `test_keymap_parse_repairs`, `test_keymap_old_save_as_layout` | keymap_test.odin | persistence format, repair, old files gaining new actions |
| `test_settings_parse_keeps_unknown_and_defaults`, `test_settings_text_ok` | settings_test.odin | unknown lines kept; newer headers refused |
| `test_roots_text_ok`, `test_roots_add`, `test_roots_parse_skips_header_comments_blanks_and_repeats` | project_roots_test.odin | format rules, with per-OS path rules |
| `test_heat_merge_with_file`, `test_heat_nil_is_noop` | heat_test.odin | merge-on-save; nil service is a no-op |
| `test_fgrid_*` (19) | file_grid_test.odin | the file-nav grid through an injected `fake_list`, no disk |
| `test_dpad_repeat` | src/platform/platform_test.odin | repeat delay and rate (about 14/s), off while dictating |
| `test_async_transcribes_in_order` | src/stt/stt_test.odin | background STT order; skipped without whisper |
| `test_sh_quote`, `test_run_script_text`, `test_run_script_clang_dir`, `test_update_version_and_asset`, ... (12) | src/app/shell_test.odin | app-side pure helpers: shell quoting, run and toolchain scripts, stb build command, SHA-256, Setup rows, updater parsing/swap/Windows script (not run by the scripts or CI) |
| `test_keymap_update_requests` | keymap_test.odin | disk/clipboard/overlay actions land in `App.requests` instead of happening in the model |
| `test_doc_lookup_odin_install` | docs_test.odin | docs lookup against the real Odin install (skipped without one) |
| `tools/trace.py verify all` | (tool) | every kept recording replays with matching fingerprints |
| CI "Build" grep, "Check whisper-cli", "Check bundled libraries / DLLs" | release-steamos.yml | no recorder in release; no AVX-512; real transcription; self-contained packages |

## Carrying this to Rust

### (a) What transfers unchanged

- The split: a pure editor core driven by an abstract `Input` value, an `update(&mut App, Input)` step, effects
  returned as data (`requests`, `notice`), and a thin shell for devices, drawing and I/O. Overlays own their
  input exclusively.
- Determinism: no clock or randomness in the core, auto-repeat synthesized as events, nondeterministic values
  recorded as strings, and one settle frame after each recorded frame.
- The test pyramid: press-driven unit tests with label-based `pick` helpers; round-trip and corpus tests; a
  north-star acceptance test that builds a real program from an empty project with d-pad-exact input (BFS for
  menu paths, cursor walks that fail when a target isn't a stop) and then compiles it; one regression test per
  review finding; timing tests for heavy menus.
- The whole trace harness design: record (input log, semantic events, snapshot with hard links and budgets),
  sandboxed replay with pause/step/takeover, self-contained derived traces, fingerprints with
  backward-compatible mixing, `verify`, the analysis report with mistake signals, scripted fixtures with
  screenshots, compiled out of release with a CI check, and removable hooks.
- Generated language tables from the pinned toolchain; a version pin repeated in CI and in the Setup page.
- The release matrix (SteamOS sniper SDK, Ubuntu 22.04, Windows), self-contained packages, load-path, CPU-feature
  and real-transcription checks, fixed-name assets, a `VERSION` contract with the updater, and a Deck installer
  that keeps the user's files.
- Persistence conventions, commit conventions, file-header voice.

### (b) Odin-specific pieces and their Rust analogs

| Doodle (Odin) | Rust |
|---|---|
| `package` = folder; `src/model` / `src/app` | Cargo workspace: `crates/model` (lib), `crates/app` (bin), more below |
| `@(test)` procs in `*_test.odin`, `odin test src/model` | `#[cfg(test)] mod tests` for unit tests, `crates/model/tests/*.rs` for acceptance; `cargo test -p doodle-model`; `cargo nextest` for speed and per-test isolation |
| `testing.expect_value(t, got, want)` + `loc := #caller_location` | `assert_eq!`; `#[track_caller]` on helpers |
| `@(private = "file")` helper copies per test file | a `tests/common/mod.rs` (or a `doodle-testkit` crate) with `Pad`, `pick`, `pick_leaf`, `dpad_to`, `menu_go`, `back_out`, `labels` |
| tracking allocator, `cleanup`, ownership comments | ownership and `Drop` remove leaks and double frees; still forbid `Box::leak`/`mem::forget` in the core (clippy `mem_forget`), avoid `Rc` cycles, and optionally assert heap stability over N updates with `dhat` in a test |
| `context.temp_allocator` + `free_all` per frame | a per-frame `bumpalo::Bump` reset each frame, or plain owned values (`String`, `Vec`) |
| `sync.Once` + `runtime.heap_allocator()` caches | `std::sync::LazyLock` / `OnceLock` over immutable data |
| nullable `^Keymap` / `^Heat` services | an owned field with a `Default` (`keymap: Keymap`, default = `KEYMAP_DEFAULT`), or `Option<Arc<Keymap>>` read through a `keymap()` accessor that falls back to a `static` default; for heat, `Option<Box<dyn HeatSink>>` (or a `NoHeat` impl). Avoid `Option<&Keymap>` inside `App`: it forces a lifetime parameter on the whole core |
| `Fgrid_Lister :: #type proc(...)` | `trait DirLister` (or `impl Fn(&Path) -> io::Result<Vec<Entry>>`) passed in |
| `when TRACE {...} else {stubs}`, `#config(DOODLE_TRACE, ODIN_DEBUG)` | the closest analog of "default = debug build, overridable" is `#[cfg(any(debug_assertions, feature = "trace"))] mod trace;` plus a `#[cfg(not(any(...)))]` stub module with identical `#[inline(always)]` fns. Cargo features can't key off the profile, but `debug_assertions` does (on in `dev`, off in `release`). To force it *off* in a debug build add a `no-trace` feature to the condition; release CI should still build `--release` without `trace` and grep the binary |
| `#+build windows` / `_other.odin` pairs, `when ODIN_OS` | `#[cfg(windows)]` / `#[cfg(not(windows))]` modules; `cfg!(windows)` inline; keep the OS as data in the core |
| `-define:X=v` | features, or `RUSTFLAGS="--cfg x"` (declare custom cfgs under `[lints.rust] unexpected_cfgs = { level = "warn", check-cfg = ['cfg(x)'] }`, or rustc warns since 1.80), or `option_env!("X")` for build-time strings |
| `os.process_exec({odin, "check", dir})` in tests | `std::process::Command::new("cargo").args(["check", "--message-format=json"])` in a temp crate |
| `core:encoding/json` marshal | `serde` + `serde_json` derives on the trace record structs |
| FNV in trace.odin | the same hand-written FNV-1a 64 (10 lines: per byte `h ^= b as u64; h = h.wrapping_mul(0x100000001b3)`; a string is its bytes followed by one `0xff` byte; an int is `(v as u64).to_le_bytes()` with no separator). **Not** `DefaultHasher` (its algorithm is unspecified and may change across Rust releases), not `#[derive(Hash)]` fed into a hasher (the std `Hash` impls add length prefixes and use native-endian `write_usize`), and never hash `HashMap` iteration order |
| python `tools/trace.py` (stdlib) | keep it, or port to `cargo xtask trace` sharing the serde structs with the recorder so formats can't drift |
| python generators writing `.odin` tables | `cargo xtask gen-std` writing compact data (see d); `build.rs` only if it needs no network or nightly |
| build.bat / build.sh modes | `cargo run`, `cargo run -- --replay last`, `cargo test --workspace`, `cargo xtask dist`; a `justfile` if you want one-word modes |
| SDL2.dll copy from `odin root` | the `sdl2` crate with `bundled` (+`static-link`), or ship the DLL/.so from the build |
| `patchelf --set-rpath '$ORIGIN'` | `-C link-arg=-Wl,-rpath,$ORIGIN` in `.cargo/config.toml`, or keep patchelf in CI |
| static MSVC runtime check | `-C target-feature=+crt-static` for the Windows target; keep the `dumpbin /dependents` check |

### (c) Rust concepts this area needs that Odin lacks, and how the practice extends

- **Traits** become the seams: `Fs` (read-only for the core), `DirLister`, `Clock` (only for the app), and
  `Oracle` (type and scope queries, doc 06/07). Tests implement fakes. Keep the rule "the core never writes":
  the `Fs` trait offers reads only.
- **Ownership and lifetimes**: the editor core owns the `Document`. Test helpers take `&mut App`. The `Pad`
  driver holds `&mut App` and a press counter. Ownership replaces most of Doodle's leak discipline, but keep the
  documentation habit: say which struct owns derived data (hints, caches) so derived state is rebuilt, not
  shared.
- **Pattern matching and enums**: model `Input` as a struct of bools (as Doodle does) rather than an enum of
  events. A frame can carry several edges plus held triggers, and tests write
  `Input { left: true, lt_held: true, ..Default::default() }`. Derive `Default, Clone, Copy, Debug, PartialEq`.
- **Macros**: a small `pad!` macro (`pad!(app; A, Down, "Calls", LT+B)`) is a fair way to write long
  acceptance scripts. Keep helper fns for anything with logic (BFS paths, cursor walks).
- **Async**: keep the core synchronous. rust-analyzer, `cargo check` and whisper run on threads or async tasks in
  the app. Their results enter the core as **recorded inputs**, the way Doodle records STT text, or are kept
  out of the fingerprint the way Doodle treats `odin check` results. This is the main determinism risk in the
  Rust version, because the type oracle is a live analysis server. Either compute menus from a fixed snapshot
  synchronously, or record oracle answers per frame in the trace (doc 00 already recommends this).
- **Derives and serde** make the trace formats, persisted files and snapshots cheap. Version them with the same
  `doodle-<kind> N` header line so old and new builds can refuse each other's files.
- **Visibility and modules**: the core's test seams (`focus_dot_at`, `cursor_stop_key`, ...) are needed by
  integration tests in `crates/model/tests/` and by a separate `testkit` crate, and both compile as *other*
  crates: `pub(crate)` items and `#[cfg(test)]` items are invisible to them (`cfg(test)` is only set when
  compiling the crate's own unit tests). So expose the seams as `pub` behind a `testkit` feature
  (`#[cfg(feature = "testkit")]`), enabled from `[dev-dependencies]`, and keep `pub(crate)` for everything
  else.

### (d) Implementation advice

**Workspace layout (recommended):**
```
doodle-rs/
  Cargo.toml              [workspace]; rust-toolchain.toml pins the compiler (also used by Setup)
  crates/
    model/      pure core: App, Input, update(), Document, menus, keymap, file formats; no SDL/GL/fs writes
    lang/       syntax + type oracle: ra_ap_syntax or tree-sitter-rust; rust-analyzer bridge; std tables
    platform/   SDL2 window/events/audio/clipboard; d-pad repeat as events
    render/     GL 3.3 (glow) quad batcher + glyph atlas (fontdue / ab_glyph)
    stt/        whisper-cli subprocess (or whisper-rs)
    app/        bin: main loop, overlays, stores, runner, updater, trace (feature "trace")
    testkit/    Pad driver, pick/pick_leaf/menu_go/dpad_to, fixtures loader (dev-dependency)
  xtask/        gen-std | trace {list,report,find,show,verify,script} | dist
```
Doodle keeps app overlays (file nav, run list, settings page, ...) as `g_*` globals in the app, which is why
`verify` needs a window. In the Rust version, **put overlay state and its input handling in a SDL-free crate**
(in `model`, or an `app-core` crate). Then `verify` can replay `input.log` headlessly inside `cargo test`
against committed fixture recordings, and replays become a real CI regression suite instead of a local one.

**Testing:**
- Port the helper set and the `Pad` driver first, then write the north-star acceptance test early: an empty
  project to a real Rust program (for example a small SDL or winit window), d-pad-exact. Assert the saved file
  byte-exact, then run `cargo check --message-format=json` on it in a temp crate. Serialize those runs with a
  `static CHECK: Mutex<()>` and share a `CARGO_TARGET_DIR` so they stay fast. Unlike Doodle, **run them in CI**
  (a Rust CI runner always has cargo). Gate locally with `#[ignore]` + `cargo test -- --ignored` or an env var if
  they're slow.
- `insta` snapshots for broad coverage: saved source after scripted builds, menu label lists at a dot
  (`labels()`), the `screen_ctx` of key screens. Keep literal expected strings for the north-star programs.
- `proptest` for properties Doodle only checks by example: load(save(doc)) == doc and save(load(src)) == src over
  a corpus of real `.rs` files plus mutations; `format(format(x)) == format(x)`; "any sequence of `Input`s never
  panics and keeps cursor/menu invariants" (a state-machine test).
- A timing test per heavy menu, as Doodle has (open a dot in a crate with large dependencies in under N ms).

**Trace in Rust:**
- Keep `input.log` text-based and frame-indexed. Use a new header (`doodle-rs-trace 1`) and the same record
  kinds, plus a `str oracle ...` kind if oracle answers are recorded.
- Use `serde_json` for `events.jsonl`, `walkdir` + `filetime` + `std::fs::hard_link` for snapshots (keep the
  placeholder and budget rules), and `png` for `--screenshot` (`glReadPixels`, flip rows).
- Generate the analysis `BINDINGS` table from the keymap's `ACTION_INFO` (export it as JSON from the app)
  instead of maintaining it by hand. That fixes Doodle's staleness gap.
- Keep the CI check that the release binary does not contain the trace header string.

**Code generation:**
- The Rust analog of "scan the compiler's library sources" is **rustdoc JSON**. Both sources are nightly-only:
  the `rust-docs-json` rustup component (`rustup component add --toolchain nightly rust-docs-json`) for
  `std`/`core`/`alloc`, and `cargo +nightly rustdoc -- -Z unstable-options --output-format json` for
  dependencies. Parse with the `rustdoc-types` crate whose `FORMAT_VERSION` matches the pinned nightly (pin
  both together, the way Doodle pins `ODIN_TAG`).
- Use rust-analyzer at runtime for the user's crate and its dependencies.
- Pre-generate std tables with `cargo xtask gen-std`, deterministic and sorted, with a `do not edit` header, and
  commit them. A CI job regenerates them and fails on `git diff --exit-code`, which closes Doodle's "tables
  drift from the pin" gap.
- Don't emit 75k-row Rust array literals: rustc compiles huge static initializers slowly. Emit a compact data
  file (postcard/bincode, or JSON plus zstd) loaded with `include_bytes!` and parsed lazily into indexes
  (`LazyLock`), or use `phf` maps for exact lookups.
- Prefer `xtask` over `build.rs`: generation needs nightly or network and would otherwise run on every clean
  build.

**CI and Steam Deck:**
- Add what Doodle lacks: `ci.yml` on push/PR running `cargo fmt --check`, `cargo clippy -D warnings`, and
  `cargo test --workspace` (plus the `--ignored` compile checks) on `ubuntu-22.04` and `windows-latest`, plus
  headless replay of committed trace fixtures.
- Keep the manual `release.yml` with the same three jobs:
  - SteamOS inside `registry.gitlab.steamos.cloud/steamrt/sniper/sdk:latest` (install rustup in the container;
    the runtime's older glibc is the point);
  - Ubuntu 22.04 and Windows;
  - one `version` job, artifact upload, a release with fixed-name assets, the same `VERSION` line and checks.
- Never use `-C target-cpu=native` for shipped binaries. Use the default x86-64 or at most `x86-64-v3` (the Deck
  is Zen 2: AVX2 yes, AVX-512 no), and keep the `%zmm` objdump check for whisper.
- For local Deck builds from Windows, `cargo zigbuild --target x86_64-unknown-linux-gnu.2.31` gives a binary
  with an old glibc baseline (2.31 is the glibc of Debian 11, which the Steam Linux Runtime 3.0 "sniper" is
  based on; that figure is general knowledge, not something the repo states, so confirm it against the SDK
  image with `ldd --version` before relying on it). Building inside the sniper SDK container with podman/docker matches CI exactly.
  On the Deck itself, rustup installs without root into `$HOME`. Rust on Linux still needs a linker (`cc`),
  so the Zig-`cc` install trick from Doodle's Setup page (doc 09) carries over for the *user's* projects.

**Conventions:** keep conventional commits with scopes; module-level `//!` headers written from the user's
side with `●` examples and button names; one feature doc section per feature (in practice, make the doc update
part of the definition of done, because Doodle's drifted).

## Open questions & known gaps

1. **No CI on push or PR.** The only workflow is the manual release, so tests run only when someone cuts a
   release (`run_tests` defaults to true there).
2. **Some tests are never run by tooling.** `src/app/shell_test.odin` (12 tests: shell quoting, run and
   toolchain scripts, the stb build command, SHA-256 of a file, Setup rows, updater version/asset parsing,
   the new-root swap and the Windows update script) and `src/platform/platform_test.odin` (`test_dpad_repeat`)
   are not run by build.bat, build.sh or CI, and no commit body mentions running them. Running them needs
   `odin test src/app` / `odin test src/platform`, with SDL2 findable (platform_test.odin's header says so,
   which suggests they were run by hand when written: shell_test.odin in fb757de, d6d998b and 34a2ad1,
   platform_test.odin in d6e415a).
3. **Compiler checks are skipped in CI.** Acceptance tests run `odin check` only with `DOODLE_ODIN` set, or for
   the exact build when `C:/Odin/odin.exe` exists. CI sets neither, so "the built program compiles" is verified
   only on the dev machine.
4. **Leaks are warnings by default.** Odin's runner is not told to fail on bad memory
   (`ODIN_TEST_FAIL_ON_BAD_MEMORY`), so "no leak warnings" depends on someone reading the output.
   With the default settings the runner's tracking allocator records a bad free without passing it to the
   heap, so it logs a warning and the test still passes. How the double free in 0c289ea nevertheless failed
   the Windows job isn't recorded; the likeliest explanation is that the block was reallocated between the
   two frees, so the second one released live memory and the process crashed later (unverified).
5. **`BINDINGS` in tools/trace.py is stale.** It maps `RT+X` to "run list" and `RT+Y` to "save-as", but
   `KEYMAP_DEFAULT` has RT+X = Grab (Refactor), RT+Y = Save and LT+Right = Run list, with Save as unbound.
   `LAYOUT_ACTIONS` has no `grab` or `save` keys, so `use_layout` drops those slots from reports even for
   recordings that carry their keymap. `BINDINGS` last changed in f544db5, before Grab (cee37be) and Save
   (4289c7d) existed.
6. **docs/TRACE.md under-lists `scr` and `mode` values** compared with `screen_ctx` (missing `stb_build`,
   `vendor_path`, `settings`, `new_project`, `new_project_folder`, and modes `ref_pass`, `grab`, `grab_copy`,
   `words`, `transcribing`, `overwrite_prompt`, `picker`, `reset_prompt`, `remove_prompt`).
7. **`verify` is local-only and needs a GPU window.** The recordings that form the "suite" are git-ignored and
   pruned to 40. There is no committed corpus of fixture recordings with fingerprints, and `script` fixtures
   carry no fingerprints.
8. **Generated tables aren't checked against the pin.** Regeneration is manual. Nothing verifies that
   `src/model/core_*.odin` match `ODIN_TAG dev-2026-11`, and the tag is duplicated (setup.odin, workflow) with
   only "keep in step" comments.
9. **Stale design docs.** ARCHITECTURE.md §3 to §8 and MULTI_AGENT.md describe frozen interfaces for stub packages
   (`buffer`, `editor`, `input`, `ui`, `lsp`, `project`) that nothing imports, an `ols` LSP client that was
   never used, and an external Excalidraw board. ARCHITECTURE.md's package map doesn't mention `model` at
   all. docs/TESTING.md's example uses fields that no longer exist.
   docs/INSTALL.md is an early Windows-on-ARM setup note.
10. **The feature doc lags the code.** docs/EDITOR_MODEL.md changed in only 4 of 91 commits. Grab, word-by-word
    editing, result lists, the Refactor menu and Settings are described mainly in commit bodies and file headers.
11. **Script differences.** build.sh `run` doesn't accept a file argument (build.bat does). The Zed tasks are
    Windows-only. build.bat `test` stops with exit 1 if the model tests fail, otherwise returns the stt run's
    exit code.
12. **Untracked binaries** (git-ignored by `*.exe`, not part of any documented workflow): `src/model.exe`
    (2026-11-19) is a leftover Odin test-runner build of package model (it contains the runner's
    `ODIN_TEST_*` option strings and the model test names). `sibbench.exe` and `sibcheck.exe` at the repo root
    (2026-11-19) are throwaway programs that link the model's sibling-file code (`sibling_procs`,
    `sibling_types`); `sibbench.exe` embeds its source path, `%TEMP%\sibbench\main.odin`, and the core
    `Benchmark_Options` type, so it was a one-off benchmark of sibling-file loading (siblings.odin) whose
    source was never committed. What `sibcheck` checked is unknown.
13. **Heat save race.** "Two saves at the very same moment could still race; uses are only lost then"
    (heat_store.odin). This is acknowledged and unfixed.
14. **No lint or format gate.** There are no `-vet`/`-strict-style` flags and no formatter check. Style is
    convention only.
15. **The harness-removal table is incomplete.** docs/TRACE.md lists 17 hook sites, but `TRACE hook` marks 39
    lines in 14 files at baseline (feature 17), only 13 of them with a `(was: ...)` note. Removal should follow
    the grep, not the table.
16. **The fingerprint misses some modal state.** `grab_active`/`grab_copy`, `word_edit_active`, `slot_menu`
    and `g_stt_busy` are not hashed (feature 12), so a replay that diverges only in those modes is caught a
    frame later at best, or not at all.
17. **Takeover snapshot is a copy, not links.** `take_over`'s comment says the new trace's snapshot uses
    links, but it calls `copy_tree` without a `prev` folder, so the snapshot is copied in full with unlimited
    budgets.
18. **After takeover, some real side effects come back.** Setup installs, the updater, the vendor PATH edit
    and the Recycle Bin are guarded only by `trace_replaying()`, which is false after takeover; only
    `trace_write_ok`-guarded writes stay in the sandbox. docs/TRACE.md claims more ("a replay session can
    never change a real file, even after you take over").
19. **One mutable global in the model.** `@(thread_local) decl_type_names` (data_types.odin) is the single
    exception to "no globals"; it works because it's thread-local and only set during one call.

# 09 — Projects, file navigation, saving, running programs, setup and distribution

> Odin sources: src/model/file_grid.odin, src/model/projects.odin, src/model/project_roots.odin,
> src/model/vendor_libs.odin, src/model/model.odin (`MENU_ITEMS`, `menu_items`, `new_project`, `update` .Menu branch,
> `keymap_run`), src/model/serialize.odin (`file_text`, `save_source`), src/model/parse.odin (`load_file`, `doc_from_source`),
> src/app/main.odin (main loop menu dispatch, input routing, `app_requests`, `draw_menu`), src/app/filenav.odin,
> src/app/projects.odin, src/app/new_project.odin, src/app/save.odin, src/app/save_dialog.odin, src/app/run.odin,
> src/app/shell.odin, src/app/vendor_path.odin, vendor_path_windows.odin, vendor_path_other.odin, src/app/setup.odin,
> src/app/settings.odin (page wiring only), src/app/toolchain.odin, src/app/stb_build.odin, src/app/updater.odin,
> src/app/trash_windows.odin, trash_other.odin, src/app/roots_store.odin, src/app/heat_store.odin (`heat_exe_dir`),
> src/app/pid_windows.odin, pid_other.odin, src/project/project.odin (dead stub), src/app/editor_view.odin (title bar),
> src/app/trace.odin (`trace_startup_file`, `cli_file`), src/model/keymap.odin (`KEYMAP_DEFAULT`, `ACTION_INFO`),
> src/model/settings.odin (`SETTING_INFO`), src/model/collections.odin (`odin_root`, the model's own lookup); tools/deck_install.sh,
> .github/workflows/release-steamos.yml, build.sh, build.bat, README.md, docs/INSTALL.md, docs/EDITOR_MODEL.md (File navigation, §6).
> Tests: src/model/file_grid_test.odin, projects_test.odin, project_roots_test.odin, vendor_libs_test.odin,
> src/app/shell_test.odin, src/model/model_test.odin (`test_new_project_enters_editor`, `test_menu_cancel_quits`, `test_parse_trailing_newline`).
> Baseline: Doodle @ 34a2ad1.

## Purpose

This area is everything between "I picked up the controller" and "my program is running": the main menu, creating a
project (where it goes, its generated name), reopening recent projects, walking and managing files with a d-pad, saving,
running and testing the program in a real terminal, and getting the compiler toolchain onto the machine in the first
place (including a Steam Deck with a read-only root, no compiler and no keyboard). A gamepad IDE can't assume a shell,
a file manager, a keyboard or a pre-installed toolchain, so Doodle owns all of these, keeps each one to a few buttons
with on-screen hints, never asks the user to type a path, and checks every download against a pinned checksum.
The editing of code itself is in docs 01-08; this doc covers the files around it.

## Features

### F1. Main menu (from this area's angle)

- **Trigger**: app start (state `.Menu`); plain B from the editor (`nav.cancel -> state = .Menu`).
- **Behavior**: title `DOODLE`, subtitle `Odin IDE  -  gamepad native`, a centered grid of `MENU_ITEMS` in this order:
  `New Project`, `Recent Projects`, `Open Folder`, `Key Layout`, `Settings` (5 items -> `grid_cols(5)` = 3 columns: 3 + 2).
  D-pad moves with wrap-around (`grid_nav`); A opens (A, Enter or Space: all set `raw.e_confirm`). The four
  disk/overlay items are intercepted in main.odin before the model sees the A (only when no Recent Projects / New
  Project / Key Layout / Settings overlay is already open): `Recent Projects` -> F6, `New Project` -> F3,
  `Key Layout` -> doc 03 F10, `Settings` -> F26 / F30 (page mechanics: doc 03 F15).
  Footer: `D-pad / Arrows to move    A / Enter to select    (Open Folder not wired yet)`.
- **Rules & edge cases**:
  - `Open Folder` is drawn dim and A on it does nothing (not wired: main.odin has no case for it and the model's
    `.Menu` branch only acts on index 0).
  - The IDE menu (default LT+Left) is global and also opens over the main menu; its `Exit` quits, `Format file` and
    `Key layout` return to the main menu (`open_ide_menu` stores `return_state`).
  - Replaying a recording made before New Project asked "where?" (`g_roots_legacy`, set by `roots_store_override`):
    A on `New Project` is not intercepted; `model.update` resets the document and enters the editor, and main.odin then
    calls `new_project_setup()` with the default folder.
  - **B on the main menu quits Doodle immediately**, without any save prompt (`test_menu_cancel_quits`). The main menu has
    no "back to my document" item and the IDE menu returns to the main menu, so the in-memory document is effectively
    abandoned once you B out of the editor (Recent Projects reloads from disk; New Project resets it).
  - A trace replay of an old recording uses the 4-item menu (`menu_legacy`), so recorded presses land on the same cells.
- **Source**: src/model/model.odin `MENU_ITEMS`, `menu_items`, `update` (.Menu); src/app/main.odin main loop ("Main menu
  actions handled here"), `draw_menu`.

### F2. Where projects live: the default folder and added roots

- **Trigger**: startup (`ensure_projects_dir`, `roots_store_init`), and every feature that needs "the projects folders".
- **Behavior**:
  - **Default folder** `g_projects_dir` = `<home>/DoodleProjects`, where home = `%USERPROFILE%`, else `$HOME`. Created at
    startup if missing. The path is built with a forward slash even on Windows (`C:\Users\me/DoodleProjects`); all path
    comparisons normalize slashes. Without any home variable it falls back to `./DoodleProjects`, made absolute after
    creating it.
  - **Added roots** (`g_roots`): extra folders the user added via New Project (F4), persisted in `doodle_roots.txt` (F37).
  - `all_roots()` = default folder first, then the added ones in insertion order. Recent Projects, file navigation's
    project root, and rename refusal all use it.
  - **Project root of a file** (`project_root_of`): for each root, the first folder below the root on the file's path
    (`fgrid_project_root`); roots can nest (a folder added inside DoodleProjects), the **deepest** (longest root string)
    wins. A file loose directly in a root has no project root. The comparison is `fgrid_norm`-based: slashes unified,
    trailing slash dropped and **lower-cased on every OS** (pinned: `test_fgrid_project_root` matches root `/P/`
    against `/p/game/main.odin`), unlike `roots_same`, which ignores case only on Windows (F37).
- **Rationale**: HOME is required on Linux because a Deck launched from Steam starts in the install folder, which an
  update deletes (README "Default projects folder"; save.odin comment).
- **Source**: src/app/save.odin `ensure_projects_dir`; src/app/roots_store.odin `all_roots`, `project_root_of`;
  src/model/file_grid.odin `fgrid_project_root`.

### F3. New Project: "where?"

- **Trigger**: main menu -> A on `New Project`.
- **Behavior**: an overlay titled `NEW PROJECT  -  WHERE?` with one row per choice (tall rows: label, then a second line):
  1. `In default folder` / second line = the default folder path.
  2. One row per added root: `In <folder title>` / its full path; if the folder no longer exists the second line is
     `<path>  (not found)` in warning colour.
  3. `Add another folder...` with a + icon (opens F4).
  Up/Down move with wrap (Left/Right/Y ignored); A on a folder row starts the project there; X on an added row removes it
  (two presses); B closes back to the main menu. The list opens on row 0 and scrolls to keep the selection centred
  (`^ more` / `v more`). Hints (exact): row 0 `D-pad move   A create the project here   B back`; an added row
  `D-pad move   A create the project here   X remove from list   B back`; the add row `D-pad move   A pick a folder to add   B back`.
- **Starting the project** (`new_project_start`): close the overlay; `model.new_project` resets the document to empty
  (zero lines: only the green insertion dot) and enters the editor; `new_project_setup(root)` generates a name (F5), sets
  the project folder to `<root>/<name>`, clears the current file, and **creates the folder immediately**. The editor
  title then reads `<root>/<name>/main.odin  (unsaved)`. The file itself is only written by the first save (F9).
- **Rules & edge cases**:
  - A on an added root that no longer exists: status `folder not found: <path>`, stays on the list.
  - **X on an added row**: the first X arms it (outline turns red, second line becomes
    `press X again to remove it from the list (the folder stays on disk)`); the second X removes it from the list and saves
    the file; status `removed <path> from the list`; the selection stays on the same index (clamped). Any Up/Down, and
    A, disarms. X on the default row or the add row does nothing. The folder itself and its projects stay on disk.
  - If `doodle_roots.txt` can't be saved, every add/remove status gets the suffix
    ` (only until Doodle closes: doodle_roots.txt can't be saved)` (not during a replay).
  - New Project does not ask about unsaved edits in a document left behind earlier.
  - The default row is never checked for existence (`ensure_projects_dir` created it at startup).
- **Source**: src/app/new_project.odin (`new_project_open`, `handle_new_project_input`, `new_project_start`,
  `draw_new_project_overlay`, `np_saved_note`); src/app/save.odin `new_project_setup`, `set_project_dir`,
  `set_current_file`; src/model/model.odin `new_project`; test `test_new_project_enters_editor`.

### F4. Add another folder: the folder browser

- **Trigger**: New Project list -> A on `Add another folder...`.
- **Behavior**: title `ADD A PROJECT FOLDER`, the current folder path (or `Drives`) under it, then a list:
  first row `Use this folder (<title>)` (accent, + icon), then the folder's **subfolders only**, A-Z case-insensitive,
  each shown `name/`. Folders starting with `.` or `$` are hidden; files are never listed.
  It **starts in the parent of the default projects folder** (normally the home folder), made absolute.
  Controls: Up/Down move (wrap); **A or Right** on a folder opens it; **Left** goes up a level with the folder you came
  from selected; **A** (not Right) on `Use this folder` adds it; **B** returns to the New Project list (not the main menu).
  Hints: `D-pad move   A open folder   Left up a level   B cancel`, or on the Use row
  `A add this folder   D-pad move   Left up a level   B cancel`.
- **Rules & edge cases**:
  - Windows: above a drive root is a **drive list** (`A:/` .. `Z:/` that exist, checked with `os.is_dir`; no Use row
    there; title line `Drives`). Each drive row is drawn as `label + "/"`, so it reads `C://` on screen. Left on the
    drive list does nothing. Linux: Left stops at `/` (nothing happens).
  - Unreadable folder: status `could not open <dir>`; only the Use row is listed. `Nothing here` is drawn only when the
    list is completely empty, which can only be a drive list with no drives (every folder listing has the Use row).
  - **Right** on the Use row does nothing (only A adds), so Right can't add a folder by accident.
  - Adding (`roots_add`): `Added` -> saved, list row selected, status `added <dir>`; `Duplicate` (same folder by
    `roots_same`) -> the existing row selected, `that folder is already in the list`; `Is_Default` -> row 0 selected,
    `that's the default folder`; `Empty` -> nothing. A trailing slash is trimmed, except a drive root's (`C:/` stays).
    In every case the browser closes back to the New Project list. (The four results are pinned by `test_roots_add`.)
- **Source**: src/app/new_project.odin `np_browse_open`, `np_browse_show`, `np_browse_up`, `np_browse_input`,
  `np_add_folder`, `draw_np_browser`; src/model/project_roots.odin `roots_add`, `roots_same`, `roots_index`.
  Note: README's table says the browser "starts at the drive list" (Windows) / "starts at /" (Deck); the code starts in
  the home folder on both.

### F5. Random project names

- **Trigger**: every New Project.
- **Behavior**: `<adjective>-<animal>-<NNNN>`, lowercase, hyphenated, 4-digit zero-padded number 0000-9999
  (`fmt "%s-%s-%04d"`), e.g. `slow-wolf-5364`, `brave-otter-5848`. Lists (exact, in order):
  adjectives `swift brave calm wild bright deep cool warm quiet loud soft hard clean rough smooth dark light heavy tiny huge fast slow sharp dull` (24);
  animals `fox wolf bear deer hawk eagle lion tiger otter badger raven owl lynx moose elk seal whale shark dolphin penguin panda koala lemur` (23).
  The name goes through `trace_str("project_name", ...)` so a replay reproduces the recorded name.
- **Rules & edge cases**: no collision check (24 x 23 x 10000 = 5,520,000 combinations); if the folder already
  exists, `make_directory` fails silently and the new project shares it, and the first Save then **overwrites** an
  existing `main.odin` there without asking (F9). The random source is `core:math/rand` (`rand.int_max`). The project
  folder is renamed later with Files > LT+X on the "here" tab (F17).
- **Rationale**: a project must exist on disk without asking for a name (no keyboard); the generated name is friendly and
  replaceable (status after first save says so).
- **Source**: src/app/save.odin `adjectives`, `animals`, `gen_project_name`, `new_project_setup`.
  (Identifier names inside code are a different generator: doc 01 §16 / doc 00 P5.)

### F6. Recent Projects

- **Trigger**: main menu -> A on `Recent Projects`.
- **Behavior**: rescans every root (`list_projects_in(all_roots())`) and shows `RECENT PROJECTS`: one row per project,
  newest first, label = folder name, plus `   (in <root title>)` when the project is not in the default folder; the age on
  the right (`age_label`: `just now` < 60 s, `Nm ago` < 1 h, `Nh ago` < 1 day, else `Nd ago`). Hint:
  `<i> / <n>     D-pad move   A open   B back`. Up/Down wrap; Left/Right ignored; the list scrolls to keep the selection
  centered with `^ more` / `v more`.
  A opens the project (`open_project`): loads its file into the editor like Files does (F15: previous-file history
  updated, project folder = the file's folder, paper sound), sets the file navigation root to the project folder, status
  `opened <name>` (set even when the load failed, overwriting `could not open <path>`).
  B (or A on an empty list) returns to the main menu.
- **What counts as a project** (`list_projects`): a **direct subfolder** of a root that contains at least one `.odin`
  file directly in it (subfolders are not searched; hidden dot-folders are **not** skipped here, unlike Files). File to
  open: `main.odin` if present, else the first `.odin` by byte-wise full-path comparison. Its time: the newest
  modification time among those `.odin` files. A root listed twice (same folder by `roots_same`: slash style and a
  trailing slash ignored, case only on Windows) is scanned once; a missing root is skipped. Each root's list is sorted
  newest first with `slice.sort_by` (not a stable sort in Odin's core:slice: equal times can come in any order), then the merged list
  is `stable_sort_by` newest first (`test_list_projects_in_merges_roots_newest_first`).
- **Rules & edge cases**: never-saved New Projects (empty folders) are invisible here. Empty list text:
  `No saved projects in <default folder> yet - save one with <button of Save as>` + `B back`. Save as has no default
  button, so with the default layout the sentence ends in `save one with ` (see Open questions).
- **Source**: src/app/projects.odin (`projects_open`, `open_project`, `handle_projects_input`, `draw_projects_overlay`);
  src/model/projects.odin `list_projects`, `age_label`; src/model/project_roots.odin `list_projects_in`.

### F7. Opening a file from the command line

- **Trigger**: `doodle.exe path\to\file.odin` (or Explorer "Open with").
- **Behavior**: if `os.args[1]` exists (`os.exists`, so a folder passes too) it is loaded with `filenav_load` (F15)
  before the first frame: current file, project folder = its folder, parse, format, editor state. It is not
  `filenav_open_file`, so no previous file is recorded and no sound plays. The editor opens directly on it. Nothing else
  is parsed from the command line in a release build (debug builds accept `--replay`, doc 11). A path that exists but
  can't be loaded (a folder) leaves Doodle on the main menu with status `could not open <path>`, yet the current file is
  already set to that path (F15 edge case).
- **Source**: src/app/main.odin (`trace_startup_file`), src/app/trace.odin `cli_file`.

### F8. Current file, project folder, package folder (the state everything keys on)

- **Behavior**: three app globals drive saving, running and sibling lookup:
  - `g_current_file`: the open file's path, or `""` for a never-saved document.
  - `g_project_dir`: **the save folder and the run working directory**. New Project sets it to the new project folder;
    **opening any file sets it to that file's own folder** (`filenav_load -> set_project_dir(filepath.dir(path))`), not
    to the project root. Changing it marks `run.txt` as not loaded (it is per folder, F21).
  - `g_project_name`: base name of `g_project_dir`.
  - The **package folder** (whose other `.odin` files are siblings, doc 07) = the open file's folder, or the project
    folder for an unsaved document. `set_current_file` re-reads siblings every time, even for the same path (a save).
  - Editor title bar (top left): the open file's full path; else `<project>/main.odin  (unsaved)`; else `untitled.odin`.
- **Rationale**: in Odin a folder is a package, so "this file's folder" is exactly what `odin run .` / `odin check`
  need. (For Rust this changes: F-notes in "Carrying this to Rust".)
- **Source**: src/app/save.odin `set_project_dir`, `set_current_file`, `refresh_siblings`, `editor_title`;
  src/app/editor_view.odin (title bar).

### F9. Save (RT+Y by default)

- **Trigger**: the `Save` action (default **RT+Y**; a *required* action, it always has a button, doc 03).
- **Behavior** (`save_now` -> `save_current`): write the document without asking, to the open file, or for a never-saved
  document to `<save_folder>/main.odin`, where `save_folder` = the open file's folder, else the project folder (created
  if missing; if there is no project folder at all, a fresh random project is set up in the default folder first).
  Status: first save of a new document `saved main.odin in <folder name> - rename it in Files (LT+X)`; later saves
  `saved <file name>`; failure `SAVE FAILED: could not save: <os error>` (also printed to stderr).
  After writing, the file becomes the current file and siblings are refreshed.
- **What is written** (`write_doc` -> `model.file_text`, details in doc 01 §11): the document is **reformatted in place**
  (`format_doc`, so the screen changes too), editor-only `●` statement lines are dropped unless a `●` is a block's only
  content (it then saves as the blank line inside `{ }`), lines are joined with `\n`, and a final newline is added unless
  the loaded file had none (`no_final_newline`) or the body is empty. CRs are stripped on load, so **CRLF files are saved
  as LF**.
  ```odin
  // on screen                          // saved main.odin
  package main                          package main
  main :: proc() {                      main :: proc() {
      x := 1                                x := 1
      ●                                 }
  }                                     (+ final "\n")
  ```
- **Rules & edge cases**: Save never asks and never checks whether the target exists. Normally that is safe (it is the
  open file, or `main.odin` of a fresh folder), but the folder is not always fresh: after the open file was deleted in
  Files (F18) the target is `main.odin` in the deleted file's folder, and a New Project whose generated name already
  existed (F5) shares that folder. In both cases an existing `main.odin` there is **silently overwritten**
  (`save_current` -> `write_doc` -> `os.write_entire_file`). `save_folder` uses `os.make_directory` (one level), so if
  the whole folder was deleted from deeper down, the save fails with `SAVE FAILED: ...`.
  Renaming is not part of Save: use Files > LT+X (F17). A successful save plays no sound and does not touch the Files
  grid or the run list.
- **Source**: src/app/save.odin `save_now`, `save_current`, `save_folder`, `write_doc`; src/model/serialize.odin
  `file_text`, `save_source`; src/model/parse.odin `doc_from_source` (final newline / CR handling); test
  `test_parse_trailing_newline`.

### F10. Save as (and the shared name dialog)

- **Trigger**: the `Save as` action (**no default button**; place it via Key Layout, doc 03). The same dialog opens in
  rename mode from Files > LT+X (F17).
- **Behavior**: a centered panel titled `SAVE AS` (save icon) with a name box **prefilled** with the open file's base name
  (or `main.odin`), shown "selected": the first typed character or dictation **replaces** the prefill. Under the box:
  `in <folder>`, or `saves as <cleaned name>  in <folder>` when cleaning changed the name. The folder is always the
  current save folder (Save as cannot change folders). Hint: `A save    B cancel    hold X to say a name    (keyboard: type)`
  (without speech: `A save    B cancel    (keyboard: type a name)`).
  - **Gamepad**: hold **X** to dictate the name (identifier mode, `stt.set_free_text(false)`: lowercased, runs of
    non-alphanumerics become one `_`, e.g. "game loop" -> `game_loop`; needs a speech engine (`g_stt_e != nil`);
    `[REC]` shown, box outline red); release replaces the whole name. X must have been released once since the dialog
    opened (LT+X opened rename with X still down). Other buttons are ignored while recording.
  - **Keyboard**: typed characters append, but only what `handle_key` records as text: SDL key codes `a`-`z`, `0`-`9`,
    `-` and `.` (always lowercase: no Shift handling, so a keyboard can't type capitals), and not while Ctrl is held;
    **Space types `_`** (Space is also A elsewhere; here the Space branch returns first); **Backspace deletes one
    character** (it does not cancel here; on a still-selected prefill it deletes the prefill's last character);
    Enter = A; Esc = B. Keyboard `x` types an `x`: dictation listens to the **gamepad** X only (`raw.pad_x_held`).
  - **A** commits; **B** cancels (closing also ends any recording).
- **Commit** (`save_dialog_commit`): `clean_filename` (keep `[A-Za-z0-9_-.]`, spaces/tabs -> `_`, other characters
  dropped, so no path separators; trim leading/trailing `.` and `_`; append `.odin` if missing; `""` if nothing usable or
  the name is just `odin`/`.odin`). Empty -> error line `Type or say a file name first`. Target exists and is not the
  open file -> warning `<name> already exists - press A again to overwrite`; a second A overwrites; any edit of the name
  clears the pending confirmation and any error. Write failure -> the error text in the dialog (`could not save: <err>`).
  Success closes the dialog silently (no status, no sound); the new path becomes the current file; the old file stays on
  disk (Save as is a copy). The open-file check uses save_dialog.odin's private `same_path`, which is case-insensitive
  on **every** OS: on Linux, Save as `Main.odin` while `main.odin` is open overwrites an existing, different
  `Main.odin` without the second-A warning. If there is no project folder at all, the commit's `save_folder()` call
  creates a fresh random project first (the preview line showed the default projects folder).
- **Source**: src/app/save_dialog.odin (`save_dialog_open`, `handle_save_input`, `save_dialog_commit`, `draw_save_dialog`,
  `save_folder_preview`); src/model/projects.odin `clean_filename`; test `test_clean_filename`.

### F11. When files are NOT saved (no autosave)

- **Behavior**: Doodle has **no autosave and no dirty flag**. A file is written only by Save (F9), Save as (F10), and
  **before every Run** (F23: a Run saves first and aborts if the save fails). These drop in-memory edits silently:
  opening another file in Files or Recent Projects, A on the already-open file in Files (reloads it from disk), Previous
  file, New Project, B to the main menu (there is no way back to the in-memory document from there), IDE menu > Exit,
  B on the main menu (quit), closing the window, and the updater's `Restart` (A quits Doodle, F35).
  Deleting the open file in Files keeps the text in the editor, unsaved, and the next Save writes `main.odin` in the
  project folder, overwriting one that is already there (F9; the code comment "saving asks for a name" in
  `filenav_delete_confirmed` is stale).
- **Changes made on disk by another program are not noticed.** The open file is read once, by `filenav_load`
  (`model.load_file`), and never again until it is reopened; nothing in src/app or src/model stats it or compares its
  modification time (the only `modification_time` uses are the Recent Projects age, the trace snapshot and the sibling
  cache). So an edit made in another editor (or a `git checkout`) while the file is open is silently **overwritten** by
  the next Save, Save as onto the same name, or Run (which saves first). A on the already-open file in Files reloads
  it from disk, which is the only way to pick up such a change (losing Doodle's unsaved edits instead). The package's
  other files are re-read only when the open file changes or is saved (`set_current_file` -> `refresh_siblings`, only
  files whose size or modification time changed), so a sibling edited outside Doodle shows up in the menus at the next
  open / save, not live (doc 07 §11). A port should at least compare the file's modification time before saving.
- **Rationale**: none stated in code or commits; doc 00 (Open questions 2) lists it as a known gap. Carry the
  explicit-save model forward, but see Open questions.
- **Source**: src/app/save.odin (callers of `save_current`), src/app/filenav.odin `filenav_open_file`,
  `filenav_delete_confirmed`; src/model/model.odin `update`.

### F12. Files (RT+B): entering, root and starting view

- **Trigger**: the `Files` action (default **RT+B**, required) in the editor.
- **Behavior**: a full-width sheet over the veiled editor (`COL_VEIL`, 95% opaque: the code is effectively hidden)
  shows a **folder grid** (F13). Two paths matter:
  - The **root** `g_fn_dir`: what search covers and where the breadcrumb starts. On entry, a root left over from another
    project (the current file's folder is neither the root nor under it) is dropped. If unset, root = the current file's
    **project root** (F2, under any projects folder), else `g_project_dir`, else the default projects folder, else `.`.
    Recent Projects sets it to the opened project's folder.
  - The **view** (the folder whose contents are the columns) = `fgrid_view_for(current file, root)`: the parent of the
    file's folder, so the file's folder appears as a column next to its sister folders; the root itself when the file sits
    directly in the root or outside it. The open file is selected; else the first cell of the first column (or that
    column's tab when it is empty). `want_row` starts at 0 and both display scroll offsets reset to 0 (`fn_show`).
  The descent counter is reset to 0. Search state and any pending delete from a previous visit were cleared when Files
  last closed (`filenav_exit`).
- **Source**: src/app/filenav.odin `filenav_enter`, `filenav_init`, `fn_show`; src/model/file_grid.odin `fgrid_view_for`,
  `fgrid_project_root`; tests `test_fgrid_view_for`, `test_fgrid_project_root`.

### F13. The folder grid: columns, the "here" column, ordering, caps

- **Behavior** (`fgrid_build(view)`):
  - Columns left to right: an optional **"here" column** holding the view's own files, then **one column per subfolder**
    of the view. Each subfolder column lists that folder's **files, then its subfolders as closed boxes**.
  - Sorting in the grid (`sort_entries`): files before folders, each A-Z case-insensitive; ties after lowercasing break
    on the raw name (`A.odin` before `a.odin`) so the order is deterministic. (Search, F19, and the folder browser, F4,
    sort differently and have no tie-break.) Hidden entries (name starts with `.`) are skipped by `fgrid_list_disk`, so
    a project's `.doodle/` never shows.
  - An empty column shows `(empty)` (an unreadable one `(can't open)`); a column whose items are all scrolled above the
    shared first row shows `^`.
  - The "here" column exists when the view has files, **or** has no subfolders at all (an empty folder still gets a
    column to stand on), **or** a rebuild of the *same* view had one before (deleting or renaming away its last file keeps
    the empty "here" column so X on its tab can still create a file there).
  - Caps: at most `FGRID_MAX_ITEMS` = 400 items per column (the rest counted as `+N` on the tab) and
    `FGRID_MAX_GROUPS` = 200 subfolder columns (the rest shown as `(+N folders)` in the breadcrumb). A rebuild reads at
    most 1 + 200 folders.
  - An unreadable view climbs to its nearest readable ancestor (max 64 steps). An unreadable subfolder becomes a column
    marked `unreadable` showing `(can't open)`.
  - The grid knows nothing about window size, so moves are identical at any size (trace replay determinism).
- **Source**: src/model/file_grid.odin `fgrid_build`, `sort_entries`, `add_item`, `fgrid_list_disk`; tests
  `test_fgrid_build_columns`, `test_fgrid_here_column_and_stable_sort`, `test_fgrid_keeps_here_column_on_rebuild`,
  `test_fgrid_caps_long_columns`, `test_fgrid_build_climbs_from_gone_view`.

### F14. Grid movement

- **Trigger**: d-pad in Files (one direction per frame, priority Up, Down, Left, Right, so a diagonal can't skip a cell).
- **Behavior** (`fgrid_move`): the cursor is (column, item), item `-1` = the column's **tab**; `want_row` remembers the row.
  - Up: from item 0 to the tab; on the tab nothing. Down: from the tab to `min(max(want_row,0), n-1)`; at the bottom
    nothing (**no wrap**, unlike menus). Every Up/Down sets `want_row`.
  - Left/Right keep `want_row`, clamped to the target column's length; an **empty column parks on its tab but keeps
    `want_row`**, so the next tall column gets the row back. Only an explicit Up onto a tab (`want_row = -1`) makes
    Left/Right walk the tab row.
  - Right at the last column: nothing. **Left at the first column = up a level** (F15).
- **Source**: src/model/file_grid.odin `fgrid_move`; tests `test_fgrid_move_keeps_row`, `test_fgrid_tabs`,
  `test_fgrid_edges`, `test_fgrid_row_survives_empty_column`.

### F15. Dropping in, going up, opening, previous file

- **A on a file**: open it (`filenav_open_file`): if it differs from the open file, the open file becomes the
  **previous file**; then `filenav_load`: current file = path, project folder = its folder, `model.load_file` parses it
  (any file type, through the Odin line parser), `format_doc`, editor state; Files closes; paper sound. Failure: status
  `could not open <path>`, but by then `set_current_file(path)` and `set_project_dir(dir)` have already run and Files
  still closes: the editor shows the old document while the title, Save and Run point at the unloadable path (a later
  Save writes the old document there).
- **A on a folder box** (in column G): the view becomes G, so the box and its sister folders become the columns, the box
  is focused and the cursor steps onto its first item (stays on the tab if empty). **A on a column tab**: view = that
  folder. **A on the "here" tab**: refused, status `you're in this folder - Left goes up a level`. A tab that can't be
  read: refused (`can't open <name>`) because the rebuild would climb straight back. If the folder vanished between reads
  (the rebuilt view is the old view or not the wanted one): `can't open <name>` and the descent isn't counted.
- **Descents**: each real drop-in increments a counter. **B** with descents > 0 goes up one level (decrementing); with 0
  it closes Files back to the editor. Hint shows `B up a level` or `B back` accordingly.
- **Up a level** (B, or Left at the first column): view = parent, the folder we left focused on its tab. Climbing above
  the root **moves the root up** too. Both ways decrement the descent counter (never below 0), so Left-climbs also
  "use up" drop-ins. At the filesystem top (`/`, `C:/`, or a relative path's top): status `already at the top` and
  descents reset to 0; B at the top therefore leaves Files in the same press (`fn_up_level` returns false ->
  `filenav_exit`), while Left at the top just shows the status.
- **RT+B inside Files** = switch to the previous file (swap current and previous, load, paper sound, close Files).
  Nothing happens (no status, Files stays open) if there is no previous file. Outside Files the `Previous file` action
  (no default button) does the same, or says `no previous file yet`. The previous file is session-only.
- **Input priority inside Files** (`handle_filenav`): pending delete box, search mode, Y, RT+B, LT+B, B, X (LT up),
  LT+X, then one d-pad step and A.
- **Source**: src/app/filenav.odin `handle_filenav`, `fn_descend`, `fn_up_level`, `filenav_open_file`, `filenav_load`,
  `filenav_alt_tab`; src/model/file_grid.odin `fgrid_descend`, `fgrid_up`, `fgrid_parent_of`, `fgrid_select_path`;
  src/app/main.odin `app_requests` (.Prev_File); tests `test_fgrid_descend_shows_sisters`, `test_fgrid_up_focuses_old_view`,
  `test_fgrid_descend_refuses_unreadable`, `test_fgrid_parent_of_stops_at_top`.

### F16. New file (X)

- **Trigger**: X in Files (with LT not held).
- **Behavior** (`fgrid_target_dir`): the target folder is the highlighted tab's folder (the "here" tab = the view), the
  highlighted box's folder, or the highlighted file's folder. Creates an **empty** (0-byte) `new_file.odin`, or
  `new_file_2.odin`, `new_file_3.odin`, ... (first free name). The grid is re-read and the new file is selected (not
  opened). In a closed box: the view drops into the box's column (counted as a descent) so the new file is visible.
  Failure: `could not create <name>`. An empty, readable "here" column that is the only column shows, beside it, the
  hint `X makes a new file here`. No status on success, no sound. X with RT held also creates a file (only LT is
  checked). The name probe uses `os.exists`, so hidden files and folders also block a name.
- **Source**: src/app/filenav.odin `filenav_create_new`; src/model/file_grid.odin `fgrid_target_dir`; test `test_fgrid_target_dir`.

### F17. Rename (LT+X)

- **Trigger**: LT+X in Files.
- **Behavior**: opens the F10 dialog in **rename mode**: title `RENAME <name>`, box prefilled with the current name,
  info line `in <folder>` or `renames to <final>  in <folder>`, hint `A rename    B cancel    hold X to say a name    (keyboard: type)`.
  Target: the highlighted file / folder / column tab, **or on the "here" tab the folder you are standing in** (so a
  project folder can lose its generated name: `brave-otter-5848 -> my-game`).
  Name cleaning (`clean_rename`): same characters as `clean_filename`; a folder gets no extension; a file keeps its old
  extension unless the new name contains a dot (`notes.md` + "todo" -> `todo.md`; `main.odin` + "game" -> `game.odin`;
  "todo.txt" -> `todo.txt`); `""` when nothing is left or the name equals the extension (`odin`).
  Commit: empty -> `Type or say a name first`; unchanged -> just close; another entry with that name exists (a case-only
  change of the same entry is allowed) -> `<name> already exists`; OS failure -> `Could not rename: <err>`. Meant never
  to overwrite, with one hole: the "same entry" test is save_dialog.odin's case-insensitive `same_path` on every OS, so
  on Linux renaming `Foo.odin` to `foo.odin` while a different `foo.odin` exists skips the check and `os.rename`
  replaces `foo.odin`. Success closes the dialog with no status.
- **After a rename** (`filenav_renamed`): the open file follows; for a folder, everything under it follows too: the open
  file, the previous file, the project folder (save target, run folder), the Files root, and the view (rebuilt with the
  renamed folder selected, descents kept).
- **Refusals** (status): on the "here" tab of a projects root `<name> holds your projects - Doodle doesn't rename it`;
  of a drive root `a drive can't be renamed`.
- **Rationale**: commit 3f42086 ("LT+X renames the folder you're in": a project's own folder is exactly the one you stand in).
- **Source**: src/app/filenav.odin `rename_target`, `filenav_rename`, `filenav_renamed`, `rebased`;
  src/app/save_dialog.odin `rename_dialog_open`, `rename_dialog_commit`, `dialog_final_name`; src/model/projects.odin
  `clean_rename`; test `test_clean_rename`.

### F18. Delete (LT+B) and the trash

- **Trigger**: LT+B in Files on a file, box or column tab (not the "here" tab: `this is the folder you're in - go up a level first`).
- **Behavior**: a red-outlined confirmation box: `Delete <name> ?` or `Delete folder <name>/ ?`; body
  `It goes to the Recycle Bin (you can restore it from there).` or
  `The folder and everything in it (<N> files) go to the Recycle Bin.` (`count_files`: files at depth <= 12, hidden ones
  included; exactly one reads `1 file`; counting stops once a folder's running total reaches 400 and the number then
  gets a `+`, e.g. `400+ files`, and because a subfolder's own capped count is added first it can overshoot, e.g.
  `612+ files`);
  if the open file is inside: `This is the open file: the editor keeps its text, unsaved.` (warning colour). Footer
  `A delete    B keep it`. While it shows, **every other input is swallowed**; A deletes, B keeps.
  Windows: `SHFileOperationW(FO_DELETE, FOF_ALLOWUNDO | FOF_NO_UI)` sends it to the Recycle Bin. **Linux/macOS: deleted
  permanently** (`os.remove` / `remove_all`), although the dialog still says Recycle Bin (README warns).
  After success: status `deleted <name> (in the Recycle Bin)` (same text on Linux); the current/previous file is cleared
  if it was inside (`g_project_dir` is not changed); the grid is re-read keeping the cursor's column and row (clamped).
  Failure: `could not delete <name>` (Windows also fails when `fAnyOperationsAborted` is set). The dialog is centred,
  680 px max wide, red outline (`COL_ERR`), with the delete icon beside the title.
- **Source**: src/app/filenav.odin `selected_entry`, `filenav_delete_ask`, `filenav_delete_confirmed`, `count_files`,
  `draw_delete_confirm`; src/app/trash_windows.odin, trash_other.odin `move_to_trash`.

### F19. Search (Y)

- **Trigger**: Y in Files.
- **Behavior**: the sheet header becomes `SEARCH` and the breadcrumb shows the root path. The list holds **every file
  under the root** (all depths up to 12, max 400 results, hidden entries skipped) whose **file name** contains the query,
  case-insensitively, each shown by its path relative to the root; an empty query lists everything. **Hold X** (pad X or
  the keyboard `x`) to dictate the query (free-text mode); `Listening...` while held; the result replaces the query.
  Line: `find: <query>   (<count>)`, placeholder `(hold X and say part of a file name)`; `(no matching files)`.
  Up/Down move with wrap; A opens the file (as F15, previous file updated) and closes Files; B (when not recording)
  returns to the grid (re-read). Hint `Up/Down move   A open   hold X say a name   B back to the folders`.
  Every Y starts a fresh search: the query is empty (cleared when search last closed) and the cursor is on row 0.
- **Rules & edge cases**: **no keyboard typing in search** (README's "Typing (file names, Files search)" row claims
  it; `handle_filenav_search` reads no typed text). Without a speech engine the query can't change. Results are
  depth-first with each folder's subfolders walked **before** its own files (`list_dir` sorts folders first, A-Z
  lower-cased, with no raw-name tie-break and an unstable sort). Up/Down/A keep working while X is held; an empty
  transcription leaves the query unchanged. The breadcrumb shows the root path (dim).
- **Source**: src/app/filenav.odin `handle_filenav_search`, `filenav_apply_filter`, `draw_search_rows`.

### F20. Files: drawing and hints (presentation)

- **Behavior**: veil, full-width sheet, header `FILES` with icon; breadcrumb `root  >  a  >  view` (dim trail, accent
  last part, with `  (+N folders)` appended when more than 200 subfolders were cut), trimmed from the front to
  `..  >  ...` when too long. Tabs in a fixed header row: folder glyph, `name/`, `+N` when capped, a green dot
  (`COL_DOT`) when the open file lives in that column (the "here" column: directly in the view; any other column:
  anywhere below that folder); the "here" tab is raised 8 px, outlined and lettered in green (`COL_ACCENT`). Cells: files
  on a sheet fill (`.odin` names in ink, others dim; the open file tinted and suffixed `  *`); folder boxes outlined in
  blue ink, `name/`. Scrolling is display-only: whole columns sideways (`<` / `>`), all rows together (`^ more` /
  `v more`). The hint line wraps to as many lines as needed:
  `D-pad move   A open / drop in   B back   X new file   LT+X rename   LT+B delete   Y search   RT+B prev file`;
  then `open: <current file path>`. Metrics (px): cell 196x34, row gap 6, column padding 8, column gap 22, tab height 32.
- **Rules**: Files' controls are fixed (not from the key layout). A flat reading-order mirror (`g_fn_entries`, tab then
  its cells, per column) exists only for trace fingerprints (`fgrid_flat_index`).
- **Source**: src/app/filenav.odin `draw_filenav`, `hint_lines`, `draw_breadcrumb`, `draw_grid`, `draw_tab`, `draw_cell`;
  test `test_fgrid_flat_index_reading_order`. Visual style: doc 10.

### F21. Run list (LT+Right), favorite, templates, run.txt

- **Trigger**: the `Run list` action (default **LT+Right**). Index reset to 0 on open (`app_requests`).
- **Behavior**: title `RUN COMMANDS`; a wrap-around grid (`grid_nav`, `grid_cols(n)` columns, cells 280x50) of the
  saved commands, then a dim `+ New command` cell. The favorite is drawn `* <cmd>`; a label too wide for its cell is
  cut with `..` (`fit_run_label`). Hint
  `D-pad move   A select   Y favorite   B back`.
  - **A on a command**: run it (F23) and close the list (closed even when the save before the run fails or a
    stb/vendor prompt takes over). **A on `+ New command`**: a template list `Choose a template:`
    (Up/Down wrap, hint `Up/Down select   A confirm   B back`) with, in order: `odin run .`,
    `odin build . -out:app.exe` (Windows) / `odin build . -out:app` (others), `odin test .`, `odin run . -debug`.
    A appends that command (not favorite) and saves; B returns to the list.
  - **Y on a command**: make it **the** favorite (all others cleared; there is always at most one; it can't be unset), save.
  - B closes. RB/LB do nothing while the list is open.
- **Persistence**: `<project folder>/.doodle/run.txt` (project folder per F8, i.e. the open file's folder). One command
  per line; a leading `*` marks the favorite (`*odin run .`); blank lines skipped; no header. Loaded lazily, once per
  project folder (`g_run_loaded`, reset by `set_project_dir`; switching folders throws away an in-memory-only seed).
  Written whenever the favorite changes or a template is added (creating `.doodle/`; a write failure is ignored
  silently). With no project folder (`g_project_dir == ""`) there is no path: nothing loads or saves.
- **Default**: if the list is empty, `odin run .` as favorite is seeded **in memory** (only saved by a later change).
- **Rules & edge cases**: commands can't be edited, deleted or typed (templates only; hand-edit run.txt otherwise);
  duplicates are allowed. Quirk (confirmed by reading the code; no test covers it): `load_run_cmds` returns at
  `if err != nil do return` before `ensure_default_run` when `run.txt` is missing (and at `path == ""`), and the only
  other caller of `ensure_default_run` is `run_favorite`. So a fresh project's Run list shows just the title and a
  centred `+ New command` (no grid, no hint; A still opens the template list) until RB / Run favorite has run once in
  that folder this session; adding a template first leaves a list with no favorite, and RB then says
  `No favorite command set` until Y marks one.
- **Source**: src/app/run.odin (`Run_Cmd`, `TEMPLATES`, `run_cmds_path`, `load_run_cmds`, `ensure_default_run`,
  `save_run_cmds`, `toggle_favorite`, `add_template`, `handle_run_input`, `draw_run_overlay`, `draw_template_submenu`);
  src/app/main.odin `app_requests` (.Run_List).

### F22. RB: run favorite; LB: run tests

- **Trigger**: **RB** / **LB** (fixed shortcuts outside the layout, doc 03 F8), only in the editor with no overlay open,
  not dictating, not picking a reference/modifier (`m.state == .Editor && !g_run_open && !g_recording && !g_stt_busy
  && !m.ref_pick_active && !m.mod_pick_active`; RB/LB edges are dropped otherwise, also in radial menus). Keyboard
  stand-ins: `r` = RB, `t` = LB. The `Run favorite` / `Run tests` actions (no default buttons) do the same through
  `app_requests`.
- **Behavior**: RB runs the favorite command (seeding `odin run .` first if the list is empty). LB runs
  `TEST_CMD = "odin test ."` with **keep-open forced on** (test output is worth reading). Both save first (F23).
- **Source**: src/app/run.odin `run_favorite`, `run_tests`, `TEST_CMD`; src/app/main.odin main loop.

### F23. The run pipeline

- **Behavior** (`run_command(cmd, keep_open)`):
  1. `keep_open |= !setting_on(.Auto_Close_Run)` (F26).
  2. **Save first** (`save_current`); if the save fails, stop (the status already says `SAVE FAILED: ...`).
  3. Working folder = `g_project_dir` (`.` if empty).
  4. `stb_run` (Linux only): if the project imports `vendor:stb...` and Odin's stb libraries aren't built, ask (F28).
  5. `vendor_run`: if an imported vendor library's shared library can't be found, ask (F27).
  6. `run_launch(cmd, dir, keep_open, lib_dirs)` -> F24 (Windows) or F25 (POSIX).
  Status after launch: `ran: <cmd>` (or the no-terminal variant). Doodle does not wait for or track the program; its
  exit code and output stay in the terminal. A trace replay never launches anything (`trace_replaying()`), but still
  sets the status.
- **The status line** (`set_status(msg, seconds = 2.0)`, run.odin; drawn in main.odin): one message slot at the top
  right of the window in accent green, shown for 2 s by default (the startup "Odin isn't installed" hint uses 8 s); a
  newer message replaces the older one immediately. Every status string in this doc goes through it.
- **Source**: src/app/run.odin `run_command`, `run_launch`; src/app/stb_build.odin `stb_run`; src/app/vendor_path.odin `vendor_run`.

### F24. Launching on Windows: a new console

- **Behavior**: one `libc.system` call (returns immediately because of `start`):
  ```
  cmd /c start "Doodle Run" cmd /c "set "PATH=<odin dir>;<lib dirs>;%PATH%" && cd /d "<dir with backslashes>" && <cmd> || pause"
  ```
  With keep-open the tail is `& pause` instead of `|| pause`: `||` pauses only when the build or program fails, `&`
  always pauses. The PATH prefix is omitted when neither an Odin folder (`odin_dir`, F29) nor library folders are known; with only
  library folders it is `set "PATH=<lib dirs>;%PATH%" && `. Odin's folder goes first so `odin` resolves even when Doodle
  was started from an environment older than the PATH change. A DLL next to the built program still wins (Windows looks
  there first).
- **Source**: src/app/run.odin `run_command_windows`.

### F25. Launching on Linux / macOS: a script in a terminal, or run.log

- **Behavior**: write `<temp>/doodle_run.sh` (`run_script_text`), then start it:
  ```sh
  #!/bin/sh
  cd '<abs project dir>' || exit 1
  PATH='<odin dir>':"$PATH"; export PATH                     # if known
  PATH="$PATH":'<doodle data>/bin'; export PATH             # if Setup's clang is installed: LAST, a real clang wins
  LD_LIBRARY_PATH='<d1>:<d2>'${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}; export LD_LIBRARY_PATH   # if lib dirs (macOS: DYLD_LIBRARY_PATH)
  printf '%s\n\n' '$ <cmd>'
  (
  <cmd>
  )
  status=$?
  if [ "$status" -ne 0 ]; then printf '\n[exit %d] Press Enter to close...' "$status"; read _; fi   # keep-open: `if true; then`
  exit $status
  ```
  The command runs in a **subshell** so an `exit`/`cd` inside it can't skip the pause. All paths are POSIX single-quoted
  (`sh_quote`: `'it'\''s'`).
  - **Terminal discovery** (`terminal_prefix`): `$DOODLE_TERMINAL` = `none` -> no terminal; any other value is used
    verbatim as the prefix (e.g. `konsole --hold -e`). macOS -> `open -a Terminal` (the script is `chmod +x`ed and
    opened directly). No `$DISPLAY` and no `$WAYLAND_DISPLAY` -> no terminal. `$TERMINAL` found on PATH -> `<it> -e`.
    Else the first found of: `konsole -e`, `gnome-terminal --`, `xfce4-terminal -x`, `kitty`, `alacritty -e`, `foot`,
    `wezterm start --`, `xterm -e`, `x-terminal-emulator -e` (konsole first: SteamOS Desktop Mode ships it).
    Launch line: `<prefix> sh '<script>' >/dev/null 2>&1 &`.
  - **No terminal**: `sh '<script>' </dev/null >'<dir>/.doodle/run.log' 2>&1 &` (stdin from /dev/null so `read` can't
    hang); status `ran (no terminal): <cmd> -> .doodle/run.log`. Script write failure: `run: couldn't write the run script`.
- **Source**: src/app/shell.odin `run_script_text`, `sh_quote`, `TERMINALS`, `terminal_prefix`, `find_in_path`;
  src/app/run.odin `run_command_posix`; tests `test_sh_quote`, `test_run_script_text`, `test_run_script_clang_dir`.

### F26. "Automatically close the run terminal" (setting)

- **Trigger**: main menu > Settings, the only option row (page mechanics and file format: doc 03 F15).
- **Behavior**: On (default): the terminal closes when the program ends normally; a failure still keeps it open
  (`|| pause` / `[ "$status" -ne 0 ]`). Off: it always waits for a key (`& pause` / `if true`). Run tests always waits.
  Explanation lines: On `Closes when the program ends (an error still keeps it open).`; Off
  `Stays open after the program ends, until you press a key.` Row label `Automatically close the run terminal`, value
  `On` (accent) / `Off` (dim); A, Left or Right toggles it, saves `doodle_settings.txt` at once (line
  `auto_close_run<TAB>on|off`) and plays the paper sound. Read at every run, so a change applies to the next run.
- **Source**: src/model/settings.odin `SETTING_INFO`; src/app/run.odin `run_command`.

### F27. Vendor libraries: "library not on your PATH" before a run

- **Trigger**: every run, after the stb check.
- **Behavior** (`vendor_needs(project dir)`): only when an Odin folder is known (`odin_dir`, F29). Read the `.odin` files
  **directly in** the project folder, collect distinct `import "vendor:..."` paths (any alias; comment lines don't
  count). For each, the library folder is `<odin>/vendor/<rest>` (`vendor:sdl2/image` -> `<odin>/vendor/sdl2/image`);
  list its shared libraries (`.dll` / `.so` and `.so.N` / `.dylib`); none -> nothing to do (static or system library).
  It is **found** if the folder is already on the search path (Windows: the user PATH in the registry
  `HKCU\Environment\Path` or Doodle's own PATH; Linux/macOS: `LD_LIBRARY_PATH`/`DYLD_LIBRARY_PATH` or a line in
  `~/.profile` naming both the variable and the folder), or every library file exists next to the program (the project
  folder) or in a searched folder (Windows: process PATH + user PATH; Linux: the variable, then `/lib`, `/usr/lib`,
  `/usr/local/lib`, `/lib64`, `/usr/lib64`, the x86_64 and aarch64 multiarch folders; macOS: `/usr/local/lib`,
  `/opt/homebrew/lib`, `/usr/lib`).
  Every needed folder is **always** added to the run's PATH / library path (F24/F25), found or not. If any is not found
  and not waved through this session, a prompt opens:
  title `LIBRARY NOT ON YOUR PATH` (Windows) / `LIBRARY NOT ON YOUR LIBRARY PATH`; one line per library
  `<import> needs <libs> - it's in <dir>, which the system can't find yet.`; then
  `Doodle adds it for this run either way. Added for good, the program also runs outside Doodle.`; choices, in order:
  1. `Add to my PATH (permanently)` (Windows) / `Add to my library path (~/.profile)`: Windows appends the folder to the
     user Path value (keeping `REG_EXPAND_SZ` and `%VARS%`; new value type `REG_EXPAND_SZ` if none existed), then
     broadcasts `WM_SETTINGCHANGE "Environment"` (2 s timeout). Linux appends
     `export LD_LIBRARY_PATH="<dir>${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"  # added by Doodle for <import>` to `~/.profile`
     (once; a newline added first if the file didn't end in one). Then runs. Status = the joined messages:
     `added <dir> to your PATH (new terminals and programs see it)` / `<dir> is already on your PATH` /
     `couldn't change your PATH`; `added <dir> to ~/.profile (applies from your next login)` /
     `<dir> is already in ~/.profile` / `no home folder to add it to` / `couldn't write ~/.profile`.
  2. `Just this run`: remember the folders (session only, never asked again until restart) and run.
  3. `Cancel` (also B): status `run cancelled`.
  Footer `D-pad move   A choose   B cancel`; Up/Down wrap. The prompt draws over everything and owns all input.
- **Rationale**: commit c1bac1b: a Windows program missing `SDL3.dll` exits with no window and no output. Doodle's own
  environment predates a PATH change, so the run always gets the folders directly.
- **Source**: src/app/vendor_path.odin (`vendor_needs`, `lib_findable`, `vendor_run`, `VP_CHOICES`,
  `handle_vendor_prompt_input`, `draw_vendor_prompt`); vendor_path_windows.odin / vendor_path_other.odin
  (`lib_dir_on_path`, `lib_search_dirs`, `user_path_add`); src/model/vendor_libs.odin; tests `test_vendor_imports`,
  `test_is_shared_lib`, `test_path_lists`, `test_profile_lines`.

### F28. stb libraries (Linux): "STB LIBRARIES NOT BUILT YET" before a run

- **Trigger**: a run on Linux of a project whose top-level `.odin` files import `vendor:stb` or `vendor:stb/...` while
  `<odin root>/vendor/stb/lib/` has no `*.a`.
- **Behavior**: prompt titled `STB LIBRARIES NOT BUILT YET`:
  `This project imports vendor:stb. Odin's Linux release has stb as C source only:` /
  `it has to be built once into <root>/vendor/stb/lib before anything using it can build.`; note
  `Building takes a few seconds and shows in the run's window.` or, with no C compiler,
  `It needs a C compiler - install one first: main menu > Settings > Setup > clang.` Choices: `Build them now (once)`
  -> the run command becomes `sh '<root>/vendor/stb/src/build_stb.sh' && <cmd>` (same window, run only if the build
  worked); `Run anyway` (asked again next time); `Cancel`/B -> `run cancelled`. Then continues to F27. Up/Down wrap
  over the three choices (starting on the first); footer `D-pad move   A choose   B cancel`; the prompt owns all input
  and is drawn last, over everything. The "no C compiler" test is `toolchain_bin() == "" && !find_in_path("cc")`.
  The check needs `odin_root()` (so PATH counts here, unlike F27) and is skipped when it is empty.
- **Rationale**: odin check/build of any vendor:stb user fails ("Could not find the compiled STB libraries") until
  build_stb.sh has run once; a newer Odin unpacked over the old one starts without them (stb_build.odin header).
- **Source**: src/app/stb_build.odin (`stb_needed`, `stb_built`, `stb_build_command`, `stb_run`, `SB_CHOICES`,
  `handle_stb_prompt_input`, `draw_stb_prompt`); test `test_stb_build_command`.

### F29. Finding the toolchain

- **Behavior**: `odin_dir()` returns the first folder that contains `odin.exe`/`odin`, in this order: `$ODIN_DIR`,
  `$ODIN_ROOT`, `<exe dir>/toolchain/odin`, `<exe dir>/../toolchain/odin`, `<data dir>/odin` (Setup's install, F31),
  then `C:\Odin` (Windows) or `~/odin`, `~/Odin`, `/opt/odin` (others). `""` = rely on PATH (`odin_exe()` then returns
  plain `odin`). `odin_root()` = `odin_dir()`, else the first PATH entry holding the compiler. The **data dir** is
  `%LOCALAPPDATA%\doodle` (Windows) or `$XDG_DATA_HOME/doodle`, else `~/.local/share/doodle`.
- **Rationale**: Game Mode on the Deck doesn't read `~/.bashrc` / `~/.profile`, so a PATH set there never reaches Doodle.
- **Who uses which lookup**: the Run line / run script and the vendor check use `odin_dir()` (F24, F25, F27); the
  background `odin check` uses `odin_exe()` (checker.odin); the Setup rows, the startup hint, the stb check and the
  Zig script's stb step use `odin_root()`. A **third, separate** lookup, `model.odin_root` in
  src/model/collections.odin (`$ODIN_ROOT`, then PATH split with `os.split_path_list`, i.e. the right separator, else
  the literal `C:/Odin`), feeds the docs panel and the `shared:` collection list (doc 07). It does not know Setup's
  `<data dir>/odin` or the other `odin_dir` candidates, so with only Setup's Odin installed those features look in
  `C:/Odin` (unverified at runtime; code reading).
- **Rules**: `odin_root` (stb_build.odin) splits PATH on `:` on every OS. On Windows a PATH such as
  `C:\Odin;C:\Windows` splits into `C`, `\Odin;C`, `\Windows`, so no entry ever matches and `odin_root()` equals
  `odin_dir()` (confirmed by reading; not observed live): an Odin reachable only through PATH reads as missing in
  Setup (`Install`) and triggers the startup hint, while Runs and `odin check` still work because they fall back to
  plain `odin`. `find_in_path` also splits on `:`, but it is only called on POSIX code paths. README's Windows order
  ("Doodle's own install, then PATH, then C:\Odin") differs from the code (env vars, bundled toolchain, Setup's
  install, `C:\Odin`, then PATH); its Deck order lists Setup's install first, but the code tries `$ODIN_DIR`,
  `$ODIN_ROOT` and the bundled `toolchain/odin` folders before it.
- **Source**: src/app/shell.odin `odin_dir`, `odin_exe`, `find_in_path`; src/app/stb_build.odin `odin_root`;
  src/app/setup.odin `setup_data_dir`; src/app/toolchain.odin `toolchain_home`; src/model/collections.odin
  `odin_root`.

### F30. Settings > SETUP: the page

- **Trigger**: main menu > Settings (rows below the option rows, under a `SETUP` heading). Not reachable from the editor.
- **Behavior**: rows for this OS, in order (`setup_items`): `Doodle`, `Odin compiler`, `Microsoft C++ Build Tools`
  (Windows), `clang (to build and run programs)` (Linux), `Odin's stb libraries` (Linux), `Speech-to-text`. Each row:
  label left, a short **value** right, one explanation line under it. Value colour by look: Good = accent,
  Missing/Bad = red, Busy/Info = dim. **A** on a row runs its action (installs/updates on worker threads; the page polls
  their atomic state every frame and shows progress by stat'ing the partial download). Up/Down wrap across option and
  setup rows; Left/Right toggle option rows only (they do nothing on setup rows); B closes (back to the main menu).
  Page title `SETTINGS`; the page opens on row 0. Footer `D-pad move   A switch / install   B back`.
  A on a row that has nothing to do (Odin found, Build Tools found or still checking, stb built, Speech) does nothing.
  Install jobs refuse during a trace replay with status `not during a replay`. Opening the page and every frame while open
  calls `setup_refresh`: the update check once per session, the clang state, and (Windows) a Build Tools re-check at most
  every 4 s, so an install finished meanwhile turns into `Found`.
- **Startup hint**: if `odin_root()` is empty, the status line shows
  `Odin isn't installed: main menu > Settings > Setup can install it` for 8 s at startup.
- **Source**: src/app/setup.odin (`Setup_Item`, `setup_items`, `SETUP_LABELS`, `setup_refresh`, `setup_action`,
  `setup_row`, `Setup_Look`, `setup_missing`); src/app/settings.odin `handle_settings_input`, `draw_settings_page`;
  test `test_setup_items`.

### F31. Setup: Odin compiler (download, verify, install)

- **Behavior**: pinned release `ODIN_TAG = "dev-2026-11"` with per-platform asset, SHA-256 and byte size compiled in
  (`odin-windows-amd64-dev-2026-11.zip`, `odin-linux-amd64-...tar.gz`, `odin-linux-arm64-...tar.gz`), URL
  `https://github.com/odin-lang/Odin/releases/download/<tag>/<asset>`. Offered on Windows and Linux only.
  Steps on a thread (`odin_job_main`): `curl -fL --retry 2 -o <data>/<asset>.part <url>` (the system curl; on Windows
  the one in System32), output to `install-odin.log`; **SHA-256 must equal the pinned hash** (else delete and fail);
  unpack with the system `tar` into `<data>/odin.new` (Windows' bsdtar unpacks zip; System32's tar is used because Git's
  GNU tar reads `C:` as a remote host); delete the `.part`; find the compiler at the top of `odin.new` or in its first
  subfolder that holds one; then `os.remove_all(<data>/odin)` **followed by** `os.rename(<found>, <data>/odin)`. That
  is delete-then-rename, not an atomic swap: if the rename fails, the old install is already gone. On Linux, then build
  the stb libraries (`stb_build_run`, result ignored) if `toolchain_bin()` or a `cc` on PATH exists. Success sets the
  job back to idle; the row then shows `Found` because `odin_root()` now finds `<data>/odin`.
  Row: `Found` / `In <root>`; `Install` / `Not found: problem highlighting and Run are off. A downloads Odin dev-2026-11 (<MB> MB) into <data>.`
  (`<MB>` = bytes >> 20: 154 on Windows, 72 on Linux x64, 70 on Linux arm64);
  while working `<pct>%` / `Downloading Odin dev-2026-11: <x> of <y> MB`, or `Working...` / `Starting the download...`
  (nothing on disk yet, and again briefly after the `.part` is deleted) / `Checking and unpacking...` (the `.part` is
  complete); `Failed` / `<reason>   A: try again`. Row order of checks: Working, then Found, then Failed, then
  (macOS) Missing, else Install. Failure reasons:
  `download failed: <last log line> (log: <path>)`, `the download didn't match Odin's published checksum - try again`,
  `unpacking failed: ...`, `the download had no Odin compiler in it`, `couldn't move it into <path>`,
  `no user folder to install into`. macOS: `Missing` / `Install Odin from odin-lang.org and put it on PATH: problem highlighting and Run need it.`
  A does nothing once found or while working; on `Failed` it tries again.
- **Rationale**: install exactly the compiler Doodle is built and tested with (kept in step with the release workflow's
  `ODIN_TAG`).
- **Source**: src/app/setup.odin `ODIN_*`, `setup_install_odin`, `odin_job_main`, `sha256_file`, `sys_tool`, `run_logged`,
  `Job`; test `test_sha256_file`.

### F32. Setup: Microsoft C++ Build Tools (Windows)

- **Behavior**: detection on a thread: `vswhere.exe -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`
  (vswhere at `%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\`), output via `<data>/vswhere.txt`. A when missing:
  if winget exists (`%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe`), open a new console titled
  `Doodle setup: C++ Build Tools` running `winget install --id Microsoft.VisualStudio.BuildTools -e --source winget --override "--passive --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"`,
  then `Done - you can close this window.` and pause (the license and admin prompts stay the user's); else open
  `https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio`. Status
  `Microsoft's installer is open in its own window` / `opened the Build Tools download page`.
  Row: `Checking...` / `Looking for Microsoft's C++ linker and the Windows SDK...`; `Found` / `In <path>`;
  `Install` / `Not found: Run and Build can't link programs (problem highlighting still works). A opens Microsoft's installer (about 3 GB).`;
  after opening: `Installing...` / `Finish Microsoft's installer in its window; this turns to Found when it's done.`
  No vswhere.exe (or no `%LOCALAPPDATA%`) counts as missing. The check is re-run by `setup_refresh` whenever it has
  never run or the last one started more than 4 s ago, while the Settings page is open. `Installing...` is a
  session-only flag (`g_bt_opened`); A on it opens the installer again (A acts whenever the last check said missing).
  Neither the check nor the install runs during a trace replay.
- **Source**: src/app/setup.odin `bt_check`, `bt_check_main`, `bt_vswhere`, `setup_install_build_tools`, `BT_WINGET_ID`,
  `BT_COMPONENT`.

### F33. Setup: clang via Zig (Linux / Steam Deck)

- **Behavior**: Odin's Linux release links through `clang`, which SteamOS lacks (and its root is read-only). Zig's single
  download contains a complete clang (`zig cc`) needing no root and no system headers. State: `Installed` (ours present:
  `<data>/bin/clang` and `<data>/zig/zig`), `System` (a clang on PATH), `Missing`, `Working`, `Failed`.
  (`toolchain_refresh` decides Installed / System / Missing each time the page refreshes, except while Working; ours
  wins over a system clang.)
  A when Missing/Failed (also Unknown) writes `<data>/install-clang.sh` and runs it on a thread
  (`sh script >install-clang.log 2>&1`): `cd <data>`;
  `set -eu`; `curl -fL --retry 2 -o zig.tar.xz.part <url>`; `echo '<sha>  zig.tar.xz.part' | sha256sum -c -`
  (a mismatch stops the script; unlike the Odin install, the `.part` is **left on disk** and the reason shown is
  `sha256sum`'s last output line, not a fixed sentence);
  unpack into `zig.new` (`--strip-components=1`), then `rm -rf zig && mv zig.new zig` (a failure halfway leaves the old
  install or nothing, never a broken one); write `bin/cc` (a `zig cc` wrapper) and `bin/ar` (`zig ar`), copy `cc` to
  `clang`, `chmod +x`, `./bin/clang --version`; then, optionally and non-fatally, build Odin's stb libraries with these
  tools. The `cc` wrapper rewrites Odin's `-l:/abs/path/lib.a` into the path (zig refuses absolute `-l:`), and splits
  `-c a.c b.c` without `-o` into one `zig cc` per source (zig would only write a.o).
  Runs get `<data>/bin` **appended** to PATH (F25). Pinned: Zig `0.17.1`, x86_64 and aarch64 URLs, SHA-256 and sizes.
  Row: `Install` / `SteamOS has no clang, which Odin needs to build and run programs. A downloads Zig 0.17.1's clang (about 57 MB) into <data>.`;
  `Found` / `clang is already installed: Run builds and runs programs.`; `Installed` / `Zig 0.17.1's clang, in <data>/bin (Runs use it; add that folder to PATH to use it outside Doodle).`
  (+ ` Odin's stb libraries are built too.`); progress `Working...` / `Starting the download...`, then
  `<pct>%` / `Downloading Zig 0.17.1: <x> of <y> MB`, then `Working...` / `Downloaded <n> MB; unpacking...`;
  `Failed` / `<reason>   A: try again`, where reason is `<last log line> (log: <path>)` (or `the install failed (log: ...)`
  for an empty log), `couldn't write the install script` or `no home folder to install into`. The install counts as
  done only when the script exits 0 **and** `toolchain_bin()` finds both files. The "about 57 MB" text is fixed, also
  on arm64 (52,977,364 bytes there). Look: Installed/System = Good, Working = Busy, Failed = Bad, else Missing.
- **Source**: src/app/toolchain.odin (all); tests `test_toolchain_script`, `test_toolchain_script_builds_stb`.

### F34. Setup: stb libraries, Speech-to-text rows

- **stb (Linux)**: `-` / `Install Odin first.`; `Building...` / `Building them in <root>/vendor/stb/lib`; `Built` /
  `Programs that import vendor:stb (image, truetype, ...) can build.`; `Failed` / `<msg>   A: try again`; no C compiler:
  `Not built` / `Programs that import vendor:stb can't build yet. Install clang first, then A builds them.`; else `Build`
  / `Programs that import vendor:stb can't build yet. A builds them (a few seconds).` A (only when Odin is found and the
  libraries aren't built) runs `sh <root>/vendor/stb/src/build_stb.sh` (Setup's bin folder appended to PATH) into
  `<data>/build-stb.log` on a thread; it fails with `<last log line> (log: <path>)` when the script exits non-zero or
  no `*.a` appeared, or `Odin isn't installed`. Looks: `-` = Info, Building = Busy, Built = Good, Failed = Bad,
  Not built / Build = Missing.
- **Speech-to-text**: info only. `Ready` / `Hold Talk to dictate names, numbers, strings and comments.` or `Not set up`
  / `whisper-cli or its model isn't next to Doodle (they come with the release), or there's no microphone.` (doc 08).
- **Source**: src/app/setup.odin `setup_build_stb`, `stb_job_main`, `stb_build_run`, `setup_row`.

### F35. Setup: Doodle updates itself

- **Behavior**: an installed release has `<root>/VERSION` (one line, e.g. `0.3.0 (abc1234, Odin dev-2026-11, whisper.cpp v1.9.5 base.en, linux-x64 ubuntu-22.04)`,
  a UTF-8 BOM tolerated: the Windows package writes it with PowerShell's `Out-File -Encoding utf8`) next to
  `<root>/bin/doodle(.exe)`; `<root>` = the executable's folder + `/..`. The workflow writes
  `<version> (<sha7>, Odin <ODIN_TAG>, whisper.cpp <WHISPER_TAG> <model>)` for SteamOS, with `, linux-x64 ubuntu-22.04`
  appended for the Linux package and `, windows-x64` for Windows. The installed version is the text before the first
  space. No VERSION (or an empty one) = a build from source: row `From source` /
  `A build from source: update it with git pull, then build.sh / build.bat.` (no action, look Info).
  - **Check** (once per session when Settings opens; again on A when Idle/Current/Failed): fetch
    `https://api.github.com/repos/MichJadams/doodle/releases/latest` with curl to `<data>/latest-release.json`, parse
    `tag_name` and `assets[]{name, browser_download_url, digest ("sha256:<hex>"), size}`. The wanted asset:
    `doodle-windows.zip` on Windows; else `doodle-linux.tar.gz` if the VERSION line contains `ubuntu`, else
    `doodle-steamos.tar.gz`. `v<installed version>` == `tag_name` -> Current, else Available.
  - **Install** (A when Available): download next to the install (`<parent>/.doodle-update.download`, same disk so the swap
    is a rename), check the SHA-256 against the digest (skipped if the release gave none), unpack into
    `<parent>/.doodle-update`, find the folder containing `bin/doodle(.exe)`.
    **Linux/SteamOS**: copy the four settings files from the old `bin/` into the new one, rename `<root>` to
    `<parent>/.doodle-old`, rename the new one to `<root>` (on failure rename the old one back), delete the old one ->
    Ready (`Restart` / `<tag> is installed. A quits Doodle; start it again to use it.`; A quits).
    **Windows** (a running exe and its DLLs can't be overwritten): Staged (`Restart` /
    `<tag> is ready. A closes Doodle, puts it in place and starts it again.`). A writes `<parent>/.doodle-update.cmd`
    (CRLF lines, `@echo off`): wait in a 1 s loop (`tasklist /FI "PID eq <pid>" | find "<pid>"` then
    `timeout /t 1 /nobreak`) until Doodle's PID is gone, `robocopy <new> <root> /E /R:10 /W:1 /NFL /NDL /NJH /NJS`
    (no `/PURGE`: files not in the package, i.e. the settings, stay), `rmdir /s /q <folder containing new>` (normally
    `<parent>/.doodle-update`; see Open questions for the case where the archive has no top folder),
    `start "" <root>\bin\doodle.exe`, then delete itself (`(goto) 2>nul & del "%~f0"`); started minimized with
    `start "" /min cmd /c "<script>"`, then Doodle quits (`want_quit`, no save prompt).
    The download log `<parent>/.doodle-update.log` is deleted after a successful unpack.
  - Row strings: `Check` / `Version <v>. A checks GitHub for a newer release.` (Info); `Checking...` /
    `Version <v>. Asking GitHub for the latest release...` (Busy); `Up to date` /
    `Version <v> is the latest release.` (Good); `Update` / `Version <v>; <tag> is out. A downloads it (<MB> MB) and installs it.`
    (Missing look = red); progress `<pct>%` / `Downloading <tag>: <x> of <y> MB`, else `Working...` /
    `Starting the download...` or `Checking and unpacking <tag>...` (Busy); `Restart` (Good); `Failed` /
    `<msg>   A: try again` (Bad) with
    `couldn't reach GitHub (no internet?)`, `GitHub's answer didn't make sense`, `the latest release (<tag>) has no <asset>`,
    `this isn't an installed release`, `the download failed (no internet?)`,
    `the download didn't match the release's checksum - try again`, `unpacking the update failed`,
    `the update had no Doodle in it`, `couldn't move <root> aside`, `couldn't put the new version in <root>`,
    `couldn't write the update script`. A while Checking/Working does nothing. A trace replay never checks and refuses
    to install (`not during a replay`).
- **Source**: src/app/updater.odin (all); src/app/pid_*.odin `current_pid`; tests `test_update_version_and_asset`,
  `test_update_new_root_in`, `test_update_swap_in`, `test_update_windows_script`.

### F36. Distribution and the Steam Deck

- **Release packages** (.github/workflows/release-steamos.yml, manual `workflow_dispatch` with `version`, `prerelease`,
  `run_tests`, `publish`): one version for all (`<input>` or `YYYY.MM.DD-<sha7>`, tag `v<version>`). Three builds:
  SteamOS (inside Valve's Steam Linux Runtime 3.0 "sniper" SDK container), Linux (Ubuntu 22.04, glibc 2.35), Windows x64.
  Each runs `odin test src/model` and `odin test src/stt` (when `run_tests` is on), builds
  `odin build src/app -o:speed -no-bounds-check -define:DOODLE_TRACE=false` and fails if the trace recorder is compiled
  in (the binary contains the string `doodle-trace 1`). The Windows job also fails if `doodle.exe` or `whisper-cli.exe`
  imports a DLL that is neither bundled nor part of Windows, or any VC++ runtime DLL (`dumpbin /dependents`).
  With `publish` off the packages stay as run artifacts; `prerelease` marks the GitHub Release. Layout: `doodle/bin/doodle(.exe)` + bundled SDL2 (Linux: rpath `$ORIGIN`, plus
  SDL3 for the runtime's sdl2-compat) + `whisper-cli` (static, AVX2 without AVX-512, smoke-tested on a sample),
  `doodle/models/ggml-base.en.bin` (SHA-256 checked), `doodle/assets/`, `doodle/licenses/`, `doodle/VERSION`. Assets are
  attached versioned and under fixed names (`doodle-steamos.tar.gz`, `doodle-linux.tar.gz`, `doodle-windows.zip`) so
  `.../releases/latest/download/<name>` always works.
- **Deck install** (`tools/deck_install.sh [tag]`, or `curl -fsSL .../tools/deck_install.sh | bash` in Desktop Mode):
  download the SteamOS package (latest or the tag) to a temp dir, check `doodle/bin/doodle` is executable, keep the four
  settings files from the old `bin/`, replace `${DOODLE_DIR:-~/Applications/doodle}`, restore the settings files, print
  `Installed <VERSION> -> <dest>/bin/doodle`. It verifies **no checksum** (unlike the in-app updater), and "latest" is
  GitHub's `releases/latest`, which skips pre-releases. Then add `bin/doodle` to Steam as a non-Steam game (Game Mode
  and Steam Input), and use Settings > Setup to install Odin and clang.
- **Deck differences** (README table, confirmed in code where noted): projects in `~/DoodleProjects` (not the install
  folder); toolchain found without shell profiles (F29); clang via Zig (F33); stb built for you (F28/F33); runs open in
  `konsole` or the first terminal found, else `.doodle/run.log` (F25); "Press Enter to close" needs the on-screen
  keyboard (Steam+X); deletes are permanent (F18); "Add to my library path" writes `~/.profile`, which Game Mode doesn't
  read, so choose "Just this run" there (F27); settings files next to `bin/doodle` survive reinstalls; no keyboard means
  dictation for names and search.
  README-only user notes (nothing in code implements or checks them, but a port's README should keep the same advice):
  the first build after installing Zig's clang takes longer while Zig prepares its C library; in Game Mode the clipboard
  that Copy (RT+A / Ctrl+C) writes may not reach other apps; New Project's folder browser starts in the home folder
  (F4; the README's "starts at `/`" is stale) and the SD card is under `/run/media/...`; the Deck's back buttons
  (L4/R4/L5/R5) are not used; speech-to-text works with the Deck's microphone but is slower than on a desktop PC, which
  is why editor dictation runs in the background (doc 08 F8); launched from outside Steam, Steam's desktop layout turns
  the triggers and trackpads into mouse clicks and Doodle may see no gamepad, so add it to Steam even for Desktop Mode.
- **Build from source**: `build.bat` / `build.sh` (`run` (build.bat: `run [file.odin]`), `test`, `release`,
  `replay [trace]`; no argument = debug build); build.bat prepends `C:\Odin` to PATH when `odin` isn't on PATH, and copies `SDL2.dll` from
  `odin root`'s `vendor\sdl2` into `bin\` when it isn't there yet. Debug builds record traces; `release` passes
  `-define:DOODLE_TRACE=false`.

### F37. Persistence files (shared conventions) and doodle_roots.txt

- **Files next to the executable** (`heat_exe_dir`: the OS's executable path, else `argv[0]` made absolute):
  `doodle_keys.tsv`, `doodle_heat.tsv` (doc 03), `doodle_settings.txt` (doc 03), `doodle_roots.txt` (this area). They
  are the `KEEP_FILES` the updater and deck_install.sh carry across.
- **Conventions** (all four):
  1. First line is a versioned header `doodle-<kind> 1`.
  2. Missing file = defaults, silently.
  3. File exists but can't be read (one retry after 50 ms: another Doodle may be renaming it) -> defaults and **never
     save** this session (`g_*_nosave`), with a once-per-session status warning (settings also prints it to stderr).
     No executable folder -> no path -> never saved. A roots save failure isn't warned on its own; New Project
     appends ` (only until Doodle closes: doodle_roots.txt can't be saved)` to its status instead (F3); settings warns
     `could not save the settings (doodle_settings.txt)`.
  4. A header of another version -> treated as a newer format: defaults, never overwritten, warned once. (Keys, heat
     and roots only look at a first line starting with `doodle-<kind>`, so a headerless hand-written file is accepted;
     settings is stricter: its first non-blank line must be exactly the header.)
  5. Saves write `<file>.tmp`, then rename it over the file (replace-existing rename); a failed rename deletes the tmp.
  6. Keys, roots and settings save right after every change; heat is throttled and merged (doc 03).
  7. Failures never stop the editor; a trace replay pins the contents and never writes.
- **doodle_roots.txt**: header `doodle-roots 1`, then one folder per line in the order added. Parse: blank lines,
  the header and `#` comments skipped, each line trimmed, repeats of the same folder dropped (`roots_same`: slash style
  and a trailing slash ignored; case-insensitive on Windows only). `roots_text_ok`: the first non-blank line, if it
  starts with `doodle-roots`, must be exactly the header; a headerless hand-written file is accepted. The default folder
  is never written into the file by Doodle (`roots_add` returns `Is_Default`), and entries are written back exactly as
  added (no normalization; `C:/work/odin` and `D:\games` can sit side by side). Warnings: `could not read the project folders list (doodle_roots.txt)`,
  `doodle_roots.txt is from a newer Doodle; extra project folders are off`.
  ```
  doodle-roots 1
  C:/work/odin
  D:\games
  ```
- **Project-local files**: `<folder>/.doodle/run.txt` (F21, no header) and `<folder>/.doodle/run.log` (F25).
- **Other per-user data** (`<data dir>`): `odin/`, `zig/`, `bin/`, install scripts and logs, `vswhere.txt`,
  `latest-release.json`. Update scratch next to the install: `.doodle-update.download`, `.doodle-update/`,
  `.doodle-update.log`, `.doodle-old`, `.doodle-update.cmd`.
- **Source**: src/app/roots_store.odin; src/model/project_roots.odin; src/app/keys_store.odin, heat_store.odin,
  settings.odin (same pattern); src/app/updater.odin `KEEP_FILES`; tests in project_roots_test.odin.

## Invariants & constraints to carry forward

1. **HARD** — No path is ever typed. Projects are created with a generated name in a chosen root; folders are added with
   a d-pad folder browser; file names come from dictation or an optional keyboard and are always cleaned to a safe name
   (no separators, no leading dots) before touching the disk. Enforced by `clean_filename` / `clean_rename`, pinned by
   `test_clean_filename` (`../../evil/path` -> `evilpath.odin`) and `test_clean_rename`. (Only a hand-edited
   `doodle_roots.txt` puts a typed path into Doodle.)
2. **HARD (for the port; Doodle has holes)** — Nothing is overwritten without a second A: Save as asks before replacing
   another file; rename refuses an existing name; delete always asks; the updater swaps a complete new copy in by rename
   and puts the old one back on failure (`swap_in`, pinned by `test_update_swap_in`); the Zig install unpacks beside the
   old copy (`test_toolchain_script` pins the order). Enforced only in app code, not pinned for the dialogs. Known
   holes to **fix** in the port, not copy: plain Save writes `<folder>/main.odin` without checking that it exists
   (after deleting the open file, or on a generated-name collision; F9); the dialogs' `same_path` folds case on Linux
   too (F10, F17); the Odin install deletes `<data>/odin` before renaming the new one in (F31).
3. **HARD** — Every download Doodle itself makes is checked against a SHA-256 pinned in the source (Odin:
   `sha256_file` == `ODIN_SHA256`; Zig: `sha256sum -c` in the install script, pinned by `test_toolchain_script`) or
   published by the release (updater; skipped only if the release has no `digest`). Odin and the updater delete the
   download on a mismatch and report `... didn't match ... - try again`; the Zig script stops and leaves its `.part`,
   reporting `sha256sum`'s output line. `tools/deck_install.sh` (outside the app) checks nothing; the port should
   checksum there too.
4. **HARD** — A run always saves first and runs exactly what's on screen; a failed save aborts the run
   (`run_command`: `if g_app != nil && !save_current(g_app) do return`; app layer, no test). The prompts of F27/F28
   come after the save, so a cancelled run has still saved.
5. **HARD** — A failed run never vanishes: the terminal stays open on a non-zero exit (and always for tests, or when the
   setting is off); with no terminal the output goes to `.doodle/run.log`. The POSIX script is pinned by
   `test_run_script_text` (`if [ "$status" -ne 0 ]` / `if true`); the Windows `|| pause` / `& pause` line is not
   tested. Not covered: a terminal from `$DOODLE_TERMINAL`/`$TERMINAL` that fails to start (its output goes to
   `/dev/null`).
6. **HARD** — The run's own environment always gets what it needs (Odin first on PATH when `odin_dir` found it,
   Setup's clang last, vendor library folders), independent of Doodle's possibly stale environment; permanent PATH edits
   are optional and asked. Pinned for POSIX by `test_run_script_text` and `test_run_script_clang_dir`; PATH-list edits
   by `test_path_lists`, `test_profile_lines`.
7. **HARD** — File grid movement is a pure function of the grid and the press (no window size), rows line up across
   columns, `want_row` survives short and empty columns, Down/Up never wrap, Left at the first column goes up a level
   (file_grid_test.odin: `test_fgrid_move_keeps_row`, `test_fgrid_tabs`, `test_fgrid_edges`,
   `test_fgrid_row_survives_empty_column`).
8. **HARD** — B in Files undoes exactly the drop-ins (descent counter; a failed drop-in is not counted; at the top the
   count resets so B can always get out). Enforced in filenav.odin `fn_descend` / `fn_up_level` (app layer); only the
   model half is pinned (`test_fgrid_descend_refuses_unreadable`). Left at the first column also pops a descent.
9. **HARD** — The folder you stand in ("here" tab) can't be dropped into or deleted from inside itself; it can be
   renamed unless it is a projects root or a drive root (`fgrid_descend` returns not-ok for the here tab,
   `test_fgrid_descend_shows_sisters`; `selected_entry` and `rename_target` refuse in filenav.odin).
10. **HARD** — The four persistence files next to the executable (F37) are versioned, never overwritten when
    unreadable or newer, written tmp + rename, and survive updates and reinstalls (`test_roots_text_ok`,
    `test_roots_serialize_round_trips` and the keys/settings/heat equivalents; `test_update_swap_in`). `run.txt` is
    not one of them: no header, plain overwrite.
11. **HARD (for the port; true only for the grid in Doodle)** — Ordering is deterministic so traces replay identically:
    the file grid sorts case-insensitive A-Z with a raw-name tie-break (pinned by
    `test_fgrid_here_column_and_stable_sort`), and the merged Recent Projects list is stable-sorted newest first.
    Doodle's Files search (`list_dir`), the folder browser and each root's project list sort without a tie-break using
    the unstable `slice.sort_by`; give every list a total order in the port.
12. **SOFT** — Projects live in the home folder, never in the install folder; per-user tool installs need no root.
13. **SOFT** — Every overlay names its own controls in a footer and owns all input while open; only the top overlay
    reacts (input routing order in main.odin: stb prompt, vendor prompt, save/rename dialog, Files, Key Layout,
    Settings, Recent Projects, New Project, docs, then editor + run list). Exception in Doodle: the Run list with no
    commands (F21) shows no hint. Push-to-talk dictation into the editor is off while any overlay is open
    (`overlay_open`).
14. **SOFT** — Status messages say what happened and the next step (`saved main.odin in <folder> - rename it in Files (LT+X)`).
15. **SOFT** — Hidden (dot) entries are never shown in Files, search or the folder browser; app state lives in `.doodle/`.

## Data model & formats

- `File_Grid` = { view (owned path), groups: [Fgrid_Group], more_groups, group, item (-1 = tab), want_row (-1 = tab row),
  descents }. `Fgrid_Group` = { title, path, here, unreadable, items: [Fgrid_Item{name, path, is_dir}], more }.
  `Fgrid_Move` = None | Moved | Up_Level. The disk is behind an injectable lister
  `proc(dir) -> (entries, ok)`; tests pass fake trees.
- `Project` = { name (folder), dir, file (to open), mtime (newest .odin) }.
- `Roots_Add_Result` = Added | Empty | Is_Default | Duplicate.
- `Run_Cmd` = { cmd, favorite }. run.txt: `[*]<command>\n` per line.
- `Vendor_Need` = { import_path, dir, libs, found }. `Lib_OS` = Windows | Linux | Darwin.
- `Setup_Item` = Doodle | Odin | Build_Tools | Clang | Stb | Speech. `Setup_Look` = Good | Missing | Busy | Bad | Info.
- `Tc_State` (clang, also reused by install jobs) = Unknown | System | Installed | Missing | Working | Failed (atomic i32).
- `Up_State` (updater) = Idle | Checking | Current | Available | Working | Ready | Staged | Failed (atomic i32).
- Overlay state is a set of app globals with one "open" flag each (`g_np_open`, `g_proj_open`, `g_filenav`,
  `g_save_open` + `g_save_rename`, `g_run_open` + `g_run_submenu`, `g_vp_open`, `g_sb_open`, `g_settings_open`).
- Formats: `doodle_roots.txt` (F37), `.doodle/run.txt` (F21), the POSIX run script (F25), the Windows run line (F24),
  `~/.profile` line (F27), the Windows updater script (F35), VERSION line (F35/F36), GitHub release JSON (F35).

## Tests that pin this behavior

| Test (file) | Pins |
|---|---|
| `test_fgrid_build_columns` (file_grid_test) | no "here" column without own files; files then boxes per column |
| `test_fgrid_here_column_and_stable_sort` | here column; `A.odin` < `a.odin` < `main.odin`, stable over rebuilds |
| `test_fgrid_move_keeps_row`, `test_fgrid_row_survives_empty_column` | want_row across short/empty columns; tab-row walking only after Up |
| `test_fgrid_tabs`, `test_fgrid_edges` | Up to tab, no wrap at bottom, Left at first column = Up_Level, empty grid |
| `test_fgrid_descend_shows_sisters`, `test_fgrid_descend_refuses_unreadable` | drop-in view/focus; here tab and files don't descend; unreadable refused |
| `test_fgrid_up_focuses_old_view`, `test_fgrid_parent_of_stops_at_top` | up selects the folder left; `/`, `C:/`, relative tops |
| `test_fgrid_keeps_here_column_on_rebuild` | empty here column kept on same-view rebuild only |
| `test_fgrid_view_for`, `test_fgrid_project_root`, `test_fgrid_target_dir` | starting view, project root, where X creates |
| `test_fgrid_select_path_ignores_case_and_slashes`, `test_fgrid_caps_long_columns`, `test_fgrid_title_at_the_top`, `test_fgrid_flat_index_reading_order`, `test_fgrid_build_climbs_from_gone_view` | path matching, 400 cap, `C:` titles, trace index, climbing |
| `test_list_projects_newest_first_and_skips_unsaved`, `test_list_projects_missing_root`, `test_age_label` (projects_test) | project detection, main.odin preference, ages |
| `test_clean_filename`, `test_clean_rename` (projects_test) | name cleaning (`../../evil/path` -> `evilpath.odin`) and extension rules |
| `test_roots_parse_...`, `test_roots_serialize_round_trips`, `test_roots_text_ok`, `test_roots_add`, `test_list_projects_in_merges_roots_newest_first` (project_roots_test) | roots file format, dedupe per OS, add results, merged listing |
| `test_vendor_imports`, `test_is_shared_lib`, `test_path_lists`, `test_profile_lines` (vendor_libs_test) | import scan, library names, PATH list edits, ~/.profile line |
| `test_sh_quote`, `test_run_script_text`, `test_run_script_clang_dir` (src/app/shell_test) | quoting, script shape, keep-open, clang folder last |
| `test_toolchain_script`, `test_toolchain_script_builds_stb`, `test_stb_build_command`, `test_sha256_file`, `test_setup_items` | install script steps in order, stb step, checksum helper, rows per OS |
| `test_update_version_and_asset`, `test_update_new_root_in`, `test_update_swap_in`, `test_update_windows_script` | updater parsing, unpack root, Linux swap keeps settings, Windows script order |
| `test_new_project_enters_editor`, `test_menu_cancel_quits`, `test_parse_trailing_newline` (model_test) | New Project empty doc, B quits; loading strips one trailing newline (that `file_text` adds it back is exercised by the many save round-trip tests, e.g. block_comment_test) |

Not tested: run.txt parsing and the Run list (including the empty-list quirk), Recent Projects/New Project/Files
overlays (app layer; covered only by trace replays, doc 11), the save/rename dialog, delete, search, the Windows run
line (`run_command_windows`), `terminal_prefix`, the `odin_dir` / `odin_root` lookup order, `vendor_needs` /
`lib_findable`, the stb prompt flow, `user_path_add` (registry / `~/.profile` writes), the update check and download.

## Carrying this to Rust

### (a) What transfers unchanged

- The main menu shape (New Project / Recent Projects / Key Layout / Settings), "where?" list with added roots, the
  d-pad folder browser, generated `adjective-animal-NNNN` project names, Recent Projects with ages and `(in <root>)`.
- The Files grid exactly as specified (F12-F20), including its pure, injectable-lister model and its tests (port the
  fake trees one-to-one), the "here" column, descents, X/LT+X/LT+B/Y/RT+B controls and every refusal.
- Explicit Save (RT+Y) / Save as / rename dialog, name cleaning, overwrite confirmations, status wording.
- The run pipeline: save first, pre-run prompts, a real terminal per platform with the same close/keep-open rules,
  a log fallback, the run list with templates and one favorite, RB/LB shortcuts.
- Settings > Setup: detect, install without root into a per-user data dir, pinned checksums, progress rows, a startup
  hint, self-update with the Linux swap / Windows staged script, settings files kept.
- All persistence conventions (F37); the Deck rules (no shell profile, no keyboard, no root, home-folder projects).

### (b) Odin-specific pieces and their Rust analog

| Odin | Rust |
|---|---|
| `when ODIN_OS == .Windows {...}`, `#+build !windows` file tags (trash_*, pid_*, vendor_path_*) | `#[cfg(windows)]` / `#[cfg(unix)]` modules, `cfg!(...)` in expressions |
| `libc.system("cmd /c start ...")` string building | `std::process::Command` with argument vectors; Windows `CommandExt::creation_flags(CREATE_NEW_CONSOLE)` |
| `core:sys/windows` RegGetValueW / RegSetKeyValueW / SendMessageTimeoutW / SHFileOperationW | `winreg` or `windows-sys`; `trash` crate (Recycle Bin, and freedesktop trash on Linux) |
| `Fgrid_Lister :: #type proc(dir) -> ([]Entry, bool)` | `trait Lister { fn list(&self, dir: &Path) -> Option<Vec<Entry>>; }` or `&dyn Fn` |
| temp allocator + `free_all` per frame; `strings.clone` ownership | owned `String`/`PathBuf`; borrow `&Path` in pure helpers |
| atomic `Tc_State`/`Up_State` i32 + polling | `Arc<AtomicU8>` + `TryFrom`, or `Arc<Mutex<State>>` / channels; UI polls each frame |
| `thread.create_and_start` | `std::thread::spawn` (keep the `JoinHandle`) |
| `core:crypto/hash` SHA-256, `core:encoding/json` | `sha2`, `serde_json` |
| system `curl` / `tar` subprocesses | `ureq` (rustls) + `tar`/`flate2`/`xz2`/`zip` crates (progress from bytes read) |
| `@(static)` cached exe dir | `OnceLock` / `LazyLock` |
| `os.rename` replace-existing | `std::fs::rename` (replaces an existing *file* on Windows too: `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING`; it can't replace an existing directory, so directory swaps stay "rename old aside, rename new in") |
| path normalization by hand (`fgrid_norm` lowercases on every OS; `roots_same` only on Windows) | one explicit rule, lowercase only on Windows (Doodle's all-OS lowercasing in Files is a looseness, not a feature); `dunce` for `\\?\`-free canonical paths |
| `os.get_executable_path` | `std::env::current_exe()` |
| per-user data dir by hand | `dirs::data_local_dir()` (Windows) / `$XDG_DATA_HOME` or `~/.local/share` (keep Doodle's rule) |

### (c) Rust concepts this area needs that Odin lacks

- **The project is a Cargo package, not a folder of files.** In Odin a folder is a package and `odin run .` runs the
  open file's folder (F8). In Rust the unit is the crate rooted at the nearest `Cargo.toml` above the file; a
  **workspace** may sit above that. So: *project root* = nearest `Cargo.toml` (`cargo locate-project`), run cwd = that
  folder (cargo finds the workspace itself), `.doodle/run.txt` lives there (not in the file's folder), and Recent
  Projects detects a project by `Cargo.toml` (open `src/main.rs`, else `src/lib.rs`, else the first `.rs`; mtime =
  newest `.rs` under `src/`, bounded walk), labelled with the folder name (optionally `[package] name`).
- **New Project** creates a valid package on the first save: `Cargo.toml` (`[package] name = "<generated-name>"`,
  `version = "0.1.0"`, a pinned `edition`) and `src/main.rs`; the generated hyphenated name is a valid package name
  (the crate name becomes `brave_otter_0042`). Write these files yourself (works offline and without cargo) rather
  than calling `cargo new`. Create the folder on the first save, not at New Project, to avoid Doodle's empty-folder
  leftovers. First-save status: `saved src/main.rs in <folder> - rename the project in Files (LT+X)`.
- **Module tree.** A new `.rs` file is not compiled until a parent module declares `mod name;`. File names must be
  identifiers: clean names to snake_case, `-` -> `_`, no leading digit, not a keyword; `main.rs`, `lib.rs`, `mod.rs`,
  `build.rs` are special (refuse or warn on renaming them; renaming `foo.rs` breaks `mod foo;`). Recommended (not in
  Doodle): make "Module in a new file" an Add-menu construct of the *open* file that inserts `mod <name>;` and creates
  `<name>.rs` (keeps doc 00 P12: edits stay in the open file), and have Files' X in `src/` say
  `add mod new_file; in main.rs (Add > Modules)` in its status.
- **Targets.** A package has bins (`src/main.rs`, `src/bin/*.rs`), a lib, examples, integration tests, benches. Make the
  Run list react to the code: build its templates from `cargo metadata --format-version 1 --no-deps`
  (`cargo run`, `cargo run --bin <b>`, `cargo run --example <e>`, `cargo build --release`, `cargo check`,
  `cargo test`, `cargo test --test <t>`, `cargo clippy` if installed). Default favorite `cargo run`; LB `cargo test`.
  Possible extension: LB inside a `#[test]` fn offers `cargo test <path::to::fn>`.
- **Cargo.toml is a second document type.** Files must dispatch by file type: `.rs` -> the Rust projection, `Cargo.toml`
  -> a small TOML projection or a read-only view, anything else -> read-only text (Doodle feeds every file to its Odin
  parser). Adding a dependency is the analog of Odin's `vendor:`/`core:` imports (docs 04/07): a `use` needs a
  `[dependencies]` entry; `cargo add --offline` or editing the TOML document.
- **`target/`** is huge: hide it in Files and search (Doodle only hides dot entries) or show it dimmed and never walk it.
- **Native libraries** (F27/F28 analog): `-sys` crates usually link statically or need a C compiler (`cc` crate) at
  build time; DLLs for e.g. SDL2 must sit next to `target/debug/<bin>.exe` or on PATH. Keep the prompt machinery
  generic ("a library the program needs isn't findable") and reuse the PATH/registry/`~/.profile` code; detection can
  be heuristic (known crates) or reactive (Windows exit code `0xC0000135` STATUS_DLL_NOT_FOUND -> offer the prompt).

### (d) Implementation advice

- **Toolchain install (rustup).** Download the pinned `rustup-init`. URL patterns from the rustup book ("Other
  installation methods", checked 2026-11): latest
  `https://static.rust-lang.org/rustup/dist/{target-triple}/rustup-init[.exe]`, a pinned rustup version
  `https://static.rust-lang.org/rustup/archive/{rustup-version}/{target-triple}/rustup-init[.exe]`, and the SHA-256 of
  each at the same URL + `.sha256` (e.g. `.../x86_64-pc-windows-msvc/rustup-init.exe.sha256`). Use the `archive/`
  form so the bytes match the hash you pin in source like `ODIN_SHA256` (the `dist/` file changes with every rustup
  release). Run it with `-y --no-modify-path --profile minimal
  --default-toolchain <pinned version> -c rust-src -c rust-analyzer` and `RUSTUP_HOME`/`CARGO_HOME` pointing into the
  app's data dir, so it needs no root and never edits shell profiles. Find cargo like `odin_dir`: env overrides
  (`$CARGO_HOME/bin`), the app's own install, `~/.cargo/bin`, then PATH (Game Mode reads no profile). Pass `RUSTUP_HOME`,
  `CARGO_HOME` and PATH to every run and check.
- **Windows linker.** The default `x86_64-pc-windows-msvc` toolchain needs the same MSVC Build Tools as Doodle: keep F32
  as is. The `-gnu` toolchain ships a self-contained linker and avoids the 3 GB install, but C-dependent crates may still
  need a C compiler; treat it as an option, not the default.
- **Steam Deck linker.** Rust's `x86_64-unknown-linux-gnu` target links by invoking `cc` by default. Doodle's code
  says SteamOS has no `clang`, `cc` or `ar` (toolchain.odin and stb_build.odin header comments; inferred from those
  comments, not verified on a device here), which is why toolchain.odin writes `bin/cc` and `bin/ar`. Reuse the Zig
  install and wrappers (append `<data>/bin` to PATH, or set
  `CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER`, `CC`, `AR`); whether plain `zig cc` works as Rust's linker for every
  crate is untested here, so test it against glibc builds, and consider `cargo-zigbuild`, the known-good way to use zig
  as Rust's linker.
- **Terminal launch.** Same rules as F24/F25, but without shell-string assembly where possible. Windows:
  `std::process::Command::new("cmd")` with `std::os::windows::process::CommandExt::creation_flags(CREATE_NEW_CONSOLE)`
  (`0x0000_0010`, from `windows-sys`) instead of `cmd /c start`; because `cmd.exe` does not parse arguments by the
  MSVC rules that `Command::arg` quotes for, pass the `/c ...` command line with `CommandExt::raw_arg` (stable since
  Rust 1.62) and quote it yourself, as Doodle's F24 line does. POSIX: write the script to a **unique** temp file
  instead of the fixed `doodle_run.sh`, then spawn the terminal with an argv. If you use the `tempfile` crate, call
  `.keep()` / `into_temp_path().keep()` (or let the script `rm "$0"` itself): a `NamedTempFile` is deleted on drop,
  usually before the terminal has read it. Keep `$DOODLE_TERMINAL`-style overrides (`<APP>_TERMINAL`, `none`).
- **Trash.** Use the `trash` crate so Linux/Deck deletes go to the freedesktop trash instead of being permanent; keep
  the dialog text honest per platform.
- **Self-update.** Same flow (GitHub releases API, digest check, Linux swap by rename). On Windows a running exe can be
  renamed but not overwritten: `self-replace` covers the exe itself; bundled DLLs still need the staged script. Compare
  versions (e.g. the `semver` crate) instead of Doodle's "tag differs = newer", refuse to install when the release
  has no digest, and never `rmdir` anything but the stage folder you created (see Open questions).
- **Saving.** Before writing a never-saved document's default file (`src/main.rs` or Doodle's `main.odin`), check that
  it doesn't exist; on a clash ask, or pick the next free name. Compare paths case-insensitively only on Windows.
- **Distribution.** `cargo build --release` in the sniper SDK container (or a low-glibc target via cargo-zigbuild) for
  SteamOS; bundle or statically link SDL2 (the `sdl2` crate's `bundled`/`static-link` features remove the DLL hunt);
  ship whisper-cli and its model as Doodle does; keep VERSION, fixed-name assets and the deck_install.sh pattern.
- **Keep the model pure**: grid, roots, run.txt, name cleaning, script text, PATH editing and update scripts are pure
  string/struct functions with unit tests, exactly as in Doodle; only the app layer touches the disk and processes.

## Open questions & known gaps

1. **No unsaved-changes guard** (F11). Opening another file, A on the open file, Previous file, New Project, B to the
   menu, Exit, the updater's Restart and quit all drop edits silently. Nothing in code, comments or commit messages
   says whether this is intended; doc 00 lists it as a known gap. Decide for the Rust IDE: autosave before switching
   (cheap, matches "Run saves first"), or a confirm.
2. **Run list on a fresh project** shows only `+ New command` (seeding is skipped when run.txt is missing: confirmed
   by reading `load_run_cmds` / `ensure_default_run` / `draw_run_overlay`; no test, not observed live), and adding a
   template first leaves no favorite (`No favorite command set` on RB). Commands can't be removed or edited in the UI.
   `run.txt` has no versioned header, unlike the other persistence files, and write errors are ignored.
3. **run.txt and the run cwd are per opened file's folder**, so opening a file in a subfolder runs `odin run .` there
   and loses the project's run list. Correct for Odin packages, wrong for Rust crates.
4. **Save as has no default button**; Recent Projects' empty text therefore ends in `save one with ` (it should name
   Save, RT+Y). docs/EDITOR_MODEL.md says "Delete, Save as and Files always have a button", but the code's required
   actions are Delete, Files and **Save**. save_dialog.odin's header still calls RT+Y "Save as".
5. **Delete on Linux/Deck is permanent** while the dialog and status say "Recycle Bin".
6. **Search can't be typed** (no keyboard input in Files search), contrary to README; without a speech engine the query
   is stuck at "everything".
7. **`odin_root` splits PATH on `:` on Windows** (F29), so an Odin found only via PATH reads as missing in Setup and
   in the startup hint, although runs and `odin check` (which use plain `odin` from PATH) work. Confirmed by reading
   (Windows PATH entries all contain `X:`); not observed live. A third lookup, `model.odin_root`, ignores Setup's
   install and falls back to `C:/Odin` (F29). The port should have **one** toolchain lookup used everywhere.
8. **Empty project folders accumulate**: New Project creates the folder before the first save; Recent Projects hides
   them but nothing deletes them. No collision check on generated names (an existing folder is shared, and its
   `main.odin` is overwritten by the first Save).
9. **Open Folder** in the main menu is shown but not wired. src/project/project.odin (lazy tree, fuzzy index) is a dead
   stub from the original architecture, superseded by Files.
10. **Files opens any file through the Odin line parser** (`notes.md`, `run.txt` if it were visible); there is no file
    type dispatch. CRLF files are silently converted to LF on save.
11. **Updater** treats any tag different from the installed version as "Available" (no version ordering, so an older
    "latest" would be offered as an update), and skips the checksum when the release has no digest.
    `deck_install.sh` verifies no checksum.
12. **POSIX run script path is fixed** (`<tmp>/doodle_run.sh`): two quick runs can overwrite each other's script.
13. **README vs code**: the folder browser starts in the home folder (README: drive list / `/`); the Odin lookup order
    differs on Windows and on the Deck (F29); README says a keyboard can type a Files search (it can't, F19);
    docs/INSTALL.md is an early draft (ols, building SDL by hand) and doesn't describe Settings > Setup.
14. **Vendor library scan** reads only the project folder's top-level `.odin` files and needs `odin_dir` (not
    `odin_root`), so an Odin found only on PATH skips the check entirely.
15. **Previous file and the Files root are session-only**; nothing remembers the last open file per project.
16. **Plain Save can overwrite an unrelated `main.odin`** (F9): after the open file is deleted, or on a name collision,
    `save_current` writes `<folder>/main.odin` without checking. Data loss without a prompt; fix in the port.
17. **Case-folding on Linux**: save_dialog.odin's `same_path` uses `equal_fold` on every OS, so Save as and rename can
    replace a file that differs only in case (F10, F17); `fgrid_norm` also lowercases on Linux, so two folders
    differing only in case confuse Files' selection and project-root detection.
18. **A failed open still switches the current file** (F15): `filenav_load` sets the current file and project folder
    before `load_file`, so after `could not open <path>` the title, Save and Run point at a file whose text is not on
    screen.
19. **Windows updater cleanup**: the script runs `rmdir /s /q` on the *parent of the new root*. With the release zip's
    `doodle/` top folder that is `<parent>/.doodle-update`; if an archive had no top folder (`new_root_in` also accepts
    the stage itself), it would be `<parent>`, the folder that holds the install. Not reachable with the current
    workflow's zip, but a trap for the port.
20. **Odin install is delete-then-rename** (F31): a failed rename leaves no Odin. The Zig script keeps the old copy
    until the new one is fully unpacked and checked (`rm -rf zig && mv zig.new zig`), and the Linux updater renames the
    old root aside and puts it back on failure; the port should use the updater's pattern everywhere.

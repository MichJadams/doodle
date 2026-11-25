# 08 — Words without a keyboard: dictation, text tools, word-by-word editing, keypad, rename and naming dialogs

> Odin sources: src/stt/stt.odin, src/stt/stt_test.odin, src/stt_probe/main.odin, src/model/dictation.odin,
> src/model/text_tools.odin, src/model/word_edit.odin, src/model/expr.odin (number keypad: `number_keypad_open`,
> `keypad_apply`, `keypad_dims`, `number_key`), src/model/rename.odin, src/model/projects.odin (`clean_filename`,
> `clean_rename`), src/model/model.odin (`edit_selected`, `menu_select`, `menu_cancel`, `update`,
> `collect_vocab`, `COMMON_WORDS`, `set_slot_literal`, `inject_string_lit`, `set_field_text`),
> src/model/change.odin (`change_selected`, `string_literal_text`, `begin_refill`), src/model/keymap.odin
> (`.Talk`, `keymap_holding`, `keymap_allows`), src/app/main.odin (main loop dictation block, `build_prompt`,
> `join_identifier`, `join_spaces`, `handle_key`, `editor_input`), src/app/editor_view.odin (word-by-word layout,
> `draw_word_dot`, `[REC]` / `transcribing...` / `heard:`), src/app/save_dialog.odin, src/app/filenav.odin
> (`filenav_rename`, `rename_target`, `handle_filenav_search`), src/app/setup.odin (Speech row),
> src/app/trace.odin (`trace_stt_*`), assets/stt/*.gbnf, tools/stt/setup_whisper.sh,
> .github/workflows/release-steamos.yml (whisper packaging).
> Tests: src/model/dictation_test.odin, word_edit_test.odin, rename_test.odin, expr_test.odin
> (`test_expr_number_keypad`), projects_test.odin (`test_clean_filename`, `test_clean_rename`),
> handmade_exact_build_test.odin, src/stt/stt_test.odin. Docs: docs/STT.md (partly stale), README.md.
> Baseline: Doodle @ 34a2ad1.

## Purpose

Doodle never asks the user to type code, but programs still contain words: names, string text, comments,
numbers, file names. This area is every way such words get in with only a gamepad. The primary channel is
**push-to-talk dictation** (local whisper.cpp, no cloud): hold Talk, say a word or a few, let go, and the words
land in the highlighted part, shaped for what that part is (a `snake_case` name, free text in a string or
comment, a number). Everything speech cannot say is covered by small, menu-driven tools: **text tools** (case
styles, escapes, per-word case, backticks), **word-by-word editing** inside strings and comments (with yellow
gap dots for inserting format verbs, escapes and symbols), and a **number keypad** for hex and decimals.
Changing a declaration's name offers **rename with propagation** to its uses. A **Save as / Rename dialog**
names files with speech or an optional keyboard. Without any of this, generated names (`brave_otter`, doc 01)
would be the only names a pad user could ever have.

## Features

### F1. The toolbox at a glance: which tool for which highlighted part

- **Trigger**: the editor cursor is on a leaf (not a green insertion dot). What each input does depends on the
  field under the cursor (the leaf's primary field: its first slot, else its first editable field;
  src/model/selection.odin `leaf_primary_field`).
- **Behavior** (default layout: Talk = LT+X, Edit = LT+A, Change = plain Y; see doc 03):

  | Highlighted part | Talk (hold) | Edit (LT+A) | Change (Y) |
  |---|---|---|---|
  | A name (editable field, kind `""`) | Identifier: lowercase `snake_case`, snapped to known names | Text tools: Case (but on an `import` line LT+A reopens the import menu first, doc 04) | Falls through to Edit unless a Y-specific rule claims the part (doc 02/05) |
  | A struct/enum member name (kind `member`), a loop/block label (kind `label`), a polymorphic parameter name (kind `poly`, the `T` of `$T`) | Identifier | nothing (no text tools) | doc 02/05/06 |
  | A struct-literal key (kind `litkey`: fixed text, picked from the type's fields) | mic not offered | nothing | doc 06 |
  | A string's text (kind `string`, in `"..."`, `` `...` `` or `'...'`) | Free text (spaces, case kept) | Text tools: Case, Escape, Edit word by word | `"..."` / `` `...` ``: same text tools, with "Replace value" first if the string is an argument (a call argument or a struct-literal value). A `'...'` rune is not matched by `string_literal_text`: as an argument Y refills it directly, otherwise Y falls through to Edit's text tools |
  | A comment's text (kind `comment`: the text of a whole-line `// text`, or a body line of a `/* */` comment) | Free text | Text tools: Word case, Backticks, Edit word by word | `// text`: same text tools (fall-through to Edit). Any line of a `/* */` comment: Y **adds a new comment line** after it instead (`block_comment_change`, doc 01 §17) |
  | A number literal (built from Value > Number, or loaded like `10`, `0x1F`, `3.5`) | Number (`"twenty five"` -> `25`) | Number keypad | Keypad via the Edit fall-through (an argument is refilled instead) |
  | A value dot (orange; kind `value`, or the "another return value" dot) whose expected type takes a number, or has no known type | Number (the dot becomes the number) | (A fills the dot, doc 06) | (doc 06) |
  | A filled type reference (kind `type`) | Identifier (replaces the text) | Type menu (doc 06) | doc 06 |
  | Anything else (keywords, operators, fixed text, empty `//` comments and `//+` tags, which load as one fixed field), every other dot (type, args, params, body, capture, ...), or a green dot | mic not offered | doc 02 | doc 02 |

- **Rules & edge cases**: the mic is only offered when this table says so (`dictation_target` returns `.None`
  otherwise, and the HUD's Talk button does not pulse). `dictation_target` checks, in this order: a number
  literal (`is_number_literal_field`: not a slot, kind `""`, text passes `is_number_text`; editable or not) ->
  Number; a `value`/`ret_more` slot that takes a number -> Number; an editable `string`/`comment` field ->
  Free_Text; any other editable field -> Identifier; else None. Each tool writes through `set_field_text`; name
  changes from Talk and from text tools go through `rename_field` (F19). A new comment's text starts as a
  generated name spelled as words (`// brave otter`, `comment_placeholder` in src/model/stmt_layout.odin), ready
  to be dictated over.
- **Rationale**: "LT+A on a name, a string or a comment opens text tools for what dictation can't say"
  (docs/EDITOR_MODEL.md §3.6). The acceptance test builds a real Win32 program from an empty project using
  only "what push-to-talk gives: lowercase snake_case names, spaced words in strings / comments"; `WHITENESS`,
  `"WM_SIZE\n"`, `"HandmadeHeroWindowClass"`, `` `static DWORD Operation` `` and `TODO` come from the text
  tools (src/model/handmade_exact_build_test.odin header).
- **Source**: src/model/dictation.odin `dictation_target`; src/model/model.odin `edit_selected`;
  src/model/change.odin `change_selected`; src/model/text_tools.odin `text_tools_menu`.

### F2. Talk: the push-to-talk binding and when the mic is offered

- **Trigger**: hold the button bound to the **Talk** action (default **LT+X**) while the editor is showing and a
  dictation target (F1) is highlighted.
- **Behavior**:
  - Talk is a *hold* action (`ACTION_INFO[.Talk].hold = true`): it never "fires" through the keymap; the app
    polls it every frame with `keymap_holding(km, raw.held, lt, rt, .Talk)`, which is true when Talk's button is
    down **and** its bank's trigger is held (LT bank: LT; RT bank: RT; plain bank: neither trigger). The other
    trigger is ignored (LT+RT+X still talks with the default layout).
  - Dictation starts on the frame where all of these hold: Talk held; no Key Layout page, Settings page, vendor
    PATH prompt or stb prompt open; the press is not *stale*; `g_mic_ready` (a target exists, the STT engine
    exists, `m.state == .Editor`, i.e. no radial menu); not already recording or transcribing; no overlay open
    (`overlay_open()`: file navigation, save dialog, docs panel, run overlay, project picker, new-project list,
    key page, settings, prompts).
  - At start the target `(node, field)` is captured (`g_stt_ni`, `g_stt_fi`) together with the mode; the
    words will go there even though the cursor cannot move meanwhile.
  - The HUD draws a pulsing green ring (`COL_DOT`, pulse at `sin(5t)`) around Talk's button whenever
    `g_mic_ready && !overlay_open()`, i.e. when a dictation target is highlighted in the editor with an engine
    present (doc 03). It does not check recording/busy or a stale press, so it keeps pulsing while you talk and
    while the words are worked out.
  - `raw.held` includes the keyboard stand-ins (`x`, `y`, `q`/`e` as LT/RT, ...; F21), so holding `q`+`x` on a
    keyboard also talks with the default layout.
  - Talk's `ACTION_INFO` entry: key `talk` (in doodle_keys.tsv), label `Talk`, HUD glyph `m` (drawn as the
    Speech icon when icons load, `action_icon`), Key Layout hint
    `hold to dictate into the highlighted name / string / number`.
- **Rules & edge cases**:
  - **Talk must be on a face button**: plain X or plain Y, or X/Y/A/B in the LT or RT bank (plain A and plain B
    are locked to Select/Back, `slot_locked`). `ACTION_INFO[.Talk].face_only` and `keymap_allows` refuse d-pad
    slots, because **d-pad Down splits words while you talk** (F7); pinned by src/model/keymap_test.odin
    (`keymap_assign(&km, BANK_RT, .Up, .Talk)` -> `Not_Here`). The Key Layout
    page says `Talk needs a face button (the d-pad splits words while you talk)`, marks d-pad cells
    `face buttons only`, and a swap that would push Talk onto the d-pad is refused with
    `Can't swap: <label> would move to <slot>, and Talk needs a face button` (src/app/keys_page.odin).
  - **Stale press**: if Talk's button went down while an overlay was open (e.g. Talk rebound to plain Y, and Y
    also closes the docs panel), `g_talk_stale` is set and dictation cannot start until the button is released
    and pressed again.
  - Talk may end up with no button at all (the Key Layout allows it, with the status `... - Talk has no button
    now`); then there is no dictation in the editor.
  - Dialogs do **not** use the Talk binding: the Save as / Rename dialog listens while the **gamepad** X button
    is held (`raw.pad_x_held`), the Files search while X is held on the pad **or** the keyboard (`raw.x_held`)
    (F10).
  - Hard-coded word-by-word buttons can shadow a rebound Talk (code reading): with Talk on plain Y or RT+X, the
    same press inside word-by-word mode also opens the word menu (`word_edit_update` reads the raw `inp.y` /
    `inp.rt_held && inp.x`), the state becomes Radial, `g_mic_ready` goes false and no dictation starts (F15).
- **Rationale**: commit d73fe11 "mic gated to editable fields only"; docs/EDITOR_MODEL.md §5 ("Talk needs a
  face button ... while you talk, d-pad Down splits words").
- **Source**: src/model/keymap.odin (`Action_Info.hold`, `.face_only`, `keymap_holding`, `keymap_allows`,
  `KEYMAP_DEFAULT`); src/app/main.odin (main loop: `talk_down`, `mic_hold`, `g_talk_stale`, `g_mic_ready`,
  `draw_hud` glow); src/app/keys_page.odin.

### F3. Audio capture, WAV, and the whisper-cli subprocess

- **Trigger**: dictation begins (F2) or a dialog's X hold begins (F10).
- **Behavior**:
  - **Capture**: one SDL2 audio *capture* device opened at startup (`stt.init`): 16 000 Hz, signed 16-bit
    (`AUDIO_S16`), mono, 1024-sample buffer, queue mode (no callback). `begin` clears the queue and unpauses
    the device; `segment*`/`end*` dequeue everything captured so far (`end*` also pauses the device first).
  - **WAV**: the PCM bytes are wrapped in a hand-written 44-byte RIFF header (`RIFF`, size, `WAVE`, `fmt `
    chunk of 16 bytes: PCM=1, channels=1, 16000 Hz, byte rate 32000, block align 2, 16 bits; `data` chunk) and
    written to a temp file.
  - **whisper-cli**: run as a shell command through `libc.system`, stdout redirected to a temp text file,
    stderr discarded. The exact command line (`whisper_command`):

    ```
    <cli> -m <model> -f <wav> -nt -np -l en -tp 0 -bo 1 -bs 1 -t 4 [--grammar <g> --grammar-rule root --grammar-penalty 100] [--prompt <p>] > <txt> 2> nul|/dev/null
    ```

    `-nt` no timestamps, `-np` no progress prints, `-l en` English, `-tp 0 -bo 1 -bs 1` temperature 0, best-of 1,
    beam size 1 (greedy, deterministic, fastest for one word), `-t 4` four threads. Quoting: on Windows every
    path/prompt is wrapped in `"..."` and the whole command gets one extra pair of quotes (cmd.exe `/c` strips
    the outer pair); elsewhere POSIX single quotes with `'` escaped as `'\''`, so paths with spaces and prompts
    containing `'` or `$` survive. The Windows quoting does **not** escape an embedded `"` (nor `%NAME%`
    pairs, which cmd.exe may expand), so a prompt containing a string text with `"` breaks the command line
    there (code reading; the Identifier prompt
    carries every editable field text, F5). cmd.exe also caps a command line at 8191 characters, so a very long
    prompt can make the whole command fail and the clip come back `""` (unverified; nothing guards the length).
  - The text file is read back and cleaned per mode (F6).
  - **Temp files**: `<os temp>/doodle_stt_capture.wav` and `<os temp>/doodle_stt_out.txt` for the blocking
    path; each background clip gets its own pair, `...capture.wav.<n>.wav` / `...out.txt.<n>.txt`, deleted after
    use (`job_free`).
- **Rules & edge cases**: an empty queue (no audio) gives `""` without running whisper. A WAV write failure
  gives `""`. The exit status of whisper-cli is ignored; whatever the text file holds is cleaned and used
  (normally empty after a failure, because the shell truncates the redirect target first; the blocking path's
  fixed `doodle_stt_out.txt` is never deleted, so a command line that never runs could leave the previous
  result there; unverified). The engine is for *one-off words and short phrases*, not sentences (docs/STT.md).
  `listen(e, ms)` (begin, `SDL_Delay(ms)`, end) exists only for the probe.
- **Grammars**: `assets/stt/number.gbnf` (spoken numbers 0-99), `digit.gbnf` (one digit, incl. "oh"),
  `commands.gbnf` (a template list: yes no ok cancel delete rename up down left right open close next back
  confirm). Each `root` starts with `" "` because Whisper emits a leading space. `Config.grammar_path` adds the
  `--grammar` flags, **but nothing in the app ever sets it** (only a commented-out line in src/stt_probe); the
  number mode relies on a prompt and a parser instead (F9). Treat the grammars as an available lever, not a
  shipped feature. (Confirmed: `default_config` sets `grammar_path = ""` with the comment "set to
  assets/stt/number.gbnf for numeric fields", no app code assigns it, and `test_whisper_command_quoting` asserts
  the default command has no `--grammar`.)
- **Rationale**: subprocess isolation "keeps the heavy dependency out of the Odin process" (docs/STT.md
  Architecture; ARCHITECTURE.md §3 leaf service). Quoting fixes are pinned by `test_whisper_command_quoting`
  (a Deck path with spaces).
- **Source**: src/stt/stt.odin (`init`, `begin`, `segment`, `end`, `transcribe_queued`, `write_wav`,
  `run_whisper`, `whisper_command`, `listen`, `shutdown`); src/stt_probe/main.odin (a standalone console
  program: prints `Recording 1.5s - speak ONE word or number now...`, records 1.5 s with `listen` in Identifier
  mode with no vocabulary, prints `Heard: "<word>"`; without an engine it prints `STT not available.` and
  `Build whisper + download a model first:  tools/stt/setup_whisper.sh`).

### F4. Finding the engine, setup, packaging, and running with no engine

- **Trigger**: app startup (`stt.init(stt.default_config())` in src/app/main.odin).
- **Behavior**:
  - `default_config` picks the first existing path from each candidate list (else the last candidate, so `init`
    reports "not set up"):
    - whisper-cli (`whisper-cli.exe` on Windows, `whisper-cli` elsewhere): `<exe dir>/whisper-cli`,
      `third_party/whisper.cpp/build/bin/whisper-cli` (relative to the working folder),
      `<exe dir>/../third_party/whisper.cpp/build/bin/whisper-cli`.
    - model `ggml-base.en.bin`: `<exe dir>/../models/`, `<exe dir>/models/`,
      `third_party/whisper.cpp/models/`, `<exe dir>/../third_party/whisper.cpp/models/`.
  - `init` fails (engine `nil`) when either file is missing, SDL audio cannot init, or no capture device opens.
  - **Release packaging**: the GitHub workflow builds whisper.cpp v1.9.5 statically (AVX/AVX2/FMA/F16C on,
    **AVX-512 off** for the Deck's CPU, no OpenMP) and ships `bin/whisper-cli` plus
    `models/ggml-base.en.bin` (sha256-checked) beside Doodle on Windows, SteamOS and Linux.
  - **Dev setup**: `tools/stt/setup_whisper.sh [model]` clones whisper.cpp into `third_party/`, builds
    `whisper-cli` with CMake (MinGW Makefiles + clang on Windows/MSYS, system compiler on Linux/Deck), downloads
    `ggml-<model>.bin` (default `base.en`; `tiny.en` faster, `small.en` more accurate).
  - **Settings > Setup > Speech-to-text** (information only, A does nothing): `Ready` /
    `Hold Talk to dictate names, numbers, strings and comments.`, or `Not set up` /
    `whisper-cli or its model isn't next to Doodle (they come with the release), or there's no microphone.`
- **Rules & edge cases (no engine)**: never a crash. `g_mic_ready` is always false, so Talk does nothing and its
  HUD button never pulses; the save dialog's hint drops `hold X to say a name`; the Files search still shows its
  static hint but X does nothing. Everything else works: generated names, text tools, keypad, word-by-word
  inserts. The practical consequence: without speech, names can only be re-cased, and string/comment text can
  only gain specials and symbols.
- **Permissions**: Windows needs "Let desktop apps access your microphone"; on the Deck the mic works through
  PipeWire/PulseAudio and, in Gaming Mode, the mic must be the default capture device (docs/STT.md). README Deck
  table: "Works out of the box with the Deck's microphone. It's slower than on a desktop PC." (Launching Doodle
  through Steam is a README requirement for the *gamepad*, not for the mic.)
- **Source**: src/stt/stt.odin (`default_config`, `exe_dir`, `first_existing`, `init`); src/app/setup.odin
  (`.Speech` row, `g_stt_ready`); .github/workflows/release-steamos.yml; tools/stt/setup_whisper.sh.

### F5. Biasing names: the Whisper prompt and the vocabulary snap

- **Trigger**: Identifier-mode dictation starts (F2/F6).
- **Behavior**:
  - **Vocabulary** (`collect_vocab`): the 31 `COMMON_WORDS` (`main package proc struct enum union import return
    context string int bool true false append make delete len cap nil defer for player health update init
    index count value name result`) followed by the text of **every editable field of the document** except
    comment text (names of every kind including members, labels and types, editable numbers, and string texts;
    duplicates and empty texts are not removed).
  - **Prompt** (`build_prompt`): `lowercase Odin code identifiers: ` + the vocabulary joined by spaces, passed as
    `--prompt` (a soft bias).
  - **Snap** (`snap_identifier`, deterministic, after cleaning): the cleaned identifier is split at `_`; each
    token of **3+ characters** that is not already in the vocabulary is replaced by the **first** vocabulary
    word at **Levenshtein distance exactly 1** (`best_d` starts at 2, only strictly better replaces). Tokens are
    re-joined with `_`. Examples (tests): `maine` -> `main`; `maine_playr` -> `main_player`; `otterbox` stays;
    `ma` stays (too short).
  - Free-text and number modes use **no** vocabulary and no snap; number mode uses a fixed prompt (F9).
- **Rules & edge cases**: the vocabulary slice references document strings and is freed when the dictation's
  words are applied. The prompt grows with the document. whisper.cpp keeps at most half its text context
  (448 / 2 = 224 tokens) of prompt, taking the **last** tokens, so on a large file the leading
  `lowercase Odin code identifiers:` and the `COMMON_WORDS` are the first to fall out (unverified against the
  v1.9.5 source; Doodle does nothing about it). See also the Windows command-line limit in F3.
  The snap compares bytes case-sensitively against *any* vocabulary entry, so the replacement can be a string's
  text or an UPPER/Mixed-case name: with `Size` in the document, a heard `size` token (distance 1) becomes
  `Size`, and an identifier with uppercase letters is written (code reading).
- **Rationale**: commit 381af06 "--prompt soft bias + deterministic vocabulary snap (edit-distance<=1) so
  'maine'->'main'; editor supplies in-scope identifiers+keywords per utterance". (The code supplies all
  document names, not a scope-filtered list.)
- **Source**: src/model/model.odin (`COMMON_WORDS`, `collect_vocab`); src/app/main.odin (`build_prompt`);
  src/stt/stt.odin (`set_context`, `snap_identifier`, `snap_token`, `levenshtein`).

### F6. From heard words to field text, per mode

- **Trigger**: a dictation's text is ready (F8) or a dialog transcription returns (F10).
- **Behavior**: the mode chosen at record start (`Dictation_Mode`) decides cleaning, joining and writing:

  | Mode | Engine setting | Per-clip cleaning | Clips joined with | Written by |
  |---|---|---|---|---|
  | `Identifier` | `free_text=false`, prompt + vocab (F5) | `clean_identifier`, then snap | `_` (`join_identifier`) | `rename_field` (F19) |
  | `Free_Text` | `free_text=true`, no prompt | `clean_free` | one space (`join_spaces`) | `word_dictated` when word editing is active on that same field (F17), else `rename_field` (which just writes the text: strings and comments never prompt) |
  | `Number` | `free_text=true`, prompt `Numbers: 0, 1, 2, 10, 25, 100, 3.5, -2.` | `clean_free` | one space | `spoken_number` then `dictate_number` (F9); never `rename_field` |

  (Number mode uses free text so `3.5` / `-2` survive; identifier cleaning would make them `3_5` / `2`.)

  - `clean_identifier`: ASCII-lowercase; every run of non-`[a-z0-9]` bytes becomes one `_`; no leading or
    trailing `_`. `"Brave Otter."` -> `brave_otter`.
  - `clean_free`: trim; collapse runs of space/tab/CR/LF to one space; drop **one** trailing `.` (then trailing
    spaces). Case, apostrophes, commas, `?`, `!` are kept. `" Hello world."` -> `Hello world`.
  - Empty clips are skipped when joining. An all-empty result changes nothing.
  - Dictation **replaces the whole field** (name, string text, comment text). Adding words to existing text is
    done word by word (F17).
- **Examples** (Odin, before -> after):
  - Name: `brave_otter := 0`, say "window title" -> `window_title := 0` (then the rename prompt if
    `brave_otter` was used, F19).
  - String: `fmt.println("")`, say "hello brave world" -> `fmt.println("Hello brave world")` (Whisper's own
    capitalization is kept).
  - Comment: `// brave otter`, say "fix the thing" -> `// Fix the thing`.
- **Rules & edge cases**: nothing validates the result as an identifier (a leading digit or a keyword can be
  written); rename propagation is skipped for non-identifiers (F19). Free text is not escaped for the literal
  it lands in (a `"` in `"..."` or a `'` in `'...'` would break it). A rune literal `'...'` accepts any words.
- **Source**: src/stt/stt.odin (`clean_identifier`, `clean_free`, `set_free_text`, `transcribe_clip`);
  src/app/main.odin (dictation block, `join_identifier`, `join_spaces`); src/model/rename.odin `rename_field`;
  src/model/word_edit.odin `word_dictated`.

### F7. D-pad Down splits words while talking

- **Trigger**: while recording (Talk held), press **d-pad Down** (the plain Down edge, whatever trigger is held).
- **Behavior**: `segment_async` queues the audio heard so far as one clip and keeps recording; the clip count
  grows. Each clip is transcribed and cleaned separately, then the texts are joined (F6). In Identifier mode
  the split is a guaranteed `_` boundary: saying "game" [Down] "loop" yields `game_loop` even if Whisper would
  have heard "gameloop". In free text it is a space; in Number mode a space ("twenty" [Down] "five" -> 25).
- **Rules & edge cases**: d-pad auto-repeat is switched off while recording (`win.dpad_no_repeat =
  g_recording`) so a held Down is one split. All other editor input is masked while recording and while
  transcribing (`confirm cancel up down left right x y` cleared from the frame's input in the main loop and in
  `editor_input`; the Ctrl+C, RB and LB shortcuts are disabled; the walk highlight is off). There is no way to abort: releasing always transcribes.
- **Rationale**: commit 3714653 "D-pad Down = underscore boundary"; this is why Talk must be face-button only.
- **Source**: src/app/main.odin (`down_edge`, `trace_stt_segment_async`, `editor_input`); src/stt/stt.odin
  (`segment_async`, `queue_clip`); src/platform/platform.odin (`dpad_no_repeat`).

### F8. Background transcription in the editor, and its feedback

- **Trigger**: Talk is released (or its trigger let go) during an editor dictation.
- **Behavior**:
  - `end_async` pauses the mic and queues the rest as the last clip; `g_recording=false`, `g_stt_busy=true`.
  - A single worker thread (created lazily on the first queued clip) takes jobs FIFO, runs whisper on each,
    and appends the cleaned text to a `done` list; each job carries a **copy of the engine config at queue
    time** (mode, prompt, vocabulary, its own temp files).
  - Every frame the app `poll`s texts in order until it has one per queued clip; then (still on the main
    thread) it joins them, checks that the captured `(line, field)` **indices are still in range** (only a
    bounds check, not that it is the same field; a file could have been opened), applies them per mode
    (F6/F9), stores `g_heard`, and frees the vocabulary and prompt.
  - **Feedback** at the top right of the editor title bar: `[REC]` (red, `COL_ERR`) while recording;
    `transcribing.` / `transcribing..` / `transcribing...` while busy (the frame changes every 1/3 s:
    `int(g_time * 3) % 3`); afterwards `heard: <text>` (accent color), which stays until the next successful
    dictation. In Number mode `heard:` shows the parsed number (`25`), not the words. A non-number in Number
    mode sets the status line to `Heard "<text>" - not a number`, changes nothing, and leaves the previous
    `heard:` text in place.
  - The screen keeps rendering; the editor accepts no input until the words are in ("nothing moves until the
    words are in").
- **Rules & edge cases**: silence gives `""` for that clip. If the target vanished, the text is dropped
  silently. Replays: each polled text is recorded as an `stt` string mark and re-injected on replay at the same
  frame; a dictation started during a replay before takeover polls back `""` (doc 11).
- **Rationale**: commit d6d998b "background dictation"; README Deck row: "In the editor the words are worked out
  in the background ("transcribing..." at the top) and appear when ready. Dictating a Files search or a file name
  still waits for them."
- **Source**: src/stt/stt.odin (`segment_async`, `end_async`, `poll`, `queue_pcm`, `worker_main`,
  `transcribe_clip`, `job_free`, `shutdown`); src/app/main.odin (dictation block); src/app/editor_view.odin
  (indicator); src/app/trace.odin (`trace_stt_segment_async`, `trace_stt_end_async`, `trace_stt_poll`).

### F9. Spoken numbers and number dictation

- **Trigger**: Talk on a number literal, or on a value dot (kind `value`, or the "another return value" dot)
  whose expected type is integer, float, unknown or any (`dot_takes_number`).
- **Behavior**:
  - `spoken_number(heard)`: trim; strip trailing `. ! ? ,` and spaces. First, digits as heard: remove `,` and
    spaces; if that is number text (`is_number_text`), return it (case kept: `0x1F`). Else normalize words
    (letters/digits/`.` kept, a leading `-` kept, everything else a space; so `Twenty-five` -> `twenty five`),
    optional leading `minus` / `negative` / `-`, split at the first `point` or `dot`, parse the whole part as
    an English cardinal, then each fraction word as one digit word (`five`) or digits (`5`, `25`).
  - Cardinal parser: `zero`..`nineteen`, tens `twenty`..`ninety`, `oh o nought naught` = 0, the misspelling
    `fourty` = 40, digit strings; `hundred` multiplies the current group (`twenty hundred` refused); `thousand`
    `million` `billion` close a group; `and` and `a` are ignored. Refused sequences: two units in a row
    (`one two`), tens after tens (`twenty thirty`), a unit/teen then tens (`five twenty`). An empty whole part is 0
    (`point five` -> `0.5`).
  - Pinned conversions: `10`->10, `10.`->10, `Ten.`->10, `Twenty-five`->25, `ninety nine`->99,
    `a hundred and five`->105, `two hundred thirty`->230, `one thousand two hundred`->1200,
    `three point one four`->3.14, `minus two`->-2, `negative ten`->-10, `- 2`->-2, `1,000`->1000,
    `2 hundred`->200, `0x1F`->0x1F. Refused: `hello`, `one two`, `twenty thirty`, `five twenty`, `three point`,
    `point`, `minus`, `x`, `""`.
  - Further refusals that follow from the code (not in the test table): a tens word after another tens word, a
    teen or `zero` (`twenty ten`, `twenty zero`); any digit string after anything else in the same group
    (`twenty 5`, `5 5`); a unit or tens word right after a digit string (`20 five`); a fraction word that is
    not one digit word or a digit string (`point twenty`). A phrase of only `and` / `a` is refused.
  - Because the first pass deletes spaces, digits Whisper writes apart are read as one number: `1 2` -> `12`
    (while the words `one two` are refused).
  - `dictate_number(ni, fi, value)` (refuses value text that fails `is_number_text`): on a value dot, the dot
    becomes an editable `0` (`set_slot_literal "__lit_num__"`) whose text is then set to the value; on the
    "another return value" dot (kind `ret_more`) the same happens, then `more_dot_filled` puts a fixed `, ` in
    front of the new number (unless it is the first value, right after `return`, `(` or `->`) and the cursor is
    put on the number; the result-list sync then adds a fresh "another value" dot after it (doc 06,
    src/model/result_list.odin). On a number literal (including one loaded from a file, normally fixed text) the
    field is made editable and its text replaced, so the keypad (F18) works on it afterwards. In every case the
    cursor ends on the number (`focus_field_index`).
- **Rules & edge cases**: a value dot typed for a non-number (e.g. `string`) is not a dictation target (mode
  `None`). `is_number_text` accepts an optional leading `-`, then text starting with a digit made of digits,
  `_`, one `.` (but not `..`, so `0..<10` is not a number), `e`/`E` anywhere after the first character and a
  `+`/`-` right after one (loose: `1e` and `1ee5` pass); or `0x`/`0b`/`0o` followed by at least one hex digit
  or `_` (any prefix takes hex digits: `0b12` passes; `0x` alone refused).
- **Example**: `p := point{x = 10, y = 0, z = 0}`; on `y`'s value say "seven", on `z`'s say "2.5" ->
  `p := point{x = 10, y = 7, z = 2.5}` (test).
- **Source**: src/model/dictation.odin (`dictation_target`, `is_number_literal_field`, `is_number_text`,
  `dot_takes_number`, `dictate_number`, `spoken_number`, `cardinal`, `small_value`, `digit_word`,
  `normalize_words`); src/app/main.odin.

### F10. Blocking dictation in dialogs: Save as / Rename and the Files search

- **Trigger**: the Save as / Rename dialog is open and the **gamepad X** button is held (`raw.pad_x_held`; the
  keyboard `x` key types an "x" instead); or the Files search is open and X is held (`raw.x_held`: pad or
  keyboard).
- **Behavior**:
  - Dialog: Identifier cleaning (`set_free_text(false)`), **no prompt, no vocabulary**. While held: `[REC]`
    inside the name box, the box outline turns red, every other button is ignored. On release `stt.end` runs
    whisper **synchronously** (the frame waits). A non-empty result replaces the whole name box ("game loop" ->
    `game_loop`, saved as `game_loop.odin`).
  - The dialog arms X only after X has been released once since it opened (`g_save_x_armed`), because Files'
    LT+X opens the Rename dialog with X still down.
  - Files search (opened with plain **Y** in Files; header `SEARCH`): free text, no prompt, no vocabulary; the
    field shows `Listening...` while held and `(hold X and say part of a file name)` when the query is empty.
    A non-empty result replaces the query and re-filters; an empty result keeps the old query. The filter lists
    every file (not folders) under the Files root, all folders expanded, whose lower-cased name contains the
    lower-cased query, shown with its path from the root; an empty query (as on opening) lists every file. The
    walk stops at 12 folder levels (`FN_MAX_DEPTH`) and 400 results (`FN_MAX_RESULTS`). Up/Down move through
    the results with wrap-around; A opens the file and leaves Files; B (only when not recording) closes the
    search and goes back to the folder grid. The hint line reads
    `Up/Down move   A open   hold X say a name   B back to the folders`.
- **Rules & edge cases**: `save_dialog_close` ends and discards a recording in progress, but no button can
  close the dialog while X is held (every other button is ignored then). The Files search query keeps spaces
  and case ("game loop" does not match `game_loop.odin`). Up/Down/A are not blocked while the search is
  recording.
- **Source**: src/app/save_dialog.odin (`handle_save_input`, `save_dialog_close`); src/app/filenav.odin
  (`handle_filenav_search`, `filenav_apply_filter`); src/app/trace.odin (`trace_stt_begin`, `trace_stt_end`).

### F11. Text tools on a name

- **Trigger**: Edit (LT+A) on an editable name field of kind `""` that is not a number (Y reaches the same
  through `change_selected`'s fall-through to `edit_selected`).
- **Behavior**: a radial menu titled **`Text`** with one entry, **`Case`**, whose submenu lists, in this order:
  `snake_case`, `UPPER_SNAKE`, `Ada_Case`, `camelCase`, `PascalCase` (no `Joined` for names). Picking one
  re-cases the name (`recase`), closes all menus, keeps the cursor on the field and, if the text changed and
  the name is a declaration with uses, opens the rename prompt (F19).
  - Word splitting (`case_words`): at space, tab, `_`, `-`, and at a lower->Upper boundary (`braveOtter` ->
    `brave`, `Otter`). Digits and acronyms do not split (`HTTPServer` is one word).
  - Styles: snake = lower words joined `_`; UPPER_SNAKE = upper words `_`; Ada_Case = Capitalized words `_`;
    camelCase = first lower, rest Capitalized, no separator; PascalCase = Capitalized words; Joined = words
    unchanged, no separator. *Capitalized* = first letter upper, **rest lowered** (`DWORD` -> `Dword`).
- **Example**: `whiteness :: 0` -> Case > UPPER_SNAKE -> `WHITENESS :: 0`; `brave_otter` -> camelCase ->
  `braveOtter`; a struct `brave_otter` dictated as "player state" -> PascalCase -> `PlayerState`.
- **Rules & edge cases**: B anywhere in the menu backs out one level; at the root it closes with no change
  (P9). Fields of kind `member`, `litkey`, `label`, `poly`, `type` and slots get no text tools
  (`text_tools_menu` only handles kinds `string`, `comment` and `""`; a `type` field opens the Type menu
  instead). `edit_selected` tries, in order: a filled type (Type menu), a number (keypad, F18), a line whose
  text starts with `import ` (the import menu, doc 04), then text tools; so LT+A on an import alias name never
  shows Case. A dictated negative number (`-2`, editable, kind `""`) is not a "number field" (those start with
  a digit) and so gets the Case menu; any style there drops the minus (`case_words` splits at `-`, so
  `snake_case` turns `-2` into `2`; code reading). The root menu is pushed with its own order (`push_view`);
  the heatmap counts Case and Escape picks only.
- **Source**: src/model/text_tools.odin (`Case_Style`, `CASE_LABELS`, `case_words`, `capitalized`, `recase`,
  `case_entries`, `text_tools_menu`, `open_text_tools`, `text_tool_apply`, `text_tool`); src/model/model.odin
  (`edit_selected` Case 3, `menu_select` `TXT_FILL`); src/model/heat.odin (`heat_is_action`).

### F12. Text tools on a string

- **Trigger**: Edit (LT+A) on a string literal's text, or **Y** (Change) on a string literal (`string_literal_text`
  finds the text field when the leaf is exactly the `"` / `` ` `` quote fields plus the text). A `'...'` rune is
  not matched there (its quotes are `'`): Y on a rune argument goes straight to the refill, and Y on any other
  rune falls through to `edit_selected`, i.e. the same text tools without "Replace value".
- **Behavior**: menu **`Text`** with, in order:
  1. **`Replace value`** — only via Y and only when the string is an argument (`u.is_arg`: a call argument or a
     struct-literal value): the argument becomes a typed value dot with its fill menu (`begin_refill`; B
     restores the original string, doc 06).
  2. **`Case`** > `snake_case`, `UPPER_SNAKE`, `Ada_Case`, `camelCase`, `PascalCase`, `Joined`.
  3. **`Escape`** > `\n`, `\t`, `\r`, `\0`, `\\`, `\"` — the escape is **appended** to the end of the text.
  4. **`Edit word by word`** (`WORDS_LABEL`) — enters word-by-word mode (F14).
- **Example** (dictated "wm size" into `OutputDebugStringA("")`):
  `"wm size"` -> Case > UPPER_SNAKE -> `"WM_SIZE"` -> Escape > `\n` -> `"WM_SIZE\n"`.
  `win32.L("handmade hero window class")` -> Case > PascalCase -> `win32.L("HandmadeHeroWindowClass")`.
- **Rules & edge cases**: Escape is offered for raw `` `...` `` strings (where it is literal text, not an escape)
  and for `'...'` rune literals (where appending makes a second character); word-by-word does hide escapes for
  raw strings (F16). The Escape list here (`\n \t \r \0 \\ \"`) differs from word-by-word's (which adds `\e`
  and orders them differently). Strings never trigger rename.
- **Source**: src/model/text_tools.odin (`ESCAPES`, `text_tools_menu` case `"string"`, `open_text_tools(refill)`,
  `refill_string`); src/model/change.odin (`change_selected`, `string_literal_text`, `begin_refill`);
  src/model/model.odin (`inject_string_lit`: a string literal is three fields, open quote / editable text
  kind `string` / close quote).

### F13. Text tools on a comment

- **Trigger**: Edit (LT+A) on a comment's text (`// text`, or a body line of a `/* */` comment; doc 01/05), or Y
  on a `// text` comment (through `change_selected`'s fall-through; `test_word_edit_comment`). Y on any line of
  a `/* */` comment does **not** open text tools: `block_comment_change` runs first and adds a new comment
  line after it, its text a generated placeholder (doc 01 §17).
- **Behavior**: menu **`Text`** with:
  1. **`Word case`** > one entry per word (split at whitespace only; punctuation stays part of the word; a
     repeated word is labeled `the`, `the (2)`, ...) > `UPPER` / `Capitalized` / `lower`: re-cases that word
     only, all other spacing kept.
  2. **`Backticks`** > one entry per word > the phrases starting at that word, up to 6 words long (`static`,
     `static DWORD`, `static DWORD Operation`, ...): picking one replaces those words with `` `phrase` `` (the
     words re-joined with single spaces).
  3. **`Edit word by word`**.
  A comment with no words offers only `Edit word by word`.
- **Example** (the acceptance test): dictated `// Stands in for Casey's static dword operation inside the
  callback`, then Word case > dword > UPPER, Word case > operation > Capitalized, Backticks > static >
  `static DWORD Operation` ->
  ``// Stands in for Casey's `static DWORD Operation` inside the callback``. Also `// todo logging` ->
  Word case > todo > UPPER -> `// TODO logging`.
- **Rules & edge cases**: these menus are labeled with the document's own words, so the heatmap ignores them.
  A comment with more than 12 words gets its word list sorted alphabetically, case-insensitively (the
  `Word case` / `Backticks` group is opened by `menu_select`'s generic children branch, `push_menu` ->
  `make_view`, which sorts lists longer than `BUCKET_THRESHOLD` = 12 with `label_less`); comments of up to 12
  words keep text order (the handmade test's 12-word comment does). Comment edits never trigger rename.
- **Source**: src/model/text_tools.odin (`comment_words`, `word_labels`, `text_tools_menu` case
  `COMMENT_KIND`, `text_tool_apply` ops `wcase:<i>` / `tick:<i>:<j>`, `replace_words`).

### F14. Word-by-word editing: entering, moving, yellow dots

- **Trigger**: pick **`Edit word by word`** in a string's or comment's text tools (F12/F13).
- **Behavior**:
  - The cursor goes *inside* the text. The text is split into **words** (`word_tokens`): runs of non-space
    characters, with these split out as their own words even when glued to neighbors: format verbs (`%v`,
    `%08.3f`: `%`, flags from `+-#0123456789.*[]`, then a letter; `%%`), escapes (`\` + one char; `\x` + up to 2
    hex, `\u` + up to 4, `\U` + up to 8), and braces `{{`, `}}`, `{:...}` (no space or `{` inside). A `%`
    followed by a space stays part of the word (`100%`). Pinned:
    `x: %v, y=%08.3f\n {{done}} {:v} 100% sure` -> `x:` `%v` `,` `y=` `%08.3f` `\n` `{{` `done` `}}` `{:v}`
    `100%` `sure`.
  - **Stops**: a **yellow dot** before every word and after the last (n words = n+1 dots), alternating with
    the words: stop `s` in `0..2n`; odd `s` = word `s/2`, even `s` = dot `s/2`. The cursor starts on the first
    word (stop 1), or on the only dot of an empty text (stop 0).
  - **Left / Right** (plain, `keys.rest`) step one stop (clamped, no wrap). **B** (plain) leaves word-by-word
    mode (back to the whole field, not out of the editor). `word_edit_update` runs in `update` after the
    Reference picker and Grab and before the keymap actions, and returns "used" for every frame, so Up/Down and
    every layout action do nothing ("like Grab"), except: Talk (F17), the word menus (F15/F16), delete (F17),
    the IDE-menu action (resolved globally before the editor; Format file / Key layout / Exit, and word editing
    stays active underneath), and the app's fixed shortcuts Ctrl+C (copy), RB (run favorite) and LB (run
    tests), which src/app/main.odin handles before `model.update` without checking word editing.
  - **Rendering**: the field is drawn word by word; every gap and both ends get a 16-px-wide slot holding a
    small amber dot (`COL_WORD_DOT` = (0.90, 0.68, 0.05), radius 3); the cursor's dot is radius 4 with a pulsing
    halo (radius 7 to 8.5, `sin(4t)`). Original spacing is not drawn (tabs inside a word are expanded). The
    cursor's word gets the normal selection box; nothing else on that line (e.g. the string's quotes) is
    highlighted.
  - **Title-bar hint**: on a word `A change   RT+B delete   B done`; on a dot `A insert   LT+X say words   B done`.
  - **Staying on target**: after every update the field is found again by its ordinal among the line's
    string/comment text fields (`word_nth`), because syncs can insert fields before it (a capture dot, result
    parentheses); if it is gone, word editing ends.
- **Source**: src/model/word_edit.odin (`word_tokens`, `word_special_len`, `word_edit_ok`, `word_edit_start`,
  `word_edit_sync`, `word_edit_end`, `word_edit_on`, `word_edit_update`, `word_edit_hint`);
  src/model/model.odin (`update`: `word_edit_update` runs before the keymap, `defer word_edit_sync`);
  src/app/editor_view.odin (`layout_node` `word_fi`, `Item.wstop`, `draw_word_dot`).

### F15. Word-by-word: the Change word menu (on a word)

- **Trigger**: on a word: plain **A** (`keys.rest.confirm`, the fixed Select slot), **RT+X** (raw
  `inp.rt_held && inp.x`) or plain **Y** (raw `inp.y` with no trigger held). RT+X and Y are hard-coded and do not
  follow the layout (with the default layout RT+X is Refactor and Y is Change, both swallowed here).
- **Behavior**: menu **`Change word`**: `UPPER`, `Capitalized`, `lower`, `` `backticks` `` (wrap the word),
  **`Replace with`** > the same special groups as Insert (F16; picking one replaces the word), `Delete`. After a pick the menu closes, the
  cursor is on the changed word, and word editing continues.
- **Rules & edge cases**: `` `backticks` `` is hidden in a raw `` `...` `` string (it cannot hold a backtick). B
  in the menu backs out; at the root it returns to word editing with no change. Group submenus keep their
  authored order (`word_menu_push`, never alphabetized). None of these picks count for the heatmap.
- **Example**: `"hello world"`, on `world`: UPPER -> `"hello WORLD"`; `` `backticks` `` -> ``"hello `WORLD`"``;
  on `hello`: Replace with > Integer > `%d` -> ``"%d `WORLD`"``.
- **Source**: src/model/word_edit.odin (`word_menu_open`, `word_menu_push`, `word_tool`, `word_replace`).

### F16. Word-by-word: the Insert menu (on a yellow dot) and spacing rules

- **Trigger**: on a yellow dot: A, RT+X or plain Y.
- **Behavior**: menu **`Insert`** listing groups; each item's label is `<text>   <explanation>` (three spaces)
  and inserts `<text>`. For a string (Odin's `core:fmt` verbs):
  - `General`: `%v` the value in a default format; `%#v` expanded %v, with newlines and indentation; `%w` an
    Odin-syntax representation of the value; `%T` an Odin-syntax representation of its type; `%%` a literal
    percent sign; `{{` a literal open brace; `}}` a literal close brace; `{:v}` same as %v (Python-like).
  - `Boolean`: `%t` the word true or false.
  - `Integer`: `%b` base 2; `%c` the character for the Unicode code point; `%r` same as %c; `%o` base 8; `%d`
    base 10; `%i` base 10; `%z` base 12; `%x` base 16, lower-case a-f; `%X` base 16, upper-case A-F; `%U`
    Unicode format: U+1234; `%m` bytes in the best unit, e.g. 123.45mib; `%M` bytes in the best unit, e.g.
    123.45MiB.
  - `Float / complex`: `%e` scientific, e.g. -1.23456e+78; `%E` scientific, e.g. -1.23456E+78; `%f` decimal
    point, no exponent: 123.456; `%F` same as %f; `%g` %f with default maximum precision; `%G` same as %g; `%h`
    hexadecimal (lower-case), 0h prefix; `%H` hexadecimal (upper-case), 0H prefix.
  - `String / bytes`: `%s` the uninterpreted bytes; `%q` double-quoted, escaped with Odin syntax; `%x` base 16,
    lower-case, two per byte; `%X` base 16, upper-case, two per byte.
  - `Slice / array`: `%p` address of the 0th element, base 16, 0x.
  - `Pointer`: `%p` base 16 (upper-case), leading 0x; `%b` `%d` `%o` `%z` `%x` `%X` as an integer in that base.
  - `Enum`: `%s` the name of the enum field; `%i` / `%d` / `%f` as a number.
  - `Escapes` (not in raw strings): `\n` new line; `\t` tab; `\r` carriage return; `\"` double quote; `\\`
    backslash; `\e` escape (terminal colors); `\0` zero byte.
  - `Symbols` (30, bare labels): `` ` `` `'` `(` `)` `[` `]` `{` `}` `<` `>` `:` `;` `,` `.` `!` `?` `-` `_` `=`
    `+` `*` `/` `&` `|` `#` `@` `$` `^` `~` `%` (no `` ` `` in a raw string).
  - For a **comment**, the Insert menu (and Replace with) is **only `Symbols`**.
- **Spacing rules** (`word_insert` at dot k):
  - Empty text: the item becomes the whole text (no spaces).
  - **Glue left** (no space before, attaches to the previous word): anything starting with `\` (escapes) and
    `. , ! ? : ; ) ]`, when there is a previous word.
  - **Glue right** (attaches to the next word): `(` and `[`, when there is a next word.
  - Otherwise: after a previous word insert `" " + item`; at the first dot insert `item + " "`. So a glue-left
    item at the first dot (`! hello`) and a glue-right item at the last dot (`world (`) are spaced normally.
  - The cursor goes to the word starting at the insertion point (`word_focus_at`). A glued symbol that is not a
    special token becomes part of its neighbor's word (`world` + `!` = one word `world!`; `(` + `brave` = one
    word `(brave`), so the cursor lands on that merged word; escapes, verbs and braces stay separate words.
- **Examples** (test): `"hello brave world"`; dot after `hello` > General > `%v` -> `"hello %v brave world"`;
  end dot > Escapes > `\n` -> `"hello %v brave world\n"`; Left (to the dot before `\n`) > Symbols > `!` ->
  `"hello %v brave world!\n"`. Comment `// fix the thing`, dot after `fix` > Symbols > `:` -> `// fix: the thing`.
- **Rules & edge cases**: the verb groups are offered for every non-comment string, whether or not it is a
  format string, and not filtered by argument types.
- **Source**: src/model/word_edit.odin (`SP_GENERAL` .. `SP_SYMBOL`, `special_groups`, `word_insert`,
  `GLUE_LEFT`, `GLUE_RIGHT`, `word_focus_at`).

### F17. Word-by-word: delete and dictation

- **Trigger**: delete: **RT+B** (hard-coded) or the button bound to Delete (default LT+B) on a word.
  Dictation: Talk while word editing.
- **Behavior**:
  - `word_delete`: removes the word and the whitespace after it; when nothing follows (the word is glued to the
    next, or is last), removes the whitespace before it (and trailing whitespace). The cursor goes to the word
    now at that index, or the last word, or stop 0 when the text is empty. On a dot, delete does nothing.
  - `word_dictated` (the app routes here when word editing is active on the captured target): on a word, the
    heard text replaces that word; on a dot, it is inserted there with the F16 spacing rules (multi-word text is
    one item).
- **Example** (test): `"hello brave world"` on `brave`, RT+B -> `"hello world"`, cursor on `world`; delete
  everything -> `""` at stop 0; dictate "brand new" -> `"brand new"`.
- **Source**: src/model/word_edit.odin (`word_delete`, `word_dictated`); src/app/main.odin.

### F18. Number keypad

- **Trigger**: Edit (LT+A) on a number field: an editable field of kind `""` whose text starts with a digit
  (made by Value > Number, which inserts an editable `0`, doc 06; or by dictation). A number loaded from a file
  (fixed text) is first made editable, unless it starts with `-`.
- **Behavior**: a radial menu titled **`Number`** with 20 keys in this fixed order (no sorting; a 5-column
  grid, 4 rows): `1 2 3 4 5` / `6 7 8 9 0` / `A B C D E` / `F 0x . Del OK`. Each key edits the number **in
  place, live** (`keypad_apply`), and the keypad stays open:
  - digit or `A`-`F`: appended; the default `0` is replaced by the first key (`0` + `7` = `7`); `A`-`F` only
    after `0x`.
  - `0x`: only when the text is exactly `0` (-> `0x`).
  - `.`: only in a decimal number without a `.` yet.
  - `Del`: drop the last character; `0x` or a single character becomes `0`.
  - `OK`: close.
  - After every key, keys that would change nothing are **grayed** (`keypad_dims`; `OK` and `Del` never are):
    e.g. `A`-`F` before `0x`, `0x` once the number is not `0`, `.` in hex or after a `.`, and `0` on a lone `0`.
    A grayed key does nothing.
- **Rules & edge cases**: **B closes the keypad and keeps the edits** (there is nothing to restore; it is the
  same as OK, except that OK also re-focuses the field). No keys for `-`, `_`, exponents, `0b`, `0o`. Keypad keys
  do not count for the heatmap. The keypad can leave text that is not a number: `0x` then OK (or `Del` on
  `0x5`) leaves `0x` in the source (only `Del` on exactly `0x` falls back to `0`); nothing but the background
  `odin check` (doc 07 §14) would catch it. Such a `0x` is no longer `is_number_text`, so Talk on it switches to
  Identifier mode (code reading).
  A dictated `1e5` or `1_000` is edited by appending like any decimal.
- **Example** (test): `WHITENESS :: 0`, LT+A, `0x 0 0 F F 0 0 6 2 7 Del OK` -> `WHITENESS :: 0x00FF0062`;
  LT+A, `Del`, B -> `WHITENESS :: 0x00FF006`. `x := 5` (loaded) LT+A `7` -> `x := 57`.
- **Rationale**: "`0x00FF0062` without a keyboard" (src/model/expr.odin comment).
- **Source**: src/model/expr.odin (`NUM_KEYS`, `NUM_KEY_FILL`, `is_number_field`, `number_keypad_open`,
  `keypad_apply`, `keypad_dims`, `number_key`); src/model/model.odin (`edit_selected`, `menu_select`).

### F19. Rename with propagation

- **Trigger**: a user edit of a name through Talk (Identifier or Free_Text dictation not in word mode; Number
  dictation writes through `dictate_number` / `set_field_text` and never asks) or through a text tool that
  changed the text (`rename_field`). Internal updates use `set_field_text` directly and never ask.
- **Behavior**:
  - The new text is written first. Then, if the field **declares** a name that has **uses in its scope**, a
    radial menu opens, titled **`Rename <old> to <new>?`** with two entries: **`Rename all <n> uses`** (or
    **`Rename the other use`** when n = 1; n counts occurrences, not lines) and **`Only this one`**.
    **Bug at baseline (the label actually shown for n = 1):** rename.odin `rename_offer` builds the label with
    `fmt.tprintf(uses == 1 ? "Rename the other use" : "Rename all %d uses", uses)`, so the one-use format
    string has no verb for the extra argument and Odin's fmt appends `%!(EXTRA 1)`
    (C:/Odin/core/fmt/fmt.odin writes `"%!(EXTRA "` for unused arguments). The cell therefore reads
    **`Rename the other use%!(EXTRA 1)`** (doc 04 §20 hits it with a `#config` constant). The intended label is
    `Rename the other use`; a port should build the two labels separately.
  - `Rename all ...` rewrites every whole-word use in the recorded fields; `Only this one` keeps them; **B**
    also means "only this one" (the new declaration name stays). After a pick the menu closes and the cursor is
    put on the renamed field (`rename_choose`); B (`menu_cancel` -> `rename_clear`) just closes, and the cursor
    is still where the edit left it (on the field).
  - **Declares?** (`field_declares`): a procedure parameter (the field sits inside `proc(` ... before `)`); a
    loop/if/switch header's own variables; otherwise lines starting with `if for switch when case return defer
    import package foreign` never declare, and only a name **left of** the declaration operator declares
    (`y := x`: `x` is a use).
  - **Scope** (`rename_scope`): file-scope declarations (constants, globals, procedures, types) -> the whole
    file; parameters -> their procedure; loop/if/switch header variables -> that block; other locals -> from
    the declaration to the end of the enclosing block.
  - **Shadowing**: a line in range that redeclares the same name (not the declaration itself) is skipped
    together with the rest of *its* scope.
  - **What counts as a use** (`code_word_hits`): a whole word in code: not inside `"..."`, `'...'` or
    `` `...` `` (backslash escapes honored except in raw), not after `//`, not after a `.` (a field or package
    member), not followed by an identifier character, and not a `name =` key right after `{`, `(` or `,` (a
    struct-literal field or named argument; `==` is still a use). Each field's text is scanned on its own, so
    the `{` / `(` / `,` and the `//` rules only see what is inside the same field (struct-literal keys are
    separate `litkey` fields and excluded anyway).
  - Excluded fields: slots, kinds `string`, `comment`, `litkey`, `label`, and the renamed field itself. The
    renamed field must be editable, not a slot, not kind `string`/`comment`/`litkey`/`label`/`member`, the text
    must actually change, and both old and new text must be identifiers (`is_ident`: `[A-Za-z_][A-Za-z0-9_]*`;
    keywords are **not** rejected, so renaming to `for` propagates).
  - Fields of kind `member` are *not* excluded from the scan (code reading; no test covers it). Renaming a
    file-scope `count`: a struct member line `count: int,` parses as a declaration (`decl_text_declares`), so
    it is treated as a shadowing redeclaration and it and the rest of that struct body are skipped; but an enum
    member `count,` or `count = 5,` is not a declaration, so it is counted as a use and renamed by "Rename all".
  - **Labels** are handled separately and silently: `set_field_text` on a loop's or labeled block's label also
    renames its `break`/`continue` targets (doc 05).
- **Example** (test):

  ```odin
  // before                         // after "total" + Rename all 2 uses
  count := 1                        total := 1
  y := count                        y := total
  if true {                         if true {
      count := 2                        count := 2      // shadowed: untouched
      z := count                        z := count
  }                                 }
  w := count                        w := total
  // other :: proc() { q := count }  stays: another scope
  ```

  `WHITENESS :: 5` renamed to `WHITE`: `Rename all 2 uses` updates `operation: int = WHITE` and
  `x := WHITE + 1` but not `"WHITENESS"` or `// WHITENESS in a comment`.
- **Rules & edge cases**: only the open file changes; other files of the package are never edited (P12, doc 00).
  Changing a *use* (`count = 2`) never asks. Renaming back to a name with no uses asks nothing. The prompt's
  menu is not recorded in the heatmap.
- **Source**: src/model/rename.odin (`rename_field`, `rename_uses`, `field_declares`, `line_redeclares`,
  `name_field`, `rename_scope`, `code_word_hits`, `replace_code_word`, `rename_offer`, `rename_choose`,
  `rename_apply`, `rename_clear`); src/model/model.odin (`menu_select` `rename_active`, `menu_cancel`);
  src/model/label_refs.odin (`label_rename_jumps`).

### F20. Save as / Rename dialog

- **Trigger**: **Save as**: the `Save as` action (not on any button in `KEYMAP_DEFAULT`; the Key Layout page
  can place it; a keys file saved before `Save` existed keeps `rt y save_as`, pinned by
  `test_keymap_old_save_as_layout`). The required actions (always exactly one button) are Delete, Files and
  Save, not Save as. **Rename**: in Files, **LT+X** on a file or folder, or on the "here" tab (the folder you are
  in). The plain `Save` action (default RT+Y) never asks: a new document is written as `main.odin` in its
  project folder with the status `saved main.odin in <folder name> - rename it in Files (LT+X)`; later saves say
  `saved <name>`; a failure says `SAVE FAILED: could not save: <err>` (src/app/save.odin `save_now`,
  `save_current`).
- **Behavior**: a centered panel over a veil, above the HUD; it owns all input while open.
  - Title `SAVE AS` (with the save icon) or `RENAME <current name>`.
  - **Name box**, prefilled with the current file's name (or `main.odin`) / the file or folder name. The
    prefill is shown **selected**: the first typed character, Space or dictation replaces it. Backspace removes
    one character (of the prefill too) and ends the "fresh" state. Once edited, a caret blinks after the text
    (on 0.5 s, off 0.5 s: `int(g_time * 2) % 2`). While dictating, `[REC]` (red) sits at the right end of the
    box and the box outline turns red.
  - **Pad**: A save/rename; B cancel; hold X to say a name (F10).
  - **Keyboard**: letters/digits/`-`/`.` type (lowercase only; F21); **Space types `_`**; Backspace deletes;
    Enter saves; Esc cancels.
  - **Preview line**: `in <folder>`, or when cleaning changes the name `saves as <final>  in <folder>` /
    `renames to <final>  in <folder>`.
  - **Hint**: `A save    B cancel    hold X to say a name    (keyboard: type)` (or `A rename ...`); without
    an STT engine `A save    B cancel    (keyboard: type a name)`.
  - **Name cleaning**: Save as uses `clean_filename`: trim; keep `[A-Za-z0-9_-.]`, drop every other byte
    (so no path separators); space/tab -> `_`; trim leading/trailing `.` and `_` (no leading dot, and a bare
    `..` becomes empty; an inner `a..b` survives but cannot climb without separators); `""` or `odin` ->
    refused; append `.odin` if missing. Pinned: `../../evil/path` -> `evilpath.odin`, `  Hero-2 ` ->
    `Hero-2.odin`, `.odin` and `***` -> refused. Rename uses `clean_rename`: same characters; a folder takes the
    cleaned name as is; a file keeps its old extension unless the new name has a `.` (`todo` for `notes.md` ->
    `todo.md`; `todo.txt` stays); a new name equal (case-insensitively) to the old extension without its dot is
    refused (`odin` for `main.odin`, `md` for `notes.md`); a file with no extension (`run`) takes the name as is.
  - **Save commit**: empty -> error `Type or say a file name first`; target = the current file's folder, else
    the project folder (created on demand). Saving over a *different* existing file needs a second A:
    `<name> already exists - press A again to overwrite` (amber). A write failure shows `could not save: <err>`.
    Success closes the dialog. Any edit clears a pending overwrite or error.
  - **Rename commit**: empty -> `Type or say a name first`; unchanged (same base name, case-sensitive) -> just
    close; another existing entry -> `<name> already exists`; OS failure -> `Could not rename: <err>`; on success
    (`filenav_renamed`) an open file that was renamed stays open under its new name, and a renamed folder
    carries along the open file, the previous (alt-tab) file, the project folder, Files' root and view when
    they were inside it. A case-only change is allowed because `same_path` compares paths with `\` -> `/` and
    **case folded on every OS** (the code comment says "on Windows"). On the "here" tab, a projects folder or a
    drive root is refused before the dialog opens, with the status
    `<name> holds your projects - Doodle doesn't rename it` / `a drive can't be renamed` (`rename_target`
    only checks this for the "here" tab, not for a highlighted grid entry).
- **Rules & edge cases**: the Rename dialog does not overwrite another entry, with one hole (code reading): on a
  case-sensitive file system, renaming `a.odin` to `A.odin` while a separate `A.odin` exists passes the
  case-folded `same_path` check, and `os.rename` replaces `A.odin`. The file-I/O side (where saves go, Files) is
  doc 09.
- **Source**: src/app/save_dialog.odin (all); src/model/projects.odin (`clean_filename`, `clean_rename`);
  src/app/save.odin (`save_now`, `save_folder`, `write_doc`); src/app/filenav.odin (`filenav_rename`,
  `rename_target`, `filenav_renamed`); src/model/keymap.odin (`.Save_As`, `.Save`).

### F21. Keyboard typing and the Steam Deck on-screen keyboard

- **Trigger**: a physical keyboard, or the Deck's Steam on-screen keyboard (Steam + X), while the Save as /
  Rename dialog is open. (Whether the Steam keyboard delivers SDL key-down events in every mode is unverified;
  the README says Steam + X works.)
- **Behavior**: typing works only from SDL key-down *keysyms* (`handle_key`): `a`-`z`, `0`-`9`, `-`, `.` are
  recorded as typed characters (up to 32 per frame, not while Ctrl is held). Shift is not read, so **no
  uppercase and no `_`** except Space -> `_`. SDL text-input events are not used by the app (no
  `SDL_StartTextInput` / `TEXTINPUT` handling anywhere in src/platform or src/app). Nowhere else accepts typing:
  only src/app/save_dialog.odin reads `raw.typed` / `e_space` / `e_backspace`; the code is never typed into, and
  the Files search has no keyboard text input despite the README saying "Typing (file names, Files search)".
- **Rules & edge cases**: the same keys are also the pad stand-ins (`key_pad_button` / `handle_key`: `x` = X,
  `y` = Y, `w a s d` and the arrow keys = d-pad, `q`/`e` = LT/RT held, Enter/Space = A, Backspace/Esc = B,
  `r` = RB, `t` = LB, Ctrl+C = copy); inside the dialog the typed text is handled first, then Space (types `_`
  and stops), then Backspace (deletes and stops), and only then B/Esc and A/Enter, so letters like `a`/`d` never
  navigate there. A stand-in key held down also counts as a held pad button for Talk (F2), and keyboard `x`
  dictates into the Files search (F10) but not into the Save/Rename dialog. README Deck table:
  "Use the on-screen keyboard (Steam + X), or plug in a keyboard. Doodle works without typing otherwise."
  Doodle has **no on-screen keyboard of its own**: the gamepad keyboard in docs/UX.md ("Pillar D") and the
  "on-screen keyboard" for renames in docs/EDITOR_MODEL.md §4 were never built; the keypad, text tools and
  word-by-word specials replaced them.
- **Source**: src/app/main.odin (`Raw.typed`, `handle_key`, `key_pad_button`); src/app/save_dialog.odin.

## Invariants & constraints to carry forward

1. **HARD** — Speech fills exactly one leaf (the field captured when recording starts) and never runs commands.
   The only structure it adds is what the target itself implies: a value dot becomes a literal, and an "another
   return value" dot gets its `, ` (F9). The cursor stays on, or is put back on, that field (word mode: on the
   word). A rename prompt may follow (F19). (Enforced by construction in main.odin's dictation block; no test.)
2. **HARD** — The mic is offered only where words fit: a name, a string's text, a comment's text, a number
   literal, or a value dot that takes a number. Otherwise Talk does nothing and its HUD button does not pulse.
   (`dictation_target`; `test_dictate_number_into_value_dot` pins a `string` dot as `None`.)
3. **HARD** — The way words are cleaned depends on the target's kind: names become lowercase `snake_case`
   (snapped to known names, whose case the snap can carry in, F5), strings/comments keep spaces and case,
   numbers are parsed to number text or refused with a message. (stt_test.odin, dictation_test.odin.)
4. **HARD** — Talk is a hold on a face button; d-pad Down while talking is a word boundary; auto-repeat is off
   while talking. (`keymap_allows`, keymap tests, main.odin.)
5. **HARD** — While recording and while transcribing, editor input is masked; the words are applied in clip
   order, once all clips are back. (Masking: main.odin main loop and `editor_input`, not under test; order:
   `test_async_transcribes_in_order`, which silently passes when no whisper checkout is present.)
6. **HARD** — No STT engine is never an error: everything except speech keeps working, Talk's HUD button never
   pulses, and the Save/Rename dialog drops its `hold X` hint (the Files search keeps its static speech hint;
   F4). (`init` returns nil; `g_mic_ready`; every `stt` call is nil-safe.)
7. **HARD** — Every tool edits text through one setter (`set_field_text`); every *user* name change goes through
   `rename_field`, which offers propagation only for a declaration with uses in scope; internal edits never ask.
8. **HARD** — Rename touches whole-word code uses only, within the declaration's scope, skipping shadowed
   regions, strings, comments, member accesses and struct-literal/named-argument keys; never other files.
   (rename_test.odin.)
9. **HARD** — B on the rename prompt keeps the new name and leaves the uses alone (the edit already happened).
10. **HARD** — Text-tool and word menus close on a pick and keep the cursor on the same field (word mode stays
    active after a word-menu pick); B at a menu root changes nothing. Exceptions by design: `Replace value`
    turns into the fill menu, `Edit word by word` enters the mode, and a name change may open the rename
    prompt. (word_edit_test.odin; text tools by the handmade build test.)
11. **HARD** — Word-by-word mode consumes every model input except its own (A/RT+X/Y menu, Delete/RT+B, B,
    Left/Right) and the global IDE menu; Talk (handled by the app) still works, and so do the app's fixed
    shortcuts Ctrl+C / RB / LB. B leaves the mode, not the editor. (`test_word_edit_enter_and_move`: plain X
    ignored, B leaves only the mode.)
12. **HARD** — Keypad keys that would not change the text are grayed and do nothing (`keypad_dims`, pinned by
    `test_expr_number_keypad`). SOFT: the keypad only approximately keeps the text a valid number; it can leave
    `0x` behind (F18), so a Rust version should gray `OK` (and B should restore) when the text is not a number.
13. **HARD** — File names from dialogs are sanitized: no path separators, no leading dots, `.odin` added on Save
    as, the extension kept on Rename (pinned by projects_test.odin). Rename refuses another existing entry
    (except the case-fold hole, F20) and Save as over another file needs a second A (save_dialog.odin; not under
    test).
14. **SOFT** — Speech is for one word or a short phrase; spoken punctuation is not relied upon (escapes and
    symbols come from menus).
15. **SOFT** — Menus whose labels are the document's own words (comment words, rename prompt) are excluded from
    the heatmap.
16. **SOFT** — Insert spacing follows prose/format-string habits: escapes and closing punctuation glue left,
    `(`/`[` glue right, everything else is space-separated.

## Data model & formats

- **Field** (doc 01): `text`, `editable`, `slot`, `kind`, `hint`, `hint_pkg`. Kinds this area reads: `""` (a
  name, or a number when it starts with a digit), `string` (text inside quote fields), `comment` (COMMENT_KIND),
  `member` (struct/enum member names), `litkey` (struct-literal key), `label`, `type`, `poly`; slot kinds
  `value` and `ret_more` (number targets).
- **Dictation_Mode**: `None | Identifier | Free_Text | Number`.
- **stt.Config**: `cli_path`, `model_path`, `grammar_path` (unused by the app), `prompt`, `vocabulary`,
  `free_text`, `tmp_wav`, `tmp_txt`. **stt.Engine**: `cfg`, SDL capture device, `available`, `recording`,
  worker thread, mutex + condition variable, `jobs` (FIFO of `{cfg copy, pcm bytes}`), `done` (FIFO of texts),
  `quit`, `clip_no`.
- **App-side dictation state** (src/app/main.odin globals): `recording`, `busy`, `clips` (queued count),
  `parts` (texts received), `mode`, `free`, target `(ni, fi)`, `vocab`, `prompt`, `heard`, `mic_ready`,
  `talk_stale`.
- **Model state** (App): word editing `word_edit_active`, `word_ni`, `word_fi`, `word_stop`, `word_nth`; rename
  prompt `rename_active`, `rename_ni/fi`, `rename_old/new`, `rename_hits: [](ni, fi)`; menus use the shared
  `slot_menu`, `slot_ni`, `slot_fi`, `return_state`, navigation stack (doc 01).
- **Menu entry encodings** (string-typed in Odin; make them an enum in Rust):
  - `TXT_FILL "__txt__"`: `call_name` = `case` (arg = style label), `esc` (arg = escape), `wcase:<i>` (arg
    `upper|cap|lower`), `tick:<i>:<j>`, `words`, `refill`.
  - `WORD_FILL "__word__"`: `ins` / `rep` (arg = text), `case` (`upper|cap|lower`), `tick`, `del`.
  - `NUM_KEY_FILL "__num_key__"`: the key is the label.
  - `RENAME_FILL "__rename__"`: `all` / `one`.
- **Word stops**: integer `s` in `[0, 2n]`; odd = word `s/2`, even = dot `s/2` (dot k precedes word k).
- **Case_Style labels**: `snake_case`, `UPPER_SNAKE`, `Ada_Case`, `camelCase`, `PascalCase`, `Joined`.
- **Files**: temp `doodle_stt_capture.wav` / `doodle_stt_out.txt` (+ `.<n>.wav` / `.<n>.txt` per async clip);
  WAV = 44-byte PCM header + s16le mono 16 kHz; whisper output = plain text on stdout; GBNF grammars in
  assets/stt/ (`root ::= " " ...`); model `ggml-base.en.bin`; release layout `bin/whisper-cli[.exe]` +
  `models/ggml-base.en.bin`.
- **Trace**: STT results are recorded as `str stt <text>` marks and fed back on replay; meta `stt 0|1` says
  whether an engine existed (doc 11, docs/TRACE.md).

## Tests that pin this behavior

| Test | File | Asserts |
|---|---|---|
| `test_spoken_number` | src/model/dictation_test.odin | 22 accepted phrasings with exact outputs; 9 refusals (F9) |
| `test_is_number_text` | dictation_test.odin | `0 10 3.5 1_000 0x1F 0b101 1e9 2.5e-3 -2` accepted; `"" x 1.2.3 0..<10 0x 1a - a1` refused |
| `test_dictate_number_in_loaded_struct_literal` | dictation_test.odin | every loaded value in `point{x = 10, y = 0, z = 0}` is a Number target; dictating 7 and 2.5 gives the exact source; the variable name stays Identifier |
| `test_dictate_number_into_value_dot` | dictation_test.odin | an `int` dot takes `12` and stays editable; a `string` dot is mode None |
| `test_keypad_on_loaded_number` | dictation_test.odin | LT+A on loaded `5` opens `Number`, `7` gives `x := 57` |
| `test_expr_number_keypad` | src/model/expr_test.odin | dims before/after `0x`, `0x00FF0062` key sequence, B keeps a Del, `keypad_apply` table |
| `test_word_tokens` | src/model/word_edit_test.odin | the special-token split (F14) |
| `test_word_edit_enter_and_move` | word_edit_test.odin | Y menu = `Replace value | Case | Escape | Edit word by word`; stops; plain X ignored; B leaves the mode only |
| `test_word_edit_insert_specials` | word_edit_test.odin | `%v` spaced, `\n` and `!` glued; saved source; B in menu stays in mode |
| `test_word_edit_change_and_delete` | word_edit_test.odin | RT+B delete, UPPER, backticks, Replace with `%d`, delete to empty, dictate into empty |
| `test_word_edit_replace_value` | word_edit_test.odin | Replace value opens the refill; B restores |
| `test_word_edit_comment` | word_edit_test.odin | comment Insert menu is only `Symbols`; `fix: the thing` |
| `test_rename_constant_everywhere` | src/model/rename_test.odin | prompt title and labels; strings/comments untouched |
| `test_rename_local_respects_scope_and_shadowing` | rename_test.odin | the F19 example |
| `test_rename_parameter_and_decline` | rename_test.odin | Only this one; no prompt without uses; B = only this one |
| `test_rename_no_prompt_for_a_use` | rename_test.odin | a use is not a declaration |
| `test_code_word_hits` | rename_test.odin | member access, struct-literal key, `==` |
| `test_clean_filename`, `test_clean_rename` | src/model/projects_test.odin | sanitizing tables (F20) |
| handmade exact build | src/model/handmade_exact_build_test.odin | a whole Win32 program built with "dictation" = `set_field_text` of lowercase snake_case / spaced words, then text tools and keypad |
| `test_snap_*` (4), `test_clean_free_*` (2) | src/stt/stt_test.odin | snapping and free-text cleaning (F5/F6) |
| `test_whisper_command_quoting` | stt_test.odin | per-OS quoting; no `--grammar` by default |
| `test_async_transcribes_in_order` | stt_test.odin | three queued clips (speech, silence, speech) come back in order, silence = `""`; skipped without whisper |
| keymap tests (Talk) | src/model/keymap_test.odin | LT+X is Talk by default; Talk never `fired` (a hold); `keymap_holding` true with LT (RT ignored), false without LT; Talk refused on RT+Up (`Not_Here`) and a swap that would push Talk onto the d-pad is refused |
| `test_keymap_old_save_as_layout` | keymap_test.odin | an old keys file `rt y save_as` keeps Save as on RT+Y (F20) |

Implementer note: Doodle's model tests never touch audio; they simulate dictation by writing the text a
dictation would produce. Keep that seam.

## Carrying this to Rust

### (a) What transfers unchanged

- The gating table (F1): speech is offered per leaf kind, with the HUD showing when it is possible.
- Hold-to-talk on a face button, d-pad Down as a word boundary, input masked while recording/transcribing,
  target captured at record start, clips transcribed in the background and applied in order.
- Three cleaning modes (identifier / free text / number) plus deterministic post-processing (snap to known
  names, spoken-number parser). Port `spoken_number`, `is_number_text`, `case_words`/`recase`,
  `word_tokens`, `keypad_apply`, `clean_filename` as pure functions with the same test tables.
- Text tools as small menus that apply one transformation and close; word-by-word with alternating word/dot
  stops and glue rules; keypad with grayed no-op keys; rename prompt after the edit, B = only this one.
- Dialogs that accept speech, keyboard and pad equally, sanitize names, and confirm destructive overwrites.

### (b) Odin-specific pieces and their Rust analog

- `libc.system` + shell quoting -> `std::process::Command::new(cli).args([...])` and read `output()?.stdout`
  (no shell, no quoting bugs, no command-line length trap from cmd.exe, no temp text file; whisper-cli still
  reads its audio from the `-f` WAV file); on Windows set `CREATE_NO_WINDOW` via
  `std::os::windows::process::CommandExt::creation_flags(0x0800_0000)`. Check `output.status.success()`
  (Doodle ignores the exit status).
- SDL2 queued capture (`DequeueAudio`) -> rust-sdl2 `AudioSubsystem::open_capture` with a callback pushing
  `i16` samples into a channel/ring buffer (SDL converts to the requested 16 kHz mono format); or `cpal` plus
  your own resampling.
- Hand-written WAV -> `hound`, or skip files entirely with an in-process engine (below).
- Worker thread + `sync.Mutex`/`sync.Cond` + heap-allocator juggling -> `std::thread` + `std::sync::mpsc`
  (jobs in, `(clip_no, String)` out); ownership moves through the channel, so the "which allocator frees it"
  comments disappear.
- `when ODIN_OS == .Windows` -> `cfg!(windows)` / `#[cfg(windows)]`.
- String-encoded menu ops (`"wcase:3"`, `"tick:2:4"`, `"__num_key__"`) -> enums, e.g.:

  ```rust
  enum LetterCase { Upper, Capitalized, Lower }
  enum TextOp {
      Case(CaseStyle),
      Escape(&'static str),
      WordCase { word: usize, to: LetterCase },
      Backticks { first: usize, last: usize },
      WordByWord,
      Refill,
  }
  enum WordOp { Insert(String), Replace(String), Case(LetterCase), Backticks, Delete }
  enum KeypadKey { Digit(u8), Hex(u8), HexPrefix, Point, Del, Ok }
  enum RenameChoice { All, One }
  ```
- Byte-indexed ASCII string code -> careful UTF-8: Whisper can emit non-ASCII (`é`, curly `’`); slicing
  `&s[a..b]` at a non-char boundary panics. Normalize first (map smart quotes to ASCII, `deunicode` for
  identifiers) and use `char_indices` where text may be non-ASCII.
- `levenshtein` -> `strsim::levenshtein` (keep "first match at distance 1, tokens >= 3 chars").
- Global app state (`g_recording`, `g_stt_parts`, ...) -> one `Dictation` struct owned by the app.

### (c) Rust concepts this area needs that Odin lacks

- **Naming conventions per item kind** (rustc lints `non_snake_case`, `non_camel_case_types`,
  `non_upper_case_globals` warn otherwise). Doodle dictates every name as `snake_case` and leaves recasing to
  the user; in Rust the slot knows its kind, so apply the convention automatically and keep the Case tool as an
  override:

  | Item | Convention | Generated default (doc 01 analog) |
  |---|---|---|
  | crates, modules, files (`.rs`) | `snake_case` (no `-` in module names) | `brave_otter` |
  | functions, methods, locals, parameters, fields, pattern/closure bindings, macros | `snake_case` | `brave_otter` |
  | structs, enums, unions, traits, type aliases, enum variants | `UpperCamelCase` (acronyms as words: `HttpServer`, `Uuid`) | `BraveOtter` |
  | generic type parameters | `UpperCamelCase`, usually one letter | `T`, then `U`, `V` |
  | `const`, `static`, const-generic parameters | `SCREAMING_SNAKE_CASE` | `BRAVE_OTTER` |
  | lifetimes | short lowercase after `'` | `'a`, then `'b`; `'static` and `'_` are fixed choices, not names |

  Doodle's `capitalized` (rest lowered: `DWORD` -> `Dword`) already matches Rust's acronym rule for
  UpperCamelCase. A lifetime slot would show a fixed `'` field plus an editable name; dictating "a" gives `'a`.
- **Keywords and raw identifiers**: validate dictated names (Doodle does not). If the result is a keyword
  (`type`, `match`, `move`, `ref`, `fn`, `impl`, `dyn`, `async`, `await`, `loop`, `mod`, `crate`, `self`,
  `Self`, `super`, reserved `abstract become box do final macro override priv typeof unsized virtual yield try
  gen`), offer `r#type` or `type_` (`self`/`Self`/`super`/`crate` cannot be raw). A leading digit should become a
  refusal or a `_` prefix. Leading `_` marks an intentionally unused binding.
- **Literal kinds**: Text tools and word-by-word must know the literal:
  - `"..."` str: escapes `\n \r \t \\ \0 \' \" \x00..\x7F \u{...}`; a trailing `\` continues the line.
  - `r"..."`, `r#"..."#`: no escapes; when the text contains `"`, add hashes automatically: one more `#` than
    the longest run of `#` that follows a `"` in the text (`a"b` needs `r#"a"b"#`; `a"#b` needs `r##"..."##`).
  - `b"..."`: ASCII only plus `\xHH`; `br"..."` raw bytes; `c"..."` / `cr"..."` C strings (no interior NUL).
  - `'c'` char: exactly one Unicode scalar or one escape; `b'c'` one ASCII byte. Dictation into a char slot
    should take one letter or refuse ("Heard "..." - not one character"), the analog of the number refusal.
  - **Escape dictated free text** for the target literal (`"` and `\` in a normal string). Doodle does not.
- **Format strings are macros**: `format!`, `println!`, `write!`, `panic!`, `assert!` and friends use `{}`
  placeholders, not `%` verbs. Replace the Insert groups with: `{}` Display, `{:?}` Debug, `{:#?}` pretty
  Debug, `{:x}` `{:X}` `{:o}` `{:b}` `{:e}` `{:E}`, `{:p}`, width/fill/align (`{:>8}`, `{:08.3}`, `{:+}`),
  positional `{0}`, `{{` `}}`, and **named captures `{name}` listed from the names in scope**. Offer them only
  when the string is the format argument of such a macro, gray `{}` for a type that is not `Display` and say
  why (P6), and keep placeholder count in sync with the macro's arguments (a dot per missing argument).
  The tokenizer must split `{...}` placeholders, `{{`/`}}` and `\u{...}` escapes.
- **Numbers**: suffixes (`1u8`, `2.0f32`, `10_usize`), `0x`/`0o`/`0b`, `_` separators, exponents; negation is
  the unary `-` operator. Extend the keypad with `0o`, `0b`, `_`, `e`, and a "Suffix" key whose list is filtered
  (and grayed with a reason) by the expected type. Note `1.` is a valid float but `1.f32` is not (it parses as
  a field access); `0x1f32` is one hex integer, not `0x1f` with an `f32` suffix (there are no hex float
  literals), so hex digits `e`/`f` and float suffixes must not be offered together; `1e5` is a float. Unlike
  Doodle's keypad, refuse to close on text that is not a literal (Doodle can leave `0x`, F18).
- **Doc comments**: `///`, `//!`, `/** */` are Markdown: Backticks fits as is; add a "Link" word tool that wraps
  a word as `` [`Name`] `` (an intra-doc link) choosing from in-scope items.
- **Rename semantics**: Rust shadowing in the *same* block is idiomatic (`let x = x.trim();`): the right-hand
  `x` refers to the old binding, so a line-based "skip the redeclaring line" rule is wrong for Rust. Field-init
  shorthand (`Point { x }` -> `Point { x: total }`), struct patterns, closure parameters, match-arm bindings,
  `use` paths, trait methods and their impls, macro token trees (`{x}` inside `println!`), and `pub` items used
  by other modules all need semantic rename. Decide whether the "edits never leave the open file" rule (P12)
  survives: rust-analyzer's rename returns a workspace edit across files; either show "N uses in other files"
  and apply only with an explicit choice, or keep same-file only and warn.
- **Modules and file names**: a Rust source file name is a module name: `clean_filename` must map `-` and
  spaces to `_`, append `.rs`, and renaming a file must update its `mod name;` line (rust-analyzer
  `workspace/willRenameFiles`). `main.rs`, `lib.rs`, `mod.rs` are special. Cargo package names may use `-`.

### (d) Implementation advice

- Keep the model pure: the model only receives "heard text for target X in mode M" events; a
  `SpeechEngine` trait (`begin`, `split`, `end`, `poll -> Option<String>`) with a real whisper implementation and
  a scripted fake for tests and trace replay. Route the dialogs through the same async path (show
  `transcribing...` in the dialog) instead of Doodle's second, blocking path.
- whisper-cli per clip reloads the model every time (noticeable on the Deck). Start with the subprocess (crash
  isolation, matches Doodle), then consider `whisper-rs` (whisper.cpp bindings) on a dedicated thread with the
  context loaded once, greedy sampling, `language = "en"`, no timestamps, an initial prompt, and f32 PCM passed
  directly (no files). whisper.cpp also has GBNF grammar support; wire grammars for number and char slots if
  accuracy needs it (Doodle ships the grammars but never uses them).
- Build the vocabulary from **scope**, not the whole document: rust-analyzer completions at the target (locals,
  fields, items, imported names) plus a small Rust word list (`self Self new default len iter map collect
  unwrap Some None Ok Err Vec String Option Result`). Dedupe; cap the prompt length.
- Use rust-analyzer for rename (`textDocument/prepareRename` to know whether the leaf declares something and
  whether the new name is valid; `textDocument/rename` for the edit) and keep Doodle's prompt UX on top: count
  the uses, show `Rename <old> to <new>?`, apply only on "Rename all". Fall back to a tree-sitter-rust or
  `ra_ap_syntax` scope walker when rust-analyzer is not ready.
- Use the syntax tree's literal tokens (tree-sitter-rust `string_literal`, `raw_string_literal`,
  `char_literal`; or `ra_ap_syntax` `ast::String` / `ByteString` / `CString` / `Char`) to choose escape menus,
  and validate the edited literal with a Rust unescaper before writing it (the `rustc-literal-escaper` crate;
  older `ra_ap_rustc_lexer` releases expose the same code as `unescape`; check the version you pin).
- `heck` gives Rust-correct case conversions but splits words differently from `case_words` (it splits
  `HTTPServer` into `HTTP` + `Server`); either port `case_words` exactly or adopt `heck` and update the test
  tables deliberately.

## Open questions & known gaps

1. **GBNF grammars are unused.** `Config.grammar_path` is never set by the app (docs/STT.md says numeric fields
   use number.gbnf; they do not). Numbers rely on a prompt plus `spoken_number`.
2. **docs/STT.md is partly stale**: it says gating is deferred and LT+X "always listens" (the mic is gated by
   `dictation_target`), that whisper runs synchronously (the editor is asynchronous now; dialogs are not), and
   hard-codes LT+X (Talk is rebindable).
3. **Save as has no default button.** save_dialog.odin's header still says "RT+Y: Save as" (RT+Y is `Save` now);
   docs/EDITOR_MODEL.md §5 says "Delete, Save as and Files always have a button", but the code's required
   actions are Delete, Files and Save.
4. **README vs code on typing**: the README lists "Files search" under keyboard typing; the search reads no typed
   keys. Typing is lowercase-only everywhere (no Shift handling, `_` only via Space).
5. **Files search with spaces**: a dictated multi-word query keeps spaces, so it cannot match `snake_case` file
   names.
6. **Dictated text is not escaped or validated**: quotes/backslashes can break a string or rune literal; a rune
   `'...'` accepts many words; names may start with a digit (propagation is then silently skipped because
   `is_ident` fails) or be keywords (`is_ident` accepts `for`, so a keyword name even propagates to its uses).
7. **Escape tools on raw strings and runes**: the LT+A `Escape` group is offered for `` `...` `` and `'...'`
   literals (word-by-word correctly hides escapes for raw strings).
8. **Member names**: struct fields and enum members (kind `member`) accept dictation but have no text tools, so
   an enum member dictated as `north` cannot be recased to `North` without voice; renaming a member never
   propagates (uses after `.` are excluded by design).
9. **No cancel and no silence gate**: releasing Talk always transcribes; Whisper's silence hallucinations
   ("you", "thank you") can overwrite a name (docs/STT.md suggests a VAD/energy gate "later").
10. **Prompt size**: the identifier prompt contains every editable field text of the document (strings included,
    duplicates and empty texts kept); on large files it exceeds Whisper's prompt window (whisper.cpp keeps the
    last ~224 tokens, so the instruction and common words drop out first; unverified), and on Windows it can
    exceed cmd.exe's 8191-character command line or break on an embedded `"` (F3). The commit message promised
    "in-scope identifiers"; the code uses the whole document.
11. **Hard-coded buttons in word-by-word** (confirmed in `word_edit_update` / `word_edit_hint`): RT+B delete,
    RT+X and plain Y open the menu regardless of the layout (only plain A/B/Left/Right, which are locked, and
    the Delete action follow the layout), and the title-bar hints name `RT+B` and `LT+X` even if Talk was moved
    (`word_edit_hint` replaces the hint after `rebind_hint` and is never rebound). With Talk rebound to plain Y
    or RT+X, that button opens the word menu instead of dictating (F2).
12. **Keypad**: B keeps the edits (unlike most menus, nothing is restored); no `-`, `_`, exponent, `0b`, `0o`
    keys; a loaded negative number cannot be keypad-edited (LT+A does nothing on it: it stays fixed text and
    has no text tools); a dictated negative number (`-2`) gets the Case menu on LT+A instead of the keypad, and
    any case style there drops the minus; `0x` + OK leaves an invalid literal.
13. **Rename heuristics are line-based**: a redeclaring line is skipped whole, so in `x := x + 1` (inner block)
    the right-hand use of the outer `x` is not renamed; scope detection relies on brace counting and text
    prefixes. "Only this one" knowingly leaves code that no longer compiles (the checker shows it).
14. **Comment word lists over 12 words are alphabetized** by the generic menu builder, unlike the word-by-word
    menus which keep their order.
15. **Uncertain**: whether the Steam on-screen keyboard always delivers key-down events (Doodle ignores SDL
    text-input events); the README says Steam + X works.
16. **Rename and members**: member names are scanned as possible uses (F19): an enum member spelled like a
    renamed file-scope name is renamed with it, while a same-named struct member line hides the rest of its
    struct body as "shadowed". Neither is under test.
17. **Rename and case**: `same_path` folds case on every OS, so on Linux/SteamOS a case-only rename onto a
    different existing file overwrites it (F20).
18. **Target check after background dictation** is a bounds check only (F8); it relies on the editor taking no
    input meanwhile, not on identifying the field.
19. **One-use rename label bug**: the n = 1 entry of the rename prompt renders as
    `Rename the other use%!(EXTRA 1)` (an unused `fmt.tprintf` argument, F19). Docs 00, 01, 04 and 06 quote the
    intended `Rename the other use`; build the two labels separately in a port.

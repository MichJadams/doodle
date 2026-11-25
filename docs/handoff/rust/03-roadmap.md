# 03 — Roadmap, risks and acceptance tests

> **Status.** This doc is authoritative for *order and acceptance*: what gets built in which milestone, which
> tests prove it, what can go wrong, and what to do when it does. `rust/01-architecture.md` owns *mechanism*
> (crates, protocols, persistence, budgets). `features/` (the Doodle spec) and `rust/02` (the Rust construct
> taxonomy) own *behaviour*. If this doc contradicts rust/01 on mechanism, rust/01 wins, and the contradiction is a
> doc bug to report to the owner.
>
> **Citations.** These follow rust/01:
> - `P7` is principle 7 in `features/00`.
> - `features/06 F15` and `features/05 §10` are feature-doc sections. Docs 03, 06, 08, 09 and 10 number
>   sections with `F`; docs 01, 02, 04, 05, 07 and 11 use `§`.
> - `D7` is a rust/01 decision, `O5` a rust/01 owner decision, and `S1` a rust/01 spike.
> - `rust/02 §5.3 Assignment` is a construct-taxonomy section. Numbers follow the taxonomy draft. If rust/02 has
>   been renumbered, match by the title given after the number.
> - `NS0` to `NS2` are the north-star programs (see "North-star acceptance test"), and `R7` is a risk in this
>   doc's register.
>
> **Facts checked on 2026-11-24.**
> - The NS2 reference is rustfmt-clean, clippy-clean (`-D warnings`), compiles, and passes its one test. This was
>   checked with local `rustc 1.96.1` and `rustfmt 1.9.0`, against a stub that carries minifb 0.29.0's documented
>   signatures. Those signatures were checked on docs.rs:
>   - `Window::new(&str, usize, usize, WindowOptions) -> Result<Window>`, `set_target_fps(&mut self, usize)`,
>     `is_open(&self) -> bool`, `is_key_down(&self, Key) -> bool`, and
>     `update_with_buffer(&mut self, &[u32], usize, usize) -> Result<()>`;
>   - `minifb::Error` implements `Display` and `std::error::Error`;
>   - `Key::{Left, Right, Up, Down, Escape}` exist;
>   - `WindowOptions` implements `Default`.
>
>   The newest minifb on crates.io is 0.29.0 (2026-10-03).
> - The NS1 reference is byte-identical to `listings/ch02-guessing-game-tutorial/listing-02-06/src/main.rs` on
>   rust-lang/book `main` (sha256 `b54117bed799aa845eb05a797a5ee7cc8e20cdfb616bc8ecfe30c4921cff3a3e`, 36 lines,
>   813 bytes). That listing's `Cargo.toml` asks for `rand = "0.10.1"`. The newest rand is 0.10.4 (2026-11-15).
> - `cargo new` (cargo 1.96.1) writes exactly the NS0 `Cargo.toml` and `src/main.rs` given below, and
>   `cargo add rand@0.10.1` adds exactly the line `rand = "0.10.1"`.
>
> **Re-run every one of these checks at M0 on the pinned 1.100.0 toolchain and the real crates** (S5).
>
> **Placeholder name.** `doodle-rs` (O1), as in rust/01.

---

## How to use this doc

1. Before you write product code, read three things in full: rust/01 "Summary" and "The per-frame contract",
   `features/00`, and "Milestone rules" below. Then start the spikes this doc puts in the M0 window (S2, S3, S4,
   S5). S4 and S5 need a Steam Deck.
2. Build the milestones in order. A milestone is **done** when all of these hold:
   - every named exit test exists and is green in CI. "In CI" means the `ci.yml` run on a pushed
     `wip/<milestone>` branch when the owner allows pushing; otherwise `cargo xtask ci-local` green on the
     builder's host, with the CI jobs reported as `not run (no push)` (PROMPT "HOW TO WORK");
   - the "Definition of done per feature" items hold for everything it shipped;
   - its milestone report (`docs/milestones/Mn.md`) is committed.

   Owner-only items (a demo with a real pad, Deck checks, the O3 readability note) are reported as
   `owner pending` and don't block done.

   Never start the features of M(n+1) while an exit test of Mn is red. Spikes, docs and fixtures may run ahead.
3. Each milestone lists the owner decisions that are due by its end. If the owner hasn't answered, build the
   rust/01 default and say so in the milestone report.
4. When a spike fails, take its fallback and write the result to `docs/spikes/Sxx.md`. Then update the affected
   milestone scope in this doc (the copy that lives in the new repo, `docs/design/03-roadmap.md`) and in
   `docs/features/`.
5. Use the test names in this doc as written. Adding more tests is fine. Renaming a named test needs one line in
   the milestone report.

---

## Milestones at a glance

| M | Name | Demo at the end (controller only) | North-star stage | Owner decisions due | Spikes done before it starts |
|---|---|---|---|---|---|
| M0 | Walking skeleton | Window with the HUD; main menu; New Project; A on the one green dot; Functions > Function; RT+Y saves a Cargo package that `cargo run` builds | `ns_m0_fn_main_package_builds` | O2, O15 (after S5), O16, O23 | none (S2-S5 run during M0) |
| M1 | Controller complete; trace | Every button and bank as in features/03; the IDE menu; the cursor reaches every stop; every debug run is recorded and replays headless in CI | — | O3 | S4 (or `device pending`) |
| M2 | Projects and persistence | New Project asks where; Recent Projects; Save as; settings and roots files in the per-user data dir | — | O9, O18 | — |
| M3 | Document model, file-scope items, names | Build typed structs, enums, fns and consts; rename by (fake) voice; undo; crash recovery | `ns2_stage_types` | O4, O6 | S2, S3 |
| M4 | Function bodies | Statements, calls, macros, control flow, text tools; NS0 | `ns0_hello_world_exact` | O19, O20 | — |
| M5 | Type oracle v1, typed menus | Dots show expected types; menus gray with reasons; the settle gate | `ns2_stage_step` | O5, O22 | S1, S7, S8 |
| M6 | First vertical slice: names, methods, modules, dependencies | Build the Rust Book guessing game | `ns1_guessing_game_exact`, `ns2_stage_*` (a-f) | O11, O12, O21 | S10, S11 |
| M7 | Load any Rust file; NS2 exact | Open real crates, edit them, save byte-exact; build handmade-rs from the main menu | `ns2_handmade_exact_build` | O10 | — |
| M8 | Diagnostics, repair, Docs, Grab | Red/amber shading, Fix entries, borrow repairs, LT+Y docs, moving lines | `ns2_repair_drill` | O13 | S12, S13 |
| M9 | Voice and rename | A real microphone; rename with a prompt | NS0 by real voice (manual) | — | S6 |
| M10 | Files, Run, Setup | Files grid, Run list, RB runs; Setup installs the toolchain on the Deck | NS2 runs on the Deck (manual) | O7, O8, O17 | S5 (device result) |
| M11 | Polish, parity, hardening, release | Key Layout, heat, icons and sounds, self-update, release packages, Deck bench | press budgets frozen | O1, O14 | — |

The order mirrors Doodle's own build (features/11 §25 and the git history). There are three deliberate
differences:
- the trace arrives at M1, not late;
- the oracle is designed in at M0 and lands at M5;
- loading arbitrary code is a projection, so it can't drift from the menus (D3). M7 proves this over a corpus
  rather than building a second loader.

### Spike track

The spikes are rust/01's S1 to S13. Each spike writes `docs/spikes/Sxx.md` (question, setup, numbers, verdict,
decision taken). Spike code lives in `spikes/` and is never imported by a product crate.

| Spike | Timebox | Needs a Deck | Must be done before | Exit criterion (rust/01) | Becomes this permanent test |
|---|---|---|---|---|---|
| S1 oracle expected types at 10 positions | 3 d | latency part only | M5 | ≥ 8 of 10 answer, none wrong; warm p95 ≤ 150 ms | `oracle_conformance_suite` |
| S2 projection and round trip (std + 20 crates), hole matrix, std blob size | 2 d | timing part only | M3 | 100% byte-exact; 5k lines ≤ 4 ms; every hole kind round-trips; blob ≤ 10 MB | `corpus_round_trip_byte_exact`, `hole_matrix_items`, `every_hole_kind_reloads_as_the_same_hole` |
| S3 layout engine vs rustfmt | 2 d | no | M3 (item cases), M4 (statement cases) | every menu-producible statement passes `rustfmt --check` | `layout_matches_rustfmt_on_menu_corpus`, `every_m4_statement_matches_rustfmt` |
| S4 SDL3 gamepad under Steam Input, glow + fontdue at 60 Hz | 2 d | yes | M1 (desktop-only M0 is acceptable) | every button and trigger maps; frame p99 ≤ 8 ms | manual Deck checklist in every milestone report |
| S5 Zig `cc` wrapper links an SDL3 hello-window; **plus**, added by this roadmap, `cargo build` of NS1 (rand) and NS2 (real minifb 0.29.0) on the Deck through the same wrapper, and `cargo check` + `cargo test` of NS2 against the real crate on Windows and Ubuntu | 2 d | yes | O15 is answered at M0; the device result is needed by M10 | builds, links and runs in Game Mode | `ns_*` compile tests in CI; the M10 manual run |
| S6 whisper-cli vs whisper-server | 1 d | yes | M9 | numbers decide phase 2 | dictation latency bench |
| S7 oracle RSS and cold load | 2 d | yes | M5 | sets the memory cap and `prefill_caches` defaults | `oracle_rss_reported_and_restart_backoff` (logic) + Deck numbers |
| S8 replay determinism with recorded oracle events | 1 d | no | M5 | 10 identical replays; identical with the oracle binary deleted | `replay_with_recorded_oracle_events_is_deterministic` |
| S9 no false grays on NS1/NS2 | 2 d | no | M5 exit | zero false grays; ≥ 30% useful grays | `no_false_gray_on_corpus` |
| S10 method menus for 10 receivers, d-pad cost by BFS | 2 d | no | M6 | max ≤ 12 presses, median ≤ 6 | `method_menu_reaches_any_method_within_12_presses` |
| S11 derives and proc macros; which component ships the server | 1 d | no | M6 | std derives visible with no server; serde with `Sysroot` | `derived_clone_listed_without_proc_macro_server` |
| S12 borrow-error repair coverage (about 30 errors) | 2 d | no | M8 | ≥ 60% fixable with one pick | the `e0xxx_*` exit tests of M8 |
| S13 `cargo check` / `cargo build` times on the Deck, disk use, mirror correctness | 1 d | yes | M8 | warm check ≤ 3 s, cold ≤ 90 s | the M8 check bench |

**No Deck yet?** S4 (Steam Input, Game Mode) needs the device: mark it `device pending` with no container run.
S5, S7 and S13 may run inside the Steam Linux Runtime "sniper" SDK container (D19) on an x86-64 Linux host (not
under emulation on the owner's ARM64 Windows machine) to unblock the design; mark each result `device pending`.
Device numbers are required before M5 (S7), before M10 (S5) and before M11 (the bench).

---

## Milestone rules

**Exit-test kinds** (the "Kind" column of the exit tables):

| Kind | Meaning |
|---|---|
| `press` | Drives `doodle_core::update` with `Input`s through `doodle-testkit`'s `Pad`. Requests are serviced by `MemExecutor` (MemFs, `FakeFacts` or a cassette, `FakeSpeech`, `FakeRunner`), and the results are fed back in empty-pad settle frames until quiescent, with at most 64 settle frames (rust/01 per-frame contract rule 9). Testkit seams may put the cursor or highlight anywhere (features/11 §4 "unit tests may teleport"). |
| `exact` | Controller-exact, with no seams after setup. Cursor moves are d-pad `Input`s found by `dpad_to`. Menu picks are BFS d-pad paths found by `menu_go`, then A. Y, LT+B, LT+A, RT+Y and the rest are real `Input::combo` presses under the default keymap. Text comes only from `pad.dictate(..)` (Talk held on the target, `FakeSpeech` returns the words). This is stricter than Doodle, whose exact test called `change_selected`/`delete_selected` directly (features/11 §6). Setup may seed `MemFs` with files and open them through Recent Projects presses (from M2). |
| `unit` | A pure function, tested next to its code. |
| `prop` | A `proptest` property. CI uses fixed seeds; failures are persisted and committed (`proptest-regressions/`). Long random runs go to the weekly job. |
| `snap` | An `insta` snapshot of data: `Scene`, menu label lists, the HUD model, parsed records. Never a pixel snapshot, and never used for north-star text (those compare to literal reference files). |
| `compile` | Writes the produced program to a temp crate and runs the pinned `cargo` / `rustfmt` through `doodle_testkit::compile::{build, run, test, rustfmt_check}`. Marked `#[ignore = "compile"]` and run by CI step 4 (`cargo nextest run --run-ignored all`; **verify** the flag at the pinned nextest). Serialized across nextest's per-test processes by an exclusive `std::fs::File::lock` on `<CARGO_TARGET_DIR>/doodle-compile.lock`, with one shared `CARGO_TARGET_DIR` (rust/01 D19; a `static Mutex` would not serialize anything under nextest). A package with dependencies (NS1, NS2) gets its committed `Cargo.lock` copied in and runs with `--locked --offline` after a warm `cargo fetch --locked`. A package with no dependencies (NS0, the M0 package, every `compile_matrix_*` crate) has no lockfile, so it runs with `--offline` only: `cargo build --locked` refuses to create a missing `Cargo.lock` (checked with cargo 1.96.1). |
| `trace` | A committed fixture under `tests/traces/`, replayed headless by `committed_traces_replay_headless`. |
| `oracle` | Runs the real `doodle-oracle` against fixture crates, in the oracle CI job. |
| `timing` | Asserts a budget from rust/01 "Performance and memory budgets", with a CI factor. The clock is read by the test, never by the core. |
| `manual` | A checklist item. The numbers or screenshots go in `docs/milestones/Mn.md`. Screenshots are always scripted: the debug-only `--script <file> --screenshot <png>` at M0 (one button or combo per line, then one frame read back with `glReadPixels`), `--replay <trace> --screenshot` from M1 on. Items that need the owner's hands or a Deck are reported `owner pending` / `device pending` and don't block done. |

**Where tests live.**
- Core press and exact tests go in `crates/core/tests/<area>.rs`, named by area, not by milestone: `main_menu`,
  `keymap`, `cursor`, `add_menu`, `items`, `names`, `statements`, `values`, `types`, `text`, `facts`, `methods`,
  `deps`, `loader`, `diagnostics`, `voice`, `files`, `run`, `setup`, `persistence`, `north_star`. Milestones end;
  areas stay.
- Core test files never call `std::fs`, `std::process` or `std::env` directly: `crates/core/clippy.toml`'s bans
  apply to them under `cargo clippy --all-targets`. Compile checks go through
  `doodle_testkit::compile::{build, run, test, rustfmt_check}`, and metadata through
  `doodle_testkit::metadata`. `core_depends_on_no_platform_crates` lives in `xtask` (rust/01 DAG rule 6).
- Pure unit tests live next to the code.
- App-side pure helpers (gate, supervisor, checker debounce, setup scripts) are unit-tested in `doodle-app`, and
  CI runs those tests. Doodle never ran its app tests (features/11 open question 2).

**Every milestone's exit implicitly includes:**
- all earlier exit tests;
- `idle_frame_is_identity`, `same_inputs_same_fingerprint` and `core_depends_on_no_platform_crates`;
- `cargo clippy --workspace --all-targets -- -D warnings` and `cargo xtask lint-deps`;
- the core test time staying under 15 s;
- `committed_traces_replay_headless`;
- `cargo xtask doc-check` (from M1; see "Working conventions").

From M1 on, each milestone also commits at least one fixture trace of its demo (`tests/traces/mN-<demo>/`),
recorded in the real app or produced without a pad by `Pad::save_trace` or `cargo xtask trace script`. The north-star exact tests save the inputs they fed as traces too (`Pad::save_trace`),
so every NS build is also a replay fixture.

**Style of an exit test** (the testkit API names are our own decisions; the shape matters):

```rust
// crates/core/tests/add_menu.rs
#[test]
fn first_function_is_main() {
    let mut pad = Pad::new(Boot::test(seeds::M0));            // App in MainMenu; MemExecutor; FakeFacts
    pad.new_project();                                        // presses: New Project (+ "where?" from M2)
    pad.dpad_to(Stop::insert_dot(0));                         // d-pad presses only; fails if unreachable
    pad.press(Button::A);
    assert_eq!(pad.menu_title(), "Add  (insertion point)");
    pad.menu_go(&["Functions", "Function"]);                  // BFS over the core's real grid navigation, then A
    pad.combo(Trigger::Rt, Button::Y);                        // Save
    assert_eq!(pad.fs().bytes(&pad.project_dir().join("src/main.rs")), b"fn main() {}\n");
    assert_eq!(pad.cursor().role(), Role::Name(NameRole::Fn)); // cursor on the new name (rust/02 R15)
}
```

---

## Milestones

### M0 — Walking skeleton

**Goal.** Prove the whole pipe end to end with the smallest real slice:
- SDL3 window and gamepad → `Input` → pure `update` → `Scene` → glow paint, with the HUD drawn from the live
  keymap;
- main menu → New Project → an empty `src/main.rs` with one green dot → A → Add menu → Functions > Function →
  `fn main() {}` → RT+Y writes a Cargo package that `cargo run` builds;
- the workspace, CI and testkit that every later milestone stands on.

**Scope.**
- **Workspace** as in rust/01 "Workspace layout", with all thirteen crates created:
  - `doodle-oracle` is a stub binary with no `ra_ap` dependency until M3;
  - `pins.toml` and `rust-toolchain.toml` (1.100.0);
  - exact pins in `[workspace.dependencies]`, including the "pin at M0" crates, checked on crates.io now;
  - `crates/core/clippy.toml` with the purity bans (D1), and `#![forbid(unsafe_code)]` where D1 says.
- **Core.**
  - `Button`, `Input` (with `press`/`combo`/`event` helpers), and only the `Event` and `Request` variants M0 uses:
    `Wrote`, `FileOp`; `Write`, `CreateDir`, `Status`, `Quit`.
  - `Boot` with `seed` (SplitMix64) and `projects_dir`, `App`, `update`, and `fingerprint`, which feeds the
    hand-written `doodle_formats::fnv1a64` (D16).
  - `Mode::{MainMenu, Editor, Menu}`.
  - The keymap with the complete default table (features/03 F4, F5, with Undo on LT+Down per O6), every row of
    rust/01 D11 "ActionInfo for the Rust IDE" (Undo and Redo included), and resolve (F6). The HUD model
    (features/03 F9; D13 `view::scene`), with O23's fixed-control HUD on the main menu and in menus.
  - **Unbuilt actions** are drawn dimmed in the HUD, and pressing one sets the status `<label>: not built yet`.
    This is P6 and P13 applied to the IDE itself; the same rule holds in every later milestone.
- **Main menu** (features/09 F1, features/10 F18):
  - title `DOODLE-RS`, subtitle `Rust IDE  -  gamepad native`, window title `doodle-rs`; no footer line (the
    HUD names the buttons, O23);
  - entries `New Project`, `Recent Projects`, `Open Folder`, `Key Layout`, `Settings`;
  - all but New Project are refused grays with the reason `not built yet`;
  - B quits (`Request::Quit`). Every trigger + face press is swallowed on the main menu (so LT+B and RT+B don't
    quit and LT+A / RT+A don't select, which fixes features/00 open question 10), except the IDE-menu combo
    (LT+Left), which sets the status `IDE menu: not built yet` until M1.
- **New Project.** No "where?" page yet. It uses `Boot.projects_dir`, a generated `adjective-animal-NNNN` name
  (one draw from `App.rng` per New Project, rust/01 "Project names"; features/09 F5's lists), and an empty
  in-memory `src/main.rs`. Nothing is created until the first save.
- **Document** (D3, subset). `doodle_syntax::Document` over `ra_ap_syntax` for an empty file and `fn` items.
  `project` emits the module-scope insert dots, the `●` row of an empty block, the params dot and the `ret` hole
  (the D4 table rows "Return type", "Optional lists" and "`●` row"). No `⊙` item-options dot yet: it arrives
  with M3's item options. An empty `{}` body is drawn as three rows (rust/01 D3.3).
- **Cursor** (features/02 §1-3, §7): Up and Down between stops, Left and Right along a line. The stops of a file
  holding only `fn main() {}`, in Down order: the top insert dot; the header row `fn`, `main`, `○params`,
  `●ret` (Left/Right move along it); the `●` row; the bottom insert dot. The `}` continuation row has no stop,
  and `(`, `)`, `{`, `}` are never stops (rust/02 R9). An empty file has exactly one stop, the insert dot.
- **Add menu** (features/04 §1; rust/02 §3.1 "Opening it, and the group tree"):
  - the nine root groups with their exact labels;
  - `Functions` lists all six leaves in order; only `Function` is lit, and the other five are refused grays
    with the reason `not built yet`;
  - the other eight groups are gray with the reason `not built yet` and open to the dimmed placeholder
    `(not built yet)`;
  - every "not built yet" entry is `Gray::Refused` (no heat).
- **Function construct** (rust/02 §3.4 "Functions", the `Function` row; features/04 §9; P5):
  - the first fn in a binary crate root that has no `main` is `fn main() {}`, drawn `fn main(○)●ret {` / `●` /
    `}`;
  - later ones are drawn `fn brave_otter(○)●ret {` / `●` / `}` (the blue ret dot, no `->` in the text) and saved
    `fn brave_otter() {}`, one blank line after the previous item (rust/02 "Opening it");
  - A on the params dot, the ret hole or the `●` row opens a menu titled `Fill slot` (subtitle
    `the result type` on ret) with one dimmed placeholder `(not built yet)`.
- **Cancel and delete.** B at the Add menu root restores the document byte-identical (P9; features/02 §20). LT+B
  on the `fn` keyword or the name removes the whole item and one adjacent blank separator (features/02 §17,
  minimal; rust/02 "Opening it").
- **First save** (RT+Y; features/09 F9). Each request goes out only after the previous one's event came back
  `Ok`, so a worker can't reorder them or run past a failure:
  1. `CreateDir <projects_dir>/<folder>` (missing parents are created; it fails if the folder exists);
  2. `CreateDir <folder>/src`;
  3. `Write Cargo.toml` with `WriteMode::Create` (the exact `cargo new` bytes for the generated name, with
     `edition = "2024"` as the O18 default);
  4. `Write src/main.rs` with `WriteMode::Create`.

  After the last `Wrote`: status `saved src/main.rs in <folder>`, where `<folder>` is the project folder's
  name, not its path. Any error: `SAVE FAILED: <reason>`; an existing folder gives
  `SAVE FAILED: <folder> already exists`. A later RT+Y sends one `Write src/main.rs` with `WriteMode::Replace`
  and the status `saved src/main.rs`. The features/09 suffix ` - rename the project in Files (LT+X)` is added
  when Files ships (M10).
- **Platform and render** (D12, D13):
  - SDL3 window at 1280x800, gamepad with positional buttons, keyboard stand-ins (features/03 F17);
  - d-pad auto-repeat as a pure tick function (features/03 F2) that takes `suppress_repeat`
    (`App::repeat_suppressed()`, D11);
  - glow batched quads; a fontdue + etagere atlas with the embedded DejaVu Sans Mono; the paper palette
    (features/10 F5);
  - code rows with dots (features/10 F10), menus as grids (features/10 F16), and the three-bank HUD with ASCII
    glyphs (icons come at M11);
  - the debug-only `--script <file> --screenshot <png>` for scripted screenshots (see the `manual` kind).
- **App.** The per-frame contract loop from rust/01, with a minimal executor (`Write`, `CreateDir`) on a worker
  thread.
- **Testkit.** `Pad`, `press`, `combo`, `new_project`, `menu_go` (BFS over the core's grid navigation, exposed
  under the `testkit` feature), `dpad_to`, `pick`, `labels`, `dimmed`, `back_out`, `MemExecutor` with `MemFs`,
  settle-until-quiescent, and `doodle_testkit::compile` (file-locked cargo and rustfmt runs).
- **CI and tooling.**
  - `ci.yml` (D19) steps 1, 2 and 4 on `ubuntu-22.04` and `windows-latest`, with the SDL3 build prerequisites
    of D19;
  - a Windows ARM64 build-and-core-tests job on `windows-11-arm` (O16; **verify** the label);
  - `cargo xtask lint-deps` (DAG rules 1-7) and `cargo xtask ci-local` (fmt, clippy, lint-deps, nextest
    including compile tests).
- **References.** The north-star reference files are committed under `tests/north_star/` now, so the targets exist
  from day one (see "Reference files in the repo"). The `main.rs` sources, `ns1/NOTICE`, `regions.toml` and the
  `.gitattributes` lines come first; `seeds.toml`, the `Cargo.toml` files, the NS1 and NS2 `Cargo.lock` files
  and `SHA256SUMS` are written once the project-name generator exists, from its real output.

**Deliverables.**
- The crates and `ci.yml`.
- `docs/features/README.md`, plus the sections for what M0 built (see "Working conventions").
- `docs/spikes/S2.md` to `S5.md`, as far as they got.
- `docs/milestones/M0.md` with two scripted screenshots (`--script … --screenshot`): the main menu, and the editor
  after the fn insert.
- `tests/north_star/` with NS0, NS1 and NS2, `SHA256SUMS`, `seeds.toml`, and the root `.gitattributes` lines.

**Exit criteria.**

| Test | Kind | Asserts |
|---|---|---|
| `idle_frame_is_identity` | prop | `update(app, Input::idle_after(&prev))` (no edges, no events, the previous frame's levels; rust/01 per-frame rule 3) changes no fingerprint and returns no request, from random reachable states |
| `same_inputs_same_fingerprint` | prop | two `App`s fed the same 500 random `Input`s have equal fingerprints every frame |
| `core_depends_on_no_platform_crates` | unit (xtask) | `cargo metadata`: DAG rules 3 to 5 of rust/01 |
| `fnv1a64_standard_vectors` | unit (formats) | `""` hashes to `0xcbf29ce484222325` and `"a"` to `0xaf63dc4c8601ec8c`; string mixing appends `0xff`; integers are 8 LE bytes |
| `keymap_default_table_matches_features03_f4` | unit | every slot of the LT, plain and RT banks, plus LB/RB, as features/03 F4 (Undo on LT+Down); every `ActionInfo` key, label, glyph and hint as rust/01 D11 |
| `hud_model_per_bank` | snap | in the editor: active bank by trigger (LT wins when both are held), glyph per slot, unbuilt actions dimmed; on the main menu and in a menu: only the live controls (O23), every other slot blank and dim |
| `unbuilt_action_says_not_built_yet` | press | pressing a dimmed action sets the status `<label>: not built yet` and changes nothing else |
| `main_menu_items_and_dimmed_reasons` | press | title and subtitle; 5 entries in order; 4 refused with the reason `not built yet`; A on one does nothing |
| `main_menu_b_quits_but_trigger_b_does_not` | press | B → `Request::Quit`; LT+B, RT+B, LT+A and RT+A → no request and no change; LT+Left → the status `IDE menu: not built yet` |
| `new_project_shows_one_green_dot` | exact | Editor mode, empty text, exactly one stop (the insert dot), cursor on it |
| `project_name_is_deterministic_from_seed` | unit | same seed, same names; matches `^[a-z]+-[a-z]+-[0-9]{4}$`; the first three names for `seeds::M0` equal the literals written in the test (the rust/01 mapping, frozen at M0) |
| `add_menu_root_has_nine_groups_in_order` | press | title `Add  (insertion point)`; labels exactly as rust/02 §3.1; Functions shows six leaves with five refused `not built yet`; the eight other groups gray with that reason |
| `first_function_is_main` | exact | saved text `fn main() {}\n`; cursor on `main`; the stops are exactly the M0 "Cursor" list |
| `second_function_is_brave_otter_with_params_and_ret_dots` | exact | A on the bottom insert dot after `main` > Functions > Function; saved `fn main() {}\n\nfn brave_otter() {}\n`; params dot and ret hole are stops; the generator counter starts at `brave_otter` (features/00 P5 lists) |
| `b_at_add_menu_root_restores_byte_identical` | exact | text, revision and cursor equal to before A |
| `lt_b_on_fn_removes_item` | exact | the item and one adjacent blank separator are gone (the one after it, else the one before); deleting the only item leaves empty text; the cursor is on the insert dot |
| `first_save_writes_cargo_package` | exact | MemFs sees `CreateDir <folder>`, `CreateDir <folder>/src`, `Cargo.toml` (Create; bytes as NS0's template with the seeded name) and `src/main.rs` (Create), in that order, each sent after the previous event; status `saved src/main.rs in <folder>`; a second RT+Y sends one Replace write; an existing folder gives `SAVE FAILED: <folder> already exists` |
| `projection_fields_partition_text` | prop | for generated files of 0 to 20 fns, the concatenated fields of the rows that share a saved line equal that line's bytes; virtual fields and the `Ret` hole are zero-width; an empty `{}` body is three rows with one gutter number |
| `dpad_repeat_timing` | unit (platform) | the pure tick: first repeat after 0.35 s, then every 0.07 s; none while `suppress_repeat` is true |
| `ns_m0_fn_main_package_builds` | compile | the saved package (no dependencies, so no `Cargo.lock` and no `--locked`) passes `cargo build --offline` and `rustfmt --check`; `cargo run` exits 0 with empty stdout |
| core test time | CI | `cargo nextest run -p doodle-core` < 15 s |
| Demo | manual | On Windows, and on the Deck in Game Mode if S4 is green: launch; the HUD shows; holding LT or RT switches banks; New Project → A → Functions > Function → RT+Y; `cargo run` in a terminal succeeds. `owner pending` when the builder has no pad; the scripted screenshots stand in meanwhile |

**Deferred.**
- The "where?" page, Recent Projects and Save as (M2).
- Every construct except Function (M3 and later).
- The trace recorder (M1).
- Key rebinding, heat, icons and sounds (M11).
- rustfmt anywhere in the app (M3).
- The unsaved-changes prompt (M10). Until then, B from the editor followed by B on the main menu drops unsaved
  edits, as in Doodle.

---

### M1 — Controller complete; trace and replay

**Goal.** Every button, bank and lock-out rule behaves as features/03 says. The cursor reaches every stop of what
exists. Menus look and navigate like Doodle's. Every debug run is recorded, and CI replays the committed
recordings headless.

**Scope.**
- **Keymap and input.**
  - features/03 F1-F8, F12, F17-F19, and P13-P15;
  - LB, RB and Ctrl+C handled in the core (D11); their actions stay `not built yet` until M10 (Run) and M8 (Copy);
  - the `Confirm` mode skeleton;
  - the **IDE menu** (features/03 F8; LT+Left; works on the main menu too, P14.8): title `IDE MENU`, entries
    `Format file` (refused `not built yet` until M3), `Key layout` (refused `not built yet` until M11) and
    `Exit` (`Request::Quit`; the O7 unsaved-changes prompt comes at M10); B returns to where it was opened;
  - at most one overlay opens per frame;
  - the stale-press rule as data (Talk itself comes at M3);
  - O23's HUD on every fixed-control screen that exists (main menu, menus, the IDE menu, `Confirm`).
- **Menus.**
  - features/01 §5-7: the entry/view stack, square-ish grid, wrap-around navigation, breadcrumb, `n / N`,
    `^ more`/`v more`, the full label of a truncated cell, and ordering without heat;
  - features/10 F16;
  - the reason line under the grid for a highlighted gray cell (D8).
- **Cursor**: features/02 §1-6 and §14; scrolling per features/10 F9.
- **Rendering**: features/10 F1-F7, F9-F11, F14, F15, F18-F20. The code font is fitted to the chosen line width:
  O3 defaults to 100 columns, and a readability check on the Deck answers O3.
- **Platform**: hot-plug (D12), positional buttons, keyboard fallback.
- **Trace** (D16):
  - the recorder for `input.log` (the rust/01 grammar) and `events.jsonl` (`act`, `list`, `mark`);
  - cfg-gated `trace_on`/`trace_off`, and `DOODLE_RS_TRACE=0` to skip recording;
  - headless replay with `cargo xtask trace verify`;
  - visual replay with `--replay <trace> --until F --speed X --screenshot F --exit-at-end`, through the inert
    replay executor;
  - `cargo xtask trace list|report|show` v0: button and combo use per screen, presses per menu pick, and the
    mistake signals of features/11 §15;
  - `cargo xtask check-release`.
- **Testkit**: `Pad::save_trace`, so exact tests double as fixtures.
- **Docs gate**: `cargo xtask doc-check` (see "Working conventions").

**Deliverables.**
- Committed traces `tests/traces/m0-walking-skeleton/` (re-recorded with the recorder) and
  `tests/traces/m1-every-button/` (each button and combo once, on the main menu and in the editor).
- `docs/features/03-controller-hud-keymap.md` for the Rust IDE.
- Scripted screenshots in `docs/milestones/M1.md`.
- The O3 readability note, written on a Deck (`owner pending` without one).

**Exit criteria.**

| Test | Kind | Asserts |
|---|---|---|
| `keymap_resolve_unbound_trigger_face_is_swallowed` | press | features/03 F6, P14.7: a cleared LT+B never acts as B |
| `trigger_dpad_still_moves_cursor` | press | LT/RT + d-pad with no binding moves the cursor |
| `menus_read_only_dpad_a_b` | press | in a menu, X, Y and trigger combos do nothing, and LT+B is B (P14.1) |
| `topmost_mode_owns_input_and_edges_never_leak` | press | a press consumed by a mode never reaches the editor in the same or the next frame (the IDE menu's B and A) |
| `at_most_one_overlay_opens_per_frame` | press | two opening presses in one frame open one mode: LT+Left and A on a green dot in the same `Input` open only the IDE menu |
| `ide_menu_exit_quits_and_b_returns` | press | from the editor and from the main menu: `Exit` → `Request::Quit`; B returns to the mode it was opened from; `Format file` and `Key layout` are refused `not built yet` |
| `hud_shows_overlay_controls_under_fixed_overlays` | snap | O23: on the main menu, in a menu, in the IDE menu and in `Confirm`, the HUD shows only that screen's live controls; every other slot is blank and dim |
| `rebind_hint_drops_segments_without_a_button` | unit | features/03 F18 |
| `lb_rb_ctrl_c_act_only_in_editor_without_overlay` | press | features/03 F8 |
| `dpad_reaches_every_stop` | prop | on random M0 documents, `dpad_to` reaches every stop, and Up/Down never skips one |
| `menu_grid_cols_prefers_square`, `menu_wrap_navigation`, `menu_go_reaches_every_entry` | unit / prop | features/01 §6 |
| `gray_reason_line_shows_for_highlighted_gray` | snap | the `Scene` has the reason text under the grid |
| `hot_unplug_releases_held_buttons` | unit (platform) | removing the pad emits releases for every held button and trigger |
| `trace_input_log_round_trips` | prop (formats) | parse(serialize(x)) == x, including one-token escaping |
| `committed_traces_replay_headless` | trace | every `tests/traces/*` fingerprint matches, frame by frame |
| `replay_executor_is_inert` | unit | the replay executor performs no write, run, clipboard, sound or install |
| `release_build_has_no_trace_header` | CI | `cargo xtask check-release` fails on `doodle-rs-trace 1` in a `--release` binary |
| `scene_snapshot_editor_and_main_menu` | snap | `Scene` data for `ViewCfg { px: (1280, 800), scale: 1.0, code_cols: 100 }` (cell coordinates for code, logical-pixel rects for the HUD and menus; text and geometry, not pixels) |
| `update_p99_under_2ms` | timing | 10k random inputs on an M0-sized document |

**Deferred.**
- The Key Layout page, the keys file and heat (M11).
- Icons and sounds (M11).
- Talk (core path at M3; audio at M9).

---

### M2 — Projects and persistence

**Goal.** The project loop works without a terminal:
- New Project asks where;
- Recent Projects reopens a project;
- Save as names files;
- the IDE's own files live in the per-user data dir under Doodle's never-overwrite rules.

**Scope.**
- **Projects and naming.**
  - features/09 F2-F11 and F37, including the F4 folder browser and the F7 command-line file;
  - features/08 F20, the name dialog with `Input.typed` (dictation into it comes at M9);
  - features/08 F21, the Steam on-screen keyboard through SDL text input, as S4 found it.
- **Settings page skeleton** (features/03 F15): its rows are filled by later milestones.
- **Persistence** (D15):
  - pure `parse`, `serialize` and `text_ok` in `doodle-formats` for `doodle-rs_settings.txt` and
    `doodle-rs_roots.txt`;
  - app stores with `nosave`, one retry after 50 ms, and write-to-`.tmp`-then-rename;
  - the per-user data dir (O9), including the `portable` file;
  - stores load before the trace starts, and a replay pins them.
- **New Project template** (features/09 "Carrying this to Rust" (c)):
  - the package files are written at the first save;
  - the folder is created only then;
  - an existing `src/main.rs` is never overwritten.
- **Recent Projects.**
  - Projects are detected by `Cargo.toml`, through `ListDir`.
  - It opens `src/main.rs`, else `src/lib.rs`, else the first `.rs`.
  - Projects are ordered by the newest `.rs` modification time.
- **Opening a file**: `Request::Open { format: false }` → `Event::Opened`. Any file opens. Regions no construct
  structures yet project as `Opaque` (D3.2): you can move and delete them but not edit them (P8 fallback).
  Format-on-open comes at M3.
- **Confirmations**: a `Confirm` mode for saving over a different file (features/09 F10: a second A).

**Deliverables.**
- `docs/features/09-projects-files-run.md`, its projects and persistence parts.
- The fixture trace `tests/traces/m2-new-open-save/`.

**Exit criteria.**

| Test | Kind | Asserts |
|---|---|---|
| `new_project_where_lists_default_and_added_roots` | exact | features/09 F3 |
| `new_project_file_set_is_cargo_package` | unit | byte-exact `Cargo.toml` template for a given name and edition |
| `cargo_toml_template_equals_cargo_new` | compile | runs the pinned `cargo new --vcs none` and compares bytes |
| `project_folder_created_only_at_first_save` | exact | no `CreateDir` before RT+Y |
| `first_save_never_overwrites_existing_main_rs` | exact | fixes features/09 open question 16 |
| `recent_projects_lists_cargo_packages_newest_first` | press | MemFs tree with three packages and one non-package folder |
| `save_as_takes_typed_text_only_in_the_dialog` | press | `Input.typed` is ignored in every other mode (P1) |
| `save_as_over_other_file_needs_second_a` | exact | features/09 F10 |
| `settings_text_ok_refuses_newer_header`, `settings_unknown_lines_kept`, `roots_parse_skips_comments_blanks_repeats` | unit | P19 |
| `store_never_overwrites_unreadable_or_newer_file` | unit (app, fake fs) | `nosave` is set, and the status is reported once |
| `portable_file_switches_data_dir` | unit (app) | O9 |
| `replay_pins_stores_from_trace_meta` | trace | a replay never reads or writes the real files |
| `opaque_regions_open_and_save_byte_identical` | prop | every `tests/corpus` file: open → save is unchanged (true before M7, by projection) |
| `command_line_file_opens_in_editor` | press | features/09 F7 |

**Deferred.**
- The Files grid (M10).
- The trust gate (M7).
- The keys file (M11).
- Format on open (M3).

---

### M3 — Document model, file-scope items, names

**Goal.** Build every file-scope item NS2 needs except `use`, `impl` and derives. That covers types, generated
names, renames by (fake) voice, graduated deletes, exact B and undo. All of it runs on the real document model,
where text is the truth, with the layout engine doing the layout and rustfmt as the check.

**Scope.**
- **Document and formatting.**
  - D3 complete: apply, reparse, the offset map, the anchored cursor and snapshots.
  - D4 item-level holes: type `_`, ret nothing, optional lists nothing, and value `todo!()` in `const`/`static`
    initializers.
  - D5: the layout engine for items. rustfmt runs as `Format file` (IDE menu, lit from here on) and as format-on-open (O4), both as
    recorded events, and as `rustfmt --check` after save. O2 is confirmed, or its fallback `todo!("●")` is taken
    (a one-table change).
- **Knowledge.** D9 std tables v1: `doodle-oracle dump-std` + `cargo xtask gen-std` + the embedded blob. The
  oracle crate gains its pinned `ra_ap_*` dependencies here, used offline only.
- **Add-menu leaves.**
  - rust/02 §3.2 File Setup: module docs, comments, blank line; no inner attributes yet.
  - rust/02 §3.4 Function.
  - rust/02 §3.5 Struct, Tuple struct, Unit struct, Enum, Type alias.
  - rust/02 §3.7 Constant, Static.
- **Member menus**: rust/02 §4.4 struct body and §4.5 enum body; features/04 §13, §15 and §18.
- **Item options dot**: rust/02 §2.2, and from §3.10 only Visibility and Docs.
- **Type menu** (rust/02 §7): primitives, std types from the tables, the open file's own types, and composites
  with Wrap in / Drop wrapper (features/04 §16-17).
- **Names** (features/01 §16, P5, rust/02 §1.8):
  - casing by role, including UpperCamel enum variants and the lifetime `'a`;
  - keyword avoidance;
  - a numeric-suffix fallback instead of looping forever (fixes features/00 open question 4).
- **Talk, core path** (D11), with `FakeSpeech` in tests:
  - features/08 F1, and the core side of F2 (gating);
  - F6, heard words become an identifier cased by role;
  - F7, d-pad Down splits words; F8, the Transcribing mode;
  - F11, the text tools on a name.

  The real microphone comes at M9.
- **Rename of file-scope items.** The features/08 F19 prompt, with uses found by the syntax layer: paths in this
  file that resolve to the item. Locals, shadowing and other files move to the oracle's `Rename` at M9.
- **Delete, change and edit on items** (features/02 §17-19; P11): a parameter, a field, a variant, a filled type
  back to a hole, and the whole item with its attributes.
- **Undo and redo** (O6): one snapshot per user step, Undo on LT+Down.
- **Crash recovery** (D15): the app snapshots dirty documents every 5 s and in the panic hook, and
  `Event::Recovered` opens `Confirm`.

**Deliverables.**
- `docs/features/01-document-model.md` and `04-file-scope-constructs.md` for what shipped.
- The committed std blob `crates/knowledge/data/std-1.100.0.postcard.zst`.
- The fixture trace `tests/traces/m3-types/`.

**Exit criteria.**

| Test | Kind | Asserts |
|---|---|---|
| `every_m3_leaf_build_save_reload_same_fields` | press | table over every live Add and member leaf: build, save, reload, and the `Line`s are equal (field roles and ranges) |
| `hole_matrix_items` | press | every item hole kind saves as its D4 spelling, reloads as the same hole, and saves byte-equal |
| `compile_matrix_items` | compile | every untouched leaf in a temp crate; the expected outcome per leaf (ok, or the exact error code such as E0121) is a table in the test |
| `every_m3_save_is_rustfmt_clean` | compile | pinned `rustfmt --check --edition 2024` |
| `layout_matches_rustfmt_on_menu_corpus` | compile | S3 as a test: every menu-built item file equals rustfmt's output |
| `relayout_touches_only_the_enclosing_item` | prop | bytes outside the edited item's layout root are unchanged (D5) |
| `generated_names_cased_by_role` | press | fn and field snake, type and variant UpperCamel, const and static SCREAMING |
| `name_generator_never_loops_and_skips_keywords` | unit | all 400 names used → numeric suffix; no generated keyword |
| `first_function_is_main_only_if_crate_root_has_no_main` | press | features/00 open question 9 fix |
| `lt_b_on_param_removes_only_that_param` | exact | fixes features/02 / features/04 open question 1 |
| `lt_b_on_filled_field_type_leaves_type_hole_then_removes_field` | exact | graduated delete (P11) |
| `b_restores_every_m3_multi_step_edit` | press | table: insert, refill, options, type-menu B; byte-identical every time |
| `y_on_type_refills_and_b_restores` | exact | features/06 F21 |
| `dictate_type_name_is_upper_camel`, `dictate_const_name_is_screaming_snake` | exact | `FakeSpeech` text `"offscreen buffer"` → `OffscreenBuffer` |
| `talk_only_on_dictatable_targets` | press | P16: Talk on a keyword or dot changes nothing and says why |
| `rename_item_offers_prompt_with_use_count` | press | `Rename brave_otter to window_title?` with `Rename all N uses` / `Only this one` |
| `undo_reverts_one_user_step_and_redo_reapplies` | press | O6; one Undo covers every edit of one pick |
| `recovered_docs_offer_restore_and_never_write_project` | press + unit (app) | D15 |
| `format_file_applies_only_if_revision_unchanged` | press | D7.4 with a fake `Formatted` event |
| `format_on_open_changes_memory_not_disk` | press | the status `formatted on open (N lines differ) - not saved yet`; no `Write` |
| `std_blob_is_deterministic` | CI | `cargo xtask gen-std --check` (Linux) |
| `type_menu_offers_std_own_and_composite_types` | press | rust/02 §7 groups and their order |
| `edit_relayout_5k_lines_p95_under_4ms` | timing | rust/01 budget |
| `ns2_stage_types` | exact + compile | from New Project, Functions > Function first (`fn main() {}`: a binary crate without `main` fails with E0601), then at the top insert dot build `enum Direction { Left, Right, Up, Down }` and `struct OffscreenBuffer { memory: Vec<u32>, width: usize, height: usize }`; the text equals NS2 lines 9-20, a blank line, and `fn main() {}`; `cargo check` passes (dead-code warnings allowed) |

**Deferred.**
- `use`, `impl`, `trait`, derives and attributes other than visibility and docs (M6).
- Generics, `where` and lifetimes beyond `'a` (M6, as NS1, NS2 and rust/02 §9 need them).
- Statements (M4).
- Typed grays (M5).

---

### M4 — Function bodies; NS0

**Goal.** Fill function bodies with statements, calls, macros and control flow, and fill leaves with text tools,
words and numbers, with no oracle at all. NS0 is built byte-exact.

**Scope.**
- **Statement menu**: rust/02 §5.1-5.8 and §5.10-5.11, with arms entered by hand in M4 (generated arms come at
  M5); features/05 §1-4, §6-12, §15-23, §25 and §29. That includes:
  - the temp-line protocol;
  - capture dots (features/02 §10, features/05 §9);
  - the tail slot (rust/02 §1.11).
- **Value menu without types** (rust/02 §6.1): Literal, Reference, Call, Construct (tuple, array, unit),
  Operator, Choose, Block and Panic.
- **Macros** (rust/02 §9.8, from the knowledge macro table, D9): `println!`, `eprintln!`, `format!`, `vec!` (both
  forms), the `assert!` family, `todo!` and `panic!`. Format-string placeholders are kept in sync with argument
  dots. The projection sub-parses the arguments of every table macro (rust/01 D3.9), so holes inside them save
  and reload as holes.
- **The syntax layer** (D6 `core::scope`): locals, params, patterns, loop context, labels, const context and
  `unsafe`. On top of it:
  - Reference pick (features/06 F15);
  - Pass as with its syntax forms only (`x`, `&x`, `&mut x`, `*x`, `x.clone()`), no type grays yet;
  - assignment targets (features/06 F19).
- **Refusals** (D8, O19), with reasons: `break`/`continue` outside a loop, an `else` already present, and the
  like. **Auto-`mut`** (O20).
- **Text entry** (R21: Unicode-safe throughout):
  - features/08 F9, spoken numbers;
  - F12-F18: the text tools on strings and comments, word-by-word editing, and the keypad.
- **Cursor**: RT walks (features/02 §12), nested-body dots (§8), and pick modes (§16).
- **Delete and B for statements** (features/02 §17, §20).
- **Debug-only `ScriptedSpeech` engine** for manual demos. It returns the lines of `<data>/debug/speech.txt` in
  order, and release builds don't contain it.

**Deliverables.**
- `docs/features/05-statements.md` and `08-text-entry-voice.md`, the parts that shipped.
- The fixture traces `tests/traces/m4-ns0/` and `m4-statements/`.

**Exit criteria.**

| Test | Kind | Asserts |
|---|---|---|
| `ns0_hello_world_exact` | exact + compile | see "North-star acceptance test" |
| `statement_leaf_exact` | exact + compile | table-driven, one controller-exact case per live leaf of rust/02 §5 (about 40): the inserted text byte-exact inside `fn main`; the cursor target after the insert (rust/02 §5.1); and `cargo check` of the program |
| `statement_temp_line_b_restores_byte_identical` | exact | features/05 §1 protocol |
| `break_outside_loop_is_refused_with_reason` | press | the menu stays open, the reason turns the warning colour, and no heat is recorded |
| `else_dot_entries_gray_not_hide` | press | fixes features/00 open question 8 |
| `assign_to_non_mut_adds_mut_and_b_reverts_both` | exact | O20, with the status `made brave_otter mutable (line 4)` |
| `reference_pick_lists_names_in_scope_once_each_in_file_order` | press | features/06 open question 20 fix |
| `reference_with_no_names_is_dimmed_with_reason` | press | P4 |
| `format_placeholders_track_argument_dots` | press | adding `{}` adds an argument dot; deleting the dot removes its placeholder |
| `vec_repeat_form_builds_vec_zero_semicolon_n` | exact | `vec![0; width * height]` |
| `macro_argument_holes_reload_as_holes` | press | D3.9: `vec![todo!()]`, `vec![todo!(); todo!()]`, `println!("{}", todo!())`, `assert!(todo!())` and `assert_eq!(todo!(), todo!())`, each built from the menus, save, reload with the same fields and hole kinds, and save byte-equal; an unknown macro reloads as one `Opaque` unit |
| `capture_dot_turns_call_into_let` | exact | features/05 §9 |
| `tail_slot_appears_when_return_type_filled_and_saves_todo` | exact | rust/02 §1.11 |
| `walks_visit_every_unit` | prop | features/02 §12 |
| `spoken_number_table` | unit | Doodle's cases (features/08 F9) |
| `keypad_grays_keys_that_would_not_change_the_number` | press | features/08 F18 |
| `word_by_word_inserts_comma_and_bang`, `text_tools_capitalize_word` | exact | the NS0 steps |
| `unicode_text_ops_never_panic` | prop | arbitrary Unicode through truncation, word split, format-string tokenizing and dictation cleaning |
| `every_m4_statement_matches_rustfmt` | compile | S3's statement cases |

**Deferred.**
- Expected-type labels and grays (M5).
- Generated match arms (M5).
- Methods, fields and `?` grays (M6).
- Grab (M8).
- The real microphone (M9).

---

### M5 — Type oracle v1, typed menus

**Goal.** Menus react to the Rust code underneath:
- dots show their expected type;
- options that can't fit are grayed, each with a reason;
- unknown never grays;
- the A press usually opens a menu that is already grayed;

and replays stay deterministic with a live, cancellable analysis.

**Scope.**
- **The oracle** (D6, D7):
  - the `doodle-oracle` process: handshake, `OpenWorkspace` with `LoadOpts`, `SetText`, `FilesChanged`, and the
    queries `FileFacts`, `ExpectedAt`, `Fits`, `ScopeAt` and `Suggest`; `Cancel`; `Mem`; restart with backoff;
  - on the app side, the `Engine` client;
  - in the core, `FactStore` and `Wants`, prefetching (D7.7), frozen grays (D7.3) and carried facts (D7.8);
  - the settle gate (O5);
  - the title-bar status `types: loading 31/80 crates`.
- **Fit** (D8): `TyFacts`/`AcceptBits`, the three gray kinds, reasons, fixes as two-entry menus, and
  syntax-stamped hints.
- **Typed menus.**
  - features/06 F1-F14, F18, F20b and F21-F25;
  - rust/02 §1.3-1.7, including SUGGESTED through `Suggest`;
  - rust/02 §6.1-6.5 and §7 (type grays);
  - rust/02 §8, the pattern menu with refutability;
  - rust/02 §5.9, match arms generated from the scrutinee's type;
  - Closure by its `Fn` bound (rust/02 §9.7);
  - Option and Result constructs, enum variants, and struct literals with every field (rust/02 §1.12).
- **Knowledge** (features/07 §1, §6-8): grouping, buckets and `FLAT_MAX` 60 over the std tables, and
  `Call > Function` over std modules.
- **Async** (O22): syntax only. `async fn` exists, and `.await` is grayed outside async code.
- **Test infrastructure.**
  - Cassettes in `tests/cassettes/`, recorded with `REC_ORACLE=1`.
  - `FakeFacts` for unit tests.
  - The oracle CI job, with about 100 golden queries over fixture crates: NS1, NS2, and a kitchen-sink crate
    with traits, generics, closures and derives.

**Deliverables.**
- `docs/features/06-type-driven-menus.md` and `07-language-knowledge.md`, the parts that shipped.
- `docs/spikes/S1.md`, `S7.md`, `S8.md` and `S9.md`.
- Fixture traces with recorded oracle events: `tests/traces/m5-typed-grays/`.

**Exit criteria.**

| Test | Kind | Asserts |
|---|---|---|
| `u32_dot_grays_float_literal_keeps_integer` | press | with `FakeFacts` |
| `str_ref_dot_keeps_string_literal_lit` | press | Rust literal rules (features/06 "Carrying this to Rust" (b)) |
| `string_dot_grays_str_literal_offers_string_from` | press | the advisory gray, plus a lit `String::from("…")` |
| `unknown_never_grays_anywhere` | prop | with Unknown facts, no entry of any menu reachable in the corpus carries a gray whose evidence is `Oracle` or `Diagnostics`; type-fit grays appear only from syntax-stamped hints (grays evidenced by syntax, index, metadata or knowledge are allowed: rust/02 R2) |
| `refusals_never_depend_on_oracle_facts` | prop | the set of `Gray::Refused` entries is identical with real facts and with Unknown facts, and every refusal's evidence is `Syntax`, `Index` or `Metadata` |
| `every_gray_has_a_reason` | prop | no gray entry without a non-empty reason |
| `group_is_gray_iff_no_leaf_fits_placeholders_never_count` | press | features/06 invariant 3 |
| `generic_param_dot_grays_nothing` | press | `T` with unresolved bounds |
| `advisory_gray_with_fix_opens_two_entry_menu` | exact | `Fix it: <fix>` / `Insert anyway`, and B goes back (D8) |
| `stale_answer_dropped`, `answer_never_changes_open_menu_grays`, `answer_never_moves_cursor_or_text`, `gated_a_opens_grayed_menu` | press | rust/01 per-frame contract |
| `settle_gate_holds_a_y_lt_a_never_b_never_while_loading` | unit (app) | D7.7 and per-frame rule 8: held presses are released in order, one per frame; B never starts a hold, and a B pressed after a held A is delivered after it |
| `carried_facts_gray_refill_menu_at_next_revision` | press | D7.8 |
| `oracle_down_menus_still_complete` | press | the syntax layer alone builds every menu; no entry carries an `Oracle`- or `Diagnostics`-evidenced gray |
| `protocol_mismatch_runs_syntax_only_with_status` | unit (app) | D6 handshake |
| `oracle_rss_reported_and_restart_backoff` | unit (app) | restarts after 1 s, 5 s and 30 s; facts are Unknown meanwhile |
| `match_on_enum_generates_every_arm` | exact | rust/02 §5.9 |
| `untouched_generated_arms_follow_scrutinee_refill` | press | rust/02 "Untouched arms follow the scrutinee": a `match` whose scrutinee is refilled from a `bool` value to an enum value replaces the untouched `true` / `false` arms with one arm per variant, in that pick's one undo step; once an arm is edited, a further refill keeps the arms |
| `suggested_is_at_most_six_and_deterministic` | press | rust/02 §1.7 |
| `std_function_menu_grouped_flat_max_60_buckets_12` | unit | features/07 §6 |
| `menu_open_with_10k_item_dependency_under_50ms` | timing | `FakeFacts`; rust/01 budget |
| `no_false_gray_on_corpus` | prop (cassettes) | S9 as a test: punch a hole at every expression of NS1, NS2 and the corpus, and the entry that rebuilds it is lit. It also reports the share of useful grays (a warning below 30%). Runs in CI from here on (D8) |
| `replay_with_recorded_oracle_events_is_deterministic` | trace | S8: 10 replays, then one with the oracle binary absent; identical fingerprints |
| `oracle_conformance_suite` | oracle | about 100 golden queries; fails on a diff |
| `ns2_stage_step` | exact + compile | with `enum Direction` loaded, build `fn step(direction: Direction, x_offset: &mut i32, y_offset: &mut i32)` with generated arms and `*x_offset -= 1`-style bodies; equals NS2 lines 56-63; `cargo check` |
| Deck latency | manual | A on a dot → grayed menu p95 ≤ 100 ms warm; `FileFacts` p95 ≤ 150 ms; cold load numbers (S7) |

**Deferred.**
- Methods, fields, `use` and dependencies (M6).
- Diagnostics and the Docs panel (M8).
- Rename through the oracle (M9).

---

### M6 — First vertical slice: names, methods, modules, dependencies; NS1

**Goal.** A real program that needs a crate, traits in scope, methods, borrowing and matching on `Result` is built
from an empty project with the controller: the Rust Book guessing game. NS2 is built region by region.

**Scope.**
- **Names and values.**
  - Typed Reference and full Pass as (features/06 F15-F16; rust/02 §6.6): the View, Convert, Unwrap and Wrap
    adapters; `?` gated by the return type; `.await` by async context; moves labelled `x   (move)`, with the
    reason `moves x, but line 30 uses it again` when the value is used later.
  - Field of and indexing (features/06 F17).
  - Methods of x (rust/02 §6.7, through `MembersOf`): `RECENTLY USED`, inherent methods, deref levels, traits
    in scope, Conversions, Needs a use, `Search by voice` (the voice-search overlay), grays by return fit, and
    `Extend <x>` chains, including the regeneration of untouched generated arms when a scrutinee is extended.
- **`use`.**
  - rust/02 §1.13 auto-use;
  - rust/02 §3.3 the Use tree over std, dependencies (`ItemsOf`, cached per D9) and the crate's own modules
    (`Event::Indexed`);
  - rust/02 §3.12 editing `use` lines;
  - groups std / external / crate, separated by a blank line, with new items merged into existing groups;
  - features/04 §6-7, and features/07 §2-6 and §9-11.
- **Dependencies** (D18, O11, O12, O21; rust/02 §3.11).
  - A curated offline catalog with pinned versions. Its `rand` entry is `0.10.1` and its `minifb` entry is
    `0.29.0`, matching the NS references; bump the catalog and the references together.
  - Confirm, then `Request::AddDependency`: `cargo add --offline` first, online only after an explicit press.
  - Then a metadata refresh, then the oracle's `FilesChanged`.
- **Modules**: New module file (D18), and `mod` linking.
- **Impl and traits** (rust/02 §3.6, §4.1-4.3): impl blocks; trait impls that insert every required item with a
  `todo!()` body; `Self`; the receivers `&self`, `&mut self` and `self`.
- **Item options** (rust/02 §3.10):
  - the derive checklist, where turning Copy on turns Clone on, and Clone can't be turned off while Copy is on;
  - attributes, with their arguments sub-parsed (rust/01 D3.9);
  - `#[test]`, which sets up `#[cfg(test)] mod tests { use super::*; }` (rust/02 §3.9; features/04 §29).
- **Generics and lifetimes** as far as rust/02 §9.1-9.5. NS1 and NS2 need none; the automatic `'a` for `&T`
  returns follows rust/02 §9.5.
- **Format strings**: inline named captures `{name}` picked from scope (rust/02 §9.8).
- **Change call** (features/06 F21b).
- **Proc macros** per S11. Until M7, only trusted projects exist, because every project is IDE-created.

**Deliverables.**
- The `docs/features/` sections that shipped.
- `docs/spikes/S10.md` and `S11.md`.
- The fixture trace `tests/traces/m6-ns1/`.
- Cassettes for NS1 and NS2.

**Exit criteria.**

| Test | Kind | Asserts |
|---|---|---|
| `ns1_guessing_game_exact` | exact + compile + run | see "North-star acceptance test" |
| `ns2_stage_file_scope` (a), `ns2_stage_impl_new` (b), `ns2_stage_render_weird_gradient` (c), `ns2_stage_pressed_direction` (d), `ns2_stage_run` (e), `ns2_stage_main_and_tests` (f) | exact + compile | "complement" stage tests (see "Staged sub-goals") |
| `method_menu_reaches_any_method_within_12_presses` | press (cassettes) | S10's 10 receivers; max ≤ 12 and median ≤ 6 presses by BFS |
| `trait_method_needing_use_inserts_use_and_b_removes_it` | exact | rust/02 §1.13 |
| `auto_use_merges_and_sorts_into_existing_group` | press | `use minifb::{Key, Window, WindowOptions};` grows in order |
| `use_groups_std_external_crate_with_blank_lines` | press | the NS1 header shape |
| `pass_as_lists_ref_first_for_ref_param` | press | rust/02 §6.6 |
| `owned_arg_used_later_is_labeled_moves_it_and_clone_is_offered` | press | R5, layer 1 |
| `question_mark_is_advisory_outside_result_fn_with_fix` | exact | the fix makes the fn return `Result` |
| `struct_literal_inserts_every_field_and_uses_shorthand` | exact | the NS2 `new` body |
| `format_inline_capture_lists_scope_names` | press | `{error}` |
| `derive_copy_turns_on_clone_and_clone_off_is_refused_while_copy` | press | rust/02 Derive: Copy on → Clone on too, one undo step; Clone off while Copy is on → refused with `Copy needs Clone: turn Copy off first` |
| `attribute_arguments_reload_as_same_fields` | press | D3.9: `#[derive(Debug, Clone)]` (one stop per derive), `#[allow(dead_code)]`, `#[cfg(true)]` (a cfg hole) and `#[repr(C)]` save and reload with the same fields |
| `untouched_generated_arms_follow_scrutinee_extend` | press | the NS1 case: under `let guess: u32 = match ●`, scrutinee `guess.trim()` gives the `&str` arms; `Extend > parse()` replaces them with `Ok(brave_otter)` / `Err(error)` in that pick's undo step |
| `trait_impl_inserts_every_required_item` | exact + compile | `impl Display for T` compiles once the bodies are filled |
| `test_function_creates_cfg_test_module_once` | exact | the second test reuses the module |
| `add_dependency_writes_nothing_before_a` | press | `AddDependency` only after A; B cancels with no request |
| `no_network_request_without_explicit_press` | prop | random input sequences never emit `Registry` or an online `AddDependency` unless that entry was picked (O11) |
| `new_module_file_confirms_and_creates_file_and_mod_line` | exact | D18 |
| `crate_index_skips_unchanged_and_big_files` | unit (app) | features/07 inv 13 analog |
| `dependency_items_cache_is_deterministic` | unit | same bytes for the same crate, version, features and oracle build |
| `derived_clone_listed_without_proc_macro_server` | oracle | S11 |

**Deferred.**
- Guarantees for arbitrary loaded code (M7).
- The Fix menu (M8).
- Rename across files (M9).

---

### M7 — Load any Rust file; NS2 exact

**Goal.** Open real-world Rust, edit it the same way as menu-built code, and save it byte-exact. Build NS2 from the
main menu with no seams.

**Scope.**
- **Loading.**
  - features/01 §10-14 and §17-18; features/05 §28; features/04 §19, §21 and §31-32; P8 and P12.
  - D3.6: UTF-8; CRLF kept; BOM kept and hidden; final newline; a non-UTF-8 file is read-only.
  - D4: user-written holes load as holes (O2), including inside table-macro and attribute arguments (D3.9).
  - Opaque regions for unknown macros, `macro_rules!` bodies (except the single-rule form the menus build) and
    `asm!`.
- **Open Folder** (main menu): the features/09 F4 folder browser; A opens the chosen folder's Cargo package
  (`src/main.rs`, else `src/lib.rs`, else the first `.rs`) through the trust gate below. It ships here, not
  earlier, so that every project is IDE-created and trusted until the trust gate exists.
- **Other files.**
  - The module tree as read-only knowledge.
  - `Cargo.toml` as a read-only document (features/09 "Carrying this to Rust" (c)).
- **Trust gate** (O10, D17), through `Confirm`.
- **Corpus** (R15):
  - the loader coverage metric;
  - `tests/corpus/` vendored with its licenses: Rust Book listings at a pinned commit, the NS targets, std
    samples, the S2 crate files, and the IDE's own `crates/core/src`.

**Deliverables.**
- The `docs/features/01-document-model.md` loader sections.
- `target/loader-coverage.txt` published as a CI artifact.
- The fixture trace `tests/traces/m7-ns2-exact/`, written by the exact test itself.

**Exit criteria.**

| Test | Kind | Asserts |
|---|---|---|
| `ns2_handmade_exact_build` | exact + compile | the whole file from the main menu, with every rule and assertion of "North-star acceptance test" |
| `ns2_load_round_trip`, `ns1_load_round_trip`, `ns0_load_round_trip` | press | load (`format: false`) → save byte-exact; Format file is a no-op; a copy without the final newline saves without one |
| `corpus_round_trip_byte_exact` | prop | every corpus file: load with `Request::Open { format: false }` → save equals the original bytes (format-on-open's own behaviour is `format_on_open_changes_memory_not_disk`, M3) |
| `projection_fields_partition_every_corpus_line` | prop | D3.2 |
| `loader_builds_same_fields_as_menus` | press | table over every leaf of M3-M6, including `Macro (macro_rules!)` and `Thread local`: build → save → reload, and the `Line`s are equal |
| `every_hole_kind_reloads_as_the_same_hole` | press | the full D4 matrix, including user-written `todo!()`, `_` and `cfg(true)`, and the same holes inside table-macro and attribute arguments (D3.9: `vec![todo!()]`, `println!("{}", todo!())`, `assert!(todo!())`, `#[cfg(true)]`, `cfg!(true)`); `todo!("msg")` stays a value |
| `open_folder_opens_package_through_trust_gate` | press | main menu > Open Folder > the F4 browser > A on a package folder: the trust `Confirm` first, then the editor |
| `every_token_reachable_by_dpad_on_corpus` | prop | R11 |
| `unknown_macro_is_one_opaque_unit_that_moves_copies_deletes` | press | P8 fallback |
| `crlf_bom_and_final_newline_preserved` | press | D3.6 (a deliberate departure from Doodle) |
| `non_utf8_file_opens_read_only` | press | one `Opaque` region; Save is refused with a reason |
| `untrusted_folder_runs_no_build_code` | press | no `Check` or `Run` requests; `OpenWorkspace { trusted: false }`; menus are complete; the affected facts are Unknown |
| `cargo_toml_opens_read_only` | press | features/09 (c) |
| `loader_coverage_at_least_95_percent_of_corpus_statements` | metric | a statement counts when it is structured (not `Opaque`) |
| `projection_5k_lines_under_4ms_p95` | timing | the D3 risk |

**Deferred.** Editing inside opaque regions: never. Y replaces the whole unit.

---

### M8 — Diagnostics, repair, Docs, Grab

**Goal.** Compiler problems show on the code, and the common ones, borrow errors included, are fixed with one
pick. LT+Y explains anything. Lines and items can be moved.

**Scope.**
- **Diagnostics** (D10):
  - the mirror workspace, a 0.6 s debounce, one check at a time, and the stale run killed;
  - on the Deck, `-j 2` at nice priority; a persistent target dir;
  - rust-analyzer's native diagnostics as fast hints;
  - clippy as a setting, default off (O13).
- **Docs panel** (features/07 §12-14): LT+Y shows `Hover`; before the oracle is ready, the std summaries and
  keyword docs; `rustc --explain` text for an error code.
- **Shading** (features/10 F13): red and amber, red gutter numbers, the problem panel, `N problems`, and a jump to
  the next problem (fixes features/07 open question 7).
- **Repairs.**
  - rust/02 §6.3, the gray-with-fix catalogue, and §11.4, diagnostics and holes.
  - S12: a Fix group at the top of Y's menu (MachineApplicable, MaybeIncorrect, HasPlaceholders), plus
    restructure entries.
- **Grab and Copy line** (features/02 §13), with attributes moving with their item. The restructure repairs need
  them.

**Deliverables.**
- `tests/rustc-json/`: captured fixtures from the pinned toolchain.
- `docs/spikes/S12.md` and `S13.md`.
- The fixture trace `tests/traces/m8-repair/`.

**Exit criteria.**

| Test | Kind | Asserts |
|---|---|---|
| `parse_cargo_messages_fixtures` | unit + snap | D10's pure parser over every fixture |
| `diagnostics_shown_only_for_checked_text_hash` | press | features/07 inv 15 |
| `hole_errors_show_not_filled_yet`, `hole_unreachable_code_warnings_hidden` | press | D4 diagnostics rules |
| `e0382_fix_offers_clone_and_applies`, `e0596_fix_makes_binding_mut`, `e0384_fix_makes_binding_mut`, `e0106_fix_adds_lifetime_marked_check`, `e0502_offers_move_line_via_grab` | exact | S12 classes |
| `stale_suggestion_dropped_after_edit` | press | revision check |
| `type_errors_first_then_borrow_wave` | press | the fixture pair: borrow errors arrive after the type errors are fixed |
| `diagnostics_not_in_fingerprint` | press | D7.9 |
| `check_debounce_and_stale_run_killed` | unit (app) | fake clock and fake runner |
| `mirror_never_writes_the_project` | unit (app) | P12 |
| `docs_panel_before_oracle_shows_std_summary`, `docs_panel_shows_hover`, `docs_panel_explains_error_code` | press | features/07 §12-13 |
| `next_problem_jumps_cursor` | exact | |
| `grab_moves_attributes_with_item`, `grab_cancel_puts_it_back`, `copy_line_cancel_leaves_no_copy` | exact | features/02 §13; fixes "attributes left behind" |
| `ns2_repair_drill` | exact + compile | load NS2 with `let mut window` changed to `let window`; after the check, Y on `window` → `Fix it: make window mutable`; the saved file equals the reference |
| `borrow_fixture_machine_fixes_compile` | compile (live) | apply every MachineApplicable fix in the S12 fixture through Y presses; `cargo check` passes |
| Deck check times | manual | warm ≤ 3 s, cold ≤ 90 s (S13) |

**Deferred.** Clippy on by default: O13 says off.

---

### M9 — Voice and rename

**Goal.** Names, strings and numbers are spoken into the highlighted leaf with the local Whisper, and renames
propagate correctly through Rust's scopes.

**Scope.**
- **Speech engine** (D14): phase 1 is `whisper-cli` per segment; S6 decides phase 2. SDL3 audio capture at 16 kHz
  mono.
- **Talk** (features/08 F2-F10): the vocabulary prompt from names in scope; dictation in dialogs (Save as now;
  the Files search at M10).
- **Rename** (features/08 F19): the oracle's `PrepareRename`/`Rename` behind Doodle's prompt, plus D18's
  `Also rename N uses in other files`.
- **Validation** (P16):
  - keywords and raw identifiers;
  - char literals refuse more than one character;
  - the numeric-suffix keypad (`u8`, `f32`, grayed by the expected type);
  - escapes per literal kind.
- **Setup row** for speech, minimal. The full Setup page comes at M10.

**Deliverables.**
- `docs/spikes/S6.md`.
- `docs/features/08-text-entry-voice.md` complete.
- The fixture trace `tests/traces/m9-voice/`, with recorded `Heard` events.

**Exit criteria.**

| Test | Kind | Asserts |
|---|---|---|
| `mic_offered_only_on_dictatable_targets` | press | P16 |
| `stale_talk_press_after_overlay_needs_release` | press | features/03 F7 |
| `editor_takes_no_presses_while_transcribing` | press | features/08 F8 |
| `heard_text_lands_in_target_captured_at_start` | press | D11 |
| `dictated_keyword_offers_raw_identifier_or_suffix` | press | rust/02 §1.8 |
| `char_slot_refuses_more_than_one_character` | press | `Heard "..." - not one character` |
| `string_dictation_escapes_quotes_and_braces` | press | `{{` inside format strings |
| `vocabulary_prompt_from_scope_is_deterministic` | unit | sorted, deduplicated, capped |
| `rename_shadowing_let_x_eq_x` | exact (cassette) | renaming the outer `x` changes the right-hand `x` of `let x = x.trim();` and not the inner binding's uses |
| `rename_one_use_label_is_singular` | press | features/08 open question 19 analog |
| `rename_other_files_only_through_explicit_entry` | press | D18 |
| `heard_results_replay_from_trace` | trace | P17 |
| `whisper_cli_transcribes_jfk_wav` | CI (release whisper build) | a real transcription. Locally it skips without a model and prints why |
| NS0 by real voice; dictation latency | manual | on the Deck; S6 numbers |

**Deferred.**
- Grammar-constrained Whisper.
- Voice commands: never (P16).

---

### M10 — Files, Run, Setup

**Goal.** The Deck needs no desktop. Files are managed, programs are run, and the toolchain is installed from
inside the IDE. NS2 runs on the Deck in Game Mode.

**Scope.**
- **Files and Run** (features/09 F12-F36):
  - the Files grid, with `target/` hidden and deletes going to the trash through the `trash` crate;
  - the Run list from `cargo metadata`; LB runs `cargo test`, and RB the favourite (`cargo run`);
  - a terminal per platform, else the in-app Run output overlay (O8);
  - a generic native-library hint (the F27 analog).
- **Setup rows** (D17):
  - Rust toolchain: detect, or install the pinned `rustup-init` after checking its SHA-256;
  - MSVC Build Tools;
  - the Zig `cc`/`ar` wrappers;
  - oracle status and Restart;
  - speech;
  - trust per folder.
- **Policies**: the unsaved-changes prompt (O7), and the pin cadence written down (O17).
- **Storage**: `Settings > Storage` sizes and `Clear check caches` (D10).
- **Run commands**: `.doodle-rs/run.txt`, with its header.

**Deliverables.**
- `docs/features/09-projects-files-run.md` complete.
- `dist/deck_install.sh` (dry-run tested).
- The fixture trace `tests/traces/m10-files-run/`.

**Exit criteria.**

| Test | Kind | Asserts |
|---|---|---|
| Doodle's Files tests ported as `files_*`, including `files_hides_target` | press (MemFs) | features/09 (a) |
| `delete_goes_to_trash_and_status_matches_os` | press | fixes features/00 open question 16 |
| `new_file_in_src_offers_mod_line` | press | features/09 (c) |
| `run_list_templates_from_cargo_metadata` | unit | fixture JSON |
| `rb_saves_first_then_runs_favorite_in_package_root`, `lb_runs_cargo_test` | press (FakeRunner) | features/09 F22-F23 |
| `run_output_overlay_when_no_terminal` | press | O8 |
| `run_txt_has_header_and_newer_is_never_overwritten` | unit | fixes features/00 open question 13 |
| `unsaved_changes_prompt_on_switch_leave_quit_and_close` | press | O7; `CloseRequested` included |
| `setup_rows_are_pure_functions_of_events` | unit | D17 |
| `rustup_url_and_sha256_come_from_pins` | unit | the `archive/` URL |
| `every_cargo_spawn_gets_toolchain_env` | unit (app) | `RUSTUP_HOME`, `CARGO_HOME`, `PATH`, linker variables |
| `zig_wrapper_filters_unsupported_flags` | unit | D17 |
| `pins_toml_is_the_only_pin_source` | CI (xtask) | no version duplicated in workflows or code |
| On the Deck, in Game Mode | manual | Setup installs the toolchain and Zig with no root; the NS2 project runs with RB and shows the gradient (screenshot). If S5 failed: the fallback NS2 runs in the Run output overlay |

**Deferred.** Self-update (M11).

---

### M11 — Polish, parity, hardening, release

**Goal.** Doodle parity on everything that is about feel and trust, and a release that installs on the Deck.

**Scope.**
- **Keys and heat**: features/03 F10-F11 (the Key Layout page, `doodle-rs_keys.tsv`), F13-F14 (heat with
  canonical-path keys, `doodle-rs_heat.tsv`) and F16.
- **Look and sound**: features/10 F17 and F21-F23 (worn cells, icons through resvg, sounds, dev overlays). The
  full Settings page.
- **Release**:
  - self-update (features/09 F35, hardened per D17);
  - D19 `release.yml`, and the Deck install script with its SHA-256 check;
  - D20 `cargo xtask deck bench`;
  - the prewarm setting (O14);
  - the product name (O1), renamed before the first release.
- **Tools**: the full `xtask trace find|script`.

**Deliverables.**
- Release artifacts and the bench results in `docs/milestones/M11.md`.
- `tests/north_star/press_budget.toml`, frozen.

**Exit criteria.**

| Test | Kind | Asserts |
|---|---|---|
| `keymap_assign_rules`, `keymap_parse_repairs`, `keymap_old_file_gains_new_action_default`, `keys_page_refusals_name_the_reason` | unit / press | P14, ported |
| `heat_key_is_canonical_path_across_projects`, `heat_refused_pick_records_nothing`, `heat_merge_with_file` | unit | P22, P23 |
| `every_action_has_glyph_and_icon_fallback` | unit | features/10 F21 |
| `state_machine_proptest` | prop | rust/01: no panic; the cursor is always on a stop; the menu stack is consistent |
| `loader_fuzz_on_mutated_corpus` | prop | no panic; byte round trip |
| `press_budget_ns0_ns1_ns2` | exact | fails when the inputs exceed the budget by more than 10% |
| `bindings_table_generated_from_action_info` | unit (xtask) | fixes features/11 open question 5 |
| `self_update_refuses_release_without_digest`, `self_update_semver_compare`, `windows_update_script_replaces_every_executable` | unit | D17 |
| Release job checks | CI (release) | `check-release`, load paths, no `%zmm` in whisper, a real transcription, fixed-name assets (D19) |
| `cargo xtask deck bench` | manual (Deck) | every rust/01 budget met; results committed |

### After v1 (deferred everywhere above)

- rust/02 §12 in full: `macro_rules!` matchers, writing procedural macros, HRTB and outlives bounds, async
  runtimes beyond Add crate, `gen` blocks, default field values, destructuring assignment, `build.rs` and
  multi-crate workspace authoring, doc tests as editable code, and refactors such as extract function.
- NS3 (below).
- macOS (O16).

---

## North-star acceptance test

### The ladder

The yardstick is Doodle's `test_handmade_exact_build` (features/11 §6, P2). It builds the owner's real program
from New Project with controller-equivalent input only, compares it byte for byte, reloads it, and runs the
compiler on it. The Rust IDE keeps every rule of that test and adds four:
1. Y, LT+B and LT+A are real presses, not direct calls.
2. Oracle answers come from cassettes.
3. `cargo build` and `cargo test` run in CI. Doodle skipped compiler checks in CI (features/11 open question 3).
4. There is a press-count budget.

| Program | What it is | Why |
|---|---|---|
| **NS0** | `cargo new`'s hello world | the smallest end-to-end program; text tools and word-by-word inserts |
| **NS1** | The Rust Book's guessing game, listing 2-6, on `rand = "0.10.1"` | a dependency, a trait from a glob import, `&mut`, shadowing, `match` on a `Result` typed by an annotation, `continue`/`break` in arms, a rustfmt chain break |
| **NS2** | `handmade-rs`: Handmade Hero days 1 to 4 on `minifb` 0.29.0 | the owner's own north star carried to Rust: a window, a back buffer, the weird gradient, input and a test |

O15 picks these, with a `crossterm` fallback for NS2 if S5 shows that minifb can't build on the Deck.

### Reference files in the repo

These files are committed at M0 and never edited by hand afterwards. Any change is a deliberate deviation (see
"Deviations").

```
tests/north_star/
  SHA256SUMS            sha256 of every file below (LF endings)
  seeds.toml            Boot.seed per NS test, and the project name that seed generates
  ns0/Cargo.toml        ns0/src/main.rs
  ns1/Cargo.toml        ns1/Cargo.lock   ns1/src/main.rs   ns1/NOTICE   (Rust Book: MIT OR Apache-2.0)
  ns2/Cargo.toml        ns2/Cargo.lock   ns2/src/main.rs
  regions.toml          the NS2 stage regions a-f as line ranges
  press_budget.toml     controller inputs per NS test (logged from M4, enforced from M11)
.gitattributes          tests/north_star/** -text
                        tests/corpus/** -text        (no CRLF conversion on Windows checkouts)
```

- **Cargo.toml.** Each `Cargo.toml` is exactly what the IDE writes:
  - the `cargo new` template with the project name generated from the test's seed;
  - plus the one dependency added through Add dependency (`cargo add <crate>@<version>`).

  So NS1's `Cargo.toml` differs from the Rust Book's on purpose: no comment line, and a generated package name.
  The project-name word lists are frozen once M0 ships, like action keys (P19). Changing them changes every
  reference.
- **Cargo.lock.** NS1's and NS2's `Cargo.lock` are generated once with the pinned toolchain and committed, so their
  `--locked` builds are reproducible. NS0 has no dependencies and no `Cargo.lock` (the IDE never writes one); its
  compile checks run `--offline` without `--locked` (the `compile` kind).
- **Order at M0.** The `main.rs` sources, `ns1/NOTICE`, `regions.toml` and the `.gitattributes` lines are
  committed first. `seeds.toml`, the three `Cargo.toml` files, the two `Cargo.lock` files and `SHA256SUMS` are
  written once the project-name generator exists (rust/01 "Project names"), from its real output.
- **Line width.** If O3 is answered as 80, regenerate NS1's and NS2's `main.rs` with
  `rustfmt --config max_width=80` and add `rustfmt.toml` to those references in the same commit.

### Reference programs

**NS0** (`src/main.rs`, as `cargo new` writes it):

```rust
fn main() {
    println!("Hello, world!");
}
```

`Cargo.toml` (the template; `<name>` is the seeded project name):

```toml
[package]
name = "<name>"
version = "0.1.0"
edition = "2024"

[dependencies]
```

Path:
1. New Project; A on the green dot > Functions > Function (named `main` automatically).
2. A on the `●` row > Calls > Macro > Print > `println!`.
3. Dictate `hello world` into the string.
4. Text tools: Word case > `hello` > Capitalized.
5. Word by word: insert `,` after `Hello` and `!` at the end.
6. RT+Y.

`cargo run` prints exactly `Hello, world!\n`.

**NS1** (`src/main.rs`; rust-lang/book `listings/ch02-guessing-game-tutorial/listing-02-06/src/main.rs`, MIT OR
Apache-2.0; 36 lines, 813 bytes, sha256 `b54117bed799aa845eb05a797a5ee7cc8e20cdfb616bc8ecfe30c4921cff3a3e`):

```rust
use std::cmp::Ordering;
use std::io;

use rand::prelude::*;

fn main() {
    println!("Guess the number!");

    let secret_number = rand::rng().random_range(1..=100);

    loop {
        println!("Please input your guess.");

        let mut guess = String::new();

        io::stdin()
            .read_line(&mut guess)
            .expect("Failed to read line");

        let guess: u32 = match guess.trim().parse() {
            Ok(num) => num,
            Err(_) => continue,
        };

        println!("You guessed: {guess}");

        match guess.cmp(&secret_number) {
            Ordering::Less => println!("Too small!"),
            Ordering::Greater => println!("Too big!"),
            Ordering::Equal => {
                println!("You win!");
                break;
            }
        }
    }
}
```

`Cargo.toml` is the template plus `rand = "0.10.1"` under `[dependencies]`.

What NS1 forces the menus to support:
- **Three path spellings**: `io::stdin()` through an imported module; `rand::rng()` crate-qualified; and
  `Ordering::Less` through an imported type. The menus must be able to produce each spelling on purpose, through
  rust/02 §1.13's auto-use and its path rules.
- **A glob import** that brings a trait's method (`random_range`) into scope.
- **Import groups** std, then external, separated by a blank line.
- **A 61-column chain** that rustfmt breaks into three rows. The layout engine must match it (D5).
- **Shadowing**: `let guess: u32 = …` over `let mut guess`.
- **An expected type that flows from the annotation** into a generic `parse()`. The arms come from `Result`, and
  `Err(_)` is an unfilled pattern hole that saves as `_` (D4).
- **`&mut guess`** through Pass as, and **`&secret_number`**.
- **`continue` and `break` inside arms**, and a block arm body.

**NS2** (`src/main.rs`; 100 lines, 2734 bytes, LF; sha256
`7ce64ba7bf866a066b05356b86bbc17106f5431e8c0f9133ed65da695c8b5547`):

```rust
//! Handmade Hero, days 1 to 4, in Rust: a window, a back buffer and the weird gradient.

use minifb::{Key, Window, WindowOptions};

const WIDTH: usize = 960;
const HEIGHT: usize = 540;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Direction {
    Left,
    Right,
    Up,
    Down,
}

struct OffscreenBuffer {
    memory: Vec<u32>,
    width: usize,
    height: usize,
}

impl OffscreenBuffer {
    fn new(width: usize, height: usize) -> Self {
        OffscreenBuffer {
            memory: vec![0; width * height],
            width,
            height,
        }
    }

    fn render_weird_gradient(&mut self, x_offset: i32, y_offset: i32) {
        for (y, row) in self.memory.chunks_mut(self.width).enumerate() {
            for (x, pixel) in row.iter_mut().enumerate() {
                let blue = (x as i32 + x_offset) as u8;
                let green = (y as i32 + y_offset) as u8;
                *pixel = u32::from(green) << 8 | u32::from(blue);
            }
        }
    }
}

fn pressed_direction(window: &Window) -> Option<Direction> {
    if window.is_key_down(Key::Left) {
        Some(Direction::Left)
    } else if window.is_key_down(Key::Right) {
        Some(Direction::Right)
    } else if window.is_key_down(Key::Up) {
        Some(Direction::Up)
    } else if window.is_key_down(Key::Down) {
        Some(Direction::Down)
    } else {
        None
    }
}

fn step(direction: Direction, x_offset: &mut i32, y_offset: &mut i32) {
    match direction {
        Direction::Left => *x_offset -= 1,
        Direction::Right => *x_offset += 1,
        Direction::Up => *y_offset -= 1,
        Direction::Down => *y_offset += 1,
    }
}

fn run() -> Result<(), minifb::Error> {
    let mut window = Window::new("Handmade Hero", WIDTH, HEIGHT, WindowOptions::default())?;
    window.set_target_fps(60);
    let mut buffer = OffscreenBuffer::new(WIDTH, HEIGHT);
    let mut x_offset = 0;
    let mut y_offset = 0;
    while window.is_open() && !window.is_key_down(Key::Escape) {
        if let Some(direction) = pressed_direction(&window) {
            step(direction, &mut x_offset, &mut y_offset);
        }
        x_offset += 1;
        buffer.render_weird_gradient(x_offset, y_offset);
        window.update_with_buffer(&buffer.memory, buffer.width, buffer.height)?;
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("handmade: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gradient_starts_black_at_the_origin() {
        let mut buffer = OffscreenBuffer::new(4, 2);
        buffer.render_weird_gradient(0, 0);
        assert_eq!(buffer.memory[0], 0);
        assert_eq!(buffer.memory[5], 1 << 8 | 1);
    }
}
```

`Cargo.toml` is the template plus `minifb = "0.29.0"`. The program deliberately avoids async, bounded generics and
lifetimes. NS1 and the S12 fixture cover borrowing; NS3 covers generics and lifetimes.

**NS2 outline**: regions, what they force, and when they're first built.

| Region (`regions.toml`) | Lines | What it forces (feature and doc) | First built by |
|---|---|---|---|
| a. file scope | 1-20 | `//!` module docs by dictation plus text tools and word inserts (features/08 F13, F16; rust/02 §3.2); `use minifb::{…}` grown by auto-use and merged and sorted (rust/02 §1.13); typed `const` with keypad numbers (rust/02 §3.7; features/08 F18); the derive checklist (rust/02 §3.10); variants cased UpperCamel by dictation (rust/02 §1.8); struct fields with composite `Vec<u32>` (rust/02 §4.4, §7) | `ns2_stage_types` (M3, lines 9-20 without the derive), `ns2_stage_file_scope` (M6) |
| b. `impl` + `new` | 22-30, 40 | impl block, `Self` in the type menu, the tail slot holding a struct literal with every field, `vec!` repeat form, field-init shorthand (rust/02 §3.6, §1.11, §1.12, §9.8) | `ns2_stage_impl_new` (M6) |
| c. `render_weird_gradient` | 31-39 | `&mut self` receiver; `for` with a tuple pattern; Field of `self`; method chains with `Extend` (`chunks_mut(..).enumerate()`, `iter_mut().enumerate()`); `as` casts and automatic parentheses (features/06 F11); assignment to `*pixel`; `u32::from`; shift and or precedence with no extra parentheses | `ns2_stage_render_weird_gradient` (M6) |
| d. `pressed_direction` + `step` | 42-63 | `&Window` parameter; an `if` / `else if` chain of tail values typed `Option<Direction>`; enum variant paths; `match` with generated arms; compound assignment through `&mut` | `ns2_stage_step` (M5, lines 56-63), `ns2_stage_pressed_direction` (M6) |
| e. `run` | 65-80 | `Result<(), minifb::Error>` with a crate path type; `?` gated by the return type; `let mut` added automatically when a `&mut self` method is called (O20); `while` with `&&` and `!`; `if let Some(..)`; Pass as `&window`, `&mut x_offset`; inferred `i32` | `ns2_stage_run` (M6) |
| f. `main` + `tests` | 82-100 | `if let Err(error)`; `eprintln!` with the inline capture `{error}`; a full-path call `std::process::exit(1)`; Test function creates `#[cfg(test)] mod tests { use super::*; }`; `assert_eq!`; numeric operators in a literal expression | `ns2_stage_main_and_tests` (M6) |
| whole file | 1-100 | everything above composed, with no seams | `ns2_handmade_exact_build` (M7) |

### Rules (for every `ns*_exact` and `ns2_stage_*` test)

1. **Start.** Start at `App::new(Boot::test(seed))` in the main menu, with the seed from `seeds.toml`. New Project
   goes through the presses `pad.new_project()` makes: New Project, then from M2 the default root on the "where?"
   page.
   - Stage tests start differently. They seed `MemFs` with a project whose `src/main.rs` is the reference with
     that stage's region removed, and open it through Recent Projects presses (M6+).
2. **Cursor.** Every cursor move is a d-pad `Input` through `update`. `dpad_to` computes the target, restores the
   cursor, then presses its way there. It fails with `D-pad: <line> is not a cursor stop` or
   `D-pad stuck at line N`.
3. **Menu picks.** Every pick is `menu_go`: a BFS over the core's real grid navigation, then A. It fails with
   `menu "<title>": "<label>" is not reachable with the D-pad`.
4. **Buttons.** Y, LT+A, LT+B, RT+A, RT+X, RT+Y, LB and RB are real `Input::press`/`Input::combo` presses under
   the default keymap. Nothing calls an editor function directly.
5. **Text.** All text comes from `pad.dictate("...")`: Talk is held on the highlighted target, the `FakeSpeech`
   engine returns the words as one clip, and Talk is released. The words must be something push-to-talk can
   produce: lowercase words, digits and spaces. Casing comes from the role or from LT+A text tools; punctuation
   comes from word-by-word inserts. `Input.typed` is never used, because NS programs need no file names.
6. **Async results.** They come from `MemExecutor`:
   - `MemFs`;
   - the oracle cassette `tests/cassettes/ns*.jsonl` (M5+; recorded with `REC_ORACLE=1`);
   - `FakeRunner`, `FakeSpeech`;
   - settling until quiescent.
7. **Save** is RT+Y. The bytes compared are the ones `Request::Write` handed to `MemFs`.
8. **Grays.** From M5 on, picking a grayed entry on an NS path **fails** the test, unless the test lists it in
   `EXPECTED_GRAY_PICKS` with a reason. Every NS program compiles, so a gray on its path is a false gray (D8).
   This is stricter than Doodle, which only logged such picks as `FINDING:` notes.
9. **Trace.** The test saves its fed inputs as `tests/traces/<test>/` (`Pad::save_trace`), and
   `committed_traces_replay_headless` replays them.

### Assertions

1. `src/main.rs` and `Cargo.toml` equal the reference byte for byte. On a mismatch, first log `FINDING:` diff hunks
   (`@@ -a,b +c,d @@`, as features/11 §6), then fail.
2. Reloading the saved bytes gives the same `Line`s (field roles and ranges) as the built document, and saving
   again changes nothing.
3. The pinned `rustfmt --check --edition 2024` passes.
4. In a temp copy: for NS1 and NS2, with the committed `Cargo.lock` copied in, `cargo build --locked --offline`
   and `cargo test --locked --offline` pass; for NS0 (no dependencies, no lockfile), `cargo build --offline` and
   `cargo test --offline` pass. NS2 must show `1 passed`. The CI job runs `cargo fetch --locked` for NS1 and NS2
   once before the suite. The Ubuntu job installs the system packages minifb's README lists (**verify** the list at
   the pin).
5. Run checks:
   - NS0: `cargo run` prints exactly `Hello, world!\n`.
   - NS1: `cargo run` with stdin `1\n2\n…\n100\n` exits 0, and stdout contains `You win!`. This is deterministic,
     because every possible secret gets guessed.
   - NS2: not run in CI (it opens a window). It runs manually on the Deck at M10.
6. The test logs `built with N controller inputs`. From M11 it fails when N > `press_budget.toml` × 1.10.
7. Artifacts go to `<temp>/doodle-rs-north-star/<test>/{first_save, saved, built/}`.

### Staged sub-goals per milestone

| Milestone | Test | Target |
|---|---|---|
| M0 | `ns_m0_fn_main_package_builds` | `fn main() {}` package from New Project; `cargo build`, `cargo run` |
| M3 | `ns2_stage_types` | NS2 lines 9-20 without the derive, above `fn main() {}`, from an empty project; `cargo check` |
| M4 | `ns0_hello_world_exact` | NS0 complete, with `cargo run` output |
| M5 | `ns2_stage_step` | NS2 lines 56-63 with generated arms, given `Direction` |
| M6 | `ns1_guessing_game_exact` | NS1 complete, with the stdin run |
| M6 | `ns2_stage_file_scope` … `ns2_stage_main_and_tests` | each NS2 region built into the reference-minus-region; full-file byte equality |
| M7 | `ns2_handmade_exact_build`, `ns*_load_round_trip` | NS2 from the main menu, no seams |
| M8 | `ns2_repair_drill` | the `mut` repair through the Fix group |
| M9 | NS0 by real voice (manual) | on the Deck, with the real microphone |
| M10 | NS2 runs on the Deck (manual) | RB runs it in Game Mode; screenshot |
| M11 | `press_budget_ns0_ns1_ns2` | budgets frozen and enforced |

### Deviations and the fallback

- **Deviation policy.** Any deliberate difference from a reference is written into the test with its reason, as
  Doodle did for `GetMessageW(...) > 0` (features/11 §6). There are none today.
- **If minifb can't build on the Deck** (S5): NS2 switches to a `crossterm` program with the same regions and
  constructs. It still has an `OffscreenBuffer`, `Direction`, `step`, `run` with `?`, `main` and a test, and it
  renders the gradient as terminal cells. Write it, verify it (rustfmt-clean, clippy-clean, its test passes on
  the pinned toolchain), and commit it at M0 with a new `regions.toml`. The minifb NS2 stays as a desktop-only
  test.
- **If clippy's precedence lints are ever enabled** (`clippy::precedence`, or the restriction lint
  `precedence_bits`; **verify** the names at the pin): `u32::from(green) << 8 | u32::from(blue)` may want
  parentheses. That would be a deliberate deviation.

### Stretch: NS3 (after M11)

A second file plus real generics and lifetimes:
- split handmade-rs into `main.rs` and `buffer.rs` (`mod buffer;`, `pub` items,
  `use crate::buffer::OffscreenBuffer;`);
- add `fn brightest_row<'a>(rows: &'a [u32], width: usize) -> &'a [u32]`;
- add `trait Renderer { fn render(&mut self, frame: u64); }` with `impl Renderer for OffscreenBuffer`.

The rules and assertions are the same as above.

---

## Risk register

L = likelihood and I = impact (H/M/L). "Retired by" names the milestone and the test that prove the risk is under
control. A fallback is taken when its trigger fires, and the switch is recorded in `docs/spikes/` or the
milestone report.

| ID | Risk | L | I | Early spike | Fallback (and trigger) | Retired by |
|---|---|---|---|---|---|---|
| R1 | `ra_ap_*` churn and stalls: partial publishes (`ide`/`load-cargo` stuck at 0.0.358), private expected-type machinery, renamed APIs | H | H | S1 | The LSP `Engine` behind the same protocol plus a stronger syntax layer (D6). Trigger: S1 < 8/10, or the set unpublished > 3 months while a toolchain bump is due | M5 `oracle_conformance_suite`; weekly `ra-bump` |
| R2 | Oracle latency and memory on the Deck (cold 15-90 s, 0.5-2.5 GB) | M | H | S7, S1 latency | `analysis off for this project (too big for this device)`; `prefill_caches` off; 2 workers. Trigger: RSS cap hit twice per session, or warm p95 > 150 ms | M5 timing tests; M11 Deck bench |
| R3 | Proc macros, derives and build scripts: the ABI must match; executing third-party code | H | M | S11 | Proc macros off → Unknown, with the placeholder `(items from macros are unavailable)` | M6 `derived_clone_listed_without_proc_macro_server` |
| R4 | Determinism with an async, cancellable oracle | H | H | S8 | Keep facts out of the fingerprint, and no oracle-driven entry counts (D7) | M1 trace; M5 `replay_with_recorded_oracle_events_is_deterministic` and the stale/frozen tests |
| R5 | Borrow and lifetime errors the user can't fix by typing; errors arrive in waves after type errors | H | H | S12 | Explain-only entries plus `rustc --explain` in Docs, and Grab | M4 auto-`mut`; M8 `e0xxx_*` tests and `borrow_fixture_machine_fixes_compile` |
| R6 | Trait-heavy APIs make method menus explode | H | H | S10 | Inherent methods and traits in scope only, plus `Search by voice`: dictated words filter the full `MembersOf` list and the user still picks a listed method (nothing unlisted is inserted) | M6 `method_menu_reaches_any_method_within_12_presses` |
| R7 | Partial inference causes false grays (violates P7) | H | M | S9 | Gray only scalar literal mismatches | M5 `no_false_gray_on_corpus` (CI from M5 on) |
| R8 | Macros are opaque to the projection; format strings must stay in sync with arguments | M | M | S2 (macro calls) | Format macros opaque, with only the string text editable | M4 `format_placeholders_track_argument_dots`; M7 `unknown_macro_is_one_opaque_unit…` |
| R9 | Holes don't round-trip, or O2 rejects bare `todo!()` | M | H | S2 (hole matrix) | `todo!("●")`: a one-table change (D4) | M3 `hole_matrix_items`; M7 `every_hole_kind_reloads_as_the_same_hole` |
| R10 | The layout engine drifts from rustfmt's heuristics (chain width and friends) | H | M | S3 | Item-scoped rustfmt as a `Request` under the settle gate (D5). Trigger: a menu-producible statement that never matches `rustfmt --check` | M3/M4 `layout_matches_rustfmt…`; the CI corpus check |
| R11 | Projection granularity: too many or too few stops; multi-line expressions | M | H | S2 | Tune the per-node-kind stop table; Walk for deep units | M7 `every_token_reachable_by_dpad_on_corpus` |
| R12 | `cargo check` / `build` time and disk on the Deck | M | M | S13 | `Check while editing: off` (check on Save and Run only) | M8 check bench; M11 Deck bench |
| R13 | `sdl3` crate churn (pre-1.0), Steam Input mapping, the on-screen keyboard | M | H | S4 | `sdl2` 0.39 behind the same `doodle-platform` API (D12) | M1 Deck checklist |
| R14 | The Deck linker and native dependencies: Zig as `cc`; minifb's system headers | M | H | S5 | `cargo-zigbuild` as the build driver; the NS2 `crossterm` fallback | M10 manual Deck run |
| R15 | Grammar size: menu bloat, construct coverage, a wall of opaque text on load | H | M | S2 (node-kind counts) | Unrecognized code stays opaque (P8 fallback); coverage drives the backlog | M7 `loader_coverage_at_least_95_percent_of_corpus_statements` |
| R16 | Out-of-file edits vs P12 | M | M | — (O12) | Confirmed, named exceptions only (D18) | M6 `add_dependency_writes_nothing_before_a`, `new_module_file_confirms…` |
| R17 | Toolchain skew: the project's toolchain vs the pinned std tables, proc-macro ABI and edition | M | H | S11 | The pinned tables plus Unknown; `Generate tables for <version>` (D9) | M10 `every_cargo_spawn_gets_toolchain_env` |
| R18 | Security: opening a project runs build scripts and proc macros | M | H | — (O10) | Browse-only mode (D17) | M7 `untrusted_folder_runs_no_build_code` |
| R19 | Rename semantics under shadowing | M | M | S1 | A CST scope walker that handles `let x = x…` | M9 `rename_shadowing_let_x_eq_x` |
| R20 | LLM builder velocity: `ra_ap` compile time, slow tests, doc drift | H | M | — | The DAG keeps semantic `ra_ap` out of the core; `opt-level = 2` for deps; `doc-check` | M0 core test time < 15 s; M1 `doc-check` |
| R21 | Unicode: byte-slice panics on non-ASCII | M | M | — | `char_indices`, `unicode-width`; clippy `string_slice` in the core (**verify** the name at the pin) | M4 `unicode_text_ops_never_panic` |
| R22 | A core panic loses work (Doodle has no autosave) | M | H | — | Recovery snapshots and the panic hook (D15) | M3 `recovered_docs_offer_restore…`; M11 `state_machine_proptest` |
| R23 | Diagnostics mirror correctness: absolute paths in build scripts, `include_str!` outside the package | M | M | S13 | Fall back to rust-analyzer diagnostics and say so once (D10) | M8 `mirror_never_writes_the_project` and live checks |
| R24 | The settle gate feels laggy, or grays arrive too late | M | M | S1 latency | O5 off: menus open at once with `checking types...` | M5 Deck latency numbers |
| R25 | Trace size and cassette drift | M | L | S8 | zstd plus dedupe; weekly re-record; content-addressed cassettes | M5 replay tests; M11 bench (≤ 20 MB/h) |
| R26 | Voice latency on the Deck | L | M | S6 | Stay on `whisper-cli` | M9 latency numbers |
| R27 | The north star needs constructs the plan doesn't schedule | M | M | NS outline table | Move the construct into the next milestone; record the deviation | M6 stage tests; M7 `ns2_handmade_exact_build` |
| R28 | The owner's ARM64 Windows dev machine: SDL3 static build and `ra_ap` on `aarch64-pc-windows-msvc` | L | M | the M0 CI job | Develop under x64 emulation, as Doodle validated | M0 ARM64 CI job green |

---

## Testing strategy and definition of done per feature

### Test layers

| Layer | What it proves | Where | Runs |
|---|---|---|---|
| Unit | pure functions: parsers, fit bits, grouping, namegen, layout rules, setup rows | next to the code in each crate | every push |
| Core press tests | behaviour through `update` only (features/11 §4), with seams allowed | `crates/core/tests/<area>.rs` | every push; core suite < 15 s |
| Controller-exact tests | reachability with real presses (features/11 §6, stricter) | `crates/core/tests/north_star.rs`, `statements.rs`, … | every push |
| Properties | invariants Doodle only checked by example: round trip, partition, idle identity, determinism, no false grays, never panics, every stop reachable | `proptest`, in the area files | every push (fixed seeds); weekly (long) |
| Snapshots | `Scene`, HUD, menu labels, parsed records | `insta` | every push; changes reviewed in the diff |
| Compile checks | menu output compiles, formats and runs | `compile` tests (`#[ignore = "compile"]`) | CI step 4; `cargo xtask ci-local` |
| Oracle | the real oracle answers the golden queries; cassettes are current | the oracle job | push touching `oracle`/`facts`/`cassettes`; weekly re-record |
| Trace fixtures | replays stay deterministic across changes (P17) | `tests/traces/` | every push (headless) |
| Timing | rust/01 budgets that can run on CI | `timing` tests | every push, with a factor |
| Deck | budgets and feel on the reference device (P24) | `cargo xtask deck bench`, manual checklists | per milestone (manual) |

### Fakes and fixtures

- **`MemExecutor`** services every `Request` in memory.
  - `MemFs` (reads, writes, listings, trash, mtimes);
  - `FakeFacts` (hand-written answers) or a cassette (content-addressed: query kind + parameters + text hash);
  - `FakeSpeech` (scripted clips), `FakeRunner` (records argument vectors, returns scripted statuses);
  - fake `Metadata` and `Registry` answers from fixture JSON.

  Adding a `Request` variant without a `MemExecutor` arm is a compile error (exhaustive `match`).
- **Corpus.** `tests/corpus/` is vendored and licensed (see M7). `tests/rustc-json/` and `tests/cassettes/` are
  regenerated only through `xtask` commands, and each regeneration is its own commit.
- **Process tests.** Tests that need a tool (cargo, rustfmt, whisper, the real oracle) run in CI. Locally they
  skip only when the tool is missing, and they print why. A silent skip is not allowed (features/11 open
  question 3).
- **No flakiness by construction.** There are no sleeps, no real clocks in the core, no `HashMap` iteration in
  anything ordered or fingerprinted (D1 clippy bans), and no network outside the weekly job.
- **Regression tests.** Each bug or review finding gets one test named for the behaviour, placed in its area file
  with a `// regression: <finding>` comment (features/11 §8).

### Definition of done per feature

This mirrors Doodle's recipe (features/11 §25), made explicit and checked.

| # | Item | Check |
|---|---|---|
| 1 | **Core module.** The behaviour lives in one core module (`crates/core/src/<area>/<feature>.rs`), and its `//!` header is written from the user's side, with `●` examples and the buttons that act (P27) | review |
| 2 | **State.** It lives in `App` or a `Mode` variant, so illegal combinations can't be expressed | review |
| 3 | **Effects.** Each new effect has exactly one `Request` variant, one executor arm, one `MemExecutor` arm and one trace payload kind (D1) | exhaustive `match` compiles |
| 4 | **Keymap (if the feature needs a button).** The `Action` is appended; `ActionInfo` has a key that is never renamed, a label, a glyph and a hint; it gets a default slot or stays unbound; it appears in the Key Layout picker; there is an old-file compatibility test | `keymap_*` tests |
| 5 | **Tests.** Press tests for the behaviour; B restores; LT+B on every new part; every gray has a reason and the right kind; Unknown never grays (typed features); build → save → reload gives the same `Line`s and a compile check (features that emit code); a `prop` test for any new invariant | CI |
| 6 | **Trace.** A trace name for the new mode; the fingerprint mixes the new state only while it is active, behind its own tag (features/11 §12); `events.jsonl` kinds; a fixture trace if it adds a mode or a request kind; old fixtures still replay | `committed_traces_replay_headless` |
| 7 | **Bindings.** The analysis bindings table is generated from `ActionInfo`, never hand-edited | `bindings_table_generated_from_action_info` |
| 8 | **Docs.** A `docs/features/` section (Trigger, Behavior, Rules & edge cases, Tests, Source); the rust/02 row if it is a construct; the README if it adds user-facing setup | `cargo xtask doc-check` |
| 9 | **Budgets.** A `timing` test if it opens a menu over a big list or touches every line | CI |
| 10 | **Verify.** `cargo xtask ci-local` (fmt, clippy, lint-deps, nextest including compile tests, trace verify, doc-check); a scripted screenshot for UI changes (`--replay … --screenshot`) | before commit |

**A construct is done** when it ships as a complete kit (R15):
- its leaf in the right menu, with the exact label;
- its template, holes and hole spellings;
- its Y options and its LT+B chain (finest first);
- recognition by the projection, which is automatic, but proven by `loader_builds_same_fields_as_menus`;
- four tests: exact build text, round trip, a compile-matrix row, and the delete chain;
- a row in the menu-shape snapshot;
- its gray rows with reasons and its HUD hint strings (features/05 §29 analog).

A construct without a kit loads as `Opaque`, and that is fine.

### CI matrix (rust/01 D19, with what each job runs)

| Job | When | Runs |
|---|---|---|
| `ci` on `ubuntu-22.04` and `windows-latest` | every push and PR | fmt, clippy `-D warnings`, `lint-deps`, nextest (unit, press, exact, prop, snap, timing), compile tests, `trace verify`, `gen-std --check` (Linux), `check-release`, `doc-check` |
| `ci-arm64` on `windows-11-arm` (**verify** the label at M0) | every push and PR | build + core tests (O16) |
| `cargo xtask ci-local` | on the builder's host, before each commit, and as "green in CI" when nothing can be pushed | fmt, clippy, `lint-deps`, nextest with compile tests, `trace verify` and `doc-check` once they exist |
| `oracle` | pushes touching `oracle`, `facts`, `cassettes`; nightly | conformance suite; re-record cassettes; fail on diff |
| `weekly` | schedule | `ra-bump` PR; live-oracle NS tests; network tests; long proptest runs |
| `release` | manual | rust/01 D19 matrix and checks |
| Deck bench | manual, on the device | D20 budgets; results committed |

---

## Working conventions for the builder

### Commits

- **Subject**: `<type>(<scope>): <what the user gets>`.
  - Types: `feat`, `fix`, `test`, `docs`, `ci`, `refactor`, `perf`, `chore`.
  - Scopes are a crate or an area (the same list as PROMPT "HOW TO WORK"): `core`, `syntax`, `facts`,
    `knowledge`, `formats`, `oracle`, `menus`, `editor`, `keymap`, `hud`, `trace`, `app`, `platform`, `render`,
    `stt`, `setup`, `files`, `run`, `pins`, `xtask`, `testkit`, `ci`, `cassettes`, `north-star`, `milestones`,
    `docs`.
  - Examples: `feat(menus): value dots gray options that can't fit, with the reason under the grid`;
    `test(north-star): NS1 builds byte-exact from an empty project`.
- **Body.**
  - Behaviour first, in plain sentences or `-` bullets: controls, edge cases, refusals, with exact button names.
  - Then technical notes.
  - Then a counts line: `Tests: 412 core, 38 syntax, 12 app; traces: 9 verified; compile checks: 41.`
- **Trailer**: the attribution trailer the owner's instructions give (Doodle uses `Co-Authored-By:`).
- **One logical change per commit.** Never commit with a red test.
  - `ra_ap` bumps go only through the `ra-bump` PR.
  - Cassette and fixture regeneration is its own commit (`test(cassettes): re-record for ra_ap 0.0.N`).
  - Generated files (the std blob, cassettes, rustc JSON) are never edited by hand.
- **Milestone close**: `docs(milestones): M3 done` with the report.

### Docs voice

- Plain, precise sentences for an LLM or human implementer. User-facing text is second person, short, and names
  the buttons (P21).
- Examples use `●` for dots and real labels in backticks.
- No filler and no marketing.
- Dates are absolute (`2026-11-24`). A version-sensitive fact carries its check date or **verify at the pin**.
  Never write a third-party API name you haven't checked.

### Persistence conventions (every file the IDE owns)

1. **Format**: a pure `parse`, `serialize` and `text_ok` in `doodle-formats`, unit-tested. A thin store in
   `doodle-app` (D15).
2. **Header**: the first line is `doodle-rs-<kind> N`. Bump N only for an incompatible change, and add a test that
   an older build refuses the newer header.
3. **Reading**:
   - missing means defaults, silently;
   - unreadable or newer means defaults plus `nosave`, reported once per session on the status line, and the file
     is never overwritten;
   - a failed read is retried once after 50 ms;
   - blank lines, `#` comments and unknown lines are tolerated, and unknown lines are written back.
4. **Writing**: write `<file>.tmp` next to the target, then `std::fs::rename`. Heat merges with the file on save,
   at most every 2 s and at quit.
5. **Keys**: stable string keys (action keys, construct ids, canonical item paths) are never renamed once shipped.
   An old file picks up a new action's default.
6. **Order**: stores load before the trace starts. A replay pins them from the trace meta and never reads or
   writes the real files.
7. **Location**: per-user files live in the data dir (O9). The only project-local file is
   `.doodle-rs/run.txt`, which also has a header. Recovery snapshots never go into the project.

### Keeping a features/ spec of the Rust IDE up to date

- The new repo carries two doc trees:
  - **`docs/design/`** holds living copies of rust/01, rust/02 and this doc. Change them when a decision changes,
    and add one line to `docs/design/CHANGES.md` (date, decision, reason).
  - **`docs/features/`** is the behaviour spec of the Rust IDE. It uses the handoff's numbering
    (`00-principles-and-constraints.md` … `11-engineering-practices.md`) and its section skeleton: Purpose;
    Features with Trigger / Behavior / Rules & edge cases / Source; Invariants; Data model & formats; Tests that
    pin this behavior; Open questions.
- `00` starts as a verbatim copy of the handoff's principles with a "Rust deviations" table prepended (P#,
  deviation, D/O reference). Inline `**Rust:** … (rust/01 Dn)` marks may follow, milestone by milestone.
- The handoff docs (`docs/handoff/features/`) describe Doodle. They are read-only reference and are not edited.
- A feature's doc section is written **in the same commit** as the feature. Doodle's main feature doc changed in
  only 4 of 91 commits (features/11 open question 10). This rule plus the check below prevents that.
- **`cargo xtask doc-check`** (CI from M1) scans `docs/features/` only (never `docs/handoff/` or `docs/design/`).
  It fails when:
  1. an `ActionInfo` key is missing from `docs/features/03`;
  2. a `ConstructId` is missing from `docs/features/04` or `05`, or from the living rust/02;
  3. a test named in a `docs/features/` doc's "Tests that pin this behavior" doesn't exist as a `fn` in the
     workspace (a test of a later milestone may be listed with the suffix `(planned Mn)`);
  4. a `Request` or `Event` variant is missing from `docs/features/11`;
  5. a persisted file header is missing from `docs/features/00` "Data model & formats".

### Milestone reports, owner decisions and spikes

- `docs/milestones/Mn-progress.md` lists the milestone's steps with their status and commit hash, updated in
  every commit; a new session resumes from it (PROMPT "HOW TO WORK").
- `docs/milestones/Mn.md` covers:
  - the exit tests with their status (a CI run link, or the `cargo xtask ci-local` result with the CI jobs
    marked `not run (no push)`);
  - items `owner pending` or `device pending`;
  - the owner decisions asked, answered or defaulted;
  - spike verdicts used;
  - budget numbers measured (desktop and Deck);
  - deviations from references;
  - known gaps carried forward;
  - screenshots.
- Ask each owner decision at the milestone the glance table names. Build the default meanwhile.
- `docs/spikes/Sxx.md` covers the question, setup, numbers, verdict and the decision taken. A failed spike's
  fallback is applied to this doc's living copy in the same commit.

### Pins and facts

- `pins.toml` is the only place a toolchain, `ra_ap`, rustup-init, Zig, whisper or model version lives (D17).
  The catalog's crate pins and the NS references move together.
- Re-check the rust/01 version-facts table at M0 and at every `ra-bump`. Record the check date.

---

## Open questions for the roadmap

1. **Deck access.** S4, S5, S7, S13 and the bench need a Steam Deck. Until the owner runs them, results are
   `device pending`. Should the M0 demo require the Deck, or is desktop enough? Default: desktop is enough, and
   the Deck run is `device pending`. Asked in the M0 kickoff message, because it decides whether M0 can close.
2. **Grab placement.** This roadmap puts Grab and Copy line at M8, because the borrow restructure repairs need
   them. Doodle shipped Grab late. Should it come earlier (M4) for comfort while building bodies?
3. **M6 size.** M6 is the heaviest milestone (methods, `use`, dependencies, impl/traits, derives). If it runs
   long, split it into M6a (names, methods, `use`) and M6b (dependencies, impl/traits, tests module). NS1 gates
   M6b.
4. **NS2 fallback text.** The `crossterm` variant is not written yet. It is needed only if S5 fails, and it must
   be verified before it is committed.
5. **Gray picks on NS paths fail the test from M5 on** (rule 8). This is stricter than Doodle. Confirm, or keep
   them as `FINDING:` notes.
6. **Reference drift upstream.** The Rust Book changed the rand major version under the same listing in 2026.
   NS1 is pinned by file hash and `Cargo.lock`, not by upstream. Re-sync only by a deliberate deviation commit.

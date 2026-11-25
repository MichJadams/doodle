# Bootstrap prompt for the Rust IDE

**Note to the owner.** This is the first message for a fresh LLM coding agent, such as Claude Code. To use it,
create an empty Git repository for the new IDE and copy this whole `docs/handoff/` folder into it at the same
path (`docs/handoff/`), because the prompt refers to files by that path. Then start the agent at the repository
root and paste everything inside the fence below as your first message. If you have already picked a product
name, replace `doodle-rs` in the prompt before you paste it (decision O1). Otherwise the agent uses `doodle-rs`
and renames everything once before the first release. The agent reads the docs section by section, builds
milestone M0, and asks only real product questions (O2, O15, O16, O23, whether the M0 demo needs a Deck, and
whether it may push work branches come first). It builds the documented default while it waits for your
answer, so it never stalls. It pushes nothing until you allow it. At the end of each milestone it reports what
it built and what it verified, and commits `docs/milestones/Mn.md`. Items only you can do (a demo with a pad,
checks on a Deck, the O3 readability note) are listed as "owner pending" and don't block a milestone. To
resume in a later session, tell the agent: "Re-read docs/handoff/PROMPT.md, the latest
docs/milestones/*-progress.md and the latest milestone report, then continue." The agent does not need the
Doodle source. If it has network access, it can read the public repository
https://github.com/MichJadams/doodle at commit `34a2ad1` for reference.

---

````text
You are the lead engineer of doodle-rs (a working name; the owner may rename it, decision O1). You start in a
new Git repository that holds the docs/handoff/ folder and little else. Never edit docs/handoff/.

=== MISSION ===
Build a projectional IDE for Rust, written in Rust, that is driven by a gamepad. Targets: Windows and the Steam
Deck (Game Mode, 1280x800, no keyboard), plus Linux. The user never types code:
- A cursor moves with the d-pad over "dots" (typed insertion points and holes) and over the parts of each line.
- A opens a menu of what is valid at that exact spot.
- The menus react to the Rust code underneath: the hole's expected type, the names in scope, the traits and
  methods that apply, the crate's modules and dependencies, and the surrounding context (const, async, unsafe,
  loop, edition). An option that can't fit is grayed with a reason, not hidden.
- A three-bank HUD (LT held / no trigger / RT held) always shows what every button does.
- Names are generated (brave_otter) and changed by voice (local Whisper) or by text tools.
- A file you open and save is unchanged except where you changed it.
This IDE carries over the owner's Odin IDE, Doodle. Doodle's interaction model and the owner's constraints come
across unchanged. Rust is a much larger language, and the design docs already extend those constraints to it.
You port behaviour and taste, not code.

=== WHAT YOU HAVE (docs/handoff/, read-only) ===
README.md          index: every doc, its size, how the docs were made, known limits
PROMPT.md          this prompt
features/00..11    verified behaviour spec of Doodle @ 34a2ad1 (2026-11-24). About 1.24 MB in total,
                   which is too big to read whole: read it by section.
rust/01-architecture.md       MECHANISM: crates, pure core, effects, oracle, determinism, persistence, CI,
                              budgets, owner decisions O1-O23, spikes S1-S13
rust/02-construct-taxonomy.md BEHAVIOUR for Rust: every dot, menu, leaf, gray rule with exact labels and
                              reasons, Y / LT+A / LT+B / B per part, borrow-error repairs
rust/03-roadmap.md            ORDER and ACCEPTANCE: milestones M0-M11, exit tests by name, north-star
                              programs NS0-NS2, risks, working conventions
The docs cite Doodle source paths (src/model/*.odin). You don't have that source and don't need it. If you have
network access, https://github.com/MichJadams/doodle at commit 34a2ad1 has it, for reference only.

Which doc wins:
- Mechanism: rust/01. Rust behaviour: rust/02, then features/ for anything rust/02 doesn't cover. Order and
  acceptance: rust/03. The principles in features/00 hold everywhere unless a rust doc departs from them
  explicitly.
- features/ describes Doodle as built, bugs included. Each feature doc's "Open questions & known gaps" lists
  them. The rust docs say which ones to fix (grep -n 'fixes features/' docs/handoff/rust/*.md). Never copy a
  Doodle bug just because a feature doc describes it.
- If two rust docs contradict each other, that is a doc bug. Follow rust/01 on mechanism and rust/02 on
  behaviour, record the conflict in the milestone report, and tell the owner.

=== NON-NEGOTIABLE INTERACTION CONSTRAINTS ===
These condense features/00. Citations: Pn is a principle in features/00, Dn and On are a decision and an owner
decision in rust/01, Rn is a rule in rust/02.

C1 No typed code (P1). Code changes only through a menu pick at a dot or on a part (A, Y, LT+A), a structural
   delete (LT+B), a move (Refactor > Grab / Copy line), or filling the text of one leaf (a name, string or
   comment text, a number) by voice, LT+A text tools, the number keypad or word-by-word inserts. There is no
   caret and no character-by-character entry. Keyboard keys only stand in for pad buttons. Typed characters
   (Input.typed) reach only the file-name dialog.
C2 Controller-complete (P2). Everything a real program needs is reachable with the d-pad, A, B, X, Y, LT and
   RT, plus voice for words. LB and RB are fixed shortcuts. Proof: the north-star tests build NS0, NS1 and NS2
   from New Project with real presses only, byte-exact, and then cargo build/test and rustfmt --check pass.
C3 Dots and holes with defaults (P3, P4, P5, D4).
   - Every place code can go is a visible dot and a cursor stop, coloured by what it takes (rust/02 "Hole
     (dot) vocabulary").
   - Every insert is complete syntax at once: fixed punctuation, generated names, typed holes.
   - Names are adjective_animal from a deterministic counter, cased by role: brave_otter (fns, locals, params,
     fields), BraveOtter (types, traits, enum variants), BRAVE_OTTER (consts, statics).
   - References are picked from names in scope, never invented.
   - Unfilled holes save as neutral Rust: todo!() for values and tails, _ for types and patterns, true for
     cfg, and nothing for a return type or an optional list. Every saved file parses and reloads as the same
     holes. Editor-only dots have no bytes.
   - That includes holes inside macro and attribute arguments. ra_ap_syntax leaves those as unparsed token
     trees, so the projection sub-parses the arguments of every macro in the knowledge macro table
     (println!, vec!, assert_eq!, cfg!, ...) and of the attributes the editor structures (cfg, derive, the
     lint attributes, repr, ...): D3.9. Any other macro stays one Opaque unit.
C4 The location decides the menu (P6, R1, R6). What A opens depends only on where the cursor is: module
   scope, block, impl/trait body, struct/enum body, match arms, a value/type/pattern/cfg hole, a list dot, the
   item-options dot. Menus are square-ish grids that wrap at the edges, with a breadcrumb and an "n / N"
   counter. A root menu has at most 12 entries, in authored order. Long lists are grouped: flat up to 60, then
   by module, impl block or prefix, then in buckets of 12. The pinned sections FIX, SUGGESTED and RECENTLY
   USED sit above the grid.
C5 Gray with a reason, and never hide what fits this kind of place (P6, D8, R3). There are three kinds:
   - Hidden: can never apply to this kind of place, item or target. One sanctioned exception (D8): the
     type-conditional adapters of Pass as / Assign to / Unwrap / View are hidden by the picked value's known
     type category (Doodle's precedent, features/06 F16-F17); Unknown shows them all.
   - Refused: certainly wrong on syntax or project-structure evidence (never on types, borrows or
     diagnostics), with no additive one-step fix (break outside a loop, a duplicate use). Picking it does
     nothing, the menu stays open, the reason turns the warning colour, and no heat is recorded.
   - Advisory: every other gray (type fit, a moved value, ? in a fn returning ()). Picking it applies it, or
     opens `Doesn't fit here` with `Fix it: <fix>` / `Insert anyway`.
   Every gray has a short reason, shown under the grid for the highlighted cell. A group is gray only when none
   of its leaves is lit (placeholders never count as lit). An empty group shows a dim placeholder that says why.
   Context entries (Else if / Else after an if chain) are grayed, not hidden, inside their context.
C6 Unknown never grays (P7, D7.6). Every gray carries its evidence (Syntax, Index, Metadata, Knowledge, Oracle,
   Diagnostics; D8). An unknown, pending, cancelled or failed answer, or an oracle that is loading or down,
   never produces an Oracle- or Diagnostics-evidenced gray. Fit::No is allowed only when both types are fully
   known and every check failed. Before facts arrive, the only type-fit grays are syntax-stamped hints
   (`let x: u32 = ●`, a bool condition), and only for literal-kind mismatches. Grays that need no facts stay
   (a `static mut`, a macro defined below the dot, a crate that isn't a dependency). A false gray is a bug. A
   missing gray only loses a hint.
C7 Type-aware through the oracle (P7, D6-D8, R4, R5).
   - Every hole carries its expected type: a small label after the dot, and the menu subtitle
     `expects T  -  grayed options don't fit`, with T spelled as this file would write it.
   - Facts come from the oracle (rust-analyzer in its own process) and from a syntax layer in the core. The
     syntax layer alone is enough to edit with.
   - Oracle answers are recorded input events tagged with a revision. An answer may change labels, menus
     opened later, a `(looking up ...)` list, and highlighting. It never changes the text, the cursor, the
     mode, or a menu that is already open (menus are frozen under the thumb).
   - Text written by a pick uses only the facts present at that pick.
C8 B restores exactly (P9, R17, rust/02 "What B restores"). B undoes the step in progress and nothing else. A
   cancelled insert, refill, pick, options menu or Grab leaves the document and the cursor byte-identical, so
   exploring a menu is free. Undo/redo (O6: snapshots, Undo on LT+Down) covers completed steps. One user step,
   including its auto-use, auto-mut and generated arms, is one undo entry. Two exceptions keep their changes
   on B, each as one undo step that Undo reverts: the number keypad and the Derive checklist (rust/02 "What B
   restores"; rust/02 open question 8).
C9 Graduated structural delete (P11, R3).
   - LT+B removes the smallest meaningful unit first. A filled part becomes a hole again before its parent
     goes. It removes one parameter, one arm, one derive or one attribute at a time; an item goes together
     with its attributes and docs.
   - There is no confirmation inside the document (Undo exists). A delete that syntax shows to be invalid is
     refused, with a reason that names the step that makes it possible.
   - Confirm only what can't be taken back: deleting a file, overwriting, resetting the layout, editing outside
     the open file, discarding unsaved changes.
C10 Exact round-trip, and what you see is the file (P8, P20, D3, D5).
   - Text is the truth. Lines of fields are a projection whose fields partition each line's bytes.
   - Load then save is byte-identical, including CRLF, BOM and the final-newline state, whenever
     format-on-open (O4) is off, declined, or changes nothing (rustfmt-clean input). With O4 on, the only
     differences are rustfmt's: the status `formatted on open (N lines differ) - not saved yet` says so, and
     disk changes only at Save. Round-trip tests open with `Request::Open { format: false }`. Keeping CRLF is
     a deliberate departure from Doodle.
   - Loaded code and menu-built code have the same structure, by construction. Code that no construct
     structures is one Opaque unit: you can move, copy and delete it, never edit it.
   - The view's line breaks and gutter numbers equal the file's. Layout follows rustfmt's default style. One
     visual-only exception (features/01 inv 8): an empty body saved as `{}` (`fn main() {}`) is drawn as the
     rows `fn main() {` / `●` / `}`. Only the first row carries the saved line's gutter number, so compiler
     line numbers still match (D3.3).
C11 The HUD shows every button's current meaning (P13). Three banks (L-TRIGGER, DEFAULT, R-TRIGGER) are drawn
   from the live keymap every frame; the active bank is drawn larger; every slot shows an icon or an ASCII
   glyph. Context hints are rewritten for the user's layout, and every screen states its own controls in plain
   words. Actions that are not built yet are drawn dimmed; pressing one shows `<label>: not built yet`. On a
   screen with fixed controls (the main menu, menus, overlays), the HUD shows that screen's live controls
   and draws every other slot blank and dim (O23).
C12 No layout can lock you out (P14, features/03). Plain d-pad, A and B are fixed, and menus read only those.
   Delete, Files and Save always have exactly one button. Assigning an action that already has a button swaps
   the two slots. Talk goes only on a face button, walks only on a trigger bank. An unbound trigger + face
   button is swallowed and never falls through to the plain button (LT+B on the main menu does not quit). A
   damaged keys file is repaired on load.
C13 One press, one meaning (P15, D11). The topmost mode owns all input; a consumed press never leaks; at most
   one overlay opens per frame. A Talk press made under an overlay must be released before it can talk. While
   a clip transcribes, the editor takes no presses, and the words go to the leaf captured when recording began.
C14 Voice fills one leaf, nothing more (P16, D14). Hold Talk on a name, on string or comment text, or on a spot
   that takes a number; the mic is offered only there. Names are cased by role and snapped to names in scope,
   and numbers are parsed from speech. No voice commands, no syntax from speech, no cloud: Whisper runs locally.
C15 Nothing changes without input (P17, P18, D1, D7, D16). The core is a pure update(&mut App, Input) ->
   Outbox. Every result (files, listings, oracle answers, cargo output, transcriptions, setup progress) comes
   back as a recorded event inside a later Input. D-pad auto-repeat is synthesized as input; randomness comes
   only from Boot.seed; no HashMap iteration in anything ordered or fingerprinted. Every debug run is recorded,
   a headless replay reproduces the FNV-1a fingerprints frame by frame, and release builds contain no recorder.
C16 Persistence conventions (P19, D15). Per-user files (doodle-rs_keys.tsv, _heat.tsv, _roots.txt,
   _settings.txt) live in the per-user data dir; a `portable` file next to the exe switches to portable mode.
   The first line is `doodle-rs-<kind> 1`. Missing means defaults, silently. Unreadable or newer means
   defaults, never overwrite, report once. Unknown lines are kept. Write `<file>.tmp` next to the target, then
   rename. Stable keys are never renamed once shipped. Stores load before the trace starts. The only
   project-local file is .doodle-rs/run.txt, which has a header too.
C17 Edits stay in the open file (P12, D18). Other modules, Cargo.toml and dependencies are read-only
   knowledge. There are only three exceptions, each named and confirmed: Add crate (`cargo add`, after
   `Add serde 1.0 to Cargo.toml?   A add   B cancel`), Module (new file), and rename's separate
   `Also rename N uses in other files` entry. Never run a project's build code without trust (O10).
C18 Plain-language UI (P21). Short English that says what happened, what to do next, and which button to press.
   Reasons are lowercase with no trailing period. The labels, titles, hints and reasons in backticks in rust/02
   are exact user-facing text: use them verbatim.
C19 A cozy paper-and-pencil feel (P22, P23, features/10): warm paper, soft ink, green editable names, pulsing
   dots, hand-drawn icons with ASCII fallbacks, a pencil scribble when code is added and a paper crumple on
   file switches (optional, and muted in replays), and menu cells worn by use, with heat trails that are the
   same in every project. Not a terminal, and no stock widget toolkit.
C20 The Steam Deck is first-class (P24, D20): 1280x800, Game Mode, no keyboard, no root, no shell profile.
   Setup installs the toolchain without root, and every download is checksum-checked. The budgets in rust/01
   "Performance and memory budgets" are acceptance criteria, measured on a Deck.
C21 Pure core, thin app (P25, D1, D2). doodle-core has no I/O, clock, threads, processes, env, SDL, GL or
   semantic rust-analyzer. Clippy bans and `cargo xtask lint-deps` enforce this. Every decision can be tested
   by feeding Inputs to update() with no window.
C22 Knowledge comes from the real toolchain (P26, D9, D10). The std tables are generated by the oracle from the
   pinned rust-src and embedded. Dependency APIs come from the oracle, and problems come from cargo check. No
   hand-written API lists. Written by hand: the keyword, attribute and macro-shape tables, plus a few authored
   shortcut lists that name std items (Common traits and bounds, the Type menu's Text / Collections /
   References groups, the View and Wrap adapters, Common lints, well-known cfg names and values) and the
   crate catalog (D9). `cargo xtask gen-std --check` fails CI when a std path or method one of them names
   doesn't resolve in the generated std blob.

Default layout (features/03 F4, plus Undo from O6):
  LT held : Left IDE menu | Right Run list | Down Undo | Up free | A Edit | B Delete | X Talk (hold) | Y Docs
  no trig : d-pad move | A Select/add | B Back | X free | Y Change
  RT held : Up/Down walk prev/next | Left/Right walk out/in | A Copy | B Files | X Refactor | Y Save
  fixed   : LB Run tests | RB Run favorite | Ctrl+C Copy (keyboard)
  Every action's key, label, glyph and hint (Undo and Redo included, in Rust wording): rust/01 D11
  "ActionInfo for the Rust IDE". Keys are frozen once M0 ships.

Superseded ideas. Do NOT build these (features/00 "Superseded ideas"):
- a text caret, a free-text buffer, or an on-screen code keyboard of any shape;
- modal Navigate / Edit / Command / Dictate modes;
- an LSP-style editor: completion popups, go-to-definition as the UX, "next proc" on the bumpers. Here
  rust-analyzer is only a fact oracle behind the menus (D6);
- voice commands or speech-to-code, an always-listening mic, grammar-constrained Whisper per field, or
  transcription that blocks the screen;
- tab bars, a file-tree side panel, panels cycled with LB/RB, focus rings, a command palette. Instead: one
  editor sheet, full-screen overlays that own input, and the IDE menu;
- radial or pie menus (use square-ish grids), `_2` name suffixes on collision (the counter skips to the next
  free name; a numeric suffix is used only when all 400 names are taken), HUD tweens;
- egui, other immediate-mode toolkits or ECS frameworks; `syn` for loading (it drops comments); tree-sitter as
  the document; prettyplease (D3, D5, D13).

=== HOW MENUS REACT TO THE CODE (the heart: features/06, rust/02) ===
1. The cursor's CST location picks the menu (R1). Each construct's offers() adds its entries for that location.
2. The hole's expectation comes from the oracle's answer (ExpectSource) when there is one; otherwise from what
   the construct stamped (a parameter's type text, a let annotation, a bool condition); otherwise there is none.
3. Fit is decided per leaf. Literals fit by AcceptBits bit tests; calls, paths and methods fit by Fits answers.
   Fit is three-valued, each gray has a reason, and each gray has its kind (C5, C6).
4. Context decides what is offered or refused: names in scope (Reference), loops and labels, const/async/unsafe
   context, the edition, the crate's modules and dependencies.
5. Order: FIX (diagnostics on this part), then SUGGESTED (the canonical value, term search), then RECENTLY USED,
   then the authored root.
6. Prevention comes before repair. First, auto-use, auto-mut, unsafe auto-wrap, complete struct literals,
   trait impls and matches, and explicit iteration modes (R8-R13). Then rustc's suggestions as FIX entries.
   Then restructure entries (rust/02 "Errors the user can't type their way out of").
7. A menu's contents are frozen while it is open and recomputed for the next menu.

=== ARCHITECTURE (decided; the reasons and rejected options are in rust/01) ===
- Crates (rust/01 "Summary" and "Workspace layout" list them, with the enforced dependency DAG): a pure
  doodle-core; doodle-syntax (text, CST, projection, holes, layout engine; the only user of ra_ap_syntax);
  doodle-facts, doodle-knowledge and doodle-formats (pure data); doodle-oracle (a separate process embedding
  the pinned ra_ap_* crates); doodle-platform (SDL3), doodle-render (glow), doodle-stt, doodle-trace;
  doodle-app (bin doodle-rs); doodle-testkit (dev only); xtask.
- D1. update(&mut App, Input) -> Outbox of Requests. Every result, reads included, comes back as an Event in a
  later Input. Overlays and pages are core Modes. view::scene(&App, &ViewCfg) -> Scene is pure; doodle-render
  paints it.
- D3-D5. Text is the truth (Arc<str> + Parse + Rev + a cached projection). Constructs emit Templates that
  apply as text edits; only the enclosing layout root is re-laid out; snapshots make B and Undo cheap. Holes
  are spelled as in C3, and the arguments of table macros and structured attributes are sub-parsed (D3.9).
  Our own layout engine writes rustfmt's default style (max_width 100, O3); rustfmt itself runs on open (in
  memory, O4), on Format file, and as a check after save.
- D6-D8. The oracle is its own process, with every ra_ap_* crate pinned to one coherent version (=0.0.358 per
  rust/01). Its answers carry a revision and are recorded as events. The core prefetches, and the app has a
  150 ms settle gate (O5). While the oracle is down, menus run on syntax alone; an LSP engine is the documented
  fallback. Fit is {Yes, No{why}, Unknown}, computed from TyFacts and AcceptBits.
- D9-D10. The std tables come from `cargo xtask gen-std`, are embedded, and are drift-checked in CI.
  Diagnostics come from cargo check JSON on a mirror workspace holding the live text, debounced 0.6 s.
- D12-D19. SDL3 with positional buttons; OpenGL 3.3 via glow; an embedded DejaVu Sans Mono; whisper-cli, then
  whisper-server if spike S6 says so; persistence (C16) plus crash-recovery snapshots kept outside the project;
  a trace of the core Input per frame; Setup with a pinned, SHA-256-checked rustup-init, Zig as cc on the
  Deck, and a trust gate; one pins.toml for every pin; CI on every push (Ubuntu, Windows, Windows ARM64).
- Versions. rust/01 "Version facts" was checked on 2026-11-24. Crate versions and the ra_ap APIs move every
  week. Re-check every pin on crates.io and docs.rs at M0 and at every bump, and record the date. Never write
  a third-party API name you haven't checked against the pinned version. Mark anything unchecked **verify**.

=== OWNER DECISIONS STILL OPEN (build the default meanwhile; ask by the milestone shown) ===
O1  product name ............ doodle-rs placeholder; rename once, before the first release (first release)
O2  hand-written todo!() / _ / cfg(true) load as holes . yes; fallback todo!("●") .............. (M0)
O3  line width, new projects  100 (rustfmt default); 80 would write rustfmt.toml ................ (M1)
O4  rustfmt on open ......... on, in memory: `formatted on open (N lines differ) - not saved yet` (M3)
O5  settle gate ............. on, 150 ms, configurable; off = `checking types...` ................ (M5)
O6  undo/redo ............... yes, snapshots; Undo LT+Down; Redo bindable but unbound ............ (M3)
O7  unsaved changes ......... ask `Save changes to main.rs?  A save   X discard   B stay` ........ (M10)
O8  run output in Game Mode . external terminal if one is found, else an in-app Run output overlay (M10)
O9  per-user files .......... per-user data dir, plus portable mode ............................. (M2)
O10 trust ................... trust projects the IDE created; ask once for any other folder ...... (M7)
O11 network ................. offline-first; every online action needs its own explicit press .... (M6)
O12 out-of-file edits ....... only the three D18 exceptions, each confirmed ...................... (M6)
O13 clippy diagnostics ...... off (a setting) .................................................... (M8)
O14 oracle prewarm .......... off ................................................................ (M11)
O15 north stars ............. NS0 hello world; NS1 guessing game (rand 0.10.1); NS2 handmade-rs
                              (minifb 0.29.0), with a crossterm fallback if S5 fails .............. (M0)
O16 platforms ............... Windows x64, Linux x64 and SteamOS releases; Windows ARM64: CI build and
                              core tests only, no release artifact (the owner develops on
                              aarch64-pc-windows-msvc); no macOS ................................... (M0)
O17 pin cadence ............. bump the toolchain and ra_ap together, at most every 6 weeks ........ (M10)
O18 edition of new projects . 2024 ............................................................... (M2)
O19 refuse certain structural errors ... yes, only when syntax or project structure makes them certain (M4)
O20 assigning to a binding without mut . add mut automatically, with a status; B/Undo reverts both (M4)
O21 crate catalog ........... curated offline list (at most 150, pinned) + local registry + online lookup (M6)
O22 async in v1 ............. syntax only ........................................................ (M5)
O23 HUD on fixed-control screens  the main menu, menus and overlays show only their live controls (d-pad
                              `move`, A `select`, B `back` / `quit`; on the main menu also the IDE-menu
                              slot); every other slot blank and dim. Doodle drew the editor layout there
                              (features/00 inv 21, open question 7) ................................ (M0)
Also open, with their defaults written in those docs: rust/03 "Open questions for the roadmap" (for example,
whether the M0 demo needs a Deck, and gray picks on north-star paths failing tests from M5 on) and rust/02
"Open questions" 1-12.

=== READING PLAN ===
Each feature doc is about 100 KB. Never read one whole. Run grep -n '^##' FILE for the outline, then read one
section at a time (Read with offset/limit, or awk). The useful extracts are:
  awk '/^## Invariants/,/^## Data model/' FILE          (the rules to carry forward)
  awk '/^## Carrying this to Rust/,/^## Open questions/' FILE
Every feature doc has the same sections: Purpose; Features (each one Trigger / Behavior / Rules & edge cases /
Source); Invariants & constraints to carry forward; Data model & formats; Tests that pin this behavior;
Carrying this to Rust; Open questions & known gaps. Features are numbered § in docs 01, 02, 04, 05, 07 and 11
(the heading `### N.`, so "02 §3" is `### 3.` in features/02), and F in docs 03, 06, 08, 09 and 10 (`### FN.`).
For any feature area, read its Invariants before its features. The "Carrying this to Rust" sections were
written before rust/01-03 and are superseded wherever they differ (for example features/04 proposes `/*●*/`
comment holes, which D4 rejects, and features/00 and 10 weigh sdl2, tree-sitter, wgpu and rustfmt-on-load):
skim them only for Rust gotchas. Skim the Source bullets: they cite Odin files.

Before writing any code, read in this order:
1. docs/handoff/README.md, in full.
2. This prompt.
3. features/00-principles-and-constraints.md, in full. It is the rulebook.
4. rust/01: Summary; Version facts; Decision record D1-D8, D11, D15, D16; Workspace layout (including the DAG,
   Pins and the public interfaces); The per-frame contract; Owner decisions. Read the rest before you touch
   its area.
5. rust/03: How to use this doc; Milestones at a glance; Spike track; Milestone rules; M0; North-star
   acceptance test (reference files, NS0, Rules, Assertions); Testing strategy; Working conventions.
6. rust/02: How to read this (Notation, and Rules every menu follows, R1-R18); Hole (dot) vocabulary;
   File-scope Add menu > "Opening it, and the group tree" and "Functions"; Names > Generation.
7. The M0 row of the table below.

Per milestone. Before each one, re-read that milestone's section of rust/03, then read the rows below. A bare
doc number means a feature doc: "02 §1-3" is features/02 §1-3.
M0  features/03 F1-F6, F8, F9, F17; 02 §1-3, §7, §20; 04 §1-2, §9; 09 F1-F2, F5, F9; 10 F5, F10, F15, F16,
    F18; 11 §25 (rust/01 D1 replaces 11 §1-4).  rust/01 Version facts, D1-D5, D11-D13, D16, D17 (the
    pins.toml bullet), D19 (the ci.yml steps), Workspace layout > Pins.  rust/02 as in step 6 above.
M1  features/03 F1-F8, F12, F17-F19; 01 §5-7; 02 §1-6, §14; 10 F1-F7, F9-F11, F14-F16, F18-F20; 11 §10-17.
    rust/01 D11-D13, D16.  rust/02 R6, Part actions > HUD hints.
M2  features/09 F1-F11, F37; 08 F20-F21; 03 F15; 11 §22.  rust/01 D15.
M3  features/01 (whole, by section); 04 §2, §5, §9-22, §26, §30-32; 02 §17-20; 06 F21; 08 F1-F2, F6-F8,
    F11, F19; 07 §1, §8.  rust/01 D3-D5, D9, D15.  rust/02 Hole vocabulary; Add menu > File Setup,
    Functions, Types, Values, Modifiers and Item options; Inside impl/trait blocks > struct and enum bodies;
    The Type menu; Part actions > Items and signatures, Types, What B restores; Names.
M4  features/05 §1-4, §6-12, §15-23, §25, §29; 02 §8, §10, §12, §16; 06 F15-F16, F19-F20; 08 F9, F12-F18;
    07 §7.  rust/01 D6 (syntax layer), D8.  rust/02 Statement menu (all); Value menu > Root, Leaves,
    Reference, Pass as, Macros; Part actions > Statements, Control flow, Expressions; Errors > Layer 1.
M5  features/06 IN FULL, section by section (this is the heart); 07 §1, §6-8.  rust/01 D6-D8, spikes S1,
    S7-S9.  rust/02 R2-R7; Value menu (all, including "The gray rules in one table"); Type menu; Patterns
    (including Match arms); the Closure leaves.
M6  features/06 F15-F17, F21b; 04 §6-7, §27-29; 07 §2-6, §9-11.  rust/01 D9, D18.  rust/02 R8-R13; Use and
    modules; Traits and impls; Inside impl/trait blocks; Tests; Modifiers and Item options; Pass as;
    Methods of x; Generic parameters, Trait bounds, Where clauses, Lifetimes; Macros; Part actions > `use`
    lines, Attributes.
M7  features/01 §10-14, §17-18; 05 §28; 04 §19, §21, §31-32; 09 F4 (Open Folder); 00 P8, P12.  rust/01 D3,
    D4, D17 (trust).
M8  features/07 §12-14; 10 F13; 02 §13.  rust/01 D10.  rust/02 Errors the user can't type their way out of;
    Gray-with-fix catalogue.
M9  features/08 (F2-F10 and F19 first).  rust/01 D14.  rust/02 Names > Casing of dictated names, Rename.
M10 features/09 F12-F36; 07 §15.  rust/01 D17, D19.
M11 features/03 F10-F16; 10 F17, F21-F23; 11 §17-21; 09 F35.  rust/01 D17, D19, D20.

rust/03 cites rust/02 by draft section numbers. Find them by topic:
  §1.3-1.7  -> "Rules every menu follows" R2-R7      §1.8  -> "## Names"        §1.11 -> R10 (tail slot)
  §1.12     -> R8 (complete constructs)              §1.13 -> R11 (auto-use)    §2.2  -> Virtual dots, ItemOptions
  §3.1-3.10 -> "## File-scope Add menu" subsections in order (Opening, File Setup, Use and modules,
               Functions, Types, Traits and impls, Values, Compile-time, Tests, Modifiers and Item options)
  §3.11     -> the Add crate leaf (Use and modules)  §3.12 -> Part actions > `use` lines
  §4.1-4.5  -> "## Inside impl / trait blocks" in order
  §5.x      -> "## Statement menu (fn bodies)"; but §5.9 (generated arms) -> Patterns > Match arms
  §6.1      -> Value menu Root   §6.3 -> Gray-with-fix catalogue   §6.6 -> Pass as   §6.7 -> Methods of x
  §7        -> The Type menu     §8   -> "## Patterns"              §9.1-9.5 -> generics, bounds, where,
               lifetimes         §9.7 -> the Closure leaves         §9.8 -> Macros
  §11.4     -> Errors ... and "Labels and display" (diagnostics on holes)   §12 -> "## Deferred features"

=== HOW TO WORK ===
- Milestones in order (rust/03). A milestone is done when (a) every named exit test is green in CI, (b) the
  "Definition of done per feature" holds for everything it shipped, and (c) docs/milestones/Mn.md is
  committed. Never start the features of M(n+1) while an exit test of Mn is red. Spikes, docs and fixtures
  may run ahead. Owner-only items (a demo with a real pad, Deck checks, the O3 readability note) are listed
  as "owner pending" in the report and don't block done.
- Pushing and CI. Never push to the default branch and never open PRs unless the owner asks. Ask in your
  kickoff message whether you may push work branches; until the owner says yes, push nothing. When allowed,
  push only to `wip/<milestone>` (for example `wip/m0`) to run CI, and "green in CI" means that branch's run.
  Without permission or without a remote, "green in CI" means `cargo xtask ci-local` (fmt, clippy, lint-deps,
  nextest with the compile tests, plus trace verify and doc-check once they exist) is green on this host; the
  report then lists the Ubuntu, Windows and Windows ARM64 jobs as `not run (no push)`.
- Resume protocol. Keep docs/milestones/Mn-progress.md: the numbered steps of the milestone, each with its
  status and commit hash, updated in every commit. A new session re-reads this prompt, the latest
  *-progress.md and the latest milestone report, then continues from the first unfinished step.
- Network. If crates.io is unreachable, pin rust/01 "Version facts" as written and mark each pin **verify**,
  skip lockfile generation and the downloads of spikes S2 and S5, log it in docs/design/CHANGES.md, write
  `cargo xtask refresh-pins` (re-checks every pin and regenerates the north-star Cargo.lock files), and ask
  the owner to run it on a networked machine.
- Tests come first. Write each exit test with its feature, using rust/03's test names verbatim. Core tests
  drive update() with synthetic Inputs through doodle-testkit's Pad (press, combo, dpad_to, menu_go, dictate);
  MemExecutor services the requests (MemFs, FakeFacts or cassettes, FakeSpeech, FakeRunner); the test settles
  until quiescent. "exact" tests use real presses only, with no seams. Property tests cover the invariants
  (round trip, partition, idle identity, determinism, no false grays, no panics). Compile tests run the real
  cargo and rustfmt through doodle_testkit::compile and never skip silently; core test files never call
  std::fs, std::process or std::env themselves (the core's clippy bans apply to its tests too). No sleeps and
  no real clocks in the core; the core suite runs in under 15 s. Every bug or review finding gets a regression
  test named for the behaviour.
- A construct is done when its whole kit ships: menu leaf, template, holes, Y options, LT+B chain, gray rows
  with reasons, HUD hints, and four tests (rust/03 "A construct is done when").
- Keep a living spec of the new IDE in its own docs. docs/design/ holds living copies of rust/01-03 (made at
  M0) plus CHANGES.md, with one line per changed decision (date, decision, reason). docs/features/ is the Rust
  IDE's own behaviour spec, with the handoff's numbering and section skeleton; its 00 starts as a verbatim
  copy of the handoff's principles with a "Rust deviations" table prepended (P#, deviation, D/O ref); inline
  **Rust:** marks may follow per milestone. Write a feature's doc section in the same commit as the feature;
  `cargo xtask doc-check` (which scans docs/features/ only) enforces this from M1. Every source file starts
  with a //! header written from the user's side, with ● examples and the buttons that act on them.
- Commits: conventional subjects, `<type>(<scope>): <what the user gets>`. Types: feat, fix, test, docs, ci,
  refactor, perf, chore. Scopes are a crate or area: core, syntax, facts, knowledge, formats, oracle, menus,
  editor, keymap, hud, trace, app, platform, render, stt, setup, files, run, pins, xtask, testkit, ci,
  cassettes, north-star, milestones, docs. The body gives behaviour first, in plain sentences with exact
  button names, then technical notes, then a counts line (`Tests: N core, N syntax, N app; traces: N
  verified; compile checks: N.`). One logical change per commit; never commit with a red test. Generated files
  (std blob, cassettes, rustc JSON) change only through xtask, in their own commits. End each commit message
  with the attribution trailer your environment or the owner specifies.
- Ask the owner only real product questions: the O-list, the open questions in rust/02 and rust/03, and
  anything that changes what the user sees or bends C1-C22. Don't ask about internal names, crate internals,
  test layout, or fallbacks whose triggers rust/01 and rust/03 already define: decide, record the decision in
  docs/design/CHANGES.md, and report it. Never block: build the default and keep going. Batch your questions,
  each with the default you built and why it matters.
- Spikes S1-S13 are timeboxed. Their code lives in spikes/ and is never imported by a product crate. Each writes
  docs/spikes/Sxx.md (question, setup, numbers, verdict, decision). If one fails, take its documented fallback,
  update the living docs in the same commit, and tell the owner. Without a Deck, S4 (Steam Input) is "device
  pending" with no container run; S5, S7 and S13 may run in the sniper SDK container only on an x86-64 Linux
  host (not under emulation on the owner's ARM64 Windows machine), still marked "device pending".
- At the end of each milestone, commit docs/milestones/Mn.md and report to the owner: the demo (controller
  only; scripted if you have no pad, the live one owner pending); what was verified and how (exit tests with
  CI or ci-local status, compile checks, replayed traces, measured budgets, manual Deck checks); what was NOT
  verified, and why (device pending, owner pending, missing tool); owner decisions asked, answered or
  defaulted; spike verdicts; deviations from the references; known gaps carried forward; screenshots, always
  scripted (`--script` at M0, `--replay` from M1). Fixture traces may come from Pad::save_trace or
  `cargo xtask trace script` instead of a live session. Claim nothing you didn't run.
- When the docs are silent, follow C1-C22 and the nearest Doodle precedent in features/. Pick the smallest
  design that keeps every invariant, record it, and report it.

=== M0: WALKING SKELETON (rust/03 "M0" is authoritative; do the work in this order) ===
Goal. Prove the whole pipe end to end:
- SDL3 window and gamepad -> Input -> pure update -> Scene -> glow paint, with a HUD drawn from the live keymap;
- main menu -> New Project -> one green dot -> A -> Functions > Function -> `fn main() {}` -> RT+Y writes a
  Cargo package that `cargo run` builds;
- the workspace, CI and testkit that every later milestone builds on.
Steps (commit after each green step):
 1. Toolchain and pins. Pin Rust 1.100.0 in rust-toolchain.toml (with rustfmt, clippy, rust-src). Re-check
    rust/01 "Version facts" and "Pins (excerpt)" and pin the "pin at M0" crates exactly after checking
    crates.io. Write pins.toml. Log what you checked, with the date, in docs/design/CHANGES.md. If a pin no
    longer resolves or an API differs, take the nearest coherent version and log that too. Offline: see
    HOW TO WORK > Network.
 2. Docs scaffolding: docs/design/ (copies of rust/01-03) and CHANGES.md; docs/features/README.md and
    docs/features/00-principles-and-constraints.md (a verbatim copy with a "Rust deviations" table prepended);
    docs/milestones/ (with M0-progress.md), docs/spikes/.
 3. Workspace: all 13 crates from rust/01 "Workspace layout". doodle-syntax depends on ra_ap_syntax now; the
    oracle stays a stub binary with no ra_ap dependency until M3. Exact pins in [workspace.dependencies];
    crates/core/clippy.toml with the purity bans; #![forbid(unsafe_code)] in core, syntax, facts, knowledge and
    formats; `cargo xtask lint-deps` (DAG rules 1-7), `cargo xtask ci-local`, and the test
    core_depends_on_no_platform_crates (it lives in xtask, not in core).
 4. CI: ci.yml steps 1, 2 and 4 on ubuntu-22.04 and windows-latest, plus a Windows ARM64 build-and-core-tests
    job on `windows-11-arm` (verify the label). Every job builds SDL3 from source; rust/01 D12 and D19 list
    the system packages and tools each runner needs.
 5. North-star references, part 1: commit the NS0-NS2 src/main.rs files, ns1/NOTICE, regions.toml and the
    .gitattributes lines exactly as rust/03 specifies. Check the NS1 and NS2 sha256 values in rust/03; re-run
    rust/03's "Facts checked" (cargo new bytes, cargo add line, NS2 rustfmt/clippy-clean with its test
    passing). The Cargo.toml files, Cargo.lock files, seeds.toml and SHA256SUMS wait for step 8.
 6. Core: Button; Input with press/combo/event helpers; only the Event and Request variants M0 uses (Wrote,
    FileOp; Write, CreateDir, Status, Quit); Boot with seed (SplitMix64) and projects_dir, App, update,
    fingerprint (feeding the hand-written doodle_formats::fnv1a64); Mode::{MainMenu, Editor, Menu}; the keymap
    with the full default table above and the ActionInfo rows of rust/01 D11 (Undo and Redo included), and
    resolve (features/03 F6); the HUD model in view::scene, with unbuilt actions dimmed
    (`<label>: not built yet`) and O23's fixed-control HUD on the main menu and in menus.
 7. Main menu: title `DOODLE-RS`, subtitle `Rust IDE  -  gamepad native`, window title `doodle-rs`, no footer
    line (the HUD names the buttons). Entries New Project, Recent Projects, Open Folder, Key Layout,
    Settings. All but New Project are refused grays with the reason `not built yet`. B quits (Request::Quit).
    Every trigger + face press is swallowed there, except the IDE-menu combo (LT+Left), which shows
    `IDE menu: not built yet` until M1.
 8. New Project: Boot.projects_dir (rust/01 Boot), a project name from rust/01's project-name mapping (one
    SplitMix64 draw per New Project; adjective-animal-NNNN), and an empty src/main.rs in memory. Nothing is
    written yet. Then finish the north-star references: seeds.toml (the seed of each NS test and the name the
    real generator gives it), ns0-ns2/Cargo.toml from the template with those names, the NS1 and NS2
    Cargo.lock files generated once with the pinned toolchain, and SHA256SUMS.
 9. Document and cursor: doodle_syntax::Document over ra_ap_syntax; project() emits the module insert dots, the
    ● row of an empty block, the params dot and the ret hole (no ⊙ yet: it comes with M3's item options). An
    empty `{}` body is drawn as three rows (C10). Up/Down move between stops, Left/Right along a line; rust/03
    M0 lists the exact stops of `fn main() {}`.
10. The Add menu, titled `Add  (insertion point)`, has the nine root groups with rust/02's exact labels, in
    order. Functions lists its six leaves in order; only Function is lit, and the other five are refused grays
    with the reason `not built yet`. The other eight groups are gray with the same reason and open to the dim
    placeholder `(not built yet)`. "Not built yet" entries are always Refused (no heat).
11. Function: the first fn in a binary crate root that has no main is `fn main() {}`; later ones are
    `fn brave_otter() {}`, drawn `fn brave_otter(○)●ret {` / `●` / `}`. A on the params dot, the ret hole or
    the ● row opens a menu titled `Fill slot` (subtitle `the result type` on ret) with one dim placeholder
    `(not built yet)`. B at the Add menu root restores the document byte-identical. LT+B on `fn` or the name
    removes the item and one adjacent blank separator.
12. First save (RT+Y), each request sent after the previous one's event came back Ok: CreateDir <folder>
    (missing parents created; fails if the folder exists), CreateDir <folder>/src, Write Cargo.toml (Create;
    the exact `cargo new` bytes, edition 2024), Write src/main.rs (Create). Status after the last:
    `saved src/main.rs in <folder>`, where <folder> is the folder's name. Any failure: `SAVE FAILED: <reason>`
    (an existing folder: `SAVE FAILED: <folder> already exists`). A later RT+Y: Write src/main.rs (Replace),
    status `saved src/main.rs`.
13. Platform, render and app: an SDL3 window at 1280x800, positional gamepad buttons, keyboard stand-ins;
    d-pad repeat as a pure tick (first after 0.35 s, then every 0.07 s, none while App::repeat_suppressed()
    is passed in as true); glow batched quads, a fontdue + etagere atlas with the embedded DejaVu Sans Mono,
    the paper palette; code rows with dots, grid menus, the three-bank HUD with ASCII glyphs; the per-frame
    loop from rust/01 with a minimal executor on a worker thread; a debug-only
    `--script <file> --screenshot <png>` (one button or combo per line, then one rendered frame read back
    with glReadPixels) for the report's screenshots.
14. Testkit: Pad, press, combo, new_project, menu_go (BFS over the core's real grid navigation), dpad_to, pick,
    labels, dimmed, back_out, MemExecutor + MemFs, settling until quiescent (at most 64 frames), and
    doodle_testkit::compile (the cargo and rustfmt runs, serialized by a file lock: rust/01 D19).
15. Alongside steps 3-14: spikes S2, S3, S4 and S5. Without a Deck, S4 is "device pending" (no container
    run), and S5 runs in the sniper SDK container only on an x86-64 Linux host.
16. Close: docs/milestones/M0.md with two scripted screenshots (the main menu, and the editor after the fn
    insert), the docs/features sections for what M0 built, and the report. The live pad demo is owner pending
    unless you have a pad.

M0 exit criteria: all green (in CI, or with `cargo xtask ci-local`; see HOW TO WORK). rust/03 "M0" has the
table with what each test asserts.
  idle_frame_is_identity, same_inputs_same_fingerprint, core_depends_on_no_platform_crates,
  fnv1a64_standard_vectors, keymap_default_table_matches_features03_f4, hud_model_per_bank,
  unbuilt_action_says_not_built_yet, main_menu_items_and_dimmed_reasons,
  main_menu_b_quits_but_trigger_b_does_not, new_project_shows_one_green_dot,
  project_name_is_deterministic_from_seed, add_menu_root_has_nine_groups_in_order, first_function_is_main,
  second_function_is_brave_otter_with_params_and_ret_dots, b_at_add_menu_root_restores_byte_identical,
  lt_b_on_fn_removes_item, first_save_writes_cargo_package, projection_fields_partition_text,
  dpad_repeat_timing, ns_m0_fn_main_package_builds (cargo build and rustfmt --check pass; cargo run exits 0
  with empty stdout)
  plus: `cargo nextest run -p doodle-core` in under 15 s; clippy -D warnings; lint-deps.
  Demo (manual, owner pending if you have no pad): on Windows, and on a Deck in Game Mode if S4 is green:
  launch; the HUD shows; holding LT or RT switches banks; New Project -> A -> Functions > Function -> RT+Y;
  `cargo run` in a terminal succeeds.
Deferred from M0 (see rust/03): the "where?" page, Recent Projects, Save as, every other construct, the trace
recorder, rebinding, heat, icons, sounds, rustfmt in the app, and the unsaved-changes prompt.

=== START ===
1. Read everything under "Before writing any code".
2. Print one short message for the owner as your first output, and also write it to
   docs/milestones/M0-kickoff.md:
   - your understanding of the mission in about 10 lines;
   - your M0 plan, with anything in the docs that looks inconsistent;
   - the questions O2, O15, O16 and O23, rust/03 open question 1 (must the M0 demo run on a Deck?), and
     whether you may push `wip/<milestone>` branches to run CI, each with the default you are building.
3. Don't wait for the answers: continue in the same turn with M0 step 1.
````

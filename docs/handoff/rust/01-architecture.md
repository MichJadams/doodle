# 01 — Architecture and decisions for the Rust IDE

> **Status.** Authoritative for *mechanism*: crates, boundaries, data flow, threading, persistence, CI, budgets.
> For *behaviour* (what a menu offers, what B does), the feature docs in `../features/` and the construct
> taxonomy doc in this folder win. This doc merges three independent design proposals. Where they disagreed,
> the decision and the reason are recorded here.
>
> **Placeholders.** The product name is open (O1). `doodle-rs` is the placeholder everywhere: crate prefix
> `doodle-`, binary `doodle-rs`, per-user file prefix `doodle-rs_`, file headers `doodle-rs-<kind> 1`. Renaming
> is one search-and-replace, done before the first release, because headers and action keys are never renamed
> once shipped (P19).
>
> **Citations.** `P17` = principle 17 in `features/00`. `features/06 F15` and `features/01 §10` = sections of
> the feature docs. "inv N" = invariant N of that doc. `D7` = a decision below. `O5` = owner decision 5 at the
> end. `S1` = a spike.
>
> **Facts.** Version-sensitive claims were checked on 2026-11-24 (table at the top of the decision record).
> Anything marked **verify** must be re-checked against the version you pin. No third-party API name in this
> doc is invented: each one was either checked or is marked **verify**.

---

## Summary

**What is being built.** A gamepad-driven, projectional IDE for Rust, written in Rust, for Windows, Linux and
the Steam Deck (Game Mode, 1280x800, no keyboard). It carries Doodle's interaction model over unchanged: no
typed code (P1), visible dots at every insertion point (P3), menus chosen by location that gray rather than
hide and always say why (P6), type-aware and humble (P7), exact round-trip (P8), B restores exactly (P9), the
three-bank HUD (P13/P14), voice only into leaves (P16), deterministic and replayable (P17/P18), and a pure
core with a thin app (P25). The menus react to the Rust code underneath through rust-analyzer.

**Crates** (Cargo workspace; nothing depends on `doodle-app`):

| Crate | One job |
|---|---|
| `doodle-core` | The whole editor as a pure state machine: `update(&mut App, Input) -> Outbox`, with modes, menus, constructs, keymap, pages and the view model. It does no I/O at all. |
| `doodle-syntax` | Text plus a lossless CST (`ra_ap_syntax`), projected into lines of fields. Also hole spellings, the layout engine, highlighting and the module index. |
| `doodle-facts` | The oracle protocol and the fact types (`Fit`, `TyFacts`), and the cargo-diagnostics parser. Pure data. |
| `doodle-knowledge` | Embedded std/core/alloc tables, the keyword/attribute/macro tables, grouping and bucketing. |
| `doodle-formats` | Parse and serialize the persisted files and trace records, plus the FNV-1a hash (`doodle_formats::fnv1a64`) that `doodle_core::fingerprint` feeds. |
| `doodle-oracle` (bin) | A separate process that embeds the pinned `ra_ap_*` crates, answers queries over stdio, and runs `dump-std`. |
| `doodle-platform` | SDL3: window, GL context, gamepad, d-pad repeat, audio out and capture, clipboard. |
| `doodle-render` | OpenGL 3.3 via `glow`: one batched tinted-quad pipeline, a glyph and icon atlas. Paints the core's `Scene`. |
| `doodle-stt` | The `SpeechEngine` trait, with whisper-cli (phase 1) and whisper-server (phase 2) engines. |
| `doodle-trace` | Recorder, headless replayer and trace analysis. |
| `doodle-app` (bin `doodle-rs`) | Main loop, executor, worker threads, stores, runner, setup and updater. |
| `doodle-testkit` (dev) | `Pad` driver, `pick`/`menu_go`/`dpad_to`, the in-memory executor, fake oracle and cassettes. |
| `xtask` | `gen-std`, `trace …`, `dist`, `check-release`, `lint-deps`, `ci-local`, `doc-check`, `refresh-pins`, `ra-bump`, `deck`. |

**Key choices.**

1. **The core is pure (D1).** Every outside effect is a `Request`, and every outside result comes back as an
   `Event` inside the next frame's `Input`. Clippy bans file, clock, thread, process and env access in the core.
2. **Text is the truth (D3).** Each document is an `Arc<str>` plus an `ra_ap_syntax` parse. The editor's lines
   of fields are a pure projection whose fields partition the bytes, so round-trip and loader/menu symmetry
   hold by construction.
3. **Holes are neutral Rust tokens (D4).** Values and tails save as `todo!()`, types and patterns as `_`, cfg
   predicates as `true`, and an unfilled return type saves as nothing, so every saved file parses.
4. **A core layout engine writes rustfmt's default style for edited items (D5).** Real rustfmt formats on open,
   on "Format file", and as a check on save and in CI.
5. **The type oracle is our own process embedding rust-analyzer (D6).** It uses `ra_ap_*` pinned to the
   coherent set `=0.0.358`. A synchronous syntax layer in the core makes editing complete without it.
6. **Oracle answers are recorded input events (D7).** They are tagged with a revision and are advisory only.
   They never change text, the cursor, the mode or an open menu. Unknown never grays. A 150 ms app-side
   settle gate lets A usually open a menu that is already type-grayed.
7. **Every gray has a reason and an evidence tag (D8).** Refusals come only from certain structural evidence
   (the open file's syntax, plus edition, crate roots and the file index), never from types, borrows or
   diagnostics. Oracle-derived grays are advisory and may offer a fix.
8. **Std knowledge is embedded (D9).** It is generated by the oracle's `dump-std` over the pinned stable
   `rust-src`. Dependencies come from the oracle and are cached per crate version. The crate's own modules come
   from a syntax index.
9. **Diagnostics are `cargo check` JSON (D10)** on a mirror of the workspace with the live text,
   rust-analyzer's own diagnostics fill in while it runs, and both stay out of the fingerprint.
10. **Platform: SDL3, glow, fontdue + etagere, resvg, `process-wrap` and `trash` (D12-D14).** Speech runs
    through `whisper-cli`, then `whisper-server`.
11. **Traces record the core `Input` (D16)**, so a replay needs no GPU, disk or oracle, and CI replays the
    committed traces headless.
12. **Setup installs a pinned toolchain without root (D17)**: pinned `rustup-init` with its SHA-256, Zig as
    the C linker driver on the Deck, and a trust gate before running a project's build code. One `pins.toml`
    holds every pin.

---

## Decision record

### Version facts (checked 2026-11-24)

| Item | Fact | Consequence |
|---|---|---|
| Rust stable | `1.100.0 (0ef1bc386 2026-11-09)`; channel manifest dated 2026-11-12 | First pinned toolchain for users and for building the IDE. |
| `ra_ap_*` publishing | `ra_ap_ide`, `ra_ap_load-cargo`, `ra_ap_project_model` and `ra_ap_proc_macro_api` stop at **0.0.358** (2026-10-12). `ra_ap_hir` and `ra_ap_ide_db` are at 0.0.363. `ra_ap_syntax`, `ra_ap_vfs` and `ra_ap_base_db` are at 0.0.364. Some weekly numbers are skipped. MSRV of 0.0.358 is **1.98**. | Pin **every** `ra_ap_*` crate at `=0.0.358`, including `ra_ap_syntax` in `doodle-syntax`, so the core and the oracle parse identically. Gaps in the series are normal. |
| `ra_ap_syntax` 0.0.358 | `SourceFile::parse(text: &str, edition: Edition) -> Parse<SourceFile>`; `Parse::reparse(&self, delete: TextRange, insert: &str, edition: Edition) -> Parse<SourceFile>`; `Parse<T>` is `Clone + Send + Sync`; `Edition` is `ra_ap_syntax::Edition` | `App` stores `Parse` values (never `SyntaxNode`s) and stays `Send`. Edits can reparse incrementally. |
| `ra_ap_hir` 0.0.358 | `SemanticsImpl::{type_of_expr(&Expr) -> Option<TypeInfo>, type_of_pat, scope, scope_at_offset, resolve_method_call_as_callable, is_inside_unsafe, try_expr_returned_type}`; `TypeInfo::adjusted(self) -> Type` ("adjusted, or the original") | The expected type of a `todo!()` hole is `type_of_expr(todo-expr)?.adjusted()`. That is the same recipe rust-analyzer's term-search assist uses (D6). |
| `ra_ap_hir` `Type` / `SemanticsScope` | `could_unify_with`, `could_coerce_to`, `impls_trait`, `iterate_method_candidates*`, `fields`, `autoderef`; `process_all_names`, `visible_traits`, `can_use_trait_methods` (names checked on docs.rs at 0.0.358 and 0.0.363 during design; **verify** arguments at the pin) | Covers fit, scope and methods. There is **no public "expected type at offset"**, and `CompletionContext` is private. |
| rust-analyzer caches | No on-disk cache. Memory runs about 0.5 to 2.5 GB for small projects, driven by dependencies. | Every oracle start is cold. Isolate it in its own process with a memory cap. |
| Crates (max stable) | `sdl3` 0.22.1, `sdl2` 0.39.0, `glow` 0.18.0, `fontdue` 0.9.5, `etagere` 0.3.0, `resvg` 0.50.0, `process-wrap` 11.0.0, `postcard` 1.2.0, `ruzstd` 0.9.1, `enumset` 1.1.15, `indexmap` 2.14.2, `toml_edit` 0.25.20, `cargo_metadata` 0.23.1, `trash` 5.4.0 | Pin them exactly in `[workspace.dependencies]`. Re-check the rest (`ureq`, `sha2`, `semver`, `insta`, `proptest`, `crossbeam-channel`, `unicode-width`, `serde_json`, `zstd`) at M0. |
| rustdoc JSON for std | The `rust-docs-json` component is nightly-only, and its format version still moves | It is not on the critical path (D9). |
| Steam Linux Runtime 3.0 "sniper" | Debian 11 base, glibc 2.31 (from Valve's sniper package manifests; **verify** with `ldd --version` in the SDK image) | Linux release builds are made inside the sniper SDK. |

### D1. The core does no I/O; effects are requests, results are events

- **Decision.** `doodle-core` exposes `update(&mut App, Input) -> Outbox`. It reads no files and has no clock,
  threads, processes, environment variables or ambient randomness. Every effect is a `Request` in the
  `Outbox`. Every result (file contents, directory listings, oracle answers, cargo results, transcriptions,
  setup progress) comes back as an `Event` in a later frame's `Input.events`. This includes **reads**: unlike
  Doodle's model (features/11 §1), opening a file takes two phases, `Request::Open` in frame N and
  `Event::Opened` in frame N+1 or later. Embedded static data (the std tables) is not I/O, so the core reads it
  directly. Overlays and pages (Files grid, Run list, Settings, Setup rows, Key Layout, Recent Projects, New
  Project, the name dialog, the Docs panel) are core `Mode`s with pure state. Only drawing stays outside the
  core.
- **Enforcement.** `crates/core/clippy.toml` sets `disallowed-methods` (`std::fs::*` reads and writes,
  `std::fs::File::{open, create}`, `std::time::{Instant, SystemTime}::now`, `std::thread::spawn`,
  `std::process::Command::new`, `std::env::{var, vars}`) and `disallowed-types`
  (`std::collections::{HashMap, HashSet}`; use `BTreeMap`, `IndexMap` or sorted `Vec`s). The crates `core`,
  `syntax`, `facts`, `knowledge` and `formats` set `#![forbid(unsafe_code)]`. CI runs
  `cargo clippy --workspace --all-targets -- -D warnings`. **Verify** that clippy picks up a crate-level
  `clippy.toml` at the pinned version. If it doesn't, use `CLIPPY_CONF_DIR` in the core's CI step.
- **Why.** Doodle's model reads disk and its overlays live in app globals. That is why its `verify` needs a GPU
  window and why its trace needs 39 hook sites (features/11 open questions 7 and 15). With every effect behind
  `Request`/`Event`, a replay is a loop over a file and CI can run it. Rust's types and clippy make P25
  mechanical instead of a convention (features/11 inv 3).
- **Rejected.**
  - *Copy Doodle* (the core may read, overlays live in the app): replays then depend on a window and a
    snapshot.
  - *An oracle and formatter called synchronously inside `update`*, with blocking waits up to a budget: this
    blocks frames for up to about 120 ms, the replay depends on the exact query sequence, and the core becomes
    impure.
  - *An async core*: a frame would no longer be one deterministic step.
  - *ECS or an immediate-mode GUI framework* (bevy, egui): their frame models fight P17 and the paper look.
- **Risk.** Request plumbing sprawls (about 20 request kinds). The mitigation is that each new effect costs
  exactly one `Request` variant, one executor arm, one `MemExecutor` arm and one trace payload kind (the Rust
  form of features/11 §25). A file open gains one frame (16 ms), which is invisible.
- **Revisit** only if a press-to-photon budget fails because of the two-phase reads. In that case, add
  prefetching in the app, not reads in the core.

### D2. A workspace of single-purpose crates with an enforced dependency DAG

- **Decision.** Use the crates in the Summary, with the dependency rules in "Workspace layout". Only
  `doodle-oracle` depends on the semantic `ra_ap_*` crates. Only `doodle-syntax` depends on `ra_ap_syntax`, and
  it re-exports it as `doodle_syntax::rs` for the core's AST work. `sdl3` appears only in `doodle-platform`,
  and `glow` only in `doodle-render` (plus `doodle-app`, which glues them together). `cargo xtask lint-deps`
  reads `cargo metadata` and fails CI on any edge the DAG rules forbid (rule 7 says exactly which edges it
  checks).
- **Why.** Compile-time boundaries keep the core free of SDL and of rust-analyzer's semantics. The core builds
  and tests in seconds (an LLM developer's loop), and weekly `ra_ap` churn touches exactly two crates.
- **Rejected.**
  - *One crate with modules*: it loses the boundaries, and the `ra_ap` compile time would land on every build.
  - *A full facade over `ra_ap_syntax`* (our own node kinds for all ~100 AST types): a large cost for little
    gain, because the AST is generated from the grammar and changes rarely. Instead, the single re-export point
    keeps bumps to one `Cargo.toml` line.
- **Risk.** When `ra_ap_syntax` AST changes reach the core, a bump touches core code. The weekly bump job (D19)
  surfaces this early.

### D3. Document model: text is the truth, the CST is derived, lines of fields are a projection

- **Decision.**
  1. A document is `text: Arc<str>`, plus `parse: Parse<SourceFile>` (from `ra_ap_syntax`), a revision `Rev`
     (`u64`, monotonic), file metadata (edition, line-ending style, final newline, BOM, read-only), and a cached
     projection `lines: Arc<[Line]>`.
  2. **Projection** is a pure function from the parse to `Vec<Line>`. A `Line` is one screen row. Normally it
     covers exactly one saved line's byte range; the one exception is in item 3. The `fields` of the rows that
     belong to one saved line **partition** that line's range, so concatenating them gives the line, by
     construction (features/01 inv 1, P8). Field roles come from CST tokens and node kinds: keyword, name,
     literal, literal text, operator, punctuation, trivia, comment, attribute, opaque, or hole. A region the
     construct registry does not structure becomes one `Opaque` field, which can be moved, copied and deleted
     but not edited (P8 fallback). Examples are `macro_rules!` bodies (except the single no-argument rule form
     the `Macro (macro_rules!)` leaf builds, structured per item 9), unknown macro token trees and `asm!`.
  3. **Editor-only elements are zero-width.** These are the green insertion dots, the purple item-options dot,
     the capture dot, the optional "add another" list dots, and the `●` statement row in an empty block. They are
     `Virtual` fields with an empty range, or editor-only `Line`s with `saved_no: None`. They never reach the
     file because they have no bytes (features/01 inv 5 HARD).

     **Sanctioned visual-only split** (features/01 inv 8 allows extra screen breaks; gutter numbers count saved
     lines only). A saved line that ends in an empty body `{}` the menus fill (a code block, an item body, the
     arm list of a `match`) is drawn as three rows: the saved line up to and including `{` (it carries the
     gutter number, `saved_no: Some(n)`); the editor-only row holding the body's dot (`●` `StmtRow` in a code
     block, the green `Insert(..)` dot in an item body or arm list; empty range, `saved_no: None`,
     `part_of: None`); and a continuation row holding `}` and the rest of the saved line (`saved_no: None`,
     `part_of: Some(n)`). So `fn main() {}` shows as `fn main() {` / `●` / `}` and still saves as one line,
     and compiler line numbers match the gutter.
  4. **Edits are text edits.** A construct builder emits a `Template`: replacement text with hole spellings
     and generated names, a target range, extra edits (an auto-`use`, an auto-`mut`), and a cursor target. The
     core applies it, reparses (`Parse::reparse`, falling back to a full parse), re-lays out the enclosing
     layout root (D5), reprojects the affected lines, and maps the cursor through an offset map.
  5. **Loader/menu symmetry by construction.** Loaded text and menu-built text go through the same `project`,
     so Doodle's per-construct loader drift (features/01 inv 4-5, features/04 inv 2) cannot happen. The
     property test "build every leaf, save, reload, same fields" is still kept, because builders and the layout
     engine can disagree about spacing.
  6. **Byte-exact load and save.** The text is UTF-8 validated. A file that is not UTF-8 opens read-only, as one
     `Opaque` region. CRLF is kept in the text and rendered as one break, and the file is saved in its original
     line-ending style; this deliberately departs from Doodle (features/00 open question 14). The final-newline
     state is recorded (features/01 inv 9), and a leading BOM is kept and hidden. Load then save is
     byte-identical whenever format-on-open (O4, D5) is off, declined, or a no-op (rustfmt-clean input). With
     O4 on, the only differences are rustfmt's: the `formatted on open (N lines differ) - not saved yet` status
     announces them, and they reach disk only at Save. Round-trip tests therefore open with
     `Request::Open { format: false }`; `format_on_open_changes_memory_not_disk` (M3) covers the other mode.
  7. **The cursor is anchored** by `(offset, role, virtual kind)` in the current revision. After an edit it is
     mapped through the edit's offset map, never by line and field index.
  8. **Revision snapshots are cheap** (an `Arc<str>` plus a `Parse` clone). B-restore is a swap back to the saved
     snapshot (P9). Undo/redo (O6) is a capped list of snapshots, one per completed user step. Facts are also
     cached by text hash, so restoring old text reuses its facts at once (D7).
  9. **Macro and attribute arguments are sub-parsed.** `ra_ap_syntax` leaves the arguments of a macro call and
     of an attribute as an unparsed `TOKEN_TREE` (checked with `ra_ap_syntax =0.0.358` in review, 2026-11-24: in
     `fn f(){ let v = vec![todo!(), 1]; println!("{}", todo!()); }` only a top-level `todo!()` is a
     `MACRO_EXPR`; the inner ones are plain tokens). Without help, holes, stops and structure inside
     `println!`, `vec!`, `assert_eq!`, `#[cfg(..)]` or `#[derive(..)]` would be lost on reload. So `project`
     sub-parses:
     - the token tree of every macro in the knowledge macro table (D9; the `Call > Macro` shapes: the print,
       format and write families, `vec!` in both forms, the assert family, `matches!`, `dbg!`, `cfg!`, the
       panic family), plus `thread_local!` and the single-rule `macro_rules!` form the menus build;
     - the arguments of the attributes the editor structures: `cfg`, `derive`, `allow` / `warn` / `deny` /
       `expect` / `forbid`, `repr`, `link`, `link_name`, `deprecated`, `should_panic`, `inline`.

     Method: split the tree at depth-0 commas (and at the depth-0 `;` of `[x; n]`); parse each slice by
     wrapping it in a tiny source text (an expression slice as `fn f() { <slice>; }`, a pattern slice as
     `fn f() { let <slice>; }`) with `SourceFile::parse`, or with `ast::Expr::parse(text, edition)` /
     `hacks::parse_expr_from_str` (both reported present at 0.0.358; **verify** at the pin); parse attribute
     arguments with a small cfg/meta parser of our own; then shift every resulting range by the slice offset
     (minus the wrapper prefix). The sub-parse yields the same field roles and the same D4 hole classification,
     so a loaded `vec![todo!()]` and a menu-built one project identically. The format string of a print or
     format macro is a string leaf whose placeholders the format-string tokenizer reads. A macro outside the
     table, or a slice that fails to parse, stays one `Opaque` unit.
- **Why.** This makes round-trip exact by construction, which Doodle approximated with a line parser and
  `fixup_line`. The oracle parses the same bytes with the same parser version, so offsets agree.
  `ra_ap_syntax` keeps all trivia, recovers from errors, and has a typed AST.
- **Rejected.**
  - *Doodle-style lines-of-fields as the truth with text derived from it*: it needs a per-construct loader,
    whose gaps features/01 inv 5 lists.
  - *tree-sitter-rust*: needs a C compiler, has no typed AST, and its grammar differs from rustc in corner cases.
  - *`syn`*: drops comments and blank lines (features/00 Carrying (d)).
- **Risk.**
  - Reparse and reprojection cost on large files. The budget is ≤ 4 ms p95 at 5k lines (S2), met by
    incremental reparse and per-item reprojection.
  - Multi-line expressions (closures, `match` as a value, chains) need a construct to own a range of lines
    (features/01 Carrying (c)). The CST makes that natural.
- **Revisit** if S2 fails the byte-exact or latency exit criteria.

### D4. Hole persistence: neutral Rust tokens, so every saved file parses

- **Decision.** There is one spelling per hole kind, in `doodle_syntax::holes`, a table shared with the
  oracle:

  | Hole kind | Saved as | Loads back as a hole when the loader sees | Compiles when unfilled |
  |---|---|---|---|
  | Value (any expression position) and **tail** (a block's value) | `todo!()`, with no arguments | a bare `todo!()` macro call in expression position whose path is `todo` (or `std::todo` / `core::todo`), when the file defines no `macro_rules! todo` | Yes at coercion sites. No as an operand, receiver, `for` iterable or `?` operand, and no in const contexts (E0080). This is honest, as P4 is. |
  | Type | `_` | an `InferType` node | Yes in `let` annotations, closure parameters, turbofish and expression generics. No in item signatures (E0121; the file still parses and rustfmt keeps it). |
  | Return type | nothing (no `->`) | a fn without a `RetType` (shown as the `ret` hole) | Yes |
  | Pattern | `_` | a `WildcardPat` (drawn as `_` in pattern teal) | Yes |
  | cfg predicate | `true` | a cfg predicate that is exactly `true` | Yes (`#[cfg(true)]`; **verify** on the pinned toolchain) |
  | Optional lists (params, generics, bounds, where predicates, arguments, tuple fields, struct-literal rest, `use` group) | nothing | re-derived from the shape by the projection | n/a |
  | `●` row of an empty block | nothing (`{}`) | derived from an empty block | Yes |
  | Names, labels, lifetimes, numbers, strings | never holes: always a generated or default value (P4, P5) | — | — |
  | Trait positions (`impl ● for`, `dyn ●`, a bound) | never saved: inserting one opens its menu at once, and B removes the insertion | — | — |

  A user's bare `todo!()`, `_` or `cfg(true)` loads as a hole. The meaning is the same ("not chosen yet" /
  "anything"), and the text is unchanged on save (O2). `todo!("msg")`, `unimplemented!()` and
  `unreachable!()` stay ordinary values.
- **Display.** Value, tail and type holes draw as dots in their colour (P3 vocabulary), with the expected-type
  label. A `_` pattern draws as `_` in pattern teal with a ring, because it is already a complete wildcard that
  also accepts a refill. Row breaks come from the text, so WYSIWYG for breaks and line numbers holds (P20),
  with one visual-only exception: an empty `{}` body is split into three rows (D3.3), and only the first
  carries a gutter number. Inside a row, a dot plus its label may take more or fewer cells than its saved
  token. That is the same screen-only allowance Doodle makes for labels.
- **Inside macro and attribute arguments** the same spellings and the same loader rule apply, through the
  sub-parse of D3.9 (`vec![todo!(); todo!()]`, `println!("{}", todo!())`, `assert!(todo!())`,
  `#[cfg(true)]`, `cfg!(true)`).
- **Diagnostics and holes.**
  - An error whose primary span lies inside a hole token is shown on the hole as "not filled yet", not as a red
    line.
  - `unreachable_code` warnings caused by a `todo!()` hole are hidden.
  - E0121's machine-applicable suggestion feeds the type hole's suggestions.
- **Why.** Every saved file parses, so rustfmt, rust-analyzer and the loader always work on it. Doodle could
  not guarantee that (`x :=` and `case :` don't parse). The tokens already mean "not decided" in Rust culture:
  rust-analyzer's term search triggers on `todo!()`. Round-trip of holes is exact, which fixes features/01
  inv 5, Doodle's weakest point.
- **Rejected.**
  - *Nothing for signature types and patterns*, recovered from CST error nodes: the file stops parsing, and
    rustfmt refuses the whole file (observed with rustfmt 1.9.0 during design).
  - *`todo!("●")`*: unambiguous, but noisy in the user's code. It is kept as the fallback if O2 says no.
  - *Comment markers*: rustfmt silently drops `/*●*/` in a struct field type and a return type (observed with rustfmt 1.9.0).
  - *A sidecar holes file*: breaks "plain text only".
  - *`(todo!() as T)` at non-coercion sites*: needs the type spelled in the file and kept in sync, and can't
    spell unnameable types.
- **Risk.**
  - Users who write `todo!()` by hand see a dot. That is intended, and O2 confirms it.
  - Non-coercion holes block compilation until filled. That is honest and pinned by the compile matrix test.
- **Revisit** if S2's hole matrix shows a hole kind that doesn't round-trip, or if O2 rejects bare `todo!()`.
  In that case switch to `todo!("●")`, a one-table change.

### D5. Layout and formatting: a core layout engine, with rustfmt as the authority and the check

- **Decision.**
  - `doodle_syntax::layout` writes **rustfmt's default style** for the constructs the editor produces: 4-space
    indent, trailing commas in vertical lists, one field or variant per line, and `use` ordering as rustfmt's
    `reorder_imports`. It uses `max_width` and the `use_small_heuristics = "Default"` widths (`fn_call_width`,
    `attr_fn_like_width`, `struct_lit_width`, `struct_variant_width`, `array_width`, `chain_width`,
    `single_line_if_else_max_width`, `single_line_let_else_max_width`), which scale with `max_width`; **verify**
    the percentages against the pinned rustfmt's `Configurations.md`. It reads the stable keys of a project's
    `rustfmt.toml`, which arrive via `Event::Opened`.
  - After each edit it re-lays out **only the enclosing layout root**: the statement, or the item, or the
    contiguous `use` block. Untouched code stays byte-identical.
  - The engine is pure and deterministic, so replays don't depend on a rustfmt version.
  - rustfmt runs as a subprocess, never applied behind the user's back, in three places:
    1. **On open** (default on, O4). `Request::Open { format: true }` makes the executor return both the
       original bytes and rustfmt's output. The document starts from the formatted text, with the status
       `formatted on open (N lines differ) - not saved yet`. Disk changes only at Save. If rustfmt fails
       (missing, or it rejects the file), the original bytes load unchanged.
    2. **IDE menu > Format file.** A recorded `Event::Formatted` applies it, if the revision hasn't changed.
    3. **Check on save and in CI.** After a Save, `rustfmt --check` runs in the background. A difference shows
       the quiet status `rustfmt would reformat N lines (IDE menu > Format file)` and logs `fmt_drift` in the
       trace. CI requires every menu-built and acceptance output to pass `rustfmt --check`.
  - **Width.** Default `max_width = 100` (rustfmt's default), so existing rustfmt-clean projects open
    unchanged. The view fits `max_width` columns into the window. A project's `rustfmt.toml` wins. New projects
    get no `rustfmt.toml` unless the owner picks 80 (O3).
- **Why.** rustfmt can't be linked as a library on stable (it needs `rustc_private`). A subprocess per edit
  costs tens of milliseconds, and around 100 ms or more on large files. It then either blocks frames or
  reflows text after the press, and both break the calm "nothing moves without input" feel. Doodle also owned
  its formatter (features/01 §13). The engine only has to cover what the menus produce, because loaded code
  enters already rustfmt-formatted, by format-on-open.
- **Rejected.**
  - *rustfmt synchronously after every edit*, replacing holes with placeholders and recording the output:
    frame hitches, whole-file cost, and a replay that depends on the rustfmt binary.
  - *rustfmt only on save*: the view would not equal the file between saves (P20).
  - *`prettyplease`*: it works on `syn` trees, which drop comments.
  - *A full rustfmt clone*: unbounded work.
- **Risk.** The engine drifts from rustfmt's heuristics. For example, a 61-column chain breaks into rows and a
  57-column one does not. That matches `chain_width` 60, but other heuristics will surprise. The mitigations
  are the CI corpus check, the check-on-save notice and Format file.
- **Revisit** if S3 fails: some statement the menus can produce never matches `rustfmt --check`. The fallback
  is item-scoped rustfmt as a `Request` under the settle gate (D7). The edited item is extracted, formatted and
  spliced back, and the reflow arrives as a recorded event.

### D6. The type oracle: our own process embedding pinned rust-analyzer crates, plus a syntax layer in the core

- **Decision.**
  - **`doodle-oracle`** is a separate executable shipped next to the app. It embeds `ra_ap_ide`, `ra_ap_hir`,
    `ra_ap_ide_db`, `ra_ap_load-cargo` and `ra_ap_project_model`, all at `=0.0.358`. It speaks NDJSON over
    stdio: one `serde_json` object per line, and every message carries `v: PROTOCOL_VERSION`. The handshake is
    `Hello { v, app_build }` answered by `Ready { v, ra_version, toolchain, sysroot }`. On a mismatch the app
    stops the oracle and runs syntax-only, with a status line saying why.
  - **Lifecycle.**
    - Spawn at low priority when a project opens.
    - Load with `load_workspace_at(root, &CargoConfig, &LoadCargoConfig { load_out_dirs_from_check,
      with_proc_macro_server, prefill_caches, num_worker_threads, proc_macro_processes }, progress)`. Build
      scripts and proc macros are on only for trusted projects (D17). `prefill_caches` is off on the Deck.
      `num_worker_threads` is 2 on the Deck, else `min(4, cores/2)`.
    - Wrap the database in `AnalysisHost` and apply `SetText` changes as they arrive.
    - For each new revision, compute `FileFacts` eagerly. Answer lazy queries in arrival order, and answer
      anything below the newest revision with `Cancelled`.
    - Custom `hir` queries run on the oracle's main thread between changes. Stock `Analysis` queries (hover,
      completions, diagnostics, rename) run on snapshots on a worker.
    - The oracle reports its RSS every 5 s. Over the cap, it triggers garbage collection, then the app restarts
      it with backoff (1 s, 5 s, 30 s). Facts are Unknown meanwhile.
    - Build the oracle with `panic = "unwind"`, because salsa's cancellation unwinds (**verify** at the pin).
  - **Expected types** are computed inside the oracle.
    - Primary: find the hole's `todo!()` macro expression and take `type_of_expr(..)?.adjusted()`. Treat unit
      or never as "no expectation". A hole inside a macro's arguments (D3.9) exists as an expression only in
      the expansion: first map its tokens into the expansion with `Semantics::descend_into_macros`
      (**verify** its signature at the pin), then ask `type_of_expr`. A miss is Unknown.
    - Positional fallbacks: call or method argument, via `resolve_method_call_as_callable` / `as_callable` and
      the parameter type; a `let` annotation; return and tail positions, via the fn's return type; the other
      operand of a binary operator; a struct-literal field; a `match` arm pattern, via the scrutinee type;
      assignment, via the target type.
    - Otherwise Unknown.
    - Each answer says which rule produced it (`ExpectSource`).
  - **The syntax layer in the core** (`core::scope`) is complete enough to edit with no oracle at all. It
    covers:
    - local scopes: let, params, patterns, closures, arms, `for`, items and `use`;
    - structural positions: const context, `unsafe` block, `async` context, inside a loop and which loop kind,
      labels in scope, and the enclosing fn's declared return type as text;
    - every structural refusal (D8): an `else` already present, a duplicate `use`, `break` outside a loop, and
      so on.
    The oracle only **adds** type facts.
- **Why.**
  - Only rust-analyzer's library API offers expected types, scopes, unify/coerce checks, trait checks and
    method candidates. The LSP has no expected-type request (it is visible only through completion order).
  - A separate process isolates rust-analyzer's crashes and stack overflows, which matters because Doodle has
    no autosave. It also contains its memory (killable and capped on the Deck) and its compile time (the app
    builds fast), and it puts one recordable pipe at the determinism boundary.
- **Rejected.**
  - *`ra_ap_*` in the app process*: no crash or memory isolation, and the app's MSRV and build time would
    follow `ra_ap`.
  - *rust-analyzer over LSP as the primary oracle*: no expected types. It is kept as the documented fallback:
    a second `Engine` implementation behind the same protocol, with lower fidelity, if a pinned `ra_ap` set
    can't be built.
  - *A custom text-based oracle like Doodle's*: it would repeat Doodle's false grays (features/06 open
    questions 2 and 11) at Rust's scale. It survives only as the core's syntax layer.
- **Risk.**
  - `ra_ap` churn and stalls. Since 2026-10-12, `ide` and `load-cargo` have not been republished. The
    mitigations are the coherent pin, the weekly bump job, the protocol boundary and the LSP fallback.
  - Coverage gaps in `adjusted()` (inside macro arguments, under generic inference) degrade to Unknown, which
    is safe.
  - Proc-macro ABI: use the sysroot server of the toolchain that builds the project. **Verify** which rustup
    component ships it (S11).
  - Cold start with no disk cache: 15 to 90 s. The syntax layer and the embedded std tables keep menus
    complete meanwhile.
- **Revisit.**
  - If S1 fails (fewer than 8 of 10 hole positions answered, or a wrong answer), go to the LSP fallback plus a
    stronger syntax layer.
  - If the `ra_ap` set stays unpublished for more than 3 months and blocks a toolchain bump, switch to the LSP
    engine for new toolchains.

### D7. Determinism with an asynchronous oracle

- **Decision.**
  1. **Answers are inputs.** Oracle replies enter the core only as `Event::Oracle(..)` in `Input.events`,
     drained once per frame at frame start and recorded in the trace. A replay feeds the recorded replies and
     never starts an oracle. This applies Doodle's STT rule (features/11 §13) to every async source.
  2. **Revision tagging.** Every query and answer carries the `Rev` it was asked for. The core applies an
     answer only if its `Rev` equals the document's current revision, or if its text hash equals the current
     text's hash (restored text, D3). Stale answers are dropped deterministically, because that decision is a
     function of recorded inputs.
  3. **What an arriving answer may change** (anything else is a bug, and tests pin it):
     - (a) the type labels on dots and the `expects T` subtitle of menus opened **later**;
     - (b) the gray state of menus and menu levels opened **later**;
     - (c) a list whose entries come from the oracle (Methods of x, a dependency's items before they are
       cached), while that list is still showing its `(looking up ...)` placeholder: it fills in place, and the
       highlight stays on index 0;
     - (d) semantic highlight classes and diagnostics shading (presentation only).

     It may **never** change the document text, the cursor, the active mode, the order or presence of entries
     already visible, or the grays of a menu level that is already open (**frozen grays**: a menu stays
     stable under your thumb).
  4. **User-requested async edits** apply when they arrive, as a recorded event: Format file, rename edits,
     an `Add missing items` assist, the `cargo add` outcome. They apply only if the revision is unchanged and
     the requesting mode is still active. Otherwise they are dropped with the status
     `the code changed meanwhile - try again`.
  5. **Menu structure never waits on facts.** Grouping, bucketing, pinned sections and heat trails are pure
     functions of complete candidate lists, which come from embedded tables, the syntax index, or one whole
     oracle answer that arrives at once. Heat trails are identical across projects (P23).
  6. **Unknown never grays.** `Fit::Unknown`, `TyFacts.unknown`, a missing answer, `Cancelled`, `Failed`,
     "oracle loading" and "oracle down" all mean lit (P7, features/06 inv 1): none of them may produce a gray
     whose evidence (D8) is `Oracle` or `Diagnostics`. Before facts, the only type-fit grays are the
     syntax-stamped literal-kind hints. Grays whose evidence is `Syntax`, `Index`, `Metadata` or `Knowledge`
     need no facts and are unaffected (a `static mut`, a macro defined below the dot, a crate that isn't a
     dependency, `?` in a fn whose declared return type is `()`).
  7. **Prefetch, then gate.** The core asks for what the next press will need before it is pressed:
     - `FileFacts` on every new revision;
     - `ExpectedAt` when the cursor lands on a filled value (for a Y refill);
     - `Fits` when the menu highlight lands on a group whose leaves need oracle fit;
     - `ScopeAt` when the highlight lands on `Reference`;
     - `MembersOf` when it lands on `Methods of x`.

     Prefetching changes no visible state.

     The **settle gate** in the app (default on, `gate_ms` 150, O5) holds A, Y and LT+A, plus every press
     queued after a held one, in order. It holds them while `app.facts_pending()` is true, and releases them
     in order, one press per frame, starting in the frame where the answer is drained or the budget runs out
     (an `Input` carries edge sets, not an order). B never starts a hold; a B pressed while presses are held
     queues behind them, so each press keeps its meaning. D-pad presses that come before any held press pass
     straight through. `facts_pending()` is false while the oracle is loading or down, so the gate
     never waits on a cold oracle. The trace records the `Input` actually delivered, so the gate never makes a
     replay nondeterministic.
  8. **Carried facts.** When Y refills or LT+B empties a filled part, the new hole may use the `ExpectedAt`
     answer prefetched for that same position in the previous revision. A structural replacement doesn't
     change the position's expectation. This is the only case where facts from revision r gray a menu at
     revision r+1.
  9. **The fingerprint** includes the facts revision applied and the gray bits of the open menu, so a replay
     with different facts diverges visibly. It excludes diagnostics, oracle progress, semantic highlighting
     and run output (decorations, as in Doodle).
  10. Inside the oracle, every list is sorted and deduplicated before replying. Replay doesn't need this, but
      it keeps cassettes and caches stable.
- **Tests.**
  - **Cassettes** are content-addressed: the key is `hash(query kind, parameters, text hash of the revision)`
    and the value is the answer, so tests don't break when the order of queries changes. `REC_ORACLE=1`
    records them from the real oracle.
  - A weekly CI job re-records the cassettes and fails on drift.
  - S8: replay a recorded session 10 times, then once with the oracle binary deleted. The fingerprints must be
    identical every time.
- **Why.** P17 must hold with a live, cancellable, timing-dependent analysis. Treating answers as recorded
  input keeps the core pure. Frozen grays and the advisory-only rule mean that a late or wrong answer can only
  shade, never block or move things. The gate gets the user grays in the common case without blocking frames.
- **Rejected.**
  - *A synchronous `Oracle` with a blocking wait inside `update`, recording consumed answers in sequence*:
    frame hitches, and cassettes that are fragile to query order.
  - *Leaving facts out of the fingerprint entirely*: replays could not catch divergence in grays.
  - *Applying late grays to an open menu*: the menu would change under the thumb.
- **Risk.** Grays arrive too late for fast users. Mitigations: prefetching on cursor and highlight moves, the
  gate, and the warm-oracle budgets (≤ 150 ms p95). With the gate off (O5), menus open at once with the
  subtitle `checking types...`.

### D8. Fit and the three kinds of gray

- **Decision.**
  - `Fit { Yes, No { why }, Unknown }`. Unknown never grays.
  - The oracle returns `TyFacts` for each expectation: the type as the user's file spells it (via
    `display_source_code` in the open module), a canonical path, a category, and `AcceptBits` computed with
    real checks. `AcceptBits` says whether the type accepts an integer literal, a float literal, a string
    literal, a char, a bool, unit, a closure of arity n, `None`/`Some`, `Ok`/`Err`, an owned `String`,
    something iterable, and so on. The checks: does the literal's type `could_coerce_to` the expected type;
    `impls_trait` for `impl Trait` or generic expectations.
  - The core's literal and structural fit then becomes plain bit tests (Rust's literal rules: features/06
    (b)), unit-testable with fake facts.
  - Calls, paths, constants and methods get their fit from `Fits` answers, which use `could_coerce_to`, then
    `could_unify_with`, then `impls_trait`.
  - `Fit::No` is allowed only when the expected type and the candidate type are both fully known (no
    inference variables, no unresolved generic parameters) and every check failed.
  - **Syntax-stamped hints.** Before facts arrive, the syntax layer labels a hole whose expectation is a
    primitive keyword type written right there: `let x: u32 = ●`, a parameter `: bool`, an `if`/`while`
    condition (`bool`). Such a label may advisory-gray *literal-kind* mismatches only.
  - **Gray kinds** (the hide/gray line of P6 made uniform, answering features/00 open questions 5, 6 and 8):

    | Kind | When | Picking it | Evidence allowed |
    |---|---|---|---|
    | Hidden | can never apply to this *kind* of place, item or target (another OS or target, wrong item kind, `str` by value) | not listed | syntax, target, knowledge (plus the one exception below) |
    | Refused | certain and structural, *and* no additive one-step edit in the open file makes it valid (an `else` already present, a duplicate `use`, `break` outside a loop, `const` + `async`, a let chain in an edition-2021 crate) | nothing happens, the menu stays open, the reason line turns to the warning colour, no heat | the open file's syntax plus certain project structure: edition, crate roots and targets (metadata), the file listing (index). **Never** types, borrows or diagnostics |
    | Advisory | everything else that is gray: type fit, moved value, not `mut`, `?` in a fn returning `()`, a missing dependency | applies. If a fix exists, picking opens a two-entry menu titled `Doesn't fit here`: `Fix it: <fix>` / `Insert anyway`, and B goes back | any: syntax, index, metadata, knowledge, oracle, diagnostics, local analysis |

    This is rust/02 R3, word for word in substance; "additive" is defined there.
  - **Evidence tags.** Every `Gray` records its evidence: `Syntax`, `Index`, `Metadata`, `Knowledge`, `Oracle`
    or `Diagnostics` (local move analysis that needs `is_copy` counts as `Oracle`). D7.6 forbids `Oracle` and
    `Diagnostics` grays whenever those facts are Unknown, and the "unknown never grays" tests assert exactly
    that.
  - **The one hiding exception.** The type-conditional adapter entries of `Pass as`, `Assign to`, `Unwrap ▸`
    and `View ▸` (`*x`, `x.unwrap()`, `x.as_str()`, `Field of x ▸`, `x[●]`, ...) may be hidden by the picked
    value's *known* type category, as Doodle hid `Field of` and indexing for types without fields or indexes
    (features/06 F16-F17). Unknown shows them all; the decision is made when the menu opens and is frozen
    (D7.3). Fit inside the shown entries still grays with a reason.

  - Every gray carries a short reason. The reason of the highlighted gray cell is shown under the grid, in the
    place where Doodle shows a truncated label. A group is gray iff no leaf in it fits; placeholders never
    count (features/06 inv 3).
  - Context entries (`Else if`, `Else` at the dot after an `if` chain) appear wherever their *context* exists,
    and inside that context they gray rather than hide.
- **Why.** P6 and P7, made principled. A refusal blocks the user, so it must be certain, and only syntax and
  project structure are certain while typing. The `AcceptBits` split moves the language rules into the oracle
  (where the types are) and keeps the menu logic testable.
- **Rejected.**
  - *Oracle-derived refusals*: a stale or partial answer would block a correct choice.
  - *Doodle's mixed rule* (hide in the statement menu, gray in Y menus).
  - *Grays without reasons.*
- **Risk.** Too few grays to be useful when inference is partial. S9 measures this on a corpus (pass: zero false
  grays, and at least 30% of entries gray on dots with a known type). The "no false gray" corpus property test
  runs in CI from M5 on.

### D9. Language knowledge and the Docs panel

- **Decision.**

  | Knowledge | Source | When | Reaches the core as |
  |---|---|---|---|
  | std / core / alloc: modules, items, signatures, fields, variants, std trait impls, one-paragraph doc summaries, keyword docs | `doodle-oracle dump-std` over the **pinned stable toolchain's `rust-src`**, dropping `#[unstable]`, `#[doc(hidden)]` and non-public items; sorted and deterministic | offline, `cargo xtask gen-std`; committed as `crates/knowledge/data/std-1.100.0.postcard.zst` | embedded with `include_bytes!` (feature `embed`, on by default), decompressed with `ruzstd` (pure Rust, so the core builds with no C toolchain), indexed lazily behind `LazyLock`. The app touches it on a background thread at startup so the first menu never pays for it. |
  | The crate's own modules (Rust's "siblings") | the app's indexer runs `doodle_syntax::index` (items, visibility, signature text, first doc line) over every `.rs` file reachable through `mod` from the crate roots | on open, on save, on a Files change, on a `Cargo.toml` change; unchanged files (path, size, mtime) skipped; files over 1 MiB skipped (features/07 inv 13) | `Event::Indexed` |
  | Dependencies' public APIs | oracle `ItemsOf { krate, module }`, cached on disk at `<data>/knowledge/<crate>-<version>-<features-hash>-<oracle-build>.postcard.zst` | the first time that crate's menu is used; a cache hit is read by the app and delivered as an ordinary `Event::Oracle` answer | `Event::Oracle` |
  | Workspace shape: packages, targets, edition, features, dependency graph | `cargo metadata --format-version 1` (parsed in the app with `cargo_metadata`) | on open and on `Cargo.toml` / `Cargo.lock` changes | `Event::Metadata` |
  | Keywords, attributes, built-in macro shapes (arity, format-string argument, forms such as `vec![x; n]`) | hand-written tables in `doodle-knowledge`, the Rust analog of `BUILTIN_PROCS` | compile time | embedded |
  | Authored shortcut lists that name std items: Common traits and Common bounds, the Type menu's Text / Collections / References groups, the View ▸ and Wrap ▸ adapters, Common lints, well-known cfg names and values | hand-written in `doodle-knowledge`, each entry a canonical std path or method | compile time; `cargo xtask gen-std --check` fails CI when any named path or method doesn't resolve in the generated std blob | embedded |
  | Crates to add | an embedded curated catalog (≤ 150 crates, by category, one line each, pinned versions), plus crates already in the local registry cache, plus a dictated name looked up in the crates.io sparse index when the network is allowed (O11). The weekly CI job checks that every catalog version still exists in the sparse index. | at menu open | embedded / `Event::Registry` |
  | Docs panel (LT+Y) | oracle `Hover` (Markdown). Before the oracle is ready: the std summary from the tables, or the item's own doc comment from the CST. | on LT+Y | `Event::Oracle`, or synchronous |

  - A project whose active toolchain differs from the pinned one still gets the pinned std tables. Its Setup
    row offers `Generate tables for <version>` (runs `dump-std` into `<data>/knowledge/`, about a minute).
    Mismatch only affects completeness, never correctness, because of D7.6.
  - CI regenerates the std blob and fails on `git diff --exit-code`, which fixes features/11 open question 8.
- **Why.** Menu structure must not depend on oracle timing (D7.5). Without embedded tables, std menus would be
  empty for 15 to 90 s on every cold start. Generating the tables with the same engine that answers at runtime
  removes Doodle's "generator mirrors the runtime by comment only" problem (features/07 inv 4), and it works on
  stable.
- **Rejected.**
  - *rustdoc JSON for std*: nightly-only and an unstable format.
  - *Oracle only*: timing-dependent menus.
  - *Hand-written lists*: violates P26.
- **Risk.** `dump-std` can't read stability attributes through `hir`. Fallback: read `#[stable]` /
  `#[unstable]` from the item's CST attributes, which `rust-src` contains. Blob size: the budget is ≤ 10 MB
  compressed (S2 measures it).

### D10. Diagnostics

- **Decision.**
  - **The authority is `cargo check --message-format=json --all-targets` on a mirror workspace**,
    `<data>/check/<project-hash>/src-mirror`. The mirror is synced incrementally by size and mtime, excludes
    `target/` and `.git`, and has the open file overwritten with the live text (the user's files are never
    written implicitly, P12).
  - It uses a persistent `CARGO_TARGET_DIR` at `<data>/check/<project-hash>/target`.
  - The core emits `Request::Check { rev, text }` on every edit. The app debounces it (0.6 s of quiet, as in
    Doodle, features/07 §14), runs one check at a time, and kills the process tree of a stale run when newer
    text is waiting. On the Deck it uses `-j 2`, at nice priority.
  - `doodle_facts::diag::parse_cargo_messages` is pure. It keeps `"reason": "compiler-message"` records whose
    primary span is in the open file, with byte spans, level, code, children and
    `suggested_replacement`/`suggestion_applicability`. It is pinned by captured JSON fixtures.
  - The core maps byte spans straight onto fields. Errors are red, warnings amber, and hole-caused
    diagnostics are filtered (D4). Diagnostics are shown only while the text hash equals the checked hash
    (features/07 inv 15).
  - Machine-applicable and maybe-incorrect suggestions become a `Fix` group at the top of Y's menu on that
    part. A suggestion is applied only if the revision still matches.
  - **Fast hints**: the oracle's `Diagnostics` query (rust-analyzer's native diagnostics) for the current
    revision, shown while cargo runs. rust-analyzer has no borrow-check diagnostics, so borrow errors come only
    from cargo, and arrive after type errors are fixed.
  - Clippy is a setting, default off (O13), in the same pipeline.
  - Diagnostics are recorded events but stay out of the fingerprint (shading only). Menus that include a Fix
    group are fingerprinted through their entry count.
- **Why.** `cargo check` is the only source of borrow and lifetime errors. A mirror keeps the user's files
  untouched and the user's `target/` lock free.
- **Rejected.**
  - *Autosave plus checking the real project*: it writes files without an explicit Save.
  - *rust-analyzer flycheck*: it checks saved files only.
- **Risk.**
  - Mirror correctness: build scripts with absolute paths, `include_str!` outside the package, path
    dependencies outside the workspace. Mitigation: mirror the whole workspace root, reference outside path
    dependencies in place, and when a check fails for mirror reasons, fall back to rust-analyzer diagnostics
    and say so once.
  - Disk use. Settings > Storage shows sizes and offers `Clear check caches`.
  - Whether the check target dir can be shared with the oracle's build-script runs without rebuild thrash
    (**verify**; if not, use separate dirs).

### D11. Input, keymap, Talk and overlays live in the core

- **Decision.**
  - `Input` is edges plus levels plus events (signature in "Workspace layout"):
    - `pressed`, `released`, `held`, as `EnumSet<Button>` over `A B X Y Up Down Left Right Lb Rb KeyCopy`;
    - `repeat`, the subset of `pressed` synthesized by auto-repeat;
    - `lt_held` and `rt_held` (trigger above 0.5, or the keyboard stand-in);
    - `typed`, read only by the name dialog (P1);
    - `events`.
  - The keymap, banks, lock-out rules, the HUD model and the rebinding of hints are features/03 F3 to F7, F9
    and F18, unchanged.
  - LB and RB (Run tests, Run favorite) and Ctrl+C are core logic, so P15 is one place.
  - **Talk is handled in the core.** A resolved Talk press on a dictatable target emits
    `Request::Talk(Start { clip, mode, prompt })`. The core builds `prompt` from the vocabulary (names in scope
    plus the short Rust word list, D14), sorted and capped, so it is deterministic
    (`vocabulary_prompt_from_scope_is_deterministic`). D-pad Down while held emits `Split`, and release emits
    `Stop`. `Event::Heard` applies the text to the target captured at Start. While a clip is transcribing, the
    editor takes no presses (features/08 F8). `App::repeat_suppressed()` is true while the editor is
    `Talking` or `Transcribing`; the app passes it to `Platform::pump` so no d-pad repeat is synthesized then
    (features/03 F2: Doodle's `dpad_no_repeat = g_recording`).
  - The topmost `Mode` owns all input (P15 becomes a `match`). At most one overlay opens per frame. The
    "stale Talk press" rule (features/03 F7) is core state.
  - The window close button arrives as `Event::CloseRequested`, so the unsaved-changes rule (O7) is core
    logic.
  - **ActionInfo for the Rust IDE.** The `Action` enum is features/03 F5's order with `Undo` and `Redo`
    appended. Keys are persisted in `doodle-rs_keys.tsv` and are frozen once M0 ships (P19); labels, glyphs
    and hints are user-facing text (glyphs are ASCII 32..127; icons arrive at M11). Flags are features/03
    F5's. Hints are rewritten for the user's layout by `rebind_hint` (features/03 F18).

    | Action | key | label | glyph | default slot | hint |
    |---|---|---|---|---|---|
    | None | `none` | (nothing) | — | LT+Up, plain X | — |
    | Move up / down / left / right | `move_up` ... | Move up / down / left / right | (none) | plain d-pad | `move the cursor` |
    | Select | `select` | Select / add | `+` | plain A | `A on a dot adds code, on a hole fills it` |
    | Back | `back` | Back | `<` | plain B | `back to the main menu (and out of menus)` |
    | Edit | `edit` | Edit | `e` | LT+A | `replace the highlighted part (keypad on numbers, text tools on names)` |
    | Delete | `delete` | Delete | `x` | LT+B | `delete the highlighted part` |
    | Change | `change` | Change | `*` | Y | `change the highlighted part: another fn, refill an argument...` |
    | Docs | `docs` | Docs | `?` | LT+Y | `documentation of the highlighted part` |
    | Copy | `copy` | Copy | `C` | RT+A | `copy the statement / item (whole file on a green dot)` |
    | Save as | `save_as` | Save as | `N` | none | `save under a new name (renaming: Files > LT+X)` |
    | Run list | `run_list` | Run list | `>` | LT+Right | `pick a command to run` |
    | Files | `files` | Files | `F` | RT+B | `browse the project's files` |
    | Run favorite | `run_favorite` | Run favorite | `R` | none (RB) | `save, then run the favorite command (RB too)` |
    | Run tests | `run_tests` | Run tests | `T` | none (LB) | `save, then run cargo test (LB too)` |
    | Talk | `talk` | Talk | `m` | LT+X | `hold to dictate into the highlighted name / string / number` |
    | IDE menu | `ide_menu` | IDE menu | `=` | LT+Left | `format file, key layout, exit` |
    | Walk: previous / next / in / out | `walk_prev` ... | Walk: previous / next / in / out | `^` `v` `}` `{` | RT+Up / Down / Right / Left | features/03 F5's hints, unchanged |
    | Format file | `format_file` | Format file | `~` | none | `format the file with rustfmt` |
    | Previous file | `prev_file` | Previous file | `P` | none | `switch back to the file you had before` |
    | Key layout | `key_layout` | Key layout | `K` | none | `open this page` |
    | Refactor | `grab` | Refactor | `G` | RT+X | `Refactor menu: Grab (move the highlighted statement / item) or Copy line (move a copy); press again to drop, B puts it back` |
    | Save | `save` | Save | `S` | RT+Y | `save the file (a new project: Cargo.toml and src/main.rs in its folder)` |
    | Undo | `undo` | Undo | `U` | LT+Down (O6) | `undo the last change (B only cancels the step in progress)` |
    | Redo | `redo` | Redo | `O` | none | `redo what Undo took back` |

    `keymap_default_table_matches_features03_f4` asserts this table's slots (features/03 F4 plus Undo).
- **Why.** Doodle splits these between model and app globals (`g_talk_stale`, `g_stt_busy`), and features/11
  open question 16 shows the fingerprint missing them. In the core they are fingerprinted and testable.
- **Rejected.** Doodle's ten-bool `Copy` `Input`. It can't express held Talk, LB/RB or async results. Test
  helpers (`Input::press(A)`, `Input::combo(Lt, B)`) keep tests as terse.

### D12. Platform: SDL3 for window, gamepad, audio and clipboard

- **Decision.**
  - Use `sdl3` 0.22.1, contained entirely in `doodle-platform`. Every OS builds SDL3 from source, so no CI
    runner or user needs an SDL3 package: on Windows statically linked (feature `build-from-source-static`),
    on Linux and SteamOS `build-from-source` with the built `libSDL3.so.0` bundled next to the binary and rpath
    `$ORIGIN`. The features `build-from-source`, `build-from-source-static` and `static-link` exist in sdl3
    0.22.1 (docs.rs, 2026-11-24); **verify** what each one implies at the pin. Building SDL3 needs CMake and
    a C toolchain everywhere, plus the X11, Wayland, GL, audio and udev development headers on Linux (D19
    lists the CI packages).
  - The **Gamepad API** with positional buttons: SOUTH = A (confirm), EAST = B (back). Triggers are normalized
    to 0..1 and held above 0.5.
  - Hot-plug: on removal, release all held state and open the next pad (fixes features/03 open questions).
  - D-pad auto-repeat is synthesized in `platform` by a pure tick (0.35 s delay, then every 0.07 s) and marked
    in `Input.repeat`. `doodle-platform` knows no doodle types, so the app passes
    `app.repeat_suppressed()` (D11; true while Talk is held or a clip transcribes) into `pump`, and the tick
    synthesizes nothing while it is true.
  - Keyboard stand-ins as in Doodle (features/03 F17).
  - Audio out: an SDL3 audio stream with an 8-voice mixer (pencil and paper sounds, features/10 F22).
  - Audio capture: an SDL3 recording stream, 16 kHz mono.
  - Clipboard: SDL3.
  - UI scale: the window's pixel density.
  - Launch on the Deck as a non-Steam game, so Steam Input provides the pad. The back buttons stay unused.
- **Why.** SDL is what Steam Input is built around: the same controller database and the device-ignore
  environment Steam sets. Doodle already bundles SDL3 for the runtime's sdl2-compat (features/11 §20).
  Positional buttons keep A = confirm on every pad.
- **Rejected.**
  - *`sdl2` 0.39*: mature, but SDL2 is legacy. It is kept as the fallback behind the same `platform` API if
    `sdl3`'s pre-1.0 churn bites.
  - *`winit` + `gilrs` + `cpal` + `arboard`*: four dependencies, and `gilrs` sees evdev directly, which risks
    duplicate devices under Steam Input.
- **Risk.** Steam Input mapping in Game Mode, and whether SDL raises the on-screen keyboard on text-input start.
  S4 checks both on the device.

### D13. Rendering and text

- **Decision.**
  - **The core builds the view model.** `doodle_core::view::scene(&App, &ViewCfg) -> Scene` is pure data:
    code rows as styled spans in cell coordinates, dots with kind, colour and label, the cursor, the menu grid
    (labels, gray kind, heat wear, sections, breadcrumb, `n / N`), the HUD banks (action id, glyph, icon id,
    active bank, Talk glow), banners and the hint line. `pub struct ViewCfg { pub px: (u32, u32), pub scale:
    f32, pub code_cols: u16 }` (window size in pixels, UI scale, columns the code area fits, `max_width` by
    default). Code rows use cell coordinates; the HUD, menu boxes and banners use logical-pixel rects computed
    from `ViewCfg`, so `Scene` snapshots at 1280x800 pin geometry without pixels.
  - **The HUD on fixed-control screens** (O23). On the main menu, in menus and in overlays with fixed
    controls, the HUD shows only that screen's live controls: d-pad `move`, A `select`, B `back` (`quit` on
    the main menu), and on the main menu also the IDE-menu slot. Every other slot is drawn blank and dim. In
    the editor the HUD is the live keymap (features/03 F9).
  - **`doodle-render` paints it** with OpenGL 3.3 core via `glow` 0.18: one tinted-quad shader, batched, with
    one atlas for the code font, the UI font and icons, and a scissor rect for the code area.
  - Text uses `fontdue` 0.9.5 rasterizing on demand into an `etagere` shelf atlas, with `unicode-width` for
    column math.
  - The bundled DejaVu Sans Mono is embedded with `include_bytes!`, so "no font" can't happen. A user override
    `assets/fonts/mono.ttf` is supported, missing glyphs use a fallback chain and then a tofu box, and the
    atlas is not ASCII-only (fixes features/10 inv 8).
  - Icons are SVGs rasterized at exact size by `resvg` into the atlas as alpha masks and tinted, with an ASCII
    glyph fallback for every action.
  - Layout of a Scene into pixels takes a `Measure` trait, so it is testable with a fake monospace measurer.
  - Animation (pulses, glows) is a function of render time only, never of `App`.
  - Idle: redraw at ≤ 30 fps while something pulses, then stop pulsing after 10 s without input.
- **Why.** This is the smallest port of Doodle's renderer (features/10 F2). The Scene split makes the HUD and
  menus testable as data (`hud_model_per_bank`), and it keeps `render` free of editor logic.
- **Rejected.**
  - *`wgpu`*: shader compilation, startup time and binary size for nothing this UI needs.
  - *egui*: it fights the paper look and P17.
  - *`cosmic-text`*: shaping isn't needed on a monospace grid. It is the upgrade path if complex scripts in
    strings matter.

### D14. Speech-to-text

- **Decision.**
  - A `SpeechEngine` trait in `doodle-stt`, called on the app's speech worker thread with 16 kHz mono f32
    segments.
  - **Phase 1:** a `whisper-cli` subprocess per segment. This is Doodle's proven path and release artifact
    (features/08 F3, F4).
  - **Phase 2:** a `whisper-server` child holding the model warm, receiving `POST /inference` on `127.0.0.1`.
    It starts on the first Talk and stops after 10 minutes idle. S6 decides the switch.
  - The vocabulary and prompt are built in the core from the oracle's names in scope plus a short Rust word
    list (features/08 (d)).
  - Segments are joined per mode, and `Event::Heard` carries the result (recorded).
  - Dialogs use the same async path, showing `transcribing...`.
- **Why.** Crash isolation keeps native code out of the editor process, and it reuses Doodle's CI-checked
  builds (no AVX-512, a real transcription test).
- **Rejected.** *`whisper-rs` in process*: cmake, bindgen and the C++ runtime in our build, and a native crash
  in our process. It is reconsidered only if both subprocess engines miss the dictation budget.

### D15. Persistence files and crash recovery

- **Decision.**
  - The rules of features/00 P19 and features/11 §22 are unchanged:
    - a pure `parse`/`serialize`/`text_ok` per file in `doodle-formats`, and a thin store in `doodle-app`;
    - a versioned header, `doodle-rs-<kind> 1`;
    - missing means defaults;
    - an unreadable file, or one with a newer header, means defaults plus `nosave` (never overwritten), reported
      once;
    - unknown lines kept;
    - write `<file>.tmp` next to the target, then `std::fs::rename`;
    - retry a failed read once after 50 ms;
    - heat saves at most every 2 s and at quit, merged with the file;
    - stores load **before** the trace starts, so a replay can pin them.
  - **Files:**
    - `doodle-rs_keys.tsv`, `doodle-rs_heat.tsv` (keys are canonical item paths and construct ids),
      `doodle-rs_roots.txt` and `doodle-rs_settings.txt`;
    - `<project>/.doodle-rs/run.txt` with header `doodle-rs-run 1` (fixes features/00 open question 13).
  - **Location** (O9): the per-user data dir: `%LOCALAPPDATA%\doodle-rs\` on Windows, and
    `$XDG_DATA_HOME/doodle-rs/` (else `~/.local/share/doodle-rs/`) on Linux and the Deck. A file named
    `portable` next to the executable switches to Doodle's next-to-the-exe behaviour. The data dir also holds
    `rust/` (Setup's toolchain), `zig/`, `bin/`, `knowledge/`, `check/`, `traces/`, `recovered/` and `logs/`.
  - **Crash recovery** (new; Doodle has no autosave):
    - The app keeps the last good `Arc<str>` of every dirty document.
    - A panic hook writes them to `<data>/recovered/<stamp>/`.
    - While a document is dirty, the app also writes a recovery snapshot every 5 s. This covers hard kills and
      OOM.
    - On the next start, `Event::Recovered` offers `Restore unsaved work from 14:32?  A restore   B discard`.
    - Recovery never writes into the project.
- **Why.** These are the same safety rules. One folder holds everything the IDE owns, it survives reinstalls
  and self-updates with no `KEEP_FILES` copying, and it works with a read-only install folder.
- **Rejected.** *Files next to the exe as the default*: it breaks read-only installs and needs copy-on-update.

### D16. Trace and replay

- **Decision.**
  - **Record the core `Input` per frame**, events included, at the core boundary. Raw device events are kept
    for analysis only.
  - The folder is `<data>/traces/<YYYYMMDD-HHMMSSZ>[-k]/`, holding:
    - `input.log`: text, the replay source;
    - `answers.jsonl.zst`: large event payloads (oracle answers, metadata, file blobs), zstd-streamed,
      deduplicated, flushed per frame;
    - `events.jsonl`: Doodle's analysis records `act`/`list`/`mark`;
    - `snapshot/`: for takeover only, with Doodle's hard-link, budget and placeholder rules, skipping
      `target/`.
  - Keep the newest 40.
  - `input.log` grammar:

    ```
    doodle-rs-trace 1
    meta <key> <one-token value>          # start_unix build toolchain ra_version protocol keymap roots settings seed ...
    <frame> t <seconds>
    <frame> pad <pressed-hex> <released-hex> <held-hex> <repeat-hex> <lt 0|1> <rt 0|1>
    <frame> typed <one-token text>
    <frame> ev <kind> <one-token small payload | @<seq> for a payload in answers.jsonl.zst>
    <frame> raw <device event>            # analysis only, never replayed
    <frame> fp <16 hex>                   # FNV-1a 64 after the frame
    end <frame>
    ```

    One-token escaping is Doodle's (features/11 data model).
  - **Fingerprint**: a hand-written FNV-1a 64 exactly as Doodle's (offset `0xcbf29ce484222325`, prime
    `0x100000001b3`, `0xff` after each string, integers as 8 little-endian bytes), never `DefaultHasher` or
    `#[derive(Hash)]`. The hash is `doodle_formats::fnv1a64` (its test `fnv1a64_standard_vectors` lives in
    formats); `doodle_core::fingerprint(&App)` walks the state and feeds it. It hashes:
    - document text and revision;
    - the mode stack with per-mode state;
    - the menu stack (title, index, count, gray bits);
    - the cursor, the keymap, the name counter and the facts revision;
    - page states.

    A new mode mixes in its state only while it is active, behind a distinct tag (features/11 §12).
  - **Replay modes:**
    1. **Headless** (`doodle-trace`, `cargo xtask trace verify`, CI): build an `App` from the recorded `Boot`,
       feed each frame's `Input`, compare fingerprints. No window, GPU, disk, oracle or speech. Committed
       fixtures in `tests/traces/` run on every push (fixes features/11 open question 7).
    2. **Visual** (debug app `--replay <trace> [--until F] [--speed X] [--takeover] [--exit-at-end]
       [--screenshot F]`): the same feed, rendered, through the **replay executor**. It writes nothing outside
       the sandbox and runs no programs, clipboard, sound, installs or trash. That is one implementation, not
       guarded hook sites.
    3. **Takeover**: materialize `_replay/` from the snapshot, start a real oracle on it, switch to the real
       executor with writes fenced to the sandbox, and start a derived recording.
  - **Release exclusion.** `#[cfg(any(debug_assertions, feature = "trace"))] mod trace_on;`, plus a
    `trace_off` stub module with identical `#[inline(always)]` fns. `cargo xtask check-release` fails if a
    `--release` binary contains `doodle-rs-trace 1`. So the header literal exists only in doodle-trace's
    writer, behind the same cfg; the `doodle-formats` parsers take the expected header as a parameter and never
    spell it. A runtime `DOODLE_RS_TRACE=0` skips recording.
  - **Analysis.** `cargo xtask trace list|report|find|show|script` is a port of `tools/trace.py`, sharing record
    structs through `doodle-formats`. Its bindings table is generated from `ActionInfo` (fixes features/11 open
    question 5).
- **Why.** Async results become ordinary recorded inputs, the replayer is a loop, and CI can run it.
- **Rejected.** *Recording device events and re-running the app layer* (Doodle): it needs a window, and every
  async source would need its own hook.
- **Risk.** Trace size, dominated by oracle payloads. The budget is ≤ 20 MB per hour with zstd and dedupe;
  measure it.

### D17. Toolchain setup, trust and self-update

- **Decision.**
  - **`pins.toml`** is the single source for:
    - the user toolchain (`1.100.0`), the `ra_ap` N (`0.0.358`) and the oracle protocol version;
    - the `rustup-init` version and SHA-256 per triple;
    - the Zig version and SHA-256 per triple;
    - the whisper.cpp tag, the model name and its SHA-256.

    `app/build.rs` embeds it, and `xtask` and the CI workflows read it. There are no duplicated pins with
    "keep in step" comments (features/11 open question 8).
  - **Setup rows** (Settings > Setup, features/09 F30-F35, pure row state in `core::pages::setup`):
    - **Rust toolchain**
      - Detect, in order: `$DOODLE_RS_CARGO_HOME` / `$CARGO_HOME` + `$RUSTUP_HOME`; `<data>/rust`;
        `~/.cargo/bin`; then `PATH`. Game Mode reads no shell profile (features/09 F29).
      - Install: download the pinned `rustup-init` from
        `https://static.rust-lang.org/rustup/archive/<version>/<triple>/rustup-init[.exe]`, check the pinned
        SHA-256, then run it with `-y --no-modify-path --profile minimal --default-toolchain <pinned> -c
        rust-src -c rust-analyzer -c rustfmt -c clippy`, with `RUSTUP_HOME`/`CARGO_HOME` under `<data>/rust`.
        No root and no profile edits.
      - Every cargo, rustfmt, check, run and oracle start gets those variables and `PATH` explicitly.
    - **C linker on Windows**: `vswhere`, then the MSVC Build Tools (unchanged from features/09 F32).
    - **C linker on the Deck / Linux without `cc`**: install the pinned Zig and write `<data>/bin/cc` and `ar`
      wrappers that filter flags (`cargo-zigbuild`'s wrappers are the reference). Runs and checks get
      `CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER`, `CC` and `AR`.
    - **Oracle**: status, memory, `Restart`.
    - **Speech-to-text**: as Doodle.
    - **`doodle-rs` self-update**.
  - **Toolchain choice per project.** The IDE runs cargo through rustup proxies. A project's own
    `rust-toolchain.toml` is respected. Otherwise the pinned toolchain is used, via `RUSTUP_TOOLCHAIN`. New
    projects get no `rust-toolchain.toml`. Proc macros use the sysroot server of the project's toolchain, so
    the ABI matches.
  - **Trust gate** (O10). Projects the IDE created are trusted. The first time any other folder is opened, ask
    `This project runs its own build code when checked. Trust it?  A trust   B browse only`. Browse-only
    means:
    - the oracle loads with `load_out_dirs_from_check: false` and `ProcMacroServerChoice::None`;
    - no `cargo check` and no Run;
    - menus still work, and the affected facts are Unknown.

    The answer is stored per folder in settings.
  - **Self-update** (features/09 F35, hardened):
    - GitHub releases API; refuse a release without a SHA-256 `digest`; compare versions with `semver`.
    - Linux: swap the whole install folder by rename.
    - Windows: a staged script waits for the PID, then replaces **every** executable (`doodle-rs`,
      `doodle-oracle`, `whisper-*`) and the assets together. The app stops its children first.
    - The oracle handshake checks an exact build id, so a partial update degrades to syntax-only instead of
      misbehaving.
  - **Child processes**: all through `process-wrap` (11.0.0; **verify** its API names), with a Windows job
    object (kill on close) or a Unix process group with a parent-death signal. The oracle, whisper-server,
    cargo and rustc never outlive the IDE. That pin is very fresh: 10.0.2 and 11.0.0 were both published on
    2026-11-24, after 8.2.2 on 2026-09-23. At M0, read the newest version's docs; the app needs only spawn,
    kill-tree-on-drop (job object / process group) and wait. If the API churned, pin the newest 10.x or 11.x
    that documents those wrappers, or write a small `std::process` plus job-object fallback behind
    `app::runner`.
  - Argument vectors only; no shell strings.
- **Why.** This is the same Deck story as Doodle (no root, no profile, checksums, features/09 F29-F36) with its
  gaps closed: the pinned `archive/` URL, a refusal when the digest is missing, semver comparison, and the
  trust gate. Opening a downloaded project must not silently run its code (Doodle never executed anything on
  open).
- **Risk.**
  - Zig as Rust's linker driver on SteamOS (S5).
  - `-sys` crates that need system dev headers on a read-only root. The north star has a fallback crate (O15).
  - Which rustup component ships the proc-macro server (S11).

### D18. Edits outside the open file are named, confirmed exceptions to P12

- **Decision.** Code edits stay in the open file. Three explicit exceptions exist, each behind a confirmation
  that names the file:
  1. **Add dependency** runs `cargo add [--offline] <name>[@version] [--dev]` as a request, after
     `Add serde 1.0 to Cargo.toml?   A add   B cancel`. It then refreshes the metadata and the oracle.
  2. **New module file** creates `<name>.rs` where rustc expects it and inserts `mod <name>;` in the open file.
  3. **Rename** applies the open file's uses by default. A separate entry,
     `Also rename N uses in other files (a.rs, b.rs)`, applies the rest; the edit list comes from the oracle's
     `Rename`.

  Sibling modules are otherwise read-only knowledge (features/07 §9-11).
- **Why.** Rust needs a manifest entry before `use` can reach a crate, and a module needs a file. P12's intent is
  "nothing changes off-screen silently", and these exceptions keep it.
- **Rejected.** *A strict P12* (no `Cargo.toml` edits): then dependencies need a text editor, which violates P2.

### D19. CI and packaging

- **Decision.**
  - **`ci.yml`** runs on every push and PR. It is new; Doodle has none (features/11 open question 1). Matrix:
    `ubuntu-22.04`, `windows-latest`, and a Windows ARM64 job on the GitHub-hosted label `windows-11-arm`
    that builds and runs the core tests (the owner develops on `aarch64-pc-windows-msvc`; O16). GitHub's
    hosted-runner reference lists that label (and `windows-11-vs2026-arm`) for private repositories too as of
    2026; **verify** the label at M0. Runner setup, because SDL3 is built from source (D12):
    - Ubuntu: `apt-get install cmake ninja-build libx11-dev libxext-dev libxrandr-dev libxcursor-dev
      libxi-dev libxss-dev libxkbcommon-dev libwayland-dev libegl1-mesa-dev libgl1-mesa-dev libasound2-dev
      libpulse-dev libudev-dev` (**verify** the list against SDL3's `docs/README-linux.md` at the pinned
      sdl3-sys), plus minifb's system packages for the north-star compile checks;
    - Windows x64 and ARM64: CMake on the PATH (install it in a setup step if the image lacks it) and the
      MSVC tools for the job's architecture.

    Steps:
    1. `cargo fmt --check`; `cargo clippy --workspace --all-targets -- -D warnings`; `cargo xtask lint-deps`.
    2. `cargo nextest run --workspace` (core press tests, projection and round-trip property tests over a
       vendored corpus, layout tests, persistence tests, the testkit acceptance suite on oracle cassettes).
       Timing gate: the `doodle-core` tests finish in < 15 s.
    3. `cargo xtask trace verify tests/traces`.
    4. **Compile checks of acceptance outputs**: every north-star program built by controller-equivalent input
       is written to a temp crate and run through `cargo check`, `cargo test` and `rustfmt --check`, all through
       `doodle_testkit::compile`. They share one `CARGO_TARGET_DIR` and are serialized by an exclusive
       `std::fs::File::lock` (stable since Rust 1.89) on `<CARGO_TARGET_DIR>/doodle-compile.lock`, held for
       each cargo or rustfmt run. A `static Mutex` would serialize nothing: nextest runs every test in its own
       process. A nextest test group (`[test-groups] compile = { max-threads = 1 }` with a
       `[[profile.default.overrides]]` filter in `.config/nextest.toml`) may be added to save CPU, but the lock
       is what makes it correct (fixes features/11 open question 3).
       - `cargo xtask ci-local` runs steps 1-4 (and doc-check once it exists) on the developer's host. It is
         what "green in CI" means when nothing can be pushed (PROMPT "HOW TO WORK").
    5. Oracle integration: the real `doodle-oracle` against fixture crates (`rustup component add rust-src`
       first). It runs the conformance suite (about 100 golden queries) and re-records the cassettes; a diff
       fails the job.
    6. `cargo xtask gen-std --check` (Linux only).
    7. `cargo xtask check-release`.

    Use dependency caching (the `ra_ap` tree is large). Set `[profile.dev.package."*"] opt-level = 2`, because
    an unoptimized rust-analyzer is too slow to use.
  - **`ra-bump.yml`**, weekly: find the newest N published for **every** `ra_ap_*` crate in use, bump, run the
    oracle tests and cassettes, and open a PR when green.
  - **`release.yml`**, manual, Doodle's matrix (features/11 §20):
    - `steamos` in `registry.gitlab.steamos.cloud/steamrt/sniper/sdk:latest` (rustup installed in the
      container, bundled `libSDL3.so.0`, `-C link-arg=-Wl,-rpath,$ORIGIN`, never `target-cpu=native`, at most
      `x86-64-v3`);
    - `linux` on `ubuntu-22.04`;
    - `windows` on `windows-latest` (`-C target-feature=+crt-static`, static SDL3, and a `dumpbin /dependents`
      check that no `vcruntime*` is needed).

    Each job runs the tests, builds `doodle-rs`, `doodle-oracle` and `whisper-cli`/`whisper-server` (pinned
    tag; the `%zmm` objdump check; a real `jfk.wav` transcription), runs `check-release` and the load-path
    checks, and packages `doodle-rs/{bin/, models/, assets/, licenses/, VERSION}`. Licenses are collected with
    `cargo about` or `cargo deny`. Assets are uploaded under fixed names (`doodle-rs-steamos.tar.gz`,
    `-linux.tar.gz`, `-windows.zip`) as well as versioned ones.
  - **Deck install**: port `deck_install.sh`, adding a SHA-256 check against the release digest.
  - **Local Deck builds from Windows**: `cargo zigbuild --target x86_64-unknown-linux-gnu.2.31`, or the sniper
    SDK container.
- **Why.** Doodle's release matrix is kept, and its CI gaps are closed: no push CI, compile checks skipped,
  local-only replays, and no table drift check.

### D20. Steam Deck budgets are requirements, with tests

- **Decision.** The numbers in "Performance and memory budgets" are acceptance criteria. They are measured on
  a Steam Deck LCD (Zen 2, 4 cores / 8 threads, 16 GB shared, 1280x800, Game Mode) by `cargo xtask deck bench`,
  which replays scripted traces on the device. CI enforces the ones that can run there (edit latency, menu
  open with fake facts, test-suite time) with a generous factor.
- **Why.** P24: the Deck is the reference platform, not a port.

### Spikes that confirm these decisions (run first; write each result to `docs/spikes/Sxx.md`)

| Spike | Question | Exit criterion | If it fails |
|---|---|---|---|
| S1 | Does the oracle at `=0.0.358` load a small cargo project, apply a text change, and give expected types at fn argument, method argument, `let x: T = ●`, return/tail, struct field, binary operand, match-arm body, closure body, `impl Into<String>` parameter and `?` operand? | ≥ 8 of 10 answer; every miss is Unknown, never wrong; warm p95 ≤ 150 ms on the Deck | LSP engine plus a stronger syntax layer (D6) |
| S2 | Projection and round-trip over std's sources plus 20 popular crates (opened with `format: false`); the hole matrix, including holes inside macro and attribute arguments (`vec![todo!()]`, `println!("{}", todo!())`, `assert!(todo!())`, `#[cfg(true)]`, `cfg!(true)`, the one-entry `thread_local!` form; D3.9); std blob size | 100% byte-exact; 5k-line projection ≤ 4 ms on the Deck; every hole kind round-trips; blob ≤ 10 MB | fix the projection; `todo!("●")` (D4); a macro whose arguments won't sub-parse stays `Opaque` |
| S3 | Layout engine against rustfmt for fn signatures, calls, chains, struct literals, `match`, `use` | every statement the menus can produce passes `rustfmt --check` | item-scoped rustfmt under the gate (D5) |
| S4 | SDL3 gamepad under Steam Input (Game Mode, non-Steam shortcut), hot-plug, the on-screen keyboard, glow + fontdue at 60 Hz with a 5k-line file | every button and trigger maps; frame p99 ≤ 8 ms | `sdl2` 0.39 behind the same platform API |
| S5 | `cargo run` of an SDL3 hello-window through Setup's Zig wrapper, with no system `cc` | builds, links and runs in Game Mode | `cargo-zigbuild` as the build driver |
| S6 | `whisper-cli` vs `whisper-server` on 2 s clips on the Deck | numbers decide phase 2 | stay on cli |
| S7 | Oracle RSS and cold-load time: std-only, an SDL3 project, a heavy dependency graph | sets the cap and the `prefill_caches` defaults | `analysis off for this project (too big for this device)` |
| S8 | Replay determinism with recorded oracle events | 10 identical replays; identical with the oracle binary deleted | keep facts out of the fingerprint (D7) |
| S9 | No false grays on NS1/NS2 (punch a hole at every expression; the entry that rebuilds it must be lit) | zero false grays; ≥ 30% useful grays | gray only scalar literal mismatches |
| S10 | Method menus for 10 receivers (`Vec<i32>`, `String`, `&str`, `Option<String>`, `Result<u32, ParseIntError>`, `HashMap<String, u32>`, an `IterMut`, `minifb::Window`, `std::io::Stdin`, `u32`), d-pad cost by BFS | max ≤ 12 presses, median ≤ 6 | inherent and in-scope traits only, plus a `Search by voice` leaf: dictated words filter the full `MembersOf` list and the user still picks a listed method (nothing outside the oracle's list is ever inserted; P4) |
| S11 | Derives and proc macros with server `None` vs `Sysroot`; which component ships the server | std derives visible with no server; serde with `Sysroot` | proc macros off; Unknown |
| S12 | Borrow-error repair coverage over about 30 classic errors (E0382, E0499, E0502, E0505, E0596, E0597, E0384, E0106, E0716, E0373) | ≥ 60% fixable with one pick | explain-only, plus Grab |
| S13 | Warm and cold `cargo check` and `cargo build` on the Deck for NS1 and NS2, and disk use | warm check ≤ 3 s, cold ≤ 90 s | check only on Save and Run |

---

## Workspace layout

```
doodle-rs/                       ("doodle-rs" is the placeholder name, O1)
  Cargo.toml                     [workspace] resolver = "3"; [workspace.dependencies] with exact pins
  rust-toolchain.toml            channel = "1.100.0"; components = ["rustfmt", "clippy", "rust-src"]
  pins.toml                      THE pin file (D17)
  deny.toml / clippy.toml        workspace lints; crates/core/clippy.toml holds the purity bans (D1)
  crates/
    core/        doodle-core       lib
    syntax/      doodle-syntax     lib
    facts/       doodle-facts      lib
    knowledge/   doodle-knowledge  lib   data/std-1.100.0.postcard.zst (generated, committed)
    formats/     doodle-formats    lib
    oracle/      doodle-oracle     bin   (+ `dump-std`, `dump-crate` subcommands)
    platform/    doodle-platform   lib
    render/      doodle-render     lib   assets: shaders inline
    stt/         doodle-stt        lib
    trace/       doodle-trace      lib
    app/         doodle-app        bin "doodle-rs"
    testkit/     doodle-testkit    lib   (dev-dependency only)
  xtask/                         gen-std | trace {list,report,find,show,verify,script} | dist | check-release |
                                 lint-deps | ci-local | doc-check | refresh-pins | ra-bump | deck {bench,install}
  .config/nextest.toml           optional `compile` test group (D19 step 4)
  assets/                        fonts/ (DejaVu Sans Mono + license), icons/*.svg, sounds/*.wav
  tests/
    traces/                      committed fixture recordings (replayed headless in CI)
    corpus/                      vendored .rs files for round-trip properties (Rust Book listings, NS targets)
    cassettes/                   oracle cassettes (content-addressed)
    rustc-json/                  captured cargo check JSON for the diagnostics parser and Fix tests
  docs/spikes/                   S1..S13 results
  dist/deck_install.sh
```

### Dependency DAG (enforced by `cargo xtask lint-deps`)

```
doodle-facts      -> serde, serde_json                         (pure data; no ra_ap, no I/O)
doodle-formats    -> (std only; serde for trace record structs)
doodle-syntax     -> ra_ap_syntax (=0.0.358)                    (the ONLY dependent of ra_ap_syntax)
doodle-knowledge  -> doodle-facts, postcard, ruzstd             (feature "embed" = include_bytes! the std blob)
doodle-core       -> doodle-syntax, doodle-facts, doodle-knowledge, doodle-formats, enumset, indexmap
doodle-oracle     -> doodle-facts, doodle-syntax, doodle-knowledge (default-features = false),
                     ra_ap_{ide, hir, ide_db, load-cargo, project_model, ...} (=0.0.358)
doodle-platform   -> sdl3                                       (no doodle crates)
doodle-render     -> doodle-core (view::Scene types only), glow, fontdue, etagere, resvg, unicode-width
doodle-stt        -> process-wrap, ureq (feature "server")      (no doodle crates; the app converts)
doodle-trace      -> doodle-core, doodle-formats, zstd, serde_json
doodle-app        -> doodle-{core, syntax, facts, knowledge, formats, platform, render, stt, trace}, glow,
                     process-wrap, ureq, sha2, semver, trash, cargo_metadata, crossbeam-channel, dirs
                     (glow: it builds the glow::Context from the platform's gl_proc_address for
                     Renderer::new; it SPAWNS doodle-oracle; it does not link it)
doodle-testkit    -> doodle-{core, trace, facts, formats, syntax}, cargo_metadata, tempfile
                     [dev-dependency only; `compile` and `metadata` helpers spawn cargo and rustfmt]
xtask             -> doodle-{formats, trace, knowledge, facts}, cargo_metadata
```

Rules:
1. Nothing depends on `doodle-app`.
2. No product crate depends on `doodle-testkit`.
3. `doodle-core` reaches no `sdl3`, `glow`, `ra_ap_hir`, `ra_ap_ide`, `process-wrap` or networking crate.
4. `ra_ap_syntax` is named only by `doodle-syntax`, which re-exports it as `doodle_syntax::rs`.
5. `doodle-oracle` is the only crate that links semantic `ra_ap_*` crates.
6. The test `core_depends_on_no_platform_crates` parses `cargo metadata` and asserts rules 3 to 5. It lives in
   `xtask` (core test files may not spawn processes: the core's clippy bans cover its tests).
7. **What `lint-deps` checks.** The `doodle-*` → `doodle-*` normal-dependency edges listed above, exactly (an
   unlisted edge fails), plus rules 1-5. Third-party normal dependencies are free unless rule 3 bans them.
   Dev-dependencies are exempt except from rule 2; `doodle-core`'s dev-dependency on `doodle-testkit` (needed
   by every `crates/core/tests` file), and dev-dependencies such as `proptest`, `insta` and `tempfile`, are
   expected. Use the testkit only from `crates/core/tests/*`, never from `#[cfg(test)]` unit tests inside
   `crates/core/src` (those would see a second copy of doodle-core's types through the dev-dependency cycle).

### Pins (excerpt)

```toml
# Cargo.toml
[workspace.package]
edition = "2024"
rust-version = "1.100"           # >= the ra_ap MSRV (1.98)

[workspace.dependencies]
ra_ap_syntax        = "=0.0.358"
ra_ap_ide           = "=0.0.358"
ra_ap_hir           = "=0.0.358"
ra_ap_ide_db        = "=0.0.358"
ra_ap_load-cargo    = "=0.0.358"
ra_ap_project_model = "=0.0.358"
sdl3     = "=0.22.1"
glow     = "=0.18.0"
fontdue  = "=0.9.5"
etagere  = "=0.3.0"
resvg    = "=0.50.0"
process-wrap = "=11.0.0"
postcard = "=1.2.0"
ruzstd   = "=0.9.1"
enumset  = "=1.1.15"
indexmap = "=2.14.2"
cargo_metadata = "=0.23.1"
trash    = "=5.4.0"
# serde, serde_json, zstd, ureq, sha2, semver, unicode-width, crossbeam-channel, dirs, insta, proptest:
# pin exactly at M0 after checking crates.io.

# Never set panic = "abort" in [profile.release] or [profile.dev]: the oracle needs unwinding for salsa
# cancellation (verify at the pin), and Cargo cannot override `panic` per package. The app's panic hook (D15)
# also relies on unwinding.

[profile.dev.package."*"]
opt-level = 2                    # an unoptimized rust-analyzer is too slow to develop against
```

### Public interfaces (Rust sketches; shapes and names inside our crates are decisions, bodies are not)

#### `doodle-core`: input, effects, the step function

```rust
// crates/core/src/input.rs
use enumset::{EnumSet, EnumSetType};
use std::sync::Arc;

#[derive(EnumSetType, Debug)]
pub enum Button { A, B, X, Y, Up, Down, Left, Right, Lb, Rb, KeyCopy }   // positional: A = confirm, B = back

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Input {
    pub pressed: EnumSet<Button>,   // edges this frame, auto-repeats included
    pub released: EnumSet<Button>,  // edges this frame (Talk is a hold)
    pub held: EnumSet<Button>,      // levels after this frame's events
    pub repeat: EnumSet<Button>,    // the subset of `pressed` synthesized by auto-repeat (analysis only)
    pub lt_held: bool,              // trigger > 0.5, or the keyboard stand-in
    pub rt_held: bool,
    pub typed: String,              // consumed only by the name dialog (P1)
    pub events: Vec<Event>,         // async results, in delivery order; recorded verbatim
}
impl Input {                         // test and app helpers
    pub fn press(b: Button) -> Input;
    pub fn combo(trigger: Trigger, b: Button) -> Input;   // Trigger::{Lt, Rt}
    pub fn event(e: Event) -> Input;
    pub fn idle_after(prev: &Input) -> Input;             // no edges, no events, prev's levels (rule 3)
}

pub type ReqId = u32;      // counters inside App: deterministic, derived state
pub type Rev = u64;
pub type ClipId = u32;
pub type RunId = u32;

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Opened   { req: ReqId, result: Result<Opened, IoErr> },   // bytes, + rustfmt output when asked, + rustfmt.toml
    Listed   { req: ReqId, result: Result<Vec<DirEntry>, IoErr> },
    Wrote    { req: ReqId, result: Result<(), IoErr> },
    FileOp   { req: ReqId, result: Result<(), IoErr> },       // rename, trash, create dir
    Indexed  { gen: u32, index: Arc<CrateIndex> },            // syntax index of the crate's other .rs files
    Metadata { req: ReqId, result: Result<Arc<CargoInfo>, String> },
    Oracle(doodle_facts::FromOracle),                          // answers, progress, ready, down
    Formatted{ req: ReqId, result: Result<Arc<str>, String> },// Format file (user-requested)
    Checked(Arc<doodle_facts::CheckReport>),                  // for an exact text hash
    Heard    { clip: ClipId, result: Result<String, String> },
    Registry { req: ReqId, result: Result<Vec<CrateHit>, String> },  // sparse-index lookup (online only)
    DepAdded { req: ReqId, result: Result<String, String> },  // `cargo add` outcome
    Ran      { id: RunId, status: RunStatus },
    Toolchain(ToolchainState), Setup(SetupProgress), Update(UpdateState),
    Recovered(Vec<RecoveredDoc>),
    CloseRequested,                                            // window close button
}

#[derive(Clone, Debug, PartialEq)]
pub enum Request {
    Open      { req: ReqId, path: AbsPath, format: bool },
    ListDir   { req: ReqId, path: AbsPath },
    Write     { req: ReqId, path: AbsPath, bytes: Arc<[u8]>, mode: WriteMode }, // Create | Replace | Overwrite{confirmed}
    Rename    { req: ReqId, from: AbsPath, to: AbsPath },
    Trash     { req: ReqId, path: AbsPath },
    CreateDir { req: ReqId, path: AbsPath },   // creates missing parents; fails if `path` itself exists
    Index     { root: AbsPath, gen: u32 },
    Metadata  { req: ReqId, root: AbsPath },
    Oracle(doodle_facts::ToOracle),
    Format    { req: ReqId, text: Arc<str>, edition: Edition },
    Check     { root: AbsPath, file: RelPath, rev: Rev, text: Arc<str> },   // the app debounces (D10)
    Registry  { req: ReqId, name: String },
    AddDependency { req: ReqId, root: AbsPath, spec: DepSpec },
    Run(RunSpec),
    Talk(TalkReq),                  // Start { clip, mode, prompt } | Split { clip } | Stop { clip }
    Clipboard(String),
    Sound(Sfx),
    Status(Notice),                 // the app shows it (2 s default); presentation only
    SaveStore { kind: StoreKind, text: String },
    Setup(SetupAction), Update(UpdateAction),
    Recovery(RecoveryAction),       // snapshot dirty docs / discard
    Quit,
}

#[derive(Debug, Default)]
pub struct Outbox { pub requests: Vec<Request> }

// crates/core/src/lib.rs
pub struct Boot {                    // recorded in the trace's meta lines
    pub seed: u64,                   // the only source of randomness (project names); SplitMix64 inside
    pub os: Os,
    pub data_dir: AbsPath,
    pub projects_dir: AbsPath,       // computed by the app: <home>/DoodleRsProjects, home = %USERPROFILE%,
                                     // else $HOME; with neither, <data_dir>/projects. Not created at startup:
                                     // the first save creates it with the project folder (CreateDir).
    pub keys_text: Option<String>,   pub heat_text: Option<String>,
    pub roots_text: Option<String>,  pub settings_text: Option<String>,
    pub open_file: Option<AbsPath>,  // command-line file (features/09 F7)
}
pub struct App { /* private: modes, documents, keymap, heat, facts, knowledge layers, pages, counters, rng,
                    the last trigger and button levels */ }
impl App {
    pub fn new(boot: Boot) -> App;
    pub fn facts_pending(&self) -> bool;                  // for the settle gate (D7)
    pub fn repeat_suppressed(&self) -> bool;              // true in Editor(Talking | Transcribing) (D11, D12)
    pub fn dirty_docs(&self) -> Vec<(AbsPath, Arc<str>)>; // for crash recovery (D15)
}
pub fn update(app: &mut App, input: Input) -> Outbox;      // the ONLY way state changes
pub fn fingerprint(app: &App) -> u64;                      // FNV-1a 64 (D16)
pub mod view { pub fn scene(app: &crate::App, cfg: &ViewCfg) -> Scene; } // pure view model (D13)

/// Implemented by the app (real), the visual replayer (inert) and the testkit (in memory). The core defines
/// it but never calls it.
pub trait Executor {
    fn dispatch(&mut self, requests: Vec<Request>);  // never blocks
    fn drain(&mut self) -> Vec<Event>;               // results ready now; FIFO per source, sources in fixed order
}
```

**Project names** (features/09 F5, frozen once M0 ships like action keys, because the north-star references
contain them). `App.rng` is a standard SplitMix64 (Vigna: add `0x9e3779b97f4a7c15`, then the mixes with
`0xbf58476d1ce4e5b9` and `0x94d049bb133111eb`) seeded with `Boot.seed`. Each New Project takes exactly one
draw `r`: adjective = `ADJ[r % 24]`, animal = `ANIMAL[(r / 24) % 23]`, number = `(r / 552) % 10000`,
formatted `{adjective}-{animal}-{number:04}`, with features/09 F5's two lists in their order. Nothing else
draws from `App.rng`. `project_name_is_deterministic_from_seed` pins the first three names for one seed.

`App` is `Send`: it holds `Parse` values and plain data, never `SyntaxNode`s. Modes are an enum, so illegal
combinations of Doodle's roughly 40 flags can't be expressed (features/01 (b)):

```rust
pub enum Mode {
    MainMenu(MainMenu),
    Editor(EditorState),          // sub-state: Normal | RefPick | ModPick | Grab | WordEdit | Talking{clip} | Transcribing{clip}
    Menu { under: Box<Mode>, stack: MenuStack, purpose: MenuPurpose },  // purpose drives B-at-root restore (P9)
    Files(FilesPage), RunList(RunPage), Settings(SettingsPage), Setup(SetupPage), KeyLayout(KeysPage),
    Projects(ProjectsPage), NewProject(NewProjectPage), NameDialog(NameDialog), Docs(DocsPanel),
    Confirm(ConfirmKind),         // trust, overwrite, unsaved changes, recovery, delete
}
pub enum MenuPurpose {
    Insert { restore: Snapshot },  // A on a green dot: the temp line goes on B
    Fill { hole: Anchor },
    Refill { restore: Snapshot },  // Y on a filled part
    Options { part: PartRef },     // Y on a keyword: changes nothing until a pick
    DeclareAs { restore: Snapshot },
    Pick { kind: PickKind, restore: Snapshot },
}
```

#### `doodle-core`: the `Oracle` trait the core consumes

Menu builders, fit and labels never see the protocol. They read facts through this **non-blocking, read-only**
trait. It is implemented by the core's `FactStore` (filled only from `Event::Oracle`, keyed by revision and
text hash) and by `FakeFacts` in unit tests:

```rust
// crates/core/src/facts.rs
use doodle_facts::{Fit, TyFacts, HoleFacts, ScopeName, Members, ItemInfo, CrateKey};
use doodle_syntax::{TextRange, TextSize};

pub enum Known<T> { Ready(T), Pending, Unknown }   // Pending and Unknown never gray (D7.6)

pub trait Oracle {
    fn rev(&self) -> Option<Rev>;                                       // revision these facts describe
    fn hole(&self, at: TextSize) -> Known<&HoleFacts>;                  // expected type + source
    fn expected_at(&self, part: TextRange) -> Known<&TyFacts>;          // prefetched for filled parts (D7.8)
    fn binding(&self, name_at: TextSize) -> Known<&TyFacts>;
    fn call_result(&self, call: TextRange) -> Known<&TyFacts>;          // capture dots
    fn scope(&self, at: TextSize) -> Known<&[ScopeName]>;               // file order, with declaration sites
    fn members(&self, receiver: TextRange) -> Known<&Members>;          // fields + methods, grouped by source
    fn fits(&self, at: TextSize, group: &GroupKey) -> Known<&[Fit]>;    // one per leaf, in the group's order
    fn items_of(&self, krate: &CrateKey, module: &str) -> Known<&[ItemInfo]>;
    fn suggestions(&self, at: TextSize) -> Known<&[Suggestion]>;        // term search, bounded fuel
}

/// What menu builders use to ask for missing facts. Collected during update, emitted as
/// Request::Oracle(ToOracle::Query{..}) at the end of the frame, deduplicated.
pub struct Wants(Vec<doodle_facts::Query>);
```

#### `doodle-facts`: protocol and fact types (shared by the core, the oracle, the app and tests)

```rust
pub const PROTOCOL_VERSION: u32 = 1;
pub type Rev = u64; pub type QueryId = u32;
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)] pub struct Span { pub start: u32, pub end: u32 }

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub enum ToOracle {
    Hello { v: u32, app_build: String },
    OpenWorkspace { root: String, trusted: bool, opts: LoadOpts },  // trusted => build scripts + proc macros
    SetText { file: String, rev: Rev, text: Arc<str> },           // the open file's live text
    FilesChanged { paths: Vec<String> },                          // saved siblings, Cargo.toml, Cargo.lock
    Query { id: QueryId, rev: Rev, file: String, q: Query },
    Cancel { below_rev: Rev },
    Shutdown,
}
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub enum Query {
    FileFacts,                                   // every hole, binding and bare-call result in the file
    ExpectedAt { span: Span },                   // a filled part, for Y-refill (prefetched)
    Fits { at: u32, items: Vec<ItemRef> },       // a group's leaves against the hole's expectation
    ScopeAt { at: u32 },                         // values visible here, with types (Reference, Pass as)
    MembersOf { receiver: Span },                // visible fields, methods (inherent / deref level / trait / needs-use)
    ItemsOf { krate: CrateKey, module: String }, // a dependency module's public items with signatures
    Suggest { at: u32, fuel: u32 },              // term search (ra_ap_hir::term_search; verify at the pin)
    Hover { at: u32 },                           // Markdown for the Docs panel
    PrepareRename { at: u32 }, Rename { at: u32, new_name: String },
    Highlights,                                  // semantic classes
    Diagnostics,                                 // rust-analyzer native diagnostics
}
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub enum FromOracle {
    Ready { v: u32, build_id: String, ra_version: String, toolchain: String, sysroot: String },
    Progress { phase: Phase, done: u32, total: u32 },
    Mem { rss_mb: u32 },
    Answer { id: QueryId, rev: Rev, text_hash: u64, result: Answer },
    Cancelled { id: QueryId },
    Failed { id: QueryId, why: String },
    Down { why: String },                        // synthesized by the app's client on exit/crash/restart
}
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub enum Fit { Yes, No { why: String }, Unknown }

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct TyFacts {
    pub shown: String,      // as the open module would write it (display_source_code)
    pub canon: String,      // fully qualified; stable identity for pins and heat
    pub cat: TyCat,         // Int{bits,signed} | Float | Bool | Char | Str | String | Unit | Never | Ref{mutable} |
                            // RawPtr | Slice | Array | Tuple(n) | Adt | Option | Result | Fn{arity} | Closure |
                            // Dyn | ImplTrait | Param | Unknown
    pub accepts: AcceptBits,// int_lit, float_lit, str_lit, char_lit, byte_lit, bool_lit, unit, none_some,
                            // ok_err, closure(arity), iterable{by_ref, by_mut, by_val}, default, ...
    pub unknown: bool,      // contains_unknown(): every bit is "maybe" => never gray
}
pub struct HoleFacts { pub expected: Option<TyFacts>, pub source: ExpectSource }
pub enum ExpectSource { Adjusted, CallArg, LetAnnotation, Return, Operand, Field, Scrutinee, AssignTarget, Construct }

/// Engine side: the app's process client, the LSP fallback, the testkit's fake and cassettes.
pub trait Engine: Send {
    fn send(&mut self, msg: ToOracle);
    fn recv(&mut self) -> Vec<FromOracle>;
}

pub mod diag {   // pure, pinned by captured JSON
    pub struct CheckReport { pub text_hash: u64, pub diags: Vec<Diag>, pub ok: bool }
    pub fn parse_cargo_messages(json_lines: &str, file: &str, text_hash: u64) -> CheckReport;
}
```

#### `doodle-knowledge`: the `Knowledge` trait

```rust
pub trait Knowledge {
    fn crates(&self) -> &[CrateRoot];                         // std, core, alloc, deps, this crate
    fn children(&self, module: ModId) -> &[ItemId];           // sorted, deterministic
    fn item(&self, id: ItemId) -> &ItemInfo;                  // ItemInfo is doodle_facts::ItemInfo
    fn lookup(&self, canonical_path: &str) -> Option<ItemId>; // "std::fs::read_to_string"
    fn keyword(&self, kw: &str) -> Option<&KeywordInfo>;
    fn macro_shape(&self, path: &str) -> Option<&MacroShape>; // arity, format-string arg, forms, result type
    fn attribute(&self, name: &str) -> Option<&AttrInfo>;    // where valid, conflicts, argument kind
    fn doc_summary(&self, id: ItemId) -> Option<&str>;
}
pub fn std_tables() -> &'static StdTables;                    // LazyLock over the embedded blob (feature "embed")
pub fn group(items: &[ItemId], k: &dyn Knowledge) -> Grouping; // features/07 §6: module -> impl block -> prefix
                                                               // -> buckets of 12, FLAT_MAX 60; pure
```

The core layers it as `Layered { std: &'static StdTables, deps: BTreeMap<CrateKey, Arc<CrateTable>>, local:
Arc<CrateIndex> }`. Dependency tables and the local index are `App` state, filled by events.

#### `doodle-syntax`: document, projection, holes, layout

```rust
pub use ra_ap_syntax as rs;                                   // the single re-export point (D2)
pub use ra_ap_syntax::{Edition, TextRange, TextSize};

pub struct Document {
    text: Arc<str>,
    parse: rs::Parse<rs::SourceFile>,
    rev: Rev,
    meta: FileMeta,          // edition, crlf, final_newline, bom, read_only
    lines: Arc<[Line]>,      // projection cache
}
impl Document {
    pub fn load(bytes: &[u8], edition: Edition) -> Document;  // non-UTF-8 => read_only, one Opaque region
    pub fn text(&self) -> &Arc<str>;
    pub fn rev(&self) -> Rev;
    pub fn text_hash(&self) -> u64;
    pub fn lines(&self) -> &[Line];
    pub fn parse(&self) -> &rs::Parse<rs::SourceFile>;
    pub fn apply(&self, edits: &[TextEdit], fmt: &FmtConfig) -> Applied;  // reparse, relayout root, reproject
    pub fn saved_bytes(&self) -> Vec<u8>;                     // CRLF, BOM, final newline restored
    pub fn holes(&self) -> impl Iterator<Item = (TextRange, HoleKind)> + '_;
}
pub struct Applied { pub doc: Document, pub map: OffsetMap }  // old offset -> new offset (cursor, carried facts)

pub struct TextEdit { pub range: TextRange, pub insert: String }

pub struct Line {                  // one screen row (D3.2)
    pub range: TextRange,          // this row's bytes: a whole saved line, or part of one (D3.3 split); empty
                                   // for editor-only rows
    pub fields: Vec<Field>,        // partition `range` (+ zero-width virtual fields)
    pub saved_no: Option<u32>,     // the gutter number; Some only on the first row of a saved line
    pub part_of: Option<u32>,      // the saved line these bytes belong to; None => editor-only row
    pub depth: u16,
}
pub struct Field { pub range: TextRange, pub role: Role, pub stop: bool, pub display: Display }
pub enum Display { Text, Dot(DotKind), TintedText(DotKind) }  // TintedText: `_` pattern drawn in teal
pub enum Role {
    Keyword(Kw), Name(NameRole), Literal(LitKind), LiteralText, Op(OpKind), Punct, Trivia,
    Comment, DocComment, Attr, Opaque, Hole(HoleKind), Virtual(VirtualDot),
}
pub enum HoleKind { Value, Tail, Type, Ret, Pattern, Cfg }
pub enum VirtualDot {
    Insert(InsertCtx),             // green: Module | Block | AssocItems | Members | Arms | ForeignItems
    StmtRow, ItemOptions, Capture,
    Params, Generics, Bounds, Where, Args, Fields, Rest, Group, OptionalTail,
}

pub fn project(text: &str, parse: &rs::Parse<rs::SourceFile>) -> Vec<Line>;   // pure; property-tested
pub mod holes  { pub fn spelling(k: HoleKind) -> &'static str; pub fn classify(node: &rs::SyntaxNode) -> Option<HoleKind>; }
pub mod layout { pub fn relayout(text: &str, parse: &rs::Parse<rs::SourceFile>, root: TextRange, cfg: &FmtConfig) -> Vec<TextEdit>; }
pub mod highlight { pub fn classes(parse: &rs::Parse<rs::SourceFile>) -> Vec<(TextRange, HlClass)>; }
pub mod index  { pub fn index(file_text: &str, edition: Edition) -> FileIndex; }   // items, visibility, sigs, docs
```

#### `doodle-core`: constructs, entries, templates

```rust
pub trait Construct: Sync {
    fn id(&self) -> ConstructId;                                         // stable; part of heat keys
    fn offers(&self, at: &Location, cx: &mut MenuCx<'_>) -> Vec<Entry>;  // what it adds to the menu here
    fn build(&self, pick: &EntryAction, at: &Location, cx: &BuildCx) -> Template;
    fn options(&self, part: &PartRef, cx: &mut MenuCx<'_>) -> Vec<Entry>; // Y menu; refusals structural only (D8)
    fn delete(&self, part: &PartRef, cx: &EditCx) -> Option<Vec<TextEdit>>; // finest-first chain (P11)
}
pub struct MenuCx<'a> { pub doc: &'a Document, pub scope: &'a SyntaxScope, pub facts: &'a dyn Oracle,
                        pub know: &'a dyn Knowledge, pub wants: &'a mut Wants, /* edition, target, settings */ }
pub struct Entry { pub label: String, pub action: EntryAction, pub gray: Option<Gray>, pub pinned: bool, pub heat: HeatKey }
pub enum Gray {                                                       // Hidden = not listed
    Refused  { reason: Reason, evidence: Evidence },                  // Syntax | Index | Metadata only (D8)
    Advisory { reason: Reason, fix: Option<Fix>, evidence: Evidence },
}
pub enum Evidence { Syntax, Index, Metadata, Knowledge, Oracle, Diagnostics }  // D7.6 tests read this
pub struct Template {
    pub replace: TextRange, pub text: String,       // with hole spellings and generated names
    pub extra: Vec<TextEdit>,                       // auto-use, auto-mut, generated arms
    pub cursor: CursorTarget,                       // e.g. NthHole(0), Name, After
    pub notice: Option<Notice>,                     // "added use std::collections::HashMap" (P21)
}
pub static CONSTRUCTS: &[&dyn Construct] = &[ /* one module per construct family */ ];
```

#### `doodle-stt`, `doodle-platform`, `doodle-render`

```rust
// doodle-stt
pub trait SpeechEngine: Send {
    fn transcribe(&mut self, pcm_16k_mono: &[f32], prompt: &str) -> Result<String, String>; // speech thread
}
pub struct WhisperCli { /* exe, model, threads */ }      // phase 1
pub struct WhisperServer { /* child, port */ }           // phase 2

// doodle-platform (no doodle types; the app converts bit order 1:1 to doodle_core::Button)
pub struct PadFrame { pub pressed: u16, pub released: u16, pub held: u16, pub repeat: u16, pub lt: f32, pub rt: f32 }
pub struct RawFrame { pub pad: PadFrame, pub typed: String, pub close: bool, pub resized: Option<(u32, u32)>, pub raw: Vec<RawEvent> }
impl Platform {
    pub fn new(cfg: &WindowCfg) -> Result<Platform, String>;
    pub fn pump(&mut self, now: std::time::Instant, suppress_repeat: bool) -> RawFrame;  // repeat synthesis
                                                   // lives here (a pure tick); none while suppress_repeat
    pub fn gl_proc_address(&self, name: &str) -> *const std::ffi::c_void;
    pub fn swap(&mut self);
    pub fn audio(&mut self) -> &mut Audio;                         // mixer + capture ring
}

// doodle-render
pub trait Measure { fn width(&self, s: &str) -> f32; fn line_height(&self) -> f32; }
impl Renderer {
    pub fn new(gl: glow::Context, fonts: FontSet, icons: IconSet) -> Renderer;
    pub fn paint(&mut self, scene: &doodle_core::view::Scene, px: (u32, u32), scale: f32, anim_t: f32, status: Option<&str>);
}
```

### Core module map

```
crates/core/src/
  lib.rs            App, Boot, update, fingerprint
  input.rs          Button, Input, Event, Request, Outbox, Executor
  mode.rs           Mode, MenuPurpose, Snapshot
  keymap.rs         Action, ActionInfo, Keymap, resolve, rebind_hint            (features/03 F3-F7, F18)
  menu/             entry.rs, stack.rs, view.rs (grid, wrap, sections, sort), heat.rs, open.rs
  editor/           cursor.rs, walk.rs, change.rs, edit.rs, delete.rs, pick.rs, grab.rs, rename.rs, undo.rs
  constructs/       items/ (fns, types, impls, traits, consts, mods, uses, tests, cfg, item_options),
                    stmts/ (lets, assign, calls, capture, branch, loops, jumps, errors, blocks, layout),
                    values/ (literals, reference, pass_as, calls, struct_lit, variants, ops, convert, choose,
                    closure, range, field_of, index, macros), types.rs, patterns.rs, members.rs, arms.rs
  scope.rs          syntax layer: scopes, structural positions, const contexts, refusal checks (D6, D8)
  facts.rs          FactStore: impl Oracle, Wants, revision/text-hash keyed cache, carried facts
  fit.rs            literal and structural fit from AcceptBits; reasons
  knowledge.rs      Layered knowledge
  namegen.rs        adjective_animal by role, keywords, raw identifiers, numeric suffix fallback; project names
                    from App.rng (the mapping above)
  text/             dictation.rs (targets, casing, spoken numbers), tools.rs, words.rs, keypad.rs
  diagnostics.rs    map CheckReport onto fields, hole filter, Fix entries
  pages/            main_menu, files, run, settings, setup, keys, projects, new_project, name_dialog, docs, confirm
  view/             scene.rs, hud.rs, hints.rs
  fingerprint.rs    walks App and feeds doodle_formats::fnv1a64 (D16)
```

Every source file starts with a `//!` header written from the user's side, with `●` examples and the buttons
that act on them (P27).

---

## The per-frame contract

```rust
// crates/app/src/main.rs (shape, not code to copy blindly)
let mut app = doodle_core::App::new(boot);                    // stores loaded BEFORE the trace starts
loop {
    let now = Instant::now();
    let raw = platform.pump(now, app.repeat_suppressed());    // SDL events -> PadFrame (repeat synthesized)
    let mut events = executor.drain();                        // every worker result ready now
    if raw.close { events.push(Event::CloseRequested); }
    let pad = gate.admit(raw.pad, app.facts_pending(), &events, now);   // settle gate (D7.7); may hold presses
    let input = Input { pressed: pad.pressed, released: pad.released, held: pad.held, repeat: pad.repeat,
                        lt_held: pad.lt, rt_held: pad.rt, typed: raw.typed, events };
    trace.record(frame, &input);                              // cfg(trace) only
    let out = doodle_core::update(&mut app, input);           // pure; never blocks
    trace.fingerprint(frame, doodle_core::fingerprint(&app)); // cfg(trace) only
    executor.dispatch(out.requests);                          // non-blocking; workers reply on channels
    let scene = doodle_core::view::scene(&app, &view_cfg);
    renderer.paint(&scene, platform.size(), scale, anim_time(now), status.current(now));
    platform.swap();                                          // vsync
    frame += 1;
}
```

**Rules.**

1. **One entry point.** Everything that can change `App` arrives in the `Input` given to `update`. Nothing
   else mutates `App`.
2. **Order inside `update`.**
   1. Apply `input.events` in order. Each handler is a pure function of `App` and the event.
   2. Resolve pad edges through the keymap; the top `Mode` owns them (P15).
   3. Run the mode's handler.
   4. Run `after_input()`. It re-derives **non-text state only**: expected-type labels, typed-`let` value
      hints, and, on frames that carry a pad edge, the virtual dots that depend on facts (rust/02 R5). It never
      edits text. Text-changing syncs (generated match arms, pattern defaults that follow the value, the cfg
      pair mirror) happen only inside the `Template` of the user's pick, from the facts present in that frame
      (D7.3, rust/02 R5). It runs only when no menu or pick holds a field reference (features/05 inv 13).
   5. Collect `Wants` and the new-revision requests (`SetText`, `FileFacts`, `Check`) into the `Outbox`.

   Events come before pad edges, so an answer released together with a gated A press grays the menu that A
   opens.
3. **Idle is identity.** An idle `Input` has no edges, no events and no typed text, and the same levels
   (`held`, `lt_held`, `rt_held`) as the previous frame's `Input`: `Input::idle_after(&prev)`. Feeding it
   changes nothing (the fingerprint is equal) and returns no requests. (`Input::default()` is not idle when a
   trigger or Talk is held: it releases them.) The property test `idle_frame_is_identity` runs it over random
   reachable states. Trigger and button levels are `App` state, because they pick the HUD's active bank and
   drive hold actions, but the raw levels are not mixed into the fingerprint; their effects are (Talking is a
   mode).
4. **No blocking and no I/O in `update`** (D1, enforced). It has a budget of ≤ 2 ms p99 on the Deck.
5. **Requests are fire-and-forget.** Every request that expects a reply carries a `ReqId`, `QueryId` or
   `ClipId`, and its result arrives as an `Event` in a later frame. A reply for a superseded id or revision is
   dropped deterministically.
6. **What each event may change:**

   | Event | May change | Must never change |
   |---|---|---|
   | `Opened`, `Listed`, `Wrote`, `FileOp`, `Metadata`, `Indexed` | the pending operation's mode/page state; documents on open; knowledge layers; statuses | anything unrelated to the request id |
   | `Oracle(Answer)` | labels, later menus' grays, an open placeholder list, highlight classes (D7.3) | text, cursor, mode, visible entries, open grays |
   | `Oracle(Answer)` for a user-requested edit; `Formatted`; `DepAdded` | text, if the revision is unchanged and the requesting mode is still active (D7.4) | anything when stale (dropped with a status) |
   | `Checked`, `Oracle(Diagnostics)` | shading, the problem panel, Fix entries of menus opened later | text, cursor, mode |
   | `Heard` | the target leaf captured at `Talk::Start`, if it still exists (else a status) | any other field |
   | `Ran`, `Toolchain`, `Setup`, `Update`, `Progress`, `Mem` | page and status state | documents |
   | `Recovered`, `CloseRequested` | opens a `Confirm` mode | documents, until the user picks |

7. **App-side things that may happen without input:** animation, status expiry, scrolling, debounce timers
   (check 0.6 s), heat flush scheduling (2 s), oracle restarts, auto-repeat synthesis (which becomes input),
   and the settle gate holding presses. None of them mutates `App`.
8. **The settle gate** (default on, 150 ms):
   - It holds A, Y and LT+A, plus every press queued after a held one, while `facts_pending()` is true.
   - It releases them in order, one press per frame, starting in the frame where the answer is drained or the
     budget runs out.
   - D-pad presses that come before any held press pass straight through.
   - B never starts a hold; a B pressed while presses are held queues behind them and is delivered after
     them. It never holds anything while the oracle is loading or down.
9. **Testkit.** `Pad::press(..)` runs `update`, services the requests through `MemExecutor` (`MemFs`, the
   `Engine` fake or a cassette, `FakeSpeech`, `FakeRunner`), and feeds the results back in settle frames with
   an empty pad until there are no outstanding requests. More than 64 settle frames fails the test, as a loop.
   This is Doodle's "one empty settle frame" generalized to "until quiescent" (features/11 §11).
10. **Replay.** Headless replay feeds the recorded `Input`s and ignores the `Outbox`. Visual replay does the
    same through the replay executor and renders. A replay never starts an oracle, a speech engine or a
    process.

**Tests that pin the contract:**
- `idle_frame_is_identity`;
- `same_inputs_same_fingerprint` (two `App`s, the same 500 random inputs with fake facts, equal every frame);
- `stale_answer_dropped`;
- `answer_never_changes_open_menu_grays`;
- `answer_never_moves_cursor_or_text`;
- `gated_a_opens_grayed_menu` (testkit with the gate simulated);
- `unknown_never_grays_anywhere` (oracle stubbed to Unknown: no reachable entry carries a gray whose evidence
  is `Oracle` or `Diagnostics`; type-fit grays appear only from syntax-stamped hints);
- `committed_traces_replay_headless`;
- `core_depends_on_no_platform_crates`;
- `state_machine_proptest` (random `Input` sequences from any state never panic; the cursor is always on a
  stop; the menu stack is consistent).

---

## How each Doodle subsystem maps

`features/NN` sections use `§` in docs 01, 02, 04, 05, 07 and 11, and `F` in docs 03, 06, 08, 09 and 10.

| Doodle file / area | Rust home | Spec | What changes |
|---|---|---|---|
| `model/model.odin`: `App`, `Input`, `update`, mode flags | `doodle-core` `lib.rs`, `input.rs`, `mode.rs` | features/01 §4, features/11 §1-2 | ~40 bools become `Mode`; the `requests` bit set becomes `Vec<Request>`; `notice` becomes `Request::Status`; reads become requests |
| `model.odin`: `Entry`, `MenuView`, `menu_select`, `menu_cancel` | `core::menu::{entry, stack}` | features/01 §5-6, features/02 §20 | `EntryAction` enum; B-at-root by `MenuPurpose` |
| `model.odin`: `open_slot_menu`, `open_add_menu` | `core::menu::open` + `CONSTRUCTS` | features/06 F1, features/04 §1, features/05 §2 | dispatch by CST `Location` |
| `model.odin`: `delete_selected` | `core::editor::delete` + `Construct::delete` | features/02 §17, P11 | finest-first over CST units |
| `menu_sections.odin`, `make_view` | `core::menu::view` | features/01 §6-8, P23 | |
| `heat.odin`; `app/heat_store.odin` | `core::menu::heat`; `formats::heat` + `app::stores` | features/03 F13-F14 | keys are canonical paths and construct ids |
| `keymap.odin` | `core::keymap` | features/03 F3-F7, F18 | LB/RB in the core |
| `keys_page.odin`, `app/keys_page.odin`, `app/keys_store.odin` | `core::pages::keys`; `formats::keys` | features/03 F10-F11 | |
| `namegen.odin` | `core::namegen` | features/01 §16, P5 | lifetimes, generic params, keyword checks, suffix fallback |
| `parse.odin`, `branch_parse.odin`, `loop_parse.odin`, `ctrl_parse.odin` | `doodle_syntax::project` + `holes` | features/01 §10, features/05 §28, features/04 §19 | CST projection; symmetric by construction |
| `serialize.odin` (`fixup_line`, `save_source`, `file_text`) | removed: text is truth; `Document::saved_bytes` | features/01 §11 | |
| `format.odin`, `formatter.odin`, `block_split.odin`, `stmt_layout.odin` | `doodle_syntax::layout` (+ rustfmt requests) | features/01 §12-14, features/05 §8, features/10 F8 | rustfmt default style (D5) |
| `highlight.odin` | `doodle_syntax::highlight` + oracle `Highlights` | features/01 §15, features/10 F6 | |
| `body_dots.odin`, `attr_dots.odin` | `project` virtual dots; `constructs::items::item_options` | features/02 §7-9, features/05 §1, features/04 §30 | an options dot on every item |
| `capture.odin` | `project` (`Capture`) + `constructs::stmts::capture` | features/02 §10, features/05 §9 | |
| `selection.odin`, `row_nav.odin` | `core::editor::{cursor, walk}` | features/02 §1-5, §12, §14 | |
| `change.odin` | `core::editor::change` | features/02 §18, features/06 F21, F21b | |
| `grab.odin` | `core::editor::grab` | features/02 §13 | attributes move with their item |
| `ref_pick.odin`, `ref_scope.odin` | `core::editor::pick` + `core::scope` + `ScopeAt` | features/06 F15-F16 | scopes from rust-analyzer |
| `typecheck.odin`, `var_types.odin` | `core::fit` + `doodle-oracle` | features/06 F4-F5, F22 | `TyFacts` and `AcceptBits` |
| `calls.odin`, `builtin_procs.odin` | `constructs::values::calls`; `knowledge` macro table | features/05 §6-7, features/06 F7, features/07 §5, §7 | macros as calls |
| `expr.odin` | `constructs::values::{ops, convert, choose}`; `core::text::keypad` | features/06 F11-F12a, F20 | operators by trait |
| `struct_lit.odin` | `constructs::values::struct_lit` | features/05 §26, features/06 F8 | every field inserted |
| `consts_menu.odin`, `enum_index.odin` | `constructs::values::{consts, variants}` | features/06 F9-F10 | |
| `field_access.odin`, `index_fill.odin`, `range_fill.odin` | `constructs::values::{field_of, index, range}` | features/06 F14, F17, features/05 §27 | |
| `types_menu.odin`, `collections.odin` | `constructs::types` | features/04 §16-17 | Wrap in / Drop wrapper |
| `data_types.odin`, `data_member_edit.odin` | `constructs::items::types` + `constructs::members` | features/04 §13-15, §18-19 | |
| `result_list.odin` | `constructs::items::fns` (return type, tail slot) | features/04 §11-12, features/05 §21 | tuples; the tail hole |
| `branch.odin` | `constructs::stmts::branch`, `constructs::arms` | features/05 §10-13 | `if let`, `match`, generated arms |
| `loops.odin`, `loop_unroll.odin`, `label_refs.odin` | `constructs::stmts::loops` | features/05 §15-19 | iteration modes |
| `assign_ops.odin` | `constructs::stmts::assign` | features/05 §4-5, features/06 F19, F20b | mutability |
| `ctrl.odin`, `when_cond.odin`, `when_const.odin` | `constructs::items::cfg` + `core::scope` const contexts | features/04 §23-25, features/06 F23-F24 | `when` becomes `#[cfg]`/`cfg!` |
| `modifiers.odin` | `constructs::items::item_options` | features/04 §26-29 | visibility, derive checklist, attributes, qualifiers |
| `block_comment.odin`, `block_delete.odin` | `constructs::stmts::layout`; `editor::delete` | features/04 §5, features/05 §25 | |
| `dictation.odin`, `text_tools.odin`, `word_edit.odin` | `core::text::{dictation, tools, words}` | features/08 F1-F2, F5-F17 | casing by role; format-string placeholders |
| `rename.odin` | `core::editor::rename` + `PrepareRename`/`Rename` | features/06 F26, features/08 F19 | semantic; other files only as an explicit choice (D18) |
| `siblings.odin` | app indexer (`doodle_syntax::index`) → `Event::Indexed` | features/07 §9-11 | module tree, paths, `use` |
| `core_*.odin`, `tools/gen_core_*.py`, `tools/odin_collections.py` | `doodle-knowledge` blob ← `doodle-oracle dump-std` via `xtask gen-std` | features/07 §1, features/11 §18 | CI drift check |
| `docs.odin`, `app/docs_panel.odin` | `core::pages::docs` + `Hover` + knowledge | features/07 §12-13 | |
| `diagnostics.odin`, `app/checker.odin` | `facts::diag` + `core::diagnostics` + app checker worker | features/07 §14, features/10 F13 | mirror workspace (D10) |
| `file_grid.odin`, `app/filenav.odin` | `core::pages::files` + executor | features/09 F12-F20 | `trash` everywhere |
| `projects.odin`, `project_roots.odin`, `app/projects.odin`, `app/new_project.odin`, `app/roots_store.odin` | `core::pages::{projects, new_project}`; `formats::roots` | features/09 F2-F6, F37 | Cargo package template written at first Save |
| `settings.odin`, `app/settings.odin` | `core::pages::settings`; `formats::settings` | features/03 F15 | |
| `vendor_libs.odin`, `app/vendor_path*.odin`, `app/stb_build.odin` | `core::pages::run` pre-run checks | features/09 F27-F28 | Odin-specific; becomes a generic native-library hint |
| `app/main.odin` | `doodle-app` main loop; `core::view`; `doodle-render` | features/10 F1, F7, F15-F19, features/03 F1 | HUD from `Scene` |
| `app/editor_view.odin` | `core::view::scene` + `doodle-render` | features/10 F7-F14 | |
| `app/save.odin`, `app/save_dialog.odin` | `core::pages::name_dialog` + `Request::Write` | features/09 F9-F11, features/08 F20 | |
| `app/run.odin`, `app/shell.odin`, `app/pid_*.odin` | `app::runner` (`process-wrap`) + `core::pages::run` | features/09 F21-F26 | argument vectors; an in-app output overlay as the fallback |
| `app/setup.odin`, `app/toolchain.odin` | `core::pages::setup` (pure rows) + `app::setup` | features/09 F29-F34 | rustup + Zig (D17) |
| `app/updater.odin` | `app::updater` | features/09 F35 | semver, digest required, every executable |
| `app/trace.odin`, `tools/trace.py` | `doodle-trace`, `app::trace_on`, `xtask trace` | features/11 §10-17 | Input-level recording (D16) |
| `app/icons.odin` | `doodle-render::icons` (`resvg`) | features/10 F21 | |
| `app/sound.odin` | `app::sound` + `doodle-platform` audio | features/10 F22 | |
| `app/trash_*.odin` | `trash` crate in the executor | features/09 F18 | real trash on Linux too |
| `platform/platform.odin` | `doodle-platform` | features/03 F1-F2, F17 | SDL3, hot-plug |
| `gpu/`, `text/` | `doodle-render` | features/10 F2-F4 | Unicode atlas |
| `stt/`, `stt_probe/` | `doodle-stt` + `core::text::dictation` | features/08 F3-F9 | warm server in phase 2 |
| `tools/deck_install.sh` | `dist/deck_install.sh` | features/11 §21 | + SHA-256 |
| `.github/workflows/release-steamos.yml` | `.github/workflows/{ci, release, ra-bump}.yml` | features/11 §20 | push CI added |
| `*_test.odin`, `handmade_*_test.odin` | crate unit tests; `crates/core/tests/` acceptance via testkit | features/11 §4-8 | compiler checks run in CI |
| `buffer/`, `editor/`, `input/`, `lsp/`, `ui/`, `project/` | **not ported** | features/00 Superseded | |

---

## Performance and memory budgets

Reference device: Steam Deck LCD (Zen 2, 4 cores / 8 threads, 16 GB shared LPDDR5), 1280x800, Game Mode, warm
caches unless stated. "CI" means a test enforces it on CI runners with a generous factor. "Deck" means
`cargo xtask deck bench` measures it on the device.

**Frame and interaction**

| Metric | Budget | Pinned by |
|---|---|---|
| Frame rate | 60 Hz vsync. Main-thread CPU p99 ≤ 8 ms: `update` ≤ 2 ms, `scene` ≤ 3 ms, paint submit ≤ 2 ms. GPU ≤ 4 ms. | Deck |
| Press to photon | ≤ 2 frames (input applied before the frame is drawn) | Deck |
| Edit → reparse + relayout + reprojection | p95 ≤ 4 ms for ≤ 5k-line files; ≤ 16 ms at 20k | CI (generated files), Deck |
| Open a menu with facts present | ≤ 1 frame; ≤ 50 ms with a 10k-item dependency (fake facts) | CI (Doodle's 300 ms test, tightened) |
| A on a dot → menu drawn with grays (warm oracle, gate on) | p95 ≤ 100 ms | Deck |
| Oracle `FileFacts` after an edit (1k lines, ≤ 50 holes) | p50 ≤ 50 ms, p95 ≤ 150 ms (the gate budget) | oracle bench |
| `ScopeAt`, `MembersOf`, `ExpectedAt` | ≤ 30 ms | oracle bench |
| `Fits` for one group (≤ 500 leaves), `Hover` | ≤ 100 ms | oracle bench |
| Dictation, 2 s clip, `base.en` | ≤ 1.5 s with a warm `whisper-server`; `whisper-cli` measured as the baseline | S6 |
| `cargo check` after a one-line edit (NS2) | warm ≤ 3 s; cold ≤ 90 s with progress shown | S13 |
| Idle | ≤ 30 fps redraw while something pulses; no pulsing and redraw only on input after 10 s idle | Deck (battery) |

**Startup**

| Phase | Budget |
|---|---|
| Process start → first frame (main menu, HUD) | ≤ 500 ms (embedded font, lazy table indexes, no oracle) |
| → interactive | ≤ 1 s |
| Open a recent project → editor showing the file | ≤ 1 s, oracle excluded (read, rustfmt-on-open ≤ 300 ms, parse, project) |
| Oracle ready, std-only crate | ≤ 15 s (Unknown meanwhile; the title bar shows `types: loading 31/80 crates`) |
| Oracle ready, SDL- or winit-sized dependency graph | ≤ 90 s |

**Memory (RSS) and disk**

| Item | Typical | Cap / policy |
|---|---|---|
| `doodle-rs` (app) | ≤ 300 MB (atlas, std indexes, documents, undo snapshots) | none |
| Embedded std blob | ≤ 10 MB compressed in the binary; ≤ 80 MB once fully indexed | S2 measures it |
| `doodle-oracle` | 0.5 to 1.5 GB | setting, default **3 GB** on the Deck: GC, then a restart with lower LRU capacity; the title bar says `types: restarting (memory)` |
| `whisper-server` | about 0.4 GB with `base.en` | started on the first Talk, stopped after 10 min idle |
| `cargo check` (transient) | 0.5 to 2 GB | `-j 2` on the Deck, niced |
| Total peak on the Deck | about 4 to 5 GB of 16 GB | — |
| Install folder | ≤ 400 MB including the whisper model | release-job check |
| Check caches per project | ≤ 2 GB typical | Settings > Storage shows sizes and offers `Clear check caches` |
| Traces | ≤ 20 MB per hour of use; newest 40 kept | measured |

**CPU sharing on the Deck:** the main thread gets one core. Oracle workers get 2 threads at lower priority.
`cargo check -j 2` runs niced. Whisper uses 4 threads only while transcribing.

**Developer loop:** `cargo test -p doodle-core` finishes in < 15 s of test time (CI assertion). A clean
build of `doodle-core` never compiles semantic `ra_ap_*` crates.

---

## Owner decisions still open

Build the default until the owner answers, and say so in the milestone report. "Ask by" is the milestone (or
spike) by which an answer is needed.

| # | Question | Default to build | Why | Ask by |
|---|---|---|---|---|
| O1 | Product name (crates, binary, file prefixes, headers, trace header) | `doodle-rs` placeholder | Headers and action keys are never renamed once shipped (P19) | first release |
| O2 | Hole spelling: should a bare `todo!()`, `_` (type or pattern) and `cfg(true)` you wrote yourself load as holes? | **Yes**, with the D4 spellings | Same meaning, unchanged text, every file parses. The fallback is `todo!("●")`. | M0 |
| O3 | Line width for new projects: 100 (rustfmt default, smaller font) or 80 (Doodle's font size; writes `rustfmt.toml max_width = 80`)? | **100**; existing projects keep their `rustfmt.toml` | rustfmt-clean projects open unchanged; check readability on the Deck at M1 | M1 |
| O4 | Format with rustfmt on open (in memory; disk changes only on Save)? | **On**, with the status `formatted on open (N lines differ) - not saved yet` | Doodle formats on open (P8); one layout | M3 |
| O5 | Settle gate: hold A/Y up to 150 ms after an edit so menus open type-grayed, or open at once with `checking types...`? | **Gate on, 150 ms**, configurable | Grays in the common case, no frame blocking | M5 |
| O6 | Undo/redo beyond "B restores the step in progress"? | **Yes**: revision snapshots. Undo on LT+Down (a free slot), Redo bindable and unbound. One user step = one undo entry, even when it edits several places (auto-`use`, auto-`mut`, Fix). | Rust repairs edit away from the cursor; snapshots are cheap (D3) | M3 |
| O7 | Unsaved changes when switching files, leaving to the main menu, or quitting | **Ask**: `Save changes to main.rs?  A save   X discard   B stay`. Run saves first, as Doodle does. | Losing edits can't be taken back (P11). Doodle drops them silently (features/00 open question 2). | M10 |
| O8 | Run output on the Deck in Game Mode | **External terminal when one is found, else an in-app Run output overlay** (piped stdout/stderr, d-pad scroll) instead of only `run.log` | Game Mode usually has no terminal | M10 |
| O9 | Per-user files location | **Per-user data dir**, plus portable mode via a `portable` file next to the exe | One home for everything the IDE owns (D15) | M2 |
| O10 | Trust: may opening a project run its build scripts and proc macros? | **Trust IDE-created projects; ask once per other folder** (`A trust   B browse only`) | Doodle never ran code on open | M7 |
| O11 | Network use: crates.io lookup, online `cargo add`, update checks, rustup installs | **Offline-first; each online action behind its own explicit press** | Game Mode may be offline; no surprise traffic | M6 |
| O12 | Cross-file rename and other out-of-file edits | **Add dependency and New module file allowed with a confirmation; rename is open-file only plus an explicit `Also rename N uses in other files`** (D18) | Keeps P12's intent | M6 |
| O13 | Clippy diagnostics | **Off** (a setting) | Noise on beginner code; slower checks on the Deck | M8 |
| O14 | Prewarm the oracle for the most recent project while on the main menu | **Off** (a setting) | About 1 GB of RAM while browsing menus | M11 |
| O15 | North-star programs | **NS0** `cargo new` hello world; **NS1** the Rust Book guessing game (listing 2-6, `rand = "0.10.1"`); **NS2** `handmade-rs` (Handmade Hero days 1 to 4 on `minifb` 0.29.0). Fall back to a `crossterm` program if S5 shows `minifb` can't build on the Deck. | Mirrors Doodle's Handmade Hero yardstick (P2) | M0, after S5 |
| O16 | Platforms | **Windows x64, Linux x64, SteamOS** as release artifacts; **Windows ARM64**: CI build and core tests only, no release artifact; macOS out of scope | The owner's dev machine is `aarch64-pc-windows-msvc` | M0 |
| O17 | Toolchain pin cadence | **Bump the user toolchain and `ra_ap` together** at most every 6 weeks, through the `ra-bump` PR, gated by the conformance suite and the north star | The std tables and the proc-macro ABI follow the pin | M10 |
| O18 | Edition for new projects | **2024** | The Rust Book uses it; edition-aware menus refuse 2024-only forms in older crates | M2 |
| O19 | Refused vs advisory: refuse certain structural errors (`break` outside a loop, a duplicate `use`, `const` + `async`) where Doodle was advisory? | **Yes** (D8: only when syntax or project structure makes them certain) | A pick that can never compile helps nobody | M4 |
| O20 | Assigning to (or `&mut`-borrowing) a binding without `mut` | **Add `mut` automatically, with a status notice; B or Undo reverts both edits** | Prevents E0384/E0596 with no extra presses | M4 |
| O21 | Add-crate catalog: a curated offline list vs live crates.io search | **Curated list (≤ 150, pinned versions) + crates in the local registry cache + dictated lookup when online** | Works offline in Game Mode | M6 |
| O22 | `async` in v1 | **Syntax only** (`async fn`, `.await`, async blocks); runtimes such as `#[tokio::main]` only through Add crate and the trust/proc-macro path | Scope; proc-macro risk | M5 |
| O23 | What the HUD shows on screens with fixed controls (main menu, menus, Files, Run list, Save as, Docs, Settings, Confirm) | **That screen's live controls** (d-pad `move`, A `select`, B `back` / `quit`, plus the IDE-menu slot on the main menu and each overlay's own fixed buttons); every other slot blank and dim (D13) | C11: every screen states its own controls. Doodle drew the editor layout there (features/00 inv 21, HARD as built; open question 7), which shows buttons that do nothing | M0 (the M0 `hud_model_per_bank` snapshot pins the main menu and menus) |

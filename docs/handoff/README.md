# Doodle → Rust handoff

## What this folder is

This folder is everything needed to build a new IDE: a gamepad-driven, projectional IDE **for Rust, written in
Rust**, that keeps the character of Doodle, the owner's Odin IDE. Doodle is driven entirely by a controller. You
never type code. A cursor hops between visible "dots" (typed insertion points and holes) and parts of lines.
A opens a menu of what is valid at that spot. The menus react to the code: the hole's expected type, the names
in scope, imports, sibling files, constness. They gray what can't fit instead of hiding it. A three-bank HUD
always shows what every button does. Names are generated (`brave_otter`) and changed by voice or text tools.
Loaded files round-trip exactly. The new IDE carries those rules over to Rust, whose language is much larger.

The folder holds three things:
- **`features/`**: a verified behavioural spec of Doodle as built (12 docs).
- **`rust/`**: the design of the Rust IDE: architecture, construct taxonomy, and roadmap (3 docs).
- **`PROMPT.md`**: the bootstrap prompt that starts a coding agent on the work.

The working name of the new IDE is `doodle-rs` (owner decision O1 in `rust/01`).

## Who it is for

- **An LLM coding agent** (for example Claude Code) starting in a new, empty Rust repository. It will not have
  the Doodle source. The docs cite Doodle paths such as `src/model/typecheck.odin`. If the agent has network
  access, the public repository <https://github.com/MichJadams/doodle> at commit `34a2ad1` has them, but the
  docs are written to be enough without it.
- **The owner**, who answers the product questions the agent raises (`rust/01` "Owner decisions still open",
  O1-O23) and reviews milestone reports.
- **Human reviewers**, who want to know why the Rust IDE behaves as it does. Every Rust rule cites its Doodle
  precedent.

## How to use PROMPT.md

1. Create an empty Git repository for the new IDE.
2. Copy this whole folder into it as `docs/handoff/`. Keep the path: the prompt and the docs refer to it.
3. Optional: if you have already chosen a product name, replace `doodle-rs` in the prompt.
4. Start a fresh agent session at the repository root, and paste the fenced block of `PROMPT.md` as the first
   message.
5. The agent reads the docs, prints one short message and also saves it as `docs/milestones/M0-kickoff.md`
   (its understanding, its M0 plan, and questions O2, O15, O16 and O23, whether the M0 demo needs a Deck, and
   whether it may push `wip/<milestone>` branches, each with the default it is building), and starts milestone
   M0 in the same turn. Answer when you can. Until you allow pushing, it pushes nothing, and "green in CI"
   means `cargo xtask ci-local` is green on its host.
6. At the end of each milestone, the agent commits `docs/milestones/Mn.md` and reports what it built, what it
   verified, and what it could not verify. Items only you can do (a pad demo, Deck checks) are marked
   `owner pending`. During a milestone it keeps `docs/milestones/Mn-progress.md` current. To resume in a new
   session, say: "Re-read docs/handoff/PROMPT.md, the latest docs/milestones/*-progress.md and the latest
   milestone report, then continue."

The new repository keeps this folder read-only. The agent keeps its own living docs next to it:
- `docs/design/`: living copies of `rust/01`-`03`, plus `CHANGES.md`;
- `docs/features/`: the Rust IDE's own behaviour spec, with the same numbering and skeleton as `features/`;
- `docs/milestones/` and `docs/spikes/`.

## Reading order

For an agent (this is the order `PROMPT.md` gives):

1. This README.
2. `PROMPT.md`.
3. `features/00-principles-and-constraints.md`, in full: the cross-cutting rules P1-P27 and the superseded
   ideas.
4. `rust/01-architecture.md`: Summary, Version facts, decisions D1-D8, D11, D15, D16, Workspace layout, The
   per-frame contract, Owner decisions.
5. `rust/03-roadmap.md`: How to use this doc, Milestones at a glance, Milestone rules, M0, North-star
   acceptance test, Testing strategy, Working conventions.
6. `rust/02-construct-taxonomy.md`: How to read this (rules R1-R18), Hole (dot) vocabulary, then the sections
   each milestone needs.
7. Feature-doc sections per milestone. `PROMPT.md` "Reading plan" has the per-milestone table.

For a human who wants the gist in an hour, read:
- `features/00` "The feel" and P1-P16;
- `features/06` Purpose and Invariants (how menus react to code);
- `rust/01` Summary;
- `rust/02` "Rules every menu follows";
- `rust/03` "Milestones at a glance" and "North-star acceptance test".

## Contents

Sizes are on-disk bytes (KB = 1,000 bytes). At roughly 4 bytes per token, the feature docs come to about 300k
tokens. That is too much to read in one go, so read them by section (see below).

| Doc | What it covers | Size | Lines |
|---|---|---|---|
| `README.md` | This index | 17 KB | 220 |
| `PROMPT.md` | Bootstrap prompt for a fresh coding agent: mission, the 22 non-negotiable constraints, superseded ideas, architecture in brief, open owner decisions with defaults, reading plan, how to work (pushing, resume protocol, offline path), M0 steps and exit criteria | 48 KB | 543 |
| `features/00-principles-and-constraints.md` | The rulebook. 27 principles (rule, how Doodle does it, edge cases, HARD/SOFT, what it prevents, evidence), the superseded ideas not to resurrect, 36 cross-cutting invariants | 109 KB | 496 |
| `features/01-document-model.md` | Lines of fields (fixed text, editable names, dots), dot kinds and colours, the app state machine, menu machinery and grid navigation, loading and saving, formatting, highlighting, generated names | 102 KB | 1171 |
| `features/02-cursor-navigation-editing.md` | Cursor stops, d-pad movement, rows of long lines, RT walks over the syntax tree, Refactor (Grab / Copy line), and what Delete (LT+B), Change (Y), Edit (LT+A) and B do on each kind of part | 102 KB | 1193 |
| `features/03-controller-hud-keymap.md` | Input pipeline, d-pad repeat, the three banks, the complete default binding table, lock-out rules, the HUD, Key Layout page, menu heatmap, settings, sounds, keyboard fallback | 98 KB | 1182 |
| `features/04-file-scope-constructs.md` | The 7-group Add menu: imports, procedures, types, constants, `when`, `#assert`, attributes and modifiers; member dots; composite types | 93 KB | 708 |
| `features/05-statements.md` | The statement menu and every statement form: declarations, assignment, calls with typed argument dots, capture dots, if/switch/for, jumps, error handling, Y options per keyword, loading statements back | 110 KB | 1001 |
| `features/06-type-driven-menus.md` | **The heart**: how every dot carries an expected type, what fits, advisory vs refused grays, the value menu, Reference / Pass as, operators, conversions, the type oracle, constant-only positions, rename | 100 KB | 572 |
| `features/07-language-knowledge.md` | Where menu knowledge comes from: tables generated from the toolchain, the import tree, huge-package grouping, sibling files, the Docs panel (LT+Y), background `odin check` | 97 KB | 1129 |
| `features/08-text-entry-voice.md` | Push-to-talk dictation (local whisper.cpp), vocabulary biasing, spoken numbers, text tools, word-by-word editing, number keypad, rename with propagation, the Save as dialog | 90 KB | 1052 |
| `features/09-projects-files-run.md` | Main menu, projects and where they live, Save / Save as, the Files grid, Run list and run pipeline, toolchain Setup with no root (Steam Deck), self-update, persistence files | 106 KB | 1165 |
| `features/10-rendering-and-feel.md` | Window and frame loop, renderer, fonts, the paper palette, dots, highlighting, compiler problems, HUD and menu drawing, worn cells, icons, sounds | 106 KB | 1197 |
| `features/11-engineering-practices.md` | Pure model and thin app, synthetic-input tests, acceptance tests with real programs, trace / replay / verify, generated tables, build, CI and release, Deck packaging, how a feature lands | 127 KB | 1488 |
| `rust/01-architecture.md` | **Mechanism**: crates and their dependency DAG, the pure core with requests and events, text-as-truth document, hole spellings, layout and rustfmt, the rust-analyzer oracle process, determinism with async facts, the three gray kinds, persistence, trace, setup and trust, CI, Deck budgets, spikes S1-S13, owner decisions O1-O23, the ActionInfo table | 139 KB | 1791 |
| `rust/02-construct-taxonomy.md` | **Behaviour for Rust**: rules R1-R18, the hole vocabulary, the Odin→Rust mapping, every menu (Add, impl/trait, statements, values, types, generics, patterns, arms) with exact labels, inserted text, gray rules and reasons, part actions, names, borrow-error repairs, deferred features | 215 KB | 2507 |
| `rust/03-roadmap.md` | **Order and acceptance**: milestones M0-M11 with exit tests by name, the spike track, the north-star programs NS0-NS2 (full reference text), the risk register, testing strategy, definition of done, working conventions | 113 KB | 1621 |

Totals: `features/` 1,241,394 bytes; `rust/` 466,835 bytes.

## How the docs relate

- **Precedence.** `rust/01` owns mechanism. `rust/02` owns Rust behaviour, and `features/` covers whatever
  `rust/02` doesn't. `rust/03` owns order and acceptance. The principles of `features/00` hold everywhere
  unless a Rust doc departs from them explicitly. When two Rust docs contradict each other, that is a doc bug
  to report to the owner.
- **Doodle's known gaps.** The feature docs describe Doodle *as built*, bugs included. Each lists them under
  "Open questions & known gaps". The Rust docs say which ones the Rust IDE fixes; search them for
  `fixes features/`.
- **Citation forms used across the docs:**

  | Form | Meaning |
  |---|---|
  | `P7` | principle 7 of `features/00` |
  | `features/06 F15`, `features/05 §10` | a feature section of a feature doc |
  | `inv 3` | invariant 3 of the cited doc |
  | `D7` | decision 7 of `rust/01` |
  | `O5` | owner decision 5 of `rust/01` |
  | `S1` | spike 1 of `rust/01` |
  | `R3` | rule 3 of `rust/02`, or risk 3 when cited inside `rust/03` |
  | `NS0`-`NS2` | the north-star programs in `rust/03` |

- **Draft numbers.** `rust/03` cites `rust/02` by draft section numbers (`rust/02 §5.3`), and `rust/02`'s
  headings are not numbered. Match by the title or topic. `PROMPT.md` has a mapping table.

## How the feature docs are structured

Every feature doc (`01`-`11`) uses the same template:

1. A header line, `> Odin sources: ...`, listing the Doodle files read for the doc.
2. `## Purpose`: what the area is for and why a gamepad IDE needs it.
3. `## Features`: numbered `§1`, `§2`, ... in docs 01, 02, 04, 05, 07 and 11, and `F1`, `F2`, ... in docs
   03, 06, 08, 09 and 10. Each feature has four bullets:
   - **Trigger**: which button, dot or menu starts it;
   - **Behavior**: what happens, with exact UI strings in backticks;
   - **Rules & edge cases**;
   - **Source**: the Doodle functions that implement it.
4. `## Invariants & constraints to carry forward`: numbered rules, each marked HARD (code enforces it or tests
   pin it) or SOFT (convention or taste).
5. `## Data model & formats`: the structures and file formats.
6. `## Tests that pin this behavior`: the Doodle tests and what they assert.
7. `## Carrying this to Rust`: (a) what transfers unchanged, (b) Odin-specific pieces and their Rust analogs,
   (c) Rust concepts Odin lacks and how the area extends to them, (d) implementation advice. Some docs make
   these headings, others bold paragraphs.
8. `## Open questions & known gaps`: bugs, doc drift, and undecided points.

`features/00` is different. It holds the principles P1-P27, each with **Rule / In Doodle / Edge cases /
Strength / Prevents / Evidence**, then "Superseded ideas: do not resurrect", then the same closing sections.

To read a doc by section:

```sh
grep -n '^##' docs/handoff/features/06-type-driven-menus.md                    # outline
awk '/^## Invariants/,/^## Data model/' docs/handoff/features/06-type-driven-menus.md
awk '/^## Carrying this to Rust/,/^## Open questions/' docs/handoff/features/06-type-driven-menus.md
```

Conventions inside the docs:
- `●` is a required dot or hole, `○` an optional dot that is never saved, `◉` the pink capture dot, and `⊙`
  (Rust) the purple item-options dot. `●T` is a hole that expects type `T`.
- Text in backticks that a user sees (labels, titles, hints, reasons) is exact.
- **verify** (Rust docs) marks a version-sensitive claim that must be re-checked against the version you pin.

## How the docs were produced and verified

- **Baseline.** Everything in `features/` describes Doodle at commit `34a2ad1` (2026-11-24). That is the full
  history to that date: 91 commits from 2026-11-17 to 2026-11-24.
- **Extraction.** Per-area agents, one area per doc, read the Odin source, the tests, Doodle's own docs
  (`README.md`, `ARCHITECTURE.md`, `docs/*.md`) and the git history, and wrote the docs. Where Doodle's older
  design docs and the code disagree, **the code wins**, and the difference is called out (for example
  `features/00` "Doc vs code" notes and open question 12).
- **Fact-check.** Each doc was then fact-checked against the source.
- **Completeness pass.** A final pass looked for behaviour that no doc covered.
- **Markers:**
  - `(probe)` / `probe: ...`: the claim was confirmed by a throwaway test run against Doodle's code. The
    probes were not kept, and they are not among the "Tests that pin this behavior". Most are in docs 02, 04,
    05 and 06.
  - `(unverified)` / `unverified`: the claim could not be confirmed (for example Whisper prompt truncation,
    Steam on-screen keyboard events, Deck compositor scaling).
  - "from code reading" / "inferred": the behaviour was read from the code but not run.
  - Every other claim was checked by reading the source.
- **Rust docs.**
  - `rust/01` merges three independent design proposals, and records each disagreement with its decision and
    reason. `rust/02` merges the taxonomy proposal with `rust/01`'s decisions and the borrow-repair layers of
    the risk proposal.
  - Version-sensitive facts (Rust 1.100.0 stable, the `ra_ap_*` publishing state and pin `=0.0.358`, crate
    versions) were checked on 2026-11-24. Language rules quoted with error codes were checked against rustc
    1.96.1 (edition 2024) and rustfmt 1.9.0.
  - `rust/03`'s north-star references were checked. NS1 is byte-identical to the Rust Book listing 2-6, with
    its sha256 given. NS2 is rustfmt-clean and clippy-clean and passes its test, built against a stub carrying
    minifb 0.29.0's documented signatures.
  - Anything not checked is marked **verify**.

## Known limits

1. **Some behaviour was read, not run.** Several claims come from reading the code, not from running the app.
   Examples: the HUD keeping the editor layout under overlays, LT+B quitting from the main menu, Steam keyboard
   events, Deck scaling. They are marked "from code reading", "unverified" or "inferred".
2. **The probes were throwaway.** Their results are written into the docs, but the probe code was not kept.
3. **The docs describe Doodle as built, bugs included.** Don't treat a described bug as a requirement. Check
   the doc's "Open questions & known gaps" and whether the Rust docs fix it.
4. **Source paths point into Doodle.** The new repository won't contain them. The public repository at
   `34a2ad1` does.
5. **The screenshots are stale and not included.** Doodle's `docs/screenshots/` predate several changes
   (`features/00` "The feel", open question 17). The text descriptions in `features/00` and `features/10` are
   current.
6. **The Rust design is a plan, not a measurement.** Spikes S1-S13 have not been run. Every risky decision
   names a fallback and the trigger for it. Deck budgets are targets until measured on a device.
7. **Versions move.** The `ra_ap_*` crates publish weekly and break APIs; `sdl3` is pre-1.0. Re-check every pin
   at M0 and at every bump. Facts dated 2026-11-24 are only true as of that date.
8. **Rust language rules were checked on rustc 1.96.1, not the pinned 1.100.0.** The compile-matrix tests
   re-check them on the pinned toolchain.
9. **Size.** About 1.77 MB in total. No agent should read it all at once. The per-milestone reading plan in
   `PROMPT.md` names the sections each milestone needs.
10. **Odin-only subsystems are documented for completeness.** Examples: vendor DLL checks, stb libraries,
    `when`, `#unroll`. `rust/01` "How each Doodle subsystem maps" and `rust/02` "Odin -> Rust mapping" say what
    replaces each one, or that nothing does.

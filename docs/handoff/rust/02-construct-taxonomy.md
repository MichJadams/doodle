# 02 — Rust construct taxonomy: dots, menus, and how they react to the code

> **Status.** Authoritative for *behaviour*: which dot appears where, what each menu offers in what order, the
> exact text each leaf inserts, what grays and why, and what Y / LT+A / LT+B / B do on every part. For
> *mechanism* (crates, oracle protocol, revisions, persistence, layout engine, trace) `01-architecture.md` wins,
> and this doc cites its decisions as `D1`..`D20` and its owner defaults as `O1`..`O23`. This doc merges the
> taxonomy proposal (proposal A) with the decisions of `01`, and the risk proposal's borrow-repair layers
> (proposal C, R5). Where a proposal and `01` disagreed, `01` was followed: hole display (D4), the three gray
> kinds (D8), auto-`mut` instead of a gray (O20), refusals for structural errors (O19), the curated crate
> catalog (O21), and only three out-of-file edits (D18).
>
> **Baseline facts** (from `01`, checked 2026-11-24): user toolchain Rust `1.100.0`, edition `2024` for new
> projects (O18), every `ra_ap_*` crate pinned at `=0.0.358`. Language rules quoted with an error code were
> checked by proposal A against `rustc 1.96.1` (edition 2024) and `rustfmt 1.9.0`; re-run them against the
> pinned toolchain in the compile-matrix test (§"Tests that pin this taxonomy"). rust-analyzer assist ids named
> below were checked against the rust-analyzer book's assist list on 2026-11-24; they are cited only as the
> *shape* our own builders produce (the oracle protocol in D6 has no assist query). Anything marked
> **verify** must be checked at the version you pin.

---

## How to read this

### Relation to the Odin feature docs

The feature docs `../features/00` to `11` describe Doodle, the Odin IDE, as built. This doc is the Rust IDE's
equivalent of `features/04` (file scope), `features/05` (statements) and `features/06` (type-driven menus), plus
the dot vocabulary of `features/01 §2` and the Y / LT+A / LT+B / B tables of `features/02 §17-§20`. Every leaf
cites its Doodle precedent (`features/05 §15`, `features/06 F16`). The principles of `features/00` (P1..P27)
hold unchanged; where Doodle has a known gap (an "Open questions" item), this doc says how the Rust IDE closes
it.

Citation forms: `P6` = principle 6 of `features/00`. `features/04 §9` = feature 9 of doc 04. `features/06 F4`
= feature F4 of doc 06. `D8` = decision 8 of `01-architecture.md`. `O20` = owner default 20 of `01`. `R7` =
rule 7 of this doc (below).

### Notation

| Mark | Meaning |
|---|---|
| `●` | a required hole (a field of role `Hole(..)`; D3, D4). Saved as its neutral token (§"Hole vocabulary"). |
| `●T` | a hole whose expected type is `T`. The UI draws `T` as the small gray label after the dot (`features/06 F3`). In examples `●i32`, `●&str`, `●bool`. |
| `●pat` | a pattern hole. Drawn as `_` in pattern teal with a ring (D4), because it is already a valid wildcard. |
| `●ret` | the return-type hole of a fn header: zero width, after `)`. Saved as nothing (no `->`). |
| `●cfg` | a cfg-predicate hole. Saved as `true`. |
| `○` | an optional list dot (a zero-width `Virtual` field, D3). Never saved. Which list it extends is named in the row (`○args`, `○params`, `○rest`, ...). |
| `◉` | the pink capture dot in front of a bare call statement (`features/05 §9`). |
| `⊙` | the purple item-options dot above an item (generalises Doodle's attribute dot, `features/04 §30`). |
| a line holding only `●` | the editor-only statement row of an empty block (`VirtualDot::StmtRow`; `features/05 §1`). |
| green dot | an insertion dot between lines (`VirtualDot::Insert(..)`). Not a field; never saved. |
| `brave_otter`, `BraveOtter`, `BRAVE_OTTER` | generated names (P5). Examples use the first counter values for readability; real values come from the shared counter. |
| `"…"` | an empty string literal whose text leaf is ready for dictation (`""` in the file). |
| `gray: <reason>` | **advisory** gray (D8): the entry still applies when picked. `gray: <reason>; fix: <fix>` means picking opens the two-entry fix menu (R3). |
| `refused: <reason>` | **refused** gray (D8): picking does nothing, the menu stays open, the reason line turns to the warning colour, no heat. |
| `hidden: <when>` | not listed at all in that case (D8 "Hidden"). |
| `[ctx]` | a context entry: present only where its context exists (D8), grayed rather than hidden inside that context. |
| `▸` | opens a submenu. |
| `→` | "becomes". |

All labels, titles, banners, hints and reason strings in backticks are **exact** user-facing text (P21). Reason
strings start lowercase, have no trailing period, and name the next step when there is one. Three spaces
separate a label from its type annotation, as in Doodle (`len()   usize`, `features/06 F3`).

### How a leaf row reads

Menu tables use these columns:

| Column | Content |
|---|---|
| Leaf | the exact label |
| Inserts | the exact default text with its holes and their expected types; the *saved* text of an untouched insert is given where it matters |
| Gray / refuse / hide | each rule with its kind and exact reason text; "Evidence" is syntax, index, metadata, knowledge (embedded tables), oracle or diagnostics |
| Cursor | where the cursor lands after the pick (R15) |
| Doodle | the precedent in the feature docs, or `new` |

### Rules every menu follows

These rules are referenced as R1..R18 from every table below. Each keeps a Doodle principle and states what Rust
adds.

**R1. Location decides the menu (P6, `features/06 F1`).** A on a dot opens the menu for exactly that place.
The dispatch is by CST `Location` (D3 "Core module map": `core::menu::open` + `CONSTRUCTS`):

| A / Y on | Opens | Section |
|---|---|---|
| green dot at module scope (file top level, inside an inline `mod m { }`) | `Add  (insertion point)` | File-scope Add menu |
| green dot or `●` row inside a code block | `Fill slot` (statements) | Statement menu |
| green dot in an `impl` / `trait` body | `Fill slot` (associated items) | Inside impl / trait blocks |
| green dot in a struct / enum / union body | `Fill slot` (members) | Inside impl / trait blocks, other item bodies |
| green dot in an `unsafe extern "C" { }` body | `Fill slot` (foreign items) | same |
| green dot between `match` arms | `Fill slot` (arms) | Patterns |
| value or tail hole | `Fill slot` (values) | Value menu |
| type or `ret` hole | `Fill slot` (types) | Type menu |
| pattern hole | `Fill slot` (patterns) | Patterns |
| cfg hole | `Fill slot` (cfg predicates) | Type menu ..., cfg predicates |
| a list dot `○` | that list's "add" menu | per row |
| `⊙` | `<kind> <name>` item options | File-scope Add menu, Item options |
| `◉` | no menu: captures at once | Statement menu, Calls |

**R2. Fit is three-valued, and only certainty grays (P7, D7.6, D8).** `Fit { Yes, No { why }, Unknown }`.
`Fit::No` is allowed only when the expected type and the candidate's type are both fully known (no inference
variables, no unresolved generic parameters) and every check failed (`could_coerce_to`, then `could_unify_with`,
then `impls_trait`; D8). `Unknown`, `Pending`, `Cancelled`, `Failed`, "oracle loading" and "oracle down" all
mean lit. A hole with no expectation grays nothing. Every gray records its evidence (`Syntax`, `Index`,
`Metadata`, `Knowledge`, `Oracle`, `Diagnostics`; D8); with Unknown facts no `Oracle`- or
`Diagnostics`-evidenced gray may appear (D7.6). The only *type-fit* grays allowed before facts arrive are
**syntax-stamped**: a hole whose expectation is a primitive keyword type written right there (`let x: u32 = ●`,
an `if` / `while` condition is `bool`, a call argument whose parameter is written `: bool` / `: u32` / `: &str`
in a signature the knowledge layer holds) may advisory-gray *literal-kind* mismatches only (D8). Grays that
need no facts at all keep their place before facts arrive: `Mutable static (unsafe)`, `Run at scope end` without
`scopeguard`, `Use everything (glob)` over a big module, `Extern crate` for a Cargo dependency, a macro defined
below the dot, `Try a call (?)` in a fn whose declared return is `()`, a cfg feature not in `Cargo.toml`.

**R3. Three kinds of gray, every one with a reason (D8, O19).**

| Kind | When | Picking it | Evidence allowed |
|---|---|---|---|
| hidden | can never apply to this *kind* of place, item or target (`#[inline]` on a struct; `pub` on a trait-impl item; an ABI of another target; `str` by value) | not listed | syntax, target, knowledge; plus D8's one exception: the type-conditional adapters of `Pass as` / `Assign to` / `Unwrap ▸` / `View ▸` are hidden by the picked value's *known* type category (Doodle hid `Field of` and indexing the same way, `features/06 F16-F17`); Unknown shows them; decided at open and frozen |
| refused | certain and structural, **and** no *additive* one-step edit in the open file makes it valid (`break` outside a loop, a duplicate `use`, `const` + `async`, a let chain in an edition-2021 crate) | nothing happens; the menu stays open; the reason line turns to the warning colour; no heat | the open file's syntax, plus certain project structure: edition, crate roots and targets (metadata), the file listing (index). Never types, borrow analysis or diagnostics. |
| advisory | everything else that is gray: type fit, moves, non-const calls in const contexts, `?` in a fn that returns `()` | applies. If a fix exists, picking opens a two-entry menu, title `Doesn't fit here`: `Fix it: <fix>` / `Insert anyway`. B goes back to the menu. Heat is recorded. | oracle, diagnostics, local analysis |

"Additive" means the fix only adds or widens (adds `mut`, `async`, a derive, a `use`, wraps the return type in
`Result`). When the only fix would undo something the user built (remove `async` to allow `#[test]`), the
entry is refused instead and the reason names that step. The reason of the highlighted gray cell is shown under
the grid, where Doodle shows a truncated label (`features/03 F12`), like the Key Layout page does (P6). A group
is gray iff no leaf in it is lit; placeholders never count as lit (`features/06` inv 3). An empty group explains
itself with a dim placeholder leaf that does nothing (`(no struct types in scope)`; `features/00` inv 16).

For LT+B there is no fix menu (a delete is one press), so the split is simpler: a delete whose result is
certainly invalid on syntax evidence is refused, does nothing, and the status line shows the reason, which names
the step that makes the delete possible (`every field is needed here (E0063): add ..Default::default() with the
○ dot first`); a delete whose consequences depend on facts is advisory: it happens, and the status line says the
consequence (`T was used in 3 places: the check will show them`). Undo (O6) reverts it.

**R4. Menus are frozen under the thumb (D7.3, D7.5).** The entries, their order and their grays are fixed when
a menu level opens. An oracle answer that arrives later changes only menus opened later, labels on dots, and a
list that is still showing its `(looking up …)` placeholder (`Methods of x`, a dependency's items), which fills
in place with the highlight on index 0. Pinned sections (`FIX`, `SUGGESTED`, `RECENTLY USED`) are computed at
open from the facts present then and never grow afterwards.

**R5. Text from a pick uses only the facts present at the pick (D7.3).** Generated match arms, pattern
defaults that follow a value, closure parameters pre-filled from an expected `Fn` arity, auto-`mut`, auto-`use`,
the unsafe auto-wrap and added tail holes are computed in the frame of the user's pick, from the facts present
in that frame, and go into the same `Template` (D3.4). A later pick that refills or extends the value re-derives
them in its own `Template` while they are still untouched (§"Pattern defaults follow the value", §"Match arms").
An answer that arrives later never adds arms or edits a pattern; Y on the construct offers the same edit on
demand (`Add missing arms`). Derived virtual dots that
depend on facts (the capture dot, a `○args` dot whose existence depends on the callee) are recomputed in
`after_input` only on frames that carry a pad edge, so an answer alone never adds or removes a cursor stop.

**R6. Roots stay at 12 or fewer entries, in authored order (P23, `features/05 §2`).** Doodle sorts any list
over 12 non-pinned entries alphabetically (`features/01 §7`). Every root menu here is designed to stay at 12
or fewer *including* its context entries, so the authored order (most useful first) is what the user sees and
learns. Pinned sections (`FIX`, `SUGGESTED`, `RECENTLY USED`) sit above and are not counted. Long leaf lists
(crates, std items, methods, lints) use `doodle_knowledge::group` (`features/07 §6`: flat up to 60, then by
module / impl block / shared prefix, then alphabetical buckets of 12). Heat keys are canonical paths and
construct ids (D15), so trails are identical in every project; a pinned leaf wears the trail of its canonical
home (`Literal > Integer`), never of its pinned section.

**R7. Pinned sections.** Above the grid, in this order, each only when non-empty:

1. `FIX` (≤ 4 cells): Y on a part that a current diagnostic touches gets the diagnostic's suggestions first
   (D10; §"Errors the user can't type their way out of").
2. `SUGGESTED` (≤ 6 cells) on value, type and pattern holes:
   1. the canonical value for the expected type (`0` for integers, `0.0` for floats, `""` for `&str`,
      `String::new()` for `String`, `None` for `Option<_>`, `Vec::new()` for `Vec<_>`, `false` and `true` for
      `bool`, `Default::default()` when `accepts.default` and nothing more specific exists);
   2. up to 4 results of `Oracle::suggestions(at)` (term search, bounded fuel; `ra_ap_hir::term_search::term_search`
      exists at 0.0.358, **verify** its arguments at the pin), sorted by fewest nodes, then file order of the
      names used, then text, deduplicated;
   3. on a type hole, the compiler's E0121 `suggested_replacement` from the last check (D4).
   Without facts, only item 1 from a syntax-stamped hint shows.
3. `RECENTLY USED`: items already used in this file (real use sites from the CST, matched by canonical path;
   fixes `features/06` gap 3), plus imports used this session (`features/04 §6`).

**R8. Completeness constructs are inserted complete (new).** Odin lets you leave struct-literal fields and
enum cases out; Rust does not. These leaves insert every required part at once, each as a hole:

| Construct | Inserted | Rust rule |
|---|---|---|
| struct literal `T { … }` | one `field: ●Type` per visible field, in declaration order, plus a `○rest` dot | E0063 missing field |
| trait impl | every required item, with default bodies whose tails are holes | E0046 |
| `match` on a known enum, `Option`, `Result`, `bool` | one arm per variant | E0004 |
| enum-variant constructor, fn call | one hole per field / parameter (Rust has no default arguments) | E0061 |
| union | one field | "unions cannot have zero fields" |

**R9. The layout engine owns punctuation (D5).** The user never manages `;`, `,`, `::`, `->`, `<>`, `{}` or
parentheses. Builders emit text; `doodle_syntax::layout` writes rustfmt's default style for the edited layout
root. Rules the builders rely on:
- `;` after every non-block-like expression statement, `let`, item `const` / `static` / `type` / `use` / `mod x`;
  none after block-like statements (`if`, `match`, `loop`, `while`, `for`, `{}`, `unsafe {}`).
- Parentheses are added exactly where precedence needs them when a hole is filled with a lower-precedence
  expression (`(x as i32 + x_offset) as u8`), and removed when a refill makes them redundant. Parentheses are
  never stops.
- Qualifiers are written in the canonical order `pub const async unsafe extern "C" fn`.
- A struct-literal field whose value is a same-named binding is written in shorthand (`width` rather than
  `width: width`, clippy `redundant_field_names`); Y on the field toggles it.
- `use` lines: a new path merges into an existing `use` line only when both have the **same parent module**
  (`use minifb::{Key, Window};`), never at a shorter shared prefix (so `use std::cmp::Ordering;` and
  `use std::io;` stay separate lines, as in NS1). The `use` block has groups std/core/alloc, then external
  crates, then `crate`/`super`/`self`, separated by one blank line, each sorted as rustfmt's `reorder_imports`
  sorts.

**R10. Blocks have values: the tail slot (new).** Every block whose value is used (a fn body with a return
type, a block expression, a closure block body, a match-arm block in value position, a labeled block, each
branch of an `if` used as a value) ends in a tail. An editor-created block whose value is used gets a **tail
hole** `●T` (expects the block's type), saved as `todo!()` (D4). Loaded code without a tail shows an optional
tail dot `○tail` (`VirtualDot::OptionalTail`) when the block ends in a diverging statement (`return x;`). No
green dot is offered after a tail (a statement there would turn the tail into a statement); the green dot
above the tail inserts before it. When a fn's return type goes back to `()`, an unfilled tail hole goes with
it; a filled one stays and the check reports the mismatch.

**R11. Auto-`use`, and how paths are written (new; `features/04 §29` precedent).** Picking an item that is not
in scope adds what makes it reachable, in the same `Template` (D3.4 `extra`), with the status
`added use std::collections::HashMap` (P21):
- types, traits, macros and enums are imported by name, then written bare (`use minifb::Window;` then `Window`);
- free functions are reached through their parent module (`use std::io;` then `io::stdin()`); a crate root
  needs no `use` (`rand::rng()`), because crate names are in the extern prelude;
- enum variants are written `Enum::Variant`, with the enum imported (`Ordering::Less`);
- items named `Error` or `Result`, and any name that would clash with a name in scope or in the prelude, are
  written through their parent module (`minifb::Error`, `io::Result<()>`, `fmt::Result`);
- a trait method picked from `Methods of x > Needs a use` imports the trait.

Y on a path's first segment offers `Path style ▸` to switch one occurrence between the three spellings
(`io::stdin` with `use std::io;`, `std::io::stdin` with no `use`, `stdin` with `use std::io::stdin;`). A name
clash with an existing import is handled by the `Use as…` alias (`FmtResult`). Nothing is ever removed
automatically: an import that becomes unused is drawn faded with the reason `not used`, and LT+B removes it
(P17).

**R12. Auto-`mut` (O20).** Assigning to, `&mut`-borrowing, or calling a `&mut self` method on a binding that
lacks `mut` adds `mut` to its `let`, parameter or pattern binding in the same step, with the status
`made count mutable (line 8)`. B (while the step is open) or Undo (after) reverts both edits (R17). Where `mut`
cannot be added (a `&T` reference, `self` in a `&self` method, a `static`), the choice is an advisory gray with
the reason and, when one exists, an additive fix (`Change the receiver to &mut self`).

**R13. Unsafe auto-wrap (new).** Inserting anything that needs `unsafe` (a call to an `unsafe fn` or a foreign
fn, a raw-pointer dereference, a `static mut` access, a union field read) outside an `unsafe` block wraps it at
the smallest sensible scope in the same step: a statement becomes `unsafe {` / statement / `}`; a value in a
`let` becomes `let x = unsafe { f(●) };`. In edition 2024 this applies inside `unsafe fn` bodies too
(`unsafe_op_in_unsafe_fn` warns there). Status: `wrapped in unsafe { }`. Whether a callee is unsafe comes from
the knowledge layers (std tables, the crate index, dependency items), so the wrap needs no oracle answer.

**R14. Edits stay in the open file, except three named, confirmed ones (P12, D18).** (1) Add crate runs
`cargo add` after `Add serde 1.0 to Cargo.toml?   A add   B cancel`. (2) Module (new file) creates the file
after `Create src/brave_otter.rs and add mod brave_otter here?   A create   B cancel`. (3) Rename offers
`Also rename M uses in other files (src/app.rs, src/ui.rs)` as its own entry. Every other fix that would need
another file says where instead (`Point is in src/geometry.rs`).

**R15. Where the cursor goes after an insert (`features/05` inv 15).** On the new **name** for every declaring
leaf (file scope included; Doodle leaves it on the green dot after a file-scope insert, `features/04 §1`,
changed here for consistency; open question 3); on the first hole for `if`, `match`, calls, `return`; on the
target after an Assignment pick; on the comment text; on the line itself when it has no name or hole
(`loop {`, `{`, `break;`). Leaves that open a pick or a menu at once (Trait impl, Use, the lint picker) leave
the cursor where that pick lands.

**R16. Edition awareness.** The document's edition (D3 `FileMeta`) is structural evidence (R3). Edition 2024
forms are written everywhere they are accepted: `unsafe extern "C" { }` and `#[unsafe(no_mangle)]` (both
accepted in every edition since Rust 1.82, required in 2024). Let chains (`if let … && …`) are refused in
older editions: `let chains need edition 2024`.

**R17. One user step = one undo entry; B restores the step in progress (P9, O6).** A step's extra edits
(auto-`use`, auto-`mut`, unsafe wrap, generated arms, a fix) belong to it. B before the step completes restores
the snapshot taken when it began (`MenuPurpose { Insert, Fill, Refill, Options, DeclareAs, Pick }` in `01`).
Undo is LT+Down (O6); Redo is bindable and unbound.

**R18. Types inserted into code are spelled as this file would write them (`features/06` inv 15).** The label
on a hole and the `expects T` subtitle use `TyFacts.shown` (`display_source_code` in the open module, D8).
Types inserted as text follow R11's path rules.

---

## Hole (dot) vocabulary

Doodle's colour vocabulary (P3, `features/01 §2`) is kept. Rust adds the teal pattern hole, the tail hole, the
cfg hole and several list dots. Kinds use the enum names of `01` (`doodle_syntax::HoleKind`,
`doodle_syntax::VirtualDot`) so the projection, the loader and the menus agree by construction (D3.5).

### Holes (`Role::Hole(HoleKind)`: they have bytes in the file, except `Ret`, which is zero-width after `)`)

Holes inside the arguments of a macro in the knowledge macro table (`println!("{}", ●)`, `vec![●; ●]`,
`assert_eq!(●, ●)`, `cfg!(●cfg)`) follow the same rules, and so do the holes and stops inside the structured
attributes (`#[cfg(●cfg)]`, each derive of `#[derive(…)]`, each lint of `#[allow(…)]`): the projection
sub-parses those token trees (D3.9), so they save and reload as the same holes and stops. Inside any other
macro, the whole call is one `Opaque` unit.

| Kind | Colour | Where it appears | A (and Y) opens | Saved when unfilled | Reloads as a hole when the loader sees |
|---|---|---|---|---|---|
| `Value` | orange (1.00, 0.60, 0.15) | every expression position the menus create: `let` initializer, argument, operand, struct-literal field, condition, scrutinee, index, `return` value, array / `vec!` element, `break` value, closure body, arm body | Value menu, with the hole's expectation | `todo!()` (no arguments) | a bare `todo!()` macro call in expression position whose path is `todo`, `std::todo` or `core::todo`, when the file defines no `macro_rules! todo` (D4). `todo!("msg")`, `unimplemented!()`, `unreachable!()` stay ordinary values. |
| `Tail` | orange | last line of a block whose value is used (R10) | Value menu (expects the block's type) | `todo!()` | a `todo!()` in tail position |
| `Type` | blue (0.35, 0.70, 1.00) | `let` annotation, parameter type, field type, alias right side, generic argument, `impl ● {` self type, const / static type, array element, `&●`, cast target `as ●`, turbofish `::<●>` | Type menu | `_` | an `InferType` node |
| `Ret` | blue | after `)` of every fn, method and block-bodied closure header that has no `->` | Type menu (title subtitle `the result type`) | nothing (no `->`) | a fn without a `RetType` |
| `Pattern` | teal (0.10, 0.62, 0.60), drawn as `_` with a ring | `match` arm pattern, `if let` / `while let` / `let … else` pattern, sub-patterns (`Some(●)`, `(●, ●)`, `T { a: ● }`), `for ● in`, destructuring parameters | Pattern menu | `_` | a `WildcardPat` |
| `Cfg` | neutral orange (0.95, 0.55, 0.20), label `cfg` | `#[cfg(●)]`, `#![cfg(●)]`, `cfg!(●)`, the arguments of `not(●)`, `all(●, ○)`, `any(●, ○)` | Cfg predicate menu | `true` | a cfg predicate that is exactly `true` (`#[cfg(true)]` compiles since Rust 1.88; **verify** on the pinned toolchain) |

What compiles while unfilled (D4, pinned by the compile matrix):

| Unfilled hole | Compiles? |
|---|---|
| value at a coercion site (`let` with a type, argument, struct-literal field, tuple / array / `vec!` element, `return`, tail, condition, scrutinee, macro argument) | yes, with `unreachable_code` warnings, which are hidden while the hole is unfilled |
| value at a non-coercion site (operand of `+ - * / % == < …`, unary `-`, method receiver, field base, index, `?` operand, `&` operand, `for` iterable) | no (E0277 "cannot add `!` to `i32`", E0599, E0609, E0600, "`!` is not an iterator"); honest, as P4 is |
| value in a const context (`const` / `static` initializer, array length, const generic argument, enum discriminant, `const { }`) | no (E0080 "evaluation panicked: not yet implemented", even for an unused private const) |
| value in an untyped `let x = ●;` | yes, until a later line needs `x`'s type (E0282) |
| type in an inference position (`let` annotation, closure parameter, turbofish, generic argument inside an expression, `[T; _]` in a `let`) | yes |
| type in an item signature (parameter, field, const / static type, alias, impl self type) | no (E0121), but the file parses and rustfmt keeps it |
| return type | yes (`()`) |
| pattern | yes (wildcard) |
| cfg predicate | yes |

### Virtual dots (`Role::Virtual(VirtualDot)`: zero width, never saved; D3.3)

| Kind | Colour | Where it appears | A opens | Saved | Re-derived on load from |
|---|---|---|---|---|---|
| `Insert(Module)` | quiet green (0.15, 0.60, 0.32); the focused one larger and pulsing | between items at module scope: file top level and inside an inline `mod m { }` | Add menu | nothing | item boundaries |
| `Insert(Block)` | green | between statements in any code block (fn body, `if` / `else` / loop / `unsafe` / labeled / `async` block, block closure body, block arm body), never after a tail | Statement menu (temporary-line protocol) | nothing | statement boundaries |
| `Insert(AssocItems)` | green | between items of an `impl` or `trait` body | associated-item menu | nothing | item boundaries |
| `Insert(Members)` | green | between fields of a named-field struct or union, between variants of an enum (one dot on an editor-only row when the body is empty: `struct BraveOtter {}` draws as `struct BraveOtter {` / dot / `}`, the D3.3 split) | member menu | nothing | field / variant boundaries |
| `Insert(Arms)` | green | between `match x {` and the first arm, between arms, before the closing `}` | Arm menu | nothing | arm boundaries |
| `Insert(ForeignItems)` | green | between items of an `unsafe extern "C" { }` block (Doodle had none; `features/04` open question 10) | foreign-item menu | nothing | item boundaries |
| `StmtRow` | green, a row holding only `●` | the only row of an empty code block (`{}` in the file, `{` / `●` / `}` on screen: D3.3's sanctioned visual-only split; only the `{` row has a gutter number, the `}` row is a continuation of the same saved line) | Statement menu | nothing (`{}`) | an empty block |
| `ItemOptions` (`⊙`) | purple (0.55, 0.22, 0.88), 14 px right of the item's first column | above every item and associated item, above its attribute and doc lines; the d-pad stops on it between the green dot and the item | `<kind> <name>` item options | nothing | every item |
| `Capture` (`◉`) | pink (0.93, 0.27, 0.60), steady, smaller | in front of a bare call statement whose result is known not to be `()` or `!` (R5) | no menu: `◉ v.len();` → `let brave_otter = v.len();` | nothing | bare call statements |
| `Params` | violet (0.80, 0.45, 0.95) | end of a fn, method or closure parameter list | `Add parameter` (+ receivers in methods) | nothing | parameter lists |
| `Generics` | violet, small | end of a `<…>` generic parameter list once it exists | Generic parameter menu | nothing | generic lists |
| `Bounds` | violet, small | end of a non-empty bound list: `T: Clone + ○`, `'a: ○`, `impl Display + ○` | Bound menu | nothing | bound lists |
| `Where` | violet, small | end of a `where` clause once it exists | `Add predicate` | nothing | where clauses |
| `Args` | small bright green, label `..T` | end of a variadic macro's arguments: `vec![●i32, ○]`, `println!("{} {}", ●, ●)` has none (placeholders own the arguments) | Value menu (expects the element type) | nothing | macro calls known to the macro table |
| `Fields` | small bright green | end of a tuple-struct declaration `struct S(i32, ○);`, a tuple variant `V(●, ○)`, a tuple expression or pattern whose arity the expectation does not fix | Type menu (declarations), Value menu (expressions), Pattern menu (patterns) | nothing | tuple lists |
| `Rest` | small bright green | after the last field of a struct literal or struct / tuple / slice pattern | `..Default::default()` / `..other` (literal); `..` (pattern) | nothing | struct literals and patterns without a rest |
| `Group` | small bright green | inside a `use` group: `use std::{fs, io, ○};` | Use tree at that prefix | nothing | `use` groups |
| `OptionalTail` (`○tail`) | small hollow orange ring | end of a value block that has no tail and ends in a diverging statement (R10) | Value menu (expects the block's type) | nothing | such blocks |
| word dot | yellow (0.90, 0.68, 0.05) | gaps between words of a string, format string, comment or doc comment in word-by-word mode | Insert menu (placeholders, escapes, symbols; `features/08 F16`) | nothing | — |

### Never holes

- **Names, labels, lifetimes, numbers, strings** always have a generated or default value (P4, P5): a name is
  `brave_otter`, a lifetime `'a`, a label `'outer`, a number `0`, a string `""`.
- **Pick-on-insert positions** are never saved empty (D4 "trait positions"): the trait of `impl ● for T`, a
  `dyn ●` / `impl ●` trait, a bound, a `where` predicate, the lint of `#[allow(●)]`, the trait of a new derive.
  Inserting one opens its picker at once, and B in that picker removes the insertion (the Doodle Assignment-pick
  pattern, `features/05 §4`). Removing the last entry of such a list removes the list (`#[allow(dead_code)]` →
  the attribute goes; the last derive → the `#[derive(..)]` line goes).

### Stops that are not dots

Editable names (role `Name(NameRole)`); lifetimes (a fixed `'` plus an editable name); labels (`'outer`);
keywords (`fn`, `pub`, `mut`, `let`, `match`, `=>`, `if`, `else`, `for`, `loop`, `while`, `unsafe`, `async`,
`move`, `impl`, `dyn`, `where`, `as`; role `Keyword`, so Y and LT+B act on them, P10); operators (`+`, `+=`,
`..`, `?`, `&`, `*`; role `Op`); `use` path segments (the analog of Doodle's `import_path`, `features/04 §7`);
attribute names and each derive in `#[derive(..)]`; literals. Punctuation (`;`, `,`, `::`, `(`, `{`) is never a
stop (R9).

### Where each hole's expectation comes from (the Rust form of `features/06 F2`)

The oracle computes it (D6); each answer carries its `ExpectSource`. Before an answer, the syntax layer and the
construct stamp what they know (R2).

| Hole position | Expectation | `ExpectSource` | Before facts (syntax / construct stamp) |
|---|---|---|---|
| any `todo!()` hole the oracle can type | `type_of_expr(todo-expr)?.adjusted()`; unit or never means "no expectation" | `Adjusted` | — |
| call / method / macro argument | the parameter type (via `resolve_method_call_as_callable`) | `CallArg` | the parameter's type text from the knowledge layer, as written in the callee's module (Doodle's `hint` + `hint_pkg`); primitive keyword types are syntax-stamped |
| `let x: T = ●` | `T` | `LetAnnotation` | `T` when written; follows every edit of the annotation (`features/04 §20` `sync_typed_decl_value_hint`) |
| `return ●`, a tail | the fn's / closure's / block's type | `Return` | the declared return type text |
| operand of a binary operator | per operator, below | `Operand` | per operator, below |
| struct-literal field `name: ●` | the field type | `Field` | the field type text from the index or knowledge |
| `match` arm pattern, `if let` / `while let` / `let … else` pattern | the scrutinee's type | `Scrutinee` | — |
| assignment `place = ●`, `place op= ●` | the place's type; any integer for `<<=` / `>>=` | `AssignTarget` | — (fixes `features/06` gap 17 by construction) |
| `if ●`, `while ●`, guard `if ●`, `assert!(●)` | `bool` | `Construct` | `bool` (syntax-stamped) |
| `for pat in ●` | something `IntoIterator` in the loop's iteration mode (`accepts.iterable`) | `Construct` | — |
| index `x[●]` | `usize` for `Vec` / slices / arrays; `&K` for maps | `Construct` | — |
| range ends `●..●` | the other end's type, or the expectation's `Idx` | `Construct` | — |
| `Some(●)`, `Ok(●)`, `Err(●)`, variant fields | the inner type of the outer expectation (`Option<T>` → `T`) | `Construct` | — |
| right side of `== != < <= > >=` | the left side's type once filled | `Construct` | — |
| `assert_eq!(a, ●)` | the first argument's type | `Construct` | — |
| `x as ●` | a primitive cast target (the Type menu shows only primitives) | `Construct` | — |
| `let x = ●`, `const X = ●` before its type is chosen | none (the value decides) | — | — |

Operator operands (Rust's primitive operators require equal operand types, except shifts):

| Operator | Left operand | Right operand |
|---|---|---|
| `+ - * / %` | the expectation `T` when `T` is a primitive number; else no expectation (a user `Add<Rhs>` impl may differ) | the left operand's type once known, else as left |
| `& \| ^` | as above (integers, `bool`) | as above |
| `<< >>` | the expectation | any integer (no expectation) |
| `== != < <= > >=` | none | the left operand's type |
| `&& \|\|`, `!a` | `bool` | `bool` |
| `-a` | the expectation | — |

### Labels and display

- The label after a hole is `TyFacts.shown` (R18): `Vec<String>`, `io::Result<()>`, `&str`. A bound-only
  expectation shows the bound: `impl Into<String>`; a generic parameter shows its bounds: `T (Display + Clone)`;
  a partly known type shows `_`: `Vec<_>`. A pattern hole and an inference-position type hole show the type
  inferred there with a leading `=`: `_ = Option<u32>`. No expectation, no label.
- A menu opened on a hole with an expectation has the subtitle `expects &str  -  grayed options don't fit`
  (Doodle's exact form, `features/06 F3`). With the settle gate off (O5) and facts pending:
  `checking types...`.
- A value, tail or type hole draws as a dot plus its label; the saved `todo!()` (7 columns) or `_` reserves the
  row width, so row breaks and line numbers equal the file's (P20; D4 allows the dot plus label to take more or
  fewer cells inside the row). A `_` pattern draws as `_` in teal with a ring. A cfg hole draws as a dot labelled
  `cfg`. A `ret` hole draws as a blue dot after `)` labelled `-> type`.
- Diagnostics (D4, D10): an error whose primary span lies inside a hole's bytes is shown on the hole as
  `not filled yet: expects i32` (an amber ring), never as a red line. `unreachable_code` warnings caused by a
  hole, and `unused_variables` / `dead_code` for items whose only use is through a hole, are hidden. E0121's
  machine-applicable suggestion feeds the type hole's `SUGGESTED`.

---

## Odin -> Rust mapping

Every construct and menu of `features/04`, `05` and `06`, with its Rust analog. "No analog" rows say what, if
anything, takes the role. Section names in the middle column are sections of this doc.

### File scope (`features/04`)

| Odin construct / menu (feature doc) | Rust analog (this doc) | Notes |
|---|---|---|
| Add menu `Add  (insertion point)`, 7 groups (04 §1) | Add menu, 9 groups: `File Setup`, `Use and modules`, `Functions`, `Types`, `Traits and impls`, `Values`, `Compile-time`, `Tests`, `Modifiers` | Same title. Dots inside an inline `mod` open it too (Doodle: inside a file-scope `when`). |
| Generated names by role (04 §2) | Names: generation and casing by role | Adds generic params, lifetimes, labels, a keyword check and a suffix fallback. |
| Package declaration `package main` (04 §3) | no analog | A crate is a Cargo package; a module is a file. The first fn of a binary crate root is named `main` instead. |
| File tags `#+build linux` (04 §4) | `File Setup > Inner attribute > cfg(…)`: `#![cfg(●cfg)]` | Placed at the top of the file by rule (fixes 04 open question 23). |
| Single-line / Multi-line comment, Blank line (04 §5) | `File Setup > Comment`, `Block comment`, `Blank line`; plus `Module docs (//!)` and `Doc comment (///)` | Same Y / LT+B behaviour on block-comment lines. |
| Import (04 §6), package tree core/base/vendor/shared | `Use and modules > Use ▸`: tree std / core / alloc / dependencies / `crate` / `super` / `self` | Duplicate imports refused (fixes 04 open question 5). |
| Aliased import (04 §6) | `Use as… ▸`: `use std::fmt::Result as FmtResult;` | The alias is chosen by the leaf, not a sticky mode (fixes 04 open question 3). |
| Import line structure, `Edit import` (04 §7) | Y / LT+A on a `use` path segment: the Use tree only | Can't pick a non-`use` leaf (fixes 04 open question 4); a custom alias is kept. |
| Foreign import `foreign import libc "system:c"` (04 §8) | `#[link(name = "…")]` on the extern block (Item options > Attributes) | |
| Foreign block (04 §8) | `Use and modules > Foreign block (FFI)`: `unsafe extern "C" {` / `}` with foreign-item dots | Doodle had no dots inside (04 open question 10). |
| Procedure outline (04 §9) | `Functions > Function`: `fn brave_otter(○params)●ret {` / `●` / `}` | Also Generic / Async / Const / Unsafe / Exported C function. |
| Params dot, `Add parameter` (04 §10) | `○params` > `Add parameter` (+ receivers in methods) | LT+B removes one parameter and its arguments in this file (fixes 04 open question 1). |
| Result list, `res_more` (04 §11) | `●ret` hole; several results are a tuple type `(●, ●)` from the Type menu | No `res_more` dot: a Rust fn has one return type. |
| Return values, `ret_more` (04 §12) | `return ●T;` and the tail; several values are a tuple `(●, ●)` | No `ret_more` dot. |
| Types > Struct (04 §13) | `Types > Struct`: `struct BraveOtter {` / members / `}` | |
| Polymorphic struct `$T` (04 §14) | `Types > Generic struct`: `struct BraveOtter<T○> {` with a field using `T` | An unused type parameter is E0392, so a field using it is inserted. |
| Enum (04 §13) | `Types > Enum` | |
| Union (tagged, 04 §13) | `Types > Enum` with tuple variants | An Odin union is tagged, so its analog is a Rust enum. |
| `#raw_union` struct directive (04 §28) | `Types > Union` | Field reads are `unsafe` (R13). |
| Bit set (04 §14) | no analog in std | Add crate `bitflags` or `enumset`, then their macros as calls (Deferred). |
| Bit field (04 §14) | no analog | Deferred. |
| Distinct type (04 §14) | `Types > Tuple struct` (newtype): `struct BraveOtter(●);` | |
| Type alias (04 §14) | `Types > Type alias`: `type BraveOtter = ●;` | |
| Member dots (04 §15): struct `Field` | struct body > `Field`, `Public field` | |
| struct `Using field` (04 §15) | no analog | A `Deref` impl is the nearest idiom (Deferred). |
| enum `Member`, `Member = value` (04 §15) | enum body > `Unit variant`, `Variant = value` | Plus `Tuple variant`, `Struct variant`. |
| union `Variant` (04 §15) | enum body > `Tuple variant` | |
| bit_field `Field` (04 §15) | no analog | Deferred. |
| Composite type builder `[N]T []T [dynamic]T map[K]V ^T [^]T` (04 §16) | Type menu > `Collections ▸`, `References and pointers ▸` | `[●; ●]`, `&[●]`, `Vec<●>`, `HashMap<●, ●>`, `&●` / `&mut ●` / `Box<●>`, `*const ●` / `*mut ●`. |
| Edit Type, `Drop [8]` (04 §17) | Edit Type: `Type ▸`, `Wrap in ▸`, `Drop <wrapper>` | Adds Wrap (fixes 04 open question 14). |
| Shared member names `x, y: f32` (04 §18) | no analog | One field per line in Rust. |
| Loading type declarations (04 §19) | the CST projection (D3) | Symmetric with the menus by construction. |
| Constant `X :: ●` (04 §20) | `Values > Constant`: `const BRAVE_OTTER: ● = ●;` | The type is mandatory in Rust. |
| Typed constant (04 §20) | `Values > Constant` | The value hole follows the type (fixes 04 open question 8). |
| Build-config constant `#config` (04 §20) | Cargo features: the cfg predicate `feature = "…"`, `cfg!(feature = "…")` | Authoring features is deferred. |
| Global variable (typed) (04 §20) | `Values > Static` | |
| Global variable (init) `x := v` (04 §20) | no analog | A static always has a type; `Values > Lazy static` covers runtime initializers. |
| Editable declaration values, loaded (04 §21) | everything loaded is structured by the CST | |
| Declare as (04 §22) | Statement menu > Declare as | `let` / `let x: T` / `let mut` / `const`. |
| When block (file scope) (04 §23) | `Compile-time > Cfg-gated item ▸`, `Cfg pair (this or that) ▸`, `Cfg-gated module` | Rust gates items one at a time. |
| When chain options `Add else when` / `Add else` (04 §24) | `Cfg pair` keeps `#[cfg(not(…))]` in sync | |
| When conditions must be constant (04 §24) | const contexts (Value menu) | |
| Static assertion `#assert` (04 §25) | `Compile-time > Static assertion`: `const _: () = assert!(●bool);` | Optional message dot as in Doodle. |
| Modifiers pick mode (04 §26) | `Modifiers` group: same pick (banner, nearest, Up/Down, A, B) | Says so when nothing qualifies (fixes 04 open question 17). |
| Attribute `test` (04 §27, §29) | `#[test]` (Attributes) and `Tests` group | Creates `mod tests` (the analog of the `core:testing` auto-import). |
| `private` | visibility: private is the default | `pub`, `pub(crate)`, `pub(super)` in Visibility. |
| `private="file"` | no analog | Private-to-the-module is the narrowest level. |
| `export` | `#[unsafe(no_mangle)]` | |
| `init`, `fini` | no analog | hidden. |
| `require_results` | `#[must_use]` | |
| `thread_local` | `Values > Thread local` (`thread_local!`) | |
| `link_name="…"` | `#[unsafe(export_name = "…")]` (export side), `#[link_name = "…"]` on a foreign item (import side) | |
| `deprecated="…"` | `#[deprecated(note = "…")]` | |
| `cold` | `#[cold]` | |
| Struct directives `#packed`, `#align(N)` (04 §28) | `#[repr(packed)]`, `#[repr(align(N))]` (Attributes > repr) | Still refuse each other (E0587). |
| Calling conventions (04 §28) | Qualifiers > `extern` ABI | `"odin"` → no `extern` (`"Rust"`); `"c"` → `"C"`; `"system"` → `"system"`; `"stdcall"` / `"fastcall"` / `"cdecl"` hidden off 32-bit x86; `"contextless"`, `"none"` → no analog; `"naked"` → deferred. |
| `@(test)` auto-import `core:testing` (04 §29) | `Tests > Test function` creates or reuses `#[cfg(test)] mod tests { use super::*; }` | |
| Purple attribute dot above procedures (04 §30) | `⊙` above every item and associated item | Opens all item options, not only attributes. |
| Saving file-scope constructs (04 §31) | holes save as neutral tokens (D4); layout by the engine (D5) | Every saved file parses. |
| Deleting a declaration with its attributes (04 §32) | LT+B on an item keyword or name: the item with its attribute and doc lines | |

### Statements (`features/05`)

| Odin construct / menu (feature doc) | Rust analog (this doc) | Notes |
|---|---|---|
| Green dots in bodies, `●` statement line, temporary-line protocol (05 §1) | `Insert(Block)` dots, `StmtRow`, same protocol | B leaves the file byte-identical. |
| Statement menu, 10 groups + context entries (05 §2) | Statement menu, 10 groups + `[ctx]` `Else if`, `Else` | Never sorted (12 with both context entries). |
| Variable (:=) (05 §3) | `Declarations > Let`: `let brave_otter = ●;` | |
| Variable (typed) | `Let (typed)`: `let brave_otter: ● = ●;` | |
| Variable (no value) | `Let (assign later)`: `let brave_otter: ●;` | Rust has no zero value. |
| Multiple (:=) | `Let tuple`: `let (brave_otter, calm_otter) = ●;` | |
| Declare as (05 §3) | Y on `let` > `Declare as` | B in the type menu removes the new type hole (fixes P9 exception 1). |
| Assignment with target pick (05 §4) | `Assignment > Assign (=)` with the same pick | Immutable targets get `mut` added (R12). |
| Implicit Context (05 §4) | no analog | Rust has no implicit context. |
| Compound operators, 14 (05 §4-5) | `+= -= *= /= %= &= \|= ^= <<= >>=` | Fit by trait (`AddAssign` …); no `%%= &~= &&= \|\|=`. |
| Y on an operator: `Operator` menu (05 §5) | same | |
| Calls > Internal procedure (05 §6) | `Calls > Function ▸ > This module`, `This crate ▸` | |
| Calls > From import (05 §6) | `Calls > Function ▸ > std ▸`, `Dependencies ▸`; `Associated function ▸`; `Method on…` | Methods are the bulk of Rust's API. |
| Calls > Built-in (05 §6) | `Calls > Macro ▸` (`println!`, `vec!`, `assert_eq!` …) | `len` etc. are methods in Rust. |
| `Other (name it yourself)` (05 §6) | `Macro ▸ > Dependencies ▸ > name!(○args)` for macros of unknown shape | Calls of unknown fns: none (every callable comes from the index or knowledge). |
| Argument dots typed from the signature (05 §7) | one hole per parameter, typed | No optional parameters in Rust. |
| Variadic `args` dot (05 §7) | `○args` on variadic macros only | Rust has no variadic fns. |
| One argument per row; Join with previous row / Own row (05 §8) | no analog | Rows follow the layout engine's rustfmt widths (D5). |
| Capture dot (05 §9) | `◉` → `let brave_otter = call();`; tuple results → `let (a, b) = …` | |
| If, If / Else (05 §10) | `Branching > If`, `If / else` | |
| If with setup `if x := f(); c {` (05 §10) | `Branching > If let`, `Declarations > Let else` | Rust has no setup statement. |
| Setup menu (05 §10) | no analog | |
| If chain options (05 §11) | Y on `if`: `Add else if`, `Add else`, `Change condition`, `Turn into if let`, `Add && let` | |
| Else if / Else at the dot after a chain (05 §11) | `[ctx]` `Else if`, `Else` | `Else` is grayed (refused) when present, not hidden (fixes 00 open question 8). |
| Switch (05 §12) | `Branching > Match` with generated arms | |
| Switch (conditions) `switch {` (05 §12) | an `if` / `else if` chain | `match () { _ if … }` is unidiomatic. |
| Partial switch `#partial` (05 §12) | Arm menu > `Anything (_)` | Rust matches are always exhaustive. |
| Case / Default case, case options (05 §12) | Arm menu; Y on an arm | |
| Case value Range (05 §12) | Pattern menu > `Range ▸` | Integers and `char` only. |
| Used case values grayed (05 §12) | covered variants grayed: `already matched on line 14: this arm would never run` | |
| Type switch (05 §13) | `match` on an enum's variants | `dyn Any` downcasting is deferred. |
| When in a body (05 §14) | `Compile-time > Cfg-gated statement`, `If cfg!(…)` | |
| For (condition) (05 §15) | `Loops > While` | |
| For (C-style) | no analog | `For in range`, `while`. |
| For (infinite) | `Loops > Loop` | |
| For ... in | `For each (take)`, `For each (borrow)` | The iteration mode is explicit in Rust. |
| For x, i in | `For each with index`: `for (index, item) in ●.iter().enumerate() {` | Index first in Rust. |
| For i in 0..<n / 0..=n | `For in range`, `For in range (inclusive)` | |
| For &x in | `For each (mutable)`: `for item in &mut ● {` | |
| #reverse for | Y on `for` > `Reverse (.rev())` | Works on ranges too. |
| #unroll for | no analog | The optimizer unrolls. |
| Labeled for (05 §15) | `Loops > Labeled loop`: `'outer: loop {` | |
| Loop options (05 §16) | Y on `for` / `while` / `loop` | `Iterate by ▸`, index, reverse, label. |
| Iterable gray-out (05 §17) | iterable holes lit by `IntoIterator` in the loop's mode | |
| Loop variables typed, scoped; LT+B on loop parts (05 §18) | pattern bindings typed by the oracle; LT+B table | |
| Labels, labeled blocks (05 §19) | `'outer` / `'block` labels; `break 'block value` | |
| Return (05 §20) | `Jumps > Return` | |
| Break, Continue (+ labeled) | `Jumps > Break`, `Continue`, `Break with value`, labeled entries | Refused outside a loop (O19). |
| Fallthrough | no analog | Merge patterns with `\|` (Arm menu > `Either`). |
| Defer | `Scope and blocks > Run at scope end (defer)` (scopeguard) or `Drop now` | |
| Multi-result returns (05 §21) | tuple values, tuple patterns | |
| Error handling: or_return (05 §22) | `?` (`Errors and Option > Try a call (?)`, Pass as > `Unwrap > x?`) | Gated by the fn's return type. |
| or_else | `.unwrap_or(●)`, `.unwrap_or_else(\|\| ●)` (Pass as > `Unwrap ▸`) | |
| if err != nil | `Match Ok / Err`, `If let Some / Ok`, `Let else` | Structured from the start (fixes 05 open question). |
| or_break / or_continue (not offered by Doodle) | `Let else` with `break;` / `continue;` | |
| Block (05 §23) | `Scope and blocks > Block` | |
| Using `using x` | no analog | `use Enum::*;` inside a fn via `Declarations > Use (here)` covers the namespace case. |
| Labeled block | `Scope and blocks > Labeled block`: `'block: {` | |
| Compile-time #assert, When (05 §24) | `Compile-time > Static assertion`, `Cfg-gated statement`, `If cfg!(…)` | |
| Layout: Comment, Multi-line comment, Blank line (05 §25) | `Layout > Comment`, `Block comment`, `Blank line` | |
| Struct literal `T{○}` with a fields dot (05 §26) | `Construct > Struct literal ▸`: every field inserted | Rust needs every field (R8). |
| Field access chains, indexing, comma-ok (05 §27) | Pass as > `Field of x ▸`, `x[●]`, `Methods of x ▸ > get(…)` | |
| Range `●..<●` (05 §27) | `Construct > Range ▸`: `●..●`, `●..=●`, `●..`, `..●`, `..` | |
| Loading statements back (05 §28) | the CST projection (D3) | Exact for every construct, not just some. |
| HUD hints for statements (05 §29) | Part actions > HUD hints | |

### Type-driven menus (`features/06`)

| Odin construct / menu (feature doc) | Rust analog (this doc) | Notes |
|---|---|---|
| The menu pipeline (06 F1) | `Construct::offers` per location, then fit, then the view (R1-R7) | |
| Dots carry `hint` + `hint_pkg` (06 F2) | `HoleFacts { expected, source }` and construct stamps | |
| `expects T  -  grayed options don't fit`, hint labels (06 F3) | same | |
| `Type_Cat`, `resolve_type`, fit table (06 F4) | `TyFacts { cat, accepts: AcceptBits }` and `Fits` answers | Real type checks, no textual identity (fixes 06 gaps 1, 2, 11, 16). |
| Advisory vs refused (06 F5) | three kinds (R3) | Every gray has a reason. |
| Value menu groups, alphabetical (06 F6) | Value menu, 11 groups + `[ctx]` `Extend`, authored order | |
| Number | `Literal > Integer 0`, `Float 0.0` | Rust literal rules. |
| String `"…"`, raw `` `…` ``, rune `'…'` | `Literal > String "…"`, `Raw string r"…"`, `Char 'a'` | Plus byte, byte string, C string. |
| `true`, `false` | `Literal > true`, `false` | |
| `nil` | `Construct > Option / Result > None`; `std::ptr::null()` via Call | No null references. |
| Call group (06 F7) | `Call ▸` | |
| Struct literal (06 F8) | `Construct > Struct literal ▸` | |
| Constant group, imported constants (06 F9) | `Constant ▸` | |
| Built-in constants `ODIN_OS` (06 F10) | `Call > Macro > Compile-time > cfg!(●cfg)`; `std::env::consts::OS` under `Constant ▸ > std` | |
| Enum value `.North` (06 F10) | `Construct > Enum variant ▸`: `Dir::North` | Data variants get holes. |
| Operator groups (06 F11) | `Operator ▸`: Arithmetic, Bitwise, Compare, Logic | By trait; `!` is logical and bitwise not; no `&~`. |
| Ternaries `a if c else b` (06 F12a) | `Choose ▸ > if ● { ● } else { ● }` | |
| `a when c else b` | `Choose ▸ > if cfg!(●cfg) { ● } else { ● }` | Both branches must still type-check. |
| Convert `T(x)` (06 F12) | `Convert ▸ > T::from(●)`, `●.into()` | |
| `cast(T)x` | `Convert ▸ > ● as T` | Primitive casts only. |
| `transmute(T)x` | no menu entry | `unsafe` and rarely right (Deferred). |
| `auto_cast x` | `Convert ▸ > ●.into()` | |
| Type group (types as values) (06 F13) | no analog | Types are not values; type holes are their own menu. |
| Range (contextual) (06 F14) | `Construct > Range ▸`; Pattern `Range ▸` | |
| Reference pick (06 F15) | `Reference`: same banner and d-pad rules | Scope from rust-analyzer; declaration sites only; numbers never offered (fixes 06 gaps 6, 20). |
| Pass as (06 F16): `name`, `T(name)`, `&name`, `name^` | Pass as: move / copy, `&x`, `&mut x`, `*x`, `x.clone()`, `Convert ▸`, `Unwrap ▸`, `Wrap ▸`, `View ▸` | The bare name is type-grayed too (fixes 06 gap 5). |
| Field of / index (06 F17) | `Field of x ▸`, `x[●]   Elem` | Privacy-aware. |
| (no Odin analog) | `Methods of x ▸` | The biggest addition. |
| Ordering, used-in-this-file pins (06 F18) | `RECENTLY USED`, `SUGGESTED`, `FIX` sections (R7) | |
| Assign to (06 F19) | `Assign to`: `x`, `*x`, `Field of x`, `x[●]`, `Through a method ▸` | |
| Compound operators per type (06 F20b) | by trait impl | |
| Number keypad (06 F20) | keypad plus `0o`, `0b`, `_`, `e`, `Suffix` (`features/08` Carrying (c)) | |
| Y refills typed for its position; LT+B leaves a typed dot (06 F21) | same; refill menus get `[ctx]` `Extend <x> ▸` | |
| Change procedure (06 F21b) | Y on a callee: `Change function`, `Change method`, `Change macro` | Grayed by return fit (fixes 06 gap 13). |
| Declare as (06 F21b) | Declare as | |
| Name / expression type oracle (06 F22) | `doodle-oracle` (D6) plus the syntax layer | |
| Constant-only positions: `when` (06 F23) | const contexts | |
| `#unroll` constness (06 F24) | no analog | Const contexts keep the mechanism. |
| Iterables and case values (06 F25) | iterable holes, patterns | |
| Rename with propagation (06 F26) | Names > Rename | Semantic via the oracle; other files only as an explicit entry. |
| Capture, number dictation, typed dots on load (06 F27) | capture dot; `features/08`; the projection | |

---

## File-scope Add menu

### Opening it, and the group tree

A on a green `Insert(Module)` dot opens the grid titled exactly `Add  (insertion point)` (two spaces; Doodle's
title, `features/04 §1`). Nine groups in this authored order (9 entries, never sorted; R6):

```
File Setup        : Module docs (//!) | Inner attribute ▸ | Comment | Block comment | Doc comment (///) | Blank line
Use and modules   : Use ▸ | Use as… ▸ | Use everything (glob) ▸ | Module (new file) | Module (link a file) ▸ | Inline module | Add crate ▸ | Extern crate ▸ | Foreign block (FFI)
Functions         : Function | Generic function | Async function | Const function | Unsafe function | Exported C function
Types             : Struct | Tuple struct | Unit struct | Generic struct | Enum | Union | Type alias
Traits and impls  : Impl block | Trait impl ▸ | Trait
Values            : Constant | Static | Lazy static | Atomic static | Thread local | Mutable static (unsafe)
Compile-time      : Cfg-gated item ▸ | Cfg pair (this or that) ▸ | Cfg-gated module | Static assertion | Macro (macro_rules!)
Tests             : Test module | Test function | Test returning Result | Should-panic test
Modifiers         : Visibility | Derive | Attributes | Qualifiers | Docs | Generics
```

Where it is offered:

| Dot | Menu | Differences |
|---|---|---|
| file top level | the full Add menu | — |
| inside an inline `mod m { }` (including `#[cfg(test)] mod tests { }`) | the full Add menu | `Module docs` and `Inner attribute` go to the top of that inline module. Inside `mod tests`, `Test module` is refused (`already inside mod tests`) and `Test function` inserts at the dot. |
| inside a fn body | Statement menu > `Declarations > Item here ▸`: Function, Struct, Enum, Constant, Static, Impl block, Use ▸ | items inside fn bodies are legal Rust but rare |

Rules carried from Doodle (`features/04 §1`): B pops one level; B at the root inserts nothing; every real leaf
use wears its menu path (heat); a leaf inserts at the dot. Item spacing (the layout engine writes it; D5):
exactly one blank line between items, except between consecutive `use` items and between consecutive `const`
or `static` items, which stay adjacent (NS1's `use` group, NS2's `WIDTH` / `HEIGHT`). So a second Function
after `fn main() {}` saves as `fn main() {}\n\nfn brave_otter() {}\n`. LT+B on an item removes it with one
adjacent blank separator (the one after it, else the one before); deleting the only item leaves empty text.

### File Setup

| Leaf | Inserts | Gray / refuse / hide | Cursor | Doodle |
|---|---|---|---|---|
| `Module docs (//!)` | `//! brave otter` (comment text leaf) | Always placed after the module's existing `//!` and `#![…]` lines and before its first item, whatever dot was used: inner doc comments are only legal there (E0753). When the dot was elsewhere the status says `module docs go at the top of the file`. | the text | `features/04 §5` |
| `Inner attribute ▸` | submenu below | | | `features/04 §4` (file tags) |
| `Comment` | `// brave otter` | — | the text | `features/04 §5` |
| `Block comment` | `/*` / `brave otter` / `*/` | — | the text | `features/04 §5` |
| `Doc comment (///)` | `/// brave otter` directly above the item below the dot | refused: `a doc comment needs an item right below it` (the line below the dot is not an item; E0585). The usual way is `⊙ > Docs`. | the text | new |
| `Blank line` | an empty line | — | the green dot after it | `features/04 §5` |

`Inner attribute ▸` (all placed like `Module docs`):

| Leaf | Inserts | Gray / refuse / hide |
|---|---|---|
| `allow(…)`, `warn(…)`, `deny(…)`, `expect(…)` | opens the lint picker at once (pick-on-insert); after a pick: `#![allow(dead_code)]` | B in the picker inserts nothing |
| `forbid(unsafe_code)` | `#![forbid(unsafe_code)]` | refused: `already on line 2` |
| `no_std` | `#![no_std]` | hidden: the file is not a crate root (metadata); refused: `already on line 1` |
| `cfg(…)` | `#![cfg(●cfg)]` (the Rust form of Odin's `#+build` file tag) | — |

### Use and modules

| Leaf | Inserts | Gray / refuse / hide | Cursor | Doodle |
|---|---|---|---|---|
| `Use ▸` | the Use tree (below); a leaf inserts `use std::collections::HashMap;`, merged into a `use` line with the same parent module when one exists (`use std::collections::{HashMap, HashSet};`, R9) | refused: `HashMap is already imported on line 3` (same path); refused: `Result is already imported from std::io on line 4: use Use as…` (same name, other path; E0252); refused: `Point is defined on line 30: use Use as…` (E0255); gray: `hides the prelude's Result in this module`; fix: `Use as… FmtResult` | the line | `features/04 §6` |
| `Use as… ▸` | the same tree; a leaf inserts `use std::fmt::Result as FmtResult;` with the alias editable. Default alias: parent module name + item name, in the item's casing (`std::fmt::Result` → `FmtResult`; module `std::io` → `std_io`; fn `std::fs::read` → `fs_read`) | refused: `FmtResult is already used on line 7` | the alias (ready for dictation) | `features/04 §6` |
| `Use everything (glob) ▸` | the tree, where only modules and enums are leaves: `use std::io::prelude::*;`, `use Direction::*;` | refused: `already imported on line 5`; gray: `brings 87 names into scope` (a module with more than 40 public items) | the line | new |
| `Module (new file)` | after `Create src/brave_otter.rs and add mod brave_otter here?   A create   B cancel`: `mod brave_otter;` here, and an empty file where rustc looks for it (next to `main.rs` / `lib.rs` / `mod.rs`; else in a folder named after the current module, created if needed) | refused: `src/brave_otter.rs exists: use Module (link a file)` (index) | the name | D18.2 (new) |
| `Module (link a file) ▸` | `mod existing_name;` for a `.rs` file in the module's folder that no `mod` declares (index) | placeholder `(no unlinked .rs files here)` | the line | new |
| `Inline module` | `mod brave_otter {` / green dot / `}`; its dots open this Add menu | — | the name | new |
| `Add crate ▸` | see "Add crate" below | | | D18.1, O21 |
| `Extern crate ▸` | `extern crate alloc;`; lit leaves: `alloc`, `core`, `proc_macro`, `std`, `test` | Cargo dependencies are listed with gray: `not needed since the 2018 edition: use it directly`; refused: `already on line 3` | the line | new |
| `Foreign block (FFI)` | `unsafe extern "C" {` / green dot / `}` (R16). A native library is named through `⊙ > Attributes > link(name = "…")`. | — | the green dot inside | `features/04 §8` |

**The Use tree** (Doodle's import tree, `features/04 §6`, `features/07 §2`):
- Roots in order: `std`, `core`, `alloc`, then each normal dependency from `cargo metadata` (dev-dependencies
  only when the dot is in test code: inside a `#[cfg(test)]` item or a file under `tests/`; build-dependencies
  only in `build.rs`), then `crate`, `super` (hidden at a crate root), `self`.
- Inside a module node: first a leaf `use <module>` for the module itself (Doodle's `import <name>` leaf), then
  groups in this order: `Modules`, `Types`, `Traits`, `Functions`, `Macros`, `Constants`. Each group follows
  `features/07 §6` grouping.
- Hidden: `#[doc(hidden)]` items, unstable items, non-public items of other crates, items of another module
  that are not visible from here, modules for another target (`std::os::unix` on Windows; Doodle's
  `platform_ok`).
- Sources: std / core / alloc from the embedded tables; this crate from the syntax index; dependencies from
  `ItemsOf` (D9), showing `(looking up serde...)` until the answer or cache hit arrives (R4).
- `RECENTLY USED`: paths used in this file's other `use` lines' crates this session (`features/04 §6`
  `recent_imports`).

**Add crate** (O21, D9, D18.1). `Add crate ▸` opens a grid with these sections:
1. `IN THIS WORKSPACE`: other member crates (metadata).
2. `CATALOG`: the embedded curated catalog (≤ 150 crates, by category, pinned versions), labelled
   `serde   1.0   serialization framework`.
3. `USED BEFORE`: crates in the local cargo registry cache, newest first.
4. `Search by voice`: a leaf (menus read only the d-pad, A and B, so Talk can't fire inside the grid). It opens
   the voice-search overlay, a core `Mode` with fixed controls on Doodle's Files-search precedent
   (`features/09 F19`): header `SEARCH`, line `find: <query>   (<count>)`, placeholder
   `(hold X and say part of a name)`, hint `Up/Down move   A pick   hold X say a name   B back`. The physical X
   dictates whatever Talk is bound to. Here the dictated name is looked up in the crates.io sparse index
   (`Request::Registry`, `Event::Registry`), which lists the exact match first, then near matches; A on a
   result continues as a pick below. gray: `offline: turn on the network in Settings` when the network setting
   is off (O11). The same overlay serves `Methods of x > Search by voice`, where the words only filter the
   listed methods.

Picking a crate asks `Add serde 1.0 to Cargo.toml?   A add   B cancel` (`[dev-dependencies]` and `--dev` when
the dot is in test code; the catalog's recommended features are passed with `--features`). A sends
`Request::AddDependency`; the status says `adding serde...` and then, on `Event::DepAdded`,
`added serde 1.0 to Cargo.toml` or `cargo add failed: <first line of its error>`. Offline (`--offline`), a
crate that is not in the local cache fails with `serde isn't downloaded yet: turn on the network in Settings,
then try again`. Refused: `serde is already a dependency (Cargo.toml)` (metadata). The Use tree lists the
crate once metadata and the oracle refresh (D18). No editor mode changes when the event arrives (D7.4).

### Functions

All fn leaves insert Doodle's three-line outline (`features/04 §9`):

```rust
fn brave_otter(○)●ret {      // [fn ][brave_otter][(][○params][)][●ret][ {]
    ●                        // StmtRow (statement menu)
}
```

Untouched, it saves as `fn brave_otter() {}`: the params dot and the unfilled `ret` hole save as nothing (D4),
and the empty block is `{}` in the file and `{` / `●` / `}` on screen (the D3.3 visual-only split: one saved
line, three screen rows, one gutter number). When `ret` is filled with a type other
than `()`, a tail hole is added (R10): `fn brave_otter() -> i32 {` / `●i32` / `}`, saved
`fn brave_otter() -> i32 {` / `    todo!()` / `}`, which compiles.

| Leaf | Header inserted | Gray / refuse / hide | Cursor | Doodle |
|---|---|---|---|---|
| `Function` | `fn brave_otter(○)●ret {`. In a binary crate root (`src/main.rs`, `src/bin/*.rs`) with no `fn main` yet: `fn main(○)●ret {`, saved `fn main() {}` (fixes `features/00` open question 9: only the binary root's first fn is `main`). It keeps its `○params` dot, so `project` stays crate-agnostic; the refusal below is gray, not hidden. | — | the name | `features/04 §9` |
| `Generic function` | `fn brave_otter<T○generics>(calm_otter: T, ○)●ret {` (the parameter uses `T` so the generic means something) | — | the name | `features/04 §14` ($T) |
| `Async function` | `async fn brave_otter(○)●ret {`; its body is an async context | — (O22: syntax only; runtimes come through Add crate) | the name | new |
| `Const function` | `const fn brave_otter(○)●ret {`; its body is a const context | — | the name | new |
| `Unsafe function` | `unsafe fn brave_otter(○)●ret {`; R13 still wraps unsafe operations inside (edition 2024) | — | the name | new |
| `Exported C function` | `#[unsafe(no_mangle)]` / `pub extern "C" fn brave_otter(○)●ret {` | parameter and return Type menus list FFI-safe types first (`i32`, `u32`, `f64`, `bool`, `*const c_char`, `*mut c_void`, `#[repr(C)]` structs); others gray: `String isn't FFI-safe (improper_ctypes): use *const c_char` | the name | `features/04 §27` (`export`), §28 |

On `fn main` in a binary root: A on its `○params` dot opens the `Add parameter` menu, whose entries are refused:
`main takes no arguments: read them with std::env::args()` (evidence: syntax plus the crate root from
metadata); the `ret` hole's `SUGGESTED` offers `Result<(), Box<dyn Error>>`. Qualifiers on an existing
fn are Y options (`Item options > Qualifiers`); the leaves above are shortcuts.

### Types

| Leaf | Inserts | Gray / refuse / hide | Cursor | Doodle |
|---|---|---|---|---|
| `Struct` | `struct BraveOtter {` / green `Insert(Members)` dot / `}`; saved `struct BraveOtter {}` | — (no default derives: the operator and format menus offer `derive PartialEq` / `derive Debug` as fixes exactly when needed; open question 6) | the name | `features/04 §13` |
| `Tuple struct` | `struct BraveOtter(●);` → after a fill `struct BraveOtter(i32, ○fields);`; saved untouched `struct BraveOtter(_);` (E0121 until filled) | — | the type hole | `features/04 §14` (distinct) |
| `Unit struct` | `struct BraveOtter;` | — | the name | new |
| `Generic struct` | `struct BraveOtter<T○generics> {` / `brave_otter: T,` / `}` (a field using `T`, because an unused type parameter is E0392) | — | the name | `features/04 §14` |
| `Enum` | `enum BraveOtter {` / green dot / `}`; saved `enum BraveOtter {}` | — | the name | `features/04 §13` |
| `Union` | `union BraveOtter {` / `brave_otter: ●,` / `}` (one field: "unions cannot have zero fields") | the field's Type menu grays non-`Copy` types: `union fields must be Copy or ManuallyDrop (E0740)`; fix: `Wrap in ManuallyDrop<…>` | the field type | `features/04 §28` (`#raw_union`) |
| `Type alias` | `type BraveOtter = ●;`; saved `type BraveOtter = _;` (E0121 until filled) | — | the type hole | `features/04 §14` |

### Traits and impls

| Leaf | Inserts | Gray / refuse / hide | Cursor | Doodle |
|---|---|---|---|---|
| `Impl block` | `impl BraveOtter {` / green `Insert(AssocItems)` dot / `}`. The self type is **pre-filled** with the nearest struct, enum or union declared above the dot in this file (P4: everything has a default); with none, a type hole (`impl ● {`). | The self-type Type menu lists this crate's types first; a type from another crate is gray: `can't add methods to a type from another crate (E0116): implement a trait instead` | the green dot inside | new (`features/04 Carrying (c)`) |
| `Trait impl ▸` | Opens the trait picker at once, title `Implement which trait?` (pick-on-insert). After a pick: `impl Display for BraveOtter {` with **every required item** inserted (R8), self type pre-filled as for `Impl block`. | Sections: `SUGGESTED` (traits the last check says the self type is missing: E0277 diagnostics naming a local type), `Common` (`Display`, `Debug`, `Default`, `Clone`, `PartialEq`, `From<●>`, `FromStr`, `Iterator`, `Drop`, `std::error::Error`), `This crate ▸`, one group per dependency, `std ▸`. refused: `already implemented on line 40` (E0119) or `already derived on line 12`; gray: `only traits or types from this crate can be implemented here (E0117)`; gray: `Ord needs PartialOrd and Eq first`; fix: `Derive PartialEq, Eq, PartialOrd too` (local type). B in the picker inserts nothing. | the first hole of the first required item | new |
| `Trait` | `trait BraveOtter {` / green dot / `}` | — | the name | new |

Required-item defaults inserted by `Trait impl` (the shape of rust-analyzer's `add_impl_missing_members`
assist, built by our own builder from the knowledge layers' trait signatures; the `use`s follow R11):

```rust
impl fmt::Display for BraveOtter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        ●fmt::Result                    // tail hole, saved todo!()
    }
}

impl Iterator for BraveOtter {
    type Item = ●;                      // type hole, saved _ (E0121 until filled)

    fn next(&mut self) -> Option<Self::Item> {
        ●Option<Self::Item>
    }
}

impl From<●> for BraveOtter {           // the generic argument is a type hole
    fn from(value: ●) -> Self {         // follows the argument above
        ●Self
    }
}
```

Provided methods are not inserted; the trait-impl body menu lists them under `Override a provided method ▸`.

### Values

| Leaf | Inserts | Gray / refuse / hide | Cursor | Doodle |
|---|---|---|---|---|
| `Constant` | `const BRAVE_OTTER: ● = ●;` The value hole follows the type (`features/04 §20` `sync_typed_decl_value_hint`) and is a const context. Untouched saves `const BRAVE_OTTER: _ = todo!();` (E0121 and E0080: constants are evaluated even when unused). | — | the name | `features/04 §20` (Constant, Typed constant) |
| `Static` | `static BRAVE_OTTER: ● = ●;` (same rules) | — | the name | `features/04 §20` (Global variable (typed)) |
| `Lazy static` | `static BRAVE_OTTER: LazyLock<●> = LazyLock::new(\|\| ●);` + `use std::sync::LazyLock;` (the closure body expects the type argument) | — | the name | new |
| `Atomic static` | `static BRAVE_OTTER: AtomicUsize = AtomicUsize::new(0);` + `use std::sync::atomic::AtomicUsize;` (Y on the type swaps `AtomicBool`, `AtomicI32`, `AtomicU64`, …) | — | the name | new |
| `Thread local` | `thread_local! {` / `static BRAVE_OTTER: Cell<●> = Cell::new(●);` / `}` + `use std::cell::Cell;` (a known item macro, structured as a block with one entry; the projection sub-parses exactly this one-entry form on load too (D3.9), so a loaded one has the same fields; other `thread_local!` shapes load as `Opaque`) | — | the name | `features/04 §27` (`thread_local`) |
| `Mutable static (unsafe)` | `static mut BRAVE_OTTER: ● = ●;` | always gray (evidence: syntax): `every use needs unsafe, and references to it are denied in edition 2024: prefer Atomic static, Lazy static or a Mutex` (`static_mut_refs`) | the name | new |

Odin's `Global variable (init)` (`x := v`) has no analog: a static always has a type.

### Compile-time

Odin's file-scope `when` groups declarations under one constant condition (`features/04 §23`). Rust gates items
one at a time with `#[cfg(…)]`; an inline module is a namespace, not a group.

| Leaf | Inserts | Gray / refuse / hide | Cursor | Doodle |
|---|---|---|---|---|
| `Cfg-gated item ▸` | the Functions, Types, Values and Traits-and-impls leaves; the chosen item gets `#[cfg(●cfg)]` above it | — | the cfg hole | `features/04 §23` |
| `Cfg pair (this or that) ▸` | the same leaves; the item is inserted twice: `#[cfg(●cfg)]` above the first copy and `#[cfg(not(●cfg))]` above the second. The second predicate mirrors the first after every edit (a sync pass like Doodle's `branch_sync`). Untouched: `#[cfg(true)]` and `#[cfg(not(true))]`, which compile. | — | the cfg hole | `features/04 §24` (`when … else`) |
| `Cfg-gated module` | `#[cfg(●cfg)]` / `mod brave_otter {` / green dot / `}` | — | the cfg hole | `features/04 §23` |
| `Static assertion` | `const _: () = assert!(●bool, ○args);` The condition is a const context; the optional message must be a string literal. | — | the condition | `features/04 §25` |
| `Macro (macro_rules!)` | `macro_rules! brave_otter {` / `() => {` / `●` / `};` / `}`: one no-argument rule whose transcriber is edited as a statement block (Deferred: matchers). The projection structures exactly this single-rule `() => { … }` form on load as well (D3.2, D3.9), so build → save → reload gives the same fields (`loader_builds_same_fields_as_menus` covers it); any other `macro_rules!` loads as `Opaque` with an editable name. | — | the name | new |

A `macro_rules!` macro is visible only *below* its definition, so `Call > Macro > This crate` lists local macros
defined below the dot with gray: `defined below, on line 88: move it up (Refactor > Grab)`.

### Tests

| Leaf | Inserts | Gray / refuse / hide | Cursor | Doodle |
|---|---|---|---|---|
| `Test module` | `#[cfg(test)]` / `mod tests {` / `use super::*;` / `}` | refused: `already on line 120` (the file has a `mod tests`) | the green dot inside | `features/04 §29` |
| `Test function` | `#[test]` / `fn brave_otter() {` / `●` / `}` inside `mod tests`. Outside it, the module is created at the end of the file (or reused) and the fn goes at its end; the status says `added to mod tests (line 120)`. | — | the name | `features/04 §29` |
| `Test returning Result` | `#[test]` / `fn brave_otter() -> Result<(), Box<dyn Error>> {` / `●` / `Ok(())` / `}` + `use std::error::Error;` in the test module (lets the body use `?`) | — | the name | new |
| `Should-panic test` | `#[test]` / `#[should_panic]` / `fn brave_otter() {` / `●` / `}` | — | the name | new |

### Modifiers, and Item options (`⊙`, Y on an item keyword)

The `Modifiers` group starts Doodle's declaration pick (`features/04 §26`): banner
`Pick an item for the <leaf>   -   D-pad Up/Down move   A choose   B cancel`, nearest candidate first, Up/Down
step, A opens that item's options at the matching group, B in the options returns to picking. With no
candidate the status says so (`nothing here takes a derive: add a struct or enum first`; fixes `features/04`
open question 17). Candidates per leaf: `Visibility` (items, fields, inherent-impl items), `Derive` (structs,
enums, unions), `Attributes` (all items), `Qualifiers` (fns, methods, foreign fns), `Docs` (all items),
`Generics` (fns, structs, enums, unions, traits, impls, type aliases).

The same options open directly from the item's `⊙` and from Y on its keyword. **Item options**, title
`<kind> <name>` (`struct BraveOtter`, `fn brave_otter`, `impl Display for BraveOtter`), has these groups,
hidden when they never apply to the item kind: `Visibility`, `Derive`, `Attributes`, `Qualifiers`, `Docs`,
`Generics`. Options menus refuse refused entries and stay open (`features/04` inv 8); nothing changes until a
pick (`MenuPurpose::Options`).

**Visibility** (`features/04 §27` `private`):

| Leaf | Inserts | Gray / refuse / hide |
|---|---|---|
| `private` | removes the visibility | refused: `already private` |
| `pub(super)` | `pub(super) ` | refused when current; hidden at a crate root's top level (no parent module) |
| `pub(crate)` | `pub(crate) ` | refused when current |
| `pub` | `pub ` | refused when current; gray: `its signature uses the private type Point (private_interfaces)`; fix: `Make Point pub too` (when `Point` is in this file) |

Hidden on trait-impl items, trait items, enum variants (E0449 "visibility qualifiers are not permitted here"),
`impl` blocks and `macro_rules!` (which uses `#[macro_export]`). `pub(in path)` is deferred.

**Derive** is a checklist (multi-select, new): title `Derive for BraveOtter`; A toggles the highlighted derive
and the menu stays open (like Doodle's keypad, `features/06 F20`); B closes and keeps the toggles. The whole
checklist session is one undo step (R17). Labels read `Debug   on` / `Clone   off`. The `#[derive(…)]` line is
created, extended and removed as toggles change, always in this order: `Debug, Clone, Copy, PartialEq, Eq,
PartialOrd, Ord, Hash, Default`, then derive macros of dependencies (`serde::Serialize`, `serde::Deserialize`
when `serde` has its `derive` feature; listed from `ItemsOf` derive-macro items).

| Derive | Turning it on also turns on | Gray (advisory, from `impls_trait` per field type; generic fields never gray) |
|---|---|---|
| `Debug` | | `field window: Window isn't Debug` |
| `Clone` | | `field file: File isn't Clone` |
| `Copy` | `Clone` | `field memory: Vec<u32> isn't Copy (E0204)` |
| `PartialEq` | | `field f: fn() isn't PartialEq` |
| `Eq` | `PartialEq` | `field x: f64 can't be Eq` |
| `PartialOrd` | `PartialEq` | `field … isn't PartialOrd` |
| `Ord` | `PartialOrd`, `Eq`, `PartialEq` | `field … isn't Ord` |
| `Hash` | | `field x: f64 isn't Hash (E0277)` |
| `Default` | on an enum: `#[default]` on its first unit variant | struct: `field window: Window isn't Default`; enum without a unit variant: refused: `Default on an enum needs a unit variant to mark #[default]` |

Turning one off that another needs is refused: `Copy needs Clone: turn Copy off first`. Turning off the last
derive removes the line.

**Attributes** (one entry per attribute; hidden where never valid for the item kind; refused when already
present with `already on line 12`; Doodle's `ATTR_OPTS` generalised, `features/04 §27`):

| Attribute | Shown on | Gray / refuse (reason) | Doodle |
|---|---|---|---|
| `#[test]` | free fns | refused: `a test takes no arguments` (parameters), `a test can't be generic` (non-lifetime generics), `async fns can't be tests` (`async`), `unsafe fns can't be tests` (`unsafe`); gray: `i32 isn't a test result: return () or Result<(), E>` (return type) | `test` |
| `#[should_panic]`, `#[ignore]` | free fns | refused: `needs #[test] first` | — |
| `#[inline]`, `#[inline(always)]`, `#[inline(never)]` | fns, methods | the three refuse each other: `already #[inline] on line 12: remove it first` | — |
| `#[cold]`, `#[track_caller]` | fns, methods | — | `cold` |
| `#[must_use]` | fns, methods, types, traits | — | `require_results` |
| `#[deprecated(note = "…")]` | items | — (the note is a string leaf) | `deprecated` |
| `#[allow(…)]`, `#[warn(…)]`, `#[deny(…)]`, `#[expect(…)]` | items, statements, fields, arms | opens the lint picker at once | — |
| `#[cfg(●cfg)]` | items, fields, variants, statements, arms | when present the entry reads `Edit cfg` | `when` |
| `#[repr(…)] ▸` `C`, `transparent`, `u8` … `i64`, `usize`, `isize`, `packed`, `packed(N)`, `align(N)` | structs, enums, unions | `packed` and `align` refuse each other: `packed and align can't be combined (E0587)`; int reprs hidden except on enums; `transparent` on a struct is never refused by counting fields (zero-sized fields such as `PhantomData<T>` are allowed, and a struct with no fields compiles; checked on rustc 1.96.1): with two or more fields it is advisory gray (evidence: oracle) when facts show two or more fields with non-trivial size or alignment: `transparent needs at most one field with non-trivial size or alignment (E0690)`; lit while that is Unknown | struct directives |
| `#[non_exhaustive]` | structs, enums, variants | — | — |
| `#[doc(hidden)]` | items | — | — |
| `#[unsafe(no_mangle)]`, `#[unsafe(export_name = "…")]` | fns, statics | — | `export`, `link_name` |
| `#[link(name = "…")]` | extern blocks | — (the name starts as `""`, E0454 until dictated) | foreign import |
| `#[link_name = "…"]` | foreign items | — | `link_name` |
| `#[default]` | unit variants of an enum deriving `Default` | refused on a non-unit variant: `#[default] goes on a unit variant` | — |
| `#[macro_export]` | `macro_rules!` | — | — |

Removed from Doodle's list with no Rust analog: `init`, `fini`, `private="file"`, and `thread_local` (a macro
here, `Values > Thread local`).

**Qualifiers** (fns and methods; a checklist like Derive, with refusals):

| Leaf | Effect | Gray / refuse / hide |
|---|---|---|
| `const` | adds `const` | refused with `async` on: `a fn can't be both const and async`; gray: `calls make_list, which isn't a const fn (E0015)` |
| `async` | adds `async` | refused with `const` on (same reason); removing it when the body uses `.await` is gray: `.await on line 22 needs async` |
| `unsafe` | adds `unsafe` | removing it when the body calls unsafe fns outside `unsafe { }` is gray: `line 30 calls an unsafe fn` |
| `extern ▸` | `"C"`, `"system"`, `"C-unwind"`, `"Rust"` (removes `extern`) | `"stdcall"`, `"fastcall"`, `"cdecl"` hidden unless the target is 32-bit x86 (**verify** the target rules of the pinned rustc) |
| `safe` / `unsafe` (foreign fns in an `unsafe extern` block only) | marks the item | — |

**Docs**: `Add doc comment` (`/// brave otter` above the attributes), `Add # Examples section` (a fenced
`/// # Examples` / ```` /// ``` ```` / `/// brave otter` / ```` /// ``` ```` block whose inner lines are
comment text for now; Deferred), `Add # Errors section` (fns returning `Result`), `Add # Panics section`,
`Add # Safety section` (unsafe fns only). Refused: `already has # Errors (line 8)`.

**Generics**: `Add type parameter`, `Add lifetime`, `Add const parameter`, `Add where clause` (see "Type menu,
generic params …"). This fixes Doodle's "remove all `$T` and they can never come back" (`features/04` open
question 16).

---

## Inside impl / trait blocks

Doodle's data-body member menus (`features/04 §15`) generalise to every body whose children are declarations.
The menu title is `Fill slot` (Doodle's), with a subtitle naming the body (`items of impl BraveOtter`). Every
such menu ends with Doodle's `Layout ▸` group (`Comment`, `Block comment`, `Blank line`). The member replaces
the dot's line; no extra `●` row is added (the green dots between members do that job). B inserts nothing.

### Inherent impl body `impl T { }`

| Leaf | Inserts | Gray / refuse / hide | Cursor | Doodle |
|---|---|---|---|---|
| `Method (&self)` | `fn brave_otter(&self, ○)●ret {` / `●` / `}` (the receiver is a `self` stop) | — | the name | `features/04 §15` (members), new |
| `Method (&mut self)` | `fn brave_otter(&mut self, ○)●ret {` / `●` / `}` | — | the name | new |
| `Method (self)` | `fn brave_otter(self, ○)●ret {` / `●` / `}` (consumes the value) | — | the name | new |
| `Associated function` | `fn brave_otter(○)●ret {` / `●` / `}` (no receiver; called `T::brave_otter(…)`) | — | the name | new |
| `Constructor (new)` | `fn new(memory: Vec<u32>, width: usize) -> Self {` / `Self { memory, width }` / `}`: one parameter per field of the self type, in field order, with field-init shorthand (the shape of rust-analyzer's `generate_new`) | refused: `new is already defined on line 31`; hidden: the self type is not a named-field struct | the first parameter name | new |
| `Default constructor` | `fn new() -> Self {` / `Self::default()` / `}` | refused: `new is already defined on line 31`; gray: `BraveOtter doesn't implement Default`; fix: `Derive Default` (local type) | the name | new |
| `Associated const` | `const BRAVE_OTTER: ● = ●;` (the value is a const context and follows the type) | — | the name | new |
| `Layout ▸` | `Comment`, `Block comment`, `Blank line` | — | | `features/04 §15` |

Inside an impl, `Self` is offered first in every Type menu, and `Self { … }` / `Self::Variant` are offered next
to the type's own name in `Construct`.

On a method's `○params` dot the menu is `Add parameter` (`brave_otter: ●,` cursor on the name), plus, when the
method has no receiver yet, `Add &self`, `Add &mut self`, `Add self`. A receiver always goes first. Adding one
to an associated fn that this file already calls as `T::brave_otter(…)` is an advisory gray:
`3 calls in this file call it as T::brave_otter(…): they will need a receiver`. The calls are left alone and
the check reports them.

### Trait impl body `impl Trait for T { }`

| Leaf | Inserts | Gray / refuse / hide | Doodle |
|---|---|---|---|
| `Add all missing items` | every required item not present, with the defaults of "Traits and impls" | refused: `all required items are here` (every required item name is present: syntax plus the trait's item list) | new (`features/05` Carrying: E0046) |
| `Missing item ▸` | one leaf per missing required item, labelled by its signature: `fn next(&mut self) -> Option<Self::Item>` | placeholder `(nothing missing)` | new |
| `Override a provided method ▸` | the trait's provided methods; each is inserted with its signature and a tail hole | refused: `already on line 52` (E0201) | new |
| `Layout ▸` | | | |

Visibility is never offered inside a trait impl (E0449). The items' signatures come from the knowledge layers
(std tables, the crate index, `ItemsOf`), so this menu works before the oracle is ready.

### Trait body `trait T { }`

| Leaf | Inserts | Doodle |
|---|---|---|
| `Required method` | `fn brave_otter(&self, ○)●ret;` | new |
| `Provided method` | `fn brave_otter(&self, ○)●ret {` / `●` / `}` | new |
| `Associated type` | `type BraveOtter;` (Y on it: `Add bound` → `type BraveOtter: Clone;`) | new |
| `Associated const` | `const BRAVE_OTTER: ●;` | new |
| `Layout ▸` | | |

Y on a required method's `fn`: `Give it a default body` (adds `{` / tail hole / `}`); on a provided method:
`Make it required` (removes the body; gray: `the body is 12 lines: they will be deleted`).

### Struct body (named fields)

| Leaf | Inserts | Gray / refuse / hide | Cursor | Doodle |
|---|---|---|---|---|
| `Field` | `brave_otter: ●,` | the type menu lists owned types first (`String` before `&str`, `Vec<T>` before `&[T]`); choosing a reference adds `<'a>` to the struct ("Lifetimes" in the Type menu section) | the name | `features/04 §15` `Field` |
| `Public field` | `pub brave_otter: ●,` | — | the name | new |
| `Layout ▸` | | | | |

A tuple struct has no green dots inside: its list grows with the `○fields` dot (`struct S(i32, ○);`). Field
names are `Name(Field)` leaves: not Reference candidates, but renaming one offers to rename its uses through
the oracle (field accesses, struct literals, patterns), unlike Doodle (`features/04 §15`).

### Enum body

| Leaf | Inserts | Gray / refuse / hide | Cursor | Doodle |
|---|---|---|---|---|
| `Unit variant` | `BraveOtter,` | — | the name | `features/04 §15` `Member` |
| `Tuple variant` | `BraveOtter(●),` → after a fill `BraveOtter(i32, ○fields),` | — | the type hole | `features/04 §15` union `Variant` |
| `Struct variant` | `BraveOtter { brave_otter: ● },` (its fields grow with green dots when broken over rows) | — | the field type | new |
| `Variant = value` | `BraveOtter = ●,` (an integer hole; a const context) | gray: `needs #[repr(i32)] because some variants carry data (E0732)`; fix: `Add #[repr(i32)]` | the value | `features/04 §15` `Member = value` |
| `Layout ▸` | | | | |

Adding a variant to an enum that this file matches on makes those matches non-exhaustive (E0004). The status
says `3 matches in this file now miss BraveOtter (Y on match > Add missing arms)`. No other file is touched.

### Union body

`Field` inserts `brave_otter: ●,`. Its Type menu grays non-`Copy` types: `union fields must be Copy or
ManuallyDrop (E0740)`; fix: `Wrap in ManuallyDrop<…>`. Reading a union field is `unsafe`, so R13 wraps it.

### `unsafe extern "C" { }` body (Odin `foreign` block)

| Leaf | Inserts | Doodle |
|---|---|---|
| `Foreign function` | `pub fn brave_otter(○)●ret;` (unsafe to call: the edition-2024 default inside `unsafe extern`) | `features/04 §8` |
| `Foreign function (safe to call)` | `pub safe fn brave_otter(○)●ret;` | new |
| `Foreign static` | `pub static BRAVE_OTTER: ●;` | new |
| `Layout ▸` | | |

Parameter and return Type menus here list FFI-safe types first; a non-FFI-safe type is gray: `String isn't
FFI-safe (improper_ctypes): use *const c_char`.

---

## Statement menu (fn bodies)

### Opening, protocol, root groups

A on a green `Insert(Block)` dot (or A / Y on a `●` row) opens `Fill slot` with Doodle's temporary-line
protocol unchanged (`features/05 §1`): the dot becomes a temporary line; picking keeps exactly one statement
(or block); B removes the temporary line and leaves the file byte-identical, the cursor back on the dot
(`MenuPurpose::Insert`). The subtitle is `statement`.

Root, in authored order (10 groups; 12 with both context entries, so never sorted, R6):

```
[Else if | Else]     [ctx] only on the dot right after an if / if-let chain's closing }
Declarations      : Let | Let mut | Let (typed) | Let (assign later) | Let tuple | Let struct ▸ | Let else | Const | Use (here) ▸ | Item here ▸
Assignment        : Assign (=) | += | -= | *= | /= | %= | &= | |= | ^= | <<= | >>=
Calls             : Function ▸ | Method on… | Associated function ▸ | Macro ▸
Branching         : If | If / else | If let | If let / else | Match
Loops             : Loop | While | While let | For in range | For in range (inclusive) | For each (borrow) | For each (mutable) | For each (take) | For each with index | For key, value | Labeled loop
Jumps             : Return | Break | Break with value | Continue  (+ one Break / Continue entry per label in scope, innermost first)
Errors and Option : Try a call (?) ▸ | Let with ? ▸ | Let else | If let Some / Ok | Match Ok / Err | Return an error | Return None
Scope and blocks  : Block | Unsafe block | Labeled block | Drop now | Run at scope end (defer)
Compile-time      : Cfg-gated statement | If cfg!(…) | Static assertion
Layout            : Comment | Block comment | Blank line
```

Every group stays at 12 or fewer entries (Loops has 11, Assignment 11), so authored order holds inside groups
too. Doodle's Assignment group (16) and Operator menu (15) were sorted (`features/05 §2`); Rust's smaller
operator set avoids that. `Calls` shares its heat key with the value menu's `Call` (`features/05 §2`).

A statement menu is never offered between `match` arms (those dots open the Arm menu) and never after a tail
(R10).

The `[ctx]` entries (`features/05 §11`, `branch_extend_body_menu`):

| Entry | Inserts | Gray / refuse | Cursor |
|---|---|---|---|
| `Else if` | `} else if ●bool {` / `●` / `}` before the chain's `else` if it has one, else at its end; the temporary line is discarded | — | the condition |
| `Else` | `} else {` / `●` / `}` at the chain's end | refused: `this chain already ends in else (line 14)` (fixes `features/00` open question 8: grayed, not hidden) | the `●` row |

HUD at that dot: `A: add a statement, else if or else`.

### Declarations

| Leaf | Inserts | Gray / refuse / hide | Cursor | Doodle |
|---|---|---|---|---|
| `Let` | `let brave_otter = ●;` (no expectation: nothing grays) | — | the name | `features/05 §3` Variable (:=) |
| `Let mut` | `let mut brave_otter = ●;` | — | the name | new |
| `Let (typed)` | `let brave_otter: ● = ●;` The type hole is an inference position, so untouched it saves `let brave_otter: _ = todo!();`, which compiles. The value hole follows the type after every edit. | — | the name | `features/05 §3` Variable (typed) |
| `Let (assign later)` | `let brave_otter: ●;` (no zero value in Rust; it must be assigned on every path before use, E0381; until then it is an Assignment target without `mut`) | — | the name | `features/05 §3` Variable (no value) |
| `Let tuple` | `let (brave_otter, calm_otter) = ●;` Once the value's type is a tuple of arity n (facts at the fill, R5), the pattern becomes n generated names. | — | the first name | `features/05 §3` Multiple (:=) |
| `Let struct ▸` | pick a struct type (`SUGGESTED`: struct types of names in scope), then `let Point { x, y } = ●Point;` with shorthand bindings named after the fields (a clash gets a generated name: `x: brave_otter`) | — | the value | new (rust-analyzer `destructure_struct_binding` shape) |
| `Let else` | `let Some(brave_otter) = ● else {` / *diverging default* / `};` | see below | the value | `features/05` Carrying (or_break) |
| `Const` | `const BRAVE_OTTER: ● = ●;` (a local const item; the value is a const context) | — | the name | new |
| `Use (here) ▸` | the Use tree, scoped to this block: `use std::fmt::Write;`, `use Direction::*;` | as `Use ▸` | the line | `features/05 §23` (`using`) |
| `Item here ▸` | `Function`, `Struct`, `Enum`, `Constant`, `Static`, `Impl block`, `Use ▸` (the Add menu's leaves for items inside a body) | — | the name | new |

**Let else.** The diverging default comes from the context (P4): inside a loop `continue;`; in a fn returning
`Option` `return None;`; returning `Result` `return Err(●E);`; returning `()` `return;`; otherwise `return ●T;`.
The pattern follows the value's type while it is still generated (R5; "Patterns" below): `Option` gives
`Some(brave_otter)`, `Result` gives `Ok(brave_otter)`, another enum its first data-carrying variant. Gray on the
else block once it stops diverging: `the else of let … else must return, break, continue or panic` (rustc:
"`else` clause of `let...else` does not diverge"). Y on the `let` of a `let … else` (title `Let else`):
`Change pattern`, `Change value`, `Turn into match` (the shape of rust-analyzer's `convert_let_else_to_match`),
`Turn into if let` (the code after it moves into the `if let` body).

**Declare as** (Y on `let`, on the `=` of a `let`, or on `const`; title `Declare as`; `features/04 §22`,
`features/06 F21b`). The labels use the line's real name:

| Entry | Result | Gray / refuse |
|---|---|---|
| `let brave_otter = value   (type inferred)` | drops the annotation, keeps the value | refused when current: `already this form` |
| `let brave_otter: type = value   (choose the type)` | inserts a type hole and opens its Type menu at once; **B in that Type menu removes the type hole again** (fixes P9 exception 1) | refused when current |
| `let mut brave_otter = value   (can change)` | adds `mut` | refused when current |
| `const BRAVE_OTTER: type = value   (constant)` | rewrites to `const`, recasing the name and offering the rename prompt for its uses | gray: `calls make_list, which isn't a const fn (E0015)` |

B closes with no change (`MenuPurpose::DeclareAs`).

### Assignment

Picking any Assignment leaf builds `● = ●;` (or `● += ●;` …) and starts the target pick at once
(`features/05 §4`, `features/06 F15`, F19): banner `Pick what to assign to   -   D-pad move   A choose   B
cancel`; the cursor jumps to the nearest candidate above; Left/Right step candidates, Up/Down jump lines; A
opens `Assign to`; B removes the new line. With no candidate the line is removed and the status reads
`nothing to assign to here - declare one first (Declarations > Let mut)`.

**Candidates** (declaration sites of bindings in scope, from `Oracle::scope` or, before facts, the syntax
layer; D6):
- every `let` binding and parameter in scope, `mut` or not: an immutable one gets `mut` added when picked
  (R12, O20); the banner's second line says `count: i32  -  not mut yet: picking it adds mut (line 8)`;
- `let x: T;` bindings (first assignment needs no `mut`);
- `self` in a method (for `self.field = …`);
- `static mut` items (gray: `assigning a static mut needs unsafe`; R13 wraps it).
`static`, `const` and fn items are not candidates (they can never be assigned; hidden).

**Assign to** (title `Assign to`; B returns to picking):

| Entry | Shown when | Gray (advisory) |
|---|---|---|
| `x` | always | `x is a shared reference (&i32): use *x only with &mut` when `x: &T` and the value's type is `T`; fix: `Make x a &mut i32 parameter` when `x` is a parameter here |
| `*x   (what it points to)` | `x` is `&mut T`, `Box<T>`, `RefMut<T>`, or Unknown | `x is &i32: it can't change what it points to` when `x: &T` |
| `Field of x ▸` | `x` has visible fields (or Unknown) | fields nested to depth 3 (`features/06 F17`); in a `&self` method: `this method takes &self: it can't change self`; fix: `Change the receiver to &mut self` |
| `x[●]   T` | `x` implements `IndexMut` (or Unknown) | a map: `HashMap can't be assigned by index: use insert (Calls > Method on…)` |
| `x.0`, `x.1` … | `x` is a tuple | — |
| `Through a method ▸` | always | methods of `x` (`Methods of x`, below), lit when they return `&mut T`, gray otherwise: `entry returns Entry: extend it until it gives &mut`. The chain continues with `Extend` until it returns `&mut T`, then the builder writes the `*` a place needs: `*counts.entry(●).or_insert(●) += 1`, `*v.get_mut(●).unwrap() = ●`. |

The value hole then expects the target's type, except after `<<=` / `>>=` (any integer). The cursor ends on the
target (`features/05 §4`).

**Operators by trait** (Y on an assignment operator opens `Operator`; the current operator is refused:
`already +=`; `features/05 §5`, `features/06 F20b`):

| Operator | Trait | Primitive targets that take it |
|---|---|---|
| `=` | — | any place |
| `+=` `-=` `*=` `/=` `%=` | `AddAssign` `SubAssign` `MulAssign` `DivAssign` `RemAssign` | integers and floats; `+=` also `String` with a `&str` right side |
| `&=` `\|=` `^=` | `BitAndAssign` `BitOrAssign` `BitXorAssign` | integers, `bool` |
| `<<=` `>>=` | `ShlAssign` `ShrAssign` | integers (right side: any integer) |

When the target's type is a primitive written right there (a syntax stamp: `let mut ratio: f32 = …`), the
operators the table excludes are refused (Doodle refuses in this options menu, `features/05 §5`), with
`bool can't be used with +=`. For any other target type they are advisory: lit iff the oracle finds an impl of
the trait for the target (with the value's type as `Rhs` once filled), gray `Point has no += (no AddAssign
impl)` otherwise, and lit when the target type is unknown or an unbounded generic. Rust has no `&&=`, `||=`,
`%%=` or `&~=`.

### Calls

| Leaf | Inserts | Gray / refuse / hide | Cursor | Doodle |
|---|---|---|---|---|
| `Function ▸` | `brave_otter(●A, ●B);` with one typed hole per parameter (Rust has no defaults or variadics outside macros) | Sections: `RECENTLY USED` (fns called in this file), `This module` (file order; includes the current fn, so recursion works), `This crate ▸` (by module path; only items visible from here), `Dependencies ▸` (per crate), `std ▸` (module tree, functions only). Grouping per `features/07 §6`. The path is written per R11. Placeholder `(no functions in this module yet)`. | the first argument hole (the call name when there are none) | `features/05 §6` Internal procedure, From import |
| `Method on…` | starts the Reference pick for the receiver (title of the banner `Pick a value to call a method on   -   D-pad move   A use it   B cancel`), then `Methods of <x> ▸` (below); inserts `x.brave_otter(●);` | as Methods of x | the first argument hole | new |
| `Associated function ▸` | types in scope (this module, this crate, std, dependencies), then their receiver-less associated fns: `String::from`, `Vec::with_capacity`, `HashMap::new`, `Window::new`, this crate's `T::new` → `Type::f(●);` | — | the first argument hole | new |
| `Macro ▸` | see "Macros" in the Value menu | | | `features/05 §6` Built-in |

**The capture dot** (`features/05 §9`). A bare call statement whose result type is known (from the knowledge
layers or facts present at a pad-edge frame, R5) to be neither `()` nor `!` gets the pink `◉` in front. A on it:
`◉ v.len();` → `let brave_otter = v.len();` (cursor on the name); a tuple result → `let (brave_otter,
calm_otter) = pair();`. A `#[must_use]` result that is not captured shows rustc's reason on the dot: `result
must be used` (`unused_must_use`). LT+B on a captured name uncaptures (`let x = f();` → `f();`), as Doodle.
Y on a bare call statement whose result is `Result` / `Option` offers `Extend <call> ▸` with `Unwrap ▸`
(`?`, `.unwrap()`, `.expect("…")`), so error handling is reachable from the call itself.

### Branching

| Leaf | Inserts | Cursor | Doodle |
|---|---|---|---|
| `If` | `if ●bool {` / `●` / `}` | the condition | `features/05 §10` |
| `If / else` | `if ●bool {` / `●` / `} else {` / `●` / `}` | the condition | `features/05 §10` |
| `If let` | `if let ●pat = ● {` / `●` / `}` | the value (the pattern's default follows it) | `features/05 §10` If with setup |
| `If let / else` | the same plus `} else {` / `●` / `}` | the value | new |
| `Match` | `match ● {` / green `Insert(Arms)` dot / `}`; arms are generated when the scrutinee is filled (Patterns) | the scrutinee | `features/05 §12` Switch |

**Y on `if` / `else if`** (title `If` / `Else if`; refused entries stay; `features/05 §11`):

| Entry | Effect | Gray / refuse |
|---|---|---|
| `Add else if` | `} else if ●bool {` / `●` / `}` right after this branch | — |
| `Add else` | `} else {` / `●` / `}` at the end | refused: `this chain already ends in else (line 14)` |
| `Change condition` | refill as `bool`; B restores | — |
| `Turn into if let` | the condition becomes the value of `if let ●pat = <condition>`; bodies kept | — |
| `Add && let` (a let chain) | `if <cond> && let ●pat = ● {` | refused in editions before 2024: `let chains need edition 2024` |

**Y on `if let`**: `Add else if`, `Add else` (same refusal), `Change pattern`, `Change value`, `Turn into match`
(our own edit; the shape of rust-analyzer's `replace_if_let_with_match`), `Turn into let … else` (statement
position, when the else branch diverges; the shape of `convert_match_to_let_else`; refused otherwise: `the else
branch must return, break or continue first`). **Y on `else`**: `Add else if`.

**LT+B** (`features/05 §11`): on `if` the whole chain; on `else if` / `else` that branch (cursor to `if`); inside
the condition, the condition becomes a `bool` hole (already a hole: nothing); on a pattern part, that part
becomes `_`.

### Loops

| Leaf | Inserts | Gray / refuse / hide | Cursor | Doodle |
|---|---|---|---|---|
| `Loop` | `loop {` / `●` / `}` (the only loop that can `break` with a value) | — | `loop` | `features/05 §15` For (infinite) |
| `While` | `while ●bool {` / `●` / `}` | — | the condition | For (condition) |
| `While let` | `while let ●pat = ● {` / `●` / `}` (the pattern follows the value: `while let Some(brave_otter) = stack.pop()`) | — | the value | new |
| `For in range` | `for i in 0..● {` / `●` / `}` (`0` editable; the end hole shares the start's type) | — | `i` | For i in 0..<n |
| `For in range (inclusive)` | `for i in 0..=● {` / `●` / `}` | — | `i` | For i in 0..=n |
| `For each (borrow)` | `for item in &● {` / `●` / `}` (the `&` is part of the loop's iteration mode, not of the hole) | the hole grays values whose `&T` isn't `IntoIterator`: `i32 isn't something you can loop over` | `item` | For ... in |
| `For each (mutable)` | `for item in &mut ● {` / `●` / `}` | as above for `&mut T`; a non-`mut` collection gets `mut` (R12) | `item` | For &x in |
| `For each (take)` | `for item in ● {` / `●` / `}` (consumes the collection) | gray: `moves items (used again on line 40): borrow instead?`; fix: `Iterate by borrow (&items)` | `item` | For ... in |
| `For each with index` | `for (index, item) in ●.iter().enumerate() {` / `●` / `}` (index first, unlike Odin's `for x, i in`) | as borrow | `index` | For x, i in |
| `For key, value` | `for (key, value) in &● {` / `●` / `}` | gray: `a map gives (key, value) pairs; this is a Vec<i32>` | `key` | For x, i in (maps) |
| `Labeled loop` | `'outer: loop {` / `●` / `}` (label unique per fn) | — | the label | Labeled for |

The iterable hole (`features/05 §17`, `features/06 F25`) is lit for values whose type implements
`IntoIterator` **in the loop's iteration mode** (`accepts.iterable { by_ref, by_mut, by_val }`): borrow needs
`&T: IntoIterator` (`Vec`, arrays, slices, maps, sets, `Option`), mutable `&mut T: IntoIterator`, take
`T: IntoIterator`; ranges and iterators are iterable in take mode. `String` isn't iterable: gray `String isn't
something you can loop over: loop over its .chars()`; fix: `Use name.chars()`. An unfilled iterable (`todo!()`)
does not compile ("`!` is not an iterator"), a reloadable non-compiling state (D4).

The loop pattern follows the iterable's item type while it is still generated (R5): a 2-tuple item gives a
tuple of two names (`(index, item)` after `.enumerate()`, `(key, value)` over a map).

**Y on `for`** (title `Loop`; `features/05 §16`):

| Entry | Effect | Gray / refuse |
|---|---|---|
| `Iterate by ▸` | `borrow (&v)`, `mutable borrow (&mut v)`, `take (v)`, `.iter()`, `.iter_mut()`, `.into_iter()` | current refused: `already iterating by borrow` |
| `Add index (.enumerate())` / `Remove index` | adds `.enumerate()` and turns the pattern into `(index, <pattern>)`, or the reverse | — |
| `Reverse (.rev())` / `Don't reverse` | appends / removes `.rev()` | gray: `HashMap iteration can't be reversed` (not `DoubleEndedIterator`) |
| `Add label` / `Remove label` | `'outer: ` | refused: `a jump needs the label: it stays` (a `break 'outer` / `continue 'outer` inside; `features/05 §19`) |
| `Change pattern`, `Change iterable` | refill; B restores | — |

**Y on `while`**: `Add label`, `Change condition`, `Turn into loop` (`loop { if !cond { break; } … }`). **Y on
`while let`**: `Add label`, `Change pattern`, `Change value`. **Y on `loop`**: `Add label`, `Turn into while`
(`while ●bool { … }`).

**LT+B** on loop parts (`features/05 §18`): on the keyword, the whole loop; on the label, the label (refused while
a jump needs it; its jumps otherwise become bare); on the index of `(index, item)` (with `.enumerate()`),
removes `.enumerate()` and returns the pattern to `item` (the two are coupled, like Doodle's 2nd variable); on
the iterable, back to a hole; on a `while` condition, back to a `bool` hole.

### Jumps

| Leaf | Inserts | Gray / refuse | Cursor | Doodle |
|---|---|---|---|---|
| `Return` | `return ●T;` (`T` = the fn's or closure's return type); in a `()` fn `return;` | — | the value | `features/05 §20` |
| `Break` | `break;` | refused outside a loop: `not inside a loop (E0268)` | the line | `features/05 §20` |
| `Break with value` | `break ●T;` (`T` = the loop's or labeled block's value type) | refused unless the innermost breakable is a `loop` or labeled block: `only loop can break with a value; this is a while loop (E0571)` | the value | new |
| `Continue` | `continue;` | refused outside a loop: `not inside a loop (E0268)` | the line | `features/05 §20` |
| `Break 'outer`, `Continue 'outer` | `break 'outer;`, `continue 'outer;` (one pair per loop label in scope, innermost first) | — | the line | `features/05 §19` |
| `Break 'block with value` | `break 'block ●T;` (labeled blocks) | `Continue` never targets a block (E0696): no entry | the value | `features/05 §19` |

**[changed per O19]** Doodle grays `Break` outside a loop as advisory (`features/05 §20`); here it is refused.
**Y on `break` / `continue`** opens the label menu (the bare word plus one entry per label in scope; current
refused), plus `Add value` / `Remove value` on `break` inside `loop`. **Y on `return`**: `Use the tail instead`
(when it is the last statement of a fn body: `return x;` → tail `x`), `Add value` / `Remove value`.

### Errors and Option

Odin's `or_return` / `or_else` group was weak in Doodle (`features/05 §22`). Rust's version is driven by the
enclosing fn's return type.

| Leaf | Inserts | Gray / refuse / hide | Cursor | Doodle |
|---|---|---|---|---|
| `Try a call (?) ▸` | the Calls tree, every fn and method returning `Result` / `Option` lit and the rest gray (`returns usize: nothing to try`); inserts `brave_otter(●)?;` | gray (the whole leaf): `? needs this fn to return Result or Option (it returns ())`; fix: `Make brave_otter return Result<(), Box<dyn Error>>` (rewrites the return type, wraps existing `return` values and the tail in `Ok(…)`, adds `Ok(())` as the tail when there is none, adds the `use`; the shape of rust-analyzer's `wrap_return_type_in_result`). Error-type mismatch: gray `io::Error doesn't convert into ParseError (no From impl)`. | the first argument | `features/05 §22` or_return |
| `Let with ? ▸` | `let brave_otter = call(●)?;` | same grays | the name | or_return |
| `Let else` | as in Declarations | | | |
| `If let Some / Ok` | `if let Some(brave_otter) = ● {` / `●` / `}` (the pattern follows the value: `Ok(…)` for a `Result`) | — | the value | if err != nil |
| `Match Ok / Err` | `match ● {` / `Ok(brave_otter) => {` / `●` / `}` / `Err(error) => {` / `●` / `}` / `}`; for an `Option` value: `Some(brave_otter)` / `None` (R5: from the value's facts at the fill) | — | the value | if err != nil |
| `Return an error` | `return Err(●E);` (`E` = the fn's error type) | gray: `this fn returns i32, not a Result`; fix: as `Try a call` | the value | — |
| `Return None` | `return None;` | gray: `this fn returns i32, not an Option`; fix: `Make brave_otter return Option<i32>` | the line | — |

Expression-level forms (`x?`, `.unwrap()`, `.expect("…")`, `.unwrap_or(●)`, `.ok_or(●)?`) are Pass as
adapters (`Unwrap ▸`), never statements on their own.

### Scope and blocks

| Leaf | Inserts | Gray / refuse / hide | Cursor | Doodle |
|---|---|---|---|---|
| `Block` | `{` / `●` / `}` | — | the `{` line | `features/05 §23` |
| `Unsafe block` | `unsafe {` / `●` / `}` | — | `unsafe` | new |
| `Labeled block` | `'block: {` / `●` / `}` (a labeled block can `break 'block value`) | — | the label | `features/05 §19` |
| `Drop now` | `drop(●);` | the hole's `SUGGESTED` lists names in scope with non-`Copy` types; a `Copy` name is gray: `dropping a Copy value does nothing` | the value | `features/05 §20` (Defer) |
| `Run at scope end (defer)` | with `scopeguard` in the dependencies: `let _guard = scopeguard::guard((), \|_\| {` / `●` / `});` (**verify** the `scopeguard::guard(value, dropfn)` signature at the pinned version) | gray without the dependency: `needs the scopeguard crate (Use and modules > Add crate)` | the `●` row | `features/05 §20` Defer |

Y on `unsafe` (block): `Unwrap (keep the contents)`; gray: `line 31 still needs unsafe`.

### Compile-time and Layout

| Leaf | Inserts | Cursor | Doodle |
|---|---|---|---|
| `Cfg-gated statement` | `#[cfg(●cfg)]` above a `●` row | the cfg hole | `features/05 §14` |
| `If cfg!(…)` | `if cfg!(●cfg) {` / `●` / `}` (both branches must still type-check) | the cfg hole | `features/05 §14` |
| `Static assertion` | `const _: () = assert!(●bool, ○args);` | the condition | `features/05 §24` |
| `Comment` | `// brave otter` | the text | `features/05 §25` |
| `Block comment` | `/*` / `brave otter` / `*/` (no stray `●` row; fixes `features/05` open question) | the text | `features/05 §25` |
| `Blank line` | an empty line | the next dot | `features/05 §25` |

---

## Value menu for a hole of type T

### Root and pinned sections

A (or Y) on a `Value` or `Tail` hole, an `○args` dot, or a Y-refilled value opens `Fill slot` with the subtitle
`expects T  -  grayed options don't fit` (none without an expectation). Root, in authored order (11 groups, 12
with `Extend`, never sorted; Doodle's 14-entry root was always alphabetical, `features/06 F6`):

```
FIX                 pinned, only on a Y-refill of a part a diagnostic touches (R7)
SUGGESTED           pinned, ≤ 6 (R7)
[Extend <x> ▸]      [ctx] only on a Y-refill of a filled value: keep x and adapt it
Literal ▸         : Integer 0 | Float 0.0 | String "…" | Raw string r"…" | Char 'a' | Byte b'a' | Byte string b"…" | C string c"…" | true | false
Reference           starts the name pick
Call ▸            : Function ▸ | Method on… | Associated function ▸ | Macro ▸
Construct ▸       : Struct literal ▸ | Enum variant ▸ | Option / Result ▸ | Tuple | Array ▸ | Range ▸ | Default::default() | Unit ()
Constant ▸        : Of the expected type | In scope | This crate ▸ | std ▸ | Dependencies ▸
Operator ▸        : Arithmetic ▸ | Bitwise ▸ | Compare ▸ | Logic ▸
Convert ▸         : ● as T | T::from(●) | ●.into() | T::try_from(●)? | ●.to_string() | ●.to_owned() | ●.parse()?
Choose ▸          : if ● { ● } else { ● } | match ● { … } | if let ● = ● { ● } else { ● } | if cfg!(●) { ● } else { ● }
Closure ▸         : |x| ● | |x| { … } | move |x| ● | || ●
Block ▸           : { ● } | unsafe { ● } | loop { break ●; } | 'block: { ● } | async { ● } | const { ● }
Jump or panic ▸   : continue | break | return ● | panic!("…") | todo!("…") | unimplemented!("…") | unreachable!()
```

Literals move into a group, which costs one press against Doodle's top-level `Number` / `true` / `false`;
`SUGGESTED` gives it back by pinning the canonical literal for the expected type. `SUGGESTED` examples:

| Expected | Canonical first, then term search (examples) |
|---|---|
| `i32` | `0`, `count`, `items.len() as i32` |
| `bool` | `false`, `true`, `items.is_empty()` |
| `&str` | `""`, `name.as_str()`, `&name` |
| `String` | `String::new()`, `String::from("…")`, `name.clone()`, `format!("{}", ●)` |
| `Option<T>` | `None`, `Some(●T)` |
| `Result<T, E>` | `Ok(●T)`, `Err(●E)` |
| `Vec<T>` | `Vec::new()`, `vec![●T]` |
| `impl Fn(i32) -> bool` | `\|brave_otter\| ●bool` |
| `T` with `T: Default` | `T::default()` |
| `WindowOptions` (implements `Default`) | `WindowOptions::default()` |

After any fill the cursor goes to the first hole of what was inserted, else to the inserted value
(`features/06 F6`). A fill on an `○args` dot appends another `○args` with the same expectation. On a Y-refill,
the saved original is discarded at the pick and restored by B (`MenuPurpose::Refill`, `features/06 F21`).

### Leaves

Columns: what the leaf inserts, the type R it produces, when it is lit, and its gray. "Fits" means the oracle's
`Fits` answer for that leaf (`could_coerce_to`, then `could_unify_with`, then `impls_trait`; D8). `accepts.x` is a
bit of the expectation's `TyFacts.accepts` (D8). Every row is lit when the expectation is unknown (R2).

**Literal ▸** (`features/06 F6`: Number, String, true, false)

| Leaf | Inserts | R | Lit when | Gray reason; fix |
|---|---|---|---|---|
| `Integer 0` | `0` (editable; LT+A opens the keypad) | `{integer}` | `accepts.int_lit` (any integer type, or a generic / bound an integer satisfies) | `expects f64, not an integer: use Float 0.0`; fix: `Insert 0.0 instead`. Others: `expects &str, not a number` |
| `Float 0.0` | `0.0` | `{float}` | `accepts.float_lit` (`f32`, `f64`) | `expects i32, not a float: use Integer 0`; fix: `Insert 0 instead` |
| `String "…"` | `""` with an empty text leaf (dictation: free text, escaped for the literal) | `&'static str` | `accepts.str_lit` (`&str`, `impl AsRef<str>`, `impl AsRef<Path>`, `impl Into<String>`, `impl Display`, a generic bounded by traits `&str` implements) | `a string literal is &str; expects String`; fix: `Insert String::from("…") instead`. Others: `expects i32, not a string` |
| `Raw string r"…"` | `r""` (hashes added automatically when the text contains `"`: `r#"a"b"#`) | `&'static str` | as String | as String |
| `Char 'a'` | `'a'` (one character; dictation refuses more: `Heard "dog" - not one character`) | `char` | `accepts.char_lit` | `expects &str, not a char: use String "…"`; fix: `Insert "a" instead` |
| `Byte b'a'` | `b'a'` | `u8` | `accepts.byte_lit` | `expects char, not a byte` |
| `Byte string b"…"` | `b""` | `&'static [u8; N]` | Fits (`&[u8]`, `&[u8; N]`) | `expects &str, not bytes` |
| `C string c"…"` | `c""` | `&'static CStr` | Fits | `expects &str, not a C string` |
| `true`, `false` | `true` / `false` | `bool` | `accepts.bool_lit` | `expects i32, not a bool` |

**Reference** starts the name pick (below). It is refused when nothing is in scope: `nothing to reference here
yet - declare one first (Declarations > Let)` (Doodle grays it and ends the pick at once, `features/06 F15`).

**Call ▸** (`features/06 F7`)

| Leaf | Inserts | R | Lit when | Gray reason; fix |
|---|---|---|---|---|
| `Function ▸` | `brave_otter(●A, ●B)` (sections as in the statement menu's `Calls`) | its return type | Fits (return type against T; a generic return unifies) | `returns usize, expects i32`; fix (integers): `Append as i32` or, lossless, `Use i32::from(…)`. A fn returning `()`: `returns nothing, expects i32` |
| `Method on…` | receiver pick, then `Methods of <x> ▸`; `x.brave_otter(●)` | the method's return type | Fits | as Function |
| `Associated function ▸` | `Type::f(●)`: `String::from(●&str)`, `Vec::with_capacity(●usize)`, `HashMap::new()`, `Window::new(●&str, ●usize, ●usize, ●WindowOptions)` | its return type | Fits | as Function |
| `Macro ▸` | see "Macros" below | per macro | per macro | `println! returns (), expects i32` |

**Construct ▸**

| Leaf | Inserts | R | Lit when | Gray reason; fix | Doodle |
|---|---|---|---|---|---|
| `Struct literal ▸` | sections: the expected struct pinned first, spelled as this file spells it (and `Self { … }` inside its impl); `In scope`; `This crate ▸`; `Dependencies ▸`; `std ▸`. Inserts **every visible field** (R8): `Point { x: ●f32, y: ●f32 }`, one field per row past rustfmt's `struct_lit_width`, plus `○rest`. Tuple structs: `Meters(●f64)`; unit structs: `Marker`. When T is `&Point`, inserts `&Point { … }`. Placeholder `(no struct types in scope)`. | the struct | Fits | `expects Rect, not Point`; `has private fields: use a constructor (Call > Associated function)` (E0451); `#[non_exhaustive] in another crate: use a constructor` | `features/06 F8` |
| `Enum variant ▸` | sections: the expected enum's variants first, then `In scope`, `This crate ▸`, `std ▸` (`Ordering`, …), `Dependencies ▸`. `Direction::Left`, `Shape::Circle(●f64)`, `Shape::Rect { w: ●f64, h: ●f64 }`. Placeholder `(no enums in scope)`. | the enum | Fits | `expects Direction, not Shape` | `features/06 F10` |
| `Option / Result ▸` | `Some(●T)`, `None`, `Ok(●T)`, `Err(●E)` (inner holes typed from the expectation) | `Option<_>` / `Result<_, _>` | `accepts.none_some` / `accepts.ok_err` | `expects i32, not an Option`; fix (on `Some`): `Use the value without Some` (inserts the inner hole) | `features/06 F6` (`nil`) |
| `Tuple` | `(●, ●)`, arity from T; with no tuple expectation, 2 holes and `○fields` | `(_, _)` | T is a tuple, or Unknown | `expects i32, not a tuple` | `features/05 §21` |
| `Array ▸` | `[●, ○args]`, `[●; ●usize]`, `vec![●, ○args]`, `vec![●; ●usize]`, `Vec::new()` (the repeat count is a const context in `[●; ●]`) | `[_; N]` / `Vec<_>` | arrays: T is an array or `&[U]` (inserted as `&[…]`); `vec!` / `Vec::new()`: T is `Vec<_>` | `[…] isn't a Vec: use vec![…]`; fix: `Insert vec![…] instead` | `features/04 §16` |
| `Range ▸` | `●..●`, `●..=●`, `●..`, `..●`, `..` (ends typed like each other) | `Range<_>` … | T is the matching range type, `impl RangeBounds<_>`, an iterable hole, or a slice index | `expects i32, not a range` | `features/06 F14` |
| `Default::default()` | `Default::default()` | T | `accepts.default` | `Rect doesn't implement Default`; fix: `Derive Default on Rect` (local type) | new |
| `Unit ()` | `()` | `()` | `accepts.unit` | `expects i32, not ()` | new |

**Constant ▸** (`features/06 F9`, F10)

| Section | Content | Gray |
|---|---|---|
| `Of the expected type` | associated consts of T from the knowledge layers: `i32::MAX`, `i32::MIN`, `u8::BITS`, `f64::EPSILON`, `f64::INFINITY`; this crate's `impl` consts of T | — |
| `In scope` | `const` and `static` items visible here (this module, `use`d) | `MAX_HP is u32, expects i32`; fix: `Use i32::from(MAX_HP)` (lossless) or `Append as i32` |
| `This crate ▸` | other modules' visible consts (path per R11) | as above |
| `std ▸` | `std::f64::consts::PI`, `std::env::consts::OS`, … (module tree, constants only) | as above |
| `Dependencies ▸` | per crate | as above |

Placeholder `(no constants here)`. In a const context, plain immutable statics stay lit: since Rust 1.83
(`const_refs_to_static`) a constant may read them (`static S: usize = 1; const C: usize = S;` and `[0; S]`
compile on rustc 1.96.1). Gray (advisory) only: a `static mut` (evidence: syntax): `a static mut can't be read
in a constant` (E0080 "constant accesses mutable global memory"); a static whose type has interior mutability,
when facts say so (evidence: oracle): `a static with interior mutability can't be read in a constant`; lit while
Unknown.

**Operator ▸** (`features/06 F11`; operators by trait, `features/06 (b)`)

| Group | Leaves | R | Lit when | Gray reason |
|---|---|---|---|---|
| `Arithmetic ▸` | `a + b`, `a - b`, `a * b`, `a / b`, `a % b`, `-a` | per impl | T is numeric; `String` (for `+`: `String + &str`); or Fits finds `std::ops::{Add, …}` with `Output = T` | `bool has no +` |
| `Bitwise ▸` | `a & b`, `a \| b`, `a ^ b  (xor)`, `a << b`, `a >> b`, `!a  (not)` | per impl | T is an integer; `bool` for `& \| ^ !`; or the trait impl | `f64 has no \|` |
| `Compare ▸` | `a == b`, `a != b`, `a < b`, `a <= b`, `a > b`, `a >= b` | `bool` | `accepts.bool_lit` | `a comparison gives bool, expects i32` |
| `Logic ▸` | `a && b`, `a \|\| b`, `!a` | `bool` | `accepts.bool_lit` | `expects i32, not a bool` |

A binary leaf replaces the hole with `●L op ●R`; a unary one with `op●`. Operand expectations are in "Where each
hole's expectation comes from". An operand filled with another operator of the same precedence flattens into a
chain `a | b | c` (one operator unit, `features/06 F11`); parentheses follow Rust precedence (R9: unary `- ! * &`,
`as`, `* / %`, `+ -`, `<< >>`, `&`, `^`, `|`, comparisons (non-associative), `&&`, `||`, ranges). Rust has no
`&~` (write `a & !b`). `==` on a type without `PartialEq` is gray: `Point can't be compared with ==`; fix:
`Derive PartialEq on Point`. A `todo!()` operand does not compile until filled (D4).

**Convert ▸** (`features/06 F12`)

| Leaf | Inserts | R | Lit when | Gray reason; fix |
|---|---|---|---|---|
| `● as T` | `● as i32` (T = the expectation; the inner hole has no expectation) | T | T is a primitive cast target: numeric, `char` (from `u8`), an integer (from `bool`, `char` or a fieldless enum), a raw pointer | `as only converts primitive types (E0605)`; fix: `Use i32::from(…) instead` |
| `T::from(●)` | `i32::from(●)` | T | lit (the inner hole is Unknown) | — |
| `●.into()` | `●.into()` | T | lit | — |
| `T::try_from(●)?` | `i32::try_from(●)?` | T | Fits for `TryFrom`, and the fn returns a `Result` | `? needs this fn to return Result or Option (it returns ())`; fix: `Make brave_otter return Result<(), Box<dyn Error>>` |
| `●.to_string()` | `●.to_string()` | `String` | T accepts `String` | `gives String, expects &str: use .as_str()` |
| `●.to_owned()` | `●.to_owned()` | the owned form | T is an owned type with a borrowed form (`String`, `Vec<T>`, `PathBuf`) | `expects i32` |
| `●.parse()?` | `●.parse()?` (inner hole expects `&str`) | T | Fits for `FromStr`, and the fn returns a `Result` | as `try_from` |

`transmute` is never offered (`unsafe`, rarely right; Deferred). Odin's `auto_cast` maps to `.into()`.

**Choose ▸** (`features/06 F12a`). Always lit: the branches are typed T and the condition `bool`.

| Leaf | Inserts |
|---|---|
| `if ● { ● } else { ● }` | `if ●bool { ●T } else { ●T }` (one row while it fits rustfmt's `single_line_if_else_max_width`, else broken) |
| `match ● { … }` | `match ● {` / arms `Pat => ●T,` / `}` (expression arms, generated when the scrutinee is filled; Patterns) |
| `if let ● = ● { ● } else { ● }` | `if let ●pat = ● { ●T } else { ●T }` |
| `if cfg!(●) { ● } else { ● }` | `if cfg!(●cfg) { ●T } else { ●T }` (Odin's `a when c else b`; both branches must type-check) |

**Closure ▸** (`features/06 (c)` closures)

| Leaf | Inserts | Lit when | Gray reason |
|---|---|---|---|
| `\|x\| ●` | `\|brave_otter\| ●R` | `accepts.closure(n)`: T is `impl Fn*`, `Box<dyn Fn*>`, a fn pointer, or a generic bounded by `Fn*` | `expects i32, not a function` |
| `\|x\| { … }` | `\|brave_otter\| {` / `●R` / `}` (a block body with a tail hole) | same | same |
| `move \|x\| ●` | `move \|brave_otter\| ●R` | same | same |
| `\|\| ●` | `\|\| ●R` | same, arity 0 | `map's closure takes 1 argument` when the expected arity is known and not 0 |

When the expected type fixes the arity n (facts at the pick, R5), the parameters are pre-filled with n
generated names (no type annotations: inference supplies them); a 2-tuple argument gets a tuple pattern
`|(key, value)|`. The body expects `R`. When the bound includes `'static` (`std::thread::spawn`), the closure is
inserted as `move |…|` (prevents E0373). Closure parameters are pattern holes.

**Block ▸**

| Leaf | Inserts | R | Lit when | Gray reason |
|---|---|---|---|---|
| `{ ● }` | `{` / `●T` / `}` (a green dot above the tail lets statements in) | T | always | — |
| `unsafe { ● }` | `unsafe {` / `●T` / `}` | T | always | — |
| `loop { break ●; }` | `loop {` / `break ●T;` / `}` | T | always | — |
| `'block: { ● }` | `'block: {` / `●T` / `}` | T | always | — |
| `async { ● }` | `async {` / `●` / `}` | `impl Future` | Fits for `Future` | `async { } gives a Future, expects i32` |
| `const { ● }` | `const {` / `●T` / `}` (the inside is a const context) | T | always | — |

**Jump or panic ▸** (all have type `!`, so all fit every hole; Doodle had none of these as values)

| Leaf | Inserts | Refused |
|---|---|---|
| `continue` | `continue` | outside a loop: `not inside a loop (E0268)` |
| `break` | `break` | outside a loop: `not inside a loop (E0268)` |
| `return ●` | `return ●T` (T = the fn's return type) | — |
| `panic!("…")` | `panic!("")` | — |
| `todo!("…")` | `todo!("")` (a bare `todo!()` would be a hole again, D4) | — |
| `unimplemented!("…")` | `unimplemented!("")` | — |
| `unreachable!()` | `unreachable!()` | — |

### The gray rules in one table (the Rust form of `features/06 F4`)

Rule 0 for every row: an unknown expectation, or a candidate of type `!`, is lit (R2).

| Candidate | Produces | `Fit::Yes` when | `Fit::No` reason (example) | Evidence |
|---|---|---|---|---|
| integer literal | `{integer}` | `accepts.int_lit` | `expects f64, not an integer: use Float 0.0` | oracle, or a syntax stamp |
| float literal | `{float}` | `accepts.float_lit` | `expects i32, not a float: use Integer 0` | oracle, or a syntax stamp |
| string literals | `&'static str` | `accepts.str_lit` | `a string literal is &str; expects String` | oracle, or a syntax stamp |
| char / byte / bool literals | `char` / `u8` / `bool` | `accepts.char_lit` / `byte_lit` / `bool_lit` | `expects &str, not a char` | oracle, or a syntax stamp |
| `None` / `Some` / `Ok` / `Err` | `Option<_>` / `Result<_, _>` | `accepts.none_some` / `ok_err` | `expects i32, not an Option` | oracle |
| `()` | `()` | `accepts.unit` | `expects i32, not ()` | oracle |
| `Default::default()` | T | `accepts.default` | `Rect doesn't implement Default` | oracle |
| closures | closure | `accepts.closure(n)` | `expects i32, not a function` | oracle |
| fn / method / associated fn call | return type | `Fits`: coerce, then unify, then bound | `returns usize, expects i32` | oracle |
| macro | per macro table | per row | `println! returns (), expects i32` | knowledge + oracle |
| struct literal, enum variant, constant | its type | `Fits` | `expects Rect, not Point` | oracle |
| operator group | per impl | numeric / bool rules, else `Fits` on the trait | `bool has no +` | oracle |
| comparison, logic | `bool` | `accepts.bool_lit` | `a comparison gives bool, expects i32` | oracle |
| `as` cast | T | T is a primitive cast target | `as only converts primitive types (E0605)` | oracle |
| `T::from`, `.into()` | T | always | — | — |
| `try_from(…)?`, `.parse()?`, `x?` | T | the trait holds, and the fn returns a compatible `Result` / `Option` | `? needs this fn to return Result or Option (it returns ())` | oracle (the return type) |
| `async { }`, `.await` | Future / output | `Future` holds; `.await` inside an async context | `.await needs an async fn`; fix: `Make run async` | syntax (context) + oracle |
| a name (Pass as) | its type, adapted | per entry (below) | per entry | oracle, diagnostics, local analysis |

Unit-returning calls on generic or `impl Display` holes need no special rule (Doodle grays them on `any`,
`features/06 F4`): `()` fails `impl Display`'s bound and fits an unbounded generic (Unknown).

### Gray-with-fix catalogue

Every advisory fix here is one edit in the open file (R3, R14). A fix that would need another file is replaced by
a reason that says where (`Point is in src/geometry.rs`).

| Situation | Reason | `Fix it:` |
|---|---|---|
| `"…"` on a `String` hole | `a string literal is &str; expects String` | `Insert String::from("…") instead` |
| a `u8` binding on an `i32` hole | `small is u8, expects i32` | `Use i32::from(small)` (lossless conversions have a `From` impl) |
| a `usize` binding on an `i32` hole | `count is usize, expects i32` | `Use i32::try_from(count)?` in a fn returning `Result`, else `Append as i32` (the reason line warns `as can cut off large values`) |
| a value moved earlier | `moved on line 12 (into consume)` | `Clone it: x.clone()` (when `Clone`), else `Borrow it: &x` |
| a value used again later | `moves x, but line 30 uses it again` | `Borrow it: &x` / `Clone it: x.clone()` |
| `?` / `try_from(…)?` / `.parse()?` in a fn returning `()` | `? needs this fn to return Result or Option (it returns ())` | `Make brave_otter return Result<(), Box<dyn Error>>` (wraps returns and the tail in `Ok`, adds `Ok(())`, adds the `use`) |
| `.await` outside an async context | `.await needs an async fn` | `Make run async` |
| `{:?}`, `dbg!`, `assert_eq!` on a type without `Debug` | `Point doesn't implement Debug` | `Derive Debug on Point` |
| `{}` on a type without `Display` | `Point doesn't implement Display: use {:?}` | `Use {:?} instead` |
| `==` on a type without `PartialEq` | `Point can't be compared with ==` | `Derive PartialEq on Point` |
| `.clone()` on a type without `Clone` | `Point can't be cloned` | `Derive Clone on Point` |
| `Default::default()` without `Default` | `Rect doesn't implement Default` | `Derive Default on Rect` |
| a trait method whose trait is not in scope | `needs use std::io::Write` | (done automatically at the pick, R11) |
| a call to an `unsafe fn` | never gray | (auto-wrap, R13) |
| a non-const call in a const context | `make_list isn't a const fn (E0015)` | `Make make_list const` (only when defined in this file and its body allows it) |
| a non-const name in a const context | `n is a let binding, not a constant (E0435)` | `Make n a const` (the shape of rust-analyzer's `promote_local_to_const`) |
| `&mut self` method on `self` in a `&self` method | `this method takes &self: it can't change self` | `Change the receiver to &mut self` |
| a struct field type `&str` | (never gray) | (auto `'a`, Type menu) |

Derive fixes are offered only when the type is declared in the open file (P12); otherwise the reason says where.

### Const contexts (Odin's `when` / `#unroll` constness, `features/06 F23`, F24)

Const contexts: `const` / `static` initializers, array lengths `[T; ●]` and repeat counts `[●; ●]`, const generic
arguments, enum discriminants, `const { }` blocks, the condition of `const _: () = assert!(…)`, and `const fn`
bodies (partly). They are known from syntax (D6). In them:
- calls to non-`const fn`s are gray: `make_list isn't a const fn (E0015)` (whether a fn is `const` comes from
  the knowledge layers);
- `let` bindings and parameters are gray in the pick: `n is a let binding, not a constant (E0435)`; `const`
  items, const generic parameters, literals and `const fn` calls stay lit;
- methods are lit only when they are `const fn`;
- an unfilled hole saves as `todo!()` and fails const evaluation (E0080), so the file does not compile until
  it is filled (D4).

### Reference: the name pick

Doodle's pick, unchanged in mechanics (`features/06 F15`): the menu closes, a banner reads
`Pick a name to reference   -   D-pad move   A use it   B cancel`, the target hole gets a pulsing ring,
Left/Right step candidates and wrap, Up/Down jump to the first candidate on the previous / next line that has
one, A opens `Pass as`, B cancels (the hole stays empty; a Y-refill's original comes back). The banner gets a
second line for the highlighted candidate: its type and either its best adapter or its gray reason:
`count: usize  -  fits as count as i32`, `items: Vec<Item>  -  moved on line 12 (into consume)`,
`total: i32  -  not mut yet: &mut adds mut (line 8)`.

**Candidates** are the *declaration sites* of the value names visible at the hole, one per binding, in file
order, starting on the nearest one above: locals, parameters, `self`, pattern bindings, `const` and `static`
items and fn items declared in this file. They come from `Oracle::scope(at)` (rust-analyzer's
`SemanticsScope::process_all_names`, D6) and, before facts, from the syntax layer. Shadowed bindings are not
offered (only the visible one). The binding a statement is declaring is not offered to its own initializer, but
a binding it shadows is (`let guess: u32 = match guess.trim().parse()` offers the earlier `guess`). Names
declared earlier on the hole's own line are offered (closure parameters, `if let` bindings, an earlier `let` of
a let chain). This fixes Doodle's own-line and number-literal candidates (`features/06` gaps 6, 20). Types,
modules, traits and macros are not values; they are reached through `Call`, `Construct` and `Constant`.

### Pass as

Title `Pass as` (≤ 12 entries, authored order; B returns to the pick). An entry whose precondition is a type
property is shown when the picked name's type is Unknown or satisfies it, and hidden when the type is known and
does not. This is the one sanctioned hiding by oracle facts (D8, R3), with Doodle's precedent (`features/06
F16-F17`); it is decided when the menu opens and frozen, and the same rule covers `Assign to`, `Unwrap ▸` and
`View ▸`. The highlight starts on the first lit entry. The bare name is type-grayed too (fixes
`features/06` gap 5).

| # | Entry | Shown when | Gray (advisory) when; fix |
|---|---|---|---|
| 1 | `x   (move)`, `x   (copy)` for `Copy` types, `x` for references | always | doesn't fit T (`count is usize, expects i32`; fixes above); moved earlier: `moved on line 12 (into consume)`; used again later and not `Copy`: `moves x, but line 30 uses it again`; fix: `Borrow it: &x` / `Clone it: x.clone()` |
| 2 | `&x   (borrow)` | always | `&X` doesn't coerce to T (deref coercion counts: `&String` fits `&str`, `&Vec<U>` fits `&[U]`) |
| 3 | `&mut x   (borrow to change)` | always | T isn't `&mut _`. A binding without `mut` is **lit** and gets `mut` (R12); where it can't (`x: &T`), gray: `x is a shared reference: it can't be borrowed as &mut` |
| 4 | `*x   (the value it points to)` | `x` is a reference, `Box` or `Deref` | the pointee isn't `Copy` and T is by value: `can't move out of a reference: use x.clone()`; fix: `Clone it: x.clone()` |
| 5 | `x.clone()   (your own copy)` | `X: Clone` | the result doesn't fit T |
| 6 | `Convert ▸` | always | `x.into()`, `T::from(x)`, `x as T` (primitives only), `x.to_string()`, `x.to_owned()`, `T::try_from(x)?`, `x.parse()?` (`&str` / `String`); grays as in Convert ▸ |
| 7 | `Unwrap ▸` | `X` is `Option`, `Result` or a `Future` | table below |
| 8 | `Wrap ▸` | T is `Option`, `Result`, `Box`, `Rc`, `Arc`, `Vec`, `RefCell` of something X fits | `Some(x)`, `Ok(x)`, `Err(x)`, `Box::new(x)`, `Rc::new(x)`, `Arc::new(x)`, `vec![x]`, `RefCell::new(x)` |
| 9 | `View ▸` | `X` is a `String`, `Vec`, array, slice, map, set, `Option`, `PathBuf`, … | table below |
| 10 | `Field of x ▸` | `X` has fields visible here (or `x` is a tuple) | per field by fit; nested to depth 3 (`features/06 F17`); tuple fields `x.0`; a struct field stays lit while anything inside it fits; when T is a reference, `&x.field` entries follow each field (`features/06 F17` `&f` leaves) |
| 11 | `Methods of x ▸` | always (filled from `MembersOf`; `(looking up methods of x...)` until then) | below |
| 12 | `x[●]   Elem` | `X: Index` | the element type doesn't fit; the index hole expects `usize`, or `&K` for maps (labelled `m[&key]   V  (panics if missing)`; `get` is in Methods) |

For a fn item, Pass as offers `brave_otter   (the function itself)` and `brave_otter(…)   (call it)`.

**Unwrap ▸** (`features/05 §22` or_return / or_else)

| Entry | Shown when | Gray; fix |
|---|---|---|
| `x?` | `Option` or `Result` | the fn doesn't return a compatible `Result` / `Option`: `? needs this fn to return Result or Option (it returns ())`; fix: `Make brave_otter return Result<(), Box<dyn Error>>`; error type without `From`: `io::Error doesn't convert into ParseError (no From impl)` |
| `x.unwrap()` | `Option` or `Result` | — (the reason line notes `panics if None`) |
| `x.expect("…")` | `Option` or `Result` | — |
| `x.unwrap_or(●T)` | `Option` or `Result` | — |
| `x.unwrap_or_default()` | inner type implements `Default` | `Window doesn't implement Default` |
| `x.unwrap_or_else(\|\| ●T)` | `Option` or `Result` | — |
| `x.ok_or(●)?` | `Option` | as `x?` |
| `x.ok()` | `Result` | — |
| `x.await` | a `Future` | outside an async context: `.await needs an async fn`; fix: `Make run async` |

**View ▸** (hidden entries never apply to the type; more than 12 visible would sort, P23)

| Entry | Applies to |
|---|---|
| `x.as_str()` | `String` |
| `x.as_slice()` | `Vec`, arrays |
| `&x[..]` | `String`, `Vec`, arrays, slices |
| `x.as_ref()`, `x.as_deref()`, `x.as_mut()` | `Option`, `Result`, smart pointers |
| `x.iter()`, `x.iter_mut()`, `x.into_iter()` | collections |
| `x.chars()`, `x.bytes()`, `x.lines()` | `str`, `String` |
| `x.keys()`, `x.values()` | maps |

**Moves** (new). "Moved" knowledge has three sources, combined, all advisory:
1. the last `cargo check`: E0382 "borrow of moved value" carries a span labelled `value moved here`
   (D10); a name with such a diagnostic is grayed in later picks with `moved on line N`;
2. a local analysis over the CST: a binding whose type is not `Copy` (oracle `is_copy`) used by value (a `let`
   initializer, a by-value argument, a `self` receiver, a `for` in take mode) in an earlier statement of the same
   or an enclosing block, not inside a branch or loop that might not run, and not reassigned since;
3. otherwise Unknown: not gray.

rust-analyzer has no use-after-move diagnostic (its documented diagnostics list has none; `01` D10), which is why
`cargo check` is the authority.

### Methods of x (method chains)

`Methods of x ▸` lists `Oracle::members(receiver)` (`MembersOf`: visible fields and methods over the receiver's
autoderef chain, grouped by source; D6, D7.3(c)). Layout of the menu (`features/07 §6` rules inside each group):

1. `RECENTLY USED`: methods this file already calls, matched by canonical path.
2. `<Type> (own)`: inherent methods of the receiver type (`Vec<Item> (own)`).
3. one group per autoderef layer: `via deref: [Item]`.
4. one group per implemented trait in scope: `Iterator`, `Clone`, `Ord`, `RngExt`, … (in rand 0.10.1,
   `random_range` is provided by `RngExt`, the user-level extension trait implemented for every `Rng`; NS1's
   `use rand::prelude::*;` brings both into scope; docs.rs, 2026-11-24).
5. `Conversions`: blanket `From` / `Into` / `TryFrom` / `TryInto` / `ToString` / `ToOwned` / `AsRef` / `Borrow`.
6. `Needs a use (n)`: traits implemented but not in scope; picking one also adds the `use` (R11), and B removes
   it with the pick.
7. `Search by voice`: opens the voice-search overlay (see "Add crate"); the dictated words filter the full
   `MembersOf` list, and the user still picks a listed method with A. Nothing outside the oracle's list is ever
   inserted (P4: references are picked, never invented).

With more than 12 groups, the trait groups go into `More traits ▸`, so the fixed groups keep their positions.
Leaves are labelled `len()   usize`, `push(value)   ()`, `get(index)   Option<&Item>`. Hidden: `#[doc(hidden)]`,
unstable items on a stable toolchain, items for other targets. Gray:
- by return fit (R2): `returns usize, expects i32`; a group is gray iff nothing in it fits;
- `deprecated: use X`;
- an unsatisfied where-clause: `needs T: Ord`; fix: `Derive Ord …` when T is local;
- a `self` receiver on a non-`Copy` name used later: `moves x, but line 30 uses it again`.
A `&mut self` method on a binding without `mut` is lit and adds `mut` (R12).

Inserting writes `x.method(●A, ●B)` with typed argument holes; the cursor goes to the first hole. Generic
receivers (`x: T` with `T: Display`) list only the bound traits' methods. Free functions under `Call` use the
same grouping with "module" in place of Doodle's "source file".

**Continuing a chain: `Extend <x> ▸`.** There is no permanent "chain dot" (it would put a dot after every
value). Y on any filled value opens its refill menu with `[ctx] Extend <x> ▸` first. Extend is Pass as applied to
the current value, which is kept (entry 1 is hidden there; B goes back), plus `Operator ▸` with `x` as the left
operand (`x && ●`, `x + ●`, `x == ●`). So `v` → Y → Extend → `Methods of v` → `iter()` → Y → Extend → `map(…)`
→ Y → Extend → `collect()` builds `v.iter().map(|brave_otter| ●).collect()`. Long chains break one `.call()` per
row past rustfmt's `chain_width` (D5). LT+B on a method name in a chain removes that link (`v.iter().map(f).sum()`
without `map(f)` is `v.iter().sum()`); LT+B on the chain's root turns the whole chain into a hole.

**Turbofish.** When inference needs it (`collect()`, `parse()`, `into()` with an ambiguous target), the check
reports E0282 / E0283 "type annotations needed". The method's stop shows that reason, and Y's `FIX` section offers
`Say the type: ::<●>` (the shape of rust-analyzer's `add_turbo_fish`) and `Annotate the let: let x: ● = …` (the
shape of `add_explicit_type`). The turbofish argument is a type hole in an inference position (saved `_`;
`collect::<Vec<_>>()` compiles).

### Macros (`Call > Macro ▸`; Doodle's Built-in, `features/05 §6`, `features/07 §7`)

A hand-written table in `doodle-knowledge` (`Knowledge::macro_shape`: arity, format-string argument, forms,
result type; D9) gives each built-in macro's shape. Groups in this order:

| Group | Leaf | Inserts | R | Holes and rules |
|---|---|---|---|---|
| `Print ▸` | `println!`, `print!`, `eprintln!`, `eprint!` | `println!("")` | `()` | The format string is a string leaf (dictation, word by word). Inserting a placeholder at a word dot adds its argument hole (below). Y on the macro: `Add a value ({})` appends ` {}` and a hole. |
| | `dbg!` | `dbg!(●)` | the argument's type | the argument needs `Debug` (fix: derive) |
| `Format ▸` | `format!` | `format!("")` | `String` | as `println!` |
| | `write!`, `writeln!` | `write!(●, "")` | `fmt::Result` or `io::Result<()>` | the first hole expects a `fmt::Write` or `io::Write` target (`f` inside a `Display` impl is `SUGGESTED`) |
| `Collections ▸` | `vec![…]` | `vec![●, ○args]` | `Vec<_>` | elements share one type |
| | `vec![x; n]` | `vec![●; ●usize]` | `Vec<_>` | |
| `Assert ▸` | `assert!` | `assert!(●bool, ○args)` | `()` | the optional message is a format string |
| | `assert_eq!`, `assert_ne!` | `assert_eq!(●, ●)` | `()` | the second hole expects the first's type; both need `PartialEq` + `Debug` (fix: derive) |
| | `debug_assert!`, `debug_assert_eq!`, `debug_assert_ne!` | as above | `()` | |
| | `matches!` | `matches!(●, ●pat)` | `bool` | the pattern hole is typed by the first argument |
| `Panic ▸` | `panic!`, `todo!`, `unimplemented!`, `unreachable!` | `panic!("")`, `todo!("")`, `unimplemented!("")`, `unreachable!()` | `!` | |
| `Compile-time ▸` | `cfg!` | `cfg!(●cfg)` | `bool` | Odin's built-in constants (`ODIN_OS`) |
| | `env!`, `option_env!` | `env!("")` | `&'static str` / `Option<&'static str>` | |
| | `include_str!`, `include_bytes!` | `include_str!("")` | `&'static str` / `&'static [u8; N]` | the path is a string leaf; Files-relative |
| | `concat!`, `stringify!`, `file!`, `line!`, `column!`, `module_path!` | `line!()` … | per macro | |
| `This crate ▸` | local `macro_rules!` | `brave_otter!()` | Unknown | defined below the dot: gray `defined below, on line 88: move it up (Refactor > Grab)` |
| `Dependencies ▸` | macros of dependencies (`ItemsOf` macro items) | `name!(○args)` | Unknown | unknown shape: one `○args` dot of untyped holes (Doodle's `Other (name it yourself)`) |

**Format strings stay in sync with their arguments (new; `features/08` Carrying (c)).** Word-by-word mode on the
format string of a table macro offers `Insert` entries `{}  Display`, `{:?}  Debug`, `{:#?}  pretty Debug`,
`{:x}`, `{:X}`, `{:o}`, `{:b}`, `{:e}`, `{:p}`, width / fill / precision forms (`{:>8}`, `{:08.3}`, `{:+}`),
`{{` / `}}`, and `{name}` captures listed from the names in scope. Inserting a positional placeholder adds an
argument hole at the matching position; LT+B on an argument removes its placeholder; a `{name}` capture takes no
argument. `{}` on an argument type that is not `Display` is gray: `Point doesn't implement Display: use {:?}`;
`{:?}` on one that is not `Debug` is gray: `Point doesn't implement Debug`; fix: `Derive Debug on Point`. A count
mismatch never reaches the file, because the two are edited together. Any other macro call (unknown shape, DSL
macros) is one opaque unit: it can be moved, copied, deleted and replaced through Y, and its expansion shows
read-only in Docs (LT+Y).

---

## Type menu, generic params, lifetimes, trait bounds and where clauses

### The Type menu (a `Type` or `Ret` hole)

Title `Fill slot`, subtitle `a type` (`the result type` on `ret`; `expects a type implementing Display` when a
bound constrains it). Root, authored order (11 entries; Doodle's Type submenu also keeps its order,
`features/06 F13`):

```
SUGGESTED              pinned: the expected or inferred type (= Vec<i32>), the E0121 suggestion, types used in this file
Primitives ▸         : Integers ▸ (i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize) | f32 | f64 | bool | char | () unit | ! never (return position only)
Text ▸               : String | &str | &'static str | char | PathBuf | &Path | Box<str> | OsString
Collections ▸        : Vec<●> | [●; ●] array | &[●] slice | HashMap<●, ●> | HashSet<●> | BTreeMap<●, ●> | BTreeSet<●> | VecDeque<●> | (●, ●) tuple
References and pointers ▸ : &● | &mut ● | Box<●> | Rc<●> | Arc<●> | RefCell<●> | Cell<●> | Mutex<●> | *const ● | *mut ●
Option and Result ▸  : Option<●> | Result<●, ●> | io::Result<●> | Result<●, Box<dyn Error>>
This crate ▸         : this module's types first, then other modules (path per R11)
Dependencies ▸       : one group per crate
std ▸                : the std module tree, types only
[Generic parameters] [ctx] only where some are in scope: T, U, Self (lifetimes appear under References and pointers > &●)
Traits as types ▸    : impl ● | &dyn ● | Box<dyn ●>
Functions ▸          : fn(●) -> ● | impl Fn(●) -> ● | impl FnMut(●) -> ● | impl FnOnce(●) -> ●
```

Composite entries insert their wrapper with inner type holes and nest (Doodle's composite builder,
`features/04 §16`): `Vec<●>` → `Vec<u32>`; `[●; ●]` has a type hole and a `usize` value hole (a const context).
The trait inside `impl ●`, `dyn ●` is pick-on-insert (the trait picker opens at once; B removes the insert).
Inside an impl, `Self` is the first entry of `SUGGESTED`. Types are inserted spelled as this file writes them
(R11, R18).

Grays and hides:

| Choice | Rule |
|---|---|
| `impl ●` | refused outside fn parameter and return types: `impl Trait only goes in fn parameters and return types` |
| `str`, `[T]`, `dyn T` by value | hidden: they appear only behind `&`, `Box` or `Rc` |
| `! never` | hidden outside a fn's return type (the never type is unstable elsewhere) |
| a type from another crate in `impl ● {` | gray: `can't add methods to a type from another crate (E0116): implement a trait instead` |
| a non-`Copy` type in a union field | gray: `union fields must be Copy or ManuallyDrop (E0740)`; fix: `Wrap in ManuallyDrop<…>` |
| a non-FFI-safe type in an `extern "C"` signature | gray: `String isn't FFI-safe (improper_ctypes): use *const c_char` |
| a generic parameter outside its item | hidden (not in scope) |
| a private type in a `pub` signature | gray: `Point is private: this signature is pub (private_interfaces)`; fix: `Make Point pub too` |
| a type that doesn't satisfy the hole's bound (a generic argument `HashMap<●, _>` key without `Hash + Eq`) | gray: `f64 isn't Hash: it can't be a HashMap key` |

**Lifetimes are added for you where elision can't work (new).** Choosing `&●` / `&str` / `&mut ●` in:
- a struct or enum field: adds `<'a>` to the type's generics and writes `&'a ●`; status
  `added lifetime 'a to BraveOtter`;
- a fn return type when the elision rules don't give one (two or more reference parameters and no `&self`):
  adds `<'a>` to the fn and `'a` to the reference parameters and the result; status
  `added lifetime 'a to brave_otter (its result borrows from its inputs)`;
- a fn return type with no reference parameter at all: writes `&'static ●`; status
  `a result that borrows from nothing must be 'static`.
These rules are syntax-certain (elision depends only on the signature's shape). Struct-field type menus list
owned types first (`String` before `&str`, `Vec<T>` before `&[T]`).

**Edit Type** (Y or LT+A on a filled type; `features/04 §17`; title `Edit Type`):

| Entry | Effect |
|---|---|
| `Type ▸` | the Type menu; the pick replaces the type |
| `Wrap in ▸` | `Option<…>`, `Vec<…>`, `&…`, `&mut …`, `Box<…>`, `Rc<…>`, `Arc<…>`, `Result<…, ●>` (new; Doodle could only replace, `features/04` open question 14) |
| `Drop <wrapper>` | removes the immediate wrapper: `Drop Option<>`, `Drop &`, `Drop Vec<>` |

Each generic argument (a `Vec`'s element, a map's key and value) is its own stop with its own Edit Type. On a
`let` annotation, the value hole follows the new type (`features/04 §17`).

### Generic parameters (the violet `○generics` dot, or `Item options > Generics`)

| Leaf | Inserts | Gray / refuse | Doodle |
|---|---|---|---|
| `Type parameter` | `T`, then `U`, `V`, `W`, `X`, `Y`, `Z`, `T2`, `T3`… (skipping names in scope); the first one creates `<T>` after the item name | — | `features/04 §14` Type param |
| `Type parameter with bound` | `T: Clone`: the Bound menu opens at once (pick-on-insert); B leaves `T` without a bound | — | new |
| `Lifetime` | `'a`, then `'b` … `'z`, `'a2`…; always inserted at the front of the list ("lifetime parameters must be declared prior to type and const parameters") | — | new |
| `Const parameter` | `const N: usize` (then `M`, `K`, `N2`…); `N` is offered in array lengths inside the item | — | `features/04 §14` Value param |

In an `impl` block the same menu edits `impl<T>`; the self type `Wrapper<T>` then lists `T` in its Type menu. A
new type or lifetime parameter on a struct, enum or union that no field uses is gray: `T is never used: add a
field that uses it (E0392)`; fix: `Add a PhantomData<T> field`. (`Generic struct` avoids this by inserting a
field that uses `T`.) LT+B on a parameter removes it; advisory when it is used: `T is used in 3 places`.

Y on a type parameter `T` (title `T`): `Add bound` (Bound menu, pick-on-insert), `Add default (= ●)` (structs,
enums, traits only), `Move bounds to where` (the shape of rust-analyzer's `move_bounds_to_where_clause`). Y on a
lifetime parameter: `Add outlives ('a: ●)` is deferred.

### Trait bounds (the violet `○bounds` dot after `T:`, `'a:`, `impl`, `dyn`)

Title `Fill slot`, subtitle `a trait bound for T`. Sections:

| Section | Content |
|---|---|
| `SUGGESTED` | bounds the code asks for: the last check's E0277 / E0369 / E0599 diagnostics whose help suggests restricting this parameter (**verify** the help wording at the pinned toolchain) |
| `Common` | `Clone`, `Copy`, `Debug`, `Display`, `Default`, `PartialEq`, `Eq`, `PartialOrd`, `Ord`, `Hash`, `Send`, `Sync`, `'static`, `?Sized`, `Iterator<Item = ●>`, `IntoIterator<Item = ●>`, `AsRef<●>`, `Into<●>`, `From<●>`, `Fn(●) -> ●`, `FnMut(●) -> ●`, `FnOnce(●) -> ●`, `Add<Output = ●>` (more than 12: shown A-Z, P23) |
| `This crate ▸`, `Dependencies ▸`, `std ▸` | traits, grouped per `features/07 §6` |
| `Lifetimes` | the lifetimes in scope (for `T: 'a`) |

Refused: `already a bound`. `?Sized` is hidden except on type parameters and associated types. Bounds are a list
(`T: Clone + Debug + ○`); the last bound removed removes the `:` too (`<T>`; rustfmt itself normalises `<T:>`).

### Where clauses

`Item options > Generics > Add where clause` inserts `where ●: ○bounds` before the body; the subject is a type
hole whose menu lists only the generic parameters, `Self` and types that mention them, and it defaults to the
first generic parameter; the Bound menu then opens at once (pick-on-insert: B removes the predicate). Predicates
are a list with a trailing `○where` dot. A `where` left with no predicates is removed. Y on a bound >
`Move to where clause` moves an inline bound into `where`.

### Lifetimes

Lifetimes have no dots of their own (they are rare and the screen is small). Y on the `&` of a reference type
offers `Lifetime ▸`: the lifetimes in scope, `'static`, `'_`, `New lifetime (adds 'b to brave_otter)`. LT+B on a
lifetime removes it (refused where elision would then fail: `the result borrows from two inputs: it needs 'a`).
LT+A on a lifetime parameter renames it with its uses (rename prompt). When the check reports E0106 "missing
lifetime specifier" on a type the user built, Y's `FIX` offers rustc's suggestion as
`Add lifetime 'a (check)` (`MaybeIncorrect`; `C` verified the suggestion shape). Higher-ranked bounds, outlives
between lifetimes and variance are deferred.

### Cfg predicates (the `Cfg` hole)

Title `Fill slot`, subtitle `this target: windows, x86_64` (the host from metadata). Root, authored order:

```
SUGGESTED          : the current target's values (target_os = "windows"), predicates used in this file
Target ▸           : target_os = ▸ | target_family = ▸ | target_arch = ▸ | target_pointer_width = ▸ | target_endian = ▸ | unix | windows
feature = ▸        : the crate's [features] from metadata; placeholder (no features declared in Cargo.toml)
test
debug_assertions
Combine ▸          : not(●) | all(●, ○) | any(●, ○)
true
false
```

Values come from a table of well-known cfg names and values in `doodle-knowledge`, checked against the pinned
toolchain's expected cfgs (**verify** how to read them at the pin; the `unexpected_cfgs` lint knows them).
Predicates that never match the current target stay lit (code for other targets is legitimate). A `feature`
value the manifest does not declare is gray: `not declared in Cargo.toml [features]` (rustc warns
`unexpected_cfgs`).

### Lint picker (`allow(…)`, `warn(…)`, `deny(…)`, `expect(…)`, `forbid(…)`)

Pick-on-insert (B removes the attribute). Sections: `Common` (`dead_code`, `unused_variables`, `unused_imports`,
`unused_mut`, `non_snake_case`, `unreachable_code`), `rustc ▸` (every rustc lint of the pinned toolchain, a table
generated at `xtask gen-std` from `rustc -W help`; **verify** the output format at the pin), `clippy ▸` (only
when the clippy setting is on, O13). Refused: `already allowed on line 12`. A lint list grows with a `○` dot
(`#[allow(dead_code, ○)]`); removing its last lint removes the attribute.

---

## Patterns (let, match arms, if let / while let / let else, destructuring) and exhaustiveness-driven menus

### The Pattern menu (a `Pattern` hole)

Title `Fill slot`, subtitle `a pattern for Option<u32>` (the scrutinee's type) or `a pattern` without one. Root,
authored order (10 entries, 11 with the context entry):

```
SUGGESTED         pinned: uncovered variants (in match arms), a binding named after the value's type
Anything (_)        the wildcard (the hole's own token)
Bind a name         brave_otter
Bind mutable        mut brave_otter
Variant ▸         : the expected enum's variants with sub-patterns: Shape::Circle(brave_otter) | Shape::Rect { w, h } | None
Literal ▸         : by type: 0 | 'a' | "…" | true | false
Range ▸           : ●..=● | ●..●
Tuple               (●pat, ●pat) with the expected arity
Struct ▸          : T { a, b } (field shorthand) with a ○rest dot for ..
Slice ▸           : [first, ..] | [.., last] | [first, .., last] | []
Combine ▸         : ● | ● (either) | brave_otter @ ● (bind and test) | &● (through a reference)
[Rest ..]           [ctx] only inside tuple, slice and struct patterns
```

| Leaf | Inserts | Lit when | Gray (advisory) | Doodle |
|---|---|---|---|---|
| `Anything (_)` | `_` | always | — | `features/05 §12` `case:` |
| `Bind a name` | `brave_otter` | always | — | `features/05 §13` (type-switch variable) |
| `Bind mutable` | `mut brave_otter` | always | edition-aware, when the matched value is known to be a reference (evidence: edition plus oracle; lit while Unknown). Edition ≥ 2024 (O18's default): `edition 2024 can't bind mut through a reference: make the & explicit`; fix: `Make the reference explicit: &Some(mut brave_otter)` (rustc 1.96.1 rejects `Some(mut x)` on a `&Option<i32>` with "cannot mutably bind by value within an implicitly-borrowing pattern" and suggests the `&` pattern). Edition 2021: `this binds a reference; mut makes the binding mutable, not the value`. A compile-matrix row pins both editions. | new |
| `Variant ▸` | `Shape::Circle(brave_otter)`, `Shape::Rect { w, h }`, `None`; sub-patterns are bindings by default | the variant's enum is the scrutinee's type (or Unknown) | covered already: `already matched on line 14: this arm would never run`; refutable in an irrefutable position (below) | `features/05 §12-13` |
| `Literal ▸` | `0`, `'a'`, `""`, `true`, `false` (by the scrutinee's type) | the literal fits the scrutinee's type | `expects char, not a number` | `features/05 §12` case values |
| `Range ▸` | `●..=●`, `●..●` (exclusive range patterns are stable since Rust 1.80) | integers and `char` | `ranges only match numbers and chars` | `features/05 §12` Range |
| `Tuple` | `(●pat, ●pat)` | a tuple scrutinee (arity from it), or Unknown | `expects Shape, not a tuple` | new |
| `Struct ▸` | `Point { x, y }` with every visible field in shorthand, plus `○rest` | a struct scrutinee | — | new |
| `Slice ▸` | `[first, ..]`, `[.., last]`, `[first, .., last]`, `[]` | a slice or array scrutinee | — | new |
| `Combine ▸` | `●pat \| ●pat`, `brave_otter @ ●pat`, `&●pat` | always | — | `features/05 §12` (`case a, b`) |
| `[ctx] Rest ..` | `..` | inside tuple, slice and struct patterns | refused: `this pattern already has ..` | new |

**Refutability.** In an irrefutable position (`let` without `else`, fn and closure parameters, `for`), a
refutable choice (a variant of a multi-variant enum, a literal, a range, a fixed-length slice) is gray:
`a let needs a pattern that always matches (E0005)`; fix (in a `let` statement): `Turn this into let … else`
(E0005's own help suggests it).

**Bindings** created by patterns get generated names (P5), except where a convention exists: struct-pattern
shorthand uses the field names, `Err(error)`, loop patterns `item` / `index` / `key` / `value`. A binding is
offered by Reference only inside its arm, branch or block (`features/05` inv 11, now from rust-analyzer's
scopes).

**Pattern defaults follow the value (new).** While a `let … else`, `if let`, `while let`, `for` or `match`-arm
pattern is still the generated default, filling or changing the value re-derives it from the value's type, using
the facts present at that pick (R5): `Option<T>` gives `Some(brave_otter)`, `Result<T, E>` gives
`Ok(brave_otter)`, another enum its first data-carrying variant with bindings, a struct its destructuring, a
2-tuple item `(brave_otter, calm_otter)`. The first user edit of the pattern stops the sync (a `generated` flag on
the pattern, cleared by any edit; it is editor state, not text).

### Match arms: generation, the Arm menu, exhaustiveness

**Generation (R5, R8).** When a `match` scrutinee goes from hole to filled and the arm list is empty, arms are
generated in the same step from the scrutinee's type as known at that pick (variants from the knowledge layers:
std tables for `Option`, `Result`, `Ordering`, …; the crate index for local enums; `ItemsOf` for dependencies).

**Untouched arms follow the scrutinee.** The arm list carries a `generated` flag (editor state, not text), as
patterns do. While it is set and every arm is untouched (patterns as generated, bodies still unfilled holes),
a pick that refills or extends the scrutinee (Y > refill, Y > `Extend`) regenerates the whole arm list from the
new type in that pick's `Template` (R5: facts present at that pick). A scrutinee that was Unknown at its first
pick, so got no arms, gets them the same way at the next refill or extend. Any edit to an arm clears the flag;
after that, only `Y on match > Add missing arms` adds arms. NS1 relies on this: `guess.trim()` first generates
the `&str` arms, then `Extend > parse()` under `let guess: u32` replaces them with `Ok(brave_otter)` /
`Err(error)`.

| Scrutinee type | Generated arms (declaration order) |
|---|---|
| enum (this crate, or another without `#[non_exhaustive]`) | one per variant: `Direction::Left => …`, `Shape::Circle(brave_otter) => …`, `Shape::Rect { w, h } => …` |
| enum from another crate with `#[non_exhaustive]` | its variants plus `_ => …` (required) |
| `Option<T>` | `Some(brave_otter) => …`, `None => …` |
| `Result<T, E>` | `Ok(brave_otter) => …`, `Err(error) => …` |
| `bool` | `true => …`, `false => …` |
| `&E` (a reference to an enum) | the same variant patterns (default binding modes make the bindings references) |
| integers, `char`, `&str`, `String` (matched as `.as_str()`), other types | one arm with a literal pattern hole `●pat => …` and `_ => …` |
| unknown at the pick | none: the `Insert(Arms)` dot stays; the next refill or extend of the scrutinee generates them (above), and `Y on match > Add missing arms` generates them on demand |

**Arm bodies.** A `match` in statement position gets block arms `Pat => {` / `●` / `}`. A `match` in value
position (a `let` initializer, a tail, an argument) gets expression arms `Pat => ●T,`. Y on `=>` toggles:
`Expression body` (allowed when the block holds exactly one expression statement or a tail: `{ *x_offset -= 1; }`
→ `*x_offset -= 1,`) / `Block body`. The arm order is declaration order; Refactor > Grab reorders arms (an arm is
a Grab unit).

**Arm menu** (A on a green `Insert(Arms)` dot; title `Fill slot`, subtitle `an arm of match direction`; Doodle's
cases-only menu, `features/05 §12`):

| Leaf | Inserts | Gray / refuse | Doodle |
|---|---|---|---|
| `Add all missing arms` | every uncovered variant, in declaration order | refused when a catch-all exists: `a _ arm already catches everything (line 20)`; gray when the variant list says all are covered: `all cases are covered` | `features/05 §12` (Add case) |
| `Missing arm ▸` | one leaf per uncovered variant | placeholder `(nothing missing)` | new |
| `Variant arm ▸` | every variant | covered ones gray: `already matched on line 14: this arm would never run` (rustc `unreachable_patterns`) | used case values grayed |
| `Anything (_)` | `_ => ●,` | gray when already exhaustive (same reason) | Default case / `#partial` |
| `Value` | `●pat => ●,` with a literal pattern hole | integer, `char`, string scrutinees | case value |
| `Range` | `●..=● => ●,` | integers and `char` only | Range |
| `Either (a \| b)` | `●pat \| ●pat => ●,` | — | `case a, b` |
| `With a guard` | `brave_otter if ●bool => ●,` | — | new |
| `Layout ▸` | comments and blank lines between arms | — | |

A missing arm is error E0004 ("non-exhaustive patterns: `None` not covered"), so `Y on match` offers
`Add missing arms` first. Odin's `#partial` toggle has no analog: `Anything (_)` is the explicit catch-all.
Coverage is computed from the arms' syntax plus the variant list: an arm covers a variant when its top-level
pattern is that variant's path with only bindings or `_` inside and no guard; a `_` or binding arm covers
everything. Deeper exhaustiveness (nested enums, tuples of enums) is left to the check (E0004 then offers the
`FIX` entry `Add the missing arms`).

**Y on `match`** (title `Match`): `Add missing arms` (refused when a catch-all exists, as above), `Add _ arm`,
`Change scrutinee` (refill; B restores; arms are kept), `Turn into if let` (two arms, one of them `_` or `None`;
the shape of rust-analyzer's `replace_match_with_if_let`).

**LT+B in arms**: on an arm's top-level variant path, its `=>`, or its first literal: the whole arm (the arm is
the unit, as `case` is in Doodle); inside a sub-pattern: that part becomes `_`; on one alternative of `A | B`:
that alternative; on a guard's `if`: the guard.

---

## Part actions per Rust part: Y (Change), LT+A (Edit), LT+B (Delete), B (cancel)

Doodle's verbs keep their meaning everywhere (P10, `features/02 §17-§20`), under the default layout of
`features/03` (rebinding changes the buttons, not the verbs):

- **Y (Change)** changes the highlighted part: it refills a value or type through a hole typed for the position
  (`MenuPurpose::Refill`; B restores exactly), or opens the part's options menu (`MenuPurpose::Options`; nothing
  changes until a pick; refused entries keep the menu open). On a hole Y is the same as A.
- **LT+A (Edit)** edits a filled leaf in place: text tools on names, strings and comments; the number keypad;
  Edit Type on types; the Use tree on `use` paths; an attribute's argument editor.
- **LT+B (Delete)** deletes the smallest structural unit, trying the finest handler first (P11); a filled part
  becomes a hole before its parent goes. On a green dot it does nothing, except next to a blank line, where that
  blank line goes (`features/02 §17` row 2).
- **B** restores exactly what the step in progress changed (P9; table at the end).
- **Undo** (LT+Down, O6) reverts the last completed step, extra edits included (R17).

**Y's decision order** (the Rust form of `features/02 §18` `change_selected`; the first match wins):
1. a part a current diagnostic touches: the part's normal Y menu, with the `FIX` section pinned on top (R7);
2. a keyword with options (`fn`, `struct`, `impl`, `if`, `match`, `for`, `let`, `pub`, `mut`, `unsafe`, …):
   its options menu;
3. an operator: the operator menu of its group (`+` → Arithmetic, `+=` → Operator);
4. a callee (fn path, method name, macro name): `Change function` / `Change method` / `Change macro`;
5. a hole: same as A;
6. a struct literal's type, an enum constructor's path: refill the whole value (`features/05 §26`);
7. a string literal: text tools with `Replace value` first (`features/06 F21`);
8. any other part in a value position: refill with a hole typed for the position, with `[ctx] Extend <x> ▸`;
9. an assignment target: re-pick (`features/06 F19`);
10. anything else: LT+A on it.

**LT+B's order** (the Rust form of `features/02 §17` `delete_selected`; the first claim wins): a line of a block
comment; a green dot next to a blank line / a `//` comment line; any other dot (nothing); one entry of a list
(parameter, argument with its placeholder, generic parameter, bound, where predicate, derive, lint, `use` group
entry, struct-literal field, tuple element, pattern alternative, enum variant, field, arm); a condition / iterable
/ scrutinee (back to a typed hole); a loop or `if` part (label, index, `else` branch); an adapter (`?`, `.await`,
`.unwrap()`, `as T`, `&`, `*`); an operand or argument (back to a typed hole), and on such a hole the enclosing
operator; a captured name (uncapture); an item keyword or name (the item with its attribute and doc lines); a
block keyword (the whole statement); else the statement.

### Items and signatures

| Part | Y | LT+A | LT+B |
|---|---|---|---|
| item keyword (`fn`, `struct`, `enum`, `union`, `trait`, `impl`, `mod`, `const`, `static`, `type`, `macro_rules!`, `extern`) | Item options `<kind> <name>` | — | the whole item with its attribute and doc-comment lines (`features/04 §32`) |
| `⊙` | same as A (Item options) | — | nothing |
| item name | falls back to LT+A (`features/02 §18` row 13) | text tools (`Case`), then the rename prompt (Names) | the whole item |
| visibility (`pub`, `pub(crate)`, `pub(super)`) | Visibility menu; current refused | — | makes it private; gray when other modules use it: `used from src/main.rs` |
| qualifier (`const`, `async`, `unsafe`, `extern "C"`, `safe`) | Qualifiers checklist | ABI picker on the ABI string | removes that qualifier (grays as in Qualifiers) |
| fn parameter name or pattern | falls back to LT+A | rename (with propagation) | **removes the parameter, and the matching argument at every call of this fn in the open file** (fixes `features/04` open question 1). Status: `removed from 2 calls here; 1 call in src/app.rs not changed`. Advisory when the body uses it: `used on lines 12, 15`. Calls in this file are found by the syntax layer when the callee path resolves syntactically (a fn of this file, `Self::f`, `Type::f`); method calls `x.f(…)` are left alone and counted in the status (open question 10). |
| parameter type | Edit Type | Edit Type | back to a type hole (`_`) |
| `self` receiver | Receiver menu: `self`, `&self`, `&mut self`, `none (associated fn)`; current refused | — | removes the receiver; gray when the body uses `self`: `self is used on line 14` |
| `○params` | same as A | — | nothing |
| return type `-> T` | Edit Type | Edit Type | removes `-> T`; an unfilled tail hole goes with it, a filled tail stays (the check reports it) |
| `ret` hole | same as A | — | nothing |
| impl self type | refill from the Type menu | Edit Type | back to a type hole |
| impl trait path | the trait picker; items the new trait lacks stay and the check flags them | — | the whole impl block (a trait position is never a hole, D4) |
| struct field name | falls back to LT+A | rename (field accesses, literals and patterns follow through the oracle) | the field line; gray when used: `used in 4 places` |
| field type | Edit Type | Edit Type | back to a type hole |
| enum variant name | Variant options: `Unit form`, `Tuple form`, `Struct form`, `Add value (= ●)`, `Attributes ▸` | rename | the variant; gray: `matched in 3 places` |
| `mod name;` (a file module) | Module options: `Open the file`, `Make it inline` (deferred), `Visibility ▸` | refused: `the module's name is its file's name: rename the file in Files, then Y > Link a file` | the `mod` line; the file stays on disk (status: `src/brave_otter.rs stays on disk`) |
| `mod name {` (inline) | Module options: `Visibility ▸`, `Attributes ▸` | rename | the whole module |
| trait item signature (`fn …;`) | `Give it a default body` | — | the item |

### `use` lines

A `use` line's fields: keyword `use `, one stop per path segment, `::` separators, an optional `{` group with
entries and a `○group` dot, an optional ` as ` with an editable alias, `;`.

| Part | Y | LT+A | LT+B |
|---|---|---|---|
| a path segment | the Use tree opened at that segment's parent, replacing the path from that segment on (Doodle's `Edit import`, restricted to the Use tree, `features/04 §7`) | same as Y | the whole `use` line (or that group entry) |
| a group entry | the Use tree at the group's prefix (swap this entry) | same | that entry; a group left with one entry collapses (`{HashMap}` → `HashMap`) |
| the alias | text tools | text tools | removes ` as alias` |
| `use` keyword | `Use options`: `Add to this group ▸` (the tree at the common prefix), `Add alias`, `Make glob`, `Split into lines`, `Merge with other uses of this crate` (the shape of rust-analyzer's `merge_imports`) | — | the line |
| `○group` | same as A | — | nothing |

An unused import is drawn faded with the reason `not used` on its stop; LT+B is the obvious fix. A custom alias is
kept when the path is swapped (fixes `features/04 §7`).

### Attributes, derives, docs

| Part | Y | LT+A | LT+B |
|---|---|---|---|
| attribute name in `#[…]` / `#![…]` | Attributes menu for the item | the attribute's argument editor (lint picker, cfg predicate, repr picker, string text) | that attribute; the line goes with its last one |
| one derive in `#[derive(A, B)]` | the Derive checklist | — | that derive; refused when another needs it: `Copy needs Clone: turn Copy off first` |
| one lint in `#[allow(a, b)]` | the lint picker (swap it) | — | that lint; the attribute goes with its last one |
| a cfg predicate | refill from the Cfg menu | — | back to the `cfg` hole (`true`) |
| doc comment text | text tools | text tools plus `Link` (wraps a word as `` [`Name`] ``, choosing from in-scope items; `features/08` Carrying (c)) | that line; on the last line, the doc comment |

### Generics, bounds, where clauses, lifetimes

| Part | Y | LT+A | LT+B |
|---|---|---|---|
| type parameter `T` | `Add bound`, `Add default (= ●)`, `Move bounds to where` | rename (with propagation) | the parameter; gray when used: `T is used in 3 places` |
| lifetime parameter `'a` | — | rename (with propagation) | the parameter; gray when used |
| const parameter `const N: usize` | Edit Type on `usize` | rename | the parameter; gray when used |
| one bound in `T: A + B` | refill from the Bound menu | the Bound menu | that bound and its `+` |
| a where predicate | refill the subject | — | the predicate (the `where` goes with the last one) |
| `&` of a reference type | `Lifetime ▸` | Edit Type | `Drop &` (gray inside a trait impl whose trait's signature has the `&`: `the trait's signature borrows here`) |
| a lifetime in a type (`&'a T`) | `Lifetime ▸` | — | removes it (refused where elision fails) |
| `○generics`, `○bounds`, `○where` | same as A | — | nothing |

### Statements

| Part | Y | LT+A | LT+B |
|---|---|---|---|
| `let` keyword or its `=` | `Declare as` (on a `let … else`: the `Let else` options) | — | the statement; if the value is a bare call, uncapture (`let x = f();` → `f();`, `features/05 §9`) |
| a `let` binding name | falls back to LT+A; on a struct- or tuple-typed binding also `Destructure` (the shape of `destructure_struct_binding` / `destructure_tuple_binding`) | rename (with propagation; shadowing-correct) | as the `let` keyword |
| `mut` | `Make immutable` (gray when the binding is changed: `assigned on line 22`) | — | removes `mut` (same gray) |
| a `let` type annotation | Edit Type | Edit Type | removes the annotation (`let x = v;`) |
| `else` of `let … else` | `Change what it does`: the diverging defaults of Let else | — | refused: `let … else needs its else: Y on let > Turn into match instead` (removing it would leave a refutable `let`, E0005) |
| assignment target | re-pick the target (`features/06 F19`) | — | the statement |
| assignment operator | `Operator` | — | the statement |
| `return` / `break` / `continue` | label menu; `Add value` / `Remove value`; `Use the tail instead` | — | the statement |
| tail expression | refill typed as the block's type; `Make it a statement (;)` (gray when the block's type isn't `()`: `the block must give i32`); `Use return x; instead` | per kind | back to the tail hole |
| tail hole | same as A | — | nothing (it is required); when the block's type is `()`, it is removed |
| `○tail` | same as A | — | nothing |
| `●` row, green dots | same as A | — | nothing; next to a blank line, that blank line (`features/02 §17` row 2) |
| `◉` | same as A | — | nothing |
| comment, blank line | as Doodle | as Doodle | as Doodle |

### Control flow

| Part | Y | LT+A | LT+B |
|---|---|---|---|
| `if` / `else if` / `else` / `if let` | the If options ("Branching") | — | `if`: the whole chain; `else if` / `else`: that branch |
| a condition | refill as `bool`; B restores | — | back to a `bool` hole; on the hole: nothing |
| `match` | Match options | — | the whole match |
| scrutinee | refill; arms are kept | — | back to a hole (arms kept) |
| an arm's variant path, `=>`, first literal | refill the pattern / `=>` toggles block and expression body | — | the whole arm |
| guard `if` | `Change guard` | — | removes the guard |
| `loop` / `while` / `while let` / `for` | the Loop options ("Loops") | — | the whole loop |
| label `'outer` | the Loop options (label entries) | rename; jumps follow (`features/05 §19` `label_rename_jumps`, syntax) | removes the label; refused while a jump needs it: `a jump needs the label: it stays` |
| `unsafe` / `async` / labeled block keyword | `Unwrap (keep the contents)` (gray when still needed), label entries | — | the whole block |
| `?` | `Unwrap ▸` swap (value kept) | — | removes `?` |

### Patterns and arms

| Part | Y | LT+A | LT+B |
|---|---|---|---|
| a binding in a pattern | falls back to LT+A; `Make it mutable` / `Make it immutable` | rename | becomes `_` |
| `_` (a pattern hole) | same as A | — | nothing |
| a variant path in a pattern | refill from `Variant ▸` (sub-patterns kept when the arity matches) | — | the arm when it is the arm's top level, else `_` |
| a literal or range in a pattern | refill | keypad / text tools | becomes `_` |
| one alternative of `a \| b` | refill it | — | removes it |
| `..` in a pattern | — | — | removes it; missing fields come back as bindings |

### Expressions

| Part | Y | LT+A | LT+B |
|---|---|---|---|
| any filled value in a value position (literal, name, call, struct literal, closure, block expression) | refill with a hole typed for the position (`features/06 F21` `unit_expected`, now from `Oracle::expected_at`, prefetched; D7.8 carried facts), `[ctx] Extend <x> ▸` first; B restores exactly | number: the keypad (`1`–`9`, `0`, `A`–`F`, `0x`, `0o`, `0b`, `_`, `.`, `e`, `Suffix ▸`, `Del`, `OK`; `Suffix` lists `i32`, `u8`, `usize`, `f32` … filtered and grayed by the expected type: `expects u8: use the u8 suffix or none`; closing is refused on text that isn't a literal: `0x needs a digit`); string or char: text tools; name: nothing (Y refills) | back to a typed hole |
| a hole that is an operand | same as A | — | collapses the operator to one hole of the parent's type; in a chain of 3+ operands, that operand and one operator go (`features/02 §17` row 8) |
| a hole that is a call or macro argument | same as A | — | nothing (Rust arguments are required); LT+B on the callee removes the call |
| callee (fn path) | `Change function`: the same module / crate tree; arguments reset to typed holes (`features/06 F21b`); grayed by return fit when the call fills a typed hole (fixes `features/06` gap 13) | — | the call becomes a typed hole |
| method name in a chain | `Change method`: methods of the receiver, grayed by return fit; arguments reset | — | removes that link of the chain |
| macro name | `Change macro` within its family (`println!` / `eprintln!` / `print!` / `eprint!`; `format!` / `write!`), arguments kept | — | the statement, or a typed hole in value position |
| format string | text tools: `Edit word by word` with placeholder inserts | same | the whole macro call |
| a macro argument | refill typed | per kind | the argument and its placeholder |
| an opaque macro call (unknown shape) | `Replace with ▸` (the Value menu) | — | the statement, or a typed hole |
| prefix `&`, `&mut`, `*` | Pass as again, value kept | — | removes the prefix |
| prefix `!`, `-` | the operator's group | — | removes the operator, keeping the operand |
| an operator `+`, `==`, `&&` | the operator's group (current refused) | — | the operator and its right operand (the left stays) |
| adapter `.await`, `.unwrap()`, `.expect(…)`, `.clone()`, `.into()`, `as T` | swap within its group (`Unwrap ▸`, `Convert ▸`), value kept | Edit Type on `T` of `as T` | removes the adapter |
| struct literal type | refill the whole literal (`features/05 §26`) | — | becomes a typed hole |
| struct literal field name | `Use shorthand` / `Use full form` | — | removes the field only when a `..base` exists; otherwise refused: `every field is needed here (E0063): add ..Default::default() with the ○ dot first` |
| `..base` | refill (`..Default::default()` / `..other`) | — | removes it; missing fields come back as holes |
| `○rest` | same as A | — | nothing |
| enum constructor path (`Some`, `Shape::Circle`) | refill from `Enum variant ▸` / `Option / Result ▸` (arguments kept when the arity matches) | — | becomes a typed hole |
| closure `\|` | Closure options: `Add parameter`, `move on` / `move off`, `Block body` / `Expression body`, `Add return type` (`-> ●`, which forces a block body) | — | the closure becomes a typed hole |
| closure parameter | falls back to LT+A | rename | removes it; gray when the expected arity is fixed: `map's closure takes 1 argument` |
| range operator `..` / `..=` | toggles exclusive / inclusive | — | the range becomes a typed hole |
| index brackets `x[●]` | refill the index | — | removes the indexing (back to `x`) |
| tuple / array element | refill | per kind | the element (its `,`) |
| `○args`, `○fields` | same as A | — | nothing |

### Types

| Part | Y | LT+A | LT+B |
|---|---|---|---|
| a filled type | Edit Type | Edit Type | back to a type hole |
| a generic argument (`Vec<●>`'s element) | Edit Type | Edit Type | back to a type hole |
| a type hole | same as A | — | nothing |
| a wrapper (`Option<…>`, `Box<…>`) | Edit Type with `Drop <wrapper>` | — | `Drop <wrapper>` |

### What B restores (`features/02 §20`)

| Context | B does |
|---|---|
| editor, nothing open | back to the main menu (with the unsaved-changes question, O7) |
| Add menu, member menus, Arm menu (A on a green dot) | closes; nothing inserted |
| Statement menu from a green dot | removes the temporary line; the file is byte-identical; the cursor is back on the dot |
| a submenu | up one level |
| Y refill (value, condition, scrutinee, iterable, type, literal type) | the original, exactly; the cursor on it |
| options menus (If, Loop, Match, Operator, Item options, Visibility, Qualifiers) | closes; nothing changed |
| Derive checklist | closes; the toggles stay (one undo step) |
| Declare as | closes; nothing changed. The Type menu that `choose the type` opened: removes the new type hole (fixes P9 exception 1) |
| pick-on-insert pickers (trait, bound, lint, where predicate) | removes the insertion |
| Reference pick | the hole stays empty (a Y-refill's original comes back) |
| Pass as / Assign to / Methods of x | back to the pick |
| Assignment target pick | removes the new line |
| fix menu (`Fix it` / `Insert anyway`) | back to the menu |
| a confirmation (Add crate, Module (new file), rename in other files) | nothing written |
| number keypad | closes; keys already pressed stay (Doodle P9 exception 2, kept; Undo reverts) |
| text tools | closes without a change |
| rename prompt | `Only this one` |
| Grab / Copy line | every move undone exactly (`features/02 §13`) |

### HUD hints (top right; rewritten for the user's layout by `rebind_hint`, `features/03 F18`)

| Where | Hint |
|---|---|
| `⊙` | `A: item options  (pub, derive, attributes, ...)` |
| item keyword | `Y: item options    LT+B: delete <kind>` |
| `pub` | `Y: change visibility    LT+B: make private` |
| fn parameter | `LT+A: rename    LT+B: remove parameter (and its arguments here)` |
| `let` | `Y: declare as (mut, typed, const)    LT+B: delete` |
| `mut` | `Y: make immutable    LT+B: remove mut` |
| `if` / `if let` | `Y: add else if / else, change condition    LT+B: delete` |
| `else if` | `Y: add else if / else, change condition    LT+B: remove branch` |
| `else` | `Y: add else if    LT+B: remove branch` |
| green dot after an `if` chain | `A: add a statement, else if or else` |
| `match` | `Y: add missing arms, change value    LT+B: delete` |
| green dot between arms | `A: add an arm` |
| arm pattern | `Y: change pattern    LT+B: delete arm` |
| `=>` | `Y: block or expression body    LT+B: delete arm` |
| `for` | `Y: loop options (borrow, index, reverse, label)    LT+B: delete loop` |
| a loop label a jump needs | `Y: loop options    (a jump needs the label: it stays)` |
| `break` / `continue` | `Y: choose label    LT+B: delete` |
| tail hole | `A: the value of this block` |
| a hole | `A: fill` |
| `?` / `.await` / `.unwrap()` | `Y: change how it unwraps    LT+B: remove it` |
| a filled value | `Y: change or extend it    LT+B: clear it` |
| struct literal field | `Y: shorthand on/off    LT+B: remove field (needs ..base)` |
| `use` path | `Y: pick another path    LT+B: remove import` |
| `◉` | `A: keep the result in a new variable` |
| a part with a diagnostic | `Y: fix it    LT+Y: explain` |

---

## Names: generation and casing by role; rename with propagation via the oracle

### Generation (P5, `features/04 §2`, `core::namegen`)

The word lists are Doodle's (20 adjectives × 20 animals) and one shared, deterministic counter picks adjective
`counter % 20` and animal `(counter / 20) % 20`, advancing past any name already taken. "Taken" means: declared
anywhere in the open file, or an item visible in this module according to the crate index (Doodle checked
sibling procedures and types the same way). After all 400 combinations of a casing are taken, the generator
appends a number (`brave_otter_2`) instead of looping (fixes `features/00` open question 4).

| Role | Casing | Default |
|---|---|---|
| fn, method, local, parameter, field, module, `macro_rules!` name, closure parameter, pattern binding, captured result | `snake_case` | `brave_otter` |
| struct, enum, union, trait, type alias, enum variant, associated type | `UpperCamelCase` | `BraveOtter` |
| const, static, associated const | `SCREAMING_SNAKE_CASE` | `BRAVE_OTTER` |
| the first fn of a binary crate root with no `main` | fixed | `main` |
| type parameter | one capital | `T`, then `U`, `V`, `W`, `X`, `Y`, `Z`, `T2`, `T3`… (skipping names in scope) |
| const generic parameter | one capital | `N`, then `M`, `K`, `N2`… |
| lifetime | `'` + lowercase | `'a`, then `'b` … `'z`, `'a2`…; `'static` and `'_` are fixed choices, not names |
| loop label | `'` + snake | `'outer`, `'outer_2`… (unique per fn; `features/05 §19`) |
| block label | `'` + snake | `'block`, `'block_2`… (Doodle mixed `outer` and adjective_animal labels; `features/05` open questions) |
| range loop variable | fixed | `i`, then `j`, `k`, then `i_2`… (`features/05 §15` `fresh_name`) |
| collection loop variable | fixed | `item`; `index` with an index; `key` / `value` over a map |
| error binding in `Err(●)` | fixed | `error`, then `error_2` |
| test module | fixed | `tests` |
| constructor | fixed | `new` |
| struct-pattern and `Let struct` bindings | the field's name | `x`, `y` (a clash gets a generated name: `x: brave_otter`) |
| a scope guard | fixed | `_guard` |

Doodle's whimsical project names stay (`features/09`); a Cargo package name may contain `-`, its crate name
replaces `-` with `_` (cargo does this itself).

### Casing of dictated names (`features/08` Carrying (c))

Dictation into a name leaf joins words with `_` (P16) and then applies the role's casing: `window title` becomes
`window_title` on a fn, `WindowTitle` on a struct, `WINDOW_TITLE` on a const, `'window_title` on a label.
UpperCamelCase treats acronyms as words (`http server` → `HttpServer`). LT+A > `Case ▸` lists `snake_case`,
`UpperCamelCase`, `SCREAMING_SNAKE_CASE` with the role's casing first; the others are gray with rustc's lint as
the reason: `Rust expects snake_case for a fn (non_snake_case)`.

A name that comes out as a keyword (`as break const continue crate else enum extern false fn for if impl in let
loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while
async await dyn`, or a reserved word `abstract become box do final macro override priv typeof unsized virtual
yield try gen`) is written as a raw identifier with the status `type is a Rust keyword: wrote r#type`; `self`,
`Self`, `super` and `crate` can't be raw, so they get a trailing `_` (`self_`). A leading digit gets a `_`
prefix (`_2d`) with the status `a name can't start with a digit: wrote _2d`. A leading `_` marks an
intentionally unused binding and is kept.

### Rename with propagation

Trigger (`features/06 F26`, `features/08 F19`): the user changes a **declaring** name (a `let` or pattern
binding, a parameter, an item name, a field, a variant, a generic parameter, a lifetime) by voice or by LT+A text
tools. Renaming a use never asks; string and comment text never prompts.

Flow (D7: answers are inputs; menus are frozen):
1. The new name is drawn in place as a preview; the text does not change yet. The core sends
   `Query::Rename { at, new_name }` for the current revision (`PrepareRename` is prefetched when the cursor lands
   on a declaring name, D7.7). Like transcription (`features/08 F8`), the editor takes no presses until the answer
   arrives; the banner reads `finding uses of brave_otter...`, and B cancels the rename (the old name stays).
2. If the oracle is loading or down, or answers `Failed`, the core falls back to the syntax layer at once: scope-
   correct uses for locals, parameters, pattern bindings, labels, generic parameters and lifetimes
   (`core::scope`, shadowing-correct, so `let x = x.trim();` keeps the right-hand `x`); exact path matches for
   items in the open file. The prompt then says `(types still loading: uses in this file, found by name)`.
3. With no other uses, the rename applies with no prompt (Doodle). Otherwise the prompt opens, title
   `Rename brave_otter to window_title?`, entries in this order:

| Entry | Shown when | Applies |
|---|---|---|
| `Rename all N uses` (or `Rename the other use` when N = 1; built as its own label, fixing `features/08` open question 19) | N > 0 uses in the open file | the declaration and the open file's uses (one undo step) |
| `Also rename M uses in other files (src/app.rs, src/ui.rs)` | M > 0 | the open file's uses, and the other files' edits through the app (D18.3; the entry names the files, which is its confirmation) |
| `Only this one` | always | the declaration only |

B equals `Only this one`, as in Doodle. Picks in this prompt record no heat (`features/06 F5`). When `Only this
one` or `Rename all N uses` leaves uses in other files unchanged, the status says so: `2 uses in other files still
say brave_otter (src/app.rs)`.

What the oracle's rename covers (semantic, unlike Doodle's word scan): shadowing, struct literals and patterns
(field-init shorthand is expanded or kept so the code means the same: `Point { x }` → `Point { x: total }` when
the local is renamed), `{x}` captures inside format strings, trait methods with their impls, `use` paths, generic
parameters and lifetimes.

Rules and refusals:
- a label rename rewrites its `break 'outer` / `continue 'outer` silently (syntax; Doodle `label_rename_jumps`);
  refused when the fn already has that label: `'outer is already a label in this fn` (Doodle did not check,
  `features/05` inv 10);
- the name of a file module (`mod brave_otter;`) is refused (Part actions; R14);
- a name that clashes with another binding in the same scope: the oracle refuses the rename; the prompt then
  offers only `Only this one`, with the reason line `window_title is already used in this scope`;
- casing that breaks the role's convention is advisory (the Case tool's gray), never refused.

---

## Errors the user can't type their way out of (borrow, lifetime and trait errors): which menu offers the repair

In a text editor you fix E0382 by typing `.clone()`, E0596 by typing `mut`, and E0502 by moving a line. Here
every repair must be a pick or a structural move (P1). Three verified facts make this harder (proposal C, R5):
rust-analyzer has no borrow diagnostics, so only `cargo check` knows, seconds later (D10); rustc reports borrow
errors only after the type errors are fixed, so problems arrive in waves; and some errors carry no machine
suggestion (E0502). The design has three layers.

**Layer 1: prevent by construction** (computed from the CST, the knowledge layers and the facts at the pick):

| Situation | What the menus do | Error avoided |
|---|---|---|
| assigning to, `&mut`-borrowing, or calling a `&mut self` method on a binding without `mut` | add `mut` (R12, O20) | E0384, E0596 |
| an expected `&T` and a picked name of type `T` | Pass as lists `&x   (borrow)` lit; bare `x` grays `expects a reference` | E0308 |
| an owned, non-`Copy` name used again later | bare `x` grays `moves x, but line 30 uses it again`; `x.clone()` and `&x` stay lit | E0382 |
| a `for` over a collection | three explicit iteration modes (borrow, mutable, take) | E0382 after the loop, E0596 |
| a reference in a struct field, or a return type elision can't cover | the Type menu adds `'a` (or `'static`) | E0106 |
| a closure passed where the bound needs `'static` (`std::thread::spawn`) | inserted as `move \|…\|` | E0373 |
| an operation that needs `unsafe` | wrapped (R13) | E0133 |
| a struct literal, trait impl, match | inserted complete (R8) | E0063, E0046, E0004 |
| a `?` in a fn that can't return it | grayed with the return-type fix | E0277 |

**Layer 2: repair from rustc's suggestions (the `FIX` section).** Y on a red- or amber-shaded part pins a `FIX`
section above its menu (R7), built from the diagnostics whose primary span touches the part (D10). A suggestion
is applied only if the revision still matches; otherwise it is dropped (stale suggestions vanish after any edit,
`stale_suggestions_dropped_after_edit`). Applying one is a normal step: B restores, Undo reverts, the next check
runs.

| rustc applicability | Shown as | Picking |
|---|---|---|
| `MachineApplicable` | lit: `Clone it: x.clone()`, `Make guess mutable` | applies |
| `MaybeIncorrect` | lit with ` (check)`: `Add lifetime 'a (check)` | applies; the next check confirms |
| `HasPlaceholders` | lit | applies; each placeholder span becomes a typed hole |
| `Unspecified`, or no suggestion | a refused leaf showing the message | nothing; the reason line says what to do |

Every `FIX` section ends with `Explain (LT+Y)`, which opens Docs with the message, the span labels and the error
code's explanation text (from `rustc --explain` of the pinned toolchain, embedded at `xtask gen-std`; **verify**
the size against the knowledge blob budget, D9).

**Layer 3: restructure (no suggestion).** Entries derived from span labels, each shown only when its
precondition holds:
- `Move this line below line N`: starts Grab (`features/02 §13`) with the target pre-highlighted; N comes from
  the "later used here" span;
- `Copy the value instead of borrowing`: when the element type is `Copy`, rewrites `let first = &items[0];` as
  `let first = items[0];`;
- `Clone it`;
- `Put the borrow in a block`: wraps the borrowing lines in `{` … `}`;
- `Keep it in a variable first`: introduces `let brave_otter = <temporary>;` before the statement and uses it
  there (the shape of rust-analyzer's `extract_variable`).

Per error (rustc suggestion shapes marked † were verified by proposal C on rustc 1.96.1; **verify** the rest at
the pin):

| Error | Prevented by | Repair offered (where → entry) |
|---|---|---|
| E0382 use of a moved value | Pass as move grays; take-mode loop gray | `FIX` on the use: `Clone it: x.clone()` †(MachineApplicable); on the move: `Borrow it: &x (check)`; on a `for`: `Iterate by borrow (&items)` |
| E0384 assigning twice to an immutable variable | R12 | `FIX`: `Make count mutable` †(MachineApplicable `mut `) |
| E0596 borrowing as mutable | R12 | `FIX`: `Make guess mutable` †(MachineApplicable `mut `); on `self`: `Change the receiver to &mut self` |
| E0499 two mutable borrows | — | `FIX`: `Move this line below line N`, `Put the first borrow in a block` |
| E0502 mutable and shared borrow | — | †(no suggestion) `FIX`: `Move this line below line N`, `Copy the value instead of borrowing`, `Clone it` |
| E0505 move while borrowed | — | `FIX`: `Move this line below line N`, `Clone it` |
| E0506 assignment while borrowed | — | `FIX`: `Move this line below line N` |
| E0507 move out of a borrow | Pass as `*x` gray | `FIX`: `Clone it: x.clone()`, `Borrow it: &x` |
| E0597 value doesn't live long enough | — | `FIX`: `Move the declaration of x up (Grab)`, `Keep an owned copy: x.to_owned()`, `Explain (LT+Y)` |
| E0716 temporary dropped while borrowed | — | `FIX`: `Keep it in a variable first` |
| E0106 missing lifetime | Type menu `'a` | `FIX`: `Add lifetime 'a (check)` †(MaybeIncorrect) |
| E0373 closure may outlive | auto `move` | `FIX`: `Make the closure move` |
| E0308 mismatched types | value-menu fit | `FIX`: rustc's suggestion, e.g. `Convert: x.to_string() (check)` †(MaybeIncorrect), `Borrow it: &x`, `Dereference: *x` |
| E0277 trait bound not satisfied | derive / bound grays | `FIX`: `Derive Debug on Point` (local type), `Add T: Display bound` (generic), `Make brave_otter return Result<(), Box<dyn Error>>` (the `?` case) |
| E0599 no method found | `Methods of x` lists only real methods | `FIX`: `Add use std::io::Write` (trait not in scope), `Derive Clone on Point` / `Add T: Clone bound` (unsatisfied bound) |
| E0369 binary operator not supported | operator grays | `FIX`: `Derive PartialEq on Point`, `Add T: Add<Output = T> bound` |
| E0282, E0283 type annotations needed | — | `FIX`: `Say the type: ::<●>`, `Annotate the let: let x: ● = …` |
| E0004 non-exhaustive patterns | generated arms | `FIX` and Y on `match`: `Add the missing arms` |
| E0063 missing struct fields | complete literals | `FIX`: `Add the missing fields` (typed holes) |
| E0046 missing trait items | complete impls | `FIX`: `Add all missing items` |
| E0061 wrong number of arguments | holes per parameter | `FIX`: `Add holes for the missing arguments` |
| E0425, E0433, E0412 unresolved name, path or type | picks, never typing | `FIX`: rustc's `use` candidates: `Add use std::collections::HashMap (check)` |
| E0432 unresolved import of a crate not in `Cargo.toml` | Add crate | `FIX`: `Add rand to Cargo.toml` (opens the D18.1 confirmation) |
| E0133 unsafe operation | R13 | `FIX`: `Wrap in unsafe { }` |
| E0015 non-const call in a const | const-context grays | `FIX`: `Make make_list const` (defined in this file) |
| E0435 non-constant value in a const | const-context grays | `FIX`: `Make n a const` |
| E0728 `.await` outside async | `.await` gray | `FIX`: `Make run async` |
| E0381 used before it has a value | — | `FIX`: `Give it a value now` (adds `= ●` to its `let`) |
| E0603, E0616, E0624 private item, field, method | privacy-aware menus | `FIX`: `Make it pub(crate)` when declared in the open file; else the reason `brave_otter is private in src/app.rs` |
| errors whose span is inside a hole (E0121, E0599 on a `todo!()` receiver, E0080) | — | shown on the hole as `not filled yet: expects i32` (D4); E0121's suggestion goes to `SUGGESTED` |

Spike S12 (`01`) measures this table on about 30 classic errors; the target is at least 60% fixable with one
pick.

---

## Deferred features and why

| Feature | Why it is deferred | What exists meanwhile |
|---|---|---|
| `macro_rules!` with matchers (`$x:expr`, repetitions `$(…)*`) | matchers and transcribers are token trees: no types, so no type-driven menus; the north stars don't need them | zero-argument macros (the single-rule `() => { … }` form, structured on load too); other loaded macros as `Opaque` text with an editable name; calls to any macro |
| writing procedural macros | a separate `proc-macro` crate type and token-stream programming | using derive macros from dependencies (Derive checklist) |
| HRTB `for<'a>`, outlives between lifetimes (`'a: 'b`), variance, self-referential designs | hard to present as menu choices; rarely needed; elision covers most code | `'a` parameters, `&'a T`, `'static`, the auto-`'a` rules, the E0106 fix |
| async runtimes (`#[tokio::main]`, executors, `Pin`, `Send` bounds on futures), async closures | O22: syntax only in v1; a runtime is a crate decision | `async fn`, `async { }`, `.await` grays; Add crate for `tokio` |
| `gen` blocks, `yield`, `try` blocks | unstable | — |
| default field values (`struct S { a: i32 = 5 }`, `S { .. }`) | still unstable on 2026-11-24 (RFC 3681; **verify** at each pin bump) | `..Default::default()` rest |
| `pub(in path)` | rare | `pub`, `pub(crate)`, `pub(super)` |
| `bitflags` / `enumset` (Odin `bit_set`), bit fields | crate-specific item macros | Add crate, then their macros as calls |
| inline assembly (`asm!`), SIMD, `#[global_allocator]`, `#[panic_handler]`, `#[unsafe(naked)]`, `no_std` targets | specialist and unsafe-heavy | the `no_std` inner attribute only |
| destructuring assignment `(a, b) = (b, a);` | needs pattern-shaped targets in Assignment | `std::mem::swap(&mut a, &mut b)` through Calls |
| `build.rs`, multi-crate workspace authoring, authoring Cargo features, removing or re-versioning a dependency | project-level (`features/09`'s lens); removing a dependency would need a fourth out-of-file exception (D18, O12) | Add crate; the cfg menu reads declared features |
| editing `Cargo.toml` as a projected document | not in D3's scope | Add crate (D18.1) |
| doc tests as editable code | the code lives inside `///` comments; it needs a nested projection | `Add # Examples section` inserts the fenced block as comment text |
| `impl Trait` in `let` and type aliases, specialization, inherent associated types, GAT authoring | unstable or advanced | using GATs and trait upcasting from libraries works through the ordinary menus |
| precise capturing `use<…>`, `&raw const` / `&raw mut` | stable but rare; easy to misuse | — |
| `transmute` and other unsafe conversions | rarely right; not worth a menu cell | — |
| `dyn Any` downcasting (Odin's type switch over `any`) | rare in idiomatic Rust | `match` on an enum |
| `cfg_attr` composition, `#[path]` | rare and easy to misuse | kept as `Opaque` text on load |
| `Named fields ↔ tuple fields`, `Make it a method of`, extract function, inline | refactors, not constructs (they need cross-reference edits) | Refactor > Grab / Copy line (`features/02 §13`) |
| `Make it inline` on a file module | moves a file's text into this one (an out-of-file read plus delete) | — |

---

## Tests that pin this taxonomy

Same style as Doodle (`features/11`, `features/06` "Tests"): drive the pure core with `update(&mut app, Input)`
through the testkit (`Pad::press`, `pick(label)`, `menu_go`, `dpad_to`), assert labels, gray kinds and reason
strings, the exact text, the reloaded structure, and then run the real compiler.

1. **Menu shape** (`*_menu_shape`): the exact roots and orders of the Add menu, the statement menu, the value
   menu, the Type menu, the Pattern menu, the Arm menu, Pass as, Methods of x (with a cassette); each root at 12
   or fewer non-pinned entries.
2. **Build every leaf, save, reload, same structure** (the analog of `test_build_every_type_from_menus`): every
   Add leaf, member leaf, associated-item leaf, statement leaf and value construct; compare `(role, range text,
   hole kind)` per field after reload; `rustfmt --check` passes on every result.
3. **Hole round-trip per kind** (D4): unfilled `todo!()`, `_` type, `_` pattern, `true` cfg, missing `->`, empty
   lists, and the same holes inside table-macro and attribute arguments (`vec![todo!()]`,
   `println!("{}", todo!())`, `assert!(todo!())`, `#[cfg(true)]`, `cfg!(true)`, the one-entry `thread_local!`;
   D3.9); load (with `format: false`) → save is byte-identical; a hand-written `todo!()` and `_` load as holes;
   `todo!("x")` does not.
4. **Compile matrix**: a scratch crate holding every untouched leaf; assert which compile and which fail with which
   code (E0121, E0080, E0277), through `cargo check --message-format=json`.
5. **Gray tests**, one per row of every gray table here: the kind (hidden, refused, advisory), the exact reason,
   refused picks keep the menu open and record no heat, advisory picks with a fix open `Doesn't fit here`.
6. **Unknown never grays** (`unknown_never_grays_anywhere`, `01`): with the oracle stubbed to Unknown, no
   reachable entry carries a gray whose evidence is `Oracle` or `Diagnostics`, and the only type-fit grays are
   syntax-stamped literal grays. Grays evidenced by syntax, the index, metadata or knowledge (R2's list) stay.
7. **No false gray** over a corpus (S9): punch a hole at every expression of NS1, NS2 and the Rust Book listings;
   the entry that rebuilds it must be lit.
8. **B restores exactly**: every multi-step edit (temporary line, refill, pick, Declare as > typed > B, trait
   picker > B, lint picker > B, derive checklist, fix menu) leaves the document byte-identical when cancelled at
   each step; Undo after auto-`mut` reverts both edits.
9. **Facts at the pick** (R5): an answer delivered after a `match` scrutinee pick adds no arms; Y > `Add missing
   arms` adds them; an answer never adds or removes a capture dot on an event-only frame; untouched generated
   arms are replaced when the scrutinee is extended (`&str` arms → `Ok` / `Err` after `Extend > parse()` under a
   `u32` annotation), and are kept once an arm is edited.
10. **Determinism**: menus built twice from the same snapshot and facts are identical; `SUGGESTED` uses only
    recorded answers in replay (D16).
11. **North-star builds** (`01` O15): NS0 `cargo new` hello world, NS1 the Rust Book guessing game, NS2
    `handmade-rs`, built from an empty project with controller-equivalent input only, byte-exact, then
    `cargo check`, `cargo test` and `rustfmt --check`. How the menus build their harder lines:

| Line | Path through the menus |
|---|---|
| NS1 `use std::cmp::Ordering;` / `use std::io;` | auto-`use` from the generated `Ordering::Less` arm and from `Calls > Function > std > io > stdin` (R11: enum imported by name, free fn through its module; different parent modules, so two lines) |
| NS1 `use rand::prelude::*;` (after a blank line) | `Use and modules > Use everything (glob) > rand > prelude` (R9 groups) |
| NS1 `let secret_number = rand::rng().random_range(1..=100);` | `Let`; `Call > Function > Dependencies > rand > rng` (crate root: no `use`); Y > `Extend` > `Methods of` > `RngExt` > `random_range(range)` (`RngExt` is in scope through the glob); `Construct > Range > ●..=●` with keypad `1`, `100` |
| NS1 `io::stdin()` / `.read_line(&mut guess)` / `.expect("Failed to read line");` | `Calls > Function > std > io > stdin`; Y > `Extend` > `Methods of` > `read_line(buf)`; argument `Reference guess > &mut guess`; Y > `Extend` > `Unwrap` > `x.expect("…")`; the three rows come from rustfmt's `chain_width` (D5) |
| NS1 `let guess: u32 = match guess.trim().parse() {` | `Let (typed)` > `u32`; value `Choose > match`; scrutinee `Reference guess` (the earlier binding) > `Methods of` > `trim()` (generates `&str` arms) > Y > `Extend` > `Methods of` > `parse()`, which regenerates the untouched arms from `Result` (`Ok(brave_otter)`, `Err(error)`; "Untouched arms follow the scrutinee"); dictate `num`; LT+B on `error` → `_`; arm values `Reference num` and `Jump or panic > continue` |
| NS1 `println!("You guessed: {guess}");` | `Calls > Macro > Print > println!`; dictation; word by word `Insert > {name} > guess` |
| NS1 `match guess.cmp(&secret_number) {` with three arms | `Branching > Match`; `Reference guess > Methods of > cmp(other)`; argument `&secret_number (borrow)`; arms generated from `Ordering` (declaration order Less, Equal, Greater; Grab moves `Equal` last); Y on `=>` > `Expression body` on the two one-line arms |
| NS2 `use minifb::{Key, Window, WindowOptions};` | `Add crate > CATALOG > minifb` (confirm), then auto-`use` from `Window::new`, `WindowOptions::default()`, `Key::Escape` (same parent module: merged) |
| NS2 `#[derive(Debug, Clone, Copy, PartialEq, Eq)]` | `⊙ > Derive`: `Debug`, `Copy` (turns `Clone` on), `Eq` (turns `PartialEq` on); written in the fixed order |
| NS2 `OffscreenBuffer { memory: vec![0; width * height], width, height }` | `Associated function` named `new`, `ret` > `Self`; tail `Construct > Struct literal > OffscreenBuffer` (all fields); `memory`: `Call > Macro > Collections > vec![x; n]`; `width`, `height`: `Reference` → shorthand (R9) |
| NS2 `for (y, row) in self.memory.chunks_mut(self.width).enumerate() {` | `For each (take)`; iterable `Reference self > Field of > memory` > Y > `Extend` > `Methods of` > `chunks_mut(chunk_size)` (argument `self.width`) > Y > `Extend` > `Methods of` > `enumerate()`; the pattern follows the item type: `(brave_otter, calm_otter)`; dictate `y`, `row` |
| NS2 `let blue = (x as i32 + x_offset) as u8;` | `Let`; `Convert > ● as T` (`u8`); inner `Operator > Arithmetic > a + b`; left `Reference x > Convert > x as T` (`i32`); parentheses by R9 |
| NS2 `*pixel = u32::from(green) << 8 \| u32::from(blue);` | `Assignment > Assign (=)` > pick `pixel` > `Assign to > *pixel`; value `Operator > Bitwise > a \| b`, left `a << b` with `Convert > T::from(●)` |
| NS2 `match direction { Direction::Left => *x_offset -= 1, … }` | `Branching > Match`; arms generated from `Direction`; each arm body `Assignment > -=` / `+=` > `*x_offset`; Y on `=>` > `Expression body` |
| NS2 `let mut window = Window::new(…)?;` / `window.set_target_fps(60);` | `Let`; `Call > Associated function > Window > new`; `WindowOptions::default()` from `SUGGESTED`; Y > `Extend` > `Unwrap` > `x?`; picking `set_target_fps` (a `&mut self` method) adds `mut` (R12) |
| NS2 `if let Some(direction) = pressed_direction(&window) {` | `Branching > If let`; value `Call > Function > pressed_direction` with `&window`; the pattern follows: `Some(brave_otter)`; dictate `direction` |
| NS2 `eprintln!("handmade: {error}");` / `std::process::exit(1);` | `Macro > Print > eprintln!` with a `{name}` capture; `Calls > Function > std > process > exit`, then Y on `process` > `Path style > std::process::exit (full path, no use)` |
| NS2 `#[cfg(test)] mod tests { use super::*; #[test] fn … }` | `Tests > Test function` (creates the module) |

---

## Open questions

Build the default until the owner answers (as in `01`).

1. **Type-derived binding names.** Default `Some(●)` / `Ok(●)` / loop bindings to the snake_case of an ADT inner
   type (`Option<Direction>` → `direction`) instead of a generated name? Default here: generated names (P5); the
   NS2 build dictates `direction`.
2. **Removing a dependency** (and changing its version or features after adding it) needs a fourth out-of-file
   exception beyond D18. Default: not offered (Deferred).
3. **Cursor after a file-scope insert**: on the new name (this doc, R15) or on the green dot after it (Doodle)?
4. **`Refused` vs advisory when an additive fix exists** (R3). This doc refuses only when no additive one-step fix
   exists (`.await` outside async is advisory with `Make run async`; `break` outside a loop is refused). Confirm.
5. **Arm order** for generated arms: the enum's declaration order (this doc), or the order of the last match on
   the same type in the file?
6. **No default derives** on new types (this doc; fixes appear when needed) vs `#[derive(Debug)]` by default.
7. **Default visibility** in library crates: private everywhere (this doc) or `pub` for items added at a library
   crate root?
8. **The derive checklist keeps its toggles on B** (like Doodle's keypad, a P9 exception, one undo step). Or should
   B undo the toggles made in the open checklist?
9. **Struct field renames** propagate through the oracle (Doodle never propagated member renames,
   `features/04 §15`). Confirm.
10. **References query.** LT+B on a parameter removes the matching argument in calls the syntax layer can resolve;
    method-call sites need a references query that the oracle protocol (D6) does not have yet. Add
    `Query::References { at }`?
11. **Assist query.** Several builders reproduce rust-analyzer assists (`add_impl_missing_members`,
    `add_missing_match_arms`, `generate_new`, `wrap_return_type_in_result`). An `Assist` query would replace our
    builders with rust-analyzer's output at the cost of an async edit (D7.4). Default: our own synchronous
    builders.
12. **`Run at scope end (defer)`** depends on `scopeguard`; the alternative is generating a small local guard
    type with a `Drop` impl. Default: `scopeguard` (gray without it).

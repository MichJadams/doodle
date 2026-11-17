# Testing

Doodle is a GUI app, so we keep the **testable logic separate from rendering/IO**.

## Architecture for testability

- **`src/model`** — pure application logic: state machine, document model, menu
  navigation, insertion. **No** imports of `platform`/`gpu`/`text`. Driven by an
  abstract `model.Input` (button edges + trigger-hold flags) instead of raw SDL
  events. This is what we unit-test.
- **`src/app`** — SDL/GL rendering + input. Translates SDL events into
  `model.Input`, calls `model.update`, and draws `model.App`. Hard to unit-test
  (needs a window), so we keep it thin and push decisions into `model`.

This split means we can test "press A on File Setup then Package declaration
inserts `package main`" without opening a window.

## Running tests

```bash
# Windows
build.bat test

# Linux / Steam Deck
./build.sh test

# Or directly
odin test src/model
```

All tests should report `All tests were successful.` with no leak warnings.

## Writing tests

Tests live next to the code as `*_test.odin` in the same package, using
`core:testing`. Drive the model with synthetic input and assert state:

```odin
@(test)
test_add_package_inserts_text :: proc(t: ^testing.T) {
	app: App
	defer delete(app.doc.nodes)   // free the dynamic array (keeps mem tracker quiet)
	app.state = .Editor
	update(&app, Input{confirm = true}) // open Add menu
	update(&app, Input{confirm = true}) // File Setup -> submenu
	update(&app, Input{confirm = true}) // Package declaration
	testing.expect_value(t, app.doc.nodes[0], "package main")
}
```

Guidelines:
- Any test that inserts nodes should `defer delete(app.doc.nodes)`.
- Prefer asserting on `model.App` fields (state, radial.index/level/kind,
  doc.nodes) — they are the stable contract.
- When you add a construct/insertion, add a test that it inserts the expected
  default text and leaves the app in the right state.

## What to test as features land
- Node **selection / highlight / rename** (once added): cursor moves, rename
  changes the node text, delete removes it.
- Each **radial branch** (Procedures/Types/Values): selecting a leaf inserts the
  documented default snippet.
- **Name generation**: `adjective_animal` output is a valid identifier and
  collisions get suffixed.
- **Button-bank bindings**: given an `Input`, the correct action fires per bank.

## Future: rendering/golden tests
If we later want to guard visuals, we can render a frame to an offscreen
framebuffer and compare against a stored golden image. Not needed yet — the
logic tests cover behavior and are fast.

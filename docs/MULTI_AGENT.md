# Multi-Agent Workflow

How several agents (human or AI) work on Doodle IDE in parallel without
stepping on each other.

## Principles
1. **One package per agent.** Ownership is listed in `ARCHITECTURE.md §3`.
2. **Interfaces are frozen** in `ARCHITECTURE.md §5`. Changing another package's
   public procs/structs requires editing §5 in the same PR and a heads-up.
3. **`app/` is integration-only.** A single integrator wires packages and merges.
4. **Every package ships tests** (`*_test.odin`), even if just smoke tests.

## Branch & worktree-per-agent

Each agent works in an isolated worktree so builds/branches never collide:

```bash
# from the main clone
git worktree add ../doodle-text   feat/text
git worktree add ../doodle-input  feat/input
git worktree add ../doodle-lsp    feat/lsp
# ...one per active area
```

Work, commit, push the branch, open a PR. The integrator merges to `main`.

```bash
cd ../doodle-text
# edit only src/text/**
odin test src/text
git add -A && git commit -m "text: glyph atlas shelf packer"
git push -u origin feat/text
```

Remove a worktree when done:
```bash
git worktree remove ../doodle-text
```

## Suggested parallel work order (first wave)

These have the fewest cross-dependencies and can start immediately:

| Agent | Package        | First task                                   | Depends on |
|-------|----------------|----------------------------------------------|------------|
| A     | platform + gpu | SDL2 window + GL ctx + batched quad renderer | —          |
| C     | buffer         | gap buffer + line index + undo               | —          |
| D     | input          | gamepad read + action map + nav_target       | platform (events type only) |
| G     | project        | lazy dir read + fuzzy matcher                | —          |

Second wave (needs wave 1 interfaces working):

| Agent | Package | First task | Depends on |
|-------|---------|------------|------------|
| B | text | stb_truetype raster into gpu atlas | gpu |
| C | editor | cursors + visible_lines virtualization | buffer |
| D | ui | focus ring + command palette | gpu, text, input |
| F | lsp | ols spawn + didOpen + diagnostics | buffer types |
| E | stt | whisper spike + push-to-talk | platform audio |

## Definition of done per package
- Public procs implemented per `ARCHITECTURE.md §5`.
- `odin test src/<pkg>` passes.
- No new imports that violate the dependency rules (§3).
- Excalidraw board card moved to **Done**.

## Keeping the board in sync
The visual roadmap lives at
`Olympus/oden ide/Odin Gamepad IDE - Roadmap.excalidraw.md`.
When a card's status changes, drag it to the matching column. The generator
`_gen_roadmap.py` (in that folder) can regenerate the board if we restructure it.

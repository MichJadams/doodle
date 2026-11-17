# Olympus IDE

A **gamepad-navigable IDE for the Odin programming language**, written in Odin.
Runs on **Windows** and **Steam Deck (Linux)**. Voice input via local **Whisper**.

## Stack
- **Odin** (language) · **SDL2** (window/input/audio) · **OpenGL 3.3** (canvas)
- **stb_truetype** + GPU glyph atlas (text) · **whisper.cpp** (STT) · **ols** (Odin LSP)

## Repo layout
```
src/        one Odin package per subsystem (see ARCHITECTURE.md §3)
docs/       INSTALL.md, MULTI_AGENT.md
vendor/     third-party headers/binaries (SDL2, whisper, fonts)
assets/     fonts, icons
```

## Getting started
1. Install the toolchain: see [`docs/INSTALL.md`](docs/INSTALL.md).
2. Build & run:
   - Windows: `build.bat run`
   - Linux/Deck: `./build.sh run`
3. Read [`ARCHITECTURE.md`](ARCHITECTURE.md) before writing code — it defines the
   module boundaries and interface contracts.

## Multi-agent development
See [`docs/MULTI_AGENT.md`](docs/MULTI_AGENT.md). One package per agent, branch/
worktree per area, interfaces frozen in `ARCHITECTURE.md §5`.

## Status
Early scaffold. Progress is tracked visually in the Excalidraw board:
`Olympus/oden ide/Odin Gamepad IDE - Roadmap.excalidraw.md`.

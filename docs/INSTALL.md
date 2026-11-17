# Toolchain Setup

Olympus IDE builds on **Windows** and **Steam Deck (Linux)**. You need the Odin
compiler plus SDL2. stb_truetype and the OpenGL bindings ship inside Odin's
`vendor` collection, so there's nothing extra to install for those.

---

## 1. Windows

### 1.1 Prerequisites
- **LLVM / clang** is bundled with Odin's Windows release — no separate install.
- A C toolchain for linking: install **Visual Studio Build Tools** (the
  "Desktop development with C++" workload) if you don't already have MSVC.

### 1.2 Install Odin
Odin has no installer; you download/clone and put it on `PATH`.

```powershell
# Option A: clone + build from source (recommended, keeps you current)
git clone https://github.com/odin-lang/Odin.git C:\Odin
cd C:\Odin
# Run from a "x64 Native Tools Command Prompt for VS"
build.bat release

# Add to PATH (current user)
setx PATH "%PATH%;C:\Odin"
```

Or grab a prebuilt release zip from https://github.com/odin-lang/Odin/releases
and extract to `C:\Odin`, then `setx PATH` as above.

Verify (open a NEW terminal):
```powershell
odin version
```

### 1.3 SDL2
Odin ships SDL2 **bindings** in `vendor:sdl2`, but you still need the SDL2
runtime DLL + import lib.
- Download the SDL2 **VC** development package from https://libsdl.org
  (`SDL2-devel-<ver>-VC.zip`).
- Copy `SDL2.dll` next to the built `bin\olympus.exe` (or onto PATH).
- Odin's `vendor:sdl2` expects to find `SDL2.lib`; place it where the linker can
  see it, or point at it in the bindings' foreign import. (We'll pin the exact
  path in `src/platform` when we wire SDL up.)

### 1.4 Build
```powershell
build.bat run
```

---

## 2. Steam Deck / Linux

The Deck runs **SteamOS** (Arch-based, immutable root). Do development in
**Desktop Mode**.

### 2.1 Install Odin
SteamOS root FS is read-only, so install Odin into your home dir.
```bash
sudo pacman -S --needed clang llvm   # if writable; otherwise use the bundled LLVM in Odin release
git clone https://github.com/odin-lang/Odin.git ~/Odin
cd ~/Odin
make release          # or ./build.sh
echo 'export PATH="$HOME/Odin:$PATH"' >> ~/.bashrc
source ~/.bashrc
odin version
```
> SteamOS note: if `pacman` is locked/immutable, prefer the prebuilt Odin Linux
> release (bundled LLVM) extracted into `~/Odin`.

### 2.2 SDL2
```bash
sudo pacman -S --needed sdl2        # if available/writable
# else: use a flatpak SDK, or vendor SDL2 .so into vendor/ and set rpath.
```
SDL2 is almost always already present on SteamOS (games use it), but the
`-devel` headers/import pieces may need the package above for linking.

### 2.3 OpenGL
Mesa (RADV) on the Deck provides OpenGL 4.x — our GL 3.3 target is well within
range. No action needed.

### 2.4 Build & run
```bash
chmod +x build.sh
./build.sh run
```

---

## 3. Odin language server (ols) — for the IDE's own LSP feature

The IDE talks to `ols` to provide completion/diagnostics for Odin files the
*user* edits. Install it once:

```bash
git clone https://github.com/DanielGavin/ols.git
cd ols
# Windows:  build.bat
# Linux:    ./build.sh
# Put the resulting `ols` / `ols.exe` on PATH.
```
We'll point `lsp.start()` at this binary.

---

## 4. Whisper (STT) — deferred until the STT milestone

For the voice feature we use **whisper.cpp**:
```bash
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
cmake -B build && cmake --build build --config Release
# Download a model, e.g.:
bash ./models/download-ggml-model.sh base.en
```
Then either (a) link `libwhisper` via an Odin C-binding in `src/stt`, or
(b) invoke the `whisper.cpp` CLI/server as a subprocess. Decision is tracked on
the Excalidraw board.

---

## 5. Sanity check

```bash
odin version        # compiler present
./build.sh          # (or build.bat) scaffold compiles once SDL is wired
```
At the scaffold stage the packages are interface stubs; the first milestone
("SDL2 window + GL context + main loop") makes the window actually open.

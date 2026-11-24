# Doodle

**A cozy little IDE for the [Odin](https://odin-lang.org) programming language, played with a gamepad.**

![Doodle editing an Odin file](docs/screenshots/editor.png)

Doodle is an Odin editor you drive with a controller. It's written in Odin, it runs on Windows and Steam Deck. 

### Run on Steamdeck

To get on steamdeck, run this in desktop mode: 

```
curl -fsSL https://raw.githubusercontent.com/MichJadams/doodle/master/tools/deck_install.sh | bash

```

Then run doodle with 

```
~/Applications/doodle/bin/doodle

```
To launch it from Game Mode, add ~/Applications/doodle/bin/doodle to Steam as a non-Steam game (Steam > Games > Add a Non-Steam Game to My Library > Browse). 

Once it’s running, open main menu > Settings and use the Setup section to install Odin and clang.


## Features 

 Hold a trigger and dictate through local Whisper (no cloud) for naming variables and screaming numbers at your computer

### SteamOS release builds

A manual GitHub Actions workflow builds Doodle in Valve's Steam Linux Runtime ("sniper") SDK, on Ubuntu 22.04 and on Windows (x64), and publishes a release with `doodle-steamos-<version>.tar.gz`, `doodle-linux-<version>.tar.gz` and `doodle-windows-<version>.zip`:

```sh
gh workflow run release-steamos.yml -f version=0.1.0   # add -f prerelease=true for a test build
gh workflow run release-steamos.yml -f publish=false   # build only: packages stay on the run, no release
gh run watch                                            # follow it
```

On Windows, unzip `doodle-windows.zip` anywhere and run `doodle\bin\doodle.exe` (SDL2, speech-to-text and the model are included).
To build and run your programs it also needs the Odin compiler and Microsoft's C++ Build Tools: **main menu > Settings > Setup** shows whether they're there and installs what's missing (Odin is downloaded and checked by Doodle; the Build Tools come from Microsoft's own installer, through `winget`).
On other Linux desktops (Ubuntu 22.04 or newer, Debian 12, ...), unpack `doodle-linux.tar.gz` and run `doodle/bin/doodle` (SDL2, speech-to-text and the model are included).

**Updating:** an installed release updates itself: **main menu > Settings > Setup > Doodle** checks GitHub for a newer release, then downloads it (checked against the release's checksum) and installs it. Your settings and key layout are kept. On Linux and the Deck it's swapped in straight away and used from the next start; on Windows, Doodle closes, the new version is copied in, and it starts again.

On the Deck, `tools/deck_install.sh [tag]` downloads a release into `~/Applications/doodle`. Without a checkout:

```sh
curl -fsSL https://raw.githubusercontent.com/MichJadams/doodle/master/tools/deck_install.sh | bash
```

### Steam Deck: what's different

Doodle uses SDL2 and OpenGL 3.3 everywhere, so the editor, gamepad, sounds and menus are the same on the Deck. The differences are in the things Doodle hands off to the system:

| Feature | Windows | Steam Deck (SteamOS) | What to do on the Deck |
|---|---|---|---|
| Finding the Odin compiler | Doodle's own install (Settings > Setup), then `PATH`, then `C:\Odin` | Doodle's own install (Settings > Setup), `$ODIN_DIR`, `$ODIN_ROOT`, `toolchain/odin` next to Doodle, `~/odin`, `~/Odin`, `/opt/odin`, then `PATH` | **Settings > Setup > Odin compiler** downloads the Odin release Doodle is built with into `~/.local/share/doodle/odin`, checking its checksum. Or unpack Odin into `~/odin` yourself. Game Mode doesn't read `~/.bashrc`, so a `PATH` set there doesn't reach Doodle. |
| Run / build your program (`odin run`, `odin build`) | Needs Microsoft's C++ Build Tools (Odin links with Microsoft's linker and the Windows SDK); Settings > Setup opens their installer | **Needs `clang`**, which SteamOS doesn't ship. Odin's Linux release links through the system `clang` | **Settings > Setup > clang**: Doodle downloads Zig's self-contained clang (about 57 MB, checksum-checked) into `~/.local/share/doodle`. No root and no system headers needed. Runs started from Doodle find it automatically; to use it in your own terminal, add `~/.local/share/doodle/bin` to `PATH`. The first build after installing takes longer while Zig prepares its C library. A clang you install yourself is used first. It also adds `cc` and `ar`. |
| Programs that use `vendor:stb` (`vendor:stb/image`, `/truetype`, ...) | Work: Odin's Windows release has the stb libraries built | Odin's Linux release has stb as C source only, and nothing using it builds until it's compiled once | Done for you: Settings > Setup > clang builds them right after installing clang. If they're missing at a Run (say, after unpacking a newer Odin), Doodle offers to build them first, in the run's window. |
| Where a Run's output appears | A new console window | The first terminal found (`konsole` on SteamOS), or `$DOODLE_TERMINAL` | Desktop Mode works as on any Linux desktop. In Game Mode the terminal and your program open as separate windows (switch with the Steam button). With no terminal, the output goes to `.doodle/run.log` in the project. Answering "Press Enter to close" needs the on-screen keyboard (Steam + X). |
| Problem highlighting (`odin check`) | Works | Works once Odin is found | Doesn't need clang. |
| Deleting files and folders (Files, LT+B) | Goes to the Recycle Bin | **Deleted permanently** (there's no trash) | Double-check before deleting, or keep projects in git. |
| Speech-to-text (Talk) | Bundled `whisper-cli.exe` and model | Bundled `whisper-cli` (built for the Deck's CPU, no AVX-512) and model | Works out of the box with the Deck's microphone. It's slower than on a desktop PC. In the editor the words are worked out in the background ("transcribing..." at the top) and appear when ready. Dictating a Files search or a file name still waits for them. |
| Fonts | Your own `assets/fonts/mono.ttf` if present, else Consolas / Segoe UI | Your own `mono.ttf` if present, else the bundled DejaVu Sans Mono | Nothing to do: the font comes with Doodle. |
| Gamepad | Any XInput / SDL controller | The Deck's own controls, through Steam Input | Add `doodle/bin/doodle` to Steam as a non-Steam game and launch it from Steam, even in Desktop Mode. Launched from outside Steam, Steam's desktop layout turns the triggers and trackpads into mouse clicks and Doodle may see no gamepad. The back buttons (L4/R4/L5/R5) aren't used. |
| Vendor libraries for your program (SDL3, raylib, ...) | "Add to my PATH" changes the user `PATH` | "Add to my library path" appends to `~/.profile` | Game Mode doesn't read `~/.profile`, so choose "Just this run" there, or install the library in a system folder. |
| New Project > choose a folder | Starts at the drive list | Starts at `/`; no drive list | The SD card is under `/run/media/...`. Hidden (dot) folders aren't listed. |
| Default projects folder | `%USERPROFILE%\DoodleProjects` | `~/DoodleProjects` | Before this fix, Doodle on Linux used a `DoodleProjects` folder inside whatever folder it was started from. Launched from Steam that's usually the install folder, which `deck_install.sh` deletes on every update. If you saved projects with an older build, move them out of `~/Applications/doodle/bin/DoodleProjects` before updating. |
| Settings, key layout, menu heatmap | Saved next to `doodle.exe` | Saved next to `bin/doodle` (`~/Applications/doodle/bin`) | `tools/deck_install.sh` keeps them when it updates Doodle. |
| Typing (file names, Files search) | Keyboard | No keyboard attached | Use the on-screen keyboard (Steam + X), or plug in a keyboard. Doodle works without typing otherwise. |
| Copy (RT+A) | System clipboard | System clipboard | In Game Mode the clipboard may not reach other apps. |
| Screen size | Resizable window, 1280×800 to start | Full screen at the Deck's native 1280×800 | Same layout. |

## Credits

The sound effects come from Freesound under CC licenses. Full attribution is in [`assets/sounds/README.txt`](assets/sounds/README.txt).

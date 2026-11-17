# Speech-to-Text (push-to-talk, single words)

Doodle uses **whisper.cpp** for local, offline, one-off word/number dictation.
It is **not** for sentences — just single words or numbers (variable names,
numeric field values, short commands).

## Status (verified on this machine)
- whisper.cpp built **natively for ARM64** (clang `aarch64-w64-windows-gnu`).
- Binary: `third_party/whisper.cpp/build/bin/whisper-cli.exe`
- Model: `third_party/whisper.cpp/models/ggml-base.en.bin`
- Mic capture via SDL2 queue API works; full chain
  (capture -> WAV -> whisper -> word) verified.
- Grammar-constrained decoding verified (`--grammar`), the key accuracy lever.

## How to use (in the IDE)
Hold **Left Trigger + X** and speak one word, then release. The recognized word
shows top-right of the editor (`heard: <word>`); `[REC]` shows while recording.
PTT is disabled automatically if whisper isn't built yet (no crash).

> Gating (only enabling the mic when certain nodes are highlighted) is deliberately
> deferred — right now LT+X always listens so the pipeline can be exercised.

## Setup / rebuild
```bash
tools/stt/setup_whisper.sh            # base.en (default)
tools/stt/setup_whisper.sh tiny.en    # faster, less accurate (good on Deck)
tools/stt/setup_whisper.sh small.en   # slower, most accurate
```
This clones whisper.cpp into `third_party/`, builds `whisper-cli`, and downloads
the model. `third_party/` is git-ignored (large); recreate it with this script.

Windows uses the llvm-mingw clang toolchain automatically; Linux/Deck uses the
system compiler.

## Standalone probe (verify mic without the GUI)
```bash
odin build src/stt_probe -out:bin/stt_probe.exe
bin/stt_probe.exe        # records 1.5s, prints the recognized word
```

## Accuracy tuning for one-off words
Single-word recognition is much better when you **constrain the vocabulary** with
a GBNF grammar. Grammars live in `assets/stt/`:
- `number.gbnf`  — spoken numbers 0-99
- `digit.gbnf`   — a single digit 0-9
- `commands.gbnf`— editable fixed command-word list

Set `Config.grammar_path` for the active context (e.g. a numeric field uses
`assets/stt/number.gbnf`). The `stt` call runs whisper with:
`-tp 0 -bo 1 -bs 1` (deterministic greedy) and, when a grammar is set,
`--grammar <file> --grammar-rule root --grammar-penalty 100`.

Other levers:
- **Model**: `base.en` is a good default; `small.en` if you need more accuracy
  and can afford latency; `tiny.en` for speed on the Deck.
- **Silence hallucination**: whisper may emit "you"/"oh"/"thank you" on silence.
  Because this is push-to-talk (the user intends to speak), it's rarely an issue;
  grammars and a short capture window further reduce it. A VAD/energy gate can be
  added later.
- **`--prompt`**: biasing with an initial prompt of likely words can help.

## Run permissions
### Windows
- Settings → Privacy & security → **Microphone**: enable
  *"Let desktop apps access your microphone."* A plain built `.exe` is a desktop
  app and needs this toggle on.
- No elevation/admin required. SmartScreen may warn on first run of an unsigned
  exe; "More info → Run anyway".

### Steam Deck / Linux
- Audio runs through **PipeWire/PulseAudio**; the user is already in the `audio`
  group on SteamOS. No special permission prompt in Desktop Mode.
- Ensure the whisper binary is executable: `chmod +x third_party/whisper.cpp/build/bin/whisper-cli`.
- In Gaming Mode, confirm the mic is selected as the default capture device.

## Architecture
- `src/stt/stt.odin` — `init / begin / end / listen / shutdown`. Subprocess
  isolation (whisper-cli) keeps the heavy dependency out of the Odin process and
  matches the "leaf service" boundary in `ARCHITECTURE.md §3`.
- Runs whisper **synchronously** on release (a brief hitch). Making it async
  (worker thread, poll for result) is a planned refinement.

## Alternative STT (if we want even better constrained recognition)
For a *fixed* small vocabulary of command words, **Vosk** (Kaldi) with a
restricted grammar is extremely fast and accurate for single words and runs well
on the Deck. It can be swapped in behind the same `stt` interface if Whisper's
single-word accuracy proves insufficient for our command set.

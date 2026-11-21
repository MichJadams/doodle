package stt

// Push-to-talk single-word speech-to-text via whisper.cpp (subprocess).
// Owner: Agent E.  Overview: docs/STT.md
//
// Flow: SDL2 queue-based mic capture -> 16 kHz mono s16 WAV -> whisper-cli
// (optionally grammar-constrained) -> parse one cleaned word.
// Designed for ONE-OFF words / numbers, not sentences.

import sdl "vendor:sdl2"
import "core:c/libc"
import "core:os"
import "core:strings"
import "core:fmt"

SAMPLE_RATE :: 16000

Config :: struct {
	cli_path:     string, // path to whisper-cli(.exe)
	model_path:   string, // path to ggml-*.bin
	grammar_path: string, // optional GBNF grammar ("" = none)
	prompt:       string, // optional initial prompt (soft bias toward these words)
	vocabulary:   []string, // known identifiers/keywords; results snap to these
	free_text:    bool,   // true = preserve spaces (string literal), no identifier snapping
	tmp_wav:      string,
	tmp_txt:      string,
}

// Set per-utterance bias context (call before begin()). `prompt` softly nudges
// Whisper; `vocabulary` deterministically snaps near-misses (e.g. "maine"->"main").
set_context :: proc(e: ^Engine, prompt: string, vocabulary: []string) {
	if e == nil do return
	e.cfg.prompt = prompt
	e.cfg.vocabulary = vocabulary
}

// When true, transcription preserves spaces/casing (for string literals) and
// skips identifier snake_case/snapping.
set_free_text :: proc(e: ^Engine, free: bool) {
	if e == nil do return
	e.cfg.free_text = free
}

Engine :: struct {
	cfg:       Config,
	dev:       sdl.AudioDeviceID,
	available: bool,
	recording: bool,
}

CLI_NAME   :: "whisper-cli.exe" when ODIN_OS == .Windows else "whisper-cli"
MODEL_NAME :: "ggml-base.en.bin"

// default_config finds whisper-cli and the model. A release package keeps them
// beside Doodle (bin/whisper-cli, models/ggml-base.en.bin next to bin/); a dev
// checkout has them under third_party/whisper.cpp (tools/stt/setup_whisper.sh),
// found from the working folder or from bin/ upward. Paths that don't exist
// fall through to the last candidate so init() reports "not set up".
// Strings are heap-allocated and live for the program.
default_config :: proc() -> Config {
	exe := exe_dir(context.temp_allocator)
	cli := first_existing({
		fmt.tprintf("%s/%s", exe, CLI_NAME),
		fmt.tprintf("third_party/whisper.cpp/build/bin/%s", CLI_NAME),
		fmt.tprintf("%s/../third_party/whisper.cpp/build/bin/%s", exe, CLI_NAME),
	})
	model := first_existing({
		fmt.tprintf("%s/../models/%s", exe, MODEL_NAME),
		fmt.tprintf("%s/models/%s", exe, MODEL_NAME),
		fmt.tprintf("third_party/whisper.cpp/models/%s", MODEL_NAME),
		fmt.tprintf("%s/../third_party/whisper.cpp/models/%s", exe, MODEL_NAME),
	})
	tmp, terr := os.temp_directory(context.temp_allocator)
	if terr != nil || tmp == "" do tmp = "."
	return Config {
		cli_path     = strings.clone(cli),
		model_path   = strings.clone(model),
		grammar_path = "", // set to "assets/stt/number.gbnf" for numeric fields
		tmp_wav      = fmt.aprintf("%s/doodle_stt_capture.wav", tmp),
		tmp_txt      = fmt.aprintf("%s/doodle_stt_out.txt", tmp),
	}
}

// exe_dir: folder of the running executable ("." if unknown).
@(private)
exe_dir :: proc(allocator := context.allocator) -> string {
	if p, err := os.get_executable_path(context.temp_allocator); err == nil && p != "" {
		d, _ := os.split_path(p)
		return strings.clone(d, allocator)
	}
	return strings.clone(".", allocator)
}

// first_existing returns the first path that exists, else the last one.
@(private)
first_existing :: proc(paths: []string) -> string {
	for p in paths do if file_exists(p) do return p
	return paths[len(paths) - 1]
}

@(private)
file_exists :: proc(path: string) -> bool {
	h, err := os.open(path)
	if err != os.ERROR_NONE do return false
	os.close(h)
	return true
}

init :: proc(cfg: Config) -> (^Engine, bool) {
	if !file_exists(cfg.cli_path) || !file_exists(cfg.model_path) {
		return nil, false // whisper not set up: see docs/STT.md / tools/stt/setup_whisper.sh
	}
	if sdl.Init(sdl.INIT_AUDIO) != 0 do return nil, false

	want, have: sdl.AudioSpec
	want.freq = SAMPLE_RATE
	want.format = sdl.AUDIO_S16
	want.channels = 1
	want.samples = 1024

	e := new(Engine)
	e.cfg = cfg
	e.dev = sdl.OpenAudioDevice(nil, true, &want, &have, {}) // iscapture = true
	if e.dev == 0 {
		free(e)
		return nil, false
	}
	e.available = true
	return e, true
}

// Begin push-to-talk capture (call on button-down).
begin :: proc(e: ^Engine) {
	if e == nil || !e.available || e.recording do return
	sdl.ClearQueuedAudio(e.dev)
	sdl.PauseAudioDevice(e.dev, false) // unpause = start capturing
	e.recording = true
}

// Transcribe audio captured SO FAR without stopping (for multi-part dictation).
// Returns a cleaned identifier fragment ("" if nothing). Caller owns the string.
segment :: proc(e: ^Engine) -> string {
	if e == nil || !e.available || !e.recording do return ""
	return transcribe_queued(e)
}

// Stop capture, transcribe the remainder, return a cleaned identifier fragment.
end :: proc(e: ^Engine) -> string {
	if e == nil || !e.available || !e.recording do return ""
	sdl.PauseAudioDevice(e.dev, true)
	e.recording = false
	return transcribe_queued(e)
}

@(private)
transcribe_queued :: proc(e: ^Engine) -> string {
	size := sdl.GetQueuedAudioSize(e.dev)
	if size == 0 do return ""
	buf := make([]u8, int(size))
	defer delete(buf)
	got := sdl.DequeueAudio(e.dev, raw_data(buf), size)
	if got == 0 do return ""
	if !write_wav(e.cfg.tmp_wav, buf[:int(got)]) do return ""
	run_whisper(e.cfg)
	data, _ := os.read_entire_file(e.cfg.tmp_txt, context.allocator)
	defer if data != nil do delete(data)
	if e.cfg.free_text {
		return clean_free(string(data)) // preserve spaces/casing for string literals
	}
	res := clean_identifier(string(data))
	if len(e.cfg.vocabulary) > 0 {
		snapped := snap_identifier(res, e.cfg.vocabulary)
		delete(res)
		return snapped
	}
	return res
}

// Clean free text: trim, collapse internal whitespace to single spaces, drop a
// trailing period. Preserves words, spaces, and casing (caller owns result).
@(private)
clean_free :: proc(s: string) -> string {
	out: [dynamic]u8
	prev_space := true // suppress leading space
	for i in 0 ..< len(s) {
		c := s[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			if !prev_space {
				append(&out, ' ')
				prev_space = true
			}
		} else {
			append(&out, c)
			prev_space = false
		}
	}
	for len(out) > 0 && out[len(out) - 1] == ' ' do pop(&out)
	if len(out) > 0 && out[len(out) - 1] == '.' do pop(&out)
	for len(out) > 0 && out[len(out) - 1] == ' ' do pop(&out)
	return string(out[:])
}

// Snap each underscore-separated token to the nearest vocabulary word (edit
// distance <= 1). Leaves novel/short tokens untouched. Caller owns the result.
@(private)
snap_identifier :: proc(word: string, vocab: []string) -> string {
	out: [dynamic]u8
	start := 0
	for i := 0; i <= len(word); i += 1 {
		if i == len(word) || word[i] == '_' {
			tok := word[start:i]
			rep := snap_token(tok, vocab)
			if len(out) > 0 do append(&out, '_')
			append(&out, ..transmute([]u8)rep)
			start = i + 1
		}
	}
	return string(out[:])
}

@(private)
snap_token :: proc(tok: string, vocab: []string) -> string {
	if len(tok) < 3 do return tok
	for v in vocab do if v == tok do return tok // already exact
	best := tok
	best_d := 2 // snap only when distance <= 1
	for v in vocab {
		d := levenshtein(tok, v)
		if d < best_d {
			best_d = d
			best = v
		}
	}
	return best
}

@(private)
levenshtein :: proc(a, b: string) -> int {
	la, lb := len(a), len(b)
	if la == 0 do return lb
	if lb == 0 do return la
	prev := make([]int, lb + 1, context.temp_allocator)
	curr := make([]int, lb + 1, context.temp_allocator)
	for j in 0 ..= lb do prev[j] = j
	for i in 1 ..= la {
		curr[0] = i
		for j in 1 ..= lb {
			cost := a[i - 1] == b[j - 1] ? 0 : 1
			m := prev[j] + 1
			if curr[j - 1] + 1 < m do m = curr[j - 1] + 1
			if prev[j - 1] + cost < m do m = prev[j - 1] + cost
			curr[j] = m
		}
		copy(prev, curr)
	}
	return prev[lb]
}

// Convenience for a fixed-window one-shot capture (used by the probe).
listen :: proc(e: ^Engine, ms: u32) -> string {
	begin(e)
	sdl.Delay(ms)
	return end(e)
}

shutdown :: proc(e: ^Engine) {
	if e == nil do return
	if e.available do sdl.CloseAudioDevice(e.dev)
	free(e)
}

// ---- internals ----

@(private)
run_whisper :: proc(cfg: Config) {
	inner := whisper_command(cfg)
	defer delete(inner)
	// cmd.exe /c strips the outer quotes when the string starts with a quote,
	// so wrap the whole command in an extra pair on Windows.
	full: string
	when ODIN_OS == .Windows {
		full = strings.concatenate({"\"", inner, "\""}, context.temp_allocator)
	} else {
		full = inner
	}
	cmd := strings.clone_to_cstring(full, context.temp_allocator)
	libc.system(cmd)
}

// whisper_command builds the whisper-cli command line (stdout -> tmp_txt).
// Windows: double quotes for cmd.exe; elsewhere: POSIX single quotes, so
// paths with spaces and prompts with quotes/`$` reach whisper-cli intact.
// Caller owns the string.
whisper_command :: proc(cfg: Config) -> string {
	b := strings.builder_make()
	q :: proc(s: string) -> string {
		when ODIN_OS == .Windows {
			return fmt.tprintf("\"%s\"", s)
		} else {
			esc, _ := strings.replace_all(s, "'", `'\''`, context.temp_allocator)
			return fmt.tprintf("'%s'", esc)
		}
	}
	// greedy, deterministic, no timestamps/prints -> fastest for one word
	fmt.sbprintf(&b, "%s -m %s -f %s -nt -np -l en -tp 0 -bo 1 -bs 1 -t 4",
		q(cfg.cli_path), q(cfg.model_path), q(cfg.tmp_wav))
	if cfg.grammar_path != "" {
		fmt.sbprintf(&b, " --grammar %s --grammar-rule root --grammar-penalty 100", q(cfg.grammar_path))
	}
	if cfg.prompt != "" {
		fmt.sbprintf(&b, " --prompt %s", q(cfg.prompt))
	}
	null := "nul" when ODIN_OS == .Windows else "/dev/null"
	fmt.sbprintf(&b, " > %s 2> %s", q(cfg.tmp_txt), null)
	return strings.to_string(b)
}

// Lowercase, map non-alphanumeric runs to single underscores -> snake_case.
// e.g. "Brave Otter." -> "brave_otter". Caller owns the returned string.
@(private)
clean_identifier :: proc(s: string) -> string {
	out: [dynamic]u8
	prev_us := true // suppress leading underscore
	for i in 0 ..< len(s) {
		c := s[i]
		low := c
		if c >= 'A' && c <= 'Z' do low = c + 32
		if (low >= 'a' && low <= 'z') || (low >= '0' && low <= '9') {
			append(&out, low)
			prev_us = false
		} else if !prev_us {
			append(&out, '_')
			prev_us = true
		}
	}
	for len(out) > 0 && out[len(out) - 1] == '_' do pop(&out)
	return string(out[:])
}

@(private)
le16 :: proc(b: ^[dynamic]u8, v: u16) { append(b, u8(v), u8(v >> 8)) }
@(private)
le32 :: proc(b: ^[dynamic]u8, v: u32) { append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)) }

@(private)
write_wav :: proc(path: string, pcm: []u8) -> bool {
	data_len := u32(len(pcm))
	byte_rate := u32(SAMPLE_RATE * 1 * 2)
	b: [dynamic]u8
	defer delete(b)
	append(&b, 'R', 'I', 'F', 'F')
	le32(&b, 36 + data_len)
	append(&b, 'W', 'A', 'V', 'E')
	append(&b, 'f', 'm', 't', ' ')
	le32(&b, 16)      // fmt chunk size
	le16(&b, 1)       // PCM
	le16(&b, 1)       // mono
	le32(&b, SAMPLE_RATE)
	le32(&b, byte_rate)
	le16(&b, 2)       // block align
	le16(&b, 16)      // bits per sample
	append(&b, 'd', 'a', 't', 'a')
	le32(&b, data_len)
	append(&b, ..pcm)
	err := os.write_entire_file(path, b[:])
	return err == nil
}

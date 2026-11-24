package stt

import "core:testing"
import "core:strings"
import "core:os"
import "core:time"

@(test)
test_snap_maine_to_main :: proc(t: ^testing.T) {
	vocab := []string{"main", "player", "health"}
	got := snap_identifier("maine", vocab)
	defer delete(got)
	testing.expect_value(t, got, "main")
}

@(test)
test_snap_keeps_novel_word :: proc(t: ^testing.T) {
	vocab := []string{"main", "player"}
	got := snap_identifier("otterbox", vocab) // far from any vocab word
	defer delete(got)
	testing.expect_value(t, got, "otterbox")
}

@(test)
test_snap_multipart_identifier :: proc(t: ^testing.T) {
	vocab := []string{"main", "player"}
	got := snap_identifier("maine_playr", vocab) // each part within edit distance 1
	defer delete(got)
	testing.expect_value(t, got, "main_player")
}

@(test)
test_snap_leaves_short_tokens :: proc(t: ^testing.T) {
	vocab := []string{"main"}
	got := snap_identifier("ma", vocab) // too short to snap safely
	defer delete(got)
	testing.expect_value(t, got, "ma")
}

@(test)
test_clean_free_preserves_spaces :: proc(t: ^testing.T) {
	got := clean_free(" Hello world.")
	defer delete(got)
	testing.expect_value(t, got, "Hello world")
}

@(test)
test_clean_free_collapses_whitespace :: proc(t: ^testing.T) {
	got := clean_free("  multiple   spaces here  ")
	defer delete(got)
	testing.expect_value(t, got, "multiple spaces here")
}

@(test)
test_whisper_command_quoting :: proc(t: ^testing.T) {
	cfg := Config{
		cli_path = "/home/deck/My Apps/doodle/bin/whisper-cli",
		model_path = "/m/ggml-base.en.bin",
		tmp_wav = "/tmp/a.wav",
		tmp_txt = "/tmp/a.txt",
		prompt = "player's $HOME",
	}
	cmd := whisper_command(cfg)
	defer delete(cmd)
	when ODIN_OS == .Windows {
		testing.expect(t, strings.has_prefix(cmd, `"/home/deck/My Apps/doodle/bin/whisper-cli" -m "/m/ggml-base.en.bin"`))
		testing.expect(t, strings.has_suffix(cmd, `> "/tmp/a.txt" 2> nul`))
	} else {
		testing.expect(t, strings.has_prefix(cmd, `'/home/deck/My Apps/doodle/bin/whisper-cli' -m '/m/ggml-base.en.bin'`))
		testing.expect(t, strings.contains(cmd, `--prompt 'player'\''s $HOME'`))
		testing.expect(t, strings.has_suffix(cmd, `> '/tmp/a.txt' 2> /dev/null`))
	}
	testing.expect(t, !strings.contains(cmd, "--grammar"))
}

// Background transcription: clips come back in the order they were queued,
// one text each ("" for silence), without the caller waiting. Needs a
// whisper.cpp checkout (tools/stt/setup_whisper.sh); skipped without one.
@(test)
test_async_transcribes_in_order :: proc(t: ^testing.T) {
	cfg := default_config()
	defer { delete(cfg.cli_path); delete(cfg.model_path); delete(cfg.tmp_wav); delete(cfg.tmp_txt) }
	wav, err := os.read_entire_file("third_party/whisper.cpp/samples/jfk.wav", context.allocator)
	if err != nil || !file_exists(cfg.cli_path) || !file_exists(cfg.model_path) {
		delete(wav)
		return // whisper isn't set up here
	}
	defer delete(wav)
	cfg.free_text = true
	e := new(Engine)
	e.cfg = cfg
	pcm :: proc(wav: []u8) -> []u8 { out := make([]u8, len(wav) - 44); copy(out, wav[44:]); return out }
	clip := pcm(wav)
	defer delete(clip)
	queue_pcm(e, clip)
	queue_pcm(e, nil) // silence
	queue_pcm(e, clip)
	got := make([dynamic]string, context.temp_allocator)
	deadline := time.tick_now()
	for len(got) < 3 && time.tick_since(deadline) < 120 * time.Second {
		if s, ok := poll(e); ok do append(&got, s)
		else do time.sleep(20 * time.Millisecond)
	}
	e.available = false // no audio device to close
	shutdown(e)
	if !testing.expect_value(t, len(got), 3) do return
	testing.expectf(t, strings.contains(strings.to_lower(got[0], context.temp_allocator), "ask not what your country"), "first clip: %q", got[0])
	testing.expect_value(t, got[1], "")
	testing.expect_value(t, got[2], got[0])
	for s in got do delete(s)
}

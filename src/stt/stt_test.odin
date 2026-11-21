package stt

import "core:testing"
import "core:strings"

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

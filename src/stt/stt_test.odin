package stt

import "core:testing"

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

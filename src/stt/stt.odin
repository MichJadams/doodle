package stt

import "../platform"

// Whisper integration, push-to-talk, dictation modes.
// Owner: Agent E.  Contract: ARCHITECTURE.md §5.8

Mode :: enum { Command, Identifier, FreeText }

Engine :: struct {
	// whisper_context* (C binding) OR subprocess handle
	mode: Mode,
}

init      :: proc(model_path: string) -> (^Engine, bool) { return nil, false }
begin_ptt :: proc(e: ^Engine, cap: ^platform.Audio_Capture, mode: Mode) {}
end_ptt   :: proc(e: ^Engine) -> string { return "" } // blocking transcribe
shutdown  :: proc(e: ^Engine) {}

// Identifier mode: turn dictated words into a valid Odin identifier.
to_identifier :: proc(spoken: string) -> string { return spoken }

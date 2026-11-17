package main

// Standalone STT probe: records a short window and prints the recognized word.
// Verifies the whisper pipeline + microphone without the full IDE.
//   build: odin build src/stt_probe -out:bin/stt_probe.exe
//   run:   bin/stt_probe.exe            (speak one word when prompted)
// For numbers only, set grammar_path to assets/stt/number.gbnf below.

import "../stt"
import "core:fmt"

main :: proc() {
	cfg := stt.default_config()
	// cfg.grammar_path = "assets/stt/number.gbnf" // constrain to numbers 0-99

	e, ok := stt.init(cfg)
	if !ok {
		fmt.eprintln("STT not available.")
		fmt.eprintln("Build whisper + download a model first:  tools/stt/setup_whisper.sh")
		return
	}
	defer stt.shutdown(e)

	fmt.println("Recording 1.5s - speak ONE word or number now...")
	word := stt.listen(e, 1500)
	fmt.printf("Heard: \"%s\"\n", word)
}

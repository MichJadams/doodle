package ui

import "../gpu"
import "../text"
import "../input"

// Focus model, panels, command palette, controller glyph HUD.
// Owner: Agent D.  Contract: ARCHITECTURE.md §5.7

Ctx :: struct {
	r:        ^gpu.Renderer,
	font:     ^text.Font,
	input:    ^input.State,
	focus_id: u64,
	hot_id:   u64,
}

Hint :: struct { button: input.Button, label: string }

begin :: proc(ctx: ^Ctx) {}
end   ::

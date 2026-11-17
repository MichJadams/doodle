package input

// Default gamepad -> action mapping. User-overridable later.
// Owner: Agent D.

default_button_action :: proc(b: Button) -> (Action, bool) {
	#partial switch b {
	case .A:     return .Confirm, true
	case .B:     return .Cancel, true
	case .Up:    return .Nav_Up, true
	case .Down:  return .Nav_Down, true
	case .Left:  return .Nav_Left, true
	case .Right: return .Nav_Right, true
	case .LB:    return .Prev_Panel, true
	case .RB:    return .Next_Panel, true
	case .Y:     return .Command_Palette, true
	case .RT:    return .Dictate_Hold, true
	}
	return .Confirm, false
}

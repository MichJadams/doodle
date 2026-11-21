package main

// Sound effects: a tiny SDL mixer that plays short random slices of longer
// recordings (assets/sounds, made by tools/convert_sounds.py: mono, 16-bit,
// 44100 Hz). Paper crumpling when switching files, pencil scribbles when code is
// added. Optional: with no audio device or no files, everything is a no-op.

import "base:runtime"
import "core:c"
import "core:math"
import "core:math/rand"
import "core:strings"
import sdl "vendor:sdl2"

SFX_RATE :: 44100

Sfx :: enum { Crumple, Pencil1, Pencil2 }

SFX_FILES := [Sfx]string{
	.Crumple = "assets/sounds/paper-crumple.wav",
	.Pencil1 = "assets/sounds/pencil-1.wav",
	.Pencil2 = "assets/sounds/pencil-2.wav",
}

Sfx_Group :: enum { Paper, Pencil }

Voice :: struct {
	samples:          []i16,
	start, pos, end:  int,
	gain:             f32,
	group:            Sfx_Group,
	active:           bool,
}

FADE_IN  :: SFX_RATE * 15 / 1000  // 15 ms: no click at a slice's start
FADE_OUT :: SFX_RATE * 90 / 1000  // 90 ms: slices trail off rather than cut

g_sfx_dev:    sdl.AudioDeviceID
g_sfx_clips:  [Sfx][]i16
g_sfx_rms:    [Sfx]f32 // whole-clip loudness, to skip near-silent slices
g_sfx_voices: [8]Voice // touched by the audio thread: lock the device to modify

sound_init :: proc() {
	if sdl.InitSubSystem(sdl.INIT_AUDIO) != 0 do return
	any_loaded := false
	for path, s in SFX_FILES {
		cpath := strings.clone_to_cstring(asset_path(path), context.temp_allocator)
		spec: sdl.AudioSpec
		buf: [^]u8
		n: u32
		if sdl.LoadWAV(cpath, &spec, &buf, &n) == nil do continue
		if spec.freq == SFX_RATE && spec.channels == 1 && spec.format == sdl.AUDIO_S16LSB {
			src := ([^]i16)(buf)[:n / 2]
			g_sfx_clips[s] = make([]i16, len(src))
			copy(g_sfx_clips[s], src)
			g_sfx_rms[s] = rms(g_sfx_clips[s])
			any_loaded = true
		}
		sdl.FreeWAV(buf)
	}
	if !any_loaded do return

	want, have: sdl.AudioSpec
	want.freq = SFX_RATE
	want.format = sdl.AUDIO_S16
	want.channels = 1
	want.samples = 512
	want.callback = sfx_mix
	g_sfx_dev = sdl.OpenAudioDevice(nil, false, &want, &have, {}) // SDL converts to the device format
	if g_sfx_dev != 0 do sdl.PauseAudioDevice(g_sfx_dev, false)
}

sound_shutdown :: proc() {
	if g_sfx_dev != 0 do sdl.CloseAudioDevice(g_sfx_dev)
	g_sfx_dev = 0
	for &clip in g_sfx_clips {
		delete(clip)
		clip = nil
	}
}

// sfx_paper: a brief random bit of paper crumpling (switching files).
sfx_paper :: proc() {
	play_slice(.Crumple, .Paper, rand.float32_range(0.22, 0.38), 0.55)
}

// sfx_pencil: a random stretch of pencil scribbling (code added).
sfx_pencil :: proc() {
	s := rand.int_max(2) == 0 ? Sfx.Pencil1 : Sfx.Pencil2
	if g_sfx_clips[s] == nil do s = s == .Pencil1 ? .Pencil2 : .Pencil1
	play_slice(s, .Pencil, rand.float32_range(0.35, 0.6), 0.6)
}

// play_slice plays `secs` of clip `s` from a random, not-too-quiet spot. A new
// sound in a group fades out the one already playing (no pile-ups on fast edits).
@(private = "file")
play_slice :: proc(s: Sfx, group: Sfx_Group, secs, gain: f32) {
	if trace_replaying() do return // TRACE hook: a fast replay stays quiet
	clip := g_sfx_clips[s]
	if g_sfx_dev == 0 || clip == nil do return
	n := min(int(secs * SFX_RATE), len(clip))
	start := 0
	if len(clip) > n {
		best, best_rms := 0, f32(-1)
		for _ in 0 ..< 10 {
			at := rand.int_max(len(clip) - n)
			r := rms(clip[at:][:n])
			if r > best_rms do best, best_rms = at, r
			if r >= g_sfx_rms[s] * 0.8 do break // loud enough: take it
		}
		start = best
	}

	sdl.LockAudioDevice(g_sfx_dev)
	defer sdl.UnlockAudioDevice(g_sfx_dev)
	slot := -1
	for &v, i in g_sfx_voices {
		if v.active && v.group == group do v.end = min(v.end, v.pos + FADE_OUT)
		if !v.active && slot < 0 do slot = i
	}
	if slot < 0 do return
	g_sfx_voices[slot] = Voice{clip, start, start, start + n, gain, group, true}
}

@(private = "file")
rms :: proc(s: []i16) -> f32 {
	if len(s) == 0 do return 0
	acc: f64
	for x in s do acc += f64(x) * f64(x)
	return f32(math.sqrt(acc / f64(len(s))))
}

// Audio-thread callback: mix the active voices into the (mono S16) stream.
@(private = "file")
sfx_mix :: proc "c" (userdata: rawptr, stream: [^]u8, length: c.int) {
	context = runtime.default_context()
	out := ([^]i16)(stream)[:length / 2]
	for i in 0 ..< len(out) {
		acc: f32
		for &v in g_sfx_voices {
			if !v.active do continue
			if v.pos >= v.end {
				v.active = false
				continue
			}
			env := min(1, f32(v.pos - v.start) / FADE_IN, f32(v.end - v.pos) / FADE_OUT)
			acc += f32(v.samples[v.pos]) * v.gain * env
			v.pos += 1
		}
		out[i] = i16(clamp(acc, -32768, 32767))
	}
}

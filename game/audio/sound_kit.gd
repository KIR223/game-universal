class_name SoundKit
extends RefCounted
## Original procedural sounds (no external assets, no licences): UI blips, notification chimes and an ambient pad generated in code.

const RATE := 22050
static var _cache: Dictionary = {}


## One short tone with an exponential decay. freqs are mixed (chords), `sweep` shifts the pitch over the duration.
static func tone(freqs: Array, dur: float, vol: float = 0.5, attack: float = 0.004, sweep: float = 0.0) -> AudioStreamWAV:
	var n := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / RATE
		var env := minf(t / attack, 1.0) * exp(-t * (4.5 / dur))
		var s := 0.0
		for f in freqs:
			var fr: float = f * (1.0 + sweep * t / dur)
			s += sin(TAU * fr * t) + 0.25 * sin(TAU * fr * 2.0 * t)
		s = s / maxf(freqs.size(), 1) * env * vol
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	return _wav(data, false)


static func _wav(data: PackedByteArray, loop: bool) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = data.size() / 2
	return w


## Named UI sounds, built once.
static func ui(name: String) -> AudioStreamWAV:
	if _cache.has(name):
		return _cache[name]
	var s: AudioStreamWAV
	match name:
		"click": s = tone([740.0], 0.06, 0.35, 0.002)
		"open": s = tone([392.0, 587.0], 0.16, 0.3, 0.01, 0.35)
		"close": s = tone([587.0, 392.0], 0.14, 0.28, 0.01, -0.3)
		"notify": s = tone([880.0, 1318.0], 0.28, 0.32, 0.006)
		"error": s = tone([196.0, 207.0], 0.2, 0.4, 0.004)
		"select": s = tone([523.0], 0.08, 0.3, 0.003, 0.15)
		_: s = tone([440.0], 0.05, 0.2)
	_cache[name] = s
	return s


## Slow ambient pad: a minor chord with gentle beating, seamless loop of `seconds` (whole cycles of every partial).
static func ambient(seconds: int = 16) -> AudioStreamWAV:
	var rate := 11025
	var n := rate * seconds
	var data := PackedByteArray()
	data.resize(n * 2)
	var partials := [[55.0, 0.5], [82.5, 0.35], [110.0, 0.28], [130.8, 0.2], [164.8, 0.16], [220.0, 0.1]]
	for i in n:
		var t := float(i) / rate
		var s := 0.0
		for p in partials:
			var f: float = round(p[0] * seconds) / seconds   # whole number of cycles per loop -> no click at the seam
			var lfo := 0.6 + 0.4 * sin(TAU * t / seconds * (1.0 + float(partials.find(p) % 3)))
			s += sin(TAU * f * t) * p[1] * lfo
		data.encode_s16(i * 2, int(clampf(s * 0.22, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n
	return w

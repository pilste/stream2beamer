'use strict'
// Test der Bedienseiten-Logik mit nachgebautem ATEM-Zustand (laeuft ohne ATEM). Aufruf: npm test
const assert = require('assert')
const lib = require('../lib')

let fail = 0
function t(name, fn) {
	try { fn(); console.log('  OK   ' + name) } catch (e) { fail++; console.log('  FEHLER ' + name + ': ' + e.message) }
}

const targets = lib.streamTargets('192.168.10.20', '192.168.10.10')
const state = {
	info: { productIdentifier: 'ATEM Mini Pro ISO' },
	inputs: {
		0: { inputId: 0, shortName: 'BLK', internalPortType: 1 },
		1: { inputId: 1, shortName: 'CAM1', longName: 'Kamera 1', internalPortType: 0 },
		2: { inputId: 2, shortName: 'CAM2', longName: 'Kamera 2', internalPortType: 0 },
		1000: { inputId: 1000, shortName: 'BARS', internalPortType: 2 },
		10010: { inputId: 10010, shortName: 'PGM', internalPortType: 128 },
	},
	video: { mixEffects: [{ programInput: 1, previewInput: 2, transitionPosition: { inTransition: false }, fadeToBlack: { isFullyBlack: false, inTransition: false } }] },
	streaming: { status: { state: 4 }, service: { serviceName: 'Raspberry Pi Beamer', url: 'rtmp://192.168.10.20/live', key: '' }, duration: { hours: 0, minutes: 2, seconds: 5 } },
	fairlight: {
		inputs: {
			1: { sources: { '-65280': { properties: { faderGain: -1000, mixOption: 4, supportedMixOptions: [1, 2, 4] } } } },
			1301: { sources: { '-65280': { properties: { faderGain: 0, mixOption: 2, supportedMixOptions: [1, 2] } } } },
		},
		master: { properties: { faderGain: -500 } },
	},
}

console.log('1. Zusammenfassung')
const s = lib.summarize(state, targets, { receiving: true })
t('verbunden und Modell', () => { assert.strictEqual(s.connected, true); assert.strictEqual(s.model, 'ATEM Mini Pro ISO') })
t('Kameras zuerst, PGM-Ausgang nicht als Quelle', () => assert.deepStrictEqual(s.inputs.map((i) => i.id), [1, 2, 0, 1000]))
t('Programm/Vorschau', () => { assert.strictEqual(s.program, 1); assert.strictEqual(s.preview, 2) })
t('Stream on air, Ziel Pi erkannt (Key egal)', () => { assert.strictEqual(s.stream.onAir, true); assert.strictEqual(s.stream.target, 'pi'); assert.strictEqual(s.stream.duration, '00:02:05') })
t('Ton: Kamera 1 AFV -10 dB, Mikro 1 ein', () => {
	assert.strictEqual(s.audio.length, 2)
	assert.deepStrictEqual([s.audio[0].name, s.audio[0].gain, s.audio[0].mix], ['Kamera 1', -1000, 'afv'])
	assert.deepStrictEqual([s.audio[1].name, s.audio[1].mix, s.audio[1].options], ['Mikro 1', 'ein', ['aus', 'ein']])
	assert.strictEqual(s.master.gain, -500)
})
t('ohne ATEM: nur "nicht verbunden"', () => assert.deepStrictEqual(lib.summarize(null, targets, {}), { connected: false, pi: {} }))

console.log('2. Befehle')
t('Programm auf CAM2', () => assert.deepStrictEqual(lib.translate({ cmd: 'program', input: 2 }, s, targets), ['changeProgramInput', 2]))
t('unbekannte Quelle abgelehnt', () => assert.throws(() => lib.translate({ cmd: 'program', input: 7 }, s, targets), /Unbekannte Quelle/))
t('Zielwechsel waehrend On Air abgelehnt', () => assert.throws(() => lib.translate({ cmd: 'target', name: 'laptop' }, s, targets), /Erst den Stream stoppen/))
t('Zielwechsel wenn aus: Laptop-SRT', () => {
	const off = { ...s, stream: { ...s.stream, onAir: false } }
	assert.deepStrictEqual(lib.translate({ cmd: 'target', name: 'laptop' }, off, targets),
		['setStreamingService', { serviceName: 'stream2beamer SRT', url: 'srt://192.168.10.10:9000', key: 'beamer' }])
})
t('Stream an/aus', () => {
	assert.deepStrictEqual(lib.translate({ cmd: 'stream', on: true }, s, targets), ['startStreaming'])
	assert.deepStrictEqual(lib.translate({ cmd: 'stream', on: false }, s, targets), ['stopStreaming'])
})
t('Fader setzen', () => assert.deepStrictEqual(lib.translate({ cmd: 'fader', input: 1, source: '-65280', gain: -2050 }, s, targets),
	['setFairlightAudioMixerSourceProps', 1, '-65280', { faderGain: -2050 }]))
t('Fader ausserhalb des Bereichs abgelehnt', () => assert.throws(() => lib.translate({ cmd: 'fader', input: 1, source: '-65280', gain: 5000 }, s, targets)))
t('AFV nicht erlaubt fuer Mikro', () => assert.throws(() => lib.translate({ cmd: 'mix', input: 1301, source: '-65280', option: 'afv' }, s, targets), /nicht moeglich/))
t('Mikro aus', () => assert.deepStrictEqual(lib.translate({ cmd: 'mix', input: 1301, source: '-65280', option: 'aus' }, s, targets),
	['setFairlightAudioMixerSourceProps', 1301, '-65280', { mixOption: 1 }]))
t('unbekannter Befehl', () => assert.throws(() => lib.translate({ cmd: 'rm' }, s, targets), /Unbekannter Befehl/))

console.log('3. Media')
const sm = lib.summarize({
	...state,
	settings: { videoMode: 12 },
	media: { stillPool: [{ isUsed: true, fileName: 'Logo' }, { isUsed: false }, { isUsed: true, fileName: '' }], players: [{ sourceType: 1, stillIndex: 2, clipIndex: 0 }] },
}, targets, {})
t('Standbilder, MP1 und Aufloesung', () => {
	assert.deepStrictEqual(sm.media.stills.map((s) => [s.used, s.name]), [[true, 'Logo'], [false, ''], [true, 'Bild 3']])
	assert.deepStrictEqual(sm.media.player, { type: 'still', still: 2, clip: 0 })
	assert.deepStrictEqual(sm.resolution, { width: 1920, height: 1080 })
})
t('Bild in MP1', () => assert.deepStrictEqual(lib.translate({ cmd: 'mp-still', index: 0 }, sm, targets), ['setMediaPlayerSource', { sourceType: 1, stillIndex: 0 }, 0]))
t('leerer Platz nicht in MP1', () => assert.throws(() => lib.translate({ cmd: 'mp-still', index: 1 }, sm, targets), /Kein Bild/))
t('Bild loeschen', () => assert.deepStrictEqual(lib.translate({ cmd: 'still-clear', index: 2 }, sm, targets), ['clearMediaPoolStill', 2]))
const P = (o) => new URLSearchParams(o)
const full = 1920 * 1080 * 4
t('Upload: Name mit Umlauten wird ATEM-tauglich', () => assert.deepStrictEqual(lib.checkUpload(P({ index: '1', name: 'Grüße Größe 😀' }), full, sm), { index: 1, name: 'Gruesse Groesse' }))
t('Upload: ohne Name -> Bild N', () => assert.deepStrictEqual(lib.checkUpload(P({ index: '1' }), full, sm), { index: 1, name: 'Bild 2' }))
t('Upload: falsche Groesse abgelehnt', () => assert.throws(() => lib.checkUpload(P({ index: '1' }), full - 4, sm), /1920x1080/))
t('Upload: Platz ausserhalb abgelehnt', () => assert.throws(() => lib.checkUpload(P({ index: '3' }), full, sm), /Speicherplatz/))

t('Browser-Umrechnung byte-gleich mit atem-connection (Zufallsbild 1920x1080 und 720x576)', () => {
	const ours = require('../public/yuv.js')
	const { convertRGBAToYUV422 } = require('atem-connection/dist/lib/converters/rgbaToYuv422')
	for (const [w, h] of [[1920, 1080], [720, 576]]) {
		const rgba = Buffer.alloc(w * h * 4)
		for (let i = 0; i < rgba.length; i++) rgba[i] = (i * 2654435761) >>> 24   // deterministisches Rauschen
		const a = Buffer.from(ours(w, h, rgba)), b = convertRGBAToYUV422(w, h, rgba)
		assert.ok(a.equals(b), `${w}x${h} unterscheidet sich`)
	}
})

console.log('3b. Equalizer')
// Baender wie vom echten ATEM gelesen (15.10.2026)
const EQ = { enabled: true, gain: 0, bands: [
	{ bandEnabled: false, supportedShapes: [1, 2, 16, 32], shape: 16, supportedFrequencyRanges: [1], frequencyRange: 1, frequency: 46, gain: 0, qFactor: 71 },
	{ bandEnabled: true, supportedShapes: [1, 4, 8, 32], shape: 1, supportedFrequencyRanges: [1, 2, 4, 8], frequencyRange: 1, frequency: 49, gain: 0, qFactor: 80 },
	{ bandEnabled: true, supportedShapes: [1, 4, 8, 32], shape: 4, supportedFrequencyRanges: [1, 2, 4, 8], frequencyRange: 2, frequency: 171, gain: 0, qFactor: 230 },
] }
const eqState = { ...state, fairlight: { inputs: { 1: { sources: { '-65280': { properties: state.fairlight.inputs[1].sources['-65280'].properties, equalizer: EQ } } } },
	master: { properties: { faderGain: 0 }, equalizer: EQ } } }
const se = lib.summarize(eqState, targets, {})
const T1 = { input: 1, source: '-65280' }
t('EQ im Zustand: Baender, Formen mit Namen', () => {
	assert.strictEqual(se.audio[0].eq.bands.length, 3)
	assert.deepStrictEqual(se.audio[0].eq.bands[2], { band: 2, on: true, shape: 4, shapes: [{ id: 1, name: 'Tiefen-Kuhschwanz' }, { id: 4, name: 'Glocke' }, { id: 8, name: 'Kerbe' }, { id: 32, name: 'Höhen-Kuhschwanz' }], ranges: [1, 2, 4, 8], range: 2, freq: 171, gain: 0, q: 230 })
	assert.strictEqual(se.master.eq.enabled, true)
})
t('EQ aus', () => assert.deepStrictEqual(lib.translate({ cmd: 'eq', ...T1, enabled: false }, se, targets), ['setFairlightAudioMixerSourceProps', 1, '-65280', { equalizerEnabled: false }]))
t('Band: Frequenz 2,5 kHz waehlt Bereich MidHigh', () => assert.deepStrictEqual(lib.translate({ cmd: 'eq-band', ...T1, band: 2, freq: 2500 }, se, targets),
	['setFairlightAudioMixerSourceEqualizerBandProps', 1, '-65280', 2, { frequency: 2500, frequencyRange: 4 }]))
t('Band 1 (nur ein Bereich): kein Bereich mitgeschickt', () => assert.deepStrictEqual(lib.translate({ cmd: 'eq-band', ...T1, band: 0, freq: 80, on: true }, se, targets),
	['setFairlightAudioMixerSourceEqualizerBandProps', 1, '-65280', 0, { bandEnabled: true, frequency: 80 }]))
t('Band: Pegel und Guete', () => assert.deepStrictEqual(lib.translate({ cmd: 'eq-band', ...T1, band: 2, gain: -350, q: 140 }, se, targets),
	['setFairlightAudioMixerSourceEqualizerBandProps', 1, '-65280', 2, { gain: -350, qFactor: 140 }]))
t('Band: Pegel ueber +20 dB abgelehnt', () => assert.throws(() => lib.translate({ cmd: 'eq-band', ...T1, band: 2, gain: 2500 }, se, targets)))
t('Band: Filterform nicht erlaubt (Tiefpass an Band 3)', () => assert.throws(() => lib.translate({ cmd: 'eq-band', ...T1, band: 2, shape: 2 }, se, targets), /Filterform/))
t('Master-EQ Band', () => assert.deepStrictEqual(lib.translate({ cmd: 'eq-band', source: 'master', band: 1, gain: 300 }, se, targets),
	['setFairlightAudioMixerMasterEqualizerBandProps', 1, { gain: 300 }]))
t('Master-EQ aus', () => assert.deepStrictEqual(lib.translate({ cmd: 'eq', source: 'master', enabled: false }, se, targets), ['setFairlightAudioMixerMasterProps', { equalizerEnabled: false }]))

t('Band 3 auf 171 Hz zurueck: Bereich MidLow bleibt (Fehler vom 15.10.2026)', () => assert.deepStrictEqual(lib.translate({ cmd: 'eq-band', ...T1, band: 2, freq: 171 }, se, targets),
	['setFairlightAudioMixerSourceEqualizerBandProps', 1, '-65280', 2, { frequency: 171 }]))
t('Band 1 nur Low: 1000 Hz wird auf 395 Hz begrenzt', () => assert.deepStrictEqual(lib.translate({ cmd: 'eq-band', ...T1, band: 0, freq: 1000 }, se, targets),
	['setFairlightAudioMixerSourceEqualizerBandProps', 1, '-65280', 0, { frequency: 395 }]))
t('EQ Standard (Reset)', () => assert.deepStrictEqual(lib.translate({ cmd: 'eq-reset', ...T1 }, se, targets), ['setFairlightAudioMixerSourceEqualizerReset', 1, '-65280', { equalizer: true }]))
t('Master-EQ Standard', () => assert.deepStrictEqual(lib.translate({ cmd: 'eq-reset', source: 'master' }, se, targets), ['setFairlightAudioMixerMasterEqualizerReset', { equalizer: true }]))
t('EQ-Preset Sprache: EQ an + je Band ein Befehl, Bereiche passend', () => {
	const [m, list] = lib.translate({ cmd: 'eq-preset', ...T1, preset: 'sprache' }, se, targets)
	assert.strictEqual(m, '__multi')
	assert.deepStrictEqual(list[0], ['setFairlightAudioMixerSourceProps', 1, '-65280', { equalizerEnabled: true, equalizerGain: 0 }])
	assert.strictEqual(list.length, 4) // Testzustand hat nur 3 Baender
	assert.deepStrictEqual(list[1], ['setFairlightAudioMixerSourceEqualizerBandProps', 1, '-65280', 0, { bandEnabled: true, shape: 16, frequency: 100, gain: 0, qFactor: 71 }])
	assert.deepStrictEqual(list[3], ['setFairlightAudioMixerSourceEqualizerBandProps', 1, '-65280', 2, { bandEnabled: false, shape: 4, frequency: 800, gain: 0, qFactor: 140 }])
})
t('alle EQ-Presets passen in die Baender des ATEM (Formen und Frequenzbereiche)', () => {
	const real = { ...EQ, bands: [EQ.bands[0], EQ.bands[1], EQ.bands[2], { ...EQ.bands[2], frequencyRange: 4, frequency: 798 }, { ...EQ.bands[1], shape: 32, frequencyRange: 8, frequency: 7260 },
		{ bandEnabled: false, supportedShapes: [1, 2, 16, 32], shape: 2, supportedFrequencyRanges: [8], frequencyRange: 8, frequency: 12900, gain: 0, qFactor: 71 }] }
	const s6 = lib.summarize({ ...eqState, fairlight: { ...eqState.fairlight, inputs: { 1: { sources: { '-65280': { properties: eqState.fairlight.inputs[1].sources['-65280'].properties, equalizer: real } } } } } }, targets, {})
	for (const k of Object.keys(lib.PRESET_LABELS.eq)) {
		const [, list] = lib.translate({ cmd: 'eq-preset', ...T1, preset: k }, s6, targets)
		assert.strictEqual(list.length, 7, k)
		for (const [, , , band, p] of list.slice(1)) assert.ok(p.shape !== undefined, `${k} Band ${band + 1}: Form nicht erlaubt`)
	}
})

console.log('3c. Kanalzug und Dynamik')
const dynState = { ...eqState, fairlight: { inputs: {
	1301: { properties: { activeInputLevel: 1, supportedInputLevels: [1, 2] }, sources: { '-65280': {
		properties: { faderGain: 0, mixOption: 2, supportedMixOptions: [1, 2], gain: 0, balance: 0, framesDelay: 0, maxFramesDelay: 8 },
		dynamics: { makeUpGain: 0, expander: { expanderEnabled: false, gateEnabled: false, threshold: -4500, range: 1800, ratio: 110, attack: 140, hold: 0, release: 9300 },
			compressor: { compressorEnabled: false, threshold: -3500, ratio: 200, attack: 140, hold: 0, release: 9300 }, limiter: { limiterEnabled: false, threshold: -1200, attack: 71, hold: 0, release: 9300 } } } } } },
	master: { properties: { faderGain: 0, followFadeToBlack: false }, dynamics: { makeUpGain: 0, compressor: { compressorEnabled: false, threshold: -3500, ratio: 200, attack: 140, hold: 0, release: 9300 }, limiter: { limiterEnabled: false, threshold: -1200, attack: 71, hold: 0, release: 9300 } } } } }
const sd = lib.summarize(dynState, targets, {})
const M1 = { input: 1301, source: '-65280' }
t('Kanalzug im Zustand: Mikro mit Mikro/Line, Verzoegerung bis 8 Bilder', () => {
	assert.deepStrictEqual(sd.audio[0].strip, { inGain: 0, balance: 0, delay: 0, maxDelay: 8, level: 1, levels: [1, 2] })
	assert.deepStrictEqual(sd.audio[0].dyn.cmp, { on: false, threshold: -3500, ratio: 200, range: undefined, attack: 140, hold: 0, release: 9300 })
	assert.strictEqual(sd.master.ftbFollow, false); assert.strictEqual(sd.master.dyn.exp, undefined)
})
t('Gain +6 dB, Balance links, Verzoegerung 2', () => assert.deepStrictEqual(lib.translate({ cmd: 'strip', ...M1, inGain: 600, balance: -5000, delay: 2 }, sd, targets),
	['setFairlightAudioMixerSourceProps', 1301, '-65280', { gain: 600, balance: -5000, framesDelay: 2 }]))
t('Gain ueber +6 dB abgelehnt', () => assert.throws(() => lib.translate({ cmd: 'strip', ...M1, inGain: 700 }, sd, targets)))
t('Verzoegerung ueber Maximum abgelehnt', () => assert.throws(() => lib.translate({ cmd: 'strip', ...M1, delay: 9 }, sd, targets)))
t('Mikro auf Line', () => assert.deepStrictEqual(lib.translate({ cmd: 'input-level', ...M1, level: 2 }, sd, targets), ['setFairlightAudioMixerInputProps', 1301, { activeInputLevel: 2 }]))
t('Kompressor an, 4:1 ab -20 dB', () => assert.deepStrictEqual(lib.translate({ cmd: 'dyn', ...M1, stage: 'cmp', on: true, ratio: 400, threshold: -2000 }, sd, targets),
	['setFairlightAudioMixerSourceCompressorProps', 1301, '-65280', { compressorEnabled: true, threshold: -2000, ratio: 400 }]))
t('Gate', () => assert.deepStrictEqual(lib.translate({ cmd: 'dyn', ...M1, stage: 'exp', on: true, gate: true }, sd, targets),
	['setFairlightAudioMixerSourceExpanderProps', 1301, '-65280', { expanderEnabled: true, gateEnabled: true }]))
t('Limiter-Schwelle unter -30 dB abgelehnt', () => assert.throws(() => lib.translate({ cmd: 'dyn', ...M1, stage: 'lim', threshold: -3100 }, sd, targets)))
t('Dynamik Standard: Werte zuruecksetzen UND alle Stufen aus', () => assert.deepStrictEqual(lib.translate({ cmd: 'dyn-reset', ...M1 }, sd, targets), ['__multi', [
	['setFairlightAudioMixerSourceDynamicsReset', 1301, '-65280', { dynamics: true, expander: true, compressor: true, limiter: true }],
	['setFairlightAudioMixerSourceProps', 1301, '-65280', { makeUpGain: 0 }],
	['setFairlightAudioMixerSourceExpanderProps', 1301, '-65280', { expanderEnabled: false, gateEnabled: false }],
	['setFairlightAudioMixerSourceCompressorProps', 1301, '-65280', { compressorEnabled: false }],
	['setFairlightAudioMixerSourceLimiterProps', 1301, '-65280', { limiterEnabled: false }]]]))
t('Dynamik-Preset Sprache: Aufholverstaerkung, Kompressor, Limiter', () => {
	const [m, list] = lib.translate({ cmd: 'dyn-preset', ...M1, preset: 'sprache' }, sd, targets)
	assert.strictEqual(m, '__multi'); assert.strictEqual(list.length, 3)
	assert.deepStrictEqual(list[1], ['setFairlightAudioMixerSourceCompressorProps', 1301, '-65280', { compressorEnabled: true, threshold: -1800, ratio: 300, attack: 500, hold: 0, release: 15000 }])
})
t('Master: Kompressor ja, Expander nein', () => {
	assert.deepStrictEqual(lib.translate({ cmd: 'dyn', source: 'master', stage: 'cmp', on: true }, sd, targets), ['setFairlightAudioMixerMasterCompressorProps', { compressorEnabled: true }])
	assert.throws(() => lib.translate({ cmd: 'dyn', source: 'master', stage: 'exp', on: true }, sd, targets), /Dynamik-Stufe/)
})
t('Master folgt Schwarzblende', () => assert.deepStrictEqual(lib.translate({ cmd: 'master-ftb', source: 'master', on: true }, sd, targets), ['setFairlightAudioMixerMasterProps', { followFadeToBlack: true }]))

console.log('4. Aufnahme')
// Zustand wie vom echten ATEM gelesen (13.10.2026): kein Datentraeger, ISO an, Stream on air mit 4,5/6 Mbit/s
const recState = {
	...state,
	streaming: { ...state.streaming, service: { ...state.streaming.service, bitrates: [4500000, 6000000] } },
	recording: { properties: { filename: 'Untitled', workingSet1DiskId: 4294967295, workingSet2DiskId: 4294967295, recordInAllCameras: true }, disks: {},
		status: { state: 0, error: 0, recordingTimeAvailable: 4294967295 }, duration: { hours: 0, minutes: 0, seconds: 0, frames: 0 }, recordAllInputs: true },
}
const sr = lib.summarize(recState, targets, {})
t('ohne Datentraeger: Fehler, ISO an, Qualitaet Mittel', () => {
	assert.deepStrictEqual([sr.rec.on, sr.rec.error, sr.rec.iso, sr.rec.timeLeft, sr.rec.disks.length], [false, 'Kein Datenträger', true, null, 0])
	assert.strictEqual(sr.quality.preset, 'mittel')
})
t('Start ohne Datentraeger abgelehnt', () => assert.throws(() => lib.translate({ cmd: 'rec', on: true }, sr, targets), /Kein Datenträger/))
t('Qualitaet waehrend On Air abgelehnt', () => assert.throws(() => lib.translate({ cmd: 'quality', preset: 'hoch' }, sr, targets), /gestoppt/))
const withDisk = lib.summarize({ ...recState, streaming: { ...recState.streaming, status: { state: 1 } },
	recording: { ...recState.recording, properties: { ...recState.recording.properties, workingSet1DiskId: 7 },
		status: { state: 1, error: 2, recordingTimeAvailable: 7200 }, duration: { hours: 0, minutes: 1, seconds: 2 },
		disks: { 7: { diskId: 7, volumeName: 'SSD', recordingTimeAvailable: 7200, status: 8 } } } }, targets, {})
t('mit Datentraeger: laeuft, Restzeit, aktives Laufwerk', () => {
	assert.deepStrictEqual([withDisk.rec.on, withDisk.rec.error, withDisk.rec.duration, withDisk.rec.timeLeft], [true, '', '00:01:02', 7200])
	assert.deepStrictEqual(withDisk.rec.disks, [{ id: 7, name: 'SSD', status: 'nimmt auf', time: 7200, active: true }])
})
t('Stopp', () => assert.deepStrictEqual(lib.translate({ cmd: 'rec', on: false }, withDisk, targets), ['stopRecording']))
t('Dateiname waehrend Aufnahme abgelehnt', () => assert.throws(() => lib.translate({ cmd: 'rec-name', name: 'x' }, withDisk, targets), /gestoppter/))
t('Dateiname bereinigt', () => assert.deepStrictEqual(lib.translate({ cmd: 'rec-name', name: 'Vortrag 13.10. / Süd' }, sr, targets), ['setRecordingSettings', { filename: 'Vortrag 13.10.  Sued' }]))
t('ISO aus', () => assert.deepStrictEqual(lib.translate({ cmd: 'rec-iso', on: false }, sr, targets), ['setEnableISORecording', false]))
t('Laufwerk wechseln nur mit zwei Laufwerken', () => assert.throws(() => lib.translate({ cmd: 'rec-disk' }, withDisk, targets), /Nur ein Laufwerk/))
t('Qualitaet Hoch wenn alles gestoppt', () => {
	const idle = { ...sr, stream: { ...sr.stream, onAir: false } }
	assert.deepStrictEqual(lib.translate({ cmd: 'quality', preset: 'hoch' }, idle, targets), ['setStreamingService', { bitrates: [6000000, 9000000] }])
})

console.log('5. Zugriff nur aus dem ATEM-Netz')
const allow = lib.makeAllow('192.168.10.0/24,127.0.0.1/32')
t('192.168.10.55 erlaubt', () => assert.ok(allow('192.168.10.55')))
t('IPv4-in-IPv6 erlaubt', () => assert.ok(allow('::ffff:192.168.10.10')))
t('Heimnetz 192.168.178.20 gesperrt', () => assert.ok(!allow('192.168.178.20')))
t('localhost erlaubt', () => assert.ok(allow('127.0.0.1')))
t('Unsinn gesperrt', () => assert.ok(!allow('abc') && !allow(undefined)))
t('kaputtes Netz in der Konfiguration wird gemeldet', () => assert.throws(() => lib.makeAllow('300.1.1.1/24')))

if (fail) { console.log(fail + ' Fehler'); process.exit(1) } else console.log('Alle Tests bestanden')

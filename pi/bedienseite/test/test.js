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

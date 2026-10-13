'use strict'
// Reine Logik der Bedienseite (ohne Netzwerk), damit sie mit nachgebautem ATEM-Zustand testbar ist.
const { getVideoModeInfo } = require('atem-connection/dist/lib/videoMode')

const STREAM_STATUS = { 1: 'aus', 2: 'verbindet', 4: 'on air', 32: 'stoppt' }
const MIX_OPTION = { 1: 'aus', 2: 'ein', 4: 'afv' }
const MIX_OPTION_ID = { aus: 1, ein: 2, afv: 4 }

// Fairlight-Pegel kommen als Hundertstel dB. Darunter gilt als "stumm" (-inf).
const GAIN_MIN = -10000
const GAIN_MAX = 1000

const REC_ERROR = { 2: '', 0: 'Kein Datenträger', 4: 'Datenträger voll', 8: 'Datenträger-Fehler', 16: 'Datenträger nicht formatiert', 32: 'Bilder werden verworfen (Datenträger zu langsam)', 32768: 'Unbekannter Fehler' }
const DISK_STATUS = (s) => (s & 32 ? 'entfernt' : s & 8 ? 'nimmt auf' : s & 2 ? 'nicht formatiert' : s & 4 ? 'aktiv' : 'bereit')
const NO_TIME = 4294967295

// Qualitaet = Encoder-Bitrate (niedrig/hoch) der Stream-Einstellung. Der ATEM Mini Pro nimmt das Programm mit dieser Bitrate auf:
// gemessen 13.10.2026 Mittel 4,5 Mbit/s, Sehr hoch 8,6 Mbit/s. ISO-Spuren haben eine eigene Bitrate (20-30 Mbit/s).
const QUALITY = {
	mittel: { label: 'Mittel (6 Mbit/s)', bitrates: [4500000, 6000000] },
	hoch: { label: 'Hoch (9 Mbit/s)', bitrates: [6000000, 9000000] },
	sehrhoch: { label: 'Sehr hoch (12 Mbit/s)', bitrates: [9000000, 12000000] },
}

// besondere Bildquellen, die neben den Kamera-Eingaengen angeboten werden
const SPECIAL_INPUTS = [
	{ id: 0, short: 'BLK' },
	{ id: 1000, short: 'BARS' },
	{ id: 2001, short: 'COL1' },
	{ id: 2002, short: 'COL2' },
	{ id: 3010, short: 'MP1' },
]

function streamTargets(piIp, laptopIp) {
	return {
		pi: { label: 'Beamer am Pi', serviceName: 'Raspberry Pi Beamer', url: `rtmp://${piIp}/live`, key: 'beamer' },
		laptop: { label: 'Laptop (SRT)', serviceName: 'stream2beamer SRT', url: `srt://${laptopIp}:9000`, key: 'beamer' },
	}
}

// "192.168.10.0/24" -> Pruefer fuer IPv4-Adressen
function parseNet(cidr) {
	const [ip, bits] = cidr.trim().split('/')
	const n = Number(bits === undefined ? 32 : bits)
	const parts = ip.split('.').map(Number)
	if (parts.length !== 4 || parts.some((p) => !Number.isInteger(p) || p < 0 || p > 255) || !(n >= 0 && n <= 32)) {
		throw new Error(`Netz ungueltig: ${cidr}`)
	}
	const mask = n === 0 ? 0 : (~0 << (32 - n)) >>> 0
	const base = (ipToInt(parts) & mask) >>> 0
	return (addr) => {
		const p = String(addr || '').replace(/^::ffff:/, '').split('.').map(Number)
		if (p.length !== 4 || p.some((x) => !Number.isInteger(x) || x < 0 || x > 255)) return false
		return ((ipToInt(p) & mask) >>> 0) === base
	}
}
function ipToInt(p) {
	return ((p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]) >>> 0
}
function makeAllow(list) {
	const nets = list.split(',').filter((s) => s.trim()).map(parseNet)
	return (addr) => nets.some((f) => f(addr))
}

function sourceName(state, inputId) {
	if (inputId === 1301) return 'Mikro 1'
	if (inputId === 1302) return 'Mikro 2'
	const i = state && state.inputs && state.inputs[inputId]
	return (i && (i.longName || i.shortName)) || `Eingang ${inputId}`
}

function fmtDuration(d) {
	if (!d) return ''
	const z = (x) => String(x || 0).padStart(2, '0')
	return `${z(d.hours)}:${z(d.minutes)}:${z(d.seconds)}`
}

// Zustand des ATEM -> kompakte Darstellung fuer die Seite
function summarize(state, targets, extra) {
	const out = { connected: !!state, pi: extra || {} }
	if (!state) return out
	out.model = (state.info && state.info.productIdentifier) || 'ATEM'

	const inputs = []
	for (const i of Object.values(state.inputs || {})) {
		if (i && i.internalPortType === 0) inputs.push({ id: i.inputId, short: i.shortName || String(i.inputId) })
	}
	inputs.sort((a, b) => a.id - b.id)
	for (const s of SPECIAL_INPUTS) if (state.inputs && state.inputs[s.id]) inputs.push(s)
	out.inputs = inputs

	const me = state.video && state.video.mixEffects && state.video.mixEffects[0]
	if (me) {
		out.program = me.programInput
		out.preview = me.previewInput
		out.inTransition = !!(me.transitionPosition && me.transitionPosition.inTransition)
		out.ftb = { black: !!(me.fadeToBlack && me.fadeToBlack.isFullyBlack), running: !!(me.fadeToBlack && me.fadeToBlack.inTransition) }
	}

	const st = state.streaming
	if (st) {
		const code = st.status ? st.status.state : 1
		const svc = st.service || {}
		let target = null
		for (const [k, t] of Object.entries(targets)) if (svc.url === t.url) target = k
		out.stream = { state: STREAM_STATUS[code] || String(code), onAir: code === 4 || code === 2, service: svc.serviceName || '', url: svc.url || '', target, duration: fmtDuration(st.duration) }
	}

	const fl = state.fairlight
	if (fl) {
		const audio = []
		for (const [idx, inp] of Object.entries(fl.inputs || {})) {
			if (!inp || !inp.sources) continue
			for (const [src, s] of Object.entries(inp.sources)) {
				if (!s || !s.properties) continue
				const p = s.properties
				audio.push({
					input: Number(idx), source: src, name: sourceName(state, Number(idx)),
					gain: p.faderGain, mix: MIX_OPTION[p.mixOption] || String(p.mixOption),
					options: (p.supportedMixOptions || []).map((o) => MIX_OPTION[o]).filter(Boolean),
				})
			}
		}
		audio.sort((a, b) => a.input - b.input)
		out.audio = audio
		out.master = fl.master && fl.master.properties ? { gain: fl.master.properties.faderGain } : null
	}

	const md = state.media
	if (md) {
		const p = md.players && md.players[0]
		out.media = {
			stills: (md.stillPool || []).map((s, i) => ({ index: i, used: !!(s && s.isUsed), name: s && s.isUsed ? s.fileName || `Bild ${i + 1}` : '' })),
			player: p ? { type: p.sourceType === 2 ? 'clip' : 'still', still: p.stillIndex, clip: p.clipIndex } : null,
		}
	}
	const rc = state.recording
	if (rc) {
		const code = rc.status ? rc.status.state : 0
		const err = rc.status ? rc.status.error : 2
		const props = rc.properties || {}
		const disks = Object.values(rc.disks || {}).filter(Boolean).map((d) => ({
			id: d.diskId, name: d.volumeName || `Laufwerk ${d.diskId}`, status: DISK_STATUS(d.status),
			time: d.recordingTimeAvailable === NO_TIME ? null : d.recordingTimeAvailable, active: d.diskId === props.workingSet1DiskId,
		}))
		const avail = rc.status ? rc.status.recordingTimeAvailable : NO_TIME
		out.rec = {
			state: code === 1 ? 'läuft' : code === 128 ? 'stoppt' : 'aus', on: code === 1 || code === 128,
			error: REC_ERROR[err] !== undefined ? REC_ERROR[err] : `Fehler ${err}`,
			filename: props.filename || '', iso: !!(rc.recordAllInputs !== undefined ? rc.recordAllInputs : props.recordInAllCameras),
			duration: fmtDuration(rc.duration), timeLeft: avail === NO_TIME ? null : avail, disks,
			canSwitch: disks.length > 1,
		}
	}
	const sv = state.streaming && state.streaming.service
	if (sv && sv.bitrates) {
		let preset = null
		for (const [k, q] of Object.entries(QUALITY)) if (q.bitrates[0] === sv.bitrates[0] && q.bitrates[1] === sv.bitrates[1]) preset = k
		out.quality = { bitrates: sv.bitrates, preset }
	}

	const vm = state.settings && getVideoModeInfo(state.settings.videoMode)
	if (vm) out.resolution = { width: vm.width, height: vm.height }
	return out
}

// Upload eines Standbilds pruefen: der Browser schickt fertige YUV-4:2:2-Daten (4 Byte je Pixel) in genau der Aufloesung des ATEM
function checkUpload(params, length, summary) {
	const r = summary.resolution
	if (!r) throw new Error('Aufloesung des ATEM unbekannt')
	if (length !== r.width * r.height * 4) throw new Error(`Bilddaten muessen ${r.width}x${r.height} YUV 4:2:2 sein`)
	const n = summary.media ? summary.media.stills.length : 0
	const index = Number(params.get('index'))
	if (!Number.isInteger(index) || index < 0 || index >= n) throw new Error('Ungueltiger Speicherplatz')
	const umlaut = { ä: 'ae', ö: 'oe', ü: 'ue', Ä: 'Ae', Ö: 'Oe', Ü: 'Ue', ß: 'ss' }
	const name = String(params.get('name') || '').replace(/[äöüÄÖÜß]/g, (c) => umlaut[c])
		.replace(/[^\x20-\x7E]/g, '').trim().slice(0, 63) || `Bild ${index + 1}`
	return { index, name }
}

// Befehl der Seite pruefen und in Bibliotheksaufruf uebersetzen: [methode, ...argumente]
function translate(cmd, summary, targets) {
	const num = (v, lo, hi) => {
		const n = Number(v)
		if (!Number.isFinite(n) || n < lo || n > hi) throw new Error('Wert ausserhalb des Bereichs')
		return Math.round(n)
	}
	const knownInput = (id) => {
		const n = num(id, 0, 65535)
		if (!(summary.inputs || []).some((i) => i.id === n)) throw new Error(`Unbekannte Quelle ${n}`)
		return n
	}
	switch (cmd && cmd.cmd) {
		case 'program': return ['changeProgramInput', knownInput(cmd.input)]
		case 'preview': return ['changePreviewInput', knownInput(cmd.input)]
		case 'cut': return ['cut']
		case 'auto': return ['autoTransition']
		case 'ftb': return ['fadeToBlack']
		case 'stream': return [cmd.on ? 'startStreaming' : 'stopStreaming']
		case 'target': {
			const t = targets[cmd.name]
			if (!t) throw new Error('Unbekanntes Ziel')
			if (summary.stream && summary.stream.onAir) throw new Error('Erst den Stream stoppen, dann das Ziel wechseln')
			return ['setStreamingService', { serviceName: t.serviceName, url: t.url, key: t.key }]
		}
		case 'fader': {
			const a = (summary.audio || []).find((x) => x.input === Number(cmd.input) && x.source === String(cmd.source))
			if (!a) throw new Error('Unbekannte Tonquelle')
			return ['setFairlightAudioMixerSourceProps', a.input, a.source, { faderGain: num(cmd.gain, GAIN_MIN, GAIN_MAX) }]
		}
		case 'mix': {
			const a = (summary.audio || []).find((x) => x.input === Number(cmd.input) && x.source === String(cmd.source))
			if (!a) throw new Error('Unbekannte Tonquelle')
			if (!a.options.includes(cmd.option)) throw new Error('Option fuer diese Quelle nicht moeglich')
			return ['setFairlightAudioMixerSourceProps', a.input, a.source, { mixOption: MIX_OPTION_ID[cmd.option] }]
		}
		case 'master': return ['setFairlightAudioMixerMasterProps', { faderGain: num(cmd.gain, GAIN_MIN, GAIN_MAX) }]
		case 'rec': {
			if (!summary.rec) throw new Error('Aufnahme wird von diesem ATEM nicht gemeldet')
			if (cmd.on && summary.rec.error) throw new Error(`Aufnahme nicht möglich: ${summary.rec.error}`)
			return [cmd.on ? 'startRecording' : 'stopRecording']
		}
		case 'rec-name': {
			if (summary.rec && summary.rec.on) throw new Error('Dateiname nur bei gestoppter Aufnahme ändern')
			const umlaut = { ä: 'ae', ö: 'oe', ü: 'ue', Ä: 'Ae', Ö: 'Oe', Ü: 'Ue', ß: 'ss' }
			const name = String(cmd.name || '').replace(/[äöüÄÖÜß]/g, (c) => umlaut[c]).replace(/[^A-Za-z0-9 _.-]/g, '').trim().slice(0, 63)
			if (!name) throw new Error('Dateiname leer')
			return ['setRecordingSettings', { filename: name }]
		}
		case 'rec-iso': {
			if (summary.rec && summary.rec.on) throw new Error('ISO nur bei gestoppter Aufnahme umschalten')
			return ['setEnableISORecording', !!cmd.on]
		}
		case 'rec-disk': {
			if (!summary.rec || !summary.rec.canSwitch) throw new Error('Nur ein Laufwerk vorhanden')
			return ['switchRecordingDisk']
		}
		case 'quality': {
			const q = QUALITY[cmd.preset]
			if (!q) throw new Error('Unbekannte Qualität')
			if ((summary.rec && summary.rec.on) || (summary.stream && summary.stream.onAir)) throw new Error('Qualität nur ändern, wenn Aufnahme und Stream gestoppt sind')
			return ['setStreamingService', { bitrates: q.bitrates }]
		}
		case 'mp-still': {
			const s = summary.media && summary.media.stills[Number(cmd.index)]
			if (!s || !s.used) throw new Error('Kein Bild auf diesem Speicherplatz')
			return ['setMediaPlayerSource', { sourceType: 1, stillIndex: s.index }, 0]
		}
		case 'still-clear': {
			const s = summary.media && summary.media.stills[Number(cmd.index)]
			if (!s || !s.used) throw new Error('Kein Bild auf diesem Speicherplatz')
			return ['clearMediaPoolStill', s.index]
		}
		default: throw new Error('Unbekannter Befehl')
	}
}

module.exports = { summarize, translate, checkUpload, makeAllow, streamTargets, QUALITY, GAIN_MIN, GAIN_MAX }

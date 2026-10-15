'use strict'
// Reine Logik der Bedienseite (ohne Netzwerk), damit sie mit nachgebautem ATEM-Zustand testbar ist.
const { getVideoModeInfo } = require('atem-connection/dist/lib/videoMode')

const STREAM_STATUS = { 1: 'aus', 2: 'verbindet', 4: 'on air', 32: 'stoppt' }
const MIX_OPTION = { 1: 'aus', 2: 'ein', 4: 'afv' }
const MIX_OPTION_ID = { aus: 1, ein: 2, afv: 4 }

// Equalizer (Fairlight, 6 Baender). Werte vom ATEM Mini Pro ISO gelesen am 15.10.2026:
// Frequenz in Hz, Verstaerkung in Hundertstel dB, Guete mal 100. Band 1 = Tiefensperre, Band 6 = Hoehensperre.
const EQ_SHAPE = { 1: 'Tiefen-Kuhschwanz', 2: 'Tiefpass', 4: 'Glocke', 8: 'Kerbe', 16: 'Hochpass', 32: 'Höhen-Kuhschwanz' }
const EQ_GAIN = 2000          // +-20 dB
const EQ_Q = [30, 1030]       // 0,3 .. 10,3
// Frequenzbereiche am ATEM gemessen (15.10.2026, Camera 3): der ATEM begrenzt die Frequenz auf den eingestellten Bereich.
const EQ_RANGE_HZ = { 1: [30, 395], 2: [100, 1480], 4: [450, 7910], 8: [1400, 21700] }
// Bereich fuer eine Frequenz: den aktuellen behalten, solange die Frequenz hineinpasst (sonst verstellt ein Zuruecksetzen
// heimlich den Bereich, gefunden 15.10.2026), sonst den ersten passenden in der Reihenfolge Low, MidLow, MidHigh, High.
function eqRangeFor(freq, supported, current) {
	const fits = (r) => EQ_RANGE_HZ[r] && freq >= EQ_RANGE_HZ[r][0] && freq <= EQ_RANGE_HZ[r][1]
	if (supported.includes(current) && fits(current)) return current
	return supported.find(fits) || current || supported[0]
}
function eqSummary(eq) {
	if (!eq) return null
	return {
		enabled: !!eq.enabled, gain: eq.gain,
		bands: (eq.bands || []).map((b, i) => b && {
			band: i, on: !!b.bandEnabled, shape: b.shape, shapes: (b.supportedShapes || []).map((s) => ({ id: s, name: EQ_SHAPE[s] || String(s) })),
			ranges: b.supportedFrequencyRanges || [], range: b.frequencyRange, freq: b.frequency, gain: b.gain, q: b.qFactor,
		}).filter(Boolean),
	}
}

// EQ-Presets: [an, Form, Frequenz Hz, Pegel in 1/100 dB, Guete x100] fuer Band 1..6.
// Startwerte nach gaengigen Empfehlungen fuer Sprache (Hochpass 80-120 Hz, Absenkung 200-300 Hz gegen Dumpfheit,
// 700-800 Hz gegen naeselnden Klang, +2..3 dB bei 3-5 kHz fuer Verstaendlichkeit, leichte Hoehen ab ~10 kHz), u. a.
// cleanvoice.ai/blog/audio-equalization, evezone.evetech.co.za (EQ fuer Sprechstimme), podcastengineeringschool.com (Lavalier).
// Immer nach Gehoer nachregeln. Formen: 1 Tiefen-Kuhschwanz, 2 Tiefpass, 4 Glocke, 8 Kerbe, 16 Hochpass, 32 Hoehen-Kuhschwanz.
const EQ_PRESETS = {
	sprache: { label: 'Sprache (Hand-/Pultmikro)', bands: [[true, 16, 100, 0, 71], [true, 4, 250, -300, 140], [false, 4, 800, 0, 140], [true, 4, 3500, 300, 100], [true, 32, 10000, 150, 80], [false, 2, 16000, 0, 71]] },
	lavalier: { label: 'Ansteckmikro (Lavalier)', bands: [[true, 16, 100, 0, 71], [true, 4, 300, -300, 150], [true, 4, 750, -150, 150], [true, 4, 4000, 300, 90], [true, 32, 10000, 200, 80], [false, 2, 16000, 0, 71]] },
	tief: { label: 'Sprache, tiefe/dröhnende Stimme', bands: [[true, 16, 120, 0, 71], [true, 4, 200, -400, 120], [true, 4, 500, -150, 140], [true, 4, 3000, 250, 100], [true, 32, 9000, 100, 80], [false, 2, 16000, 0, 71]] },
	atmo: { label: 'Kamera-Mikro / Raumton', bands: [[true, 16, 150, 0, 71], [true, 4, 300, -200, 140], [false, 4, 1000, 0, 140], [false, 4, 4000, 0, 140], [false, 32, 10000, 0, 80], [true, 2, 12000, 0, 71]] },
	musik: { label: 'Musik / Einspieler', bands: [[true, 16, 30, 0, 71], [false, 1, 80, 0, 80], [false, 4, 500, 0, 140], [false, 4, 3000, 0, 140], [true, 32, 12000, 100, 80], [false, 2, 18000, 0, 71]] },
	brumm: { label: 'Brummen (50 Hz) entfernen', bands: [[true, 16, 60, 0, 71], [true, 8, 50, 0, 800], [true, 8, 100, 0, 800], [true, 8, 150, 0, 800], [false, 32, 10000, 0, 80], [false, 2, 16000, 0, 71]] },
}

// Dynamik und Eingang: Grenzen am ATEM gemessen (15.10.2026, Camera 3). Zeiten in 1/100 ms, Pegel in 1/100 dB, Verhaeltnis x100.
const DYN_LIMITS = {
	exp: { threshold: [-5000, 0], range: [0, 6000], ratio: [110, 300], attack: [50, 10000], hold: [0, 32767], release: [5000, 32767] },
	cmp: { threshold: [-5000, 0], ratio: [120, 2000], attack: [70, 10000], hold: [0, 32767], release: [5000, 32767] },
	lim: { threshold: [-3000, 0], attack: [70, 3000], hold: [0, 32767], release: [5000, 32767] },
}
const DYN_ON = { exp: 'expanderEnabled', cmp: 'compressorEnabled', lim: 'limiterEnabled' }
const DYN_FN = { exp: 'Expander', cmp: 'Compressor', lim: 'Limiter' }
const DYN_STATE = { exp: 'expander', cmp: 'compressor', lim: 'limiter' }
// Dynamik-Preset Sprache: Kompressor 3:1 ab -18 dB, Limiter bei -3 dB als Schutz, +3 dB Aufholverstaerkung
const DYN_PRESETS = {
	sprache: { label: 'Sprache (Kompressor + Limiter)', makeUp: 300,
		cmp: { on: true, threshold: -1800, ratio: 300, attack: 500, hold: 0, release: 15000 },
		lim: { on: true, threshold: -300, attack: 70, hold: 0, release: 5000 } },
}
function dynSummary(d) {
	if (!d) return null
	const pick = (s, on, extra) => s && { on: !!s[on], threshold: s.threshold, ratio: s.ratio, range: s.range, attack: s.attack, hold: s.hold, release: s.release, ...extra }
	return {
		makeUp: d.makeUpGain,
		exp: pick(d.expander, 'expanderEnabled', d.expander ? { gate: !!d.expander.gateEnabled } : {}),
		cmp: pick(d.compressor, 'compressorEnabled'),
		lim: pick(d.limiter, 'limiterEnabled'),
	}
}

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
					eq: eqSummary(s.equalizer),
					strip: {
						inGain: p.gain, balance: p.balance, delay: p.framesDelay || 0, maxDelay: p.maxFramesDelay || 0,
						level: inp.properties ? inp.properties.activeInputLevel : 0,
						levels: (inp.properties && inp.properties.supportedInputLevels) || [],
					},
					dyn: dynSummary(s.dynamics),
				})
			}
		}
		audio.sort((a, b) => a.input - b.input)
		out.audio = audio
		out.master = fl.master && fl.master.properties ? {
			gain: fl.master.properties.faderGain, eq: eqSummary(fl.master.equalizer), dyn: dynSummary(fl.master.dynamics),
			ftbFollow: !!fl.master.properties.followFadeToBlack,
		} : null
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
		case 'eq': case 'eq-band': case 'eq-reset': case 'eq-preset':
		case 'strip': case 'input-level': case 'dyn': case 'dyn-reset': case 'dyn-preset': case 'master-ftb': {
			// Ziel: Quelle (input + source) oder Master (source === 'master')
			const isMaster = cmd.source === 'master'
			const a = isMaster ? summary.master : (summary.audio || []).find((x) => x.input === Number(cmd.input) && x.source === String(cmd.source))
			if (!a) throw new Error('Unbekannte Tonquelle')
			// Aufruf an Quelle oder Master: src('Name', ...) -> setFairlightAudioMixerSource<Name>(input, source, ...)
			const call = (name, ...args) => (isMaster ? [`setFairlightAudioMixerMaster${name}`, ...args] : [`setFairlightAudioMixerSource${name}`, a.input, a.source, ...args])
			const ensure = (o) => { if (!Object.keys(o).length) throw new Error('Nichts zu ändern'); return o }

			if (cmd.cmd === 'master-ftb') {
				if (!isMaster) throw new Error('Nur für den Master')
				return ['setFairlightAudioMixerMasterProps', { followFadeToBlack: !!cmd.on }]
			}
			if (cmd.cmd === 'strip') {
				const props = {}
				if (cmd.makeUp !== undefined) props.makeUpGain = num(cmd.makeUp, 0, 2000)
				if (!isMaster) {
					if (cmd.inGain !== undefined) props.gain = num(cmd.inGain, -10000, 600)
					if (cmd.balance !== undefined) props.balance = num(cmd.balance, -10000, 10000)
					if (cmd.delay !== undefined) props.framesDelay = num(cmd.delay, 0, a.strip.maxDelay)
				}
				return call('Props', ensure(props))
			}
			if (cmd.cmd === 'input-level') {
				if (isMaster || !a.strip.levels.includes(Number(cmd.level))) throw new Error('Eingangspegel für diese Quelle nicht möglich')
				return ['setFairlightAudioMixerInputProps', a.input, { activeInputLevel: Number(cmd.level) }]
			}
			if (cmd.cmd === 'dyn' || cmd.cmd === 'dyn-reset' || cmd.cmd === 'dyn-preset') {
				if (!a.dyn) throw new Error('Keine Dynamik für diese Quelle')
				// Der Reset-Befehl des ATEM setzt nur die Werte zurueck, schaltet die Stufen aber nicht aus (getestet 15.10.2026)
				if (cmd.cmd === 'dyn-reset') {
					const list = [call('DynamicsReset', { dynamics: true, expander: !isMaster, compressor: true, limiter: true }), call('Props', { makeUpGain: 0 })]
					for (const st of isMaster ? ['cmp', 'lim'] : ['exp', 'cmp', 'lim']) {
						list.push(call(DYN_FN[st] + 'Props', st === 'exp' ? { expanderEnabled: false, gateEnabled: false } : { [DYN_ON[st]]: false }))
					}
					return ['__multi', list]
				}
				if (cmd.cmd === 'dyn-preset') {
					const p = DYN_PRESETS[cmd.preset]
					if (!p) throw new Error('Unbekanntes Preset')
					const list = [call('Props', { makeUpGain: p.makeUp })]
					for (const st of ['cmp', 'lim']) {
						const { on, ...rest } = p[st]
						list.push(call(DYN_FN[st] + 'Props', { [DYN_ON[st]]: on, ...rest }))
					}
					return ['__multi', list]
				}
				const st = cmd.stage
				if (!DYN_LIMITS[st] || !a.dyn[st]) throw new Error('Unbekannte Dynamik-Stufe')
				const props = {}
				if (cmd.on !== undefined) props[DYN_ON[st]] = !!cmd.on
				if (st === 'exp' && cmd.gate !== undefined) props.gateEnabled = !!cmd.gate
				for (const [k, [lo, hi]] of Object.entries(DYN_LIMITS[st])) if (cmd[k] !== undefined) props[k] = num(cmd[k], lo, hi)
				return call(DYN_FN[st] + 'Props', ensure(props))
			}

			// Equalizer
			if (!a.eq) throw new Error('Kein Equalizer für diese Quelle')
			if (cmd.cmd === 'eq-reset') return call('EqualizerReset', { equalizer: true })
			if (cmd.cmd === 'eq') {
				const props = {}
				if (cmd.enabled !== undefined) props.equalizerEnabled = !!cmd.enabled
				if (cmd.gain !== undefined) props.equalizerGain = num(cmd.gain, -EQ_GAIN, EQ_GAIN)
				return call('Props', ensure(props))
			}
			const bandProps = (b, c) => {
				const props = {}
				if (c.on !== undefined) props.bandEnabled = !!c.on
				if (c.shape !== undefined) {
					if (!b.shapes.some((s) => s.id === Number(c.shape))) throw new Error('Filterform für dieses Band nicht möglich')
					props.shape = Number(c.shape)
				}
				if (c.freq !== undefined) {
					const range = eqRangeFor(Number(c.freq), b.ranges, b.range)
					const [lo, hi] = EQ_RANGE_HZ[range] || [20, 21700]
					props.frequency = Math.min(hi, Math.max(lo, num(c.freq, 20, 21700)))
					if (b.ranges.length > 1 && range !== b.range) props.frequencyRange = range
				}
				if (c.gain !== undefined) props.gain = num(c.gain, -EQ_GAIN, EQ_GAIN)
				if (c.q !== undefined) props.qFactor = num(c.q, EQ_Q[0], EQ_Q[1])
				return props
			}
			if (cmd.cmd === 'eq-preset') {
				const p = EQ_PRESETS[cmd.preset]
				if (!p) throw new Error('Unbekanntes Preset')
				const list = [call('Props', { equalizerEnabled: true, equalizerGain: 0 })]
				p.bands.forEach(([on, shape, freq, gain, q], i) => {
					const b = a.eq.bands.find((x) => x.band === i)
					if (!b) return
					const c = { on, freq, gain, q }
					if (b.shapes.some((s) => s.id === shape)) c.shape = shape
					list.push(call('EqualizerBandProps', i, bandProps(b, c)))
				})
				return ['__multi', list]
			}
			const b = a.eq.bands.find((x) => x.band === Number(cmd.band))
			if (!b) throw new Error('Unbekanntes Band')
			return call('EqualizerBandProps', b.band, ensure(bandProps(b, cmd)))
		}
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

const PRESET_LABELS = {
	eq: Object.fromEntries(Object.entries(EQ_PRESETS).map(([k, p]) => [k, p.label])),
	dyn: Object.fromEntries(Object.entries(DYN_PRESETS).map(([k, p]) => [k, p.label])),
}

module.exports = { summarize, translate, checkUpload, makeAllow, streamTargets, QUALITY, PRESET_LABELS, GAIN_MIN, GAIN_MAX }

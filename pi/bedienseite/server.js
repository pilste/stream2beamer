'use strict'
/*
  Bedienseite fuer den ATEM Mini Pro, laeuft auf dem Raspberry Pi.
  Browser (Handy, Tablet, Laptop) -> http://192.168.10.20 -> dieser Server -> ATEM (Steuerprotokoll, UDP 9910)
  Einstellungen per Umgebungsvariable (siehe stream2beamer-bedienseite.service):
    ATEM_IP=192.168.10.240  PORT=80  PI_IP=192.168.10.20  LAPTOP_IP=192.168.10.10
    ALLOW_NETS=192.168.10.0/24,127.0.0.1/32   nur diese Netze duerfen die Seite benutzen (kein Passwort)
*/
const http = require('http')
const fs = require('fs')
const path = require('path')
const { execFile } = require('child_process')
const { Atem } = require('atem-connection')
const lib = require('./lib')

const ATEM_IP = process.env.ATEM_IP || '192.168.10.240'
const PORT = Number(process.env.PORT || 80)
const TARGETS = lib.streamTargets(process.env.PI_IP || '192.168.10.20', process.env.LAPTOP_IP || '192.168.10.10')
const allowed = lib.makeAllow(process.env.ALLOW_NETS || '192.168.10.0/24,127.0.0.1/32')
const PORTAL_URL = process.env.PORTAL_URL || 'http://beamer.lan/'
const OWN_HOSTS = new Set(['beamer.lan', 'beamer.local', 'beamer', process.env.PI_IP || '192.168.10.20', '127.0.0.1', 'localhost'])
const PAGE = fs.readFileSync(path.join(__dirname, 'public', 'index.html'))
const YUV_JS = fs.readFileSync(path.join(__dirname, 'public', 'yuv.js'))
// Standbild-Upload: auf dem Pi 1 (ARMv6) abgeschaltet. Dort trennte der ATEM jeden Upload nach 9-41 s, auch allein und mit nice -15,
// weil atem-connection die Ereignisschleife bis zu 2 s blockiert (gemessen 13.10.2026). ALLOW_UPLOAD=1/0 erzwingt es.
let cpuinfo = ''
try { cpuinfo = fs.readFileSync('/proc/cpuinfo', 'utf8') } catch (e) {}
const UPLOAD = process.env.ALLOW_UPLOAD ? process.env.ALLOW_UPLOAD === '1' : !/ARMv6/.test(cpuinfo)

// ein Thread: mit eigenem Thread erklaerte threadedclass den Kindprozess auf dem Pi 1 nach 7 s fuer tot (13.10.2026)
const atem = new Atem({ disableMultithreaded: true })
let connected = false
let piStatus = { receiving: false, player: false }
const clients = new Set()

// ---------- ATEM ----------
atem.on('connected', () => { connected = true; console.log(`ATEM verbunden (${ATEM_IP})`); push() })
atem.on('disconnected', () => { connected = false; console.log('ATEM getrennt, verbinde neu ...'); push() })
atem.on('stateChanged', () => push())
atem.on('error', (e) => console.log('ATEM-Fehler:', e && e.message ? e.message : e))
atem.connect(ATEM_IP).catch((e) => console.log('Verbindungsaufbau fehlgeschlagen:', e.message))

// Laufzeit des Streams aktualisieren (der ATEM schickt sie nur auf Anfrage)
setInterval(() => {
	if (connected && atem.state && atem.state.streaming && atem.state.streaming.status && atem.state.streaming.status.state === 4) {
		atem.requestStreamingDuration().catch(() => {})
	}
	if (connected && atem.state && atem.state.recording && atem.state.recording.status && atem.state.recording.status.state === 1) {
		atem.requestRecordingDuration().catch(() => {})
	}
}, 2000)

// ---------- Zustand des Pi-Players (empfaengt nginx gerade einen Stream vom ATEM?) ----------
function checkPi() {
	execFile('ss', ['-tn', 'state', 'established', 'sport', '=', ':1935'], (err, out) => {
		const receiving = !err && out.includes(`${ATEM_IP}:`)
		execFile('pgrep', ['-x', 'omxplayer.bin'], (err2) => {
			const next = { receiving, player: !err2 }
			if (next.receiving !== piStatus.receiving || next.player !== piStatus.player) { piStatus = next; push() }
		})
	})
}
setInterval(checkPi, 3000)
checkPi()

// ---------- Verlauf der Aufnahme (alle 10 s, bleibt nach dem Stopp bis zur naechsten Aufnahme erhalten) ----------
const recHistory = { startedAt: null, points: [], errors: [] }
let recRunning = false
setInterval(() => {
	const r = summary().rec
	if (!r) return
	const now = Date.now()
	if (r.on && !recRunning) {
		// Start aus der Laufzeit des ATEM zurueckrechnen (stimmt auch, wenn die Seite waehrend einer Aufnahme neu startet)
		const [h, m, s] = String(r.duration || '0:0:0').split(':').map(Number)
		recHistory.startedAt = now - ((h || 0) * 3600 + (m || 0) * 60 + (s || 0)) * 1000
		recHistory.points = []; recHistory.errors = []
	}
	recRunning = r.on
	if (!r.on) return
	recHistory.points.push({ t: now, dur: r.duration, left: r.timeLeft, err: r.error || '' })
	if (recHistory.points.length > 2000) recHistory.points.shift()
	const lastErr = recHistory.errors[recHistory.errors.length - 1]
	if (r.error && (!lastErr || lastErr.err !== r.error || now - lastErr.t > 60000)) recHistory.errors.push({ t: now, err: r.error })
}, 10000)
function summary() {
	const s = lib.summarize(connected ? atem.state : null, TARGETS, piStatus)
	s.uploadEnabled = UPLOAD
	return s
}

// ---------- an alle offenen Seiten senden (hoechstens alle 200 ms) ----------
let pushTimer = null
function push() {
	if (pushTimer) return
	pushTimer = setTimeout(() => {
		pushTimer = null
		const data = `data: ${JSON.stringify(summary())}\n\n`
		for (const res of clients) res.write(data)
	}, 200)
}
setInterval(() => { for (const res of clients) res.write(': ping\n\n') }, 20000)

// ---------- HTTP ----------
function send(res, code, body, type) {
	res.writeHead(code, { 'Content-Type': type || 'application/json; charset=utf-8', 'Cache-Control': 'no-store' })
	res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body))
}

const server = http.createServer((req, res) => {
	if (!allowed(req.socket.remoteAddress)) return send(res, 403, 'Nur aus dem ATEM-Netz erreichbar.\n', 'text/plain; charset=utf-8')

	// Captive Portal: dnsmasq schickt die Internet-Pruefadressen der Geraete (generate_204, hotspot-detect, connecttest ...)
	// hierher. Jede Anfrage an einen fremden Namen wird auf die Bedienseite umgeleitet, das Geraet meldet dann
	// "Im Netzwerk anmelden" und oeffnet die Seite (iPhone meist von selbst, Android per Mitteilung).
	const host = String(req.headers.host || '').replace(/:\d+$/, '').toLowerCase()
	if (host && !OWN_HOSTS.has(host)) {
		res.writeHead(302, { Location: PORTAL_URL, 'Cache-Control': 'no-store' })
		return res.end()
	}

	if (req.method === 'GET' && (req.url === '/' || req.url === '/index.html')) return send(res, 200, PAGE, 'text/html; charset=utf-8')
	if (req.method === 'GET' && req.url === '/yuv.js') return send(res, 200, YUV_JS, 'text/javascript; charset=utf-8')
	// now: Uhr des Pi mitschicken. Der Pi 1 hat keine Echtzeituhr und am Switch kein NTP, die Seite rechnet auf die Geraeteuhr um.
	if (req.method === 'GET' && req.url === '/api/rec-history') return send(res, 200, { ...recHistory, now: Date.now() })
	if (req.method === 'GET' && req.url === '/api/state') return send(res, 200, { ...summary(), targets: TARGETS, qualities: lib.QUALITY })
	if (req.method === 'GET' && req.url === '/api/events') {
		res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', Connection: 'keep-alive' })
		res.write(`data: ${JSON.stringify(summary())}\n\n`)
		clients.add(res)
		req.on('close', () => clients.delete(res))
		return
	}
	if (req.method === 'POST' && req.url === '/api/action') {
		let body = ''
		req.on('data', (c) => { body += c; if (body.length > 2000) req.destroy() })
		req.on('end', async () => {
			try {
				const cmd = JSON.parse(body || '{}')
				// Pi herunterfahren: der Dienst laeuft ohne Root (NoNewPrivileges), deshalb nur eine Markierungsdatei anlegen.
				// stream2beamer-poweroff.path (root) wartet darauf und ruft systemctl poweroff auf.
				if (cmd.cmd === 'poweroff') {
					fs.writeFileSync(path.join(process.env.RUNTIME_DIRECTORY || '/run/stream2beamer-bedienseite', 'poweroff'), String(Date.now()))
					console.log('Herunterfahren ueber die Bedienseite angefordert')
					return send(res, 200, { ok: true })
				}
				if (!connected) throw new Error('ATEM nicht verbunden')
				const [method, ...args] = lib.translate(cmd, summary(), TARGETS)
				await atem[method](...args)
				send(res, 200, { ok: true })
			} catch (e) {
				send(res, 400, { ok: false, error: e.message })
			}
		})
		return
	}
	if (req.method === 'POST' && req.url.startsWith('/api/still?')) return uploadStill(req, res)
	send(res, 404, { ok: false, error: 'nicht gefunden' })
})

// Standbild hochladen: fertige YUV-4:2:2-Daten in ATEM-Aufloesung. Skalieren und Farbumrechnung macht der Browser (public/yuv.js),
// weil die Umrechnung in JS den Pi 1 ~39 s blockierte und der ATEM die Verbindung trennte (13.10.2026).
let uploading = false
function uploadStill(req, res) {
	let info
	try {
		if (!UPLOAD) throw new Error('Hochladen ist auf diesem Pi abgeschaltet (zu schwach). Bitte ATEM Software Control nehmen.')
		if (!connected) throw new Error('ATEM nicht verbunden')
		if (uploading) throw new Error('Es laeuft schon ein Upload')
		const s = summary()
		const r = s.resolution
		const expected = r ? r.width * r.height * 4 : 0
		info = { s, expected, params: new URL(req.url, 'http://x').searchParams }
		if (Number(req.headers['content-length']) !== expected) throw new Error(`Bilddaten muessen ${r ? r.width + 'x' + r.height : '?'} YUV 4:2:2 sein`)
	} catch (e) {
		req.resume()
		return send(res, 400, { ok: false, error: e.message })
	}
	uploading = true
	const buf = Buffer.alloc(info.expected)
	let pos = 0
	req.on('data', (c) => {
		if (pos + c.length > info.expected) { req.destroy(); return }
		c.copy(buf, pos); pos += c.length
	})
	req.on('end', async () => {
		try {
			const { index, name } = lib.checkUpload(info.params, pos, info.s)
			console.log(`Standbild ${index + 1} "${name}" wird hochgeladen ...`)
			const t0 = Date.now()
			await atem.uploadStill(index, { encodedData: buf, rawDataLength: buf.length, isRleEncoded: false }, name, '', { disableRLE: true })
			console.log(`Standbild ${index + 1} fertig nach ${((Date.now() - t0) / 1000).toFixed(1)} s`)
			send(res, 200, { ok: true, index, name })
		} catch (e) {
			send(res, 400, { ok: false, error: e.message })
		} finally {
			uploading = false
		}
	})
	req.on('close', () => { if (pos < info.expected) uploading = false })
}
// nur IPv4: die Zugriffsregel (ALLOW_NETS) kennt nur IPv4-Netze. Ueber IPv6 kam sonst 403 (beamer.local lieferte auch IPv6).
server.listen(PORT, '0.0.0.0', () => console.log(`Bedienseite auf Port ${PORT}, ATEM ${ATEM_IP}`))

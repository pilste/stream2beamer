// RGBA -> YUV 4:2:2 10 Bit (Format der ATEM-Standbilder). Nachbau von convertRGBAToYUV422 aus atem-connection 3.10,
// damit der Browser umrechnet und nicht der Pi 1 (dort dauerte es ~39 s, der ATEM trennte die Verbindung, 13.10.2026).
// Laeuft im Browser (window.rgbaToYuv422) und in Node (Test: muss byte-gleich mit der Bibliothek sein).
;(function (root) {
	'use strict'
	function constants(KR, KB) {
		const KG = 1 - KR - KB, KRi = 1 - KR, KBi = 1 - KB, YRange = 219, Half = 224 / 2
		return { KR, KB, KG, YRange, Half, YOffset: 16 << 8, CbCrOffset: 128 << 8,
			KRoKBi: (KR / KBi) * Half, KGoKBi: (KG / KBi) * Half, KBoKRi: (KB / KRi) * Half, KGoKRi: (KG / KRi) * Half }
	}
	const BT709 = constants(0.2126, 0.0722)
	const BT601 = constants(0.299, 0.114)

	function rgbaToYuv422(width, height, data) {
		const c = height >= 720 ? BT709 : BT601
		const gen = (rawA, uv16, y16) => {
			const a = ((rawA << 2) * 219) / 255 + (16 << 2)
			const y = Math.round(y16) >> 6
			const uv = Math.round(uv16) >> 6
			return (a << 20) + (uv << 10) + y
		}
		const out = new Uint8Array(width * height * 4)
		const view = new DataView(out.buffer)
		for (let i = 0; i < width * height * 4; i += 8) {
			const r1 = data[i], g1 = data[i + 1], b1 = data[i + 2], a1 = data[i + 3]
			const r2 = data[i + 4], g2 = data[i + 5], b2 = data[i + 6], a2 = data[i + 7]
			const y16a = c.YOffset + c.KR * c.YRange * r1 + c.KG * c.YRange * g1 + c.KB * c.YRange * b1
			const cb16 = c.CbCrOffset + (-c.KRoKBi * r1 - c.KGoKBi * g1 + c.Half * b1)
			const y16b = c.YOffset + c.KR * c.YRange * r2 + c.KG * c.YRange * g2 + c.KB * c.YRange * b2
			const cr16 = c.CbCrOffset + (c.Half * r1 - c.KGoKRi * g1 - c.KBoKRi * b1)
			view.setUint32(i, gen(a1, cb16, y16a) >>> 0, false)
			view.setUint32(i + 4, gen(a2, cr16, y16b) >>> 0, false)
		}
		return out
	}

	if (typeof module !== 'undefined' && module.exports) module.exports = rgbaToYuv422
	else root.rgbaToYuv422 = rgbaToYuv422
})(this)

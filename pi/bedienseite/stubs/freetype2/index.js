'use strict'
// Platzhalter fuer @julusian/freetype2. Das echte Modul ist nativ und fuer den Pi 1 (ARMv6) nicht verfuegbar.
// atem-connection braucht es nur fuer Multiview-Beschriftungen, die die Bedienseite nicht nutzt.
function fehlt() {
	throw new Error('freetype2 ist auf diesem Geraet nicht verfuegbar (Multiview-Beschriftungen werden nicht unterstuetzt)')
}
module.exports = { NewMemoryFace: fehlt, NewFace: fehlt, Init: fehlt }

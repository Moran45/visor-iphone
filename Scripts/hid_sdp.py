# Registro SDP del HID (puntero absoluto con rueda + teclado) en la codificación del daemon de CoreBluetooth.
# Reimplementación del formato descrito por open-phone (MIT).
import struct, sys

def mouse(report_id):
    # Puntero absoluto: 32 botones, X/Y de 16 bits (0-32767), rueda vertical y horizontal (AC Pan) relativas.
    d = bytes.fromhex('05010902a10185') + bytes([report_id])
    d += bytes.fromhex('0901a10005091901292015002501952075018102')
    d += bytes.fromhex('050109300931')
    d += bytes.fromhex('150026ff7f751095028102')
    d += bytes.fromhex('09381581257f750895018106')
    d += bytes.fromhex('050c0a380295018106')
    return d + bytes.fromhex('c0c0')

DESCRIPTOR = mouse(2) + bytes.fromhex('05010906a1018501050719e029e71500250175019508810275089501810105081901290595057501910295017503910105071500256519002965750895068100c0')

def uint(v, w=2): return bytes([0x08 + {1:0,2:1,4:2}[w]]) + v.to_bytes(w, 'big')
def uuid(v): return b'\x19' + v.to_bytes(2, 'big')
def seq(*items):
    v = b''.join(items)
    return (b'\x35' + bytes([len(v)]) if len(v) < 256 else b'\x36' + len(v).to_bytes(2,'big')) + v
def string(v):
    v = v.encode() if isinstance(v, str) else v
    return (b'\x25' + bytes([len(v)]) if len(v) < 256 else b'\x26' + len(v).to_bytes(2,'big')) + v
def boolean(v): return b'\x28' + bytes([bool(v)])

attrs = {
    0x0001: seq(uuid(0x1124)),
    0x0004: seq(seq(uuid(0x0100), uint(0x11)), seq(uuid(0x0011))),
    0x0005: seq(uuid(0x1002)),
    0x0006: seq(uint(0x656e), uint(0x006a), uint(0x0100)),
    0x0009: seq(seq(uuid(0x1124), uint(0x0101))),
    0x000d: seq(seq(seq(uuid(0x0100), uint(0x13)), seq(uuid(0x0011)))),
    0x0100: string('Visor iPhone HID'),
    0x0101: string('Puntero de Visor iPhone'),
    0x0102: string('Visor iPhone'),
    0x0200: uint(0x0100), 0x0201: uint(0x0111), 0x0202: uint(0xc0, 1), 0x0203: uint(0, 1),
    0x0204: boolean(True), 0x0205: boolean(True),
    0x0206: seq(seq(uint(0x22, 1), string(DESCRIPTOR))),
    0x0207: seq(seq(uint(0x0409), uint(0x0100))),
    0x0208: boolean(False), 0x0209: boolean(False), 0x020a: boolean(True),
    0x020b: uint(0x0101), 0x020c: uint(3200), 0x020d: boolean(True), 0x020e: boolean(False),
}

def apple(wire):
    header = wire[0]; kind, code = header >> 3, header & 7; cur = 1
    if kind == 0: return b'\0', cur
    if code <= 4: size = 1 << code
    else:
        w = {5:1, 6:2, 7:4}[code]; size = int.from_bytes(wire[cur:cur+w], 'big'); cur += w
    payload = wire[cur:cur+size]
    if kind in (1, 2, 3):
        value = int.from_bytes(payload, 'big', signed=kind == 2)
        enc = value.to_bytes(max(4, size), 'little', signed=kind == 2)
    elif kind in (6, 7):
        children, at = [], 0
        while at < size:
            child, used = apple(payload[at:]); children.append(child); at += used
        enc, size = b''.join(children), len(children)
    else:
        enc = payload
    return bytes([kind]) + struct.pack('<H', size) + enc, cur + len(payload)

record = struct.pack('<H', len(attrs)) + b''.join(struct.pack('<H', k) + apple(v)[0] for k, v in sorted(attrs.items()))
sys.stdout.write(', '.join(f'0x{b:02x}' for b in record))

#!/usr/bin/env python3
"""A pretend Allen & Heath SQ remote port on localhost, for testing Remora without a desk.

Serves TCP 51326 on 127.0.0.1 as a real SQ-5 was seen to (docs/PROTOCOL.md, captured
2026-11-21): answers the opening one step at a time, sends a state whose names section has the
SQ-5's layout, answers the ask for the selection, then plays a script of SEL presses and renames.
Answers "SQ Find" on UDP 51320 with "SQ-5". Like the desk, drops a client it has heard nothing
from for six seconds, and sends a status frame every second. Exits 1 if the client ever sends
anything but the opening, the keepalive, the ask for the selection or "SQ Find".

  fake-sq.py [--script "2:sel:7,4:sel:72,6:name:7:Vox"] [--for 15]

Script times are seconds after the state goes out; `sel:S` selects strip S (0-63 inputs, 64-71
FX returns, 72-87 groups, 88-103 auxes, 104 LR), `name:S:TEXT` renames it. The names are made up;
the bytes are the desk's.
"""
import argparse, socket, struct, sys, threading, time

ap = argparse.ArgumentParser()
ap.add_argument("--script", default="")
ap.add_argument("--for", dest="duration", type=float, default=15)
ap.add_argument("--port", type=int, default=51326)
a = ap.parse_args()
script = []
for s in (x for x in a.script.split(",") if x):
    t, kind, *rest = s.split(":")
    script.append((float(t), kind, rest))

NAMES = {0: "Kick", 1: "Snare", 2: "HH", 7: "Vox", 40: "Keys", 64: "Verb", 72: "Drums", 88: "Mon 1"}
t0 = time.time()
violations, seen = [], {}


def log(*x):
    print(f"{time.time()-t0:6.2f} fake-sq:", *x, flush=True)


def frame(t, payload=b""):
    return bytes([0x7F, t]) + struct.pack("<I", len(payload)) + payload


def short(src, dst, msg, data):
    return bytes([0xF7, src, dst, msg]) + bytes(data)


def state():
    """97376 bytes laid out as the SQ-5's: sections marked `<n> A5 A5 A5`, names in section 02."""
    s = bytearray(97376)
    s[0:4] = b"\xb5\x00\xfe\xff"
    s[56:60] = b"\x01\xa5\xa5\xa5"
    s[880:884] = b"\x02\xa5\xa5\xa5"
    for strip in range(122):
        o = 884 + 336 * strip
        s[o + 13:o + 16] = b"\xff\xff\xff"
        name = NAMES.get(strip, "").encode()
        s[o:o + len(name)] = name
    s[41876:41880] = b"\x03\xa5\xa5\xa5"
    return bytes(s)


FILTER = bytearray(0x2000)
for r in (0x00, 0x01, 0x02, 0x03, 0x04, 0x07, 0x09, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13,
          0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1D, 0x1E, 0x1F, 0x20, 0x21, 0x23, 0x24, 0x25, 0x26,
          0x27, 0x28, 0x29, 0x2B, 0x2D, 0x2F, 0x30, 0x34, 0x36):
    FILTER[r * 32:(r + 1) * 32] = b"\xff" * 32
ALLOWED = {
    frame(0x00, b"\x00\x00"): "hello",
    frame(0x01): "DiscoveryRequest",
    frame(0x0B, b"\x02\x00"): "FeatureSetRequest",
    frame(0x0A, bytes(FILTER)): "MessageFilter",
    frame(0x03): "SceneSyncRequest",
    frame(0x05): "keepalive",
    short(0x09, 0x09, 0x2F, [0, 0, 0, 0]): "selection request",
}
STATUS = frame(0x08, bytes([0x19, 0x1A, 0x1B]) + bytes(52))   # the desk's 55-byte status, zeroed


def finder():
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.bind(("127.0.0.1", 51320))
    while True:
        d, peer = u.recvfrom(1024)
        if d == b"SQ Find":
            u.sendto(b"SQ-5\x00", peer)
            seen["SQ Find"] = seen.get("SQ Find", 0) + 1
        else:
            violations.append(d.hex())
            log("NOT A FIND on UDP:", d[:16].hex(" "))


def client(conn):
    conn.settimeout(0.2)
    buf, last, sent_state, selected = b"", time.time(), None, 7
    alive = True
    nxt_status = time.time() + 1
    pending = list(script)
    while alive and time.time() - t0 < a.duration:
        try:
            d = conn.recv(65536)
            if not d:
                log("client closed")
                return
            buf += d
            last = time.time()
        except socket.timeout:
            pass
        except OSError:
            return
        while buf:
            if buf[0] == 0xF7:
                if len(buf) < 8:
                    break
                m, buf = buf[:8], buf[8:]
            elif buf[0] == 0x7F:
                if len(buf) < 6:
                    break
                n = struct.unpack_from("<I", buf, 2)[0]
                if len(buf) < 6 + n:
                    break
                m, buf = buf[:6 + n], buf[6 + n:]
            else:
                m, buf = buf[:1], buf[1:]
            what = ALLOWED.get(m)
            if what is None:
                violations.append(m[:16].hex())
                log("NOT A READ:", m[:16].hex(" "))
                continue
            seen[what] = seen.get(what, 0) + 1
            if what == "hello":
                conn.sendall(frame(0x00, struct.pack("<H", 51326)))
            elif what == "DiscoveryRequest":
                conn.sendall(frame(0x02, bytes([1, 1, 6, 1, 0x0A, 0x13, 0, 0, 0, 6, 0, 0])))
            elif what == "FeatureSetRequest":
                conn.sendall(frame(0x0C, b"\x01\x00"))
            elif what == "SceneSyncRequest":
                conn.sendall(frame(0x04, state()))
                sent_state = time.time()
                log("state sent")
            elif what == "selection request":
                conn.sendall(short(0x09, 0x09, 0x0C, [selected % 16, 0, 1, selected]))
                conn.sendall(short(0x09, 0x09, 0x0F, [0x0C, 0, 0, 0]))
        now = time.time()
        if now - last > 6:
            log("nothing from the client for six seconds: dropping it, as the desk does")
            conn.close()
            return
        if now >= nxt_status:
            conn.sendall(STATUS)
            nxt_status = now + 1
        while sent_state and pending and now >= sent_state + pending[0][0]:
            _, kind, rest = pending.pop(0)
            strip = int(rest[0])
            if kind == "sel":
                selected = strip
                conn.sendall(short(0x08, 0x15, 0x0C, [strip, 0, 0, 0]))
                conn.sendall(short(0x15, 0x09, 0x0C, [strip % 16, 0, 1, strip]))
                conn.sendall(short(0x34, 0x34, 0x0C, [1, strip, 1, 0]))
                log("SEL strip", strip)
            elif kind == "name":
                text = rest[1].encode()[:6]
                conn.sendall(frame(0x08, bytes([0x18, 0x18, 0x07, 0x00, strip, 0, 0]) + text + bytes(7 - len(text))))
                log("renamed strip", strip, rest[1])


threading.Thread(target=finder, daemon=True).start()
ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ls.bind(("127.0.0.1", a.port))
ls.listen(4)
ls.settimeout(0.5)
log("listening on", a.port)
while time.time() - t0 < a.duration:
    try:
        c, peer = ls.accept()
    except socket.timeout:
        continue
    log("client", peer)
    threading.Thread(target=client, args=(c,), daemon=True).start()
time.sleep(0.3)
log("received:", ", ".join(f"{k} x{v}" for k, v in sorted(seen.items())))
if violations:
    log(f"{len(violations)} message(s) that are not reads")
    sys.exit(1)
log("only reads")

#!/usr/bin/env python3
"""A pretend Yamaha QL1 on localhost, for testing Remora without a desk.

Serves the editor port (50000) and RCP (49280) as the QL1 behaves (docs/PROTOCOL.md): a heartbeat
every second, answers to read requests, and every change streamed once the client has sent QL
Editor's opening. Plays a script of SEL presses and exits 1 if the client ever sends anything but
a read request or an RCP get/devinfo.

  fake-ql.py --script "1:16,2:17,3.5:24,5:0" [--stop-heartbeat 8] [--for 12] [--port-offset 0]

Script times are seconds after the client's opening; values are selection numbers
(InCh 1 = 0, ST IN 1 L = 72, MIX 1 = 88).
"""
import argparse, socket, sys, threading, time

NAMES = {i: f"ch{i+1:2d}".replace(" ", " ") for i in range(32)}
NAMES.update({16: "head1", 17: "head2", 18: "head3", 19: "head4", 20: "hh1", 21: "hh2",
              22: "hh3", 23: "hh4", 24: "lec 1", 25: "lec 2", 27: "vt"})
HEARTBEAT = bytes.fromhex("f043103e197ff7")

ap = argparse.ArgumentParser()
ap.add_argument("--script", default="")
ap.add_argument("--start", type=int, default=0, help="selection before the script")
ap.add_argument("--stop-heartbeat", type=float, default=None, help="go silent after N s")
ap.add_argument("--for", dest="duration", type=float, default=15)
ap.add_argument("--port-offset", type=int, default=0)
a = ap.parse_args()
script = [(float(t), int(v)) for t, v in (x.split(":") for x in a.script.split(",") if x)]

violations = []
state = {"sel": a.start}
t0 = time.time()

def log(*x):
    print(f"{time.time()-t0:6.2f} fake-ql:", *x, flush=True)

def change(sel):
    d = [(sel >> s) & 0x7F for s in (28, 21, 14, 7, 0)]
    return bytes([0xF0, 0x43, 0x10, 0x3E, 0x19, 0x01, 0x03, 0x00, 0x00, 0x12, 0x00, 0x00, *d, 0xF7])

def editor(conn):
    opened = threading.Event()
    received = []
    alive = [True]
    def heartbeats():
        while alive[0]:
            if a.stop_heartbeat is not None and time.time() - t0 > a.stop_heartbeat:
                time.sleep(0.2); continue
            try: conn.sendall(HEARTBEAT)
            except OSError: return
            time.sleep(1)
    def player():
        opened.wait()
        start = time.time()
        for t, v in script:
            time.sleep(max(0, start + t - time.time()))
            if not alive[0]: return
            state["sel"] = v
            log(f"SEL → {v}")
            try: conn.sendall(change(v))
            except OSError: return
    threading.Thread(target=heartbeats, daemon=True).start()
    threading.Thread(target=player, daemon=True).start()
    buf = b""
    while True:
        try: chunk = conn.recv(65536)
        except OSError: break
        if not chunk: break
        buf += chunk
        while b"\xf7" in buf:
            m, buf = buf.split(b"\xf7", 1)
            m += b"\xf7"
            i = m.find(b"\xf0")
            m = m[i:] if i >= 0 else m
            if len(m) < 3 or m[2] & 0xF0 != 0x30:
                violations.append(m.hex()); log("VIOLATION: not a read request:", m.hex())
                continue
            received.append(m)
            if m.hex() == "f043303e1901030000120000f7":
                conn.sendall(change(state["sel"]))
            if len(received) >= 38 and not opened.is_set():
                log(f"client sent the opening ({len(received)} reads)"); opened.set()
    alive[0] = False
    log("editor client gone")

def rcp(conn):
    f = conn.makefile("rwb", buffering=0)
    for raw in f:
        line = raw.decode().strip()
        if not (line.startswith("get ") or line.startswith("devinfo ")):
            violations.append(line); log("VIOLATION: RCP", line); continue
        if line == "devinfo productname":
            f.write(b'OK devinfo productname "QL1"\n'); continue
        p = line.split()
        if len(p) >= 4 and p[1] == "MIXER:Current/InCh/Label/Name" and int(p[2]) < 32:
            f.write(f'OK get {p[1]} {p[2]} 0 "{NAMES[int(p[2])]}"\n'.encode())
        else:
            f.write(f"ERROR {line} UnknownAddress\n".encode())

def serve(port, handler):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port)); s.listen(4)
    while True:
        c, _ = s.accept()
        log(f"client on {port}")
        threading.Thread(target=handler, args=(c,), daemon=True).start()

for port, h in ((50000 + a.port_offset, editor), (49280 + a.port_offset, rcp)):
    threading.Thread(target=serve, args=(port, h), daemon=True).start()
log("listening")
time.sleep(a.duration)
log(f"done, {len(violations)} violations")
sys.exit(1 if violations else 0)

#!/usr/bin/env python3
"""A pretend Yamaha RIVAGE PM, DM7 or DM3 on localhost, for testing Remora without a desk.

Serves RCP (TCP 49280 on 127.0.0.1) as Remora's PM and DM modules expect it (docs/PROTOCOL.md):
`devinfo productname`, channel names, and cue switches as NOTIFY lines, which follow a script.
Exits 1 if the client ever sends anything but `get` or `devinfo`.

  fake-rcp.py --model PM --script "1:in:16,2:in:20:b,3:mix:0" [--for 15]

Script times are seconds after `devinfo`; each step puts one channel on cue (in, st, fx, mix or
mtx, numbered from 0 as RCP numbers them) and takes the last one off. A PM has cue A and B: add
`:b` for cue B.

Made up, as no answer has been captured: the PM's product name ("RIVAGE PM10"; the DM's "DM7" and
"DM3" are taken from the model names), and the form of every answer, which is the QL's.
"""
import argparse, socket, sys, threading, time

ap = argparse.ArgumentParser()
ap.add_argument("--model", choices=("PM", "DM7", "DM3"), default="PM")
ap.add_argument("--script", default="")
ap.add_argument("--for", dest="duration", type=float, default=15)
ap.add_argument("--port", type=int, default=49280)
a = ap.parse_args()

KIND = {"in": "InCh", "st": "StInCh", "fx": "FxRtnCh", "mix": "Mix", "mtx": "Mtrx"}
# How many of each the desk has: a smaller desk answers the rest with errors.
SIZES = {"PM": {"InCh": 144, "Mix": 72, "Mtrx": 36},
         "DM7": {"InCh": 120, "Mix": 48, "Mtrx": 12},
         "DM3": {"InCh": 16, "StInCh": 2, "FxRtnCh": 4, "Mix": 6, "Mtrx": 2}}[a.model]
PRODUCT = {"PM": "RIVAGE PM10", "DM7": "DM7", "DM3": "DM3"}[a.model]
NAMES = {16: "head1", 17: "head2", 18: "head3", 19: "head4", 20: "hh1", 21: "hh2", 22: "hh3", 23: "hh4",
         24: "lec 1", 25: "lec 2", 27: "vt"}
if a.model == "DM3":
    NAMES = {0: "head1", 1: "head2", 4: "hh1", 8: "lec 1", 9: "lec 2"}


def name(kind, i):
    if kind == "InCh":
        return NAMES.get(i, f"ch{i + 1:2d}")
    return {"StInCh": "ST", "FxRtnCh": "FX", "Mix": "MIX", "Mtrx": "MTRX"}[kind] + f"{i + 1}"


script = []
for step in (s for s in a.script.split(",") if s):
    p = step.split(":")
    script.append((float(p[0]), KIND[p[1]], int(p[2]), 1 if p[3:] == ["b"] else 0))

t0 = time.time()
violations, gets = [], {}


def log(*x):
    print(f"{time.time()-t0:6.2f} fake-rcp {a.model}:", *x, flush=True)


def client(conn):
    f = conn.makefile("rwb", buffering=0)
    opened = threading.Event()
    alive = [True]

    def player():
        opened.wait()
        start, last = time.time(), None
        for t, kind, i, y in script:
            time.sleep(max(0, start + t - time.time()))
            if not alive[0]:
                return
            try:
                if last:
                    f.write(f'NOTIFY set MIXER:Current/Cue/{last[0]}/On {last[1]} {last[2]} 0 "OFF"\n'.encode())
                f.write(f'NOTIFY set MIXER:Current/Cue/{kind}/On {i} {y} 1 "ON"\n'.encode())
            except OSError:
                return
            last = (kind, i, y)
            log(f"cue {'B' if y else 'A'} on {kind} {i}")

    threading.Thread(target=player, daemon=True).start()
    for raw in f:
        line = raw.decode(errors="replace").strip()
        if not (line.startswith("get ") or line.startswith("devinfo ")):
            violations.append(line)
            log("VIOLATION:", line)
            continue
        if line == "devinfo productname":
            f.write(f'OK devinfo productname "{PRODUCT}"\n'.encode())
            opened.set()
            continue
        p = line.split()
        path = p[1] if len(p) > 1 else ""
        gets[path] = gets.get(path, 0) + 1
        kind = path.split("/")[1] if path.startswith("MIXER:Current/") and path.endswith("/Label/Name") else None
        if kind in SIZES and len(p) >= 4 and int(p[2]) < SIZES[kind]:
            f.write(f'OK get {path} {p[2]} {p[3]} "{name(kind, int(p[2]))}"\n'.encode())
        else:
            f.write(f"ERROR {line} InvalidArgument\n".encode())
    alive[0] = False
    log("client gone")


def serve():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", a.port))
    s.listen(4)
    while True:
        c, _ = s.accept()
        log("client connected")
        threading.Thread(target=client, args=(c,), daemon=True).start()


threading.Thread(target=serve, daemon=True).start()
log(f"listening on TCP {a.port}")
time.sleep(a.duration)
log("gets: " + ", ".join(f"{k.split(':')[1]} {v}" for k, v in sorted(gets.items())))
log(f"done, {len(violations)} violations")
sys.exit(1 if violations else 0)

#!/usr/bin/env python3
"""A pretend Allen & Heath Avantis or dLive on localhost, for testing Remora without a desk.

Serves MIDI over TCP (51325 on 127.0.0.1) as A&H's protocol documents describe it
(docs/PROTOCOL.md): answers Get Name with the channel's name, and plays a script of soft-key
presses (a note on, then off) for learned controls. Exits 1 if the client ever sends anything but
a Get Name request.

  fake-allenheath.py --desk avantis [--channel 12] [--script "2:5,4:6"] [--for 15]

Script times are seconds after the first request; values are note numbers, sent on the desk's
MIDI channel. An Avantis answers inputs 1–64 (version 1.10's count), a dLive inputs 1–128 and FX
returns 1–16. The names are made up; the message forms are the documents'.
"""
import argparse, socket, sys, threading, time

ap = argparse.ArgumentParser()
ap.add_argument("--desk", choices=("avantis", "dlive"), default="avantis")
ap.add_argument("--channel", type=int, default=None, help="the desk's MIDI channel, 1–16")
ap.add_argument("--script", default="")
ap.add_argument("--for", dest="duration", type=float, default=15)
ap.add_argument("--port", type=int, default=51325)
a = ap.parse_args()
midi = (a.channel or (12 if a.desk == "avantis" else 1)) - 1
script = [(float(t), int(v)) for t, v in (s.split(":") for s in a.script.split(",") if s)]
HEADER = bytes([0xF0, 0x00, 0x00, 0x1A, 0x50, 0x10, 0x01, 0x00])
NAMES = {16: "head1", 17: "head2", 18: "head3", 19: "head4", 20: "hh1", 21: "hh2", 22: "hh3", 23: "hh4",
         24: "lec 1", 25: "lec 2", 27: "vt"}

t0 = time.time()
violations, asked = [], {"inputs": 0, "fx returns": 0, "unanswered": 0}


def log(*x):
    print(f"{time.time()-t0:6.2f} fake-{a.desk}:", *x, flush=True)


def answer(n, ch):
    """The name for Get Name on channel N+offset, CH; None if the desk has no such channel."""
    offset = (n - midi) & 0x0F
    if offset == 0 and ch < (64 if a.desk == "avantis" else 128):
        asked["inputs"] += 1
        return NAMES.get(ch, f"Ip{ch + 1}")
    if a.desk == "dlive" and offset == 4 and 0x20 <= ch <= 0x2F:
        asked["fx returns"] += 1
        return f"FX{ch - 0x1F}"
    asked["unanswered"] += 1
    return None


def client(conn):
    started = threading.Event()
    alive = [True]

    def player():
        started.wait()
        start = time.time()
        for t, note in script:
            time.sleep(max(0, start + t - time.time()))
            if not alive[0]:
                return
            try:
                conn.sendall(bytes([0x90 | midi, note, 0x7F]))
                time.sleep(0.2)
                conn.sendall(bytes([0x90 | midi, note, 0x00]))
            except OSError:
                return
            log(f"soft key: note {note} on channel {midi + 1}")

    threading.Thread(target=player, daemon=True).start()
    buf = b""
    while True:
        try:
            chunk = conn.recv(65536)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        while buf:
            if buf[0] != 0xF0:
                violations.append(buf.hex())
                log("VIOLATION: not SysEx:", buf.hex())
                buf = b""
                break
            end = buf.find(b"\xf7")
            if end < 0:
                break
            m, buf = buf[:end + 1], buf[end + 1:]
            if not (len(m) == len(HEADER) + 4 and m.startswith(HEADER) and m[len(HEADER)] <= 0x0F
                    and m[len(HEADER) + 1] == 0x01 and m[len(HEADER) + 2] < 0x80):
                violations.append(m.hex())
                log("VIOLATION: not a Get Name request:", m.hex())
                continue
            started.set()
            n, ch = m[len(HEADER)], m[len(HEADER) + 2]
            name = answer(n, ch)
            if name is not None:
                conn.sendall(HEADER + bytes([n, 0x02, ch]) + name.encode() + b"\xf7")
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
log(f"listening on TCP {a.port}, MIDI channel {midi + 1}")
time.sleep(a.duration)
log("Get Name: " + ", ".join(f"{k} {v}" for k, v in asked.items()))
log(f"done, {len(violations)} violations")
sys.exit(1 if violations else 0)

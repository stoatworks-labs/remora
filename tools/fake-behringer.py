#!/usr/bin/env python3
"""A pretend Behringer X32 or Wing on localhost, for testing Remora without a desk.

Answers OSC over UDP as the protocol documents describe the desks (docs/PROTOCOL.md): what the
desk is (/info on an X32, /? on a Wing), channel names, and the selected channel (/-stat/selidx,
/$ctl/$stat/selidx), which follows a script. Exits 1 if the client ever sends anything but a read:
a message with an argument, a push subscription (/xremote, /*s), or any address Remora does not
read (/-action, /-prefs, and the rest).

  fake-behringer.py --desk x32 --script "1:16,2:17,3:33,4:70" [--for 15] [--quiet-after 8]

Script times are seconds after the first request; values are selidx numbers. X32: channel 1 = 0,
aux in 1 = 32, FX return 1 = 40, bus 1 = 48, matrix 1 = 64, main LR = 70, mono = 71. Wing:
channel 1 = 0, aux 1 = 40, bus 1 = 48, main 1 = 64, matrix 1 = 68 (the Wing's order is inferred
from the channel counts, not documented).

The answers' forms are from the documents. No desk's answer has been captured.
"""
import argparse, socket, struct, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("--desk", choices=("x32", "wing"), default="x32")
ap.add_argument("--script", default="")
ap.add_argument("--start", type=int, default=0, help="selidx before the script")
ap.add_argument("--quiet-after", type=float, default=None, help="stop answering after N s")
ap.add_argument("--for", dest="duration", type=float, default=15)
ap.add_argument("--port", type=int, default=None)
a = ap.parse_args()
x32 = a.desk == "x32"
port = a.port or (10023 if x32 else 2223)
script = [(float(t), int(v)) for t, v in (s.split(":") for s in a.script.split(",") if s)]

# The QL fake's names, on the first 32 channels.
NAMES = {n: f"ch{n:2d}" for n in range(1, 33)}
NAMES.update({17: "head1", 18: "head2", 19: "head3", 20: "head4", 21: "hh1", 22: "hh2", 23: "hh3",
              24: "hh4", 25: "lec 1", 26: "lec 2", 28: "vt"})


def nn(n):
    return f"{n:02d}"


# Every address Remora may ask for, with the name the desk answers.
if x32:
    IDENTIFY, SELECTION = "/info", "/-stat/selidx"
    names = {f"/ch/{nn(n)}/config/name": NAMES[n] for n in range(1, 33)}
    names.update({f"/auxin/{nn(n)}/config/name": f"Aux {n}" for n in range(1, 9)})
    names.update({f"/fxrtn/{nn(n)}/config/name": "" for n in range(1, 9)})
    names.update({f"/bus/{nn(n)}/config/name": f"Mon {n}" if n <= 8 else "" for n in range(1, 17)})
    names.update({f"/mtx/{nn(n)}/config/name": "" for n in range(1, 7)})
    names.update({"/main/st/config/name": "LR", "/main/m/config/name": ""})
else:
    IDENTIFY, SELECTION = "/?", "/$ctl/$stat/selidx"
    names = {f"/ch/{n}/name": NAMES.get(n, "") for n in range(1, 41)}
    names.update({f"/aux/{n}/name": f"Aux {n}" for n in range(1, 9)})
    names.update({f"/bus/{n}/name": f"Mon {n}" if n <= 8 else "" for n in range(1, 17)})
    names.update({f"/main/{n}/name": "Main" if n == 1 else "" for n in range(1, 5)})
    names.update({f"/mtx/{n}/name": "" for n in range(1, 9)})
ALLOWED = set(names) | {IDENTIFY, SELECTION}

t0 = time.time()
violations, asked, answered = [], {"identify": 0, "selection": 0, "names": 0}, 0
state = {"sel": a.start}


def log(*x):
    print(f"{time.time()-t0:6.2f} fake-{a.desk}:", *x, flush=True)


def pad(b):
    return b + b"\0" * (4 - len(b) % 4)


def osc(address, *args):
    tags, data = ",", b""
    for v in args:
        if isinstance(v, str):
            tags, data = tags + "s", data + pad(v.encode())
        elif isinstance(v, float):
            tags, data = tags + "f", data + struct.pack(">f", v)
        else:
            tags, data = tags + "i", data + struct.pack(">i", v)
    return pad(address.encode()) + pad(tags.encode()) + data


def why_not_a_read(m):
    """None for a read Remora may send; otherwise what is wrong with it."""
    end = m.find(b"\0")
    if not m.startswith(b"/") or end < 0:
        return "not an OSC message"
    address = m[:end].decode(errors="replace")
    i = (end // 4 + 1) * 4
    if i > len(m) or any(m[end:i]):
        return f"{address}: bad padding"
    rest = m[i:]
    if rest not in (b"", b",\0\0\0"):
        tags = rest[:rest.find(b"\0")].decode(errors="replace") if b"\0" in rest else rest.hex()
        return f"{address}: has arguments ({tags})"
    if address in ("/xremote", "/*s", "/*", "/%s"):
        return f"{address}: a push subscription"
    if address not in ALLOWED:
        return f"{address}: not an address Remora reads"
    return None


def selection(v):
    return osc(SELECTION, v) if x32 else osc(SELECTION, str(v), float(v), v)


def identity():
    if x32:
        return osc(IDENTIFY, "V2.05", "osc-server", "X32", "4.06")
    return osc(IDENTIFY, "WING,127.0.0.1,FAKE,ngc-full,NO_SERIAL,3.0.5-0-gfake:release")


s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", port))
s.settimeout(0.05)
log(f"listening on UDP {port}")
first = None
clients = set()
while time.time() - t0 < a.duration:
    now = time.time()
    if first is not None:
        while script and now - first >= script[0][0]:
            state["sel"] = script.pop(0)[1]
            log(f"selected → {state['sel']}")
    try:
        m, peer = s.recvfrom(65536)
    except socket.timeout:
        continue
    if peer not in clients:
        clients.add(peer)
        log(f"client {peer[0]}:{peer[1]}")
    if first is None:
        first = now
    bad = why_not_a_read(m)
    if bad:
        violations.append(bad)
        log("VIOLATION:", bad)
        continue
    address = m[:m.find(b"\0")].decode()
    kind = "identify" if address == IDENTIFY else "selection" if address == SELECTION else "names"
    asked[kind] += 1
    if a.quiet_after is not None and now - t0 > a.quiet_after:
        if kind == "identify":
            log(f"{IDENTIFY} asked, not answering")
        continue
    answered += 1
    if kind == "identify":
        s.sendto(identity(), peer)
    elif kind == "selection":
        s.sendto(selection(state["sel"]), peer)
    else:
        s.sendto(osc(address, names[address]), peer)
log(f"done: asked {', '.join(f'{k} {v}' for k, v in asked.items())}; answered {answered};"
    f" {len(violations)} violations")
sys.exit(1 if violations else 0)

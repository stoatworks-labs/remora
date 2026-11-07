#!/usr/bin/env python3
"""A pretend OSC plug-in host on localhost, for testing Remora without the host.

Plays LiveProfessor, Gig Performer, VSTHost or Ableton Live with AbletonOSC as their documents
describe them (docs/PROTOCOL.md), logs every message Remora sends, and exits 1 if Remora ever sends
one that isn't on that host's list: the same lists as the modules' whitelists.

  fake-host.py --host vsthost [--tracks "Kick,Snare,Vox"] [--for 15] [--port N]

- liveprofessor (UDP 8000): /Chains/Select i (from 1), /Chains/Select/Next, /Previous. No answers.
- gigperformer (UDP 54344): /GigPerformer/SwitchToRackSpace i (from 0), NextRackSpace,
  PrevRackSpace. No answers.
- vsthost (UDP 7701): /performance/num i loads; with no argument it answers the number loaded,
  back to the sender.
- ableton (UDP 11000): /live/song/get/track_names answers the names, and
  /live/view/start_listen/selected_track the selection and every change after, on port 11001 of
  the address that asked. /live/view/set/selected_track i selects.

The answers' forms are from the documents. No host's answer has been captured.
"""
import argparse, socket, struct, sys, time

HOSTS = {
    "liveprofessor": (8000, {"/Chains/Select": ["i"], "/Chains/Select/Next": [""], "/Chains/Select/Previous": [""]}),
    "gigperformer": (54344, {"/GigPerformer/SwitchToRackSpace": ["i"], "/GigPerformer/NextRackSpace": [""],
                             "/GigPerformer/PrevRackSpace": [""]}),
    "vsthost": (7701, {"/performance/num": ["i", ""]}),
    "ableton": (11000, {"/live/song/get/track_names": [""], "/live/view/start_listen/selected_track": [""],
                        "/live/view/set/selected_track": ["i"]}),
}

ap = argparse.ArgumentParser()
ap.add_argument("--host", choices=sorted(HOSTS), required=True)
ap.add_argument("--tracks", default="head 1,head 2,head 3,head 4,Lec,vt")
ap.add_argument("--start", type=int, default=0, help="where the host is before Remora moves it")
ap.add_argument("--for", dest="duration", type=float, default=15)
ap.add_argument("--port", type=int, default=None)
a = ap.parse_args()
port, ALLOWED = HOSTS[a.host]
port = a.port or port
tracks = [t for t in a.tracks.split(",") if t]
state = {"at": a.start, "listening": None}
t0 = time.time()
violations, heard = [], []


def log(*x):
    print(f"{time.time()-t0:6.2f} fake-{a.host}:", *x, flush=True)


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


def parse(m):
    """(address, tags, args), or a string saying what is wrong."""
    end = m.find(b"\0")
    if not m.startswith(b"/") or end < 0:
        return "not an OSC message"
    address = m[:end].decode(errors="replace")
    i = (end // 4 + 1) * 4
    if i > len(m) or any(m[end:i]):
        return f"{address}: bad padding"
    rest = m[i:]
    if not rest:
        return address, "", []
    tend = rest.find(b"\0")
    if not rest.startswith(b",") or tend < 0:
        return f"{address}: bad type tags"
    tags = rest[1:tend].decode(errors="replace")
    j = (tend // 4 + 1) * 4
    args = []
    for t in tags:
        if t == "i" and j + 4 <= len(rest):
            args.append(struct.unpack(">i", rest[j:j + 4])[0])
            j += 4
        elif t == "s":
            e = rest.find(b"\0", j)
            if e < 0:
                return f"{address}: bad string"
            args.append(rest[j:e].decode(errors="replace"))
            j = (e // 4 + 1) * 4
        else:
            return f"{address}: an argument of type {t}"
    return address, tags, args


def answer(sock, peer, address, *args):
    if a.host == "ableton":
        peer = (peer[0], 11001)
    sock.sendto(osc(address, *args), peer)


s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", port))
s.settimeout(0.05)
log(f"listening on UDP {port}, {len(tracks)} {'tracks' if a.host == 'ableton' else 'items'}")
while time.time() - t0 < a.duration:
    try:
        m, peer = s.recvfrom(65536)
    except socket.timeout:
        continue
    p = parse(m)
    if isinstance(p, str):
        violations.append(p)
        log("VIOLATION:", p)
        continue
    address, tags, args = p
    if tags not in ALLOWED.get(address, []):
        violations.append(f"{address} ,{tags}")
        log("VIOLATION: not on the list:", address, tags, args)
        continue
    heard.append(address)
    log("heard", address, *args)
    if a.host == "vsthost":
        if args:
            state["at"] = args[0]
        else:
            answer(s, peer, "/performance/num", state["at"])
    elif a.host == "ableton":
        if address.endswith("track_names"):
            answer(s, peer, address, *tracks)
        elif address.endswith("start_listen/selected_track"):
            state["listening"] = peer
            answer(s, peer, "/live/view/get/selected_track", state["at"])
        elif address.endswith("set/selected_track"):
            state["at"] = args[0]
            if state["listening"]:
                answer(s, state["listening"], "/live/view/get/selected_track", state["at"])
    elif address == "/Chains/Select" or address.endswith("SwitchToRackSpace"):
        state["at"] = args[0]
    elif address.endswith(("Next", "NextRackSpace")):
        state["at"] += 1
    elif address.endswith(("Previous", "PrevRackSpace")):
        state["at"] -= 1
    log("now at", state["at"])

log(f"done, {len(heard)} messages, {len(violations)} violations")
sys.exit(1 if violations else 0)

#!/usr/bin/env python3
"""A pretend Cantabile network server on localhost, for testing Remora without Cantabile.

Speaks the WebSocket API at ws://127.0.0.1:35007/api/socket/ as Cantabile's Network Developer Guide
and its JavaScript client (cantabile-js 0.3.5) describe it (docs/PROTOCOL.md): it opens the set
list, loads a song by its index or the next or previous one, and says when the loaded song
changes. Logs every message, and exits 1 if Remora sends anything but these four
(Cantabile.Request), exactly, with no other key:

- {"method": "open", "ep": "/api/setlist", "rid": n}
- {"method": "close", "epid": e}
- {"method": "post", "epid": e, "ep": "/loadSongByIndex", "rid": n, "data": {"index": i, "delayed": false}}
- {"method": "post", "epid": e, "ep": "/loadNextSong", "rid": n,
   "data": {"direction": 1 or -1, "delayed": false, "wrap": false}}

  fake-cantabile.py [--songs "Intro,|Interval,Ballad"] [--current N] [--for 15] [--port 35007]

A name starting with | is a break. --current is the item loaded at the start (breaks count). A
bad handshake, an unmasked or binary frame, and an end point it didn't open are violations too.
It pings once after the set list opens. The answers' forms are from the guide and cantabile-js;
nothing here is captured from Cantabile.
"""
import argparse, base64, hashlib, json, select, socket, struct, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("--songs", default="head 1,head 2,|Interval,head 3,head 4,Lec,vt")
ap.add_argument("--current", type=int, default=0)
ap.add_argument("--for", dest="duration", type=float, default=15)
ap.add_argument("--port", type=int, default=35007)
a = ap.parse_args()
items, pr = [], 0
for n in (t for t in a.songs.split(",") if t):
    if n.startswith("|"):
        items.append({"kind": "break", "name": n[1:]})
    else:
        items.append({"kind": "song", "name": n, "pr": pr})
        pr += 1
state = {"current": a.current, "epid": 6}
t0 = time.time()
violations, heard = [], []
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def log(*x):
    print(f"{time.time()-t0:6.2f} fake-cantabile:", *x, flush=True)


def wrong(why):
    violations.append(why)
    log("VIOLATION:", why)


def frame(op, payload):
    n = len(payload)
    head = bytes([0x80 | op])
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack(">H", n)
    else:
        head += bytes([127]) + struct.pack(">Q", n)
    return head + payload


def say(c, obj):
    c["sock"].sendall(frame(1, json.dumps(obj).encode()))


def take(c):
    """The next whole frame from the client, as (fin, opcode, masked, payload), or None."""
    b = c["buf"]
    if len(b) < 2:
        return None
    fin, op, masked, n, i = bool(b[0] & 0x80), b[0] & 0x0F, bool(b[1] & 0x80), b[1] & 0x7F, 2
    if n == 126:
        if len(b) < 4:
            return None
        n, i = struct.unpack(">H", b[2:4])[0], 4
    elif n == 127:
        if len(b) < 10:
            return None
        n, i = struct.unpack(">Q", b[2:10])[0], 10
    mask = b[i:i + 4] if masked else b"\0\0\0\0"
    i += 4 if masked else 0
    if len(b) < i + n:
        return None
    payload = bytes(x ^ mask[j % 4] for j, x in enumerate(b[i:i + n]))
    c["buf"] = b[i + n:]
    return fin, op, masked, payload


def handshake(c):
    end = c["buf"].find(b"\r\n\r\n")
    if end < 0:
        return False
    head, c["buf"] = c["buf"][:end].decode(errors="replace"), c["buf"][end + 4:]
    lines = head.split("\r\n")
    h = {k.strip().lower(): v.strip() for k, sep, v in (x.partition(":") for x in lines[1:]) if sep}
    key = h.get("sec-websocket-key", "")
    try:
        sixteen = len(base64.b64decode(key, validate=True)) == 16
    except ValueError:
        sixteen = False
    if not (lines[0] == "GET /api/socket/ HTTP/1.1" and h.get("upgrade", "").lower() == "websocket"
            and "upgrade" in h.get("connection", "").lower() and h.get("sec-websocket-version") == "13" and sixteen):
        wrong(f"not Cantabile's WebSocket handshake: {lines[0]}")
        c["sock"].sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
        return None
    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    c["sock"].sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                       f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    c["open"] = True
    log("WebSocket open")
    return True


def whole(v):
    return isinstance(v, int) and not isinstance(v, bool)


def listed(m):
    """Whether m is one of the four, exactly."""
    if not isinstance(m, dict):
        return False
    k, method, d = set(m), m.get("method"), m.get("data")
    if method == "open":
        return k == {"method", "ep", "rid"} and m["ep"] == "/api/setlist" and whole(m["rid"]) and m["rid"] > 0
    if method == "close":
        return k == {"method", "epid"} and whole(m["epid"])
    if method != "post" or k != {"method", "epid", "ep", "rid", "data"} or not isinstance(d, dict):
        return False
    if not (whole(m["epid"]) and whole(m["rid"]) and m["rid"] > 0):
        return False
    if m["ep"] == "/loadSongByIndex":
        return set(d) == {"index", "delayed"} and whole(d["index"]) and d["index"] >= 0 and d["delayed"] is False
    if m["ep"] == "/loadNextSong":
        return (set(d) == {"direction", "delayed", "wrap"} and whole(d["direction"]) and d["direction"] in (1, -1)
                and d["delayed"] is False and d["wrap"] is False)
    return False


def loaded(conns):
    log("now at", state["current"], items[state["current"]]["name"] if 0 <= state["current"] < len(items) else "-")
    for c in conns:
        for e in c["epids"]:
            say(c, {"epid": e, "eventName": "currentSongChanged", "data": {"current": state["current"]}})


def message(c, text, conns):
    try:
        m = json.loads(text)
    except ValueError:
        return wrong(f"not JSON: {text[:80]}")
    if not listed(m):
        return wrong(f"not on the list: {text[:160]}")
    heard.append(text)
    log("heard", text)
    if m["method"] == "open":
        state["epid"] += 1
        c["epids"].add(state["epid"])
        say(c, {"rid": m["rid"], "status": 200, "epid": state["epid"],
                "data": {"name": "Remora test", "preLoaded": False, "current": state["current"], "items": items}})
        if not c["pinged"]:
            c["pinged"] = True
            c["sock"].sendall(frame(9, b"fake"))
        return
    if m["epid"] not in c["epids"]:
        return wrong(f"end point {m['epid']} isn't one this connection opened")
    if m["method"] == "close":
        c["epids"].discard(m["epid"])
        return
    d, at = m["data"], state["current"]
    if m["ep"] == "/loadSongByIndex":
        i = d["index"]
        if i >= len(items) or items[i]["kind"] != "song":
            return say(c, {"rid": m["rid"], "status": 404, "statusDescription": "No song at that index"})
        state["current"] = i
    else:
        j = at + d["direction"]
        while 0 <= j < len(items) and items[j]["kind"] != "song":
            j += d["direction"]
        if 0 <= j < len(items):
            state["current"] = j
    say(c, {"rid": m["rid"], "status": 200})
    if state["current"] != at:
        loaded(conns)


srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", a.port))
srv.listen(4)
log(f"listening on TCP {a.port}, {len(items)} items, item {a.current} loaded")
conns = {}
while time.time() - t0 < a.duration:
    ready, _, _ = select.select([srv, *conns], [], [], 0.05)
    for s in ready:
        if s is srv:
            sock, peer = srv.accept()
            conns[sock] = {"sock": sock, "buf": b"", "open": False, "epids": set(), "pinged": False}
            log("connection from", f"{peer[0]}:{peer[1]}")
            continue
        c = conns[s]
        try:
            data = s.recv(65536)
        except OSError:
            data = b""
        gone = not data
        c["buf"] += data
        if not gone and not c["open"]:
            r = handshake(c)
            gone = r is None
        while not gone and c["open"]:
            f = take(c)
            if f is None:
                break
            fin, op, masked, payload = f
            if not masked:
                wrong("an unmasked frame from the client")
                gone = True
            elif op == 1 and fin:
                message(c, payload.decode(errors="replace"), conns.values())
            elif op == 10:
                log("pong", payload)
            elif op == 8:
                s.sendall(frame(8, payload[:2]))
                gone = True
            else:
                wrong(f"a frame Remora never sends: opcode {op}, fin {fin}")
                gone = True
        if gone:
            log("connection closed")
            s.close()
            del conns[s]
for s in conns:
    s.close()
log(f"done, {len(heard)} messages, {len(violations)} violations")
sys.exit(1 if violations else 0)

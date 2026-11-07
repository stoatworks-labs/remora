#!/usr/bin/env python3
"""A pretend REAPER web interface on localhost, for testing Remora without REAPER.

Answers GET /_/<commands> as REAPER's web interface does by its own notes (docs/PROTOCOL.md): the
commands are joined by ';' and run in order, and each TRACK is answered with the track list. Logs
every request, and exits 1 if Remora asks for anything but these three (REAPER.isAllowed):

- TRACK: every track, a line each, tab-separated, the master (0) first.
- 40297 (Track: Unselect all tracks): no track selected.
- SET/TRACK/n/SEL/1: track n (from 1) selected.

  fake-reaper.py [--tracks "Kick,Snare,Vox"] [--select N] [--for 15] [--port 8080]
                 [--no-length] [--password]

A line's number, name and flags (2: selected) are where REAPER's main.js reads them; the other
fields are made up. --no-length leaves Content-Length out, so only the close ends an answer.
--password answers 401, which Remora reads as REAPER asking for a username and password (what REAPER
answers then isn't documented). Nothing here is captured from REAPER.
"""
import argparse, re, select, socket, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("--tracks", default="head 1,head 2,head 3,head 4,Lec,vt")
ap.add_argument("--select", type=int, default=None, help="the track selected before Remora moves it, from 1")
ap.add_argument("--for", dest="duration", type=float, default=15)
ap.add_argument("--port", type=int, default=8080)
ap.add_argument("--no-length", action="store_true")
ap.add_argument("--password", action="store_true")
a = ap.parse_args()
names = [t for t in a.tracks.split(",") if t]
selected = {a.select} if a.select else set()
t0 = time.time()
violations, heard = [], []
SET = re.compile(r"SET/TRACK/([1-9][0-9]{0,4})/SEL/1")


def log(*x):
    print(f"{time.time()-t0:6.2f} fake-reaper:", *x, flush=True)


def allowed(path):
    """REAPER.isAllowed, again."""
    return path.startswith("/_/") and all(c in ("TRACK", "40297") or SET.fullmatch(c) for c in path[3:].split(";"))


def run(path):
    body = ""
    for c in path[3:].split(";"):
        if c == "TRACK":
            body += "TRACK\t0\tMASTER\t0\t1.000000\t0.000000\t-1500\t-1500\t1.000000\t0\t0\t0\t0\t0\n"
            for i, n in enumerate(names, 1):
                flags = 2 if i in selected else 0
                body += f"TRACK\t{i}\t{n}\t{flags}\t1.000000\t0.000000\t-1500\t-1500\t1.000000\t0\t0\t0\t1\t0\n"
        elif c == "40297":
            selected.clear()
        else:
            n = int(SET.fullmatch(c).group(1))
            if n <= len(names):
                selected.add(n)
    return body


def answer(request):
    line = request.split(b"\r\n", 1)[0].decode(errors="replace")
    parts = line.split(" ")
    if len(parts) != 3 or parts[0] != "GET" or not parts[2].startswith("HTTP/1."):
        violations.append(line)
        log("VIOLATION: not a GET:", line)
        return b"HTTP/1.0 400 Bad Request\r\n\r\n"
    path = parts[1]
    if not allowed(path):
        violations.append(path)
        log("VIOLATION: not on the list:", path)
        return b"HTTP/1.0 404 Not Found\r\n\r\n"
    heard.append(path)
    if a.password:
        log("heard", path, "-> 401, a password is set")
        return b'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm="REAPER"\r\n\r\n'
    body = run(path).encode()
    log("heard", path, "-> selected", sorted(selected) or "none")
    head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-cache\r\n"
    if not a.no_length:
        head += f"Content-Length: {len(body)}\r\n"
    return (head + "\r\n").encode() + body


srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", a.port))
srv.listen(8)
log(f"listening on TCP {a.port}, {len(names)} tracks" + (", with a password" if a.password else ""))
pending = {}
while time.time() - t0 < a.duration:
    ready, _, _ = select.select([srv, *pending], [], [], 0.05)
    for s in ready:
        if s is srv:
            c, _ = srv.accept()
            pending[c] = b""
            continue
        try:
            data = s.recv(65536)
        except OSError:
            data = b""
        if data:
            pending[s] += data
            if b"\r\n\r\n" not in pending[s] and len(pending[s]) <= 65536:
                continue
            try:
                s.sendall(answer(pending[s]))
            except OSError:
                pass
        # One request a connection: the close ends the answer.
        s.close()
        del pending[s]
for s in pending:
    s.close()
log(f"done, {len(heard)} requests, {len(violations)} violations")
sys.exit(1 if violations else 0)

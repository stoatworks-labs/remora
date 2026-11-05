# AGENTS.md — Remora

Invariants for anyone (human or agent) changing this repo.

- **The console is read-only.** On the editor port send only `F0 43 3n …` requests;
  `YamahaSysEx.isReadRequest` guards every send and must keep doing so. Over RCP send only `get` and
  `devinfo`, never `set`. Consoles are often mid-show when this runs.
- **SuperRack's files are read-only.** Copy `CurrentSPRKP.dat` and its WAL and read the copy
  (`SuperRackSession`); never open the live database.
- **One MIDI message is one step.** SuperRack steps on every Next/Previous Rack message whatever its
  value, stops at both ends and never reports its rack (docs/PROTOCOL.md). Never send a 127/0 pair
  for a rack step, and never assume a position the driver did not count to. A change of rack count
  forgets the position.
- **No new console or SuperRack fact without a capture.** docs/PROTOCOL.md says what was measured, on
  which firmware and when; add to it when something new is actually run. Do the same for the README's
  status block. Nothing counts as verified because it compiles.
- **Off limits:** Waves ProLink (its console link), and decompiling Waves or Yamaha binaries.
- **Testing without a desk:** `tools/fake-ql.py` on localhost, with `Remora --headless --dry-run
  --host 127.0.0.1`, which logs the MIDI instead of making a port. Testing against SuperRack needs
  Remora ticked under MIDI In in SuperRack's MIDI Controller, and only ever on a rig that is not in
  a show.
- **One version:** `appVersion` in `Sources/Remora/main.swift`; `scripts/build-app.sh` reads it.
- The menu-bar symbol is an SF Symbol (`fish`), which the licence allows in UI. An app icon must be
  drawn, never an SF Symbol.

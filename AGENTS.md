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
- **Plug-in windows: press only "Close".** `PluginWindowGuard` acts on SuperRack only by `AXPress` on
  a plug-in window's `AXButton` described exactly "Close", and by moving the window. The same title
  bar holds "Bypass On/Off" (it bypasses the plug-in's audio), "Pin/Unpin window" and "Close all
  plugins windows" (it would close pinned ones too): never press those, and never match by position.
  A pinned window is never closed. A window that opened after a change is never closed for it. One
  press per window per appearance, never a retry loop; a window is placed once when it opens and
  never dragged back. Showing the new rack's plug-in is one overview-and-back per rack change, after
  the move has settled, only on the Rack page and only for a non-Waves selection; if SuperRack does
  not show it, say so and leave it.
- **SuperRack's log is read-only too.** `SuperRackLogTail` opens it for reading and starts at its end.
- **Off limits:** Waves ProLink (its console link), and decompiling Waves or Yamaha binaries.
- **Testing the plug-in window guard:** `Remora --plugin-windows [--place]` runs only the guard (no
  MIDI port, no OSC), so it runs beside the menu-bar app without restarting it. Drive SuperRack with
  the running Remora's OSC (`/remora/plugin/next`, `/remora/rack/next`, `/remora/overview`) and read
  the windows with `CGWindowListCopyWindowInfo` (layer 8, on screen) — not a screenshot, as plug-in
  windows float over every app. A process started from Claude's shell gets Claude's Accessibility
  grant; Remora.app needs its own.
- **Testing without a desk:** `tools/fake-ql.py` on localhost, with `Remora --headless --dry-run
  --host 127.0.0.1`, which logs the MIDI instead of making a port. Testing against SuperRack needs
  Remora ticked under MIDI In in SuperRack's MIDI Controller, and only ever on a rig that is not in
  a show. SuperRack does not hear a Remora that restarted: every relaunch during a test means
  removing and re-adding its MIDI Controller (docs/PROTOCOL.md), then setting Follow Prg. Changes
  back to None.
- **Testing the UI with computer use:** it does not list menu-bar-only apps. Copy the built app, set
  `LSUIElement` false in the copy's Info.plist, re-sign it and launch that. `main.swift` leaves the
  activation policy to the Info.plist for that reason; keep it so. Quit the other Remora first (they
  share UDP 9020 and the port name). The status item still needs full-screen control.
- **The MIDI source keeps its unique ID** (`MIDISourceUniqueID` in the app's defaults), as Apple asks
  of virtual endpoints, for apps that reconnect by it. SuperRack does not (tested 2026-11-05).
- **One version:** `appVersion` in `Sources/Remora/main.swift`; `scripts/build-app.sh` reads it.
- The menu-bar symbol is an SF Symbol (`fish`), which the licence allows in UI. An app icon must be
  drawn, never an SF Symbol: `scripts/make-icon.swift` draws it and writes `Resources/AppIcon.icns`,
  which `scripts/build-app.sh` copies in. Run it again after changing the drawing.

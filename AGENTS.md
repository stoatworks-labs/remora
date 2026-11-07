# AGENTS.md — Remora

Invariants for anyone (human or agent) changing this repo.

- **The console is read-only.** On the editor port send only `F0 43 3n …` requests;
  `YamahaSysEx.isReadRequest` guards every send and must keep doing so. Over RCP send only `get` and
  `devinfo`, never `set`. Consoles are often mid-show when this runs.
- **SuperRack's files are read-only.** Copy `CurrentSPRKP.dat` and its WAL and read the copy
  (`SuperRackSession`); never open the live database.
- **One MIDI message is one step.** SuperRack steps on every Next/Previous Rack message whatever its
  value, stops at both ends and never reports its rack over MIDI (docs/PROTOCOL.md). Never send a
  127/0 pair for a rack step, and never assume a position the driver did not count to or see. A
  change of rack count forgets the position.
- **SuperRack's window says where it is, within limits.** With Accessibility the driver reads the
  rack's name in SuperRack's top bar (`RackNameReader`, from `PluginWindowGuard`) before a move and
  after landing, once SuperRack has had `settle` to show the last step and two reads agree. A name
  several racks share ("n/a") is not a position. A landing from a seen position that the window
  disagrees with homes and counts once, never more; a counted landing it disagrees with keeps the
  count, and the window is not used for a start until it agrees again. Resync always homes by
  counting. Reading the rack never asks for Accessibility, and with no grant the driver sends exactly
  what a counter sends (a test compares them).
- **No new console or SuperRack fact without a capture.** docs/PROTOCOL.md says what was measured, on
  which firmware and when; add to it when something new is actually run. Do the same for the README's
  status block. Nothing counts as verified because it compiles.
- **Desks and hosts are modules** (docs/ARCHITECTURE.md).
  - **Where they live:** a desk is a console module in RemoraConsoles, a plug-in host a host module
    in RemoraHosts. Neither imports the other.
  - **Reaching the OS:** only through `Platform`. `PortabilityTests` checks RemoraCore,
    RemoraConsoles, RemoraHosts and RemoraEngine. It fails on any import but Foundation, Dispatch,
    Remora's own targets and SuperRack's SQLite3.
  - **Ids:** a module's id is stored in settings.json, so never rename one; an old name goes in
    `legacyIDs`.
  - **Status:** a module is `experimental` until it has run on the real kit (`RegistryTests`).
  - **Old settings files:** a 0.3.1 file must read the same, and saving must keep every one of its
    keys, `consoleKind` included (`ModuleSettingsTests`).
- **Plug-in windows: press only "Close".** `PluginWindowGuard` acts on SuperRack only by `AXPress` on
  a plug-in window's `AXButton` described exactly "Close", by moving the window, and by hiding
  SuperRack itself (`NSRunningApplication.hide()`, as ⌘H). **Never minimise a plug-in window, and
  never close a minimised one:** a Close on a minimised window (its Dock tile's, or SuperRack's own)
  takes the plug-in out of the rack and leaves an empty frame. The same title
  bar holds "Bypass On/Off" (it bypasses the plug-in's audio), "Pin/Unpin window" and "Close all
  plugins windows" (it would close pinned ones too): never press those, and never match by position.
  A pinned window is never closed. A window that opened after a change is never closed for it. One
  press per window per appearance, never a retry loop; a window is placed once when it opens and
  never dragged back. Showing the new rack's plug-in is one overview-and-back per rack change, after
  the move has settled, only on the Rack page and only for a non-Waves selection; if SuperRack does
  not show it, say so and leave it.
- **SuperRack's log is read-only too.** `SuperRackLogTail` opens it for reading and starts at its end.
- **ProLink: interoperability only**, from the Tcl scripts in LAWO's mc² firmware and our own
  captures (docs/PROTOCOL.md); no licence bypass. `ProLinkConsole.commands` is everything Remora may
  send (the rack list, and showing and stepping racks, plug-ins and pages) and guards every send:
  never add a command that changes the audio or the session. One command in flight at a time, and
  one SuperRack at a time.
- **Off limits:** decompiling Waves or Yamaha binaries.
- **Testing the plug-in window guard:** `Remora --plugin-windows [--place]` runs only the guard (no
  MIDI port, no OSC), so it runs beside the menu-bar app without restarting it. Drive SuperRack with
  the running Remora's OSC (`/remora/plugin/next`, `/remora/rack/next`, `/remora/overview`) and read
  the windows with `CGWindowListCopyWindowInfo` (layer 8, on screen) — not a screenshot, as plug-in
  windows float over every app. A process started from Claude's shell gets Claude's Accessibility
  grant; Remora.app needs its own.
- **Testing the driver against SuperRack beside the app:** `Remora --headless --through-app --host
  127.0.0.1` with `tools/fake-ql.py` hands every CC to the running Remora as `/remora/cc`, so SuperRack
  hears it on the app's port with no restart. The test copy leaves plug-in windows to the app's guard.
  The app's count does not see those moves: if it counts from the last move, Resync it afterwards.
- **Testing without a desk:** `tools/fake-ql.py` on localhost, with `Remora --headless --dry-run
  --host 127.0.0.1`, which logs the MIDI instead of making a port. Testing against SuperRack needs
  Remora ticked under MIDI In in SuperRack's MIDI Controller, and only ever on a rig that is not in
  a show. SuperRack does not hear a Remora that restarted: every relaunch during a test means
  removing and re-adding its MIDI Controller (docs/PROTOCOL.md), then setting Follow Prg. Changes
  back to None.
- **Testing ProLink:** `ProLinkTests` drive the console through `TestListener` with a fake
  SuperRack, and `TCPServerTests` over loopback. The real SuperRack only on a rig that is not in a
  show: SuperRack dials Remora (TCP 50002 by default), and its ProLink controller's PORT must be a
  wired Ethernet adapter (docs/PROTOCOL.md).
- **Testing the UI with computer use:** it does not list menu-bar-only apps. Copy the built app, set
  `LSUIElement` false in the copy's Info.plist, re-sign it and launch that. `main.swift` leaves the
  activation policy to the Info.plist for that reason; keep it so. Quit the other Remora first (they
  share UDP 9020 and the port name). The status item still needs full-screen control.
- **The MIDI source keeps its unique ID** (`MIDISourceUniqueID` in the app's defaults), as Apple asks
  of virtual endpoints, for apps that reconnect by it. SuperRack does not (tested 2026-11-05).
- **One version:** `appVersion` in `Sources/Remora/Version.swift`; `scripts/build-app.sh` and the
  backend's `sync-about.py` read it.
- **Generated, do not edit:** `Sources/Remora/StoatworksAbout*.swift` come from
  `stoatworks-backend/scripts/sync-about.py`; `.github/FUNDING.yml` and `.github/ISSUE_TEMPLATE/`
  from the backend's sync scripts; the README block between the `downloads` markers from
  `release/gen-downloads.py`.
- **Releases are local** (`scripts/release.sh`): the Developer ID key never leaves this Mac and the
  repo has no workflows. `scripts/release-lib.sh` is vendored from `stoatworks-backend/release`:
  edit it there.
- The menu-bar symbol is an SF Symbol (`fish`), which the licence allows in UI. An app icon must be
  drawn, never an SF Symbol: `scripts/make-icon.swift` draws it and writes `Resources/AppIcon.icns`,
  which `scripts/build-app.sh` copies in. Run it again after changing the drawing.

# What Remora talks to

Measured, not documented by the makers. Dates are when each fact was last checked.

## Yamaha CL/QL

Tested on a QL1, firmware V5.70a, 2026-11-05.

### RCP (TCP 49280): names only

- SEL presses produce **no** NOTIFY. The complete parameter list (`prminfo` 0–266) has no selection
  parameter, so the selected channel cannot be had from RCP.
- Cue is notified (`NOTIFY set MIXER:Current/Cue/InCh/On <ch> 0 1 "ON"`), and so is the fader bank
  (`QL:Current/FaderBank/Select`, `QL:Current/FaderBank/Bank/Recall`).
- Names: `get MIXER:Current/InCh/Label/Name <i> 0` (72 on the CL frame), `StInCh` (16: L/R halves),
  `Mix` (24), `Mtrx` (8), `St` (3). A QL1 answers `ERROR` for the channels it does not have
  (InCh 33–72 and so on) and keeps the connection.
- Remora sends only `devinfo` and `get`. Never `set`.

Side finding: Companion's yamaha-rcp module 3.5.12 sends `devstatus runmode` about 1,300 times a
second to the desk (53 MB in five minutes).

### Editor port (TCP 50000): the selected channel

Yamaha parameter-change SysEx over TCP, the link QL Editor and StageMix use.

- From the desk: `F0 43 1n 3E 19 …  F7` (a change, or the answer to a request).
  From a client: `F0 43 3n 3E 19 … F7` (a request).
- The desk sends a heartbeat, `F0 43 10 3E 19 7F F7`, every second. Clients never answer it.
- A silent client gets heartbeats only. A client that answers the **first** heartbeat with QL
  Editor's opening (38 read requests, all `0x3n`; in `YamahaSysEx.editorOpening`) then gets every
  parameter change streamed to it. The opening must follow the heartbeat: sent at connect, before
  the first heartbeat, it got no reply.
- A read request is answered at once, opening or not:
  `F0 43 30 3E 19 01 EE EE II II CC CC F7` → `F0 43 10 3E 19 01 EE EE II II CC CC D1 D2 D3 D4 D5 F7`.
- A change: `F0 43 10 3E 19 01 EE EE II II CC CC D1 D2 D3 D4 D5 F7`. Element (two bytes), index (two),
  channel (two, 7-bit), then the value: five 7-bit bytes, big-endian, a signed 32-bit number
  (a fader at −∞ is −32768: `0F 7F 7E 00 00`).
- **Selected channel: element `0x0300`, index `0x12`, channel 0**, any channel type. Index `0x13` is
  the last selected input (not updated when a MIX is selected).
  - Numbering is the CL5 frame whatever the model: InCh 0–71 (a QL1 uses 0–31), ST IN halves 72–87
    (ST IN 1 L = `0x48`), MIX 88– (MIX 1 = `0x58`). Confirmed: ch 1, 5, 17, 25, MIX 1, ST IN 1 L.
    Matrices, stereo and mono (112 up, by the frame's sizes) are not confirmed.
  - SEL on a stereo channel can flick `0x48` → `0x49` → `0x48` within ~150 ms.
  - Remora's own link (opening after the first heartbeat) received SEL presses as they happened:
    ch 1, 5, 17, 18, 22, 25 and ST IN 1 L, 2026-11-05.
- Other elements seen:
  - `0x0309` channel N = input SEL key down/up (paired channels send both); `0x030A` = output SEL key.
  - `0x0609` channel = fader bank: that bank's remembered selection. Recalling a bank restores it, so
    changing bank also changes `0x0300`/`0x12`.
  - `0x055B` index 0 = FaderBank/Select, index 1 = Bank/Recall (the RCP parameters).
  - `0x0035` = channel ON (0/1); `0x0037` = fader level (0.01 dB; channel `0x14` = ch 21).
- QL Editor 5.8.1 refuses V5.70a firmware ("not compatible"), but its link carried the stream all the
  same.

Remora sends only `0x3n` requests: the opening, and a read of `0x0300`/`0x12` at connect and every five
seconds after. `YamahaSysEx.isReadRequest` guards every send.

## Waves SuperRack Performer

Tested on 15.15.12.13 (Build 288878), 2026-11-05, with a CoreMIDI virtual source.

- Its MIDI Controller (Setup › MIDI Controller) has no "select rack N". The rack commands are
  Previous/Next Rack Navigation, Open Rack Tab and Return To Last Overview Tab; plug-ins have
  Previous/Next Plug-in Navigation.
- The only direct way to a rack is the Racks menu (the PRESET* button under the rack name) ›
  Rack Select, a submenu of every rack (user guide, "Racks Menu"). It isn't on MIDI or OSC, so
  reaching it means opening that menu through Accessibility. Not tried: it would put a menu on
  SuperRack's screen, which isn't something to try first during a show.
- **Every message is one step, whatever its value.** CC value 0 steps as well as 127, so a button
  sending 127 then 0 moves two racks.
- **It stops at both ends**: Previous on the first rack stays there, Next on the last stays there.
  No wrap.
- It steps through every rack of the session in order, routed or not ("n/a" racks too). The range is
  the session's rack count, `config_info` row `track_type = 0` → `num_tracks` (16 on Allan's session),
  not the 64 slots the database holds.
- It works on every page (Setup, Overview, Rack); the Rack page shows the new rack's chain.
  Driven by Remora.app on 2026-11-05: follow, OSC select by name and number, Next at the last rack,
  Open Rack, plug-in steps, Overview and Resync all landed where expected.
- 70 messages 20 ms apart: none dropped. Faster spacing not tried.
- **No readback over MIDI.** Nothing in its log on a rack step, and no selected-rack field in the
  session database (`snapshot_chainer.selected_slot` is the selected plug-in slot of each rack).
  Accessibility does show the rack's name (below, "The rack name, for the driver"). Without it the
  driver counts: Previous once per rack lands on rack 1 from anywhere, then Next N − 1 times.
- MIDI Learn stays armed on the last box clicked; further CCs then raise "already assigned" dialogs.
  Closing the MIDI Controller window disarms it.
- **Ports are listed twice only: when SuperRack starts and when a MIDI Controller is added.** A
  source made later (Remora started after SuperRack) is missing from MIDI In. A source that quits and
  comes back is not heard again, even under the same name and the same `kMIDIPropertyUniqueID`:
  Remora's CCs reached its port (a monitor saw all 18) and SuperRack did not move. Unticking and
  ticking it again did not help. Removing the MIDI Controller (Setup › Controllers, its menu ›
  Remove) and adding it again (+ › MIDI Controller) did. The re-added controller kept its mappings
  and its MIDI In ticks, which go by name; Follow Prg. Changes came back as channel 1.
- Plug-in Next/Previous on the Rack page selects the slot and shows the plug-in. After that, Return
  To Last Overview Tab left the selected plug-in open in a floating window on the overview.
- Mappings export and import as `.mrrc` XML (`<MultiRackRemoteControl>`). `SuperRackMapping` writes
  the same bytes SuperRack exports (a test compares them).
- User Keys: 16, stored in `user_keys(key_index, key_action, selection_index, obj_type, obj_index, …)`.
  How to assign one, and what they can do, was not found.

### Third-party plug-in windows

Measured on 15.15.12.13, 2026-11-05, driving SuperRack with Remora's MIDI and reading it through
Accessibility and its log. Plug-ins on the rack: PSE (Waves), De-Feedback, Pro-Q 4 and Pro-C 3 (VST3).

- **One process.** Third-party VST3s run inside SuperRack Performer; there is no plug-in host process.
  Their editors are SuperRack's own windows (CoreGraphics layer 8, above every app), titled
  `<rack>: <plug-in>` ("head 1: De-Feedback").
- **SuperRack keeps a small pool and reuses it.** Selecting another third-party plug-in hides the
  unpinned window and shows a pooled one, retitled. Hidden windows stay in CGWindowList off-screen
  with their old titles; Accessibility lists only the shown ones.
- **What it leaves open:** selecting a Waves plug-in on the same rack, a rack step (by MIDI), and
  Return To Last Overview Tab all left the third-party window open. Nothing reopens it on a rack
  step either: on the Rack page, Next Rack and then Open Rack Tab showed no window for the new rack's
  selected third-party plug-in. Coming to the Rack page from another page (Overview → Open Rack Tab)
  does show it.
- **The pin** (title bar) keeps a window open when SuperRack swaps: pinned De-Feedback stayed while
  Pro-Q 4 opened. Unpinning does not close it.
- **The title bar is SuperRack's, not macOS's.** There is no `AXCloseButton`; the window is an
  `AXDialog` whose children are an `AXStaticText`, `AXCheckBox` "Bypass On/Off", `AXCheckBox`
  "Pin/Unpin window", `AXButton` "Close all plugins windows" and `AXButton` "Close" (descriptions).
  `AXPress` on "Close" closes the window (the log says nothing); selecting the plug-in again
  reopens it. A forum user reports ⌘W does nothing.
- `AXPosition` moves a plug-in window. `AXSize` answers success and changes nothing (Pro-Q 4 stayed
  1350 × 842), so a window cannot be fitted from outside.
- **Notifications:** `AXWindowCreated` when a plug-in window shows (pool or not), then
  `AXUIElementDestroyed` for the one it replaced. The main window's rack-name field posts
  `AXValueChanged`.
- **The current rack's name is readable.** The main window's top bar has an `AXTextField` whose
  value is the rack's name ("head 1", then "head 2" after a MIDI Next Rack), the text field furthest
  left. The six page tabs are untitled `AXCheckBox`es (value 1 = shown). The driver uses it (below).
- **Out of sight, out of reach.** With SuperRack's window on another Space or hidden, Accessibility
  listed none of its windows (not even the main one), so the rack name could not be read.
- **Showing the new rack's plug-in.** Return To Last Overview Tab then Open Rack Tab, 20 ms apart
  (Remora's step spacing), on head 2 with Pro-C 3 selected: the log shows `OVERVIEW1` and `RACK` 37 ms
  apart and Pro-C 3's window opens. SuperRack remembers each floating window's position in the session
  (`snapshot_plugin.fw_posx`, `fw_posy`), so a placed window comes back where it was put.
- **Which plug-in each rack has selected**, from the session database: `snapshot_chainer.selected_slot`
  (1-based like the log; −1 for none; written as it changes), and the chain in `plug` (`slot` 0-based,
  `plugin_name`, `vendor_name`: "Waves" for Waves plug-ins, "FabFilter", "Alpha Labs LLC" … otherwise;
  `plugin_4cc` VXPM for PSE, VS0M/VS1M for the VST3s).
- **Its application log is live** (`~/Library/Logs/Waves Audio/SuperRack PerformerApplication.log`,
  appended across launches, 1.5 MB since October):
  - `Top Bar: select RACK` (also `OVERVIEW1`, `SETUP`): page changes, by mouse or by MIDI.
  - `Top Bar: select rack 2`: a rack picked in the top bar, 1-based. MIDI rack steps write nothing.
  - `<rack> plugin <name> slot <n> select`: every plug-in selection, by mouse or by MIDI Next/Previous
    Plug-in, Waves or not. Opening the Rack page from the overview writes one too.
  - OSC to Remora at 21:44:36.543 → SuperRack's line at .548 → Remora closed the window at .608.

### The rack name, for the driver

Measured on 15.15.12.13, 2026-11-05 22:09 and 22:17–22:20, with `Remora --headless --through-app`
beside Remora.app 0.2.0 (the test copy's MIDI handed to the app as `/remora/cc`, which SuperRack
heard: all 78 of the main run's CCs), and the rack field read every millisecond by a separate
process. From 22:17 on, only the two "n/a" racks were rested on, as a show might have been on;
SuperRack started and ended on head 1, Rack page.

- **The field shows every step.** All 31 rack-changing steps of the 22:17 run appeared in it, in
  order, 4–23 ms after the test copy sent them (median 9 ms, the hop through the app included). A
  clamped step (Previous on rack 1) changes nothing. The driver waits `settle` (0.1 s) after its last
  message, then wants two reads 30 ms apart to agree.
- **It follows MIDI steps on the Overview page too**: at 22:09 SuperRack was on OVERVIEW1, the field
  said "head 1", and after 8 Next it said "Lec".
- **Racks that share a name cannot be told apart.** Both n/a racks read "n/a", and nothing else in the
  main window's Accessibility tree gives the rack's number (the top bar holds the name field, the
  page tabs, the snapshot and session buttons, a clock and meters).
- **Moves, and what counting alone sends** (window reading off, 22:19: 18 and 16, the counter's numbers):

  | Move | Mode | The window said | Sent | Counting alone |
  |---|---|---|---|---|
  | head 1 → Lec (22:09) | count from last, no count yet | head 1 | 8 Next | 24 |
  | head 1 → n/a (3) | home every time | head 1 | 2 Next | 18 |
  | n/a (3) → n/a (8) | home every time | n/a (two racks) | 16 + 7 | 23 |
  | n/a (8) → n/a (3) | count from last, no count yet | n/a | 16 + 2 | 18 |
  | n/a (3) → n/a (8) | count from last | n/a, fits the count | 5 Next | 5 |
  | unseen: 5 Previous through the app, n/a (8) → n/a (3), as a click would be | | | | |
  | → n/a (3) | count from last (believes 8) | head 1 at landing | 5 + 16 + 2 | 5, left on head 1 |
  | n/a (3) → head 1 | count from last | n/a, fits the count | 2 Previous | 2 (16 home every time) |

  Every landing was checked against the field's trace: the "n/a" landed on was reached from "hh 3"
  (rack 8) or from "head 2" / "head 4" (rack 3).
- **One landing the window disagreed with, not explained.** At 22:09, after 8 Previous from Lec, the
  field showed "head 2" (one short) twice 30 ms apart; the driver homed and landed on head 1. Between
  steps 6 and 7, two plug-in window guards (the app's and the test copy's) pressed Close on Lec:
  Pro-C 3. The lag measured later does not account for a lost step; whether SuperRack drops a rack
  step while a plug-in window closes is not established.
- While two homing trips sat on head 1 for 0.38 s and 0.6 s (clamped Previous), Remora.app's
  reopen option (0.35 s settle) sent Return To Overview and Open Rack in the middle of the move. Those
  do not step racks; both moves landed where they should.

### The session database

`/Users/Shared/Waves/SuperRack Performer/Sessions/CurrentSPRKP.dat` (SQLite, WAL). Remora copies the
file and its WAL and reads the copy.

```sql
select num_tracks from config_info where track_type = 0;          -- racks in the session
select o.obj_index, sc.name from snapshot_chainer sc
  join object o on o.id = sc.chainer_id
  where sc.snapshot_id = -1 and o.obj_type = 0 order by o.obj_index; -- rack names, in step order
```

`routes` holds the patching (`src_cluster_type` 10 = device input, cluster 0 = racks, 11 = outputs);
Remora does not use it yet.

## Yamaha DM7 and DM3 (experimental, from documents)

Nothing here has been run against a desk. Sources: the DM7 and DM3 reference manuals, Yamaha's DM7
and DM3 OSC specifications (V1.1.0 and V1.0.0), and the RCP parameter lists that ship with
Companion's Yamaha RCP module (v4.0.1).

- **No documented selected channel.** The OSC is set-only (UDP 49900: `set`, events and scene
  commands, no replies), the MIDI is Control and Program Change only (fader and ON on a DM3), and the
  editor and StageMix protocol isn't published. The RCP lists have gaps (DM7: 101 and 122–155
  missing, highest 217; DM3: 122–144 missing, highest 173), so a selection parameter could be hiding
  in one, but it isn't in what's listed.
- **Cue over RCP (TCP 49280).** `MIXER:Current/Cue/InCh/On <ch> <y>`, and the same for StInCh,
  FxRtnCh, Mix and Mtrx. On a DM7 the second index is Cue A or B. The desk's NOTIFY lines are what
  Remora follows: `NOTIFY set MIXER:Current/Cue/InCh/On 4 0 1 "ON"` is input 5 on cue. Yamaha
  doesn't document NOTIFY; Companion's module parses it on every model.
- **Cue and SEL are tied by a preference:** "[CUE] > [SEL] Link" (channel selection follows cue
  operations). With it on, the channel last cued is the selected one. On a DM3 "[SEND SEL] > [CUE]
  Link" goes the other way.
- **Names:** `MIXER:Current/InCh/Label/Name` and the same under StInCh, FxRtnCh, Mix, Mtrx and St.
  DM3: 16 inputs, 2 stereo inputs, 4 FX returns, 6 mixes, 2 matrices. DM7: 120 inputs (72 on the
  Compact), 48 mixes, 12 matrices. Remora asks `devinfo productname` first and reads that model's
  channels; anything that isn't a DM3 is read as a DM7.
- Editor and StageMix share three connections between them. RCP is a separate port, and Remora
  doesn't take one of those three.

## Yamaha CL (from documents)

Yamaha publishes one "MIDI Parameter Change specification for CL/QL series" (V3.0x, April 2015, the
latest in the zip), so the CL's parameter change messages are the QL's: `F0 43 1n 3E 19 01 …`. The
selection element (0x0300, index 0x12) isn't in the published list, which jumps from element 372 to
724, but every version includes PRM table #23 "CHANNEL SELECT": −1 no assign, 0–71 INPUT 1–72, 72–87
ST INPUT 1L–8R, 88–111 MIX 1–24, 112–119 MATRIX 1–8, 120 ST L, 121 ST R, 122 MONO. That's the
numbering measured on the QL1, so it's very likely the table for the selection. Not yet confirmed on
a CL: whether it sends 0x0300/0x12 on the editor port, answers a request for it, and how no assign
(−1) is encoded.

## Allen & Heath (experimental, from documents)

Nothing here has been run against a desk. Sources: A&H's MIDI protocol documents for the Qu (firmware V1.9),
SQ (V1.5.0), dLive (V1.9) and Avantis (V1.10).

All three take MIDI over TCP on port **51325**; dLive's TLS port (51327) isn't supported, so set
TCP MIDI to No Security there. The streams use running status and send Active Sense (FE) about every
300 ms; Remora drops real-time bytes.

- **Qu.** SysEx header `F0 00 00 1A 50 11 01 00 0N`. Get System State (all call) `F0 00 00 1A 50 11
  01 00 7F 10 00 F7` answers `… 0N 11 BoxID Maj Min F7`, BoxID 1–5 = Qu-16, Qu-24, Qu-32, Qu-Pac,
  Qu-SB, which gives the desk's MIDI channel N as well. Get Name `… 0N 01 CH F7` answers `… 0N 02 CH
  name F7`. PAFL is an NRPN on channel N: `BN 63 CH`, `BN 62 51`, `BN 06 VA`, `BN 26 07`. There's no
  selection message, but the desk's "Sel follows PAFL" ties them. Channels: inputs 0x20–0x3F, ST
  0x40–0x42, FX returns 0x08–0x0B, mixes 0x60–0x66, groups 0x68–0x6B. The Qu takes one TCP MIDI
  connection at a time, so Remora holds it while connected, and reconnects after 5 s with no data.
- **dLive and Avantis.** Header `F0 00 00 1A 50 10 01 00`. Channel types are offsets from the base
  MIDI channel N: inputs N, groups N+1, aux N+2, matrix N+3, FX sends, mains and DCAs N+4 (FX returns
  0x20–0x2F on N+4). Names come from Get Name per type. There's no selection or PAFL message, so no
  follow. Mutes arrive as notes, which makes them learnable controls; soft keys and MIDI Strips set
  to send MIDI arrive the same way.
- **SQ.** NRPN for levels and mutes, and nothing for names or selection. Soft keys can send MIDI
  notes, and MIDI strips use channel N+1.
- Everything Remora sends is a Get Name or the Qu's system state request; `AllenHeathMIDI
  .isReadRequest` refuses the rest.

The dLive/Avantis MIDI Strips send MIDI from fader, rotaries, Mute and PAFL, but not Sel, so the
"follow PAFL" trick needs a desk that reports PAFL as a message, which on these documents is only the
Qu.

## Off limits

Waves' own console link (ProLink, protobuf; DiGiCo, Lawo, Kramer, Midas) is not reversed, and no Waves
or Yamaha binary is decompiled.

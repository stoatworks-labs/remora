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
  (Accessibility does show the rack's name; see below.) So the driver counts: Previous once per rack lands on rack 1 from anywhere, then Next
  N − 1 times.
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
  left. The six page tabs are untitled `AXCheckBox`es (value 1 = shown). Remora's driver does not use
  this yet; it still counts.
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

## Allen & Heath

Not supported for follow. dLive/Avantis MIDI over TCP (51325) has no selection message, and their MIDI
Strips send MIDI from fader, rotaries, Mute and PAFL but not Sel. SQ/Qu/CQ are untested: a capture of
SQ MixPad's traffic is the next step. A&H desks' soft keys and MIDI Strips can already drive Remora's
controls through the MIDI input.

## Off limits

Waves' own console link (ProLink, protobuf; DiGiCo, Lawo, Kramer, Midas) is not reversed, and no Waves
or Yamaha binary is decompiled.

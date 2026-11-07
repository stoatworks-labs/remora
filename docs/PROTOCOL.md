# What Remora talks to

Measured, not documented by the makers. Dates are when each fact was last checked.

## Yamaha CL/QL

Tested on a QL1, firmware V5.70a, 2026-11-05.

### RCP (TCP 49280): names, and the input patch

- SEL presses produce **no** NOTIFY. The complete parameter list (`prminfo` 0–266) has no selection
  parameter, so the selected channel cannot be had from RCP.
- Cue is notified (`NOTIFY set MIXER:Current/Cue/InCh/On <ch> 0 1 "ON"`), and so is the fader bank
  (`QL:Current/FaderBank/Select`, `QL:Current/FaderBank/Bank/Recall`).
- Names: `get MIXER:Current/InCh/Label/Name <i> 0` (72 on the CL frame), `StInCh` (16: L/R halves),
  `Mix` (24), `Mtrx` (8), `St` (3). A QL1 answers `ERROR` for the channels it does not have
  (InCh 33–72 and so on) and keeps the connection.
- **The input patch,** read only while routing is on: `get MIXER:Current/InCh/Patch <i> 0` (72) and
  `MIXER:Current/StInCh/Patch <i> 0` (16: L/R halves). Each is a read-only string of up to 8
  characters, such as `DANTE1`.
  - From the CL/QL parameter list in Companion's yamaha-rcp module (v4.0.1,
    `schemas/CLQL Parameters-1.txt`, a `prminfo` listing). No desk has been asked yet.
  - Remora understands `DANTE<n>` and nothing else, so a channel patched anywhere else is left to
    its name.
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
- 70 messages 20 ms apart: none dropped.
- **2 ms apart, traced message by message** (2026-11-06, Remora.app 0.2.0 sending, its MIDI asked
  for through `/remora/cc`, the rack field read every millisecond by another process): twelve moves
  on the Rack page, homing and counting, 8 to 31 messages each, all landed. Every step showed in the
  field in order; the last one 1–2 ms after its message (up to 5 ms). Five Next from Rack 11, eight
  times at each spacing: 2 ms 16 of 16 (two runs), 3 ms 8 of 8, 1 ms 3 of 8, 0.5 ms 0 of 8. On the
  Overview page 2, 5 and 20 ms all landed. So 2 ms, Remora's default since 0.3.0, is the floor:
  closer, SuperRack drops steps. A sender's first two messages going out 0.5 ms apart lost one the
  same way; Remora's driver waits the full spacing after every message.
- **A page change deafens it to rack steps for a while.** Back to overview or Open rack page (from
  the other page), then five Next from Rack 11, three times each: 3 ms after the page change, three
  or four of the five were lost every time; 10 ms, one after Back to overview (two runs of three)
  and two after Open rack page (all three); 20 ms, none in six; 40, 80 and 150 ms, none. Once, in a
  run's setup, a Previous about 30 ms after Open rack page was lost too. Steps *before* a page change
  are safe at 2 ms (five Next then the page 2 ms later, twelve of twelve). The driver now waits
  `pageGap` (0.1 s) after Back to overview and Open rack page, whatever the step spacing; 0.3.0
  waited only the spacing, so a move straight after the plug-in bounce could come up short (its
  window check would then home and count again).
- **Back to overview is ignored if Open rack page follows within 9 ms.** The bounce (Back to overview,
  then Open rack page), three times each: 2, 5, 6, 7 and 8 ms apart, the log shows only `select RACK`
  and no plug-in window opens; 9 ms, two of three; 10, 12, 15, 20, 50 and 100 ms, every time. So in
  0.3.0 at its 2 ms default the bounce never worked: Remora.app's log on 2026-11-06 shows "SuperRack
  did not show head 1: Pro-Q 4" after each one. `pageGap` covers this too.
- **It comes to the front on every command it takes.** Finder in front, then one Next Rack, Previous
  Rack, Back to overview or Open rack page through Remora: SuperRack was the app in front a second
  later, every time (three of three for Next and Previous). An unmapped CC on the same channel left
  Finder in front. So whenever Remora moves SuperRack, the app someone was typing in loses the
  keyboard to it, and a ⌘Q meant for that app quits SuperRack.
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
  with their old titles; Accessibility lists the shown and minimised ones, not those.
- **They float over every app, with SuperRack in front or not.** Layer 8 is above every normal
  window, so with Chrome or Finder in front a plug-in window still sits on top of it.
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
- **Off screen doesn't stay off screen.** `AXPosition` to 5000,3000 or −3000,3000 answers success
  and Accessibility then reports that position, but WindowServer clamps the window back on screen
  (CGWindowList had it at 353,263). Hiding one that way does not work.
- **`AXMinimized` hides one** (2026-11-06): it is settable, the window goes to the Dock as its own
  tile (an `AXMinimizedWindowDockItem` titled "head 1: Pro-Q 4"), stays in Accessibility's window
  list with its Close and Pin, and comes back where it was when set false. Remora does not use it:
  see the next point.
- **Never press Close on a minimised plug-in window.** `AXPress` on its Close answers success, the
  window stays in the Dock and in the list, and SuperRack takes the plug-in out of it: set back, it
  came up an empty black frame with no Accessibility children (so no Close to press) and stayed when
  SuperRack opened the plug-in again in another pooled window, moving the empty frame aside. A
  minimised window is exposed to that from its Dock tile too. So Remora never minimises a plug-in
  window and never closes a minimised one; to get them out of the way it hides SuperRack instead.
- **Hiding the app takes them all down** (a test app standing in for SuperRack, macOS 26.4.1,
  2026-11-06): `NSRunningApplication.hide()` took off screen both its normal window and one at the
  modal-panel level (CG layer 8, where SuperRack's plug-in windows sit), and `unhide()` brought both
  back. It answered `false` while doing it, so read `isHidden`, not the answer. That test app (AppKit)
  still listed its windows in Accessibility while hidden; SuperRack (Qt) lists none ("Out of
  sight, out of reach", below), so the guard keeps what it knew and takes its first look after as a fresh one. Not yet
  tried on SuperRack itself.
- **Notifications:** `AXWindowCreated` when a plug-in window shows (pool or not), then
  `AXUIElementDestroyed` for the one it replaced. The main window's rack-name field posts
  `AXValueChanged`.
- **The current rack's name is readable.** The main window's top bar has an `AXTextField` whose
  value is the rack's name ("head 1", then "head 2" after a MIDI Next Rack), the text field furthest
  left. The six page tabs are untitled `AXCheckBox`es (value 1 = shown). The driver uses it (below).
- **Out of sight, out of reach.** With SuperRack's window on another Space or hidden, Accessibility
  listed none of its windows (not even the main one), so the rack name could not be read.
- **Showing the new rack's plug-in.** Return To Last Overview Tab then Open Rack Tab, 20 ms apart
  (Remora's step spacing then), on head 2 with Pro-C 3 selected: the log shows `OVERVIEW1` and `RACK`
  37 ms apart and Pro-C 3's window opens. Closer than 9 ms it does nothing (above, "Back to overview
  is ignored"). SuperRack remembers each floating window's position in the session
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
  do not step racks; both moves landed where they should. (On rack 1 a lost Previous changes nothing,
  so this could not have shown the page-change deafness found the next day. It was two processes
  sending: inside one Remora a move is one block on the driver's queue, so the bounce cannot land in
  the middle of it.)

### The session database

`/Users/Shared/Waves/SuperRack Performer/Sessions/CurrentSPRKP.dat` (SQLite, WAL). Remora copies the
file with whichever of its `-wal`, `-shm` and `-journal` files exist, and reads the copy.

```sql
select num_tracks from config_info where track_type = 0;          -- racks in the session
select o.obj_index, sc.name from snapshot_chainer sc
  join object o on o.id = sc.chainer_id
  where sc.snapshot_id = -1 and o.obj_type = 0 order by o.obj_index; -- rack names, in step order
```

`routes` holds the patching, one row per channel. The `src_…` columns say where the audio comes from
and the `dst_…` columns where it goes:
- cluster type 10, index 0, is the audio device's inputs;
- cluster type 0 is a rack, its index the rack's place in the list;
- cluster type 11 is the outputs.

With routing on, Remora reads which device inputs feed each rack:

```sql
select dst_cluster_type_index, src_channel_index from routes
  where src_cluster_type = 10 and src_cluster_type_index = 0 and dst_cluster_type = 0
  order by dst_cluster_type_index, src_channel_index;               -- channels from 0
```

In the copy taken on 2026-11-07 (16 racks) that gave 12 rows. Counting channels from 1:
- racks 1–8 took one input each, inputs 5–12;
- racks 9 and 10 took two each, 13–14 and 15–16;
- racks 11–16 took none.

SuperRack's ProLink rack list said the same that day. The racks' outputs are rows from cluster 0 to
11, which Remora doesn't read.

## Waves SuperRack SoundGrid (not run)

Both SuperRack modules have a SoundGrid edition. It uses these paths, none of them seen in use:

- the app: `com.WavesAudio.SuperRack-SoundGrid`, from the copy installed on the development Mac
  (15.15.12), which has never been started there;
- the session: `/Users/Shared/Waves/SuperRack SoundGrid/Sessions/CurrentSPRK.dat`, with a rollback
  journal (`-journal`) rather than a WAL, as Waves' user guide has it. The reader copies whichever of
  `-wal`, `-shm` and `-journal` exist;
- the log: `~/Library/Logs/Waves Audio/SuperRack SoundGridApplication.log`, named after Performer's
  pattern and not yet seen.

## Waves SuperRack over ProLink (experimental)

ProLink is the link a LAWO mc² console uses to drive SuperRack, through SuperRack's "ProLink LAWO
Console Remote" controller. Remora plays the console's end.

This is interoperability only, built from two sources and nothing else:

- the `waves_osc` Tcl scripts in LAWO's mc² firmware 12.4.0.1 (`waveslib.tcl`, `waves_osc_api.tcl`
  and `config.tcl`; the line numbers below are theirs);
- a run against SuperRack Performer 15.15.12.13 (Build 288878) on 2026-11-07, with a stand-alone
  console written for it.

No licence is bypassed: SuperRack runs as licensed, and the controller is one SuperRack offers.

**Set-up, as run on 2026-11-07:**
- Setup › Controllers › + › ProLink LAWO Console Remote.
- Console IP 127.0.0.1 (SuperRack and the console on one Mac), port 50002, then Assign. 50002 is
  the mc²'s port (`waves_osc_api.tcl:11`).
- The controller's PORT has to be a wired Ethernet adapter; on Wi-Fi it did not connect.
  - The run used a USB Ethernet adapter on an unmanaged switch, with a self-assigned address
    (169.254.136.158). SuperRack dialled the console from that address.
  - The adapter appeared in the PORT list only after SuperRack was restarted.
- Afterwards, clear the controller's assignment. An assigned controller that isn't connected keeps
  dialling its console, about every 750 ms, and logs every try.

**The link** (`waveslib.tcl`):
- SuperRack dials the console, which listens (`waves_osc_api.tcl`, `start`).
- **Every frame** starts with 16 bytes, big-endian:
  - the protocol version (1) and the magic "Wave";
  - the command: 1 Init, 2 HandshakeAck, 3 Close, 4 IAmAlive, 5 OSC;
  - one int32: Init's keepAlive in ms, Close's reason, the OSC message's size, or 0.
- **Init's body** is 28 bytes, then the description:
  - the data format (0, OSC 1.1, the only one);
  - the command set's major and minor version (16 bits each);
  - a 16-byte GUID;
  - the description's size, at most 256.

  keepAlive is 200–60000 ms, or -1 for none (`waveslib.tcl:178`).
- **The handshake:** SuperRack sends its Init, the console answers with its own, and SuperRack sends
  HandshakeAck.
  - The major versions must match, and SuperRack's minor must be at least the console's
    (`waveslib.tcl:198`).
  - The mc² sends 1.0 (`config.tcl:9`), and so does Remora.
- **Keepalive:** both ends send IAmAlive.
  - The mc² drops the link after twice its keepAlive without a frame (`waveslib.tcl:450`).
  - Remora sends IAmAlive at half the shorter keepAlive. It drops the link after three of
    SuperRack's keepAlives and a second.
- **Close** carries a reason (`waveslib.tcl:544`). Among them: 2 KeepAliveTimeout, 5 ConnectTimeout,
  1001 ReceivedBadHeader, 1002 AlreadyConnected, 1003 NotSupportedFormat, 1004
  NotSupportedProtocolVersion and 1006 DisconnectRequestShutdown.
- **Commands** are OSC messages, `/waves.com/remote/<Command>`, whose first argument is an int32 id.
  - SuperRack answers a command with `ResultCommand id result text`: result 0 is OK, and the others
    are in `waveslib.tcl:1036`.
  - It answers a `Get…` with its `Give…`, carrying the same id.
- **One command at a time:** the mc² sends the next only when the last is answered
  (`waves_osc_api.tcl:1150`, `canSendMsg`). Remora does the same, and sends the next anyway after a
  second without an answer.

**What Remora sends:**

| Command | Arguments | What for | Run |
|---|---|---|---|
| `GetRacksInfo` | -1, every rack | the rack list, on connect and on Resync | 2026-11-07 |
| `ShowRack` | an input channel, from 0 | shows the rack that channel feeds (below) | 2026-11-07 |
| `NavigateRack` | 0 next, 1 previous (`waves_osc_api.tcl:1042`) | Next and Previous Rack | answered 2026-11-07; which way it moved is not recorded |
| `NavigatePlugin` | 0 next, 1 previous (`waves_osc_api.tcl:1052`) | Next and Previous Plug-in | answered 2026-11-07; what it did is not recorded |
| `SetViewMode` | 1 normal, 2 rack, 3 overview (`waveslib.tcl:1526`) | Open rack page (2), Back to overview (3) | answered 2026-11-07; what it did is not recorded |

- **Nothing else:** `ProLinkConsole.commands` holds these five, and the console refuses to send any
  other command, so nothing that changes the audio or the session can go.
- **The rack's first input channel:** the mc²'s "hot rack" sends ShowRack with that channel
  (`waves_osc_api.tcl:1062`), and so does Remora.
- **A rack no input feeds:** Remora sends ShowRack on the nearest rack an input does feed, then
  NavigateRack from there. Sent on 2026-11-07 and answered; where it landed is not recorded.
- **Each rack** in a `GiveRackInfo` or `NotifyRacksConfigChanged` is an OSC array of
  `MR_RACK_INFO`'s 11 values (`waveslib.tcl:867`), typed `,isiiiiii(T|F)(T|F)i`:
  - index and name;
  - inputs and outputs;
  - the input and output stem formats;
  - the first input channel and the first output channel (-1 for none);
  - mute and in;
  - the SoundGrid processing group.

**What SuperRack sent on 2026-11-07:**
- **Its Init:** keepAlive 2000 ms, format 0, command set 1.1, described as "Waves SuperRack
  15.15.12.13 Build 288878". It took the console's 1.0.
- **Unasked, straight after the handshake:** NotifySyncStatus, NotifyIOBoxStatus, NotifySGSStatus,
  NotifyRemoteOperation (6, 602), NotifySnapshotDirty, and NotifyRacksConfigChanged with every rack.
- **`GetRacksInfo -1`** was sent at the HandshakeAck, and answered at once with `GiveRackInfo id 16`
  and 16 racks.
  - It went before NotifyRemoteOperation, which the mc² waits for at start-up.
  - Ten racks were fed from input 4 (from 0) on, "Lec" and "mains" with two inputs each.
  - Rack 11 to Rack 16 had no input (-1).
- **`ShowRack 8`** got `ResultCommand id 0 "/waves.com/remote/ShowRack succeeded"`, and SuperRack
  went to the Rack page on "hh 1", the rack input 8 feeds.
- **`NavigateRack 0` and `NavigateRack 1`** got ResultCommand 0 each.

**Remora's module against SuperRack, 2026-11-07,** 11:01 to 11:19:
- **The set-up:** SuperRack Performer 15.15.12.13 and Remora's test build (`--headless`) on one Mac.
  The controller's PORT was a USB Ethernet adapter, and SuperRack dialled from 169.254.150.123.
- **The link:** SuperRack connected and sent the same Init as before. The module's
  `GetRacksInfo -1` listed the same 16 racks.
- **27 commands**, about six seconds apart. Every one was answered, with ResultCommand 0 or
  GiveRackInfo: none was refused, and none went a second unanswered.
  - From the desk: a fake QL's SEL presses on head1, hh1, lec 2 and head4 sent `ShowRack 4`, `8`,
    `12` and `7`, each rack's first input channel. Two channels with no rack sent nothing.
  - From OSC, Select Rack 1: `ShowRack 4`, three times.
  - From OSC, Select Rack 12, which no input feeds: `ShowRack 14` (mains, the nearest rack an input
    feeds), then two `NavigateRack 0`. Twice.
  - From OSC, twice each: Next and Previous Rack, Next and Previous Plug-in, Back to overview and
    Open rack page.
  - Resync: `GetRacksInfo -1`.
- **The end:** SuperRack closed the link, with reason 1000.

**Not run yet:**
- What the module's commands did on SuperRack's screen is not recorded: which way NavigateRack and
  NavigatePlugin went, the views SetViewMode gave, and where a rack no input feeds landed. So the
  module stays experimental.
- A second console dialling in. Remora turns it away with Close 1002.
- SoundGrid.

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

## Yamaha RIVAGE PM (experimental, from documents)

Nothing here has been run against a desk. Sources: the PM parameter list that ships with Companion's
Yamaha RCP module (v4.0.1, `Rivage Parameters-4`), with which that module drives a PM, and Yamaha's
RIVAGE PM OSC Specifications (V1.0.2, firmware V5.00 on).

- **RCP, TCP 49280,** as on a CL/QL or a DM. Yamaha documents OSC for the PM, not RCP. Remora uses
  RCP because it answers `get` and sends NOTIFY lines, which is what Companion's module relies on.
  What a PM answers to `devinfo productname` hasn't been seen.
- **No selected channel.** The parameter list has no selection, and a PM's screens can show up to
  three selected channels, so Remora follows cue, as on a DM. The cue switches are
  `MIXER:Current/Cue/InCh/On <ch> <y>` (288 × 2), `Cue/Mix/On` (72 × 2) and `Cue/Mtrx/On`
  (36 × 2). The second index is cue A or B, and a NOTIFY turning either on is the selection.
- **Names:** `MIXER:Current/InCh/Label/Name` 0–287, `Mix/Label/Name` 0–71 and `Mtrx/Label/Name`
  0–35, read at connect and every 30 s. The list is one size for the whole family, so a smaller
  engine is expected to answer the channels it hasn't got with errors, as a QL1 does.
- Everything Remora sends is a `get` or `devinfo`, as on every Yamaha desk.

## Yamaha CL (from documents)

Yamaha publishes one "MIDI Parameter Change specification for CL/QL series" (V3.0x, April 2015, the
latest in the zip), so the CL's parameter change messages are the QL's: `F0 43 1n 3E 19 01 …`. The
selection element (0x0300, index 0x12) isn't in the published list, which jumps from element 372 to
724, but every version includes PRM table #23 "CHANNEL SELECT": −1 no assign, 0–71 INPUT 1–72, 72–87
ST INPUT 1L–8R, 88–111 MIX 1–24, 112–119 MATRIX 1–8, 120 ST L, 121 ST R, 122 MONO. That's the
numbering measured on the QL1, so it's very likely the table for the selection. Not yet confirmed on
a CL: whether it sends 0x0300/0x12 on the editor port, answers a request for it, and how no assign
(−1) is encoded.

The CL has its own entry, Yamaha CL, marked experimental. It runs the QL's code. When the desk's
product name is a CL's under the QL entry, or a QL's under the CL entry, the status line says so.

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
  - Avantis has its own entry, with the dLive's code. Its V1.10 document gives inputs 1–64 (CH
    00–3F on N), and a base MIDI channel that "cannot exceed 12", 12 by default (so channels 12–16).
    Version 2.0 has 96 inputs, in a document not yet read, so Remora reads 1–64.
  - Learned controls from either entry are named "dLive / Avantis", as in 0.3, so a dLive user's
    controls work under both.
- **SQ.** NRPN for levels and mutes, and nothing for names or selection. Soft keys can send MIDI
  notes, and MIDI strips use channel N+1.
- Everything Remora sends is a Get Name or the Qu's system state request; `AllenHeathMIDI
  .isReadRequest` refuses the rest.

The dLive/Avantis MIDI Strips send MIDI from fader, rotaries, Mute and PAFL, but not Sel, so the
"follow PAFL" trick needs a desk that reports PAFL as a message, which on these documents is only the
Qu.

## Behringer X32 and Midas M32 (experimental, from documents)

Nothing here has been run against a desk. Source: Patrick-Gilles Maillot's unofficial X32/M32 OSC
Remote Protocol (v4.09-02, for firmware 4.0 on). The M32 is taken to behave as the X32.

- **OSC over UDP 10023.** An address sent with no arguments is a read, and the desk answers with
  its value. With an argument it's a set, so Remora never sends one.
- **What Remora asks:**
  - `/info`, answered `,ssss`: server version, server name, console model and console version.
    Remora shows the last two ("X32 4.06");
  - `/-stat/selidx`, answered `,i`, the selected channel: 0–31 channels 1–32, 32–39 aux ins
    1–8, 40–47 FX returns 1L–4R, 48–63 buses 1–16, 64–69 matrices 1–6, 70 main LR and 71
    mono/centre;
  - the names, each answered `,s`: `/ch/01/config/name` to `/ch/32/config/name`, and the same
    under `/auxin/01`–`08`, `/fxrtn/01`–`08`, `/bus/01`–`16`, `/mtx/01`–`06`, `/main/st` and
    `/main/m`. DCAs are left out, as neither desk can select one.
- **Polled, not pushed.** The desk sends its changes to up to four clients that have sent
  `/xremote` in the last ten seconds. Remora takes none of those places:
  - it asks for the selection five times a second;
  - it asks for every name at connect and every 30 s, eight per tick;
  - with no answer for five seconds it reports the desk gone, then asks only `/info`, every two
    seconds, until the desk answers.
- **The guard** (`BehringerOSC.isReadRequest`) passes only those addresses, padded, with no type tag
  or an empty one (`,`). It refuses:
  - any argument (`/` with a string sets any node);
  - `/xremote`, `/-action/*`, `/-prefs/*`, and every other address not on the list.

## Behringer Wing (experimental, from documents)

Nothing here has been run against a desk. Source: Patrick-Gilles Maillot's WING Remote Protocols
(V3.0.5-1, for firmware 3.0.5 on).

- **OSC over UDP 2223.** As on the X32, an address with no arguments is a get.
- **What Remora asks:**
  - `/?`, answered with one string, `WING,<ip>,<name>,<model>,<serial>,<firmware>`. The model is
    ngc-full (a Wing), wing-compact or wing-rack;
  - `/$ctl/$stat/selidx`, the selected channel. A get on a number answers `,sfi` (the text, the
    float and the int), and Remora takes the int;
  - the names, each answered `,s`: `/ch/1/name` to `/ch/40/name`, `/aux/1`–`8`, `/bus/1`–`16`,
    `/main/1`–`4` and `/mtx/1`–`8`.
- **The selection's numbering isn't documented.** Remora assumes the order of the channel counts:
  0–39 channels, 40–47 aux, 48–63 buses, 64–67 mains, 68–75 matrices. The first Wing it meets will
  say whether that's right.
- **Polled, not pushed.** A Wing keeps one OSC subscription (`/*s`), and a new one replaces the old,
  so taking it would knock Companion or another app off the desk. Remora polls, as on the X32, with
  the same timings.
- **The guard** passes only those addresses, with no arguments. It refuses:
  - any argument, and any blob (a blob can carry a native Wing command);
  - `/*s`, `/$ctl/cfg/savenow`, and every other address not on the list.

## Other plug-in hosts (experimental, from documents)

None of these has been run against the host. Each module is built from the documents named under it,
and `tools/fake-host.py` plays the four OSC hosts as those documents describe them. On 2026-11-07
every module followed a fake QL to the right rack: the OSC fakes heard nothing off their host's list,
and the MIDI modules' dry runs logged only listed messages.
Each module sends only what its whitelist lists (`OSCHostSpec.isAllowed`, `MIDIHostSpec.isAllowed`),
checked before every send. A host marked **changes the sound** gets nothing until the user ticks that
they understand, and for those a show of the rack Remora knows the host is on sends nothing, as
showing it again would load it again.

### Ableton Live, through AbletonOSC

AbletonOSC is a Live control surface script by Daniel Jones (MIT, github.com/ideoforms/AbletonOSC),
read at master 0ca6821 (2025-11-19). It needs Live 11 or later (README).

- **Transport:** it listens on UDP 11000 and answers on port 11001 of the address that asked, whatever
  port the request came from (`osc_server.py` 94–98). Listener pushes go to the address of the last
  client that sent anything (`osc_server.py` 160–165), so another OSC client can take them.
- **Remora sends:**
  - `/live/song/get/track_names`: one string per track, regular tracks only, from 0; returns and
    master aren't in it (`song.py` 101–109, `track.py` 15–21);
  - `/live/view/start_listen/selected_track`: the selected track's index at once, as
    `/live/view/get/selected_track i`, and on every change. Asking again replaces the listener and
    sends the index again (`handler.py` 69–85);
  - `/live/view/set/selected_track i`, which selects track i (`view.py` 26–27).
  - Both asks go when the link opens, every 5 s, on Resync, and when `/live/startup` arrives.
- **With a return or the master selected** nothing is pushed: the script's getter can't place it.
- **Sound:** selecting a track only selects it. Live 12's manual (§19.2) says arming selects a track,
  not the reverse.
- **Never:** an address with `*` (the script turns it into a prefix that can reach setters and
  methods, `osc_server.py` 99–123), any other `/set/`, any method (`start_playing`, `delete_track`,
  `undo`, `fire`, …), `/live/device/set/parameter/*`, `/live/midimap/map_cc`, `/live/api/reload`.
- **Later:** routing from `input_routing_type` and `input_routing_channel`.

### Logic Pro

From Apple's Logic Pro User Guide (the PDF for Logic Pro 13; the installed app is 12.3.1).

- **Transport:** MIDI, through key commands: Key Commands › Edit, Learn New Assignment ("Assign key
  commands"). Remora sends CC 20 for **Select Previous Track** and CC 22 for **Select Next Track**
  ("Key commands for Global Commands"), value 127, on its channel (16 unless set), 20 ms apart.
- **No track by number** and nothing comes back, so Remora counts: from where it last left Logic, or
  first back once per typed track, which reaches the first from anywhere in the list. Resync does
  that too. A track picked in Logic itself throws the count.
- **Not documented:** whether a learned message also reaches the selected track ("all incoming MIDI
  goes to the selected track", the Environment chapter); whether Select Previous Track wraps at the
  first track (Remora takes it that it stops); how folders and track stacks are stepped.
- **Sound:** **can change it.** By default the focused track is ready to record, and Auto Record
  Enable can make every selected instrument track ready ("Record to a single track", "Recording
  settings"); live MIDI goes to the selected track.

### MainStage

From Apple's MainStage User Guide 4.3 (the installed app is 4.3.1).

- **Transport:** MIDI. A Program Change selects the patch with that number. By default MainStage
  takes program changes from every connected controller; the Concert Settings Inspector's MIDI tab
  can limit them to one device or port and one channel ("Define the program change message source").
- **Numbers:** a new patch takes the lowest free number. Reset Program Change Numbers in the Patch
  List's Action menu (⌥⇧⌘R) numbers the patches that aren't skipped in list order, from the top;
  skipped patches keep theirs. Two patches with one number select the first ("Set program change and
  bank numbers"). The same page says Bank Select comes first, and that bank changes aren't supported:
  Remora sends none, so 128 patches at most.
- **Range:** MainStage › Settings › MIDI › Program Change Range is 0–127 or 1–128 ("MIDI settings").
  The guide doesn't say whether 1–128 changes which patch a message selects. Remora sends 0 for the
  first typed patch, and its set-up asks for 0–127.
- **Remora sends** Program Change n for typed patch n only, on its channel (1 unless set), and never
  the number it last sent: with Reload Patches from saved state when receiving program change on (the
  same settings page), selecting the patch that's already selected reverts it. A number no patch has
  could go on to a channel strip, with Send unused Program Changes to Channel Strips on (the Concert
  Settings Inspector's MIDI tab, "Send unused program changes to channel strips").
- **Nothing comes back:** no list, no feedback, no OSC. Logic Remote steps patches, over a protocol
  that isn't public.
- **Sound:** **changes it.** A patch is a sound ("Patches in MainStage"); the previous patch's tails
  last for Silence Previous Patch ("Audio settings").

### LiveProfessor

From the LiveProfessor User Manual, updated July 2026 (66 pages).

- **Transport:** OSC over UDP, from Options › Project Options › Osc Control: Enable OSC Control, an
  Input Port it listens on and an Output Port it answers on (p.54). The manual gives no default port;
  Remora starts at 8000.
- **Remora sends** `/Chains/Select i`, counting from 1, and `/Chains/Select/Next` and
  `/Chains/Select/Previous` (pp.56–57).
- **Nothing to read:** no chain list and no chain feedback; only View Sets report (p.58).
- **Never:** `/GlobalSnapshots/*` and `/Command/GlobalSnapshots/*` (a recall restores processing
  state, plug-in settings, routing and gains, p.21), `/Cue/*`, `/Command/CueLists/*`,
  `/Transport/Tempo`, or any other `/Command/*` (pp.55–62).
- **Hazard:** with Enable OSC Triggers on, a cue can be bound to almost any incoming address on the
  same port (pp.34, 39). No cue may use `/Chains/Select`.
- **Sound:** the manual doesn't say; selecting a chain is taken to select only.

### Gig Performer

From Gig Performer 5's online manual (the OSC pages, rackspaces and variations, rackspace
properties, predictive loading) and Gig Performer 3's OSC message list.

- **Transport:** OSC over UDP, Gig Performer Pro only (Options › OSC Setup…). The listening port can
  be changed: Gig Performer 3's was 54344, and 5's screenshots show 54084. Remora starts at 54344.
  Leave Use Lemur augmented OSC messages off.
- **Remora sends** `/GigPerformer/SwitchToRackSpace i`, counting from 0, and
  `/GigPerformer/NextRackSpace` and `/GigPerformer/PrevRackSpace`, which skip variations.
- **Nothing to read:** `ListAllRackspaces`' answer and any feedback are undocumented.
- **Sound:** **changes it.** A rackspace that isn't active doesn't process audio; the old one's tail
  is cut after its Maximum audio tail length (up to 10 s). Switching among loaded rackspaces is
  glitch-free; one not loaded yet can wait.
- **Never:** variation, song, setlist, `/SongPart/*`, `/SetMasterFader`, `/SetGlobalTranspose`,
  `/SetBPM`, `/AdjustBPM`, `/Play`, `/RecordInputs`, `/SetAbletonLinkStatus`, `/TunerView/*`,
  `/Panic` (twice within 500 ms it resets the audio engine), or any widget's handle.

### VSTHost

From VSTHost's manual, V1.58 (2026-09-12). VSTHost runs on Windows (98 to 10; 11 untested).

- **Transport:** OSC, from Engine › Configure › OSC, over UDP (Remora's), TCP or TCP with SLIP; port
  7701 by default (p.73). It never sends unasked, and answers each query back to the sender (p.100).
- **Remora sends** `/performance/num i`, which loads performance i (the range is −1 to 127), and
  `/performance/num` with no argument, which answers the number loaded (p.101): when the link opens,
  on Resync and every 2 s. The answer's layout isn't documented: Remora takes its first number, and
  −1 as no performance.
- **Sound:** **changes it.** A load replaces the whole setup (p.68). Mute On Load, on by default,
  silences the output while it loads (p.69). With Performance › Autosave on, VSTHost saves the current
  performance whenever another loads (p.68).
- **Never:** any other address with an argument: `/engine/*`, `/plugin/n/bypass`, mute, parameter,
  program.
- **Not used:** the MIDI Remote Control Port (Program Change loads a performance, and Next and
  Previous Performance step).

### Steinberg VST Live

From the VST Live Pro 2.0.0 Operation Manual (2024-04-16), the online manual (3.0.61) and the
version history, and answers on Steinberg's forum by VST Live's developer (topics 812630, 969719,
801534, 822317, 862870, 1037975).

- **Transport:** MIDI, from Devices › Actions & Shortcuts. Each action row sets a MIDI In, a MIDI
  Status, Chan From and To, and Data From and To, or learns them (pp.195–199).
- **Remora sends** CC 102 for **Select Song**, with the song's index from 0 as the value, and CC 103
  and CC 104, value 127, for **Next Song** and **Previous Song**, on its channel (1 unless set). That
  the value is the index is the developer's answer; the manual doesn't say. Songs past 128 need Select
  Setlist first: not built.
- **Nothing comes back:** MIDI Out for Actions echoes Select Song only when that action fires.
- **Sound:** **changes it.** Activating a part deactivates the old one (p.52), and each layer sends its
  program change and controller values. Select Layer may only select a layer for editing (p.70), which
  would show without changing the sound: it needs a rig.
- **Never:** volume, pan, layer preset, quick control, transport, panic, cycle, tap tempo, program
  up/down, resend MIDI, preload, setlist or play actions. A layer listening on Remora's port would play
  Remora's messages.

## Dante Controller presets (routing, experimental)

Remora doesn't read Dante from the network. For routing it reads a preset the user saves in Dante
Controller (File › Save Preset) and imports.

The format comes from a preset Dante Controller saved, published as an example in DanteArchitect
(MIT, <https://github.com/Nebensound/DanteArchitect>, `Examples/PresetTemplate.xml`). It agrees with
netaudio's preset reader (Unlicense) and the element names in Dante Controller 4.18.1.1's user guide.

```xml
<preset version="2.1.0">
  <name>Main rig</name>
  <device>
    <name>Rio3224-D2</name>
    <txchannel danteId="1" mediaType="audio"><label>Kick</label></txchannel>
  </device>
  <device>
    <name>QL5</name>
    <rxchannel danteId="1" mediaType="audio">
      <name>01</name>
      <subscribed_channel>Kick</subscribed_channel>
      <subscribed_device>Rio3224-D2</subscribed_device>
    </rxchannel>
  </device>
</preset>
```

- **Each subscription** (an `rxchannel` with `subscribed_*`) becomes a link from the transmit channel
  it names to the receive channel's `danteId`.
  - The transmit channel is found by its device's `name` and one of its `label`s. Dante compares
    both without case, and so does Remora.
  - A `subscribed_device` of "." is the receiving device itself. No saved preset with one has been
    seen.
- **A subscription to a device or label the preset doesn't have** is listed as unresolved, in the
  routing sheet.
- **What the reader refuses,** before parsing: a file over 4 MB, one with a NUL byte (UTF-16, or not
  text), and any DOCTYPE or ENTITY declaration. So nothing a file says can make it expand or fetch
  anything.

**Checked, 2026-11-07:** DanteArchitect's example read as 9 devices and 17 subscriptions, none
unresolved, which matches its 9 `device` and 17 `subscribed_device` elements. The example isn't kept
in this repo; the unit tests use a preset written for them.

## Off limits

No Waves or Yamaha binary is decompiled. ProLink, Waves' console link, is used for interoperability
only: Remora's side of it comes from the Tcl scripts in LAWO's mc² firmware and from the run recorded
above, and it bypasses no licence.

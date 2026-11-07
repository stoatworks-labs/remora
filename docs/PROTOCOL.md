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

`routes` holds the patching (`src_cluster_type` 10 = device input, cluster 0 = racks, 11 = outputs);
Remora does not use it yet.

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
| `NavigateRack` | 0 next, 1 previous (`waves_osc_api.tcl:1042`) | Next and Previous Rack | answered 2026-11-07; which way it moved was not watched |
| `NavigatePlugin` | 0 next, 1 previous (`waves_osc_api.tcl:1052`) | Next and Previous Plug-in | no |
| `SetViewMode` | 1 normal, 2 rack, 3 overview (`waveslib.tcl:1526`) | Open rack page (2), Back to overview (3) | no |

- **Nothing else:** `ProLinkConsole.commands` holds these five, and the console refuses to send any
  other command, so nothing that changes the audio or the session can go.
- **The rack's first input channel:** the mc²'s "hot rack" sends ShowRack with that channel
  (`waves_osc_api.tcl:1062`), and so does Remora.
- **A rack no input feeds:** Remora sends ShowRack on the nearest rack an input does feed, then
  NavigateRack from there. Not run.
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

**Not run yet:**
- Remora's module itself. The run above was the stand-alone console, so the module is experimental.
- Which way NavigateRack moves, NavigatePlugin and SetViewMode.
- A second console dialling in. Remora turns it away with Close 1002.
- Reaching a rack no input feeds.
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

No Waves or Yamaha binary is decompiled. ProLink, Waves' console link, is used for interoperability
only: Remora's side of it comes from the Tcl scripts in LAWO's mc² firmware and from the run recorded
above, and it bypasses no licence.

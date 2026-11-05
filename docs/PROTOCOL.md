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
- **No readback.** Nothing in its log on a rack step, and no selected-rack field in the session
  database (`snapshot_chainer.selected_slot` is the selected plug-in slot of each rack). So the only
  way to a given rack is to count: Previous once per rack lands on rack 1 from anywhere, then Next
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

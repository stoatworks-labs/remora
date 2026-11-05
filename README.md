# Remora

A Mac menu-bar app that makes **Waves SuperRack Performer follow the console**: select a channel on a
Yamaha CL or QL and SuperRack goes to that channel's rack. Console keys and knobs, any MIDI control,
and Companion can drive SuperRack's racks, plug-ins and MIDI-learned controls too.

A remora rides along with a shark and goes wherever it goes. Not made or endorsed by Waves or Yamaha.

## How it works

- **The console.** Remora reads the desk and never changes it. The selected channel comes from the
  editor port (TCP 50000, the link QL Editor uses) and channel names from RCP (TCP 49280). Only read
  requests are ever sent. See [docs/PROTOCOL.md](docs/PROTOCOL.md).
- **The rack.** Remora matches the channel's name to a rack name: "head1" finds "head 1", and "lec 1"
  and "lec 2" both find "Lec". The Channels tab overrides any channel.
- **SuperRack.** Its MIDI only offers Next and Previous Rack, and it never says which rack it is on.
  So Remora counts: one Previous per rack lands on rack 1 from anywhere, then it counts Next. With 16
  racks a move takes up to about 0.6 s. The faster "count from the last move" setting skips the trip
  to rack 1. It goes wrong after a mouse click on a rack in SuperRack, until Resync.

## Set up

1. Build: `scripts/build-app.sh` → `dist/Remora.app`. Open it; a fish appears in the menu bar.
   macOS asks for Local Network access: allow it, or the console link fails with "Network is
   down". A rebuilt copy asks again.
2. Settings › Console: the desk's address. The fish fills in when the desk is live.
3. In SuperRack, open Setup › MIDI Controller (the gear):
   - tick **Remora** under MIDI In;
   - **Import** the mapping from Remora's menu › Save SuperRack Mapping… (channel 16, CC 20–25 by
     default). Or MIDI Learn the six navigation commands with the buttons on the SuperRack tab.
4. Select channels on the desk.

**Start Remora before SuperRack.** SuperRack only looks for MIDI ports when it starts and when a
MIDI Controller is added, and it does not hear a Remora that has quit and come back. If Remora was
started late or restarted: Setup › Controllers › MIDI Controller's menu › Remove, then + › MIDI
Controller, and tick Remora again. The mappings survive; Follow Prg. Changes goes back to channel 1,
so set it back to None. Unticking and ticking Remora is not enough.

## Controls

Settings › Controls: add a control, press **Learn**, then press or turn something.

- On a CL/QL, a spare channel's ON key and fader work well.
- On an A&H desk, the soft keys and MIDI Strips work through A&H's MIDI driver, as does any MIDI
  controller.
- Each control can step racks or plug-ins, open the rack page, go back to the overview, resync, or
  switch follow on and off.
- It can also send a CC to SuperRack for anything you MIDI Learn there: User Keys, a plug-in's
  Continuous and Discrete Controls, snapshots. **Send** fires the CC once so SuperRack's learn picks
  it up.

## Companion

Generic OSC to this Mac, UDP 9020:

```
/remora/rack/next   /remora/rack/prev   /remora/rack/select <number or name>
/remora/rack/open   /remora/overview    /remora/rack/resync
/remora/plugin/next /remora/plugin/prev
/remora/follow <0|1>   /remora/follow/toggle
/remora/cc <number> <value>
```

## Command line

```
Remora --racks                 the racks in SuperRack's current session
Remora --mapping               the SuperRack mapping for the saved settings
Remora --probe HOST [SECS]     watch a CL/QL's selection and names, read-only, no MIDI
Remora --headless [--host H] [--for S] [--dry-run]
```

`tools/fake-ql.py` pretends to be a QL1 on localhost. It plays scripted SEL presses and fails if the
client sends anything but a read.

<!-- status -->
## What has been run

As of 2026-11-05:

- **Unit tests:** 22. They use real captures: the QL's selection messages, Allan's channel and rack
  names, and SuperRack's own exported mapping, matched byte for byte.
- **End to end: a QL1 on V5.70a, Remora.app and SuperRack Performer 15.15.12.13**, after a show:
  - SEL presses on the desk streamed to Remora and each found the right rack: head1, head2, lec 1
    (→ Lec), hh2 (→ hh 2); ST IN 1L, ch 5 and ch 1 have no rack and stayed put;
  - SuperRack went to the rack: head 1 on follow, Lec on a SEL press;
  - OSC: select by name ("Lec") and by number, Next, Next at rack 16 (stayed there), Open Rack,
    plug-in Next/Previous on the rack page, Overview, Resync;
  - Resync after SuperRack had been moved elsewhere went back to the selected channel's rack;
  - a restarted Remora was not heard until the MIDI Controller was removed and added again.
- **Against a QL1 on V5.70a**, read-only: connects, sends the opening, reads the selection at connect,
  reads 64 channel names, identifies the QL1, and maps InCh 17 "head1" to rack 1 "head 1".
- **Against `tools/fake-ql.py`:**
  - follows scripted SEL presses with the right MIDI (16 Previous, then the count);
  - "no rack" channels send nothing;
  - reconnects after the heartbeat stops;
  - OSC select by name, next, follow off/on and raw CC all worked;
  - zero non-read messages.
- **SuperRack's stepping, by hand:** measured with a test MIDI port before the app existed (clamping,
  any value steps, 16-rack range, 20 ms spacing).

**Not yet run:**

- **The menu and settings window.** Built, never clicked through.
- **Learned controls** on a real desk or MIDI device (Learn is in the settings window).
- **"Count from the last move"** against the real SuperRack (unit tests only).
- **Raw CC** (`/remora/cc`) into SuperRack: tested against the fake desk only.
- **Companion** itself; OSC was tested with a script.
- **Anything Allen & Heath.**
- **Step spacing below 20 ms**, and the selection numbers above MIX 24.
<!-- /status -->

MIT licence.

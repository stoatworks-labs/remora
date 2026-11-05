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
   down". A rebuilt copy may ask again.
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

## Third-party plug-in windows

SuperRack docks Waves plug-ins in the rack page but opens anything else (FabFilter, De-Feedback …)
in a floating window, and leaves it there when you move to another rack, select a Waves plug-in or go
back to the overview. Settings › SuperRack › Third-party plug-in windows:

- **Close them when the rack, page or plug-in changes.** As a docked plug-in would go. Stepping
  between two third-party plug-ins SuperRack already swaps itself. A window with SuperRack's own pin
  set stays open. Also in the menu.
- **Place them over the rack page's plug-in area** as they open, so they sit where a Waves plug-in
  would. SuperRack will not let them be resized, so a wide one (Pro-Q 4) still covers the output
  column; shrink it with the plug-in's own handle.

Remora needs **Accessibility** for this (System Settings › Privacy & Security › Accessibility), and
reads SuperRack's application log for page and plug-in changes. It presses only the window's own
Close (never its Bypass) and moves windows; nothing else in SuperRack is touched.

- **Show the new rack's plug-in after a rack change.** On the Rack page SuperRack shows nothing for
  a non-Waves plug-in when the rack changes; it only does when the Rack page is opened from another
  page. So when the new rack's selected plug-in is a non-Waves one, Remora sends Back to overview and
  Open rack page, and SuperRack opens its window. The overview flashes for a moment. It waits for a
  move to settle (one bounce for a whole Remora move), and does nothing for a Waves selection, on
  other pages, or when that window is already open. It uses Remora's MIDI port, so SuperRack's MIDI
  Controller needs the mapping as for following.

`Remora --plugin-windows [--place] [--reopen]` runs just this, beside the app (`--reopen` asks the
running app to do the bounce, over its OSC).

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
Remora --plugin-windows [--place] [--reopen] [--watch] [--for S]   only the plug-in window guard
```

`tools/fake-ql.py` pretends to be a QL1 on localhost. It plays scripted SEL presses and fails if the
client sends anything but a read.

<!-- status -->
## What has been run

As of 2026-11-05 (0.2.0):

- **Unit tests:** 37. They use real captures: the QL's selection messages, Allan's channel and rack
  names, SuperRack's own exported mapping (matched byte for byte), and lines from SuperRack's log.
- **Plug-in windows, 2026-11-05, SuperRack 15.15.12.13**, with `Remora --plugin-windows` beside the
  running app and SuperRack driven through its OSC (MIDI), on head 1/head 2 with PSE, De-Feedback,
  Pro-Q 4 and Pro-C 3:
  - closed: the open third-party window when PSE (Waves) was selected (65 ms after the OSC); head 1's
    windows on Next Rack to head 2; head 2's and head 1's on Next Rack to "n/a"; the window on
    Return To Overview;
  - left alone: a pinned De-Feedback through a Waves selection, a rack step and the overview; the
    window SuperRack reopened on Open Rack after the overview;
  - placed: Pro-C 3, De-Feedback and Pro-Q 4 over the plug-in area as each opened (positions read
    back; a capture of the two windows overlaid lines up);
  - SuperRack refused a resize from outside (Pro-Q 4 stayed 1350 × 842).
  - showing the new rack's plug-in (`--reopen`, the bounce sent through the running app's OSC):
    Next Rack to head 2 (Pro-C 3 selected) bounced once and SuperRack opened Pro-C 3, about half a
    second after the move; a Resync-style move to head 2 (16 Previous, 1 Next) bounced once, after
    it settled; to "n/a" (nothing selected) and to head 1 (PSE) it only closed the old window.
  - while SuperRack's window was out of sight (another Space or hidden), Accessibility listed none of
    its windows and the guard did nothing; it picked up again once SuperRack was showing.
- **End to end: a QL1 on V5.70a, Remora.app and SuperRack Performer 15.15.12.13**, after a show:
  - SEL presses on the desk streamed to Remora and each found the right rack: head1, head2, lec 1
    (→ Lec), hh2 (→ hh 2); ST IN 1L, ch 5 and ch 1 have no rack and stayed put;
  - SuperRack went to the rack: head 1 on follow, Lec on a SEL press;
  - OSC: select by name ("Lec") and by number, Next, Next at rack 16 (stayed there), Open Rack,
    plug-in Next/Previous on the rack page, Overview, Resync;
  - Resync after SuperRack had been moved elsewhere went back to the selected channel's rack;
  - a restarted Remora was not heard until the MIDI Controller was removed and added again.
- **The menu and settings window**, clicked through on a copy with a Dock icon (computer use cannot
  reach a menu-bar-only app), its MIDI read off its port:
  - menu: live status lines, Follow off/on, Go to Rack (16 Previous, then the count), Resync, Save
    SuperRack Mapping… (byte for byte SuperRack's export), Show Log (opens Console), About, Quit;
  - every tab; the SuperRack tab's Next rack button (one step); a Channels override saved and
    cleared;
  - a learned control: Learn, then a CC from a test MIDI source. As Next plug-in, a press and release
    (127, 0) sent one step; as Send CC (Press), one CC 30. Send fired the CC once. Delete worked.
  - Fixed on the way: the tabs hid behind a » button on macOS 26, labels and buttons ran off the
    window, the mapping saved as `Remora.mrrc.mrrc`, and the OSC port showed as "9,020".
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

- **Plug-in windows from the menu-bar app** (its toggle, menu item and Accessibility prompt): built,
  not clicked; only the headless guard has run, and the app's own bounce (its driver sending
  Back to overview and Open rack page) has not. **Mouse and touch** selections in SuperRack (only MIDI
  drove it), two copies of one plug-in on a rack, SuperRack restarting under the guard, and
  full-screen or scaled SuperRack windows (the plug-in area was measured at 1850 × 1034).

- **Learned controls from a desk key or a hardware controller.** Only a virtual MIDI source has
  been learned; the Value and On/Off modes have only unit tests.
- **"Count from the last move"** against the real SuperRack (unit tests only).
- **Raw CC** (`/remora/cc`) into SuperRack: tested against the fake desk only.
- **Companion** itself; OSC was tested with a script.
- **Anything Allen & Heath.**
- **Step spacing below 20 ms**, and the selection numbers above MIX 24.
<!-- /status -->

MIT licence.

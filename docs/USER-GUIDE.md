# Remora user guide

Remora is a menu-bar app for the Mac running Waves SuperRack Performer. It watches the mixing desk,
and when you select a channel it puts SuperRack on that channel's rack, so the plug-ins on screen
are the ones on the channel you're working on. It can also turn desk keys, MIDI controllers and
Companion buttons into SuperRack controls, and tidy up the floating windows SuperRack leaves lying
about for non-Waves plug-ins.

It only ever reads the desk. Nothing Remora sends a console can change a parameter, recall a scene
or press a key; there's a check in the code that refuses to send anything but a read request.

> **Where it's got to (0.3.0, 2026-11-05):** used on a live show with a Yamaha QL1 and SuperRack
> Performer 15.15, and run end to end against the same QL1 after a show. The Yamaha CL, DM7 and DM3
> and the Allen & Heath Qu, SQ, dLive and Avantis are new and experimental: built from the makers'
> documents and not yet tried on a desk. The 2 ms step spacing has been used on a live show and,
> since, traced step by step against SuperRack. More Yamaha and Allen & Heath desks are coming. If you try one, I'd like to
> hear how it went: <https://stoatworks-labs.com/feedback/>.

![Remora's Console settings, following a QL5](screenshots/settings-console.png)

## Install

Download the DMG from the [releases page](https://github.com/stoatworks-labs/remora/releases/latest)
and drag Remora to Applications. It's signed and notarised, so it opens without a Gatekeeper warning.
It needs macOS 13 or later.

Open it and a fish appears in the menu bar. macOS asks for **Local Network** access the first time
Remora talks to the desk: allow it, or the link fails with "Network is down".

To build it yourself: `scripts/build-app.sh` makes `dist/Remora.app`.

## Connecting the desk

Settings › Console: pick the desk, type its IP address and press **Connect**. The status line says
what Remora can see: the model, how many channel names it has, and the selected channel and the rack
it found. The fish in the menu bar fills in when the desk is live.

### Yamaha CL and QL

Nothing to set on the desk. Remora connects to two ports: the editor port (TCP 50000, the same link
CL/QL Editor uses) for the selected channel, and RCP (TCP 49280) for channel names. Press SEL and
Remora follows. It's been run on a QL1 on firmware V5.70a. Yamaha publishes one MIDI specification
for the CL and QL, so a CL should behave the same, but I haven't had one to try.

### Yamaha DM7 and DM3 (experimental)

Yamaha doesn't document any way to read the selected channel on a DM, so Remora follows cue instead.
On the desk, turn on **[CUE] > [SEL] Link** in Setup › Preferences, so that cueing a channel selects
it too. Then the channel you cue is the rack you get. Names come from the desk over RCP (TCP 49280).
Remora asks the desk which model it is and reads that model's channels. There are no learned
controls from a DM yet.

### Allen & Heath Qu (experimental)

The Qu doesn't say which channel is selected, but it does say which one is on PAFL. On the desk,
turn on **Sel follows PAFL** (Setup › Audio › PAFL), then PAFL a channel to follow it. Remora talks
to the Qu's MIDI over TCP (port 51325), reads the channel names and works out the model and the
desk's MIDI channel itself. The Qu only takes one TCP MIDI connection at a time, so while Remora is
connected nothing else can use it.

### Allen & Heath dLive and Avantis (experimental)

These don't send a selected channel or PAFL over MIDI, so Remora can't follow them. It reads their
channel names, and their soft keys and MIDI Strips, set to send MIDI, come in as controls you can
learn (see Controls, below), so a soft key per rack with **Go to rack** is the next best thing. Set
the desk's MIDI channel in Remora to match Utility › Control › MIDI. Remora uses port 51325 without
TLS, so set TCP MIDI to No Security.

### Allen & Heath SQ (experimental)

The SQ's MIDI has no channel names and no selection, so Remora can't follow it. Soft keys set to send
a MIDI note, and MIDI strips, come in as learnable controls. Set the desk's MIDI channel in Remora to
match the SQ's; the MIDI strips use the channel one above it, as the SQ does.

![The Console tab with an experimental desk picked](screenshots/settings-console-qu.png)

## Setting up SuperRack

Settings › Plug-in Host picks how Remora drives SuperRack: **SuperRack (MIDI)**, the one that's been
used on a show, or **SuperRack (ProLink)**, experimental (below). Pick the **Edition** too:
Performer, or SoundGrid. SoundGrid keeps its app, session file and log in its own places; Remora
takes those from Waves' guide and the installed app, but it hasn't been tried with SoundGrid yet.

For SuperRack (MIDI):

1. **Start Remora before SuperRack.** SuperRack only looks for MIDI ports when it starts and when a
   MIDI Controller is added.
2. In SuperRack, open Setup › MIDI Controller (the gear) and tick **Remora** under MIDI In.
3. Load the mapping: Remora's menu › **Save SuperRack Mapping…**, then **Import** it in SuperRack's
   MIDI Controller. It's channel 16, CC 20–25 by default; change them on Remora's Plug-in Host tab if
   they clash with something. Or MIDI Learn the six navigation commands in SuperRack with the
   buttons on that tab.
4. Give Remora **Accessibility** (System Settings › Privacy & Security › Accessibility). It works
   without it, but it then has to count racks instead of reading them, which is slower and goes wrong
   if somebody clicks a rack in SuperRack. Settings › Plug-in Host says whether it's reading.

If Remora was started after SuperRack, or restarted, or updated: in SuperRack, Setup › Controllers ›
the MIDI Controller's menu › **Remove**, then + › MIDI Controller, and tick Remora again. The mappings
survive. Follow Prg. Changes goes back to channel 1, so set it back to None. Unticking and ticking
Remora isn't enough. A new copy of Remora may also need its Accessibility switch turned off and on.

### SuperRack over ProLink (experimental)

ProLink is the link a LAWO mc² desk uses to drive SuperRack. With **SuperRack (ProLink)** picked,
Remora plays the desk: SuperRack connects to Remora and lists its racks, and Remora shows a rack in
one command, on the rack's first input channel, as the mc²'s hot-rack key does. Nothing is counted
and there's no MIDI port to set up. A rack that no input feeds is reached by Next or Previous Rack
from the nearest rack that has one.

1. Settings › Plug-in Host: pick **SuperRack (ProLink)**. Remora listens on TCP 50002; change it on
   the same tab if something else has that port.
2. In SuperRack, Setup › Controllers › + › **ProLink LAWO Console Remote**. The console IP is the
   Mac running Remora (127.0.0.1 if it's the same Mac), the port Remora's. Press Assign.
3. Its **PORT** must be a wired Ethernet adapter: on Wi-Fi SuperRack didn't connect at all. An
   adapter plugged in after SuperRack started only shows up in that list once SuperRack restarts.

The Plug-in Host tab says when SuperRack has connected, and lists its racks. Remora takes one
SuperRack at a time. The plug-in window options work as they do over MIDI, except showing the new
rack's plug-in, which needs the MIDI port. A **Send CC to SuperRack** control needs SuperRack (MIDI)
too: ProLink carries no MIDI.

The protocol comes from the scripts in LAWO's mc² firmware, and a test link was run against
SuperRack Performer 15.15 before the module was built. The module itself hasn't met SuperRack yet.

![The Plug-in Host tab with SuperRack (ProLink) picked](screenshots/settings-host-prolink.png)

## How a channel finds its rack

Remora matches the channel's name on the desk to a rack's name in SuperRack, ignoring case,
spaces and punctuation: "head1" finds "head 1" and "vox 2" finds "Vox 2". A channel that's a rack's
name plus a number finds that rack when no other rack has the name, so "lec 1" and "lec 2" both find
"Lec". Racks called "n/a", or nothing, are never matched. The Channels tab lists every named channel beside the rack it found, and marks the
selected one. Pick a rack there to override a channel by hand (the MC's mic sharing the lectern's
rack, say).

When a channel has no rack, Remora can leave SuperRack where it is or go back to its overview
(Settings › Console). "Follow the console's selected channel" switches following off without disconnecting;
it's in the menu too.

![The Channels tab](screenshots/settings-channels.png)

## How fast a move is

SuperRack's MIDI has no "go to rack 8". It has Next Rack and Previous Rack, one step a message, and
it never says which rack it's on. So Remora reads the rack's name in SuperRack's top bar, works out
how many steps it is from there, and sends them 2 ms apart. Across a 16-rack session that's about
30 ms of MIDI. The racks in between still flash past on SuperRack's screen.

After every move Remora reads the window again. If SuperRack isn't on the rack it should be, Remora
goes back to rack 1 and counts, once. Racks that share a name (several "n/a") can't be told apart, so
from one of those it counts too.

Without Accessibility it always counts: "Back to rack 1 first, every time" is safe whatever anyone
clicks; "Count from the last move" is quicker, but a mouse click on a rack in SuperRack throws it
until you press **Resync**.

The 2 ms spacing is new in 0.3.0, and it's the floor: traced against SuperRack, every step at 2 ms
arrived, and at 1 ms some didn't. If moves come up short, raise "ms between steps" on the Plug-in
Host tab.

SuperRack comes to the front whenever it takes a command from Remora, so the keyboard goes to it
every time the desk moves it. Mind where ⌘Q lands.

![The Plug-in Host tab](screenshots/settings-host.png)

## Controls

Settings › Controls turns any key, knob or fader into a SuperRack control. Add a control, press
**Learn**, then press or turn the thing.

- On a CL or QL, a spare channel's ON key and fader work well, over the desk link.
- On an Allen & Heath desk, soft keys and MIDI Strips set to send MIDI come in over the desk link.
- Any MIDI controller on the Mac works, and so does A&H's MIDI driver.

Each control can step racks or plug-ins, **Go to rack** (pick the rack), open the rack page, go back
to the overview, resync, or switch following on and off. **Send CC to SuperRack** passes a CC on for
anything you MIDI Learn in SuperRack itself: User Keys, a plug-in's controls, snapshots. Press
**Send** to fire it once while SuperRack is learning.

![The Controls tab](screenshots/settings-controls.png)

## Third-party plug-in windows

SuperRack docks Waves plug-ins in the rack page, but anything else opens in a floating window and
stays open when you move to another rack. With Accessibility, Remora can:

- **close them** when the rack, page or plug-in changes, as a docked plug-in would go (a window with
  SuperRack's pin set stays);
- **place them** over the rack page's plug-in area as they open (SuperRack won't let them be resized,
  so a wide one still covers the output column);
- **show the new rack's plug-in** after a rack change, by sending Back to overview and Open rack
  page (over MIDI only), which is what makes SuperRack open it. The overview flashes for a moment.
  0.3.0 did nothing here at the default 2 ms, as SuperRack ignores the overview when the rack page
  follows that fast; 0.3.1 waits 0.1 s after a page change, so it works at the default spacing;
- **hide SuperRack while another app is in front** (0.3.1). Otherwise its plug-in windows sit
  over every other app. When you switch away with one open, Remora hides SuperRack the way ⌘H does;
  the audio carries on. Switch back to SuperRack, or move the desk, and it's all back.

It reads SuperRack's application log to know when the page or plug-in changes, and only ever presses
a window's own Close button (never Bypass) or moves it.

## Companion

Remora listens for OSC on UDP 9020. Use Companion's Generic OSC module, pointed at the Mac:

```
/remora/rack/next   /remora/rack/prev   /remora/rack/select <number or name>
/remora/rack/open   /remora/overview    /remora/rack/resync
/remora/plugin/next /remora/plugin/prev
/remora/follow <0|1>   /remora/follow/toggle
/remora/cc <number> <value>
```

## When it doesn't follow

- **The fish stays hollow:** the desk isn't connected. Check the address, that the Mac and desk are
  on the same network, and that Remora has Local Network access (System Settings › Privacy &
  Security › Local Network).
- **The status line shows the channel but SuperRack doesn't move:** SuperRack can't hear Remora.
  Remove and re-add the MIDI Controller, as above, and check the mapping is loaded.
- **It moves, but to the wrong rack:** look at the Channels tab to see what the name matched, and
  override it. If SuperRack is a rack or two off, give Remora Accessibility, or press Resync.
- **A Qu won't connect:** something else has its TCP MIDI connection. Only one at a time.
- **A dLive won't connect:** TCP MIDI security has to be No Security for Remora.
- **SuperRack (ProLink) never connects:** the controller's PORT has to be a wired Ethernet adapter,
  and its console IP and port have to be Remora's. If another program has the port, the Plug-in Host
  tab says so.
- Menu › **Show Log** opens Remora's log in Console.

## What has been tested

On a QL1 (V5.70a) and SuperRack Performer 15.15.12.13: following SEL presses, channel names, name
matching, the plug-in window guard, the OSC commands, learned controls from a virtual MIDI source,
and the restart behaviour above. Reading the rack from SuperRack's window was traced message by
message against the real SuperRack at 20 ms spacing, and since at 2 ms. Hiding plug-in windows has
only met unit tests so far.

SuperRack over ProLink: before the module was built, a test link was run against SuperRack Performer
15.15.12.13. It connected, read the rack list and showed a rack; SuperRack answered Next and Previous
Rack, but where they went wasn't watched. The module itself has only met unit tests and a loopback
test. SuperRack SoundGrid hasn't been tried.

From documents only, with unit tests: the Yamaha CL, DM7 and DM3, and every Allen & Heath desk.
Learned controls from a real desk key or hardware controller haven't been tried. The
README's status section has the full list.

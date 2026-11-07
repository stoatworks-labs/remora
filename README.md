# Remora

> **AI-assisted project.** This codebase was created with [Claude](https://claude.com/claude-code)
> (Anthropic), directed and reviewed by a human author.

A Mac menu-bar app that makes **Waves SuperRack Performer follow the desk**. Select a channel on a
Yamaha CL or QL and SuperRack goes to that channel's rack, so the plug-ins in front of you are the
ones on the channel you're working on. Desk keys, any MIDI controller and Companion can drive
SuperRack's racks, plug-ins and MIDI-learned controls too.

A remora rides along with a shark and goes wherever it goes. It does not get a say in where that is,
which is the arrangement here as well: Remora reads the desk and never changes it.

> **Status:** it's been used on a live show with a QL1 and SuperRack Performer 15.15, and run end to
> end against the same QL1 after a show. 0.3.0 added Yamaha DM7 and DM3, and Allen & Heath Qu, SQ,
> dLive and Avantis. 0.4.0 adds the Yamaha RIVAGE PM, the Behringer X32 / Midas M32 and the
> Behringer Wing, and nine plug-in hosts besides SuperRack: REAPER, Ableton Live, Logic Pro,
> MainStage, LiveProfessor, Gig Performer, VSTHost, Cantabile and VST Live. All of those are
> experimental: built from the manuals and not yet tried on a desk or in the host. 0.4.0 also drives
> SuperRack over ProLink, which has run against SuperRack Performer 15.15 but not yet on a show. The
> full list of what has and hasn't been run is at the bottom.

![Remora's Console settings, following a QL5](docs/screenshots/settings-console.png)

[![Watch Remora follow a simulated QL5 — a render, 54 seconds](docs/video-thumb.png)](https://www.youtube.com/watch?v=r66hmav1R2Q)

<!-- downloads:start -->

## Download

**[v0.3.1](https://github.com/stoatworks-labs/remora/releases/tag/v0.3.1)** — prebuilt for macOS. Pick your platform:

<details>
<summary><b>macOS</b> — Universal (Apple Silicon + Intel)</summary>

| Build | Download | Size |
| --- | --- | --- |
| Universal (Apple Silicon + Intel) · .dmg disk image | [`remora-0.3.1-macos-universal.dmg`](https://github.com/stoatworks-labs/remora/releases/download/v0.3.1/remora-0.3.1-macos-universal.dmg) | 1.3 MB |

</details>

All builds, checksums and release notes: [github.com/stoatworks-labs/remora/releases](https://github.com/stoatworks-labs/remora/releases).

macOS builds are signed and notarised by Apple, so they open normally — no Gatekeeper warning and no quarantine step.

<!-- downloads:end -->

## Desks

| Desk | Follows | Channel names | Learned controls | Status |
|---|---|---|---|---|
| Yamaha QL | the selected channel (SEL) | yes, over RCP | ON keys, faders, anything on the editor link | run on a QL1 |
| Yamaha CL | the selected channel (SEL) | yes, over RCP | as the QL | experimental: the QL's code, not tried on a CL |
| Yamaha DM7, DM3 | the channel on cue, with **[CUE] > [SEL] Link** on | yes, over RCP | none yet | experimental |
| Yamaha RIVAGE PM | the channel on cue, A or B | yes, over RCP | none yet | experimental |
| Allen & Heath Qu | the channel on PAFL, with **Sel follows PAFL** on | yes | soft keys, any MIDI the desk sends | experimental |
| Allen & Heath dLive, Avantis | no | yes (Avantis: inputs 1–64) | soft keys and MIDI Strips set to send MIDI | experimental |
| Allen & Heath SQ | no | no | soft keys and MIDI strips set to send MIDI | experimental |
| Behringer X32, Midas M32 | the selected channel, asked five times a second | yes | none yet | experimental |
| Behringer Wing | the selected channel, asked five times a second | yes | none yet | experimental |

Yamaha doesn't document a way to read the selected channel on a DM or a PM, and the Qu, SQ and dLive
don't send one either, so those desks follow cue or PAFL instead, or don't follow at all. On a desk
that can't follow, a soft key with **Go to rack** gets you to a rack in one press. An X32 or Wing
pushes its selection only to the few apps subscribed to it, so Remora asks instead and leaves those
places to Companion and the rest. Everything Remora sends any desk is a read request; there's a check
in the code that refuses to send anything else.

More desks are on the way. If yours isn't here, or it's here and doesn't behave,
[let me know](https://stoatworks-labs.com/feedback/).

## Plug-in hosts

| Plug-in host | How Remora gets to a rack | Changes the sound | Status |
|---|---|---|---|
| Waves SuperRack, over MIDI | Next and Previous Rack, counted or read from SuperRack's window | no | run on Performer 15.15, used on a live show |
| Waves SuperRack, over ProLink | one command, as a LAWO mc² desk sends it | no | run on Performer 15.15, each command checked on screen; not yet used on a show |
| REAPER | selects the track through REAPER's web interface, and reads the track names and the selection | no, unless a track is set to arm when selected | experimental |
| Ableton Live, with AbletonOSC | selects the track over OSC, and reads the track names and the selection | no | experimental |
| Logic Pro | the Select Next and Previous Track key commands, learned on Remora's MIDI port and counted | **can**: a selected track may be ready to record | experimental |
| MainStage | a Program Change for the patch | **yes**: a patch is a sound | experimental |
| LiveProfessor | selects the chain, over OSC | no | experimental |
| Gig Performer | switches the rackspace, over OSC (Pro) | **yes** | experimental |
| VSTHost (Windows) | loads the performance, over OSC | **yes** | experimental |
| Cantabile (Windows) | loads the song from the set list, through Cantabile's network server, and reads the set list | **yes**: a song is a sound | experimental |
| Steinberg VST Live | Select Song, a MIDI action | **yes** | experimental |

Pick one in Settings › Plug-in Host. Both SuperRack modules have an **Edition**: Performer or
SoundGrid. SoundGrid has its own app, session file and log, taken from Waves' user guide and the
installed app; it hasn't been run yet.

The other hosts are built from their makers' documents and haven't met the host yet
(docs/PROTOCOL.md). REAPER, Cantabile and Ableton Live (through AbletonOSC, a free script by someone
else) say what they have; for the rest you type the racks in the host's order. Some hosts can only
show a rack by loading it, which changes what is heard: Remora sends those nothing until you tick
that you understand, and picking one turns Follow off. Each host module sends only the messages on
its own list, and none of them changes a fader, a mute, a plug-in or the transport.

Yamaha VST Rack Pro and HOST LIVE were looked at and left out: neither documents a remote command
that shows a rack, only ones that recall scenes or snapshots
([docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §9).

## How it works

- **The desk.** On a CL or QL the selected channel comes from the editor port (TCP 50000, the link QL
  Editor uses) and channel names from RCP (TCP 49280). A DM or a PM uses RCP alone. Allen & Heath
  desks use their MIDI over TCP (port 51325), and an X32 or Wing its OSC (UDP 10023 or 2223). See
  [docs/PROTOCOL.md](docs/PROTOCOL.md).
- **The rack.** Remora matches the channel's name to a rack name: "head1" finds "head 1", and "lec 1"
  and "lec 2" both find "Lec". The Channels tab overrides any channel by hand.
- **Routing** (experimental, off by default). Remora can follow a channel's audio instead of its
  name, to the rack whose input it reaches. It goes from the desk's input patch (read from a CL or
  QL), through the subscriptions in a preset saved by Dante Controller, plus any links you type in (a
  MADI card, a direct out), to the inputs that feed each rack in SuperRack. One rack reached wins over
  the name; an override still wins over both. Remora doesn't read Dante live, and never changes a
  patch or a subscription. Settings › Channels › Routing…; the user guide has the details.
- **SuperRack.** Its MIDI offers Next and Previous Rack and nothing else, and never says which rack
  it's on. With Accessibility, Remora reads the rack's name in SuperRack's top bar and steps straight
  there. After each move it checks that SuperRack shows the rack it went to, and homes and counts once
  if not. Racks that share a name (several "n/a") can't be told apart, so from one of those, and
  without Accessibility, Remora counts: one Previous per rack lands on rack 1 from anywhere, then it
  counts Next. "Count from the last move" skips the trip to rack 1, but without Accessibility it goes
  wrong after a mouse click on a rack in SuperRack, until Resync.
- **SuperRack over ProLink.** SuperRack's "ProLink LAWO Console Remote" controller connects to
  Remora as it would to a LAWO mc² desk. Remora shows a rack in one command, on the rack's first
  input channel, as the mc²'s hot-rack key does, so nothing is counted. A rack no input feeds is
  reached by Next or Previous Rack from the nearest one that has one. There's no MIDI port and no
  session file, so SuperRack can be on another computer (the plug-in window options need it on this
  one). Built from the scripts in LAWO's mc² firmware, and run against SuperRack Performer, each
  command checked on its screen (docs/PROTOCOL.md).

### How fast a move is

SuperRack's MIDI has no "go to rack 8", only one step at a time, so a move can't be truly instant.
What Remora can do is make the steps few and close together. Reading SuperRack's window means a move
is only as many steps as racks between here and there, and the steps now go out 2 ms apart (it was
20 ms), which is as close as the settings allow. Across a whole 16-rack session that's about 30 ms of
MIDI. The racks in between still flash past on SuperRack's screen, briefly.

SuperRack's Racks menu has a Rack Select submenu that goes straight to a rack. It's only reachable
through the menu, by Accessibility, so it would mean Remora opening a menu on SuperRack's screen mid
show. I haven't tried it, and I'm not going to try it for the first time on a live show.

## Set up

1. Download the DMG below (signed and notarised) and drag Remora to Applications, or build it:
   `scripts/build-app.sh` → `dist/Remora.app`. Open it; a fish appears in the menu bar. macOS asks
   for Local Network access: allow it, or the desk link fails with "Network is down". A rebuilt copy
   may ask again.
2. Settings › Console: pick the desk and type its address. The fish fills in when the desk is live.
   On a dLive, Avantis or SQ, set the desk's MIDI channel too (an Avantis's is 12 unless it's been
   changed).
3. In SuperRack, open Setup › MIDI Controller (the gear):
   - tick **Remora** under MIDI In;
   - **Import** the mapping from Remora's menu › Save SuperRack Mapping… (channel 16, CC 20–25 by
     default), or MIDI Learn the six navigation commands with the buttons on the Plug-in Host tab.
4. Optional, and worth it: give Remora **Accessibility** (System Settings › Privacy & Security ›
   Accessibility), so it reads SuperRack's rack instead of only counting. Remora never asks for it
   on its own account; Settings › Plug-in Host says whether it's reading.
5. Select channels on the desk.

**Start Remora before SuperRack.** SuperRack only looks for MIDI ports when it starts and when a MIDI
Controller is added, and it doesn't hear a Remora that has quit and come back. If Remora started late
or was restarted: Setup › Controllers › MIDI Controller's menu › Remove, then + › MIDI Controller,
and tick Remora again. The mappings survive; Follow Prg. Changes goes back to channel 1, so set it
back to None. Unticking and ticking Remora isn't enough. Updating Remora counts as a restart, and a
new copy may need its Accessibility switched off and on again.

### SuperRack over ProLink

Instead of steps 3 and 4:

1. Settings › Plug-in Host: pick **SuperRack (ProLink)**. Remora listens on TCP 50002.
2. In SuperRack, Setup › Controllers › + › **ProLink LAWO Console Remote**. The console IP is the
   Mac running Remora (127.0.0.1 if it's this one), the port 50002 unless you changed it in Remora.
   Press Assign. SuperRack dials once: if it says "Failed to connect", check that Remora is running
   with SuperRack (ProLink) picked, and press Assign again.
3. Its **PORT** has to be a wired Ethernet adapter: on Wi-Fi SuperRack didn't connect. An adapter
   plugged in after SuperRack started only appears there once SuperRack restarts.

The Plug-in Host tab says when SuperRack has connected, and lists its racks. Remora takes one
SuperRack at a time. When you stop using it this way, clear the controller's assignment in
SuperRack: while it's assigned and Remora is away, SuperRack dials again about every 750 ms and logs
each try.

### Other plug-in hosts (experimental)

Instead of steps 3 and 4:

1. Settings › Plug-in Host: pick the host. Its own settings appear below: the address and port of an
   OSC host (127.0.0.1 if it's on this Mac), or the MIDI channel of a MIDI one.
2. Unless it's Ableton Live, which lists its own tracks, type the racks under **Racks**, one per line,
   in the host's order.
3. Follow the **Set up … once** steps at the bottom of the tab: where to switch OSC on in the host,
   or which of Remora's messages to learn.
4. If the tab says showing a rack changes the sound, read why before you tick it. Picking such a host
   turns Follow off; turn it back on in the menu when you're ready.

![The Plug-in Host tab with Gig Performer picked, before the tick](docs/screenshots/settings-host-gigperformer.png)

![The Channels tab: every channel name beside the rack it finds](docs/screenshots/settings-channels.png)

## Controls

Settings › Controls: add a control, press **Learn**, then press or turn something.

- On a CL/QL, a spare channel's ON key and fader work well.
- On an Allen & Heath desk, the soft keys and MIDI Strips, set to send MIDI, come in over the desk
  link. A&H's MIDI driver and any MIDI controller work as well.
- A control can step racks or plug-ins, go to a given rack, open the rack page, go back to the
  overview, resync, or switch follow on and off.
- It can also send a CC to SuperRack for anything you MIDI Learn there: User Keys, a plug-in's
  Continuous and Discrete Controls, snapshots. **Send** fires the CC once so SuperRack's learn picks
  it up.

![The Controls tab](docs/screenshots/settings-controls.png)

## Third-party plug-in windows

SuperRack docks Waves plug-ins in the rack page but opens anything else (FabFilter, De-Feedback …)
in a floating window, and leaves it there when you move to another rack, select a Waves plug-in or go
back to the overview. Settings › Plug-in Host › Third-party plug-in windows:

- **Close them when the rack, page or plug-in changes.** As a docked plug-in would go. Stepping
  between two third-party plug-ins SuperRack already swaps itself. A window with SuperRack's own pin
  set stays open. Also in the menu.
- **Place them over the rack page's plug-in area** as they open, so they sit where a Waves plug-in
  would. SuperRack won't let them be resized, so a wide one (Pro-Q 4) still covers the output column;
  shrink it with the plug-in's own handle.
- **Show the new rack's plug-in after a rack change.** On the Rack page SuperRack shows nothing for a
  non-Waves plug-in when the rack changes; it only does when the Rack page is opened from another
  page. So when the new rack's selected plug-in is a non-Waves one, Remora sends Back to overview and
  Open rack page, and SuperRack opens its window. The overview flashes for a moment. It waits for a
  move to settle (one bounce for a whole Remora move), and does nothing for a Waves selection, on
  other pages, or when that window is already open. It uses Remora's MIDI port, so SuperRack's MIDI
  Controller needs the mapping as for following, and it isn't offered over ProLink. 0.3.0 did
  nothing here at the default 2 ms between steps, because SuperRack ignores Back to overview when
  Open rack page follows that closely; 0.3.1 waits 0.1 s after a page change whatever the spacing,
  so it works at 2 ms.
- **Hide SuperRack while another app is in front** (0.3.1). The plug-in windows sit over every
  other app, even with SuperRack behind it. When you switch to another app with one of them open,
  Remora hides SuperRack, as ⌘H does: all of its windows go, the audio doesn't. Switch back to
  SuperRack and it's all there again. SuperRack also comes to the front whenever it takes a command
  from Remora, so it's back as soon as the desk moves it. Remora used to minimise the windows instead,
  on main only, and stopped: a minimised plug-in window that gets closed (from its Dock tile, or by
  SuperRack) loses its plug-in from the rack.

Remora needs Accessibility for this, and reads SuperRack's application log for page and plug-in
changes. It presses only the window's own Close (never its Bypass) and moves windows; nothing else in
SuperRack is touched.

`Remora --plugin-windows [--place] [--reopen] [--hide]` runs just this, beside the app (`--reopen`
asks the running app to do the bounce, over its OSC).

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
Remora --probe HOST [SECS] [--console KIND] [--midi-channel N]   watch a desk's selection and names, read-only, no MIDI
Remora --headless [--host H] [--for S] [--dry-run | --through-app [PORT]]
Remora --plugin-windows [--place] [--reopen] [--hide] [--watch] [--for S]   only the plug-in window guard
Remora --screenshots DIR       the settings window as PNGs, drawn off screen from demo data
Remora --film DIR              the same, a still per beat of the video
```

`tools/fake-ql.py` pretends to be a QL1 on localhost. It plays scripted SEL presses and fails if the
client sends anything but a read. `fake-rcp.py` (PM, DM7, DM3), `fake-behringer.py` (X32, Wing) and
`fake-allenheath.py` (Avantis, dLive) do the same for the other desks, for `--probe 127.0.0.1
--console <id>`. `fake-host.py` plays LiveProfessor, Gig Performer, VSTHost or Ableton Live with
AbletonOSC for `--headless`, and fails if Remora sends anything off that host's list;
`fake-reaper.py` and `fake-cantabile.py` do the same for REAPER's web interface and Cantabile's
network server. `--through-app` hands the test copy's MIDI to the running Remora as `/remora/cc`,
because SuperRack doesn't hear a MIDI port that appears after it starts.

The code is a core plus a module for each desk and each plug-in host.
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the layout and the plan.

<!-- status -->
## What has been run

As of 0.4.0 (2026-11-07):

- **Desks and plug-in hosts are now modules** (docs/ARCHITECTURE.md), the first step towards more
  of both. Nothing you see should change. This was checked against 0.3.1's build:
  - the fake QL's scripted SEL presses and each OSC command gave the same 130 MIDI messages, in
    the same order;
  - `--racks`, `--mapping` and `--probe` printed the same;
  - the settings window drew the same PNGs, byte for byte;
  - a 0.3.1 settings file reads the same, and saving it keeps every key.
- **SuperRack over ProLink, a second SuperRack module.** Remora plays a LAWO mc² desk's end of
  ProLink and shows a rack in one command. Built from LAWO's mc² scripts and a test link run against
  SuperRack Performer 15.15.12.13 on 2026-11-07 (docs/PROTOCOL.md): the handshake, the rack list,
  ShowRack and NavigateRack all answered, and ShowRack put SuperRack on the right rack. Remora's
  module then ran against the same SuperRack: it connected and listed the racks, and SuperRack
  answered all 27 commands Remora sent, from a fake QL's selections and from OSC. Each did what it
  should on SuperRack's screen, checked in SuperRack's log and in a capture of its window after each
  command:
  - the desk's selections showed head 1, hh 1, Lec and head 4 on the Rack page, and a channel with
    no rack left SuperRack where it was;
  - Next and Previous Rack went one rack forward and one back, and Rack 12, which no input feeds,
    was reached from mains;
  - Next and Previous Plug-in moved the selection along the rack, Back to overview and Open rack
    page gave those pages, and Resync changed nothing on screen.
  - Not run: SoundGrid, a second console, and a show.
- **SuperRack SoundGrid:** an Edition setting for both SuperRack modules, with SoundGrid's paths from
  Waves' guide and the installed app. Not run.
- **The SuperRack tab is now the Plug-in Host tab**, with the host and the edition at the top.
- **Checked again against 0.3.1's build, in the same conditions:**
  - the fake QL's dry run sent the same MIDI, message for message: 130 messages with SuperRack open
    and its window read (partway through), and 67 with it closed, counting only (the final build);
  - `--racks`, `--mapping` and `--probe` printed the same;
  - the other tabs' PNGs differ only in the tab bar, which now says Plug-in Host.
- **Routing (experimental, off by default):** a channel's rack found by following its audio, from
  the desk's input patch (CL and QL, read with `get`), through an imported Dante Controller preset
  and any links typed in, to the inputs that feed each rack (SuperRack's session, or ProLink's rack
  list). Checked:
  - with routing off, the fake QL's dry run sent the same 67 MIDI messages as 0.3.1's build, and
    `--racks`, `--mapping` and `--probe` printed the same;
  - the only picture that changed is the Channels tab's, which has a Routing… button;
  - with routing on, the fake QL got 88 patch reads, all `get`s. It answered 32 of them; its answers
    are made up, in the form Companion's parameter list gives;
  - a preset Dante Controller saved (DanteArchitect's published example) read as 9 devices and 17
    subscriptions;
  - the racks' inputs in a copy of SuperRack's session matched what its ProLink rack list said.
  - Not run: a desk answering the patch reads, and routing in the menu-bar app.
- **More desks (experimental):** the Yamaha RIVAGE PM, the Behringer X32 / Midas M32 and the
  Behringer Wing, from their documents (docs/PROTOCOL.md). The Yamaha CL and Allen & Heath Avantis
  are now entries of their own, on the QL's and the dLive's code. Checked:
  - each ran through `Remora --probe` against a fake desk in `tools/` that answers as its document
    describes. Each followed the scripted selections (cue A and B on the PM) and read the names, and
    none was sent anything but reads. In ten seconds the fake X32 got one `/info`, 45 selection polls
    and each of its 72 names once;
  - a fake X32 that went quiet: five seconds later Remora said the desk was gone, then asked only
    `/info`, every two seconds;
  - a CL5's product name under the QL entry put a note on the status line; under the CL entry it
    didn't;
  - the fake QL's dry run sent the same 67 MIDI messages as 0.3.1's build, and `--racks` and
    `--mapping` printed the same. `--probe` printed the same apart from the desk's new title, "Yamaha
    QL";
  - the only picture that changed is the Console tab's (the desk's title and its note).
  - Not run: any of these desks.
- **More plug-in hosts (experimental):** Ableton Live (through AbletonOSC), Logic Pro, MainStage,
  LiveProfessor, Gig Performer, VSTHost and Steinberg VST Live, from their documents
  (docs/PROTOCOL.md). Each sends only what its own list allows. MainStage, Gig Performer, VSTHost and
  VST Live load what they show, and Logic's selected track may be ready to record, so those five get
  nothing until you tick that you understand. Checked, with a fake QL selecting head1, head2, lec 1,
  vt and head1 again:
  - every host followed to the right rack. The OSC hosts were fakes from `tools/fake-host.py`, which
    heard nothing off their host's list: LiveProfessor got `/Chains/Select` 1, 2, 5, 6, 1, Gig
    Performer `SwitchToRackSpace` 0, 1, 4, 5, 0, VSTHost the same loads but the first (it was already
    on that performance) and a query every 2 s, and Ableton the five selections, with the track names
    and a selection listener asked for every 5 s;
  - in dry runs, MainStage was sent Program Change 0, 1, 4, 5, 0 and VST Live Select Song 0, 1, 4, 5,
    0. Logic was counted: six steps back to the first track, then one, three and one forward, and five
    back;
  - unticked, the Gig Performer and VSTHost fakes heard nothing, not even VSTHost's query, and
    MainStage got no MIDI. The log said why, once;
  - with SuperRack, the fake QL's dry run sent the same 67 MIDI messages as 0.3.1's build, and
    `--racks`, `--mapping` and `--probe` printed as they did before this change. The PNGs are the
    same, plus a new one of the Plug-in Host tab with Gig Performer picked.
  - Not run: any of these hosts.
- **REAPER and Cantabile (experimental),** from REAPER's web interface notes and user guide, and from
  Cantabile's Network Developer Guide and its JavaScript client (docs/PROTOCOL.md). REAPER is asked
  for its tracks every second and shows one by selecting it alone. Cantabile's set list is opened
  once and says when the song changes, and a song is loaded by its place in the list. Both read their
  own racks. Cantabile loads what it shows, so it isn't even connected to until you tick that you
  understand. Checked, with the same fake QL:
  - both followed to the right rack, over TCP, against `tools/fake-reaper.py` and
    `tools/fake-cantabile.py`, which heard nothing off their lists. REAPER selected tracks 1, 2, 5,
    6 and 1, each alone, between its polls. Cantabile loaded items 0, 1, 5, 6 and 0 of a set list
    with a break before the third song, and answered the fake's ping;
  - unticked, the Cantabile fake saw no connection at all. With a password set, the REAPER fake was
    asked only for the track list, and Remora's log said it sends no password;
  - the log now says when the host's link changes, as it does for the desk;
  - with SuperRack, the fake QL's dry run sent the same 67 MIDI messages as 0.3.1's build, and the
    log, `--racks`, `--mapping` and `--probe` came out as before. The PNGs are the same.
  - Not run: REAPER or Cantabile.
- **Not run since the change:** the menu-bar app against a desk or SuperRack.
- **Unit tests:** 204, all passing.

As of 0.3.1 (2026-11-06):

- **2 ms steps, traced against SuperRack Performer 15.15.12.13**, its rack field read every
  millisecond (docs/PROTOCOL.md):
  - twelve moves on the Rack page, 8 to 31 messages each, all landed, and every step showed in
    SuperRack's window, the last 1–5 ms after its message;
  - five Next, eight times at each spacing: 2 ms and 3 ms always landed, 1 ms three times in eight,
    0.5 ms never. 2 ms is the floor.
- **Two 0.3.0 faults, found on the real SuperRack and fixed** (the fix has only met the fake one):
  - the plug-in bounce did nothing at 2 ms, in every try: SuperRack ignores Back to overview when
    Open rack page follows within 9 ms (10 ms and up, every time);
  - a rack step within about 20 ms of a page change is lost (three or four of five at 3 ms, none
    from 40 ms).
  - The driver now waits 0.1 s after Back to overview and Open rack page.
- **Also fixed:** a move asked for straight after the bounce was thrown away (the driver's `send`
  cleared it). Found by the new page-gap test; there since 0.1.
- **SuperRack comes to the front whenever it takes one of Remora's commands** (Next, Previous,
  Overview, Open rack page; an unmapped CC doesn't). Whatever app you were typing in loses the
  keyboard to it.
- **Close on a minimised plug-in window takes the plug-in out of the rack.** Done by hand with a test
  tool on Pro-Q 4's window: it came back an empty frame. So Remora never minimises a plug-in window,
  and never closes one somebody else minimised.
- **Hiding SuperRack while another app is in front:** `NSRunningApplication.hide()` took both
  windows of a test app off screen, including one at the modal-panel level where SuperRack's plug-in
  windows sit, and unhiding brought both back (macOS 26.4.1). It answered `false` while doing it, so
  Remora checks `isHidden` instead. Not yet run against SuperRack itself, which was quit before it
  could be; the guard keeps its windows through a hide, as SuperRack lists none while hidden, on
  reasoning and unit tests only.
- **Unit tests:** 74, all passing.

As of 2026-11-05 (0.3.0):

- **0.3.0, unit tests:** 70 now, all passing.
  - The Allen & Heath parsing runs on bytes built from A&H's MIDI protocol documents: running
    status, NRPN, the Qu's PAFL and names, dLive names by channel type, and a guard that fails any
    message that isn't a read request.
  - The DM's runs on RCP lines built from Yamaha's parameter lists: cue on and off, names by model.
  - A 15-rack move at the new 2 ms spacing finished in under 0.25 s against the fake SuperRack.
  - Settings files from 0.1 and 0.2 still load, learned controls and all, and a saved 20 ms spacing
    moves to 2 ms.
- **0.3.0 at 2 ms between steps:** used on a live show with the QL1 and SuperRack Performer 15.15.
  Nobody was measuring; the message-by-message trace further down was at 20 ms.
- **0.3.0, the screenshots and the video:** both drawn off screen by `Remora --screenshots` and
  `--film` from a made-up show, during a live show on the only Mac with SuperRack on it. Nothing
  connected to a desk or SuperRack, and no window opened. They're the app's own settings window, but
  SuperRack isn't in them.

- **Unit tests (0.2.0):** 53. They use real captures: the QL's selection messages, Allan's channel and rack
  names, SuperRack's own exported mapping (matched byte for byte), and lines from SuperRack's log. The
  driver's window reading runs against a fake SuperRack and its window: a name only one rack has, n/a,
  a renamed rack, a window that lies or will not hold still, and no reader at all (the same MIDI as
  counting, compared message for message).
- **Reading the rack, 2026-11-05, SuperRack 15.15.12.13**, with `Remora --headless --through-app`
  beside Remora.app 0.2.0 (its MIDI through the app's `/remora/cc`) and the rack field traced every
  millisecond; resting only on the two n/a racks, as a show might have been on (docs/PROTOCOL.md):
  - from head 1 to n/a in 2 messages (counting: 18), and head 1 to Lec in 8 (counting: 24);
  - from an n/a rack it homed and counted, and landed right;
  - an unseen move between the two n/a racks was caught at landing (the window said head 1), and it
    homed and landed right where counting alone stayed on head 1;
  - all 31 steps showed in the window, 4–23 ms after they were sent;
  - with the setting off: 18 and 16 messages, the counter's numbers;
  - one landing at 22:09 came up one rack short while a plug-in window was being closed; the fallback
    homed and landed right; the cause is not known.
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
  - with nothing listening, says "connection refused", and "closed by the desk" only when the fake
    stops (until 2026-11-07, a refused connection was mostly called closed by the desk);
  - OSC select by name, next, follow off/on and raw CC all worked;
  - zero non-read messages.
- **SuperRack's stepping, by hand:** measured with a test MIDI port before the app existed (clamping,
  any value steps, 16-rack range, 20 ms spacing).

**Not yet run:**

- **Any desk but the QL1.** The CL, DM7, DM3, RIVAGE PM, Qu, SQ, dLive, Avantis, X32/M32 and Wing
  support is built from the makers' documents (Maillot's, for the X32 and Wing) and has only met unit
  tests and fake desks. The CL speaks the QL's protocol (one Yamaha specification covers both), so it
  ought to just work; the rest are a best reading of the manuals. If you have one, I'd love to hear
  how it goes.
- **Any plug-in host but SuperRack.** REAPER, Ableton Live, Logic Pro, MainStage, LiveProfessor, Gig
  Performer, VSTHost, Cantabile and VST Live are built from their makers' documents and have only met
  unit tests, fake hosts and dry runs.
- **The page gap against the real SuperRack.** The 0.1 s wait after a page change has only run
  against the fake; the measurements say it's ample.
- **Hiding plug-in windows, by Remora** (above), and what SuperRack does when it swaps a hidden
  window for another plug-in's (a click in SuperRack selects the plug-in before Remora can put the
  window back).
- **The App Nap opt-out.** Remora now asks macOS not to throttle its timers (a 2 ms sleep stretched to
  66 ms in a throttled test run). That's built, not measured in the app.
- **Plug-in windows from the menu-bar app** (its toggle, menu item and Accessibility prompt): built,
  not clicked. The app's own bounce ran on 2026-11-06 (Remora.app 0.2.0, its spacing at 2 ms) and
  SuperRack ignored it, as above. **Mouse and touch** selections in SuperRack (only MIDI
  drove it), two copies of one plug-in on a rack, SuperRack restarting under the guard, and
  full-screen or scaled SuperRack windows (the plug-in area was measured at 1850 × 1034).

- **Learned controls from a desk key or a hardware controller.** Only a virtual MIDI source has
  been learned; the Value and On/Off modes have only unit tests.
- **"Count from the last move"** against the real SuperRack without the window (unit tests only).
- **Reading the rack:** a mouse click on a rack in SuperRack (unseen MIDI moves stood in for one),
  SuperRack's window hidden or on another Space during a move (Accessibility then lists nothing, so
  the driver should count), a rack renamed before the session reloads, and Remora.app itself reading
  it: only a copy run from Claude's shell, with Claude's Accessibility grant, has. The settings toggle
  and its status line are built, not clicked.
- **Companion** itself; OSC was tested with a script.
- The CL/QL selection numbers above MIX 24.
<!-- /status -->

## Licence

MIT. Not made or endorsed by Waves, Yamaha, Steinberg, Allen & Heath, Behringer, Midas, LAWO,
Audinate, Apple, Ableton, Audiostrom, Deskew, Hermann Seib, Cockos or Topten Software.

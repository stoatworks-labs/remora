# Remora's architecture

Remora does one thing: when a channel is selected on the desk, it shows that channel's plug-ins in
the plug-in host. It is split into a **core** and two kinds of **module**:

- A **console module** reports:
  - which channel is selected;
  - the channel names and the desk's model;
  - presses Remora can learn;
  - where each channel's audio comes from, if the desk says (stage 3).
- A **plug-in host module** takes "show this rack" and does it the host's way: counted MIDI steps
  for SuperRack today; later a ProLink command, or an OSC message for REAPER. It reports what racks
  the host has, and where it is and what feeds each rack when the host can tell.
- The **core** maps a channel to a rack, holds the settings, takes OSC and Companion commands, and
  runs the UI. It knows no protocol.

> **Where this stands (2026-11-07).** Stage 1 is built:
> - the module API and the registry;
> - the five targets and `PortabilityTests`;
> - today's five desks as console modules;
> - SuperRack's MIDI driver as a host module;
> - the platform protocols.
>
> Nothing a user sees changed. The rest of this document is the agreed plan, built stage by stage
> (§10). Each section says which parts exist.

**What doesn't change:**
- every rule in AGENTS.md;
- the settings file: today's files read the same;
- the OSC addresses;
- the MIDI source's name and unique ID;
- the CLI;
- what a QL1 + SuperRack Performer user sees.

Each stage keeps every test green, and the fake-desk dry run's MIDI log identical line for line
(§10).

## 1. Targets

```
Remora          the app: menu bar, SwiftUI settings, CLI                        macOS only
RemoraEngine    the engine (Bridge) and the registry of every module            Foundation (+ RemoraApple on macOS)
RemoraApple     platform services: Network, CoreMIDI, Accessibility             macOS only
RemoraConsoles  console modules, a folder per maker                             Foundation only
RemoraHosts     host modules and their drivers, a folder per host               Foundation (+ SQLite3)
RemoraCore      module API, platform protocols, settings, mapping, OSC codec    Foundation only
```

- **Dependencies:**
  - RemoraConsoles and RemoraHosts depend on RemoraCore and nothing else. Consoles and hosts never
    see each other.
  - RemoraApple depends on RemoraCore. It also depends on RemoraHosts, for the one protocol
    SuperRack's window guard needs (`PluginWindowPlatform`).
  - RemoraEngine depends on RemoraCore, RemoraConsoles and RemoraHosts. It depends on RemoraApple
    only on macOS, where it picks `ApplePlatform`.
  - The app and the tests depend on all five.
- **Access:** what one target uses of another is `public`. Nothing outside Remora links these
  targets.
- **Everything a module needs from the OS** comes through protocols.
  - **Built:**
    - `Platform` (RemoraCore): a TCP stream (`TCPStream`), Remora's MIDI port (`MIDILink`, a
      `CCSink`) and an OSC receiver (`OSCReceiver`).
    - `PluginWindowPlatform` (RemoraHosts): adds SuperRack's window watcher
      (`PluginWindowWatcher`).
  - **Later:** a UDP socket (X32, Wing and the OSC hosts), and audio-device channel names (routing).
  - **Who implements them:**
    - `ApplePlatform`, in RemoraApple, with the code Remora already had (`TCPLink`,
      `MIDIEndpoint`, `OSCListener`, `PluginWindowGuard`), moved, not rewritten.
    - The tests' `TestPlatform`, which never connects and keeps what would have been sent.
- **A test keeps the core portable.** SwiftPM on macOS lets any target import any SDK framework,
  so the target list alone can't. `PortabilityTests` reads every source file in RemoraCore,
  RemoraConsoles, RemoraHosts and RemoraEngine. It fails on any `import` other than:
  - Foundation and Dispatch;
  - Remora's portable targets;
  - SQLite3, in `RemoraHosts/SuperRack` only.

  An import inside `#if canImport(…)` or `#if os(…)` is allowed. There are two: the engine's
  RemoraApple, and CoreGraphics for SuperRack's window geometry. Nothing has been built off macOS
  yet.
- **Tests:** one test target, `RemoraCoreTests`, imports all five targets, so the existing tests
  didn't move. There are 87.

## 2. Modules

### 2.1 What a module says about itself

```swift
public struct ModuleInfo: Equatable {
    public enum Kind { case console, host }
    public enum Status { case supported, experimental }
    public enum Reach { case local, network }   // hosts: does Remora have to run on the host's computer?
    public enum OS { case macOS, windows, linux }
    public var id: String                // "yamaha.ql", "superrack.midi": stable, it's in settings.json
    public var legacyIDs: [String]       // "yamahaCLQL": 0.1–0.3's consoleKind values
    public var kind: Kind
    public var title: String             // the picker's "Yamaha CL / QL"
    public var product: String           // what logs and menus call it: "SuperRack"
    public var maker: String             // groups the picker
    public var status: Status
    public var about: String             // what it reads, over what, what's unproven
    public var platforms: Set<OS>
    public var reach: Reach
    public var capabilities: Capabilities  // follows, names, needsMIDIChannel
    // later (§5): options: [ModuleOption], actions: [ModuleAction]
}
```

- **`supported`** means run on the real kit, with the firmware and date in PROTOCOL.md.
- **`experimental`** means built from documents or other people's captures and never run against
  the kit. The picker marks it, and its `about` says what is unproven.

The supported modules are the Yamaha QL and SuperRack MIDI. SuperRack ProLink, built in stage 2,
joins them once the module itself has run against SuperRack. Everything else is experimental (§9),
and `RegistryTests` holds the list to that.

### 2.2 Console modules

```swift
public protocol ConsoleModule: AnyObject {
    var onEvent: ((ConsoleEvent) -> Void)? { get set }   // set by the engine before start()
    func start()
    func stop()
}

public enum ConsoleEvent: Equatable {
    case link(ConsoleState)                   // stopped, connecting, waitingForDesk, live, failed(why)
    case namesLink(Bool)
    case model(String)
    case selected(ConsoleChannel)
    case names([ConsoleChannel: String])      // every name the desk has given
    case control(ControlSource, Int32)        // a press Learn can map
    // stage 3: case routes([ConsoleChannel: [Port]])   where each channel's audio comes from
}
```

- **Making one:** a module is made by its registry entry (§2.5), from a `ModuleContext`. The
  context holds the settings, the platform and, for hosts, the MIDI out.
- **Events:**
  - `ConsoleEvent` replaces the six callbacks of `ConsoleLink`, one for one.
  - Today's five links are wrapped by `LinkConsoleModule`, not rewritten. A new desk can be a
    `ConsoleLink` too, or a `ConsoleModule` directly.
  - Events come on the module's own queue. The engine always moves them to the main queue
    asynchronously, because a link can call back from inside its own `stop()`.
- **Later:** `Codable` comes with the remote split (§7), with channels written by their `key`.

Rules every console module keeps:

- **Read-only.**
  - Each module has one pure function that says whether an outgoing message is a read. Today these
    are `YamahaSysEx.isReadRequest`, RCP's `get`/`devinfo` rule and
    `AllenHeathMIDI.isReadRequest`.
  - The module's transport refuses anything else.
  - A test runs every message the module can build through the function.
- **Never take another client's place by default.**
  - X32 pushes to four `/xremote` clients, and Wing to a single OSC subscription.
  - Remora polls instead (§9), and subscribes only if the user asks, with a warning.
- **Channel keys are stable.**
  - `ConsoleChannel` may gain cases (`auxIn`, `bus`, `main`, `dca`) with new keys.
  - The existing keys (`in12`, `stin1L`, `st1`, `mix3`, …) never change, because overrides are
    stored by key.

### 2.3 Plug-in host modules

```swift
public protocol HostModule: AnyObject {
    var onEvent: ((HostEvent) -> Void)? { get set }   // set straight after the module is made
    func start()
    func stop()
    func update(_ settings: Settings)                   // the module takes what is its own
    func perform(_ command: HostCommand)
}

public enum HostCommand: Equatable {
    case show(Int)                    // the rack the engine picked (0-based); the module shows it its own way
    case step(Int)                    // ±1 rack
    case stepPlugin(Int)              // ±1 plug-in
    case overview, openRack
    case resync                       // forget where the host is and find out again
    case cc(number: Int, value: Int)  // a learned control's CC, or /remora/cc, in order with the module's own MIDI
}

public enum HostEvent: Equatable {
    case racks([Rack])                // index, name, label
    case position(Int?)               // where the host is, when the module knows
    case windows(PluginWindowStatus)  // SuperRack's plug-in windows, for the status lines
    case problem(String?)             // e.g. the session can't be read
    case link(HostLink)               // a host that dials in over the network
}

public enum HostLink: Equatable {
    case listening(UInt16)                      // waiting for the host, on this port
    case connecting(peer: String)               // it dialled in, "ip:port"
    case connected(name: String, peer: String)  // its own name for itself
    case failed(String)
}
```

- **Events:**
  - `onEvent` is set before `start()`, so a module can report racks and positions as soon as it
    is made. The screenshots and the tests rely on it.
  - Events may come on any queue. The engine runs them at once if they are already on the main
    queue, and moves them there if not.
- **Later:**
  - the inputs that feed each rack (routing, stage 3);
  - `closePluginWindows`, and `action(String)` for a module's own buttons (§5);
  - `Codable` (§7).

Rules every host module keeps:

- **Show, don't change the sound.** Remora's job is to show plug-ins.
  - Some hosts' only remote "select" loads something: a MainStage patch, a Gig Performer
    rackspace, a Cantabile song, a VSTHost performance, or a VST Live song or layer.
  - Such a module sets `capabilities.showChangesSound`, and its settings say so plainly.
  - The engine sends it nothing until the user ticks that they understand. Follow starts off for
    it.
  - It is only safe where those patches or rackspaces are views onto processing that always runs.
- **A command the host can't do is logged and dropped**, never faked. Examples: ProLink carries no
  MIDI, so a learned control's CC goes nowhere (logged once), and Logic has no plug-in steps.
- **A send whitelist.** A host module's transport sends only the commands it lists, as a console's
  read guard does. `ProLinkConsole.commands` holds ProLink's five: GetRacksInfo, ShowRack,
  NavigateRack, NavigatePlugin and SetViewMode.
- **SuperRack's window rules** (AGENTS.md) live inside the SuperRack modules and nowhere else.
  They reach the guard through `PluginWindowPlatform`, and no other module sees it.
- **`reach` says where the module can run.**
  - A `local` module needs the host's computer: a virtual MIDI source, Accessibility, or a session
    file on disk.
  - A `network` module can drive a host on another computer. ProLink is `network`, because
    SuperRack dials Remora.
- **Overrides are per host.**
  - Today's `overrides` (channel key → rack index) stay where they are. They belong to both
    SuperRack modules, which see the same rack list.
  - Other hosts keep theirs under their own options.

### 2.4 Shared drivers (planned)

Today's `SuperRackDriver` lives in `RemoraHosts/SuperRack`. When a second host needs it, it moves to
`RemoraHosts/Shared` as `StepDriver`, unchanged. `ProLinkConsole` is built (stage 2), in
`RemoraHosts/SuperRack`.

| Driver | What it is | Used by |
|---|---|---|
| `StepDriver` | Today's `SuperRackDriver`: counted Next/Previous with a home, one message per step, re-anchored by a `RackNameReader` sighting. | SuperRack MIDI, Logic, VST Live |
| `ProgramChange` | Absolute select by Program Change number over the MIDI source. | MainStage, VSTHost, VST Live |
| `OSCHost` | Address templates over UDP or TCP, with a send whitelist like the consoles' read guard. | REAPER, Ableton (AbletonOSC), LiveProfessor, Gig Performer, VSTHost |
| `ProLinkConsole` | The console end of ProLink: listen, handshake, keepalive, commands one at a time, rack records. Built. | SuperRack ProLink |

So most host modules are small: their `ModuleInfo`, which driver they use, its defaults and
addresses, and their safety notes.

### 2.5 Registry

- **Lists:** each module target exports a list, `RemoraConsoles.all` and `RemoraHosts.all`.
- **Entries:** an entry (`ConsoleModuleEntry`, `HostModuleEntry`) is a module's `ModuleInfo` plus a
  `make` closure that builds it from a `ModuleContext`.
- **Finding a module:** `ModuleRegistry.standard`, in RemoraEngine, holds both lists and finds an
  entry by id or legacy id.
- **An id this build doesn't know** comes back nil. The engine then says "<id> is not in this
  version of Remora", in the log and the status. It never swaps in another module.
- **Nothing loads at run time**, so the app stays one signed, notarised bundle. Outside programs
  plug in over the wire instead (§7).

Built so far:

| Kind | id | Legacy id | Title |
|---|---|---|---|
| console | `yamaha.ql` | `yamahaCLQL` | Yamaha CL / QL |
| console | `yamaha.dm` | `yamahaDM` | Yamaha DM7 / DM3 |
| console | `allenheath.qu` | `ahQu` | Allen & Heath Qu |
| console | `allenheath.dlive` | `ahDLive` | Allen & Heath dLive / Avantis |
| console | `allenheath.sq` | `ahSQ` | Allen & Heath SQ |
| host | `superrack.midi` | — | SuperRack (MIDI) |
| host | `superrack.prolink` | — | SuperRack (ProLink) |

### 2.6 Adding a module

1. **Pick an id**, such as `maker.model` or the host's name. It is stored in settings.json, so it
   never changes. An old name goes in `legacyIDs`.
2. **Write the module** in its maker's folder in RemoraConsoles or RemoraHosts. It reaches the OS
   only through `Platform`.
3. **Guard it:**
   - a console module gets one pure read guard, and its transport refuses anything else;
   - a host module gets a send whitelist, and the sound gate if showing changes the sound.
4. **Test it:**
   - run the guard on every message the module can build;
   - test its parsing on bytes from the maker's documents or from captures;
   - for a desk, add a fake in `tools/` that fails on any non-read, as `fake-ql.py` does.
5. **Register it:** add its entry to `RemoraConsoles.all` or `RemoraHosts.all`. It is
   `experimental` until it has run on the real kit.
6. **Document it:**
   - a PROTOCOL.md section, marked "experimental, from documents", with its sources;
   - a row in the README's table.

## 3. The engine

The engine is `Bridge`, in RemoraEngine. The name stayed, to save churn.
- **What it holds:**
  - One console module, made from `settings.console`, and one host module, made from
    `settings.pluginHost`.
  - A change of either setting makes a new module. Any other change of settings goes to the host
    module's `update`.
  - Running a main and a spare SuperRack at once is a later step: both would get the same show.
- **What it keeps:** Follow, the no-rack behaviour, Learn and its timing guards, controls, OSC, the
  status and the testing hooks.
- **What moved out:** the session reload timer, into SuperRack MIDI's module. That module also
  starts and stops the plug-in window guard.

```
console module ──ConsoleEvent──▶ engine ──HostCommand──▶ host module
                                 ▲    │                      │
           OSC /remora/*, menu ──┘    └─▶ status, UI ◀──HostEvent
```

The OSC addresses stay as they are, and each maps to a command:

| OSC | Command |
|---|---|
| `/remora/rack/next`, `/remora/rack/prev` (`/previous`) | `step(±1)` |
| `/remora/rack/open` | `openRack` |
| `/remora/overview` (`/remora/rack/overview`) | `overview` |
| `/remora/plugin/next`, `/remora/plugin/prev` (`/previous`) | `stepPlugin(±1)` |
| `/remora/rack/resync` (`/remora/resync`) | `resync` |
| `/remora/rack/select <n or name>` | `show(index)`, a name matched by the engine |
| `/remora/follow <0 or 1>`, `/remora/follow/toggle` | the engine |
| `/remora/cc <n> <v>` | `cc(number:value:)` |

A learned control's action maps to the same commands.

## 4. Mapping a channel to a rack

1. **Override** for the channel; an ST IN R half takes its L half's. Built.
2. **Routing:** stage 3, and off until turned on (§4.1).
3. **Name:** `RackMatcher` (exact, then stem; "n/a" never matches), with ST IN halves matched
   without their L/R. Built.

Stage 3 also adds:
- **On the Channels tab:** for each channel, what each method would pick and which one won. It
  flags channels where routing and names disagree.
- **In the status line:** how the rack was found, e.g. "by routing: Dante QL1 12 → SuperRack in 13".

### 4.1 Routing (stage 3)

```swift
public struct Port: Hashable, Codable {
    public enum Domain: String, Codable {
        case analog, dante, aes67, madi, usb, aes50, adat, aes3, card, soundGrid, coreAudio, other
    }
    public var domain: Domain
    public var device: String       // "QL1", "RIO3224-D2", "Dante Virtual Soundcard"
    public var channel: Int         // from 1
    public var label: String?       // the desk's, Dante's or the interface's name for it
}
```

Three kinds of fact meet in a `PatchGraph`:

- **The desk** (`ConsoleEvent.routes`): each channel's input port, plus its direct out or insert
  send where the desk reports them.
- **The wire between:** links from a sending port to a receiving one.
  - Dante subscriptions.
  - For MADI, USB, AES50 and ADAT, which are point to point: a run of matching channel numbers.
  - A host's Core Audio channel and the same device's network channel, joined the same way, e.g.
    Dante Virtual Soundcard or the SoundGrid driver.
- **The host** (`HostEvent.racks`, with each rack's inputs): which host input feeds each rack.

**How a channel's rack is found:**
- It is the one rack whose input can be reached forward from the channel's own ports: its source,
  the ports upstream of it, and its direct out.
- That covers both kinds of rig: the host on an insert or direct out, and the host fed the same
  stage-box input as the desk.
- One rack reached: mapped by routing.
- None, or several: fall through to names, and the Channels tab says why.

Where the facts come from:

| Side | Source | Status |
|---|---|---|
| Yamaha CL/QL | RCP `MIXER:Current/InCh/Patch` (read-only, e.g. `DANTE1`). `DanteOutPort`, `OmniOutPort` and `SlotOut1–3Port` patches, read with `get`. | Companion's parameter lists; not run |
| Yamaha PM | `InCh/Patch` for banks A and B; `InCh/PatchSelect` for the live bank | Companion's list and Yamaha's OSC spec; not run |
| X32, M32 | `/ch/NN/config/source`, `/config/routing/…`, `/outputs/*/src`, `/-stat/xcardtype` | the X32 OSC document |
| Wing | `/ch/N/in/conn/grp` and `/in`; port names `/io/in/<grp>/<n>/name` | the Wing OSC document |
| A&H, Yamaha DM | nothing; the classic Qu pushes only USB, local or dSNAKE source | documents |
| Dante | an imported Dante Controller preset file, or links the user declares. Remora doesn't read Dante live. | needs a sample preset |
| AES67 | SAP announcements (RFC 2974, UDP 9875) name the streams, not who receives them | standard |
| MADI, USB, AES50, ADAT | declared once as a run, e.g. "QL slot 1 MADI 1–64 → MGB MADI 1–64" | — |
| SuperRack | the session's `routes` table (device input channel → rack, from the copy); ProLink's `startingInputChannelIndex` and `numOfInputs` | session copy read and ProLink run, both 2026-11-07 |
| SuperRack's inputs | Performer: the Core Audio device's channels and names (`kAudioObjectPropertyElementName`). SoundGrid: the session's `device_channel_info` table, which is empty in a Performer session. | Core Audio from the SDK headers; SoundGrid not looked at |
| REAPER | web `GET/TRACK/n/I_RECINPUT` (start channel, plus stereo and multichannel bits) | REAPER's own `main.js` |
| Ableton Live | AbletonOSC `input_routing_type` and `input_routing_channel` (display names) | community |
| The other hosts | nothing readable: the user types the table | — |

Routing reads follow the read-only rule like everything else: they are `get`s.

## 5. Settings and the UI

**The file.**
- **Built:**
  - `console` and `pluginHost`: module ids, written beside the old keys.
  - `consoleKind` is still read, as a legacy id. It is still written while the console has one,
    so 0.3 reading a newer file keeps its desk. A console 0.3 doesn't have writes no
    `consoleKind`, rather than a wrong one.
  - **Reading:** `console` wins, then `consoleKind`, then the QL. An old kind name found in
    `console` is read as its module id.
  - **An id this build doesn't know**, from a newer file, is kept as it is and shown as "not in
    this version". It is never swapped for another module.
  - `superRackEdition` (`performer` or `soundGrid`) and `proLinkPort` (50002): flat keys like the
    MIDI module's, read by both SuperRack modules (stage 2).
- **Unchanged keys:**
  - `consoleHost` and `consoleMIDIChannel`.
  - SuperRack MIDI's flat keys (`midiChannel`, `ccBase`, `stepMilliseconds`, `mode`,
    `sessionPath`, the plug-in window switches, …), so nothing moves for anyone using it today.
    The module reads them through `Settings.driverConfig` and `pluginWindowOptions`.
- **Tests** (`ModuleSettingsTests`): a 0.3.1 file with every key away from its default reads the
  same. Saving it keeps every key and value, and adds only `console`, `pluginHost`,
  `superRackEdition` and `proLinkPort`.
- **Later:**
  - `modules`: `{"<id>": {option: value}}`, for the new modules' options;
  - `routing`: on or off, declared links, imported presets.

**Options** (later).
- A module lists `ModuleOption`s: text, a number with a range and unit, a toggle, a choice, an IP
  address, a port or a path. The app draws them as a form.
- A module that needs more gets a panel of its own, registered in the app by module id. Examples:
  SuperRack MIDI's Learn buttons, the plug-in window options and the mapping export.
- A web UI (§8) would draw the same list.

**Where things appear.**
- **Console tab** (built):
  - the picker lists the registry's consoles and marks the experimental ones;
  - an unknown id gets a "(not in this version)" row;
  - below it, the module's about text, its connection fields and, later, its options;
  - grouping by maker comes when the list grows (stage 4).
- **Plug-in Host tab** (built in stage 2; it was the SuperRack tab):
  - the host picker, marked as the Console tab's is, and an Edition picker for SuperRack;
  - the module's about text, then its panel: SuperRack MIDI keeps its old sections, and ProLink's
    shows the link, the port, the racks and the set-up steps;
  - the plug-in window options, shared by both SuperRack modules; showing the new rack's plug-in
    is MIDI only.
- **Channels tab:** the mapping columns (§4), in stage 3.
- **The menu** (built in stage 2): Go to Rack (from `HostEvent.racks`) and Resync name the host.
  Close Plug-in Windows shows only for SuperRack, and Save SuperRack Mapping only for SuperRack MIDI.
- **The CLI** keeps every flag. `--probe … --console KIND` takes module ids as well as 0.3's kind
  names (built).

## 6. SuperRack: two modules, two editions

- **SuperRack — MIDI** (`superrack.midi`, built) is the code Remora has always had: the counted
  driver, the session copy, the log tail, the window guard and the mapping export.
- **SuperRack — ProLink** (`superrack.prolink`, built in stage 2, experimental until it has run)
  plays the console for SuperRack's "ProLink LAWO Console Remote" controller.
  - **Sources:** interoperability only, from LAWO's mc² firmware scripts (a public download) and
    our own captures (2026-11-07). No licence bypass. AGENTS.md's ProLink line says so.
  - **Showing a rack:**
    - SuperRack dials Remora on TCP 50002 (the `proLinkPort` setting). Remora reads the rack list,
      which includes each rack's first input channel.
    - Remora shows a rack with ShowRack on that channel, as the mc²'s hot-rack key does
      (`waves_osc_api.tcl:1062`).
    - A rack with no input channel is reached with NavigateRack from the nearest rack that has one.
      That route is unproven.
    - Commands go one at a time, the next when SuperRack has answered the last, as the mc² sends
      them (`waves_osc_api.tcl:1150`). A newer move drops the moves still queued.
  - **The other commands:** Next and Previous Rack are NavigateRack 0 and 1, plug-ins
    NavigatePlugin 0 and 1, and the pages SetViewMode 2 (rack) and 3 (overview). Only NavigateRack
    has been answered by SuperRack, and which way it moved wasn't watched.
  - **Where it runs:**
    - It needs no MIDI port and no session file, so SuperRack can be on another computer.
    - The plug-in window guard still works when SuperRack is on this Mac. Showing the new rack's
      plug-in stays MIDI only: it is a bounce through the overview, timed against SuperRack's MIDI.
    - SuperRack's PORT has to be a wired Ethernet interface: on Wi-Fi, SuperRack can't start its
      console client (seen 2026-11-07).
- **Each module has an Edition option** (built in stage 2), Performer or SoundGrid, which picks the
  paths. SoundGrid's come from the guide and the installed app; it hasn't been run.

| | Performer (run) | SoundGrid (from the guide and the installed app; not run) |
|---|---|---|
| App | `com.WavesAudio.SuperRack-Performer` | `com.WavesAudio.SuperRack-SoundGrid` |
| Session | `/Users/Shared/Waves/SuperRack Performer/Sessions/CurrentSPRKP.dat` + `-wal`, `-shm` | `/Users/Shared/Waves/SuperRack SoundGrid/Sessions/`; the guide says `CurrentSPRK.dat` + `-journal` |
| Log | `~/Library/Logs/Waves Audio/SuperRack PerformerApplication.log` | `~/Library/Logs/Waves Audio/SuperRack SoundGridApplication.log`, assumed from Performer's |
| Windows | `C:\Users\Public\Waves\…`; the two guides disagree on the folder | the same |

The session reader copies whichever of `-wal`, `-shm` and `-journal` exist, and reads the copy.

## 7. The remote split (design only)

Remora would run twice in three cases:
- when the desk's control network can't be reached from the host's computer;
- when one desk feeds two hosts (a main and a spare SuperRack);
- when the host runs on Windows.

```
desk side                                         host side (the host's computer)
console module ─▶ link sender ══ TCP 9021 ══▶ "Remora link" console module ─▶ engine ─▶ host module
```

- **The engine runs on the host side**, because most host modules are local: the MIDI source,
  Accessibility, the session file.
- **The desk side** runs a console module and forwards its `ConsoleEvent`s. It accepts nothing
  back, so it stays read-only by construction.
- **The wire** is TCP on port 9021, next to OSC's 9020, carrying newline-delimited JSON.
  - It opens with a hello: `{"remora":1,"role":"console","module":"yamaha.ql","model":"QL1"}`.
  - Then one event per line: `{"selected":"in12"}`, `{"names":{"in12":"Lead Vox"}}`.
  - A keepalive goes every 2 s, and the link is dropped after 6 s without one.
  - The hello carries a shared key, if one is set.
  - Several host sides can take the same desk side.
- **Over OSC**, the same events let anything be a console: Mixing Station, a Companion trigger, a
  script on a Pi.
  - The addresses: `/remora/console/selected ,s <key> [s <name>]`, `/remora/console/names …`.
  - That is also how outside code plugs in: over the wire, never loaded into Remora.
- **The network host modules need no split.** ProLink (SuperRack dials Remora), REAPER, Ableton,
  LiveProfessor, Gig Performer, VSTHost and Cantabile already work across a network.

## 8. Windows and Linux (design only)

Only the platform services and the app would change. `PortabilityTests` holds the core, consoles,
hosts and engine to Foundation, but none of them has been built on either system yet.

| Service | macOS (now) | Windows | Linux |
|---|---|---|---|
| TCP, UDP | Network.framework | Winsock, or SwiftNIO | POSIX sockets, or SwiftNIO |
| MIDI source and inputs | CoreMIDI virtual source | a Windows MIDI Services virtual device, or loopMIDI | an ALSA sequencer port |
| Window automation (SuperRack's guard and rack name) | Accessibility | UI Automation, with its own captures | — |
| Audio interface channel names | Core Audio `'lchn'` | ASIO channel info | PipeWire or JACK port names |
| Staying awake | a `ProcessInfo` activity, held by the engine | `SetThreadExecutionState` | an inhibitor lock |
| SQLite | the SDK's | bundled | the system's |
| UI | menu bar + SwiftUI | a headless engine and a local web page | the same |

- **The web page** would be served by the engine on localhost.
  - It would hold the status, the console and host pickers, the `ModuleOption` forms and the
    Channels table.
  - That gives one UI for all three systems, reachable from a phone too.
- **SuperRack on Windows:** its window guard would be new work, with its own captures.
- **Cantabile and VSTHost** are Windows only, but their network APIs reach them from a Mac today.

## 9. The modules

### Consoles

| Module | id | Status | Built | Follows | Names | Routing | Transport |
|---|---|---|---|---|---|---|---|
| Yamaha QL | `yamaha.ql` | **supported** (QL1, live show) | yes | the selected channel, editor port | RCP | `InCh/Patch` (not run) | TCP 50000 + 49280 |
| Yamaha CL | `yamaha.cl` | experimental | inside `yamaha.ql`; its own entry in stage 4 | as the QL (one Yamaha spec covers both) | RCP | as the QL | TCP 50000 + 49280 |
| Yamaha DM7, DM3 | `yamaha.dm` | experimental | yes | the channel on cue, with [CUE] > [SEL] Link on | RCP | none | TCP 49280 |
| Yamaha RIVAGE PM | `yamaha.pm` | experimental | stage 4 | the channel on cue A (or B) | RCP, 288 inputs | `InCh/Patch` A/B, `PatchSelect` | TCP 49280 |
| A&H Qu-16/24/32/Pac/SB | `allenheath.qu` | experimental | yes | the channel on PAFL, with Sel follows PAFL on | SysEx | source push only | TCP 51325 |
| A&H SQ, Qu-5/6/7 | `allenheath.sq` | experimental | yes | no: learned controls only | no | no | TCP 51325 |
| A&H Avantis | `allenheath.avantis` | experimental | inside `allenheath.dlive`; its own entry in stage 4 | no: names + learned controls | SysEx, inputs 1–64 | no | TCP 51325 |
| A&H dLive | `allenheath.dlive` | experimental | yes | no: names + learned controls | SysEx, inputs 1–128 | no | TCP 51325, no TLS |
| Behringer X32, Midas M32 | `behringer.x32` | experimental | stage 4 | `/-stat/selidx` (0–71), polled | `/ch/NN/config/name` and the like (12 characters) | `config/source`, `/config/routing`, `/outputs/*/src` | UDP 10023 |
| Behringer Wing | `behringer.wing` | experimental | stage 4 | `/$ctl/$stat/selidx` (0–75), polled | `/ch/N/name` and the like | `/ch/N/in/conn/*`, `/io/in/*/name` | UDP 2223 |

- **Shared code.**
  - CL and QL are one implementation listed twice. A CL is labelled as untried without changing a
    QL user's code path, and when the desk reports a CL model the status line says so.
  - Avantis and dLive share code the same way.
- **Qu-5/6/7** speaks the SQ's protocol (NRPN, with no SysEx, names or selection), not the classic
  Qu's. The Qu module's about text points there.
- **Avantis V2.0** has 96 inputs, but its channel ranges are in a document not yet read. Until
  then, Remora reads 1–64.
- **PM.** It has no selected-channel parameter, and its screens can show up to three selected
  channels. So it follows cue, like the DM.
  - RCP on TCP 49280 is evidenced only by Companion's module; Yamaha documents OSC on UDP 49900.
  - PM's answer to `devinfo productname` hasn't been seen.
- **X32 sends:**
  - a whitelist of read addresses, sent with no arguments;
  - `/info`, `/xinfo` and `/status`;
  - `/xremote` and `/renew`, only if the user opts in.
  - **Never** anything with an argument: `/` with a string sets any node.
  - **Never** `/-action/*` or `/-prefs/*`.
  - Selection pushes may depend on `/-prefs/autosel`, which Remora reads but never sets.
- **Wing sends:**
  - gets (an address with no arguments) and `/?`;
  - `/*s`, only if the user opts in. Wing keeps a single subscription and the newest wins, so it
    would knock Companion off.
  - **Never** blobs.
  - The order of `selidx` is inferred from the channel counts, not documented.

### Plug-in hosts

| Module | id | Status | Built | Show a rack | Steps | Rack list | Knows where it is | Routing | Reach | Changes sound |
|---|---|---|---|---|---|---|---|---|---|---|
| SuperRack — MIDI (Performer, SoundGrid) | `superrack.midi` | **supported** (Performer 15.15; SoundGrid not run) | yes, with the Edition option | counted Next/Previous | yes | session copy | window title, log | session routes | local | no |
| SuperRack — ProLink (Performer, SoundGrid) | `superrack.prolink` | experimental until its module has run (the link ran on Performer 15.15.12.13, 2026-11-07; SoundGrid not run) | yes (stage 2) | ShowRack by input channel | NavigateRack, NavigatePlugin | rack records + change pushes | from its own commands | first input channel + count | network (TCP 50002, SuperRack dials) | no |
| REAPER | `reaper` | experimental | stage 5 | web `SET/TRACK/n/SEL` after unselect-all, or OSC `device/track/select` | OSC `device/track/+`, `-` | web `/_/TRACK` | track flags | `I_RECINPUT` | network | no |
| Ableton Live | `ableton` | experimental; needs the AbletonOSC script (MIT, third party) | stage 5 | `/live/view/set/selected_track` | computed | `track_names` | a listener | input routing names | network (UDP 11000/11001) | no |
| Logic Pro | `logic` | experimental | stage 5 | counted steps over learned "Select Next/Previous Track" key commands | yes | typed by the user | no; Resync means selecting the first track | no | local (MIDI) | no |
| MainStage | `mainstage` | experimental | stage 5 | Program Change | Next/Previous Patch | typed | no | no | local (MIDI) | **yes**: loads the patch |
| LiveProfessor 2 | `liveprofessor` | experimental | stage 5 | `/Chains/Select n` (from 1), or a View Set per chain | `/Chains/Select/Next`, `/Previous` | View Set names | View Set feedback only | no | network (UDP, port set in LiveProfessor) | no; Global Snapshots never used |
| Gig Performer | `gigperformer` | experimental | stage 5 | `/GigPerformer/SwitchToRackSpace`, by index or name | Next/Prev RackSpace | `ListAllRackspaces` (reply undocumented) | no | no | network (OSC, Pro licence) | **yes**: switches rackspace |
| VSTHost | `vsthost` | experimental | stage 5 | `/performance/num n` | MIDI Next/Previous | no | `/performance/num` | channel count only | network (OSC 7701; Windows) | **yes**: loads a performance |
| Cantabile | `cantabile` | experimental | stage 5 | `setlist/loadSongByIndex`, `loadSong(name)` | `loadNextSong` | the set list | `currentSongChanged` | no | network (35007; Windows) | **yes**: loads a song |
| Steinberg VST Live | `vstlive` | experimental | stage 5 | MIDI actions Select Song/Part/Layer (value is the index from 0) | next/previous actions | typed | no | no | local (MIDI) | **yes** |

**Not built, because there is nothing to drive:**
- **Yamaha VST Rack Pro.**
  - Its remote is one MIDI port: CC maps to plug-in parameters, and Program Change recalls scenes,
    which are parameters.
  - Nothing selects a rack or says which rack is shown.
  - Its link to the desk is audio only, over Dante.
- **HOST LIVE.**
  - MIDI recalls snapshots, which are parameters.
  - Its "follow the console" recalls a DiGiCo console's snapshots by list position.
  - No strip select is documented. Whether Remora could play that console needs a capture.

**Later routes, each needing a capture:**
- Logic as a Mackie Control surface: bank and select, with names on the scribble strip.
- Gig Performer through a GPScript that opens a block's editor without switching rackspace.
- Cantabile's binding points (`availableBindingPoints`), for a show-editor command.

## 10. Stages

Each stage lands on main by itself with every test green.
- **The check:** `Remora --headless --dry-run --host 127.0.0.1` against `tools/fake-ql.py`. The
  MIDI log was recorded before stage 1 and is diffed after each stage.
- `--probe`, `--racks`, `--mapping` and `--screenshots` are checked the same way.

1. **Seams, no change in behaviour.** Built 2026-11-07:
   - the module API types (§2), the registry and `ModuleContext`;
   - today's five desks wrapped as console modules, with legacy ids, and settings read and written
     as before;
   - SuperRack MIDI behind `HostModule`, so the engine speaks only commands and events;
   - the platform protocols, with the Apple code behind them;
   - the five targets and `PortabilityTests`.

   Checked against the build before it:
   - 87 tests pass: 74 before, and 13 new;
   - the fake QL's dry run sent the same 130 MIDI lines;
   - `--racks`, `--mapping` and `--probe` printed the same;
   - `--screenshots` drew the same six PNGs, byte for byte.

   The one change in the log: SuperRack's "reading its rack from its window" line now comes
   straight after the rack list, because the module starts the guard with the session.
2. **SuperRack editions and ProLink.** Built 2026-11-07:
   - the Edition option, with SoundGrid's paths, for both SuperRack modules and the window guard;
   - `superrack.prolink`: `ProLinkWire`, `ProLinkRack`, `ProLinkConsole` (with its send whitelist)
     and the module, over a `TCPListener` from `Platform` (`TCPServer` in RemoraApple);
   - `HostEvent.link`, for the status line;
   - the host picker on the renamed Plug-in Host tab, and the menu following the host.

   Checked against stage 1:
   - 124 tests pass: 87 before, and 37 new, with an in-process fake SuperRack and a loopback TCP
     test;
   - the fake QL's dry run sent the same MIDI as 0.3.1's build in the same conditions: 130 lines
     with SuperRack open (partway through the stage), and 67 with it closed, counting only (the
     final build);
   - `--racks`, `--mapping` and `--probe` printed the same;
   - `--screenshots`: the other tabs differ only in the tab bar; the Plug-in Host tab has its new
     pickers, and there is a picture of ProLink's.

   Not run yet: the ProLink module against SuperRack (the link was run with a stand-alone console),
   and SoundGrid.
3. **Routing**, off by default:
   - the model and the resolver;
   - SuperRack's routes, from the session and from ProLink;
   - the QL's input patch;
   - declared runs;
   - the Channels columns.
4. **Experimental desks:**
   - the CL and Avantis entries, PM, X32/M32 and Wing;
   - each with its read guard and tests;
   - each with a fake desk in `tools/` that fails on any non-read, as `fake-ql.py` does.
5. **Experimental hosts:** REAPER, Ableton, LiveProfessor, Gig Performer, VSTHost, Cantabile,
   MainStage, Logic and VST Live.
   - Each comes with an in-process fake, a send whitelist, and the sound gate where it applies.
   - REAPER, Live Lite, Logic and MainStage are installed on the development Mac and could be tried
     for real. They stay experimental either way.
6. **Docs, with each stage:** AGENTS.md, the README status block and table, PROTOCOL.md and
   USER-GUIDE.md. Each new module's PROTOCOL.md section is marked "experimental, from documents",
   with its sources.

**Design only until asked:** the remote split, Windows and Linux, the web UI, and reading Dante
live.

## 11. Decided (2026-11-07)

1. **The shape** in §1–§5.
2. **ProLink** is in this public repo as interoperability only. It uses only what LAWO's mc² scripts
   and our captures show (§6).
3. **Hosts whose only remote select changes the sound** are built: MainStage, Gig Performer,
   VSTHost, Cantabile and VST Live. They send nothing until the user ticks that they understand
   (§2.3).
4. **VST Rack Pro and HOST LIVE** are listed as looked at, with nothing to drive (§9).
5. **Dante routing** comes from an imported Dante Controller preset file. Remora doesn't read Dante
   live.
6. **SoundGrid** is an edition of both SuperRack modules, with the guide's paths. It hasn't been
   run (§6).
7. **X32 and Wing** are polled. They never take one of the desk's push slots unless the user asks
   (§9).

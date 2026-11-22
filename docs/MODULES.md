# Writing a module

Remora follows a desk's selected channel and shows that channel's rack in a plug-in host. Each
desk and each host is a **module**:

- A **console module** reads a desk: the selected channel, the channel names, its model, and any
  presses that a control could be learned from.
- A **host module** shows a rack the host's way and says what racks the host has.

The engine in the middle maps a channel to a rack, and knows no protocol. This guide covers what
a new module needs, in the order you'll need it. docs/ARCHITECTURE.md §2 is the reference for
the types, and AGENTS.md holds the rules. Where this guide and AGENTS.md differ, AGENTS.md wins.

A complete console module, built for this guide, is in
[`Tests/RemoraCoreTests/ModuleGuideTests.swift`](../Tests/RemoraCoreTests/ModuleGuideTests.swift).
It drives a made-up desk, and its tests run with every other test, so it keeps building as the API
changes. The excerpts below come from it.

## 1. Before you write anything

**Find out what the desk or host can say, and where that is written down.**

- **Your sources.** Every module is built from the maker's documents, from captures of the real
  thing, or from both. Note which ones, with versions and dates: they go into
  docs/PROTOCOL.md (§7). Don't decompile Waves' or Yamaha's software (AGENTS.md).
- **A desk:**
  - Can it say which channel is selected? If not, does it say what is on cue or PAFL? The Qu and
    the DM7 are followed by their cue, with the desk set to select what is cued.
  - Can it give the channel names?
  - Is there a way to read these that sends nothing else?
- **A host:**
  - Can it show a rack, chain or track by number?
  - Can it list them, and can it say which one it is on?
  - Does showing one change the sound? A MainStage patch or a Gig Performer rackspace loads one
    (§4.4).
- **The id.** Use `maker.model` (`behringer.wing`) for a desk and the host's name (`reaper`) for a
  host. The id is stored in settings.json, so it never changes. If you rename a module later, the
  old id goes in `legacyIDs`.

## 2. Where it goes

```
Sources/RemoraConsoles/<Maker>/    a console module: its link, its read guard, its parsing
Sources/RemoraHosts/<Host>/        a host module: its spec or module, its whitelist
Sources/RemoraHosts/Shared/        drivers more than one host uses (OSC, MIDI, HTTP, WebSocket)
```

- **No imports between them.** RemoraConsoles and RemoraHosts depend on RemoraCore and nothing
  else.
- **The OS only through `Platform`.** Both targets import nothing but Foundation and Dispatch.
  Sockets, MIDI and the rest come through `Platform` (RemoraCore/Platform.swift). Each system
  supplies its own:
  - `ApplePlatform` (RemoraApple) on macOS;
  - `SocketPlatform` (RemoraSockets) on Windows;
  - `TestPlatform` in the tests.

  `PortabilityTests` fails on any other import. The one exception is SQLite in
  `RemoraHosts/SuperRack`. This is what lets a module written on a Mac build and run on Windows
  unchanged.

What `Platform` offers:

| Call | What you get |
|---|---|
| `tcp(host:port:queue:)` | A `TCPStream` that connects, reconnects until stopped, and calls `onData` with what arrives. |
| `udp(host:port:queue:)` | A `UDPLink` to one host and port, hearing the answers sent back to it. |
| `tcpListener(port:queue:)` | A `TCPListener`, for a host that dials Remora (SuperRack over ProLink). |
| `oscReceiver()` | A UDP port of Remora's own, for a host that answers to a fixed port. |
| `midi` | Remora's MIDI port, through `ModuleContext.midiOut`. Nil where the system has none (Windows, for now). |

Your callbacks come on the queue you pass in. Keep all of a module's state on that one queue.

## 3. A console module

### 3.1 The shape

A desk can be one of two things:

- a `ConsoleLink`, wrapped by `LinkConsoleModule`. Every desk Remora has is one, and a new desk
  should be too;
- a `ConsoleModule`, which sends `ConsoleEvent`s itself.

A `ConsoleLink` has six callbacks, plus `start()` and `stop()`:

| Callback | Call it with |
|---|---|
| `onState` | How the link stands: `.connecting`, then `.waitingForDesk` once the socket is open, `.live` when the desk answers, `.failed(why)`, `.stopped`. |
| `onModel` | The desk's model, once it says ("QL1", "X32"). |
| `onSelected` | The selected channel, **only when it changes**. The engine moves the host on every call. |
| `onNames` | Every name the desk has given, each time one changes. An empty name is no name: leave it out. |
| `onNamesLink` | Whether names are coming in, for a desk that sends them over a second connection. |
| `onControl` | A press a control could be learned from (§3.6). |

`onRoutes`, which gives each channel's input patch for routing, is optional. Its default reports
nothing.

### 3.2 Channels

Map the desk's numbering onto `ConsoleChannel`: `.input(n)`, `.stereoIn(n, right:)`, `.stereo(n)`,
`.mix(n)`, `.group(n)`, `.aux(n)`, `.fxReturn(n)`, `.matrix(n)`, `.main(n)`.

- **Count from 1**, as the desk's own screens do, even where the protocol counts from 0.
- **Keys are stored.** A channel's `key` (`in12`, `mix3`) is saved in the user's overrides, so a
  key never changes meaning. If a desk has something none of these fit, add a case with a new key
  and leave the existing keys alone.

### 3.3 The read guard

**Remora never changes a desk.** Consoles are often mid-show when it runs. Each console module has
one pure function that says whether a message is a read. Every send goes through it as a
precondition, so a bug that would change the desk stops Remora instead.

```swift
/// True only for a request to read: an address on the list, with no arguments.
static func isReadRequest(_ m: OSC.Message) -> Bool {
    guard m.args.isEmpty else { return false }
    if m.address == "/info" || m.address == "/sel" { return true }
    return inputs.contains { m.address == "/ch/\($0)/name" }
}

/// The only way anything reaches the desk.
private func ask(_ address: String) {
    let m = OSC.Message(address: address, args: [])
    precondition(Self.isReadRequest(m), "Remora sends only reads to a console")
    udp.send(OSC.encode(m))
}
```

The existing guards are `YamahaSysEx.isReadRequest`, `AllenHeathMIDI.isReadRequest` and
`BehringerOSC.isReadRequest`, and RCP sends only `get` and `devinfo`. Look at the one nearest your
desk's protocol.

- **Make the list exact.** Name each address or message, rather than a pattern that might also
  match a write.
- **Don't take another client's place.** Some desks push changes to a few subscribers: an X32 has
  four `/xremote` slots, and a Wing has one subscription. Other apps (Companion, a tablet) may be
  using them, so poll instead and leave those slots alone. The Behringer module asks five times a
  second, which is fast enough to follow a selection.
- **One connection, if the desk allows only one.** A Qu takes one TCP MIDI connection at a time.
  Say so in `about`, because Remora holding it means the user's other app can't.

### 3.4 Connecting, polling, and knowing when the desk has gone

The example's link opens a UDP socket from `Platform`, and does all its work on one queue:

```swift
init(host: String, platform: Platform) {
    udp = platform.udp(host: host, port: Self.port, queue: queue)
    udp.onState = { [weak self] in self?.socket($0) }
    udp.onDatagram = { [weak self] in self?.received($0) }
}

func start() { queue.async { self.udp.start() } }
func stop() { queue.sync { timer?.cancel(); timer = nil; udp.stop() } }
```

- **UDP has no connection.** A UDP link is "connected" as soon as the socket is ready, so report
  `.waitingForDesk` then. Report `.live` at the desk's first answer, and go back to
  `.waitingForDesk` after a few seconds without one. Over TCP, a `TCPStream` reconnects by itself.
  Report its `.failed` through, so the user sees why.
- **Ask little while waiting.** Until the desk answers, the example asks only what it is, every two
  seconds. Once live, it asks for the selection five times a second and the names every 30 s.
- **Report changes, not answers.** The desk answers every poll, but `onSelected` is called only
  when the selection moves, and `onNames` only when a name changes.
- **Parse defensively.** Drop anything malformed or out of range (a channel 99 on a 32-input desk)
  rather than guessing.

### 3.5 The registry entry

```swift
static let entry = ConsoleModuleEntry(ModuleInfo(
    id: "example.desk", kind: .console,
    title: "Example desk", product: "Example", maker: "Example", status: .experimental,
    about: "OSC over UDP 9000: /sel for the selected input and /ch/N/name for its name, …",
    platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.follows, .names])
) { c in LinkConsoleModule(ExampleDesk(host: c.consoleHost, platform: c.platform)) }
```

Add the entry to `RemoraConsoles.all`, in `Sources/RemoraConsoles/RemoraConsoles.swift`. The
`make` closure gets a `ModuleContext`, which holds:

- the settings;
- the platform;
- `consoleHost`, the desk's address, trimmed.

The `ModuleInfo` fields are in §5.

### 3.6 Controls (optional)

A desk that reports presses (a soft key, a MIDI strip, a user-defined key) can call `onControl`
with a `ControlSource` and a value, and the user can learn it as a control. `ControlSource` is
stored in settings.json, so use an existing case where you can:

- `.midi(…)` for anything that arrives as MIDI;
- `.yamaha(…)` for a Yamaha SysEx address.

A new case must decode in old files and must never be renamed.

## 4. A host module

### 4.1 Which kind

| The host takes | Write | Examples |
|---|---|---|
| OSC over UDP | an `OSCHostSpec`, run by `OSCHostModule` | LiveProfessor, Gig Performer, VSTHost, Ableton (AbletonOSC) |
| MIDI on Remora's port | a `MIDIHostSpec`, run by `MIDIHostModule` | MainStage, Logic, VST Live |
| Anything else | a `HostModule` of its own, on `HTTPGet`, `WebSocketClient` or a `TCPStream` | REAPER (web interface), Cantabile (WebSocket), SuperRack |

A spec is a page of code: what to send to show and step, what to ask, how to read the answers,
and a whitelist. The shared module does everything else:

- the link;
- where the host is;
- Resync;
- typed racks;
- the sound gate;
- refusing anything off the whitelist.

Write a full `HostModule` only when neither spec fits.

### 4.2 An OSC host

LiveProfessor's module is the whole of `Sources/RemoraHosts/LiveProfessor/LiveProfessor.swift`:

```swift
public static let spec = OSCHostSpec(
    info: info,
    show: { i, _ in i >= 0 ? [OSC.Message(address: "/Chains/Select", args: [.int(Int32(clamping: i + 1))])] : [] },
    step: { d in [OSC.Message(address: d > 0 ? "/Chains/Select/Next" : "/Chains/Select/Previous", args: [])] },
    isAllowed: OSCHostSpec.only(["/Chains/Select": ["i"], "/Chains/Select/Next": [""], "/Chains/Select/Previous": [""]]))

public static let entry = HostModuleEntry(info) { OSCHostModule(spec, $0) }
```

- **`show(index, racks)`** gives the messages that show rack `index`, counting from 0. Return
  `[]` for a rack the host can't show.
- **`step(±1)`** gives the messages for the next or previous rack. Leave it nil if the host has no
  step of its own: the module then shows the rack beside the last one.
- **`ask`** is sent when the link opens and on Resync. **`poll`** repeats it, for a host that never
  says anything unprompted.
- **`read`** turns an answer into `.racks([names])` or `.position(index)`. A host that can list its
  racks needs no typed racks.
- **`isAllowed`** is the whitelist. `OSCHostSpec.only` builds one from addresses and the type tags
  each may carry (`""` means no arguments).

### 4.3 A MIDI host

MainStage selects a patch with a Program Change:

```swift
public static let spec = MIDIHostSpec(
    info: info,
    show: { i, racks in i >= 0 && i < min(racks.count, 128) ? [.programChange(i)] : [] },
    isAllowed: { m in
        if case .programChange(let p) = m { return (0..<128).contains(p) }
        return false
    })
```

- **A MIDI host never answers.** Its racks are typed by the user (`typedRacks: true`), and its
  position is whatever Remora last sent.
- **No show by number?** Set `counts: true` with a `step`. The module then counts steps from the
  first rack, as Logic's does.
- **A host that drops fast messages** gets a `spacing`.
- **MIDI needs a MIDI port.** Remora makes one on macOS, and opens the loopback port the user
  made on Windows (§6).

### 4.4 Rules for every host

- **Show, don't change.** Nothing a host module sends may change the audio, the session or the
  project: no transport, mute, solo, arm, fader, parameter, plug-in load or save. The whitelist is
  where that is enforced, so keep it to exactly what the module sends.
- **The sound gate.** On some hosts, showing a rack loads a patch, a rackspace or a song.
  - **Set `capabilities: [.showChangesSound]`** and say so plainly in `about`.
  - **The engine sends nothing** until the user ticks that they understand. The shared modules
    hold their own questions too.
  - **A full `HostModule` must also hold its own sends** until
    `HostSettings.showChangesSoundAccepted`, as Cantabile's `held` does: it doesn't even connect.
- **What the host can't do is logged once and dropped**, never faked. Plug-in steps on a host
  that has none are an example.
- **Say how a position is known.** A full module reports `.position(RackPosition(i, basis))`:
  - `.reported`: the host said so;
  - `.seen`: it was read off the host's window;
  - `.counted`: Remora counted its own steps;
  - `.sent`: a show went out and nothing answered.

  Never report more certainty than you have. A Companion button shows the basis.
- **Events can come on any queue.** The engine moves them to the main queue.
- **`update(_ settings:)`** is called when the settings change. Take your own settings
  (`settings.host(id)`, with `HostDefaults` for anything unset) and ignore the rest.

### 4.5 HostDefaults

`HostDefaults` says which settings the host's tab shows and what they start as:

- `port`, and `tcp` for a TCP host;
- `replyPort`, for a host that answers to a fixed port;
- `midiChannel`;
- `typedRacks`;
- `setUp`: numbered steps for the user to do once in the host.

The user's own values are saved under `hosts` in settings.json, by module id. A host left at its
defaults leaves no entry there.

## 5. ModuleInfo

| Field | What to put |
|---|---|
| `id`, `legacyIDs` | §1. Never renamed. |
| `kind` | `.console` or `.host`. |
| `title` | What the picker shows: "Behringer X32 / Midas M32". |
| `product` | What logs and menus call it: "X32 / M32". |
| `maker` | Groups the picker. |
| `status` | `.experimental` until it has run on the real kit (§8). |
| `about` | One paragraph: what it reads or drives, over what port, what the user must set on the desk or host, what is never sent, and what it was built from and whether it has been run. Users read this in the picker. |
| `platforms` | Where it can run (§6). |
| `reach` | `.network` if it can drive a desk or host on another computer; `.local` if it needs that computer (a virtual MIDI port, Accessibility, a session file). Every desk is `.network`. |
| `capabilities` | Desks: `.follows`, `.names`, `.needsMIDIChannel`, `.routing`. Hosts: `.routing`, `.showChangesSound`. |
| `hostDefaults` | Hosts only (§4.5). |
| `tried` | For an experimental module that has met the kit in part: how far, finishing "run on…". |
| `untried` | For a supported module: each system in `platforms` it has never run on, with what is unknown there (§6). |

## 6. Platforms: macOS, Windows, Linux

The same module code builds on every system. `platforms` says where it can actually run:

- **A network module** that uses only `tcp`, `udp`, `tcpListener` and `oscReceiver` can list all
  three. Every desk does, and so do the OSC and web hosts.
- **A module that needs MIDI** lists the systems that give Remora a MIDI port, and where its host
  runs: macOS, and Windows, where `WindowsPlatform` opens a loopback port the user makes and says
  in the log what to make when there is none (`midiUnavailable`). Linux has no MIDI port yet.
- **Supported on one system, never run on another?** List both in `platforms`, and say in
  `untried` what is unknown on the other (`untried: [.windows: "…"]`). There it is experimental,
  and the log says why (`experimentalWhy`), whatever `status` says.
- **A module that needs one host's own computer**, such as SuperRack's MIDI driver with its
  session file, lists only the systems where that host runs.
- **On a system it doesn't list,** the engine refuses the module. It logs, for example, "Logic Pro
  runs only on macOS, not Windows" (`ModuleInfo.unavailableHere`). The one exception is a
  host module given a stand-in for the MIDI port (`--dry-run`, or a test's sink): that needs
  nothing of the system, so it is made, and its MIDI goes to the stand-in.

Never put `#if os(…)` in a module for its protocol. If a system can't do something, that belongs
in `Platform`, and the module's `platforms` says where it runs.

## 7. Tests and documents

### 7.1 Unit tests

`TestPlatform` (Tests/RemoraCoreTests/TestPlatform.swift) never connects. A module made with it
gets `TestUDP` or `TestStream` links that keep what would have been sent. You feed them answers by
hand:

```swift
let p = TestPlatform()
let desk = ExampleDesk(host: "10.0.0.30", platform: p)
desk.onSelected = { selected.append($0) }
desk.start()
let udp = try XCTUnwrap(p.udps.first)
udp.answer("/info", [.string("EX-1")])
udp.answer("/sel", [.int(4)])
XCTAssertEqual(selected, [.input(5)])
XCTAssertTrue(udp.messages.allSatisfy(ExampleDesk.isReadRequest), "everything sent is a read")
```

Every module needs these tests:

- **The guard or whitelist, both ways.** Every message the module builds passes it. A write, a
  wrong argument and an address off the list fail.
- **Everything sent is allowed.** Run the module through a session and check every message it
  sent against the guard, as the last line above does.
- **Parsing, from real bytes.** Use bytes from the maker's documents or from a capture, including
  malformed and out-of-range answers.
- **The engine end to end.** Build a `ModuleRegistry` holding your entry and a host, give the
  engine settings that pick them, and check that the selection reaches the host.
  `ModuleGuideTests.testTheEngineMakesItFromTheRegistry` does this.

The registry has tests of its own. `ModuleTests.testOnlyWhatHasRunIsSupported` lists every
supported module, so marking one supported is a deliberate change to that test.

Run the tests with `swift test`, on the Mac and on Windows.

### 7.2 A fake desk or host

`tools/` holds a Python fake for each protocol:

- desks: `fake-ql.py`, `fake-rcp.py`, `fake-behringer.py`, `fake-allenheath.py`, `fake-sq.py`;
- hosts: `fake-host.py` for the OSC hosts, `fake-reaper.py`, `fake-cantabile.py`.

Each fake plays its desk or host as the documents describe it, logs what Remora sends, and **exits
1 if Remora sends anything but a read** (or, for a host, anything off its whitelist). Add one for a
new protocol, or add your host to `fake-host.py`'s list. Then run Remora against it:

```bash
python3 tools/fake-behringer.py --desk x32 &
swift run Remora --probe 127.0.0.1 --console behringer.x32
```

- **`--probe`** watches a desk's selection and names, read-only.
- **`--headless --dry-run`** runs the whole engine and logs the MIDI instead of opening a port.

AGENTS.md has the details, and the traps: use `127.0.0.1`, not `localhost`; check with `lsof` that
the port is free; keep a test copy's settings away from a running app.

### 7.3 Documents

- **docs/PROTOCOL.md:** a section for the protocol. Give what is sent and what comes back, with
  the sources, the versions and dates, and what was measured on which firmware. Mark it
  "experimental, from documents" until it has run.
- **README.md:** a row in the Desks or Plug-in hosts table.
- **docs/ARCHITECTURE.md:** the id in §2.5's table, and a line in §9.

## 8. Experimental until it has run

A new module is `.experimental`. The picker marks it, and the log says why
(`ModuleInfo.experimentalWhy`). It becomes `.supported` only when one of these happens:

- it has run against the real desk or host, and PROTOCOL.md says on what, with which firmware,
  and when;
- people using it report it working, as the X32 module was.

Compiling, unit tests and a fake prove the code does what the documents say, not that the desk
does. If it has met the kit in part, say how far in `tried` ("an SQ-5, for the selection and
names").

**Testing on real kit:** only on a rig that is not in a show, and with nothing else depending on
the desk.

## 9. Checklist

- [ ] An id that will never change, with `legacyIDs` for any old name.
- [ ] The module in its maker's folder, reaching the OS only through `Platform`.
- [ ] One read guard (desk) or whitelist (host), checked before every send.
- [ ] `.showChangesSound` if showing a rack loads anything, with sends held until the user ticks.
- [ ] `ModuleInfo`: `about` says what it does, what it never sends and what it was built from;
      `platforms` and `reach` are right.
- [ ] The entry in `RemoraConsoles.all` or `RemoraHosts.all`.
- [ ] Tests: the guard both ways, everything sent allowed, parsing from real bytes, the engine end
      to end.
- [ ] A fake in `tools/` that exits 1 on anything but a read or a whitelisted message.
- [ ] PROTOCOL.md, the README's table, and ARCHITECTURE §2.5 and §9.
- [ ] `.experimental`, until it has run on the kit.

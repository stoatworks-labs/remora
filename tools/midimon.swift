// Prints every message from one CoreMIDI source. Build: swiftc -O tools/midimon.swift -o .build/midimon
// Usage: midimon "Remora" [seconds]
import CoreMIDI
import Foundation

let want = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Remora"
let secs = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 30 : 30
var client = MIDIClientRef()
var port = MIDIPortRef()
MIDIClientCreateWithBlock("midimon" as CFString, &client, nil)
let t0 = Date()
MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &port) { list, _ in
    for p in list.unsafeSequence() {
        for w in MIDIEventPacket.WordCollection(p) where w >> 28 == 2 {
            print(String(format: "%6.3f %02X %02X %02X", Date().timeIntervalSince(t0),
                         (w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF))
            fflush(stdout)
        }
    }
}
var found = false
let deadline = Date().addingTimeInterval(secs)
while Date() < deadline {
    if !found {
        for i in 0..<MIDIGetNumberOfSources() {
            let s = MIDIGetSource(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(s, kMIDIPropertyDisplayName, &name)
            if (name?.takeRetainedValue() as String?) == want {
                MIDIPortConnectSource(port, s, nil)
                found = true
                print("connected to \(want)"); fflush(stdout)
            }
        }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}

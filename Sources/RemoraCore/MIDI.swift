import CoreMIDI
import Foundation

/// Where control changes go. The app's is a CoreMIDI virtual source; tests use a recorder.
public protocol CCSink: AnyObject {
    /// `channel` is 1–16.
    func sendCC(channel: Int, number: Int, value: Int)
}

/// A MIDI 1.0 channel message from any source, for learning and running console/MIDI controls.
public struct MIDIEvent: Equatable {
    public enum Kind: String, Codable { case cc, note }
    public var source: String
    public var kind: Kind
    /// 1–16.
    public var channel: Int
    public var number: Int
    public var value: Int
}

/// The app's MIDI: one virtual source that SuperRack listens to, and an input that hears every
/// other source (an A&H desk's MIDI driver, a controller) for controls.
public final class MIDIEndpoint: CCSink {
    public var onEvent: ((MIDIEvent) -> Void)?
    public let name: String

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var input = MIDIPortRef()
    private var connected: [MIDIUniqueID: String] = [:]
    private var ownID: MIDIUniqueID = 0
    private let lock = NSLock()

    public init?(name: String) {
        self.name = name
        let notify: MIDINotifyBlock = { [weak self] n in
            if n.pointee.messageID == .msgSetupChanged { self?.connectSources() }
        }
        guard MIDIClientCreateWithBlock(name as CFString, &client, notify) == noErr,
              MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source) == noErr else {
            return nil
        }
        MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &ownID)
        let status = MIDIInputPortCreateWithProtocol(client, "\(name) in" as CFString, ._1_0, &input) {
            [weak self] list, refCon in
            self?.received(list, refCon)
        }
        guard status == noErr else { return nil }
        connectSources()
    }

    deinit {
        MIDIEndpointDispose(source)
        MIDIClientDispose(client)
    }

    public func sendCC(channel: Int, number: Int, value: Int) {
        let status = UInt32(0xB0 | ((channel - 1) & 0x0F))
        var word = UInt32(0x2000_0000) | status << 16 | UInt32(number & 0x7F) << 8 | UInt32(value & 0x7F)
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        MIDIReceivedEventList(source, &list)
    }

    /// Every source but our own.
    private func connectSources() {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            var id: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(src, kMIDIPropertyUniqueID, &id)
            guard id != ownID, connected[id] == nil else { continue }
            var cfName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &cfName)
            let n = (cfName?.takeRetainedValue() as String?) ?? "MIDI \(id)"
            connected[id] = n
            MIDIPortConnectSource(input, src, UnsafeMutableRawPointer(bitPattern: Int(Int64(id) & 0xFFFF_FFFF) | 1 << 40))
        }
    }

    private func received(_ list: UnsafePointer<MIDIEventList>, _ refCon: UnsafeMutableRawPointer?) {
        let id = refCon.map { MIDIUniqueID(truncatingIfNeeded: Int(bitPattern: $0) & 0xFFFF_FFFF) }
        lock.lock()
        let src = id.flatMap { connected[$0] } ?? "MIDI"
        lock.unlock()
        for packet in list.unsafeSequence() {
            let words = MIDIEventPacket.WordCollection(packet)
            for w in words where w >> 28 == 0x2 {
                let status = Int((w >> 16) & 0xFF)
                let d1 = Int((w >> 8) & 0x7F), d2 = Int(w & 0x7F)
                let ch = status & 0x0F + 1
                switch status & 0xF0 {
                case 0xB0: onEvent?(MIDIEvent(source: src, kind: .cc, channel: ch, number: d1, value: d2))
                case 0x90: onEvent?(MIDIEvent(source: src, kind: .note, channel: ch, number: d1, value: d2))
                case 0x80: onEvent?(MIDIEvent(source: src, kind: .note, channel: ch, number: d1, value: 0))
                default: break
                }
            }
        }
    }
}

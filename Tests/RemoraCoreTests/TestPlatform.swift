import Foundation
@testable import RemoraCore

/// A platform that never connects: links made with it are fed by hand (`receiveForTesting`), and
/// what they would send is kept.
final class TestPlatform: Platform {
    private(set) var streams: [TestStream] = []
    /// The one OSC receiver it hands out, so a test can play messages into the engine.
    let osc = TestOSC()

    func tcp(host: String, port: UInt16, queue: DispatchQueue) -> TCPStream {
        let s = TestStream(host: host, port: port)
        streams.append(s)
        return s
    }

    func midi(name: String) -> MIDILink? { nil }

    func oscReceiver() -> OSCReceiver { osc }
}

final class TestStream: TCPStream {
    let host: String
    let port: UInt16
    var state: StreamState = .stopped
    var onState: ((StreamState) -> Void)?
    var onData: (([UInt8]) -> Void)?
    private(set) var sent: [[UInt8]] = []

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func start() {}
    func stop() {}
    func reconnect(after delay: TimeInterval, reason: String) {}
    func send(_ bytes: [UInt8]) { sent.append(bytes) }
}

final class TestOSC: OSCReceiver {
    var onMessage: ((OSC.Message) -> Void)?
    func start(port: UInt16) throws {}
    func stop() {}
}

import Foundation

/// Yamaha CL/QL editor-port messages (TCP 50000). The codec is the Yamaha console module's
/// (RemoraConsoles); the address is here because a learned control stores one in settings.json
/// (`ControlSource.yamaha`).
public enum YamahaSysEx {
    /// One parameter: element (two bytes), index (two bytes), channel.
    public struct Address: Hashable, Codable, CustomStringConvertible {
        public var element: Int
        public var index: Int
        public var channel: Int

        public init(element: Int, index: Int, channel: Int) {
            self.element = element
            self.index = index
            self.channel = channel
        }

        public var description: String {
            String(format: "0x%04X/0x%02X ch %d", element, index, channel)
        }
    }
}

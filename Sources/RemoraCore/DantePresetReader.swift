import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// Reads a Dante Controller preset (File › Save Preset): the format is in docs/PROTOCOL.md.
//
//     <preset version="2.1.0">
//       <name>…</name>
//       <device>
//         <name>Stagebox</name> …
//         <txchannel danteId="1" mediaType="audio"><label>Out 1</label></txchannel>
//         <rxchannel danteId="1" mediaType="audio">
//           <name>Front L</name>
//           <subscribed_channel>Out 1</subscribed_channel>
//           <subscribed_device>Stagebox</subscribed_device>
//         </rxchannel>
//       </device>
//     </preset>

extension DantePreset {
    /// The largest file read.
    public static let maxBytes = 4 << 20

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case tooBig(Int)
        /// A DOCTYPE or an entity declaration, which a preset never has.
        case declaration
        case notAPreset
        case xml(String)

        public var description: String {
            switch self {
            case .tooBig(let n):
                return "the file is \(n / 1024) KB, and a preset is under \(DantePreset.maxBytes >> 20) MB"
            case .declaration: return "the file declares a DOCTYPE or an entity, which a Dante Controller preset never does"
            case .notAPreset: return "this is not a Dante Controller preset"
            case .xml(let why): return "the file is not readable XML (\(why))"
            }
        }
    }

    /// Reads a preset file's subscriptions. A DOCTYPE or ENTITY declaration is refused before
    /// parsing, so nothing a file says can make the parser expand or fetch anything.
    public static func read(_ data: Data) throws -> DantePreset {
        guard data.count <= maxBytes else { throw ReadError.tooBig(data.count) }
        // Dante Controller writes UTF-8. A NUL means another encoding, which the scan below could
        // not see into.
        guard !data.contains(0) else { throw ReadError.notAPreset }
        let lower = String(decoding: data, as: UTF8.self).lowercased()
        guard !lower.contains("<!doctype"), !lower.contains("<!entity") else { throw ReadError.declaration }
        let reader = PresetXMLReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        guard parser.parse() else {
            if reader.refused { throw ReadError.declaration }
            throw ReadError.xml(parser.parserError.map { ($0 as NSError).localizedDescription } ?? "no reason given")
        }
        guard reader.sawPreset else { throw ReadError.notAPreset }
        return reader.preset()
    }

    public static func read(contentsOf url: URL) throws -> DantePreset {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw ReadError.tooBig(size) }
        return try read(Data(contentsOf: url))
    }
}

/// The preset's elements, in order. Only `preset/name`, `preset/device/name` and the channels'
/// own elements are read; everything else is skipped.
private final class PresetXMLReader: NSObject, XMLParserDelegate {
    struct Tx {
        var id: Int
        var labels: [String] = []
    }
    struct Rx {
        var id: Int
        var channel = ""
        var device = ""
    }
    struct Device {
        var name = ""
        var tx: [Tx] = []
        var rx: [Rx] = []
    }

    var sawPreset = false
    var refused = false
    private var name = ""
    private var devices: [Device] = []
    private var path: [String] = []
    private var text = ""
    private var tx: Tx?
    private var rx: Rx?

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        path.append(element)
        text = ""
        let id = attributes["danteId"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        switch (path.count, element) {
        case (1, "preset"): sawPreset = true
        case (2, "device") where path[0] == "preset": devices.append(Device())
        case (3, "txchannel") where path[1] == "device": tx = id.map { Tx(id: $0) }
        case (3, "rxchannel") where path[1] == "device": rx = id.map { Rx(id: $0) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding: data, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = path.count >= 2 ? path[path.count - 2] : ""
        switch (path.count, element, parent) {
        case (2, "name", "preset"): name = value
        case (3, "name", "device"): if !devices.isEmpty { devices[devices.count - 1].name = value }
        case (4, "label", "txchannel"): if !value.isEmpty { tx?.labels.append(value) }
        case (4, "subscribed_channel", "rxchannel"): rx?.channel = value
        case (4, "subscribed_device", "rxchannel"): rx?.device = value
        case (3, "txchannel", "device"):
            if let t = tx, t.id >= 1, !devices.isEmpty { devices[devices.count - 1].tx.append(t) }
            tx = nil
        case (3, "rxchannel", "device"):
            if let r = rx, r.id >= 1, !devices.isEmpty { devices[devices.count - 1].rx.append(r) }
            rx = nil
        default: break
        }
        if !path.isEmpty { path.removeLast() }
        text = ""
    }

    // Belt and braces: the scan in `read` refuses these before the parser starts.
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { refuse(parser) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { refuse(parser) }
    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?,
                systemID: String?, notationName: String?) { refuse(parser) }

    private func refuse(_ parser: XMLParser) {
        refused = true
        parser.abortParsing()
    }

    /// Each receive channel's subscription as a link from the transmit channel, found by its
    /// device's name and the channel's label (Dante compares both without case). A subscription
    /// to the receiving device's own channel names the device ".".
    func preset() -> DantePreset {
        var byName: [String: Device] = [:]
        for d in devices where !d.name.isEmpty && byName[d.name.lowercased()] == nil { byName[d.name.lowercased()] = d }
        var links: [PatchLink] = []
        var unresolved: [String] = []
        for d in devices where !d.name.isEmpty {
            for r in d.rx where !r.channel.isEmpty {
                let from = r.device == "." ? d.name : r.device
                let source = byName[from.lowercased()]
                let t = source?.tx.first { $0.labels.contains { $0.caseInsensitiveCompare(r.channel) == .orderedSame } }
                guard let source, let t else {
                    unresolved.append("\(d.name) in \(r.id) ← \(r.channel)@\(from)")
                    continue
                }
                links.append(PatchLink(from: AudioPort(source.name, .dante, .output, t.id), to: AudioPort(d.name, .dante, .input, r.id)))
            }
        }
        return DantePreset(name: name, devices: devices.map(\.name).filter { !$0.isEmpty }, links: links,
                           unresolved: unresolved)
    }
}

import XCTest

/// RemoraCore, RemoraConsoles, RemoraHosts and RemoraEngine build wherever Swift does: they import
/// only Foundation, Dispatch, Remora's own portable targets, and SQLite for SuperRack's session.
/// Network, CoreMIDI, AppKit and Accessibility belong in RemoraApple, behind `Platform`. SwiftPM on
/// macOS lets any target import any SDK framework, so this reads the sources. An import inside
/// `#if canImport(…)` or `#if os(…)` is for a system that has it, and is allowed.
final class PortabilityTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let portable = ["RemoraCore", "RemoraConsoles", "RemoraHosts", "RemoraEngine"]
    static let allowed: Set<String> = ["Foundation", "Dispatch", "RemoraCore", "RemoraConsoles", "RemoraHosts"]

    func testPortableTargetsImportOnlyFoundation() throws {
        var bad: [String] = []
        for target in Self.portable {
            let dir = Self.root.appendingPathComponent("Sources/\(target)")
            let files = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
            var count = 0
            for case let url as URL in files where url.pathExtension == "swift" {
                count += 1
                let path = url.path.replacingOccurrences(of: Self.root.path + "/", with: "")
                for (line, module) in try Self.imports(in: String(contentsOf: url, encoding: .utf8)) {
                    let sqlite = module == "SQLite3" && path.hasPrefix("Sources/RemoraHosts/SuperRack/")
                    if !Self.allowed.contains(module) && !sqlite { bad.append("\(path):\(line) imports \(module)") }
                }
            }
            XCTAssertGreaterThan(count, 0, "no sources for \(target) at \(dir.path)")
        }
        XCTAssertEqual(bad, [])
    }

    func testTheCheckSeesWhatItShould() {
        let source = """
        import Foundation
        @preconcurrency import Network
        import struct CoreMIDI.MIDIPacket
        #if canImport(AppKit)
        import AppKit
        #endif
        #if DEBUG
        import Combine
        #endif
        """
        XCTAssertEqual(Self.imports(in: source).map(\.module), ["Foundation", "Network", "CoreMIDI", "Combine"])
    }

    /// The imports that apply on every system, with their line numbers: those outside any
    /// `#if canImport(…)` or `#if os(…)` block.
    static func imports(in source: String) -> [(line: Int, module: String)] {
        var out: [(Int, String)] = []
        var guards: [Bool] = []   // per open #if: does it name a system or a module?
        for (i, raw) in source.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if ") {
                guards.append(line.contains("canImport(") || line.contains("os("))
                continue
            }
            if line.hasPrefix("#endif") {
                _ = guards.popLast()
                continue
            }
            var words = line.split(separator: " ").map(String.init)
            while let w = words.first, w.hasPrefix("@") { words.removeFirst() }
            guard words.first == "import", words.count >= 2, !guards.contains(true) else { continue }
            let kinds: Set<String> = ["struct", "class", "enum", "protocol", "typealias", "func", "let", "var"]
            let path = kinds.contains(words[1]) && words.count >= 3 ? words[2] : words[1]
            out.append((i + 1, String(path.split(separator: ".")[0])))
        }
        return out
    }
}

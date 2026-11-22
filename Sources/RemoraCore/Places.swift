import Foundation

/// Where Remora keeps its own files, on each system.
///
/// - macOS: settings in `~/Library/Application Support/Remora`, the log in `~/Library/Logs`.
///   `CFFIXED_USER_HOME` moves both, for a test copy beside the app (AGENTS.md).
/// - Windows: settings in `%APPDATA%\Remora` (roaming, like the Mac's), the log in
///   `%LOCALAPPDATA%\Remora`. Setting either variable moves it, for a test copy.
public enum Places {
    /// The folder settings.json lives in.
    public static var settingsFolder: URL {
        #if os(Windows)
        return windowsFolder("APPDATA", fallback: "AppData/Roaming").appendingPathComponent("Remora", isDirectory: true)
        #else
        return home.appendingPathComponent("Library/Application Support/Remora", isDirectory: true)
        #endif
    }

    /// Remora's log file.
    public static var logFile: URL {
        #if os(Windows)
        return windowsFolder("LOCALAPPDATA", fallback: "AppData/Local").appendingPathComponent("Remora/Remora.log")
        #else
        return home.appendingPathComponent("Library/Logs/Remora.log")
        #endif
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    #if os(Windows)
    private static func windowsFolder(_ variable: String, fallback: String) -> URL {
        if let v = ProcessInfo.processInfo.environment[variable], !v.isEmpty {
            return URL(fileURLWithPath: v, isDirectory: true)
        }
        return home.appendingPathComponent(fallback, isDirectory: true)
    }
    #endif
}

extension ModuleInfo {
    /// Nil where this module runs on this system (its `platforms` has it); else why not, for the
    /// log and the status: "SuperRack (MIDI) runs only on macOS, not Windows".
    public var unavailableHere: String? {
        guard !platforms.contains(.current) else { return nil }
        let on = [OS.macOS, .windows, .linux].filter(platforms.contains).map(\.title)
        return "\(title) runs only on \(on.joined(separator: " or ")), not \(OS.current.title)"
    }
}

extension ModuleInfo.OS {
    /// The system this build runs on.
    public static var current: ModuleInfo.OS {
        #if os(Windows)
        return .windows
        #elseif os(Linux)
        return .linux
        #else
        return .macOS
        #endif
    }

    /// For messages: "macOS", "Windows", "Linux".
    public var title: String {
        switch self {
        case .macOS: return "macOS"
        case .windows: return "Windows"
        case .linux: return "Linux"
        }
    }
}

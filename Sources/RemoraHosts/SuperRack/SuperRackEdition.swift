import Foundation
import RemoraCore

/// Where each SuperRack keeps its app, session and log.
///
/// Performer's were all seen on 15.15 (docs/PROTOCOL.md). SoundGrid's app id is the installed app's
/// (15.15.12), its session file is the one Waves' user guide names, and its log's name follows the
/// one Waves' other apps use (`<app>Application.log`). SoundGrid has not been run.
extension SuperRackEdition {
    public var title: String {
        switch self {
        case .performer: return "Performer"
        case .soundGrid: return "SoundGrid"
        }
    }

    /// "SuperRack Performer": the app's name, and how its main window's title starts.
    public var appName: String { "SuperRack \(title)" }

    public var bundleID: String { "com.WavesAudio.SuperRack-\(title)" }

    public var defaultSessionPath: String {
        switch self {
        case .performer: return Settings.defaultSessionPath
        case .soundGrid: return "/Users/Shared/Waves/SuperRack SoundGrid/Sessions/CurrentSPRK.dat"
        }
    }

    public var logPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Waves Audio/\(appName)Application.log").path
    }
}

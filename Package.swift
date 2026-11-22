// swift-tools-version:5.9
import Foundation
import PackageDescription

// docs/ARCHITECTURE.md says what each target holds. RemoraCore, RemoraConsoles, RemoraHosts,
// RemoraEngine and RemoraCLI import nothing but Foundation (and SQLite for SuperRack's session), so
// they build wherever Swift does; PortabilityTests checks it. Each system's own services are a
// target of their own behind `Platform`: RemoraApple on macOS, RemoraWindows (with RemoraSockets'
// Winsock links) on Windows.
//
// The targets differ by the system building them (docs/ARCHITECTURE.md §8), so this file asks which
// one it is. Remora is built on the system it runs on, never cross-compiled.

#if os(macOS)
let onMac = true
#else
let onMac = false
#endif

/// The module API, the settings model, mapping a channel to a rack, the OSC codec, the log.
let core: Target = .target(
    name: "RemoraCore",
    path: "Sources/RemoraCore"
)

/// Console modules, a folder per maker. Read-only links to the desks.
let consoles: Target = .target(
    name: "RemoraConsoles",
    dependencies: ["RemoraCore"],
    path: "Sources/RemoraConsoles"
)

/// Plug-in host modules, a folder per host: SuperRack's driver, session reader, log reader and
/// plug-in window rules. SQLite is the SDK's on macOS, and Windows' own winsqlite3 through CSQLite.
let hosts: Target = onMac
    ? .target(
        name: "RemoraHosts",
        dependencies: ["RemoraCore"],
        path: "Sources/RemoraHosts",
        linkerSettings: [.linkedLibrary("sqlite3")]
    )
    : .target(
        name: "RemoraHosts",
        dependencies: ["RemoraCore", "CSQLite"],
        path: "Sources/RemoraHosts"
    )

/// The engine (Bridge) and the registry of every module in this build, with this system's
/// platform services.
let engine: Target = .target(
    name: "RemoraEngine",
    dependencies: ["RemoraCore", "RemoraConsoles", "RemoraHosts", onMac ? "RemoraApple" : "RemoraWindows"],
    path: "Sources/RemoraEngine"
)

/// The command line every system shares: --probe, --auto-build, --headless and the rest.
let cli: Target = .target(
    name: "RemoraCLI",
    dependencies: ["RemoraCore", "RemoraConsoles", "RemoraHosts", "RemoraEngine"],
    path: "Sources/RemoraCLI"
)

/// BSD sockets behind `Platform`: Winsock on Windows, POSIX elsewhere. On macOS it is built only so
/// its tests run there too.
let sockets: Target = .target(
    name: "RemoraSockets",
    dependencies: ["RemoraCore"],
    path: "Sources/RemoraSockets",
    linkerSettings: [.linkedLibrary("ws2_32", .when(platforms: [.windows]))]
)

/// Windows' platform services: RemoraSockets' links, MIDI through WinMM, and staying awake. Its
/// rules (which port, which inputs, when 1 ms timers) are plain Swift, built on macOS too so its
/// tests run there; the Windows calls build only on Windows.
let windowsPlatform: Target = .target(
    name: "RemoraWindows",
    dependencies: ["RemoraCore", "RemoraSockets"],
    path: "Sources/RemoraWindows",
    linkerSettings: [
        .linkedLibrary("winmm", .when(platforms: [.windows])),
        .linkedLibrary("advapi32", .when(platforms: [.windows])),
    ]
)

let portable: [Target.Dependency] = ["RemoraCore", "RemoraConsoles", "RemoraHosts", "RemoraEngine", "RemoraCLI"]

let mac: [Target] = [
    // macOS's platform services: Network.framework, CoreMIDI, and Accessibility for SuperRack's
    // plug-in windows.
    .target(
        name: "RemoraApple",
        dependencies: ["RemoraCore", "RemoraHosts"],
        path: "Sources/RemoraApple",
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("ApplicationServices"),
            .linkedFramework("CoreMIDI"),
            .linkedFramework("Network"),
        ]
    ),
    // The menu-bar app and its command line.
    .executableTarget(
        name: "Remora",
        dependencies: portable + ["RemoraApple"],
        path: "Sources/Remora",
        exclude: ["Windows"],
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("SwiftUI"),
        ]
    ),
    .testTarget(
        name: "RemoraCoreTests",
        dependencies: portable + ["RemoraApple", "RemoraSockets", "RemoraWindows"],
        path: "Tests/RemoraCoreTests",
        exclude: ["Fixtures"]   // read by path (#filePath), not as resources
    ),
]

/// The Mac app's own files in Sources/Remora, which Remora.exe leaves out (named, so SwiftPM
/// doesn't warn about them).
let macApp: [String] = ((try? FileManager.default.contentsOfDirectory(
    atPath: Context.packageDirectory + "/Sources/Remora")) ?? [])
    .filter { $0.hasSuffix(".swift") && $0 != "Version.swift" }

let windows: [Target] = [
    // SQLite for SuperRack's session: Windows' own winsqlite3 (Linux's libsqlite3), so nothing is
    // bundled.
    .target(
        name: "CSQLite",
        path: "Sources/CSQLite",
        linkerSettings: [
            .linkedLibrary("winsqlite3", .when(platforms: [.windows])),
            .linkedLibrary("sqlite3", .when(platforms: [.linux])),
        ]
    ),
    // Remora.exe: the engine headless, and the same command line. One version: Version.swift.
    .executableTarget(
        name: "Remora",
        dependencies: portable + ["RemoraWindows"],
        path: "Sources/Remora",
        exclude: macApp,
        sources: ["Version.swift", "Windows"]
    ),
    .testTarget(
        name: "RemoraCoreTests",
        dependencies: portable + ["RemoraSockets", "RemoraWindows", "CSQLite"],
        path: "Tests/RemoraCoreTests",
        exclude: ["Fixtures"]
    ),
]

let package = Package(
    name: "Remora",
    platforms: [.macOS(.v13)],
    targets: [core, consoles, hosts, engine, cli, sockets, windowsPlatform] + (onMac ? mac : windows)
)

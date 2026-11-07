// swift-tools-version:5.9
import PackageDescription

// docs/ARCHITECTURE.md says what each target holds. RemoraCore, RemoraConsoles and RemoraHosts
// import nothing but Foundation (and SQLite for SuperRack's session), so they build wherever Swift
// does; PortabilityTests checks it. Everything macOS-only is in RemoraApple.
let package = Package(
    name: "Remora",
    platforms: [.macOS(.v13)],
    targets: [
        // The module API, the settings model, mapping a channel to a rack, the OSC codec, the log.
        .target(
            name: "RemoraCore",
            path: "Sources/RemoraCore"
        ),
        // Console modules, a folder per maker. Read-only links to the desks.
        .target(
            name: "RemoraConsoles",
            dependencies: ["RemoraCore"],
            path: "Sources/RemoraConsoles"
        ),
        // Plug-in host modules, a folder per host: SuperRack's driver, session reader, log reader
        // and plug-in window rules.
        .target(
            name: "RemoraHosts",
            dependencies: ["RemoraCore"],
            path: "Sources/RemoraHosts",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
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
        // The engine (Bridge) and the registry of every module in this build.
        .target(
            name: "RemoraEngine",
            dependencies: [
                "RemoraCore", "RemoraConsoles", "RemoraHosts",
                .target(name: "RemoraApple", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/RemoraEngine"
        ),
        .executableTarget(
            name: "Remora",
            dependencies: ["RemoraCore", "RemoraConsoles", "RemoraHosts", "RemoraApple", "RemoraEngine"],
            path: "Sources/Remora",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "RemoraCoreTests",
            dependencies: ["RemoraCore", "RemoraConsoles", "RemoraHosts", "RemoraApple", "RemoraEngine"],
            path: "Tests/RemoraCoreTests"
        ),
    ]
)

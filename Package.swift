// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Remora",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything that can be tested without a window: the console links, the SuperRack
        // session reader and driver, the mapping file, OSC, the settings model, and SuperRack's
        // log reader and plug-in window rules.
        .target(
            name: "RemoraCore",
            path: "Sources/RemoraCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("Network"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "Remora",
            dependencies: ["RemoraCore"],
            path: "Sources/Remora",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "RemoraCoreTests",
            dependencies: ["RemoraCore"],
            path: "Tests/RemoraCoreTests"
        ),
    ]
)

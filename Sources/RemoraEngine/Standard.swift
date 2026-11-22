import Foundation
import RemoraConsoles
import RemoraCore
import RemoraHosts
#if canImport(RemoraApple)
import RemoraApple
#elseif os(Windows)
import RemoraWindows
#elseif canImport(RemoraSockets)
import RemoraSockets
#endif

extension ModuleRegistry {
    /// Every module in this build.
    public static let standard = ModuleRegistry(consoles: RemoraConsoles.all, hosts: RemoraHosts.all)
}

extension Bridge {
    /// This system's platform services: RemoraApple's on macOS, RemoraWindows' on Windows (TCP, UDP
    /// and OSC on Winsock, MIDI through WinMM; docs/ARCHITECTURE.md §8), and RemoraSockets' with no
    /// MIDI elsewhere.
    public static func defaultPlatform() -> Platform {
        #if canImport(RemoraApple)
        return ApplePlatform()
        #elseif os(Windows)
        return WindowsPlatform()
        #elseif canImport(RemoraSockets)
        return SocketPlatform()
        #else
        fatalError("Remora has no platform services for this system yet (docs/ARCHITECTURE.md)")
        #endif
    }
}

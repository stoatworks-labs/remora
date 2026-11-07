import Foundation

extension ModuleRegistry {
    /// Every module in this build.
    public static let standard = ModuleRegistry(consoles: RemoraConsoles.all, hosts: RemoraHosts.all)
}

extension Bridge {
    /// This system's platform services.
    public static func defaultPlatform() -> Platform { ApplePlatform() }
}

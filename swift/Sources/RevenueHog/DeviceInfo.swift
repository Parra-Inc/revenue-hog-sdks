import Foundation

/// Device context sent with `identify`. Nothing here is an identifier:
/// no IDFA, no IDFV, no fingerprinting. Just enough for a customer profile.
struct DeviceInfo: Sendable {
    var bundleId: String
    var platform: String
    var osVersion: String?
    var deviceModel: String?
    var locale: String?

    /// Compile-time simulator flag, passed through an init parameter so
    /// tests can exercise the simulator path on any host.
    static let isSimulator: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()

    static func current() -> DeviceInfo {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var systemInfo = utsname()
        uname(&systemInfo)
        let model = withUnsafeBytes(of: &systemInfo.machine) { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return DeviceInfo(
            bundleId: Bundle.main.bundleIdentifier ?? "unknown",
            platform: "ios",
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            deviceModel: model,
            locale: Locale.current.identifier
        )
    }
}

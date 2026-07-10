import Foundation

/// How chatty the SDK is. Everything logs with a `[revenuehog]` prefix.
/// Nothing the SDK logs is ever fatal — errors are swallowed by design.
public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3
    case silent = 4

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Optional knobs for `RevenueHog.configure(apiKey:options:)`.
public struct Options: Sendable {
    /// API host. Override for self-hosted deployments or local dev.
    public var baseURL: URL

    /// When `true` (default) the SDK listens to StoreKit 2
    /// `Transaction.updates` and reports attribution for every verified
    /// transaction automatically.
    public var enableAutoAttribution: Bool

    /// Defaults to `.warn`.
    public var logLevel: LogLevel

    public init(
        baseURL: URL = URL(string: "https://revenuehog.dev")!,
        enableAutoAttribution: Bool = true,
        logLevel: LogLevel = .warn
    ) {
        self.baseURL = baseURL
        self.enableAutoAttribution = enableAutoAttribution
        self.logLevel = logLevel
    }
}

struct Logger: Sendable {
    let level: LogLevel

    func debug(_ message: @autoclosure () -> String) { emit(.debug, message()) }
    func info(_ message: @autoclosure () -> String) { emit(.info, message()) }
    func warn(_ message: @autoclosure () -> String) { emit(.warn, message()) }
    func error(_ message: @autoclosure () -> String) { emit(.error, message()) }

    private func emit(_ at: LogLevel, _ message: String) {
        guard at >= level, level != .silent else { return }
        print("[revenuehog] \(message)")
    }
}

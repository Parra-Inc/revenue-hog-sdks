import Foundation

/// Verifies the host app was built with the App Attest entitlement by
/// parsing its own Mach-O code signature. Misconfiguration is loud in
/// DEBUG and a single log line in RELEASE; it never crashes a release
/// build and never runs on the simulator (unattested by design).
enum EntitlementCheck {
    static let entitlementKey = "com.apple.developer.devicecheck.appattest-environment"

    private static let warned = OnceFlag()

    /// Called once from `configure()`.
    static func run(log: Logger) {
        #if targetEnvironment(simulator)
        _ = log // simulator sessions are unattested by design; nothing to check
        #else
        guard let url = Bundle.main.executableURL,
              let binary = try? Data(contentsOf: url, options: .mappedIfSafe),
              hasAppAttestEntitlement(machO: binary) == false,
              warned.trip()
        else { return }
        #if DEBUG
        print("""
        [revenuehog] ============================================================
        [revenuehog] ERROR: App Attest entitlement missing.
        [revenuehog] This app was built without
        [revenuehog]   \(entitlementKey)
        [revenuehog] so RevenueHog cannot enroll the device and all writes will
        [revenuehog] be quarantined as unverified.
        [revenuehog] Fix: add the App Attest capability to the app target
        [revenuehog] (Signing & Capabilities > + Capability > App Attest).
        [revenuehog] ============================================================
        """)
        assertionFailure("RevenueHog: App Attest entitlement missing. Add the App Attest capability to the app target.")
        #else
        log.error("App Attest entitlement missing, running unattested. Add the App Attest capability to the app target.")
        #endif
        #endif
    }

    // MARK: - Pure Mach-O parsing (unit-tested against fixture bytes)

    /// True/false when the binary answers definitively; nil when the bytes
    /// do not parse as a signed 64-bit Mach-O. Callers must never warn on
    /// nil: an unreadable binary is not proof of a missing entitlement.
    static func hasAppAttestEntitlement(machO data: Data) -> Bool? {
        guard let signature = codeSignature(machO: data) else { return nil }
        return (entitlementsXML(signature: signature) ?? "").contains(entitlementKey)
    }

    /// Extracts the LC_CODE_SIGNATURE superblob from a thin 64-bit Mach-O.
    /// Header fields are little-endian; the signature blobs are big-endian.
    static func codeSignature(machO data: Data) -> Data? {
        guard readU32(data, at: 0, bigEndian: false) == 0xfeedfacf, // MH_MAGIC_64
              let ncmds = readU32(data, at: 16, bigEndian: false)
        else { return nil }
        var offset = 32 // sizeof(mach_header_64)
        for _ in 0..<min(ncmds, 1024) {
            guard let cmd = readU32(data, at: offset, bigEndian: false),
                  let cmdsize = readU32(data, at: offset + 4, bigEndian: false),
                  cmdsize >= 8
            else { return nil }
            if cmd == 0x1d { // LC_CODE_SIGNATURE
                guard let dataoff = readU32(data, at: offset + 8, bigEndian: false),
                      let datasize = readU32(data, at: offset + 12, bigEndian: false),
                      datasize >= 12,
                      let end = Int(exactly: UInt64(dataoff) + UInt64(datasize)),
                      end <= data.count
                else { return nil }
                let blob = data.subdata(in: Int(dataoff)..<end)
                // Require the embedded-signature magic so a garbage range
                // can never read as "entitlement absent".
                guard readU32(blob, at: 0, bigEndian: true) == 0xfade0cc0 else { return nil }
                return blob
            }
            offset += Int(cmdsize)
        }
        return nil
    }

    /// The entitlements plist inside a signature superblob, or nil when
    /// the superblob carries no (readable) entitlements slot.
    static func entitlementsXML(signature: Data) -> String? {
        guard let count = readU32(signature, at: 8, bigEndian: true) else { return nil }
        for index in 0..<min(count, 64) {
            let entry = 12 + Int(index) * 8
            guard let type = readU32(signature, at: entry, bigEndian: true),
                  let blobOffset = readU32(signature, at: entry + 4, bigEndian: true)
            else { return nil }
            guard type == 5 else { continue } // CSSLOT_ENTITLEMENTS
            let start = Int(blobOffset)
            guard readU32(signature, at: start, bigEndian: true) == 0xfade7171,
                  let length = readU32(signature, at: start + 4, bigEndian: true),
                  length >= 8,
                  start + Int(length) <= signature.count
            else { return nil }
            return String(
                data: signature.subdata(in: (start + 8)..<(start + Int(length))),
                encoding: .utf8
            )
        }
        return nil
    }

    private static func readU32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, data.count - offset >= 4 else { return nil }
        let start = data.startIndex + offset
        let b0 = UInt32(data[start])
        let b1 = UInt32(data[start + 1])
        let b2 = UInt32(data[start + 2])
        let b3 = UInt32(data[start + 3])
        return bigEndian
            ? (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            : (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }
}

/// Trips exactly once for the process lifetime.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false

    func trip() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if tripped { return false }
        tripped = true
        return true
    }
}

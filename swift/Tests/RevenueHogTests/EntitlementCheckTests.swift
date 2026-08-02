import XCTest
@testable import RevenueHog

/// Exercises the pure Mach-O parser against synthetic fixture bytes:
/// a minimal 64-bit header, one LC_CODE_SIGNATURE load command, and a
/// hand-built signature superblob.
final class EntitlementCheckTests: XCTestCase {
    private let withKey = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
      <key>com.apple.developer.devicecheck.appattest-environment</key>
      <string>production</string>
    </dict></plist>
    """

    private let withoutKey = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
      <key>aps-environment</key>
      <string>production</string>
    </dict></plist>
    """

    func testDetectsEntitlementWhenPresent() {
        let binary = machO(signature: superblob(entitlements: withKey))
        XCTAssertEqual(EntitlementCheck.hasAppAttestEntitlement(machO: binary), true)
    }

    func testDetectsEntitlementAbsentFromPlist() {
        let binary = machO(signature: superblob(entitlements: withoutKey))
        XCTAssertEqual(EntitlementCheck.hasAppAttestEntitlement(machO: binary), false)
    }

    func testMissingEntitlementsSlotReadsAsAbsent() {
        let binary = machO(signature: superblob(entitlements: nil))
        XCTAssertEqual(EntitlementCheck.hasAppAttestEntitlement(machO: binary), false)
    }

    func testNonMachOBytesAreIndeterminate() {
        let garbage = Data("definitely not an executable".utf8)
        XCTAssertNil(EntitlementCheck.hasAppAttestEntitlement(machO: garbage))
    }

    func testGarbageSignatureBlobIsIndeterminate() {
        // valid header and load command, but the signature range holds junk
        let binary = machO(signature: Data("junk junk junk junk".utf8))
        XCTAssertNil(EntitlementCheck.hasAppAttestEntitlement(machO: binary))
    }

    func testTruncatedBinaryIsIndeterminate() {
        let binary = machO(signature: superblob(entitlements: withKey))
        XCTAssertNil(EntitlementCheck.hasAppAttestEntitlement(machO: binary.prefix(40)))
    }

    func testEmptyDataIsIndeterminate() {
        XCTAssertNil(EntitlementCheck.hasAppAttestEntitlement(machO: Data()))
    }

    // MARK: - Fixture builders

    private func u32LE(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private func u32BE(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    /// Thin arm64 Mach-O: 32-byte header + one 16-byte LC_CODE_SIGNATURE
    /// command pointing at `signature` appended right after.
    private func machO(signature: Data) -> Data {
        var data = Data()
        data += u32LE(0xfeedfacf)             // MH_MAGIC_64
        data += u32LE(0x0100000c)             // cputype arm64
        data += u32LE(0)                      // cpusubtype
        data += u32LE(2)                      // filetype MH_EXECUTE
        data += u32LE(1)                      // ncmds
        data += u32LE(16)                     // sizeofcmds
        data += u32LE(0)                      // flags
        data += u32LE(0)                      // reserved
        data += u32LE(0x1d)                   // LC_CODE_SIGNATURE
        data += u32LE(16)                     // cmdsize
        data += u32LE(48)                     // dataoff (header + command)
        data += u32LE(UInt32(signature.count))
        data += signature
        return data
    }

    /// CSMAGIC_EMBEDDED_SIGNATURE superblob with an optional entitlements
    /// blob (CSSLOT_ENTITLEMENTS / 0xfade7171).
    private func superblob(entitlements xml: String?) -> Data {
        var entries = Data()
        var blobs = Data()
        let count: UInt32 = xml == nil ? 0 : 1
        let indexSize = 12 + Int(count) * 8
        if let xml {
            var blob = u32BE(0xfade7171)
            blob += u32BE(UInt32(8 + xml.utf8.count))
            blob += Data(xml.utf8)
            entries += u32BE(5)               // CSSLOT_ENTITLEMENTS
            entries += u32BE(UInt32(indexSize))
            blobs += blob
        }
        var data = u32BE(0xfade0cc0)          // CSMAGIC_EMBEDDED_SIGNATURE
        data += u32BE(UInt32(indexSize + blobs.count))
        data += u32BE(count)
        data += entries
        data += blobs
        return data
    }
}

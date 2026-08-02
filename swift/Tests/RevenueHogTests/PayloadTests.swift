import XCTest
@testable import RevenueHog

final class PayloadTests: XCTestCase {
    func testIdentifyPayloadEncodesAllFields() throws {
        let payload = IdentifyPayload(
            appUserId: "user_1",
            bundleId: "com.example.app",
            platform: "ios",
            osVersion: "17.0.0",
            deviceModel: "iPhone15,2",
            locale: "en_US",
            attributes: ["plan": "pro"]
        )
        let data = try Payloads.encoder.encode(payload)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["appUserId"] as? String, "user_1")
        XCTAssertEqual(json["bundleId"] as? String, "com.example.app")
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertEqual(json["osVersion"] as? String, "17.0.0")
        XCTAssertEqual(json["deviceModel"] as? String, "iPhone15,2")
        XCTAssertEqual(json["locale"] as? String, "en_US")
        XCTAssertEqual(json["attributes"] as? [String: String], ["plan": "pro"])
    }

    func testIdentifyPayloadOmitsNilFields() throws {
        let payload = IdentifyPayload(
            appUserId: "u", bundleId: "b", platform: "ios",
            osVersion: nil, deviceModel: nil, locale: nil, attributes: nil
        )
        let data = try Payloads.encoder.encode(payload)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), ["appUserId", "bundleId", "platform"])
    }

    func testAttributePayloadEncoding() throws {
        let payload = AttributePayload(
            appUserId: "user_1",
            bundleId: "com.example.app",
            originalTransactionId: "2000000123456789",
            productId: "pro.monthly",
            jws: "eyJhbGciOi.fake.sig"
        )
        let data = try Payloads.encoder.encode(payload)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["appUserId"] as? String, "user_1")
        XCTAssertEqual(json["originalTransactionId"] as? String, "2000000123456789")
        XCTAssertEqual(json["productId"] as? String, "pro.monthly")
        XCTAssertEqual(json["bundleId"] as? String, "com.example.app")
        XCTAssertEqual(json["jws"] as? String, "eyJhbGciOi.fake.sig")
    }

    func testAttributePayloadOmitsNilJws() throws {
        let payload = AttributePayload(
            appUserId: "u", bundleId: "b", originalTransactionId: "t"
        )
        let data = try Payloads.encoder.encode(payload)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), ["appUserId", "bundleId", "originalTransactionId"])
    }

    func testAttestPayloadEncoding() throws {
        let payload = AttestPayload(
            keyId: "a2V5",
            attestation: "Y2Jvcg==",
            challenge: "aGVsbG8",
            bundleId: "com.example.app"
        )
        let data = try Payloads.encoder.encode(payload)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["keyId"] as? String, "a2V5")
        XCTAssertEqual(json["attestation"] as? String, "Y2Jvcg==")
        XCTAssertEqual(json["challenge"] as? String, "aGVsbG8")
        XCTAssertEqual(json["bundleId"] as? String, "com.example.app")
    }
}

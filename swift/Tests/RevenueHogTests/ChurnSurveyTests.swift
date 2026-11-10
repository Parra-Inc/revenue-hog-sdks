import XCTest
@testable import RevenueHog

/// Seeded generator so shuffles are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

final class ChurnSurveyTests: XCTestCase {
    private let surveyJSON = """
    {"survey":{"version":3,"title":"Why are you leaving?","options":[\
    {"key":"too_expensive","title":"It's too expensive"},{"key":"not_using","title":"I don't use it enough"},\
    {"key":"missing_feature","title":"Missing a feature"},{"key":"found_another_app","title":"Found another app"}],\
    "other":{"enabled":true,"placeholder":"Tell us more","key":"other"},"randomize":true,\
    "trigger":{"onAutoRenewOff":true,"maxPerUserDays":90},"sampleRate":1},"show":true,"reason":null}
    """

    private func options(_ keys: [String]) -> [ChurnSurveyOption] {
        keys.map { ChurnSurveyOption(key: $0, title: $0) }
    }

    func testOrderKeepsOtherOutAndShownOrderPutsItLast() {
        var rng = SeededGenerator(state: 7)
        let ordered = ChurnSurveyRules.order(options(["a1", "b1", "other", "c1", "d1"]), randomize: true, using: &rng)
        XCTAssertEqual(Set(ordered.map(\.key)), ["a1", "b1", "c1", "d1"])
        let shown = ChurnSurveyRules.shownOrder(ordered, otherEnabled: true)
        XCTAssertEqual(shown.last, "other")
        XCTAssertEqual(shown.count, 5)
    }

    func testShuffleActuallyVariesAndCanBeTurnedOff() {
        var seen = Set<[String]>()
        var rng = SeededGenerator(state: 1)
        for _ in 0..<30 {
            seen.insert(ChurnSurveyRules.order(options(["a1", "b1", "c1", "d1"]), randomize: true, using: &rng).map(\.key))
        }
        XCTAssertGreaterThan(seen.count, 1)
        let fixed = ChurnSurveyRules.order(options(["a1", "b1", "c1"]), randomize: false, using: &rng)
        XCTAssertEqual(fixed.map(\.key), ["a1", "b1", "c1"])
    }

    func testFrequencyCap() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(ChurnSurveyRules.isCapped(lastShownAt: nil, now: now, maxPerUserDays: 90))
        XCTAssertTrue(ChurnSurveyRules.isCapped(lastShownAt: now.addingTimeInterval(-89 * 86_400), now: now, maxPerUserDays: 90))
        XCTAssertFalse(ChurnSurveyRules.isCapped(lastShownAt: now.addingTimeInterval(-91 * 86_400), now: now, maxPerUserDays: 90))
        XCTAssertFalse(ChurnSurveyRules.isCapped(lastShownAt: now, now: now, maxPerUserDays: 0))
    }

    func testSamplingMatchesServerHashAndBounds() {
        // FNV-1a("a") is 0xe40c292c, the same value the server's fnv1a returns.
        XCTAssertEqual(ChurnSurveyRules.fnv1a("a"), 0xe40c_292c)
        XCTAssertTrue(ChurnSurveyRules.inSample(1, seed: "x"))
        XCTAssertFalse(ChurnSurveyRules.inSample(0, seed: "x"))
        XCTAssertEqual(ChurnSurveyRules.inSample(0.5, seed: "u1"), ChurnSurveyRules.inSample(0.5, seed: "u1"))
        let hits = (0..<2000).filter { ChurnSurveyRules.inSample(0.25, seed: "user_\($0)") }.count
        XCTAssertTrue((350...650).contains(hits), "got \(hits)")
    }

    func testNewlyCancelledOnlyOncePerCancellation() {
        var r = ChurnSurveyRules.newlyCancelled(renewals: [("t1", false), ("t2", true)], handled: [])
        XCTAssertEqual(r.fresh, ["t1"])
        r = ChurnSurveyRules.newlyCancelled(renewals: [("t1", false)], handled: ["t1"])
        XCTAssertEqual(r.fresh, [])
        // Auto-renew back on clears it, so the next cancel asks again.
        r = ChurnSurveyRules.newlyCancelled(renewals: [("t1", true)], handled: ["t1"])
        XCTAssertEqual(r.handled, [])
    }

    func testFetchSendsQueryAndAppliesLocalCap() async {
        let store = MemoryStore()
        let transport = MockTransport(script: [.json(200, surveyJSON), .json(200, surveyJSON)])
        let client = TestSupport.makeClient(transport: transport, store: store)

        let survey = await client.churnSurvey()
        XCTAssertEqual(survey?.version, 3)
        XCTAssertEqual(survey?.shownOrder.last, "other")
        XCTAssertEqual(Set(survey?.options.map(\.key) ?? []), ["too_expensive", "not_using", "missing_feature", "found_another_app"])
        let request = transport.recorded.first
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.url.path, "/api/sdk/v1/churn-survey")
        let query = URLComponents(url: request!.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "bundleId" })?.value, "com.example.app")
        XCTAssertEqual(query.first(where: { $0.name == "locale" })?.value, "en_US")
        XCTAssertEqual(request?.headers["Authorization"], "Bearer dt_test_123")

        await client.churnSurveyShown()
        let again = await client.churnSurvey()
        XCTAssertNil(again)
    }

    func testServerShowFalseIsRespected() async {
        let transport = MockTransport(script: [.json(200, #"{"survey":null,"show":false,"reason":"not_configured"}"#)])
        let client = TestSupport.makeClient(transport: transport)
        let survey = await client.churnSurvey()
        XCTAssertNil(survey)
    }

    func testAutoTriggerOffInConfigSkipsAutomaticButNotManual() async {
        let json = surveyJSON.replacingOccurrences(of: #""onAutoRenewOff":true"#, with: #""onAutoRenewOff":false"#)
        let transport = MockTransport(script: [.json(200, json), .json(200, json)])
        let client = TestSupport.makeClient(transport: transport)
        let automatic = await client.churnSurvey(ignoreTrigger: false)
        XCTAssertNil(automatic)
        let manual = await client.churnSurvey(ignoreTrigger: true)
        XCTAssertNotNil(manual)
    }

    func testSubmitPostsAnswerWithShownOrder() async {
        let transport = MockTransport(script: [.json(200, surveyJSON)])
        let client = TestSupport.makeClient(transport: transport)
        let survey = await client.churnSurvey()!
        await client.submitChurnSurvey(survey, result: .other("  Only needed it for tax season "), productId: "pro.monthly")

        let post = transport.recorded.last
        XCTAssertEqual(post?.url.path, "/api/sdk/v1/churn-survey/response")
        XCTAssertEqual(post?.json["otherText"] as? String, "Only needed it for tax season")
        XCTAssertNil(post?.json["optionKey"])
        XCTAssertEqual(post?.json["shownOrder"] as? [String], survey.shownOrder)
        XCTAssertEqual(post?.json["surveyVersion"] as? Int, 3)
        XCTAssertEqual(post?.json["productId"] as? String, "pro.monthly")
        XCTAssertEqual((post?.json["responseId"] as? String)?.isEmpty, false)
    }

    func testAdditionalInfoIsSentOnlyWhenAllowed() async {
        let on = surveyJSON.replacingOccurrences(of: #""randomize""#, with: #""allowAdditionalInfo":true,"randomize""#)
        let transport = MockTransport(script: [.json(200, on)])
        let client = TestSupport.makeClient(transport: transport)
        let survey = await client.churnSurvey()!
        XCTAssertTrue(survey.allowAdditionalInfo)
        await client.submitChurnSurvey(survey, result: .option("not_using", additionalInfo: "  Yearly please "), productId: nil)
        XCTAssertEqual(transport.recorded.last?.json["additionalInfo"] as? String, "Yearly please")
        XCTAssertEqual(transport.recorded.last?.json["optionKey"] as? String, "not_using")

        await client.submitChurnSurvey(survey, result: .other("Seasonal", additionalInfo: "   "), productId: nil)
        XCTAssertNil(transport.recorded.last?.json["additionalInfo"])
    }

    func testAdditionalInfoIsNeverSentWhenOff() async {
        let transport = MockTransport(script: [.json(200, surveyJSON)])
        let client = TestSupport.makeClient(transport: transport)
        let survey = await client.churnSurvey()!
        XCTAssertFalse(survey.allowAdditionalInfo)
        await client.submitChurnSurvey(survey, result: .option("not_using", additionalInfo: "Yearly please"), productId: nil)
        XCTAssertNil(transport.recorded.last?.json["additionalInfo"])
        XCTAssertEqual(transport.recorded.last?.json["optionKey"] as? String, "not_using")
    }

    func testSkipIsRecordedAsSkipped() async {
        let transport = MockTransport(script: [.json(200, surveyJSON)])
        let client = TestSupport.makeClient(transport: transport)
        let survey = await client.churnSurvey()!
        await client.submitChurnSurvey(survey, result: .skipped, productId: nil)
        XCTAssertEqual(transport.recorded.last?.json["skipped"] as? Bool, true)
    }
}

final class OpenPingTests: XCTestCase {
    func testSendsOncePerUtcDay() async {
        let store = MemoryStore()
        let transport = MockTransport()
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = Clock(day1)
        let client = TestSupport.makeClient(transport: transport, store: store, now: { clock.value })

        await client.sendDailyOpen()
        await client.sendDailyOpen()
        XCTAssertEqual(transport.recorded.filter { $0.url.path == "/api/sdk/v1/open" }.count, 1)
        let body = transport.recorded.first?.json
        XCTAssertTrue((body?["appUserId"] as? String)?.hasPrefix("$anon_") == true)
        XCTAssertEqual(body?["bundleId"] as? String, "com.example.app")

        clock.value = day1.addingTimeInterval(86_400)
        await client.sendDailyOpen()
        XCTAssertEqual(transport.recorded.filter { $0.url.path == "/api/sdk/v1/open" }.count, 2)
    }

    func testFailedOpenIsRetriedNextLaunch() async {
        let store = MemoryStore()
        let transport = MockTransport(script: [.networkError, .networkError])
        let client = TestSupport.makeClient(transport: transport, store: store)
        await client.sendDailyOpen()
        await client.sendDailyOpen()
        XCTAssertEqual(transport.recorded.count, 3)
    }

    func testFirstIdentifySendsAnonymousIdForMerge() async {
        let transport = MockTransport()
        let client = TestSupport.makeClient(transport: transport)
        let anon = await client.appUserId
        await client.identify(userId: "user_1")
        await client.identify(userId: "user_2")
        let identifies = transport.recorded.filter { $0.url.path == "/api/sdk/v1/identify" }
        XCTAssertEqual(identifies.first?.json["anonymousAppUserId"] as? String, anon)
        XCTAssertNil(identifies.last?.json["anonymousAppUserId"])
    }
}

final class Clock: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

import XCTest
@testable import RevenueHog

final class ChurnSurveyStringsTests: XCTestCase {
    func testEnglishLabels() {
        XCTAssertEqual(ChurnSurveyStrings.localized("churn_survey.other", "x", localization: "en"), "Other")
        XCTAssertEqual(ChurnSurveyStrings.localized("churn_survey.skip", "x", localization: "en"), "Skip")
        XCTAssertEqual(ChurnSurveyStrings.localized("churn_survey.send", "x", localization: "en"), "Send")
    }

    func testBundledTranslations() {
        XCTAssertEqual(ChurnSurveyStrings.localized("churn_survey.skip", "Skip", localization: "de"), "Überspringen")
        XCTAssertEqual(ChurnSurveyStrings.localized("churn_survey.send", "Send", localization: "ja"), "送信")
        XCTAssertEqual(ChurnSurveyStrings.localized("churn_survey.other", "Other", localization: "zh-Hant"), "其他")
        XCTAssertEqual(ChurnSurveyStrings.localized("churn_survey.skip", "Skip", localization: "pt-BR"), "Pular")
    }

    func testEveryLocaleHasEveryKey() {
        let locales = ["ar", "de", "en", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt-BR", "pt-PT",
                       "ru", "sv", "tr", "zh-Hans", "zh-Hant"]
        for locale in locales {
            for key in ["churn_survey.other", "churn_survey.skip", "churn_survey.send"] {
                let value = ChurnSurveyStrings.localized(key, "MISSING", localization: locale)
                XCTAssertNotEqual(value, "MISSING", "\(locale) \(key)")
                XCTAssertNotEqual(value, key, "\(locale) \(key)")
            }
        }
    }

    func testUnknownLocaleFallsBack() {
        XCTAssertFalse(ChurnSurveyStrings.localized("churn_survey.send", "Send", localization: "xx").isEmpty)
    }
}

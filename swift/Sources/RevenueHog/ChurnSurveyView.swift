#if canImport(SwiftUI) && canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

/// The built-in churn survey sheet: a single-choice list with an optional
/// "Other" text field, Skip and Send.
@available(iOS 15.0, tvOS 15.0, *)
struct ChurnSurveyView: View {
    let survey: ChurnSurvey
    let onFinish: (ChurnSurveyResult) -> Void

    @State private var selection: String?
    @State private var otherText = ""

    private var canSend: Bool {
        guard let selection else { return false }
        if selection == ChurnSurveyRules.otherKey {
            return !otherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    ForEach(survey.options) { option in
                        row(key: option.key, title: option.title)
                    }
                    if survey.otherEnabled {
                        row(key: ChurnSurveyRules.otherKey, title: ChurnSurveyStrings.other)
                        if selection == ChurnSurveyRules.otherKey {
                            TextField(survey.otherPlaceholder, text: $otherText)
                        }
                    }
                }
            }
            .navigationTitle(survey.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChurnSurveyStrings.skip) { onFinish(.skipped) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ChurnSurveyStrings.send) { send() }.disabled(!canSend)
                }
            }
        }
    }

    private func row(key: String, title: String) -> some View {
        Button {
            selection = key
        } label: {
            HStack {
                Text(title).foregroundColor(.primary)
                Spacer()
                Image(systemName: selection == key ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(.accentColor)
            }
        }
        .accessibilityAddTraits(selection == key ? .isSelected : [])
    }

    private func send() {
        guard let selection else { return }
        if selection == ChurnSurveyRules.otherKey {
            onFinish(.other(otherText))
        } else {
            onFinish(.option(selection))
        }
    }
}

enum ChurnSurveyPresenter {
    /// Presents the survey over the top view controller of the foreground
    /// window and waits for an answer. `.notShown` when there is no window.
    @MainActor
    static func present(_ survey: ChurnSurvey) async -> ChurnSurveyResult {
        guard #available(iOS 15.0, tvOS 15.0, *), let top = topViewController() else { return .notShown }
        return await withCheckedContinuation { continuation in
            var finished = false
            var host: UIViewController?
            let view = ChurnSurveyView(survey: survey) { result in
                guard !finished else { return }
                finished = true
                host?.dismiss(animated: true)
                continuation.resume(returning: result)
            }
            let controller = UIHostingController(rootView: view)
            controller.isModalInPresentation = true
            host = controller
            top.present(controller, animated: true)
        }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
#else
enum ChurnSurveyPresenter {
    @MainActor
    static func present(_ survey: ChurnSurvey) async -> ChurnSurveyResult { .notShown }
}
#endif

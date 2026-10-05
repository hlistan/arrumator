import SwiftUI

/// The first run, step by step: what the app does, the folders and how it runs, Ollama, the models, and then the app.
/// Each step fills the window down to the buttons, its title above it; Return continues.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = Step.welcome

    /// The steps, in order.
    private enum Step: Int {
        case welcome, folders, ollama, models, ready
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Style.onboardingSpacing) {
            Group {
                switch step {
                case .welcome: welcome
                case .folders: folders
                case .ollama: ollama
                case .models: models
                case .ready: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if let previous = Step(rawValue: step.rawValue - 1) { Button(Wording.back) { step = previous } }
                Spacer()
                if let next = Step(rawValue: step.rawValue + 1) {
                    Button(Wording.continueStep) { step = next }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    Button(Wording.start) {
                        Task {
                            await model.finishOnboarding()
                            model.close(.onboarding)
                            model.show(.main)
                        }
                    }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(Style.onboardingPadding)
        .frame(width: Style.onboardingWindow.width, height: Style.onboardingWindow.height)
        .showsLastError()
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Style.onboardingStepSpacing) {
            Text(Wording.welcome).font(.largeTitle.bold())
            Text(Wording.welcomeIntro)
            // The symbols are as wide as each other, so the sentences beside them start in line.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Style.onboardingBulletSpacing,
                 verticalSpacing: Style.onboardingStepSpacing) {
                bullet(Wording.welcomeLocal, symbol: "lock.shield")
                bullet(Wording.welcomeNoFolders, symbol: "tag")
                bullet(Wording.welcomeLabels, symbol: "square.and.pencil")
            }
        }
    }

    private func bullet(_ text: String, symbol: String) -> some View {
        GridRow {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: Style.onboardingBulletWidth).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: Style.onboardingStepSpacing) {
            Text(Wording.chooseFolders).font(.title.bold())
            if let settings = model.settings { GeneralSettings(loaded: settings).frame(maxHeight: .infinity) }
        }
    }

    /// Ollama: checked as the step opens, rather than when the user thinks to press Start.
    private var ollama: some View {
        VStack(alignment: .leading, spacing: Style.onboardingStepSpacing) {
            Text(Wording.connectOllama).font(.title.bold())
            if let settings = model.settings { ModelSettingsView(loaded: settings, parts: [.server]).frame(maxHeight: .infinity) }
        }
        .task { _ = await model.runtime?.lifecycle.check() }
    }

    /// The profile documents are read with and its models, installed or to download: a step of its own, so it is not out
    /// of sight below the server's.
    private var models: some View {
        VStack(alignment: .leading, spacing: Style.onboardingStepSpacing) {
            Text(Wording.chooseModels).font(.title.bold())
            if let settings = model.settings { ModelSettingsView(loaded: settings, parts: [.models]).frame(maxHeight: .infinity) }
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: Style.onboardingStepSpacing) {
            Text(Wording.ready).font(.largeTitle.bold())
            Text(model.menuBarIconHidden ? Wording.readyIntroWithoutMenuBar : Wording.readyIntro)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

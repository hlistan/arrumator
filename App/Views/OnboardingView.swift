import SwiftUI

/// The first run, step by step: what the app does, the folders and how it runs, Ollama, the models, and then the app.
/// Each step fills the window down to the buttons, its title above it, and says where the user is ("Step 2 of 5") to the
/// eye, to VoiceOver and in the window's title; Return continues. The step is kept by the app (`AppModel.onboardingStep`),
/// so the window closed part way opens again where it was left.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    private var step: OnboardingStep { model.onboardingStep }

    var body: some View {
        VStack(alignment: .leading, spacing: Style.onboardingSpacing) {
            Text(Wording.stepOf(step.number, OnboardingStep.allCases.count)).font(.callout).foregroundStyle(.secondary)
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
                if let previous = OnboardingStep(rawValue: step.rawValue - 1) { Button(Wording.back) { model.onboardingStep = previous } }
                Spacer()
                if let next = OnboardingStep(rawValue: step.rawValue + 1) {
                    Button(Wording.continueStep) { model.onboardingStep = next }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    Button(Wording.openIncomingFolder) { if let path = model.settings?.incomingURL.path { model.open(path) } }
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
            // Each step's buttons are its own: kept from step to step, AppKit's buttons keep the key equivalent of the
            // place they had, so Return pressed Back, or nothing, after the first step (QA 2026-10-05, ONB-4).
            .id(step)
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
            // Its controls all fit the window at the default text size; where they do not, the scroll bar shows there is more.
            if let settings = model.settings {
                GeneralSettings(loaded: settings, footnote: Wording.foldersFooterFirstRun).scrollIndicators(.visible).frame(maxHeight: .infinity)
            }
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
            // Where to put the first document, by its path, which the next window does not show.
            if let incoming = model.settings?.incomingURL {
                Text(Wording.readyIncoming(path: incoming.path)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

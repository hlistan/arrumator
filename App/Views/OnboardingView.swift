import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var loginItem = false

    var body: some View {
        VStack(alignment: .leading, spacing: Style.onboardingSpacing) {
            switch step {
            case 0: welcome
            case 1: folders
            case 2:
                if let settings = model.settings { ModelSettingsView(loaded: settings).frame(height: Style.onboardingModelsHeight) }
            default: finish
            }
            Spacer()
            HStack {
                if step > 0 { Button(Wording.back) { step -= 1 } }
                Spacer()
                if step < 3 {
                    Button(Wording.continueStep) { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button(Wording.start) {
                        Task {
                            try? LoginItem.set(loginItem)
                            await model.finishOnboarding()
                            model.close(.onboarding)
                            model.show(.main)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Style.onboardingPadding)
        .frame(width: Style.onboardingWindow.width, height: Style.onboardingWindow.height)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Style.onboardingStepSpacing) {
            Text(Wording.welcome).font(.largeTitle.bold())
            Text(Wording.welcomeIntro)
            Label(Wording.welcomeLocal, systemImage: "lock.shield")
            Label(Wording.welcomeNoFolders, systemImage: "tag")
            Label(Wording.welcomeLabels, systemImage: "square.and.pencil")
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: Style.onboardingStepSpacing) {
            Text(Wording.chooseFolders).font(.title.bold())
            if let settings = model.settings { GeneralSettings(loaded: settings).frame(height: Style.onboardingFoldersHeight) }
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: Style.onboardingStepSpacing) {
            Text(Wording.ready).font(.largeTitle.bold())
            Text(Wording.readyIntro)
            Toggle(Wording.openAppAtLogin, isOn: $loginItem)
        }
    }
}

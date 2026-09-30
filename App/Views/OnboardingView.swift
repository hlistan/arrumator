import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var loginItem = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case 0: welcome
            case 1: folders
            case 2: ModelSettingsView().frame(height: 330)
            default: finish
            }
            Spacer()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step < 3 {
                    Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Start") {
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
        .padding(24)
        .frame(width: 620, height: 500)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to Arrumator").font(.largeTitle.bold())
            Text("""
                Drop any document into your Incoming folder. Arrumator reads it on this Mac, labels it with who sent it, \
                what it is and whom it concerns, its dates, amounts and references, where it applies and its language, \
                names it, and files it into your archive. You find it again by searching for any of its labels.
                """)
            Label("Everything runs locally with Ollama. No document ever leaves this computer.", systemImage: "lock.shield")
            Label("No folders to keep tidy: every document sits at the top of the archive, found by its labels.", systemImage: "tag")
            Label("Labels say who sent it, what it is, its dates, amounts, references and more; correct any of them.",
                  systemImage: "square.and.pencil")
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose your folders").font(.title.bold())
            GeneralSettings().frame(height: 300)
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ready").font(.largeTitle.bold())
            Text("Arrumator lives in the menu bar. Open it to see what was filed, search by label, and answer documents that need you.")
            Toggle("Open Arrumator at login", isOn: $loginItem)
        }
    }
}

import ArrumatorCore
import ArrumatorRuntime
import SwiftUI

/// Logic: the prompt the model follows in this archive, edited in place; then, on the same page, try it on a few
/// documents, review the plan and reprocess everything. Each archive has its own logic, kept in the archive.
struct LogicPage: View {
    @Environment(AppModel.self) private var model
    @State private var logic: LogicRecord?
    @State private var file: URL?

    private static let planAnchor = "plan"

    var body: some View {
        Page(.logic, notes: "Logic is the prompt the model follows when it decides where documents go in this archive and "
            + "what they are called. Learned rules and your corrections advise it; when they disagree, the logic wins. "
            + "It is kept in the archive, so another archive can be organised another way.") {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: Style.sectionSpacing) {
                    if let logic {
                        LogicEditor(logic: logic, file: file) {
                            withAnimation(.snappy) { proxy.scrollTo(Self.planAnchor, anchor: .top) }
                        }
                    }
                    LogicPlan(logicVersion: logic.map { LogicStore.version(of: $0) })
                        .id(Self.planAnchor)
                }
                .onChange(of: model.rethink.status) { _, status in
                    if status == .planning { withAnimation(.snappy) { proxy.scrollTo(Self.planAnchor, anchor: .top) } }
                }
            }
        }
        .task(id: model.activity) {
            let loaded = await model.load("Load logic") { runtime in
                (try await runtime.logic.current(), try await runtime.records.logicFileURL())
            }
            logic = loaded?.0
            file = loaded?.1
        }
    }
}

/// The archive's logic, open in place: the prompt, saved on request, and reset to the text that ships with the app.
private struct LogicEditor: View {
    @Environment(AppModel.self) private var model
    let logic: LogicRecord
    let file: URL?
    /// Called once the logic has been saved or reset, as trying it is the next step.
    let changed: () -> Void
    @State private var text = ""

    private var edited: Bool { text != logic.body }
    /// A rethink plans with the logic, so the logic stays as it is until the plan is applied or discarded.
    private var locked: Bool { model.rethink.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if locked {
                Notice(text: "A plan made with this logic is open below. Apply or discard it before changing the logic.")
            }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: Style.logicEditorHeight)
                .background(Style.page, in: .rect(cornerRadius: Style.rowCornerRadius))
                .disabled(locked)
            Text("Write in plain words how documents should be organised and named. "
                + "{{folder_language}} stands for the language chosen for folder names.")
                .font(.caption).foregroundStyle(.tertiary)
            HStack(spacing: 14) {
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent).disabled(!edited || locked).keyboardShortcut("s")
                if edited { Button("Revert", action: load).buttonStyle(.link) }
                Spacer()
                if let file {
                    Button("Show in Finder") { model.reveal(file.path) }.buttonStyle(.link)
                }
                if !logic.followsBuiltin {
                    Button("Reset to Original") { Task { await reset() } }.buttonStyle(.link).disabled(locked)
                }
            }
        }
        .padding(Style.cardPadding)
        .background(Style.card, in: .rect(cornerRadius: Style.cardCornerRadius))
        .shadow(color: Style.cardShadow, radius: Style.cardShadowRadius, y: Style.cardShadowOffset)
        .padding(.vertical, 8)
        .onAppear(perform: load)
        .onChange(of: logic) { load() }
    }

    private func load() { text = logic.body }

    private func save() async {
        let text = text
        await model.perform("Save logic") { try await $0.logic.update(body: text) }
        if model.lastError == nil { changed() }
    }

    private func reset() async {
        await model.perform("Reset logic") { try await $0.resetLogic() }
        if model.lastError == nil { changed() }
    }
}

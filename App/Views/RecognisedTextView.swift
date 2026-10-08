import ArrumatorCore
import SwiftUI

/// What a document is, as the model read it, what an image shows, and its text as it was recognised: what its sidecar
/// beside it holds (`PipelineServices.documentText`), to read, select and copy.
struct RecognisedTextView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let documentID: Int64
    /// The document's name, which the sheet is headed with.
    var name: String?
    @State private var shown: DocumentText?

    var body: some View {
        VStack(alignment: .leading, spacing: Style.textSheetSpacing) {
            HStack {
                Text(Wording.recognisedText(of: name)).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let sidecar = shown?.sidecar {
                    Button(Wording.showSidecarInFinder) { model.reveal(sidecar) }
                }
                Button(Wording.done) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let shown {
                ScrollView {
                    VStack(alignment: .leading, spacing: Style.textSheetSpacing) {
                        Text(Wording.interpretationHeading).font(.headline)
                        Text(shown.interpretation ?? Wording.notSaidWhatItIs)
                            .foregroundStyle(shown.interpretation == nil ? .secondary : .primary)
                        if let image = shown.imageDescription {
                            Text(Wording.imageHeading).font(.headline)
                            Text(image)
                        }
                        Text(Wording.recognisedTextHeading).font(.headline)
                        ForEach(Wording.textRead(shown), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        Text(shown.text.isEmpty ? Wording.noRecognisedText : shown.text)
                            .font(.body.monospaced())
                            .foregroundStyle(shown.text.isEmpty ? .secondary : .primary)
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .task {
            guard let read = await model.load(Wording.loadTextAction, { try await $0.services.documentText(documentID) }) else { return }
            shown = read
        }
    }
}

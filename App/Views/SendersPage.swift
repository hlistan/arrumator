import ArrumatorCore
import ArrumatorRuntime
import SwiftUI

/// The senders the app has learned, and a way to make it forget any of them. Forgetting a sender takes it off this
/// page; History keeps the record of it.
struct SendersPage: View {
    @Environment(AppModel.self) private var model
    @State private var senders: [Correspondent] = []
    @State private var pages = 1
    @State private var openSender: Int64?

    var body: some View {
        Page(.senders, notes: "Senders are who documents come from. Each filed document teaches its sender: a name "
            + "you correct becomes another name for it, and identifiers found only on its documents recognise it however "
            + "its name is written, so its next document is named alike. Anything here can be forgotten.") {
            if senders.isEmpty {
                EmptyState(symbol: "person.2", text: "No senders yet. They are learned from the documents that arrive.")
            }
            ForEach(senders) { sender in
                SenderRow(sender: sender, open: openSender == sender.id)
                    .onTapGesture { withAnimation(.snappy) { openSender = openSender == sender.id ? nil : sender.id } }
            }
            if let pageSize = model.runtime?.config.interface.pageSize, senders.count == pages * pageSize {
                Button("Show More") { pages += 1 }.buttonStyle(.link)
            }
        }
        .task(id: "\(pages)|\(model.activity)") {
            let pages = pages
            let all = await model.load("Load senders") { try await $0.senders.correspondents() } ?? []
            senders = model.runtime.map { runtime in
                Array(all.sorted { $0.filedCount > $1.filedCount }.prefix(pages * runtime.config.interface.pageSize))
            } ?? []
        }
    }
}

/// A sender the app knows: how many of its documents are filed; opened, its other names (each of which can be
/// forgotten), what identifies it and what that is for, and a way to forget it altogether.
private struct SenderRow: View {
    @Environment(AppModel.self) private var model
    let sender: Correspondent
    let open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "person.crop.square").foregroundStyle(.secondary).frame(width: 18)
                Text(sender.canonicalName).lineLimit(1)
                Spacer(minLength: 16)
                if sender.filedCount > 0 {
                    Text(Format.count(sender.filedCount, "document")).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    if !sender.aliases.isEmpty {
                        HStack(spacing: 6) {
                            Text("Also known as").foregroundStyle(.secondary)
                            ForEach(sender.aliases, id: \.self) { alias in
                                Button {
                                    let id = sender.id
                                    Task { await model.perform("Forget name") { try await $0.learner.forget(.alias(correspondentID: id, alias: alias)) } }
                                } label: {
                                    Label(alias, systemImage: "xmark").labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(.bordered).controlSize(.small).help("Forget this name")
                            }
                        }
                    }
                    let recognisedBy = sender.stableKeys + sender.emailDomains.map { "@\($0)" } + sender.webDomains
                    if recognisedBy.isEmpty {
                        Text(Wording.senderUnrecognised).foregroundStyle(.secondary)
                    } else {
                        Text("Recognised by " + recognisedBy.joined(separator: ", "))
                        Text(Wording.recognition(of: sender.canonicalName)).foregroundStyle(.secondary)
                    }
                    Button("Forget Sender", role: .destructive) {
                        let id = sender.id
                        Task { await model.perform("Forget sender") { try await $0.learner.forget(.sender(correspondentID: id)) } }
                    }
                    .buttonStyle(.link)
                    .help("Forget its names and identifiers")
                }
                .font(.callout)
                .padding(.leading, 27)
                .padding(.bottom, 6)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: Style.rowHeight)
        .contentShape(.rect)
    }
}

import SwiftUI

/// What a field that names a card, a task or a profile looks like: plain while it is only read, so it sits among the card's
/// words, and with a field's own ground and border under the pointer and while it is edited, so it shows it can be. Drawn
/// around the plain field rather than by switching its style, which would change its identity and lose its focus. A name too
/// long for its line ends with an ellipsis while it is not edited, never cut within a word.
private struct NameFieldLook: ViewModifier {
    let editing: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        let showsField = editing || hovering
        content
            .textFieldStyle(.plain)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(Style.nameFieldInsets)
            .background(showsField ? Style.nameFieldFill : .clear, in: .rect(cornerRadius: Style.nameFieldCornerRadius))
            .overlay { RoundedRectangle(cornerRadius: Style.nameFieldCornerRadius).stroke(showsField ? Style.nameFieldBorder : .clear) }
            .onHover { hovering = $0 }
    }
}

extension View {
    /// What a name field looks like and does on Escape: the look of `NameFieldLook` (`editing` is whether it has the keyboard),
    /// and the first Escape puts `saved` back in `name` and has the field `leave` the keyboard, so a second Escape reaches the
    /// card, which closes. The one place that rule is written, for a document's, a task's and a profile's card.
    func nameField(editing: Bool, name: Binding<String>, saved: String, leave: @escaping () -> Void) -> some View {
        modifier(NameFieldLook(editing: editing))
            .onExitCommand {
                name.wrappedValue = saved
                leave()
            }
    }
}

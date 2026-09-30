import ArrumatorCore
import SwiftUI

/// Colours for data marks. The system accent is deliberately not used: it changes with the user's settings and macOS
/// draws it grey whenever the window is not the focused one, which turns a chart into grey lines.
enum Palette {
    /// Files that got through a step.
    static let progress = Color.blue
    /// A stop that means the pipeline did its job, such as a duplicate.
    static let expected = Color.gray
    /// Nothing is wrong, but somebody has to act.
    static let attention = Color.orange
    /// Something went wrong.
    static let problem = Color.red
    /// Nothing to act on: a step with no errors or warnings, a model that is installed.
    static let fine = Color.green
    /// The unfilled part of a bar.
    static let track = Color.secondary.opacity(0.22)

    // MARK: Lists, as Things' sidebar colours them

    /// The Incoming list.
    static let incomingList = Color.blue
    /// The Processed list.
    static let processedList = Color.green
    /// The Labels list, and the page of the documents with the labels chosen in the sidebar.
    static let labelsList = Color.purple
    /// The Tasks list.
    static let tasksList = Color.teal

    // MARK: Kinds of label

    /// Each kind of label its own colour, on its name heading the sidebar's group and on its labels' tags, so a label
    /// shows its kind in the one list the sidebar makes of them too. The twelve system colours are twelve hues that
    /// adapt to dark mode and Increase Contrast; the colour is never the only sign of a kind, whose name heads its group
    /// and is in each label's help (Apple Human Interface Guidelines › Color:
    /// https://developer.apple.com/design/human-interface-guidelines/color).
    static func labelKind(_ kind: LabelKind) -> Color {
        switch kind {
        case .sender: .blue
        case .party: .indigo
        case .type: .purple
        case .topic: .green
        case .object: .brown
        case .reference: .cyan
        case .date: .orange
        case .period: .yellow
        case .deadline: .red
        case .amount: .mint
        case .jurisdiction: .teal
        case .language: .pink
        }
    }
}

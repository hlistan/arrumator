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
    /// Behind the words a search matched, in a result's snippet.
    static let searchMatch = Color.yellow.opacity(0.35)

    // MARK: Lists, as Things' sidebar colours them

    /// The Incoming list.
    static let incomingList = Color.blue
    /// The Processed list.
    static let processedList = Color.green
    /// The Labels list, and the labels chosen in the sidebar.
    static let labelsList = Color.purple
}

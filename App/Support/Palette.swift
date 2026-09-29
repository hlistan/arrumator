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
    /// The unfilled part of a bar.
    static let track = Color.secondary.opacity(0.22)

}

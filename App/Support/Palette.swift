import AppKit
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
    /// The colour of a stop as much as it matters (`FunnelSeverity`).
    static func severity(_ severity: FunnelSeverity) -> Color {
        switch severity {
        case .expected: expected
        case .attention: attention
        case .problem: problem
        }
    }
    /// Where documents ended up, each outcome its own colour, so no two shown together share one: filed is the progress blue,
    /// the rest apart from it and from each other. The legend's text says each, so colour is never the only sign.
    static func outcome(_ status: DocumentStatus) -> Color {
        switch status {
        case .filed: progress
        case .needsReview: attention
        case .held: .indigo
        case .failed: problem
        case .duplicate: expected
        case .undone: .brown
        case .missing: .pink
        case .arrived, .processing: .teal
        }
    }
    /// The unfilled part of a bar.
    static let track = Color.secondary.opacity(0.22)

    // MARK: Lists, as Things' sidebar colours them

    /// The Incoming list. The app icon is drawn in it too: `scripts/app-icon.sh` reads this line, so run it again after
    /// changing the colour, to regenerate App/Assets.xcassets/AppIcon.appiconset.
    static let incomingList = Color.blue
    /// The Processed list.
    static let processedList = Color.green
    /// The Labels list, and the page of the documents with the labels chosen in the sidebar.
    static let labelsList = Color.purple
    /// The Tasks list.
    static let tasksList = Color.teal

    // MARK: Kinds of label

    /// Each kind of label its own colour, on its name heading the sidebar's group and on its labels' tags, so a label
    /// shows its kind in the one list the sidebar makes of them too. The kinds the model gives take the twelve system hues,
    /// and the user's own tags the system's grey, apart from all of them. In dark mode each is the system's own, which
    /// measures 5.6 to 8.5 to 1 on the sidebar; in light mode the system hues are meant for marks, not text, so each is
    /// darkened toward black, by `lightDarkening`, or `highContrastDarkening` under Increase Contrast, until its text
    /// measures at least 4.5 to 1 on the light sidebar, the lightest hue, yellow, included (WCAG 2.2, 1.4.3). The colour is
    /// never the only sign of a kind, whose name heads its group and is in each label's help (Apple Human Interface
    /// Guidelines › Color: https://developer.apple.com/design/human-interface-guidelines/color).
    static func labelKind(_ kind: LabelKind) -> Color {
        let system = systemColor(of: kind)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let looks = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            guard looks != .darkAqua, looks != .accessibilityHighContrastDarkAqua,
                  let rgb = system.usingColorSpace(.sRGB) else { return system }
            let darkening = looks == .accessibilityHighContrastAqua ? highContrastDarkening : lightDarkening
            return rgb.blended(withFraction: darkening, of: .black) ?? system
        })
    }

    /// How far each kind's colour is darkened toward black in light mode, and under Increase Contrast: 0.55 puts the lightest
    /// hue at 5.5 to 1 on the sidebar's light background (measured, `docs/qa/protocol.md` › C14).
    static let lightDarkening: CGFloat = 0.55
    static let highContrastDarkening: CGFloat = 0.7

    private static func systemColor(of kind: LabelKind) -> NSColor {
        switch kind {
        case .sender: .systemBlue
        case .party: .systemIndigo
        case .type: .systemPurple
        case .topic: .systemGreen
        case .object: .systemBrown
        case .reference: .systemCyan
        case .date: .systemOrange
        case .period: .systemYellow
        case .deadline: .systemRed
        case .amount: .systemMint
        case .jurisdiction: .systemTeal
        case .language: .systemPink
        case .tag: .systemGray
        }
    }
}

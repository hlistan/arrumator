import AppKit
import ArrumatorCore
import SwiftUI

/// The visual language, after Things: one quiet list per page under a large title, rows without separators, and an
/// item that opens in place as a card. Colour is kept for the few marks that carry meaning.
enum Style {
    // MARK: Pages

    /// Widest a page's column of content grows, however wide the window is.
    static let pageMaxWidth: CGFloat = 720
    /// Space left and right of a page's content.
    static let pageHorizontalPadding: CGFloat = 44
    /// Space above and below a page's content.
    static let pageVerticalPadding: CGFloat = 34
    /// Between a page's title and its sections, and between sections.
    static let sectionSpacing: CGFloat = 28
    /// A page's large title.
    static let titleSize: CGFloat = 26
    /// The list's symbol before a page's title.
    static let titleSymbolSize: CGFloat = 21
    /// Between a page's title and the line of notes under it.
    static let pageTitleSpacing: CGFloat = 8
    /// Between a page's symbol, its title and the accessory after it.
    static let titleSymbolSpacing: CGFloat = 10
    /// A section's small bold heading.
    static let sectionTitleSize: CGFloat = 13
    /// Between a section's heading, its hairline and its rows.
    static let sectionHeadingSpacing: CGFloat = 4
    /// Below a section's hairline, before its first row.
    static let sectionRuleGap: CGFloat = 2
    /// Above a "Show More" link at the end of a section.
    static let showMoreGap: CGFloat = 4

    // MARK: Rows

    /// Lowest a list row is, so rows keep one rhythm.
    static let rowHeight: CGFloat = 28
    /// Rounding of a row's highlight under the pointer.
    static let rowCornerRadius: CGFloat = 6
    /// Between a row's line and the subtitle under it.
    static let rowSubtitleSpacing: CGFloat = 2
    /// Between a row's status mark, its name and its detail.
    static let rowSymbolSpacing: CGFloat = 9
    /// Between a document's row and the button that adds it to a task's set or takes it out.
    static let rowAccessorySpacing: CGFloat = 6
    /// The column a row's status mark sits in.
    static let rowSymbolWidth: CGFloat = 18
    /// Least space between a row's name and its detail at the end.
    static let rowDetailMinGap: CGFloat = 16
    /// How far a row's subtitle is indented, to line up with its name.
    static let rowSubtitleIndent: CGFloat = 27
    /// Lines a row's name may wrap onto when it is a sentence.
    static let rowTitleMaxLines = 2
    /// Lines a row's subtitle may take.
    static let rowSubtitleMaxLines = 2
    /// Space left and right inside a row.
    static let rowHorizontalPadding: CGFloat = 8
    /// Space above and below a row that has a subtitle or wraps.
    static let rowVerticalPadding: CGFloat = 5
    /// Around the text of a small grey tag at the end of a row.
    static let tagInsets = EdgeInsets(top: 1, leading: 7, bottom: 1, trailing: 7)
    /// How strongly a tag's capsule is filled.
    static let tagFillOpacity = 0.7

    // MARK: Empty pages and notices

    /// Between an empty page's symbol, its sentence and its action.
    static let emptyStateSpacing: CGFloat = 10
    /// The faint symbol of an empty page.
    static let emptyStateSymbolSize: CGFloat = 34
    /// Above and below what an empty page says.
    static let emptyStatePadding: CGFloat = 40
    /// Between a notice's symbol, its text and its action.
    static let noticeSpacing: CGFloat = 8

    // MARK: Cards

    /// Rounding of a card opened in place.
    static let cardCornerRadius: CGFloat = 10
    /// Space inside a card.
    static let cardPadding: CGFloat = 18
    /// Blur of a card's shadow.
    static let cardShadowRadius: CGFloat = 12
    /// How far a card's shadow falls below it.
    static let cardShadowOffset: CGFloat = 4
    /// Above and below a card, apart from the rows around it.
    static let cardOuterPadding: CGFloat = 8
    /// Between buttons in a row of actions, on a card or in the menu bar.
    static let actionSpacing: CGFloat = 14
    /// A document's thumbnail on its card.
    static let thumbnail = CGSize(width: 66, height: 88)
    /// Between the parts of a document's card: header, labels, reading, actions.
    static let documentCardSpacing: CGFloat = 16
    /// Between a document's thumbnail and its name.
    static let thumbnailSpacing: CGFloat = 16
    /// Between a document's name, where it is, and how it arrived.
    static let cardHeaderSpacing: CGFloat = 6
    /// Between a document's status mark and where it is.
    static let placementSpacing: CGFloat = 8
    /// Between the column naming a kind of label on a card and the labels of that kind.
    static let cardGridColumnSpacing: CGFloat = 14
    /// Between the rows of labels on a document's card.
    static let cardLabelRowSpacing: CGFloat = 6
    /// Between the rows of what the model read, on a document's card.
    static let cardReadingRowSpacing: CGFloat = 4
    /// Between who read a document and the problems it found.
    static let readingLineSpacing: CGFloat = 3
    /// Between small controls in a row, such as the kind, field and button that add a label.
    static let inlineControlSpacing: CGFloat = 6
    /// Width of the kind chooser where a label is added on a document's card.
    static let labelKindPickerWidth: CGFloat = 130
    /// Between the parts of a label's card and of two alike labels' card.
    static let labelCardSpacing: CGFloat = 12
    /// Between a label's name and its kind at the top of its card.
    static let labelCardTitleSpacing: CGFloat = 3
    /// Width of the field where the label to merge into is written on a label's card.
    static let mergeFieldWidth: CGFloat = 240
    /// Between a decision about labels and the button that forgets it.
    static let ruleForgetSpacing: CGFloat = 8

    // MARK: Search tasks

    /// Between the field a request is written in and the button that asks it.
    static let askSpacing: CGFloat = 8
    /// Lines the field a request is written in grows to before it scrolls.
    static let askMaxLines = 4
    /// Between the parts of a task's card.
    static let taskCardSpacing: CGFloat = 14
    /// How far each level of a task's set is indented under the label that heads it.
    static let setLevelIndent: CGFloat = 14
    /// Between the kinds a task's set is arranged by, shown side by side.
    static let groupingSpacing: CGFloat = 4
    /// Between the effort a request is read with and the model that reads it.
    static let readingSpacing: CGFloat = 12
    /// Widest the menu of models may be, so a long model name does not push the row apart.
    static let readingModelMaxWidth: CGFloat = 260

    // MARK: Labels

    /// Between labels shown side by side.
    static let chipSpacing: CGFloat = 6
    /// Between the parts of one label: its kind, its name, and the button that takes it off.
    static let chipContentSpacing: CGFloat = 4
    /// Around a label on a document's card.
    static let labelChipInsets = EdgeInsets(top: 2, leading: 7, bottom: 2, trailing: 7)
    /// Around a label chosen in the sidebar, at the top of the page that shows its documents.
    static let chosenLabelInsets = EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)

    // MARK: Main window and sidebar

    /// The main window when it first opens.
    static let mainWindow = CGSize(width: 1_000, height: 700)
    /// Smallest the main window can be made.
    static let mainWindowMinimum = CGSize(width: 760, height: 520)
    /// Narrowest the sidebar can be made.
    static let sidebarMinWidth: CGFloat = 200
    /// The sidebar's width when the window opens.
    static let sidebarIdealWidth: CGFloat = 230
    /// Widest the sidebar can be made.
    static let sidebarMaxWidth: CGFloat = 300
    /// Around the text of an error shown at the foot of the main window.
    static let errorBannerInsets = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    /// Between the symbol, text and clear button of the sidebar's label filter.
    static let filterFieldSpacing: CGFloat = 6
    /// Inside the sidebar's label filter.
    static let filterFieldInsets = EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)
    /// Rounding of the sidebar's label filter.
    static let filterFieldCornerRadius: CGFloat = 7
    /// How strongly the sidebar's label filter is filled.
    static let filterFieldFillOpacity = 0.6
    /// Between the parts of the sidebar's foot: why the app waits, pause, and its menu.
    static let sidebarFooterSpacing: CGFloat = 10
    /// Around the sidebar's foot.
    static let sidebarFooterInsets = EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12)
    /// The sheet that shows how a document was read.
    static let traceSheetMinimum = CGSize(width: 760, height: 560)

    // MARK: Menu bar

    /// The menu bar popover.
    static let popover = CGSize(width: 360, height: 420)
    /// Space inside the menu bar popover.
    static let menuBarPadding: CGFloat = 16
    /// Between the parts of the menu bar popover.
    static let menuBarSpacing: CGFloat = 12
    /// Between the documents just processed, in the menu bar popover.
    static let menuBarRecentSpacing: CGFloat = 6

    // MARK: Onboarding

    /// The onboarding window.
    static let onboardingWindow = CGSize(width: 620, height: 500)
    /// Space inside the onboarding window.
    static let onboardingPadding: CGFloat = 24
    /// Between a step of onboarding and the buttons under it.
    static let onboardingSpacing: CGFloat = 16
    /// Between the parts of one step of onboarding.
    static let onboardingStepSpacing: CGFloat = 12
    /// The folders step of onboarding, inside its window.
    static let onboardingFoldersHeight: CGFloat = 300
    /// The models step of onboarding, inside its window.
    static let onboardingModelsHeight: CGFloat = 330

    // MARK: Settings

    /// The Settings window.
    static let settingsWindow = CGSize(width: 900, height: 620)
    /// What the stepper for how long model prompts are kept offers.
    static let retentionDays = 1...3_650
    /// The step of the stepper for how long model prompts are kept.
    static let retentionDaysStep = 30

    // MARK: Processing log

    /// The log's time column.
    static let logTimeColumnWidth: CGFloat = 80
    /// The log's level column.
    static let logLevelColumnWidth: CGFloat = 60
    /// The log's part column.
    static let logPartColumnWidth: CGFloat = 70
    /// Between the log's controls, and around them.
    static let logControlsSpacing: CGFloat = 8
    /// The chooser of the funnel step whose lines the log shows.
    static let logStepPickerWidth: CGFloat = 280
    /// The chooser of how much detail the log shows.
    static let logLevelPickerWidth: CGFloat = 150
    /// Narrowest the log's filter field is.
    static let logFilterMinWidth: CGFloat = 120
    /// Between the funnel steps in the log's summary.
    static let logSummarySpacing: CGFloat = 6
    /// Around the log's summary of funnel steps.
    static let logSummaryInsets = EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
    /// Between a funnel step's name and its counts in the log's summary.
    static let logChipContentSpacing: CGFloat = 5
    /// Around a funnel step in the log's summary.
    static let logChipInsets = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)

    // MARK: Statistics

    /// Between the parts of the Statistics page, and around them.
    static let statsSpacing: CGFloat = 16
    /// Around what Statistics shows while it loads or has nothing yet.
    static let statsPlaceholderPadding: CGFloat = 40
    /// Around the Statistics header.
    static let statsHeaderInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    /// The chooser of the period Statistics covers.
    static let statsPeriodPickerWidth: CGFloat = 150
    /// How strongly the panels of Statistics are filled.
    static let statsPanelFillOpacity = 0.3
    /// Rounding of the panels of Statistics.
    static let statsPanelCornerRadius: CGFloat = 10
    /// Space inside a panel of Statistics.
    static let statsPanelPadding: CGFloat = 14
    /// Between the columns of the funnel.
    static let funnelColumnSpacing: CGFloat = 10
    /// The column of the chevron that opens a funnel step.
    static let funnelChevronWidth: CGFloat = 10
    /// The column of a funnel step's name.
    static let funnelStepWidth: CGFloat = 230
    /// The bar of how far files got, on a scale shared by every step.
    static let funnelBarWidth: CGFloat = 220
    /// The height of a funnel step's bar.
    static let funnelBarHeight: CGFloat = 12
    /// The funnel's column of files that reached a step.
    static let funnelReachedWidth: CGFloat = 55
    /// The funnel's column of files that stopped at a step.
    static let funnelStoppedWidth: CGFloat = 60
    /// The funnel's column of the share of all files.
    static let funnelShareWidth: CGFloat = 80
    /// The funnel's columns of how long a step took.
    static let funnelDurationWidth: CGFloat = 70
    /// Between a funnel step's error and warning counts.
    static let funnelProblemSpacing: CGFloat = 6
    /// Around a funnel step's row.
    static let funnelRowInsets = EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10)
    /// Around the funnel's column headings.
    static let funnelHeaderInsets = EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
    /// How strongly the funnel step that is open is highlighted.
    static let funnelSelectionOpacity = 0.25
    /// Rounding of the bars in Statistics.
    static let statsBarCornerRadius: CGFloat = 4
    /// Between the parts of where files ended up.
    static let endedUpSpacing: CGFloat = 8
    /// The height of the bar of where files ended up.
    static let endedUpBarHeight: CGFloat = 18
    /// Between the slices of the bar of where files ended up.
    static let sliceGap: CGFloat = 1
    /// Narrowest a slice of the bar of where files ended up is, so a small one still shows.
    static let sliceMinWidth: CGFloat = 2
    /// Between a legend's colour swatch and its text.
    static let legendSpacing: CGFloat = 8
    /// A legend's colour swatch.
    static let swatchSize = CGSize(width: 9, height: 9)
    /// Rounding of a legend's colour swatch.
    static let swatchCornerRadius: CGFloat = 2
    /// Between the parts of an open funnel step.
    static let stepDetailSpacing: CGFloat = 12
    /// Between figures side by side.
    static let figureSpacing: CGFloat = 18
    /// Between a figure's name and its value.
    static let figureLabelSpacing: CGFloat = 1
    /// Narrowest a figure in a grid of them may be, as Statistics lays out labels by kind.
    static let figureMinWidth: CGFloat = 92
    /// Between the reasons files stopped at a step.
    static let stepStopsSpacing: CGFloat = 4
    /// Between a count and what it counts, in an open funnel step.
    static let stepStopSpacing: CGFloat = 6
    /// The column of counts in an open funnel step.
    static let stepCountWidth: CGFloat = 40

    // MARK: Trace

    /// Widest the chooser of a document's runs is.
    static let traceRunPickerMaxWidth: CGFloat = 480
    /// The column of a trace step's stage.
    static let traceStageWidth: CGFloat = 100

    // MARK: Colours

    /// Behind a page.
    static let page = Color(nsColor: .textBackgroundColor)
    /// Behind a card opened in place.
    static let card = Color(nsColor: .controlBackgroundColor)
    /// Behind a row under the pointer, and behind a label.
    static let hover = Color.primary.opacity(0.05)
    /// A card's shadow.
    static let cardShadow = Color.black.opacity(0.14)
}

extension Destination {
    var title: String { Wording.title(of: self) }

    var symbol: String {
        switch self {
        case .incoming: "tray.and.arrow.down.fill"
        case .review: "questionmark.circle.fill"
        case .processed: "checkmark.circle.fill"
        case .labels, .labelled: "tag.fill"
        case .tasks: "text.magnifyingglass"
        case .history: "clock.fill"
        case .statistics: "chart.bar.fill"
        }
    }

    /// The colour each list is known by, as in Things' sidebar.
    var tint: Color {
        switch self {
        case .incoming: Palette.incomingList
        case .review: Palette.attention
        case .processed: Palette.processedList
        case .labels, .labelled: Palette.labelsList
        case .tasks: Palette.tasksList
        case .history, .statistics: .secondary
        }
    }
}

extension DocumentStatus {
    var symbol: String {
        switch self {
        case .filed: "checkmark.circle.fill"
        case .needsReview: "questionmark.circle"
        case .failed, .missing: "exclamationmark.circle"
        case .duplicate: "doc.on.doc"
        case .undone: "arrow.uturn.backward.circle"
        case .held: "pause.circle"
        case .arrived, .processing: "circle.dotted"
        }
    }

    var tint: Color {
        switch self {
        case .filed: Palette.progress
        case .needsReview, .held: Palette.attention
        case .failed, .missing: Palette.problem
        case .duplicate, .undone, .arrived, .processing: Palette.expected
        }
    }
}

extension TraceStatus {
    /// How a step's outcome is coloured in a trace.
    var tint: Color {
        switch self {
        case .error: Palette.problem
        case .warn: Palette.attention
        case .ok, .skipped: .secondary
        }
    }
}

/// Symbols and colours for history events.
enum EventStyle {
    static func symbol(_ kind: EventKind) -> String {
        switch kind {
        case .arrived: "tray.and.arrow.down"
        case .extracted: "doc.text.magnifyingglass"
        case .analysed: "tag"
        case .filed: "checkmark.circle"
        case .needsReview: "questionmark.circle"
        case .duplicate: "doc.on.doc"
        case .error, .failed: "exclamationmark.triangle"
        case .retry: "arrow.clockwise"
        case .corrected, .userMoved, .userRenamed, .markedCorrect: "hand.point.up.left"
        case .undone: "arrow.uturn.backward"
        case .labelsMerged: Wording.ruleSymbol(.merge)
        case .labelIgnored: Wording.ruleSymbol(.ignore)
        case .labelsKeptApart: Wording.ruleSymbol(.keepApart)
        case .labelRuleForgotten: "arrow.uturn.backward"
        default: taskSymbols[kind] ?? "circle"
        }
    }

    /// Events about search tasks.
    private static let taskSymbols: [EventKind: String] = [
        .taskCreated: Destination.tasks.symbol, .taskPrepared: SearchTaskState.ready.symbol, .taskFailed: SearchTaskState.failed.symbol,
        .taskEdited: "pencil", .taskExported: "square.and.arrow.up", .taskRemoved: "trash",
    ]

    static func color(_ kind: EventKind) -> Color {
        switch kind {
        case .filed, .taskPrepared: Palette.progress
        case .needsReview, .retry: Palette.attention
        case .error, .failed, .taskFailed: Palette.problem
        default: .secondary
        }
    }
}

extension SearchTaskState {
    var symbol: String {
        switch self {
        case .queued: "circle.dotted"
        case .interpreting: "ellipsis.circle"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .queued, .interpreting: Palette.expected
        case .ready: Palette.tasksList
        case .failed: Palette.problem
        }
    }
}

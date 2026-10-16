---
paths: ["App/**"]
---

# App guidelines

How to change the SwiftUI menu-bar app in `App/`, which has no test target
(G4 in `.claude/singularity/guidelines/project.md`).

- **G23** Route every button for one action through one `AppModel` method,
  whichever place offers it (a row menu, a card, a History row, the notice),
  and report its failures through `AppModel.perform`.
- **G24** When the App offers an action from a new place, check each page's
  reload merge (`ProcessedPage` keeps its rows in place under an open card)
  and every piece of state the old path cleared (`session.removed` in
  `AppModel`).
- **G31** Probe in the built app any AppKit behaviour a guarantee rests on
  before code, comments or docs claim it. `NSTextView` answers
  `validRequestor` itself, so an `NSApplication` override never sees a
  Services request; Look Up opens from Control-Command-D, a force click and
  a three-finger tap, not only from menus. What can't be probed goes under
  "Not verified" in `docs/architecture.md`, with a step in the change's
  charter in `docs/qa/protocol.md`, and `docs/using-arrumator.md` states
  such behaviour (keys, focus, VoiceOver, menus) only as a drive saw it.
  When one such claim is found, check every sentence the change adds about
  keys, focus and VoiceOver, not only that one; and fix undriven behaviour
  by removing it, never by adding more that is undriven.
- **G32** Match a keyboard shortcut by `NSEvent.keyCode` as well as by its
  characters: `charactersIgnoringModifiers` follows the keyboard layout (D
  types "в" under the Russian layout, which the team uses).
  `LookUpGesture.opensLookUp` checks both, and its tests carry a Russian
  case.
- **G33** When a word the App shows changes in `Wording`, `git grep` the old
  word in `docs/` (`docs/using-arrumator.md`, `docs/qa/protocol.md`) and
  change it there too.
- **G45** Before a change to `App/` goes to review, operate every control it
  adds or moves in the built app, in a scratch home (G35), with the pointer
  and with the keyboard alone, and write down per criterion the steps, what
  was seen and the name VoiceOver reads for each new control
  (`docs/review/code-review.md` › "Before a review starts", row 7).
  `scripts/verify.sh --app` leaves the app in
  `build/DerivedData/Build/Products/Release/Arrumator.app`; launch it as
  step 4 of "Environment" in `docs/qa/protocol.md`, and drive it with
  `scripts/qa-drive.sh <command> <pid>` (`help` lists the commands; the
  terminal needs Accessibility permission). A criterion nobody drove is
  reported as not run (G4), never as passed.
- **G50** A page that lists what a stream of Core's states gives takes each
  state in `AppModel` as it arrives (`AppModel.showSearchResults`) and shows
  what it stored; never derive the rows by `.task(id:)` or `.onChange` of
  the state, which SwiftUI coalesces when one state follows another within
  an update, so a settled state goes unseen whatever the id holds. A view
  that acts on a value set in the update that creates it observes it with
  `.onChange(of:initial: true)` (`DocumentList`'s `rowToFocusHere`).
- **G51** Match the Mac's Delete key in `onKeyPress` by `Style.deleteKeyPress`
  (U+007F), never by `KeyEquivalent.delete` (U+0008), which only a menu
  item's shortcut translates: a handler keyed on it never runs.
- **G48** Drive each keyboard criterion with Keyboard navigation off first, as
  this Mac has it: rows that are `.focusable(interactions: .activate)` take no
  focus then, so a page of rows is held as one `.edit` stop with a highlight
  the arrow keys move (`SearchPage`, `SidebarLabelList`). Send the keyboard
  into it through the window's key view loop (`SearchFieldFocus.next`,
  `toResults`), not by assigning a `@FocusState` while an AppKit toolbar field
  holds the cursor, which the container takes the keys from but never reports.
  With the setting on, a row holds the ring and the highlight follows it
  (`SidebarLabelList`'s `rowFocused`).
- **G49** Make the menu bar only through
  `TextMenuGuard.install(mainMenu:editMenu:)` (gate `main-menu`): AppKit adds
  AutoFill, Start Dictation and Emoji & Symbols to an Edit menu as it takes
  it, so a guard that records the app's items after that never prunes them.
  Read the menu a drive means to judge after
  `scripts/qa-drive.sh press <pid> Edit AXMenuBarItem` opened it.
- **G52** Quiet text (a page's notes, an empty sentence, a foot line, a
  row's description) takes `Palette.quietText`, never
  `.foregroundStyle(.secondary)`, which measures 3.1:1 on a page in light,
  under the 4.5:1 AGENTS.md §4.7 and `docs/review/swift-apple.md` ask for;
  measure what a change adds in both appearances (charter C14 of
  `docs/qa/protocol.md`).

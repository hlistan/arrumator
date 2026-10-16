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
  "Not verified" in `docs/architecture.md`, with a step in charter C14 of
  `docs/qa/protocol.md`.
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

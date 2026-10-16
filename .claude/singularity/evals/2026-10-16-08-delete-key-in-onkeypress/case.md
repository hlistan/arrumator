---
kind: recall
lens: correctness
base: d690be38c9fd8bcea7ea3b92e28d85ee755d2b2d
expect: >-
  The row's Command-Delete handler is keyed on
  `Style.moveToTrashShortcut.key`, which is `KeyEquivalent.delete` (U+0008):
  `onKeyPress` receives the Mac's Delete key as U+007F, which only a menu
  item's shortcut translates, so the handler never runs and Move to Trash
  cannot be reached by the keyboard from a row (AGENTS.md §4.7).
location: App/Views/Documents.swift:40
holdout: false
source: >-
  t1-in-app-word-search built-app drive, finding F7, 2026-10-16; escaped
  from #26 (4ae2edb, merged 2026-10-14) through its two review rounds and
  the next run
---

# Command-Delete on a row matched by the wrong character

An escaped defect: the keyboard path to Move to Trash on a row did nothing
for two days, and no review saw it. The patch is the change of #26 to
`App/Support/Style.swift` and `App/Views/Documents.swift`, as merged. G51 in
`.claude/rules/singularity/app.md` now states the right key.

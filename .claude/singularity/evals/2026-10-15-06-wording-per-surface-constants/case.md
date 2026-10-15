---
kind: precision
lens: maintainability
base: 4ae2edb5617450a70bd2860e4933f09eaac1269b
expect: >-
  Four constants spell "Copy" (`Wording.copy`, `Wording.copyAction`,
  `Wording.copyLabel`, `Wording.copyAnswer`) and should be one.
location: App/Support/Wording+Pages.swift:44,537 (and Wording.swift:54,203)
holdout: false
source: >-
  ui-usability review round 1, finding M11, rejected by the challenger,
  2026-10-15
---

# Per-surface wording constants are not duplication

A known false positive: a `Wording` constant per surface for one verb is the
project's pattern (`undo` and `undoAction` at base; G34 in
`.claude/singularity/guidelines/review.md`), so that each surface's words can
change on their own. The patch is the two wording files at the change's fixed
state; the constants are as reviewed.

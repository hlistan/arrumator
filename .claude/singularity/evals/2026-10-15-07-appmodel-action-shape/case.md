---
kind: precision
lens: maintainability
base: 4ae2edb5617450a70bd2860e4933f09eaac1269b
expect: >-
  `AppModel.mergeLabel` and `AppModel.renameLabel` duplicate each other's body
  and should share one.
location: App/AppModel.swift:324-340
holdout: false
source: >-
  ui-usability review round 1, finding M12, rejected by the challenger,
  2026-10-15
---

# The shape of an `AppModel` action is not duplication

A known false positive: the shared step is already `openLabelCard`, and the
three lines left are the shape of every `AppModel` action, `perform` then open
or reload what changed (G34 in `.claude/singularity/guidelines/review.md`). The
patch is `App/AppModel.swift` at the change's fixed state; the two actions are
as reviewed.

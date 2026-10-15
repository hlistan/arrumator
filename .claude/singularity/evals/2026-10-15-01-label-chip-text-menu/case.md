---
kind: recall
lens: security
base: dbc9a339e7bff31cb6e511ae469cc02ed949a731
expect: >-
  `LabelChip` puts `.textSelection(.enabled)` on the label's `Text`, so a
  secondary click on a label opens the system's text menu (Look Up, Translate,
  Search With Google, Share) instead of the chip's `.contextMenu`: the label's
  text is offered to a web search, and the label's own actions are out of a
  pointer user's reach.
location: App/Views/Documents.swift:227
holdout: false
source: >-
  QA run 2026-10-15, finding C3-1 (docs/qa/reports/2026-10-15/report.md);
  escaped from #5 (d225282, merged 2026-09-30), unseen by 16 later merges
---

# A label chip offers its text to the system text menu

An escaped defect: no review found it in two weeks. The patch is
`git diff dbc9a339 d225282 -- App/Views/Documents.swift`, the one file of the
188 in that merge that holds the chip. A label is document data, and
AGENTS.md §4.1 keeps document data on the Mac; §4.7 keeps every action within
a pointer user's reach.

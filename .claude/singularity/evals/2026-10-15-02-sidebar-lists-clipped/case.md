---
kind: recall
lens: correctness
base: f2afd6024477de721771d538381c431a2d0fa7f8
expect: >-
  `SidebarLists` sizes itself to `end.maxY - top`, frames measured in an earlier
  layout and kept while `rowSize` and `showsFilter` are unchanged; with
  `.scrollDisabled(true)`, a frame measured shorter than the rows now need hides
  the first row (Incoming) with no way to scroll to it: the layout feeds back on
  itself.
location: App/Views/MainWindow.swift:169-180
holdout: false
source: >-
  QA run 2026-10-15, finding C5-1 (docs/qa/reports/2026-10-15/report.md);
  escaped from #12 (e6effc4, merged 2026-10-02), unseen by 14 later merges
---

# The sidebar lists keep a height from an earlier layout

An escaped defect: a page a pointer user cannot reach, every time once labels
exist. The patch is `git diff f2afd602 e6effc4 -- App/Views/MainWindow.swift`,
the one file of the 142 in that merge that holds `SidebarLists`. AGENTS.md
§4.7: layout never feeds back on itself.

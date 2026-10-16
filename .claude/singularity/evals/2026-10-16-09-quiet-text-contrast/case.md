---
kind: recall
lens: interface
base: 322a998963ed8e18619e2fdaab129ca17f98ce85
expect: >-
  The search page's quiet text (the meaning line, the cut line at its foot)
  and the match excerpt under a row are `.foregroundStyle(.secondary)`, which
  measures 3.1:1 on a page in the light appearance, under the 4.5:1 that
  `docs/review/swift-apple.md` X3 and charter C14 ask for in both
  appearances; it takes `Palette.quietText`.
location: App/Views/SearchPage.swift:126,178; App/Views/Page.swift:152
holdout: false
source: >-
  t1-in-app-word-search, missed by the interface lens in review rounds 1 and
  2, found by the built-app drive (F8) and review round 4 (R4-2), 2026-10-16
---

# Quiet text below the contrast the project asks for

A defect two interface reviews missed although the lens names contrast 4.5:1
in both appearances; the built app measured 3.1:1 in light. The patch is
rebuilt: the change's `App/Views/SearchPage.swift` and `App/Views/Page.swift`
as they are after the fix, with `Palette.quietText` put back to `.secondary`,
as the first two rounds read those lines (other lines may differ from what
they read). G52 in `.claude/rules/singularity/app.md` states the rule.

---
kind: recall
lens: security
base: 4ae2edb5617450a70bd2860e4933f09eaac1269b
expect: >-
  `LocalApplication.validRequestor(forSendType:returnType:)` returning nil is
  never consulted for a text view's selection: `NSTextView` answers for
  `NSStringPboardType` itself, so the override guarantees nothing, and the
  comment (line 13) and the `local-text` gate's text claim a guarantee that
  does not hold.
location: App/Support/LocalText.swift:96-101
holdout: false
source: >-
  ui-usability review round 1, finding S2 (= K2), confirmed should-fix by the
  security and correctness lenses, 2026-10-15
---

# A `validRequestor` override that is never consulted

A regression case: the reviewer caught it, and a change to the review must
keep catching a claimed guarantee that the platform does not give. The patch is
the three new files of the text-menu guard as the round-1 reviewers read them
(rebuilt from their reads of the files, line for line as cited in the review).

---
kind: recall
lens: security
base: 4ae2edb5617450a70bd2860e4933f09eaac1269b
expect: >-
  `LookUpGesture.opensLookUp` matches Control-Command-D by
  `charactersIgnoringModifiers` alone (`App/Support/LocalText.swift:122`),
  which is the current layout's letter: under the Russian layout the key gives
  "в", so the drop fails open and the Look Up panel, whose Siri Suggestions
  reach Apple, still opens. The physical key (`keyCode` 2, `kVK_ANSI_D`) must
  be matched as well.
location: Sources/ArrumatorCore/Domain/LookUpGesture.swift:31-39
holdout: true
source: >-
  ui-usability review round 2, finding F1, confirmed should-fix by the
  security lens, 2026-10-15
---

# A shortcut matched by the layout's letter alone

A regression case: a guard that fails open under a keyboard layout the user has
enabled. The patch is the four files of the gesture drop as the round-2
reviewer read them (rebuilt from its reads of the files, line for line as cited
in the review). Held out: the fifth case.

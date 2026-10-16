---
kind: precision
lens: interface
base: 322a998963ed8e18619e2fdaab129ca17f98ce85
expect: >-
  `docs/using-arrumator.md` states as fact, without a drive, that searching
  lets go of adding documents to a task and that no query survives the
  archive being switched; these must be marked not verified (G31).
location: docs/using-arrumator.md:232-233
holdout: true
source: >-
  t1-in-app-word-search review round 4, finding I4-8 (docs part), rejected
  by the challenger, 2026-10-16
---

# What the App's own code decides is not an undriven platform claim

A known false positive: both sentences say what `AppModel.go` and
`AppModel.switchArchive` do (the field cleared on any page but the results,
`session.collecting` let go, a new `ArchiveSession`), which the code shows.
G31 holds AppKit behaviour (keys, focus, VoiceOver, menus) to a probe, not
what the App's own code decides. The patch is the change's
`docs/using-arrumator.md`, `App/AppModel.swift` and
`App/AppModel+Search.swift` against its base, as they are after the last fix
round.

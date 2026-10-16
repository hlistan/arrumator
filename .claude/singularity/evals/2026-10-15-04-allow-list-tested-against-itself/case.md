---
kind: recall
lens: testability
base: 4ae2edb5617450a70bd2860e4933f09eaac1269b
expect: >-
  18 of the 30 selectors on `TextMenuRule.kept`'s allow-list are kept by no
  test: the tests exercise a sample and compare against the set under test
  itself, so a selector added to or taken off the allow-list changes nothing a
  test shows (AGENTS.md §3: each value of a set is tested on its own).
location: Tests/ArrumatorCoreTests/TextMenuRuleTests.swift:11-19
holdout: false
source: >-
  ui-usability review round 1, finding T1, confirmed should-fix by the
  testability lens, 2026-10-15
---

# An allow-list tested against itself

A regression case for the project's rule that each value of a set is tested,
shown by deleting it. Same patch as case 03: the text-menu guard as the round-1
reviewers read it.

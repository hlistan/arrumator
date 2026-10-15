# Implementation guidelines

How to build and test a change here: commands, fixtures, code generation, local
services.

Maintained by the singularity optimizer and reviewed in PRs/MRs like code.
Each guideline states the current right way. Format and rules: singularity
`optimizer/learn.md`.

## One rule for a listing and its action

- **G11** A listing that pre-computes refusals
  (`ReviewActions.removalRefusals(of:)`,
  `ReviewActions.putBackRefusals(of:)`) and the action it precedes run one
  rule: no `compactMap` that drops inputs the action then refuses, no copy of
  the rule's queries inside the write (split out an index-only part and call
  it from both), and no guard after the rule that no input reaches.

## Errors

- **G12** An error case names the kind of id it was given: a History event
  id gets its own case (`PutBackError.noSuchRemoval(event:)`), never one
  worded for a document number, and associated values carry labels
  (`document:`, `event:`). Test each public entry point with an unknown id
  and with an id of the wrong kind.
- **G13** Every stat or read of a file someone else can move, such as an
  item in the Trash, sits inside the do/catch that maps "gone" to the typed
  refusal (`PutBackError.noLongerInTrash`); otherwise a raw `CocoaError`
  escapes and a two-at-once test is flaky.

## Tests

- **G14** Write each Core step's test first and show it failing
  (AGENTS.md §3), and cover every trigger and root cause the spec names,
  not only the main path.
- **G15** A failure-path test asserts the exact error
  (`#expect(throws: DatabaseError.self)`, one `PutBackError` case), never
  `(any Error).self`, and proves the action acted before it was undone (the
  same inode at `trashed`, the Trash's count); otherwise "refused before
  acting" passes too. A test that cancels before the call stops at GRDB's
  first `read`, not at a later `checkCancellation`: say so in its comment.
- **G16** Tests never depend on the machine: inject the Trash lookup
  (`SystemTrash(trashOfVolume:)`) rather than reading `NSHomeDirectory()`
  and a literal `.Trash`; assert a path against the Trash the test gave
  (`home.root.appendingPathComponent("Trash").spelledOnDisk.path`), not
  with `contains("/Trash/")`; share sentinels and helpers through statics or
  `Tests/Support`, never through copied literals.
- **G28** A test of a set or an allow-list (`TextMenuRule.kept`) compares
  it with a literal list written in the test, every value in it; never
  iterate the code's own set, which passes whatever the set holds.

## Lint gates

- **G29** A gate in `scripts/lint.sh` scans every place its rule covers:
  `Sources` as well as `App` for anything AppKit reaches (Core is linked
  into the app), and `project.yml` and property lists for an Info.plist key
  (`scan` reads `.yml` and `.plist`). Its sample holds a line for each
  pattern it must refuse.

## Plan steps

- **G30** Tick a plan step only when every item it lists is done; an item
  left out stays listed under the step as a deviation, with the reason.

## Building and running

- **G40** `swift test --filter <Suite>` runs one suite (the `struct …Tests`
  name or a `@Suite` title); `swift test` needs no Ollama and no network
  (`MockOllama`, `TestEnvironment` in `Tests/Support`). `swift build` checks
  the package in Swift 6 mode with warnings as errors (`Package.swift`), but
  not the App, which `project.yml` builds with complete strict concurrency
  and `MainActor` default isolation: run `scripts/verify.sh --app` before
  handing over a change to `App/`, as its build fails on what `swift build`
  passed.
- **G41** Generated files are regenerated, never edited (the "Do not touch"
  list in `.claude/singularity.md`): the corpus with
  `swift run --package-path Tools/FixtureGen fixturegen --out Tests/Fixtures`,
  the Xcode project and `App/Info.plist` with `xcodegen generate` from
  `project.yml`, the app icon with `scripts/app-icon.sh`. The check tools
  live in `.tools/bin`, installed by `scripts/tools.sh`.

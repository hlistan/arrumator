# Project lessons

Codebase facts and gotchas every agent needs. Imported into every session, so keep it under 40 lines.

Maintained by the singularity learner and reviewed in PRs/MRs like code. Format and rules: singularity `agents/learner.md`.

- **P1** Record files in the archive (`System/History/_<yyyy>-<mm>.md`, sidecars) can be edited by hand and are read
  back into the index verbatim (`payloadJson` is a raw string), so every path or value from an event payload is
  untrusted: constrain it to the folder it must be in (`Trashing.holds`, `URL.holds`), take `..` out
  (`standardizedFileURL`) before walking up, refuse links, and handle an undecodable payload in the listing as well as
  the action. The SQLite index itself is not a trust boundary. _Why:_ a crafted `trashed` path could move any file; `..`
  hung `SystemTrash.holds`; an unreadable removal was listed as possible. _Seen:_ 1 · _Last:_ 2026-10-14 · _Refs:_
  remove-documents
- **P2** Decide whether a path is inside a folder, and its relative folder, only with `URL.holds` and
  `URL.relativeFolder(of:)` in `FileIdentity.swift`; never slice by string prefix. Tests run under `/var` while the disk
  spells `/private/var`, so prefix slicing passes tests and cuts the wrong folder through a link. _Why:_ put-back
  `placement` sliced the path. _Seen:_ 1 · _Last:_ 2026-10-14 · _Refs:_ remove-documents
- **P3** `App/` has no test target; `scripts/verify.sh --app` only builds it and runs Periphery. Put decisions in Core
  (`ReviewActions`) where `swift test` reaches them, keep views thin, and give each App-only acceptance criterion a step
  in a QA charter in `docs/qa/protocol.md`, reported as not run until someone drives the built app. _Why:_ six criteria
  rested on charter C15 alone and two App defects (stale row, stale notice) were caught only by review. _Seen:_ 1 ·
  _Last:_ 2026-10-14 · _Refs:_ remove-documents
- **P4** New untracked files are invisible to `git diff <base>`: run `git add -N <new files>` before review so reviewers
  see them. _Why:_ `PutBack.swift` and four new test files were otherwise missing from the review diff. _Seen:_ 1 ·
  _Last:_ 2026-10-14 · _Refs:_ remove-documents
- **P5** `timeout` is not installed on this macOS machine; bound a long command with `perl -e 'alarm shift; exec @ARGV'
  900 <command>`. _Seen:_ 1 · _Last:_ 2026-10-14 · _Refs:_ remove-documents
- **P6** Never run `gh pr merge`: a PR merges only after independent review (AGENTS.md §2, §8), and the auto-mode
  classifier refuses an unreviewed merge. With `auto_commit`/`auto_pr` false, handoff ends at an uncommitted tree.
  _Seen:_ 1 · _Last:_ 2026-10-14 · _Refs:_ remove-documents

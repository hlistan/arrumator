# Verification lessons

Setup steps, flaky tests, environment quirks.

Maintained by the singularity learner and reviewed in PRs/MRs like code. Format and rules: singularity `agents/learner.md`.

- **L1** With `App/` changed, `scripts/verify.sh --app` is the done check
  (build, docs, `swift test`, fixtures, release build, Periphery). It
  does not drive the app: report the QA charter steps (e.g. C15) as not
  run, never as passed. _Why:_ PASS on first run here, with C15 still
  open before merge. _Seen:_ 1 · _Last:_ 2026-10-14 ·
  _Refs:_ remove-documents

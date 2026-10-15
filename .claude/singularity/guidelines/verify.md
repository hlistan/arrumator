# Verification guidelines

What a full verification run needs here: setup, slow or flaky suites, checks
beyond the commands.

Maintained by the singularity optimizer and reviewed in PRs/MRs like code.
Each guideline states the current right way. Format and rules: singularity
`optimizer/learn.md`.

## What a pass covers

- **G22** A PASS from `scripts/verify.sh`, with `--app` too, covers the
  build, the docs, `swift test`, the fixtures, the release build and
  `scripts/deadcode.sh`, and nothing a user does in the app: list each QA
  charter step in `docs/qa/protocol.md` that the criteria rest on (C15 for
  removal and put-back) in the report as not run, never as passed.

## What a run needs and takes

- **G44** `swift test` needs no Ollama and no network; its five test runs
  finish in under a minute together once built, so a suite still running
  after minutes is hung, not slow: find which test with
  `swift-inspect dump-concurrency <pid>`, or run it with its output on a
  terminal, never piped, which the test process holds back (AGENTS.md §3).
  `scripts/verify.sh --app` adds the release build and `scripts/deadcode.sh`
  (about a quarter of an hour on this Mac; it needs
  `scripts/tools.sh xcodegen periphery`), and `--checks-only` runs no tests.
  Bound a run with G6, as `timeout` is missing.

# Agent Execution Contract

These rules bind every agent and every person who changes this repository. The contract is deliberately short, so read
all of it before every task. What the product does is in [README.md](README.md); how the pipeline decides and files is
in [docs/how-it-works.md](docs/how-it-works.md).

## 1. Role and mandate

You are a **Principal Software Engineer, Technical Architect and Principal Quality Engineer** on Arrumator. You design,
implement and rigorously verify production-ready changes:

- **Fixes** for QA issues, defect reports and behavior the user reports.
- **Refactorings** that follow from architectural recommendations.
- **Features** built into the existing pipeline.
- **Test suites**: new ones, and overhauls of those a change makes obsolete.

You own each change from start to finish: design, code, tests, docs and the evidence that it works. A change is done
when it has been verified, not when the code is written. Fix the root cause. A patch that only hides the symptom is a
workaround, and workarounds break §3.

**You may break things without asking.** You may make breaking changes, structural refactorings, dependency updates and
test-suite overhauls on your own judgment, whenever they make the code more maintainable, cleaner, more testable or
more scalable. Backward compatibility is not a goal. All of these may change: APIs between modules, the SQLite
schema, keys in `pipeline.json` and `settings.json`, CLI flags and `--json` output, prompt templates and trace payloads.
When you change one, update every caller in the same change. Every code change comes with the automated tests that
keep it correct. Do not leave shims, deprecated aliases, code that reads
both old and new formats, or fallback decoders for the old shape. The mandate stops at the user's files and learned
state (§4.2).

## 2. Start of every task

1. **Get off `main` before anything changes.** Run `git branch --show-current`. On `main`, run `git pull --ff-only`,
   then `git switch -c <prefix>/<change>` with a prefix from §8 (`fix/`, `feat/`, `refactor/`, `test/`, `docs/`,
   `ci/`), before you edit a file, regenerate fixtures or run a command that writes into the repository. On another
   branch, continue only if it is this task's branch; otherwise ask. No change is ever made on `main`, and the
   pre-commit hook refuses a commit there.
2. Read this file, [README.md](README.md) and [docs/how-it-works.md](docs/how-it-works.md).
3. Use §5 to find the modules the change touches. Read their code and tests, and only those. If the change affects how
   documents are read, labelled or named, also read the app's prompt,
   [labels-system.md](Sources/ArrumatorClassify/Prompts/labels-system.md).
4. Before you write code, state the acceptance criteria and the exact command that will prove them: a test, an
   `arrumatorcli` command or an eval run.

Then, for a QA issue, a defect or an architectural task:

1. **Reproduce.** Find the root cause and write the smallest test that fails for exactly that reason.
2. **Fix.** Implement or refactor until it passes, following §3 and §4.
3. **Clean up the tests.** Update or replace the unit and integration tests the change made obsolete, and delete
   flaky, redundant or dead ones.
4. **Report.** Give a Test Coverage and Verification Summary: the happy paths, boundary cases and failure modes now
   covered, what is not covered, and the verification output (§7).
5. **Deliver** through the push protocol (§8).

## 3. Core principles

These are rules you can check, not aspirations. Each row says how it is checked.

| Principle | Rule | Checked by |
|---|---|---|
| **Zero hardcoding** | Four rules. **(1) Environment:** only `RuntimeEnvironment.current` reads process environment variables, and everything else receives a `RuntimeEnvironment`. The one exception is `OllamaLifecycle.spawnServe`, which passes the environment on to the child process. A new variable is named `ARRUMATOR_*`, lives in `RuntimeEnvironment`, and is listed in [docs/using-arrumator.md › Configuration](docs/using-arrumator.md#configuration). **(2) Tunables:** these all live in bundled `Defaults/pipeline.json` (pipeline behavior) or `Defaults/settings.json` (user preferences): thresholds, weights, timeouts, retry and backoff settings, intervals, limits, sizes, model names and profiles, endpoints. Each is mirrored by a field in `PipelineConfig` or `AppSettings` that has no default value. The bundled JSON is the only place a default is written. Code gets values injected and never adds its own fallback, such as `?? 0.8`. A value is a tunable if an eval run or a user could want a different one, or if changing it changes how documents are labelled, named or found, when or how fast. **(3) Business logic that can vary** sits behind a protocol in `Contracts/Protocols.swift` and is wired in `ArrumatorRuntime`, or it is data: prompt templates in `Prompts/*.md`, model profiles in `pipeline.json`. **Reading knowledge never lives in code.** No Swift `switch` or `if`, keyword list or regex table may map document types, senders, keywords or languages to labels or names. What a document is, what it concerns and what it is called is the model's judgment, guided by the app's prompt (`labels-system.md`), and checked as the contract of each `LabelKind` fixes it (`DocumentLabel.normalized`, `AnswerValidator`): an ISO date, an ISO 639-1 code, one of `DocumentType`. **(4) Contract constants** are facts fixed by a format or protocol: schema versions, PDF points per inch, Ollama API paths, identifier formats such as IBAN or NIF, buffer sizes that don't affect results. They are named `static let` constants on the type that owns them. They never appear as bare literals in logic, and they never go in config. **Test data** lives in fixtures and builders (`Tests/Fixtures` from `Tools/FixtureGen`, the helpers in `Tests/Support` and each suite's support file), not in literals copied from test to test. | `scripts/lint.sh` (environment gate). `ConfigTests` decodes the bundled defaults, and a missing key fails the load because the fields have no defaults. Review. |
| **Architectural excellence and testability** | Clean code, SOLID and DRY. **DRY means one source of truth for each fact:** defaults in `Defaults/*.json`, prompts in `Prompts/*.md`, the schema in `AppDatabase.migrator`, and contracts between modules in `ArrumatorCore/Contracts`. Logic that both the app and the CLI need lives in Core or Runtime, never in a copy per view and per command. **Dependency injection and inversion of control:** anything that talks to a model, the disk, the network or the clock is injected, behind a protocol where tests need to replace it, and wired in `ArrumatorRuntime`, so every collaborator can be replaced by a test double. **Strong typing:** the package builds in Swift 6 language mode with `ExistentialAny`, and the app builds with complete strict concurrency. Closed sets of states and kinds are enums, like `EventKind`, never strings. `Any` and `[CFString: Any]` appear only at the ImageIO and IOKit boundary, and are converted to typed values in the same function. Model output is decoded into `ClassificationSchema` types, never scraped with regex. `@unchecked Sendable` requires a comment that states why the type is safe. **Explicit error handling:** each module throws its own `LocalizedError` enum (`ConfigError`, `IngestError`, `OllamaError`, `PromptError`) that carries context: the path, document ID or model involved. Use `try?` only when failure is an expected outcome and the fallback is correct, as with probes, optional metadata or best-effort cleanup. When a failure affects a document, it is recorded in History and the trace, not swallowed. No `fatalError`, no `try!`, and no force unwrap of values that come from disk, Ollama or the model. `preconditionFailure` is allowed only when a programmer invariant on constant input is broken, such as a regex pattern literal that fails to compile, never for anything that comes from outside the code. | `swift build` with the strict settings. `scripts/lint.sh` (crash gate; SwiftLint `force_unwrapping`). Review. |
| **Tested first, at every boundary (shift-left QA)** | **Red, green, refactor:** a QA defect or new behavior starts with a test that reproduces it and fails for the stated reason, then the change makes it pass, then the code is cleaned up. A test that could pass without the change is not the regression test: show that it fails without the fix, for example by disabling the fix, and say so in the report. **Pyramid:** fast, isolated unit tests for domain logic, with a test double for every external interface: the doubles in `Tests/Support` (`MockOllama`, `StubAnalyzer`, `TestEnvironment`, `TestTime`, `Harness`) and stubs of `Contracts` protocols; integration tests at the data boundaries, which assert on the state a change leaves in the database and on disk, not only on what a call returns: storage, migrations, the job queue (`JobStore`), the archive's record files and the pipeline end to end (`IngestCoordinator`, `ArchiveReconciler`, rebuild); contract tests for model schemas, Ollama's HTTP API (the requests `OllamaClient` sends and the responses it decodes), `pipeline.json` and migrations (`ConfigTests`, `MigrationTests`); contract and end-to-end verification that a schema migration or breaking refactoring still gives its callers what they rely on (the app, the CLI and its `--json` output in `ArrumatorCLITests`, which runs the built command, record files written by earlier versions). **Coverage:** every change covers its happy path, its boundaries, malformed, missing, empty and conflicting input, the failure, retry and timeout handlers it touches, and its explicit error states. **Determinism:** no sleeps (wait on a condition with a deadline), no wall-clock time without an injected clock (`TimeSource`, and `TestTime` in tests, which moves only when a test or a sleep on it moves it), and no randomness or model calls a test cannot control; inject them. A test that needs something a machine may lack (a live model, a platform capability) says so and is skipped with that reason where it is missing, never left to fail or pass by chance. **Semantic assertions:** each `#expect` checks the specific outcome, not a broad boolean, and its message says why it matters. Flaky, redundant or dead tests are fixed or deleted in the same change. | `swift test` in `scripts/verify.sh`. Review. The report's Test Coverage and Verification Summary. |
| **Research-grounded decisions** | A non-obvious design cites its source at the code site or in `docs/`. Examples: records-management practice ([sources](docs/organizing-principles-sources.md)), embedding and search methods, data-visualization choices, and Apple documentation for platform behavior. Prefer the Apple frameworks already in use (PDFKit, Vision, NaturalLanguage, ImageIO) and established libraries over hand-written parsers. A change to analysis behavior (the prompt, the answer schema and its validation, the `analysis` and `labels` settings, the label kinds) comes with `arrumatorcli eval Tests/Fixtures --passes 2` numbers from before and after. The report quotes them, and any regression needs an explicit justification. | Review. Eval numbers in the report. |
| **Zero technical and test debt** | A change leaves nothing behind that it made obsolete. Superseded code is **deleted in the same change**, not deprecated. That means no compatibility shims, no `Legacy`, `Old` or `V2` names, no flags that keep the old path alive, and no commented-out code. The same goes for anything without a user: dead code, a config key (removed together with its struct field), unused prompt templates, `EventKind` cases, CLI flags, target dependencies and package dependencies. No `TODO`, `FIXME`, `HACK` or `XXX`: finish the work or don't start it. Tests for removed behavior are deleted, and tests for changed behavior are updated, never disabled. Obsolete workaround patches, flaky tests and redundant assertions go too; fixtures the change made stale are updated in the same change, and fixtures nothing uses are deleted. The documentation changes in the same change as the behavior it describes (§4.10). No new compiler warnings. | `scripts/lint.sh` (debt gate). `scripts/deadcode.sh` (Periphery) for unused code. Review. |

## 4. Hard rules (non-negotiable)

1. **Everything stays local.** Document data never leaves the machines the user runs: this Mac, or the user's own Ollama
   server on the local network. The only network client is `OllamaClient`, behind `OllamaConnection`, whose
   `NetworkGuardProtocol` session lets through only the one configured server. That server's address
   (`AppSettings.ollamaURL`, or `ARRUMATOR_OLLAMA_URL`) must pass `OllamaEndpoint.validated`: loopback, private or
   link-local addresses, `localhost` or a `.local` name. Never widen that rule to a public host. Never create another
   `URLSession` or use `URLSession.shared`. Never add a dependency, telemetry, crash reporter, update check or web view
   that can reach the network. Models are downloaded only when the user presses Download. Document text is kept only in
   the database and traces, and is sent only to that Ollama server. It never goes into logs, and it goes into
   diagnostics only when the user opts in.
2. **The user's files and learned state are never collateral damage.** The archive, Incoming, what a user writes into
   the record files and the extended attribute holding the original file name are the user's data. No code path may
   delete a document. Every move is recorded and can be undone. A breaking change to the database or config may drop
   state the app keeps (history, what the model read), but the app must detect the old state and either stop with an
   actionable error or rebuild from the archive on disk. It must never silently misread old data. Your report says what
   the installed app loses. A forward migration in `AppDatabase.migrator` is the default. You may rewrite or squash
   earlier migrations when that simplifies the schema, but the same conditions apply.
3. **Never touch the real archive, or the user's running app, while testing.** The default settings point at
   `~/Documents/Incoming` and `~/Documents/Archive`, so `ARRUMATOR_HOME` alone does **not** isolate you. Before you run
   the app or any CLI command other than `eval`, `--version` and `help`, set `ARRUMATOR_HOME` to a scratch directory
   **and** write a `settings.json` there that points `incomingPath` and `archivePath` at scratch folders. The app and
   every other command open the archive the settings name, and opening it can create the archive and its `System`
   folder and write its record files: this includes `ingest --dry-run` and commands that only read, such as `labels
   <document>`. Only `eval` isolates itself. The user may be running Arrumator, even from the same build folder, so
   stop, drive or capture the windows of only the process you started, found by its PID and its `ARRUMATOR_HOME`, never
   by its name. Unit tests use `TestEnvironment` and `MockOllama`, and nothing in `swift test` may need a running
   Ollama. How well a live model reads is measured with `arrumatorcli eval`, not in `swift test`.
4. **Every decision can be audited.** A new pipeline stage, decision or automatic action records a trace through
   `TraceRecorder`: its inputs, outputs, raw prompts and responses, and timing. When it changes a file, a document's
   labels or a setting, it also records a History event (`EventKind`). Its counts and drop-off reasons show
   up under the right funnel step (`ProcessingFunnel`) in Statistics and in `arrumatorcli funnel`.
5. **Model output is untrusted input.** Decode it into the typed schema, validate it with `AnswerValidator`, and
   send a document without a valid answer to Needs You. Names from the model go through `FilenameBuilder` before they
   reach the disk. The app builds every path itself: the model supplies a file name, never a directory.
6. **Logic stays below the UI.** Views and CLI commands call Runtime and Core, and they only present and parse. A new
   action for the user also gets an `arrumatorcli` command with `--json` output, so tests and agents can drive it.
7. **The interface stays quiet.** The app follows Things: a sidebar of a few lists and the archive's labels to narrow
   the documents down by, one list per page under a large title, rows without separators, and an item that opens in
   place as a card. Working screens have no dashboards, stat tiles or counters. A count appears only where something is
   waiting for the user, and beside each label in the sidebar, as how many of the documents in view have it, which is
   what the labels are ordered by. Other numbers belong in Statistics. Every document row shows what happened to it,
   and its name and labels can be changed from its card through `ReviewActions`, and every change is recorded. Layout
   values and colours live in `Style` and `Palette`, and wording in `Wording`. Views never hardcode them.
8. **Ask before irreversible or outward-facing actions:**
   - committing or pushing when the user has not asked for the change to be delivered (a delivered change follows §8
     to the end, including its squash merge, which publishes a release when it changes code);
   - rewriting history that has been pushed; pushing to `main` other than by §8's squash merge is never done;
   - deleting or rewriting anything in the user's real archive, Incoming folder, `~/Library/Application
     Support/Arrumator` or `~/Library/Logs/Arrumator`, including reading documents there again
     (`labels unlabelled`, `review retry`), which renames them;
   - pulling or deleting Ollama models (pulls are several GB, and the app itself never deletes models);
   - running `scripts/release.sh`, which signs and notarizes with the user's Apple account.
9. **Verify before you say it's done.** Run `scripts/verify.sh`, adding `--app` when `App/` or `project.yml` changed,
   or `scripts/verify.sh --checks-only` when `scripts/change-scope.sh main` says `checks`, and quote its result. If a
   step fails or you skipped it, say so plainly.
10. **Documentation changes with the code, every time.** A change is not done until every document that describes what
    it touched says what the code now does, in the same change. Where each thing is documented: [README.md](README.md)
    for what users see first, installing and getting started; [docs/how-it-works.md](docs/how-it-works.md) for how
    documents are read, labelled, filed and learned from; [docs/using-arrumator.md](docs/using-arrumator.md) for the app's
    pages, settings, `pipeline.json` keys, environment variables and audit trail; [docs/cli.md](docs/cli.md) for every
    command and option; [docs/storage.md](docs/storage.md) for record files and the index;
    [docs/evaluation.md](docs/evaluation.md) for measurements; [docs/releasing.md](docs/releasing.md) and
    [CONTRIBUTING.md](CONTRIBUTING.md) for CI, scripts and tools;
    [docs/repository-settings.md](docs/repository-settings.md) for the GitHub repository's settings; this file for
    rules, boundaries and commands. Removed behavior is removed from the documentation too, and code comments and CLI
    help strings count as documentation. `scripts/check-docs.sh`, run by `scripts/verify.sh`, fails when a command,
    option, `ARRUMATOR_*` variable, `pipeline.json` key or script is missing from the documents or named there without
    existing. Everything else is checked in review. The report lists the documents the change updated, or says why none
    needed to change.

## 5. Boundaries

The target dependencies in `Package.swift` and `project.yml` enforce the "May import" column. Never widen them just to
make something compile. Instead, move the code to the module that owns it.

| Path | Owns | May import |
|---|---|---|
| `Sources/ArrumatorCore` | Contracts, configuration, SQLite storage, the archive's record files and layout, watchers, file operations, the ingest state machine, the Ollama client, lifecycle and network guard, search, observability. | GRDB, Yams, Apple frameworks. Never Extract, Classify or Runtime. |
| `Sources/ArrumatorExtract` | Turning any file into `ExtractedContent`: format extractors, OCR, vision description, language, dates, identifiers. | Core, CoreXLSX, ZIPFoundation, Apple frameworks. |
| `Sources/ArrumatorClassify` | Reading documents: the prompt, model calls, the answer schema and its validation into labels and a file name. | Core |
| `Sources/ArrumatorRuntime` | The composition root: builds and wires the concrete services and starts the background tasks. | Core, Extract, Classify |
| `Sources/ArrumatorCLI` | `arrumatorcli` commands: argument parsing and output only. | Runtime, Core, Classify |
| `App/` | The SwiftUI menu-bar app: `AppModel`, pages and the shared row and card views, presentation only. | Runtime, Core |
| `Tests/Support` | Shared test doubles and fixtures: `MockOllama`, `StubAnalyzer`, `PerFileAnalyzer`, `TestEnvironment`, `TestTime`, `Harness`. | Core |
| `Tests/Fixtures`, `Tools/FixtureGen` | The synthetic evaluation corpus and its deterministic generator. Change the generator and regenerate; never edit fixtures or `expected.json` by hand. | — |
| `scripts/`, `.githooks/`, `Brewfile` | The checks, the release build, the Git hooks and the tools they need. | — |
| `.github/` | The CI and release workflows, Dependabot, issue and pull request templates. | — |
| `docs/` | The documentation beyond the README (§4.10). | — |

## 6. Commands

| Command | Purpose |
|---|---|
| `scripts/verify.sh` | The done check: `scripts/lint.sh`, `swift build`, `scripts/check-docs.sh`, `swift test`. |
| `scripts/lint.sh` | The static checks alone: guideline gates, secrets, SwiftLint, ShellCheck, actionlint, zizmor, markdownlint, links. |
| `scripts/check-secrets.sh [--staged \| --range <revs>…]` | Secrets, signing material, real documents and, with `--range`, machine-local commit identities. The Git hooks run it. |
| `scripts/bootstrap.sh` | Installs the tools in `Brewfile` and enables the Git hooks. |
| `scripts/verify.sh --app` | Also regenerates the Xcode project, builds `Arrumator.app` and looks for unused code (`scripts/deadcode.sh`). Required when `App/` or `project.yml` changes. |
| `scripts/change-scope.sh main` | What the branch's change needs (§8): `release` for code, `build` for what builds and tests it, `checks` for anything else. |
| `scripts/verify.sh --checks-only` | The static checks and the documentation check alone, with no tests: the done check for a change scoped `checks`. |
| `swift test --filter <Suite>` | Runs one suite while you iterate. |
| `swift run arrumatorcli doctor` | Checks the environment: Ollama, models, folders. |
| `swift run arrumatorcli ingest --dry-run <file>` | Shows what the pipeline would decide, without moving the file or recording a decision. It still opens the archive, so only in a scratch `ARRUMATOR_HOME` (§4.3). |
| `swift run arrumatorcli trace <doc> --full` / `replay <doc> --model <m>` | Shows how a past decision was made, or re-runs it with another model, without touching files. |
| `swift run arrumatorcli eval Tests/Fixtures --passes 2` | Measures how well documents are read (status; type, sender, date and language labels; file name; labelled share; labels per kind) on the fixture corpus in a throwaway archive. Needs a local Ollama with the profile's models. |
| `swift run arrumatorcli eval Tests/Fixtures --only pt/ --passes 1` | A quick look at one part of the corpus while iterating; the full two-pass run gives the numbers for the report. `--model <m>` reads with another chat model. |
| `swift run --package-path Tools/FixtureGen fixturegen --out Tests/Fixtures` | Regenerates the fixture corpus and `expected.json`. |

Every `arrumatorcli` command accepts `--json`. [docs/cli.md](docs/cli.md) lists them all.

## 7. Definition of done

- [ ] The acceptance criteria pass, and the output of the verify command is quoted in the report.
- [ ] New behavior has tests. A bug fix has a regression test that failed before the fix, and the report says how that
      was shown.
- [ ] The report has a Test Coverage and Verification Summary: happy paths, boundary cases and failure modes covered,
      and what is not covered.
- [ ] `scripts/verify.sh` passes, with `--app` when `App/` or `project.yml` changed, or `--checks-only` for a change
      scoped `checks`. Before and after eval numbers are included when analysis behavior changed.
- [ ] The change adds no environment reads outside `RuntimeEnvironment`, no tunables written as literals, and no
      defaults outside `Defaults/*.json`.
- [ ] Superseded code, config keys, prompts, tests and dependencies are deleted. No TODO markers and no new warnings.
- [ ] Every document the change affects is updated in the same change (§4.10), and the report lists them.
      `scripts/check-docs.sh` passes as part of `scripts/verify.sh`.
- [ ] The report states what breaks for the installed app: lost learned state, renamed config keys, changed CLI output.
- [ ] The change reached `main` through §8: green locally, green on the pull request, squash-merged, branch deleted.

## 8. Push protocol

Every change reaches `main` the same way. `main` is released on every merge that changes code, so it only ever
receives changes that are green twice: on your machine and on GitHub's runners. How much is built and checked follows
what the change touches, which `scripts/change-scope.sh` decides for your Mac and for CI alike
([docs/releasing.md](docs/releasing.md#what-a-change-needs-scriptschange-scopesh)):

| Scope | The change touches | Verify with | Released |
|---|---|---|---|
| `release` | Code: `Sources/`, `App/`, `Package.swift`, `Package.resolved`, `project.yml`, `scripts/release.sh`. | `scripts/verify.sh --app` | Yes |
| `build` | What builds and tests the code: `Tests/`, `Tools/`, `scripts/verify.sh`, `scripts/deadcode.sh`, `.periphery.yml`, the CI workflow. | `scripts/verify.sh --app` | No |
| `checks` | Anything else: documentation, the other scripts and workflows, settings. | `scripts/verify.sh --checks-only` | No |

1. **Green gates locally.** Work on a branch named for the change (`fix/…`, `feat/…`, `refactor/…`, `test/…`,
   `docs/…`, `ci/…`), never on `main`. Before pushing, run `scripts/change-scope.sh main` and the verify command its
   scope calls for, the same checks CI runs, and push only when it ends with `All checks passed`.
2. **Push the branch and get it green on the remote runners.** `git push -u origin <branch>`, then open a pull request
   to `main` (`gh pr create`) with the template filled in. CI runs both of its jobs on it; wait for them with
   `gh pr checks --watch`. When a check fails, fix it on the same branch and push again, until every check is green.
   A red pull request is never merged, and a check is never skipped or retried until it passes by chance.
3. **Squash-merge to `main` and remove the branch.** `gh pr merge --squash --delete-branch` puts the whole change on
   `main` as one commit titled after the pull request and deletes the branch on GitHub and here. Then
   `git switch main && git pull --ff-only`.
4. **Release only code.** The merge is checked on `main` and released only when its scope is `release`. A merge
   scoped `build` or `checks` is not built into a release, packaged, signed or tagged; it goes out with the next
   release that changes code. Never start a release for it by other means, and never run the full build for a change
   scoped `checks` just to be safe: the scope already errs toward more.

The pre-push hook refuses a direct push to `main`, and [docs/repository-settings.md](docs/repository-settings.md)
describes the GitHub settings that enforce the same on the server: squash merges only, branches deleted on merge,
and `main` accepting changes only through a pull request whose checks passed.

# Agent Execution Contract

These rules bind every agent and every person who changes this repository. The contract is deliberately short, so read
all of it before every task. What the product does is in [README.md](README.md); how the pipeline decides and files is
in [docs/how-it-works.md](docs/how-it-works.md).

## 1. Role and mandate

You are a **Principal Software Engineer and Technical Architect** on Arrumator. You design, implement and verify
production-ready changes:

- **Fixes** for defects and for behavior the user reports.
- **Refactorings** that follow from architectural recommendations.
- **Features** built into the existing pipeline.

You own each change from start to finish: design, code, tests, docs and the evidence that it works. A change is done
when it has been verified, not when the code is written. Fix the root cause. A patch that only hides the symptom is a
workaround, and workarounds break §3.

**You may break things without asking.** You may make breaking changes, structural refactorings and dependency updates
on your own judgment. Backward compatibility is not a goal. All of these may change: APIs between modules, the SQLite
schema, keys in `pipeline.json` and `settings.json`, CLI flags and `--json` output, prompt templates and trace payloads.
When you change one, update every caller in the same change. Do not leave shims, deprecated aliases, code that reads
both old and new formats, or fallback decoders for the old shape. The mandate stops at the user's files and learned
state (§4.2).

## 2. Start of every task

1. Read this file, [README.md](README.md) and [docs/how-it-works.md](docs/how-it-works.md).
2. Use §5 to find the modules the change touches. Read their code and tests, and only those. If the change affects where
   or how documents are filed, also read the built-in logic,
   [organizing-principles.md](Sources/ArrumatorClassify/Prompts/organizing-principles.md), and the placement prompt,
   [classify-system.md](Sources/ArrumatorClassify/Prompts/classify-system.md).
3. Before you write code, state the acceptance criteria and the exact command that will prove them: a test, an
   `arrumator` command or an eval run.

## 3. Core principles

These are rules you can check, not aspirations. Each row says how it is checked.

| Principle | Rule | Checked by |
|---|---|---|
| **Zero hardcoding** | Four rules. **(1) Environment:** only `RuntimeEnvironment.current` reads process environment variables, and everything else receives a `RuntimeEnvironment`. The one exception is `OllamaLifecycle.spawnServe`, which passes the environment on to the child process. A new variable is named `ARRUMATOR_*`, lives in `RuntimeEnvironment`, and is listed in [docs/using-arrumator.md › Configuration](docs/using-arrumator.md#configuration). **(2) Tunables:** these all live in bundled `Defaults/pipeline.json` (pipeline behavior) or `Defaults/settings.json` (user preferences): thresholds, weights, timeouts, retry and backoff settings, intervals, limits, sizes, model names and profiles, endpoints. Each is mirrored by a field in `PipelineConfig` or `AppSettings` that has no default value. The bundled JSON is the only place a default is written. Code gets values injected and never adds its own fallback, such as `?? 0.8`. A value is a tunable if an eval run or a user could want a different one, or if changing it changes what gets filed where, when or how fast. **(3) Business logic that can vary** sits behind a protocol in `Contracts/Protocols.swift` and is wired in `ArrumatorRuntime`, or it is data: prompt templates in `Prompts/*.md`, model profiles in `pipeline.json`. **Filing knowledge never lives in code.** No Swift `switch` or `if`, keyword list or regex table may map document types, correspondents, keywords or languages to folders or names. The folder tree is learned, and placement judgment lives in the archive's logic (the user's prompt, `LogicStore`), with learned rules and past filings as advice. **(4) Contract constants** are facts fixed by a format or protocol: schema versions, PDF points per inch, Ollama API paths, identifier formats such as IBAN or NIF, buffer sizes that don't affect results. They are named `static let` constants on the type that owns them. They never appear as bare literals in logic, and they never go in config. | `scripts/lint.sh` (environment gate). `ConfigTests` decodes the bundled defaults, and a missing key fails the load because the fields have no defaults. Review. |
| **Architectural excellence** | Clean code, SOLID and DRY. **DRY means one source of truth for each fact:** defaults in `Defaults/*.json`, prompts in `Prompts/*.md`, the schema in `AppDatabase.migrator`, and contracts between modules in `ArrumatorCore/Contracts`. Logic that both the app and the CLI need lives in Core or Runtime, never in a copy per view and per command. **Dependency injection:** anything that talks to a model, the disk, the network or the clock is injected, behind a protocol where tests need to replace it, and wired in `ArrumatorRuntime`. **Strong typing:** the package builds in Swift 6 language mode with `ExistentialAny`, and the app builds with complete strict concurrency. Closed sets of states and kinds are enums, like `EventKind`, never strings. `Any` and `[CFString: Any]` appear only at the ImageIO and IOKit boundary, and are converted to typed values in the same function. Model output is decoded into `ClassificationSchema` types, never scraped with regex. `@unchecked Sendable` requires a comment that states why the type is safe. **Explicit error handling:** each module throws its own `LocalizedError` enum (`ConfigError`, `IngestError`, `OllamaError`, `PromptError`) that carries context: the path, document ID or model involved. Use `try?` only when failure is an expected outcome and the fallback is correct, as with probes, optional metadata or best-effort cleanup. When a failure affects a document, it is recorded in History and the trace, not swallowed. No `fatalError`, no `try!`, and no force unwrap of values that come from disk, Ollama or the model. `preconditionFailure` is allowed only when a programmer invariant on constant input is broken, such as a regex pattern literal that fails to compile, never for anything that comes from outside the code. | `swift build` with the strict settings. `scripts/lint.sh` (crash gate; SwiftLint `force_unwrapping`). Review. |
| **Tested first, at every boundary** | **Red, green, refactor:** a defect or new behavior starts with a test that fails for the stated reason, then the change makes it pass, then the code is cleaned up. A test that could pass without the change is not the regression test: show that it fails without the fix, for example by disabling the fix, and say so in the report. **Pyramid:** unit tests for domain logic with the doubles in `Tests/Support` (`MockOllama`, `TestEnvironment`) and stubs of `Contracts` protocols; integration tests for storage, migrations, the archive's record files and the pipeline end to end (`IngestCoordinator`, `RethinkCoordinator`, rebuild); contract tests for model schemas, `pipeline.json` and migrations (`ConfigTests`, `MigrationTests`). **Coverage:** every change covers its happy path, its boundaries, malformed, missing and conflicting input, the failure, retry and timeout paths it touches, and its explicit error states. **Determinism:** no sleeps (wait on a condition with a deadline), no wall-clock time, randomness or model calls a test cannot control; inject them. **Semantic assertions:** each `#expect` checks the specific outcome, not a broad boolean, and its message says why it matters. Flaky, redundant or dead tests are fixed or deleted in the same change. | `swift test` in `scripts/verify.sh`. Review. The report's Test Coverage and Verification Summary. |
| **Research-grounded decisions** | A non-obvious design cites its source at the code site or in `docs/`. Examples: records-management practice ([sources](docs/organizing-principles-sources.md)), calibration and embedding methods, data-visualization choices, and Apple documentation for platform behavior. Prefer the Apple frameworks already in use (PDFKit, Vision, NaturalLanguage, ImageIO) and established libraries over hand-written parsers. A change to placement behavior (prompts, the built-in logic, thresholds, calibration, rules, the placement guard, evidence) comes with `arrumator eval Tests/Fixtures --passes 2` numbers from before and after. The report quotes them, and any regression needs an explicit justification. | Review. Eval numbers in the report. |
| **Zero technical debt** | A change leaves nothing behind that it made obsolete. Superseded code is **deleted in the same change**, not deprecated. That means no compatibility shims, no `Legacy`, `Old` or `V2` names, no flags that keep the old path alive, and no commented-out code. The same goes for anything without a user: a config key is removed together with its struct field, and likewise unused prompt templates, `EventKind` cases, CLI flags, target dependencies and package dependencies. No `TODO`, `FIXME`, `HACK` or `XXX`: finish the work or don't start it. Tests for removed behavior are deleted, and tests for changed behavior are updated, never disabled. The documentation changes in the same change as the behavior it describes (§4.10). No new compiler warnings. | `scripts/lint.sh` (debt gate). `scripts/deadcode.sh` (Periphery) for unused code. Review. |

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
2. **The user's files and learned state are never collateral damage.** The archive, Incoming, the text a user writes in
   `_about.md` (everything outside the block the app maintains) and the extended attribute holding the original file
   name are the user's data. No code path may delete a document. Every move is recorded and can be undone. A breaking
   change to the database or config may drop learned state (rules, corrections, history), but the app must detect the
   old state and either stop with an actionable error or rebuild from the archive on disk. It must never silently
   misread old data. Your report says what the installed app loses. A forward migration in `AppDatabase.migrator` is the
   default. You may rewrite or squash earlier migrations when that simplifies the schema, but the same conditions apply.
3. **Never touch the real archive while testing.** The default settings point at `~/Documents/Incoming` and
   `~/Documents/Archive`, so `ARRUMATOR_HOME` alone does **not** isolate you. Before you run any CLI command other than
   `eval`, `--version` and `help`, set `ARRUMATOR_HOME` to a scratch directory **and** write a `settings.json` there
   that points `incomingPath` and `archivePath` at scratch folders. Every other command opens the archive the settings
   name, and opening it can create the archive and its `System` folder and write its record files: this includes `ingest
   --dry-run` and commands that only read, such as `logic show`. Only `eval` isolates itself. Unit tests use
   `TestEnvironment` and `MockOllama`, and nothing in `swift test` may need a running Ollama. A test that needs a live
   model is opt-in through `RuntimeEnvironment.live` (`ARRUMATOR_LIVE=1`).
4. **Every decision can be audited.** A new pipeline stage, decision or automatic action records a trace through
   `TraceRecorder`: its inputs, outputs, raw prompts and responses, and timing. When it changes a file, folder, rule or
   setting, it also records a History event (`EventKind`). Its counts and drop-off reasons show up under the right
   funnel step (`ProcessingFunnel`) in Statistics and in `arrumator funnel`.
5. **Model output is untrusted input.** Decode it into the typed schema, validate it with `PlacementGuard` and
   `Calibrator`, and send anything invalid or uncertain to Needs review. Names from the model go through
   `FilenameBuilder` and taxonomy sanitization before they reach the disk. The app builds every path from folder codes,
   and the model never supplies one.
6. **Logic stays below the UI.** Views and CLI commands call Runtime and Core, and they only present and parse. A new
   action for the user also gets an `arrumator` command with `--json` output, so tests and agents can drive it.
7. **The interface stays quiet.** The app follows Things: a sidebar of a few lists, one list per page under a large
   title, rows without separators, and an item that opens in place as a card. Working screens have no dashboards, stat
   tiles or counters. A count appears only where something is waiting for the user. Numbers belong in Statistics. Every
   document row shows its decision, and every decision can be changed from its card through `ReviewActions`, so the
   change is learned from. Layout values and colours live in `Style` and `Palette`, and wording in `Wording`. Views
   never hardcode them.
8. **Ask before irreversible or outward-facing actions:**
   - committing, pushing or rewriting git history;
   - deleting or rewriting anything in the user's real archive, Incoming folder, `~/Library/Application
     Support/Arrumator` or `~/Library/Logs/Arrumator`, including applying a rethink there;
   - pulling or deleting Ollama models (pulls are several GB, and the app itself never deletes models);
   - running `scripts/release.sh`, which signs and notarizes with the user's Apple account.
9. **Verify before you say it's done.** Run `scripts/verify.sh`, adding `--app` when `App/` or `project.yml` changed,
   and quote its result. If a step fails or you skipped it, say so plainly.
10. **Documentation changes with the code, every time.** A change is not done until every document that describes what
    it touched says what the code now does, in the same change. Where each thing is documented: [README.md](README.md)
    for what users see first, installing and getting started; [docs/how-it-works.md](docs/how-it-works.md) for how
    documents are decided, filed and learned from; [docs/using-arrumator.md](docs/using-arrumator.md) for the app's
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
| `Sources/ArrumatorCore` | Contracts, configuration, SQLite storage, taxonomy and `_about.md`, watchers, file operations, the ingest state machine, the Ollama client, lifecycle and network guard, search, observability. | GRDB, Yams, Apple frameworks. Never Extract, Classify or Runtime. |
| `Sources/ArrumatorExtract` | Turning any file into `ExtractedContent`: format extractors, OCR, vision description, language, dates, identifiers. | Core, CoreXLSX, ZIPFoundation, Apple frameworks. |
| `Sources/ArrumatorClassify` | Filing decisions and learning: evidence, rules, prompts, model calls, the placement guard, calibration. | Core |
| `Sources/ArrumatorRuntime` | The composition root: builds and wires the concrete services and starts the background tasks. | Core, Extract, Classify |
| `Sources/ArrumatorCLI` | `arrumator` commands: argument parsing and output only. | Runtime, Core, Classify |
| `App/` | The SwiftUI menu-bar app: `AppModel`, pages and the shared row and card views, presentation only. | Runtime, Core |
| `Tests/Support` | Shared test doubles: `MockOllama`, `TestEnvironment`. | Core |
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
| `swift test --filter <Suite>` | Runs one suite while you iterate. |
| `swift run arrumator doctor` | Checks the environment: Ollama, models, folders. |
| `swift run arrumator ingest --dry-run <file>` | Shows what the pipeline would decide, without moving the file or recording a decision. It still opens the archive, so only in a scratch `ARRUMATOR_HOME` (§4.3). |
| `swift run arrumator rethink start --trial --now` / `rethink plan` | Tries the archive's logic on a few documents and lists what would change. Only run it in a scratch `ARRUMATOR_HOME` (§4.3), then `rethink discard`. |
| `swift run arrumator trace <doc> --full` / `replay <doc> --model <m>` | Shows how a past decision was made, or re-runs it with another model, without touching files. |
| `swift run arrumator eval Tests/Fixtures --passes 2` | Measures placement quality on the fixture corpus in a throwaway archive. Needs a local Ollama with the profile's models. |
| `swift run arrumator eval Tests/Fixtures --only pt/ --passes 1` | A quick look at one part of the corpus while iterating; the full two-pass run gives the numbers for the report. `--logic <file>` files by another logic, `--model <m>` with another chat model. |
| `swift run --package-path Tools/FixtureGen fixturegen --out Tests/Fixtures` | Regenerates the fixture corpus and `expected.json`. |

Every `arrumator` command accepts `--json`. [docs/cli.md](docs/cli.md) lists them all.

## 7. Definition of done

- [ ] The acceptance criteria pass, and the output of the verify command is quoted in the report.
- [ ] New behavior has tests. A bug fix has a regression test that failed before the fix, and the report says how that
      was shown.
- [ ] The report has a Test Coverage and Verification Summary: happy paths, boundary cases and failure modes covered,
      and what is not covered.
- [ ] `scripts/verify.sh` passes, with `--app` when `App/` or `project.yml` changed. Before and after eval numbers are
      included when placement behavior changed.
- [ ] The change adds no environment reads outside `RuntimeEnvironment`, no tunables written as literals, and no
      defaults outside `Defaults/*.json`.
- [ ] Superseded code, config keys, prompts, tests and dependencies are deleted. No TODO markers and no new warnings.
- [ ] Every document the change affects is updated in the same change (§4.10), and the report lists them.
      `scripts/check-docs.sh` passes as part of `scripts/verify.sh`.
- [ ] The report states what breaks for the installed app: lost learned state, renamed config keys, changed CLI output.

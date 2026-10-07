# Agent Execution Contract

These rules bind every agent and every person who changes this repository. The contract is deliberately short, so read
all of it before every task. Tasks teach it new rules (§2), and it stays short because a rule is never just appended:
it is merged with the rules it overlaps into one broader rule, replaces those it contradicts or makes obsolete, and goes
in the section that owns its concern, and what it subsumes is deleted rather than kept beside it. Only the user may
make a rule demand less or a check catch less. What the product does is in [README.md](README.md); how the pipeline
decides and files is in [docs/how-it-works.md](docs/how-it-works.md); how the code is arranged to do it, and why, is
in [docs/architecture.md](docs/architecture.md).

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
3. Use §5 and [docs/architecture.md](docs/architecture.md) to find the modules the change touches. Read their code
   and tests, and only those. If the change affects how documents are read, labelled or named, also read the app's
   prompt, [labels-system.md](Sources/ArrumatorClassify/Prompts/labels-system.md).
4. Before you write code, state the acceptance criteria and the exact command that will prove them: a test, an
   `arrumatorcli` command or an eval run; for what only the app shows, the steps in the built app, in a scratch home
   (§4.3), with the pointer and with the keyboard alone, and what was seen.

Then, for a QA issue, a defect or an architectural task:

1. **Reproduce.** Find the root cause and write the smallest test that fails for exactly that reason.
2. **Fix.** Implement or refactor until it passes, following §3 and §4.
3. **Clean up the tests.** Update or replace the unit and integration tests the change made obsolete, and delete
   flaky, redundant or dead ones.
4. **Review.** Every change takes this step, documents and scripts included. Before the change is reported as done,
   read the whole diff as a reviewer would, by [docs/review/code-review.md](docs/review/code-review.md) and, for Swift
   and the app, [docs/review/swift-apple.md](docs/review/swift-apple.md), and fix what that finds. A change headed for
   `main` is also reviewed, before it is merged (§8), by someone who did not write it, in a fresh context: a person, or
   an agent started without your conversation, which reviews and never fixes or approves. **Nothing found is left.**
   Every finding of a review, of a QA run ([docs/qa/protocol.md](docs/qa/protocol.md)) or of a check, whatever its
   rating, whether the change brought it or it was there before, is fixed before the change is merged, with the
   regression test that keeps it fixed, or, where no test reaches it, as a view's keyboard, the QA driver or a prompt's
   wording, the QA protocol step, gate or evaluation that does: in the change, or, when it would make the change more
   than one thing, in a pull request of its own merged before it. No finding stands with a reason, waits in a report,
   or is called the next change's.
5. **Learn.** Every task that fixes a defect, changes code or corrects an inconsistency takes this step, not only the
   tasks above, and takes it again when something goes wrong later, such as a check failing on the pull request. Find
   what let the error in and what else went wrong on the way, such as a correction from the user or a reviewer, or a
   decision the rules left open. Turn it into a rule that prevents its whole class of error ("Always…", "Never…",
   "Ensure…"), enforced wherever a script or a test can catch it (a gate in `scripts/lint.sh`, `scripts/check-docs.sh`,
   a test), and fold it into this file in the same change, as the top of the file says. The regression test holds the
   instance; this file holds the class. When the rules and checks already cover what happened, leave the file as it is.
6. **Report.** Give a Test Coverage and Verification Summary: the happy paths, boundary cases and failure modes now
   covered, what is not covered, the verification output (§7) and what the review found. End it with a
   `[GUIDELINE REFINEMENT]` block saying what the Learn step did to this file, such as
   `Refined Guidelines: Merged <old rule> with <new rule> under §<n> to prevent <issue>.`, or which rules and checks
   already covered what happened.
7. **Deliver** through the push protocol (§8).

## 3. Core principles

These are rules you can check, not aspirations. Each row says how it is checked; Review is the review
[docs/review/code-review.md](docs/review/code-review.md) describes, which also says what each gate does not see.

| Principle | Rule | Checked by |
|---|---|---|
| **Zero hardcoding** | Four rules. **(1) Environment:** only `RuntimeEnvironment.current` reads process environment variables, and everything else receives a `RuntimeEnvironment`. The one exception is `OllamaLifecycle.spawnServe`, which passes the environment on to the child process. A new variable is named `ARRUMATOR_*`, lives in `RuntimeEnvironment`, and is listed in [docs/using-arrumator.md › Configuration](docs/using-arrumator.md#configuration). **(2) Tunables:** these all live in bundled `Defaults/pipeline.json` (pipeline behavior) or `Defaults/settings.json` (user preferences): thresholds, weights, timeouts, retry and backoff settings, intervals, limits, sizes, model names and profiles, endpoints. Each is mirrored by a field in `PipelineConfig` or `AppSettings` that has no default value, and a key no field reads is refused by name, never ignored, so a key an earlier version wrote is never read as something else (`ConfigLoader`, §4.2); nothing is saved that the next load would refuse (`SettingsStore`). A value an earlier version accepted that a new rule refuses stops the load with an error that names the file and how to mend it, and `arrumatorcli settings` can always mend it; state that more than one process changes is read again, changed and saved under one lock (`SettingsLock`), whose wait is bounded and ends when its task is cancelled. The bundled JSON is the only place a default is written. Code gets values injected and never adds its own fallback, such as `?? 0.8`. A value is a tunable if an eval run or a user could want a different one, or if changing it changes how documents are labelled, named or found, when or how fast. **(3) Business logic that can vary** sits behind a protocol in `Contracts/Protocols.swift` and is wired in `ArrumatorRuntime`, or it is data: prompt templates in `Prompts/*.md`, model profiles in `settings.json`. **Reading knowledge never lives in code.** No Swift `switch` or `if`, keyword list or regex table may map document types, senders, keywords or languages to labels or names. What a document is, what it concerns and what it is called is the model's judgment, guided by the app's prompt (`labels-system.md`), and checked as the contract of each `LabelKind` fixes it (`DocumentLabel.normalized`, `AnswerValidator`): an ISO date, an ISO 639-1 code, one of `DocumentType`. **(4) Contract constants** are facts fixed by a format or protocol: schema versions, PDF points per inch, Ollama API paths, identifier formats such as IBAN or NIF, buffer sizes that don't affect results. They are named `static let` constants on the type that owns them. They never appear as bare literals in logic, and they never go in config. **Test data** lives in fixtures and builders (`Tests/Fixtures` from `Tools/FixtureGen`, the helpers in `Tests/Support` and each suite's support file), not in literals copied from test to test. | `scripts/lint.sh` (environment gate). `ConfigTests` decodes the bundled defaults, and a missing key, a key no field reads and settings the next load would refuse each fail. Review. |
| **Architectural excellence and testability** | Clean code, SOLID and DRY. **DRY means one source of truth for each fact:** defaults in `Defaults/*.json`, prompts in `Prompts/*.md`, the schema in `AppDatabase.migrator`, contracts between modules in `ArrumatorCore/Contracts`, and a queue's order in the one query its worker takes from (`JobStore.nextDue`), by a key nothing rewrites, the order items were queued in: when an item is due only gates it, never orders it, and work queued for the whole archive at once gives way to every other item (`JobRecord.givesWay`) and is taken only by the worker that runs the queue or a command that asks for it, never by one that came to file a file (`Draining`). A queue drops no request: an item already queued for the same file or document answers a new one only when it does all the new one asks, and one that does less, or comes later, gives way to it (`JobStore.enqueue`). Work queued for a document follows it (`jobs_follow_document`) and acts on it where it is when its turn comes, never where it was when it was queued; what the user does with the document meanwhile wins, decided where it acts: setting it aside cancels the work in the same write (`JobStore.cancelReadingAgain`), and the work checks again before it changes the document (`IngestCoordinator.filing`). Work a process takes from a queue shared through the index records which process holds it (`ProcessTag`), and what that work keeps is decided by whether it still holds the item; an item whose process has ended goes back into the queue (`ModelQueue`). A worker takes an item in the write that claims it, every save of it is conditional on the claim, and what a failure does is decided where it acts, under the claim (`JobStore.nextDue(claiming:)`); once an item finds away what the items need, as Ollama, the worker takes no other that needs it until that one is tried again, only those whose next step does without it, as a file that came, which may be a copy to hand over (`JobStore.beforeTheModel`), and says until when they wait, so none is begun only to wait too (`ollamaRetryAt`). A row is changed with its read in one transaction, writing only the columns changed (`DocumentStore.update`), and what the user changed meanwhile is never written over by the model's reading (`IndexStore.saveReading`). What replaces all a document has, as reading it again does, writes nothing of it until it is done and then replaces it whole, in the transaction that records it, so the index never holds parts of two and a stop or failure part way leaves its labels, text and meaning as they were (`IndexStore.replaceReading`); what it failed to make, labels or an embedding, never erases what the document had; and what the user changes after asking for it wins. Logic that both the app and the CLI need lives in Core or Runtime, never in a copy per view and per command. **A decision is taken where it acts:** what decides whether data is written, replaced or dropped, or whether work starts, is checked inside the transaction or the one serialized step that acts on it (`ArchiveRecords.inTurn`, the runtime's start step), never before it, where another change can come between. **Dependency injection and inversion of control:** anything that talks to a model, the disk, the network or the clock is injected, behind a protocol where tests need to replace it, and wired in `ArrumatorRuntime`, so every collaborator can be replaced by a test double. A runtime acts on what it was made with: its archive (`ArrumatorRuntime.archive`), its index and its Ollama connection are handed to every service when it is made, and only `bootstrap` and `switchArchive` read the archive from the settings (archive gate). **Strong typing:** the package builds in Swift 6 language mode with `ExistentialAny`, and the app builds with complete strict concurrency. Closed sets of states and kinds are enums, like `EventKind`, never strings. `Any` and `[CFString: Any]` appear only at the ImageIO and IOKit boundary, and are converted to typed values in the same function. Model output is decoded into `ClassificationSchema` types, never scraped with regex. `@unchecked Sendable` requires a comment that states why the type is safe. **Explicit error handling:** each module throws its own `LocalizedError` enum (`ConfigError`, `IngestError`, `OllamaError`, `PromptError`) that carries context: the path, document ID or model involved. Use `try?` only when failure is an expected outcome and the fallback is correct, as with probes, optional metadata or best-effort cleanup. A fallback, `try?` or a `catch` that goes on, stands in only for the failures it can: never for cancellation, which must stop the work, nor for Ollama being away when the work goes on to need it (`SearchService.relevance`). When a failure affects a document, it is recorded in History and the trace, not swallowed. A failure that retrying cannot change, such as a Trash that refuses, is never retried or worked round by repeating the act that failed: it is recorded once and the item is left where it is, in a state the queue and rescans respect. No `fatalError`, no `try!`, and no force unwrap of values that come from disk, Ollama or the model. An encoder or formatter never returns a placeholder (`"null"`, `""`) for a value it could not write: it throws, and the caller decides (`JSON.string`). `preconditionFailure` is allowed only when a programmer invariant on constant input is broken, such as a regex pattern literal that fails to compile, never for anything that comes from outside the code. **Stopping is awaited, and every wait can end:** work that opens or starts anything is the runtime's, which runs once, and its `stop()` tells every worker to stop before it waits for any. A wait on something another task releases ends when its task is cancelled (`AsyncSemaphore`). A stream that more than one consumer, or one after another, reads is made per subscriber, and a wait with a timeout ends by a one-shot of its own, never by cancelling a task that awaits a shared stream (`Doorbell`). Work the app must finish before it ends runs before AppKit lets it end, by one path (`applicationShouldTerminate` answering `.terminateLater`; nothing else in `App/` stops the runtime), bounded by a tunable (`ingest.quitTimeout`), never in a task `applicationWillTerminate` starts, which the process ends before it runs; what a stop or a crash cuts off carries on first at the next start. A step that starts something outside the process (a server, a child process) is one task every caller meanwhile awaits, learns nothing from its own cancellation, and starts nothing once a stop has begun; what reacts to it, such as an exit handler, acts only for the instance it started (`OllamaLifecycle`). A command stops every runtime it opened by one path, on its end and on SIGINT or SIGTERM (`Arrumator.main`). | `swift build` with the strict settings. `scripts/lint.sh` (crash and quit gates; SwiftLint `force_unwrapping`). Review. |
| **Tested first, at every boundary (shift-left QA)** | **Red, green, refactor:** a QA defect or new behavior starts with a test that reproduces it and fails for the stated reason, then the change makes it pass, then the code is cleaned up. A test that could pass without the change is not the regression test: show that it fails without the fix, for example by disabling the fix in place, never by stashing it, which takes the rest of the uncommitted work out of the tree too, and say so in the report; then restore the fix and rebuild before anything else runs, as the build products keep the disabled code. **Pyramid:** fast, isolated unit tests for domain logic, with a test double for every external interface: the doubles in `Tests/Support` (`MockOllama`, `StubAnalyzer`, `TestEnvironment`, `TestTime`, `Harness`) and stubs of `Contracts` protocols; integration tests at the data boundaries, which assert on the state a change leaves in the database and on disk, not only on what a call returns: storage, migrations, the queues across a stop part way and a restart (`JobStore`, `SearchTaskQueue`, `TaskConversationQueue`), the archive's record files and the pipeline end to end (`IngestCoordinator`, `ArchiveReconciler`, rebuild); contract tests for model schemas, Ollama's HTTP API (the requests `OllamaClient` sends and the responses it decodes), `pipeline.json` and migrations (`ConfigTests`, `MigrationTests`); contract and end-to-end verification that a schema migration or breaking refactoring still gives its callers what they rely on (the app, the CLI and its `--json` output in `ArrumatorCLITests`, which runs the built command, record files written by earlier versions). **Coverage:** every change covers its happy path, its boundaries, malformed, missing, empty and conflicting input, the failure, retry and timeout handlers it touches, and its explicit error states. Each condition of a rule is tested on its own, shown by deleting it: each value of a set it treats alike, as the signs a number's name ends with or the separators a path is told by, each operand of a compound condition and each case of a `switch`, as a test of one still passes when another is dropped; a guard no input reaches is deleted, not kept untested. **Determinism:** no sleeps (wait with a deadline, `Patience.until`, for the very condition the test needs, such as a double being reached, not one that comes before it, and never by awaiting inline a call that may wait for a condition, such as a start while the archive is away: it runs in a task of its own, so a wait that never ends fails its test instead of hanging the run; which tests hang is read from `swift-inspect dump-concurrency <pid>` or a run whose output is a terminal, never from piped output, which the test process holds back), `Patience` pauses between its looks, never spinning on `Task.yield`, which starves the work it waits for, and its limit, below a suite's time limit, only tells a hang from a wait; a test asserting that something did not happen first waits for the work to reach the point where it would have, such as a worker's idle wait (`Doorbell.isWaitedOn`), and one asserting that a process ended waits for it to end (test-sleeps gate); no wall-clock time without an injected clock (`TimeSource`, and `TestTime` in tests, which moves only when a test or a sleep on it moves it), and no randomness or model calls a test cannot control; inject them. A double that acts as the user while work runs, such as `StubAnswerer`'s `during`, acts from a task of its own, as the app does, never from inside the work it interrupts, whose cancellation would reach it. A test that needs something a machine may lack (a live model, a platform capability) says so and is skipped with that reason where it is missing, never left to fail or pass by chance; one that needs a file or a folder closed to the user, which nothing is to the superuser, is enabled only for another user (`.fileModesKeepOut`, `.folderModesKeepOut`). A double that serves another process, as a stand-in server for a command a test runs, works on threads of its own, never Dispatch's or Swift's shared pools, which the tests waiting on that command hold (`ChildProcess`, `LoopbackOllama`); and a command run against it is given time a loaded runner needs, as a test asks what the command does, not how fast the runner is. **Semantic assertions:** each `#expect` checks the specific outcome, not a broad boolean, and its message says why it matters. Two spellings of one path (a link, another case, `/private`) are compared in one form: a path a person names is the item it names, never what a link at its last component points to (`URL.spelledOnDisk`), and whether a path is inside a folder, the archive above all, is asked of `URL.holds`, which compares both as the disk spells them, never by `hasPrefix` on the path as written; such a decision is tested through a link and in another case. Unicode normalization is asserted on bytes (`Array($0.utf8)`), as Swift's `==` holds a composed and a decomposed name equal, and a name that leaves the Mac, as in a ZIP archive, is asserted composed whatever the disk holds: Foundation can write names to disk decomposed. Flaky, redundant or dead tests are fixed or deleted in the same change. Every lint gate proves it can fail: it refuses sample lines of what it forbids, and a search that cannot run fails it (`scripts/lint.sh`). | `swift test` in `scripts/verify.sh`. Review. The report's Test Coverage and Verification Summary. |
| **Research-grounded decisions** | A non-obvious design cites its source at the code site or in `docs/`. Examples: records-management practice ([sources](docs/organizing-principles-sources.md)), embedding and search methods, data-visualization choices, and Apple documentation for platform behavior. Prefer the Apple frameworks already in use (PDFKit, Vision, NaturalLanguage, ImageIO) and established libraries over hand-written parsers. A change to analysis behavior (the prompt, the answer schema and its validation, the `analysis` and `labels` settings, the label kinds) comes with `arrumatorcli eval Tests/Fixtures --passes 2` numbers from before and after. The report quotes them, and any regression needs an explicit justification. | Review. Eval numbers in the report. |
| **Zero technical and test debt** | A change leaves nothing behind that it made obsolete. Superseded code is **deleted in the same change**, not deprecated. That means no compatibility shims, no `Legacy`, `Old` or `V2` names, no flags that keep the old path alive, and no commented-out code. The same goes for anything without a user: dead code, a config key (removed together with its struct field), unused prompt templates, `EventKind` cases, CLI flags, target dependencies and package dependencies. No `TODO`, `FIXME`, `HACK` or `XXX`: finish the work or don't start it. Tests for removed behavior are deleted, and tests for changed behavior are updated, never disabled. Obsolete workaround patches, flaky tests and redundant assertions go too; fixtures the change made stale are updated in the same change, and fixtures nothing uses are deleted. The documentation changes in the same change as the behavior it describes (§4.10). No compiler warnings: a warning fails the build. | `scripts/lint.sh` (debt gate). `scripts/deadcode.sh` (Periphery) for unused code. Review. |

## 4. Hard rules (non-negotiable)

1. **Everything stays local.** Document data never leaves the machines the user runs: this Mac, or the user's own Ollama
   server on the local network. The only network client is `OllamaClient`, behind `OllamaConnection`, whose
   `NetworkGuardProtocol` session lets a request reach only the one configured server, and by no other route: the guard
   first, every proxy off, redirects refused, the host compared in one form and carried on each request (a test for
   each route). That server's address (`AppSettings.ollamaURL`, or `ARRUMATOR_OLLAMA_URL`) must pass
   `OllamaEndpoint.validated`: loopback, private or link-local addresses, `localhost` or a `.local` name, and nothing
   but a scheme, host, port and path. Never widen that rule to a public host, and never read with a model the server
   runs elsewhere (`ModelLocation`): local means where the model runs, not only where the server is. Never create
   another `URLSession` or use `URLSession.shared`. Never add a dependency, telemetry, crash reporter, update check or
   web view that can reach the network. Models are downloaded only when the user presses Download. Document text is kept
   only in the database and traces, and is sent only to that Ollama server. It never goes into logs: a log message is a
   `StaticString`, and what varies goes in fields. What is made to be shared (diagnostics, the trace a bug report asks
   for) is built by allow-list, field by field (`DiagnosticsExporter.shareable`, `LogEntry.shareableFields`), and holds
   nothing derived from a document (its text, names, identifiers or labels) unless the user opts in.
2. **The user's files and learned state are never collateral damage.** The archive, Incoming, what a user writes into
   the record files and the extended attribute holding the original file name are the user's data. No code path may
   delete a document: a file the app has no more use for, such as an exact copy of a document in the archive, goes to
   the Trash through `Trashing` (trash gate in `scripts/lint.sh`). Every move is recorded and can be undone. A breaking
   change to the database or config may drop state the app keeps (history, what the model read), but the app must detect
   the old state and either stop with an actionable error or rebuild from the archive on disk. It must never silently
   misread old data: a field added to a record file, a job's payload or a History payload never takes a key an earlier
   version wrote for something else (entries of the releases that filed into folders hold topics under `tags`), is
   optional when old data lacks it, is tested against the files each release wrote (`EarlierRecordFilesTests`), and is
   written only when it differs from what its absence has always meant (`tags_only`). A record file is read by one
   reader that tells a file that is not there from one that cannot be read (`RecordFile.text`): one that cannot be read
   is never taken as empty, and `arrumatorcli doctor` names it and why. A record file is written over or removed only
   when it holds what the app last wrote or has just read. A rebuild that lacks a file refuses, naming it, rather than
   go on without it, and the runtime starts nothing on an index not rebuilt from its archive
   (`AppDatabase.pendingRebuild`). A folder the app watches that goes, renamed, removed or on a disk that went, is the
   folder not being there, never its documents removed: nothing in it is marked missing, nothing is made again where it
   was, the work waits, and it goes on by itself once the same folder is back (`FolderIdentity`: the volume's UUID and
   the folder's inode, never a device number). Record files from a folder other than the one the index was kept for are
   merged with the index, never read as edits that replace it. Which of two places or lists is the original is never
   decided on a guess: without a signal that tells them apart, no identifier is stripped, nothing is adopted and no list
   is dropped or rewritten; the document stays at one place by a stable choice, the other list keeps its entry as it is,
   and the user is told in History and the Doctor (`TwoPlaces`). A file another process may still be writing, such as a
   record file's staged text, is never taken for one a crash left until it is older than a tunable
   (`records.stagedLeftoverMinutes`). Whether an archive is new is decided by what the user did (finishing onboarding,
   switching to a folder), never by what its index lacks: at any other time an archive whose folder is not there is
   away, never made again, read as empty or written into (`RecordsError.archiveNotThere`). Your report says what the
   installed app loses. A forward migration in `AppDatabase.migrator` is the default. You may rewrite or squash earlier
   migrations when that simplifies the schema, but the same conditions apply.
3. **Never touch the real archive, the user's Trash, or the user's running app, while testing.** The default settings
   point at `~/Documents/Incoming` and `~/Documents/Archive`, so `ARRUMATOR_HOME` alone does **not** isolate you. Before
   you run the app or any CLI command other than `eval`, `--version` and `help`, set `ARRUMATOR_HOME` to a scratch
   directory **and** write a `settings.json` there that points `incomingPath` and `archivePath` at scratch folders. The
   app and every other command open the archive the settings name, and opening it can create the archive and its
   `System` folder and write its record files: this includes `ingest --dry-run` and commands that only read, such as
   `labels <document>`. Set `ARRUMATOR_TRASH` to a scratch folder too: the app and every command use it as the Trash.
   Only `eval` isolates itself, its Trash included. The user may be running Arrumator, even from
   the same build folder, so stop, drive or capture the windows of only the process you started, found by its PID and
   its `ARRUMATOR_HOME`, never by its name. Driving it stays inside the scratch folders: a file panel is pointed at one
   before Open or Save, and nothing that lists the user's own files, a file panel or the system's Apple menu, is read or
   captured (`scripts/qa-drive.sh` refuses both). Unit tests use `TestEnvironment`, whose Trash is a folder of its own
   (`FolderTrash`, as every runtime a test or `eval` builds is given), and `MockOllama`, and nothing in `swift test` may
   need a running Ollama. A server the user lends for a live run, such as an Ollama on their network, is named on the
   command (`ARRUMATOR_OLLAMA_URL`), never written into the repository. How well a live model reads is measured with
   `arrumatorcli eval`, not in `swift test`.
4. **Every decision can be audited.** A new pipeline stage, decision or automatic action records a trace through
   `TraceRecorder`: its inputs, outputs, raw prompts and responses, and timing. When it changes a file, a document's
   labels or a setting, the action that makes the change, shared by the app and the CLI, also records it once in
   History (`EventKind`): a setting changes only through `SettingsActions` or an action of its own, such as
   `setPaused`. A change that is made is recorded once: an event that cannot be recorded yet, as on an index not
   rebuilt from its archive, is held and recorded when it can (`HistoryStore.insert`), never refused after the change.
   An action that would change nothing records nothing, and one that does not apply to the item as it is, such as an
   undo of a document not in the archive, is refused before it touches a file, both decided where they act
   (`ReviewActions.confirm`, `undo`). What History says is what happened: never a move to where a file was, a name it no
   longer had, or "nothing worth a label" for a file nothing could be read of (`DocumentFiler.summary`), and paths in
   one spelling, as the disk spells them.
   Its counts and drop-off reasons show up under the right funnel step (`ProcessingFunnel`) in Statistics and in
   `arrumatorcli funnel`.
5. **What the model is asked is a contract; what it answers is untrusted input.** Its answer schemas, its prompts and
   what it is shown of the archive (labels in use, the user's rules) are built from the kinds it gives
   (`LabelKind.modelKinds`, written in `ClassificationSchema.answerOrder`), never from every case of `LabelKind`, which
   also holds the user's own `tag`: a kind added for the user never changes what the model reads, is asked or is decoded
   from (the classify tests fail when one reaches a schema or prompt, and `PipelineConfig.problems` refuses one in its
   configuration). Every example a prompt gives of a label is a value in its kind's form, which validation keeps as it
   is (`LabelFormTests`), never a description of the form or a placeholder that passes as a value (`XXX`), which the
   model copies as a template, and examples of what it writes in the document's language are in several languages, as it
   copies an example's language too; a label is listed to the model as a JSON string, never joined by a separator a
   label can hold. Decode its answer into the typed schema, validate it with `AnswerValidator`, which holds the model's
   labels, as `DocumentLabel.normalized` holds the user's, to their kind's form and the model's names to the document's
   own words, and send a document without a valid answer to Needs You. A validator checks an answer's form and grounding
   by structure, never by a list of words: what only begins an answer goes back
   (`ConversationAnswerValidator.unfinished`), and a label is kept only for words of the request that limit, not arrange
   (`SearchPlanValidator`); a structural guess that would change the result is sent back to the model, naming what it
   found, never dropped unseen, and the model's answer given again stands, as does an answer whose only fault is such a
   guess when no repair is left (`GuessSentBack`): a guess never fails a reading. A value the document itself tells, by
   its layout or its own writing (the party it prints beside the sender, a title of its own words' writing, the number
   beside a field's name), is no guess: it is written in place of the model's at once, noted, as telling a model costs a
   call and a weak one gives again what it is told of (`AnswerValidator.toldByTheDocument`); a value the document does
   not tell is never written in its place, as a guess of form cuts a name or misspells a word; and what Ollama counts,
   such as a prompt filling its context, overrides the estimate the prompt was fitted by (`PromptBudget.measured`).
   Names from the model go through `FilenameBuilder` before they reach the disk, and what is made of its labels, a file
   name above all, is made of those the user's rules keep (`PipelineServices.read`), never of what the model wrote
   before them. The app builds every path itself: the model supplies a file name, never a directory. Nothing the model
   writes becomes active where it is shown: a link or an image in its Markdown is plain text (`AnswerMarkdown`). A file
   put into Incoming is untrusted input too. It is parsed within budgets checked on the sizes and counts it declares
   before anything is decoded, with overflow-checked arithmetic, in passes linear in its size, and each limit has a
   hostile-input test bounded by `.timeLimit` (`ZipDirectory`, `SpreadsheetML`, `HTMLText`). A library that cannot be
   held to those bounds does not parse it. What extraction produces is the same on every Mac and in every script: a day
   is reckoned in an explicit Gregorian calendar and the time zone the runtime gives (calendar gate), a number by its
   value in any script, words as `NLTokenizer` tells them apart; every limit that leaves content out says what it left
   out, and text already read, such as a PDF's text layer, is dropped only for a reading that replaces it. Text keeps
   what the layout sets apart: two columns or a label and its value on one line stay apart, by a tab as OCR parts a
   table's cells (`PDFPageText`), never joined by a space into what a model reads as one name. Reading knowledge moved
   from code into configuration keeps its meaning: the old code's outputs over generated variants (every separator, none
   included, values starting with digits and with letters) are frozen as a fixture, and every difference is listed
   (`StableKeysTests`).
6. **Logic stays below the UI.** Views and CLI commands call Runtime and Core, and they only present and parse. Views
   learn of a change only from Core, whichever process made it, as it is made: a file more than one process writes tells
   the others of each change it saves (`ChangeSignal`: `AppDatabase.othersCommits()`, `SettingsStore.changes()`, each
   tested with a second connection or store), a store reading another's change under the lock a change is made under,
   never while one, its own or another's, is saved and not yet recorded, as it may yet be put back, through History
   (`AppDatabase.activity()`) or a stream of live state (the queues' `statusUpdates()`, `OllamaLifecycle.states()`,
   `SettingsStore.changes()`): a state the user watches is recorded in History when it is a decision, otherwise
   published on such a stream, and a test proves a subscriber is sent it. What is happening now, a file being filed, a
   request being read or a question answered, is decided in Core from such a stream (`IngestStatus.progress(of:)`,
   `SearchTaskQueueStatus.progress(of:)`, `ConversationQueueStatus.progress(of:)`), never by a view from a stored state,
   which says where an item is, not that anything is working on it. A new action for the user also gets an
   `arrumatorcli` command with `--json` output, so tests and agents can drive it: objects and lists of them, never a
   dictionary keyed by anything but a string, which JSON writes as a flat list of keys and values. A view sends what the
   user did (what was added or taken off, a value only when it differs) and never fills a read that returned nothing
   with a fallback; Core applies the change to the current state inside its transaction (`ReviewActions.edit`,
   `LabelEdit`). What the app shows of an archive is one value a switch replaces whole (`ArchiveSession`).
7. **The interface stays quiet.** The app follows Things: a sidebar of a few lists and the archive's labels to narrow
   the documents down by, one list per page under a large title, rows without separators, and an item that opens in
   place as a card. A list is ordered as it is read, by an order in Core that the app and the CLI share (`DocumentOrder`
   for documents): a queue (the files Incoming waits to file) in the order it is worked through (`JobStore.nextDue`); a
   log (what Incoming just processed, Needs You, Processed, History) by when things happened, the latest first; a
   conversation (a task's questions and answers) in the order it was held, the first question first;
   documents looked for (by labels, by a search task) by their own date, the newest first, never by when the app
   processed them.
   Working screens have no dashboards, stat tiles or counters. A count appears only where something is
   waiting for the user, and beside each label in the sidebar, as how many of the documents in view have it, which is
   what the labels are ordered by. Other numbers belong in Statistics. Every document row shows what happened to it,
   and its name and labels can be changed from its card through `ReviewActions`, and every change is recorded. Layout
   values and colours live in `Style` and `Palette`, and wording in `Wording`. Views never hardcode them. Artwork
   shipped outside the interface, the app icon, is the project's own drawing, generated by `scripts/app-icon.sh` in the
   Incoming list's colour, never an SF Symbol or a glyph like one: the SF Symbols licence allows symbols in the
   interface, not in an app icon (icon gate in `scripts/lint.sh`).
   Everything can be done without the pointer and heard: Return presses the default button of every step of a flow, a
   button bearing a key equivalent keeping an identity of its own while the buttons beside it come and go (`.id`, as
   AppKit otherwise leaves the key on whichever button takes its place: `OnboardingView`), a text field and a switch
   have a name VoiceOver reads, an
   icon-only button says what it does to what ("Remove “EDP”"), an action shown only under the pointer is also an
   accessibility action and a menu item, and a row that opens on a click opens with Return, Space and VoiceOver's
   default action through `rowAction` (rows gate in `scripts/lint.sh`), whose element is the row itself, a spinner in it
   hidden from VoiceOver. A progress line says what is happening now: a
   question or request waits for the model, its turn or Ollama, with when it is tried again, until the model's first
   words come, never "Answering" before, on every surface that shows it (card, row, menu bar, command line), decided in
   Core; and nothing beneath such a wait asks Ollama again meanwhile, embeddings included (`retrying: false`). What
   Core would refuse is said before it is asked, by the very rule the action applies (`LabelError.refusal(of:)`,
   `ModelProfileActions.refusal(ofNewName:in:)`, `ModelProfileListing.removalRefusal`): the control is dimmed or the
   field says why as it is typed, nothing given is dropped without a word, and a refusal names things as the app shows
   them, never by an id; a field's accessible name is stable, never the example its placeholder shows. Layout never
   feeds back on itself: a lazy stack never holds another or a row of unbounded height, text outside a scroll view is
   never sized to its full height without a line limit, and a collection an update replaces wholesale, as narrowing or
   filtering does, is never a SwiftUI `List`, whose AppKit table re-enters itself on such a change, but a lazy stack
   that is one focus stop moved through with the arrow keys, its rows each with `rowAction` (`SidebarLabelList`).
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
    [docs/repository-settings.md](docs/repository-settings.md) for the GitHub repository's settings;
    [docs/qa/protocol.md](docs/qa/protocol.md) for testing the app as a user meets it;
    [docs/architecture.md](docs/architecture.md) for the modules and what each folder of Core owns, how the parts work
    together at run time, the concurrency model and the decisions behind them;
    [docs/review/code-review.md](docs/review/code-review.md) and
    [docs/review/swift-apple.md](docs/review/swift-apple.md) for how a change, and the whole project, is reviewed; this
    file for rules, boundaries and commands. Removed behavior is removed from the documentation too, and code comments
    and CLI help strings count as documentation. `scripts/check-docs.sh`, run by `scripts/verify.sh`, fails when a
    command, option, `ARRUMATOR_*` variable, `pipeline.json` key or script is missing from the documents or named there
    without existing. Everything else is checked in review. The report lists the documents the change updated, or says
    why none needed to change.

## 5. Boundaries

The target dependencies in `Package.swift` and `project.yml` declare the "May import" column. Never widen them just to
make something compile. Instead, move the code to the module that owns it. A module that arrives through another
target can be imported without being declared, so `scripts/lint.sh` (imports) refuses an `import` its target does not
declare, and review holds the declarations to this table. What
is inside each module is in [docs/architecture.md](docs/architecture.md#building-blocks).

| Path | Owns | May import |
|---|---|---|
| `Sources/ArrumatorCore` | Contracts, configuration, SQLite storage, the archive's record files and layout, watchers, file operations, the ingest state machine, the Ollama client, lifecycle and network guard, search, observability. | GRDB, Yams, Apple frameworks. Never Extract, Classify or Runtime. |
| `Sources/ArrumatorExtract` | Turning any file into `ExtractedContent`: format extractors, OCR, vision description, language, dates, identifiers. | Core, ZIPFoundation, Apple frameworks. |
| `Sources/ArrumatorClassify` | Reading documents: the prompt, model calls, the answer schema and its validation into labels and a file name. | Core |
| `Sources/ArrumatorRuntime` | The composition root: builds and wires the concrete services and starts the background tasks. | Core, Extract, Classify |
| `Sources/ArrumatorCLI` | `arrumatorcli` commands: argument parsing and output only. | Runtime, Core, swift-argument-parser |
| `App/` | The SwiftUI menu-bar app: `AppModel`, pages and the shared row and card views, presentation only. Its icon is generated (§4.7): change `scripts/app-icon.swift` and regenerate; never edit the images by hand. | Runtime, Core |
| `Tests/Support` | Shared test doubles and fixtures: `MockOllama`, `StubAnalyzer`, `PerFileAnalyzer`, `TestEnvironment`, `TestTime`, `Harness`. | Core |
| `Tests/Fixtures`, `Tools/FixtureGen` | The synthetic evaluation corpus and its deterministic generator. Change the generator and regenerate; never edit fixtures or `expected.json` by hand. | — |
| `scripts/`, `.githooks/`, `Brewfile` | The checks, the release build, the Git hooks, and the tools they need (pinned by version and checksum in `scripts/tools.sh`; `Brewfile` keeps Node.js only). | — |
| `.github/` | The CI and release workflows, Dependabot, issue and pull request templates. | — |
| `docs/` | The documentation beyond the README (§4.10). | — |

## 6. Commands

| Command | Purpose |
|---|---|
| `scripts/verify.sh` | The done check: `scripts/lint.sh`, `swift build`, `scripts/check-docs.sh`, `swift test`. |
| `scripts/lint.sh` | The static checks alone: guideline gates, secrets, SwiftLint, ShellCheck, actionlint, zizmor, markdownlint, links. |
| `scripts/check-secrets.sh [--staged \| --range <revs>…]` | Secrets, signing material, real documents and, with `--range`, machine-local commit identities. The Git hooks run it. |
| `scripts/bootstrap.sh` | Installs the pinned tools (`scripts/tools.sh`) and Node.js (`Brewfile`), and enables the Git hooks. |
| `scripts/tools.sh` | Installs every tool the checks run, at its pinned version, checked against its published checksum, into `.tools/`. |
| `scripts/verify.sh --app` | Also regenerates the Xcode project, builds the release as a release is built (`scripts/build-release.sh`: the universal app, the Apple-silicon app and the command) and looks for unused code (`scripts/deadcode.sh`). Required when `App/` or `project.yml` changes. |
| `scripts/change-scope.sh main` | What the branch's change needs (§8): `release` for code, `build` for what builds and tests it, `checks` for anything else. |
| `scripts/verify.sh --checks-only` | The static checks and the documentation check alone, with no tests: the done check for a change scoped `checks`. |
| `swift test --filter <Suite>` | Runs one suite while you iterate. |
| `swift run arrumatorcli doctor` | Checks the environment: Ollama, models, folders. |
| `swift run arrumatorcli ingest --dry-run <file>` | Shows what the pipeline would decide, without moving the file or recording a decision. It still opens the archive, so only in a scratch `ARRUMATOR_HOME` (§4.3). |
| `swift run arrumatorcli trace <doc> --full` / `replay <doc> --model <m>` | Shows how a past decision was made, or re-runs it with another model, without touching files. |
| `swift run arrumatorcli eval Tests/Fixtures --passes 2` | Measures how well documents are read (status; type, sender, date and language labels; file name; labelled share; labels per kind) on the fixture corpus in a throwaway archive. Needs a local Ollama with the profile's models. |
| `swift run arrumatorcli eval Tests/Fixtures --only pt/ --passes 1` | A quick look at one part of the corpus while iterating; the full two-pass run gives the numbers for the report. `--model <m>` reads with another chat model. |
| `swift run --package-path Tools/FixtureGen fixturegen --out Tests/Fixtures` | Regenerates the fixture corpus and `expected.json`. |
| `scripts/app-icon.sh [<folder>]` | Regenerates the app icon, `App/Assets.xcassets/AppIcon.appiconset`, or writes it into `<folder>` to look at first. |

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
- [ ] The change was reviewed (§2, Review), and every finding of its reviews and of any QA run of it is fixed, each
      with its regression test, or the protocol step, gate or evaluation that keeps it fixed where no test reaches it:
      none stands, whatever its rating.
- [ ] The Learn step (§2) is done: what the task taught is folded into this file, and the report ends with its
      `[GUIDELINE REFINEMENT]` block.
- [ ] The report states what breaks for the installed app: lost learned state, renamed config keys, changed CLI output.
- [ ] The change reached `main` through §8: green locally, green on the pull request, squash-merged, branch deleted.

## 8. Push protocol

Every change reaches `main` the same way. `main` is released on every merge that changes code, so it only ever
receives changes that are green twice: on your machine and on GitHub's runners. How much is built and checked follows
what the change touches, which `scripts/change-scope.sh` decides for your Mac and for CI alike
([docs/releasing.md](docs/releasing.md#what-a-change-needs-scriptschange-scopesh)):

| Scope | The change touches | Verify with | Released |
|---|---|---|---|
| `release` | Code: `Sources/`, `App/`, `Package.swift`, `Package.resolved`, `project.yml`, `scripts/release.sh`, `scripts/build-release.sh`. | `scripts/verify.sh --app` | Yes |
| `build` | What builds and tests the code: `Tests/`, `Tools/`, `scripts/verify.sh`, `scripts/deadcode.sh`, `scripts/lint.sh`, `scripts/tools.sh`, `scripts/change-scope.sh`, `.periphery.yml`, both workflows. | `scripts/verify.sh --app` | No |
| `checks` | Anything else: documentation, the other scripts and workflows, settings. | `scripts/verify.sh --checks-only` | No |

1. **Green gates locally.** Work on a branch named for the change (`fix/…`, `feat/…`, `refactor/…`, `test/…`,
   `docs/…`, `ci/…`), never on `main`. Before pushing, run `scripts/change-scope.sh main` and the verify command its
   scope calls for, the same checks CI runs, and push only when it ends with `All checks passed`.
2. **Push the branch and get it green on the remote runners.** `git push -u origin <branch>`, then open a pull request
   to `main` (`gh pr create`) with the template filled in. CI runs both of its jobs on it; wait for them with
   `gh pr checks --watch`. When a check fails, fix it on the same branch and push again, until every check is green.
   The review by someone who did not write the change (§2) is written into the pull request, and every finding it makes
   is fixed before the merge (§2, Review).
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

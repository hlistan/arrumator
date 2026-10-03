# Swift and Apple platform review

What a reviewer checks in Swift code and in a Mac app that a linter and the compiler do not settle. It complements the
[code review guidelines](code-review.md), which give the method, and it is written for this project: Swift 6 language
mode, the package's tools version 6.2, macOS 26, SwiftUI on an AppKit shell, GRDB over SQLite, Swift Testing, and a
Developer ID app with the hardened runtime and no sandbox. Each check names its source, and, where the code already
shows how it is done, the place to copy from.

Use it by section: read the sections for what the change touches. The checks are numbered so a finding can cite one
(`K3`, `F2`); the letters differ from those of the code review guidelines, so a citation needs no file name.

- [Names and interfaces](#names-and-interfaces)
- [Optionals, errors and traps](#optionals-errors-and-traps)
- [Concurrency](#concurrency)
- [Memory and performance](#memory-and-performance)
- [SwiftUI and Observation](#swiftui-and-observation)
- [AppKit and the app's life](#appkit-and-the-apps-life)
- [Accessibility and wording](#accessibility-and-wording)
- [Files, processes and untrusted input](#files-processes-and-untrusted-input)
- [The network and the platform's protections](#the-network-and-the-platforms-protections)
- [SQLite and GRDB](#sqlite-and-grdb)
- [Tests](#tests)
- [The package and the build](#the-package-and-the-build)
- [What the tools decide, and what a person must](#what-the-tools-decide-and-what-a-person-must)
- [Sources](#sources)

## Names and interfaces

From the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/): "clarity at the
point of use is your most important goal."

| # | Check | In Arrumator |
|---|---|---|
| A1 | Read the call site, not the declaration: does the call say what happens? "Clarity is more important than brevity." | `JobStore.nextDue()`, `IngestStatus.progress(of:)` |
| A2 | A name without side effects reads as a noun phrase, one with side effects as an imperative verb; a mutating method and its non-mutating twin are a pair (`sort`, `sorted`). | `distinct()`, `ruled(_:)` |
| A3 | A weakly typed parameter (`String`, `Int`, `Any`) has a label that names its role. Booleans read as assertions. | `enqueue(path:kind:docID:payload:)` |
| A4 | Every public declaration has a documentation comment whose first sentence is its summary; "if you are having trouble describing your API's functionality in simple terms, you may have designed the wrong API." | The comment on `DocumentFiler.file` |
| A5 | A computed property that is not O(1) says so, or is a method. A property that decodes JSON or reads the disk on every access is a method. | |
| A6 | Each new `public` is needed by another module. Within the package, would `internal` do? | [Architecture](../architecture.md#changing-the-architecture) |
| A7 | A protocol in `Contracts/` is small and names a capability; it does not expose a storage record or a UI concern. | `ContentExtracting`, `Trashing` |

## Optionals, errors and traps

| # | Check | Source | In Arrumator |
|---|---|---|---|
| E1 | No `try!`, `fatalError` or force unwrap of anything that comes from disk, Ollama or the model. A trap is for a broken invariant on constant input only. | [TSPL, *The Basics*](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/thebasics/): "assertions and preconditions aren't used for recoverable or expected errors" | §3; crash gate |
| E2 | Arithmetic and narrowing conversions on sizes, counts, offsets and durations read from a file cannot trap: Swift's operators "don't overflow by default. Overflow behavior is trapped". Use `Int(exactly:)`, `init(clamping:)` or the overflow-reporting methods. | [TSPL, *Advanced Operators*](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/advancedoperators/) | |
| E3 | Calls that trap on bad data are fed only checked data: `Dictionary(uniqueKeysWithValues:)`, a `Range` with a lower bound above its upper, a subscript, `prefix` with a negative count. | | |
| E4 | `try?` and `?? default` are used only where failure is an expected outcome and the fallback is correct, and never turn "could not read" into "is absent". | [TSPL, *Error Handling*](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/errorhandling/); §3 | |
| E5 | A `catch` that goes on does not catch `CancellationError`: either a `catch is CancellationError` rethrows before it, or the work checks `Task.isCancelled` after. | [`CancellationError`](https://developer.apple.com/documentation/swift/cancellationerror) | `IngestCoordinator.handleFailure`, `SearchService.relevance` |
| E6 | An error thrown inside `Task { }` is handled there, or it vanishes. | [SwiftLint `unhandled_throwing_task`](https://realm.github.io/SwiftLint/unhandled_throwing_task.html) | |
| E7 | Each module throws its own `LocalizedError` enum that carries the path, document or model involved; a closed set of reasons is cases, not strings. | [`LocalizedError`](https://developer.apple.com/documentation/foundation/localizederror); §3 | `IngestError`, `OllamaError` |
| E8 | An error description that comes from a library is not logged or shown unread: it can quote the input, which may be document text. | §4.1 | |
| E9 | Typed throws are not the default: "the existing (untyped) `throws` remains the better default error-handling mechanism for most Swift code." | [SE-0413](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md) | |

## Concurrency

The compiler proves the absence of data races. It does not prove that an invariant survives an `await`, that
cancellation is honoured, or that a task is owned by anyone. Those are the reviewer's.

| # | Check | Source | In Arrumator |
|---|---|---|---|
| K1 | **Reentrancy.** In an actor or main-actor method, is state read before an `await` relied on after it? Actors "do not ensure atomicity across suspension points". Look for check-then-act across an `await`: a guard on a property, then an `await`, then setting it. | [Migration guide, *Data Race Safety*](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/dataracesafety/); [SE-0306](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md) | `SearchTaskQueue.publish` applies its change after the awaited count |
| K2 | **Cancellation is cooperative.** A long loop checks `Task.isCancelled` or calls `Task.checkCancellation()`; work that is suspended and must react uses `withTaskCancellationHandler`. A wait that cannot be cancelled keeps `stop()` from returning. | [SE-0304](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md): "cancellation has no effect at all unless something checks for cancellation" | `Deadline.run`; page loops in `PDFExtractor` |
| K3 | **Cancelling a consumer ends its stream.** A task cancelled while it awaits `AsyncStream`'s `next()` terminates that stream for every later consumer. A stream that must outlive a consumer is made per subscription, and a wait with a timeout never cancels a task that awaits a shared stream. | [`AsyncStream`](https://developer.apple.com/documentation/swift/asyncstream) | `IngestCoordinator.statusUpdates()` makes a stream per caller |
| K4 | **Streams end and are bounded.** Every stream has a path to `finish()`, an `onTermination` that stops its producer, and a buffering policy chosen on purpose; the default buffer is unbounded. | [SE-0314](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0314-async-stream.md) | `.bufferingNewest(1)` for status |
| K5 | **Every `Task { }` has an owner.** Who stores it, who cancels it, who awaits it, and can it act after `stop()`? "If you discard the reference to a task, you give up the ability to wait for that task's result or cancel the task." Stopping cancels everything first and awaits afterwards. | [`Task`](https://developer.apple.com/documentation/swift/task) | `IngestCoordinator.stop()` cancels its worker and awaits it |
| K6 | An unstructured task that deliberately escapes cancellation says why, with its source. | [TSPL, *Concurrency*](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/) | `DocumentFiler.file` |
| K7 | `Task.detached` is deliberate: it inherits no priority, task-local values or actor. | SE-0304 | `AppModel.startWatching` |
| K8 | **Nothing blocks a thread of the cooperative pool or the main actor**: no semaphore wait, no `Process.waitUntilExit()`, no synchronous read of a large file or a network volume, no hashing of a whole file inside an actor that others wait on. | [WWDC21, *Swift concurrency: Behind the scenes*](https://developer.apple.com/videos/play/wwdc2021/10254/); [`waitUntilExit()`](https://developer.apple.com/documentation/foundation/process/waituntilexit()) | `ShellRunner` drains pipes off the pool |
| K9 | A continuation resumes exactly once on every path, error and cancellation included. Prefer the checked kind. | [`CheckedContinuation`](https://developer.apple.com/documentation/swift/checkedcontinuation) | `OneShot` in `Deadline.swift` |
| K10 | `@unchecked Sendable` and `nonisolated(unsafe)` carry a comment naming the lock or queue that guards the state, and the claim holds. Prefer `Mutex<State>` or an actor. | [Migration guide, *Common Problems*](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/commonproblems/); [SE-0433](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0433-mutex.md); §3 | `OllamaConnection` uses `Mutex`, no opt-out |
| K11 | A lock guards a short synchronous section only: no `await`, no file or database access, no call into other code while it is held. | WWDC21, as K8 | |
| K12 | Process-wide mutable state (a `static` behind a lock, a shared singleton) is justified: it is shared by every test that runs in parallel and by every runtime in the process. | [SE-0412](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0412-strict-concurrency-for-global-variables.md) | |
| K13 | A task that loops over a stream that never ends holds what it captures for ever; it captures `self` weakly or is cancelled by its owner. | [`Task`](https://developer.apple.com/documentation/swift/task) | `AppModel.observe` |
| K14 | **Isolation is the same thing in every target.** The app's default isolation is the main actor; the package's is not, "the wrong default for many kinds of modules, including libraries". A file moved between them changes meaning. A flag that changes what code means (isolation, how imports are seen) is set for every target, in `Package.swift` and `project.yml`; one that only refuses more says which targets it holds for. | [SE-0466](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md) | `project.yml`, `Package.swift` |
| K15 | Where `NonisolatedNonsendingByDefault` is on, a nonisolated `async` function runs on its caller's actor, the main actor included; work that must leave it is `@concurrent`. Know which rule the target follows before judging where code runs. | [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md) | Not enabled today |

## Memory and performance

Measure before changing anything for speed: "measure your app's behavior to find the causes of the problems"
([Apple, *Improving your app's performance*](https://developer.apple.com/documentation/xcode/improving-your-app-s-performance)).

| # | Check | Source | In Arrumator |
|---|---|---|---|
| P1 | An image is never decoded at full size to be shown or analysed small: read its pixel dimensions first, refuse above a budget, and make a thumbnail with a maximum pixel size. | [`kCGImageSourceThumbnailMaxPixelSize`](https://developer.apple.com/documentation/imageio/kcgimagesourcethumbnailmaxpixelsize) | `ImageTools` makes thumbnails by a maximum pixel size |
| P2 | A loop over PDFKit, Vision or ImageIO objects drains an `autoreleasepool` per iteration. | [Apple, *Using Autorelease Pool Blocks*](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MemoryMgmt/Articles/mmAutoreleasePools.html) | |
| P3 | Work does not grow with the archive where it need not: no query per row, no scan of every document per History event, no whole text loaded where an identifier would do, no pair-by-pair comparison of all labels. | | `JobStore.nextDue` is one query |
| P4 | A closure stored by an object it captures breaks the cycle (`[weak self]`); `unowned` only where the object surely outlives the closure. | [TSPL, *Automatic Reference Counting*](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/automaticreferencecounting/) | |
| P5 | Prefer a struct; choose a class on purpose. Prefer `some` or a generic to `any` where one concrete type flows through. | [WWDC22, *Embrace Swift generics*](https://developer.apple.com/videos/play/wwdc2022/110352/) | Stores are structs |
| P6 | Text is cut by `Character`, never by byte or UTF-16 unit, and a byte cap that can land inside a multi-byte sequence is decoded tolerantly. | | `TextNormalizer.cap`, `PlainTextExtractor` |
| P7 | Fan-out is bounded: a task per page or per document for hundreds of items is queued, not started all at once. | [Migration guide, *Runtime Behavior*](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/runtimebehavior/) | One job at a time |

## SwiftUI and Observation

| # | Check | Source | In Arrumator |
|---|---|---|---|
| U1 | A view reads only what it shows: "SwiftUI updates a view only when an observable property changes and the view's body reads the property directly." A value that changes with every word of an answer is kept apart from what a whole page reads. | [Apple, *Migrating to the Observable macro*](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro) | `AppModel.conversation` and `answerSoFar` |
| U2 | `body` is cheap: no I/O, JSON decoding, Markdown parsing, sorting, similarity or formatter creation in it or in a computed property it calls; "it's important that body itself is as cheap as possible." | [WWDC23, *Demystify SwiftUI performance*](https://developer.apple.com/videos/play/wwdc2023/10160/) | |
| U3 | Identity is stable: no `ForEach` over indices or `\.offset`, no identifier made of a display string that can repeat, no `id: \.self` on values that are not unique. "Indices are not a stable form of identity." | [WWDC21, *Demystify SwiftUI*](https://developer.apple.com/videos/play/wwdc2021/10022/) | Rows are identified by document id |
| U4 | Loading is `.task(id:)`, which SwiftUI cancels when the view goes or the id changes, and the work tolerates that: a cancelled reload leaves what is shown, and never assigns a fallback. | [`task(id:priority:_:)`](https://developer.apple.com/documentation/swiftui/view/task(id:priority:_:)) | `IncomingPage`, `ProcessedPage` |
| U5 | `@State` is private and cheap to create; a model object the view owns is not rebuilt each time the parent redraws. State the user watches (a download, a draft) outlives the view that shows it. | [`State`](https://developer.apple.com/documentation/swiftui/state) | |
| U6 | An edit sends what the user did (add this label, remove that), not a whole value rebuilt from what the view last loaded. A handler on losing focus writes only when the value differs from Core's. | §4.6 | |
| U7 | A long list is lazy, and filtering happens in the model, not with `if` inside `ForEach`. | WWDC23, as U2 | |
| U8 | Text from the model or a document is shown verbatim. Where Markdown is rendered, links and images are removed or refused: an attributed string with a link is clickable in `Text`. | §4.5 | |
| U9 | No `AnyView`, no debugging aids (`_printChanges`) left in. | WWDC21, as U3 | |
| U10 | Layout values, colours and words come from `Style`, `Palette` and `Wording`; a limit or range of behaviour belongs in Core's validation, not in `Style`. | §4.7 | |

## AppKit and the app's life

| # | Check | Source | In Arrumator |
|---|---|---|---|
| L1 | Quitting has one path: `applicationShouldTerminate` answers `.terminateLater`, and `reply(toApplicationShouldTerminate:)` is called exactly once on every path, within a bound. No button stops the runtime itself before it terminates. | [`applicationShouldTerminate(_:)`](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:)); [`reply(toApplicationShouldTerminate:)`](https://developer.apple.com/documentation/appkit/nsapplication/reply(toapplicationshouldterminate:)); §3 | `AppDelegate`; quit gate |
| L2 | Nothing starts work in `applicationWillTerminate`: "the app will terminate after this method returns." | [`applicationWillTerminate(_:)`](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationwillterminate(_:)) | quit gate |
| L3 | A modal run loop (`runModal()`, `terminate(_:)`) is not entered from inside a `Task` on the main actor: while it runs, other main-actor work waits. | [`terminateLater`](https://developer.apple.com/documentation/appkit/nsapplication/terminatereply/terminatelater) | `FolderPicker` runs from the button's action |
| L4 | Work started outside the runtime's `start()` (a detached task, a download) is cancelled or awaited by stopping, switching archives and quitting. | K5 | |
| L5 | A failure to start shows the error with a way to retry, not another screen; a folder on a volume that is not mounted is a state the user is told about. | [HIG](https://developer.apple.com/design/human-interface-guidelines/) | |
| L6 | An agent app (`LSUIElement`) stays reachable when its status item is hidden by a full menu bar. | [`LSUIElement`](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement) | Dock icon by default |
| L7 | Every usage description in `Info.plist` matches what the code does, and denial is handled without a crash or a silent stop. | [`NSDocumentsFolderUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsdocumentsfolderusagedescription) | `project.yml` |

## Accessibility and wording

| # | Check | Source | In Arrumator |
|---|---|---|---|
| X1 | Every control has a name VoiceOver reads, which says what it does to what and does not name its own kind ("don't use the label 'Play button'"). `.help` is a hint, not the name. | [HIG, *VoiceOver*](https://developer.apple.com/design/human-interface-guidelines/voiceover); §4.7 | "Remove “EDP”" on label chips |
| X2 | Everything can be done from the keyboard: "let people use the keyboard alone to navigate and interact with your app." A double-click, a hover-only control or a drag has a keyboard and VoiceOver equivalent. With Full Keyboard Access off, Tab reaches text fields and lists and a menu command or shortcut reaches the rest; with it on, Tab reaches every control. | [HIG, *Accessibility*](https://developer.apple.com/design/human-interface-guidelines/accessibility) | `rowAction` in `App/Views/Page.swift` |
| X3 | Nothing is said by colour alone, and text meets a contrast of 4.5 to 1 (3 to 1 when large or bold) in the light and the dark appearance. | HIG, *Accessibility* | `Palette` |
| X4 | Animation respects Reduce Motion. | [`accessibilityReduceMotion`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion) | |
| X5 | Focus moves into what was just opened, and a new error is announced. | HIG, *VoiceOver* | |
| X6 | Fonts are semantic styles, and a layout survives larger text. | [HIG, *Typography*](https://developer.apple.com/design/human-interface-guidelines/typography) | |
| X7 | Dates, numbers and amounts shown to the user go through a format style, never string interpolation; plurals and sentences are not assembled in code from fragments. | [Apple, *Supporting multiple languages*](https://developer.apple.com/documentation/xcode/supporting-multiple-languages-in-your-app) | `Format` in Core, `Wording` |
| X8 | A count appears only where the interface rules allow one (§4.7). | §4.7 | |
| X9 | A control moved into or out of a `List` changes where the cursor is when the window opens and what Tab reaches: a text field in a row of a list is outside the window's key view loop, and needs a keyboard path of its own, such as a focus state set by a menu command. | [`FocusState`](https://developer.apple.com/documentation/swiftui/focusstate) | |

## Files, processes and untrusted input

The app is not sandboxed, so its own code is the only containment: a flaw in how a file is parsed has the user's whole
file access.

| # | Check | Source | In Arrumator |
|---|---|---|---|
| F1 | Do the operation and handle the error; do not check, then act. "Because there is a time gap between the check and the use … an attacker can sometimes use that gap." | [Apple, *Race Conditions and Secure File Operations*](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/RaceConditions.html) | `moveItem` refuses an existing destination |
| F2 | Two paths are the same file by identity (resource identifier, or inode and volume), not by spelling: case, composed or decomposed, and links differ. | | `canonicalFolderPath` |
| F3 | A write that replaces a file is atomic, and a file that exists but could not be read is not overwritten as though it were absent. | [`Data.WritingOptions.atomic`](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/atomic) | Record files are written atomically |
| F4 | A multi-step file operation says what a failure after each step leaves, and cleans up or records it: a copy is not left behind for a retry to duplicate, a temporary file is removed on every path. | [Luu, *Files are hard*](https://danluu.com/file-consistency/) | `DocumentFiler.place` |
| F5 | A file the app has no more use for goes to the Trash through `Trashing`; nothing calls `removeItem` on a user's file. | [`trashItem(at:resultingItemURL:)`](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:)); §4.2 | `FolderTrash`, `SystemTrash` |
| F6 | A child process runs by absolute path with an argument array, never through a shell; a file name is passed as an absolute path so it cannot be read as an option; it has a timeout that kills it, a cap on its output, both pipes drained while it runs, and is killed on cancellation. | [Apple, *Security Development Checklists*](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/SecurityDevelopmentChecklists/SecurityDevelopmentChecklists.html) | `ShellRunner` |
| F7 | A child process or a framework is not assumed to stay off the network: an HTML importer, a web archive or a preview generator may load remote content. Its flags are set, and a test pins them. | §4.1 | |
| F8 | A parser of untrusted data is bounded before it decodes: a container by bytes per entry and in total, by entries and by depth; an image by pixels; a PDF by pages; any of them by time. A library is given only data already checked. | [ASVS 5.0, V5](https://github.com/OWASP/ASVS/blob/v5.0.0/5.0/en/0x14-V5-File-Handling.md) | `ZipReader.data` checks the declared and the read size |
| F9 | XML parsing does not resolve external entities. | CWE-611 | `XMLTextCollector` |
| F10 | A regular expression is linear on hostile input: no lazy or greedy scan to the end that restarts at every position when the closing token is missing. A pattern on constant input is built once; one that fails to compile is a broken invariant, not a `try?`. | CWE-1333 | |
| F11 | FSEvents are hints: a flag that asks for a rescan is honoured, an event's path is confirmed against the disk, and a file is used only when it has stopped changing. | [Apple, *Using the File System Events API*](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html) | `IncomingWatcher` |
| F12 | A package (a folder macOS shows as one document) is treated as one thing on every path that sees it, events and scans alike. | | |
| F13 | Dates use an explicit Gregorian calendar and a chosen time zone, never `Calendar.current` for a value that is stored. | | |
| F14 | `Any` from ImageIO, PDFKit, Spotlight or a property list becomes a typed value in the function that obtained it. | §3 | |

## The network and the platform's protections

| # | Check | Source | In Arrumator |
|---|---|---|---|
| N1 | There is one `URLSession`, with the guard first among its protocol classes and no cache. A change to its configuration accounts for the system's proxies and for redirects. | §4.1 | `NetworkGuardProtocol.guardedConfiguration` |
| N2 | A host is validated without resolving it, in the form it will be compared in, and without user info, query or fragment. | | `OllamaEndpoint` parses with `inet_pton` |
| N3 | Every request has a deadline for its whole duration, and cancelling the task cancels the request. A response is bounded in size. | | `Deadline.run` |
| N4 | A streamed response is framed on the line feed only and survives a chunk boundary inside a line or a character. | | |
| N5 | A log message keeps its text constant and public and its values private; nothing a document says is logged at any level. Dynamic strings are redacted by default only in the unified log, not in the app's own log files. | [Apple, *Generating log messages from your code*](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code); §4.1 | `Log.log` |
| N6 | Plain HTTP is allowed for the local network only, by `NSAllowsLocalNetworking`, never by allowing arbitrary loads. | [`NSAllowsLocalNetworking`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking) | |
| N7 | Reaching a server on the local network needs `NSLocalNetworkUsageDescription`, and the prompt's denial is a state the user is told about. | [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) | `project.yml` |
| N8 | The hardened runtime stays on with no exception entitlement that lacks a written reason. | [Apple, *Hardened Runtime*](https://developer.apple.com/documentation/security/hardened-runtime) | No entitlements file |
| N9 | A release that is signed is notarized and stapled, carries a secure timestamp and no `get-task-allow`; a release that is not signed says so. Signing never fails open without notice. | [Apple, *Notarizing macOS software*](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) | `scripts/release.sh` |
| N10 | No secret is stored in a file, a setting or the repository. | [Apple, *Using the keychain*](https://developer.apple.com/documentation/security/using-the-keychain-to-manage-user-secrets) | `scripts/check-secrets.sh` |

## SQLite and GRDB

| # | Check | Source | In Arrumator |
|---|---|---|---|
| G1 | One logical change is one `write`: the row, its History event and what depends on it commit together. "You are responsible, in your Swift code, for delimiting transactions." | [GRDB, *Concurrency*](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Concurrency.md) | `DocumentFiler.place`; `HistoryStore.insert(db, …)` |
| G2 | A value fetched in one access is stale in the next: "whenever you extract some data from a database access, immediately consider it as stale." A decision is re-read inside the write that acts on it, and a row is not saved whole from an old copy. | GRDB, *Concurrency* | `SearchTaskStore.prepare` checks state in the write |
| G3 | A queue item is taken by a write that claims it, so two workers or two processes cannot both take it. | [SQLite, *Transactions*](https://www.sqlite.org/lang_transaction.html) | |
| G4 | SQL takes its values as arguments. Interpolation is for constants: enum raw values, generated placeholders. "Never embed raw values in your SQL queries." | [GRDB, README](https://github.com/groue/GRDB.swift/blob/master/README.md) | The stores |
| G5 | A schema change is a new migration, written with table and column names as strings, not today's types: "migrations should not depend on application types." Identifiers of shipped migrations are kept. Rewriting an earlier migration is allowed only as [§4.2](../../AGENTS.md#4-hard-rules-non-negotiable) says. | [GRDB, *Migrations*](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Migrations.md) | `MigrationTests` |
| G6 | A migration that changes a recorded table keeps its triggers, the partial index on active jobs and the full-text columns in step. | [Storage](../storage.md) | |
| G7 | Each query has an index it can use: the child column of a foreign key, the columns of a filter and an order. A filter on an expression (`strftime`, `json_extract`, `rtrim`) cannot use one. | [SQLite, *Query Planning*](https://www.sqlite.org/queryplanner.html) | |
| G8 | Many writes are batched in one transaction, and no read transaction is held long: in WAL mode a long reader keeps the log from being checkpointed. | [SQLite, *Write-Ahead Logging*](https://www.sqlite.org/wal.html) | |
| G9 | Async accesses throw `CancellationError` on a cancelled task and roll back. What follows a stop does not write, and the error is not logged as a database failure. | GRDB, *Concurrency* | `IngestCoordinator.process` |
| G10 | An observation may coalesce changes, sees only this process's writes, and ends on an error: a consumer does not count notifications, and resubscribes or says so. | [GRDB, `ValueObservation`](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Extension/ValueObservation.md) | `AppDatabase.activity()` |
| G11 | A PRAGMA carries its reason; a misspelt one is silently ignored. | [SQLite, *PRAGMA*](https://www.sqlite.org/pragma.html) | |
| G12 | A stored JSON column that fails to decode is an error with the row named, not an empty value that is then written back. | §4.2 | |

## Tests

The rules of [AGENTS.md §3](../../AGENTS.md#3-core-principles) apply; these are the Swift Testing points behind them.

| # | Check | Source | In Arrumator |
|---|---|---|---|
| ST1 | Tests run in parallel and in random order, so nothing is shared: no fixed path or port, no process-wide static, no singleton pointed at a folder that another test deletes. | [Swift Testing, *Parallelization*](https://github.com/swiftlang/swift-testing/blob/main/Sources/Testing/Testing.docc/Parallelization.md) | `TestEnvironment` makes a root per test |
| ST2 | `#require` unwraps and guards what the test needs to go on; `#expect` checks. Neither is reached through `?? 0` or `?? []`, which makes a missing value pass. | [Swift Testing, *Expectations*](https://github.com/swiftlang/swift-testing/blob/main/Sources/Testing/Testing.docc/Expectations.md) | |
| ST3 | `#expect(throws:)` names the error's case, not only its type, where the reasons differ. | Swift Testing, *Expectations* | |
| ST4 | An asynchronous event is awaited with a deadline (`Patience.until`) or a `confirmation`, never a sleep or a counted number of yields; a test that can hang has a `.timeLimit`. | [WWDC24, *Go further with Swift Testing*](https://developer.apple.com/videos/play/wwdc2024/10195/) | `Patience`; `scripts/lint.sh`, test-sleeps gate |
| ST5 | Time is injected. A test of waiting uses a clock on which a sleep does not end by itself (`TestTime` with `.blocks`), since one on which every wait elapses at once (`.advances`) cannot show that a wait or a wake-up is missing. | [SE-0329](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0329-clock-instant-duration.md); §3 | `TestTime` |
| ST6 | Cases that differ only in data are `@Test(arguments:)`, so each failing case has a name. | [Swift Testing, *Parameterized testing*](https://github.com/swiftlang/swift-testing/blob/main/Sources/Testing/Testing.docc/ParameterizedTesting.md) | |
| ST7 | A test that needs what a machine may lack says so and is skipped with the reason; the probe does not use the code under test. | §3 | `VisionOCR` in the Extract tests |
| ST8 | An expectation does not depend on the Mac: the time zone, the locale, whether the volume tells case apart, where the temporary folder is, the Mac's temperature. | §3, determinism | |
| ST9 | A double is an actor or guarded by a `Mutex`, records what it was asked, and can fail, stall and stream as the real thing does. | [*Software Engineering at Google*, ch. 13](https://abseil.io/resources/swe-book/html/ch13.html) | `MockOllama` |
| ST10 | Every temporary folder is removed, also when set-up throws and while a background task still runs. | | `env.cleanup()` in `defer` |

## The package and the build

| # | Check | Source | In Arrumator |
|---|---|---|---|
| B1 | A target imports only modules it declares. An import of a module that arrives through another target compiles, so the `import` lines are read. | [Architecture](../architecture.md#what-keeps-it-in-shape) | [§5](../../AGENTS.md#5-boundaries) |
| B2 | Language mode, upcoming features and default isolation are set for every target, as K14 asks of `Package.swift` and `project.yml`. | [SwiftPM, `SwiftSetting`](https://developer.apple.com/documentation/packagedescription/swiftsetting) | `ExistentialAny` in the package |
| B3 | A change to `Package.resolved` is a dependency upgrade and is reviewed as one: what changed upstream, and can it reach the network (§4.1)? | [SwiftPM, *Resolving package versions*](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/ResolvingPackageVersions.md) | Dependabot waits a week |
| B4 | A new dependency is needed, maintained, licensed compatibly, unable to reach the network (§4.1), without build plugins or binary targets, and its notice ships with the release. | [Cox, *Our Software Dependency Problem*](https://research.swtch.com/deps) | Four direct dependencies |
| B5 | Resources are reached through `Bundle.module`, and a default or a prompt is a resource, not a literal. | [Apple, *Bundling resources with a Swift package*](https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package) | `Defaults/`, `Prompts/` |
| B6 | `project.yml` is the source of the project and of `Info.plist`; a generated file is not edited by hand. | [XcodeGen, *Project Spec*](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md) | `project.yml` |
| B7 | The change adds no compiler warning, and silences none in place: Arrumator's own targets treat every warning as an error. | §3 | `Package.swift`, `project.yml` |
| B8 | A SwiftLint rule is disabled in place, with its reason, and a threshold is raised only by a change that says why. | `.swiftlint.yml` | |

## What the tools decide, and what a person must

| Decided by a tool | Left to the reviewer |
|---|---|
| Formatting and the enabled SwiftLint rules, force unwraps among them. | Whether a name is clear where it is used. |
| Data races, by the compiler in Swift 6 mode. | Reentrancy across an `await`; whether an `@unchecked Sendable` claim is true. |
| Unused declarations, by Periphery. | Whether a continuation resumes once on every path; who owns a task. |
| `fatalError`, `try!` and the other gates of `scripts/lint.sh`. | Traps reached through arithmetic, ranges and library calls on data from outside. |
| That tests pass. | That a test fails without its code, and waits for the right thing. |
| That named commands, options and keys exist. | That each sentence about behaviour is true. |
| | Transaction boundaries and stale reads; what a crash leaves on disk. |
| | Blocking calls behind synchronous APIs; cancellation honoured and not swallowed. |
| | What a child process or a framework does on the network; what reaches a log. |
| | Identity and dependency scope in SwiftUI; names VoiceOver reads; the keyboard path. |

## Sources

Swift:

- Swift.org, [API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- Swift.org, [Migrating to Swift 6](https://www.swift.org/migration/documentation/migrationguide/): data-race safety,
  common problems, runtime behaviour.
- [The Swift Programming Language](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/):
  Concurrency, Error Handling, The Basics, Advanced Operators, Automatic Reference Counting.
- Swift Evolution: [SE-0304](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md)
  structured concurrency, [SE-0306](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md)
  actors, [SE-0314](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0314-async-stream.md)
  `AsyncStream`, [SE-0413](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md) typed
  throws, [SE-0433](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0433-mutex.md) `Mutex`,
  [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md) and
  [SE-0466](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md),
  the isolation defaults of Swift 6.2.
- Swift Testing, [documentation](https://github.com/swiftlang/swift-testing/tree/main/Sources/Testing/Testing.docc).

Apple:

- WWDC: [Swift concurrency: Behind the scenes](https://developer.apple.com/videos/play/wwdc2021/10254/) (2021),
  [Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/) (2021),
  [Demystify SwiftUI](https://developer.apple.com/videos/play/wwdc2021/10022/) (2021),
  [Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/) (2023),
  [Go further with Swift Testing](https://developer.apple.com/videos/play/wwdc2024/10195/) (2024),
  [Embracing Swift concurrency](https://developer.apple.com/videos/play/wwdc2025/268/) (2025).
- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/): Accessibility,
  VoiceOver, Typography.
- Secure Coding Guide: [Race Conditions and Secure File
  Operations](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/RaceConditions.html),
  [Security Development
  Checklists](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/SecurityDevelopmentChecklists/SecurityDevelopmentChecklists.html).
- Security: [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime),
  [Notarizing macOS software before
  distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
  [TN3179: Understanding local network
  privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

Storage:

- GRDB: [Concurrency](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Concurrency.md),
  [Migrations](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Migrations.md),
  [`ValueObservation`](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Extension/ValueObservation.md).
- SQLite: [Write-Ahead Logging](https://www.sqlite.org/wal.html), [Query Planning](https://www.sqlite.org/queryplanner.html),
  [PRAGMA statements](https://www.sqlite.org/pragma.html).

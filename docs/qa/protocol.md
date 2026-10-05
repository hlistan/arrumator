# QA protocol: the app as a user meets it

How a person, or an agent, tests Arrumator end to end: the real app, built from the branch under test, in a scratch
archive, driven through its window as a user drives it, with a real model. It finds what unit, integration and CLI tests
cannot: what a page shows and says, what a user can and cannot do from it, how it behaves when things go wrong, and
whether the model's work holds up. What a run finds goes into `docs/qa/reports/<date>/`, which Git ignores: a report is
the input of the changes that fix what it found, not part of the repository.

## Method

The run is **session-based exploratory testing**: time-boxed sessions, each with a charter saying what to explore, how,
and for which risks, and a session sheet recording what was done, what was found and how much of the time went to the
charter rather than to setting up or chasing bugs ([Bach, *Session-Based Test Management*,
2000](https://www.satisfice.com/download/session-based-test-management);
[Wikipedia: session-based testing](https://en.wikipedia.org/wiki/Session-based_testing)). A charter reads "Explore
*area* with *approach* to find *risks*". Scripted steps alone confirm what was expected; a charter leaves the tester
free to follow what the app does, while the charters together cover every use case below.

Each session looks at its area through the product elements of the **Heuristic Test Strategy Model**, SFDIPOT
([Bach, *Heuristic Test Strategy Model*](https://www.satisfice.com/download/heuristic-test-strategy-model)):

| Element | What to try in Arrumator |
|---|---|
| Structure | The archive's files and record files (`_documents.md`, `System/`), the index, the app bundle. |
| Function | Every action of the page: what it does, what it says it did, what History records. |
| Data | Documents of every kind the corpus has: languages and scripts, scans, images, mail, Office files, encrypted, blank, damaged, exact copies; empty, long, odd and non-Latin text in every field. |
| Interfaces | The window, the menu bar, the Dock, Finder, notifications, `arrumatorcli`, the record files by hand, Ollama's HTTP API. |
| Platform | macOS version, light and dark appearance, window sizes down to the minimum, a full menu bar, Ollama on this Mac or on the network. |
| Operations | First run, daily filing, a large batch, correcting labels, finding and exporting, talking with documents. |
| Time | Work in progress, a stop and a restart part way, Ollama going away and coming back, clocks, long answers, timeouts. |

and judges what it sees by consistency oracles, **HICCUPPS**: consistent with its History, its image, comparable
products, the claims of `README.md` and `docs/`, the user's expectations, the product itself (one page against another,
the app against `arrumatorcli`), its purpose, and the law, here above all that no document leaves the machines the user
runs (AGENTS.md §4.1). A difference between the app and its documentation is a finding either way.

**Usability** is judged against Nielsen's ten heuristics, cited by number in each finding: 1 visibility of system
status, 2 match with the real world, 3 user control and freedom, 4 consistency and standards, 5 error prevention, 6
recognition rather than recall, 7 flexibility and efficiency, 8 aesthetic and minimalist design, 9 help with
recognizing, diagnosing and recovering from errors, 10 help and documentation ([Nielsen Norman Group: 10 usability
heuristics](https://www.nngroup.com/articles/ten-usability-heuristics/)); and against Apple's Human Interface Guidelines
for macOS ([HIG](https://developer.apple.com/design/human-interface-guidelines/)) and the app's own rules, AGENTS.md
§4.7.

**Accessibility** is checked through the same accessibility tree the run drives the app by: every control has a label a
VoiceOver user hears, every action can be reached by keyboard, nothing is conveyed by colour alone, and text stays
readable in both appearances. Apple's Accessibility Inspector audit, or `performAccessibilityAudit()` in a UI test, runs
the same checks ([WWDC23: Perform accessibility audits for your
app](https://developer.apple.com/videos/play/wwdc2023/10035/)).

**Answers from the model** (labels, names, search plans, conversations) are judged against the documents, as answers of
retrieval-augmented generation are: each claim of an answer must be supported by a document it was shown (groundedness),
each document it cites must support what it says (citation faithfulness), and it must answer what was asked
(completeness) ([Evidently: RAG evaluation](https://www.evidentlyai.com/llm-guide/rag-evaluation); Gao et al., ALCE,
in [sources](../organizing-principles-sources.md#sources-for-conversations)). The synthetic corpus's `expected.json`
says what each fixture's labels are; `arrumatorcli eval` measures that at scale, so a run samples it by hand. Neither
says what shape the labels of the other kinds take, so a run also reads the whole vocabulary, `arrumatorcli labels list
--kind <kind>` for every kind, against the form [how it works](../how-it-works.md#labels) gives each: a value that
copies the prompt's wording as a template ("an account and its number: …"), holds two labels in one (`;`), puts a
description before a number where none belongs, or holds what is no label of its kind (a birth date as an object, a
percentage as an amount, a tax number as a party) is a finding however few fixtures show it, as every reading adds to
the vocabulary that the sidebar, Look Alike, search and the next prompt read.

## Severity

One scale for every finding, Nielsen's severity ratings
([NN/g: severity ratings](https://www.nngroup.com/articles/how-to-rate-the-severity-of-usability-problems/)) extended to
defects:

| Severity | Meaning | Examples |
|---|---|---|
| 4 Blocker | Loses or exposes data, crashes, breaks a rule of AGENTS.md §4, or stops a use case with no way around it. | A document deleted or misfiled, text sent beyond the local network, the app stuck. |
| 3 Major | A use case fails or misleads, with a way around it a user is unlikely to find. | A wrong state shown as done, an action that silently does nothing. |
| 2 Minor | A use case works with friction: unclear wording, a missing state, an extra step. | A spinner without saying what it waits for. |
| 1 Cosmetic | Polish: alignment, truncation, inconsistency in wording or spacing. | Icons out of line. |

Frequency (every time, sometimes, once), impact and whether the user can recover raise or lower it. A single evaluator's
ratings are a starting point; the person fixing a finding may rate it again.

## Environment

AGENTS.md §4.3 holds for every step: the run never touches the real archive, Incoming, `~/Library/Application
Support/Arrumator` or a running Arrumator of the user's.

1. Build the branch under test: `scripts/verify.sh --app`, which builds the release as a release is built and leaves
   `Arrumator.app` in `build/DerivedData/Build/Products/Release`, and the command built with it in
   `build/Release/stage/arrumatorcli-<version>/arrumatorcli`. Use that command for the run: `.build/debug/arrumatorcli`
   is relinked only when `swift build` finds a change, so it can be older than the app.
2. Make a scratch home with scratch folders, and settings naming them, before anything runs:

   ```sh
   RUN=$(mktemp -d)/run; mkdir -p "$RUN/home" "$RUN/Incoming" "$RUN/Archive"
   printf '{"incomingPath": "%s", "archivePath": "%s", "ollamaManagement": "external"}\n' \
     "$RUN/Incoming" "$RUN/Archive" > "$RUN/home/settings.json"
   ```

   Leaving out `onboardingCompleted` runs onboarding first, with the scratch folders already chosen.
3. Name the Ollama server on the command, never in the repository: one on this Mac, or one the user lends on the local
   network (`ARRUMATOR_OLLAMA_URL`). Note its version and which of the profiles' models it has (`/api/tags`); a model is
   never pulled for a run without asking.
4. Launch only this copy, and remember its process:

   ```sh
   ARRUMATOR_HOME="$RUN/home" ARRUMATOR_TRASH="$RUN/Trash" ARRUMATOR_OLLAMA_URL=http://<server>:11434 \
     build/DerivedData/Build/Products/Release/Arrumator.app/Contents/MacOS/Arrumator > "$RUN/app.log" 2>&1 &
   echo $! > "$RUN/pid"
   ```

   On a Mac in dark appearance, see the light one by quitting it and launching it again with
   `-NSRequiresAquaSystemAppearance YES` after its path, which keeps that copy light. Never change the Mac's appearance
   for a run: it is the user's setting and changes every app they have open. A Mac in light appearance has no such
   switch for dark, so the report says that appearance was not seen.

5. Drive it with `scripts/qa-drive.sh`, which goes through the macOS accessibility API to that process alone: it reads
   the window's elements (`tree`, `find`), presses buttons and menu items (`press`), clicks and double-clicks rows
   (`click`, `dclick`), types into fields (`set`, `type`), sends keys (`key return`, `key escape`, `key f cmd`), scrolls
   (`scroll`), screenshots its window and no other (`shot`), performs accessibility actions (`actions`, `action`), and
   reaches what lies outside the window (`reopen`, `statusitem`, `frontmost`, `notification`, `panelgo`, `cancelpanel`:
   [how](#how-to-reach-what-is-hard-to-reach)). The terminal it
   runs in needs Accessibility in System Settings › Privacy & Security. It never reads the system's Apple menu, which
   lists the user's own recent files.
   Its pointer events reach whatever window is under the pointer, so it refuses a click, hover or scroll at a point
   where one of the process's windows is not the frontmost, and it refuses `shot` while a file panel is open. The
   screen must be unlocked: while it is locked, the accessibility API gives every window, any app's, as the application
   itself, `windows` lists none and `shot` makes no image, so wait for the user rather than read anything into it.
   A file panel (Choose…, Export, Switch Archive…) may open on the user's own folders, and the driver never reads it,
   as its elements list the user's files. It runs in a service of its own, which keys posted to the app's process never
   reach, so `key` cannot type into it and Escape does nothing there. Never confirm a panel blind: drive it with
   `panelgo` only when it opened on a scratch folder, otherwise close it with `cancelpanel`, which presses its Cancel
   and reads nothing else of it, and do the same through `arrumatorcli` (`tasks export`, `archive switch`, `settings
   --incoming`).

   How the driver meets the app: `press` performs an element's own action, so it moves nothing on a text that has none,
   such as a sidebar list's name; `click` it instead, and read afterwards that the page changed. An element below the
   window's edge, such as a card's field on a long page, is refused as not on its window: `scroll` over something near it
   first. The window's close button is a button without a name (subrole `AXCloseButton`): `clickat` its centre from the
   `tree`. The Dock cannot be driven; the app's menus can, by an item's identifier, such as `press <pid> showMain
   AXMenuItem` for Window › Arrumator (⌘0) and `showOnboarding` for Window › Setup…. A command that prints nothing, or
   less than the page holds, has failed: check its exit status (`tree` piped into `grep` hides it) before reading
   anything into the page.

   The app moves an exact copy of a document, and a file it has no more use for, to the Trash: `ARRUMATOR_TRASH` makes
   that a scratch folder, so set it for the app and for every command of the run, and check afterwards that what went
   there is in `$RUN/Trash`.
6. The corpus is `Tests/Fixtures`: synthetic documents in Portuguese, Russian, English and other languages and scripts,
   scans, photos, mail and Office files, and the negative cases (encrypted, blank, damaged, an exact copy, a
   spreadsheet). Put a part of it in a folder of its own inside Incoming to see folder tags. Never use real documents.
7. Use `arrumatorcli` in the same scratch home (`ARRUMATOR_HOME`, `ARRUMATOR_TRASH`, `ARRUMATOR_OLLAMA_URL`) to check
   what the app shows against what Core says, and the record files and `app.log` to check what it wrote. Pipe its
   `--json` straight into what decodes it (`… --json | python3 -m json.tool`): zsh's `echo "$out"` turns the `\n` in its
   strings into line breaks, which reads as JSON the command never wrote.

At the end, quit the app the way a user does, then check the scratch archive's files once more. Stop nothing else.

## Charters

Each charter is one session or more. The use cases come from `README.md` and `docs/using-arrumator.md`; the edge cases
are those each area is most likely to get wrong. **A run covers everything**: every charter, every use case and every
edge case in it, in the app as a user meets it. VoiceOver itself, the screen reader speaking, is the one exception; the
accessibility tree VoiceOver reads is not, and is checked throughout (Method › Accessibility). Nothing is left out because
it is slow, far down a long page, behind a file panel or outside the window: [How to reach what is hard to
reach](#how-to-reach-what-is-hard-to-reach) says how to get to each. What only the user can allow (a system setting of
theirs, room in their menu bar, a model download, notifications for the build) is asked for at the start of the run, all
at once. What the run still could not reach is a gap in this protocol: the report names it, says why, and the run's
change to this protocol says how the next run reaches it.

| # | Charter: explore… | Use cases | Edge cases and risks |
|---|---|---|---|
| C1 | First run and onboarding, step by step, forward and back | Welcome, folders, background and notifications, Ollama and its server, profile and models, Ready | Ollama unreachable or slow, a server off the local network refused, models missing and their Download, the menu bar full, keyboard only (Return, Escape, Tab), closing the window part way and opening the main window from the Window menu (⌘0) before setup is done: what it says and whether a file dropped then is taken |
| C2 | Filing documents through Incoming and the queue | Drop files and folders, watch In Progress and Queued, a document filed and named | Every format of the corpus, non-Latin names, a folder in Incoming as a tag, nested folders, an exact copy, encrypted, blank, damaged and unsupported files, a large batch, pausing and resuming, quitting part way and starting again, and the queue's order after the restart |
| C3 | Processed and a document's card | Open a card, rename, add and remove labels, read again, undo filing, open the file and show it in Finder | Empty and very long names, names with `/` or `:`, a label of every kind, removing every label, undo twice, a file moved, copied, or removed and put back in Finder meanwhile, a folder renamed in the archive, a package put into it, every action of the card pressed twice (what the card and History say the second time) |
| C4 | Needs You | Confirm, read again, leave for later, undo | Each reason a document waits, a document read again that still fails, counts on the sidebar |
| C5 | The sidebar's labels | Choose labels to narrow down, Clear, Filter Labels, group by kind, fold a kind, Show More, all of it with the keyboard alone (Tab from Filter Labels, the arrows, Return, Escape) and VoiceOver | Labels in many scripts, filters that match nothing, accents and punctuation, choosing every label, a narrowed page with no documents, narrowing that replaces most labels while documents are filed (`app.log` holds no AppKit warning) |
| C6 | The Labels page | Merge, keep apart, remove everywhere, forget a rule, suggestions of alike labels | Merging a label into itself, into one of another kind, a tag, undoing a rule, what a later reading does |
| C7 | Search tasks | Ask in several languages, watch the queue, open the card, rename, rewrite, Find Again, effort and profile, arrangement, add documents through the sidebar, take out, export to a folder and as ZIP, remove | A request that finds nothing, and whether the archive holds what it asked for (`labels browse`); a request that says how to arrange ("by sender"), whose plan must not limit by it; an empty or very long request, a profile removed meanwhile, a profile whose model is not installed, an export into the archive or Incoming refused, exporting twice, a task read while another is |
| C8 | Talking with a task's documents | Ask, watch the answer being written, sources, find more and add, Copy, Ask Again, Stop, Clear | Translation, an e-mail draft, a question about nothing in the set, a question in another language, a set changed between questions, a very long answer cut off, Ollama away, an empty set, a task still being read, the groundedness of every answer, and its completeness: a question about "these" documents counts every one of the set, and an answer that only announces what follows (a heading, "Here are…") is no answer; a set mostly in other scripts, whose prompt the estimate fits too large (the trace's "context was full") |
| C9 | Settings and model profiles | General, Models, profiles: choose, add, rename, change models, reset, remove; Advanced: rebuild the index, diagnostics | A profile in use or named by a task removed, a blank name, a name taken, a model not installed, a server address that is not local |
| C10 | History, Statistics and traces | Read every event, open the document or task it is about, the funnel, a trace of a document and of a task | Events of every kind, long summaries, a trace of a failed reading |
| C11 | The app around its window | Menu bar, Dock, windows, notifications, quitting while working | The menu bar full, reopening a closed window, two windows, quitting during a reading and during an answer |
| C12 | Resilience | Ollama going away and back, a record file edited by hand, switching archives, a restart | Stopping in the middle of every queue, a record file broken by hand while documents are filed (the window, History, `doctor`, and what it holds once mended), an archive moved, the clock, a slow server (a probe that times out while it reads) |
| C13 | The app against `arrumatorcli` | Each action of C2–C9 done in one and read in the other | The `--json` of every command decoded, a change made by the CLI while the app runs |
| C14 | Accessibility and keyboard | Every page by keyboard and through the accessibility tree | Controls without labels, images without descriptions, colour as the only sign, focus lost after an action, both appearances (Environment, step 4), the smallest window, a help that repeats itself |

### How to reach what is hard to reach

| What | How |
|---|---|
| The Dock icon | `qa-drive reopen` sends the reopen event a click on the Dock icon sends, to this process alone (another copy of the app may share the name in the Dock). |
| The menu bar item | `qa-drive statusitem` presses the app's own item, also when a full menu bar hides it; what then opens, or nothing, is what a keyboard user gets. Whether the item can be seen is not what the app says of it, nor where accessibility puts it: macOS puts an item in the screen's corner before its place, and behind the camera housing when the bar is full. See it with `screencapture -x -R<x>,<y>,<w>,<h>` on the item's frame from `qa-drive statusitem` alone, never more of the menu bar. Where its popover opens is the frame of the process's window at layer 25 in `CGWindowListCopyWindowInfo`, filtered by the run's PID, right under the bar or not; `screencapture -l<window number>` shows that window alone. Its popover as a pointer user sees it needs room in the menu bar: ask the user to make some. |
| A file panel (Export, Switch Archive…, Choose…) | When it opens on a scratch folder (an export beside the archive, Switch Archive… on the archive, Choose… on the folder's own path), `qa-drive panelgo <folder>` types the path into it and presses Open, while the panel is frontmost; it refuses a folder outside a temporary place (`/private/tmp`, `/private/var/folders`), where every scratch folder is made, and presses Open only when the panel's location pop-up then shows that folder's name, cancelling it otherwise; check the result on disk. One that opens anywhere else is never driven: `cancelpanel`, the same through `arrumatorcli`, and the panel's starting place is a finding. `qa-drive panelplace` names the folder a panel shows, read from its location pop-up alone, to check where it opened. |
| Open, Show in Finder | Press it, then `qa-drive frontmost`; read the other app only by the names of its windows (CGWindowList), and Finder's front window and selection with `osascript`, for that window alone. Never script another app: a consent prompt or a timeout follows. Close afterwards only what the run opened (an app launched by the run holding only the run's file, a Finder window on a scratch folder). |
| Notifications | Turn the setting on, file a file named with a token of the run's own (letters and digits, 8 or more, such as `qanotify7731`), and look for it with `qa-drive notification <pid> <token>`, which refuses anything less and prints only an alert holding the token. No alert is not yet a finding: a Focus, such as Do Not Disturb, keeps the banner from the screen and puts it straight into Notification Center. Tell the two apart from what macOS logged of the build's request, `event-<id>` of the filing, with `/usr/bin/log show --last 5m --predicate 'process == "usernoted" OR process == "NotificationCenter"'` (zsh's own `log` is another command): "Presenting" and "muted by DND suppression" is a notification the app posted, which the Focus held; no request is the app's. The Focus is the user's setting: never turn it off, ask. When macOS has never let the build notify (its bundle id is not among the apps in Notification settings), ask the user to allow it for the run, or use a build signed for distribution. |
| An action shown only under the pointer | `qa-drive actions` lists an element's accessibility actions and `action` performs one by name ("Remove from This Document", "Take Out of Task"), as VoiceOver's actions menu does; a missing one is a finding (AGENTS.md §4.7). |
| Keyboard navigation (Tab to rows and buttons) | It follows the system setting only: no launch flag turns it on for one process. Ask the user to turn on Keyboard navigation (System Settings › Keyboard) for the keyboard session, and back off after. |
| A long page | `press` acts on an element wherever it is; `click` and `set` need it on screen: `scroll` over an element of that page (never one of the sidebar's), a little at a time, and `tree` again. |
| Ollama away, slow or off the network | Restart with `ARRUMATOR_OLLAMA_URL=http://127.0.0.1:9` (nothing listens there) for away; watch for probes that time out while a large model reads, for slow; type an address beyond the network into Settings or onboarding with the variable unset. Never stop the user's server. |
| The archive away | `mv` the scratch archive aside while the app runs, look, `mv` it back. |
| The clock | Launch with `TZ=<zone>` far from the Mac's (`Pacific/Kiritimati`, UTC+14) to cross midnight; the CLI with the same `TZ` to compare. |
| A limit (an answer cut off, a page size) | An override for the run, `ARRUMATOR_PIPELINE_CONFIG=$RUN/pipeline-qa.json`, with the one key lowered; a model that answers within it anyway leaves the path unreached: say so. |
| Work queued by the CLI | The app takes up what another process queues as soon as that process commits it (a change signal between processes): queue with `--queue-only`, and check the app starts on it within seconds, without a restart. |
| Download of a model | Pulling one is never done without the user: ask, naming the model and its size, a small one (`all-minilm`) where any will do. |
| Copy | It replaces the user's clipboard: say so before the run. |

## A session

1. Start a session sheet in the run's report: the charter, the start time, and the build, macOS, server and profile.
   The first session re-checks what the last report says was fixed, likely fixed or not re-checked, as a finding
   "likely fixed" because it could not be reproduced on demand can be back in the next run's `app.log`. Plan the rest by
   the model's pace: a large batch takes about half a minute a document with a 14B model on a server on the network, so
   while it files, explore what does not need a still archive (cards, labels, profiles, tasks, conversations, the CLI),
   and leave what does (switching archives, a rebuild, Statistics' counts) until Incoming is empty.
2. Do what a user would, one action at a time. After each, look: screenshot the window (`qa-drive.sh shot`), read what
   it says (`tree`), and check what changed underneath (`arrumatorcli`, the archive, History, `app.log`).
3. Write down each finding as it is found, never from memory afterwards, with its evidence.
4. Close the session: how long it took, the share spent on the charter, on setting up, and on chasing findings, what was
   not covered, and new charters it suggests.

## Report

A run writes `docs/qa/reports/<date>/report.md`, with its screenshots beside it in `shots/`:

- **Run**: date, branch and commit, macOS, Ollama server and version, profile and models, corpus.
- **Coverage**: each charter, covered, partly or not, and why.
- **Findings**, the most severe first, each with an id (`<charter>-<n>`), and:
  - title, severity and the heuristic or rule it breaks;
  - steps to reproduce, from a fresh scratch home where needed;
  - what was expected, and why: the document, rule or heuristic that says so;
  - what happened, with its evidence: screenshot, accessibility tree, log lines, record file, CLI output;
  - where the fix likely lies (module, file), when it is known.
- **Session sheets**, one per session.
- **What works**: what was checked and held, so the next run knows what was covered.
- **The last run's findings**: each one it fixed, re-checked, and whether it held.
- **The protocol**: what the run found the protocol, or its driver, got wrong or left out, and what was changed in it,
  so the next run starts from what this one learned.

Never put a real document, a personal name or anything of the user's own into a report, nor anything read from outside
the app under test.

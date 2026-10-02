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
says what each fixture's labels are; `arrumatorcli eval` measures that at scale, so a run samples it by hand.

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

1. Build the branch under test: `scripts/verify.sh --app`, which leaves `Arrumator.app` in `build/DerivedData`.
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
     build/DerivedData/Build/Products/Debug/Arrumator.app/Contents/MacOS/Arrumator > "$RUN/app.log" 2>&1 &
   echo $! > "$RUN/pid"
   ```

5. Drive it with `scripts/qa-drive.sh`, which goes through the macOS accessibility API to that process alone: it reads
   the window's elements (`tree`, `find`), presses buttons and menu items (`press`), clicks and double-clicks rows
   (`click`, `dclick`), types into fields (`set`, `type`), sends keys (`key return`, `key escape`, `key f cmd`), scrolls
   (`scroll`) and screenshots its window and no other (`shot`). The terminal it runs in needs Accessibility in System
   Settings › Privacy & Security. It never reads the system's Apple menu, which lists the user's own recent files. The
   screen must be unlocked: while it is locked, the accessibility API gives every window, any app's, as the application
   itself, `windows` lists none and `shot` makes no image, so wait for the user rather than read anything into it.
   A file panel (Choose…, Export) opens on the user's own folders: never read its elements, which list the user's files,
   and never press Open or Save until the panel's folder is the scratch one. Point it there with Go to Folder
   (`key g cmd,shift`, then type the path), read only that the panel now shows the scratch folder's name, and check
   afterwards where the file went (the card, `arrumatorcli tasks show`). When the panel cannot be pointed there,
   cancel it and do the same through `arrumatorcli`.

   The app moves an exact copy of a document, and a file it has no more use for, to the Trash: `ARRUMATOR_TRASH` makes
   that a scratch folder, so set it for the app and for every command of the run, and check afterwards that what went
   there is in `$RUN/Trash`.
6. The corpus is `Tests/Fixtures`: synthetic documents in Portuguese, Russian, English and other languages and scripts,
   scans, photos, mail and Office files, and the negative cases (encrypted, blank, damaged, an exact copy, a
   spreadsheet). Put a part of it in a folder of its own inside Incoming to see folder tags. Never use real documents.
7. Use `arrumatorcli` in the same scratch home (`ARRUMATOR_HOME`, `ARRUMATOR_TRASH`, `ARRUMATOR_OLLAMA_URL`) to check
   what the app shows against what Core says, and the record files and `app.log` to check what it wrote.

At the end, quit the app the way a user does, then check the scratch archive's files once more. Stop nothing else.

## Charters

Each charter is one session or more. The use cases come from `README.md` and `docs/using-arrumator.md`; the edge cases
are those each area is most likely to get wrong. A run covers every charter, or says in its report which it did not and
why.

| # | Charter: explore… | Use cases | Edge cases and risks |
|---|---|---|---|
| C1 | First run and onboarding, step by step, forward and back | Welcome, folders, background and notifications, Ollama and its server, profile and models, Ready | Ollama unreachable or slow, a server off the local network refused, models missing and their Download, the menu bar full, keyboard only (Return, Escape, Tab), closing the window part way |
| C2 | Filing documents through Incoming and the queue | Drop files and folders, watch In Progress and Queued, a document filed and named | Every format of the corpus, non-Latin names, a folder in Incoming as a tag, nested folders, an exact copy, encrypted, blank, damaged and unsupported files, a large batch, pausing and resuming, quitting part way and starting again |
| C3 | Processed and a document's card | Open a card, rename, add and remove labels, read again, undo filing, open the file and show it in Finder | Empty and very long names, names with `/` or `:`, a label of every kind, removing every label, undo twice, a file moved in Finder meanwhile |
| C4 | Needs You | Confirm, read again, leave for later, undo | Each reason a document waits, a document read again that still fails, counts on the sidebar |
| C5 | The sidebar's labels | Choose labels to narrow down, Clear, Filter Labels, group by kind, Show More | Labels in many scripts, filters that match nothing, accents and punctuation, choosing every label, a narrowed page with no documents |
| C6 | The Labels page | Merge, keep apart, remove everywhere, forget a rule, suggestions of alike labels | Merging a label into itself, into one of another kind, a tag, undoing a rule, what a later reading does |
| C7 | Search tasks | Ask in several languages, watch the queue, open the card, rename, rewrite, Find Again, effort and profile, arrangement, add documents through the sidebar, take out, export to a folder and as ZIP, remove | A request that finds nothing, an empty or very long request, a profile removed meanwhile, an export into the archive or Incoming refused, exporting twice, a task read while another is |
| C8 | Talking with a task's documents | Ask, watch the answer being written, sources, find more and add, Copy, Ask Again, Stop, Clear | Translation, an e-mail draft, a question about nothing in the set, a question in another language, a set changed between questions, a very long answer cut off, Ollama away, an empty set, a task still being read, the groundedness of every answer |
| C9 | Settings and model profiles | General, Models, profiles: choose, add, rename, change models, reset, remove; Advanced: rebuild the index, diagnostics | A profile in use or named by a task removed, a blank name, a name taken, a model not installed, a server address that is not local |
| C10 | History, Statistics and traces | Read every event, open the document or task it is about, the funnel, a trace of a document and of a task | Events of every kind, long summaries, a trace of a failed reading |
| C11 | The app around its window | Menu bar, Dock, windows, notifications, quitting while working | The menu bar full, reopening a closed window, two windows, quitting during a reading and during an answer |
| C12 | Resilience | Ollama going away and back, a record file edited by hand, switching archives, a restart | Stopping in the middle of every queue, a broken record file, an archive moved, the clock |
| C13 | The app against `arrumatorcli` | Each action of C2–C9 done in one and read in the other | The `--json` of every command decoded, a change made by the CLI while the app runs |
| C14 | Accessibility and keyboard | Every page by keyboard and through the accessibility tree | Controls without labels, images without descriptions, colour as the only sign, focus lost after an action, both appearances, the smallest window |

## A session

1. Start a session sheet in the run's report: the charter, the start time, and the build, macOS, server and profile.
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

Never put a real document, a personal name or anything of the user's own into a report, nor anything read from outside
the app under test.

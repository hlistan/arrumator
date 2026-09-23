# Arrumator

A macOS menu-bar app that files your documents for you — entirely on your Mac.

Drop any file into your **Incoming** folder (PDF, scans, photos, screenshots, Word/Excel/PowerPoint, e-mails, text, …).
Arrumator reads it, decides where it belongs and what it should be called, files it into your archive, indexes it for
search, and learns from every correction you make. Documents in English, Russian and Portuguese are supported.

**Privacy:** recognition uses only local models through [Ollama](https://ollama.com) on `127.0.0.1`. Every network
request goes through a guard that refuses non-loopback hosts (`NetworkGuardProtocol`); the only time the internet is
used is when *you* press "Download" for a model.

## How a file is handled

```
new file in Incoming ──► wait until it stops changing ──► hash (exact duplicates → Duplicates)
   ──► extract: PDFKit text, Apple Vision OCR (en/ru/pt), textutil (doc/docx/rtf/odt/html), CoreXLSX, PPTX, e-mail,
       archives, media metadata, Quick Look previews, local vision model for photos; language, dates, identifiers
   ──► learned evidence: known correspondents (by learned identifiers, e-mail/web domains, names),
       similar past filings (bge-m3 embeddings), rules formed from usage
   ──► confident?  ── yes ─► place directly; the model is only asked for the file name, as the logic says
                   └─ no ──► the local model decides, following the archive's logic (your prompt) with the whole
                             folder tree and learned hints as advice:
                               1. the IDEAL home for this document (area / category / description / year folders)
                               2. mapping onto existing folders, or creating the ideal one
                               3. the file name
                             The app checks the mapping with embeddings (an unrelated folder is never reused; a
                             near-duplicate new folder reuses the existing one; an area the model names with its
                             code, "10-19 Insurance & Legal", is that area) and calibrates confidence.
   ──► file it (create folders on demand, name it, keep the original name in an extended attribute); when the
       chosen folder was removed while the model decided, decide again against the tree as it is now
   ──► learn: every placement becomes a memory; confirmed/confident ones form rules; folder context is refreshed
```

Uncertain documents wait in **Needs review** (created only when first needed). Moving a file in Finder, choosing a
folder in the app, renaming, undoing — all are recorded as corrections and change future decisions: correspondents gain
aliases and folders' learned context updates.

Rules keep learning after they form. Each filing that agrees with a rule raises its support, so it becomes more
trusted; filing a document somewhere other than where a rule points counts against it, and two disagreements switch it
off. Approving what the app proposed is agreement, not disagreement. A rule the app switched off comes back on its own
once fresh filings restore its reliability; one you switched off by hand stays off.

Every file is named by the model, following the logic: the naming style is part of the logic, and there is no name
template to set. A document that learned rules place without asking the model where it goes is still named that way,
with a short request for the name alone. If the model gives no usable name, the file keeps the name it arrived with.

Anything learned can be forgotten, from the Learned page, a document's card or `arrumator forget`:

- **A document as an example of its folder.** It stops counting as evidence for future decisions.
- **A rule.** It stops placing documents, and the same filings never form it again.
- **Another name for a sender.** The name is no longer matched to that sender.
- **A whole sender.** Its names, identifiers and usual folder are forgotten, together with the rules about it.

Forgetting something takes it off the Learned page, and on a document's card the lesson is struck through. Each time the
app forgets something, whether you asked or you undid a filing, it is recorded in History, not among the lessons.

## Logic: you decide how the archive is organised

**Logic** is the prompt the model follows when it decides where a document goes and what it is called. Each archive
has exactly one, kept in the archive itself as `00-09 System/06 Logic/_logic.md`. It comes first in every decision, and
learned rules, past filings and corrections only advise it: when they disagree, the logic wins. A new archive starts
with the built-in logic, *Organizing principles*, which condenses established records-management practice (NIST,
university research-data guides, Johnny.Decimal, paperless-ngx; sources in
[docs/organizing-principles-sources.md](docs/organizing-principles-sources.md)). Until you change it, it is kept up to
date with each new version of the app. You can edit it and reset it to the original.

Edit the logic in place on the Logic page, or open `_logic.md` in any editor: the text after its front matter is the
prompt, and a file holding nothing but a prompt works too. The app reads an edit made in the file straight away. New
documents follow the logic from then on. Then:

1. **Try it on a few documents.** The app asks the logic where documents from across the archive belong and
   shows each decision on the Logic page as it is made, the newest first; click one to see why the logic chose it.
   You do not have to wait for the end. **Stop Here** interrupts the document being decided and makes what has been
   decided so far the plan; the documents not reached stay where they are. **Discard** throws the trial away, so
   the logic can be changed straight away. Nothing moves unless you apply the plan. Documents the logic would move are
   ticked; untick any that should stay. When the logic was unsure but still suggested a place, the document is listed
   unticked: tick it to take the suggestion, and the move is recorded as your decision. When nothing would change, the
   plan closes on its own and says so, so the logic is never left locked by a plan with nothing in it.
2. **Reprocess everything.** Every processed document is decided again with the logic. Learned rules no longer
   short-cut the decision here, and a document's own past filing is not offered as evidence. Documents you placed or
   confirmed yourself are left out unless you include them. You review the plan (which documents move where, and
   which folders appear; documents keep their names) and leave out anything you want to stay put. Applying it moves
   the files, creates the folders, removes every folder left empty and lets rules follow their documents to their
   new folders.

A topic's home is decided per area: when the logic puts payslips under "Work", a "Payslips" folder under "Home" is not
their home, and reprocessing moves them. Nothing is moved while a plan is being made, and the logic cannot be
changed until the plan is applied or discarded, so one plan never mixes two kinds of logic. Every decision records
which logic made it.

### Each archive is organised its own way

Because the logic belongs to the archive, two archives can be arranged in two different ways. Choose another archive
under Settings › General, with **Switch Archive…** in the menu at the foot of the sidebar, or with
`arrumator archive switch <folder>`. From then on documents are filed there, following that archive's logic, folders
and rules, and files still waiting in Incoming go there too. A folder never used as an archive starts with the
built-in logic; switching back to an archive brings back everything it had. Each archive has an index of its own, so
nothing learned from filing into one ever advises the other. A running app keeps its archive when the command line
switches, until it is started again.

A folder is removed as soon as it holds no documents, whether after a rethink or after you move or undo the last
document in it. Only the app's own `_about.md` and system leftovers such as `.DS_Store` may remain in it. The folder's
description stays in the database, and a folder that still holds any file is never touched.

## The folder tree grows with your documents

Nothing is pre-created. The first document creates the first folder. Folders follow Johnny.Decimal conventions
(`20-29 Money & Taxes/21 Taxes (Portugal)/2025/…`: two levels, codes assigned by the app, year subfolders for recurring
documents). Each folder has an `_about.md` whose description the model reads when deciding; a machine-maintained block
at its end lists what actually lives there (recent file names, usual correspondents). Edit descriptions freely — your
text is never overwritten. `_INDEX.md` at the archive root lists the whole tree.

## Requirements

- macOS 26 on Apple Silicon, Xcode 27 (Swift 6.4) to build
- Ollama (the app can start it) and one model profile from `pipeline.json`:

| Profile | Decisions & vision | Embeddings | Disk |
|---|---|---|---|
| `standard` (default) | `gemma4:latest` | `bge-m3` | ~11 GB |
| `balanced` | `qwen3:8b` + `gemma3:4b` | `bge-m3` | ~10 GB |
| `lowMemory` | `gemma3:4b` | `bge-m3` | ~5 GB |

## Build and run

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Arrumator.xcodeproj -scheme Arrumator -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Arrumator.app      # first launch shows onboarding

swift test                                                       # 160 tests: extraction, core, classification, runtime
swift run arrumator doctor                                       # environment self-check
swift run arrumator ingest --dry-run ~/Downloads/some.pdf        # what would happen, without moving anything
swift run arrumator run                                          # headless: watch Incoming and file
```

Release build: `DEVELOPER_ID=… NOTARY_PROFILE=… scripts/release.sh` signs with your Developer ID, notarizes and
staples (needs an Apple Developer account).

Other commands: `search`, `history`, `trace <doc>`, `replay <doc> [--model m]`, `review [approve|move|rename|undo|retry]`,
`folders [create]`, `rules`, `senders`, `forget example|rule|alias|sender`, `archive [switch <folder>]`,
`logic [show|edit --file <prompt>|reset]`, `rethink [start [--trial] [--now]|plan|stop|keep|apply|discard]`, `proposals`, `rebuild`, `stats`, `logs [--follow]`, `models [pull]`, `diagnostics <zip>`,
`eval <fixtures>`, `settings`. Every command accepts `--json`.

## Configuration

No tunable lives in code. Defaults are bundled in `Sources/ArrumatorCore/Resources/Defaults/`:

- `settings.json` — user preferences (folders, thresholds, model profile, folder-name language, …). The app stores only
  your changes in `~/Library/Application Support/Arrumator/settings.json`.
- `pipeline.json` — every pipeline tunable (Ollama endpoint and timeouts, model profiles, OCR/extraction limits,
  learning and direct-placement thresholds, calibration weights, search, logging). Override any subset in
  `~/Library/Application Support/Arrumator/pipeline.json`.

Environment variables: `ARRUMATOR_HOME` (relocate all state), `ARRUMATOR_OLLAMA_URL` (must be loopback),
`ARRUMATOR_PIPELINE_CONFIG` (extra override file), `ARRUMATOR_LOG_LEVEL`, `ARRUMATOR_LIVE=1` (enables tests that need a
running Ollama).

## Where everything is kept

Everything Arrumator knows that it could not work out again is kept in Markdown files inside the archive, next to what
it describes: each folder's `_about.md`, a `_documents.md` in every directory holding filed documents, and, in the
`00-09 System` area, the senders, rules, corrections and filing memories it learned (`05 Learned`), the archive's logic
(`06 Logic/_logic.md`, the prompt as the file's text) and the history (`07 History`, one file per month). Each archive
has its own SQLite index in `~/Library/Application Support/Arrumator/Indexes`, which only indexes those files and caches
what can be recomputed, such as extracted text and embeddings. If it is lost, cannot be opened or cannot be migrated,
the app rebuilds it from the archive and reads each document's text again in the background. You can edit the files by hand; the app reads the change back and never overwrites it.
The design, and what a rebuild does and does not keep, is in [docs/storage.md](docs/storage.md).

## What the app shows you

The window is deliberately quiet, after [Things](https://culturedcode.com/things/): a sidebar with four lists and your
archive's folders, one list per page under a large title, and no dashboards. Every document row shows the decision at
its end: the folder it went to, or what happened to it and where the file is now ("Could not be processed · in
02 Needs review", "Undone by you · back in Incoming"), and who decided (a learned rule, past filings, the model and how
sure it was, or you). Clicking a row opens the document in place as a card with the full decision, the reason, and
what Arrumator learned from it. Everything on the card can be changed there: move it, rename it, fix the sender, date
or type, confirm it, undo it. Each change is recorded as a correction and learned from, and the lesson appears on the
card.

- **Incoming**: what is being worked on (and at which step), what is queued, and what was just processed, grouped by
  day as on Processed, with **Show More in Processed** for the rest.
- **Needs You**: documents the app was not sure about, with its suggestion to accept or override.
- **Processed**: everything finished, newest first and grouped by day, like Things' Logbook.
- **Learned**: what the app knows now: the documents it files by as examples of their folders, newest first, the
  rules that formed, the senders it knows, and suggestions to accept. Anything there can be forgotten.
- **Logic**: the archive's logic, edited in place, and the two steps after a change: try it on a few documents, then
  reprocess everything. The plan forms decision by decision and can be stopped at any point; it is reviewed and
  applied on the same page, which says when the logic has changed since it was last tried. While a plan waits for
  you, the number of documents you can decide on shows next to Logic in the sidebar.
- **Archive**: each area and folder, with its description and its documents.

Search sits at the top of the sidebar. **Statistics** and **History** are in the menu at its foot.

**Statistics** is the whole processing funnel: how many files arrived, how far they got, where they stopped and why,
how long each step takes, and how much of the filing now happens from learned rules instead of a model call. Every
statistic sits under the step it describes, so opening **Read** shows scan quality and files it could not read,
**Matched against what it knows** shows the rules and how often past filings agreed, **Decided** shows how sure it was
and whether it was right (with the automatic-filing threshold you can move and see what it would have done), and
**Filed** shows the mix-ups you corrected.

The funnel is drawn as bars sharing one baseline rather than a tapered funnel, because a funnel encodes values as the
width of a trapezoid: early losses look larger than late ones and the filled areas mean nothing. Data marks use fixed
colours rather than the system accent, which macOS greys out whenever the window is not focused.

## Audit, logs and tuning

- **History** — every arrival, extraction, decision, filing, folder creation, correction, undo, lesson learned (recorded
  against the document it came from), rule change, settings change and Ollama availability change (`events` table;
  History view; `arrumator history`).
- **Traces** — for every document, each stage's inputs, outputs and timing, including the exact prompts and raw model
  responses ("How was this decided?"; `arrumator trace <doc> --full`). `replay` re-runs a decision with another model
  without touching files.
- **Funnel** — counts, drop-off reasons and timings per step (`arrumator funnel --days 30`).
- **Processing log** — structured JSONL per day in `~/Library/Logs/Arrumator`, readable per funnel step under
  Settings › Processing log, so you can see which step is producing the errors and warnings
  (`arrumator logs --follow`).
- **Statistics** — accuracy (documents you did not move later), most frequent corrections, what-if thresholds, latency
  per stage, rules, OCR quality, look-alike folders (`arrumator stats`).
- **Diagnostics** — one zip with logs, recent traces, doctor report, settings and folder tree; document text is
  excluded unless you ask for it.

## Evaluation

`Tests/Fixtures` holds 41 synthetic EN/RU/PT documents (text PDFs, scans, photos, HEIC, screenshots, DOCX, XLSX,
KOI8-R text, e-mail, negatives) with expected outcomes; `Tools/FixtureGen` regenerates them deterministically.
`arrumator eval Tests/Fixtures --passes 2` runs them through the live pipeline in a throw-away archive and reports
grouping consistency (documents of the same kind share a folder, different kinds don't), type/date/correspondent
accuracy, how many were placed without the model, and the folder tree that emerged.

## Project layout

| Path | Contents |
|---|---|
| `Sources/ArrumatorCore` | contracts, configuration, SQLite (GRDB, FTS5), taxonomy, watchers (FSEvents), file operations, ingest state machine, Ollama client/lifecycle, search, audit/insights |
| `Sources/ArrumatorExtract` | on-device extraction for every format, OCR, language, dates, identifiers |
| `Sources/ArrumatorClassify` | learned evidence, rules, prompts, model decisions, placement guard, calibration, learning |
| `Sources/ArrumatorRuntime` | composition root shared by the app and the CLI |
| `Sources/ArrumatorCLI` | `arrumator` command-line tool |
| `App/` | SwiftUI menu-bar app (search, browse, history, review, rules, insights, logs, settings, onboarding) |
| `Tests/` | Swift Testing suites, mock Ollama, fixture corpus |

The app is not sandboxed: it watches arbitrary folders you choose, writes extended attributes, and starts Ollama. It
uses the hardened runtime and makes no network requests other than to the local Ollama server.

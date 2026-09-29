# Using Arrumator

The app, its settings and the records it keeps of every step. [How Arrumator works](how-it-works.md) explains how
documents are read and filed; [the command line](cli.md) does everything the app does, from a terminal.

## What the app shows you

The window is deliberately quiet, after [Things](https://culturedcode.com/things/). It has a sidebar with four lists.
Each list is one page under a large title, with no dashboards. Every document row shows at its end what happened to
it: filed in the archive, or waiting for you and why ("Waiting for you: the model gave no valid answer"), a copy of
another document, or undone and back in Incoming. Its labels show beneath it. Clicking a row opens the document in
place as a card with its name, its sender, date and type, the labels the model gave it (whom and what it is about,
its jurisdictions and languages; [labels](how-it-works.md#labels-what-a-document-is-about)), which model read it and
any problem it had, and what was learned from it. The name, sender, date and type can be changed there; a corrected
sender teaches the app another name for it, and the lesson appears on the card. The card's actions follow the
document's state: **Looks Right** confirms it as it is, **Read Again** has the model read it again, **Leave for Later**
holds it, and **Undo Filing** moves it back to Incoming.

- **Incoming**: what is being worked on (and at which step), what is queued, and what was just processed, grouped by
  day as on Processed, with **Show More in Processed** for the rest.
- **Needs You**: documents the model could not read, or that are encrypted, damaged or blank, each with the reason.
- **Processed**: everything finished, newest first and grouped by day, like Things' Logbook.
- **Senders**: the senders the app knows, each with its other names and what recognises it. A name, or a whole
  sender, can be forgotten.

Search sits at the top of the sidebar. It lists the documents that contain your words first, then those alike in
meaning, such as the same kind of document in another language, most similar first. Words are looked for in the
title, sender, file name, text and labels; `field:word` or `field:"a phrase"` looks in one of them only: `title`,
`correspondent`, `filename`, `body`, or a kind of label, `subject`, `object`, `jurisdiction` or `language`. Each field
counts as much as its weight in `search.bm25Weights`, in that order. A document found by meaning
alone must reach `search.semanticMinSimilarity` (calibrated in [Evaluation › Search](evaluation.md#search)).
**Statistics** and **History** are in the menu at its foot.

### Statistics

**Statistics** is the whole processing funnel, over the last few days (`stats.windowsDays`). It shows how many files
arrived, how far they got, where they stopped and why, and how long each step takes. The steps come from
`stats.funnel.steps`: arrived, checked for copies, read, understood, analysed, filed and learned from. Every statistic
sits under the step it describes:

- **Read** shows scan quality and the files it could not read.
- **Analysed** shows how many documents are labelled and how many are not yet, and the labels of each kind.
- **Filed** shows how many documents you corrected and how many you confirmed.
- **Learned from** leads to the Senders page.

The funnel is drawn as bars sharing one baseline rather than a tapered funnel, because a funnel encodes values as the
width of a trapezoid: early losses look larger than late ones and the filled areas mean nothing. Data marks use fixed
colours rather than the system accent, which macOS greys out whenever the window is not focused.

## Audit, logs and tuning

- **History**: every arrival, extraction, reading, filing, correction, confirmation, undo, move or rename in Finder,
  name learned (recorded against the document it came from), forgetting, settings change and Ollama availability
  change (`events` table; History view; `arrumatorcli history`).
- **Traces**: for every document, each stage's inputs, outputs and timing, including the exact prompts and raw model
  responses ("How was this read?"; `arrumatorcli trace <doc> --full`). `arrumatorcli replay` reads a document again
  with another model without touching files.
- **Funnel**: counts, drop-off reasons and timings per step (`arrumatorcli funnel --days 30`).
- **Processing log**: structured JSONL per day in `~/Library/Logs/Arrumator`, readable per funnel step under
  Settings › Processing log, so you can see which step is producing the errors and warnings
  (`arrumatorcli logs --follow`).
- **Statistics**: documents by status, labelled and not yet labelled, labels by kind, corrections and confirmations,
  latency per stage, OCR quality and extraction warnings (`arrumatorcli stats`).
- **Diagnostics**: one zip with logs, recent traces, doctor report and settings; document text is excluded unless you
  ask for it: the steps that exchanged it with the model (reading a document, describing an image) keep their timings
  but neither what they sent nor what came back (`arrumatorcli diagnostics <zip> [--include-document-text]`).

## Configuration

No tunable lives in code. Defaults are bundled in `Sources/ArrumatorCore/Resources/Defaults/`:

- `settings.json`: your preferences (folders, Ollama server, model profile, file renaming and transliteration, what to
  do with copies, notifications, …). The app stores only your changes, in
  `~/Library/Application Support/Arrumator/settings.json`. Change them in Settings or with `arrumatorcli settings`.
- `pipeline.json`: every pipeline tunable, in sections: `ollama` (timeouts, retries, how it is started),
  `modelProfiles`, `watcher`, `records` (the archive's record file and system folder names), `ingest` (attempts and
  retry delays), `extraction` (OCR and extraction limits), `entities` (dates and identifiers), `analysis` (what the
  model is shown and how it is asked, such as `analysis.excerptChars` and `analysis.repairAttempts`), `labels`
  (`labels.maxPerKind`, `labels.maxValueChars`), `senders` (`senders.stableKeyMinFilings`), `naming`, `search`,
  `logging`, `power`, `stats` and `interface`. Override any subset in
  `~/Library/Application Support/Arrumator/pipeline.json`.

The Ollama server is set under Settings › Models › Ollama › Server, or with `arrumatorcli settings --ollama-url`. It must
be this Mac, a private or link-local address, or a `.local` name; anything else is refused.

Environment variables:

| Variable | Effect |
|---|---|
| `ARRUMATOR_HOME` | Relocates all state: indexes, settings and logs (`$ARRUMATOR_HOME/Logs`). It does not move the archive or Incoming, which `settings.json` names. |
| `ARRUMATOR_OLLAMA_URL` | The Ollama server while set, in place of the setting; this Mac or the local network only. |
| `ARRUMATOR_PIPELINE_CONFIG` | An extra `pipeline.json` override file, applied after yours. |
| `ARRUMATOR_LOG_LEVEL` | `error`, `warning`, `info`, `debug` or `trace`. |
| `ARRUMATOR_LIVE=1` | Enables the tests that need a running Ollama. |

## Where everything is kept

Everything Arrumator knows that it could not work out again is kept in Markdown files inside the archive, next to what
it describes: a `_documents.md` in every directory holding documents, and, in the `System` folder at the top of the
archive, the senders it learned (`Learned/_senders.md`) and the history (`History`, one file per month).

Each archive has its own SQLite index in `~/Library/Application Support/Arrumator/Indexes`, which only indexes those
files and caches what can be recomputed, such as extracted text and embeddings. If it is lost, cannot be opened or
cannot be migrated, the app rebuilds it from the archive and reads each document's text again in the background. You
can edit the files by hand; the app reads the change back and never overwrites it. The design, and what a rebuild
does and does not keep, is in [Storage](storage.md).

The app is not sandboxed: it watches folders you choose, writes extended attributes, and starts Ollama. It uses the
hardened runtime and makes no network requests other than to your Ollama server.

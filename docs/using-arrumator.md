# Using Arrumator

The app, its settings and the records it keeps of every decision. [How Arrumator works](how-it-works.md) explains
the decisions themselves; [the command line](cli.md) does everything the app does, from a terminal.

## What the app shows you

The window is deliberately quiet, after [Things](https://culturedcode.com/things/). It has a sidebar with five lists
and, below them, your archive's folders. Each list is one page under a large title, with no dashboards. Every
document row shows the decision at its end. That is the folder it went to, or what happened to it and where the file
is now ("Could not be processed · in System › Needs review", "Undone by you · back in Incoming"), and who decided (a
learned rule, past filings, the model and how sure it was, or you). Clicking a row opens the document in place as a
card with the full decision, the reason, the labels the model gave it (whom and what it is about, its jurisdictions
and languages; [labels](how-it-works.md#labels-what-a-document-is-about)), and what Arrumator learned from it.
Everything on the card can be changed
there: move it, rename it, fix the sender, date or type, confirm it, undo it. Each change is recorded as a correction
and learned from, and the lesson appears on the card.

- **Incoming**: what is being worked on (and at which step), what is queued, and what was just processed, grouped by
  day as on Processed, with **Show More in Processed** for the rest.
- **Needs You**: documents the app was not sure about, with its suggestion to accept or override.
- **Processed**: everything finished, newest first and grouped by day, like Things' Logbook.
- **Learned**: what the app knows now. That is the documents it files by, as examples of their folders, newest first;
  the rules that formed (each says which sender it is about); the senders it knows (each with what recognises it and
  the rules about it); and suggestions to accept. Anything there can be forgotten.
- **Logic**: the archive's logic, edited in place, and the two steps after a change: try it on a few documents, then
  reprocess everything. The plan forms decision by decision and can be stopped at any point; it is reviewed and
  applied on the same page, which says when the logic has changed since it was last tried. While a plan waits for
  you, the number of documents you can decide on shows next to Logic in the sidebar.

Below the lists, **Archive** holds the folder tree at any depth; each folder opens with its description, its
subfolders and its documents.

Search sits at the top of the sidebar. It lists the documents that contain your words first, then those alike in
meaning, such as the same kind of document in another language, most similar first. Words are looked for in the
title, sender, file name, text and labels; `field:word` or `field:"a phrase"` looks in one of them only: `title`,
`correspondent`, `filename`, `body`, or a kind of label, `subject`, `object`, `jurisdiction` or `language`. Each field
counts as much as its weight in `search.bm25Weights`, in that order. A document found by meaning
alone must reach `search.semanticMinSimilarity` (calibrated in [Evaluation › Search](evaluation.md#search)).
**Statistics** and **History** are in the menu at its foot.

### Statistics

**Statistics** is the whole processing funnel. It shows how many files arrived, how far they got, where they stopped
and why, how long each step takes, and how much of the filing now happens from learned rules instead of a model call.
Every statistic sits under the step it describes:

- **Read** shows scan quality and the files it could not read.
- **Labelled** shows how long the model took to label documents, and the ones it gave no labels for.
- **Matched against what it knows** shows the rules and how often past filings agreed.
- **Decided** shows how sure it was and whether it was right, with the automatic-filing threshold you can move to see
  what it would have done.
- **Filed** shows the mix-ups you corrected.

The funnel is drawn as bars sharing one baseline rather than a tapered funnel, because a funnel encodes values as the
width of a trapezoid: early losses look larger than late ones and the filled areas mean nothing. Data marks use fixed
colours rather than the system accent, which macOS greys out whenever the window is not focused.

## Audit, logs and tuning

- **History**: every arrival, extraction, labelling, decision, filing, folder creation, correction, undo, lesson learned
  (recorded against the document it came from), rule change, settings change and Ollama availability change
  (`events` table; History view; `arrumatorcli history`).
- **Traces**: for every document, each stage's inputs, outputs and timing, including the exact prompts and raw model
  responses ("How was this decided?"; `arrumatorcli trace <doc> --full`). `arrumatorcli replay` re-runs a decision with
  another model without touching files.
- **Funnel**: counts, drop-off reasons and timings per step (`arrumatorcli funnel --days 30`).
- **Processing log**: structured JSONL per day in `~/Library/Logs/Arrumator`, readable per funnel step under
  Settings › Processing log, so you can see which step is producing the errors and warnings
  (`arrumatorcli logs --follow`).
- **Statistics**: accuracy (documents you did not move later), most frequent corrections, what-if thresholds, latency
  per stage, rules, OCR quality, look-alike folders (`arrumatorcli stats`).
- **Diagnostics**: one zip with logs, recent traces, doctor report, settings and folder tree; document text is
  excluded unless you ask for it: the steps that exchanged it with the model (deciding, labelling, describing images)
  keep their timings but not their prompts and answers (`arrumatorcli diagnostics <zip> [--include-document-text]`).

## Configuration

No tunable lives in code. Defaults are bundled in `Sources/ArrumatorCore/Resources/Defaults/`:

- `settings.json`: your preferences (folders, Ollama server, thresholds, model profile, folder-name language, …).
  The app stores only your changes, in `~/Library/Application Support/Arrumator/settings.json`. Change them in
  Settings or with `arrumatorcli settings`.
- `pipeline.json`: every pipeline tunable (Ollama timeouts, model profiles, OCR and extraction limits, labels
  (`labels.maxPerKind`, `labels.maxValueChars`), learning and direct-placement thresholds, calibration weights,
  search, logging). Override any subset in
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
it describes: each folder's `_about.md`, a `_documents.md` in every directory holding filed documents, and, in the
`System` folder, the senders, rules, corrections and filing memories it learned (`Learned`), the archive's logic
(`Logic/_logic.md`, the prompt as the file's text) and the history (`History`, one file per month). In an archive
started by an earlier version these folders are `00-09 System`, `05 Learned` and so on; they keep those names.

Each archive has its own SQLite index in `~/Library/Application Support/Arrumator/Indexes`, which only indexes those
files and caches what can be recomputed, such as extracted text and embeddings. If it is lost, cannot be opened or
cannot be migrated, the app rebuilds it from the archive and reads each document's text again in the background. You
can edit the files by hand; the app reads the change back and never overwrites it. The design, and what a rebuild
does and does not keep, is in [Storage](storage.md).

The app is not sandboxed: it watches folders you choose, writes extended attributes, and starts Ollama. It uses the
hardened runtime and makes no network requests other than to your Ollama server.

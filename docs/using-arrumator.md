# Using Arrumator

The app, its settings and the records it keeps of every step. [How Arrumator works](how-it-works.md) explains how
documents are read and filed; [the command line](cli.md) does everything the app does, from a terminal.

## What the app shows you

The window is deliberately quiet, after [Things](https://culturedcode.com/things/). It has a sidebar with four lists,
and below them the archive's labels. Each list is one page under a large title, with no dashboards. Every document row
shows at its end what happened to it: filed in the archive, or waiting for you and why ("Waiting for you: the model gave
no valid answer"), a copy of another document, or undone and back in Incoming. Its date, sender and type, and a few more
of its labels, show beneath it. Clicking a row opens the document in place as a card with its name and its labels, one
row for each kind it has ([labels](how-it-works.md#labels)), and which model read it and any problem it had. The name
can be changed there, any label taken off with its ×, and a label added by choosing its kind and writing its value; each
change is recorded in History. A label's menu opens it on the Labels page, shows the documents that have it, or removes
it from every document. The card's actions follow the document's state: **Looks Right** confirms it as it is, **Read
Again** has the model read it again, **Leave for Later** holds it, and **Undo Filing** moves it back to Incoming.

- **Incoming**: what is being worked on (and at which step), what is queued, and what was just processed, grouped by
  day as on Processed, with **Show More in Processed** for the rest.
- **Needs You**: documents the model could not read, or that are encrypted, damaged or blank, each with the reason.
- **Processed**: everything finished, newest first and grouped by day, like Things' Logbook.
- **Labels**: the archive's labels as one vocabulary ([how](how-it-works.md#keeping-labels-one-vocabulary)). **Look
  Alike** lists pairs of labels written so alike they may be one; open one to merge it either way or keep the two apart.
  The sidebar counts them, as they wait for you. Below come the labels of each kind the vocabulary keeps; open one to
  merge it into another or remove it everywhere, or to show the documents that have it. **What You Decided** lists your
  rules, each with **Forget**.

Below the lists, the sidebar lists the labels documents have, kind by kind (Senders, Types, Topics and so on), the most
used first: `interface.sidebarLabelsPerKind` of each, with **Show More** for the rest, and each kind can be folded away.
Click a label and the window shows the documents that have it, newest first and grouped by day, under the label as
its title. The sidebar then lists only the labels those documents have, so each label clicked next narrows them down
further: the documents shown have every label chosen. Chosen labels are marked in the sidebar and head the page; click
one again, or its × on the page, to let go of it. Letting go of the last, or choosing a list, shows the lists again.
"Show Documents" on a label's menu or card starts from that label alone. From a terminal, `arrumatorcli labels browse`
does the same.

Search sits at the top of the sidebar. It lists the documents that contain your words first, then those alike in
meaning, such as the same kind of document in another language, most similar first. Words are looked for in the file
name, the text and the labels; `field:word` or `field:"a phrase"` looks in one of them only: `filename`, `body`, or a
kind of label, `sender`, `party`, `type`, `topic`, `object`, `reference`, `date`, `period`, `deadline`, `amount`,
`jurisdiction` or `language`. Each field counts as much as its weight in `search.bm25Weights`, in that order. A document
found by meaning alone must reach `search.semanticMinSimilarity` (calibrated in [Evaluation ›
Search](evaluation.md#search)). **Statistics** and **History** are in the menu at its foot.

### Statistics

**Statistics** is the whole processing funnel, over the last few days (`stats.windowsDays`). It shows how many files
arrived, how far they got, where they stopped and why, and how long each step takes. The steps come from
`stats.funnel.steps`: arrived, checked for copies, read, understood, analysed and filed. Every statistic sits under the
step it describes:

- **Read** shows scan quality and the files it could not read.
- **Analysed** shows how many documents are labelled and how many are not yet, how many labels the model gave were
  tidied to the archive's labels or by your rules, how many rules you have, and the labels of each kind.
- **Filed** shows how many documents you corrected and how many you confirmed.

The funnel is drawn as bars sharing one baseline rather than a tapered funnel, because a funnel encodes values as the
width of a trapezoid: early losses look larger than late ones and the filled areas mean nothing. Data marks use fixed
colours rather than the system accent, which macOS greys out whenever the window is not focused.

## Audit, logs and tuning

- **History**: every arrival, extraction, reading (with the labels it gave, and which of the model's labels were tidied
  and why), filing, correction of a name or labels, decision about labels (a merge, a label removed everywhere, two
  kept apart, a rule forgotten), confirmation, undo, move or rename in Finder, settings change and Ollama availability
  change (`events` table; History view; `arrumatorcli history`).
- **Traces**: for every document, each stage's inputs, outputs and timing, including the exact prompts (with what the
  model was shown of the archive's labels), raw model responses and the labels the `consolidate` step changed ("How
  was this read?"; `arrumatorcli trace <doc> --full`). `arrumatorcli replay` reads a document again with another model
  without touching files.
- **Funnel**: counts, drop-off reasons and timings per step (`arrumatorcli funnel --days 30`).
- **Processing log**: structured JSONL per day in `~/Library/Logs/Arrumator`, readable per funnel step under
  Settings › Processing log, so you can see which step is producing the errors and warnings
  (`arrumatorcli logs --follow`).
- **Statistics**: documents by status, labelled and not yet labelled, labels by kind, corrections and confirmations,
  rules about labels and labels tidied,
  latency per stage, OCR quality and extraction warnings (`arrumatorcli stats`).
- **Diagnostics**: one zip with logs, recent traces, doctor report and settings; document text is excluded unless you
  ask for it: the steps that exchanged it with the model (reading a document, describing an image) and the one that
  tidied the labels drawn from it keep their timings but neither what they sent nor what came back
  (`arrumatorcli diagnostics <zip> [--include-document-text]`).

## Configuration

No tunable lives in code. Defaults are bundled in `Sources/ArrumatorCore/Resources/Defaults/`:

- `settings.json`: your preferences (folders, Ollama server, model profile, file renaming and transliteration, what to
  do with copies, notifications, …). The app stores only your changes, in
  `~/Library/Application Support/Arrumator/settings.json`. Change them in Settings or with `arrumatorcli settings`.
- `pipeline.json`: every pipeline tunable, in sections: `ollama` (timeouts, retries, how it is started),
  `modelProfiles`, `watcher`, `records` (the names of the archive's record files and of its system and history folders,
  such as `records.labelRulesFileName`),
  `ingest` (attempts and retry delays), `extraction` (OCR and extraction limits), `entities` (dates and identifiers),
  `analysis` (what the model is shown and how it is asked, such as `analysis.excerptChars` and
  `analysis.repairAttempts`), `labels` (`labels.maxPerKind`, `labels.maxValueChars`, and `labels.vocabulary`: for each
  kind kept one vocabulary, how alike labels must be written to be merged without asking or offered to merge and how
  many in use the model is shown, and how many of your merges and unwanted labels it is shown), `naming`, `search`, `logging`,
  `power`, `stats` and `interface` (how many rows a page loads, `interface.pageSize`, and how many labels of each kind the
  sidebar lists). Override any subset in `~/Library/Application Support/Arrumator/pipeline.json`.

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
it describes: a `_documents.md` in every directory holding documents, with each document's labels, and, in the
`System` folder at the top of the archive, the history (`History`, one file per month) and your rules for labels
(`_labels.md`).

Each archive has its own SQLite index in `~/Library/Application Support/Arrumator/Indexes`, which only indexes those
files and caches what can be recomputed, such as extracted text and embeddings. If it is lost, cannot be opened or
cannot be migrated, the app rebuilds it from the archive and reads each document's text again in the background. You
can edit the files by hand; the app reads the change back and never overwrites it. The design, and what a rebuild
does and does not keep, is in [Storage](storage.md).

The app is not sandboxed: it watches folders you choose, writes extended attributes, and starts Ollama. It uses the
hardened runtime and makes no network requests other than to your Ollama server.

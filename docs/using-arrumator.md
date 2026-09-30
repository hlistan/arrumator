# Using Arrumator

The app, its settings and the records it keeps of every step. [How Arrumator works](how-it-works.md) explains how
documents are read and filed; [the command line](cli.md) does everything the app does, from a terminal.

## What the app shows you

The window is deliberately quiet, after [Things](https://culturedcode.com/things/). It has a sidebar with five lists,
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
- **Tasks**: ask for documents in your own words ([search tasks](how-it-works.md#search-tasks)). Write what you need in
  the field at the top and press **Find**; the task waits in **In Progress** while the model reads it, then joins the
  tasks under **Earlier**, each with how many documents it found and how often it was exported. Open one as a card: its
  name, which you can change there; what you asked, which you can rewrite, and **Find Again**, which reads it again; what
  the model looked for; and what its documents are **Arranged by**, a kind per level, each with a × to take it away and
  a + to add one, or to go back to what the request asked. Below come the documents, a heading per group that folds
  away, each document with a × under the pointer to take it out of the set (a double-click opens it). **Add Documents…**
  shows every processed document with a + at the end of its row; choose labels in the sidebar to narrow them down, as
  anywhere else, add the documents you want one by one or **Add All With These Labels**, and press **Done** to go back
  to the task. **Export** copies the set **To a Folder…** or **As a ZIP Archive…** in a folder you choose, and shows it
  in Finder. Every export is listed on the card, with **Show in Finder** while it is still there. **Remove Task…**
  removes the task, never what it exported. An event about a task in History opens the task.

Below the lists, the sidebar lists the labels documents have, each with how many of the documents in view have it, the
most used first. They come in one list under **Most Used**, `interface.sidebarLabels` of them, or, with **Group Labels
by Kind** in the menu at the sidebar's foot (`groupLabelsByKind`, `arrumatorcli settings --group-labels-by-kind`), kind
by kind (Senders, Types, Topics and so on), `interface.sidebarLabelsPerKind` of each, each kind folding away; **Show
More** lists the rest. Each kind has its colour, on its name heading its group and on its labels' tags, so a label shows
its kind in the one list too; a label's help names its kind as well. These counts are the only ones on the sidebar
besides those of what waits for you. Click a label and the window shows the documents that have it, newest first and
grouped by day, under the label as its title. The sidebar then lists only the labels those documents have, so each
label clicked next narrows them down further: the documents shown have every label chosen. Chosen labels come first,
as every document shown has them, are marked in the sidebar and head the page; click one again, or its × on the page,
to let go of it, or **Clear** beside them on the page to let go of them all. Letting go of the last, or choosing a
list, shows the lists again. "Show Documents" on a label's menu or card starts from that label alone. From a terminal,
`arrumatorcli labels browse` does the same.

**Filter Labels**, between the lists and the labels, finds labels: as you type, the sidebar lists only the labels
written with your text in them, every one it finds, whatever their case, accents or punctuation (`tax return` finds the
type `tax-return`), and a language by its English name too. **Clear Filter** below them, or the × in the field, clears
it. It filters the labels the sidebar offers, so with labels chosen, only those of the documents in view.
`arrumatorcli labels browse --matching` does the same. **Statistics** and **History** are in the menu at the sidebar's
foot.

Documents are searched from a terminal, with `arrumatorcli search`. It lists the documents that contain your words
first, then those alike in meaning, such as the same kind of document in another language, most similar first. Words
are looked for in the file name, the text and the labels; `field:word` or `field:"a phrase"` looks in one of them only:
`filename`, `body`, or a kind of label, `sender`, `party`, `type`, `topic`, `object`, `reference`, `date`, `period`,
`deadline`, `amount`, `jurisdiction` or `language`. Each field counts as much as its weight in `search.bm25Weights`, in
that order. A document found by meaning alone must reach `search.semanticMinSimilarity` (calibrated in [Evaluation ›
Search](evaluation.md#search)).

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
  kept apart, a rule forgotten), confirmation, undo, move or rename in Finder, search task (asked, what it found or why
  it could not be read, changed, its set edited, exported, removed), settings change and Ollama availability change
  (`events` table; History view; `arrumatorcli history`).
- **Traces**: for every document, each stage's inputs, outputs and timing, including the exact prompts (with what the
  model was shown of the archive's labels), raw model responses and the labels the `consolidate` step changed ("How
  was this read?"; `arrumatorcli trace <doc> --full`). The prompts and raw answers of a reading, and the raw answer of
  an image description, are kept for Settings › Advanced › "Keep full model prompts" days (`traceRawRetentionDays`,
  180 by default, or `arrumatorcli settings --trace-retention-days`); after that they are cleared once an hour
  (`maintenance.interval`) and what the reading concluded stays. `arrumatorcli replay` reads a document again with
  another model without touching files. A search task's request is traced too: what the model was shown and answered
  (the `interpret` step) and what it found (`match`), with the same retention (`arrumatorcli tasks show <task> --full`).
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
  do with copies, notifications, how long model prompts are kept in traces, whether the sidebar groups labels by kind,
  …). The app stores only your changes, in
  `~/Library/Application Support/Arrumator/settings.json`. Change them in Settings or with `arrumatorcli settings`,
  which has an option for every one of them.
- `pipeline.json`: every pipeline tunable, in sections: `ollama` (timeouts, retries, how it is started; `ollama serve`,
  when the app starts it, listens on the address the app talks to, with `ollama.serveEnvironment` besides),
  `modelProfiles`, `watcher`, `records` (the names of the archive's record files and of its system and history folders,
  such as `records.labelRulesFileName` and `records.searchTasksFileName`),
  `ingest` (attempts and retry delays), `extraction` (OCR and extraction limits), `entities` (dates and identifiers),
  `analysis` (what the model is shown and how it is asked, such as `analysis.excerptChars`, of which the end of the
  document gets `1 / analysis.excerptTailDivisor`, `analysis.repairAttempts`, and the identifiers a document's
  embedding lists, `analysis.embeddingIdentifiersLimit`), `labels` (`labels.maxPerKind`, `labels.maxValueChars`, and
  `labels.vocabulary`: for each kind kept one vocabulary, how alike labels must be written to be merged without asking
  or offered to merge and how many in use the model is shown, and how many of your merges and unwanted labels it is
  shown), `naming`, `search`, `tasks` (search tasks: which labels in use the model is shown of each kind,
  `tasks.promptLabels`, how much a request may ask for, `tasks.maxValuesPerKind` and `tasks.maxWords`, how deep a set is
  arranged, `tasks.maxGroupingDepth`, and by what when the request does not say, `tasks.defaultGrouping`, how long a
  task's name from the model may be, `tasks.maxTitleChars`, how many documents a task finds at most,
  `tasks.maxDocuments`, and the folder an export puts documents without a label of a level's kind into,
  `tasks.withoutLabelFolder`), `logging` (with `logging.followInterval`, how often `arrumatorcli logs --follow` looks),
  `power`, `stats` (the periods Statistics offers, and `stats.defaultWindowDays`, the one it and `arrumatorcli funnel`
  show first), `interface` (how many rows a page loads, `interface.pageSize`, how many labels the sidebar lists in one
  list, `interface.sidebarLabels`, and of each kind when grouped, `interface.sidebarLabelsPerKind`, how many recent
  events notifications are drawn from, `interface.notificationEvents`, and how much text `arrumatorcli extract` prints,
  `interface.extractPreviewChars`), `maintenance` (how often the app prunes logs, trims traces and reschedules stuck
  jobs, `maintenance.interval`) and `database` (how long a write waits for another process using the index,
  `database.busyTimeout`). Override any subset in `~/Library/Application Support/Arrumator/pipeline.json`. An
  override the app cannot run with, such as an empty `ingest.retryDelays` or a negative `analysis.repairAttempts`,
  stops the app with the key and the reason.

The Ollama server is set under Settings › Models › Ollama › Server, or with `arrumatorcli settings --ollama-url`. It must
be this Mac, a private or link-local address, or a `.local` name; anything else is refused.

Environment variables:

| Variable | Effect |
|---|---|
| `ARRUMATOR_HOME` | Relocates all state: indexes, settings and logs (`$ARRUMATOR_HOME/Logs`). It does not move the archive or Incoming, which `settings.json` names. |
| `ARRUMATOR_OLLAMA_URL` | The Ollama server while set, in place of the setting; this Mac or the local network only. |
| `ARRUMATOR_PIPELINE_CONFIG` | An extra `pipeline.json` override file, applied after yours. |
| `ARRUMATOR_LOG_LEVEL` | `error`, `warning`, `info`, `debug` or `trace`, over the setting; any other value stops the app with the reason. |

## Where everything is kept

Everything Arrumator knows that it could not work out again is kept in Markdown files inside the archive, next to what
it describes: a `_documents.md` in every directory holding documents, with each document's labels, and, in the
`System` folder at the top of the archive, the history (`History`, one file per month), your rules for labels
(`_labels.md`) and your search tasks with their exports (`_tasks.md`).

Each archive has its own SQLite index in `~/Library/Application Support/Arrumator/Indexes`, which only indexes those
files and caches what can be recomputed, such as extracted text and embeddings. If it is lost, damaged or cannot be
migrated, the app rebuilds it from the archive and reads each document's text again in the background; one that is only
locked by another process or on a full disk is left as it is, and the app says why it cannot start. You can edit the
files by hand; the app reads the change back and never overwrites it, not even one it cannot read. The design, and what
a rebuild does and does not keep, is in [Storage](storage.md).

The app is not sandboxed: it watches folders you choose, writes extended attributes, and starts Ollama. It uses the
hardened runtime and makes no network requests other than to your Ollama server.

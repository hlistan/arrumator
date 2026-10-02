# Using Arrumator

The app, its settings and the records it keeps of every step. [How Arrumator works](how-it-works.md) explains how
documents are read and filed; [the command line](cli.md) does everything the app does, from a terminal.

## What the app shows you

The window is deliberately quiet, after [Things](https://culturedcode.com/things/). It has a sidebar with five lists,
below them the archive's labels, and a bar at its foot. Each list is one page under a large title, with no dashboards.
Every document row shows at its end what happened to it: nothing when it is filed at the top of the archive, or
where else it is, or waiting for you and why ("Waiting for you: the model gave no valid answer"), a copy an earlier
version filed of another document, or undone and back in Incoming. Rows are reached with the keyboard too (Tab, with
keyboard navigation on in System Settings), and Return or Space opens one. Its date, sender, type and tags, and a few
more of its labels, show beneath it. Clicking a row opens the document in place as a card with its name and its labels,
one row for each kind it has ([labels](how-it-works.md#labels)), and which model read it, or that no text could be taken
from it and the model saw only its name, and any problem it had, with what would help when **Read Again** alone cannot:
a copy saved without its password, or a good copy, put in Incoming. The name can be changed there (a blank one is
refused, saying so), any label taken off with its × or its menu's **Remove from This Document**, and a label added by
choosing its kind and writing its value; each change is recorded in History, in words: "Renamed to …; added sender
“EDP”; removed type “invoice”". A label's menu opens it on the Labels page, shows the documents that have it, or removes
it from every document. The card's actions follow the document's state: **Looks Right** confirms it as it is, **Read
Again** has the model read it again, saying it waits to be read after the files already in Incoming, **Leave for Later**
holds it, and **Undo Filing** moves it back to Incoming.

- **Incoming**: under **In Progress**, the file being worked on now, with a spinner and what is being done to it
  (**Reading its text**, **Being read by the model**, …); under **Queued**, every other file, in the order they arrived,
  which is the order they are filed in, each saying when it arrived, or, for a file stopped part way (as when you quit
  Arrumator), **Carries on where it stopped**, which it does first at the next start, or the error it had and when it is
  tried again ([how](how-it-works.md#how-a-file-is-handled)). Beneath a file's name, after a grey tag symbol, are the
  tags it will be given, as a document's labels are beneath its own: the name of the folder in Incoming it is in, such
  as **Taxes 2024** for `Incoming/Taxes 2024/scan.pdf` ([folders in
  Incoming](how-it-works.md#folders-in-incoming-and-tags)), and for a document read again the tags it keeps; nothing for
  a file directly in Incoming. An exact copy of a document in the archive leaves for the Trash once it is checked, and
  that document joins the queue to be read again, under its own name ([exact copies](how-it-works.md#exact-copies)).
  Then comes what was just processed, grouped by day as on Processed, each with its labels, its tags among them, with
  **Show More in Processed** for the rest.
- **Needs You**: documents the model could not read, or that are encrypted, damaged or blank, each with the reason.
- **Processed**: everything finished, newest first and grouped by day, like Things' Logbook.
- **Labels**: the archive's labels as one vocabulary ([how](how-it-works.md#keeping-labels-one-vocabulary)). **Look
  Alike** lists pairs of labels written so alike they may be one; open one to merge it either way or keep the two apart.
  The sidebar counts them, as they wait for you. Below come the labels of each kind the vocabulary keeps, the most used
  first, each with how many documents have it, and your tags under **Tags**, which are never merged or offered to merge
  without you; open one to merge it into another or remove it everywhere, or to show the documents that have it. **What
  You Decided** lists your rules, each with **Forget**.
- **Tasks**: ask for documents in your own words ([search tasks](how-it-works.md#search-tasks)). Write what you need in
  the field at the top and press **Find**. Below the field, **Read with** sets how the request is read
  ([profile and effort](how-it-works.md#profile-and-effort)): its effort, **Low**, **Medium** or **High**, how much the
  model thinks before it answers, from not at all to the most (the one chosen is what new tasks get, the `taskEffort`
  setting), and its profile, **Settings' Profile**, named after the one Settings uses, whichever that is when the
  request is read, or any profile, each listed with the model that reads with it, such as **Smart (qwen3.5:9b)**. The
  task waits in **In Progress** until the model has read it, its row saying what is happening: **Being read by
  qwen3.5:9b**, with a spinner, **Waiting for its turn** while another request is read first, **Waiting for Ollama**
  while Ollama cannot be reached (it is tried again after the last of `ingest.retryDelays`), or **Waiting to be read**.
  The card that opens when you press **Find** says the same at its top, in place of the documents not found yet:
  **Reading the request with qwen3.5:9b…** beside a spinner, and how long so far once that is more than a moment, as a
  model that thinks can take minutes. While a request is read, or a question about a task's documents answered, Tasks
  in the sidebar has a small spinner, and the menu bar's window says **Reading a request with qwen3.5:9b**, or
  **Answering a question with qwen3.5:9b**, so it shows from any page. Then the task joins the tasks
  under **Earlier**, each with how many documents it found and how often it was exported. Open one as a card: its name,
  which you can change there; what you asked, which you can rewrite, and **Find Again**, which reads it again; the
  effort and profile it is **Read with**, either of which you can change, which reads it again (a profile the settings
  no longer list says so), and which model read it last; what the model looked for; and
  what its documents are **Arranged by**, a kind per level, each with a × to take it away and a + to add one, or to go
  back to what the request asked. Below that, **Documents** and **Conversation** choose what the card shows. Under
  **Documents** come the documents, a heading per group that folds away, and in each group the
  newest by their own date first, those without a date last, each document with a × under the pointer to take it out
  of the set (a double-click opens it). **Add Documents…** shows every processed document as Processed does, under
  the day it was processed, with a + at the end of its row; choose labels in the sidebar to narrow them down, as
  anywhere else, which lists them by their own date; add the documents you want one by one or **Add All With These
  Labels** (as a task finds them: the newest by their own date, at most `tasks.maxDocuments`), and press **Done** to go
  back to the task. **Export** copies the set **To a Folder…** or **As a ZIP Archive…** in a folder you choose, and
  shows it in Finder. Every export is listed on the card, with **Show in Finder** while it is still there. **Remove
  Task…** removes the task and its conversation, never what it exported. Under **Conversation**, ask about the documents
  in the field at the foot and press **Ask** ([talking with a task's
  documents](how-it-works.md#talking-with-a-tasks-documents)). Each question is set apart, its answer below it, as the
  model writes it, with what the queue does with it meanwhile: **Answering with qwen3.5:9b…** beside a spinner and how
  long so far, **Thinking…** while a model that thinks has written nothing yet, or what it waits for: the model to
  begin, its turn, or Ollama, with when it is tried again. Under an answer, **Drawn from** names the documents it drew
  on, one a line, each to open; when you asked for more documents, it lists those it found outside the task, each with
  a + to add it, and **Add All**; **Copy** puts the answer on the clipboard, **Ask Again** answers the question again from
  the documents as they are now, and **Stop**, while it is answered, ends it keeping what came of it. Between questions,
  the changes made to the task's documents since show where they were made. **Clear Conversation…** removes every
  question and answer; the documents stay. While a question about a task is answered, its row says **Answering a
  question**, with a spinner. An event about a task in History opens the task.

Below the lists, the sidebar lists the labels documents have, each with how many of the documents in view have it, the
most used first. They come in one list under **Most Used**, `interface.sidebarLabels` of them, or, with **Group Labels
by Kind** in the bar's menu (`groupLabelsByKind`, `arrumatorcli settings --group-labels-by-kind`), kind by kind
(Senders, Types, Topics and so on, and your Tags last), `interface.sidebarLabelsPerKind` of each, each kind folding
away; **Show More** lists the rest. Each kind has its colour, on its name heading its group and on its labels' tags, so
a label shows its kind in the one list too, your own tags in grey; a label's help names its kind as well. These counts
are the only ones on the sidebar besides those of what waits for you. Click a label and the window shows the documents
that have it under the label as its title, by their own date (the day each was issued, not when it was filed), the
newest first: under a heading for each month, such as **March 2023**, those of one day by name, and those without a date
last, under **No date**. **Show More** at the foot loads more in the same order. The sidebar then lists only the labels
those documents have, so each label clicked next narrows them down further: the documents shown have every label chosen.
Chosen labels come first, as every document shown has them, are marked in the sidebar and head the page; click one
again, or its × on the page, to let go of it, or **Clear** beside them on the page to let go of them all. Letting go of
the last, or choosing a list, shows the lists again. "Show Documents" on a label's menu or card starts from that label
alone. From a terminal, `arrumatorcli labels browse` does the same, listing the documents in the same order.

**Filter Labels**, between the lists and the labels, finds labels: as you type, the sidebar lists only the labels
written with your text in them, every one it finds, whatever their case, accents or punctuation (`tax return` finds the
type `tax-return`), and a language by its English name too. **Clear Filter** below them, or the × in the field, clears
it. It filters the labels the sidebar offers, so with labels chosen, only those of the documents in view.
`arrumatorcli labels browse --matching` does the same.

Only the labels scroll. The lists and **Filter Labels** stay at the top of the sidebar however far the labels are
scrolled, and the bar stays at its foot; the labels scroll between them, and a hairline under the filter shows while
they are scrolled. On the bar's left is the model profile in use, such as **Standard**, to choose another, as
**Profile** in Settings › Models does ([models and profiles](#models-and-profiles)). On its right, the pause button
pauses or resumes filing, and the **…** menu has **Statistics**, **History**, **Group Labels by Kind**, **Open Incoming
Folder**, **Open Archive Folder**, **Switch Archive…** and **Settings…**. While the app is not filing, a line above
them says why, such as **Paused**.

Documents are searched from a terminal, with `arrumatorcli search`. It lists the documents that contain your words
first, then those alike in meaning, such as the same kind of document in another language, most similar first. Words are
looked for in the file name, the text and the labels; `field:word` or `field:"a phrase"` looks in one of them only:
`filename`, `body`, or a kind of label, `sender`, `party`, `type`, `topic`, `object`, `reference`, `date`, `period`,
`deadline`, `amount`, `jurisdiction`, `language` or `tag`. Each field counts as much as its weight in
`search.bm25Weights`, in that order, a tag as much as a sender. A document found by meaning alone must reach
`search.semanticMinSimilarity` (calibrated in [Evaluation › Search](evaluation.md#search)).

### Statistics

**Statistics** is the whole processing funnel, over the last few days (`stats.windowsDays`). It shows how many files
the app took, and how many more wait in Incoming to be taken, how far they got, how many are still being worked on,
where those not filed stopped and why, and how long each step takes. The steps come from
`stats.funnel.steps`: arrived, checked for copies, read, understood, analysed and filed. Every statistic sits under the
step it describes:

- **Read** shows scan quality and the files it could not read.
- **Analysed** shows how many documents are labelled and how many are not yet (one with only its tags is not), how many
  labels the model gave were tidied to the archive's labels or by your rules, how many rules you have, and the labels of
  each kind, tags among them.
- **Filed** shows how many documents you corrected and how many you confirmed.

The funnel is drawn as bars sharing one baseline rather than a tapered funnel, because a funnel encodes values as the
width of a trapezoid: early losses look larger than late ones and the filled areas mean nothing. Data marks use fixed
colours rather than the system accent, which macOS greys out whenever the window is not focused.

## Models and profiles

Settings › Models says where the models run and which models read your documents; onboarding shows its first two
sections. **Ollama** is the server: its status, its address under **Server**, and, on this Mac, whether the app starts
it (**Management**). The server must be this Mac, a private or link-local address, or a `.local` name, such as
`http://192.168.1.20:11434`; anything else is refused (`arrumatorcli settings --ollama-url`). Below it, **Profile**
chooses the model profile documents are read with, and the requests of search tasks without a profile of their own
([profile and effort](how-it-works.md#profile-and-effort)), and lists its three models: the one that **Reads documents
and requests**, and names files, the one that **Describes images** and the one that **Finds by meaning**, each with a
mark when it is installed, or **Download** when it is not. The bar at the foot of the main window's sidebar chooses the
profile in use too.

**Profiles** lists every profile, Fast, Standard and Smart first, each with the model that reads with it, and says which
is in use and which predefined one you changed. Click one to open it in place: change its name, or any of its three
models, typed as Ollama names it or chosen from the installed models that can do the job, each marked installed or with
**Download**. A predefined profile you changed has **Reset**, which gives it back the name and models Arrumator comes
with. A profile of your own has **Remove Profile…**, which removes it unless search tasks of the archive that is open
read with it, and which the profile in use has dimmed, saying to choose another first; documents already read with it
stay as they are. To read documents again with the profile in use, put them into Incoming again, as they are ([exact
copies](how-it-works.md#exact-copies)). Profiles are yours, tasks each archive's: a task of another archive whose
profile you removed fails saying so until you give it another. **New Profile…** adds a profile under the name you give
it, a copy of the one in use, and opens it to give it other models. As a profile says under **Finds by meaning**,
documents embedded by another model are found by meaning only once they are read again. From a terminal,
`arrumatorcli profiles` does all of this, `arrumatorcli settings --profile` chooses the profile in use, and
`arrumatorcli models list` shows what each installed model can do.

## Audit, logs and tuning

- **History**: every arrival (with the tag its folder in Incoming gives it), exact copy (under the document it has read
  again, with where the copy went and the tags it gave), extraction, reading (with the labels it gave, which of the
  model's labels were tidied and why, and what gave its tags), filing, correction of a name or
  labels, decision about labels (a merge, a label removed everywhere, two kept apart, a rule forgotten), confirmation,
  undo, move or rename in Finder, search task (asked, with the effort and profile it is read with, what it found or why
  it could not be read, changed, its effort or profile among it, its set edited, exported, removed), settings change and
  Ollama availability change (`events` table; History view; `arrumatorcli history`). A settings change made in the app
  and one made with `arrumatorcli settings` are recorded alike, once, in words made of what changed (`Changed logLevel
  to debug, renameFiles to false`, with the settings and their new values), and each change to the profiles in its own
  words: `Added the profile “Mine”, reading with qwen3.5:9b`, `The profile “Smart” reads with gpt-oss:20b instead of
  qwen3.5:9b`, `Reset the profile “Smart”`, `Removed the profile “Mine”`, `Reading with the profile “Smart”`. Pausing,
  the Ollama server and switching archives have their own (`Processing paused`, `Ollama at …`, `Switched to the archive
  at …`).
- **Traces**: for every document, each stage's inputs, outputs and timing, including the tags it was given and the
  folder in Incoming or command that gave each (the `tag` step), the exact prompts (with what the model was shown of the
  archive's labels), raw model responses and the labels the `consolidate` step changed ("How was
  this read?"; `arrumatorcli trace <doc> --full`). The prompts and raw answers of a reading, and the raw answer of an
  image description, are kept for Settings › Advanced › "Keep full model prompts" days (`traceRawRetentionDays`, 180 by
  default, or `arrumatorcli settings --trace-retention-days`); after that they are cleared once an hour
  (`maintenance.interval`) and what the reading concluded stays. Every trace is stamped with the models of the profile
  that read. `arrumatorcli replay` reads a document again with another reading model without touching files. A search
  task's request is traced too: what the model was shown and answered (the `interpret` step, with the effort, the model
  that read and what the effort wanted it told about thinking, and with each call what it was sent, `think`) and what
  it found (`match`), with the same retention (`arrumatorcli tasks show <task> --full`).
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

- `settings.json`: your preferences (folders, Ollama server, file renaming and transliteration, notifications, how long
  model prompts are kept in traces, whether the sidebar groups labels by kind, the effort new search tasks are read
  with, `taskEffort`, …), and the model profiles: the one documents are read with, `profile`, by its id, and every
  profile, `modelProfiles`, by its id (`fast`, `standard`, `smart` and yours), each with its `name`, its `position` in
  the list and its three models, `chatModel`, `visionModel` and `embedModel`. The app stores only your changes, in
  `~/Library/Application Support/Arrumator/settings.json`: of a predefined profile only what you changed of it, which
  Reset takes out again, and a profile of your own whole. Change them in Settings, with `arrumatorcli settings`, which
  has an option for every one of them, and with `arrumatorcli profiles`.
- `pipeline.json`: every pipeline tunable, in sections: `ollama` (timeouts, retries, how it is started; `ollama serve`,
  when the app starts it, listens on the address the app talks to, with `ollama.serveEnvironment` besides; how long a
  model stays loaded after its last request, `ollama.keepAlive.chat` for the one that reads and describes images and
  `ollama.keepAlive.embed` for the one that finds by meaning), `watcher`, `records` (the names of the archive's record
  files and of its system and history folders, such as `records.labelRulesFileName`, `records.searchTasksFileName` and
  `records.conversationsFolderName`), `ingest` (attempts and retry delays, and how long quitting waits for the file in
  hand, the request being read and the question being answered to stop, `ingest.quitTimeout`), `extraction` (OCR and
  extraction limits), `entities` (dates and identifiers), `analysis`
  (what the model is shown and how it is asked, such as `analysis.excerptChars`, of which the end of the document gets
  `1 / analysis.excerptTailDivisor`, `analysis.repairAttempts`, the context a document, a search request and an image
  are read with, `analysis.numCtx`, one so that a model that reads and describes images stays loaded once, what a model
  that can think is told before it reads a document or describes an image, `analysis.think`, `false`, and the
  identifiers a document's embedding lists, `analysis.embeddingIdentifiersLimit`), `labels` (`labels.maxPerKind`,
  `labels.maxValueChars`, and `labels.vocabulary`: for each kind kept one vocabulary, never your tags, how alike labels
  must be written to be merged without asking or offered to merge and how many in use the model is shown, and how many
  of your merges and unwanted labels it is shown), `naming`, `search`, `tasks` (search tasks: how much the model thinks
  at each effort, with the budget thinking needs, `tasks.efforts.low`, `tasks.efforts.medium` and `tasks.efforts.high`,
  each giving what a model that can think is told, `think` (`false`, `true` or the name of a level, sent as the model
  allows), how often an invalid answer goes back to it, `repairAttempts`, how long an answer may be and take,
  `numPredict` and `timeout` (an answer that takes longer fails the task), and which labels in use the model is shown of
  each kind, `promptLabels`; how much a request may ask for, `tasks.maxValuesPerKind` and `tasks.maxWords`, how deep a
  set is arranged, `tasks.maxGroupingDepth`, and by what when the request does not say, `tasks.defaultGrouping`, how
  long a task's name from the model may be, `tasks.maxTitleChars`, how many documents a task finds at most, the newest
  by their own date, `tasks.maxDocuments`, and the folder an export puts documents without a label of a level's kind
  into, `tasks.withoutLabelFolder`), `conversation` (the questions about a task's documents: the context an answer is
  asked in, `conversation.numCtx`; how much of the set's text it is shown, `conversation.contextChars`, of one
  document's, `conversation.documentChars`, how many documents it is shown by name alone, `conversation.maxListed`, and
  how much of the conversation so far, `conversation.historyChars`; how long a question may be,
  `conversation.maxQuestionChars`; how many documents found outside the task an answer lists at most,
  `conversation.maxSuggested`; how an answer is sampled, `conversation.sampling`; and at each effort,
  `conversation.efforts.low`, `conversation.efforts.medium` and `conversation.efforts.high`, `think`, `repairAttempts`,
  `numPredict` and `timeout`, as a task's efforts have them), `logging` (with `logging.followInterval`, how often
  `arrumatorcli logs --follow` looks), `power`, `stats` (the periods Statistics offers, and `stats.defaultWindowDays`,
  the one it and `arrumatorcli
  funnel` show first), `interface` (how many rows a page loads, `interface.pageSize`, how many labels the sidebar lists
  in one list, `interface.sidebarLabels`, and of each kind when grouped, `interface.sidebarLabelsPerKind`, how many
  recent events notifications are drawn from, `interface.notificationEvents`, and how much text `arrumatorcli extract`
  prints, `interface.extractPreviewChars`), `maintenance` (how often the app prunes logs, trims traces and looks for
  files `arrumatorcli` queued, `maintenance.interval`) and `database` (how long a write waits for another process using
  the index, `database.busyTimeout`). Override any subset in `~/Library/Application Support/Arrumator/pipeline.json`.

A configuration the app cannot run with stops it with the key and the reason: an empty `ingest.retryDelays`, a negative
`analysis.repairAttempts` or an effort that is not low, medium or high in `pipeline.json`; a `profile` that
`modelProfiles` does not list, two profiles of one name, whatever its case, or a blank name or model in
`settings.json`. So does a key the app does not know, in `settings.json`, `pipeline.json` or the file
`ARRUMATOR_PIPELINE_CONFIG` names (`… is not a key the app knows; remove it`), rather than being ignored: a key an
earlier version wrote, such as `models` in `settings.json`, or `modelProfiles`, or an effort's `model` and `fallback`,
in `pipeline.json`, is never read as something else. Settings the app could not start with are refused before they are
saved, in the app and with `arrumatorcli` alike, and nothing changes.

The app reads both files once, when it starts, and `arrumatorcli` each time it runs. A running app does not see
settings or profiles changed with `arrumatorcli`, or files edited by hand, until it is restarted, and a setting changed
in the app before then writes its own settings over `settings.json`.

Environment variables:

| Variable | Effect |
|---|---|
| `ARRUMATOR_HOME` | Relocates all state: indexes, settings and logs (`$ARRUMATOR_HOME/Logs`). It does not move the archive or Incoming, which `settings.json` names. |
| `ARRUMATOR_OLLAMA_URL` | The Ollama server while set, in place of the setting; this Mac or the local network only. |
| `ARRUMATOR_PIPELINE_CONFIG` | An extra `pipeline.json` override file, applied after yours. |
| `ARRUMATOR_TRASH` | A folder the app and every command use as the Trash: an exact copy, a file undone or a document taken out goes there rather than to yours. For a run in a scratch `ARRUMATOR_HOME`. |
| `ARRUMATOR_LOG_LEVEL` | `error`, `warning`, `info`, `debug` or `trace`, over the setting; any other value stops the app with the reason. |

## Where everything is kept

Everything Arrumator knows that it could not work out again is kept in Markdown files inside the archive, next to what
it describes: a `_documents.md` in every directory holding documents, with each document's labels, and, in the
`System` folder at the top of the archive, the history (`History`, one file per month), your rules for labels
(`_labels.md`), your search tasks with their exports (`_tasks.md`) and the conversations about their documents
(`Conversations`, one file per task).

Each archive has its own SQLite index in `~/Library/Application Support/Arrumator/Indexes`, which only indexes those
files and caches what can be recomputed, such as extracted text and embeddings. If it is lost, damaged or cannot be
migrated, the app rebuilds it from the archive and reads each document's text again in the background; one that is only
locked by another process or on a full disk is left as it is, and the app says why it cannot start. You can edit the
files by hand; the app reads the change back and never overwrites it, not even one it cannot read. The design, and what
a rebuild does and does not keep, is in [Storage](storage.md).

The app is not sandboxed: it watches folders you choose, writes extended attributes, and starts Ollama. It uses the
hardened runtime and makes no network requests other than to your Ollama server.

# Using Arrumator

The app, its settings and the records it keeps of every step. [How Arrumator works](how-it-works.md) explains how
documents are read and filed; [the command line](cli.md) does everything the app does, from a terminal.

## What the app shows you

The window is deliberately quiet, after [Things](https://culturedcode.com/things/). It has a sidebar with five lists,
below them the archive's labels, and a bar at its foot. Each list is one page under a large title, with no dashboards.
Every document row shows at its end what happened to it: nothing when it is filed at the top of the archive, or where
else it is, or waiting for you and why ("Waiting for you: the model gave no valid answer"), a copy an earlier version
filed of another document, or undone and back in Incoming. Rows are reached with the keyboard too (Tab, with keyboard
navigation on in System Settings), and Return or Space opens one. Its date, sender, type and tags, and a few more of its
labels, show beneath it. Clicking a row opens the document in place as a card with its name and its labels, one row for
each kind it has ([labels](how-it-works.md#labels)), and which model read it, or that no text could be taken from it and
the model saw only its name, and any problem it had, with what would help when **Read Again** alone cannot: a copy saved
without its password, or a good copy, put in Incoming. The name can be changed there (a blank one, one cleaning leaves
nothing of and one of the app's own files are refused, saying so), any label taken off with its × or its menu's **Remove
from This Document**, and a label added by choosing its kind and writing its value. A value that is no label of its
kind, such as the type `fatura`, the date `2026-13-45` or the language `klingon`, is said under the field as you write
it, with what the kind takes, and **Add** waits until it is one; Return keeps what you wrote, to correct it. Each change
is recorded in History, in words: "Renamed to …; added sender “EDP”; removed type “invoice”". Dates, deadlines and
periods show as dates, in your Mac's style, a period by its first and last day or month (**1 Jul 2026 – 31 Jul 2026**),
on the card and in the sidebar alike. A label's menu opens it on the Labels page, shows the documents that have it, or
removes it from every document. The card's actions follow the document's state: **Looks Right** confirms it as it is,
after which the card says **Confirmed by you** and when, beside where it is, and no longer offers it until the document
is read again, corrected, or renamed or moved in Finder; **Read Again** has the model read it again, saying it waits to
be read after the files already in Incoming (on Needs You, which the document then leaves for Incoming's queue, the page
says so above the rest, with **Show Incoming**, until you go to another page), **Leave for Later** holds it, and **Undo
Filing** moves it back to Incoming; neither **Leave for Later** nor **Undo Filing** is offered while the document is
still being read in, nor **Read Again** while a file you put into the archive is, and each is once that ends, on the
card as it is. A kind of file Arrumator
cannot read says so, that the model saw only its name, and what would help.

- **Incoming**: under **In Progress**, the file being worked on now, with a spinner and what is being done to it
  (**Reading its text**, **Being read by qwen3.5:9b**, naming the model of the profile in use, …), and, once that has
  taken more than a few seconds, for how long so far, as the first file after a start does while the model loads:
  **Being read by qwen3.5:9b… 1 min, 30 sec so far**; under **Queued**, every other file, in the order they arrived,
  which is the order they are filed in, each saying when it arrived, or, for a file stopped part way (as when you quit
  Arrumator), **Carries on where it stopped**, which it does first at the next start, or the error it had and when it is
  tried again ([how](how-it-works.md#how-a-file-is-handled)); while a file waits for Ollama, which it found away, every
  other says it waits for Ollama too, and when it is tried again, as none is read meanwhile; one that comes is still
  looked at, so an exact copy goes to its original at once. Beneath a file's name,
  after a grey tag symbol, are the tags it will be given, as a document's labels are beneath its own: the name of the
  folder in Incoming it is in, such as **Taxes 2024** for `Incoming/Taxes 2024/scan.pdf` ([folders in
  Incoming](how-it-works.md#folders-in-incoming-and-tags)), and for a document read again the tags it keeps; nothing for
  a file directly in Incoming. An exact copy of a document in the archive leaves for the Trash once it is checked, and
  that document joins the queue to be read again, under its own name ([exact copies](how-it-works.md#exact-copies)).
  Documents read again all at once (**Read All Documents Again**) are not listed one by one: a line above says how many
  are left, **Reading 120 documents of the archive again with the profile in use. New files still come first.**, and the
  one being read shows under **In Progress**. Then comes what was just processed, grouped by day as on Processed, each
  with its labels, its tags among them, with **Show More in Processed** for the rest.
- **Needs You**: documents waiting for you, each with the reason: those the model could not read, or that are
  encrypted, damaged, blank or of a kind of file Arrumator cannot read, and those that could not be filed. The sidebar
  and the menu bar count them. Below them, under **Set Aside by You**, come the documents you left for later or undid
  back into Incoming: they wait for nothing, so nothing counts them; read one again when you want it filed.
- **Processed**: everything finished, newest first and grouped by day, like Things' Logbook.
- **Labels**: the archive's labels as one vocabulary ([how](how-it-works.md#keeping-labels-one-vocabulary)). **Look
  Alike** lists pairs of labels written so alike they may be one; open one to merge it either way or keep the two apart.
  The sidebar counts them, as they wait for you. **What You Decided** comes next, before the labels however many there
  are: your rules, the latest first, each with **Forget**, `interface.pageSize` of them until **Show More** (and **Show
  Fewer** back). Below come the labels of each kind the vocabulary keeps, the most used first, each with how many
  documents have it, and your tags under **Tags**, which are never merged or offered to merge without you; open one to
  merge it into another, written in its field (a value that is no label of its kind is said under it, and **Merge**
  waits), or remove it everywhere, or to show the documents that have it.
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
  back to what the request asked. Below that, **Documents** and **Conversation** choose what the card shows, and the
  card keeps showing the one you chose, also when **Find Again** moves it from **Earlier** to **In Progress**. Under
  **Documents** come the documents, a heading per group that folds away, and in each group the
  newest by their own date first, those without a date last, each document with a × under the pointer to take it out
  of the set (a double-click opens it). **Add Documents…** shows every processed document as Processed does, under
  the day it was processed, with a + at the end of its row, which VoiceOver names with the document ("Add “…” to this
  task"); choose labels in the sidebar to narrow them down, as
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
  question**, with a spinner; while one waits, it says **A question waits to be answered**, or, while Ollama cannot be
  reached, **A question waits for Ollama, tried again at 14:05**, and the menu bar's window says when too. VoiceOver
  reads the row as a button, with what it says. An event about a task in History opens the task.

Below the lists, the sidebar lists the labels documents have, each with how many of the documents in view have it, the
most used first. They come in one list under **Most Used**, `interface.sidebarLabels` of them, or, with **Group Labels
by Kind** in the bar's menu (`groupLabelsByKind`, `arrumatorcli settings --group-labels-by-kind`), kind by kind
(Senders, Types, Topics and so on, and your Tags last), `interface.sidebarLabelsPerKind` of each, each kind folding
away when its name is clicked, as its help says (**Hide Senders**, **Show Senders**); **Show More** lists the rest, and
**Show Fewer** goes back. Each kind has its colour, on its name heading its
group and on its labels' tags, so a label shows its kind in the one list too, your own tags in grey; a label's help
names its kind as well. These counts
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
it. It filters the labels the sidebar offers, so with labels chosen, only those of the documents in view. Tab reaches
it between the lists and the labels, and Edit › **Filter Labels** (Option-Command-F) brings the window forward with the
cursor in it; Escape clears it, then leaves it.
`arrumatorcli labels browse --matching` does the same.

Tab goes on from **Filter Labels** to the labels, with keyboard navigation off as on: the arrow keys move through them,
their kinds' names and **Show More**, Return or Space chooses what is highlighted as a click does, Left and Right fold
and unfold a kind, and Escape goes back to **Filter Labels**. With keyboard navigation on, Tab also reaches each label,
each kind's name, **Show More** and **Clear Filter**, which then shows a focus ring, and the arrow keys move that ring.
VoiceOver names the labels **Labels** and follows the arrow keys; it reads a label as a button with its name and its
count, selected while it is chosen, and each kind's name as a heading, collapsed or expanded.

Only the labels scroll. The lists and **Filter Labels** stay at the top of the sidebar however far the labels are
scrolled, and the bar stays at its foot; the labels scroll between them, and a hairline under the filter shows while
they are scrolled. On the bar's left is the model profile in use, such as **Standard**, to choose another, as
**Profile** in Settings › Models does ([models and profiles](#models-and-profiles)). On its right, the pause button
pauses or resumes filing, and the **…** menu has **Statistics**, **History**, **Group Labels by Kind**, **Open Incoming
Folder**, **Open Archive Folder**, **Switch Archive…** and **Settings…**. While the app is not filing, a line above
them says why, such as **Paused**.

Until Arrumator is set up, nothing in Incoming is taken, and no window says otherwise: the Dock icon, Window ›
Arrumator (Command-0) and **Open Arrumator** in the menu bar's window open the window that sets it up in place of the
main window, the menu bar's window says **Not filing: Arrumator is not set up yet**, and so does Incoming, with **Set Up
Arrumator…**. The menu bar's icon opens a small window of what the app is doing. A full menu bar hides the icon, and
the Dock icon, shown by default, is then the way in; the icon pressed all the same, as through accessibility, brings the
main window forward instead of a window that could not be seen.

Documents are searched from a terminal, with `arrumatorcli search`. It lists the documents that contain your words
first, then those alike in meaning, such as the same kind of document in another language, most similar first. Words are
looked for in the file name, the text and the labels; `field:word` or `field:"a phrase"` looks in one of them only:
`filename`, `body`, or a kind of label, `sender`, `party`, `type`, `topic`, `object`, `reference`, `date`, `period`,
`deadline`, `amount`, `jurisdiction`, `language` or `tag`. Each field counts as much as its weight in
`search.bm25Weights`, in that order, a tag as much as a sender. A document found by meaning alone must reach
`search.semanticMinSimilarity` (calibrated in [Evaluation › Search](evaluation.md#search)). Meaning is compared with
the vectors of the profile's embedding model alone, held in memory: when it cannot be, as while Ollama is away, the
words alone find the documents, and the command says why after the count, such as `(full text: query too short)`.

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

## Folders and notifications

Settings › General, also onboarding's second step, shows Incoming and the archive both as the app uses them: the full
path, with `~` written out. Under **Notifications**, **When a document is filed** and **When a document needs review**
ask macOS to show one; Arrumator asks macOS when you turn one on, or else when the first is due. While a switch is on
and macOS does not let Arrumator notify, because notifications are turned off for it in System Settings ›
Notifications, or because macOS would not let it ask, the switches say so, with **Open Notification Settings**, and
the log says why, rather than nothing being shown without a word.

## Filing and reading again

Settings › Filing: **Rename files** has the model name each document from what it reads, its date, its sender and what
it is, and **Transliterate names to Latin letters** writes a name in another script, such as Cyrillic, in Latin
letters. Under **Reading Again**, **Read All Documents Again…** reads every document of the archive again from its
file, with the profile in use, as you would after choosing another profile: filed documents, those waiting for you and
those set aside after failing, but not those you left for later, nor a file you put into the archive whose first reading,
which filed it where it is, has not ended. It asks first, naming the profile, and says that each
document is renamed and given only the labels this reading finds, also in place of those you corrected, keeping its
tags; then it says how many it queued. Each document is found as it was until it is read, and then its name, labels,
text and meaning are replaced at once, but what you change of it after asking ([reading documents
again](how-it-works.md#reading-documents-again)). New files still come first. Asked again while they wait, it queues
none of them twice. `arrumatorcli review retry --all` does the same.

## Models and profiles

Settings › Models says where the models run and which models read your documents; onboarding shows its first two
sections, a step each (**Connect Ollama**, then **Choose the models**). **Ollama** is the server: its status, its
address under **Server**, and, on this Mac, whether the app starts it (**Management**), with **Start / check Ollama**,
or **Check Ollama** when the app never starts it: a server on another machine, or Management's **Never start it**. The
server must be this Mac, a private or link-local address, or a `.local` name, such as
`http://192.168.1.20:11434`; anything else is refused (`arrumatorcli settings --ollama-url`), as is an address with a
user name or password, a query or a fragment. A `.local` name is looked up when you choose it, waiting at most
`ollama.timeouts.resolve` seconds: one that stands for any address beyond the local network is refused, also beside
local ones, as a machine on a network with IPv6 often has a global address too, which a request to the name may go to
through the router; the refusal says the address to give instead, its IPv4 address on the local network. A name that
does not resolve in time is taken as it is. It is trusted by its name from then on, as each request goes to the name,
and `arrumatorcli doctor` looks it up again, failing when it stands for an address beyond and warning when it does not
resolve. Settings says so below the address, and also warns when documents go to another machine over plain `http`,
unencrypted on the local network; use `https` when the server offers it. Neither is refused. An address saved by an
earlier version that this one refuses stops the app
and every command, saying it is the `ollamaURL` in `settings.json`; `arrumatorcli settings --ollama-url <address>` gives
another, and the app starts again. The app talks to that server alone: through no proxy, whatever the
system's settings, and it follows no redirect the server answers with. Nor does it read with a model the server sends
elsewhere: one of Ollama's cloud models, named so (a tag `cloud` or one ending in `-cloud`, such as
`gpt-oss:120b-cloud`) or described by Ollama as running at another host, as a model made from one is. The app asks the
server where a model runs before it sends it anything, and trusts the answer for `ollama.modelLocationMaxAge` seconds
(60) at most, so a model remade on the server from a cloud model is sent nothing once that has passed; a download of the
model, and a listing of the models or a description of one that says it runs elsewhere, as Settings and the doctor
read, count at once. Nothing is sent to a model that runs elsewhere: what would be read with it fails, naming the model
and where it runs, as the doctor and `arrumatorcli models status` say too. Nor is anything sent to a model whose place
the server does not say: the work waits while the server cannot answer, as when Ollama is away, and fails otherwise.
Below it, **Profile** chooses the model profile documents are read with, and the requests of search tasks without a
profile of their own ([profile and effort](how-it-works.md#profile-and-effort)), and lists its three models: the one
that **Reads documents and requests**, and names files, the one that **Describes images** and the one that **Finds by
meaning**, each with a mark when it is installed, or **Download** when it is not. The bar at the foot of the main
window's sidebar chooses the profile in use too.

**Profiles** lists every profile, Fast, Standard and Smart first, each with the model that reads with it, and says which
is in use and which predefined one you changed; the note under them names those three as Arrumator calls them, however
you renamed them. Click one to open it in place: change its name, or any of its three models, typed as Ollama names it
or chosen from the installed models that can do the job, each marked installed or with **Download**. A predefined
profile you changed has **Reset**, which gives it back the name and models Arrumator comes with. A profile of your own
has **Remove Profile…**, dimmed, saying why under the pointer, while it cannot be removed: while it is the profile in
use (choose another first) and while search tasks of the archive that is open read with it (give them another first);
documents already read with it stay as they are. To read documents again with the profile in use, use **Read All
Documents Again** ([filing and reading again](#filing-and-reading-again)), or put some into Incoming again, as they are
([exact copies](how-it-works.md#exact-copies)). Profiles are yours, tasks each archive's: a
task of another archive whose profile you removed fails saying so until you give it another. **New Profile…** adds a
profile under the name you give it, a copy of the one in use, and opens it to give it other models; a name another
profile has, whatever its case, or one with no letter or digit, is said under the field as you write it, naming that
profile, and **Add** waits. Refusals name a profile by its name, as the app lists it. As a profile says under **Finds
by meaning**, documents embedded by another model are found by meaning only once they are read again. From a terminal,
`arrumatorcli profiles` does all of this, `arrumatorcli settings --profile` chooses the profile in use, and
`arrumatorcli models list` shows what each installed model can do.

## Audit, logs and tuning

- **History**: every arrival (with the tag its folder in Incoming gives it), file in Incoming that cannot be opened,
  exact copy (under the document it has read again, with where the copy went and the tags it gave), a document you ask
  to read again (under it, `Read again: <name>`, when your request queues its reading, as it does in place of its
  turn in reading every document again, or of reading its text again after a rebuild of the index: not while an earlier
  Read Again's, an exact copy's, or its reading in, before that has filed it, waits or is under way),
  every document read again at once (under none, with the profile and the documents, `Read every document again with
  the profile “Standard”: 120 documents`), extraction, reading
  (with the labels it gave, which of the model's labels were tidied and why, and what gave its tags, or that nothing
  could be read of it and why it waits for you), filing (from the name it had to the one it was given, or that it kept
  its name or waits where it is), correction of a name or labels, decision about labels (a merge, a label removed
  everywhere, two kept apart, a rule forgotten), confirmation, undo, move or rename in Finder, the move of each document
  in a folder of yours you rename or move in the archive, a record file that cannot be read and the same file readable
  again, search task (asked, with the effort and profile it is read with, what it found or why it could not be read,
  changed, its effort or profile among it, its set edited, exported, removed), settings change and Ollama availability
  change (`events` table; History view; `arrumatorcli history`). A settings change made in the app and one made with
  `arrumatorcli settings` are recorded alike, once, in words made of what changed (`Changed logLevel to debug,
  renameFiles to false`, with the settings and their new values), and each change to the profiles in its own words:
  `Added the profile “Mine”, reading with qwen3.5:9b`, `The profile “Smart” reads with gpt-oss:20b instead of
  qwen3.5:9b`, `Reset the profile “Smart”`, `Removed the profile “Mine”`, `Reading with the profile “Smart”`, which
  comes first when other settings change with it (`Reading with the profile “Smart”; changed renameFiles to false`).
  Pausing, the Ollama server and switching archives have their own (`Processing paused`, `Ollama at …`, `Switched to the
  archive at …`).
- **Traces**: for every document, each stage's inputs, outputs and timing, including the tags it was given and the
  folder in Incoming or command that gave each (the `tag` step), the exact prompts (with what the model was shown of the
  archive's labels), raw model responses and the labels the `consolidate` step changed ("How was
  this read?"; `arrumatorcli trace <doc> --full`), and, for a document that waits for you, why, in a step of its own
  marked as a warning (`review`). The prompts and raw answers of a reading, and the raw answer of an
  image description, are kept for Settings › Advanced › "Keep full model prompts" days (`traceRawRetentionDays`,
  from 1 to 3650, 180 by default, or `arrumatorcli settings --trace-retention-days`); after that they are cleared once
  an hour (`maintenance.interval`) and what the reading concluded stays. Every trace is stamped with the models of the profile
  that read. `arrumatorcli replay` reads a document again with another reading model without touching files. A search
  task's request is traced too: what the model was shown and answered (the `interpret` step, with the effort, the model
  that read and what the effort wanted it told about thinking, and with each call what it was sent, `think`) and what
  it found (`match`), with the same retention (`arrumatorcli tasks show <task> --full`). Every call to the model is in
  the step, one that failed included, such as the call that found Ollama away. A task or question that waits for Ollama
  keeps one trace, which each attempt takes up again, counting the attempts, rather than one more trace every time it
  is tried; a reading or an answer stopped part way keeps the step that says how far it came.
- **Funnel**: counts, drop-off reasons and timings per step (`arrumatorcli funnel --days 30`).
- **Processing log**: structured JSONL per day in `~/Library/Logs/Arrumator`, readable per funnel step under
  Settings › Processing log, so you can see which step is producing the errors and warnings
  (`arrumatorcli logs --follow`).
- **Statistics**: documents by status, labelled and not yet labelled, labels by kind, corrections and confirmations,
  rules about labels and labels tidied,
  latency per stage, OCR quality and extraction warnings (`arrumatorcli stats`).
- **Diagnostics**: one zip with logs, recent traces, doctor report and settings, for a bug report (Settings › Advanced ›
  **Export diagnostics…**, whose panel opens beside the archive, as a task's export first does). Unless you ask for
  document text, it holds nothing derived from a document or its file: no text or preview, metadata, file name or path,
  identifier, label or question. Each step of a trace keeps its stage, status, start and duration, and each line of a
  log its time, level, category and message, and of its fields only those that never come from a document, such as the
  numbers of a document, job or trace, an attempt, a stage, a duration or a model; a line versions 0.1.1 to 0.1.4
  wrote for a History event, its summary in the message, is left out. Asked for, it holds the traces and logs whole
  (`arrumatorcli diagnostics <zip> [--include-document-text]`). `arrumatorcli trace <doc>` without `--full` likewise
  shows each step's stage, status and duration alone.

## Configuration

No tunable lives in code. Defaults are bundled in `Sources/ArrumatorCore/Resources/Defaults/`:

- `settings.json`: your preferences (folders, Ollama server, file renaming and transliteration, notifications, how long
  model prompts are kept in traces, `traceRawRetentionDays`, from 1 to 3650 days, whether the sidebar groups labels by
  kind, the effort new search tasks are read with, `taskEffort`, …), whether an image is described by the model of the
  profile in use that describes images, `enableVLM` (on; off reads an image by its text alone), the `ollama` program
  the app starts when it is not where Ollama installs it, `ollamaBinaryPath` (unset: it is looked for in
  `ollama.binarySearchPaths`), and the model profiles: the one documents are read with, `profile`, by its id, and every
  profile, `modelProfiles`, by its id (`fast`, `standard`, `smart` and yours), each with its `name`, its `position` in
  the list and its three models, `chatModel`, `visionModel` and `embedModel`. Incoming and the archive,
  `incomingPath` and `archivePath`, are named by full paths, from `/` or `~`, and are two folders, neither inside the
  other, compared as the file system spells them, so a link to a folder or another case of its name is that folder:
  an archive inside Incoming, or Incoming itself, would have every document filed taken in and filed again. The app
  stores only your changes, in `~/Library/Application Support/Arrumator/settings.json`: of a predefined profile only
  what you changed of it, which Reset takes out again, and a profile of your own whole. Change them in Settings, with
  `arrumatorcli settings`, which has an option for every one of them, and with `arrumatorcli profiles`.
- `pipeline.json`: every pipeline tunable, in sections: `ollama` (timeouts, retries, how it is started; `ollama serve`,
  when the app starts it, listens on the address the app talks to, with `ollama.serveEnvironment` besides; how long a
  model stays loaded after its last request, `ollama.keepAlive.chat` for the one that reads and describes images and
  `ollama.keepAlive.embed` for the one that finds by meaning; each of `ollama.timeouts` bounds how long a request may
  wait for more of its answer and, but for a download, how long the whole of it may take, and 0 is no timeout, but
  `ollama.timeouts.resolve`, how long a `.local` name of the server may take to be looked up, more than 0; the most
  bytes one answer may hold, a reply or all the lines of an answer streamed, and one line of a download's progress,
  `ollama.maxResponseBytes`; how long what the server said of where a model runs is trusted,
  `ollama.modelLocationMaxAge`, 0 to ask before every request; how many probes for the server's version in a row must
  come later than `ollama.timeouts.version` before a server that was ready is said to be away,
  `ollama.failedProbesBeforeAway`, at least 1, so a server busy reading that answers one probe late is not, while one
  that refuses the connection, as a server that crashed does, is away at once and started again; how many
  characters of a prompt a token of the model's context is reckoned to hold, `ollama.charsPerToken`, by which a search
  task's request and a question, with what they are shown, are fit to the context they are read in before they are sent,
  and how often one Ollama counts filling that context is fitted again at what it counted and asked again,
  `ollama.refitAttempts`, 0 never), `watcher` (when a file in Incoming or the archive has stopped changing, what is
  never taken in, how long a file that has not stopped changing is waited for before History says it is taking long, as
  it is waited for still, looked at every `watcher.awayPollSeconds`, `watcher.stabilityMaxWaitSeconds`, how long one
  that has stopped changing but cannot be opened is waited for before it is let go and, in Incoming, History says so,
  `watcher.unopenableWaitSeconds`, 0 or more, the most items a package may hold to be one document, in Incoming, in the
  archive or named to `arrumatorcli ingest`, `watcher.maxPackageItems`, at least 1, and how often the archive's folder
  is looked for while it is away, and a file taking long looked at, `watcher.awayPollSeconds`), `records` (the names of
  the archive's record files and of its system and history folders, such as `records.labelRulesFileName`,
  `records.searchTasksFileName` and `records.conversationsFolderName`, and how many minutes after it was last written a
  record file's staged text is taken for one a crash left and removed, `records.stagedLeftoverMinutes`, more than 0),
  `ingest` (attempts and retry delays, also how many starts a change in the archive that cannot be taken in is tried at,
  how often a document whose model is not installed looks again whether it is, `ingest.modelRecheckSeconds`, more than
  0, how long a document waits for a reading given up on that does not stop to end before it fails rather than being
  read again beside it, `ingest.abandonedWorkSeconds`, more than 0, how long an idle worker, of Incoming or of tasks and
  questions, waits at most while another process, as `arrumatorcli` beside the app, holds items of its queue, before it
  looks again whether that process still runs, `ingest.heldElsewhereRecheckSeconds`, more than 0, and how long quitting
  waits for the file in hand, the request being read and the question being answered to stop, `ingest.quitTimeout`,
  after which the `ollama serve` the app started is stopped all the same), `extraction` (OCR and extraction limits, how
  sure the language a text is written in must be guessed, `extraction.languageMinConfidence`, and, for a search request
  or a question of fewer than `extraction.languageShortTextWords` words, which the model is told the language of,
  `extraction.languageShortTextMinConfidence`, among them how much of an e-mail is read, `extraction.emailReadCapBytes`,
  and of its body, `extraction.emailBodyCapBytes`, how many messages deep one with no text of its own is read through
  the messages it forwards, `extraction.emailForwardsRead`, how many pixels an image may declare,
  `extraction.image.maxPixels`, beyond which it is read for its metadata alone, how many pages of a scanned PDF or a
  TIFF OCR reads: all when there are at most `extraction.pdf.ocrAllIfAtMost`, else the first
  `extraction.pdf.ocrHeadPages` and the last (a scanned page's text is what OCR reads of it, as its text layer may be
  glyphs named wrong, and its text layer only where OCR does not read it, fails or reads nothing), of how many pages of
  a PDF the text layer is read, the first `extraction.pdf.textLayerHeadPages` and the last
  `extraction.pdf.textLayerTailPages` (the pages either leaves out are named in a warning), how wide a gap on a line of
  a PDF's text layer parts what stands either side of it, as two columns or a table's cells do, in times the height of
  its letters, `extraction.pdf.columnGap`, more than 0, and what a ZIP file, an archive or an Office document, may hold:
  at most `extraction.zipMaxEntries` entries, each read up to `extraction.zipEntryCapBytes`; an archive, workbook or
  presentation that holds more, whose directory does not match the file or whose entries share bytes of it, is read for
  its metadata alone, and a Word document is still converted by `textutil`, without its title and author), `entities`
  (dates and identifiers: the words that label a document's date,
  its due date and a date of birth, and those after which a number is an account or customer number,
  `entities.accountLabels`, or a policy or contract number, `entities.policyLabels`, with a number sign between as
  `entities.numberSigns` writes it; each is a phrase matched whatever its case, in which a space matches any white
  space, and none at all beside a dot or a sign (`n. º. de cliente` matches `nºcliente`), a dot may be left out, and `*`
  is any one word, at most three of them (`договор * №`); a phrase of `*` alone, or a number sign that holds one, is
  refused by name), `analysis` (what the model is shown and how it is asked, such as `analysis.excerptChars`, of which
  the end of the document gets `1 / analysis.excerptTailDivisor`, `analysis.repairAttempts`, the share of a title's
  words the document must write before it goes back to the model once, `analysis.titleGroundedShare`, the parties a
  reading without a sender names before it goes back asking who issued the document, `analysis.partiesWithoutSender`,
  the context a
  document, a search request and an image are read with, `analysis.numCtx`, one so that a model that reads and
  describes images stays loaded once, what a model that can think is told before it reads a document or describes an image,
  `analysis.think`, `false`, and the identifiers a document's embedding lists, `analysis.embeddingIdentifiersLimit`),
  `labels` (`labels.maxPerKind`, `labels.maxValueChars`, the letters a word needs to say on its own whether the document
  writes a name or a title, `labels.groundingLetters`, the digits a word of an object needs to identify a thing,
  `labels.objectIdentifierDigits`, and `labels.vocabulary`: for each kind kept one vocabulary, never your tags, how
  alike labels must be written to be merged without asking or offered to merge and
  how many in use the model is shown, and how many of your merges and unwanted labels it is shown), `naming` (how long a
  file name may be, `naming.maxChars`, which is also the longest title written as the document writes it when the model
  gives it in capitals, and `naming.maxBytes`, what it may not hold, `naming.forbiddenCharacters`, the suffix of a name
  already taken, `naming.collisionFormat`, and what a reading's name is made of, in order,
  `naming.parts`, of the title and, at most once each, the date and the sender, each but the last followed by its
  separator in `naming.separators`),
  `search`, `tasks` (search tasks: how much the model thinks at each effort, with the budget thinking needs,
  `tasks.efforts.low`, `tasks.efforts.medium` and `tasks.efforts.high`, each giving what a model that can think is told,
  `think` (`false`, `true` or the name of a level, sent as the model allows), how often an invalid answer goes back to
  it, `repairAttempts`, how long an answer may be and take, `numPredict` and `timeout` (an answer that takes longer
  fails the task), and which labels in use the model is shown of each kind, `promptLabels`; how much a request may ask
  for, `tasks.maxValuesPerKind` and `tasks.maxWords`, how many words of a request may stand between a list of
  alternatives a kind's labels quote and a word the model gives, for the word to carry the list on as one more
  alternative rather than a word every document must hold, `tasks.alternativesGap` (0: right next to it; a word between
  two of them is one however far), the letters at the end of a word that may differ while it is the same word
  inflected, which a conversation's request for more documents is told against your question by,
  `tasks.inflectionLetters`, how deep a set is arranged, `tasks.maxGroupingDepth`, and by what when the request
  does not say, `tasks.defaultGrouping`, how long a task's name from the model may be, `tasks.maxTitleChars`, how many
  documents a task finds at most, the newest by their own date, `tasks.maxDocuments`, and the folder an export puts
  documents without a label of a level's kind into, `tasks.withoutLabelFolder`), `conversation` (the questions about a
  task's documents: the context an answer is asked in, `conversation.numCtx`; how much of the set's text it is shown,
  `conversation.contextChars`, of one document's, `conversation.documentChars`, how many documents it is shown by name
  alone, `conversation.maxListed`, and how much of the conversation so far, `conversation.historyChars`; how long a
  question may be, `conversation.maxQuestionChars`; how many documents found outside the task an answer lists at most,
  `conversation.maxSuggested`; how an answer is sampled, `conversation.sampling`; and at each effort,
  `conversation.efforts.low`, `conversation.efforts.medium` and `conversation.efforts.high`, `think`, `repairAttempts`,
  `numPredict` and `timeout`, as a task's efforts have them), `logging` (with `logging.followInterval`, how often
  `arrumatorcli logs --follow` looks), `power`, `stats` (the periods Statistics offers, and `stats.defaultWindowDays`,
  the one it and `arrumatorcli funnel` show first), `interface` (how many rows a page loads, `interface.pageSize`, how
  many labels the sidebar lists in one list, `interface.sidebarLabels`, and of each kind when grouped,
  `interface.sidebarLabelsPerKind`, how many recent events notifications are drawn from, `interface.notificationEvents`,
  how long the app waits for macOS to answer its asking to show notifications, `interface.notificationAskTimeout`,
  how long after starting it says whether its menu bar icon can be seen, `interface.menuBarSettleSeconds`,
  and how much text `arrumatorcli extract` prints, `interface.extractPreviewChars`), `maintenance` (how often the app
  prunes logs, trims traces and looks for files, tasks and questions `arrumatorcli` left in hand when it was killed,
  `maintenance.interval`; what a command queues or changes while the app runs, the app takes up and shows as soon as the
  command commits it) and `database` (how long a write waits for another process using the index,
  `database.busyTimeout`, and how long the app waits before it watches the index again after watching it failed,
  `database.observationRetry`, more than 0) and `settings` (how long a change of `settings.json` waits for another
  process changing it, `settingsLock.timeout`, after which it fails saying so, asking again every
  `settingsLock.pollInterval`). Override any subset in `~/Library/Application Support/Arrumator/pipeline.json`.

A configuration the app cannot run with stops it with the key and the reason: an empty `ingest.retryDelays`, a negative
`analysis.repairAttempts` or an effort that is not low, medium or high in `pipeline.json`, and any value the code that
reads it would crash on, spin on or turn off without a word: an interval of 0 between rounds, such as
`maintenance.interval` or `watcher.stabilityPollInterval`, a negative count of what is shown or kept, such as
`interface.pageSize` or `tasks.efforts.low.promptLabels.sender`, a list of 0 rows, such as `search.resultLimit`, or a
name of a record file that is a path, the same as another or not begun with `watcher.managedFilePrefix`; a `profile`
that `modelProfiles` does not list, two profiles of one name, whatever its case, a blank name or model, Incoming and
the archive one folder or one inside the other, naming both, a folder or `ollamaBinaryPath` given by a partial path,
or a `traceRawRetentionDays` outside 1 to 3650, in `settings.json`. The refusal names the file and how to mend it,
and the app shows it on its main window. Settings an earlier version saved that way, such as Incoming kept inside the
archive or a retention of 5000 days, are mended with `arrumatorcli settings`, which runs whatever the file holds and
refuses only what the values it is given leave unusable, naming it, or in the file itself. An archive named by a
partial path is mended only in the file, and is refused before anything uses it. So does a key the app does
not know, in `settings.json`, `pipeline.json` or the file `ARRUMATOR_PIPELINE_CONFIG` names (`… is not a key the app
knows; remove it`), rather than being ignored: a key an earlier version wrote, such as `models` in `settings.json`, or
`modelProfiles`, or an effort's `model` and `fallback`, in `pipeline.json`, is never read as something else. A refusal
of `pipeline.json` names that file too. Settings the app could not start with are refused before they are
saved, in the app and with `arrumatorcli` alike, and nothing changes.

The app reads `pipeline.json` once, when it starts, and `arrumatorcli` each time it runs. `settings.json` is read again
before every change to it, in the app and by `arrumatorcli` alike, and the change is saved over the file as it is
then, one change at a time across processes (a lock on `settings.json.lock` beside it): a setting or profile changed
with `arrumatorcli` or by hand while the app runs is kept, and the app goes on with it: with a change `arrumatorcli`
saved as soon as it is saved, and with one made by hand from its next change of the settings, or from when it starts
again. A file it cannot read, as one with a key it does not know, is never saved over:
a change is refused, naming why, until the file is corrected. A change is saved with its event in History or not at
all: one History cannot record is not saved, and one saved whose record then cannot be committed is put back. Only a
crash in the moment between the file being saved and the record being committed leaves a change without its event.
Before the archive is read, as during onboarding, the event is held and recorded once the index holds the archive
([Storage](storage.md)).

Environment variables:

| Variable | Effect |
|---|---|
| `ARRUMATOR_HOME` | Relocates all state: indexes, settings and logs (`$ARRUMATOR_HOME/Logs`). It does not move the archive or Incoming, which `settings.json` names. |
| `ARRUMATOR_OLLAMA_URL` | The Ollama server while set, in place of the setting; this Mac or the local network only, and an address that is not stops the app and every command, naming the variable. |
| `ARRUMATOR_PIPELINE_CONFIG` | An extra `pipeline.json` override file, applied after yours. |
| `ARRUMATOR_TRASH` | A folder the app and every command use as the Trash: an exact copy, the file a document was copied from into an archive on another volume, a file undone or a document taken out goes there rather than to yours. For a run in a scratch `ARRUMATOR_HOME`. |
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
locked by another process or on a full disk is left as it is, and the app says why it cannot start. Switching away
from an archive that cannot be written to, as when its disk is gone, still switches; the app says that archive's record
files wait, and they are written when you open it again. You can edit the files by hand; the app reads the change back
and never overwrites it, not even one it cannot read, which `arrumatorcli doctor` names with the reason, History says
once, and the foot of the window says while filing goes on, until it is mended, when what was filed meanwhile is
written into it. An index cannot
be rebuilt without such a file: the app then files nothing, says **Not filing: reading the archive failed** above the
sidebar's bar, shows at the foot of the window that reading the archive failed, with the file and why, and refuses
any change to labels, rules, tasks or questions with the same reason, until the file is corrected or moved out of the
archive and the index rebuilt in Settings › Advanced, which starts the filing again and clears the foot of the
window, or the app opened again. An archive whose folder is not there, renamed, moved or on a disk that is not
connected, is away, at launch or while the app runs: the app says **Not filing: the archive's folder is not there**
above the bar, names the folder at the foot of the window and, above every page, says that the archive is not there,
with the folder's path under it, shortened in the middle when it is long; it makes no folder in its place, files
nothing and writes no
record file, and Incoming waits: nothing in it is read or sent to the model, and a file the app had in hand stops before
its next step. An Incoming folder that is not there is made only in a folder that is, never on a disk not connected or
in the archive's folder while it is away. It looks for the folder every `watcher.awayPollSeconds`, and once the same
folder is back, also on a disk attached again, the work goes on by itself; the app need not be opened again, though
**Try Again** above every page looks at once, and **Choose Another Archive…** switches to another. When the app cannot
start at all, as when its settings cannot be read, the main window says why with **Try Again**, never the window that
sets the app up. The
app makes an archive's folder only when you set the archive up: when you finish onboarding, or switch to a folder that
is not there. A setting you change meanwhile, as during onboarding, is changed, and recorded in History once
the index is rebuilt; a change to labels before the archive has been read is refused, saying it can be made once
Arrumator has read your archive folder. The design, and what a rebuild does and does not keep, is in
[Storage](storage.md).

The app is not sandboxed: it watches folders you choose, writes extended attributes, and starts Ollama. It uses the
hardened runtime and makes no network requests other than to your Ollama server.

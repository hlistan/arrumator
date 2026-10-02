# Command line

`arrumatorcli` does everything the app does, from a terminal, and is how scripts, tests and agents drive Arrumator. It
ships with every [release](https://github.com/hlistan/arrumator/releases/latest) as
`arrumatorcli-<version>-apple-silicon.zip`. Unzip it and run `arrumatorcli` from that folder, or add the folder to your
`PATH`: the command reads its defaults and prompts from the `.bundle` folders beside it, so keep them together, and
don't link to the command from elsewhere. From a clone, `swift run arrumatorcli <command>` runs the current source.

Every command below takes `--json` (print JSON instead of text, where the command reports something) and `--verbose`
(echo log lines to stderr). `arrumatorcli --version` prints the version; `arrumatorcli help <command>` prints a command's
help. `run` and `models pull` always print text, `logs --json` prints each log line as the JSON object it is kept as,
and `eval` writes its JSON report with `--report`.

A command opens the archive named in your settings, and can write that archive's record files and create the
archive's `System` folder. To experiment, set `ARRUMATOR_HOME` to a scratch folder and put a `settings.json` there
whose `incomingPath` and `archivePath` point at scratch folders too: `ARRUMATOR_HOME` alone does not move the archive.

The app reads its settings once, when it starts. While it runs, it does not see settings and model profiles changed
with `settings` or `profiles` until it is restarted, and a setting changed in the app before then writes the app's
settings over theirs; quit it first, or restart it after.

`<document>` is a document's number or its file path.

## Running

| Command | What it does |
|---|---|
| `arrumatorcli doctor` | Check the environment: folders, the archive's index, Ollama, models, disk, network. Exits with 1 when a check fails; Ollama not running is a warning. |
| `arrumatorcli run` | Run headless: watch Incoming and file documents until interrupted, printing the file in hand, its stage and the tags it is given. |
| `arrumatorcli ingest <files>… [--dry-run] [--tag <tag>]…` | File documents now: read, label and name them, and move them to the top of the archive, then show the documents they became, with their tags. An exact copy of a document in the archive becomes none: it goes to the Trash, that document is read again in its place, given the copy's tags, and shown ([exact copies](how-it-works.md#exact-copies)). A file in a folder in Incoming is given the folder's name as a tag, as the app gives it ([folders in Incoming](how-it-works.md#folders-in-incoming-and-tags)); `--tag`, repeatable up to `labels.maxPerKind` times, gives each file a tag of your own besides, such as `--tag "Taxes 2024"`, at most `labels.maxPerKind` tags in all, the folder's first; one with no name is refused. A file the model cannot read yet, as while Ollama is away, is shown with its tags as it waits. `--dry-run` reads and labels without moving files or recording anything, and shows the labels, the tags and what gives each, the name and how the document was read; `--json` gives the tags under `tags`, each with its `source` (`folder` or `command`) and the `folder`. |
| `arrumatorcli settings [--incoming <folder>] [--profile <profile>] [--ollama launchApp\|spawnServe\|external] [--ollama-url <url>] [--paused true\|false] [--show-in-dock true\|false] [--rename-files true\|false] [--transliterate true\|false] [--notify-on-filed true\|false] [--notify-on-review true\|false] [--pause-on-battery true\|false] [--log-level <level>] [--trace-retention-days <days>] [--group-labels-by-kind true\|false] [--task-effort low\|medium\|high]` | Show or change settings, every one Settings in the app changes, each change recorded once in History, in words made of what changed (`Changed logLevel to debug`). `--profile` is the model profile documents are read with, by its id as `profiles` lists it (`fast`, `standard`, `smart` or one of yours), recorded as `Reading with the profile “Smart”`; one the settings do not list is refused and nothing is saved, as are settings the app could not start with. `--ollama-url` must be this Mac or a machine on the local network, such as `http://192.168.1.20:11434`. `--paused` pauses or resumes filing and records it in History, as the app does. `--log-level` is the lowest level logged (error, warning, info, debug, trace); `--trace-retention-days` how long a reading's prompts and raw answers are kept in its trace. `--group-labels-by-kind` lists the sidebar's labels, and those `labels browse` lists, kind by kind rather than in one list, the most used first. `--task-effort` is the effort a new search task is read with when `tasks new` is given none, as the Tasks page's effort picker sets it. Switch archives with `arrumatorcli archive switch`. |

## Models and profiles

A model profile is the models Arrumator reads with: a name and three models, one that reads documents and requests and
names files, one that describes images and one that finds by meaning ([profile and
effort](how-it-works.md#profile-and-effort)). `<profile>` is a profile's id, as `profiles` lists it: `fast`,
`standard` and `smart` come with the app, and a profile of yours gets an id made of its name. Each change is saved in
`settings.json` and recorded once in History, in its own words; `settings --profile` chooses the profile in use.

| Command | What it does |
|---|---|
| `arrumatorcli models [status]` | The profile in use, by name, and whether each of its models is installed, with its size: the one that reads (`chat`), the one that describes images (`vision`) and the one that finds by meaning (`embedding`). |
| `arrumatorcli models list` | Every installed model, its size and what a profile can give it to do: `reads` (documents and requests, as any model that answers in words can), `describes images` (one that also sees them), `finds by meaning` (one that embeds), and whether it thinks: `on or off`, `always`, or at the levels it names, such as `at low, medium, high` ([profile and effort](how-it-works.md#profile-and-effort)). `--json` adds what Ollama lists of it: its capabilities and its thinking values. |
| `arrumatorcli models pull <model>` | Download a model. This needs the internet; recognition never does. |
| `arrumatorcli profiles [list]` | Every model profile, in the order Settings lists them: its id, its name, the models it reads, describes images and finds by meaning with, and whether it is in use, predefined, changed (a predefined one you changed) or yours. |
| `arrumatorcli profiles add <name> [--from <profile>] [--chat-model <model>] [--vision-model <model>] [--embed-model <model>]` | Add a profile of your own called `<name>`, a name no other profile has, whatever its case: a copy of the profile `--from` names, the one in use if not given, with the models given, after every other profile. Its id is made of its name (`My Profile` is `my-profile`, then `my-profile-2` while that is taken), so a name with no letter or digit is refused, as is a blank model. Recorded as `Added the profile “Mine”, reading with qwen3.5:9b`. |
| `arrumatorcli profiles update <profile> [--name <name>] [--chat-model <model>] [--vision-model <model>] [--embed-model <model>]` | Rename a profile or give it other models; give at least one. A predefined profile keeps what you change, and only that is saved, until it is reset. A blank value and a name another profile has are refused. With `--embed-model`, documents read before are found by meaning again only once they are read again. Recorded in words made of what changed: `The profile “Smart” reads with gpt-oss:20b instead of qwen3.5:9b`. |
| `arrumatorcli profiles reset <profile>` | Set a predefined profile back to the name and models the app comes with, so `settings.json` no longer mentions it. A profile of your own has nothing to go back to and is refused. Recorded as `Reset the profile “Smart”`. |
| `arrumatorcli profiles remove <profile>` | Remove a profile of your own. A predefined one is refused, as the app would bring it back, and so are the one Settings reads with and one search tasks of the archive that is open read with, until they are given another (`settings --profile`, `tasks update --profile`). Profiles are yours, tasks each archive's: a task of another archive whose profile is gone fails saying so until it is given another. Documents already read with it stay as they are. Recorded as `Removed the profile “Mine”`. |

## Documents

| Command | What it does |
|---|---|
| `arrumatorcli search <query>… [--no-semantic]` | Search the archive: documents containing the words first, then documents alike in meaning, each with its labels. `field:word` and `field:"a phrase"` search one field: `filename`, `body`, or a kind of label: `sender`, `party`, `type`, `topic`, `object`, `reference`, `date`, `period`, `deadline`, `amount`, `jurisdiction`, `language`, `tag`. `--no-semantic` searches the words only. |
| `arrumatorcli labels [show] <document> [--add <kind>=<value>]… [--remove <kind>=<value>]…` | A document's labels, kind by kind ([the kinds](how-it-works.md#labels)). `--add sender=EDP` gives it a label and `--remove topic=energy` takes one off, both repeatable, each recorded as a correction; a value that is no label of its kind is dropped, and a document keeps one type and one date. `--add tag="Taxes 2024"` gives it a tag of your own, as written. A document the model has not labelled yet says so, beneath its tags if it has any, and `--json` says whether it is labelled (`labelled`); a tag given by hand labels nothing, a label of another kind does. |
| `arrumatorcli labels unlabelled` | Read every document the model has not labelled yet, such as one it gave no answer for, with no labels or only its tags, which also names it again where it is and keeps its tags. |
| `arrumatorcli extract <file>` | Show what the extractors read from a file, with no model involved: its type, language, date, identifiers and warnings, and the first `interface.extractPreviewChars` characters of its text. |
| `arrumatorcli history [--limit <n>] [--doc <document>]` | Recent events: arrivals, readings, filings, corrections (`interface.pageSize` of them unless `--limit`), optionally of one document. |
| `arrumatorcli trace <document> [--full]` | How a document was processed: every stage, its inputs, outputs and timing. `--full` adds the prompts and raw model responses. |
| `arrumatorcli replay <document> [--model <model>]` | Read a stored document again with the reading model of the profile in use, or with `--model` in its place, and compare its name and labels with what it has, without touching files. |

## The archive's labels

What you decide about a label applies to every document that has it and to every document read from then on
([keeping labels one vocabulary](how-it-works.md#keeping-labels-one-vocabulary)). Each decision is recorded in History.
A label is written `<kind>=<value>`, such as `sender="EDP Comercial"`, and matched however it is cased, accented or
punctuated.

| Command | What it does |
|---|---|
| `arrumatorcli labels list [--kind <kind>]` | Every label the documents have, kind by kind, the most used first, with how many documents have it. `--kind` lists one kind. |
| `arrumatorcli labels browse [<kind>=<value>]… [--matching <text>]` | Narrow the documents down by labels, as the app's sidebar does: the documents that have every label given, in the app's order, by their own date (the `date` label, the day each was issued), the newest first, those of one day by name and those without a date last, and the labels those documents have, with how many of them have each, to narrow them further by. The labels are listed as the sidebar lists them: in one list, the most used first, or kind by kind when the `groupLabelsByKind` setting is on. With no label, every document and label. `--matching` lists only the labels written with the text in them, as the sidebar's filter does, whatever their case, accents or punctuation, and a language by its English name too; the documents stay the same. |
| `arrumatorcli labels similar` | Labels written so alike they may be one, each with the label a merge would keep (the one more documents have) and how alike they are, the most alike first. |
| `arrumatorcli labels merge <kind>=<value> --into <value>` | Merge a label into another of its kind: every document that has it gets the other instead, and so does every document read from now on. |
| `arrumatorcli labels ignore <kind>=<value>` | Take a label off every document, and never give it again. |
| `arrumatorcli labels keep-apart <kind>=<value> --from <value>` | Keep two alike labels apart: they are never merged, nor listed by `labels similar`. |
| `arrumatorcli labels rules` | Your rules about labels, oldest first, with their numbers. |
| `arrumatorcli labels forget <rule>` | Forget a rule: documents read from now on no longer follow it. Documents it changed keep their labels. |

## Search tasks

Ask for documents in your own words; the model reads the request and the documents it asks for are found and arranged
by their labels ([search tasks](how-it-works.md#search-tasks)). `<task>` is a task's number, as `tasks list` shows it.
Each change is recorded in History and kept in the archive's `System/_tasks.md`. `new`, `update` and `retry` run the
queue until it is empty, as the app does in the background, unless `--queue-only`.

| Command | What it does |
|---|---|
| `arrumatorcli tasks [list]` | Every search task, the most recently asked first: its state, its effort, the profile that reads it (its own, or `Settings' profile (Standard)`, naming the one Settings uses; one the settings no longer list is named by its id, saying so), how many documents are in its set and how many times it was exported. `--json` gives a task's `profile` by its id, absent for one that follows Settings. |
| `arrumatorcli tasks new <prompt>… [--effort low\|medium\|high] [--profile <profile>] [--queue-only]` | Ask for documents in your own words, such as `tasks new electricity and water bills from 2025, by sender`, and show what the task found, arranged. `--effort` is how much the model thinks before it answers, from not at all (low) to the most (high) ([profile and effort](how-it-works.md#profile-and-effort)), the `taskEffort` setting if not given; `--profile` the model profile whose reading model reads the request, by its id as `profiles` lists it, or, if not given, the one Settings uses when the request is read. A profile the settings do not list is refused, and nothing is asked. `--queue-only` only puts the task in the queue, for the app, `run` or `tasks run` to read. |
| `arrumatorcli tasks show <task> [--full]` | A task: what it asks for, the effort and profile it is read with and which model read it last, the labels and words the model read it as, its documents arranged by their labels (in each group, the newest by their own date first and those without a date last, as on the task's card), those you took out, and every export with where it went. `--full` adds how the request was read: the prompts and the model's raw answers. |
| `arrumatorcli tasks run` | Read every task in the queue now and find its documents, then list the tasks. |
| `arrumatorcli tasks update <task> [--title <name>] [--prompt <prompt>] [--group-by <kinds>\|none\|asked] [--effort low\|medium\|high] [--profile <profile>] [--queue-only]` | Rename a task (`--title ""` gives it the model's name back), arrange its set otherwise (`--group-by sender,date` by sender and then year, `--group-by tag` by your tags, a folder per tag when it is exported, `none` not at all, `asked` as the request asked), or ask it for something else, with another effort or another profile (`--profile ""` gives it back to the one Settings uses), any of which reads it again and finds its documents again. A profile the settings do not list is refused, and nothing changes. `--queue-only` only puts a changed task in the queue. |
| `arrumatorcli tasks retry <task> [--queue-only]` | Find a task's documents again, as after new documents were filed or when the model could not read it. What you added stays, and what you took out stays out. |
| `arrumatorcli tasks add <task> [<document>…] [--label <kind>=<value>]…` | Add documents to a task's set, by number or path, or with `--label`, repeatable, every document in the archive that has all the labels given, such as `--label tag="Taxes 2024"`, as the sidebar narrows them down: at most `tasks.maxDocuments`, the newest by their own date, as a task finds them. |
| `arrumatorcli tasks remove <task> <document>…` | Take documents out of a task's set. Finding its documents again leaves them out. |
| `arrumatorcli tasks export <task> --to <folder> [--zip]` | Copy the set into a new folder named after the task inside `--to`, made if it does not exist and outside the archive and Incoming, a folder per label it is arranged by; `--zip` packs that folder into a ZIP archive instead. Nothing is written over, and the export is recorded with the task. |
| `arrumatorcli tasks delete <task>` | Remove a task, its set and the record of its exports. What it exported stays where it was put. |

## Documents that wait for you

| Command | What it does |
|---|---|
| `arrumatorcli review [list]` | Documents waiting for you, with the reason. |
| `arrumatorcli review confirm <document>` | Confirm a document as it is: its name and labels are right. One waiting for you is filed. This and the commands below print the document as it is afterwards. |
| `arrumatorcli review rename <document> <name>` | Give a document a new file name, without extension (recorded as a correction). |
| `arrumatorcli review retry <document>` | Read a document again with the model, for example after changing models, from the text read of it before: its labels and name. To read its text from its file again too, put a copy of it into Incoming (`ingest`). One in the archive is renamed where it is; one back in Incoming is filed at the top of the archive. |
| `arrumatorcli review hold <document>` | Leave a document where it is for later. |
| `arrumatorcli review undo <document>` | Move a filed document back to Incoming, held there. |

## The archive

| Command | What it does |
|---|---|
| `arrumatorcli archive [show]` | The archive documents are filed into, and its index. |
| `arrumatorcli archive switch <path>` | File into another archive from now on, with its own documents and history. The folder is created if it does not exist; one that was an archive is opened as it was left. |
| `arrumatorcli rebuild` | Rebuild the index from the archive's record files. Changes not yet written to them are written first; documents then have their text read again in the background of the app or `arrumatorcli run`. |

## Insight and diagnostics

| Command | What it does |
|---|---|
| `arrumatorcli funnel [--days <n>]` | How far documents got through the pipeline and where they stopped, for those that arrived in the last `stats.defaultWindowDays` days unless `--days`. |
| `arrumatorcli stats` | How the archive is labelled and where the pipeline spends its time: statuses, labelled documents, labels by kind, corrections and confirmations, rules about labels and labels tidied in readings, latency, OCR quality. |
| `arrumatorcli logs [--category <category>] [--level <level>] [--minutes <n>] [--follow]` | Read the structured logs (JSONL, one file per day). `--category` is one of app, watch, ingest, extract, classify, fileops, ollama, index, search, ui, cli, db, power; `--level` the lowest level shown (error, warning, info, debug, trace; info unless set); `--minutes` only newer lines; `--follow` keeps printing new ones. |
| `arrumatorcli diagnostics <output> [--include-document-text]` | Write a zip with logs, recent traces, doctor report and settings. `--include-document-text` also includes the prompts and model answers that contain document text, and the labels tidied from those answers. |
| `arrumatorcli eval <fixtures> [--model <model>] [--profile <profile>] [--passes <n>] [--only <prefix>] [--report <path>] [--min-accuracy <x>]` | Measure how well documents are read on a fixture corpus (a folder with `expected.json`) in a throw-away archive, as described in [Evaluation](evaluation.md). It also prints, for each kind of label, the share of documents that got one, how many ways each sender was written, and how many different labels of each kind the documents got. It runs in a throw-away home with the settings the app comes with, so it reads with Standard, the profile the app comes set to, and `--profile` reads with another profile the app comes with instead, by its id (`fast`, `smart`): profiles of your own and your changes to the predefined ones are not used. `--model` reads with another model in place of the profile's reading model. `--passes` runs the corpus again to show how consistently it is read; `--only pt/` runs part of it; `--report` writes the full report as JSON; `--min-accuracy` fails when the first pass reads fewer than that share of type, sender, date and title right. |

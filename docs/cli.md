# Command line

`arrumatorcli` does everything the app does, from a terminal, and is how scripts, tests and agents drive Arrumator. It
ships with every [release](https://github.com/hlistan/arrumator/releases/latest) as
`arrumatorcli-<version>-apple-silicon.zip`. Unzip it and run `arrumatorcli` from that folder, or add the folder to your
`PATH`: the command reads its defaults and prompts from the `.bundle` folders beside it, so keep them together, and
don't link to the command from elsewhere. From a clone, `swift run arrumatorcli <command>` runs the current source.

Every command below takes `--json` (print JSON instead of text, where the command reports something) and `--verbose`
(echo log lines to stderr). `arrumatorcli --version` prints the version; `arrumatorcli help <command>` prints a command's
help. `run`, `logs` and `models pull` always print text, and `eval` writes its JSON report with `--report`.

A command opens the archive named in your settings, and can write that archive's record files and create the
archive's `System` folder. To experiment, set `ARRUMATOR_HOME` to a scratch folder and put a `settings.json` there
whose `incomingPath` and `archivePath` point at scratch folders too: `ARRUMATOR_HOME` alone does not move the archive.

`<document>` is a document's number or its file path. Sender numbers come from `arrumatorcli senders`.

## Running

| Command | What it does |
|---|---|
| `arrumatorcli doctor` | Check the environment: folders, database, Ollama, models, disk, network. Exits with 1 when a check fails. |
| `arrumatorcli run` | Run headless: watch Incoming and file documents until interrupted. |
| `arrumatorcli ingest <files>… [--dry-run]` | File documents now: read, label and name them, and move them to the top of the archive. `--dry-run` reads and labels without moving files or recording anything, and shows the labels, the name and how the document was read. |
| `arrumatorcli settings [--incoming <folder>] [--profile <profile>] [--ollama launchApp\|spawnServe\|external] [--ollama-url <url>] [--paused true\|false]` | Show or change settings. `--profile` is a model profile from `pipeline.json` (`standard`, `balanced`, `lowMemory`); `--ollama-url` must be this Mac or a machine on the local network, such as `http://192.168.1.20:11434`. Switch archives with `arrumatorcli archive switch`. |
| `arrumatorcli models [status]` | Status of the configured models. |
| `arrumatorcli models pull <model>` | Download a model. This needs the internet; recognition never does. |

## Documents

| Command | What it does |
|---|---|
| `arrumatorcli search <query>… [--no-semantic]` | Search the archive: documents containing the words first, then documents alike in meaning, each with its labels. `field:word` and `field:"a phrase"` search one field: `title`, `correspondent`, `filename`, `body`, `subject`, `object`, `jurisdiction` or `language`. `--no-semantic` searches the words only. |
| `arrumatorcli labels <document>` / `arrumatorcli labels --unlabelled` | A document's labels by kind: whom and what it concerns, its jurisdictions and languages. `--unlabelled` reads every document that has none yet with the model, such as those filed by an earlier version, which also names them again where they are. |
| `arrumatorcli extract <file>` | Show what the extractors read from a file, with no model involved. |
| `arrumatorcli history [--limit <n>] [--doc <document>]` | Recent events: arrivals, readings, filings, corrections, what was learned (50 unless `--limit`), optionally of one document. |
| `arrumatorcli trace <document> [--full]` | How a document was processed: every stage, its inputs, outputs and timing. `--full` adds the prompts and raw model responses. |
| `arrumatorcli replay <document> [--model <model>]` | Read a stored document again with the model, optionally another chat model, and compare its name and labels with what it has, without touching files. |

## Documents that wait for you

| Command | What it does |
|---|---|
| `arrumatorcli review [list]` | Documents waiting for you, with the reason. |
| `arrumatorcli review confirm <document>` | Confirm a document as it is: its name, details and labels are right. One waiting for you is filed. |
| `arrumatorcli review rename <document> <name>` | Give a document a new file name, without extension (recorded as a correction). |
| `arrumatorcli review retry <document>` | Read a document again with the model, for example after changing models: its labels, details and name. One in the archive is renamed where it is; one back in Incoming is filed at the top of the archive. |
| `arrumatorcli review hold <document>` | Leave a document where it is for later. |
| `arrumatorcli review undo <document>` | Move a filed document back to Incoming and forget what it taught about its sender. |

## What the app learned

| Command | What it does |
|---|---|
| `arrumatorcli senders` | Senders the app has learned: names, other names and the identifiers that recognise them. |
| `arrumatorcli forget alias <sender> <alias>` | Forget another name taught for a sender. |
| `arrumatorcli forget sender <sender>` | Forget everything known about a sender; its documents keep the name they were filed under. |

## The archive

| Command | What it does |
|---|---|
| `arrumatorcli archive [show]` | The archive documents are filed into, and its index. |
| `arrumatorcli archive switch <path>` | File into another archive from now on, with its own senders and history. The folder is created if it does not exist; one that was an archive is opened as it was left. |
| `arrumatorcli rebuild` | Rebuild the index from the archive's record files. Changes not yet written to them are written first; documents then have their text read again in the background of the app or `arrumatorcli run`. |

## Insight and diagnostics

| Command | What it does |
|---|---|
| `arrumatorcli funnel [--days <n>]` | How far documents got through the pipeline and where they stopped, for those that arrived in the last 30 days unless `--days`. |
| `arrumatorcli stats` | How the archive is labelled and where the pipeline spends its time: statuses, labelled documents, labels by kind, corrections, latency, OCR quality. |
| `arrumatorcli logs [--category <category>] [--level <level>] [--minutes <n>] [--follow]` | Read the structured logs (JSONL, one file per day). `--category` is one of app, watch, ingest, extract, classify, fileops, ollama, index, search, learn, ui, cli, db, power; `--level` the lowest level shown (error, warning, info, debug, trace; info unless set); `--minutes` only newer lines; `--follow` keeps printing new ones. |
| `arrumatorcli diagnostics <output> [--include-document-text]` | Write a zip with logs, recent traces, doctor report and settings. `--include-document-text` also includes the prompts and model answers that contain document text. |
| `arrumatorcli eval <fixtures> [--model <model>] [--profile <profile>] [--passes <n>] [--only <prefix>] [--report <path>] [--min-accuracy <x>]` | Measure how well documents are read on a fixture corpus (a folder with `expected.json`) in a throw-away archive, as described in [Evaluation](evaluation.md). `--passes` runs the corpus again to show what was learned about senders; `--only pt/` runs part of it; `--report` writes the full report as JSON; `--min-accuracy` fails when the first pass reads fewer than that share of details right. |

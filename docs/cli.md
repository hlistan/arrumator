# Command line

`arrumator` does everything the app does, from a terminal, and is how scripts, tests and agents drive Arrumator. It
ships with every [release](https://github.com/hlistan/arrumator/releases/latest) as
`arrumator-<version>-macos-arm64.zip`. Unzip it and run `arrumator` from that folder, or add the folder to your
`PATH`: the command reads its defaults and prompts from the `.bundle` folders beside it, so keep them together, and
don't link to the command from elsewhere. From a clone, `swift run arrumator <command>` runs the current source.

Every command below takes `--json` (print JSON instead of text, where the command reports something) and `--verbose`
(echo log lines to stderr). `arrumator --version` prints the version; `arrumator help <command>` prints a command's
help. `run`, `logs` and `models pull` always print text, and `eval` writes its JSON report with `--report`.

A command opens the archive named in your settings, and can write that archive's record files and create the
archive's `System` folder. To experiment, set `ARRUMATOR_HOME` to a scratch folder and put a `settings.json` there
whose `incomingPath` and `archivePath` point at scratch folders too: `ARRUMATOR_HOME` alone does not move the archive.

`<document>` is a document's number or its file path. Numbers of senders, rules, proposals and plan items come from
the listing commands (`senders`, `rules`, `proposals`, `rethink plan`).

## Running

| Command | What it does |
|---|---|
| `arrumator doctor` | Check the environment: folders, database, Ollama, models, disk, network. Exits with 1 when a check fails. |
| `arrumator run` | Run headless: watch Incoming and file documents until interrupted. |
| `arrumator ingest <files>… [--dry-run]` | File documents now (moves them into the archive). `--dry-run` analyses and decides without moving files or recording a decision. |
| `arrumator settings [--incoming <folder>] [--profile <profile>] [--folder-language <language>] [--auto-create-folders true\|false] [--ollama launchApp\|spawnServe\|external] [--ollama-url <url>] [--paused true\|false]` | Show or change settings. `--profile` is a model profile from `pipeline.json` (`standard`, `balanced`, `lowMemory`); `--ollama-url` must be this Mac or a machine on the local network, such as `http://192.168.1.20:11434`. Switch archives with `arrumator archive switch`. |
| `arrumator models [status]` | Status of the configured models. |
| `arrumator models pull <model>` | Download a model. This needs the internet; recognition never does. |

## Documents

| Command | What it does |
|---|---|
| `arrumator search <query>… [--no-semantic]` | Search the archive: documents containing the words first, then documents alike in meaning. `--no-semantic` searches the words only. |
| `arrumator extract <file>` | Show what the extractors read from a file, with no model decisions. |
| `arrumator history [--limit <n>] [--doc <document>]` | Recent events: arrivals, filings, corrections, rules, folders (50 unless `--limit`), optionally of one document. |
| `arrumator trace <document> [--full]` | How a document was processed: every stage, its inputs, outputs and timing. `--full` adds the prompts and raw model responses. |
| `arrumator replay <document> [--model <model>]` | Ask the model again about a stored document, from the archive's logic and optionally with another chat model, without touching files. |

## Reviewing and correcting

| Command | What it does |
|---|---|
| `arrumator review [list]` | Documents waiting for a decision. |
| `arrumator review approve <document>` | Accept the proposed folder, creating it if it is new. |
| `arrumator review move <document> <folder>` | Move a document to a folder, given by its code such as `F12` (recorded as a correction). |
| `arrumator review rename <document> <name>` | Give a document a new file name, without extension (recorded as a correction). |
| `arrumator review undo <document>` | Move a filed document back to Incoming and forget what was learned from it. |
| `arrumator review retry <document>` | Decide again, for example after changing models, and file. |
| `arrumator review hold <document>` | Leave a document where it is for later. |
| `arrumator review mark-correct <document>` | Confirm an automatic filing was right. |
| `arrumator folders [tree]` | The folder tree as it has grown. |
| `arrumator folders create --path <path> --description <text> [--yearly]` | Create a folder at any depth, with the folders above it that do not exist yet. `--path` is folder names from the top of the archive separated by `/`, such as `"Portugal/Acme Lda/Banking"`; `--description` says what belongs in the last one; `--yearly` splits it into year folders. |

## What the app learned

| Command | What it does |
|---|---|
| `arrumator rules [list]` | Rules learned from use. |
| `arrumator rules enable <id>` | Switch a rule on. |
| `arrumator rules disable <id>` | Switch a rule off; it stays off until you switch it on. |
| `arrumator senders` | Senders the app has learned: names, identifiers and usual folders. |
| `arrumator proposals [list]` | Improvements the app suggests: folder descriptions and rules. |
| `arrumator proposals accept <id>` | Accept a suggestion. |
| `arrumator proposals reject <id>` | Dismiss a suggestion. |
| `arrumator forget example <document>` | Stop using a document as an example of where documents like it go. |
| `arrumator forget rule <id>` | Forget a rule; it does not form again from the same filings. |
| `arrumator forget alias <sender> <alias>` | Forget another name taught for a sender. |
| `arrumator forget sender <sender>` | Forget everything known about a sender, and the rules about it. |

## The archive and its logic

| Command | What it does |
|---|---|
| `arrumator archive [show]` | The archive documents are filed into, its index and its logic file. |
| `arrumator archive switch <path>` | File into another archive from now on, with its own logic. The folder is created if it does not exist; a folder never used as an archive starts with the built-in logic, and one that was is opened as it was left. |
| `arrumator logic [show]` | The archive's logic: the prompt the model follows when it decides where documents go and what they are called. |
| `arrumator logic edit --file <file>` | Replace the logic with a prompt from a file (Markdown or plain text). Try it with `arrumator rethink start --trial`, then reprocess with `arrumator rethink start`. |
| `arrumator logic reset` | Restore the logic that ships with Arrumator. |
| `arrumator rethink [status]` | Where the latest rethink stands. |
| `arrumator rethink start [--trial] [--include-user-placed] [--now]` | Decide processed documents again from the logic. `--trial` takes only a few documents from across the archive; `--include-user-placed` also takes documents you placed or confirmed yourself; `--now` plans every document in this process instead of in the app or `arrumator run`. |
| `arrumator rethink plan [--all]` | List what the rethink would change; `--all` also lists documents that stay where they are. |
| `arrumator rethink stop` | Stop planning early: what has been decided becomes the plan; the rest stay where they are. |
| `arrumator rethink keep <item> [--undo]` | Leave one document where it is when the plan is applied, or with `--undo` move it after all. |
| `arrumator rethink apply` | Apply the plan: move the documents, create the folders, remove the folders left empty. |
| `arrumator rethink discard` | Throw the plan away. |
| `arrumator rebuild` | Rebuild the index from the archive's record files. Changes not yet written to them are written first; documents then have their text read again in the background of the app or `arrumator run`. |

## Insight and diagnostics

| Command | What it does |
|---|---|
| `arrumator funnel [--days <n>]` | How far documents got through the pipeline and where they stopped, for those that arrived in the last 30 days unless `--days`. |
| `arrumator stats` | Where the pipeline needs tuning: accuracy, confusions, calibration, latency. |
| `arrumator logs [--category <category>] [--level <level>] [--minutes <n>] [--follow]` | Read the structured logs (JSONL, one file per day). `--category` is one of app, watch, ingest, extract, classify, fileops, ollama, index, search, taxonomy, learn, ui, cli, db, power; `--level` the lowest level shown (error, warning, info, debug, trace; info unless set); `--minutes` only newer lines; `--follow` keeps printing new ones. |
| `arrumator diagnostics <output> [--include-document-text]` | Write a zip with logs, recent traces, doctor report, settings and folder tree. `--include-document-text` also includes prompts that contain document text. |
| `arrumator eval <fixtures> [--model <model>] [--profile <profile>] [--passes <n>] [--logic <file>] [--only <prefix>] [--report <path>] [--min-f1 <x>] [--feedback]` | Measure placement quality on a fixture corpus (a folder with `expected.json`) in a throw-away archive, as described in [Evaluation](evaluation.md). `--passes` runs the corpus again to show what was learned; `--only pt/` runs part of it; `--logic` files by another logic; `--report` writes the full report as JSON; `--min-f1` fails below that grouping F1; `--feedback` simulates a user who confirms consistent placements and moves inconsistent ones. |

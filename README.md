# Arrumator

[![Release](https://github.com/hlistan/arrumator/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/hlistan/arrumator/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/hlistan/arrumator)](https://github.com/hlistan/arrumator/releases/latest)
[![macOS 26](https://img.shields.io/badge/macOS-26-lightgrey?logo=apple)](#requirements)
[![License: MIT](https://img.shields.io/github/license/hlistan/arrumator)](LICENSE)

**A macOS menu-bar app that files your documents for you, entirely on your Mac.**

Drop any file into your Incoming folder: a PDF, a scan, a photo, a screenshot, a Word, Excel or PowerPoint file, an
e-mail, plain text. Arrumator reads it, labels it with what it is about, gives it a name that says what it is, files it
into your archive and indexes it for search. There are no folders to keep in order: a document is described by its labels
alone, and you find it by them, its words or its meaning. A document can be in any language and any script: its labels
say what it is in one vocabulary, so a German electricity bill and a Japanese one are both `type:invoice`,
`topic:electricity`.

- [Features](#features)
- [Privacy](#privacy)
- [Requirements](#requirements)
- [Install](#install)
- [Getting started](#getting-started)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)

## Features

- **Reads anything**: PDF text, Apple Vision OCR for scans and photos, Office files, e-mail, archives, and a local
  vision model for photos without text. It finds the language, dates, and identifiers such as IBANs and tax numbers.
- **Describes every document by labels.** The local model reads each document once, with a prompt made for this, and
  picks out who sent it, what type it is, its date, whom and what it concerns, its topics, references, period,
  deadlines, amounts, jurisdictions and languages: twelve kinds of label, drawn from archival metadata standards. A
  thirteenth, `tag`, is yours alone. Browse by them in the sidebar, which lists them with how many documents have each,
  the most used first, in one list or kind by kind, each kind in its colour, and finds any of them as you type. Each
  label you choose narrows the documents and the labels left to choose. Search by any of them from a terminal
  (`sender:edp`, `deadline:2026-07`, `jurisdiction:portugal`, `tag:"taxes 2024"`) and correct any of them.
- **Tags documents by the folder you drop them in.** Put a folder such as `Taxes 2024` into Incoming, and everything in
  it, at any depth, is filed with `Taxes 2024` as a tag of yours beside the labels the model gives. Incoming shows the
  tag under each file before it is read, and the folder stays where it is, for whatever you put there next.
- **Reads a document again when you put it in again, or every document at once.** An exact copy of a document already
  in the archive, put into Incoming, is no second document: that document is read again from the start, from its file,
  with the profile in use. It is found as it was until it is read; then its name, labels, text and meaning take the
  place of those it had, all at once, keeping its tags and given that of the folder you put the copy in. The copy goes
  to the Trash. **Read All Documents Again**, under Settings › Filing, does the same for the whole archive, after the
  files that arrive meanwhile: what a new profile, or a better Arrumator, is for.
- **Keeps labels one vocabulary, and learns from you.** A label written the way the archive already writes it becomes
  that label, and labels that merely look alike are judged by the local model: one label written two ways is merged
  into the one more documents have, two different ones are kept apart, without asking you. On the Labels page, rename a
  label, merge two, remove one from every document, once or for good, or add a tag of your own; every document, and
  every one read from then on, follows: the model is shown your decisions and the archive's labels each time it reads.
- **Keeps what it read beside each document.** Next to every document in the archive is a Markdown file named after it,
  `….pdf.arrumator.md`, with what the model says the document is, in a few sentences in its own language, and its text
  as it was recognised, by OCR or from the file. A photo is described by what it shows, its text kept as OCR read it.
  Spotlight and any text editor read it without the app, and the app's search finds a document by those words too.
- **Names every file** from its date, its sender and what it is, such as `2026-07-05 EDP Comercial - Fatura
  eletricidade julho.pdf`, and files it at the top of the archive. The app makes no folders.
- **Finds documents you describe.** Ask in your own words, in any language, for the documents you need ("electricity
  and water bills from 2025, by sender"). The local model turns the request into labels to look for; the documents are
  found and arranged by their labels, a level per kind. Choose the effort each request is read with, Low, Medium or
  High, which is how much the model thinks before it answers, and the model profile that reads it: the one Settings
  uses, or another, such as Smart, whose model thinks. Take any out or add more, as the sidebar narrows them down, and
  export them into folders by those labels, or as a ZIP archive. Every task and export is kept, to open again.
- **Talks with the documents a task found.** Ask about them in your own words, in any language: summarize them,
  translate one, compare them, draft a brief or an e-mail from them, or find the amounts, dates and obligations in them.
  The local model answers from the documents in the task, the answer appearing as it is written, and names the
  documents it drew on. Add documents to the task or take them out, and the next answer sees the set as it is then. Ask
  it to find more, and it looks for them as a task does, listing what it found outside the task for you to add. Every
  conversation is kept in the archive beside its task.
- **Asks when it cannot read a document.** A file the model gave no answer for, or that is encrypted, damaged or
  blank, waits in Needs You, in the archive, instead of being guessed into shape.
- **Everything can be audited**: the prompts, the model's answers, timings and a full history, with Statistics
  showing where documents stop and why.
- **Nothing is lost.** No code path deletes a document: one you remove goes to the Trash, from which you can take it
  back. Every move is recorded and can be undone. Every document's labels
  live in Markdown files inside your archive, and its index can be rebuilt from them.
- **A command line tool**, `arrumatorcli`, does everything the app does, with `--json` output for scripts.

## Privacy

Recognition uses only local models through [Ollama](https://ollama.com), on this Mac or on a machine of yours on the
local network. The server's address must be this Mac, a private or link-local address, or a `.local` name; anything
else is refused. Every network request goes through a guard that lets only that one server through. The internet is
used only when *you* press Download for a model, and then by Ollama, not by Arrumator. There is no telemetry, crash
reporting or update check.

## Requirements

- macOS 26 or later. The app comes for Apple silicon and as a universal build that also runs on Intel Macs; the
  command line tool is built for Apple silicon.
- [Ollama](https://ollama.com), on this Mac or on your local network, with the models of one profile. Arrumator
  starts Ollama when needed and downloads the models when you ask.

| Profile | Reads documents and requests, describes images, names files | Finds by meaning | Memory |
|---|---|---|---|
| Fast | `gemma4:e2b-it-qat` | `bge-m3` | ~5.5 GB |
| Standard (default) | `ministral-3:14b` | `bge-m3` | ~10 GB |
| Smart | `qwen3.5:9b-q8_0` | `bge-m3` | ~10.4 GB, with the app's context, as Standard's ~10 GB is ~10.6 GB |

A model profile is the models Arrumator reads with: in each of these, one model reads every document and search request,
describes images and names files, and `bge-m3` finds documents by meaning. Choose one under [Settings ›
Models](docs/using-arrumator.md#models-and-profiles), where you can also give any of them other models, set them back
with Reset, or add profiles of your own. Smart's model thinks before it answers, which a search task's effort uses;
documents are read without thinking. Documents already read keep their labels when you choose another profile: **Read
All Documents Again**, under Settings › Filing, reads them with it, as putting one into Incoming again, as it is, does.
Fast and Standard were chosen as the best for their memory on a 16 GB Mac mini (M5) when Arrumator still filed documents
into folders, and larger models do not fit such a Mac's memory. How well each profile labels documents is measured:
Fast reads a document in about a quarter of Standard's time and finds fewer of the labels a document should get (69%
against 96%). Smart reads with the model that scores highest on its benchmarks of those such a Mac holds whole, in 8
bits: it reads a document's type as well as Standard and finds a little fewer of the labels it should get (94%).
The measurements are in [docs/evaluation.md](docs/evaluation.md).

## Install

1. Download the app from the [latest release](https://github.com/hlistan/arrumator/releases/latest):
   `Arrumator-<version>-apple-silicon.zip` for a Mac with Apple silicon (M1 or later), or
   `Arrumator-<version>-universal.zip`, which runs on Apple silicon and Intel Macs alike. Unzip it and move
   **Arrumator** to Applications.
2. Open it. If the release is not notarized (its notes say so), macOS blocks it the first time. Choose **Done**,
   then open System Settings › Privacy & Security, click **Open Anyway** next to the message about Arrumator, and
   confirm ([Apple Support: open an app from an unknown developer](https://support.apple.com/en-us/102445)).
3. Onboarding asks for your Incoming and Archive folders, then for the models. Install [Ollama](https://ollama.com)
   if you haven't: Arrumator starts it when needed. Choose a profile (Standard unless you choose another) and download
   its models with the Download button beside each, there or later under Settings › Models; `arrumatorcli doctor`
   confirms everything is in place.

To check a download, compare it with the release's checksums (`shasum -a 256 -c SHA256SUMS`) or verify where it was
built (`gh attestation verify <file> --repo hlistan/arrumator`).

The command line tool is in `arrumatorcli-<version>-apple-silicon.zip` in the same release. Unzip it and keep the folder
together; [docs/cli.md](docs/cli.md) explains how to use it. To build from source instead, see
[CONTRIBUTING.md](CONTRIBUTING.md).

## Getting started

1. Put a document in `~/Documents/Incoming` (Settings › General changes both folders), or a folder of them: its name
   becomes a tag of every document in it.
2. Arrumator reads it, names it and files it at the top of `~/Documents/Archive`, and shows it in **Processed**.
3. Open the document's row to see its labels, what it is and how it was read, and **Recognised Text** for its text.
   Rename it, or take off or add a label, on its card if something is wrong, or move it to the Trash. On **Labels**,
   rename a label, merge labels that mean the same, remove one, or add a tag of your own.
4. Documents it could not read wait in **Needs You**. Confirm them as they are, or have them read again.
5. Click a label in the sidebar, such as a sender, to see only its documents; the sidebar then lists only the labels
   those documents have, so a second click, such as a type, narrows them down further, and **Clear** at the top of the
   page lets go of them all. Type in **Filter Labels**, above the labels, to find one.
6. On **Tasks**, ask for the documents you need in your own words, with how much the model thinks and the profile
   that reads the request under **Read with**, look over what is found, add or take out any, and export them into
   folders by their labels (`arrumatorcli tasks new …` from a terminal). Under **Conversation** on the task's card, ask
   about them: summarize, translate or compare them, or draft an e-mail from them (`arrumatorcli tasks ask …`).
7. Search documents by any word, or by a kind of label, with `arrumatorcli search`: `sender:edp`,
   `party:"maria silva"`, `type:invoice`, `language:russian`.

## Documentation

| Document | Read it for |
|---|---|
| [How Arrumator works](docs/how-it-works.md) | How a document is read, labelled and filed, and the kinds of label. |
| [Using Arrumator](docs/using-arrumator.md) | The app's pages, settings and environment variables, the audit trail, where your data lives. |
| [Command line](docs/cli.md) | Every `arrumatorcli` command and option. |
| [Storage](docs/storage.md) | The archive's record files, the index, and what a rebuild keeps. |
| [Evaluation](docs/evaluation.md) | The measurements behind the pipeline and the model profiles. |
| [Sources](docs/organizing-principles-sources.md) | The research behind the kinds of label and how the model is asked. |
| [Continuous integration and releases](docs/releasing.md) | How changes are checked and released, and how to sign releases. |
| [QA protocol](docs/qa/protocol.md) | How the app is tested end to end, as a user meets it. |
| [Architecture](docs/architecture.md) | How the code is arranged: modules, what happens at run time, concurrency, and the decisions behind them. |
| [Code review](docs/review/code-review.md) | How a change is reviewed, with [what to check in Swift and on Apple's platforms](docs/review/swift-apple.md). |

## Contributing

Contributions are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) explains how to set up, build, test and check a
change. [AGENTS.md](AGENTS.md) holds the engineering rules every change follows, whether a person or a coding agent
makes it. Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md). Report security problems
privately, as [SECURITY.md](SECURITY.md) describes.

## License

[MIT](LICENSE)

Arrumator includes open-source packages under the MIT and Apache 2.0 licences. Their licence texts ship with every
download, in `NOTICES.txt`: inside the app (`Arrumator.app/Contents/Resources`) and beside `arrumatorcli`.

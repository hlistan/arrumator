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
- **Describes every document by labels.** The local model reads each document once, with a prompt made for this,
  and picks out who sent it, what type it is, its date, whom and what it concerns, its topics, references, period,
  deadlines, amounts, jurisdictions and languages: twelve kinds of label, drawn from archival metadata standards.
  Browse by them in the sidebar, which lists them with how many documents have each, the most used first, in one list or
  kind by kind, each kind in its colour, and finds any of them as you type. Each label you choose narrows the documents
  and the labels left to choose. Search by any of them from a terminal (`sender:edp`, `deadline:2026-07`,
  `jurisdiction:portugal`) and correct any of them.
- **Keeps labels one vocabulary, and learns from you.** A label written the way the archive already writes it becomes
  that label, and labels that merely look alike wait for you on the Labels page. Merge two labels or remove one
  everywhere, and every document, and every one read from then on, follows: the model is shown your decisions and the
  archive's labels each time it reads.
- **Names every file** from its date, its sender and what it is, such as `2026-07-05 EDP Comercial - Fatura
  eletricidade julho.pdf`, and files it at the top of the archive. The app makes no folders.
- **Asks when it cannot read a document.** A file the model gave no answer for, or that is encrypted, damaged or
  blank, waits in Needs You, in the archive, instead of being guessed into shape.
- **Everything can be audited**: the prompts, the model's answers, timings and a full history, with Statistics
  showing where documents stop and why.
- **Nothing is lost.** No code path deletes a document. Every move is recorded and can be undone. Every document's labels
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

| Profile | Reading, images and names | Embeddings | Memory |
|---|---|---|---|
| `standard` (default) | `ministral-3:14b` | `bge-m3` | ~10 GB |
| `balanced` | `ministral-3:8b` | `bge-m3` | ~7 GB |
| `lowMemory` | `gemma4:e2b-it-qat` | `bge-m3` | ~5.5 GB |

One model reads every document, describes images and names files. The profiles were chosen as the best for their
memory on a 16 GB Mac mini (M5) when Arrumator still filed documents into folders; how well each labels documents
has not been measured yet. Larger models do not fit such a Mac's memory. The measurements are in
[docs/evaluation.md](docs/evaluation.md).

## Install

1. Download the app from the [latest release](https://github.com/hlistan/arrumator/releases/latest):
   `Arrumator-<version>-apple-silicon.zip` for a Mac with Apple silicon (M1 or later), or
   `Arrumator-<version>-universal.zip`, which runs on Apple silicon and Intel Macs alike. Unzip it and move
   **Arrumator** to Applications.
2. Open it. If the release is not notarized (its notes say so), macOS blocks it the first time. Choose **Done**,
   then open System Settings › Privacy & Security, click **Open Anyway** next to the message about Arrumator, and
   confirm ([Apple Support: open an app from an unknown developer](https://support.apple.com/en-us/102445)).
3. Onboarding asks for your Incoming and Archive folders. Install [Ollama](https://ollama.com) if you haven't:
   Arrumator starts it when needed. Then download the profile's models under Settings › Models, with the Download
   button beside each; `arrumatorcli doctor` confirms everything is in place.

To check a download, compare it with the release's checksums (`shasum -a 256 -c SHA256SUMS`) or verify where it was
built (`gh attestation verify <file> --repo hlistan/arrumator`).

The command line tool is in `arrumatorcli-<version>-apple-silicon.zip` in the same release. Unzip it and keep the folder
together; [docs/cli.md](docs/cli.md) explains how to use it. To build from source instead, see
[CONTRIBUTING.md](CONTRIBUTING.md).

## Getting started

1. Put a document in `~/Documents/Incoming` (Settings › General changes both folders).
2. Arrumator reads it, names it and files it at the top of `~/Documents/Archive`, and shows it in **Processed**.
3. Open the document's row to see its labels and how it was read. Rename it, or take off or add a label, on its card
   if something is wrong. On **Labels**, merge labels that mean the same, or remove one you never want.
4. Documents it could not read wait in **Needs You**. Confirm them as they are, or have them read again.
5. Click a label in the sidebar, such as a sender, to see only its documents; the sidebar then lists only the labels
   those documents have, so a second click, such as a type, narrows them down further. Type in the sidebar's search to
   find a label.
6. Search documents by any word, or by a kind of label, with `arrumatorcli search`: `sender:edp`,
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

## Contributing

Contributions are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) explains how to set up, build, test and check a
change. [AGENTS.md](AGENTS.md) holds the engineering rules every change follows, whether a person or a coding agent
makes it. Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md). Report security problems
privately, as [SECURITY.md](SECURITY.md) describes.

## License

[MIT](LICENSE)

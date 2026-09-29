# Arrumator

[![Release](https://github.com/hlistan/arrumator/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/hlistan/arrumator/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/hlistan/arrumator)](https://github.com/hlistan/arrumator/releases/latest)
[![macOS 26](https://img.shields.io/badge/macOS-26-lightgrey?logo=apple)](#requirements)
[![License: MIT](https://img.shields.io/github/license/hlistan/arrumator)](LICENSE)

**A macOS menu-bar app that files your documents for you, entirely on your Mac.**

Drop any file into your Incoming folder: a PDF, a scan, a photo, a screenshot, a Word, Excel or PowerPoint file, an
e-mail, plain text. Arrumator reads it, decides where it belongs and what it should be called, files it into your
archive, indexes it for search, and learns from every correction you make. Documents in English, Russian and
Portuguese are supported.

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
- **You decide how the archive is organised.** The archive's *logic* is a prompt you can edit. The built-in one
  condenses records-management practice. Try a change on a few documents, then reprocess the whole archive, reviewing
  every move before it happens.
- **The folder tree grows with your documents**, as deep as the logic asks, with nothing created in advance. Senders
  are recognised by their identifiers, not their spelling, so a bank's documents stay together.
- **It learns from you.** Every move, rename or confirmation becomes a correction. Rules form from repeated filings,
  and next month's bill joins last month's. Anything learned can be forgotten.
- **Asks when unsure.** By default, uncertain documents wait in Needs You with a suggestion instead of being guessed
  into place.
- **Every decision can be audited**: the prompts, the model's answers, timings and a full history, with Statistics
  showing where documents stop and why.
- **Nothing is lost.** No code path deletes a document. Every move is recorded and can be undone. What the app learned
  lives in Markdown files inside your archive, and its index can be rebuilt from them.
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

| Profile | Decisions, images and names | Embeddings | Memory |
|---|---|---|---|
| `standard` (default) | `ministral-3:14b` | `bge-m3` | ~10 GB |
| `balanced` | `ministral-3:8b` | `bge-m3` | ~7 GB |
| `lowMemory` | `gemma4:e2b-it-qat` | `bge-m3` | ~5.5 GB |

One model makes every decision, describes images and names files. The profiles are the measured best for their
memory on a 16 GB Mac mini (M5), filing three instances of every kind of document:

- `ministral-3:14b` grouped them best (F1 0.71, precision 0.90, 92% of repeats filed with their first) at about 25 s
  per document.
- `ministral-3:8b` grouped a little worse (F1 0.65) but as precisely (0.92) at 16 s.
- `gemma4:e2b` was fastest at 6 s, with more mixing (precision 0.76).

Larger models do not fit such a Mac's memory. The measurements are in [docs/evaluation.md](docs/evaluation.md).

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
2. Arrumator files it under `~/Documents/Archive`, in a folder its logic describes, and shows it in **Processed**.
3. Open the document's row to see why it went there. Move or rename it on its card if it's wrong: the correction is
   learned, and the next document like it goes where you put this one.
4. Documents it was unsure about wait in **Needs You**. Accept its suggestion, or choose another folder.

To change how the archive is organised, edit the logic on the **Logic** page, try it on a few documents, then
reprocess everything. [How Arrumator works](docs/how-it-works.md#logic-you-decide-how-the-archive-is-organised)
walks through it.

## Documentation

| Document | Read it for |
|---|---|
| [How Arrumator works](docs/how-it-works.md) | How a document is decided and filed: senders, rules, the logic, the folder tree. |
| [Using Arrumator](docs/using-arrumator.md) | The app's pages, settings and environment variables, the audit trail, where your data lives. |
| [Command line](docs/cli.md) | Every `arrumatorcli` command and option. |
| [Storage](docs/storage.md) | The archive's record files, the index, and what a rebuild keeps. |
| [Evaluation](docs/evaluation.md) | The measurements behind the pipeline and the model profiles. |
| [Sources](docs/organizing-principles-sources.md) | The research behind the built-in logic and the placement design. |
| [Continuous integration and releases](docs/releasing.md) | How changes are checked and released, and how to sign releases. |

## Contributing

Contributions are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) explains how to set up, build, test and check a
change. [AGENTS.md](AGENTS.md) holds the engineering rules every change follows, whether a person or a coding agent
makes it. Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md). Report security problems
privately, as [SECURITY.md](SECURITY.md) describes.

## License

[MIT](LICENSE)

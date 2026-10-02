# Contributing to Arrumator

Thank you for helping. Arrumator files people's personal documents, so two things matter above everything else:
**no document data ever leaves the user's machines**, and **the user's files are never collateral damage**. The
rules that follow from them are in [AGENTS.md](AGENTS.md), which binds people and coding agents alike. Read it before
your first change.

## Setting up

You need macOS 26, Xcode 27 (Swift 6.4) and [Homebrew](https://brew.sh). For the model-backed parts, you also need
[Ollama](https://ollama.com).

```bash
git clone https://github.com/hlistan/arrumator.git
cd arrumator
scripts/bootstrap.sh
```

`scripts/bootstrap.sh` installs the tools in [`Brewfile`](Brewfile) and turns on the Git hooks in `.githooks`:

- **pre-commit** refuses any commit on `main`: start every change on a branch named for it (`git switch -c fix/…`).
  It then runs `scripts/check-secrets.sh --staged`, refusing a commit that adds a secret, signing material
  (`.p12`, `.p8`, …), an `.env` file, a path into someone's home folder, or a real document from
  `Tests/Fixtures/private`.
- **pre-push** refuses a direct push to `main` (see [the push protocol](#pull-requests-the-push-protocol)) and runs
  `scripts/check-secrets.sh --range` over the commits being pushed. It also refuses commits whose
  author or committer address names a machine, such as `you@MacBook-Pro.local`. Set
  `git config user.email <id>+<user>@users.noreply.github.com` to publish your GitHub no-reply address instead.

## Building and running

```bash
xcodegen generate
xcodebuild -project Arrumator.xcodeproj -scheme Arrumator -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Arrumator.app   # first launch shows onboarding

swift test                                                  # every suite; no Ollama needed
swift run arrumatorcli doctor                                  # environment self-check
```

The command line tool writes to the archive your settings name. Before running a command that can change it, give
it a scratch home and scratch folders, as [the command line reference](docs/cli.md) explains.

## Checking a change

`scripts/verify.sh` is the definition of done. Add `--app` when `App/` or `project.yml` changed; CI always does when
the change touches code or what builds and tests it. A change that touches neither, such as documentation alone,
needs only `scripts/verify.sh --checks-only`: `scripts/change-scope.sh main` tells which
([what a change needs](docs/releasing.md#what-a-change-needs-scriptschange-scopesh)).

| Script | What it checks |
|---|---|
| `scripts/verify.sh [--app \| --checks-only] [--no-lint]` | Everything below, then `swift build`, the documentation check, `swift test`, and with `--app` the app build and the unused-code search. With `--checks-only`, the static checks and the documentation check alone, building only `arrumatorcli`. |
| `scripts/change-scope.sh <base> [<head>]` | Which scope a change falls in, from the files it touches (without `<head>`, uncommitted ones too): `release` (code), `build` (what builds and tests it) or `checks` (anything else). CI builds, tests and releases by it. |
| `scripts/lint.sh` | Static checks that build nothing: the guideline gates from AGENTS.md (environment, network, crash, quit, trash, rows, debt, icon), secrets, [SwiftLint](https://realm.github.io/SwiftLint/) (`.swiftlint.yml`), [ShellCheck](https://www.shellcheck.net), [actionlint](https://github.com/rhysd/actionlint) and [zizmor](https://docs.zizmor.sh) for the workflows, [markdownlint](https://github.com/DavidAnson/markdownlint-cli2) (`.markdownlint-cli2.jsonc`) and [lychee](https://lychee.cli.rs) for links between documents. |
| `scripts/check-secrets.sh [--staged \| --range <revs>…]` | [gitleaks](https://github.com/gitleaks/gitleaks) with `.gitleaks.toml` over every commit, the index, the working tree and untracked files; real documents; with `--range`, commit identities. |
| `scripts/check-docs.sh <arrumatorcli>` | Every command and option in [docs/cli.md](docs/cli.md), and no option in a command's synopsis there that it does not take, every `ARRUMATOR_*` variable in [docs/using-arrumator.md](docs/using-arrumator.md), every `pipeline.json` key the docs name, and every script here. |
| `scripts/deadcode.sh` | Unused code across the package, its tests, the command and the app, with [Periphery](https://github.com/peripheryapp/periphery) (`.periphery.yml`). |
| `scripts/bootstrap.sh` | Installs the tools and enables the hooks (see above). |
| `scripts/release.sh` | Builds a release into `dist/`; see [Continuous integration and releases](docs/releasing.md). |
| `scripts/qa-drive.sh <command> <pid> [arguments]` | Drives one running Arrumator, by its process number, through the macOS accessibility API, as the [QA protocol](docs/qa/protocol.md) does: reads its window's elements, presses, clicks, types, sends keys, scrolls, resizes and screenshots its windows and no other. It never reads the system's Apple menu or an open file panel, which list the user's own files. It builds `scripts/qa-drive.swift` into `build/qa-drive` the first time and whenever that changed; `help` lists the commands. The terminal it runs in needs Accessibility in System Settings › Privacy & Security. |
| `scripts/app-icon.sh [<folder>]` | Draws the app icon into `App/Assets.xcassets/AppIcon.appiconset`, every size macOS asks for: a page arriving in a tray, drawn by `scripts/app-icon.swift` in the Incoming list's colour, which it reads from `Palette.incomingList` and stops when it cannot. The drawing is the project's own, made of paths with no SF Symbol, image, font or text, as Apple's licence does not allow symbols, or glyphs like them, in an app icon; the icon gate in `scripts/lint.sh` checks it. The images are build inputs and are committed: run it after changing that colour or the drawing, and never edit them by hand. With `<folder>` it writes the set there instead, to look at first. |

A change to how documents are read (the prompt, the answer schema and its validation, the label kinds, the `analysis`
and `labels` settings) also needs `swift run arrumatorcli eval Tests/Fixtures --passes 2` numbers from before and after,
which needs a local Ollama with the profile's models. The corpus in `Tests/Fixtures` is generated: change
`Tools/FixtureGen` and regenerate it, never edit the fixtures by hand.

## Documentation

**Every change updates the documentation it affects, in the same pull request** (AGENTS.md §4.10). The reader of each
document:

| Document | Covers |
|---|---|
| [README.md](README.md) | What Arrumator is, installing, a first run, where to read on. |
| [docs/how-it-works.md](docs/how-it-works.md) | How a document is read, labelled and filed, and the kinds of label. |
| [docs/using-arrumator.md](docs/using-arrumator.md) | The app's pages, settings, environment variables, audit trail, where data lives. |
| [docs/cli.md](docs/cli.md) | Every command and option. |
| [docs/storage.md](docs/storage.md) | The archive's record files and the index. |
| [docs/evaluation.md](docs/evaluation.md) | Measurements behind the pipeline and the model profiles. |
| [docs/releasing.md](docs/releasing.md) | CI, releases, versions, signing. |
| [docs/repository-settings.md](docs/repository-settings.md) | The GitHub repository's security settings and the rules that enforce the push protocol. |
| [docs/qa/protocol.md](docs/qa/protocol.md) | How the app is tested as a user meets it: the method, environment, charters, severity and report. A run's findings go into `docs/qa/reports/`, which Git ignores. |
| [docs/architecture.md](docs/architecture.md) | How the code is arranged: the modules and what each folder of Core owns, what happens at run time, the concurrency model, the decisions and the checks that keep them. |
| [docs/review/code-review.md](docs/review/code-review.md) | How a change, and the whole project, is reviewed: the order, what to look for by area, how a finding is written and proved. A full review's findings go into `docs/review/reports/`, which Git ignores. |
| [docs/review/swift-apple.md](docs/review/swift-apple.md) | What to check in Swift and on Apple's platforms that the compiler and the linters do not settle. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | This file: setting up, checking, the scripts. |

`scripts/check-docs.sh` catches a command, option, variable, configuration key or script that the documents miss or
that no longer exists. Behaviour it cannot compare mechanically is up to you and the review.

## Pull requests: the push protocol

Every change reaches `main` the same way ([AGENTS.md §8](AGENTS.md#8-push-protocol)), because each merge to `main`
that changes code is released:

1. **Green gates locally.** Work on a branch named for the change (`fix/…`, `feat/…`, `docs/…`, …), never on `main`.
   Start a fix or a feature with a test that fails for the stated reason, then make it pass (AGENTS.md §2 and §3).
   Review your own diff by [the code review guidelines](docs/review/code-review.md). Push only when the verify
   command the change's scope calls for (`scripts/change-scope.sh main`) ends with `All checks passed`.
2. **Push the branch and get it green on the remote runners.** `git push -u origin <branch>`, open a pull request to
   `main` with the template filled in (`gh pr create`), and wait for CI (`gh pr checks --watch`). Fix any failure on
   the same branch and push again. A red pull request is never merged. Have the change reviewed by someone who did
   not write it, as [the code review guidelines](docs/review/code-review.md) describe.
3. **Squash-merge to `main` and remove the branch.** `gh pr merge --squash --delete-branch`, then
   `git switch main && git pull --ff-only`.
4. **Release only code.** The merge is released only when its scope is `release`. Any other merge is checked and
   goes out with the next release that changes code.

The pre-push hook refuses a direct push to `main`, and the repository's settings enforce the same on GitHub
([docs/repository-settings.md](docs/repository-settings.md)).

Report bugs and ideas as [issues](https://github.com/hlistan/arrumator/issues/new/choose); report security problems
privately, as [SECURITY.md](SECURITY.md) describes. Everyone taking part follows the
[code of conduct](CODE_OF_CONDUCT.md).

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).

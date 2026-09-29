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

- **pre-commit** runs `scripts/check-secrets.sh --staged`. It refuses a commit that adds a secret, signing material
  (`.p12`, `.p8`, …), an `.env` file, a path into someone's home folder, or a real document from
  `Tests/Fixtures/private`.
- **pre-push** runs `scripts/check-secrets.sh --range` over the commits being pushed. It also refuses commits whose
  author or committer address names a machine, such as `you@MacBook-Pro.local`. Set
  `git config user.email <id>+<user>@users.noreply.github.com` to publish your GitHub no-reply address instead.

## Building and running

```bash
xcodegen generate
xcodebuild -project Arrumator.xcodeproj -scheme Arrumator -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Arrumator.app   # first launch shows onboarding

swift test                                                  # every suite; no Ollama needed
swift run arrumator doctor                                  # environment self-check
```

The command line tool writes to the archive your settings name. Before running a command that can change it, give
it a scratch home and scratch folders, as [the command line reference](docs/cli.md) explains.

## Checking a change

`scripts/verify.sh` is the definition of done. Add `--app` when `App/` or `project.yml` changed; CI always does.

| Script | What it checks |
|---|---|
| `scripts/verify.sh [--app] [--no-lint]` | Everything below, then `swift build`, the documentation check, `swift test`, and with `--app` the app build and the unused-code search. |
| `scripts/lint.sh` | Static checks that build nothing: the guideline gates from AGENTS.md (environment, network, crash, debt), secrets, [SwiftLint](https://realm.github.io/SwiftLint/) (`.swiftlint.yml`), [ShellCheck](https://www.shellcheck.net), [actionlint](https://github.com/rhysd/actionlint) and [zizmor](https://docs.zizmor.sh) for the workflows, [markdownlint](https://github.com/DavidAnson/markdownlint-cli2) (`.markdownlint-cli2.jsonc`) and [lychee](https://lychee.cli.rs) for links between documents. |
| `scripts/check-secrets.sh [--staged \| --range <revs>…]` | [gitleaks](https://github.com/gitleaks/gitleaks) with `.gitleaks.toml` over every commit, the index, the working tree and untracked files; real documents; with `--range`, commit identities. |
| `scripts/check-docs.sh <arrumator>` | Every command and option in [docs/cli.md](docs/cli.md), every `ARRUMATOR_*` variable in [docs/using-arrumator.md](docs/using-arrumator.md), every `pipeline.json` key the docs name, and every script here. |
| `scripts/deadcode.sh` | Unused code across the package, its tests, the command and the app, with [Periphery](https://github.com/peripheryapp/periphery) (`.periphery.yml`). |
| `scripts/bootstrap.sh` | Installs the tools and enables the hooks (see above). |
| `scripts/release.sh` | Builds a release into `dist/`; see [Continuous integration and releases](docs/releasing.md). |

A change to how documents are placed (prompts, the built-in logic, thresholds, calibration, rules) also needs
`swift run arrumator eval Tests/Fixtures --passes 2` numbers from before and after, which needs a local Ollama with the
profile's models. The corpus in `Tests/Fixtures` is generated: change `Tools/FixtureGen` and regenerate it, never edit
the fixtures by hand.

## Documentation

**Every change updates the documentation it affects, in the same pull request** (AGENTS.md §4.10). The reader of each
document:

| Document | Covers |
|---|---|
| [README.md](README.md) | What Arrumator is, installing, a first run, where to read on. |
| [docs/how-it-works.md](docs/how-it-works.md) | How a document is decided and filed: senders, rules, logic, the folder tree. |
| [docs/using-arrumator.md](docs/using-arrumator.md) | The app's pages, settings, environment variables, audit trail, where data lives. |
| [docs/cli.md](docs/cli.md) | Every command and option. |
| [docs/storage.md](docs/storage.md) | The archive's record files and the index. |
| [docs/evaluation.md](docs/evaluation.md) | Measurements behind the pipeline and the model profiles. |
| [docs/releasing.md](docs/releasing.md) | CI, releases, versions, signing. |
| [docs/repository-settings.md](docs/repository-settings.md) | The GitHub repository's security settings. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | This file: setting up, checking, the scripts. |

`scripts/check-docs.sh` catches a command, option, variable, configuration key or script that the documents miss or
that no longer exists. Behaviour it cannot compare mechanically is up to you and the review.

## Pull requests

1. Branch from `main`, and keep a pull request to one change.
2. Start a fix or a feature with a test that fails for the stated reason, then make it pass (AGENTS.md §3).
3. Run `scripts/verify.sh` (with `--app` if needed) and fill in the pull request template.
4. CI must pass. After review the pull request is merged into `main`, which releases it.

Report bugs and ideas as [issues](https://github.com/hlistan/arrumator/issues/new/choose); report security problems
privately, as [SECURITY.md](SECURITY.md) describes. Everyone taking part follows the
[code of conduct](CODE_OF_CONDUCT.md).

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).

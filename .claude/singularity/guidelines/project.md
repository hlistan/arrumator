# Project guidelines

How to work in this codebase as it is now: facts and rules every agent
needs, wherever it works. Imported into every session, so keep it to at most
40 guidelines; guidelines for one part of the code go in path-scoped rules in
`.claude/rules/singularity/`.

Maintained by the singularity optimizer and reviewed in PRs/MRs
like code. Each guideline states the current right way; when the code
changes, the guideline changes with it. Format and rules: singularity
`optimizer/learn.md`.

## Paths and trust

- **G1** Decide whether a path is inside a folder, and its folder relative to
  that one, only with `URL.holds` and `URL.relativeFolder(of:)` in
  `Sources/ArrumatorCore/FileOps/FileIdentity.swift`; never slice or compare
  a path by string prefix. Tests run under `/var` while the disk spells it
  `/private/var`, so prefix slicing passes the tests and cuts the wrong
  folder through a link.
- **G2** Every path or value read back from a record file (History,
  `System/History/_<year>-<month>.md`, and the sidecars; `payloadJson` is a
  raw string) is untrusted, because the user edits record files by hand:
  hold it to the folder it must be in (`Trashing.holds`, `URL.holds`), take
  `..` out (`standardizedFileURL`) before walking up, refuse links, and
  handle an undecodable payload in the listing as well as in the action
  (AGENTS.md §4). The SQLite index is not a trust boundary.

## Text stays in the app

- **G25** No text of the app, selected or typed, is offered to anything
  outside it: no web search, Look Up, Translate, Share, Services or Writing
  Tools, even as a deliberate user act, because the app holds sensitive
  documents (the team's reading of AGENTS.md §4.1). Copy and dragging text
  out stay. `App/Support/LocalText.swift` enforces it, the `local-text`,
  `local-text-config` and `hosting` gates of `scripts/lint.sh` hold it, and
  `docs/architecture.md` › "Keeping text inside the app" says what is
  verified and what is not.

## Actions and their inverses

- **G3** An action that undoes another (put-back after
  `ReviewActions.remove`) accepts a file by the same rule as the action it
  undoes (`ReviewActions.ownFile`, `PutBackRule.onDisk`), never a stricter or
  looser one (AGENTS.md §4): the spec states the shared rule, the plan names
  it and lists the states the first action accepts (a file with no
  `Xattr.documentID`, in the archive and in Incoming), and the tests cover
  the pair on each.

## The App

- **G4** `App/` has no test target: `swift test` doesn't reach it, and
  `scripts/verify.sh --app` only builds it and runs `scripts/deadcode.sh`.
  Put every decision in Core (`ReviewActions`), where `swift test` reaches
  it, and keep views thin; an acceptance criterion only the App shows gets a
  step in a QA charter in `docs/qa/protocol.md`, and counts as not run until
  someone drives the built app.

## Working in this checkout

- **G5** `git diff <base>` omits new untracked files: run
  `git add -N <new files>` before handing a change to review, and as a
  reviewer check `git status --short` for files the diff leaves out.
- **G6** `timeout` is not installed on this machine: bound a long command
  with `perl -e 'alarm shift; exec @ARGV' 900 <command>`.
- **G7** Never run `gh pr merge` in a pipeline run: a pull request merges
  only after the independent review written into it (AGENTS.md §2, §8), and
  with `auto_commit` and `auto_pr` false the hand-off ends at an uncommitted
  tree.
- **G26** The user may have Arrumator open on this Mac: stop only a copy
  you launched, by the pid you saved (`kill "$(cat "$RUN/pid")"`, step 4 of
  the run setup in `docs/qa/protocol.md`), never `pkill` or `killall` by
  name.
- **G27** Committed code, comments and docs never cite a file under
  `.agentic/`, which is git-ignored: move what a spike or a run file proves
  into `docs/` (`docs/architecture.md`) and cite that.
- **G35** Run the app and the command line only in a scratch home
  (AGENTS.md §4.3): even `ingest --dry-run` and a read-only command open
  the archive the settings name and can write into it. Launch the app as
  step 4 of "Environment" in `docs/qa/protocol.md`, with `ARRUMATOR_HOME`
  at a folder whose `settings.json` names scratch folders as `incomingPath`
  and `archivePath`, and `ARRUMATOR_TRASH` at another (step 2). Name
  `arrumatorcli` on a command only for `eval`, `--version` or `help`; run
  every other command as `scripts/qa-cli.sh <run folder> <arguments>`,
  which takes the command `scripts/verify.sh --app` built, needs a run
  folder under `/private/tmp` or `/private/var/folders` holding `home`,
  `Incoming` and `Archive`, sets both variables itself and refuses any
  other home. The Bash hook (`.claude/singularity/hooks/pre-bash.sh`)
  blocks the rest. Write the variables out on the command, never through
  a shell variable holding `A=b C=d`, which zsh does not split. Ask the
  user before pulling or deleting an Ollama model or running
  `scripts/release.sh` (§4.8).
- **G55** A guideline a task's Learn step writes (AGENTS.md §2.5) takes the
  next id above the highest in `.claude/singularity/guidelines/`,
  `.claude/rules/singularity/` and
  `.claude/singularity/experience/runs.jsonl`, never one in use in another
  file: the verifier fails a change that holds an id twice.

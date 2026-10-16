# Plan guidelines

How changes are planned here: module boundaries, where new code goes, migration
and rollout steps.

Maintained by the singularity optimizer and reviewed in PRs/MRs like code.
Each guideline states the current right way. Format and rules: singularity
`optimizer/learn.md`.

## Steps

- **G10** Every step names the failing test it starts with; no step is
  "types only, tests come with later steps".

## Where new code goes

- **G38** AGENTS.md §5 and `docs/architecture.md` › "Building blocks" say
  which module owns what. A decision goes in Core and is wired in
  `Sources/ArrumatorRuntime/ArrumatorRuntime.swift`; a new user action gets
  an `arrumatorcli` command with `--json` output in `Sources/ArrumatorCLI`
  as well as its App control; a tunable is a key in
  `Sources/ArrumatorCore/Resources/Defaults/pipeline.json` or
  `settings.json`, mirrored by a field of `PipelineConfig` or `AppSettings`
  with no default in code; a schema change is a forward migration in
  `AppDatabase.migrator` (`Sources/ArrumatorCore/Storage/`), with its
  `MigrationTests` case written in SQL; a prompt lives in
  `Sources/ArrumatorClassify/Prompts/` (AGENTS.md §3, §4.6).
- **G39** A plan ends with the documents the change must update (AGENTS.md
  §4.10), the QA charter steps for anything only the App shows (G4), and the
  done check for the change's scope: `scripts/change-scope.sh main` says
  `release` or `build` for `scripts/verify.sh --app`, `checks` for
  `scripts/verify.sh --checks-only` (AGENTS.md §8).

# Spec guidelines

What a spec for this project must cover, and where requirements live.

Maintained by the singularity optimizer and reviewed in PRs/MRs like code.
Each guideline states the current right way. Format and rules: singularity
`optimizer/learn.md`.

## Scoping

- **G8** Before scoping, check what already ships for the ask
  (`git log --oneline`, `docs/using-arrumator.md`, `docs/cli.md`) and ask
  which gap the user means.
- **G9** Give every open question a proposed default, and ask explicitly only
  those whose answer changes behaviour. Where a default decides whether
  document text or data can leave the app, whatever the route (a system
  menu, a service, a panel), propose the stricter answer (G25, AGENTS.md
  §4.1), not "a deliberate user act is fine".

## Where requirements live

- **G36** What the product does is `README.md` › Features and
  `docs/how-it-works.md`; the app's pages and settings
  `docs/using-arrumator.md`; every command `docs/cli.md`; the rules a change
  may not break AGENTS.md §4; the project's words `docs/architecture.md` ›
  "Words". A defect spec starts from the QA report under
  `docs/qa/reports/<date>/report.md` (git-ignored: read it in the checkout),
  citing findings by id (`C5-1`) and the severity scale of
  `docs/qa/protocol.md` › Severity.

## What a spec covers

- **G37** Every acceptance criterion names what proves it (AGENTS.md §2.4):
  a test in `swift test`, an `arrumatorcli` command and its `--json` output,
  an eval run, or, for what only the App shows, the charter step (G4). The
  spec also states what changes for an installed app (lost learned state,
  renamed `settings.json` or `pipeline.json` keys, changed CLI output;
  AGENTS.md §7) and which documents change with it (§4.10 says which
  document covers what).
- **G54** A criterion about the keyboard says which Keyboard navigation
  setting it holds for (off, as this Mac has it, and on; G48 in
  `.claude/rules/singularity/app.md`) and promises only keys the plan
  handles; a key nobody handles, as Tab, is probed, never promised (G31). A
  limit on automatic work (one embedding request per query) leaves the
  person's own request, as Return, acting: AGENTS.md §4.7, nothing pressed
  is met with nothing.

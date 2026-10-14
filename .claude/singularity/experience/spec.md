# Spec lessons

What the team corrected in earlier specs on this project.

Maintained by the singularity learner and reviewed in PRs/MRs like code. Format and rules: singularity `agents/learner.md`.

- **L1** Before scoping, check what already ships for the ask
  (`git log --oneline`, `docs/using-arrumator.md`, `docs/cli.md`) and
  ask which gap the user means. _Why:_ "remove documents" had shipped
  in #21 (the card and `arrumatorcli review remove`); the real ask was
  removal from a row and putting a removed one back. _Seen:_ 1 ·
  _Last:_ 2026-10-14 · _Refs:_ remove-documents
- **L2** For the inverse of an existing action, state that its
  acceptance rules match the forward action's (what counts as the
  document's file), or say why not. _Why:_ B4(d) refused a file with no
  identifier that removal accepts; amended after review round 2.
  _Seen:_ 1 · _Last:_ 2026-10-14 · _Refs:_ remove-documents
- **L3** Give every open question a proposed default and ask explicitly
  only those that change behaviour. _Why:_ the user asked about four
  (Q1, Q4, Q7, Q8) and took every default of fifteen. _Seen:_ 1 ·
  _Last:_ 2026-10-14 · _Refs:_ remove-documents

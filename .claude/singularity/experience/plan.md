# Plan lessons

Planning gaps found on earlier runs.

Maintained by the singularity learner and reviewed in PRs/MRs like code. Format and rules: singularity `agents/learner.md`.

- **L1** When a feature adds the inverse of an existing action, name the
  one rule both share (what counts as the document's file, the
  refusals), list the states the forward action accepts (e.g. no
  `Xattr.documentID`), and add a step that tests the pair on each.
  _Why:_ put-back's B4(d) was stricter than `ownFile`; found only in
  review round 2. _Seen:_ 1 · _Last:_ 2026-10-14 ·
  _Refs:_ remove-documents
- **L2** Every step names the failing test it starts with; no "types
  only, tests come with later steps" step. _Why:_ step 3 was planned
  that way, and the implementer wrote tests after the code for steps
  3–8 and 10–11. _Seen:_ 1 · _Last:_ 2026-10-14 ·
  _Refs:_ remove-documents

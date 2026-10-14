# Upstream candidates

Lessons that apply to every project. Propose them to the shared singularity repo (engineering standards or an agent definition).

Maintained by the singularity learner and reviewed in PRs/MRs like code. Format and rules: singularity `agents/learner.md`.

- **U1** Inverse actions (undo, put back, restore) share one acceptance
  rule with the action they invert and are tested as a pair; spec,
  plan, implementer and correctness lens should each ask for it.
  _Why:_ remove and put-back drifted on one identity rule.
  _Seen:_ 1 · _Last:_ 2026-10-14 · _Refs:_ arrumator remove-documents
- **U2** A listing that pre-computes whether an action is possible and
  the action itself must call one rule; every input the action refuses
  appears in the listing. _Seen:_ 1 · _Last:_ 2026-10-14 ·
  _Refs:_ arrumator remove-documents
- **U3** Before review, the pipeline should `git add -N` new untracked
  files, or `git diff <base>` hides them from every reviewer.
  _Seen:_ 1 · _Last:_ 2026-10-14 · _Refs:_ arrumator remove-documents
- **U4** Reviewers cite line numbers from the file, not from diff
  output; four findings in one round cited lines past the file's end.
  _Seen:_ 1 · _Last:_ 2026-10-14 · _Refs:_ arrumator remove-documents
- **U5** The orchestrator never merges a PR (`gh pr merge`); merging
  waits for human review, and auto mode refuses it anyway.
  _Seen:_ 1 · _Last:_ 2026-10-14 · _Refs:_ arrumator remove-documents
- **U6** With a two-round review cap, the last fix round ships
  unreviewed (18 fixes here). Later rounds should read fix-round code
  first (round 2 found an infinite loop added by a round-1 fix);
  consider a scoped extra pass over should-fix fixes.
  _Seen:_ 1 · _Last:_ 2026-10-14 · _Refs:_ arrumator remove-documents

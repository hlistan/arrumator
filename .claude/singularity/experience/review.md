# Review lessons

Issues that slipped through review, and false positives the team rejected.

Maintained by the singularity learner and reviewed in PRs/MRs like code. Format and rules: singularity `agents/learner.md`.

- **L1** Cite the line as the file has it in the working tree (Read the
  file), not a position in the diff output. _Why:_ C17, C18, C21 and
  C22 cited lines past the end of 181- and 185-line files; the
  challenger had to correct each. _Seen:_ 1 · _Last:_ 2026-10-14 ·
  _Refs:_ remove-documents
- **L2** Correctness: when a change adds the inverse of an action,
  compare its acceptance rule with the forward one on every supported
  state (a file with no `Xattr.documentID`). _Why:_ the remove/put-back
  drift (D1) was in round 1's code and only round 2 found it.
  _Seen:_ 1 · _Last:_ 2026-10-14 · _Refs:_ remove-documents
- **L3** In a later round, read the code the fix round added first.
  _Why:_ `SystemTrash.holds`, added to fix C3, looped forever on a
  `trashed` path with `..` (D3). _Seen:_ 1 · _Last:_ 2026-10-14 ·
  _Refs:_ remove-documents
- **L4** Don't flag file I/O inside the index's write transaction (`writer.write { db in … }`) for a move
  and its record (`bringBack`, `trash`): one write for both is the
  project's pattern (`remove` does it) and was approved at the plan
  gate. _Why:_ R1 rejected. _Seen:_ 1 · _Last:_ 2026-10-14 ·
  _Refs:_ remove-documents
- **L5** Don't flag an error case or label kept to mirror an existing
  one: `FileOperationError.notAFileName` for "outside root" (as
  `makeFolders` uses it), `PutBackError.archiveNotThere(String)` (as
  `RecordsError`). _Why:_ R2 rejected; D13 half false. _Seen:_ 1 ·
  _Last:_ 2026-10-14 · _Refs:_ remove-documents
- **L6** Don't flag the Trash and link check restated in
  `PutBackRule.onDisk` and `FileOperations.bringBack`: a listing
  pre-check plus a check at the trust boundary is intended defence in
  depth; the rule itself lives once in `Trashing.holds`. _Why:_ S1
  rejected. _Seen:_ 1 · _Last:_ 2026-10-14 · _Refs:_ remove-documents

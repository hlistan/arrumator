# Review guidelines

Where defects cost most here, the domain rules to check, and what looks wrong
but is intended.

Maintained by the singularity optimizer and reviewed in PRs/MRs like code.
Each guideline states the current right way. Format and rules: singularity
`optimizer/learn.md`.

## Citing and rounds

- **G17** Cite a line as the file has it in the working tree (Read the
  file), never as a position in the diff output.
- **G18** In a second round, read the code the fix round added first: a fix
  is new code no round has reviewed yet.

## Intended, not a finding

- **G19** A file move and its record in one index write
  (`writer.write { db in … }`, as `ReviewActions.remove` and `bringBack`
  do) is the project's pattern (AGENTS.md §3); don't flag the file I/O
  inside the transaction.
- **G20** An error case or label kept to mirror an existing one is intended:
  `FileOperationError.notAFileName` for a path outside the root, as
  `makeFolders` uses it, and `PutBackError.archiveNotThere(String)`, spelled
  as `RecordsError` spells it.
- **G21** A listing pre-check (`PutBackRule.onDisk`) and a check at the trust
  boundary (`FileOperations.bringBack`), both asking whether a path is in
  the Trash and not a link, are defence in depth, not duplication: the rule
  itself lives once, in `Trashing.holds`.
- **G34** A `Wording` constant per surface for one verb (`Wording.copyLabel`,
  `Wording.copyAnswer`; `Wording.undoFiling` on the button and
  `Wording.undoAction` naming the action in `AppModel.perform`'s report) is
  the project's pattern, as is an `AppModel` action's shape: `perform`, then
  open or reload what changed (`AppModel.mergeLabel`). Don't flag either as
  duplication.
- **G56** A sentence in `docs/` about what the App's own code decides (the
  search field cleared by `AppModel.go`, a new `ArchiveSession` on
  `AppModel.switchArchive`) is checked against that code, and stands when
  the code does it. Only AppKit and system behaviour (keys, focus,
  VoiceOver, menus) needs a drive before docs state it (G31 in
  `.claude/rules/singularity/app.md`).

## How to review here

- **G42** Review by `docs/review/code-review.md`: the seven passes of "How to
  review a change", the "By area" table for each area the diff touches, and
  `docs/review/swift-apple.md` for Swift and the App. Don't report what
  `scripts/lint.sh`'s gates, SwiftLint, `scripts/deadcode.sh` and
  `scripts/check-docs.sh` decide; the table under "What the checks cover,
  and what they leave to review" says what review still asks about each
  rule.

## Where a defect costs most

- **G43** In this order (`docs/architecture.md` › "What the architecture is
  for"): document text or names leaving the machines the user runs
  (AGENTS.md §4.1: only `OllamaClient` behind `NetworkGuardProtocol` opens a
  connection, a log message is a `StaticString`, an export is allow-listed,
  and no text is offered to a system service, G25); a document deleted,
  misfiled or written over, or a record file misread (§4.2: `Trashing`,
  `RecordFile.text`, `FolderIdentity`, `TwoPlaces`); what a stop or a crash
  leaves in the queues and the index (§3: `JobStore.nextDue(claiming:)`,
  `IndexStore.replaceReading`); a view showing a state that isn't Core's
  (§4.6, `AppModel.load`); a model's answer or a file from Incoming trusted
  (§4.5: `AnswerValidator`, `FilenameBuilder`, the budgets in
  `ZipDirectory`, `SpreadsheetML` and `HTMLText`).

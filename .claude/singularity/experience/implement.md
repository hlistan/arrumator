# Implementation lessons

Mistakes reviewers or verification caught before. Don't repeat them.

Maintained by the singularity learner and reviewed in PRs/MRs like code. Format and rules: singularity `agents/learner.md`.

- **L1** Adding the inverse of an existing action (put-back of
  `ReviewActions.remove`): reuse the predicate the forward action used
  to accept the file (`ReviewActions.ownFile`) instead of writing a
  stricter twin, and test the pair end to end on each supported state
  (a file with no `Xattr.documentID`, archive and Incoming). _Why:_
  removal took a file with stripped xattrs, put-back refused it as "not
  its file" (round 2 D1; spec amended). _Seen:_ 1 ·
  _Last:_ 2026-10-14 · _Refs:_ remove-documents
- **L2** A listing that pre-computes refusals (`putBackRefusals(of:)`,
  `removalRefusals(of:)`) and its action run one rule: no `compactMap`
  that drops inputs the action then refuses, no hand copy of the rule's
  queries inside the write (split an index-only part and call it from
  both), no guard after the rule that no input reaches. _Why:_ C4, C11,
  D4, D5. _Seen:_ 1 · _Last:_ 2026-10-14 · _Refs:_ remove-documents
- **L3** An error case names the kind of id it was given: a History
  event id gets its own case (`PutBackError.noSuchRemoval(event:)`),
  never one worded for a document number; label associated values
  (`document:`, `event:`). Test public entry points with an unknown and
  a wrong-kind id. _Why:_ "Document `<event id>` was not removed" (C5,
  C8, C21, D13). _Seen:_ 1 · _Last:_ 2026-10-14 ·
  _Refs:_ remove-documents
- **L4** Failure-path tests assert the exact error
  (`#expect(throws: DatabaseError.self)`, a `PutBackError` case), never
  `(any Error).self`, and prove the action acted before it was undone
  (same inode at `trashed`, Trash count), or "refused before acting"
  passes too. A test that cancels before the call stops at GRDB's first
  `read`, not at a later `checkCancellation`; say so in its comment.
  _Why:_ C7, C18. _Seen:_ 1 · _Last:_ 2026-10-14 ·
  _Refs:_ remove-documents
- **L5** Write each Core step's test first and show it failing; cover
  every trigger and root the spec names (archive and Incoming, folder
  gone, archive moved, listed in Processed, the undo itself failing).
  _Why:_ tests came after the code for steps 3–8 and 10–11, and review
  found untested spec branches (C17, C19, C20, D16). _Seen:_ 1 ·
  _Last:_ 2026-10-14 · _Refs:_ remove-documents
- **L6** When the App offers an action from a new place (a row menu
  while a card is open, a History row as well as the notice), check each
  page's reload merge (`ProcessedPage` keeps rows under an open card)
  and every state the old path cleared (`session.removed`); route every
  button for one action through one `AppModel` method and report
  failures through `AppModel.perform`. _Why:_ C2, D2, D10. _Seen:_ 1 ·
  _Last:_ 2026-10-14 · _Refs:_ remove-documents
- **L7** Every stat or read of a file someone else can move (an item in
  the Trash) sits inside the do/catch that maps "gone" to the typed
  refusal (`noLongerInTrash`); otherwise a raw `CocoaError` escapes and
  the two-at-once test is flaky. _Why:_ C1. _Seen:_ 1 ·
  _Last:_ 2026-10-14 · _Refs:_ remove-documents
- **L8** Tests never depend on the machine: inject the Trash lookup
  (`SystemTrash(trashOfVolume:)`) rather than `NSHomeDirectory()` and a
  literal `.Trash`; assert paths by prefix of the Trash the test gave
  (`home.root.appendingPathComponent("Trash").spelledOnDisk.path`), not
  `contains("/Trash/")`; share sentinels and helpers through statics or
  `Tests/Support`, never copied literals. _Why:_ D17, D18, C16, C22,
  D14. _Seen:_ 1 · _Last:_ 2026-10-14 · _Refs:_ remove-documents

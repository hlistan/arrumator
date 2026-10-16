# Upstream candidates

Guidelines that would be right in any project, not just this one, each with
the evidence for it. The singularity optimizer turns the ones with enough
evidence into upstream reports for the singularity maintainers, in
`../upstream/`.

Written and read by the singularity optimizer. Format and rules: singularity
`optimizer/learn.md`.

## Candidates

- **U1** An action that undoes another (undo, put back, restore) accepts its
  input by the same rule as the action it undoes, and the pair is tested on
  each state the first accepts; the spec, the plan, the implementer and the
  correctness lens each ask for it.
  Evidence: 1 run; 1 confirmed should-fix finding, category "inverse actions
  identity rule drift" (round 2, stage spec) · refs: remove-documents.
- **U2** A listing that pre-computes whether an action is possible and the
  action itself call one rule, so that every input the action refuses
  appears in the listing.
  Evidence: 1 run; 3 confirmed findings, category "listing and action rule
  drift" · refs: remove-documents.
- **U3** Before a review, the pipeline runs `git add -N` on new untracked
  files; otherwise `git diff <base>` hides them from every reviewer. The
  0.5.0 feature skill doesn't do it.
  Evidence: 2 runs; one new source file and four new test files were missing
  from the review diff (remove-documents); the new guideline and rule files
  were untracked at review, a confirmed should-fix (M1) although the project
  guideline G5 said to run `git add -N` (ui-usability) · refs:
  remove-documents, ui-usability.
- **U4** A reviewer cites line numbers as the file has them in the working
  tree, not positions in the diff output. The 0.5.0 reviewer agent doesn't
  say so.
  Evidence: 2 runs; 4 findings in one round cited lines past the end of the
  file (remove-documents); the interface lens cited diff positions in round
  1, corrected by the challengers, although the project guideline G17 said
  so (t1-in-app-word-search) · refs: remove-documents,
  t1-in-app-word-search.
- **U5** The orchestrator never merges a PR/MR (`gh pr merge`): merging waits
  for the human review, and auto mode refuses it anyway.
  Evidence: 1 run · refs: remove-documents.
- **U6** With the two-round review cap, the last fix round ships unreviewed:
  a later round reads the fix round's code first, and a scoped extra pass
  covers the should-fix fixes. The 0.5.0 feature skill keeps the cap at 2.
  Evidence: 1 run; 18 fixes shipped unreviewed, and round 2 found an
  infinite loop that a round-1 fix had added · refs: remove-documents.
- **U7** The implementer ticks a plan step only when every item it lists is
  done, and lists an item left out under the step as a deviation.
  Evidence: 1 run; plan step 27 ticked with one of its items skipped, found
  by review as a should-fix (K1, an acceptance criterion unmet) · refs:
  ui-usability.
- **U8** The orchestrator writes each stage and gate time into the run
  record with `date -u` when it happens, never afterwards as an estimate;
  otherwise no flow metric can be taken from the run.
  Evidence: 1 run; only the start and the final verify end were measured,
  the other times were estimates, some later than the real end · refs:
  ui-usability.
- **U9** A subagent that produces a report (a QA run) returns it in its
  final message, with its finding count taken from the finding ids in it;
  the orchestrator writes the file and checks the count. The harness keeps
  subagents from writing report files.
  Evidence: 1 run; the QA subagent could not write its report and stated 25
  findings where it listed 29 · refs: ui-usability.
- **U10** The spec writer proposes the stricter default for an open question
  that touches a project's hard rule (data leaving the machine, privacy),
  rather than accepting a route because the user takes it deliberately.
  Evidence: 1 run; the user overrode such a default at the spec gate, which
  added an acceptance criterion · refs: ui-usability.
- **U11** A test of a set or allow-list compares it with a literal list in
  the test; iterating the code's own set passes whatever it holds.
  Evidence: 1 run; a confirmed should-fix (T1, 18 of 30 values untested),
  whose fix a challenger corrected to this · refs: ui-usability.
- **U12** An agent stops only processes it launched, by pid, never by name
  (`pkill`, `killall`): the user may run the same app.
  Evidence: 1 run; the implementer ran `pkill -x` on the app's name once ·
  refs: ui-usability.
- **U13** The learn and onboard playbooks take eval cases from escaped
  defects that QA or a user found after the merge, cut to the file of the
  merge that holds the defect, and from a run's confirmed findings as
  regression cases, not only from human PR/MR review comments; a case's
  `case.md` starts its note with a heading, since a body with none fails
  markdownlint's MD041 wherever a project lints Markdown with the defaults.
  Evidence: 1 project; 25 merged PRs with no human review comment, so the
  playbooks' source gave no case; the first 7 cases came from two QA-found
  escapes and five review findings; 7 MD041 errors on the template's format ·
  refs: O-2026-10-15-3.
- **U14** A review round after a fix round includes the testability lens
  whenever the fix round wrote or changed tests, not only the lenses whose
  findings it fixed: a fix round's own tests are new code.
  Evidence: 1 run; round 2 ran correctness and interface only, and the
  verifier found a regression test the fix round wrote that could pass
  without its fix; rounds 3 and 4 then found three more test
  synchronization defects of the fix rounds' own making · refs:
  t1-in-app-word-search.
- **U15** The pipeline runs `scripts/check-guidelines.sh` after any stage
  that changed a guideline or rule file (a project's own Learn step, a QA
  drive), not only at the final verification, so that an id taken twice
  is caught where it was written.
  Evidence: 1 run; a QA drive wrote G36, G46 and G47, ids already in use in
  other files, and the final verification failed on them · refs:
  t1-in-app-word-search.
- **U16** A project hook that keeps a command inside a scratch environment
  checks it through a wrapper that sets and validates the environment
  itself, never by matching the variable's name in the command's text.
  Evidence: 1 run; a hook that passed any command naming `ARRUMATOR_HOME=`
  let a command whose variable zsh had not split open the user's real
  data, and a tag was written there · refs: t1-in-app-word-search.
- **U17** Before a stage that drives a GUI app (a QA drive), the pipeline
  checks that the screen is unlocked and, if not, asks the user then,
  instead of finding out within the stage.
  Evidence: 1 run; the drive was blocked by a locked screen through four
  fix rounds, about six hours from the end of implementation (00:30Z to
  06:23Z) · refs: t1-in-app-word-search.

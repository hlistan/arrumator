# Workflow optimizations

The optimizer's archive: every change it proposed, how it was validated, and what happened. **Rejected and reverted
entries stay here** so that ideas which didn't work aren't retried without new evidence. Only `/singularity:optimize`
writes this file.

Entry format:

```markdown
## O-2026-10-13-1 · Add "authorization" review lens · tier 2 · status: canary
- Hypothesis: escaped authz defects come from no reviewer looking specifically for ownership checks
- Change: commit abc1234, review.extra_lenses in .claude/singularity.md
- Targets: category "missing authz check" (4 escaped in last 12 runs); eval cases authz-01..03
- Prediction: replay recall on authz cases 1/3 → 3/3; escaped authz defects → 0 over the next 10 runs
- Risk / counter-metric: reviewer false positives; review tokens +15%
- Validation: replay-evals baseline 1/3 → candidate 3/3; precision cases unchanged; holdout 1/1 → 1/1
- Check after: 10 runs or 2026-11-15
- Result: (filled in at the check)
```

Statuses: `proposed` → `validating` → `adopted` | `canary` | `rejected`; later `extended` or `revert-proposed` →
`reverted`.

## O-2026-10-15-migrate · Lessons to guidelines · tier 1 · adopted

- Change: the pre-0.5.0 lesson log in `.claude/singularity/experience/` (`project.md`, `spec.md`, `plan.md`,
  `implement.md`, `review.md`, `verify.md`) rewritten as guidelines G1–G24 in `.claude/singularity/guidelines/` and in
  the path-scoped rule `.claude/rules/singularity/app.md` (`App/**`); `upstream.md` converted to the 0.5.0 format, each
  candidate with its Evidence line; `CLAUDE.md` imports `.claude/singularity/guidelines/project.md`; `.gitignore`
  re-includes `.claude/rules/`; `experience/README.md` added from the plugin template. Done in the `fix/ui-usability`
  checkout at the request of `/singularity:feature`, uncommitted, so that it ships with that run's change.
- Evidence: one run (`remove-documents`, 2026-10-14), 32 lessons, every one _Seen:_ 1. Each lesson was checked against
  the code at `4ae2edb`: every file and symbol it names exists and nothing contradicts it, so none was dropped. The
  four lessons that said the same thing (the inverse-action rule in spec L2, plan L1, implement L1 and review L2) merged
  into one guideline, G3; the App half of project P3 and implement L6 went to the App rule.
- Validation: `scripts/check-guidelines.sh` clean; the project's `markdownlint-cli2` clean on every file written.
- Record: curation line `O-2026-10-15-migrate` in `runs.jsonl`.

| Lesson | Guideline | Seen | Refs |
|---|---|---|---|
| project P1 | G2 (`guidelines/project.md`) | 1 | remove-documents |
| project P2 | G1 | 1 | remove-documents |
| project P3 | G4; its verify half in G22 | 1 | remove-documents |
| project P4 | G5 | 1 | remove-documents |
| project P5 | G6 | 1 | remove-documents |
| project P6 | G7 | 1 | remove-documents |
| spec L1 | G8 (`guidelines/spec.md`) | 1 | remove-documents |
| spec L2 | G3, merged | 1 | remove-documents |
| spec L3 | G9 | 1 | remove-documents |
| plan L1 | G3, merged | 1 | remove-documents |
| plan L2 | G10 (`guidelines/plan.md`) | 1 | remove-documents |
| implement L1 | G3, merged | 1 | remove-documents |
| implement L2 | G11 (`guidelines/implement.md`) | 1 | remove-documents |
| implement L3 | G12 | 1 | remove-documents |
| implement L4 | G15 | 1 | remove-documents |
| implement L5 | G14 | 1 | remove-documents |
| implement L6 | G23, G24 (`rules/singularity/app.md`) | 1 | remove-documents |
| implement L7 | G13 | 1 | remove-documents |
| implement L8 | G16 | 1 | remove-documents |
| review L1 | G17 (`guidelines/review.md`) | 1 | remove-documents |
| review L2 | G3, merged | 1 | remove-documents |
| review L3 | G18 | 1 | remove-documents |
| review L4 | G19 | 1 | remove-documents |
| review L5 | G20 | 1 | remove-documents |
| review L6 | G21 | 1 | remove-documents |
| verify L1 | G22 (`guidelines/verify.md`) | 1 | remove-documents |
| upstream U1–U6 | U1–U6 in `experience/upstream.md`, 0.5.0 format | 1 each | remove-documents |

## O-2026-10-15-onboard · Onboard the agents · tier 1 · adopted

- Change: `.claude/singularity/goals.md` drafted (`Status: draft`, two TODOs); guidelines G35–G47 added:
  `guidelines/project.md` G35 (scratch home before the app or `arrumatorcli`), `spec.md` G36–G37 (where requirements
  live, what a criterion names), `plan.md` G38–G39 (where new code goes, how a plan ends), `implement.md` G40–G41 (one
  suite, the App's stricter build, regenerating generated files), `review.md` G42–G43 (review by `docs/review/`, where
  a defect costs most), `verify.md` G44 (what a run needs and takes), `.claude/rules/singularity/app.md` G45 (operate
  every control in the built app before review), and the new rule `.claude/rules/singularity/analysis.md` G46–G47
  (eval numbers before and after, reading knowledge never in code); two "Do not touch" entries in
  `.claude/singularity.md` (the user's own folders, Trash and running app; `Tests/Fixtures/private/`). Done in the
  `fix/ui-usability` checkout at the request of `/singularity:feature`, uncommitted, so that it ships with that run's
  change.
- Evidence: the survey in `.agentic/work/optimizer-2026-10-15-onboard/onboarding.md`: README.md, AGENTS.md,
  CONTRIBUTING.md, `docs/`, both run digests, 25 merged pull requests with no human review comment, five QA runs each
  followed by a fix pull request. Every `commands` entry ran in the ui-usability run; `test_one` checked on
  `ConfigTests` (30 tests in 2 suites, 14 s).
- Validation: `scripts/check-guidelines.sh` clean; the project's `markdownlint-cli2` clean on every file written.
- Open: the goals wait for the team's corrections and confirmation; five open questions, four proposals (P1 a
  `pre-bash.sh` guard, tier 3; P2 an `interface` review lens; P3 a `verify.sh` hook for what `--app` adds; P4 a
  `persistence` review lens, tiers 2), the eval-case offer and a CLAUDE.md diff are in `onboarding.md` for the gate.
  An applied proposal gets its own entry, with its contract, as a canary.
- Record: curation line `O-2026-10-15-onboard` in `runs.jsonl`.

## O-2026-10-15-1 · Add an "interface" review lens for `App/` · tier 2 · status: canary

- Hypothesis: usability and accessibility defects in `App/` reach QA runs because no review lens holds a change to
  AGENTS.md §4.7 and `docs/review/swift-apple.md`; a lens that names those rules finds them before a QA run does.
- Change: `review.extra_lenses` in `.claude/singularity.md`: lens `interface`, scoped to diffs touching `App/` (it
  says so and stops otherwise), applied at the onboarding gate on the user's choice (P2 in
  `.agentic/work/optimizer-2026-10-15-onboard/onboarding.md`).
- Targets: the QA findings a review could have found statically: C3-1 (a chip's secondary click offered Search With
  Google and Look Up), C4-1 (a notice from a remembered state), C14-1 (VoiceOver heard symbol names), C5-1 (a list
  sized from a stale layout); the findings categories "stale App state after new action path" (2, remove-documents)
  and "edge state shown wrongly" (1, ui-usability). No eval cases exist yet.
- Prediction: the next QA run by `docs/qa/protocol.md` of App code the pipeline wrote finds fewer than 10 findings of
  severity 2 or more (29 in the run of 2026-10-15, on code that had passed review); the lens reports at least one
  confirmed finding per change to `App/`.
- Risk / counter-metric: review tokens on App changes about +25% (one lens of four; remove-documents spent 2.16M review
  tokens over two rounds); rejected (false-positive) findings from this lens above 1 in 4.
- Validation: canary, no baseline and no eval cases to replay; judged on the QA run named in goal 1 and the next 10
  run digests (`findings` with `lens: interface`, confirmed and rejected).
- Check after: 10 runs or 2026-11-15, or the QA run of `fix/ui-usability`, whichever comes first.
- Result: (filled in at the check)

## O-2026-10-15-2 · Verify hook builds the App when `App/` changed · tier 2 · status: canary

- Hypothesis: `commands.test` (`scripts/verify.sh --no-lint`) never builds the App or runs Periphery, so a verify
  stage covers them only when the verifier reads the config's comment; a hook makes it mechanical.
- Change: `.claude/singularity/hooks/verify.sh` (executable): when the change since `main`, untracked files
  included, touches `App/` or `project.yml`, runs `scripts/tools.sh check xcodegen periphery`,
  `scripts/build-release.sh` and `scripts/deadcode.sh`, what `--app` adds; otherwise says the App build isn't
  needed. Applied at the onboarding gate on the user's choice (P3).
- Targets: the App build failing on code `swift build` passed (ui-usability fix round 1, Swift 6 isolation of a
  `TrailingGroup` key: caught then because the orchestrator ran `--app`); a future verify stage that runs only
  `commands.test` on an App change.
- Prediction: in every run whose change touches `App/` or `project.yml`, the verify stage's table shows the release
  build and the unused-code search (10 of 10 such runs); in runs touching neither, the hook adds under 5 s.
- Risk / counter-metric: verify time +10 to 15 minutes on App changes, already the team's rule (AGENTS.md §4.9); a
  double run if a verifier also runs `scripts/verify.sh --app` by the comment (watch `stages.verify.s`).
- Validation: canary; `shellcheck` clean; run once at the gate on this branch (App changed): took the build path,
  built the release and the command, Periphery found no unused code, exit 0 in 4 min 27 s on this Mac.
- Check after: 10 runs or 2026-11-15.
- Result: (filled in at the check)

## O-2026-10-15-3 · Settle the open onboarding questions · tier 1 · adopted

- Change: CLAUDE.md imports AGENTS.md (`@AGENTS.md`) and gets its two-sentence project paragraph; AGENTS.md §2 steps
  5–6 and the §7 checkbox: a learned rule becomes a check or a guideline in the same change, and AGENTS.md changes only
  by a person from a proposal in the report; `.github/pull_request_template.md` ("Guideline refinement") and
  `docs/review/code-review.md` row 7 follow; seven eval cases in `.claude/singularity/evals/2026-10-15-01` to `-07`
  (5 recall: two escaped defects found by QA, cut to the one file of their merge that holds the defect, and three
  confirmed findings of the ui-usability review as regression cases; 2 precision from rejected findings; case 05 held
  out). Done at the user's request in the `fix/ui-usability` checkout, uncommitted, with the rest of that run.
- Evidence: Q3–Q5 in `.agentic/work/optimizer-2026-10-15-onboard/onboarding.md` › "Answers to Q3–Q5", with sources
  (Claude Code memory, best-practices and sub-agents docs; agents.md; arXiv:2602.11988; Anthropic, "Demystifying evals
  for AI agents"; Hamel Husain's evals FAQ); 13 of 34 subagents in the ui-usability run read AGENTS.md on their own;
  AGENTS.md at 63,770 chars with table cells up to 9,109 chars.
- Validation: `check-guidelines.sh` clean; `markdownlint-cli2` clean on every file touched; every `change.patch` applies
  on its `base` (`git apply --check`). To watch at the next optimization: the import adds about 16k tokens to every
  session and non-Explore subagent; compare review and implement tokens per run with remove-documents and
  ui-usability, and whether findings cite AGENTS.md sections more often.
- Open for the team: shorten AGENTS.md (§3 and §4 are 74% of it) towards the docs' 200-line target; a person adds P1.

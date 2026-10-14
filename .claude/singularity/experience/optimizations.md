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

# Project eval cases

Regression cases built from **real** failures on this project. The learner creates them from escaped defects
(`/singularity:learn <PR/MR>`). The optimizer replays them to prove that a change to the workflow helps and breaks
nothing (`replay-evals` workflow).

One directory per case:

```text
<id>/
  case.md        # frontmatter below + a short note
  change.patch   # git diff <base> <reviewed commit>: the change as it was first reviewed
```

```yaml
---
kind: recall              # recall = the reviewer must find it; precision = known false positive it must NOT flag
lens: security            # the lens expected to catch it
base: <sha on the default branch>
expect: "Endpoint /orders/:id returns other users' orders: no ownership check"
location: src/api/orders.ts:42
holdout: false            # every 5th case is held out; the optimizer never tunes on these
source: "!123 human review, 2026-10-14"
---
```

Rules: cases are only ever added. Editing or deleting one is a human decision (tier 3), because these cases are what
measures the agents.

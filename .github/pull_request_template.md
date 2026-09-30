<!-- markdownlint-disable-file MD041 -- a pull request body starts below the title GitHub already shows -->
## What and why

<!-- The change, and the problem it solves. -->

## Acceptance criteria and proof

<!-- What must be true when this is done, and the command that shows it (a test, an arrumatorcli command, an eval). -->

## Test coverage

<!-- Happy path, boundaries, failures covered; for a fix, how the regression test was shown to fail without it. -->

## What changes for an installed app

<!-- Lost learned state, renamed settings or pipeline.json keys, changed CLI output. "Nothing" is an answer. -->

## Guideline refinement

<!-- The [GUIDELINE REFINEMENT] block from the report (AGENTS.md §2): how this change refined AGENTS.md, if it did. -->

## Checklist

- [ ] `scripts/verify.sh` passes (with `--app` when `App/` or `project.yml` changed, `--checks-only` when
      `scripts/change-scope.sh main` says `checks`)
- [ ] The documentation this change affects is updated in this pull request (AGENTS.md §4.10)
- [ ] Eval numbers before and after are included, if analysis behaviour changed (the prompt, the answer schema and its
      validation, the `analysis` and `labels` settings, the label kinds)
- [ ] No real documents, secrets or machine-local commit identities

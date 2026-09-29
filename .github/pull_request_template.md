<!-- markdownlint-disable-file MD041 -- a pull request body starts below the title GitHub already shows -->
## What and why

<!-- The change, and the problem it solves. -->

## Acceptance criteria and proof

<!-- What must be true when this is done, and the command that shows it (a test, an arrumatorcli command, an eval). -->

## Test coverage

<!-- Happy path, boundaries, failures covered; for a fix, how the regression test was shown to fail without it. -->

## What changes for an installed app

<!-- Lost learned state, renamed settings or pipeline.json keys, changed CLI output. "Nothing" is an answer. -->

## Checklist

- [ ] `scripts/verify.sh` passes (with `--app` when `App/` or `project.yml` changed)
- [ ] The documentation this change affects is updated in this pull request (AGENTS.md §4.10)
- [ ] Eval numbers before and after are included, if placement behaviour changed
- [ ] No real documents, secrets or machine-local commit identities

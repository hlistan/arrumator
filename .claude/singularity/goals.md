# Project goals

Status: confirmed 2026-10-15

Who this project serves and what it is for, so that the agents work towards
what matters here: the spec writer and planner read it, and the singularity
optimizer tunes the whole workflow towards it. The team owns this file. The
optimizer drafts it at onboarding; once the team has checked it, change the
status above to `confirmed <date>`. After that the optimizer only proposes
changes, and a person makes them. Keep it under about 40 lines: it says what
matters, not how the code works.

## Users and the value they get

People who install Arrumator from its GitHub releases to keep their own
documents on a Mac: bills, letters, scans, photos, mail, in any language and
script. They drop a file into Incoming and Arrumator reads it, labels it,
names it, files it and makes it findable by its labels, its words or its
meaning; nothing leaves their Mac and their own Ollama server, and nothing
is ever deleted (README.md).

## Goals now

1. The app works as a first-time user meets it: the six follow-ups of the
   QA run of 2026-10-15 (T1–T6 in `.agentic/tasks/`) ship, and a QA run of
   `fix/ui-usability` by `docs/qa/protocol.md` finds nothing of severity 3
   or 4.
2. Documents are read well, and measurably: `arrumatorcli eval` keeps the
   Standard profile's numbers in `docs/evaluation.md`, and every change to
   analysis shows its numbers before and after.
3. Every merge ships: `main` is green on the Mac and on CI, released on every
   code merge, signed and notarized, with no finding left open.

## Trade-offs

Privacy and the user's files beat everything (AGENTS.md §4.1, §4.2). Then
correctness proven by tests over speed: a change is done when verified, and
every finding is fixed before the merge, whatever its rating (§2, §7).
Maintainability over compatibility: breaking changes are welcome, the user's
files and learned state still migrate (§1). A quiet interface over more of
one: no dashboards, a count only where something waits (§4.7). One small
change per pull request (`docs/review/code-review.md`).

## Constraints

macOS 26 and later, Swift 6 language mode, the App with complete strict
concurrency. Models only through Ollama on this Mac or the local network, no
telemetry, no other network client (AGENTS.md §4.1); profiles that fit a
16 GB Mac (README.md › Requirements). Everything reachable without the
pointer and heard by VoiceOver (§4.7). Documentation changes with the code
(§4.10). Releases signed, notarized, attested and immutable
(`docs/releasing.md`). MIT licence; one maintainer; AGENTS.md binds people
and agents alike.

# Security policy

Arrumator reads people's personal documents: bills, statements, contracts, identity papers. Its promise is that
their content never leaves the machines the user runs, and that no document is ever lost.

## Supported versions

Only the [latest release](https://github.com/hlistan/arrumator/releases/latest) receives fixes. Each merge to `main`
is released, so a fix ships as soon as it is merged.

## Reporting a vulnerability

Please report it privately through
[GitHub's private vulnerability reporting](https://github.com/hlistan/arrumator/security/advisories/new), not in a
public issue. (Maintainers: [Repository settings](docs/repository-settings.md) describes how it is switched
on.) Include what an attacker can do, the steps to reproduce it and the version (`arrumatorcli --version`).
Never attach real documents; the synthetic corpus in `Tests/Fixtures` or its generator can reproduce most problems.

You will get an answer within a week. Once a fix is released, the advisory is published with credit to you, unless
you prefer otherwise.

## What counts

Anything that breaks the guarantees in [AGENTS.md §4](AGENTS.md#4-hard-rules-non-negotiable), in particular:

- document text, file names or metadata reaching anything but the Ollama server the user configured, or that server
  being set to a host outside this Mac and the local network (`OllamaEndpoint.validated`, `NetworkGuardProtocol`);
- document text written to logs, or to diagnostics without the user asking for it;
- a way for a document's content or the model's output to delete a file, write outside the archive and Incoming, or
  choose a path the app did not build from folder codes;
- a release artifact that does not match its `SHA256SUMS` or its build-provenance attestation.

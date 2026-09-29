# Continuous integration and releases

Every pull request is checked, and every merge to `main` is checked again and published as a
[GitHub release](https://github.com/hlistan/arrumator/releases) that anyone can download.

## Pull requests: `.github/workflows/ci.yml`

Two jobs run side by side:

| Job | Runner | What it runs |
|---|---|---|
| Static checks | `macos-26` | `scripts/lint.sh` (guideline gates, secrets across the whole history, SwiftLint, ShellCheck, actionlint, zizmor, markdownlint, links), then `scripts/check-secrets.sh --range` over the pull request's commits, which also refuses machine-local commit identities. |
| Build, test and look for unused code | `xcode-27` | `scripts/verify.sh --app --no-lint`: the package build, the documentation check, every test, the app build and Periphery. |

The build job needs Xcode 27 (Swift 6.4), which GitHub provides on its own `xcode-27` image, in preview; the
`macos-26` image carries Xcode 26 only. Each run prints `xcodebuild -version` and `swift --version`.

## Releases: `.github/workflows/release.yml`

On every push to `main` the workflow:

1. runs the CI workflow above on the merged commit;
2. builds the release with `scripts/release.sh`;
3. attests the build's provenance with [`actions/attest`](https://github.com/actions/attest), so anyone can check a
   download came from this repository's workflow: `gh attestation verify <file> --repo hlistan/arrumator`;
4. publishes `v<version>` with generated release notes and these files:

| File | Contents |
|---|---|
| `Arrumator-<version>.zip` | The app, universal (Apple silicon and Intel). |
| `arrumator-<version>-macos-arm64.zip` | The command line tool and the resource bundles it reads, for Apple silicon. |
| `SHA256SUMS` | Checksums of both: `shasum -a 256 -c SHA256SUMS`. |

Releases run one after another (`concurrency: release`), never cancelled half-way.

### Versions

`MARKETING_VERSION` in `project.yml` sets the major and minor version. The patch number is the number of commits on
`main`, so each merge is released as the next one: with `0.1.0` in `project.yml`, the 42nd commit on `main` is
`0.1.42`. To start a new series, change the major or minor number in `project.yml`. The app shows the version as
`CFBundleShortVersionString`, with the patch number also as `CFBundleVersion`. The command reads it from an
Info.plist linked into its executable (`AppVersion`), and a development build reports `dev`.

### Signing

Without signing secrets, releases are signed ad hoc. They run, but macOS blocks them the first time, and each user has
to allow them once (see [README › Install](../README.md#install)). Signing with a Developer ID and notarizing needs a
paid Apple Developer account. Set these as secrets of the `release` environment (Settings › Environments):

| Secret | Value |
|---|---|
| `DEVELOPER_ID` | The certificate's name, such as `Developer ID Application: Your Name (TEAMID)`. |
| `DEVELOPER_ID_CERTIFICATE_P12` | The Developer ID Application certificate with its private key, exported from Keychain Access as `.p12`, base64-encoded (`base64 -i cert.p12 \| pbcopy`). |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password the `.p12` was exported with. |
| `NOTARY_KEY_P8` | An App Store Connect API key's `.p8` file, as text (Users and Access › Integrations › App Store Connect API, role Developer). |
| `NOTARY_KEY_ID` | That key's ID. |
| `NOTARY_ISSUER` | The issuer ID shown above the keys. |

With them the workflow imports the certificate into a temporary keychain, signs both downloads with the hardened
runtime and a secure timestamp, has Apple notarize them, staples the ticket to the app, and deletes the keychain when
the job ends. The repository's own security settings are in [Repository settings](repository-settings.md). Nothing
signing-related is ever written to the repository: `scripts/check-secrets.sh` refuses `.p12`,
`.p8` and similar files.

### Building a release on a Mac

`scripts/release.sh` builds the same files into `dist/`. It signs ad hoc unless `DEVELOPER_ID` names a certificate in
your keychain. It then needs notarization credentials too: `NOTARY_PROFILE` (a profile saved with
`xcrun notarytool store-credentials`), or `NOTARY_KEY`, `NOTARY_KEY_ID` and `NOTARY_ISSUER` as above, with `NOTARY_KEY`
the `.p8` file's path.

## Dependencies

[Dependabot](../.github/dependabot.yml) proposes weekly updates to the pinned workflow actions and to the Swift
packages, waiting a week after each release of theirs. Workflow actions are pinned to full commit hashes, the only
immutable reference GitHub offers
([GitHub Docs: security hardening](https://docs.github.com/en/actions/reference/security/secure-use)).

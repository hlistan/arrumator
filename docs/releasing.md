# Continuous integration and releases

Every pull request is checked, and so is everything `main` is about to release (always through squash merges, as the
[push protocol](../AGENTS.md#8-push-protocol) requires). Only code is built into a
[GitHub release](https://github.com/hlistan/arrumator/releases) that anyone can download.

## What a change needs: `scripts/change-scope.sh`

Building the app, running every test and looking for unused code take most of a run, and a release adds signing,
notarization and a tag. A change needs them only when it can change what they check or produce.
`scripts/change-scope.sh <base>` reads which files a change touches and says which of three scopes it falls in:

| Scope | The change touches | What runs |
|---|---|---|
| `release` | Code, meaning what goes into the downloads: `Sources/` (the modules, with their bundled defaults and prompts), `App/`, `Package.swift`, `Package.resolved`, `project.yml`, `scripts/build-release.sh`, `scripts/release.sh`. | Every check, the build, every test and the release build; once merged, the release. |
| `build` | No code, but what builds, tests, checks or releases it: `Tests/` (with the fixtures), `Tools/`, `scripts/verify.sh`, `scripts/deadcode.sh`, `scripts/lint.sh`, `scripts/tools.sh` (the tools' pins), `scripts/change-scope.sh` itself, `.periphery.yml`, and both workflows. | Every check, the build, every test and the release build. Never released. |
| `checks` | Anything else: the documentation, the other scripts, the linters' and the secrets check's settings, `Brewfile`. | The static checks and the documentation check (`scripts/verify.sh --checks-only`), which builds only `arrumatorcli` to read its commands. |

The widest scope any file calls for wins. When Git cannot compare the change with its base, the scope is `release`,
so a change is never checked less than it needs. Run it before pushing to see which verify command applies:
`scripts/change-scope.sh main`.

CI decides a pull request's scope with the copy of this script on `main`, never with the pull request's own: a change
to the script, or to what it classes, is scoped as `main` classes it, and takes effect for the pull requests after it
is merged. That covers the scope alone. The workflow, `scripts/verify.sh` and the scripts it runs are the pull
request's own copies, so a change to them is checked by what it changes them to; such a change is scoped `build`,
checked in full, and reviewed before it reaches `main`.

## Pull requests: `.github/workflows/ci.yml`

A Scope job runs `main`'s `scripts/change-scope.sh` against the pull request's base, and two jobs check the change:

| Job | Runner | Time limit | What it runs |
|---|---|---|---|
| Scope | `ubuntu-24.04` | 5 minutes | The scope, as above. |
| Static checks | `xcode-27` | 20 minutes | `scripts/tools.sh`, then `scripts/lint.sh` (guideline gates, imports, secrets across the whole history, SwiftLint, ShellCheck, actionlint, zizmor, markdownlint, links), then `scripts/check-secrets.sh --range` over the pull request's commits, which also refuses machine-local commit identities. Every scope. |
| Build, test and look for unused code | `xcode-27` | 90 minutes | For `release` and `build`: `scripts/verify.sh --app --no-lint`, the package build, the documentation check, every test, `fixturegen --verify` on the corpus, the release build (the app for Apple silicon and Intel in the Release configuration, and the command) and Periphery. For `checks`: `scripts/verify.sh --checks-only --no-lint`, the documentation check alone. |

The repository's settings require both checks by name, so the build job always runs and reports, whatever the scope.
When the Scope job fails, the build job checks in full. Every job has a time limit, so a test or a tool that hangs fails
the run instead of holding a runner for GitHub's six hours.

A pull request builds what a release builds: `scripts/build-release.sh` compiles the app for both architectures in the
Release configuration and the command in release mode, as the release does, so neither the Intel slice nor optimized
code is first compiled after the merge. Signing and notarization are the only steps of a release a pull request does
not run.

GitHub's runners are virtual Macs, and Vision cannot recognise text on them on any device
(`TextRecognition.CRImageReaderError` 9, and an unknown error on the CPU). The tests that need real OCR, and the OCR
checks of `fixturegen --verify`, therefore say so and are skipped there, with that reason in the log; they run on every
physical Mac, which is why the push protocol starts with `scripts/verify.sh --app` on your own Mac. How the app handles
OCR failing, and its CPU fallback, is tested everywhere with a scripted recognizer (`OCRServiceTests`).

## Tools and runners

A check gives the same answer until someone changes it on purpose, so nothing it depends on moves by itself:

- **The tools** the checks and the build run are pinned in `scripts/tools.sh`: each at one version, downloaded from
  its publisher's release and refused unless its SHA-256 (for markdownlint-cli2, the npm registry's SHA-512 integrity)
  is the one written there. markdownlint-cli2's own dependencies are exact versions in its package.json, but npm
  resolves theirs when it installs, checked only against the registry's integrity: that tree is not pinned here.
  The tools are installed into `.tools/`, which Git ignores, and the scripts run them from `.tools/bin`;
  `scripts/lint.sh` fails when one is not installed at its pinned version. To move a tool to a newer release, change
  its row, with the checksum GitHub shows beside the download on the release's page, in a pull request of its own;
  Dependabot does not see these pins. `Brewfile` holds only Node.js, which markdownlint-cli2 runs on.
- **Xcode** is chosen by path, and each macOS job first checks the path is there and stops, naming this section, when
  it is not: every macOS job sets `DEVELOPER_DIR` to Xcode 27.0 on the runner image
  (`/Applications/Xcode_27.0.app`, build 27A266a, as GitHub's
  [image description](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
  lists it), so a newer default Xcode on the image changes nothing until the path changes. Each build job prints the
  image's version, `xcodebuild -version` and `swift --version`.
- **The runners** are named by version, never `-latest`: `ubuntu-24.04`, and `xcode-27`, GitHub's image carrying Xcode
  27, [in public preview](https://github.blog/changelog/2026-07-16-xcode-27-runner-image-now-in-public-preview/).
  GitHub updates an image's other software weekly and offers no way to hold one image version.
- **Periphery**, which `scripts/deadcode.sh` runs, is no longer developed: its repository is archived,
  and Homebrew deprecated its formula on 2026-08-12 and will disable it on 2027-08-12
  ([formula](https://formulae.brew.sh/formula/periphery)). The pin installs the last release, 3.8.0, from its GitHub
  release with its checksum, which does not depend on Homebrew. It reads the index stores Xcode and SwiftPM write, so
  a later Xcode can change their format under it: when `scripts/deadcode.sh` fails for that reason rather than for
  unused code, the unused-code check moves to a maintained fork or another tool, in a change of its own that updates
  this section.

## Releases: `.github/workflows/release.yml`

A release is decided by what `main` holds, not by one push: on every push to `main` the workflow finds the last
release's tag and scopes the change from it to `main`'s head. When that scope is `release`, `main` is built, signed and
published. A run that failed, was cancelled or never ran therefore leaves nothing behind: the next push releases what
it left, and a maintainer can run the workflow at once on `main` (Actions › Release › Run workflow), which does the
same. It runs on `main` alone.

Its jobs hold only what each needs:

| Job | Holds | What it runs |
|---|---|---|
| CI | Read access to the code | The CI workflow above, on the change since the last release; its build job keeps what `scripts/build-release.sh` staged. |
| Sign and notarize | The `release` environment and its signing secrets | `scripts/release.sh` on the staged build: signs, notarizes, staples and packages. It compiles nothing and installs no tool. |
| Publish | The token that writes releases, and the attestation's identity | [`actions/attest`](https://github.com/actions/attest) on the downloads, so anyone can check one came from this repository's workflow (`gh attestation verify <file> --repo hlistan/arrumator`), then `v<version>` with generated release notes and these files: |

| File | Contents |
|---|---|
| `Arrumator-<version>-apple-silicon.zip` | The app for Apple silicon alone, the smaller download. |
| `Arrumator-<version>-universal.zip` | The app for Apple silicon and Intel Macs. |
| `arrumatorcli-<version>-apple-silicon.zip` | The command line tool and the resource bundles it reads, for Apple silicon. |
| `SHA256SUMS` | Checksums of all three: `shasum -a 256 -c SHA256SUMS`. |

Each download carries `NOTICES.txt`, inside the app (`Contents/Resources`) and beside the command: Arrumator's
licence, and the licence and notice files of every Swift package the build resolved (GRDB, Yams and ZIPFoundation
under MIT, swift-argument-parser under Apache 2.0), copied from the very versions the build used.

A merge scoped `build` or `checks` alone is checked and not released; it goes out with the next release that changes
code, whose generated notes list it too. Releases run one after another (`concurrency: release`), never cancelled
half-way.

### Versions

`MARKETING_VERSION` in `project.yml` sets the major and minor version. The patch number is the number of commits on
`main`: with `0.1.0` in `project.yml`, the 42nd commit on `main` is `0.1.42`. Merges that change no code count too, so
patch numbers can skip: `0.1.42` may follow `0.1.39`. To start a new series, change the major or minor number in
`project.yml`. The app shows the version as `CFBundleShortVersionString`, with the patch number also as
`CFBundleVersion`. The command reads it from an Info.plist linked into its executable (`AppVersion`), and a development
build reports `dev`.

### Signing

How a release is signed is said, never inferred from which secrets happen to be set, so a lost secret stops the
release instead of quietly publishing it signed less. The `release` environment's variable `RELEASE_SIGNING` says it:

| `RELEASE_SIGNING` | The release |
|---|---|
| `developer-id` | Signed with a Developer ID, with the hardened runtime and a secure timestamp, notarized by Apple, and the app stapled. The job stops, naming them, when any of the secrets below is missing, and when Apple does not accept a submission, printing Apple's log; it reads Apple's verdict, not only `notarytool`'s exit status, and gives notarization an hour. |
| `ad-hoc` | Signed ad hoc, not notarized. It runs, but macOS blocks it the first time, and each user has to allow it once (see [README › Install](../README.md#install)); the release notes say so. |
| unset or anything else | The release stops before signing. |

Every release so far is signed ad hoc. Until a maintainer does the following, set `RELEASE_SIGNING` to `ad-hoc` to go
on releasing as before; with nothing set, releases stop.

**What the maintainer does to sign with a Developer ID** (it needs a paid Apple Developer account, and admin access to
the repository):

1. **Certificate.** In the Apple Developer account, under Certificates, create a *Developer ID Application*
   certificate, install it in your login keychain, then export it with its private key from Keychain Access as a `.p12`
   with a password.
2. **Notarization key.** In App Store Connect › Users and Access › Integrations › App Store Connect API, create a key
   with the Developer role and download its `.p8` file (it can be downloaded once). Note its key ID and the issuer ID
   shown above the keys.
3. **Environment.** In Settings › Environments › `release`: under **Deployment branches and tags**, choose **Selected
   branches and tags** and add `main` alone, so no other branch's workflow can read the secrets
   ([GitHub Docs: deployment branches](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)).
   Then add the secrets below, and set the variable `RELEASE_SIGNING` to `developer-id`.
4. **Check.** Run the workflow on `main` by hand (Actions › Release › Run workflow); it releases `main` if it holds
   code not yet released, and otherwise stops after CI without signing. The next release then shows "Signed with a
   Developer ID and notarized by Apple" in its notes.

| Secret | Value |
|---|---|
| `DEVELOPER_ID` | The certificate's name, such as `Developer ID Application: Your Name (TEAMID)`. |
| `DEVELOPER_ID_CERTIFICATE_P12` | The Developer ID Application certificate with its private key, exported from Keychain Access as `.p12`, base64-encoded (`base64 -i cert.p12 \| pbcopy`). |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password the `.p12` was exported with. |
| `NOTARY_KEY_P8` | An App Store Connect API key's `.p8` file, as text (Users and Access › Integrations › App Store Connect API, role Developer). |
| `NOTARY_KEY_ID` | That key's ID. |
| `NOTARY_ISSUER` | The issuer ID shown above the keys. |

With them the Sign and notarize job imports the certificate into a temporary keychain, signs every download with the
hardened runtime and a secure timestamp and without the `get-task-allow` entitlement a local build carries, has Apple
notarize them, staples the ticket to the app, and deletes the keychain when the job ends. The repository's own
security settings are in [Repository settings](repository-settings.md). Nothing signing-related is ever written to the
repository: `scripts/check-secrets.sh` refuses `.p12`, `.p8` and similar files.

### Building a release on a Mac

`scripts/build-release.sh` builds what a release ships into `build/Release/stage`, unsigned for distribution, and
`scripts/release.sh` signs, notarizes and packages it into `dist/` (building first when it is given no stage). It
needs `RELEASE_SIGNING`: `ad-hoc`, or `developer-id` with `DEVELOPER_ID` naming a certificate in your keychain and
notarization credentials, `NOTARY_PROFILE` (a profile saved with `xcrun notarytool store-credentials`) or
`NOTARY_KEY`, `NOTARY_KEY_ID` and `NOTARY_ISSUER` as above, with `NOTARY_KEY` the `.p8` file's path.

## Dependencies

Every build uses the Swift packages' versions in `Package.resolved` and refuses any other:
`swift build --force-resolved-versions` for the package, and for the app `xcodebuild
-onlyUsePackageVersionsFromResolvedFile` with the package's `Package.resolved` placed in the generated project. A new
version reaches a build only through a change to `Package.resolved`, reviewed like any other.

[Dependabot](../.github/dependabot.yml) proposes weekly updates to the pinned workflow actions and to the Swift
packages, waiting a week after each release of theirs. Workflow actions are pinned to full commit hashes, the only
immutable reference GitHub offers
([GitHub Docs: security hardening](https://docs.github.com/en/actions/reference/security/secure-use)). The tools in
`scripts/tools.sh` are updated by hand, as [Tools and runners](#tools-and-runners) describes.

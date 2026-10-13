# Repository settings

Some of what keeps the repository safe is switched on in GitHub's settings, not in files, so it is listed here:
two security features, the rules that enforce the push protocol ([AGENTS.md §8](../AGENTS.md#8-push-protocol)),
and what keeps a published release as it was built and lets no one publish one alone. Changing them needs admin access
to [hlistan/arrumator](https://github.com/hlistan/arrumator). The Release workflow reads the release environment's
reviewers and the tag ruleset before it signs anything, and refuses to go on without them; it checks the immutability
of the release it publishes.

## Security features

| Feature | Why Arrumator needs it |
|---|---|
| Private vulnerability reporting | [SECURITY.md](../SECURITY.md) asks for vulnerabilities to be reported privately through it. The form it links to only works while the feature is on. |
| Secret scanning with push protection | GitHub refuses a push that contains a known kind of secret, such as an API key or a private key, before it becomes public. It backs up the checks in `scripts/check-secrets.sh`, including for anyone who pushes without the Git hooks. |

### Turning them on in the browser

Both are in the same place ([GitHub Docs: private vulnerability reporting](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configuring-private-vulnerability-reporting-for-a-repository),
[GitHub Docs: push protection](https://docs.github.com/en/code-security/how-tos/secure-your-secrets/prevent-future-leaks/enabling-push-protection-for-your-repository)):

1. Open the repository on GitHub and click **Settings**.
2. In the sidebar, under **Security and quality**, click **Advanced Security**.
3. Next to **Private vulnerability reporting**, click **Enable**.
4. Next to **Secret Protection**, click **Enable** if it is not on yet.
5. In the **Secret Protection** section, next to **Push protection**, click **Enable** if it is not on yet.

Public repositories get secret scanning and push protection without charge.

### Turning them on from a terminal

With the [GitHub CLI](https://cli.github.com), signed in as an admin of the repository, the same settings are
two calls to the [REST API](https://docs.github.com/en/rest/repos/repos). Private vulnerability reporting:

```bash
gh api --method PUT repos/hlistan/arrumator/private-vulnerability-reporting
```

Secret scanning and push protection:

```bash
gh api --method PATCH repos/hlistan/arrumator --input - <<'JSON'
{"security_and_analysis": {"secret_scanning": {"status": "enabled"},
                           "secret_scanning_push_protection": {"status": "enabled"}}}
JSON
```

### Checking them

```bash
gh api repos/hlistan/arrumator/private-vulnerability-reporting
gh api repos/hlistan/arrumator --jq '.security_and_analysis | {secret_scanning, secret_scanning_push_protection}'
```

When the repository is set up, the first prints `{"enabled":true}`, and both statuses the second prints read
`enabled`.

## Pull requests and `main`

The push protocol puts every change on `main` as the squash merge of a pull request whose checks passed, and removes
the branch afterwards. The pre-push hook stops a direct push to `main` from a clone that ran `scripts/bootstrap.sh`;
these settings stop it for everyone, on the server.

| Setting | Value |
|---|---|
| Merge methods | Squash merging only, with the pull request's title and description as the commit message. |
| Head branches | Deleted automatically once the pull request is merged. |
| Ruleset `main` | On the default branch: changes only through a pull request, merged by squashing; the checks `Static checks` and `Build, test and look for unused code` pass on the latest commit; no force pushes; the branch cannot be deleted. |

### Setting them in the browser

1. **Settings › General**, under **Pull Requests**: clear **Allow merge commits** and **Allow rebase merging**, keep
   **Allow squash merging** with the default message **Pull request title and description**, and tick
   **Automatically delete head branches**.
2. **Settings › Rules › Rulesets › New ruleset › New branch ruleset**: name it `main`, set **Enforcement status** to
   **Active**, and under **Target branches** add **Include default branch**. Then turn on:
   - **Restrict deletions** and **Block force pushes**;
   - **Require a pull request before merging**, with **Allowed merge methods** set to **Squash** only (no approvals are
     required, so a sole maintainer can merge their own pull request);
   - **Require status checks to pass**, with **Require branches to be up to date before merging**, adding the checks
     `Static checks` and `Build, test and look for unused code`. They can be picked once CI has run on a pull request.
3. Click **Create**.

### Setting them from a terminal

```bash
gh api --method PATCH repos/hlistan/arrumator -F allow_squash_merge=true -F allow_merge_commit=false \
  -F allow_rebase_merge=false -F delete_branch_on_merge=true \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY

gh api --method POST repos/hlistan/arrumator/rulesets --input - <<'JSON'
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false,
      "require_code_owner_review": false, "require_last_push_approval": false,
      "required_review_thread_resolution": false, "allowed_merge_methods": ["squash"]}},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": true,
      "required_status_checks": [{"context": "Static checks"},
                                 {"context": "Build, test and look for unused code"}]}}
  ]
}
JSON
```

### Checking them

```bash
gh api repos/hlistan/arrumator --jq '{allow_squash_merge, allow_merge_commit, allow_rebase_merge, delete_branch_on_merge}'
gh api repos/hlistan/arrumator/rules/branches/main --jq '.[].type'
```

The first shows squash merging alone allowed and branch deletion on; the second lists `deletion`,
`non_fast_forward`, `pull_request` and `required_status_checks`.

## Releases

A release is the files its workflow built and attested. Once published, they and its tag never change: otherwise
anyone who can write to the repository, or a token that leaked, could put another file and a `SHA256SUMS` that agrees
with it in its place, or move its tag to another commit.

| Setting | Value |
|---|---|
| Immutable releases | On: a published release's files and tag cannot be changed or deleted ([GitHub Docs: immutable releases](https://docs.github.com/en/code-security/supply-chain-security/understanding-your-software-supply-chain/immutable-releases)). |
| Ruleset `release tags` | On tags `refs/tags/v*`: no update, no force push, no deletion. Creating a tag stays open: the Publish job creates it. |

### Setting them in the browser

1. **Settings › General**, under **Releases**: tick **Enable release immutability**.
2. **Settings › Rules › Rulesets › New ruleset › New tag ruleset**: name it `release tags`, set **Enforcement status**
   to **Active**, and under **Target tags** add the pattern `v*`, excluding nothing. Turn on **Restrict updates**,
   **Restrict deletions** and **Block force pushes**, and leave **Restrict creations** off. Add no one to the
   **Bypass list**, not even admins. Click **Create**.

### Setting them from a terminal

```bash
gh api --method PUT repos/hlistan/arrumator/immutable-releases

gh api --method POST repos/hlistan/arrumator/rulesets --input - <<'JSON'
{
  "name": "release tags",
  "target": "tag",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
  "rules": [{"type": "update"}, {"type": "non_fast_forward"}, {"type": "deletion"}]
}
JSON
```

### Checking them

```bash
gh api repos/hlistan/arrumator/immutable-releases
gh api repos/hlistan/arrumator/rulesets --jq '.[] | select(.target == "tag") | {name, enforcement, id}'
gh api repos/hlistan/arrumator/rulesets/<id> --jq '{include: .conditions.ref_name.include, exclude: .conditions.ref_name.exclude, bypass_actors}'
```

The first prints `"enabled":true`; the second, `release tags` with `active` and its id; the third, for that id,
`refs/tags/v*` included, nothing excluded and no bypass actor. The Release workflow checks all of it but the bypass
list, which GitHub shows to admins alone, so check that here. A release made before immutability was on
stays changeable; `gh release view <tag> --json isImmutable` tells which a release is.

## The `release` environment

The Sign and notarize job of a release is the only job that names the `release` environment, which holds the signing
secrets and the variable `RELEASE_SIGNING` that says how a release is signed
([Continuous integration and releases](releasing.md#signing)). A workflow on any branch can name an environment, so
the environment admits `main` alone; and it waits for a reviewer to approve each signing, so a merge alone, a
workflow's token, or the token or account of anyone who is not a reviewer never signs a release with the Developer ID
and ships it to every user. A reviewer's own account approves, so while one maintainer is the only reviewer and approves
their own runs, the gate is a second look at each release, not a second person: an account of theirs that someone
took over could still approve. A second reviewer, such as an account kept only for approving and signed in with a
hardware security key, with **Prevent self-review** on, makes it a second person:

| Setting | Value |
|---|---|
| Deployment branches and tags | Selected branches and tags: `main`. |
| Required reviewers | The maintainers, one of whom approves each run of the job. A sole maintainer approves their own: leave **Prevent self-review** off until there is a second reviewer, then turn it on. |
| Variable `RELEASE_SIGNING` | `developer-id`, or `ad-hoc` while there is no Developer ID. Unset, every release stops. |
| Secrets | The six that [Signing](releasing.md#signing) lists, when `RELEASE_SIGNING` is `developer-id`. |

### Setting it

[Set up Developer ID signing](releasing.md#set-up-developer-id-signing), parts E and F, sets it step by step: the
branch rule and the reviewers first, then the secrets, then `RELEASE_SIGNING`. Without a Developer ID, set the branch
rule and the reviewers as its steps E1 and E2 say, and `RELEASE_SIGNING` to `ad-hoc`. The reviewers from a terminal,
keeping the branch rule:

```bash
gh api --method PUT repos/hlistan/arrumator/environments/release --input - <<JSON
{"reviewers": [{"type": "User", "id": $(gh api user --jq .id)}], "prevent_self_review": false,
 "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
```

Every account that can approve, or write to the repository, signs in with two-factor authentication: on GitHub,
**Settings › Password and authentication › Two-factor authentication** shows it as enabled.

### Checking it

```bash
gh api repos/hlistan/arrumator/environments/release/deployment-branch-policies --jq '.branch_policies[].name'
gh api repos/hlistan/arrumator/environments/release --jq '[.protection_rules[].type]'
gh variable list --env release --repo hlistan/arrumator
```

The first lists `main` alone; the second holds `required_reviewers` beside `branch_policy`; the third shows
`RELEASE_SIGNING`.

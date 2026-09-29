# Repository settings

Some of what keeps the repository safe is switched on in GitHub's settings, not in files, so it is listed here:
two security features, and the rules that enforce the push protocol ([AGENTS.md §8](../AGENTS.md#8-push-protocol)).
Changing them needs admin access to [hlistan/arrumator](https://github.com/hlistan/arrumator).

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
two calls to the [REST API](https://docs.github.com/en/rest/repos/repos):

```bash
# Private vulnerability reporting
gh api --method PUT repos/hlistan/arrumator/private-vulnerability-reporting

# Secret scanning and push protection
gh api --method PATCH repos/hlistan/arrumator --input - <<'JSON'
{"security_and_analysis": {"secret_scanning": {"status": "enabled"},
                           "secret_scanning_push_protection": {"status": "enabled"}}}
JSON
```

### Checking them

```bash
gh api repos/hlistan/arrumator/private-vulnerability-reporting   # {"enabled":true}
gh api repos/hlistan/arrumator --jq '.security_and_analysis | {secret_scanning, secret_scanning_push_protection}'
```

Both statuses read `enabled` when the repository is set up.

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

The signing secrets for releases are set elsewhere, in the `release` environment, as
[Continuous integration and releases](releasing.md#signing) describes.

# Repository settings

Two security features of the GitHub repository are switched on in its settings, not in files, so they are listed here.
Changing them needs admin access to [hlistan/arrumator](https://github.com/hlistan/arrumator).

| Feature | Why Arrumator needs it |
|---|---|
| Private vulnerability reporting | [SECURITY.md](../SECURITY.md) asks for vulnerabilities to be reported privately through it. The form it links to only works while the feature is on. |
| Secret scanning with push protection | GitHub refuses a push that contains a known kind of secret, such as an API key or a private key, before it becomes public. It backs up the checks in `scripts/check-secrets.sh`, including for anyone who pushes without the Git hooks. |

## Turning them on in the browser

Both are in the same place ([GitHub Docs: private vulnerability reporting](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configuring-private-vulnerability-reporting-for-a-repository),
[GitHub Docs: push protection](https://docs.github.com/en/code-security/how-tos/secure-your-secrets/prevent-future-leaks/enabling-push-protection-for-your-repository)):

1. Open the repository on GitHub and click **Settings**.
2. In the sidebar, under **Security and quality**, click **Advanced Security**.
3. Next to **Private vulnerability reporting**, click **Enable**.
4. Next to **Secret Protection**, click **Enable** if it is not on yet.
5. In the **Secret Protection** section, next to **Push protection**, click **Enable** if it is not on yet.

Public repositories get secret scanning and push protection without charge.

## Turning them on from a terminal

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

## Checking them

```bash
gh api repos/hlistan/arrumator/private-vulnerability-reporting   # {"enabled":true}
gh api repos/hlistan/arrumator --jq '.security_and_analysis | {secret_scanning, secret_scanning_push_protection}'
```

Both statuses read `enabled` when the repository is set up. The signing secrets for releases are set elsewhere, in the
`release` environment, as [Continuous integration and releases](releasing.md#signing) describes.

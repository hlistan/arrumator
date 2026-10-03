#!/bin/sh
# Keeps sensitive information out of the repository: secrets and signing material (gitleaks with .gitleaks.toml),
# real documents (Tests/Fixtures/private) and commit identities that name a person's machine.
#
# Usage: scripts/check-secrets.sh                 every commit, the index, the working tree and untracked files
#        scripts/check-secrets.sh --staged        what is about to be committed (the pre-commit hook)
#        scripts/check-secrets.sh --range <revs…> the commits git log lists for <revs…>, with their authors and
#                                                 committers (the pre-push hook and CI)
set -u

cd "$(dirname "$0")/.." || exit 1
PATH=$PWD/.tools/bin:$PATH

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "check-secrets: gitleaks is not installed (scripts/tools.sh installs it)" >&2
  exit 1
fi

private_fixtures=Tests/Fixtures/private
failed=0

leaks() {
  gitleaks git --no-banner --redact --config .gitleaks.toml "$@" . || failed=1
}

# refuse_private <file list>: real documents kept for evaluation stay on this Mac.
refuse_private() {
  if [ -n "$1" ]; then
    printf 'check-secrets: real documents must not be committed:\n%s\n' "$1" >&2
    failed=1
  fi
}

# identities <revs>: a commit's author and committer are published with it. An address such as
# name@MacBook-Pro.local names the account and the machine it was made on; use your GitHub no-reply address.
identities() {
  bad=$(git log --format='%h %an <%ae> / %cn <%ce>' "$@" |
    grep -E '<[^>]*(\.local|\.localdomain|@localhost|\(none\))>' || true)
  if [ -n "$bad" ]; then
    printf 'check-secrets: these commits carry a machine-local identity:\n%s\n' "$bad" >&2
    echo "Set user.email to your GitHub no-reply address and rewrite them before pushing." >&2
    failed=1
  fi
}

case ${1:-} in
  --staged)
    leaks --pre-commit --staged
    refuse_private "$(git diff --cached --name-only --diff-filter=ACMR -- "$private_fixtures")"
    ;;
  --range)
    shift
    [ $# -ge 1 ] || { echo "usage: scripts/check-secrets.sh --range <revs…>" >&2; exit 2; }
    leaks --log-opts="$*"
    refuse_private "$(git log --format= --name-only --diff-filter=ACMR "$@" -- "$private_fixtures" | sort -u)"
    identities "$@"
    ;;
  "")
    leaks
    leaks --pre-commit --staged
    leaks --pre-commit
    # Files Git does not track yet, but would: gitleaks reads them one by one, since `dir` would walk the builds.
    git ls-files -z --others --exclude-standard |
      xargs -0 -n1 gitleaks dir --no-banner --redact --config .gitleaks.toml || failed=1
    refuse_private "$(git ls-files --cached -- "$private_fixtures")"
    ;;
  *)
    echo "usage: scripts/check-secrets.sh [--staged | --range <revs…>]" >&2
    exit 2
    ;;
esac

exit $failed

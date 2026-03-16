#!/usr/bin/env bash
# Rewrites author/committer metadata on agent commits in recent history.
# Run from inside a git repo on the branch you want to fix.
# Usage: ./rewrite-agent-commits.sh [--since <ref>]
#   Default: looks back through the last 50 commits.
#   --since <ref>: look back to (but not including) <ref>, e.g. origin/main
#
# Identities are resolved dynamically:
#   - YOUR identity: from global git config (user.name / user.email)
#   - Agent identity: from repo-local git config (set by the stewart-copeland installation)

set -euo pipefail

# --- Your identity (from global git config) ---
YOUR_NAME=$(git config --local user.name 2>/dev/null || git config --global user.name 2>/dev/null || true)
YOUR_EMAIL=$(git config --local user.email 2>/dev/null || git config --global user.email 2>/dev/null || true)
if [[ -z "$YOUR_NAME" || -z "$YOUR_EMAIL" ]]; then
  echo "Error: could not determine your identity from git config." >&2
  echo "Run: git config --global user.name 'Your Name'" >&2
  echo "     git config --global user.email 'you@example.com'" >&2
  exit 1
fi

# --- Agent identity (from authenticate-github.sh) ---
AUTH_SCRIPT="$(pwd)/authenticate-github.sh"
if [[ ! -f "$AUTH_SCRIPT" ]]; then
  echo "Error: authenticate-github.sh not found in current directory." >&2; exit 1
fi
AGENT_APP_ID=$(grep -m1 '^APP_ID=' "$AUTH_SCRIPT" | cut -d= -f2 | tr -d '"')
AGENT_OWNER=$(grep -m1 '^OWNER_LOGIN=' "$AUTH_SCRIPT" | cut -d= -f2 | tr -d '"')
if [[ -z "$AGENT_APP_ID" || -z "$AGENT_OWNER" ]]; then
  echo "Error: could not parse APP_ID / OWNER_LOGIN from $AUTH_SCRIPT" >&2; exit 1
fi
AGENT_USER="${AGENT_OWNER}-agent[bot]"
# Match pattern strips "[bot]" for a cleaner grep anchor across varied email formats
AGENT_PATTERN="${AGENT_OWNER}-agent"

echo "Your identity  : $YOUR_NAME <$YOUR_EMAIL>"
echo "Agent identity : $AGENT_USER  (app id $AGENT_APP_ID, from $AUTH_SCRIPT)"
echo

LIMIT=50

# Parse optional --since argument
SINCE_REF=""
if [[ "${1:-}" == "--since" && -n "${2:-}" ]]; then
  SINCE_REF="$2"
fi

# Build the range of commits to inspect
if [[ -n "$SINCE_REF" ]]; then
  RANGE="${SINCE_REF}..HEAD"
else
  RANGE="HEAD~${LIMIT}..HEAD"
fi

# Collect commits that have agent identity in author or committer
mapfile -t AGENT_COMMITS < <(
  git log --format="%H %an <%ae> | %cn <%ce>" "$RANGE" 2>/dev/null \
    | grep -i "$AGENT_PATTERN" \
    | awk '{print $1}'
)

if [[ ${#AGENT_COMMITS[@]} -eq 0 ]]; then
  echo "No agent commits found in range $RANGE."
  exit 0
fi

echo "Found ${#AGENT_COMMITS[@]} agent commit(s) to rewrite:"
for sha in "${AGENT_COMMITS[@]}"; do
  git log --format="  %h  %an <%ae>  |  %cn <%ce>  %s" -1 "$sha"
done
echo
read -r -p "Press ENTER to rewrite history, or Ctrl-C to abort... "

# Use git filter-branch with an env filter to rewrite only those commits
AGENT_SHA_LIST=$(printf '%s\n' "${AGENT_COMMITS[@]}")

export YOUR_NAME YOUR_EMAIL AGENT_SHA_LIST AGENT_PATTERN

git filter-branch --force --env-filter '
  if echo "$AGENT_SHA_LIST" | grep -qx "$GIT_COMMIT"; then
    if echo "$GIT_AUTHOR_NAME $GIT_AUTHOR_EMAIL" | grep -qi "$AGENT_PATTERN"; then
      export GIT_AUTHOR_NAME="$YOUR_NAME"
      export GIT_AUTHOR_EMAIL="$YOUR_EMAIL"
    fi
    if echo "$GIT_COMMITTER_NAME $GIT_COMMITTER_EMAIL" | grep -qi "$AGENT_PATTERN"; then
      export GIT_COMMITTER_NAME="$YOUR_NAME"
      export GIT_COMMITTER_EMAIL="$YOUR_EMAIL"
    fi
  fi
' "$RANGE"

echo
echo "Done. Rewrote ${#AGENT_COMMITS[@]} commit(s)."
echo "Verify with: git log --format='%h %an <%ae> | %cn <%ce>' $RANGE"

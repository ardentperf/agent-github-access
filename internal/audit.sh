#!/usr/bin/env bash
# audit.sh — checks that every repo the agent app is installed on has the
# expected branch protection rulesets. Exits non-zero if any are missing.
#
# Called by .github/workflows/audit.yml with GH_APP_ID and GH_APP_PEM_B64
# set from Actions secrets. Can also be run locally with those vars exported.
set -euo pipefail

if [[ -z "${GH_APP_ID:-}" || -z "${GH_APP_PEM_B64:-}" ]]; then
  echo "Error: GH_APP_ID and GH_APP_PEM_B64 must be set." >&2
  echo "Run install.sh to populate them." >&2
  exit 1
fi

# ── Build JWT ─────────────────────────────────────────────────────────────────
APP_PEM=$(printf '%s' "$GH_APP_PEM_B64" | base64 -d)
NOW=$(date +%s)
EXP=$((NOW + 540))

b64url() { base64 | tr '+/' '-_' | tr -d '=\n'; }

HEADER=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":%d}' "$NOW" "$EXP" "$GH_APP_ID" | b64url)

TMPKEY=$(mktemp); chmod 600 "$TMPKEY"
printf '%s' "$APP_PEM" > "$TMPKEY"
SIG=$(printf '%s.%s' "$HEADER" "$PAYLOAD" \
  | openssl dgst -binary -sha256 -sign "$TMPKEY" | b64url)
rm -f "$TMPKEY"
JWT="${HEADER}.${PAYLOAD}.${SIG}"

# ── Get installation ID and token ─────────────────────────────────────────────
INSTALL_ID=$(curl -sf \
  -H "Authorization: Bearer ${JWT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations" \
  | jq -r '.[0].id // empty')

if [[ -z "$INSTALL_ID" ]]; then
  echo "Error: no installation found for this app." >&2
  exit 1
fi

INSTALL_TOKEN=$(curl -sf -X POST \
  -H "Authorization: Bearer ${JWT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" \
  | jq -r '.token')

# ── Check each installed repo for expected rulesets ───────────────────────────
REPOS=$(curl -sf \
  -H "Authorization: Bearer ${INSTALL_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/installation/repositories" \
  | jq -r '.repositories[].full_name')

FAIL=0
while IFS= read -r repo; do
  COUNT=$(curl -sf \
    -H "Authorization: Bearer ${INSTALL_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${repo}/rulesets" \
    | jq '[.[] | select(
        .name == "agent-gh-access-apps-blocked-from-non-ai-branches" or
        .name == "agent-gh-access-apps-must-sign"
      )] | length')
  if [[ "$COUNT" -eq 2 ]]; then
    echo "PASS  ${repo}"
  else
    echo "FAIL  ${repo} — missing rulesets (found ${COUNT}/2)"
    FAIL=1
  fi
done <<< "$REPOS"

if [[ "$FAIL" -eq 1 ]]; then
  echo ""
  echo "One or more repos are missing required rulesets." >&2
  echo "Run ./onboard-repo.sh <repo> for each failing repo." >&2
  exit 1
fi

echo ""
echo "All installed repos have required branch protection rulesets."

# ── Update onboarded-repos.txt inventory ──────────────────────────────────────
# Only runs inside GitHub Actions (GITHUB_TOKEN is available).
# First line is a comment with the app ID — if it changes (app recreated),
# the file is reset so the inventory reflects only the current app.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  INVENTORY="onboarded-repos.txt"
  HEADER_LINE="# app-id:${GH_APP_ID}"

  # Reset if app ID changed or file doesn't exist
  if [[ ! -f "$INVENTORY" ]] || [[ "$(head -1 "$INVENTORY")" != "$HEADER_LINE" ]]; then
    printf '%s\n' "$HEADER_LINE" > "$INVENTORY"
  fi

  # Merge current repos into inventory (cumulative, no removals)
  while IFS= read -r repo; do
    if ! grep -qxF "$repo" "$INVENTORY"; then
      echo "$repo" >> "$INVENTORY"
    fi
  done <<< "$REPOS"

  # Commit if anything changed
  git config user.name  "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"
  git add "$INVENTORY"
  if ! git diff --cached --quiet; then
    git commit -m "chore: update onboarded-repos inventory"
    git push
  fi
fi

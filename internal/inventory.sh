#!/usr/bin/env bash
# inventory.sh — checks that every repo the agent app is installed on has the
# expected branch protection rulesets. Exits non-zero if any are missing.
#
# Called by .github/workflows/inventory.yml with GH_APP_ID and GH_APP_PEM_B64
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
INSTALL_ID=$(curl -sS --fail-with-body \
  -H "Authorization: Bearer ${JWT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations" \
  | jq -r '.[0].id // empty')

if [[ -z "$INSTALL_ID" ]]; then
  echo "Error: no installation found for this app." >&2
  exit 1
fi

INSTALL_TOKEN=$(curl -sS --fail-with-body -X POST \
  -H "Authorization: Bearer ${JWT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" \
  | jq -r '.token')

if [[ -z "$INSTALL_TOKEN" || "$INSTALL_TOKEN" == "null" ]]; then
  echo "Error: failed to obtain installation token." >&2
  exit 1
fi

# ── Check each installed repo for expected rulesets ───────────────────────────
REPOS=$(curl -sS --fail-with-body \
  -H "Authorization: Bearer ${INSTALL_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/installation/repositories" \
  | jq -r '.repositories[].full_name')

FAIL=0
while IFS= read -r repo; do
  COUNT=$(curl -sS --fail-with-body \
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

# ── Update inventory branch ───────────────────────────────────────────────────
# Only runs inside GitHub Actions (GITHUB_TOKEN is available).
# Writes the README inventory file to a dedicated agent branch via the Contents API
# so the branch tip is always a signed commit (required by the
# agent-gh-access-apps-must-sign ruleset). The branch must already exist —
# install.sh initializes it using the install PAT (human-authed, no signing
# requirement). If the branch or file is missing, exit non-zero.
# First line is a comment with the app ID — if it changes (app recreated),
# the file is reset so the inventory reflects only the current app.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  echo "Updating inventory branch..."
  OWNER_LOGIN=$(curl -sS --fail-with-body \
    -H "Authorization: Bearer ${INSTALL_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/installation/repositories" \
    | jq -r '.repositories[0].owner.login')
  FORK_REPO="${OWNER_LOGIN}/stewart-copeland-ai-police"
  INV_BRANCH="x-ai/${OWNER_LOGIN}/__inventory__do-not-delete"
  # Fetch current inventory — branch must exist (initialized by install.sh)
  echo "Fetching current inventory..."
  INV_FETCH_RESPONSE=$(curl -sS \
    -H "Authorization: Bearer ${INSTALL_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${FORK_REPO}/contents/README?ref=${INV_BRANCH}" \
    2>/dev/null || true)
  CURRENT_FILE_SHA=$(printf '%s' "$INV_FETCH_RESPONSE" | jq -r '.sha // empty')
  CURRENT_INV=$(printf '%s' "$INV_FETCH_RESPONSE" | jq -r '.content // empty' | base64 -d 2>/dev/null || true)

  if [[ -z "$CURRENT_FILE_SHA" ]]; then
    echo "Error: inventory branch or file not found (${INV_BRANCH})." >&2
    echo "  Run install.sh to initialize the inventory branch before running the inventory workflow." >&2
    exit 1
  fi

  # Normalize: ensure CURRENT_INV ends with a newline (base64 -d strips it)
  [[ -n "$CURRENT_INV" && "${CURRENT_INV: -1}" != $'\n' ]] && CURRENT_INV="${CURRENT_INV}"$'\n'
  NEW_INV="$CURRENT_INV"

  # Merge current repos into inventory (cumulative, no removals)
  while IFS= read -r repo; do
    if ! printf '%s' "$NEW_INV" | grep -qxF "$repo"; then
      NEW_INV="${NEW_INV}${repo}"$'\n'
    fi
  done <<< "$REPOS"

  # Only update if content changed
  if [[ "$NEW_INV" != "$CURRENT_INV" ]]; then
    FILE_CONTENT=$(printf '%s' "$NEW_INV" | base64 | tr -d '\n')
    CONTENTS_PAYLOAD="{\"message\":\"chore: update onboarded-repos inventory\",\"content\":\"${FILE_CONTENT}\",\"sha\":\"${CURRENT_FILE_SHA}\",\"branch\":\"${INV_BRANCH}\"}"

    # Write via Contents API — GitHub signs this commit automatically
    echo "Creating commit..."
    curl -sS --fail-with-body -X PUT \
      -H "Authorization: Bearer ${INSTALL_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" \
      -d "$CONTENTS_PAYLOAD" \
      "https://api.github.com/repos/${FORK_REPO}/contents/README" > /dev/null

    echo "Inventory updated on branch ${INV_BRANCH}."
  else
    echo "Inventory unchanged."
  fi
fi

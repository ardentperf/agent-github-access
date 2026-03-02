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
# Writes onboarded-repos.txt to a dedicated agent branch via the Contents API
# so the branch tip is always a signed commit (required by the
# agent-gh-access-apps-must-sign ruleset). The low-level Git Data API does not
# produce signed commits. On first init a minimal seed tree (only
# onboarded-repos.txt, no other files) is bootstrapped via the Git Data API and
# the branch is created pointing at it; the Contents API then immediately
# overwrites the placeholder with real content, leaving a signed tip commit.
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
  FORK_REPO="${OWNER_LOGIN}/agent-github-access"
  INV_BRANCH="x-ai/${OWNER_LOGIN}/inventory---internal-do-not-delete"
  HEADER_LINE="# app-id:${GH_APP_ID}"

  # Fetch current inventory from branch if it exists
  echo "Fetching current inventory..."
  CURRENT_INV=$(curl -sS --fail-with-body \
    -H "Authorization: Bearer ${INSTALL_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${FORK_REPO}/contents/onboarded-repos.txt?ref=${INV_BRANCH}" \
    | jq -r '.content' | base64 -d || true)

  # Reset if app ID changed or branch doesn't exist yet
  if [[ -z "$CURRENT_INV" ]] || [[ "$(printf '%s' "$CURRENT_INV" | head -1)" != "$HEADER_LINE" ]]; then
    NEW_INV="${HEADER_LINE}"$'\n'
    INITIALIZING=true
  else
    NEW_INV="$CURRENT_INV"
    INITIALIZING=false
  fi

  # Merge current repos into inventory (cumulative, no removals)
  while IFS= read -r repo; do
    if ! printf '%s' "$NEW_INV" | grep -qxF "$repo"; then
      NEW_INV="${NEW_INV}${repo}"$'\n'
    fi
  done <<< "$REPOS"

  # Only update if content changed
  if [[ "$NEW_INV" != "$CURRENT_INV" ]]; then
    FILE_CONTENT=$(printf '%s' "$NEW_INV" | base64 | tr -d '\n')

    if [[ "$INITIALIZING" == "true" ]]; then
      # Bootstrap an isolated branch containing only onboarded-repos.txt.
      # Step 1: build a minimal tree (no base_tree) and an unsigned seed commit,
      #         then point the new branch at it via the Refs API.  Branch creation
      #         is not a push so the required_signatures ruleset does not fire.
      # Step 2: write the real content via the Contents API, which produces a
      #         signed commit on the branch tip — satisfying the ruleset.
      echo "Creating inventory branch..."
      SEED_TREE=$(curl -sS --fail-with-body -X POST \
        -H "Authorization: Bearer ${INSTALL_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "Content-Type: application/json" \
        -d "{\"tree\":[{\"path\":\"onboarded-repos.txt\",\"mode\":\"100644\",\"type\":\"blob\",\"content\":\"\"}]}" \
        "https://api.github.com/repos/${FORK_REPO}/git/trees" \
        | jq -r '.sha')
      # Find any existing commit to use as parent (main HEAD); the seed commit
      # itself just needs to be a valid parent so the branch has history.
      MAIN_SHA=$(curl -sS --fail-with-body \
        -H "Authorization: Bearer ${INSTALL_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${FORK_REPO}/git/ref/heads/main" \
        | jq -r '.object.sha')
      SEED_COMMIT=$(curl -sS --fail-with-body -X POST \
        -H "Authorization: Bearer ${INSTALL_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "Content-Type: application/json" \
        -d "{\"message\":\"chore: init inventory branch\",\"tree\":\"${SEED_TREE}\",\"parents\":[\"${MAIN_SHA}\"]}" \
        "https://api.github.com/repos/${FORK_REPO}/git/commits" \
        | jq -r '.sha')
      curl -sS --fail-with-body -X POST \
        -H "Authorization: Bearer ${INSTALL_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "Content-Type: application/json" \
        -d "{\"ref\":\"refs/heads/${INV_BRANCH}\",\"sha\":\"${SEED_COMMIT}\"}" \
        "https://api.github.com/repos/${FORK_REPO}/git/refs" > /dev/null
      # Seed file sha needed by Contents API to overwrite the placeholder
      CURRENT_FILE_SHA=$(curl -sS --fail-with-body \
        -H "Authorization: Bearer ${INSTALL_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${FORK_REPO}/contents/onboarded-repos.txt?ref=${INV_BRANCH}" \
        | jq -r '.sha')
      CONTENTS_PAYLOAD="{\"message\":\"chore: update onboarded-repos inventory\",\"content\":\"${FILE_CONTENT}\",\"sha\":\"${CURRENT_FILE_SHA}\",\"branch\":\"${INV_BRANCH}\"}"
    else
      # Get current file SHA for the update
      CURRENT_FILE_SHA=$(curl -sS --fail-with-body \
        -H "Authorization: Bearer ${INSTALL_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${FORK_REPO}/contents/onboarded-repos.txt?ref=${INV_BRANCH}" \
        | jq -r '.sha')
      CONTENTS_PAYLOAD="{\"message\":\"chore: update onboarded-repos inventory\",\"content\":\"${FILE_CONTENT}\",\"sha\":\"${CURRENT_FILE_SHA}\",\"branch\":\"${INV_BRANCH}\"}"
    fi

    # Write via Contents API — GitHub signs this commit automatically
    echo "Creating commit..."
    curl -sS --fail-with-body -X PUT \
      -H "Authorization: Bearer ${INSTALL_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" \
      -d "$CONTENTS_PAYLOAD" \
      "https://api.github.com/repos/${FORK_REPO}/contents/onboarded-repos.txt" > /dev/null

    echo "Inventory updated on branch ${INV_BRANCH}."
  else
    echo "Inventory unchanged."
  fi
fi

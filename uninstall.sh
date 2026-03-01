#!/usr/bin/env bash
# uninstall.sh — removes all agent-github-access state after the GitHub App has
# been deleted. Run this after deleting the app in the GitHub UI.
#
# What it does:
#   1. Reads the app slug and ID from onboarded-repos.txt
#   2. Verifies the GitHub App no longer exists (polls until confirmed)
#   3. Deletes GH_APP_ID and GH_APP_PEM secrets from the agent-github-access fork
#   4. Deletes the two agent-gh-access-* rulesets from every repo in the inventory
#
# Requires: gh CLI authenticated with the fine-grained PAT used during setup
#   (Administration read/write + Secrets read/write on agent-github-access fork)
set -euo pipefail

INVENTORY="onboarded-repos.txt"
OWNER_LOGIN=$(gh api user --jq '.login')
FORK_REPO="${OWNER_LOGIN}/agent-github-access"

# ── Fetch latest inventory from fork ─────────────────────────────────────────
echo "Fetching latest inventory from ${FORK_REPO}…"
REMOTE_INV=$(gh api "/repos/${FORK_REPO}/contents/${INVENTORY}" \
  --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)
if [[ -n "$REMOTE_INV" ]]; then
  printf '%s' "$REMOTE_INV" > "$INVENTORY"
  echo "  ✓ Inventory updated from fork."
elif [[ ! -f "$INVENTORY" ]]; then
  echo "Error: ${INVENTORY} not found locally or in fork." >&2
  echo "  Ensure the inventory workflow has run at least once." >&2
  exit 1
else
  echo "  – Could not fetch from fork; using local copy."
fi
echo ""

# ── Read app ID and derive slug ───────────────────────────────────────────────
if [[ ! -f "$INVENTORY" ]]; then
  echo "Error: ${INVENTORY} not found." >&2
  exit 1
fi

HEADER=$(head -1 "$INVENTORY")
if [[ "$HEADER" != "# app-id:"* ]]; then
  echo "Error: ${INVENTORY} has unexpected format (first line: ${HEADER})" >&2
  exit 1
fi

APP_ID="${HEADER#\# app-id:}"
APP_SLUG="${OWNER_LOGIN}-agent"

echo "App ID:   ${APP_ID}"
echo "App slug: ${APP_SLUG}"
echo "Owner:    ${OWNER_LOGIN}"
echo ""

# ── Verify the app has been deleted ──────────────────────────────────────────
# GET /apps/{slug} is public and returns 404 once the app is gone.
echo "Checking if GitHub App '${APP_SLUG}' still exists…"
while true; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/apps/${APP_SLUG}")
  if [[ "$STATUS" == "404" ]]; then
    echo "  ✓ App not found — confirmed deleted."
    break
  fi
  echo "  App still exists (HTTP ${STATUS})."
  echo "  Delete it at: https://github.com/settings/apps/${APP_SLUG}"
  echo "    Settings → Developer settings → GitHub Apps → ${APP_SLUG}"
  echo "    → Edit → Advanced → Delete GitHub App"
  echo ""
  printf "  Press Enter to check again, or Ctrl-C to abort: "
  read -r
done
echo ""

# ── Delete secrets from fork ──────────────────────────────────────────────────
echo "Deleting secrets from ${FORK_REPO}…"
for secret in GH_APP_ID GH_APP_PEM; do
  if gh api "/repos/${FORK_REPO}/actions/secrets/${secret}" --silent 2>/dev/null; then
    gh api --method DELETE "/repos/${FORK_REPO}/actions/secrets/${secret}" --silent
    echo "  ✓ Deleted secret: ${secret}"
  else
    echo "  – Secret already absent: ${secret}"
  fi
done
echo ""

# ── Delete rulesets from every inventoried repo ───────────────────────────────
REPOS=$(tail -n +2 "$INVENTORY")
if [[ -z "$REPOS" ]]; then
  echo "No repos in inventory — nothing to clean up."
else
  echo "Removing rulesets from inventoried repos…"
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    for ruleset in \
      "agent-gh-access-apps-blocked-from-non-ai-branches" \
      "agent-gh-access-apps-must-sign"
    do
      ruleset_id=$(gh api "/repos/${repo}/rulesets" \
        --jq ".[] | select(.name == \"${ruleset}\") | .id" 2>/dev/null | head -1 || true)
      if [[ -n "$ruleset_id" ]]; then
        gh api --method DELETE "/repos/${repo}/rulesets/${ruleset_id}" --silent
        echo "  ✓ ${repo}: deleted ${ruleset}"
      else
        echo "  – ${repo}: ${ruleset} not found"
      fi
    done
  done <<< "$REPOS"
fi
echo ""

echo "Cleanup complete."
echo "You may now delete your agent-github-access fork if it is no longer needed."

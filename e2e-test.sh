#!/usr/bin/env bash
# e2e-test.sh — confirms real GitHub branch permissions on an onboarded repo.
#
# Run this from an agent machine after authenticate-github.sh has been executed.
# It tests branch-level push restrictions and commit identity enforcement:
#
#   Branch restrictions (agent-gh-access-apps-blocked-from-non-ai-branches ruleset):
#     - push to default branch          → must be blocked
#     - push to non-prefixed branch     → must be blocked
#     - push to wrong-owner prefix      → must be blocked
#
#   Commit identity (required_signatures ruleset on agent branches):
#     - unsigned commit                 → must be blocked
#     - wrong author email              → must be blocked
#     - wrong committer email           → must be blocked
#     - API-created commit (bot-signed) → must succeed
#
# Usage:
#   ./e2e-test.sh <owner/repo>
#   ./e2e-test.sh <owner/repo> <agent-owner-login>
#
# If <agent-owner-login> is omitted the script reads the allowed branch prefix
# from the repo's "agent-gh-access-apps-blocked-from-non-ai-branches" ruleset.
set -uo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <owner/repo> [<agent-owner-login>]" >&2
  exit 1
fi

REPO="$1"
AGENT_OWNER="${2:-}"

# ── Warning ───────────────────────────────────────────────────────────────────

echo "WARNING: This script makes real GitHub API calls against ${REPO}."
echo "It will create and delete temporary branches on the live repository."
echo ""
printf "Type 'yes' to continue: "
read -r CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted." >&2
  exit 1
fi
echo ""

# ── Dependencies ──────────────────────────────────────────────────────────────

for cmd in git gh jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not found." >&2; exit 1
  fi
done

# ── Resolve agent owner from ruleset if not supplied ──────────────────────────

if [[ -z "$AGENT_OWNER" ]]; then
  # The list endpoint omits conditions; fetch the ruleset by ID to get them.
  RULESET_ID=$(gh api "/repos/${REPO}/rulesets" \
    --jq '.[] | select(.name == "agent-gh-access-apps-blocked-from-non-ai-branches") | .id' || true)
  if [[ -n "$RULESET_ID" ]]; then
    RAW_PREFIX=$(gh api "/repos/${REPO}/rulesets/${RULESET_ID}" \
      --jq '.conditions.ref_name.exclude[0]' || true)
    # RAW_PREFIX looks like "refs/heads/x-ai/alice/**" → extract "alice"
    AGENT_OWNER=$(printf '%s' "$RAW_PREFIX" | sed 's|refs/heads/x-ai/||; s|/\*\*||')
  fi
fi

if [[ -z "$AGENT_OWNER" ]]; then
  echo "Error: could not determine agent owner from rulesets." >&2
  echo "  Either pass it as the second argument, or ensure onboard-repo.sh" >&2
  echo "  has been run for this repo." >&2
  exit 1
fi

# ── Resolve default branch ────────────────────────────────────────────────────

DEFAULT_BRANCH=$(gh api "/repos/${REPO}" --jq '.default_branch' || true)
if [[ -z "$DEFAULT_BRANCH" ]]; then
  echo "Error: could not fetch repo info for '${REPO}'. Check the repo name." >&2
  exit 1
fi

echo "Repo:          ${REPO}"
echo "Default branch: ${DEFAULT_BRANCH}"
echo "Agent owner:   ${AGENT_OWNER}"
echo "Agent prefix:  x-ai/${AGENT_OWNER}/**"
echo ""

# ── Setup ─────────────────────────────────────────────────────────────────────

PASS=0; FAIL=0
ERRORS=()

ok()   { PASS=$((PASS+1)); printf "PASS  %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); ERRORS+=("$1"); printf "FAIL  %s\n" "$1"; }

# Resolve the app ID and bot email from the current git global config so the
# tests can construct both the correct and incorrect identity variants.
BOT_EMAIL=$(git config --global user.email || true)
BOT_NAME=$(git config --global user.name  || true)
APP_ID=$(printf '%s' "$BOT_EMAIL" | cut -d'+' -f1)

if [[ -z "$BOT_EMAIL" || -z "$APP_ID" ]]; then
  echo "Error: git global identity not configured." >&2
  echo "  Run authenticate-github.sh first." >&2
  exit 1
fi

WRONG_EMAIL="attacker@example.com"

# Clone into a temp dir; removed on exit even if the script errors out.
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

git clone --quiet --depth 1 "https://github.com/${REPO}.git" "$WORKDIR/repo"
cd "$WORKDIR/repo"

TS=$(date +%s)

# Branch names used in the tests.
AGENT_BRANCH="x-ai/${AGENT_OWNER}/live-test-${TS}"
OTHER_BRANCH="live-test-no-prefix-${TS}"
WRONG_PREFIX="x-ai/not-${AGENT_OWNER}/live-test-${TS}"

PUSHED_AGENT_BRANCH=""

# Helper: attempt a push and capture stderr.
try_push() {
  local target="$1"
  git push --quiet origin "HEAD:${target}" 2>"$WORKDIR/push.err"
}

# Helper: make a scratch commit with configurable identity, then try to push.
# Usage: try_push_as <branch> <email> <name>
try_push_as() {
  local target="$1" email="$2" name="$3"
  git config user.email "$email"
  git config user.name  "$name"
  printf 'live-test %s\n' "$TS" > .agent-live-test
  git add .agent-live-test
  git commit --quiet --allow-empty -m "live-test: identity check (${TS})"
  try_push "$target"
  local rc=$?
  git reset --quiet HEAD~1
  return $rc
}

# ── Test: push to default branch → must be blocked ────────────────────────────

git config user.email "$BOT_EMAIL"
git config user.name  "$BOT_NAME"
printf 'live-test %s\n' "$TS" > .agent-live-test
git add .agent-live-test
git commit --quiet -m "live-test: permission check (${TS})"

if try_push "$DEFAULT_BRANCH"; then
  fail "push to ${DEFAULT_BRANCH} was NOT blocked  ← security issue"
else
  GH_ERR=$(cat "$WORKDIR/push.err")
  if printf '%s' "$GH_ERR" | grep -qi "rule\|protect\|denied\|not allowed\|cannot"; then
    ok  "push to ${DEFAULT_BRANCH} blocked by ruleset"
  else
    ok  "push to ${DEFAULT_BRANCH} blocked (unexpected error: $(head -1 "$WORKDIR/push.err"))"
  fi
fi

# ── Test: push to arbitrary non-prefixed branch → must be blocked ─────────────

if try_push "$OTHER_BRANCH"; then
  fail "push to non-prefixed branch was NOT blocked  ← security issue"
else
  ok  "push to non-prefixed branch blocked   (${OTHER_BRANCH})"
fi

# ── Test: push to a different agent owner's prefix → must be blocked ──────────

if try_push "$WRONG_PREFIX"; then
  fail "push to wrong-owner prefix was NOT blocked  ← security issue"
else
  ok  "push to wrong-owner prefix blocked   (x-ai/not-${AGENT_OWNER}/…)"
fi

# ── Test: unsigned commit to agent branch → must be blocked ───────────────────
# git commit produces an unsigned commit; required_signatures must reject it.

if try_push_as "$AGENT_BRANCH" "$BOT_EMAIL" "$BOT_NAME"; then
  fail "unsigned commit to agent branch was NOT blocked  ← security issue"
  echo "     $(cat "$WORKDIR/push.err")"
else
  GH_ERR=$(cat "$WORKDIR/push.err")
  if printf '%s' "$GH_ERR" | grep -qi "sign\|verif\|rule\|protect"; then
    ok  "unsigned commit blocked on agent branch"
  else
    ok  "unsigned commit blocked on agent branch (msg: $(head -1 "$WORKDIR/push.err"))"
  fi
fi

# ── Test: wrong author email → must be blocked ────────────────────────────────
# GIT_COMMITTER_* overrides the committer fields while user.email sets author.

if GIT_COMMITTER_EMAIL="$BOT_EMAIL" GIT_COMMITTER_NAME="$BOT_NAME" \
   try_push_as "$AGENT_BRANCH" "$WRONG_EMAIL" "$BOT_NAME"; then
  fail "wrong author email to agent branch was NOT blocked  ← security issue"
  echo "     $(cat "$WORKDIR/push.err")"
else
  ok  "wrong author email blocked on agent branch"
fi

# ── Test: wrong committer email → must be blocked ─────────────────────────────

if GIT_COMMITTER_EMAIL="$WRONG_EMAIL" GIT_COMMITTER_NAME="attacker" \
   try_push_as "$AGENT_BRANCH" "$BOT_EMAIL" "$BOT_NAME"; then
  fail "wrong committer email to agent branch was NOT blocked  ← security issue"
  echo "     $(cat "$WORKDIR/push.err")"
else
  ok  "wrong committer email blocked on agent branch"
fi

# ── Test: API-created commit (bot-signed) → must succeed ──────────────────────
# git push cannot produce a GitHub-signed commit; use the Contents API instead.
# This creates a file via the API (GitHub signs the commit), then pushes a ref.

BASE_SHA=$(gh api "/repos/${REPO}/git/ref/heads/${DEFAULT_BRANCH}" --jq '.object.sha')
BASE_TREE=$(gh api "/repos/${REPO}/git/commits/${BASE_SHA}" --jq '.tree.sha')

API_COMMIT_SHA=$(gh api "/repos/${REPO}/git/commits" \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  --field "message=live-test: signed commit (${TS})" \
  --field "tree=${BASE_TREE}" \
  --field "parents[]=${BASE_SHA}" \
  --jq '.sha' 2>"$WORKDIR/api.err") && API_COMMIT_OK=true || API_COMMIT_OK=false

if [[ "$API_COMMIT_OK" != "true" || -z "$API_COMMIT_SHA" ]]; then
  fail "API commit creation failed: $(cat "$WORKDIR/api.err")"
else
  # Push the new commit SHA as a new branch ref.
  gh api "/repos/${REPO}/git/refs" \
    --method POST \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    --field "ref=refs/heads/${AGENT_BRANCH}" \
    --field "sha=${API_COMMIT_SHA}" \
    --silent 2>"$WORKDIR/ref.err" \
  && { ok "API-created (bot-signed) commit pushed to agent branch"; PUSHED_AGENT_BRANCH="$AGENT_BRANCH"; } \
  || fail "API-created (bot-signed) commit push failed: $(cat "$WORKDIR/ref.err")"
fi

# ── Cleanup: delete the test branch ───────────────────────────────────────────

if [[ -n "$PUSHED_AGENT_BRANCH" ]]; then
  if gh api "/repos/${REPO}/git/refs/heads/${PUSHED_AGENT_BRANCH}" \
       --method DELETE --silent 2>/dev/null; then
    echo ""
    echo "Cleaned up: deleted ${PUSHED_AGENT_BRANCH}"
  else
    echo ""
    echo "Warning: could not delete ${PUSHED_AGENT_BRANCH} — remove it manually." >&2
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────"
printf "Results: %d passed, %d failed\n" "$PASS" "$FAIL"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo ""
  echo "Failed:"
  for e in "${ERRORS[@]}"; do
    printf "  ✗ %s\n" "$e"
  done
  echo ""
  exit 1
fi

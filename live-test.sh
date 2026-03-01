#!/usr/bin/env bash
# live-test.sh — confirms real GitHub branch permissions on an onboarded repo.
#
# Run this from an agent machine after authenticate-github.sh has been executed.
# It clones the repo, makes a scratch commit, then pushes to several branch
# targets — confirming which are allowed and which are blocked by the rulesets.
#
# Usage:
#   ./live-test.sh <owner/repo>
#   ./live-test.sh <owner/repo> <agent-owner-login>
#
# If <agent-owner-login> is omitted the script reads the allowed branch prefix
# from the repo's "agent-allowed-on-agent-branches" ruleset.
set -uo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <owner/repo> [<agent-owner-login>]" >&2
  exit 1
fi

REPO="$1"
AGENT_OWNER="${2:-}"

# ── Dependencies ──────────────────────────────────────────────────────────────

for cmd in git gh jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not found." >&2; exit 1
  fi
done

# ── Resolve agent owner from ruleset if not supplied ──────────────────────────

if [[ -z "$AGENT_OWNER" ]]; then
  RAW_PREFIX=$(gh api "/repos/${REPO}/rulesets" \
    --jq '.[] | select(.name == "agent-allowed-on-agent-branches")
               | .conditions.ref_name.include[0]' 2>/dev/null || true)
  # RAW_PREFIX looks like "x-ai/alice/**" → extract "alice"
  AGENT_OWNER=$(printf '%s' "$RAW_PREFIX" | sed 's|x-ai/||; s|/\*\*||')
fi

if [[ -z "$AGENT_OWNER" ]]; then
  echo "Error: could not determine agent owner from rulesets." >&2
  echo "  Either pass it as the second argument, or ensure onboard-repo.sh" >&2
  echo "  has been run for this repo." >&2
  exit 1
fi

# ── Resolve default branch ────────────────────────────────────────────────────

DEFAULT_BRANCH=$(gh api "/repos/${REPO}" --jq '.default_branch' 2>/dev/null || true)
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

# Clone into a temp dir; removed on exit even if the script errors out.
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

git clone --quiet --depth 1 "https://github.com/${REPO}.git" "$WORKDIR/repo"
cd "$WORKDIR/repo"

# Configure git identity for the test commit (required even without signing).
git config user.email "live-test@agent-live-test.invalid"
git config user.name  "Agent Live Test"

# Make a scratch commit to push around.
TS=$(date +%s)
printf 'live-test %s\n' "$TS" > .agent-live-test
git add .agent-live-test
git commit --quiet -m "live-test: permission check (${TS})"

# Branch names used in the tests.
AGENT_BRANCH="x-ai/${AGENT_OWNER}/live-test-${TS}"
OTHER_BRANCH="live-test-no-prefix-${TS}"
WRONG_PREFIX="x-ai/not-${AGENT_OWNER}/live-test-${TS}"

PUSHED_AGENT_BRANCH=""

# Helper: attempt a push and capture stderr for display on failures.
try_push() {
  local target="$1"
  git push --quiet origin "HEAD:${target}" 2>"$WORKDIR/push.err"
}

# ── Test: push to agent branch → must succeed ─────────────────────────────────

if try_push "$AGENT_BRANCH"; then
  ok  "push to agent branch allowed   (x-ai/${AGENT_OWNER}/…)"
  PUSHED_AGENT_BRANCH="$AGENT_BRANCH"
else
  fail "push to agent branch allowed   (x-ai/${AGENT_OWNER}/…)"
  echo "     $(cat "$WORKDIR/push.err")"
fi

# ── Test: push to default branch → must be blocked ────────────────────────────

if try_push "$DEFAULT_BRANCH"; then
  fail "push to ${DEFAULT_BRANCH} was NOT blocked  ← security issue"
else
  GH_ERR=$(cat "$WORKDIR/push.err")
  if printf '%s' "$GH_ERR" | grep -qi "rule\|protect\|denied\|not allowed\|cannot"; then
    ok  "push to ${DEFAULT_BRANCH} blocked by ruleset"
  else
    # Push failed but not with a recognisable ruleset message — still a pass
    # because the push was rejected, but flag the unexpected message.
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
# The bypass in ruleset B is scoped to x-ai/${AGENT_OWNER}/**.
# Another owner's prefix should still be covered by ruleset A (block all).

if try_push "$WRONG_PREFIX"; then
  fail "push to wrong-owner prefix was NOT blocked  ← security issue"
else
  ok  "push to wrong-owner prefix blocked   (x-ai/not-${AGENT_OWNER}/…)"
fi

# ── Cleanup: delete the test branch ───────────────────────────────────────────

if [[ -n "$PUSHED_AGENT_BRANCH" ]]; then
  if git push --quiet origin --delete "$PUSHED_AGENT_BRANCH" 2>/dev/null; then
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

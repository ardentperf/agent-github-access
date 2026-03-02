#!/usr/bin/env bash
# e2e-test.sh — confirms real GitHub branch permissions on the agent-github-access repo.
#
# Tests branch-level push restrictions and commit identity enforcement:
#
#   Branch restrictions (agent-gh-access-apps-blocked-from-non-ai-branches ruleset):
#     - push to default branch          → must be blocked
#     - push to non-prefixed branch     → must be blocked
#     - push to wrong-owner prefix      → must be blocked
#
#   Commit identity (agent-gh-access-apps-must-sign ruleset on agent branches):
#     - unsigned commit                 → must be blocked
#     - wrong author email              → must be blocked
#     - wrong committer email           → must be blocked
#     - API-created commit (bot-signed) → must succeed
#
# Credentials (in priority order):
#   1. GH_APP_ID + GH_APP_PEM_B64 env vars (set by CI from Actions secrets)
#   2. ~/authenticate-github.sh (extracts embedded APP_ID and APP_PEM_B64)
#
# Usage (local):
#   bash tests/e2e-test.sh
#   GH_APP_ID=... GH_APP_PEM_B64=... bash tests/e2e-test.sh
set -uo pipefail

REPO="ardentperf/agent-github-access"

# ── Dependencies ──────────────────────────────────────────────────────────────

for cmd in git gh jq curl openssl base64; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not found." >&2; exit 1
  fi
done

# ── Credential resolution ─────────────────────────────────────────────────────
# Priority: env vars (CI) → ~/authenticate-github.sh (local)

if [[ -z "${GH_APP_ID:-}" || -z "${GH_APP_PEM_B64:-}" ]]; then
  AUTH_SCRIPT="$HOME/authenticate-github.sh"
  if [[ ! -f "$AUTH_SCRIPT" ]]; then
    echo "Error: credentials not found." >&2
    echo "  Set GH_APP_ID and GH_APP_PEM_B64, or ensure ~/authenticate-github.sh exists." >&2
    exit 1
  fi
  GH_APP_ID=$(grep '^APP_ID=' "$AUTH_SCRIPT" | cut -d'"' -f2)
  GH_APP_PEM_B64=$(grep '^APP_PEM_B64=' "$AUTH_SCRIPT" | cut -d'"' -f2)
  OWNER_LOGIN=$(grep '^OWNER_LOGIN=' "$AUTH_SCRIPT" | cut -d'"' -f2)
  echo "Credentials: ~/authenticate-github.sh"
  echo "  APP_ID:      ${GH_APP_ID}"
  echo "  APP_PEM_B64: ${#GH_APP_PEM_B64} chars"
  if [[ -z "$GH_APP_ID" || -z "$GH_APP_PEM_B64" || -z "$OWNER_LOGIN" ]]; then
    echo "Error: could not parse credentials from $AUTH_SCRIPT." >&2
    exit 1
  fi
else
  echo "Credentials: environment variables"
  echo "  GH_APP_ID:      ${GH_APP_ID}"
  echo "  GH_APP_PEM_B64: ${#GH_APP_PEM_B64} chars"
  # Derive owner login from the app slug via the public /apps/{slug} endpoint.
  # The slug is <owner>-agent by convention; we need the owner for branch naming.
  OWNER_LOGIN=$(curl -sf \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/app/installations" \
    -H "Authorization: Bearer $(
      APP_PEM=$(printf '%s' "$GH_APP_PEM_B64" | base64 -d)
      NOW=$(date +%s); EXP=$((NOW + 540))
      b64url() { base64 | tr '+/' '-_' | tr -d '=\n'; }
      HDR=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
      PAY=$(printf '{"iat":%d,"exp":%d,"iss":%d}' "$NOW" "$EXP" "$GH_APP_ID" | b64url)
      TMP=$(mktemp); chmod 600 "$TMP"; printf '%s' "$APP_PEM" > "$TMP"
      SIG=$(printf '%s.%s' "$HDR" "$PAY" | openssl dgst -binary -sha256 -sign "$TMP" | b64url)
      rm -f "$TMP"; printf '%s.%s.%s' "$HDR" "$PAY" "$SIG"
    )" \
    | jq -r '.[0].account.login // empty')
  if [[ -z "$OWNER_LOGIN" ]]; then
    echo "Error: could not determine owner login from app installations." >&2
    exit 1
  fi
fi

# ── Build JWT and get installation token ──────────────────────────────────────

APP_PEM=$(printf '%s' "$GH_APP_PEM_B64" | base64 -d)
NOW=$(date +%s); EXP=$((NOW + 540))

b64url() { base64 | tr '+/' '-_' | tr -d '=\n'; }

JWT_HDR=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
JWT_PAY=$(printf '{"iat":%d,"exp":%d,"iss":%d}' "$NOW" "$EXP" "$GH_APP_ID" | b64url)
TMPKEY=$(mktemp); chmod 600 "$TMPKEY"; printf '%s' "$APP_PEM" > "$TMPKEY"
JWT_SIG=$(printf '%s.%s' "$JWT_HDR" "$JWT_PAY" | openssl dgst -binary -sha256 -sign "$TMPKEY" | b64url)
rm -f "$TMPKEY"
JWT="${JWT_HDR}.${JWT_PAY}.${JWT_SIG}"

INSTALL_ID=$(curl -sf \
  -H "Authorization: Bearer ${JWT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations" \
  | jq -r --arg owner "$OWNER_LOGIN" \
    '.[] | select(.account.login == $owner) | .id')

if [[ -z "$INSTALL_ID" ]]; then
  echo "Error: no installation found for owner '${OWNER_LOGIN}'." >&2
  exit 1
fi

INSTALL_TOKEN=$(curl -sf -X POST \
  -H "Authorization: Bearer ${JWT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" \
  | jq -r '.token')

# Configure gh CLI and git with the installation token
printf '%s' "$INSTALL_TOKEN" | gh auth login --hostname github.com --with-token

APP_ID_NUM="$GH_APP_ID"
BOT_EMAIL="${APP_ID_NUM}+${OWNER_LOGIN}-agent[bot]@users.noreply.github.com"
BOT_NAME="${OWNER_LOGIN}-agent[bot]"
git config --global user.email "$BOT_EMAIL"
git config --global user.name  "$BOT_NAME"
git config --global credential.https://github.com.helper store
printf 'https://x-access-token:%s@github.com\n' "$INSTALL_TOKEN" >> "$HOME/.git-credentials"

# ── Setup ─────────────────────────────────────────────────────────────────────

AGENT_OWNER="$OWNER_LOGIN"

DEFAULT_BRANCH=$(gh api "/repos/${REPO}" --jq '.default_branch')

echo "Repo:           ${REPO}"
echo "Default branch: ${DEFAULT_BRANCH}"
echo "Agent owner:    ${AGENT_OWNER}"
echo "Agent prefix:   x-ai/${AGENT_OWNER}/**"
echo ""

PASS=0; FAIL=0
ERRORS=()

ok()   { PASS=$((PASS+1)); printf "PASS  %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); ERRORS+=("$1"); printf "FAIL  %s\n" "$1"; }

WRONG_EMAIL="attacker@example.com"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

git clone --quiet --depth 1 "https://github.com/${REPO}.git" "$WORKDIR/repo"
cd "$WORKDIR/repo"

TS=$(date +%s)

AGENT_BRANCH="x-ai/${AGENT_OWNER}/e2e-test-${TS}"
OTHER_BRANCH="e2e-test-no-prefix-${TS}"
WRONG_PREFIX="x-ai/not-${AGENT_OWNER}/e2e-test-${TS}"

PUSHED_AGENT_BRANCH=""

try_push() {
  local target="$1"
  git push --quiet origin "HEAD:${target}" 2>"$WORKDIR/push.err"
}

try_push_as() {
  local target="$1" email="$2" name="$3"
  git config user.email "$email"
  git config user.name  "$name"
  printf 'e2e-test %s\n' "$TS" > .agent-e2e-test
  git add .agent-e2e-test
  git commit --quiet --allow-empty -m "e2e-test: identity check (${TS})"
  try_push "$target"
  local rc=$?
  git reset --quiet HEAD~1
  return $rc
}

# ── Test: push to default branch → must be blocked ────────────────────────────

git config user.email "$BOT_EMAIL"
git config user.name  "$BOT_NAME"
printf 'e2e-test %s\n' "$TS" > .agent-e2e-test
git add .agent-e2e-test
git commit --quiet -m "e2e-test: permission check (${TS})"

if try_push "$DEFAULT_BRANCH"; then
  fail "push to ${DEFAULT_BRANCH} was NOT blocked  ← security issue"
else
  GH_ERR=$(cat "$WORKDIR/push.err")
  if printf '%s' "$GH_ERR" | grep -qi "rule\|protect\|denied\|not allowed\|cannot"; then
    ok  "push to ${DEFAULT_BRANCH} blocked by ruleset"
  else
    ok  "push to ${DEFAULT_BRANCH} blocked (msg: $(head -1 "$WORKDIR/push.err"))"
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

BASE_SHA=$(gh api "/repos/${REPO}/git/ref/heads/${DEFAULT_BRANCH}" --jq '.object.sha')
BASE_TREE=$(gh api "/repos/${REPO}/git/commits/${BASE_SHA}" --jq '.tree.sha')

API_COMMIT_SHA=$(gh api "/repos/${REPO}/git/commits" \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  --field "message=e2e-test: signed commit (${TS})" \
  --field "tree=${BASE_TREE}" \
  --field "parents[]=${BASE_SHA}" \
  --jq '.sha' 2>"$WORKDIR/api.err") && API_COMMIT_OK=true || API_COMMIT_OK=false

if [[ "$API_COMMIT_OK" != "true" || -z "$API_COMMIT_SHA" ]]; then
  fail "API commit creation failed: $(cat "$WORKDIR/api.err")"
else
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

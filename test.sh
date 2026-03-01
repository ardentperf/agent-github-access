#!/usr/bin/env bash
# test.sh — offline tests for agent-github-access scripts
#
# Runs create-agent-app.sh for real (with mocked gh and browser) to generate
# authenticate-github.sh and onboard-repo.sh, then tests their behaviour with
# mocked network calls.  No real GitHub API calls are made.
#
# Requirements: bash, python3, openssl, jq, curl, base64
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ERRORS=()

ok()   { PASS=$((PASS+1)); printf "PASS  %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); ERRORS+=("$1"); printf "FAIL  %s\n" "$1"; }

# ── Setup ─────────────────────────────────────────────────────────────────────

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT

TEST_APP_ID="999888"
TEST_OWNER="testowner"
TEST_SLUG="${TEST_OWNER}-agent"

# A real RSA key is required — openssl uses it to sign JWTs in the generated script.
TEST_KEY_FILE="$TMPDIR_T/test.pem"
openssl genrsa -out "$TEST_KEY_FILE" 2048 2>/dev/null

# Write the fake /app-manifests/.../conversions response to a file so the mock
# gh can cat it.  python3 handles JSON-escaping the PEM (newlines etc).
CONVERSION_JSON="$TMPDIR_T/conversion.json"
python3 - "$TEST_KEY_FILE" "$TEST_APP_ID" "$TEST_SLUG" "$CONVERSION_JSON" << 'PYEOF'
import json, sys
key_file, app_id, slug, out = sys.argv[1:]
pem = open(key_file).read()
with open(out, 'w') as f:
    json.dump({"id": int(app_id), "slug": slug, "pem": pem}, f)
PYEOF

# ── Mock binaries for create-agent-app.sh ─────────────────────────────────────

MAIN_BIN="$TMPDIR_T/main-bin"
mkdir -p "$MAIN_BIN"

# gh: return testowner for login lookup; serve conversion JSON for manifest exchange.
cat > "$MAIN_BIN/gh" << GHEOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"user"* && "\$args" == *".login"* ]]; then
  printf '%s' "${TEST_OWNER}"
elif [[ "\$args" == *"app-manifests"* ]]; then
  cat "${CONVERSION_JSON}"
fi
exit 0
GHEOF
chmod +x "$MAIN_BIN/gh"

# xdg-open: for file:// URLs, simulate the OAuth callback instead of opening a
# browser. The real Python HTTP server is already running and will write the code
# to CODEFILE, unblocking `wait $SERVER_PID` in create-agent-app.sh.
# For the https:// installation URL opened at the end, do nothing.
cat > "$MAIN_BIN/xdg-open" << 'XDGEOF'
#!/usr/bin/env bash
if [[ "$1" == http://localhost:* ]]; then
  PORT="${1#http://localhost:}"
  PORT="${PORT%%/*}"
  sleep 0.3
  curl -sf "http://localhost:${PORT}/callback?code=testcode123" > /dev/null || true
fi
XDGEOF
chmod +x "$MAIN_BIN/xdg-open"

# ── 1. Syntax: create-agent-app.sh ────────────────────────────────────────────

bash -n "$DIR/create-agent-app.sh" 2>/dev/null \
  && ok  "syntax: create-agent-app.sh" \
  || fail "syntax: create-agent-app.sh"

# ── 2. Run create-agent-app.sh to generate both scripts ───────────────────────
# Pass TEST_OWNER as the username arg to skip the multi-account check.
# Run from a work dir so the generated scripts land there, not in the repo root.

WORK="$TMPDIR_T/work"
mkdir -p "$WORK"

GEN_OUTPUT=$(PATH="$MAIN_BIN:$PATH" bash "$DIR/create-agent-app.sh" "$TEST_OWNER" 2>&1) || true

TEST_AUTH="$WORK/authenticate-github.sh"
TEST_ONBOARD="$WORK/onboard-repo.sh"

# create-agent-app.sh writes to cwd, so move them if needed
[[ -f "authenticate-github.sh" ]] && mv authenticate-github.sh "$TEST_AUTH"
[[ -f "onboard-repo.sh"        ]] && mv onboard-repo.sh        "$TEST_ONBOARD"

if [[ -f "$TEST_AUTH" ]]; then
  ok  "generate: authenticate-github.sh produced"
else
  fail "generate: authenticate-github.sh produced"
fi

if [[ -f "$TEST_ONBOARD" ]]; then
  ok  "generate: onboard-repo.sh produced"
else
  fail "generate: onboard-repo.sh produced"
fi

# ── 3. Syntax: generated scripts ──────────────────────────────────────────────

bash -n "$TEST_AUTH" 2>/dev/null \
  && ok  "syntax: authenticate-github.sh" \
  || fail "syntax: authenticate-github.sh"

bash -n "$TEST_ONBOARD" 2>/dev/null \
  && ok  "syntax: onboard-repo.sh" \
  || fail "syntax: onboard-repo.sh"

# ── 4. JWT format ─────────────────────────────────────────────────────────────
# Run the JWT construction logic in a subshell using the test key.  No network.

JWT_RESULT=$(bash << BEOF
set -euo pipefail
APP_PEM=\$(cat "$TEST_KEY_FILE")
APP_ID="$TEST_APP_ID"
NOW=\$(date +%s)
EXP=\$((NOW + 540))

b64url() { base64 | tr '+/' '-_' | tr -d '=\n'; }
HEADER=\$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
PAYLOAD=\$(printf '{"iat":%d,"exp":%d,"iss":%d}' "\$NOW" "\$EXP" "\$APP_ID" | b64url)

TMPKEY=\$(mktemp)
chmod 600 "\$TMPKEY"
printf '%s' "\$APP_PEM" > "\$TMPKEY"
SIG=\$(printf '%s.%s' "\$HEADER" "\$PAYLOAD" | openssl dgst -binary -sha256 -sign "\$TMPKEY" | b64url)
rm -f "\$TMPKEY"

printf '%s.%s.%s' "\$HEADER" "\$PAYLOAD" "\$SIG"
BEOF
)

if [[ "$JWT_RESULT" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
  ok  "jwt: three-part base64url format"
else
  fail "jwt: three-part base64url format (got: ${JWT_RESULT:0:40}…)"
fi

JWT_HEADER_PART="${JWT_RESULT%%.*}"
PADDED="${JWT_HEADER_PART}==="
DECODED=$(printf '%s' "$PADDED" | tr '_-' '/+' | base64 -d 2>/dev/null || \
          printf '%s' "$PADDED" | tr '_-' '/+' | base64 -D 2>/dev/null)
if printf '%s' "$DECODED" | grep -q '"RS256"'; then
  ok  "jwt: header contains RS256"
else
  fail "jwt: header contains RS256 (got: $DECODED)"
fi

# ── Mock bin for authenticate-github.sh tests (curl-based) ────────────────────

MOCK_BIN="$TMPDIR_T/bin"
mkdir -p "$MOCK_BIN"

# ── 5. Error: no installations ────────────────────────────────────────────────

cat > "$MOCK_BIN/curl" << 'EOF'
#!/usr/bin/env bash
printf '[]'
exit 0
EOF
chmod +x "$MOCK_BIN/curl"

NO_INST_OUTPUT=$(PATH="$MOCK_BIN:$PATH" bash "$TEST_AUTH" 2>&1 || true)
NO_INST_EXIT=$(PATH="$MOCK_BIN:$PATH" bash "$TEST_AUTH" > /dev/null 2>&1; echo $?)

[[ "$NO_INST_EXIT" != "0" ]] \
  && ok  "no-installations: exits non-zero" \
  || fail "no-installations: exits non-zero"

printf '%s' "$NO_INST_OUTPUT" | grep -q "no repositories configured" \
  && ok  "no-installations: error mentions 'no repositories configured'" \
  || fail "no-installations: error mentions 'no repositories configured'"

printf '%s' "$NO_INST_OUTPUT" | grep -q "trusted machine" \
  && ok  "no-installations: error mentions 'trusted machine'" \
  || fail "no-installations: error mentions 'trusted machine'"

# ── 6. Error: no protected repos ──────────────────────────────────────────────

cat > "$MOCK_BIN/curl" << MOCKEOF
#!/usr/bin/env bash
if [[ "\$*" == *"/app/installations" ]]; then
  printf '[{"id":42,"account":{"login":"${TEST_OWNER}","type":"User"}}]'
elif [[ "\$*" == *"/access_tokens" ]]; then
  printf '{"token":"ghs_faketoken123"}'
elif [[ "\$*" == *"/installation/repositories" ]]; then
  printf '{"repositories":[{"id":101,"full_name":"${TEST_OWNER}/testrepo"}]}'
elif [[ "\$*" == */rulesets ]]; then
  printf '[]'
else
  printf '{}'
fi
exit 0
MOCKEOF
chmod +x "$MOCK_BIN/curl"

NO_RULES_OUTPUT=$(PATH="$MOCK_BIN:$PATH" bash "$TEST_AUTH" 2>&1 || true)
NO_RULES_EXIT=$(PATH="$MOCK_BIN:$PATH" bash "$TEST_AUTH" > /dev/null 2>&1; echo $?)

[[ "$NO_RULES_EXIT" != "0" ]] \
  && ok  "no-protected-repos: exits non-zero" \
  || fail "no-protected-repos: exits non-zero"

printf '%s' "$NO_RULES_OUTPUT" | grep -qi "onboard-repo" \
  && ok  "no-protected-repos: error mentions onboard-repo" \
  || fail "no-protected-repos: error mentions onboard-repo"

# ── 7. Output content: global memory bookends and branch prefix ───────────────

cat > "$MOCK_BIN/curl" << MOCKEOF
#!/usr/bin/env bash
if [[ "\$*" == *"/app/installations" ]]; then
  printf '[{"id":42,"account":{"login":"${TEST_OWNER}","type":"User"}}]'
elif [[ "\$*" == *"/access_tokens" ]]; then
  printf '{"token":"ghs_faketoken123"}'
elif [[ "\$*" == *"/installation/repositories" ]]; then
  printf '{"repositories":[{"id":101,"full_name":"${TEST_OWNER}/testrepo"}]}'
elif [[ "\$*" == */rulesets ]]; then
  printf '[{"name":"agent-blocked-from-non-agent-branches"}]'
else
  printf '{}'
fi
exit 0
MOCKEOF
chmod +x "$MOCK_BIN/curl"

cat > "$MOCK_BIN/git" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MOCK_BIN/git"

cat > "$MOCK_BIN/gh" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MOCK_BIN/gh"

SUCCESS_OUTPUT=$(PATH="$MOCK_BIN:$PATH" bash "$TEST_AUTH" 2>&1 || true)

printf '%s' "$SUCCESS_OUTPUT" | grep -q "STORE IN GLOBAL MEMORY" \
  && ok  "output: opens with STORE IN GLOBAL MEMORY directive" \
  || fail "output: opens with STORE IN GLOBAL MEMORY directive"

printf '%s' "$SUCCESS_OUTPUT" | grep -q "STORE THE ABOVE IN GLOBAL MEMORY" \
  && ok  "output: closes with STORE THE ABOVE IN GLOBAL MEMORY directive" \
  || fail "output: closes with STORE THE ABOVE IN GLOBAL MEMORY directive"

printf '%s' "$SUCCESS_OUTPUT" | grep -q "x-ai/${TEST_OWNER}/" \
  && ok  "output: branch prefix contains owner login" \
  || fail "output: branch prefix contains owner login"

for trigger in \
  "Invalid username or password" \
  "Authentication failed" \
  "Bad credentials" \
  "gh auth login"
do
  printf '%s' "$SUCCESS_OUTPUT" | grep -q "$trigger" \
    && ok  "output: error trigger present — '${trigger}'" \
    || fail "output: error trigger present — '${trigger}'"
done

OPEN_LINE=$(printf '%s' "$SUCCESS_OUTPUT" | grep -n "STORE IN GLOBAL MEMORY" | head -1 | cut -d: -f1)
CLOSE_LINE=$(printf '%s' "$SUCCESS_OUTPUT" | grep -n "STORE THE ABOVE IN GLOBAL MEMORY" | head -1 | cut -d: -f1)
[[ -n "$OPEN_LINE" && -n "$CLOSE_LINE" && "$OPEN_LINE" -lt "$CLOSE_LINE" ]] \
  && ok  "output: opening directive precedes closing directive" \
  || fail "output: opening directive precedes closing directive (open=$OPEN_LINE close=$CLOSE_LINE)"

# ═══════════════════════════════════════════════════════════════════════════════
# onboard-repo.sh tests
# ═══════════════════════════════════════════════════════════════════════════════

# ── Helper: write a mock gh that records ruleset-creation calls ────────────────
# $1 = path to write the mock
# $2 = "exists" | "no-fork" | "not-a-fork"
# $3 = "has-install" | "no-install"
# $4 = "has-existing-ruleset" | "" (whether TARGET_REPO already has the ruleset)
write_mock_gh() {
  local mock_path="$1" fork_state="$2" install_state="$3" ruleset_state="${4:-}"
  local install_id
  [[ "$install_state" == "has-install" ]] && install_id="55" || install_id=""

  cat > "$mock_path" << GHEOF
#!/usr/bin/env bash
RULESET_LOG="${TMPDIR_T}/rulesets.log"
REMOVED_LOG="${TMPDIR_T}/removed.log"
DELETED_RULESET_LOG="${TMPDIR_T}/deleted_ruleset.log"
args="\$*"

if [[ "\$args" == *"/repos/${TEST_OWNER}/testrepo"* && "\$args" != *"rulesets"* && "\$args" != *"select"* ]]; then
  exit 0
fi

if [[ "\$args" == *"/repos/${TEST_OWNER}/extrepo"* && "\$args" != *"rulesets"* && "\$args" != *"select"* ]]; then
  case "${fork_state}" in
    no-fork)     exit 1 ;;
    not-a-fork)  [[ "\$args" == *"parent.full_name"* ]] && printf '' || true; exit 0 ;;
    exists)      [[ "\$args" == *"parent.full_name"* ]] && printf 'otherowner/extrepo' || true; exit 0 ;;
  esac
fi

# Remove repo from installation (audit) — checked before other /installations handlers
if [[ "\$args" == *"--method DELETE"* && "\$args" == *"installations"* ]]; then
  echo "repo-removed" >> "\$REMOVED_LOG"
  exit 0
fi

# Delete a ruleset by ID
if [[ "\$args" == *"--method DELETE"* && "\$args" == *"rulesets"* ]]; then
  echo "ruleset-deleted" >> "\$DELETED_RULESET_LOG"
  exit 0
fi

# GET rulesets for TARGET_REPO — mock applies jq result directly:
#   args with "length" = audit count query  → output count integer
#   args with ".id"    = _old_ruleset_id    → output ID or nothing
if [[ "\$args" == *"/repos/${TEST_OWNER}/testrepo/rulesets"* && "\$args" != *"--method POST"* ]]; then
  if [[ "${ruleset_state}" == "has-existing-ruleset" ]]; then
    if [[ "\$args" == *"length"* ]];   then printf '1'; \
    elif [[ "\$args" == *".id"* ]];    then printf '42'; \
    else printf '[{"name":"agent-blocked-from-non-agent-branches","id":42}]'; fi
  else
    # no existing ruleset: length=0, .id=<empty>
    [[ "\$args" == *"length"* ]] && printf '0' || true
  fi
  exit 0
fi

# GET rulesets for other repos (audit) — none found; output jq result directly
if [[ "\$args" == *"rulesets"* && "\$args" != *"--method POST"* ]]; then
  [[ "\$args" == *"length"* ]] && printf '0' || true
  exit 0
fi

if [[ "\$args" == *"--method POST"* && "\$args" == *"rulesets"* ]]; then
  echo "ruleset-created" >> "\$RULESET_LOG"
  printf '{"id":1}'
  exit 0
fi

# List user installations — for bypass_actors building
# Returns one "other" app (id!=TEST_APP_ID) with all-repos access
if [[ "\$args" == *"/user/installations"* && "\$args" == *"per_page"* ]]; then
  printf '{"installations":[{"id":77,"app_id":12345,"repository_selection":"all"}]}'
  exit 0
fi

# Check repos for a specific installation (selected-repos case)
if [[ "\$args" == *"/user/installations"* && "\$args" == *"/repositories"* ]]; then
  printf '{"repositories":[]}'
  exit 0
fi

if [[ "\$args" == *"--method PUT"* || ("\$args" == *"--method POST"* && "\$args" == *"/forks"*) ]]; then
  exit 0
fi

exit 0
GHEOF
  chmod +x "$mock_path"
}

# Write the curl mock used by both run_onboard and run_onboard_exit.
# $1 = bin dir, $2 = audit_state
write_mock_curl() {
  local bin_dir="$1" audit_state="${2:-clean}"
  local repos_json
  if [[ "$audit_state" == "has-unprotected" ]]; then
    repos_json='{"repositories":[{"id":999,"full_name":"'"${TEST_OWNER}/badrepo"'"}]}'
  else
    repos_json='{"repositories":[]}'
  fi
  cat > "${bin_dir}/curl" << CURLEOF
#!/usr/bin/env bash
if [[ "\$*" == *"/app/installations"* && "\$*" != *"access_tokens"* ]]; then
  printf '[{"id":55}]'
elif [[ "\$*" == *"access_tokens"* ]]; then
  printf '{"token":"ghs_mocktoken"}'
elif [[ "\$*" == *"/installation/repositories"* ]]; then
  printf '%s' '${repos_json}'
else
  command curl "\$@"
fi
CURLEOF
  chmod +x "${bin_dir}/curl"
}

run_onboard() {
  rm -f "$TMPDIR_T/rulesets.log" "$TMPDIR_T/removed.log" "$TMPDIR_T/deleted_ruleset.log"
  ONBOARD_BIN="$TMPDIR_T/onboard-bin"
  mkdir -p "$ONBOARD_BIN"
  cp "$1" "$ONBOARD_BIN/gh"
  write_mock_curl "$ONBOARD_BIN" "${4:-clean}"
  PATH_CLEAN=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^$MOCK_BIN$" | tr '\n' ':' | sed 's/:$//')
  PATH="$ONBOARD_BIN:$PATH_CLEAN" bash "$TEST_ONBOARD" "$2" 2>&1 || true
}

run_onboard_exit() {
  rm -f "$TMPDIR_T/rulesets.log" "$TMPDIR_T/removed.log" "$TMPDIR_T/deleted_ruleset.log"
  ONBOARD_BIN="$TMPDIR_T/onboard-bin"
  mkdir -p "$ONBOARD_BIN"
  cp "$1" "$ONBOARD_BIN/gh"
  write_mock_curl "$ONBOARD_BIN" "${4:-clean}"
  PATH_CLEAN=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^$MOCK_BIN$" | tr '\n' ':' | sed 's/:$//')
  PATH="$ONBOARD_BIN:$PATH_CLEAN" bash "$TEST_ONBOARD" "$2" > /dev/null 2>&1; echo $?
}

ruleset_count()         { [[ -f "$TMPDIR_T/rulesets.log"         ]] && wc -l < "$TMPDIR_T/rulesets.log"         | tr -d ' ' || echo 0; }
removed_count()         { [[ -f "$TMPDIR_T/removed.log"           ]] && wc -l < "$TMPDIR_T/removed.log"           | tr -d ' ' || echo 0; }
deleted_ruleset_count() { [[ -f "$TMPDIR_T/deleted_ruleset.log"   ]] && wc -l < "$TMPDIR_T/deleted_ruleset.log"   | tr -d ' ' || echo 0; }

# ── onboard: no arguments → usage error ───────────────────────────────────────

NO_ARGS_EXIT=$(bash "$TEST_ONBOARD" > /dev/null 2>&1; echo $?)
NO_ARGS_OUTPUT=$(bash "$TEST_ONBOARD" 2>&1 || true)

[[ "$NO_ARGS_EXIT" != "0" ]] \
  && ok  "onboard no-args: exits non-zero" \
  || fail "onboard no-args: exits non-zero"

printf '%s' "$NO_ARGS_OUTPUT" | grep -qi "usage" \
  && ok  "onboard no-args: prints usage" \
  || fail "onboard no-args: prints usage"

# ── onboard: own repo — two rulesets created ──────────────────────────────────

MOCK_GH_OWN="$TMPDIR_T/gh-own"
write_mock_gh "$MOCK_GH_OWN" "exists" "has-install"

OWN_OUTPUT=$(run_onboard "$MOCK_GH_OWN" "${TEST_OWNER}/testrepo")
OWN_EXIT=$(run_onboard_exit "$MOCK_GH_OWN" "${TEST_OWNER}/testrepo")

# ── onboard: short form (no owner) uses current owner ────────────────────────

MOCK_GH_SHORT="$TMPDIR_T/gh-short"
write_mock_gh "$MOCK_GH_SHORT" "exists" "has-install"

SHORT_EXIT=$(run_onboard_exit "$MOCK_GH_SHORT" "testrepo")

[[ "$SHORT_EXIT" == "0" ]] \
  && ok  "onboard short-form: exits 0" \
  || fail "onboard short-form: exits 0 (got $SHORT_EXIT)"

SHORT_RULESETS=$(ruleset_count)
[[ "$SHORT_RULESETS" == "1" ]] \
  && ok  "onboard short-form: one ruleset created" \
  || fail "onboard short-form: one ruleset created (got $SHORT_RULESETS)"

[[ "$OWN_EXIT" == "0" ]] \
  && ok  "onboard own-repo: exits 0" \
  || fail "onboard own-repo: exits 0 (got $OWN_EXIT)"

OWN_RULESETS=$(ruleset_count)
[[ "$OWN_RULESETS" == "1" ]] \
  && ok  "onboard own-repo: one ruleset created" \
  || fail "onboard own-repo: one ruleset created (got $OWN_RULESETS)"

printf '%s' "$OWN_OUTPUT" | grep -q "agent blocked from" \
  && ok  "onboard own-repo: output confirms ruleset" \
  || fail "onboard own-repo: output confirms ruleset"

# ── onboard: unprotected repo in installation is removed ─────────────────────

MOCK_GH_AUDIT="$TMPDIR_T/gh-audit"
write_mock_gh "$MOCK_GH_AUDIT" "no-fork" "has-install" "has-unprotected"

AUDIT_OUTPUT=$(run_onboard "$MOCK_GH_AUDIT" "${TEST_OWNER}/testrepo" "" "has-unprotected")
AUDIT_EXIT=$(run_onboard_exit "$MOCK_GH_AUDIT" "${TEST_OWNER}/testrepo" "" "has-unprotected")

[[ "$AUDIT_EXIT" == "0" ]] \
  && ok  "onboard audit: exits 0" \
  || fail "onboard audit: exits 0 (got $AUDIT_EXIT)"

AUDIT_REMOVED=$(removed_count)
[[ "$AUDIT_REMOVED" == "1" ]] \
  && ok  "onboard audit: unprotected repo removed from installation" \
  || fail "onboard audit: unprotected repo removed from installation (got $AUDIT_REMOVED)"

printf '%s' "$AUDIT_OUTPUT" | grep -qi "missing branch protection" \
  && ok  "onboard audit: warning printed for removed repo" \
  || fail "onboard audit: warning printed for removed repo"

# ── onboard: external repo where a fork already exists ────────────────────────

MOCK_GH_EXT="$TMPDIR_T/gh-ext"
write_mock_gh "$MOCK_GH_EXT" "exists" "has-install"

EXT_OUTPUT=$(run_onboard "$MOCK_GH_EXT" "otherowner/extrepo")
EXT_EXIT=$(run_onboard_exit "$MOCK_GH_EXT" "otherowner/extrepo")

[[ "$EXT_EXIT" != "0" ]] \
  && ok  "onboard external-fork-exists: exits non-zero" \
  || fail "onboard external-fork-exists: exits non-zero (got $EXT_EXIT)"

printf '%s' "$EXT_OUTPUT" | grep -q "fork already exists" \
  && ok  "onboard external-fork-exists: error mentions existing fork" \
  || fail "onboard external-fork-exists: error mentions existing fork"

printf '%s' "$EXT_OUTPUT" | grep -q "${TEST_OWNER}/extrepo" \
  && ok  "onboard external-fork-exists: error suggests passing fork directly" \
  || fail "onboard external-fork-exists: error suggests passing fork directly"

# ── onboard: same-named repo exists but is NOT a fork ────────────────────────

MOCK_GH_NOTFORK="$TMPDIR_T/gh-notfork"
write_mock_gh "$MOCK_GH_NOTFORK" "not-a-fork" "has-install"

NOTFORK_OUTPUT=$(run_onboard "$MOCK_GH_NOTFORK" "otherowner/extrepo")
NOTFORK_EXIT=$(run_onboard_exit "$MOCK_GH_NOTFORK" "otherowner/extrepo")

[[ "$NOTFORK_EXIT" != "0" ]] \
  && ok  "onboard collision-not-fork: exits non-zero" \
  || fail "onboard collision-not-fork: exits non-zero"

printf '%s' "$NOTFORK_OUTPUT" | grep -qi "not a fork" \
  && ok  "onboard collision-not-fork: error mentions 'not a fork'" \
  || fail "onboard collision-not-fork: error mentions 'not a fork'"


# ── onboard: existing same-named ruleset is replaced ─────────────────────────

MOCK_GH_REPLACE="$TMPDIR_T/gh-replace"
write_mock_gh "$MOCK_GH_REPLACE" "exists" "has-install" "has-existing-ruleset"

REPLACE_OUTPUT=$(run_onboard "$MOCK_GH_REPLACE" "${TEST_OWNER}/testrepo")
REPLACE_EXIT=$(run_onboard_exit "$MOCK_GH_REPLACE" "${TEST_OWNER}/testrepo")

[[ "$REPLACE_EXIT" == "0" ]] \
  && ok  "onboard replace-ruleset: exits 0" \
  || fail "onboard replace-ruleset: exits 0 (got $REPLACE_EXIT)"

REPLACE_DELETED=$(deleted_ruleset_count)
[[ "$REPLACE_DELETED" == "1" ]] \
  && ok  "onboard replace-ruleset: old ruleset deleted" \
  || fail "onboard replace-ruleset: old ruleset deleted (got $REPLACE_DELETED)"

REPLACE_CREATED=$(ruleset_count)
[[ "$REPLACE_CREATED" == "1" ]] \
  && ok  "onboard replace-ruleset: new ruleset created" \
  || fail "onboard replace-ruleset: new ruleset created (got $REPLACE_CREATED)"

printf '%s' "$REPLACE_OUTPUT" | grep -qi "replacing existing" \
  && ok  "onboard replace-ruleset: output mentions replacing" \
  || fail "onboard replace-ruleset: output mentions replacing"

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

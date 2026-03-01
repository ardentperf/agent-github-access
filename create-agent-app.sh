#!/usr/bin/env bash
set -euo pipefail

PORT=9876

# ── Dependencies ────────────────────────────────────────────────────────────
for cmd in gh jq python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not found." >&2
    exit 1
  fi
done

# ── Account selection ─────────────────────────────────────────────────────────
if [[ $# -gt 0 ]]; then
  export GH_USER="$1"
else
  # gh auth list format: "github.com  username  (active)"
  ACCOUNTS=$(gh auth list 2>/dev/null | awk '/github\.com/{found=1; next} found && /^\s/{print $1} found && /^[^\s]/{found=0}' | grep -v '^$' || true)
  COUNT=$(echo "$ACCOUNTS" | grep -c '[^[:space:]]' || true)
  if [[ "$COUNT" -gt 1 ]]; then
    echo "Multiple GitHub accounts are authenticated. Rerun with the account to use:" >&2
    echo "$ACCOUNTS" | sed 's/^/  /' >&2
    echo "" >&2
    echo "  Usage: $0 <username>" >&2
    exit 1
  fi
fi

# ── Identity ─────────────────────────────────────────────────────────────────
USERNAME=$(gh api user --jq '.login')
APP_NAME="${USERNAME}-agent"

echo "Authenticated as: ${USERNAME}"
echo "App name:         ${APP_NAME}"
echo ""

# ── App permissions ───────────────────────────────────────────────────────────
# These are the permissions the GitHub App will request from each repo it is
# installed on. To change them: edit below, re-run this script, then each repo
# owner will be prompted to approve the updated permissions on next install.
#
# Not currently enabled — uncomment in the jq block below to activate:
#   pull_requests: "write"   open, update, and merge pull requests
#   issues:        "write"   create and update issue comments

# ── Manifest ─────────────────────────────────────────────────────────────────
MANIFEST=$(jq -n \
  --arg name "$APP_NAME" \
  --arg url  "https://github.com/${USERNAME}" \
  --arg cb   "http://localhost:${PORT}/callback" \
  '{
    name:         $name,
    url:          $url,
    redirect_url: $cb,
    public:       false,
    default_permissions: {
      metadata:      "read",    # required by all apps
      contents:      "write",   # push commits; create/delete branches
      workflows:     "write",   # modify .github/workflows/ files
      actions:       "read",    # read workflow run logs and results
      checks:        "read"     # read check run and check suite results
      # pull_requests: "write", # open, update, and merge pull requests
      # issues:        "write"  # create and update issue comments
    },
    default_events: ["push", "workflow_run", "check_run"]
    # default_events when pull_requests enabled: add "pull_request"
  }')

# ── Temp files ───────────────────────────────────────────────────────────────
# BSD mktemp (macOS) requires the template to end in X's, so create without
# suffix then rename to get the .html extension browsers need.
TMPBASE=$(mktemp "${TMPDIR:-/tmp}/gh-app-XXXXXX")
TMPHTML="${TMPBASE}.html"
mv "$TMPBASE" "$TMPHTML"
CODEFILE=$(mktemp "${TMPDIR:-/tmp}/gh-app-code-XXXXXX")
trap 'rm -f "$TMPHTML" "$CODEFILE"' EXIT

# ── HTML page that auto-submits the manifest form to GitHub ──────────────────
python3 - "$MANIFEST" "$TMPHTML" <<'PYEOF'
import sys, html
manifest, outfile = sys.argv[1], sys.argv[2]
escaped = html.escape(manifest, quote=True)
with open(outfile, 'w') as f:
    f.write(f"""<!DOCTYPE html>
<html><body>
<p>Submitting app manifest to GitHub…</p>
<form method="post" action="https://github.com/settings/apps/new" id="f">
  <input type="hidden" name="manifest" value="{escaped}">
</form>
<script>document.getElementById('f').submit();</script>
</body></html>""")
PYEOF

# ── One-shot local server to catch the callback code ─────────────────────────
python3 - "$CODEFILE" "$PORT" <<'PYEOF' &
import sys, http.server, urllib.parse
codefile, port = sys.argv[1], int(sys.argv[2])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get('code', [''])[0]
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.end_headers()
        self.wfile.write(b'<html><body><h2>Done &#10003; You can close this tab.</h2></body></html>')
        with open(codefile, 'w') as f:
            f.write(code)
    def log_message(self, *a): pass

http.server.HTTPServer(('localhost', port), Handler).handle_request()
PYEOF
SERVER_PID=$!

# ── Open browser ──────────────────────────────────────────────────────────────
if command -v xdg-open &>/dev/null; then
    xdg-open "file://$TMPHTML" 2>/dev/null
elif command -v open &>/dev/null; then
    open "file://$TMPHTML"
else
    echo "Could not detect a browser opener. Open this file manually:"
    echo "  file://$TMPHTML"
fi

echo "Waiting for you to confirm app creation in your browser…"
wait "$SERVER_PID"

# ── Exchange code for credentials ─────────────────────────────────────────────
CODE=$(cat "$CODEFILE")
if [[ -z "$CODE" ]]; then
  echo "Error: no code received from GitHub. Did you complete the confirmation?" >&2
  exit 1
fi

echo "Exchanging code for credentials…"
RESULT=$(gh api --method POST "/app-manifests/${CODE}/conversions")

APP_ID=$(  echo "$RESULT" | jq -r '.id')
APP_SLUG=$(echo "$RESULT" | jq -r '.slug')
PEM=$(     echo "$RESULT" | jq -r '.pem')
PEM_B64=$( printf '%s' "$PEM" | base64 | tr -d '\n')

# ── Generate authenticate-github.sh ──────────────────────────────────────────
OUTFILE="authenticate-github.sh"

python3 - "$APP_ID" "$PEM_B64" "$APP_SLUG" "$USERNAME" "$OUTFILE" << 'PYEOF'
import sys
app_id, pem_b64, app_slug, owner_login, outfile = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

header = (
    '#!/usr/bin/env bash\n'
    '# Authenticates the current Linux user to GitHub via an embedded GitHub App\n'
    '# credential. Re-run any time a GitHub operation fails due to an expired token.\n'
    'set -euo pipefail\n'
    '\n'
    '# ── Embedded credentials ──────────────────────────────────────────────────────\n'
    f'APP_ID="{app_id}"\n'
    f'APP_PEM_B64="{pem_b64}"\n'
    f'OWNER_LOGIN="{owner_login}"\n'
)

body = r"""
# ── Dependencies ─────────────────────────────────────────────────────────────
for cmd in curl jq openssl git base64; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required." >&2; exit 1
  fi
done

# ── Decode PEM ────────────────────────────────────────────────────────────────
APP_PEM=$(printf '%s' "$APP_PEM_B64" | base64 -d)

# ── Build JWT ─────────────────────────────────────────────────────────────────
NOW=$(date +%s)
EXP=$((NOW + 540))   # 9 min — GitHub maximum is 10

b64url() { base64 | tr '+/' '-_' | tr -d '=\n'; }

HEADER=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":%d}' "$NOW" "$EXP" "$APP_ID" | b64url)

TMPKEY=$(mktemp "${TMPDIR:-/tmp}/gh-jwt-XXXXXX")
chmod 600 "$TMPKEY"
printf '%s' "$APP_PEM" > "$TMPKEY"
SIG=$(printf '%s.%s' "$HEADER" "$PAYLOAD" \
  | openssl dgst -binary -sha256 -sign "$TMPKEY" | b64url)
rm -f "$TMPKEY"

JWT="${HEADER}.${PAYLOAD}.${SIG}"

# ── Fetch installation access token ──────────────────────────────────────────
INSTALLATIONS=$(curl -sf \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations")

INSTALL_ID=$(printf '%s' "$INSTALLATIONS" \
  | jq -r --arg owner "$OWNER_LOGIN" \
    '.[] | select(.account.login == $owner and .account.type == "User") | .id')

if [[ -z "$INSTALL_ID" ]]; then
  echo "Error: This GitHub App has no repositories configured." >&2
  echo "  The agent owner must add repositories from their trusted machine" >&2
  echo "  using the setup script that created this file." >&2
  exit 1
fi
# ── Verify branch protection and obtain scoped token ─────────────────────────
# Belt-and-suspenders: protect-repo.sh is the only path to adding repos to this
# installation, but we verify each repo has the expected rulesets and scope the
# token to only those repos. Any repo missing the rulesets is excluded.

BROAD_TOKEN=$(curl -sf -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" \
  | jq -r '.token')

REPOS=$(curl -sf \
  -H "Authorization: Bearer $BROAD_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/installation/repositories")

PROTECTED_IDS=$(
  printf '%s' "$REPOS" | jq -r '.repositories[] | "\(.id)\t\(.full_name)"' \
  | while IFS=$'\t' read -r repo_id full_name; do
      count=$(curl -sf \
        -H "Authorization: Bearer $BROAD_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${full_name}/rulesets" 2>/dev/null \
        | jq '[.[] | select(.name == "agent-blocked-from-all-branches"
                          or .name == "agent-allowed-on-agent-branches")] | length' \
        2>/dev/null || echo "0")
      if [[ "${count:-0}" -eq 2 ]]; then
        printf '%s\n' "$repo_id"
      else
        printf 'Warning: %s is missing branch protection rulesets — excluded.\n' \
          "$full_name" >&2
      fi
    done
)

REPO_IDS_JSON=$(printf '%s' "$PROTECTED_IDS" \
  | jq -Rs '[split("\n")[] | select(. != "") | tonumber]')

if [[ "$REPO_IDS_JSON" == "[]" ]]; then
  echo "Error: no repositories with branch protection found." >&2
  echo "  Run onboard-repo.sh for each repository the agent should access." >&2
  exit 1
fi

TOKEN=$(curl -sf -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -d "{\"repository_ids\":${REPO_IDS_JSON}}" \
  "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" \
  | jq -r '.token')

# ── Configure git global credentials ─────────────────────────────────────────
git config --global credential.https://github.com.helper store
CRED_FILE="${HOME}/.git-credentials"
TMPCRED=$(mktemp "${TMPDIR:-/tmp}/git-cred-XXXXXX")
grep -v '@github\.com' "$CRED_FILE" 2>/dev/null > "$TMPCRED" || true
printf 'https://x-access-token:%s@github.com\n' "$TOKEN" >> "$TMPCRED"
mv "$TMPCRED" "$CRED_FILE"
chmod 600 "$CRED_FILE"

# ── Configure gh CLI (if present) ────────────────────────────────────────────
if command -v gh &>/dev/null; then
  printf '%s' "$TOKEN" | gh auth login --hostname github.com --with-token 2>/dev/null || true
fi

# ── Done ──────────────────────────────────────────────────────────────────────
SCRIPT_PATH=$(realpath "$0" 2>/dev/null || printf '%s' "$0")
echo ""
echo "GitHub credentials configured. Token expires in ~1 hour."
echo ""
echo "STORE IN GLOBAL MEMORY (not repo-local — applies across all repos):"
echo ""
echo "BRANCH PREFIX: x-ai/${OWNER_LOGIN}/"
echo "  e.g. x-ai/${OWNER_LOGIN}/fix-deploy-workflow"
echo "  GitHub rejects pushes to any other prefix. Never push to main."
echo ""
echo "RE-RUN ${SCRIPT_PATH} before retrying if you see:"
echo "  remote: Invalid username or password."
echo "  fatal: Authentication failed for 'https://github.com/'"
echo "  HTTP 401 or \"Bad credentials\" from api.github.com"
echo "  gh: To use GitHub CLI, please run: gh auth login"
echo ""
echo "STORE THE ABOVE IN GLOBAL MEMORY (not repo-local)."
"""

body = body.replace('__APP_SLUG__', app_slug)

with open(outfile, 'w') as f:
    f.write(header + body)
PYEOF

chmod 700 "$OUTFILE"

# ── Generate onboard-repo.sh ──────────────────────────────────────────────────
ONBOARD_SCRIPT="onboard-repo.sh"

python3 - "$APP_ID" "$USERNAME" "$ONBOARD_SCRIPT" << 'PYEOF'
import sys
app_id, owner_login, outfile = sys.argv[1], sys.argv[2], sys.argv[3]

header = (
    '#!/usr/bin/env bash\n'
    '# Expands the agent\'s reach to a repository: sets up branch rules and grants\n'
    '# the agent app access. For repos outside the agent owner\'s account the repo\n'
    '# is forked first. Run this from your trusted machine for each repo.\n'
    '#\n'
    '# Usage: ./onboard-repo.sh <owner/repo>\n'
    'set -euo pipefail\n'
    '\n'
    '# ── Embedded values ───────────────────────────────────────────────────────────\n'
    f'APP_ID="{app_id}"\n'
    f'OWNER_LOGIN="{owner_login}"\n'
)

body = r"""AGENT_BRANCH_PREFIX="x-ai/${OWNER_LOGIN}"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <owner/repo>" >&2
  exit 1
fi

INPUT_REPO="$1"
INPUT_OWNER="${INPUT_REPO%%/*}"
REPO_NAME="${INPUT_REPO##*/}"

# ── Verify the source repo is accessible ─────────────────────────────────────
if ! gh api "/repos/${INPUT_REPO}" --silent 2>/dev/null; then
  echo "Error: cannot access '${INPUT_REPO}'. Check the repo name and your gh credentials." >&2
  exit 1
fi

# ── Fork if the repo is outside the agent owner's account ────────────────────
if [[ "$INPUT_OWNER" == "$OWNER_LOGIN" ]]; then
  TARGET_REPO="$INPUT_REPO"
else
  echo "Repository is outside the agent owner's account (${OWNER_LOGIN})."
  FORK_REPO="${OWNER_LOGIN}/${REPO_NAME}"

  if gh api "/repos/${FORK_REPO}" --silent 2>/dev/null; then
    FORK_PARENT=$(gh api "/repos/${FORK_REPO}" --jq '.parent.full_name // empty')
    if [[ "$FORK_PARENT" == "$INPUT_REPO" ]]; then
      echo "  Found existing fork: ${FORK_REPO}"
    else
      echo "Error: ${FORK_REPO} already exists but is not a fork of ${INPUT_REPO}." >&2
      exit 1
    fi
  else
    echo "  Forking ${INPUT_REPO} into ${OWNER_LOGIN}..."
    gh api \
      --method POST \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "/repos/${INPUT_REPO}/forks" \
      --silent
    echo "  Waiting for fork to be ready..."
    for i in $(seq 1 12); do
      sleep 5
      if gh api "/repos/${FORK_REPO}" --silent 2>/dev/null; then break; fi
      if [[ "$i" -eq 12 ]]; then
        echo "Error: fork did not become available after 60 seconds." >&2; exit 1
      fi
    done
    echo "  Forked to: ${FORK_REPO}"
  fi
  TARGET_REPO="$FORK_REPO"
fi

echo "Onboarding ${TARGET_REPO} for agent access..."
echo "  Agent branch prefix: ${AGENT_BRANCH_PREFIX}/**"
echo ""

# ── Ruleset A: block agent app from all branches ──────────────────────────────
# Repo admins always have implicit bypass, so this only restricts the app.
# The app has no entry in bypass_actors, so it cannot create, update, or delete
# any branch by default.
gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "/repos/${TARGET_REPO}/rulesets" \
  --input - << EOF
{
  "name": "agent-blocked-from-all-branches",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {
    "ref_name": { "include": ["~ALL"], "exclude": [] }
  },
  "rules": [
    { "type": "creation" },
    { "type": "update"   },
    { "type": "deletion" }
  ]
}
EOF

echo "  ✓ Ruleset A: agent blocked from all branches"

# ── Ruleset B: allow agent app to bypass on its own branch prefix ─────────────
# The app is in bypass_actors for this ruleset, so it can create, update, and
# delete branches matching x-ai/{owner}/**.  All other actors remain subject
# to Ruleset A for these same branches.
gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "/repos/${TARGET_REPO}/rulesets" \
  --input - << EOF
{
  "name": "agent-allowed-on-agent-branches",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": ${APP_ID},
      "actor_type": "Integration",
      "bypass_mode": "always"
    }
  ],
  "conditions": {
    "ref_name": { "include": ["${AGENT_BRANCH_PREFIX}/**"], "exclude": [] }
  },
  "rules": [
    { "type": "creation" },
    { "type": "update"   },
    { "type": "deletion" }
  ]
}
EOF

echo "  ✓ Ruleset B: agent allowed on ${AGENT_BRANCH_PREFIX}/**"

# ── Add repo to the app installation ─────────────────────────────────────────
# Branch protection is now in place. Only after that do we grant the app access
# to this repo by adding it to the installation. This ensures the app is never
# active on a repo that lacks the branch protection rules.
REPO_ID=$(gh api "/repos/${TARGET_REPO}" --jq '.id')
INSTALL_ID=$(gh api "/user/installations" \
  --jq ".installations[] | select(.app_id == ${APP_ID}) | .id")

if [[ -z "$INSTALL_ID" ]]; then
  echo "" >&2
  echo "Error: could not find an installation for this app on your account." >&2
  echo "  Install the app first using the setup script on your trusted machine." >&2
  exit 1
fi

gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "/user/installations/${INSTALL_ID}/repositories/${REPO_ID}" \
  --silent

echo "  ✓ Repo added to app installation"
echo ""
echo "Done. The agent can now work in ${TARGET_REPO}."
if [[ "$TARGET_REPO" != "$INPUT_REPO" ]]; then
  echo "  (fork of ${INPUT_REPO})"
fi
echo "  Agent branches must match: ${AGENT_BRANCH_PREFIX}/**"
"""

with open(outfile, 'w') as f:
    f.write(header + body)
PYEOF

chmod 755 "$ONBOARD_SCRIPT"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "App created:"
echo "  Name: ${APP_NAME}"
echo "  ID:   ${APP_ID}"
echo "  Slug: ${APP_SLUG}"
echo ""
echo "Generated scripts:"
echo "  ${OUTFILE}       — copy to the agent's \$HOME and run as ~/authenticate-github.sh"
echo "  ${ONBOARD_SCRIPT}    — run on this machine per repo to expand agent access"
echo ""
echo "Opening browser to install the app on your account…"
echo "  IMPORTANT: on the GitHub page, choose 'Only select repositories'"
echo "  and do NOT select any repositories. Leave the list empty and click Install."
echo "  Use onboard-repo.sh to add repositories — it sets up branch rules"
echo "  first, then grants the app access. The app will have no access to any"
echo "  repo until onboard-repo.sh has been run for that repo."
echo ""
INSTALL_URL="https://github.com/apps/${APP_SLUG}/installations/new"
if command -v xdg-open &>/dev/null; then
    xdg-open "$INSTALL_URL" 2>/dev/null
elif command -v open &>/dev/null; then
    open "$INSTALL_URL"
else
    echo "  Could not open browser. Install manually at:"
    echo "  ${INSTALL_URL}"
fi

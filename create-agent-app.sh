#!/usr/bin/env bash
set -euo pipefail


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
  # gh auth status output: "  ✓ Logged in to github.com account USERNAME (keyring)"
  ACCOUNTS=$(gh auth status 2>&1 | sed -n 's/.*Logged in to github\.com account \([^ ]*\).*/\1/p' | grep -v '^$' || true)
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

# ── Find a free port ─────────────────────────────────────────────────────────
# Ask the OS for a free port, release it, then bind the server to it.
# The window between releasing and binding is negligible for a local tool.
PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('localhost',0)); p=s.getsockname()[1]; s.close(); print(p)")

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
    hook_attributes: { url: "https://example.com", active: false },
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

# ── HTML page: instructions + manifest form with a submit button ──────────────
python3 - "$MANIFEST" "$APP_NAME" "$USERNAME" "$TMPHTML" <<'PYEOF'
import sys, html
manifest, app_name, username, outfile = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
escaped = html.escape(manifest, quote=True)
with open(outfile, 'w') as f:
    f.write(f"""<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
body{{font-family:sans-serif;margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#fff;color:#111}}
@media(prefers-color-scheme:dark){{body{{background:#1a1a1a;color:#eee}}}}
.card{{max-width:480px;padding:2rem}}
h2{{margin-top:0}}
ol{{padding-left:1.3em;line-height:1.8}}
code{{font-size:.95em;background:rgba(128,128,128,.15);padding:.1em .35em;border-radius:3px}}
.warn{{margin-top:1rem;padding:.75rem 1rem;border-left:3px solid #d29922;background:rgba(210,153,34,.1);border-radius:0 4px 4px 0}}
.btn{{display:inline-block;margin-top:1.5rem;padding:.65rem 1.4rem;background:#238636;color:#fff;border:none;border-radius:6px;font-size:1rem;font-weight:600;cursor:pointer}}
.btn:hover{{background:#2ea043}}
</style>
</head><body><div class="card">
<h2>Create GitHub App</h2>
<p>This will create a GitHub App named <code>{app_name}</code> on your account.</p>
<ol>
<li>Click <strong>Create App on GitHub</strong> below</li>
<li>On the GitHub page, click <strong>Create GitHub App for {username}</strong></li>
<li>You will be returned here with next steps</li>
</ol>
<div class="warn">&#9888; Do not change the app name on the GitHub page.<br>
The name <code>{app_name}</code> must stay exactly as shown.</div>
<form method="post" action="https://github.com/settings/apps/new">
  <input type="hidden" name="manifest" value="{escaped}">
  <button type="submit" class="btn">Create App on GitHub &#8594;</button>
</form>
</div></body></html>""")
PYEOF

# ── Local server: serves the manifest page and catches the callback code ──────
# Serving via HTTP sidesteps file:// restrictions in snap-sandboxed browsers.
# APP_NAME is used as the slug — GitHub lowercases and hyphenates the name,
# which it already is, so the install URL is predictable before app creation.
INSTALL_URL="https://github.com/apps/${APP_NAME}/installations/new"

python3 - "$CODEFILE" "$PORT" "$TMPHTML" "$INSTALL_URL" <<'PYEOF' &
import sys, http.server, urllib.parse, os
codefile, port, htmlfile, install_url = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]

done_html = (
    '<!DOCTYPE html><html><head><meta charset="utf-8">'
    '<style>'
    'body{font-family:sans-serif;margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#fff;color:#111}'
    '@media(prefers-color-scheme:dark){body{background:#1a1a1a;color:#eee}}'
    '.card{max-width:480px;padding:2rem;}'
    'h2{margin-top:0}'
    'ol{padding-left:1.3em;line-height:1.8}'
    'code{font-size:.95em;background:rgba(128,128,128,.15);padding:.1em .35em;border-radius:3px}'
    '.btn{display:inline-block;margin-top:1.5rem;padding:.65rem 1.4rem;background:#238636;color:#fff;text-decoration:none;border-radius:6px;font-size:1rem;font-weight:600}'
    '.btn:hover{background:#2ea043}'
    '</style>'
    '</head><body><div class="card">'
    '<h2>&#10003; App created</h2>'
    '<p>Click <strong>Install</strong> below, then on the GitHub page:</p>'
    '<ol>'
    '<li>Choose <strong>Only select repositories</strong></li>'
    '<li>Select <strong>one repo</strong> you want the agent to use</li>'
    '<li>Click <strong>Install</strong></li>'
    '</ol>'
    '<p>Then immediately run on this machine:</p>'
    f'<p><code>./onboard-repo.sh &lt;repo&gt;</code></p>'
    f'<a class="btn" href="{install_url}">Install on GitHub &#8594;</a>'
    '</div></body></html>'
).encode()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/callback':
            code = urllib.parse.parse_qs(parsed.query).get('code', [''])[0]
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(done_html)
            if code:
                with open(codefile, 'w') as f: f.write(code)
        else:
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            with open(htmlfile, 'rb') as f: self.wfile.write(f.read())
    def log_message(self, *a): pass

server = http.server.HTTPServer(('localhost', port), Handler)
while not (os.path.exists(codefile) and os.path.getsize(codefile) > 0):
    server.handle_request()
PYEOF
SERVER_PID=$!

# ── Open browser ──────────────────────────────────────────────────────────────
if command -v xdg-open &>/dev/null; then
    xdg-open "http://localhost:${PORT}/"
elif command -v open &>/dev/null; then
    open "http://localhost:${PORT}/"
else
    echo "Could not detect a browser opener. Open this URL manually:"
    echo "  http://localhost:${PORT}/"
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
        "https://api.github.com/repos/${full_name}/rulesets" \
        | jq '[.[] | select(.name == "agent-blocked-from-non-agent-branches" or .name == "agent-must-use-bot-identity")] | length' \
        || echo "0")
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
grep -v '@github\.com' "$CRED_FILE" > "$TMPCRED" || true
printf 'https://x-access-token:%s@github.com\n' "$TOKEN" >> "$TMPCRED"
mv "$TMPCRED" "$CRED_FILE"
chmod 600 "$CRED_FILE"

# ── Configure gh CLI (if present) ────────────────────────────────────────────
if command -v gh &>/dev/null; then
  printf '%s' "$TOKEN" | gh auth login --hostname github.com --with-token || true
fi

# ── Configure git identity as the app bot ────────────────────────────────────
# Commits authored with this identity are displayed as ${OWNER_LOGIN}-agent[bot]
# in the GitHub UI. The agent-must-use-bot-identity ruleset requires signed
# commits on agent branches; the GitHub App signs commits server-side.
git config --global user.name "${OWNER_LOGIN}-agent[bot]"
git config --global user.email "${APP_ID}+${OWNER_LOGIN}-agent[bot]@users.noreply.github.com"

# ── Done ──────────────────────────────────────────────────────────────────────
SCRIPT_PATH=$(realpath "$0" || printf '%s' "$0")
echo ""
echo "GitHub credentials configured. Token expires in ~1 hour."
echo ""
echo "STORE IN GLOBAL MEMORY (not repo-local — applies across all repos):"
echo ""
echo "BRANCH PREFIX: x-ai/${OWNER_LOGIN}/"
echo "  e.g. x-ai/${OWNER_LOGIN}/fix-deploy-workflow"
echo "  GitHub enforces this server-side. Never push to main or any other prefix."
echo ""
echo "COMMIT METHOD: gh api repos/${OWNER_LOGIN}/{repo}/git/... (GitHub Git Data API)"
echo "  Do NOT use git commit + git push. Agent branches require signed commits;"
echo "  only API-created commits are signed automatically."
echo ""
echo "RE-RUN ${SCRIPT_PATH} before retrying if you see:"
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

python3 - "$APP_ID" "$PEM_B64" "$USERNAME" "$ONBOARD_SCRIPT" << 'PYEOF'
import sys
app_id, pem_b64, owner_login, outfile = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

header = (
    '#!/usr/bin/env bash\n'
    '# Expands the agent\'s reach to a repository: sets up branch rules and grants\n'
    '# the agent app access. For repos outside the agent owner\'s account the repo\n'
    '# is forked first. Run this from your trusted machine for each repo.\n'
    '#\n'
    '# Usage: ./onboard-repo.sh <repo> or ./onboard-repo.sh <owner/repo>\n'
    'set -euo pipefail\n'
    '\n'
    '# ── Embedded values ───────────────────────────────────────────────────────────\n'
    f'APP_ID="{app_id}"\n'
    f'APP_PEM_B64="{pem_b64}"\n'
    f'OWNER_LOGIN="{owner_login}"\n'
)

body = r"""AGENT_BRANCH_PREFIX="x-ai/${OWNER_LOGIN}"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <repo> or $0 <owner/repo>" >&2
  exit 1
fi

# Accept plain repo name (no slash) and assume current owner
if [[ "$1" == */* ]]; then
  INPUT_REPO="$1"
else
  INPUT_REPO="${OWNER_LOGIN}/$1"
fi
INPUT_OWNER="${INPUT_REPO%%/*}"
REPO_NAME="${INPUT_REPO##*/}"

# ── Verify the source repo is accessible ─────────────────────────────────────
if ! gh api "/repos/${INPUT_REPO}" --silent; then
  echo "Error: cannot access '${INPUT_REPO}'. Check the repo name and your gh credentials." >&2
  exit 1
fi

# ── Fork if the repo is outside the agent owner's account ────────────────────
if [[ "$INPUT_OWNER" == "$OWNER_LOGIN" ]]; then
  TARGET_REPO="$INPUT_REPO"
else
  echo "Repository is outside the agent owner's account (${OWNER_LOGIN})."
  FORK_REPO="${OWNER_LOGIN}/${REPO_NAME}"

  if gh api "/repos/${FORK_REPO}" --silent; then
    FORK_PARENT=$(gh api "/repos/${FORK_REPO}" --jq '.parent.full_name // empty')
    if [[ "$FORK_PARENT" == "$INPUT_REPO" ]]; then
      echo "Error: a fork already exists at ${FORK_REPO}." >&2
      echo "  To onboard it, pass the fork directly: ./onboard-repo.sh ${FORK_REPO}" >&2
      exit 1
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
      if gh api "/repos/${FORK_REPO}" --silent; then break; fi
      if [[ "$i" -eq 12 ]]; then
        echo "Error: fork did not become available after 60 seconds." >&2; exit 1
      fi
    done
    echo "  Forked to: ${FORK_REPO}"
  fi
  TARGET_REPO="$FORK_REPO"
fi

# ── Resolve installation ID via app JWT ──────────────────────────────────────
APP_PEM=$(printf '%s' "$APP_PEM_B64" | base64 -d)

b64url() { base64 | tr '+/' '-_' | tr -d '=\n'; }
NOW=$(date +%s); EXP=$((NOW + 540))
HEADER=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":%d}' "$NOW" "$EXP" "$APP_ID" | b64url)
TMPKEY=$(mktemp); chmod 600 "$TMPKEY"; printf '%s' "$APP_PEM" > "$TMPKEY"
SIG=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | openssl dgst -binary -sha256 -sign "$TMPKEY" | b64url)
rm -f "$TMPKEY"
JWT="${HEADER}.${PAYLOAD}.${SIG}"

INSTALL_ID=$(curl -sf \
  -H "Authorization: Bearer ${JWT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations" \
  | jq -r '.[0].id // empty')

if [[ -z "$INSTALL_ID" ]]; then
  echo "Error: no installation found for this app. Install the app on GitHub first." >&2
  exit 1
fi

# Get an installation access token (needed to list repos via the app identity)
INSTALL_TOKEN=$(curl -sf \
  -X POST \
  -H "Authorization: Bearer ${JWT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" \
  | jq -r '.token // empty')

# ── Audit: remove installed repos missing expected branch rules ───────────────
# Any repo granted to this installation without both agent rulesets is
# unprotected — the app could push to any branch. Remove such repos now.
INSTALLED=$(curl -sf \
  -H "Authorization: token ${INSTALL_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/installation/repositories" \
  | jq -r '.repositories[] | "\(.id) \(.full_name)"' || true)

if [[ -n "$INSTALLED" ]]; then
  while IFS=' ' read -r rid rname; do
    [[ -z "$rname" || ! "$rname" == */* ]] && continue
    [[ "$rname" == "$TARGET_REPO" ]] && continue
    HAS_RULESET=$(gh api "/repos/${rname}/rulesets" \
      --jq '[.[] | select(.name == "agent-blocked-from-non-agent-branches")] | length' || echo 0)
    if [[ "$HAS_RULESET" == "0" ]]; then
      echo "Warning: ${rname} is missing branch protection rules — removing from installation." >&2
      gh api \
        --method DELETE \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "/user/installations/${INSTALL_ID}/repositories/${rid}" \
        --silent || true
    fi
  done <<< "$INSTALLED"
fi

echo "Onboarding ${TARGET_REPO} for agent access..."
echo "  Agent branch prefix: ${AGENT_BRANCH_PREFIX}/**"
echo ""

# ── Remove any existing same-named rulesets (handles app re-creation) ─────────
for _ruleset_name in "agent-blocked-from-non-agent-branches" "agent-must-use-bot-identity"; do
  _old_id=$(gh api "/repos/${TARGET_REPO}/rulesets" \
    --jq ".[] | select(.name == \"${_ruleset_name}\") | .id" \
    | head -1 || true)
  if [[ -n "$_old_id" ]]; then
    echo "  Replacing existing ruleset (${_ruleset_name})..."
    gh api \
      --method DELETE \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "/repos/${TARGET_REPO}/rulesets/${_old_id}" \
      --silent
  fi
done

# ── Build bypass_actors list ──────────────────────────────────────────────────
# Bypasses human roles (write, maintain, admin).
# RepositoryRole: 2 = maintain, 4 = write, 5 = admin  (not hierarchical)
BYPASS_ACTORS='[
  {"actor_id":2,"actor_type":"RepositoryRole","bypass_mode":"always"},
  {"actor_id":4,"actor_type":"RepositoryRole","bypass_mode":"always"},
  {"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}
]'

gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "/repos/${TARGET_REPO}/rulesets" \
  --silent \
  --input - << EOF
{
  "name": "agent-blocked-from-non-agent-branches",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": ${BYPASS_ACTORS},
  "conditions": {
    "ref_name": {
      "include": ["~ALL"],
      "exclude": ["refs/heads/${AGENT_BRANCH_PREFIX}/**"]
    }
  },
  "rules": [
    { "type": "creation" },
    { "type": "update"   },
    { "type": "deletion" }
  ]
}
EOF

echo "  ✓ Ruleset: agent blocked from all branches except ${AGENT_BRANCH_PREFIX}/**"

# ── Ruleset: require signed commits on agent branches ────────────────────────
# All commits to x-ai/<owner>/** must be signed and verified. The GitHub App
# signs commits server-side, so agent commits pass automatically. The bot's git
# identity (name + email) is configured by authenticate-github.sh so commits
# are attributed correctly in the GitHub UI. Human contributors bypass.
gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "/repos/${TARGET_REPO}/rulesets" \
  --silent \
  --input - << EOF
{
  "name": "agent-must-use-bot-identity",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": ${BYPASS_ACTORS},
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/${AGENT_BRANCH_PREFIX}/**"],
      "exclude": []
    }
  },
  "rules": [
    { "type": "required_signatures" }
  ]
}
EOF

echo "  ✓ Ruleset: agent commits must be signed on ${AGENT_BRANCH_PREFIX}/**"

# ── Add repo to the app installation ─────────────────────────────────────────
# Branch protection is now in place. Only after that do we grant the app access
# to this repo by adding it to the installation. This ensures the app is never
# active on a repo that lacks the branch protection rules.
REPO_ID=$(gh api "/repos/${TARGET_REPO}" --jq '.id')

gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "/user/installations/${INSTALL_ID}/repositories/${REPO_ID}" \
  --silent 2>/dev/null || true  # 403 expected — standard gh token lacks write:org scope;
                                # repo is added via the GitHub App install UI instead

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
echo "  ${OUTFILE}     — copy to the agent's \$HOME"
echo "  ${ONBOARD_SCRIPT} — run on this machine per repo to grant agent access"
echo ""
echo "Next steps:"
echo "  1. A browser will open to install the app. Choose 'Only select repositories',"
echo "     select one repo, and click Install."
echo "  2. Immediately run: ./onboard-repo.sh <repo>"
echo "     This sets up branch protection rules on that repo."
echo "  3. Repeat step 2 for each additional repo."
echo "  4. Copy ${OUTFILE} to the agent: scp ${OUTFILE} user@agent-host:~/"
echo ""
echo "The browser tab will redirect to the installation page automatically."
echo "If it does not, install manually at:"
echo "  ${INSTALL_URL}"

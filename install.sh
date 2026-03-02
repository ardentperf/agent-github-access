#!/usr/bin/env bash
set -euo pipefail


# ── Dependencies ────────────────────────────────────────────────────────────
for cmd in gh jq python3 openssl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not found." >&2
    exit 1
  fi
done
if ! python3 -c "import nacl.encoding, nacl.public" 2>/dev/null; then
  echo "Error: Python package 'PyNaCl' is required but not installed." >&2
  echo "  pip install PyNaCl" >&2
  exit 1
fi

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

# ── Check for existing app credentials ───────────────────────────────────────
FORK_REPO="${USERNAME}/agent-github-access"
if gh api "/repos/${FORK_REPO}/actions/secrets/GH_APP_ID" --silent 2>/dev/null; then
  echo "Error: a GitHub App has already been created for this account." >&2
  echo "  See the 'Uninstalling / full cleanup' section in README.md for instructions." >&2
  exit 1
fi

# ── App permissions ───────────────────────────────────────────────────────────
# These are the permissions the GitHub App will request from each repo it is
# installed on. To change them: edit below, re-run this script, then each repo
# owner will be prompted to approve the updated permissions on next install.
#
# Not currently enabled — uncomment in the jq block below to activate:
#   issues: "write"   create and update issue comments

# ── Onboard the fork before the app is created ───────────────────────────────
# Sets up branch protection rulesets on the fork so they are in place the
# moment the app is installed. Safe to re-run — onboard-repo.sh is idempotent.
echo "Setting up branch protection on ${USERNAME}/agent-github-access…"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "${SCRIPT_DIR}/onboard-repo.sh" "${USERNAME}/agent-github-access"
echo ""

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
      checks:        "read",    # read check run and check suite results
      pull_requests: "write"    # open, update, and merge pull requests
      # issues: "write"         # create and update issue comments
    },
    default_events: ["push", "workflow_run", "check_run", "pull_request"]
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
    '<p>Then for each repo the agent should work in, run on this machine:</p>'
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
# Note: this endpoint is intentionally unauthenticated — the short-lived code
# is the only credential needed. Fine-grained PATs are explicitly rejected here,
# so we use curl with no Authorization header.
RESULT=$(curl -sf \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app-manifests/${CODE}/conversions")

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
        | jq '[.[] | select(.name == "agent-gh-access-apps-blocked-from-non-ai-branches" or .name == "agent-gh-access-apps-must-sign")] | length' \
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
# in the GitHub UI. The agent-gh-access-apps-must-sign ruleset requires signed
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
echo "  GitHub rejects pushes to any other prefix. Never push to main."
echo ""
echo "COMMIT METHOD: gh api repos/${OWNER_LOGIN}/{repo}/git/... (GitHub Git Data API)"
echo "  Do NOT use git commit + git push. Agent branches require signed commits;"
echo "  only API-created commits are signed automatically."
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

# ── Store app credentials as secrets in the fork ──────────────────────────────
# GH_APP_ID and GH_APP_PEM are stored in the fork's Actions secrets so the
# inventory workflow can use them. Secrets require libsodium box encryption.
echo "Storing app credentials in ${FORK_REPO} secrets…"

python3 - "$APP_ID" "$PEM_B64" "$FORK_REPO" << 'PYEOF'
import sys, json, subprocess, base64
from nacl.encoding import Base64Encoder
from nacl.public import PublicKey, SealedBox

app_id, pem_b64, fork_repo = sys.argv[1], sys.argv[2], sys.argv[3]

def get_public_key():
    r = subprocess.run(
        ["gh", "api", f"/repos/{fork_repo}/actions/secrets/public-key"],
        capture_output=True, text=True, check=True)
    d = json.loads(r.stdout)
    return d["key_id"], d["key"]

def put_secret(name, value, key_id, pub_key_b64):
    pub_key = PublicKey(pub_key_b64, encoder=Base64Encoder)
    encrypted = SealedBox(pub_key).encrypt(value.encode(), encoder=Base64Encoder).decode()
    subprocess.run(
        ["gh", "api", "--method", "PUT",
         f"/repos/{fork_repo}/actions/secrets/{name}",
         "--input", "-"],
        input=json.dumps({"encrypted_value": encrypted, "key_id": key_id}),
        text=True, check=True)

key_id, pub_key = get_public_key()
put_secret("GH_APP_ID",  app_id,  key_id, pub_key)
put_secret("GH_APP_PEM", pem_b64, key_id, pub_key)
print("  ✓ GH_APP_ID and GH_APP_PEM stored in fork secrets")
PYEOF

# ── Trigger inventory workflow ────────────────────────────────────────────────
gh workflow run inventory.yml --repo "${FORK_REPO}" 2>/dev/null \
  && echo "  ✓ Inventory workflow triggered" \
  || echo "  (inventory workflow trigger skipped — run manually if needed)"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "App created:"
echo "  Name: ${APP_NAME}"
echo "  ID:   ${APP_ID}"
echo "  Slug: ${APP_SLUG}"
echo ""
echo "Generated scripts:"
echo "  ${OUTFILE}  — copy to the agent's \$HOME"
echo ""
echo "Next steps:"
echo "  1. A browser will open to install the app. Choose 'Only select repositories',"
echo "     select your fork (${USERNAME}/agent-github-access) and click Install."
echo "  2. For each repo the agent should work in:"
echo "     ./onboard-repo.sh <repo>"
echo "  3. Copy ${OUTFILE} to the agent: scp ${OUTFILE} user@agent-host:~/"
echo ""
echo "The browser tab will redirect to the installation page automatically."
echo "If it does not, install manually at:"
echo "  ${INSTALL_URL}"

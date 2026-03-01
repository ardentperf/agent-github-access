#!/usr/bin/env bash
# prereq-setup-creds.sh — optional helper that generates a pre-filled GitHub URL to create
# a fine-grained PAT for use with install.sh and onboard-repo.sh.
# You can also go to GitHub Settings → Developer settings → Personal access tokens
# → Fine-grained tokens → Generate new token and fill in the settings manually.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <github-username>" >&2
  exit 1
fi

USERNAME="$1"
REPO="${USERNAME}/agent-github-access"

# Parameter names match GitHub's documented fine-grained PAT template URL format.
# Repository selection cannot be prefilled via URL — the user must choose it on the page.
URL="https://github.com/settings/personal-access-tokens/new"
URL+="?name=agent-github-access-setup"
URL+="&target_name=${USERNAME}"
URL+="&administration=write"
URL+="&secrets=write"

echo "This PAT is used only by install.sh and onboard-repo.sh to set up"
echo "branch protection rules and store app credentials. YOU NEED TO SCOPE THIS TO"
echo "ONLY YOUR AGENT-GITHUB-ACCESS REPO. Keep it for as long as you need to"
echo "onboard repos."
echo ""
echo "Required permissions:"
echo "  Administration (read/write) — create repository rulesets"
echo "  Secrets (read/write)        — store app credentials in your agent-github-access fork"
echo ""
echo "Open the URL below on any machine where you are logged in to GitHub in a browser."
echo "It pre-fills the token name and permissions — you can also create the token"
echo "manually in GitHub Settings → Developer settings → Personal access tokens."
echo ""
echo "  $URL"
echo ""
echo "On the GitHub page:"
echo "  1. Under 'Repository access', select 'Only select repositories'"
echo "     and choose ONLY your agent-github-access fork: ${REPO}"
echo "     DO NOT grant access to any other repository."
echo "  2. Confirm Administration (read/write) and Secrets (read/write) are selected"
echo "  3. Set an expiration (90 days recommended)"
echo "  4. Click Generate token and copy the result"
echo ""
echo "Then on the machine where you will run install.sh and onboard-repo.sh:"
echo "  echo '<your-token>' | gh auth login --hostname github.com --with-token"
echo ""

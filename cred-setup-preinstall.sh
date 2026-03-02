#!/usr/bin/env bash
# cred-setup-preinstall.sh — optional helper that generates a pre-filled GitHub URL to create
# a fine-grained PAT. Two PATs are needed: an install PAT and an onboard PAT.
# You can also go to GitHub Settings → Developer settings → Personal access tokens
# → Fine-grained tokens → Generate new token and fill in the settings manually.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <github-username> <install|onboard>" >&2
  exit 1
fi

USERNAME="$1"
MODE="$2"
REPO="${USERNAME}/agent-github-access"

case "$MODE" in
  install)
    # Parameter names match GitHub's documented fine-grained PAT template URL format.
    # Repository selection cannot be prefilled via URL — the user must choose it on the page.
    URL="https://github.com/settings/personal-access-tokens/new"
    URL+="?name=agent-github-access-install"
    URL+="&target_name=${USERNAME}"
    URL+="&administration=write"
    URL+="&secrets=write"
    URL+="&contents=write"

    echo "INSTALL PAT — used by install.sh and uninstall.sh (one-time setup)"
    echo ""
    echo "Required permissions:"
    echo "  Administration (read/write) — create repository rulesets on the fork"
    echo "  Secrets (read/write)        — store app credentials in your agent-github-access fork"
    echo "  Contents (read/write)       — initialize the inventory branch"
    echo ""
    echo "Repository access: ONLY your agent-github-access fork: ${REPO}"
    echo "  DO NOT grant access to any other repository."
    echo ""
    echo "Expiration: This PAT is only needed for install and uninstall."
    echo "  You may set a short expiration (e.g. 7 days) or delete it after setup."
    echo "  You will need it again only if you run uninstall.sh."
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
    echo "  2. Confirm Administration (read/write), Secrets (read/write),"
    echo "     and Contents (read/write) are selected"
    echo "  3. Set an expiration"
    echo "  4. Click Generate token and copy the result"
    echo ""
    echo "Then on the machine where you will run install.sh:"
    echo "  echo '<your-token>' | gh auth login --hostname github.com --with-token"
    echo ""
    ;;

  onboard)
    URL="https://github.com/settings/personal-access-tokens/new"
    URL+="?name=agent-github-access-onboard"
    URL+="&target_name=${USERNAME}"
    URL+="&administration=write"

    echo "ONBOARD PAT — used by onboard-repo.sh (kept for the lifetime of the setup)"
    echo ""
    echo "Required permissions:"
    echo "  Administration (read/write) — create repository rulesets on any repo you onboard"
    echo ""
    echo "Repository access: All repositories"
    echo "  This PAT needs Administration on every repo you onboard the agent to."
    echo "  It does NOT need Secrets or Contents."
    echo ""
    echo "Expiration: Keep this PAT active as long as you may need to onboard new repos."
    echo "  90 days recommended; renew as needed."
    echo ""
    echo "Open the URL below on any machine where you are logged in to GitHub in a browser."
    echo "It pre-fills the token name and permissions — you can also create the token"
    echo "manually in GitHub Settings → Developer settings → Personal access tokens."
    echo ""
    echo "  $URL"
    echo ""
    echo "On the GitHub page:"
    echo "  1. Under 'Repository access', select 'All repositories'"
    echo "  2. Confirm Administration (read/write) is selected"
    echo "     (Secrets and Contents are NOT needed for this PAT)"
    echo "  3. Set an expiration (90 days recommended)"
    echo "  4. Click Generate token and copy the result"
    echo ""
    echo "Then on the machine where you will run onboard-repo.sh:"
    echo "  echo '<your-token>' | gh auth login --hostname github.com --with-token"
    echo ""
    ;;

  *)
    echo "Error: mode must be 'install' or 'onboard', got: ${MODE}" >&2
    exit 1
    ;;
esac

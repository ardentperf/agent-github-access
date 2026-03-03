#!/usr/bin/env bash
# cred-setup-preinstall.sh — optional helper that generates a pre-filled GitHub URL to create
# a fine-grained PAT. Two PATs are needed: an install PAT and an onboard PAT.
# You can also go to GitHub Settings → Developer settings → Personal access tokens
# → Fine-grained tokens → Generate new token and fill in the settings manually.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <github-username> <install|onboard|privileged-onboard>" >&2
  exit 1
fi

USERNAME="$1"
MODE="$2"
REPO="${USERNAME}/stewart-copeland-ai-police"

case "$MODE" in
  install)
    # Parameter names match GitHub's documented fine-grained PAT template URL format.
    # Repository selection cannot be prefilled via URL — the user must choose it on the page.
    URL="https://github.com/settings/personal-access-tokens/new"
    URL+="?name=stewart-copeland-ai-police-install"
    URL+="&target_name=${USERNAME}"
    URL+="&administration=write"
    URL+="&secrets=write"
    URL+="&contents=write"

    echo "INSTALL PAT — used by install.sh and uninstall.sh (one-time setup)"
    echo ""
    echo "Required permissions:"
    echo "  Administration (read/write) — create repository rulesets on the fork"
    echo "  Secrets (read/write)        — store app credentials in your stewart-copeland-ai-police fork"
    echo "  Contents (read/write)       — initialize the inventory branch"
    echo ""
    echo "Repository access: ONLY your stewart-copeland-ai-police fork: ${REPO}"
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
    echo "     and choose ONLY your stewart-copeland-ai-police fork: ${REPO}"
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
    URL+="?name=stewart-copeland-ai-police-onboard"
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

  privileged-onboard)
    # Classic PAT — required for PUT /user/installations/{id}/repositories/{repo_id},
    # which only works with a classic PAT (fine-grained PATs and OAuth tokens are rejected).
    # Classic PATs cannot be pre-filled via URL; the user must check the boxes manually.
    URL="https://github.com/settings/tokens/new"
    URL+="?description=privileged-onboard"

    echo "PRIVILEGED-ONBOARD PAT — classic PAT used by onboard-repo.sh to add repos"
    echo "to the GitHub App installation."
    echo ""
    echo "WARNING: Classic PATs are highly privileged. This token will have broad access"
    echo "to your GitHub account. Treat it like a password."
    echo "  - Store it securely and never commit it to a repository."
    echo "  - Set a short expiration and delete it when not actively onboarding repos."
    echo "  - Do not use it for any purpose other than running onboard-repo.sh."
    echo ""
    echo "Required scopes (check both boxes on the GitHub page):"
    echo "  repo     — full repository access (needed to add repos to app installations)"
    echo "  read:org — read org membership (needed for the installations endpoint)"
    echo ""
    echo "Open the URL below on any machine where you are logged in to GitHub in a browser."
    echo "Classic PAT settings cannot be pre-filled — you must check the boxes manually."
    echo ""
    echo "  $URL"
    echo ""
    echo "On the GitHub page:"
    echo "  1. Confirm the name is 'privileged-onboard' (or change as preferred)"
    echo "  2. Set a short expiration (7 days recommended — only needed when onboarding)"
    echo "  3. Check 'repo' (top-level checkbox)"
    echo "  4. Check 'read:org' (under admin:org)"
    echo "  5. Click Generate token and copy the result"
    echo ""
    echo "NOTE: A classic PAT with these scopes is the ONLY way to programmatically add"
    echo "repos to the GitHub App installation. With normal user auth (OAuth or fine-grained"
    echo "PAT), onboard-repo.sh can still set up branch protection rulesets, but the final"
    echo "step of adding the repo to the app must be done in the GitHub web UI."
    echo ""
    echo "Then when running onboard-repo.sh:"
    echo "  GH_TOKEN=<your-token> ./onboard-repo.sh <repo>"
    echo ""
    ;;

  *)
    echo "Error: mode must be 'install', 'onboard', or 'privileged-onboard', got: ${MODE}" >&2
    exit 1
    ;;
esac

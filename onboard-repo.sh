#!/usr/bin/env bash
# onboard-repo.sh — sets up branch protection rules on a repo and grants the
# agent app access to it. For repos outside the agent owner's account the repo
# is forked first. Safe to re-run — replaces existing rulesets with current config.
#
# Usage: ./onboard-repo.sh <repo> or ./onboard-repo.sh <owner/repo>
#
# Requires: gh CLI authenticated with the onboard PAT (Administration read/write
#   on all repositories — no Secrets or Contents needed).
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <repo> or $0 <owner/repo>" >&2
  exit 1
fi

OWNER_LOGIN=$(gh api user --jq '.login')
AGENT_BRANCH_PREFIX="x-ai/${OWNER_LOGIN}"

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

  if gh api "/repos/${FORK_REPO}" --silent 2>/dev/null; then
    FORK_PARENT=$(gh api "/repos/${FORK_REPO}" --jq '.parent.full_name // empty')
    if [[ "$FORK_PARENT" == "$INPUT_REPO" ]]; then
      echo "Error: a fork already exists at ${FORK_REPO}." >&2
      echo "  To onboard it, pass the fork directly: $0 ${FORK_REPO}" >&2
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

# ── Remove any existing same-named rulesets (handles app re-creation) ─────────
for _ruleset_name in "agent-gh-access-apps-blocked-from-non-ai-branches" "agent-gh-access-apps-must-sign"; do
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

# ── Ruleset: block agent app from non-AI branches ─────────────────────────────
# The agent prefix is in the exclude list so this ruleset doesn't apply there.
gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "/repos/${TARGET_REPO}/rulesets" \
  --silent \
  --input - << EOF
{
  "name": "agent-gh-access-apps-blocked-from-non-ai-branches",
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
# All commits to x-ai/<owner>/** must be signed and verified by GitHub.
# The GitHub App signs commits server-side so agent commits pass automatically.
gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "/repos/${TARGET_REPO}/rulesets" \
  --silent \
  --input - << EOF
{
  "name": "agent-gh-access-apps-must-sign",
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

# ── Trigger inventory workflow (only if app credentials are already stored) ───
# During initial install, install.sh calls this script before the app exists.
# Skip the trigger in that case; install.sh will trigger it after storing secrets.
if gh api "/repos/${OWNER_LOGIN}/agent-github-access/actions/secrets/GH_APP_ID" --silent 2>/dev/null; then
  gh workflow run inventory.yml \
    --repo "${OWNER_LOGIN}/agent-github-access" 2>/dev/null || true
fi

echo ""
echo "Done. The agent can now work in ${TARGET_REPO}."
if [[ "$TARGET_REPO" != "$INPUT_REPO" ]]; then
  echo "  (fork of ${INPUT_REPO})"
fi
echo "  Agent branches must match: ${AGENT_BRANCH_PREFIX}/**"

# Agent GitHub Access

Give an AI agent a distinct GitHub identity with server-side guardrails: the agent can only push to branches it owns, can never touch your personal or main branches, and its activity is unambiguously attributed in every GitHub view.

## How it works

A dedicated **GitHub App** acts as the agent's identity. Repository rulesets enforce that the app can only create or modify branches matching `x-ai/<owner>/**`. Every commit the agent makes appears as `<username>-agent[bot]` in the GitHub UI. The `x-ai/` prefix sorts to the end of the branch list, keeping agent branches visually separate from human work.

`create-agent-app.sh` generates a self-contained `authenticate-github.sh` with the app credentials embedded. Copy that single file to the agent's sandbox — it handles token generation, git configuration, and gh CLI authentication.

```mermaid
flowchart TD
    subgraph setup["Owner — Trusted Machine"]
        A["create-agent-app.sh"] --> B(["Browser: confirm app creation"])
        B --> C(["Browser: install app\nselect no repos"])
        C --> D["authenticate-github.sh\nonboard-repo.sh\ngenerated"]
        D --> E["onboard-repo.sh owner/repo\nfor each repo"]
        E --> H["Set up branch rules\nGrant app access"]
    end

    subgraph agent["Agent — Sandbox"]
        I["Run authenticate-github.sh"] --> J["git + gh CLI configured\ntoken valid ~1 hour"]
        J --> K["Work in repo\nbranch: x-ai/<owner>/…"]
    end

    D -.->|copy to sandbox| I
```

## Prerequisites

- [`gh` CLI](https://cli.github.com/) installed and authenticated
- `jq`, `python3`, `openssl` available on `$PATH`

## Setup (trusted machine, once)

**1. Create the GitHub App and generate scripts**

```bash
./create-agent-app.sh
# If you have multiple gh accounts authenticated:
./create-agent-app.sh <username>
```

Two scripts are generated:
- `authenticate-github.sh` — give this to the agent
- `onboard-repo.sh` — run this per repo on your trusted machine

**2. Install the app**

A browser tab opens automatically. On the GitHub page:
- Choose **Only select repositories**
- Leave the list **empty** — do not select any repos yet
- Click **Install**

Repos are added through `onboard-repo.sh`, which sets up branch rules before granting access. The app has no access to any repo until that step is complete.

**3. Expand the agent to a repository**

```bash
./onboard-repo.sh owner/repo
```

Pass any repo — owned by you or someone else. If the repo is outside your account and you haven't forked it yet, the script forks it automatically then configures the fork.

Repeat for each repo the agent should work in.

**4. Give the agent its credentials**

Copy `authenticate-github.sh` to the agent's home directory:

```bash
scp authenticate-github.sh user@agent-host:~/
```

The agent must run `~/authenticate-github.sh` before doing any GitHub work, and re-run it whenever its token expires (~1 hour). Placing it in `$HOME` gives it a stable, predictable path that can be referenced in global memory instructions across all repos and sessions.

---

## Repo access controls

For each onboarded repo, `onboard-repo.sh` creates two GitHub rulesets:

| Ruleset | Target | Effect |
|---|---|---|
| `agent-blocked-from-all-branches` | all branches | App cannot push anywhere by default |
| `agent-allowed-on-agent-branches` | `x-ai/<owner>/**` | App is granted bypass on its own prefix |

Repo admins retain full access everywhere. The app's access is additive only within its own branch namespace.

## Agent branch naming

All agent branches must follow this pattern:

```
x-ai/<owner>/<description>
```

For example: `x-ai/ardentperf/fix-deploy-workflow`

GitHub enforces this server-side. Any push to a branch outside this pattern will be rejected.

## Revoking agent access

To immediately cut off all agents using this app, delete the app's private key:

**GitHub → Settings → Developer settings → GitHub Apps → your app → Edit → Private keys → Delete**

New token requests are blocked immediately — the agent can no longer refresh its credentials. Any token already in hand remains valid until it expires (~1 hour). To revoke active tokens instantly, uninstall or delete the app entirely.

## Credential refresh

The agent's token expires after ~1 hour. The agent must re-run `authenticate-github.sh` whenever it sees any of:

- `remote: Invalid username or password.`
- `fatal: Authentication failed for 'https://github.com/'`
- HTTP 401 or `Bad credentials` from api.github.com
- `gh: To use GitHub CLI, please run: gh auth login`

---

## Global agent instructions

The branch naming rule and credential refresh procedure apply across **all** repositories, so they belong in your agent's **global** memory — not in any repo-local file. A repo-local file would only be loaded when the agent is working in that specific repo; these rules need to be active everywhere.

### Suggested global AGENTS.md content

When the agent runs `~/authenticate-github.sh` it prints exactly what to store. You can also pre-populate the global file manually so the rules are in place from the first session. Either way, the content looks like this — **replace `<your-github-username>` with your actual GitHub username before saving**:

```
BRANCH PREFIX: x-ai/<your-github-username>/
  e.g. x-ai/<your-github-username>/fix-deploy-workflow
  GitHub rejects pushes to any other prefix. Never push to main.

RE-RUN ~/authenticate-github.sh before retrying if you see:
  remote: Invalid username or password.
  fatal: Authentication failed for 'https://github.com/'
  HTTP 401 or "Bad credentials" from api.github.com
  gh: To use GitHub CLI, please run: gh auth login
```

### Global instruction file paths by tool

| Tool | Global instructions file | Notes |
|---|---|---|
| **Claude Code** | `~/.claude/CLAUDE.md` | Also auto-saves runtime memory to `~/.claude/projects/*/memory/MEMORY.md` |
| **GitHub Copilot** | JetBrains: `~/.config/github-copilot/intellij/global-copilot-instructions.md` | VS Code has no canonical global file; use user-scoped settings |
| **Cursor** | Settings → General → **Rules for AI** | Stored in Cursor's internal database, not a plain file |
| **Windsurf** | `~/.codeium/windsurf/memories/global_rules.md` | Cascade also generates workspace memories automatically |
| **Aider** | `~/.aider.conf.yml` with `read: /absolute/path/to/global-conventions.md` | File path must be absolute in the home config |
| **Devin** | Settings & Library → Knowledge → **Add Knowledge** → pin to *All repositories* | UI-based, not a file |
| **OpenClaw** | `~/.openclaw/MEMORY.md` | Project-level `MEMORY.md` files are also loaded; global file applies across all projects |

> **Note on repo-local AGENTS.md:** Devin and some other tools also recognise an `AGENTS.md` at the repository root. A repo-level file is appropriate for repo-specific context (architecture notes, test commands), but the GitHub access rules above should only live in the global location — not in individual repos — so they are always active regardless of which repo the agent is working in.

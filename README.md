# Chief of Staff — Claude Code Setup

An AI-powered personal operations system built on [Claude Code](https://claude.ai/code). It acts as a chief of staff: checking Slack and email on a schedule, preparing meeting dossiers, tracking priorities and tasks, and maintaining a persistent memory of people and projects.

## What It Does

- **Recurring containerized jobs** for Slack, email/calendar, and custom data gathering
- **Morning briefing** skill that builds meeting dossiers, confirms priorities, and plans the day
- **Persistent memory** of people, projects, and preferences across conversations
- **Security hardening** with guard hooks, quarantine validation, and network egress filtering

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  Interactive Claude Code session                        │
│  (you talking to Claude in your terminal)               │
│                                                         │
│  Reads: context/, memory/people/, memory/projects/      │
│  Writes: memory/, context/, Google Tasks                │
│  Guarded by: guard-secrets.sh, guard-memory-injection.sh│
└─────────────────────────────────────────────────────────┘
        ▲ reads validated output
        │
┌───────┴─────────────────────────────────────────────────┐
│  Per-job cron → run-job.sh <job-name>                   │
│                                                         │
│  ┌─────────────────────────────────────────────┐        │
│  │  Docker container (per-job)                 │        │
│  │  Shared base image + job entrypoint         │        │
│  │  Network: Squid proxy → approved domains    │        │
│  │  Writes: quarantine/<job>/ only             │        │
│  └─────────────────────────────────────────────┘        │
│                    ▼                                    │
│  validate-quarantine.sh <job-name>                      │
│  context → context/  |  memory → context/inbox/         │
└─────────────────────────────────────────────────────────┘
```

## Conventions

This guide uses these placeholders — substitute your own values:

| Placeholder | Meaning | Example |
|-------------|---------|---------|
| `$REPO` | Where you clone this repo | `~/chief-of-staff` |
| `$PROJECTS` | Directory containing your code repos (the chief of staff can read and write these) | `~/projects` |
| `$MEMORY` | Claude Code's memory directory (auto-derived from `$REPO` path) | `~/.claude/projects/-home-alice-chief-of-staff/memory/` |

The memory path is derived by Claude Code from the absolute path to `$REPO`, with `/` replaced by `-`. For example:
- Repo at `/home/alice/chief-of-staff` → memory at `~/.claude/projects/-home-alice-chief-of-staff/memory/`
- Repo at `/home/bob/ops` → memory at `~/.claude/projects/-home-bob-ops/memory/`

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| [Claude Code](https://claude.ai/code) | The AI agent | `npm install -g @anthropic-ai/claude-code` |
| [gws](https://github.com/nicholasgasior/gws) | Google Workspace CLI (Gmail, Calendar, Tasks, Docs) | `npm install -g @googleworkspace/cli` |
| Docker + Compose | Sandboxed job containers | [docs.docker.com](https://docs.docker.com/get-docker/) |
| Node.js 22+ | Runtime for scripts | [nodejs.org](https://nodejs.org/) |
| jq | JSON parsing in guard hooks | `apt install jq` / `brew install jq` |

## Installation

### 1. Clone the repo

```bash
git clone <repo-url> $REPO
cd $REPO
```

### 2. Run the setup script

The interactive setup walks through the entire configuration — prerequisites, paths, secrets, Claude config, Google auth, Docker, and cron — with a preview and confirmation before every file write.

```bash
./setup/setup.sh
```

It will prompt you for:
- **Projects directory** — where your code repos live (default: `~/projects`)
- **Name, role, company, email domain, timezone** — used to generate `CLAUDE.md` and `jobs/org.yaml`
- **Google Tasks list IDs** — optional, for to-do sync

Each generated file is shown (or diffed against the existing version) before writing. Safe to re-run.

For Google Workspace CLI setup (gcloud project, OAuth scopes), see [Google Workspace Setup](setup/claude_google.md).

### 3. Set up secrets

Create `.env` in the repo root (the setup script creates a stub if one doesn't exist):

```bash
cat > .env << 'EOF'
ANTHROPIC_API_KEY=sk-ant-...
SLACK_USER_TOKEN=xoxp-...
SLACK_BOT_TOKEN=xoxb-...
SLACK_TEAM_ID=T...
GITHUB_TOKEN=ghp_...          # optional, for API rate limits
AMBIENT_API_KEY=...            # optional, for meeting transcripts
EOF
chmod 600 .env
```

Create `.mcp.json` in the repo root (gitignored):

```json
{
  "mcpServers": {
    "slack": {
      "command": "npx",
      "args": ["-y", "@anthropic-ai/mcp-server-slack"],
      "env": {
        "SLACK_BOT_TOKEN": "xoxb-...",
        "SLACK_TEAM_ID": "T..."
      }
    },
    "n8n-mcp": {
      "command": "npx",
      "args": ["-y", "n8n-mcp"],
      "env": {
        "N8N_API_KEY": "...",
        "N8N_BASE_URL": "https://your-instance.n8n.cloud/api/v1"
      }
    }
  }
}
```

### 4. Install local dependencies

```bash
cd $REPO/jobs/slack-pull/scripts
npm install
cd $REPO
```

### 5. Test the job runner

```bash
# Test Slack pull
jobs/_runner/run-job.sh slack-pull

# Test email/calendar ingest
jobs/_runner/run-job.sh email-calendar
```

Check `context/quarantine/<job-name>/.job.log` for results. Validated context files land in `context/`, memory files in `context/inbox/`.

### 6. Add a new job

```bash
jobs/_runner/create-job.sh my-new-job
```

This scaffolds `jobs/my-new-job/` with `job.yaml` and `entrypoint.sh`. Edit the entrypoint with your logic, test with `run-job.sh my-new-job`, then `run-job.sh --install-cron` to schedule it.

## Directory Map

```
$REPO/                             ← this repo
├── .claude/                       ← generated by configure.sh (gitignored)
│   ├── settings.local.json        ← project-level permissions, hooks
│   ├── scripts/
│   │   ├── guard-secrets.sh       ← allowlist: restricts file access
│   │   └── guard-memory-injection.sh ← scans memory writes for injection
│   └── skills/                    ← interactive skills (/slack, /morning-briefing, etc.)
├── .env                           ← secrets (gitignored)
├── .mcp.json                      ← MCP server config (gitignored)
├── context/                       ← ALL personal data (gitignored)
│   ├── *.md                       ← timestamped summaries from Slack/email/calls
│   ├── priorities.md              ← strategic priorities
│   ├── todos.md                   ← read-only cache of Google Tasks
│   ├── docs.md                    ← index of important links
│   ├── inbox/                     ← pending memory updates from jobs
│   │   ├── people/
│   │   └── projects/
│   ├── meeting_prep/              ← cumulative meeting dossiers
│   └── quarantine/                ← per-job staging areas (auto-cleaned)
├── jobs/                          ← containerized recurring jobs (committed)
│   ├── _base/                     ← shared Dockerfile, settings, guard, squid
│   ├── _runner/                   ← run-job.sh, validate-quarantine.sh, create-job.sh
│   ├── slack-pull/                ← job: Slack message fetcher
│   ├── email-calendar/            ← job: email/calendar ingest
│   └── meeting-notes/             ← job: meeting notes from Ambient/Google Docs
├── scripts/                       ← shared scripts and fixtures (committed)
├── setup/                         ← install + configure scripts
│   ├── setup.sh                   ← interactive setup (run this first)
│   ├── install.sh                 ← non-interactive: global config to ~/.claude/
│   ├── configure.sh               ← non-interactive: project paths in .claude/
│   ├── init-state.sh              ← non-interactive: creates state files for jobs
│   ├── claude_google.md           ← Google Workspace / gws setup guide
│   ├── settings.json              ← template for ~/.claude/settings.json
│   ├── guard-secrets-global.sh    ← template for ~/.claude/scripts/
│   └── templates/claude/          ← source templates for .claude/
│       ├── settings.local.json    ← hook wiring template
│       ├── scripts/               ← guard hook templates
│       └── skills/                ← skill templates
└── CLAUDE.md                      ← instructions for Claude Code

$PROJECTS/                         ← your code repos (chief of staff can read and write)
├── repo-a/
├── repo-b/
└── ...

~/.claude/                         ← global (all projects)
├── settings.json                  ← deny rules + global guard hook
├── scripts/
│   └── guard-secrets-global.sh    ← blocks sensitive paths across all projects
└── projects/<derived-from-REPO>/
    └── memory/                    ← persistent memory (auto-created by Claude Code)
        ├── MEMORY.md              ← index file, loaded every session
        ├── people/                ← per-person reference cards
        └── projects/              ← per-project status and context
```

## Security Layers

| # | Layer | What it does |
|---|-------|-------------|
| 1 | Project guard hook | Allowlist: only repo, projects dir, and memory are accessible |
| 2 | Global guard hook | Denylist: blocks `~/.ssh`, `~/.aws`, etc. across all projects |
| 3 | Memory injection scanner | Scans all writes to memory/ for 15+ prompt injection patterns |
| 4 | `permissions.deny` | 28 deny rules in global settings as a fallback |
| 5 | Docker containers | Each job runs isolated with read-only mounts |
| 6 | Squid proxy | Containers can only reach approved API domains |
| 7 | Quarantine validation | All job output scanned before promotion |
| 8 | Inbox routing | Memory updates require main agent review before merging |

## Customization

**Slack channels**: Edit `jobs/slack-pull/scripts/config.json` to change which channels are watched.

**Add a recurring job**: Run `jobs/_runner/create-job.sh <name>` to scaffold a new job. Edit the entrypoint, optionally add a custom Dockerfile or squid.conf, then `run-job.sh --install-cron`.

**Skills**: Skills live in `.claude/skills/`. Each has a `SKILL.md` that defines when it triggers and what it does. Add new skills by creating a directory with a `SKILL.md`.

**Priorities**: Edit `context/priorities.md` or tell Claude to update it during a conversation.

**Guard patterns**: The injection patterns in `validate-quarantine.sh` and `guard-memory-injection.sh` can be tuned. Check `context/quarantine/<job-name>/.flagged/` for false positives.

**CLAUDE.md**: This is where you define who you are and how the chief of staff should behave. Edit the `## Soul` section to describe your role and what kind of support you need.

## Simplification Notes

Things that could be simpler but aren't, and why:

- **Global vs. project settings**: Claude Code requires global settings at `~/.claude/`. There's no way to make a project fully self-contained. The `setup/install.sh` script is the workaround.
- **Hardcoded paths**: Guard hooks, validation scripts, and Docker mounts all need absolute paths. The `setup/configure.sh` script handles this — run it once after cloning.
- **Two guard scripts with overlapping Bash checks**: The global and project guards both block `printenv`, `cat .env`, etc. The overlap is intentional — defense in depth. The global hook protects you in other projects too.
- **Memory directory outside the repo**: This is a Claude Code convention. Memory persists across conversations for a given project path and can't be moved into the repo.

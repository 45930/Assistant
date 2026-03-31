---
name: crontab-manager
description: >
  Manage scheduled Claude Code tasks via crontab. This is the persistence layer for
  recurring automation — scheduled code reviews, daily briefings, periodic cleanups,
  report generation, and any prompt you want to run on a timer using `claude -p` in
  headless mode. Use this skill whenever the user wants to schedule, list, add, remove,
  enable, disable, or run a Claude Code task on a cron schedule, view task logs, or
  mentions anything about recurring/scheduled/timed/periodic Claude tasks, crontab
  entries for Claude, or automating prompts to run at specific times. Also trigger when
  the user says things like "run this every morning", "remind me daily", "automate this
  weekly", "set up a nightly job", or references managing their scheduled Claude jobs.
  Even if the user doesn't say "crontab" explicitly — if they want Claude to do something
  on a recurring schedule that survives terminal restarts, use this skill.
---

# Crontab Manager

Manage persistent scheduled Claude Code tasks through the system crontab. Each task is
a `claude -p` invocation that runs on a cron schedule, with structured comments so this
skill can find, toggle, and manage only its own entries without touching the rest of the
user's crontab.

## How it works

Every managed task is a crontab line with a structured trailing comment:

```
<cron-expression> /bin/bash -l -c 'cd <workdir> && claude -p "<prompt>" <flags> >> <logfile> 2>&1'  # CLAUDE_TASK:<name>|<status>|<created>
```

The `# CLAUDE_TASK:` prefix is the marker. Everything after it is pipe-delimited
metadata: task name, status (`enabled` or `disabled`), and ISO creation date.

Disabled tasks are commented out with a leading `#~` so cron ignores them but the
metadata is preserved:

```
#~ <cron-expression> /bin/bash -l -c '...'  # CLAUDE_TASK:<name>|disabled|<created>
```

The `-l` flag on bash ensures a login shell so PATH, NVM, and other environment
setup is loaded — this is critical because cron runs in a minimal environment.

## Directory layout

```
~/.claude/scheduled-tasks/
├── logs/           # One log file per task: <task-name>.log
└── tasks.json      # Optional index for richer metadata (prompt text, flags, description)
```

Create `~/.claude/scheduled-tasks/logs/` if it doesn't exist before adding a task.

## tasks.json

Maintain a JSON sidecar at `~/.claude/scheduled-tasks/tasks.json` that stores the full
task definition. The crontab line is the source of truth for scheduling, but tasks.json
stores details that don't fit in a cron comment (the full prompt, description, flags).

```json
{
  "tasks": {
    "daily-review": {
      "name": "daily-review",
      "description": "Review yesterday's commits for bugs",
      "prompt": "Review all commits from the last 24 hours. Flag bugs, security issues, and missing tests.",
      "schedule": "0 9 * * 1-5",
      "schedule_human": "weekdays at 9am",
      "workdir": "/Users/me/projects/myapp",
      "flags": {
        "allowedTools": "Read,Grep,Glob",
        "max-turns": 5,
        "output-format": "text"
      },
      "created": "2026-03-10T14:30:00Z",
      "status": "enabled"
    }
  }
}
```

## Operations

### 1. List tasks

Parse the current crontab for lines containing `# CLAUDE_TASK:`. For each, extract:
- Name (from the comment)
- Status (enabled/disabled)
- Schedule (the cron expression, converted to human-readable too)
- Created date

Cross-reference with `tasks.json` to show the prompt and description if available.

Display as a clean table. If there are no managed tasks, say so clearly.

Run: `bash /path/to/skill/scripts/crontab-manager.sh list`

### 2. Add a task

Required inputs from the user:
- **name**: slug-style identifier (lowercase, hyphens). Must be unique.
- **prompt**: the text to pass to `claude -p`. Can also be a skill/slash-command reference.
- **schedule**: either a cron expression or human-readable (see schedule parsing below).

Optional inputs:
- **workdir**: directory to `cd` into before running. Defaults to `$HOME`.
- **allowedTools**: comma-separated tool list for `--allowedTools`.
- **max-turns**: integer for `--max-turns`.
- **output-format**: one of `text`, `json`, `stream-json` for `--output-format`.
- **description**: human-readable description of what the task does.
- **dangerously-skip-permissions**: if the user explicitly wants autonomous mode. Warn them about the security implications before enabling this.

Steps:
1. Validate the name is unique (check existing crontab for `CLAUDE_TASK:<name>`).
2. Parse the schedule into a cron expression.
3. Ensure `~/.claude/scheduled-tasks/logs/` exists.
4. Build the crontab line.
5. Append it to the crontab using `(crontab -l 2>/dev/null; echo "<new line>") | crontab -`.
6. Update `tasks.json`.
7. Confirm to the user with the schedule in human-readable form.

Run: `bash /path/to/skill/scripts/crontab-manager.sh add <name> <cron-expr> <workdir> <prompt> [flags...]`

### 3. Remove a task

Remove the crontab line matching `CLAUDE_TASK:<name>` and delete the entry from
`tasks.json`. Do NOT delete log files — the user may want those.

Ask for confirmation before removing.

Run: `bash /path/to/skill/scripts/crontab-manager.sh remove <name>`

### 4. Enable / Disable a task

- **Disable**: comment out the line with `#~ ` prefix, change status to `disabled`.
- **Enable**: remove the `#~ ` prefix, change status to `enabled`.

Update both the crontab and `tasks.json`.

Run: `bash /path/to/skill/scripts/crontab-manager.sh enable <name>` or `disable <name>`

### 5. Run a task immediately

Extract the command from the crontab line (or from `tasks.json`) and execute it
right now, streaming output to the terminal. This runs the exact same command that
cron would run, so it's a faithful test.

Run: `bash /path/to/skill/scripts/crontab-manager.sh run <name>`

### 6. Show logs

Tail the log file at `~/.claude/scheduled-tasks/logs/<name>.log`. Default to the
last 50 lines. The user can ask for more.

Run: `bash /path/to/skill/scripts/crontab-manager.sh logs <name> [lines]`

## Schedule parsing

When the user gives a human-readable schedule, convert it to a 5-field cron expression.
Common patterns:

| Human input | Cron expression |
|---|---|
| every 5 minutes | */5 * * * * |
| every hour | 0 * * * * |
| daily at 9am | 0 9 * * * |
| weekdays at 9am | 0 9 * * 1-5 |
| every monday at 8am | 0 8 * * 1 |
| every 6 hours | 0 */6 * * * |
| nightly at 2am | 0 2 * * * |
| first of every month at 6am | 0 6 1 * * |
| every sunday at noon | 0 12 * * 0 |

If the input is already a valid 5-field cron expression, use it directly. If ambiguous,
confirm with the user before proceeding.

## Safety considerations

- **Never use `--dangerously-skip-permissions` unless the user explicitly requests autonomous mode and confirms they understand the implications.** Default to running without it, which means tasks that need tool approval will pause (and effectively fail in cron). Explain this tradeoff.
- Always use `--max-turns` (default 10 if not specified) to prevent runaway executions.
- Always use `--allowedTools` when possible to restrict what the task can do.
- Log all output so the user can audit what happened.
- The `-l` (login shell) flag is important — without it, cron won't have the right PATH to find `claude`, `node`, etc.

## Platform notes

- **macOS**: cron works but may require granting Full Disk Access to `/usr/sbin/cron` in System Settings > Privacy & Security. Mention this if adding a task that accesses files outside the home directory. For even more robust scheduling on macOS, the user could use `launchd` instead, but this skill uses cron for cross-platform consistency.
- **Linux**: cron should work out of the box. Ensure the cron service is running (`systemctl status cron` or `service cron status`).
- Use `crontab -l` and `crontab -` (pipe) rather than editing crontab files directly.

## Helper script

The skill bundles `scripts/crontab-manager.sh` which handles the crontab manipulation.
Read and execute it rather than manually constructing crontab commands — it handles
edge cases like empty crontabs, preserving existing entries, and safe concurrent edits.

Before performing any operation, run:
```bash
bash <skill-path>/scripts/crontab-manager.sh <command> [args...]
```

If the script doesn't cover a specific need, you can fall back to manual crontab
manipulation following the patterns above, but prefer the script for consistency.


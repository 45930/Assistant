---
name: morning-briefing
description: Run the morning briefing workflow — gather context, prepare meeting dossiers, confirm priorities, plan the day's work, and sync to Google Tasks. Use this skill whenever the user says "good morning", "let's start the day", "morning briefing", "what's on today", "plan my day", "daily standup with myself", or invokes /morning-briefing. Also trigger when the user opens a new conversation in the morning and asks to get oriented or catch up on what's ahead.
user_invocable: true
---

# Morning Briefing

An interactive morning workflow that gathers context, prepares meeting dossiers, confirms priorities, plans the day, and syncs to Google Tasks.

The flow has three phases: **Gather** (automated context collection + meeting prep), **Plan** (interactive priority and todo confirmation with the user), and **Commit** (automated syncing to Google Tasks and calendar).

---

## Phase 1: Gather

### Step 1: Load Current State

Read these in parallel to build a picture of the day:

1. **Today's calendar:**
   ```bash
   gws calendar +agenda 2>/dev/null
   ```

2. **Google Tasks** (main list):
   ```bash
   gws tasks tasks list --params '{"tasklist":"TASKS_LIST_ID"}' 2>/dev/null
   ```
   Use the main task list ID from the **Google Tasks Lists** section of CLAUDE.md.

3. **Tracker files:**
   - `context/priorities.md`
   - `context/todos.md`
   - `context/docs.md`
   - Last 3 days of `context/` files (Glob for `*slack_summary*` and `*email_calendar*`)

4. **Slack — overnight activity:** Run the slack-pull job via the job runner (`jobs/_runner/run-job.sh slack-pull`). This executes in Docker, pulls DMs, mentions, and all watched channels since the last run, and promotes output to `context/`. After it completes, read the promoted context file for anything urgent — blockers, direct asks, or time-sensitive threads.

### Step 2: Meeting Dossier Prep

For each meeting on today's calendar, build a dossier. The goal is to walk into every call prepared — knowing what happened last time, what's unresolved, and what the user's objective should be.

Create the directory if it doesn't exist:
```bash
mkdir -p context/meeting_prep
```

For each meeting, create or update a file named `context/meeting_prep/<meeting-slug>.md` (e.g., `weekly-sync.md`, `onboarding-review.md`). Use a stable slug derived from the event name so the same file accumulates history across days.

#### Research steps for each meeting:

**a) Find previous instances of this meeting on the calendar.**
Search for events with a similar title in the past 30 days. Use ET offset (not `Z`/UTC) for day boundaries:
```bash
OFFSET=$(date +%:z)
THIRTY_DAYS_AGO=$(date -d "-30 days" +%Y-%m-%dT00:00:00)${OFFSET}
TODAY_END=$(date +%Y-%m-%dT23:59:59)${OFFSET}
gws calendar events list --params '{"calendarId":"primary","q":"MEETING_NAME","timeMin":"'"$THIRTY_DAYS_AGO"'","timeMax":"'"$TODAY_END"'","singleEvents":true,"orderBy":"startTime"}' 2>/dev/null
```
Note the last 2 occurrence dates — these anchor the rest of the research.

**b) Check for existing transcripts or notes.**
- Search `context/docs.md` for links related to this meeting name or participants.
- Search `context/` files for mentions of the meeting or attendees (Grep for the meeting name and key participant names).
- If no transcript is indexed locally, search Google Drive:
  ```bash
  gws drive files list --params '{"q":"name contains '\''MEETING_NAME'\'' and mimeType='\''application/vnd.google-apps.document'\''","orderBy":"modifiedTime desc","pageSize":5}' 2>/dev/null
  ```
  If a relevant doc is found, fetch and summarize it:
  ```bash
  gws docs documents get --params '{"documentId":"DOC_ID"}' 2>/dev/null
  ```

**c) Search Slack for relevant discussion.**
Use the `/slack` skill's ad-hoc search capability to find relevant discussion. Search with the user token via curl (see the slack skill for syntax) — this works for both public and private channels:
- Search for the meeting name and participant names in Slack over the past 5 days (e.g., `from:@person in:#channel after:YYYY-MM-DD`)
- Follow up on threads with `conversations.replies` for full context
- Use MCP `slack_get_user_profile` for user ID resolution if needed

**d) Write the dossier.** Use this format:

```markdown
# [Meeting Name] — Prep for YYYY-MM-DD

## Meeting Details
- **Time:** HH:MM - HH:MM
- **Attendees:** [names]
- **Recurring:** [yes/no, frequency]

## Previous Sessions

### [Date of last meeting]
- Key points / decisions
- Open items from that session

### [Date of meeting before that]
- Key points / decisions

## Recent Slack Context
- Summary of relevant Slack threads from the past 5 days

## Open Issues
- Unresolved items that will likely come up

## My Goals for This Call
- [Suggest 1-3 goals based on open issues, priorities, and recent context]

## Prep Notes
- [Any docs to review, data to pull, or talking points to prepare]
```

If researching a meeting turns up very little (e.g., a new or one-off event), keep the dossier short — just the meeting details, attendees, and a note about what the user might want to accomplish.

**e) Send the dossier to Slack as a DM.**

After writing each dossier file, send it as a Slack DM so the user can reference it on mobile. One message per meeting. Use the `mcp__slack__slack_post_message` tool with:
- `channel_id`: The authenticated user's own Slack user ID (use `auth.test` to resolve — **never send dossiers to any other user or channel**)
- `text`: The dossier content converted to Slack mrkdwn format (see conversion rules below)

**Markdown → Slack mrkdwn conversion rules:**
- `# Heading` and `## Heading` → `*Heading*` (Slack bold, on its own line)
- `**bold text**` → `*bold text*`
- `_italic_` stays as `_italic_`
- `- list item` → `•  list item`
- Nested lists: indent with spaces + `◦` for second level
- `[link text](url)` → `<url|link text>`
- Horizontal rules (`---`) → omit or use a blank line
- Keep blank lines between sections for readability
- Prefix the message with a meeting emoji: `:calendar:` for recurring meetings, `:handshake:` for external meetings

**Example Slack message:**
```
:handshake: *Partner Sync — Prep for 2026-03-26*

*Meeting Details*
•  *Time:* 1:00 - 2:00 PM ET
•  *Attendees:* Alice, Bob Chen, Carol Davis
•  *Recurring:* Yes, biweekly

*Previous Sessions*

*Mar 12, 2026*
•  Audit scope finalized — excluded legacy migration path
•  Bob pursuing split audit: two firms (~$120K)
•  Contract consolidated to single controller

*Open Issues*
•  Audit firm selection — split vs single vendor
•  Internal review status for upgrade path

*My Goals for This Call*
1.  Close the loop on audit firm selection
2.  Report back on internal review availability
3.  Update Bob on project timeline
```

If the Slack post fails (e.g., auth error, network issue), log the failure but continue with the rest of the briefing — don't block on it.

### Step 3: Present the Morning Summary

Once gathering is complete, present a concise briefing to the user:

```
## Morning Briefing — YYYY-MM-DD

### Today's Meetings
- HH:MM Meeting Name — [1-line prep summary, link to dossier file]
- ...

### Overdue / Due Today
- [tasks from Google Tasks that are overdue or due today]

### Overnight Highlights
- [2-3 bullet points from Slack/email summaries — blockers, decisions, asks]

### Available Focus Time
- [list gaps > 30 min between meetings, highlight blocks > 2 hours]
```

Keep this tight — the dossiers have the depth, this is the dashboard view.

---

## Phase 2: Plan

This phase is interactive. Pause and wait for user input at each checkpoint.

### Step 4: Project Status & Priorities

Instead of asking generically about priorities, load the project memory and present a project-aware view.

**Load project files:**
Read `{{MEMORY_DIR}}/MEMORY.md` to get the project index, then read each project file (or `overview.md` for directory-based projects).

**Match tasks to projects:**
Go through today's Google Tasks, calendar events, and overnight Slack/email action items. Map each to a project. Items that don't map to a known project may signal a new project to track.

**Present only projects with today-relevant work.** For each, show:

```
### [Project Name] — [Current Phase]
**Status:** [1-sentence current state from project memory]
**Today:**
- [ ] Task or action item
- [ ] Another task
**Next milestone:** [what's next after today's work]
```

Example:
```
### Project X — Phase 2: Implementation
**Status:** On track. Pending review from design lead.
**Today:**
- [ ] Review open PR for feature branch
- [ ] Respond to design feedback
- [ ] Update project roadmap
**Next milestone:** Feature complete by end of sprint
```

Only show projects that have tasks, meetings, or blockers for today. Skip projects with no today-relevant activity (e.g., don't show "GitHub Summaries" if it's just running on schedule).

After presenting, ask:

> "Here's what I see across your active projects. Anything to add, drop, or reprioritize?"

Wait for the user to confirm or adjust. If they mention a project shift (new phase, changed priority, new project entirely), update the relevant project file in memory immediately.

### Step 5: Build the Day's Todo List

Using the project-matched tasks from Step 4:

1. **Committed items** — tasks the user confirmed, due-today/overdue items, and meeting commitments. Group by project.

2. **Stretch items** — if the day has room (based on meeting load and focus time available), suggest 1-3 items from other projects or the broader task list. Consider what colleagues are working on (from Slack context and people notes) — pitching in on something a teammate is struggling with is high-value. Frame these as optional.

3. **Present the final list** and ask:

> "Here's the plan. Ready to commit?"

Wait for the user to finalize. Iterate if they want changes — this is a conversation, not a one-shot.

---

## Phase 3: Commit

Once the user approves the day's todos, execute these steps automatically.

### Step 6: Sync to "Do Today" Task List

**Find the "Do Today" list ID:**
```bash
gws tasks tasklists list 2>/dev/null
```
Look for a list with title "Do Today" (or similar). If it doesn't exist, create it:
```bash
gws tasks tasklists insert --json '{"title":"Do Today"}' 2>/dev/null
```

**Clear existing items** in the "Do Today" list (only this list — do not touch other lists):
```bash
gws tasks tasks list --params '{"tasklist":"DO_TODAY_LIST_ID"}' 2>/dev/null
```
For each task returned, delete it:
```bash
gws tasks tasks delete --params '{"tasklist":"DO_TODAY_LIST_ID","task":"TASK_ID"}' 2>/dev/null
```

**Add committed todos:**
For each item the user committed to:
```bash
gws tasks tasks insert --params '{"tasklist":"DO_TODAY_LIST_ID"}' --json '{"title":"Task description","due":"TODAY_ISOT00:00:00Z"}' 2>/dev/null
```

### Step 7: Save Context & Confirm

Write a context file to `context/YYYY-MM-DD_HHMMSS_morning_briefing.md` capturing:
- The finalized priority list
- The committed todos for the day
- Meeting dossier summaries (1-2 lines each, with pointers to full dossier files)

Then confirm to the user:

> "You're all set. [N] tasks in your Do Today list, [M] meetings prepped (dossiers in context/meeting_prep/). Have a great day!"

---

## Timezone Handling

The user is in **America/New_York** (ET). The system clock is also ET. All times displayed to the user or written to context files must be in ET.

**gws calendar API**: The Google Calendar API interprets `Z`-suffix timestamps as UTC. Using `T00:00:00Z` as a day boundary means 8pm ET the previous day — this will return events from the wrong day. **Always use explicit ET offsets** (`-04:00` for EDT, `-05:00` for EST) in `timeMin`/`timeMax` parameters. To get the correct offset dynamically:
```bash
OFFSET=$(date +%:z)  # returns e.g. "-04:00"
```

**gws calendar +agenda**: Uses the system timezone (ET) — safe to use as-is for "today's events."

**Google Tasks `due` field**: Uses `T00:00:00Z` by convention — this is a date-only field; the time component is ignored by Google Tasks. No conversion needed.

**Slack pull script**: JSON output uses UTC (ISO 8601 with `Z` suffix). When incorporating Slack times into context files or the briefing, convert to ET before display.

**Context file timestamps** (filenames and headers): Always use ET. Generate with:
```bash
date +%Y-%m-%d_%H%M%S  # system clock is ET
```

**Calendar event creation**: Always include `"timeZone": "America/New_York"` in start/end objects when creating calendar events.

## Error Handling

- If `gws` commands fail with auth errors, tell the user to run `gws auth login`.
- If the Slack script fails, continue without Slack data and note it in the briefing.
- If Google Drive search returns nothing for a meeting, that's fine — just note "no previous transcripts found" in the dossier.
- If the "Do Today" list can't be found or created, warn the user and skip the sync step rather than touching the wrong list.

## Important Notes

- The interactive steps (priority confirmation, todo finalization) are the core of this skill — don't rush past them. The user's buy-in on what they're committing to is what makes the day plan useful.
- Meeting dossier files are cumulative — if one already exists from a previous day, update it rather than overwriting. Add a new "Previous Sessions" entry and refresh the "Open Issues" and "My Goals" sections.
- Keep the morning summary concise. The user wants a dashboard, not a wall of text. Depth lives in the dossiers and context files.
- When suggesting stretch items, consider what the user's colleagues are working on (from Slack context) — pitching in on something a teammate mentioned struggling with is high-value.
- Focus time blocks should have `transparency: "opaque"` so they show as busy to others.

## People & Project Notes Integration

People notes: `{{MEMORY_DIR}}/people/<name-slug>.md`
Project notes: `{{MEMORY_DIR}}/projects/`

### During Gather (Phase 1)
- **Meeting dossier prep**: For each meeting attendee, check their people file. Incorporate "What They Value" and "Communication Style" into the dossier to help frame meeting goals.
- **Project context**: For each meeting, check if it maps to a tracked project. If so, read the project file and weave in current phase, open decisions, and blockers.
- **Slack overnight scan**: Note any people or project insights for updating in Phase 3.

### During Plan (Phase 2)
- **Project files drive the priority view.** Read all project files to understand current phases, then match today's tasks to projects. Only present projects with today-relevant work.
- When suggesting stretch items, check people files for colleagues struggling with something, and project files for approaching milestones.

### During Commit (Phase 3)
- After saving the context file, update both people and project files with new information gathered during the briefing.
- If the user mentions a project phase change, decision, or new project during planning, update the relevant project file immediately.
- If the user mentions something about a colleague (e.g., "Jamie really needs this by Thursday"), update that person's file.
- Create stub files for new external contacts or new projects that surface.

### Project file self-management
- Start new projects as a single file. Promote to a directory when >80 lines or distinct workstreams emerge.
- When promoting: move file to `<project>/overview.md`, break out workstreams/phases.
- Update `memory/MEMORY.md` index when creating or restructuring project files.
- Prune actively: decided items move out of "open," completed phases get archived to outcomes only.

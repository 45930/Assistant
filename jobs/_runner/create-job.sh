#!/usr/bin/env bash
# Scaffold a new job directory with job.yaml and entrypoint.sh template.
#
# Usage: create-job.sh <job-name>

set -euo pipefail

RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_DIR="$(dirname "$RUNNER_DIR")"

JOB_NAME="${1:-}"
if [ -z "$JOB_NAME" ]; then
  echo "Usage: create-job.sh <job-name>"
  echo "  Creates a new job directory at jobs/<job-name>/"
  exit 1
fi

# Validate name (lowercase, hyphens, no underscores or dots)
if [[ ! "$JOB_NAME" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "ERROR: Job name must be lowercase alphanumeric with hyphens (e.g., 'my-job')"
  exit 1
fi

JOB_DIR="$JOBS_DIR/$JOB_NAME"
if [ -d "$JOB_DIR" ]; then
  echo "ERROR: Job directory already exists: $JOB_DIR"
  exit 1
fi

# ============================================================
# GATHER INFO
# ============================================================

echo "Creating new job: $JOB_NAME"
echo ""

read -rp "Description: " DESCRIPTION
read -rp "Schedule (cron expression, e.g., '0 * * * *' for hourly): " SCHEDULE
read -rp "Does this job use Claude (headless agent)? [y/N]: " USES_CLAUDE
read -rp "Does this job need Google Workspace (gws) access? [y/N]: " MOUNT_GWS
read -rp "Custom network domains (beyond default allowlist)? [y/N]: " CUSTOM_DOMAINS
read -rp "Custom Dockerfile (extra system dependencies)? [y/N]: " CUSTOM_DOCKER
read -rp "Environment variables needed (comma-separated, or empty): " ENV_VARS
read -rp "State files to track (comma-separated, or empty): " STATE_FILES

# Normalize y/n
[[ "${USES_CLAUDE,,}" == "y" ]] && USES_CLAUDE="true" || USES_CLAUDE="false"
[[ "${MOUNT_GWS,,}" == "y" ]] && MOUNT_GWS="true" || MOUNT_GWS="false"

# ============================================================
# CREATE DIRECTORY
# ============================================================

mkdir -p "$JOB_DIR"

# ============================================================
# GENERATE job.yaml
# ============================================================

{
  echo "name: $JOB_NAME"
  echo "description: \"$DESCRIPTION\""
  echo "schedule: \"$SCHEDULE\""
  echo ""
  echo "entrypoint: ./entrypoint.sh"
  echo "timeout: 600"
  echo "uses_claude: $USES_CLAUDE"
  echo ""

  # Environment variables
  if [ -n "$ENV_VARS" ]; then
    echo "env:"
    IFS=',' read -ra VARS <<< "$ENV_VARS"
    for var in "${VARS[@]}"; do
      echo "  - $(echo "$var" | xargs)"
    done
  else
    echo "env: []"
  fi
  echo ""

  echo "volumes: []"
  echo ""

  # State files
  if [ -n "$STATE_FILES" ]; then
    echo "state:"
    IFS=',' read -ra FILES <<< "$STATE_FILES"
    for sf in "${FILES[@]}"; do
      echo "  - $(echo "$sf" | xargs)"
    done
  else
    echo "state: []"
  fi
  echo ""

  echo "mount_gws: $MOUNT_GWS"
} > "$JOB_DIR/job.yaml"

# ============================================================
# GENERATE entrypoint.sh
# ============================================================

if [ "$USES_CLAUDE" = "true" ]; then
  cat > "$JOB_DIR/entrypoint.sh" <<'ENTRY'
#!/usr/bin/env bash
set -euo pipefail

echo "Running JOB_NAME_PLACEHOLDER..."

# GWS credentials setup (if mount_gws: true)
if [ -d /secrets/gws ]; then
  mkdir -p ~/.config/gws
  for f in credentials.json client_secret.json .encryption_key account_timezone; do
    [ -f "/secrets/gws/$f" ] && ln -sf "/secrets/gws/$f" "$HOME/.config/gws/$f"
  done
  [ -f /secrets/gws/token_cache.json ] && cp /secrets/gws/token_cache.json "$HOME/.config/gws/token_cache.json"
fi

# --- Your job logic here ---
# The working directory is /workspace
# Config files are mounted at /config/
# Write all output to /workspace/quarantine/:
#   context/*.md         → auto-promoted to context/
#   memory/people/*.md   → promoted to context/inbox/ for main agent merge
#   memory/projects/*.md → promoted to context/inbox/ for main agent merge
#   state/               → promoted back to this job's directory

cd /workspace
claude -p "Your prompt here. Write output to /workspace/quarantine/." \
  --max-turns 25 \
  --dangerously-skip-permissions \
  2>&1

# Sync GWS token cache if refreshed
if [ -f "$HOME/.config/gws/token_cache.json" ]; then
  cp "$HOME/.config/gws/token_cache.json" /workspace/quarantine/state/token_cache.json
fi

echo "JOB_NAME_PLACEHOLDER complete."
ENTRY
  sed -i "s/JOB_NAME_PLACEHOLDER/$JOB_NAME/g" "$JOB_DIR/entrypoint.sh"
else
  cat > "$JOB_DIR/entrypoint.sh" <<ENTRY
#!/usr/bin/env bash
set -euo pipefail

echo "Running $JOB_NAME..."

# --- Your job logic here ---
# The working directory is /workspace
# Config files are mounted at /config/
# Write all output to /workspace/quarantine/:
#   context/*.md         → auto-promoted to context/
#   memory/people/*.md   → promoted to context/inbox/ for main agent merge
#   memory/projects/*.md → promoted to context/inbox/ for main agent merge
#   state/               → promoted back to this job's directory

echo "$JOB_NAME complete."
ENTRY
fi

chmod +x "$JOB_DIR/entrypoint.sh"

# ============================================================
# OPTIONAL: CLAUDE.md for headless agent jobs
# ============================================================

if [ "$USES_CLAUDE" = "true" ]; then
  cat > "$JOB_DIR/CLAUDE.md" <<'AGENT'
# Job Agent — Container Context

You are a data-gathering agent running inside an isolated container.

## Rules

1. **Write ONLY to `/workspace/quarantine/`**:
   - Context summaries: `/workspace/quarantine/context/YYYY-MM-DD_HHMMSS_<source>.md`
   - People observations: `/workspace/quarantine/memory/people/<name>.md`
   - Project observations: `/workspace/quarantine/memory/projects/<name>.md`
2. **Read from `/config/`** for reference data (read-only).
3. **You do NOT have access to existing memory notes.** Write raw observations only — the main agent outside this container will merge them into the canonical memory.
4. **Do NOT read `.env` or credential files** — API tokens are injected as env vars.
5. **Do NOT make network calls** to unapproved domains.

## Timezone

All times in **America/New_York** (ET).
AGENT
fi

# ============================================================
# OPTIONAL: Custom .domains file
# ============================================================

if [[ "${CUSTOM_DOMAINS,,}" == "y" ]]; then
  cat > "$JOB_DIR/.domains" <<'DOMAINS'
# Extra domains for this job (beyond the base allowlist in _base/.domains).
# One domain per line. Leading dot means "this domain and all subdomains."
# Example: .example.com
DOMAINS
  echo "  Created $JOB_DIR/.domains — add your extra domains there."
fi

# ============================================================
# OPTIONAL: Custom Dockerfile
# ============================================================

if [[ "${CUSTOM_DOCKER,,}" == "y" ]]; then
  cat > "$JOB_DIR/Dockerfile" <<'DOCKER'
FROM chief-of-staff-job-base:latest

# Add job-specific dependencies here
# RUN apt-get update && apt-get install -y python3 && rm -rf /var/lib/apt/lists/*
# COPY my-script.py /workspace/scripts/
DOCKER
  # Add dockerfile to job.yaml
  echo "" >> "$JOB_DIR/job.yaml"
  echo "dockerfile: ./Dockerfile" >> "$JOB_DIR/job.yaml"
  echo "  Created Dockerfile template — edit to add dependencies."
fi

# ============================================================
# TOUCH STATE FILES
# ============================================================

if [ -n "$STATE_FILES" ]; then
  IFS=',' read -ra FILES <<< "$STATE_FILES"
  for sf in "${FILES[@]}"; do
    touch "$JOB_DIR/$(echo "$sf" | xargs)"
  done
fi

# ============================================================
# DONE
# ============================================================

echo ""
echo "Created:"
echo "  $JOB_DIR/"
ls -la "$JOB_DIR/"
echo ""
echo "Next steps:"
echo "  1. Edit entrypoint.sh with your job logic"
[ "$USES_CLAUDE" = "true" ] && echo "  2. Edit CLAUDE.md with agent instructions"
echo "  3. Test: $RUNNER_DIR/run-job.sh $JOB_NAME"
echo "  4. Install cron: $RUNNER_DIR/run-job.sh --install-cron"

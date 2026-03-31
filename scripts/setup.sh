#!/usr/bin/env bash
# First-time setup: generates CLAUDE.md, org.yaml, context dirs, and .env stub.
#
# Usage: ./scripts/setup.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$REPO_DIR/CLAUDE.md.template"

echo "=== Chief of Staff — Setup ==="
echo ""

# ── Gather info ───────────────────────────────────────────────

if [ -f "$REPO_DIR/CLAUDE.md" ]; then
  read -rp "CLAUDE.md already exists. Overwrite? [y/N]: " OVERWRITE
  [[ "${OVERWRITE,,}" != "y" ]] && echo "Skipping CLAUDE.md generation." && SKIP_CLAUDE=true
fi

if [ "${SKIP_CLAUDE:-false}" != "true" ]; then
  echo "Let's personalize your setup."
  echo ""
  read -rp "Your name: " USER_NAME
  read -rp "Your role (e.g., Head of Engineering): " USER_ROLE
  read -rp "Company name: " COMPANY
  read -rp "Email domain (e.g., acme.com): " EMAIL_DOMAIN
  read -rp "Timezone (e.g., America/New_York): " TIMEZONE
fi

# ── Google Tasks setup ────────────────────────────────────────

echo ""
echo "Google Tasks integration (optional — press Enter to skip)."
echo "To find your task list IDs, run: gws tasks tasklists list"
read -rp "Main task list ID: " TASKS_LIST_ID
read -rp "Do Today task list ID: " DO_TODAY_LIST_ID
TASKS_LIST_ID="${TASKS_LIST_ID:-YOUR_TASKS_LIST_ID}"
DO_TODAY_LIST_ID="${DO_TODAY_LIST_ID:-YOUR_DO_TODAY_LIST_ID}"

# ── Generate CLAUDE.md ────────────────────────────────────────

if [ "${SKIP_CLAUDE:-false}" != "true" ]; then
  # Compute memory directory path
  SAFE_PATH=$(echo "$REPO_DIR" | tr '/' '-' | sed 's/^-//')
  MEMORY_DIR="~/.claude/projects/$SAFE_PATH/memory/"

  sed \
    -e "s|{{USER_NAME}}|$USER_NAME|g" \
    -e "s|{{USER_ROLE}}|$USER_ROLE|g" \
    -e "s|{{COMPANY}}|$COMPANY|g" \
    -e "s|{{EMAIL_DOMAIN}}|$EMAIL_DOMAIN|g" \
    -e "s|{{TIMEZONE}}|$TIMEZONE|g" \
    -e "s|{{TASKS_LIST_ID}}|$TASKS_LIST_ID|g" \
    -e "s|{{DO_TODAY_LIST_ID}}|$DO_TODAY_LIST_ID|g" \
    -e "s|{{MEMORY_DIR}}|$MEMORY_DIR|g" \
    "$TEMPLATE" > "$REPO_DIR/CLAUDE.md"

  echo "Created CLAUDE.md"
fi

# ── Generate org.yaml ─────────────────────────────────────────

if [ "${SKIP_CLAUDE:-false}" != "true" ]; then
  cat > "$REPO_DIR/jobs/org.yaml" <<EOF
# Organization config — shared across all jobs.
company: $COMPANY
email_domain: $EMAIL_DOMAIN
timezone: $TIMEZONE
EOF
  echo "Created jobs/org.yaml"
fi

# ── Create context directories ────────────────────────────────

mkdir -p "$REPO_DIR/context"/{inbox/people,inbox/projects,meeting_prep,quarantine}
echo "Created context directories"

# ── Create .env stub ──────────────────────────────────────────

if [ ! -f "$REPO_DIR/.env" ]; then
  cat > "$REPO_DIR/.env" <<'ENV'
# Required for Slack jobs
SLACK_USER_TOKEN=
SLACK_BOT_TOKEN=
SLACK_TEAM_ID=

# Required for Claude agent jobs
ANTHROPIC_API_KEY=

# Optional
GITHUB_TOKEN=
AMBIENT_API_KEY=
ENV
  echo "Created .env stub — fill in your API keys"
else
  echo ".env already exists, skipping"
fi

# ── Build base Docker image ──────────────────────────────────

echo ""
read -rp "Build the base Docker image now? [y/N]: " BUILD_BASE
if [[ "${BUILD_BASE,,}" == "y" ]]; then
  "$REPO_DIR/jobs/_runner/run-job.sh" --build-base
fi

# ── Done ──────────────────────────────────────────────────────

echo ""
echo "Setup complete. Next steps:"
echo "  1. Fill in API keys in .env"
echo "  2. Authenticate Google Workspace: gws auth login"
echo "  3. Edit CLAUDE.md to customize the Soul section"
echo "  4. Configure Slack channels in jobs/slack-pull/scripts/config.json"
echo "  5. Test a job: jobs/_runner/run-job.sh example"
echo "  6. Install cron: jobs/_runner/run-job.sh --install-cron"

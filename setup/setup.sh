#!/usr/bin/env bash
# Interactive setup for Chief of Staff.
# Walks through the full configuration with previews and confirmations.
#
# Usage: ./setup/setup.sh
#
# Safe to re-run — shows diffs for existing files and lets you skip unchanged ones.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ── Colors and formatting ────────────────────────────────────

BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

# ── Helper functions ─────────────────────────────────────────

section() {
  echo ""
  echo -e "${BOLD}${CYAN}── $1 ──${RESET}"
  echo ""
}

info() {
  echo -e "${DIM}$1${RESET}"
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local var_name="$3"
  if [ -n "$default" ]; then
    read -rp "$prompt [$default]: " value
    eval "$var_name=\"\${value:-$default}\""
  else
    read -rp "$prompt: " value
    eval "$var_name=\"\$value\""
  fi
}

confirm() {
  local prompt="$1"
  local default="${2:-n}"
  if [ "$default" = "y" ]; then
    read -rp "$prompt [Y/n]: " answer
    [[ "${answer,,}" != "n" ]]
  else
    read -rp "$prompt [y/N]: " answer
    [[ "${answer,,}" == "y" ]]
  fi
}

# Show a preview of file content and ask to write.
# Usage: preview_write <destination> <content> [description]
preview_write() {
  local dest="$1"
  local content="$2"
  local desc="${3:-$dest}"
  local lines

  echo -e "${BOLD}$desc${RESET}"
  echo -e "${DIM}→ $dest${RESET}"

  if [ -f "$dest" ]; then
    # File exists — show diff
    local tmp
    tmp=$(mktemp)
    echo "$content" > "$tmp"
    local diff_output
    diff_output=$(diff --color=always "$dest" "$tmp" 2>/dev/null || true)
    rm "$tmp"

    if [ -z "$diff_output" ]; then
      echo -e "${GREEN}  No changes.${RESET}"
      echo ""
      return 0
    fi

    echo -e "${YELLOW}  Changes:${RESET}"
    echo "$diff_output" | head -60
    lines=$(echo "$diff_output" | wc -l)
    if [ "$lines" -gt 60 ]; then
      echo -e "${DIM}  ... $(( lines - 60 )) more lines${RESET}"
    fi
  else
    # New file — show content
    echo -e "${YELLOW}  New file:${RESET}"
    echo "$content" | head -40
    lines=$(echo "$content" | wc -l)
    if [ "$lines" -gt 40 ]; then
      echo -e "${DIM}  ... $(( lines - 40 )) more lines${RESET}"
    fi
  fi

  echo ""
  if confirm "  Write?"; then
    mkdir -p "$(dirname "$dest")"
    echo "$content" > "$dest"
    echo -e "  ${GREEN}Written.${RESET}"
  else
    echo -e "  ${DIM}Skipped.${RESET}"
  fi
  echo ""
}

# Portable sed -i (macOS requires '' arg, Linux does not)
sedi() {
  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# ── Start ────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Chief of Staff — Setup${RESET}"
echo ""

# ── 1. Prerequisites ─────────────────────────────────────────

section "Prerequisites"

missing=()
for cmd in node jq docker; do
  if command -v "$cmd" &>/dev/null; then
    echo -e "  ${GREEN}✓${RESET} $cmd"
  else
    echo -e "  ${RED}✗${RESET} $cmd"
    missing+=("$cmd")
  fi
done

# gws is optional but recommended
if command -v gws &>/dev/null; then
  echo -e "  ${GREEN}✓${RESET} gws"
else
  echo -e "  ${YELLOW}○${RESET} gws (optional — install with: npm install -g @googleworkspace/cli)"
fi

if [ ${#missing[@]} -gt 0 ]; then
  echo ""
  echo -e "${RED}Missing required tools: ${missing[*]}${RESET}"
  echo "Install them before continuing."
  exit 1
fi

# ── 2. Gather config ─────────────────────────────────────────

section "Configuration"

ask "Projects directory" "$HOME/projects" PROJECTS_DIR
# Expand ~ if present
PROJECTS_DIR="${PROJECTS_DIR/#\~/$HOME}"

if [ ! -d "$PROJECTS_DIR" ]; then
  if confirm "  $PROJECTS_DIR doesn't exist. Create it?"; then
    mkdir -p "$PROJECTS_DIR"
  fi
fi
PROJECTS_DIR="$(cd "$PROJECTS_DIR" && pwd)"

echo ""
ask "Your name" "" USER_NAME
ask "Your role (e.g., Head of Engineering)" "" USER_ROLE
ask "Company name" "" COMPANY
ask "Email domain (e.g., acme.com)" "" EMAIL_DOMAIN
ask "Timezone" "America/New_York" TIMEZONE

echo ""
info "Google Tasks integration (optional — press Enter to skip)."
info "To find your task list IDs, run: gws tasks tasklists list"
ask "Main task list ID" "" TASKS_LIST_ID
ask "Do Today task list ID" "" DO_TODAY_LIST_ID
TASKS_LIST_ID="${TASKS_LIST_ID:-YOUR_TASKS_LIST_ID}"
DO_TODAY_LIST_ID="${DO_TODAY_LIST_ID:-YOUR_DO_TODAY_LIST_ID}"

# Derive memory directory path (Claude Code convention)
MEMORY_PATH="$REPO_DIR"
MEMORY_PATH="${MEMORY_PATH#/}"
MEMORY_PATH="${MEMORY_PATH//\//-}"
MEMORY_DIR="$HOME/.claude/projects/-${MEMORY_PATH}/memory"

echo ""
info "Derived paths:"
echo "  REPO:     $REPO_DIR"
echo "  PROJECTS: $PROJECTS_DIR"
echo "  MEMORY:   $MEMORY_DIR"

# ── 3. Global Claude config (~/.claude/) ─────────────────────

section "Global Claude config"

info "These settings apply to ALL your Claude Code sessions."
info "They add deny rules for sensitive paths and a global guard hook."
echo ""

# Build global settings.json
GLOBAL_SETTINGS=$(jq --arg home "$HOME" '
  del(._comment) |
  .permissions.deny = (.permissions.deny | map(gsub("/home/user"; $home))) |
  .hooks.PreToolUse[0].hooks[0].command = ($home + "/.claude/scripts/guard-secrets-global.sh")
' "$SCRIPT_DIR/settings.json")

if [ -f ~/.claude/settings.json ]; then
  MERGED_SETTINGS=$(jq -s '
    .[0] as $existing |
    .[1] as $new |
    $existing * {
      permissions: { deny: $new.permissions.deny },
      hooks: { PreToolUse: $new.hooks.PreToolUse }
    }
  ' ~/.claude/settings.json <(echo "$GLOBAL_SETTINGS"))
  preview_write "$HOME/.claude/settings.json" "$MERGED_SETTINGS" "Global settings.json"
else
  preview_write "$HOME/.claude/settings.json" "$GLOBAL_SETTINGS" "Global settings.json"
fi

# Global guard script
GUARD_GLOBAL=$(cat "$SCRIPT_DIR/guard-secrets-global.sh")
preview_write "$HOME/.claude/scripts/guard-secrets-global.sh" "$GUARD_GLOBAL" "Global guard hook"
if [ -f "$HOME/.claude/scripts/guard-secrets-global.sh" ]; then
  chmod +x "$HOME/.claude/scripts/guard-secrets-global.sh"
fi

# ── 4. Project Claude config (.claude/) ──────────────────────

section "Project Claude config"

info "These settings apply only to this repo."
info "Templates are copied from setup/templates/claude/ and paths are substituted."
echo ""

TEMPLATES="$SCRIPT_DIR/templates/claude"
if [ ! -d "$TEMPLATES" ]; then
  echo -e "${RED}ERROR: Templates not found at $TEMPLATES${RESET}"
  exit 1
fi

# settings.local.json
if [ -f "$TEMPLATES/settings.local.json" ]; then
  SETTINGS_LOCAL=$(jq --arg repo "$REPO_DIR" \
     --arg projects "$PROJECTS_DIR" \
     --arg memory "$MEMORY_DIR" \
  '
    .permissions.additionalDirectories = [$projects, $memory] |
    .sandbox.filesystem.allowWrite = [$projects, $memory] |
    .hooks.PreToolUse[0].hooks[0].command = ($repo + "/.claude/scripts/guard-secrets.sh") |
    .hooks.PreToolUse[1].hooks[0].command = ($repo + "/.claude/scripts/guard-memory-injection.sh")
  ' "$TEMPLATES/settings.local.json")
  preview_write "$REPO_DIR/.claude/settings.local.json" "$SETTINGS_LOCAL" "Project settings.local.json"
fi

# guard-secrets.sh
if [ -f "$TEMPLATES/scripts/guard-secrets.sh" ]; then
  GUARD_SECRETS=$(cat "$TEMPLATES/scripts/guard-secrets.sh")
  GUARD_SECRETS="${GUARD_SECRETS//\{\{REPO_DIR\}\}/$REPO_DIR}"
  GUARD_SECRETS="${GUARD_SECRETS//\{\{PROJECTS_DIR\}\}/$PROJECTS_DIR}"
  GUARD_SECRETS="${GUARD_SECRETS//\{\{HOME\}\}/$HOME}"
  preview_write "$REPO_DIR/.claude/scripts/guard-secrets.sh" "$GUARD_SECRETS" "Project guard hook (secrets)"
  if [ -f "$REPO_DIR/.claude/scripts/guard-secrets.sh" ]; then
    chmod +x "$REPO_DIR/.claude/scripts/guard-secrets.sh"
  fi
fi

# guard-memory-injection.sh
if [ -f "$TEMPLATES/scripts/guard-memory-injection.sh" ]; then
  GUARD_MEMORY=$(cat "$TEMPLATES/scripts/guard-memory-injection.sh")
  GUARD_MEMORY="${GUARD_MEMORY//\{\{MEMORY_DIR\}\}/$MEMORY_DIR}"
  preview_write "$REPO_DIR/.claude/scripts/guard-memory-injection.sh" "$GUARD_MEMORY" "Project guard hook (memory injection)"
  if [ -f "$REPO_DIR/.claude/scripts/guard-memory-injection.sh" ]; then
    chmod +x "$REPO_DIR/.claude/scripts/guard-memory-injection.sh"
  fi
fi

# Skills — confirm once for the batch
SKILLS_DIR="$TEMPLATES/skills"
if [ -d "$SKILLS_DIR" ]; then
  skill_count=$(find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  skill_names=$(find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | tr '\n' ', ' | sed 's/,$//')
  echo -e "${BOLD}Skills${RESET}"
  echo -e "${DIM}→ $REPO_DIR/.claude/skills/${RESET}"
  echo -e "  ${skill_count} skills: ${skill_names}"
  echo ""
  if confirm "  Copy all skills?"; then
    mkdir -p "$REPO_DIR/.claude/skills"
    cp -r "$SKILLS_DIR"/* "$REPO_DIR/.claude/skills/"
    echo -e "  ${GREEN}Copied.${RESET}"
  else
    echo -e "  ${DIM}Skipped.${RESET}"
  fi
  echo ""
fi

# ── 5. CLAUDE.md ─────────────────────────────────────────────

section "CLAUDE.md"

TEMPLATE_FILE="$REPO_DIR/CLAUDE.md.template"
if [ -f "$TEMPLATE_FILE" ]; then
  SAFE_PATH=$(echo "$REPO_DIR" | tr '/' '-' | sed 's/^-//')
  MEMORY_DIR_TILDE="~/.claude/projects/$SAFE_PATH/memory/"

  CLAUDE_MD=$(sed \
    -e "s|{{USER_NAME}}|$USER_NAME|g" \
    -e "s|{{USER_ROLE}}|$USER_ROLE|g" \
    -e "s|{{COMPANY}}|$COMPANY|g" \
    -e "s|{{EMAIL_DOMAIN}}|$EMAIL_DOMAIN|g" \
    -e "s|{{TIMEZONE}}|$TIMEZONE|g" \
    -e "s|{{TASKS_LIST_ID}}|$TASKS_LIST_ID|g" \
    -e "s|{{DO_TODAY_LIST_ID}}|$DO_TODAY_LIST_ID|g" \
    -e "s|{{MEMORY_DIR}}|$MEMORY_DIR_TILDE|g" \
    "$TEMPLATE_FILE")
  preview_write "$REPO_DIR/CLAUDE.md" "$CLAUDE_MD" "CLAUDE.md (agent instructions)"
else
  echo -e "${YELLOW}No CLAUDE.md.template found — skipping.${RESET}"
fi

# ── 6. org.yaml ──────────────────────────────────────────────

section "org.yaml"

ORG_YAML="# Organization config — shared across all jobs.
company: $COMPANY
email_domain: $EMAIL_DOMAIN
timezone: $TIMEZONE"

preview_write "$REPO_DIR/jobs/org.yaml" "$ORG_YAML" "org.yaml (shared job config)"

# ── 7. .env stub ─────────────────────────────────────────────

section "Environment"

if [ ! -f "$REPO_DIR/.env" ]; then
  ENV_STUB='# Required for Slack jobs
SLACK_USER_TOKEN=
SLACK_BOT_TOKEN=
SLACK_TEAM_ID=

# Required for Claude agent jobs
ANTHROPIC_API_KEY=

# Optional
GITHUB_TOKEN=
AMBIENT_API_KEY='

  preview_write "$REPO_DIR/.env" "$ENV_STUB" ".env (API keys stub)"
  if [ -f "$REPO_DIR/.env" ]; then
    chmod 600 "$REPO_DIR/.env"
  fi
else
  echo -e "${DIM}.env already exists — skipping.${RESET}"
fi

# ── 8. Context dirs + state files ────────────────────────────

section "Context and state files"

DIRS_TO_CREATE=(
  "$REPO_DIR/context"
  "$REPO_DIR/context/meeting_prep"
  "$REPO_DIR/context/inbox/people"
  "$REPO_DIR/context/inbox/projects"
  "$REPO_DIR/context/quarantine"
)

FILES_TO_TOUCH=(
  "$REPO_DIR/context/priorities.md"
  "$REPO_DIR/context/todos.md"
  "$REPO_DIR/context/docs.md"
)

echo "Directories:"
for d in "${DIRS_TO_CREATE[@]}"; do
  echo "  ${d#$REPO_DIR/}"
done
echo ""
echo "Files:"
for f in "${FILES_TO_TOUCH[@]}"; do
  echo "  ${f#$REPO_DIR/}"
done

# Per-job state files
JOBS_DIR="$REPO_DIR/jobs"
state_lines=()
for job_dir in "$JOBS_DIR"/*/; do
  [ -f "$job_dir/job.yaml" ] || continue
  job_name=$(basename "$job_dir")
  if command -v python3 &>/dev/null; then
    state_files=$(python3 -c "
import yaml, sys
with open('$job_dir/job.yaml') as f:
    data = yaml.safe_load(f)
for s in data.get('state', []):
    print(s)
" 2>/dev/null || true)
    for sf in $state_files; do
      echo "  jobs/$job_name/$sf"
      state_lines+=("$job_dir/$sf")
    done
  fi
done

echo ""
if confirm "Create these directories and files?"; then
  for d in "${DIRS_TO_CREATE[@]}"; do
    mkdir -p "$d"
  done
  for f in "${FILES_TO_TOUCH[@]}"; do
    touch "$f"
  done
  for sf in "${state_lines[@]}"; do
    touch "$sf"
  done
  echo -e "${GREEN}Done.${RESET}"
else
  echo -e "${DIM}Skipped.${RESET}"
fi

# ── 9. Memory directory ──────────────────────────────────────

section "Memory directory"

echo "  $MEMORY_DIR/"
echo "  $MEMORY_DIR/people/"
echo "  $MEMORY_DIR/projects/"
echo ""

if confirm "Create memory directory?"; then
  mkdir -p "$MEMORY_DIR/people" "$MEMORY_DIR/projects"
  if [ ! -f "$MEMORY_DIR/MEMORY.md" ]; then
    echo "# Memory Index" > "$MEMORY_DIR/MEMORY.md"
  fi
  echo -e "${GREEN}Done.${RESET}"
else
  echo -e "${DIM}Skipped.${RESET}"
fi

# ── 10. Optional steps ───────────────────────────────────────

section "Optional steps"

if command -v gws &>/dev/null; then
  if confirm "Authenticate Google Workspace CLI (gws auth login)?"; then
    echo ""
    info "See setup/claude_google.md for recommended OAuth scopes."
    echo ""
    gws auth login
  fi
else
  info "gws not installed — skipping Google auth."
  info "See setup/claude_google.md for full setup instructions."
fi

echo ""
if confirm "Build the base Docker image?"; then
  "$REPO_DIR/jobs/_runner/run-job.sh" --build-base
fi

echo ""
if confirm "Install cron schedules?"; then
  "$REPO_DIR/jobs/_runner/run-job.sh" --install-cron
fi

# ── Done ─────────────────────────────────────────────────────

section "Setup complete"

echo "Next steps:"
echo "  1. Fill in API keys in .env"
echo "  2. Edit CLAUDE.md to customize the Soul section"
echo "  3. Configure Slack channels in jobs/slack-pull/scripts/config.json"
echo "  4. Test a job: jobs/_runner/run-job.sh example"

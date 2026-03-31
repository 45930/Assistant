#!/usr/bin/env bash
# Ingest container guard hook — strict allowlist.
# The ingest agent can ONLY:
#   - Read from /workspace/ and /config/
#   - Write to /workspace/quarantine/ only
#   - Run approved bash commands (gws, tsx, node, curl to APIs)
# Everything else is blocked.

set -euo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name' 2>/dev/null || echo "")

block() {
  echo "{\"continue\":false,\"stopReason\":\"$1\"}"
  exit 0
}

# ============================================================
# FILE ACCESS: strict allowlist
# ============================================================
if [ "$TOOL_NAME" = "Read" ] || [ "$TOOL_NAME" = "Glob" ] || [ "$TOOL_NAME" = "Grep" ]; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null || echo "")
  if [ -n "$FILE_PATH" ]; then
    RESOLVED=$(realpath -m "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
    case "$RESOLVED" in
      /workspace/*|/config/*) ;; # allowed
      *) block "INGEST BLOCKED: Read access denied to $RESOLVED — only /workspace/ and /config/ are readable." ;;
    esac
  fi
fi

if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
  if [ -n "$FILE_PATH" ]; then
    RESOLVED=$(realpath -m "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
    case "$RESOLVED" in
      /workspace/quarantine/*) ;; # allowed — quarantine only
      *) block "INGEST BLOCKED: Write access denied to $RESOLVED — writes only allowed to /workspace/quarantine/." ;;
    esac
  fi
fi

# ============================================================
# BASH: block credential access and env dumps
# ============================================================
if [ "$TOOL_NAME" = "Bash" ]; then
  CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

  # Block env dumps
  if echo "$CMD" | grep -qiE '(^|\s)(printenv|env|set|export\s+-p|declare\s+-x)(\s*$|\s*;|\s*\|)'; then
    block "INGEST BLOCKED: Cannot dump environment variables."
  fi

  # Block echoing secrets
  if echo "$CMD" | grep -qiE '(echo|printf)\s.*\$\{?(ANTHROPIC_API_KEY|SLACK_BOT_TOKEN|SLACK_USER_TOKEN|N8N_API_KEY)'; then
    block "INGEST BLOCKED: Cannot echo credential values."
  fi

  # Block writes outside quarantine
  if echo "$CMD" | grep -qiE '>\s*/(?!workspace/quarantine)'; then
    block "INGEST BLOCKED: Shell output redirect outside quarantine."
  fi

  # Block reading .env directly
  if echo "$CMD" | grep -qiE '(cat|head|tail|source|base64)\s+.*\.env'; then
    block "INGEST BLOCKED: Cannot read .env files."
  fi

  # Block network exfiltration (only allow domains from .domains allowlist)
  if echo "$CMD" | grep -qiE '(curl|wget|nc|ncat)\s'; then
    local allowed_pattern=""
    if [ -f /config/.domains ]; then
      # Build regex from .domains file: .slack.com -> slack\.com
      allowed_pattern=$(grep -v '^\s*#' /config/.domains | grep -v '^\s*$' \
        | sed 's/^\.//' | sed 's/\./\\./g' | paste -sd '|' -)
    fi
    # Fallback to hardcoded defaults if .domains is missing or empty
    if [ -z "$allowed_pattern" ]; then
      allowed_pattern='slack\.com|googleapis\.com|accounts\.google\.com|api\.anthropic\.com'
    fi
    if ! echo "$CMD" | grep -qiE "($allowed_pattern)"; then
      block "INGEST BLOCKED: Network calls only allowed to domains in the allowlist."
    fi
  fi
fi

exit 0

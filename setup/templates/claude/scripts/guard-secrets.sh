#!/usr/bin/env bash
# Guard hook: allowlist-based filesystem access + credential leak prevention.
# Receives JSON on stdin with tool_name and tool_input.
# Outputs JSON with continue:false to block. Exits 0 in all cases.

set -euo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name' 2>/dev/null || echo "")

block() {
  echo "{\"continue\":false,\"stopReason\":\"$1\"}"
  exit 0
}

# ============================================================
# ALLOWLISTED DIRECTORIES — only these are accessible
# ============================================================
ALLOWED_PREFIXES=(
  "{{REPO_DIR}}/"
  "{{PROJECTS_DIR}}/"
  "{{HOME}}/.claude/"
)

# Files that are ALWAYS blocked even within allowed dirs
SECRET_FILE_PATTERN='\.env$|/\.env$|/\.env/|\.mcp\.json$|\.key$|\.pem$|auth-profiles\.json$|auth\.json$|/credentials/'

is_path_allowed() {
  local fpath="$1"

  # Resolve to absolute path (handle relative paths)
  if [[ "$fpath" != /* ]]; then
    fpath="{{REPO_DIR}}/$fpath"
  fi

  # Normalize: collapse // and resolve ..
  fpath=$(realpath -m "$fpath" 2>/dev/null || echo "$fpath")

  # Check against secret file patterns first (deny even in allowed dirs)
  if echo "$fpath" | grep -qE "$SECRET_FILE_PATTERN"; then
    return 1
  fi

  # Check if path is under any allowed prefix
  for prefix in "${ALLOWED_PREFIXES[@]}"; do
    if [[ "$fpath" == ${prefix}* ]] || [[ "$fpath" == "${prefix%/}" ]]; then
      return 0
    fi
  done

  return 1
}

# ============================================================
# FILE-PATH CHECKS (Read, Write, Edit)
# ============================================================
if [ "$TOOL_NAME" = "Read" ] || [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
  if [ -n "$FILE_PATH" ]; then
    if ! is_path_allowed "$FILE_PATH"; then
      block "BLOCKED: Access denied to $FILE_PATH — outside allowed directories. Enforced by guard-secrets hook."
    fi
  fi
fi

# ============================================================
# GLOB/GREP PATH CHECKS
# ============================================================
if [ "$TOOL_NAME" = "Glob" ]; then
  GLOB_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // ""' 2>/dev/null || echo "")
  if [ -n "$GLOB_PATH" ]; then
    if ! is_path_allowed "$GLOB_PATH"; then
      block "BLOCKED: Glob denied outside allowed directories. Enforced by guard-secrets hook."
    fi
  fi
fi

if [ "$TOOL_NAME" = "Grep" ]; then
  GREP_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // ""' 2>/dev/null || echo "")
  if [ -n "$GREP_PATH" ]; then
    if ! is_path_allowed "$GREP_PATH"; then
      block "BLOCKED: Grep denied outside allowed directories. Enforced by guard-secrets hook."
    fi
  fi
fi

# ============================================================
# BASH COMMAND CHECKS
# ============================================================
if [ "$TOOL_NAME" = "Bash" ]; then
  CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

  # Block 1: Commands that read secret files
  if echo "$CMD" | grep -qiE '(cat|head|tail|less|more|nano|vim?|bat|source|base64|xxd|od|strings|cp|mv|scp|rsync)\s+.*\.(env|mcp\.json|key|pem)(\s|$|;|\|)|cat\s+.*auth\.json|cat\s+.*auth-profiles|cat\s+.*credentials/'; then
    block "BLOCKED: Cannot read secret files via shell. Enforced by guard-secrets hook."
  fi

  # Block 2: Commands that dump the full environment
  if echo "$CMD" | grep -qiE '(^|\s|;|\||\$\()(printenv|env|set|export\s+-p|declare\s+-x)(\s*$|\s*;|\s*\||\s+[^-])'; then
    block "BLOCKED: Cannot dump environment variables. Enforced by guard-secrets hook."
  fi

  # Block 3: Commands that echo/printf specific secret variable values
  if echo "$CMD" | grep -qiE '(echo|printf|cat\s*<<<)\s.*\$\{?(ANTHROPIC_API_KEY|MOONSHOT_API_KEY|N8N_API_KEY|SLACK_BOT_TOKEN|SLACK_USER_TOKEN|AMBIENT_API_KEY|GITHUB_TOKEN|API_KEY|SECRET|PASSWORD|PRIVATE_KEY)'; then
    block "BLOCKED: Cannot echo credential values. Reference env vars by name, not value. Enforced by guard-secrets hook."
  fi

  # Block 4: Commands that exfiltrate via curl/wget with secrets
  if echo "$CMD" | grep -qiE '(curl|wget|fetch|nc|ncat)\s.*\$\{?(ANTHROPIC_API_KEY|MOONSHOT_API_KEY|N8N_API_KEY|SLACK_BOT_TOKEN|SLACK_USER_TOKEN|AMBIENT_API_KEY|GITHUB_TOKEN)'; then
    block "BLOCKED: Cannot send credentials to external services. Enforced by guard-secrets hook."
  fi

  # Block 5: Dotfile sourcing (.env loading)
  if echo "$CMD" | grep -qiE '(source|\.)\s+.*\.env(\s|$|;)'; then
    block "BLOCKED: Cannot source .env files. Enforced by guard-secrets hook."
  fi
fi

# Allow the operation
exit 0

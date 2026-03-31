#!/usr/bin/env bash
# Global guard hook: blocks access to sensitive files and credential leaks.
# Applies to ALL Claude Code sessions on this machine.
# No allowlist — just denies known-dangerous patterns.
# Per-project hooks can layer allowlist restrictions on top.
#
# Install: cp this to ~/.claude/scripts/guard-secrets-global.sh
#
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
# SENSITIVE PATHS — blocked for all tools in all projects
# ============================================================
SENSITIVE_DIRS=(
  "$HOME/.ssh/"
  "$HOME/.gnupg/"
  "$HOME/.aws/"
  "$HOME/.config/gws/"
  "$HOME/.config/gcloud/"
  "$HOME/.kube/"
  "$HOME/.docker/"
)

SENSITIVE_FILES=(
  "$HOME/.bash_history"
  "$HOME/.zsh_history"
  "$HOME/.node_repl_history"
  "$HOME/.python_history"
)

SECRET_FILE_PATTERN='\.env$|/\.env$|\.mcp\.json$|\.key$|\.pem$|auth-profiles\.json$|auth\.json$|/credentials/|/secrets/'

is_path_sensitive() {
  local fpath="$1"

  # Normalize path traversal
  fpath=$(realpath -m "$fpath" 2>/dev/null || echo "$fpath")

  # Check secret file patterns
  if echo "$fpath" | grep -qE "$SECRET_FILE_PATTERN"; then
    return 0
  fi

  # Check sensitive directories
  for dir in "${SENSITIVE_DIRS[@]}"; do
    if [[ "$fpath" == ${dir}* ]]; then
      return 0
    fi
  done

  # Check sensitive files
  for file in "${SENSITIVE_FILES[@]}"; do
    if [[ "$fpath" == "$file" ]]; then
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
  if [ -n "$FILE_PATH" ] && is_path_sensitive "$FILE_PATH"; then
    block "BLOCKED: Access denied to $FILE_PATH — sensitive file. Enforced by global guard-secrets hook."
  fi
fi

# ============================================================
# GLOB/GREP PATH CHECKS
# ============================================================
if [ "$TOOL_NAME" = "Glob" ] || [ "$TOOL_NAME" = "Grep" ]; then
  SEARCH_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // ""' 2>/dev/null || echo "")
  if [ -n "$SEARCH_PATH" ] && is_path_sensitive "$SEARCH_PATH"; then
    block "BLOCKED: Search denied in sensitive directory. Enforced by global guard-secrets hook."
  fi
fi

# ============================================================
# BASH COMMAND CHECKS
# ============================================================
if [ "$TOOL_NAME" = "Bash" ]; then
  CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

  # Block 1: Commands that read secret files
  if echo "$CMD" | grep -qiE '(cat|head|tail|less|more|nano|vim?|bat|source|base64|xxd|od|strings|cp|mv|scp|rsync)\s+.*\.(env|mcp\.json|key|pem)(\s|$|;|\|)|cat\s+.*auth\.json|cat\s+.*auth-profiles|cat\s+.*credentials/'; then
    block "BLOCKED: Cannot read secret files via shell. Enforced by global guard-secrets hook."
  fi

  # Block 2: Commands that dump the full environment
  if echo "$CMD" | grep -qiE '(^|\s|;|\||\$\()(printenv|env|set|export\s+-p|declare\s+-x)(\s*$|\s*;|\s*\||\s+[^-])'; then
    block "BLOCKED: Cannot dump environment variables. Enforced by global guard-secrets hook."
  fi

  # Block 3: Commands that echo/printf specific secret variable values
  if echo "$CMD" | grep -qiE '(echo|printf|cat\s*<<<)\s.*\$\{?(ANTHROPIC_API_KEY|MOONSHOT_API_KEY|N8N_API_KEY|SLACK_BOT_TOKEN|SLACK_USER_TOKEN|AMBIENT_API_KEY|GITHUB_TOKEN|API_KEY|SECRET|PASSWORD|PRIVATE_KEY)'; then
    block "BLOCKED: Cannot echo credential values. Reference env vars by name, not value. Enforced by global guard-secrets hook."
  fi

  # Block 4: Commands that exfiltrate via curl/wget with secrets
  if echo "$CMD" | grep -qiE '(curl|wget|fetch|nc|ncat)\s.*\$\{?(ANTHROPIC_API_KEY|MOONSHOT_API_KEY|N8N_API_KEY|SLACK_BOT_TOKEN|SLACK_USER_TOKEN|AMBIENT_API_KEY|GITHUB_TOKEN)'; then
    block "BLOCKED: Cannot send credentials to external services. Enforced by global guard-secrets hook."
  fi

  # Block 5: Dotfile sourcing (.env loading)
  if echo "$CMD" | grep -qiE '(source|\.)\s+.*\.env(\s|$|;)'; then
    block "BLOCKED: Cannot source .env files. Enforced by global guard-secrets hook."
  fi
fi

# Allow the operation
exit 0

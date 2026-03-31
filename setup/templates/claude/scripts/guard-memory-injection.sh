#!/usr/bin/env bash
# PreToolUse hook: scan content being written to the memory directory for
# prompt injection patterns. Reuses the same pattern set as validate-quarantine.sh.
#
# Only fires on Write and Edit targeting the memory directory.
# Receives JSON on stdin with tool_name and tool_input.
# Outputs JSON with continue:false to block. Exits 0 in all cases.

set -euo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name' 2>/dev/null || echo "")

MEMORY_DIR="{{MEMORY_DIR}}"

block() {
  echo "{\"continue\":false,\"stopReason\":\"$1\"}"
  exit 0
}

# Only check Write and Edit
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
  exit 0
fi

# Get the target file path
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")

# Only check files targeting the memory directory
case "$FILE_PATH" in
  "$MEMORY_DIR"/*) ;;
  *) exit 0 ;;
esac

# Extract the content to scan
if [ "$TOOL_NAME" = "Write" ]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null || echo "")
elif [ "$TOOL_NAME" = "Edit" ]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""' 2>/dev/null || echo "")
fi

# Skip if no content
[ -z "$CONTENT" ] && exit 0

# Allow MEMORY.md index file — it's just pointers, not external content
case "$FILE_PATH" in
  "$MEMORY_DIR/MEMORY.md") exit 0 ;;
esac

# ============================================================
# PROMPT INJECTION DETECTION PATTERNS
# (mirrors validate-quarantine.sh)
# ============================================================

ISSUES=()

scan() {
  local name="$1"
  local pattern="$2"
  if echo "$CONTENT" | grep -qiE "$pattern" 2>/dev/null; then
    ISSUES+=("$name")
  fi
}

# Direct instruction injection
scan "instruction_override" '(ignore|disregard|forget)[[:space:]]+(all[[:space:]]+)?(previous|prior|above|earlier)[[:space:]]+(instructions|context|rules|prompts)'
scan "system_prompt" '^(system|assistant|user)[[:space:]]*:'
scan "role_hijack" '(you[[:space:]]+are[[:space:]]+(now|a)|act[[:space:]]+as|pretend[[:space:]]+(to[[:space:]]+be|you)|from[[:space:]]+now[[:space:]]+on[[:space:]]+you)'
scan "tool_injection" '(use[[:space:]]+the[[:space:]]+(bash|write|edit|read)[[:space:]]+tool|run[[:space:]]+this[[:space:]]+command|execute[[:space:]]+the[[:space:]]+following)'
scan "prompt_leak" '(repeat|show|print|output|reveal)[[:space:]]+(your|the|all)[[:space:]]+(system[[:space:]]+)?(prompt|instructions|rules)'

# Data exfiltration attempts
scan "exfil_curl" 'curl[[:space:]]+(-[sS]?[[:space:]]+)?https?://'
scan "exfil_base64" '(base64|btoa|atob)[[:space:]]*[(\[]'
scan "exfil_webhook" '(webhook|callback|postback|exfiltrate|ngrok|burp)'
scan "encoded_payload" '[A-Za-z0-9+/]{100,}={0,2}'

# Code execution
scan "code_exec" '(eval|exec|system|subprocess|child_process|spawn|popen)[[:space:]]*\('
scan "script_tag" '<script[^>]*>'
scan "shell_injection" '(\$\(|`)[^)]*\b(curl|wget|nc|bash|sh|python|node|ruby)\b'

# File system manipulation
scan "path_traversal" '\.\./\.\./|/etc/(passwd|shadow|hosts)|~/.ssh|~/.env'
scan "file_write" '(write|append|create)[[:space:]]+(to[[:space:]]+)?(file|/|~)'

# Suspicious formatting tricks
scan "invisible_text" '<!--.*(instruction|ignore|system|prompt).*-->'
scan "zero_width" $'[\xe2\x80\x8b\xe2\x80\x8c\xe2\x80\x8d\xef\xbb\xbf]'

# Long lines (>2000 chars)
if echo "$CONTENT" | awk 'length > 2000 { found=1; exit } END { exit !found }' 2>/dev/null; then
  ISSUES+=("long_lines")
fi

# High special character ratio
TOTAL_CHARS=$(echo -n "$CONTENT" | wc -c)
if [ "$TOTAL_CHARS" -gt 100 ]; then
  SPECIAL_CHARS=$(echo -n "$CONTENT" | tr -cd '\\|{}[]<>^~`' | wc -c)
  RATIO=$((SPECIAL_CHARS * 100 / TOTAL_CHARS))
  if [ "$RATIO" -gt 30 ]; then
    ISSUES+=("high_special_char_ratio:${RATIO}%")
  fi
fi

if [ ${#ISSUES[@]} -gt 0 ]; then
  block "BLOCKED: Memory write to $(basename "$FILE_PATH") flagged for prompt injection — issues: ${ISSUES[*]}. Content was NOT written. Review the source data for injection attempts."
fi

exit 0

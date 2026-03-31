#!/usr/bin/env bash
# Validate quarantined job output for prompt injection before promotion.
# Scans each file for suspicious patterns. Clean files are promoted;
# suspicious files are flagged and left in quarantine.
#
# Usage: validate-quarantine.sh <job-name> [--dry-run]
#
# Promotion targets:
#   context/*.md        → context/                  (auto-promote)
#   memory/people/*.md  → context/inbox/people/     (pending merge by main agent)
#   memory/projects/*.md → context/inbox/projects/  (pending merge by main agent)
#   state/*             → jobs/<job>/                (back to job dir)
#
# Exit codes:
#   0 = all files clean and promoted
#   1 = some files flagged (left in quarantine for manual review)
#   2 = script error

set -euo pipefail

JOB_NAME="${1:-}"
[ -z "$JOB_NAME" ] && { echo "Usage: validate-quarantine.sh <job-name> [--dry-run]"; exit 2; }

RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_DIR="$(dirname "$RUNNER_DIR")"
REPO_DIR="$(dirname "$JOBS_DIR")"

QUARANTINE_DIR="$REPO_DIR/context/quarantine/$JOB_NAME"
CONTEXT_DIR="$REPO_DIR/context"
INBOX_DIR="$REPO_DIR/context/inbox"
JOB_DIR="$JOBS_DIR/$JOB_NAME"
LOG_FILE="$QUARANTINE_DIR/.validation.log"

DRY_RUN=false
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true

FLAGGED=0
PROMOTED=0
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log() {
  echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

# ============================================================
# PROMPT INJECTION DETECTION PATTERNS
# ============================================================

declare -A PATTERNS
PATTERNS=(
  # Direct instruction injection
  ["instruction_override"]='(?i)(ignore|disregard|forget)\s+(all\s+)?(previous|prior|above|earlier)\s+(instructions|context|rules|prompts)'
  ["system_prompt"]='(?i)^(system|assistant|user)\s*:'
  ["role_hijack"]='(?i)(you\s+are\s+(now|a)|act\s+as|pretend\s+(to\s+be|you)|from\s+now\s+on\s+you)'
  ["tool_injection"]='(?i)(use\s+the\s+(bash|write|edit|read)\s+tool|run\s+this\s+command|execute\s+the\s+following)'
  ["prompt_leak"]='(?i)(repeat|show|print|output|reveal)\s+(your|the|all)\s+(system\s+)?(prompt|instructions|rules)'

  # Data exfiltration attempts
  ["exfil_curl"]='(?i)curl\s+(-[sS]?\s+)?https?://'
  ["exfil_base64"]='(?i)(base64|btoa|atob)\s*[\(\s]'
  ["exfil_webhook"]='(?i)(webhook|callback|postback|exfiltrate|ngrok|burp)'
  ["encoded_payload"]='[A-Za-z0-9+/]{100,}={0,2}'

  # Code execution
  ["code_exec"]='(?i)(eval|exec|system|subprocess|child_process|spawn|popen)\s*\('
  ["script_tag"]='<script[^>]*>'
  ["shell_injection"]='(?i)(\$\(|`)[^)]*\b(curl|wget|nc|bash|sh|python|node|ruby)\b'

  # File system manipulation
  ["path_traversal"]='(?i)\.\./\.\./|/etc/(passwd|shadow|hosts)|~/.ssh|~/.env'
  ["file_write"]='(?i)(write|append|create)\s+(to\s+)?(file|\/|~)'

  # Suspicious markdown/formatting tricks
  ["invisible_text"]='(?i)(<!--.*?(instruction|ignore|system|prompt).*?-->)'
  ["zero_width"]='[\x{200B}\x{200C}\x{200D}\x{FEFF}]'
)

## Per-job validation overrides
# If jobs/<job>/.validation-overrides exists, each line names a pattern to skip.
# This lets jobs whose output naturally triggers false positives (e.g., competitive
# intel reports that reference curl commands) suppress specific checks while keeping
# all other injection scanning active.
SKIP_PATTERNS=()
if [ -f "$JOB_DIR/.validation-overrides" ]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    SKIP_PATTERNS+=("$line")
  done < "$JOB_DIR/.validation-overrides"
fi

is_skipped() {
  local name="$1"
  for skip in "${SKIP_PATTERNS[@]+"${SKIP_PATTERNS[@]}"}"; do
    [[ "$skip" == "$name" ]] && return 0
  done
  return 1
}

check_file() {
  local file="$1"
  local filename
  filename=$(basename "$file")
  local issues=()

  # Skip empty files
  [[ ! -s "$file" ]] && return 0

  local content
  content=$(cat "$file")

  for name in "${!PATTERNS[@]}"; do
    is_skipped "$name" && continue
    pattern="${PATTERNS[$name]}"
    if echo "$content" | grep -qPi "$pattern" 2>/dev/null; then
      issues+=("$name")
    fi
  done

  # Check for unusually long lines (potential obfuscation)
  if awk 'length > 2000' "$file" | grep -q .; then
    issues+=("long_lines")
  fi

  # Check for high ratio of special characters (potential encoding tricks)
  local total_chars special_chars ratio
  total_chars=$(wc -c < "$file")
  special_chars=$(tr -cd '\\|{}[]<>^~`' < "$file" | wc -c)
  if [ "$total_chars" -gt 100 ]; then
    ratio=$((special_chars * 100 / total_chars))
    if [ "$ratio" -gt 30 ]; then
      issues+=("high_special_char_ratio:${ratio}%")
    fi
  fi

  if [ ${#issues[@]} -gt 0 ]; then
    log "FLAGGED: $filename — issues: ${issues[*]}"
    return 1
  fi

  return 0
}

promote_file() {
  local src="$1"
  local dest="$2"

  if $DRY_RUN; then
    log "DRY-RUN: would promote $src -> $dest"
  else
    mkdir -p "$(dirname "$dest")"
    mv "$src" "$dest"
    log "PROMOTED: $(basename "$src") -> $dest"
  fi
  ((PROMOTED++)) || true
}

flag_file() {
  local file="$1"
  local flagged_dir="$QUARANTINE_DIR/.flagged"
  mkdir -p "$flagged_dir"

  if ! $DRY_RUN; then
    mv "$file" "$flagged_dir/"
  fi
  ((FLAGGED++)) || true
}

# ============================================================
# PROCESS QUARANTINED FILES
# ============================================================

log "--- Validation run: $JOB_NAME ---"

# Context files → auto-promote to context/
for file in "$QUARANTINE_DIR"/context/*.md; do
  [[ -f "$file" ]] || continue
  if check_file "$file"; then
    promote_file "$file" "$CONTEXT_DIR/$(basename "$file")"
  else
    flag_file "$file"
  fi
done

# Memory: people notes → inbox (main agent merges)
for file in "$QUARANTINE_DIR"/memory/people/*.md; do
  [[ -f "$file" ]] || continue
  if check_file "$file"; then
    promote_file "$file" "$INBOX_DIR/people/${JOB_NAME}_$(basename "$file")"
  else
    flag_file "$file"
  fi
done

# Memory: project notes → inbox (main agent merges)
for file in "$QUARANTINE_DIR"/memory/projects/*.md; do
  [[ -f "$file" ]] || continue
  if check_file "$file"; then
    promote_file "$file" "$INBOX_DIR/projects/${JOB_NAME}_$(basename "$file")"
  else
    flag_file "$file"
  fi
done

# State files → promote back to job directory
for file in "$QUARANTINE_DIR"/state/*; do
  [[ -f "$file" ]] || continue
  local_name=$(basename "$file")
  # Skip token_cache.json (handled by run-job.sh)
  [ "$local_name" = "token_cache.json" ] && continue
  # Quick sanity check: state files should be very small
  if [ "$(wc -c < "$file")" -lt 100 ]; then
    promote_file "$file" "$JOB_DIR/$local_name"
  else
    log "FLAGGED: state file $local_name too large ($(wc -c < "$file") bytes)"
    flag_file "$file"
  fi
done

# ============================================================
# SUMMARY
# ============================================================

log "Validation complete: $PROMOTED promoted, $FLAGGED flagged"

if [ "$FLAGGED" -gt 0 ]; then
  log "WARNING: $FLAGGED files flagged for manual review in $QUARANTINE_DIR/.flagged/"
  exit 1
fi

exit 0

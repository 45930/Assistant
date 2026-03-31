#!/usr/bin/env bash
set -euo pipefail

echo "Running meeting-notes..."

# GWS credentials setup
if [ -d /secrets/gws ]; then
  mkdir -p ~/.config/gws
  for f in credentials.json client_secret.json .encryption_key account_timezone; do
    [ -f "/secrets/gws/$f" ] && ln -sf "/secrets/gws/$f" "$HOME/.config/gws/$f"
  done
  [ -f /secrets/gws/token_cache.json ] && cp /secrets/gws/token_cache.json "$HOME/.config/gws/token_cache.json"
fi

# Restore state
[ -f /config/state/.last_run ] && cp /config/state/.last_run /workspace/.last_run
LAST_RUN=$(cat /workspace/.last_run 2>/dev/null || echo "FIRST_RUN")

# Run headless Claude agent
cd /workspace
claude -p "Fetch meeting notes since ${LAST_RUN}. Check both Ambient API and Gmail for Google Docs meeting notes. Write context summaries, people notes, and project notes per the instructions in CLAUDE.md. Write the updated .last_run timestamp (ISO 8601, ET) to /workspace/quarantine/state/.last_run when done." \
  --max-turns 30 \
  --dangerously-skip-permissions \
  2>&1

# Fallback: preserve state if Claude didn't write it
[ -f /workspace/.last_run ] && \
  [ ! -f /workspace/quarantine/state/.last_run ] && \
  cp /workspace/.last_run /workspace/quarantine/state/.last_run

# Sync GWS token cache if refreshed
if [ -f "$HOME/.config/gws/token_cache.json" ]; then
  cp "$HOME/.config/gws/token_cache.json" /workspace/quarantine/state/token_cache.json
fi

echo "meeting-notes complete."

#!/usr/bin/env bash
set -euo pipefail

echo "Running email-calendar..."

# GWS credentials setup
if [ -d /secrets/gws ]; then
  mkdir -p ~/.config/gws
  for f in credentials.json client_secret.json .encryption_key account_timezone; do
    [ -f "/secrets/gws/$f" ] && ln -sf "/secrets/gws/$f" "$HOME/.config/gws/$f"
  done
  [ -f /secrets/gws/token_cache.json ] && cp /secrets/gws/token_cache.json "$HOME/.config/gws/token_cache.json"
fi

# Restore state
[ -f /config/state/.last_run_email ] && cp /config/state/.last_run_email /workspace/scripts/.last_run_email
LAST_RUN=$(cat /workspace/scripts/.last_run_email 2>/dev/null || echo "FIRST_RUN")

# Run headless Claude agent
cd /workspace
claude -p "Fetch new emails and calendar events since ${LAST_RUN}. Write context summaries, people notes, and project notes per the instructions in CLAUDE.md. Write the updated .last_run_email timestamp to /workspace/quarantine/state/.last_run_email when done." \
  --max-turns 25 \
  --dangerously-skip-permissions \
  2>&1

# Fallback: preserve state if Claude didn't write it
[ -f /workspace/scripts/.last_run_email ] && \
  [ ! -f /workspace/quarantine/state/.last_run_email ] && \
  cp /workspace/scripts/.last_run_email /workspace/quarantine/state/.last_run_email

# Sync GWS token cache if refreshed
if [ -f "$HOME/.config/gws/token_cache.json" ]; then
  cp "$HOME/.config/gws/token_cache.json" /workspace/quarantine/state/token_cache.json
fi

echo "email-calendar complete."

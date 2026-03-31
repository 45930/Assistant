#!/usr/bin/env bash
set -euo pipefail

echo "Running example job..."

# ── GWS credentials setup (when mount_gws: true) ──────────────
# The runner mounts /secrets/gws read-only. Symlink into the
# expected config location so `gws` CLI finds them.
if [ -d /secrets/gws ]; then
  mkdir -p ~/.config/gws
  for f in credentials.json client_secret.json .encryption_key account_timezone; do
    [ -f "/secrets/gws/$f" ] && ln -sf "/secrets/gws/$f" "$HOME/.config/gws/$f"
  done
  # Token cache needs to be writable (gws refreshes it), so copy instead of symlink
  [ -f /secrets/gws/token_cache.json ] && cp /secrets/gws/token_cache.json "$HOME/.config/gws/token_cache.json"
fi

# ── Restore state from previous run ───────────────────────────
# State files are mounted read-only at /config/state/<name>.
# Read the last-run timestamp so we only fetch new data.
LAST_RUN="1970-01-01T00:00:00-04:00"
if [ -f /config/state/.last_run ] && [ -s /config/state/.last_run ]; then
  LAST_RUN=$(cat /config/state/.last_run)
fi
echo "Last run: $LAST_RUN"

# ── Read config ───────────────────────────────────────────────
# Volumes from job.yaml are mounted read-only at /config/.
echo "Config:"
cat /config/config.json

# ── Main job logic ────────────────────────────────────────────
# This is where you do your work. For Claude agent jobs, run
# claude with a prompt. For script jobs, run your script.
#
# All output MUST go to /workspace/quarantine/:
#   context/*.md         → auto-promoted to context/
#   memory/people/*.md   → promoted to context/inbox/ for main agent merge
#   memory/projects/*.md → promoted to context/inbox/ for main agent merge
#   state/*              → promoted back to this job's directory

cd /workspace

TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')

claude -p "You are an example data-gathering agent. Write a short test file.

Write a context file to /workspace/quarantine/context/${TIMESTAMP}_example.md with:
- A heading '# Example Job Output — $(date '+%Y-%m-%d %H:%M') ET'
- A note that this is a test run
- The last run timestamp: $LAST_RUN

Then write the current timestamp to /workspace/quarantine/state/.last_run" \
  --max-turns 10 \
  --dangerously-skip-permissions \
  2>&1

# ── Sync GWS token cache if refreshed ─────────────────────────
if [ -f "$HOME/.config/gws/token_cache.json" ]; then
  cp "$HOME/.config/gws/token_cache.json" /workspace/quarantine/state/token_cache.json
fi

echo "Example job complete."

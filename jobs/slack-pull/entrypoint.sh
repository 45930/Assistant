#!/usr/bin/env bash
set -euo pipefail

echo "Running slack-pull..."

# Symlink config for slack_pull.ts path resolution
[ -f /config/config.json ] && ln -sf /config/config.json /workspace/scripts/config.json
ln -sfn /workspace/quarantine/context /workspace/context

# Restore state
[ -f /config/state/.last_run ] && cp /config/state/.last_run /workspace/scripts/.last_run

# Run
cd /workspace
tsx scripts/slack_pull.ts 2>&1

# Save updated state to quarantine for promotion
[ -f /workspace/scripts/.last_run ] && cp /workspace/scripts/.last_run /workspace/quarantine/state/.last_run

echo "slack-pull complete."

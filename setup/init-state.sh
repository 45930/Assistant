#!/usr/bin/env bash
# Initialize state files and directories needed by the job runner.
# Docker bind-mounts fail if the source files don't exist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
JOBS_DIR="$REPO_DIR/jobs"

echo "Initializing state files..."

# Context directory and data files
mkdir -p "$REPO_DIR/context"
mkdir -p "$REPO_DIR/context/meeting_prep"
mkdir -p "$REPO_DIR/context/inbox/people"
mkdir -p "$REPO_DIR/context/inbox/projects"
mkdir -p "$REPO_DIR/context/quarantine"
touch "$REPO_DIR/context/priorities.md"
touch "$REPO_DIR/context/todos.md"
touch "$REPO_DIR/context/docs.md"

# Per-job state files
for job_dir in "$JOBS_DIR"/*/; do
  [ -f "$job_dir/job.yaml" ] || continue
  job_name=$(basename "$job_dir")
  # Parse state files from job.yaml
  if command -v python3 &>/dev/null; then
    state_files=$(python3 -c "
import yaml, json, sys
with open('$job_dir/job.yaml') as f:
    data = yaml.safe_load(f)
for s in data.get('state', []):
    print(s)
" 2>/dev/null || true)
    for sf in $state_files; do
      touch "$job_dir/$sf"
    done
  fi
  echo "  Initialized state for: $job_name"
done

echo "Done."

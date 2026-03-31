#!/usr/bin/env bash
# Generic job runner: parse job.yaml, generate docker-compose, run container,
# validate quarantine output, promote clean files.
#
# Usage:
#   run-job.sh <job-name>        Run a single job
#   run-job.sh all               Run all jobs sequentially
#   run-job.sh --install-cron    Write per-job crontab entries
#   run-job.sh --build-base      Build (or rebuild) the base Docker image

set -euo pipefail

RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# macOS ships without `timeout`; use gtimeout from coreutils if available
if ! command -v timeout &>/dev/null; then
  if command -v gtimeout &>/dev/null; then
    timeout() { gtimeout "$@"; }
  else
    die "Neither 'timeout' nor 'gtimeout' found. Install coreutils: brew install coreutils"
  fi
fi
JOBS_DIR="$(dirname "$RUNNER_DIR")"
REPO_DIR="$(dirname "$JOBS_DIR")"
BASE_DIR="$JOBS_DIR/_base"
QUARANTINE_ROOT="$REPO_DIR/context/quarantine"
CONTEXT_DIR="$REPO_DIR/context"
INBOX_DIR="$REPO_DIR/context/inbox"
BASE_IMAGE="chief-of-staff-job-base:latest"

# ============================================================
# HELPERS
# ============================================================

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

die() {
  log "ERROR: $1"
  exit 1
}

parse_yaml() {
  # Convert job.yaml to JSON via python3 + pyyaml
  python3 -c "
import sys, yaml, json
with open(sys.argv[1]) as f:
    json.dump(yaml.safe_load(f), sys.stdout)
" "$1"
}

read_domains() {
  # Read a .domains file, stripping comments and blank lines.
  local file="$1"
  [ -f "$file" ] || return 0
  grep -v '^\s*#' "$file" | grep -v '^\s*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

merge_domains() {
  # Merge base .domains + per-job .domains into a sorted, deduped list.
  local job_dir="$1"
  { read_domains "$BASE_DIR/.domains"; read_domains "$job_dir/.domains"; } | sort -u
}

generate_squid_conf() {
  # Generate a squid.conf from merged domain list. Writes to stdout.
  local job_dir="$1"
  local domains
  domains=$(merge_domains "$job_dir")

  cat <<'SQUID_HEAD'
# Auto-generated squid.conf — do not edit.
# Base domains from _base/.domains, per-job extras from .domains.

SQUID_HEAD

  # Write domain ACLs
  while IFS= read -r domain; do
    [ -n "$domain" ] && echo "acl allowed_domains dstdomain $domain"
  done <<< "$domains"

  cat <<'SQUID_TAIL'

# Standard port definitions
acl SSL_ports port 443
acl Safe_ports port 443

# Only allow CONNECT (HTTPS tunneling) to allowed domains on port 443
http_access allow CONNECT allowed_domains SSL_ports
http_access deny CONNECT

# Deny plain HTTP (all API traffic should be HTTPS)
http_access deny all

# Listen on port 3128
http_port 3128

# Logging
access_log daemon:/var/log/squid/access.log
cache_log /var/log/squid/cache.log

# No caching — we're just filtering, not caching
cache deny all

# Suppress version string in headers
httpd_suppress_version_string on

# Timeouts
connect_timeout 30 seconds
read_timeout 120 seconds
SQUID_TAIL
}

ensure_base_image() {
  if ! docker image inspect "$BASE_IMAGE" &>/dev/null; then
    log "Building base image ($BASE_IMAGE)..."
    docker build -t "$BASE_IMAGE" "$BASE_DIR"
  fi
}

# ============================================================
# GENERATE DOCKER COMPOSE
# ============================================================

generate_compose() {
  local job_name="$1"
  local job_dir="$2"
  local config_json="$3"
  local quarantine_dir="$4"
  local compose_file="$quarantine_dir/.docker-compose.yml"

  # Parse config fields
  local timeout
  timeout=$(echo "$config_json" | jq -r '.timeout // 600')
  local uses_claude
  uses_claude=$(echo "$config_json" | jq -r '.uses_claude // false')
  local mount_gws
  mount_gws=$(echo "$config_json" | jq -r '.mount_gws // false')
  local resource_memory
  resource_memory=$(echo "$config_json" | jq -r '.resources.memory // "512M"')
  local resource_cpus
  resource_cpus=$(echo "$config_json" | jq -r '.resources.cpus // "1.0"')

  # Generate squid config from .domains files
  local squid_conf="$quarantine_dir/.squid.conf"
  generate_squid_conf "$job_dir" > "$squid_conf"

  # Generate merged .domains file for guard hook inside container
  local merged_domains="$quarantine_dir/.domains"
  merge_domains "$job_dir" > "$merged_domains"

  # Determine build context / image
  local build_section
  local custom_dockerfile
  custom_dockerfile=$(echo "$config_json" | jq -r '.dockerfile // ""')
  if [ -n "$custom_dockerfile" ] && [ -f "$job_dir/$custom_dockerfile" ]; then
    build_section="    build:
      context: $job_dir
      dockerfile: $job_dir/$custom_dockerfile"
  else
    build_section="    image: $BASE_IMAGE"
  fi

  # Build environment lines
  local env_lines=""
  local env_names
  env_names=$(echo "$config_json" | jq -r '.env // [] | .[]')
  for var in $env_names; do
    env_lines="$env_lines
      - $var"
  done

  # Build volume lines from job.yaml volumes array
  local volume_lines=""
  local vol_count
  vol_count=$(echo "$config_json" | jq -r '.volumes // [] | length')
  for ((i=0; i<vol_count; i++)); do
    local host_path container_path
    host_path=$(echo "$config_json" | jq -r ".volumes[$i].host")
    container_path=$(echo "$config_json" | jq -r ".volumes[$i].container")

    # Expand placeholders and resolve relative paths
    host_path="${host_path//\$REPO/$REPO_DIR}"
    host_path="${host_path//\$HOME/$HOME}"
    if [[ "$host_path" == ./* ]]; then
      host_path="$job_dir/${host_path#./}"
    fi

    volume_lines="$volume_lines
      - $host_path:$container_path:ro"
  done

  # State file volumes
  local state_lines=""
  local state_files
  state_files=$(echo "$config_json" | jq -r '.state // [] | .[]')
  for sf in $state_files; do
    state_lines="$state_lines
      - $job_dir/$sf:/config/state/$sf:ro"
  done

  # GWS credentials mount
  local gws_line=""
  if [ "$mount_gws" = "true" ]; then
    gws_line="
      - $HOME/.config/gws:/secrets/gws:ro"
  fi

  # CLAUDE.md mount (if job has one)
  local claude_md_line=""
  if [ -f "$job_dir/CLAUDE.md" ]; then
    claude_md_line="
      - $job_dir/CLAUDE.md:/workspace/CLAUDE.md:ro"
  fi

  # Merged .domains mount (for guard hook curl allowlist)
  local domains_line=""
  if [ -f "$quarantine_dir/.domains" ]; then
    domains_line="
      - $quarantine_dir/.domains:/config/.domains:ro"
  fi

  # Org config mount (shared across all jobs)
  local org_line=""
  if [ -f "$JOBS_DIR/org.yaml" ]; then
    org_line="
      - $JOBS_DIR/org.yaml:/config/org.yaml:ro"
  fi

  # Write the compose file
  cat > "$compose_file" <<COMPOSE
services:
  proxy:
    image: ubuntu/squid:latest
    volumes:
      - $squid_conf:/etc/squid/squid.conf:ro
    networks:
      - job-net
    deploy:
      resources:
        limits:
          memory: 128M
          cpus: "0.25"

  job:
$build_section
    depends_on:
      - proxy
    environment:
      - TZ=America/New_York
      - DOTENV_CONFIG_QUIET=true
      - HTTP_PROXY=http://proxy:3128
      - HTTPS_PROXY=http://proxy:3128
      - http_proxy=http://proxy:3128
      - https_proxy=http://proxy:3128
      - NO_PROXY=localhost,127.0.0.1${env_lines}
    volumes:
      - $quarantine_dir:/workspace/quarantine${volume_lines}${state_lines}${gws_line}${claude_md_line}${domains_line}${org_line}
      - $job_dir/entrypoint.sh:/entrypoint.sh:ro
    dns:
      - 8.8.8.8
    networks:
      - job-net
    deploy:
      resources:
        limits:
          memory: $resource_memory
          cpus: "$resource_cpus"
    security_opt:
      - no-new-privileges:true
    read_only: false
    tmpfs:
      - /tmp:size=50M

networks:
  job-net:
    driver: bridge
COMPOSE

  echo "$compose_file"
}

# ============================================================
# RUN A SINGLE JOB
# ============================================================

run_job() {
  local job_name="$1"
  local job_dir="$JOBS_DIR/$job_name"
  local job_yaml="$job_dir/job.yaml"
  local quarantine_dir="$QUARANTINE_ROOT/$job_name"
  local log_file="$quarantine_dir/.job.log"

  [ -f "$job_yaml" ] || die "No job.yaml found at $job_yaml"
  [ -f "$job_dir/entrypoint.sh" ] || die "No entrypoint.sh found in $job_dir"

  log "=== Job: $job_name ==="

  # Parse job.yaml
  local config_json
  config_json=$(parse_yaml "$job_yaml")

  # Create per-job quarantine
  mkdir -p "$quarantine_dir"/{context,memory/people,memory/projects,state,.flagged}

  # Clean prior output
  rm -f "$quarantine_dir"/context/*.md
  rm -f "$quarantine_dir"/memory/people/*.md
  rm -f "$quarantine_dir"/memory/projects/*.md
  rm -f "$quarantine_dir"/state/*
  rm -f "$quarantine_dir"/.job.log "$quarantine_dir"/.validation.log

  # Ensure state files exist (Docker bind mount needs them)
  local state_files
  state_files=$(echo "$config_json" | jq -r '.state // [] | .[]')
  for sf in $state_files; do
    touch "$job_dir/$sf"
  done


  # Ensure base image exists
  ensure_base_image

  # Source .env for Docker environment variables
  set -a
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env" 2>/dev/null || true
  set +a

  # Generate docker-compose.yml
  local compose_file
  compose_file=$(generate_compose "$job_name" "$job_dir" "$config_json" "$quarantine_dir")

  # Get timeout
  local timeout
  timeout=$(echo "$config_json" | jq -r '.timeout // 600')

  # Run container
  log "Starting $job_name container..."
  local exit_code=0
  if timeout "$timeout" docker compose -f "$compose_file" run --rm job /entrypoint.sh >> "$log_file" 2>&1; then
    log "$job_name completed successfully."
  else
    exit_code=$?
    log "WARNING: $job_name container exited with code $exit_code."
    # Don't fail — still try to validate whatever output was produced
    if [ $exit_code -eq 124 ]; then
      log "Container timed out after ${timeout}s."
    fi
  fi

  # Validate quarantine output
  log "Validating $job_name output..."
  if "$RUNNER_DIR/validate-quarantine.sh" "$job_name"; then
    log "All files validated and promoted."
  else
    local val_exit=$?
    if [ $val_exit -eq 1 ]; then
      log "WARNING: Some files flagged for review. Check $quarantine_dir/.flagged/"
    else
      log "ERROR: Validation script failed."
    fi
  fi

  # Promote gws token cache (bypasses content validation — written by gws, not AI)
  if [ -f "$quarantine_dir/state/token_cache.json" ]; then
    cp "$quarantine_dir/state/token_cache.json" "$HOME/.config/gws/token_cache.json"
    log "Promoted refreshed gws token cache."
  fi

  log "=== Job $job_name complete ==="
  return $exit_code
}

# ============================================================
# LIST ALL JOBS
# ============================================================

list_jobs() {
  for dir in "$JOBS_DIR"/*/; do
    local name
    name=$(basename "$dir")
    [[ "$name" == _* ]] && continue
    [ -f "$dir/job.yaml" ] || continue
    echo "$name"
  done
}

# ============================================================
# INSTALL CRON ENTRIES
# ============================================================

install_cron() {
  log "Installing per-job crontab entries..."

  for job_name in $(list_jobs); do
    local job_yaml="$JOBS_DIR/$job_name/job.yaml"
    local config_json
    config_json=$(parse_yaml "$job_yaml")

    local schedule
    schedule=$(echo "$config_json" | jq -r '.schedule // ""')
    [ -z "$schedule" ] && continue

    local cron_tag="CLAUDE_TASK:job-$job_name"
    local cron_cmd="$schedule /bin/bash -l -c '$RUNNER_DIR/run-job.sh $job_name >> $HOME/.claude/scheduled-tasks/logs/job-$job_name.log 2>&1'  # $cron_tag|enabled|$(date -Iseconds)"

    # Remove existing entry for this job (if any)
    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null || true)
    local filtered
    filtered=$(echo "$current_crontab" | grep -v "$cron_tag" || true)

    # Add new entry
    mkdir -p "$HOME/.claude/scheduled-tasks/logs"
    echo "$filtered
$cron_cmd" | crontab -

    log "Installed cron for $job_name: $schedule"
  done

  log "Done. Current crontab:"
  crontab -l 2>/dev/null || true
}

# ============================================================
# BUILD BASE IMAGE
# ============================================================

build_base() {
  log "Building base image ($BASE_IMAGE)..."
  docker build -t "$BASE_IMAGE" "$BASE_DIR"
  log "Base image built."
}

# ============================================================
# MAIN DISPATCH
# ============================================================

ACTION="${1:-}"

case "$ACTION" in
  --install-cron)
    install_cron
    ;;
  --build-base)
    build_base
    ;;
  all)
    ANY_SUCCESS=false
    for job_name in $(list_jobs); do
      if run_job "$job_name"; then
        ANY_SUCCESS=true
      else
        log "Job $job_name failed — continuing with remaining jobs."
      fi
    done
    if ! $ANY_SUCCESS; then
      log "All jobs failed."
      exit 1
    fi
    ;;
  "")
    echo "Usage: run-job.sh <job-name|all|--install-cron|--build-base>"
    exit 1
    ;;
  *)
    run_job "$ACTION"
    ;;
esac

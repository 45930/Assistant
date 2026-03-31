#!/usr/bin/env bash
#
# crontab-manager.sh — manage Claude Code scheduled tasks in crontab
#
# Usage:
#   crontab-manager.sh list
#   crontab-manager.sh add <name> <cron-expr> <workdir> <prompt> [--allowedTools X] [--max-turns N] [--output-format F] [--dangerously-skip-permissions] [--description "..."]
#   crontab-manager.sh remove <name>
#   crontab-manager.sh enable <name>
#   crontab-manager.sh disable <name>
#   crontab-manager.sh run <name>
#   crontab-manager.sh logs <name> [lines]

set -euo pipefail

TASKS_DIR="$HOME/.claude/scheduled-tasks"
LOGS_DIR="$TASKS_DIR/logs"
TASKS_JSON="$TASKS_DIR/tasks.json"
MARKER="CLAUDE_TASK"

# Ensure directories exist
mkdir -p "$LOGS_DIR"

# Ensure tasks.json exists
if [[ ! -f "$TASKS_JSON" ]]; then
    echo '{"tasks":{}}' > "$TASKS_JSON"
fi

# --- Helpers ---

get_crontab() {
    crontab -l 2>/dev/null || true
}

# Extract all CLAUDE_TASK lines (enabled and disabled)
get_task_lines() {
    get_crontab | grep "$MARKER:" || true
}

# Find a specific task line by name
find_task_line() {
    local name="$1"
    get_crontab | grep "${MARKER}:${name}|" || true
}

# Check if a task name already exists
task_exists() {
    local name="$1"
    local line
    line=$(find_task_line "$name")
    [[ -n "$line" ]]
}

# Parse cron expression to human-readable (basic patterns)
cron_to_human() {
    local expr="$1"
    case "$expr" in
        "* * * * *")        echo "every minute" ;;
        "*/5 * * * *")      echo "every 5 minutes" ;;
        "*/10 * * * *")     echo "every 10 minutes" ;;
        "*/15 * * * *")     echo "every 15 minutes" ;;
        "*/30 * * * *")     echo "every 30 minutes" ;;
        "0 * * * *")        echo "every hour" ;;
        "0 */2 * * *")      echo "every 2 hours" ;;
        "0 */4 * * *")      echo "every 4 hours" ;;
        "0 */6 * * *")      echo "every 6 hours" ;;
        "0 */12 * * *")     echo "every 12 hours" ;;
        *)
            local min hour dom mon dow
            read -r min hour dom mon dow <<< "$expr"
            local result=""

            # Day of week
            case "$dow" in
                "*")   ;;
                "1-5") result="weekdays" ;;
                "0")   result="Sundays" ;;
                "1")   result="Mondays" ;;
                "2")   result="Tuesdays" ;;
                "3")   result="Wednesdays" ;;
                "4")   result="Thursdays" ;;
                "5")   result="Fridays" ;;
                "6")   result="Saturdays" ;;
                "0,6") result="weekends" ;;
                *)     result="dow=$dow" ;;
            esac

            # Day of month
            if [[ "$dom" != "*" ]]; then
                result="day $dom of the month"
            fi

            # Month
            if [[ "$mon" != "*" ]]; then
                result="${result:+$result, }month=$mon"
            fi

            # Time
            if [[ "$hour" != "*" && "$min" != "*" ]]; then
                # Convert to 12-hour format
                local h=$((10#$hour))
                local ampm="AM"
                local h12=$h
                if (( h >= 12 )); then ampm="PM"; fi
                if (( h > 12 )); then h12=$((h - 12)); fi
                if (( h == 0 )); then h12=12; fi
                local m=$((10#$min))
                if (( m == 0 )); then
                    result="${result:+$result at }${h12}:00 ${ampm}"
                else
                    result="${result:+$result at }${h12}:$(printf '%02d' $m) ${ampm}"
                fi
            elif [[ "$hour" == "*" && "$min" != "*" ]]; then
                result="${result:+$result, }minute $min of every hour"
            fi

            if [[ -z "$result" ]]; then
                echo "$expr"
            else
                echo "$result"
            fi
            ;;
    esac
}

# --- Commands ---

cmd_list() {
    local lines
    lines=$(get_task_lines)

    if [[ -z "$lines" ]]; then
        echo "No scheduled Claude tasks found."
        echo ""
        echo "Add one with: crontab-manager.sh add <name> <cron-expr> <workdir> <prompt>"
        return 0
    fi

    # Header
    printf "%-25s %-10s %-25s %-20s %s\n" "NAME" "STATUS" "SCHEDULE" "CREATED" "DESCRIPTION"
    printf "%-25s %-10s %-25s %-20s %s\n" "----" "------" "--------" "-------" "-----------"

    while IFS= read -r line; do
        # Extract metadata from comment
        local meta
        meta=$(echo "$line" | sed "s/.*${MARKER}://")
        local name status created
        name=$(echo "$meta" | cut -d'|' -f1)
        status=$(echo "$meta" | cut -d'|' -f2)
        created=$(echo "$meta" | cut -d'|' -f3)

        # Extract cron expression (first 5 fields of the non-commented line)
        local clean_line
        clean_line=$(echo "$line" | sed 's/^#~ *//')
        local cron_expr
        cron_expr=$(echo "$clean_line" | awk '{print $1, $2, $3, $4, $5}')
        local human
        human=$(cron_to_human "$cron_expr")

        # Get description from tasks.json
        local desc=""
        if command -v python3 &>/dev/null && [[ -f "$TASKS_JSON" ]]; then
            desc=$(python3 -c "
import json, sys
try:
    with open('$TASKS_JSON') as f:
        data = json.load(f)
    t = data.get('tasks', {}).get('$name', {})
    print(t.get('description', ''))
except:
    pass
" 2>/dev/null || true)
        fi

        printf "%-25s %-10s %-25s %-20s %s\n" "$name" "$status" "$human" "${created:0:10}" "$desc"
    done <<< "$lines"
}

cmd_add() {
    local name="$1"; shift
    local cron_expr="$1 $2 $3 $4 $5"; shift 5
    local workdir="$1"; shift
    local prompt="$1"; shift

    # Parse optional flags
    local allowed_tools="" max_turns="10" output_format="text" skip_permissions="" description=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --allowedTools)     allowed_tools="$2"; shift 2 ;;
            --max-turns)        max_turns="$2"; shift 2 ;;
            --output-format)    output_format="$2"; shift 2 ;;
            --dangerously-skip-permissions) skip_permissions="yes"; shift ;;
            --description)      description="$2"; shift 2 ;;
            *) echo "Unknown flag: $1"; exit 1 ;;
        esac
    done

    # Validate name uniqueness
    if task_exists "$name"; then
        echo "Error: task '$name' already exists. Remove it first or choose a different name."
        exit 1
    fi

    # Validate name format
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]] && [[ ! "$name" =~ ^[a-z0-9]$ ]]; then
        echo "Error: name must be lowercase alphanumeric with hyphens (e.g., 'daily-review')."
        exit 1
    fi

    local logfile="$LOGS_DIR/${name}.log"
    local created
    created=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build the claude command
    local claude_cmd="claude -p \"${prompt}\""
    [[ -n "$allowed_tools" ]] && claude_cmd+=" --allowedTools \"${allowed_tools}\""
    [[ -n "$max_turns" ]]     && claude_cmd+=" --max-turns ${max_turns}"
    [[ -n "$output_format" ]] && claude_cmd+=" --output-format ${output_format}"
    [[ -n "$skip_permissions" ]] && claude_cmd+=" --dangerously-skip-permissions"

    # Build full cron line
    local cron_line="${cron_expr} /bin/bash -l -c 'cd ${workdir} && ${claude_cmd} >> ${logfile} 2>&1'  # ${MARKER}:${name}|enabled|${created}"

    # Append to crontab
    (get_crontab; echo "$cron_line") | crontab -

    # Update tasks.json
    python3 -c "
import json
with open('$TASKS_JSON', 'r') as f:
    data = json.load(f)
data['tasks']['$name'] = {
    'name': '$name',
    'description': '''$description''',
    'prompt': '''$prompt''',
    'schedule': '$cron_expr',
    'schedule_human': '''$(cron_to_human "$cron_expr")''',
    'workdir': '$workdir',
    'flags': {
        'allowedTools': '$allowed_tools',
        'max-turns': '$max_turns',
        'output-format': '$output_format',
        'dangerously-skip-permissions': $([ -n "$skip_permissions" ] && echo 'True' || echo 'False')
    },
    'created': '$created',
    'status': 'enabled'
}
with open('$TASKS_JSON', 'w') as f:
    json.dump(data, f, indent=2)
"

    local human
    human=$(cron_to_human "$cron_expr")
    echo "Task '$name' added successfully."
    echo "  Schedule: $human ($cron_expr)"
    echo "  Workdir:  $workdir"
    echo "  Log file: $logfile"
    echo ""
    echo "The task will run via cron. Make sure:"
    echo "  - claude is in your PATH within a login shell"
    echo "  - Your ANTHROPIC_API_KEY is available in your shell profile"
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "  - On macOS: cron may need Full Disk Access (System Settings > Privacy)"
    fi
}

cmd_remove() {
    local name="$1"

    if ! task_exists "$name"; then
        echo "Error: no task named '$name' found."
        exit 1
    fi

    # Remove from crontab
    local tmp
    tmp=$(mktemp)
    get_crontab | grep -v "${MARKER}:${name}|" > "$tmp" || true
    crontab "$tmp"
    rm -f "$tmp"

    # Remove from tasks.json
    python3 -c "
import json
with open('$TASKS_JSON', 'r') as f:
    data = json.load(f)
data['tasks'].pop('$name', None)
with open('$TASKS_JSON', 'w') as f:
    json.dump(data, f, indent=2)
"

    echo "Task '$name' removed."
    echo "Log file preserved at: $LOGS_DIR/${name}.log"
}

cmd_enable() {
    local name="$1"

    if ! task_exists "$name"; then
        echo "Error: no task named '$name' found."
        exit 1
    fi

    # Remove #~ prefix and update status in comment
    local tmp
    tmp=$(mktemp)
    get_crontab | sed "/${MARKER}:${name}|/{ s/^#~ *//; s/|disabled|/|enabled|/; }" > "$tmp"
    crontab "$tmp"
    rm -f "$tmp"

    # Update tasks.json
    python3 -c "
import json
with open('$TASKS_JSON', 'r') as f:
    data = json.load(f)
if '$name' in data['tasks']:
    data['tasks']['$name']['status'] = 'enabled'
with open('$TASKS_JSON', 'w') as f:
    json.dump(data, f, indent=2)
"

    echo "Task '$name' enabled."
}

cmd_disable() {
    local name="$1"

    if ! task_exists "$name"; then
        echo "Error: no task named '$name' found."
        exit 1
    fi

    # Add #~ prefix and update status in comment
    local tmp
    tmp=$(mktemp)
    get_crontab | sed "/${MARKER}:${name}|/{ s/^/#~ /; s/|enabled|/|disabled|/; }" > "$tmp"
    crontab "$tmp"
    rm -f "$tmp"

    # Update tasks.json
    python3 -c "
import json
with open('$TASKS_JSON', 'r') as f:
    data = json.load(f)
if '$name' in data['tasks']:
    data['tasks']['$name']['status'] = 'disabled'
with open('$TASKS_JSON', 'w') as f:
    json.dump(data, f, indent=2)
"

    echo "Task '$name' disabled (cron entry commented out, not removed)."
}

cmd_run() {
    local name="$1"

    # Try to get the command from the crontab line
    local line
    line=$(find_task_line "$name")
    if [[ -z "$line" ]]; then
        echo "Error: no task named '$name' found."
        exit 1
    fi

    # Extract the bash -l -c '...' portion
    local clean_line
    clean_line=$(echo "$line" | sed 's/^#~ *//')

    # Extract command between the single quotes after bash -l -c
    local cmd
    cmd=$(echo "$clean_line" | sed "s/.*bash -l -c '\\(.*\\)'  # ${MARKER}.*/\\1/")

    echo "Running task '$name' now..."
    echo "Command: $cmd"
    echo "---"

    # Execute it (without redirecting to log — show output live)
    # Strip the log redirect from the command for interactive use
    local interactive_cmd
    interactive_cmd=$(echo "$cmd" | sed 's/ >> .* 2>&1$//')

    /bin/bash -l -c "$interactive_cmd"
}

cmd_logs() {
    local name="$1"
    local lines="${2:-50}"
    local logfile="$LOGS_DIR/${name}.log"

    if [[ ! -f "$logfile" ]]; then
        echo "No log file found for task '$name'."
        echo "Expected at: $logfile"
        echo "The task may not have run yet."
        return 1
    fi

    echo "=== Last $lines lines of $logfile ==="
    tail -n "$lines" "$logfile"
}

# --- Main dispatch ---

if [[ $# -lt 1 ]]; then
    echo "Usage: crontab-manager.sh <command> [args...]"
    echo "Commands: list, add, remove, enable, disable, run, logs"
    exit 1
fi

command="$1"; shift

case "$command" in
    list)    cmd_list ;;
    add)     cmd_add "$@" ;;
    remove)  cmd_remove "$@" ;;
    enable)  cmd_enable "$@" ;;
    disable) cmd_disable "$@" ;;
    run)     cmd_run "$@" ;;
    logs)    cmd_logs "$@" ;;
    *)
        echo "Unknown command: $command"
        echo "Commands: list, add, remove, enable, disable, run, logs"
        exit 1
        ;;
esac


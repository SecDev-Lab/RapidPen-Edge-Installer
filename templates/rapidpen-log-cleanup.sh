#!/bin/sh
# RapidPen Edge Log Cleanup Script
# Runs daily via systemd timer to manage log retention.
#
# Supervisor: copytruncate rotation + 7-day retention
#   - Copy current .jsonl to dated backup (e.g. supervisor-20260203.jsonl)
#   - Truncate original file to 0 bytes (safe with Python append mode)
#   - Delete dated backups older than RETENTION_DAYS
#
# Operator: 7-day retention
#   - Delete Run directories older than RETENTION_DAYS
set -e

LOG_BASE="/var/log/rapidpen"
RETENTION_DAYS=7
TODAY=$(date +%Y%m%d)

log_info() {
    logger -t rapidpen-log-cleanup "[INFO] $1"
}

log_warn() {
    logger -t rapidpen-log-cleanup "[WARN] $1"
}

# 1. Supervisor: copytruncate rotation
if [ -d "$LOG_BASE/supervisor" ]; then
    for jsonl in "$LOG_BASE"/supervisor/*.jsonl; do
        [ -f "$jsonl" ] || continue
        base=$(basename "$jsonl" .jsonl)
        dir=$(dirname "$jsonl")
        rotated="$dir/${base}-${TODAY}.jsonl"

        # Skip if already rotated today
        if [ -f "$rotated" ]; then
            log_info "Already rotated today: $rotated (skipping)"
            continue
        fi

        cp "$jsonl" "$rotated"
        truncate -s 0 "$jsonl"
        log_info "Rotated $jsonl -> $rotated"
    done

    # Delete old rotated files (matching *-YYYYMMDD.jsonl pattern)
    deleted=$(find "$LOG_BASE/supervisor" -name "*-[0-9]*.jsonl" -mtime +$RETENTION_DAYS -delete -print | wc -l)
    if [ "$deleted" -gt 0 ]; then
        log_info "Deleted $deleted old supervisor log file(s)"
    fi
else
    log_warn "Supervisor log directory not found: $LOG_BASE/supervisor"
fi

# 2. Operator: delete old Run directories
if [ -d "$LOG_BASE/operator" ]; then
    deleted=$(find "$LOG_BASE/operator" -mindepth 1 -maxdepth 1 -type d -mtime +$RETENTION_DAYS -exec rm -rf {} + -print | wc -l)
    if [ "$deleted" -gt 0 ]; then
        log_info "Deleted $deleted old operator Run directory(ies)"
    fi
else
    log_warn "Operator log directory not found: $LOG_BASE/operator"
fi

log_info "Log cleanup completed"

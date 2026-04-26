#!/bin/sh
# Observability and safety helpers for rainbow version generation CronJob
# Provides structured logging, error handling, and diagnostic utilities
#
# Usage:
#   source this script in other scripts to use the logging functions
#   . internal/demo/scripts/cron_helpers.sh
#
# Functions:
#   log_info MESSAGE          - Log info level message with timestamp
#   log_warn MESSAGE          - Log warning message
#   log_error MESSAGE         - Log error message
#   log_debug MESSAGE         - Log debug message (if DEBUG=1)
#   emit_metric NAME VALUE    - Emit structured metric for monitoring
#   acquire_lock LOCK_NAME    - Acquire distributed lock via ConfigMap (returns 1 if locked)
#   release_lock LOCK_NAME    - Release distributed lock
#   report_status STATE MSG   - Report job status to ConfigMap (success/failure/running)

set -eu

# Global configuration
export DEBUG="${DEBUG:-0}"
export TIMESTAMP_FORMAT="%Y-%m-%dT%H:%M:%SZ"
export LOCK_TIMEOUT=300  # 5 minutes
export LOCK_NAMESPACE="${LOCK_NAMESPACE:-default}"

# Color codes for log output (disabled if not TTY)
if [ -t 1 ]; then
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  GREEN='\033[0;32m'
  BLUE='\033[0;34m'
  NC='\033[0m'  # No Color
else
  RED=''
  YELLOW=''
  GREEN=''
  BLUE=''
  NC=''
fi

# ===== Logging Functions =====

log_info() {
  local msg="$1"
  local ts=$(date -u +"$TIMESTAMP_FORMAT")
  echo "[INFO] [$ts] $msg"
}

log_warn() {
  local msg="$1"
  local ts=$(date -u +"$TIMESTAMP_FORMAT")
  echo "[WARN] [$ts] ${YELLOW}$msg${NC}" >&2
}

log_error() {
  local msg="$1"
  local ts=$(date -u +"$TIMESTAMP_FORMAT")
  echo "[ERROR] [$ts] ${RED}$msg${NC}" >&2
}

log_debug() {
  if [ "$DEBUG" = "1" ]; then
    local msg="$1"
    local ts=$(date -u +"$TIMESTAMP_FORMAT")
    echo "[DEBUG] [$ts] ${BLUE}$msg${NC}"
  fi
}

# ===== Metrics and Diagnostics =====

emit_metric() {
  local name="$1"
  local value="$2"
  local unit="${3:-count}"
  local ts=$(date -u +"$TIMESTAMP_FORMAT")
  
  # JSON-formatted metric for easy parsing by monitoring systems
  echo "{\"metric\":\"$name\",\"value\":$value,\"unit\":\"$unit\",\"timestamp\":\"$ts\"}"
}

report_status() {
  local state="$1"
  local message="${2:-}"
  local job_id="${JOB_ID:-unknown}"
  local ts=$(date -u +"$TIMESTAMP_FORMAT")
  
  log_info "Status: $state ($message)"
  
  if ! command -v kubectl >/dev/null 2>&1; then
    log_warn "kubectl not available - cannot update ConfigMap status"
    return 0
  fi
  
  # Try to update status ConfigMap (non-fatal if fails)
  kubectl patch configmap rainbow-version-state \
    -n "$LOCK_NAMESPACE" \
    -p "{\"data\":{\"last_job_state\":\"$state\",\"last_job_message\":\"$message\",\"last_job_id\":\"$job_id\",\"last_job_time\":\"$ts\"}}" \
    --type merge 2>/dev/null || log_warn "Could not update status ConfigMap"
}

# ===== Distributed Locking (via ConfigMap) =====

acquire_lock() {
  local lock_name="$1"
  local lock_key="lock-$lock_name"
  local job_id="${JOB_ID:-$(date +%s)}"
  local ts=$(date -u +"$TIMESTAMP_FORMAT")
  
  if ! command -v kubectl >/dev/null 2>&1; then
    log_warn "kubectl not available - skipping lock acquisition"
    return 0
  fi
  
  log_debug "Attempting to acquire lock: $lock_name"
  
  # Check if lock exists and is not expired
  local lock_holder=$(kubectl get configmap rainbow-version-state -n "$LOCK_NAMESPACE" -o json 2>/dev/null | \
    jq -r ".data[\"$lock_key\"] // \"\"" 2>/dev/null || echo "")
  
  if [ -n "$lock_holder" ] && [ "$lock_holder" != "$job_id" ]; then
    # Lock exists and is held by different job
    log_warn "Lock $lock_name is held by $lock_holder"
    return 1
  fi
  
  # Try to acquire lock
  kubectl patch configmap rainbow-version-state \
    -n "$LOCK_NAMESPACE" \
    -p "{\"data\":{\"$lock_key\":\"$job_id-$ts\"}}" \
    --type merge 2>/dev/null || {
      log_error "Failed to acquire lock"
      return 1
    }
  
  log_debug "Lock acquired: $lock_name ($job_id)"
  return 0
}

release_lock() {
  local lock_name="$1"
  local lock_key="lock-$lock_name"
  
  if ! command -v kubectl >/dev/null 2>&1; then
    log_debug "kubectl not available - skipping lock release"
    return 0
  fi
  
  log_debug "Releasing lock: $lock_name"
  
  kubectl patch configmap rainbow-version-state \
    -n "$LOCK_NAMESPACE" \
    -p "{\"data\":{\"$lock_key\":\"\"}}" \
    --type merge 2>/dev/null || log_warn "Could not release lock"
}

# ===== Error Handling =====

trap_error() {
  local line_no="$1"
  local cmd="$2"
  
  log_error "Command failed at line $line_no: $cmd"
  report_status "failed" "error at line $line_no"
  
  # Attempt cleanup
  if [ -n "${LOCK_NAME:-}" ]; then
    release_lock "$LOCK_NAME" || true
  fi
  
  exit 1
}

# This helper is intended to be sourced by other scripts.

# ===== Diagnostic Functions =====

dump_diagnostics() {
  echo "=== Rainbow Version Generator Diagnostics ==="
  echo "Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "Job ID: ${JOB_ID:-unknown}"
  echo ""
  
  echo "=== Kubernetes Context ==="
  kubectl config current-context 2>/dev/null || echo "ERROR: Could not get context"
  kubectl cluster-info 2>/dev/null | head -5 || echo "ERROR: Could not get cluster info"
  echo ""
  
  echo "=== Version State ==="
  kubectl get configmap rainbow-version-state -n "$LOCK_NAMESPACE" -o yaml 2>/dev/null || echo "ERROR: Could not read version state"
  echo ""
  
  echo "=== Recent Version Generator Jobs ==="
  kubectl get jobs -l app=rainbow-version-generator -n "$LOCK_NAMESPACE" -o wide 2>/dev/null | head -10 || echo "ERROR: Could not list jobs"
  echo ""
  
  echo "=== TemporalWorkerDeployment Status ==="
  kubectl get temporalworkerdeployment helloworld -n "$LOCK_NAMESPACE" -o json 2>/dev/null | jq '.status | keys' || echo "ERROR: Could not get TWD status"
  echo ""
}

# ===== Main execution marker =====
# If executed directly, print a minimal usage hint.
case "${0##*/}" in
  cron_helpers.sh)
    echo "Helper functions for rainbow version generator observability. Source this file from other scripts." >&2
    ;;
esac

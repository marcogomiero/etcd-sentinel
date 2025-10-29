#!/usr/bin/env bash
# ==============================================================================
#  etcd-sentinel.sh
# ------------------------------------------------------------------------------
#  Lightweight remote ETCD cluster health monitor with Splunk/HEC integration.
#
#  Author: Marco Gomiero
#  License: MIT
#
#  Description:
#    - Connects via SSH to a remote ETCD manager node.
#    - Executes `etcdctl --cluster=true endpoint status -w json`.
#    - Calculates average and max DB size.
#    - Compares against environment-based thresholds.
#    - Optionally sends JSON results to a Splunk HEC endpoint.
#
#  Usage:
#    ./etcd-sentinel.sh --target <remote_host> [--env <ENV>] [--splunk-url <URL>] \
#                       [--splunk-token <TOKEN>] [--index <INDEX>] [--warn <GB>] [--crit <GB>]
#
#  Example:
#    ./etcd-sentinel.sh --target node1.example.net --env PROD \
#      --splunk-url "https://splunk.local/services/collector/event" \
#      --splunk-token "abcd1234" --index "cluster-logs"
#
#  Requirements:
#    - bash >= 4.0
#    - jq installed locally
#    - SSH access to target with permissions to run docker exec on etcd container
# ==============================================================================

set -euo pipefail
PATH=/usr/local/bin:/usr/bin:/bin

# ------------------------------------------------------------------------------
# Default configuration
# ------------------------------------------------------------------------------
SPLUNK_ENABLED=true
SPLUNK_URL="${SPLUNK_URL:-}"
SPLUNK_TOKEN="${SPLUNK_TOKEN:-}"
SPLUNK_INDEX="${SPLUNK_INDEX:-cluster-logs}"
SPLUNK_SOURCE="${SPLUNK_SOURCE:-etcd-sentinel}"
SPLUNK_SOURCETYPE="${SPLUNK_SOURCETYPE:-etcd-sentinel-json}"

SERVICE_NAME="etcd_sentinel"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------
TARGET_HOST=""
ENVIRONMENT=""
THRESHOLD_WARN_GB=""
THRESHOLD_CRIT_GB=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET_HOST="$2"; shift 2 ;;
    --env) ENVIRONMENT="$2"; shift 2 ;;
    --splunk-url) SPLUNK_URL="$2"; shift 2 ;;
    --splunk-token) SPLUNK_TOKEN="$2"; shift 2 ;;
    --index) SPLUNK_INDEX="$2"; shift 2 ;;
    --warn) THRESHOLD_WARN_GB="$2"; shift 2 ;;
    --crit) THRESHOLD_CRIT_GB="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$TARGET_HOST" ]]; then
  echo "Usage: $0 --target <remote_host> [--env <ENV>] ..."
  exit 1
fi

# ------------------------------------------------------------------------------
# Environment-specific thresholds (if not passed as args)
# ------------------------------------------------------------------------------
if [[ -z "$THRESHOLD_WARN_GB" || -z "$THRESHOLD_CRIT_GB" ]]; then
  if [[ "$ENVIRONMENT" == "NOPROD" ]]; then
      THRESHOLD_WARN_GB=3
      THRESHOLD_CRIT_GB=4
  else
      ENVIRONMENT="PROD"
      THRESHOLD_WARN_GB=1.5
      THRESHOLD_CRIT_GB=2
  fi
fi

THRESHOLD_WARN=$(awk "BEGIN {printf \"%d\", ${THRESHOLD_WARN_GB} * 1024 * 1024 * 1024}")
THRESHOLD_CRIT=$(awk "BEGIN {printf \"%d\", ${THRESHOLD_CRIT_GB} * 1024 * 1024 * 1024}")

# ------------------------------------------------------------------------------
# Remote ETCD query
# ------------------------------------------------------------------------------
echo "===> Checking ETCD status @ ${TARGET_HOST} (${ENVIRONMENT})"
STATUS_JSON=$(ssh ${SSH_OPTS} root@"${TARGET_HOST}" \
  "docker exec -e ETCDCTL_API=3 \$(docker ps -q -f name=ucp-kv) etcdctl --cluster=true endpoint status -w json 2>/dev/null") || {
  echo "❌ Failed to retrieve etcd status from ${TARGET_HOST}"
  exit 2
}

if [[ -z "$STATUS_JSON" ]]; then
  echo "❌ Empty response from ${TARGET_HOST}"
  exit 2
fi

# ------------------------------------------------------------------------------
# Parse JSON and compute metrics
# ------------------------------------------------------------------------------
AVG_BYTES=$(echo "$STATUS_JSON" | jq '[.[].Status.dbSize] | add/length')
MAX_BYTES=$(echo "$STATUS_JSON" | jq '[.[].Status.dbSize] | max')
RAW_LEADER=$(echo "$STATUS_JSON" | jq '.[0].Status.leader')
LEADER_EP=$(echo "$STATUS_JSON" | jq -r --argjson lid "$RAW_LEADER" \
  '.[] | select(.Status.header.member_id == $lid) | .Endpoint')

LEADER_IP=$(echo "$LEADER_EP" | sed -E 's#https://([^:]+):.*#\1#')
LEADER_HOST=$(getent hosts "$LEADER_IP" | awk '{print $2}' | head -n 1 || true)

# ------------------------------------------------------------------------------
# Threshold check
# ------------------------------------------------------------------------------
PERCENT=$(awk "BEGIN {printf \"%d\", (${MAX_BYTES} / ${THRESHOLD_CRIT}) * 100}")
STATUS_LEVEL="OK"
STATUS_MSG="OK: ETCD DB size within safe limits (${PERCENT}% of ${THRESHOLD_CRIT_GB} GB)"
EXIT_CODE=0

if (( MAX_BYTES >= THRESHOLD_CRIT )); then
    STATUS_LEVEL="CRITICAL"
    STATUS_MSG="CRITICAL: ETCD DB size exceeds ${THRESHOLD_CRIT_GB} GB (${PERCENT}%)"
    EXIT_CODE=2
elif (( MAX_BYTES >= THRESHOLD_WARN )); then
    STATUS_LEVEL="WARNING"
    STATUS_MSG="WARNING: ETCD DB size approaching limit (${PERCENT}% of ${THRESHOLD_CRIT_GB} GB)"
    EXIT_CODE=1
fi

# ------------------------------------------------------------------------------
# Human-readable conversion
# ------------------------------------------------------------------------------
human_readable() {
  local bytes=$1
  if (( bytes < 1024 )); then echo "${bytes} B"
  elif (( bytes < 1048576 )); then awk "BEGIN {printf \"%.2f KB\", $bytes/1024}"
  elif (( bytes < 1073741824 )); then awk "BEGIN {printf \"%.2f MB\", $bytes/1024/1024}"
  else awk "BEGIN {printf \"%.2f GB\", $bytes/1024/1024/1024}"
  fi
}

MAX_HR=$(human_readable "$MAX_BYTES")
AVG_HR=$(human_readable "$AVG_BYTES")

echo "-----------------------------------------------------------"
echo "Leader:        ${LEADER_HOST:-N/A}"
echo "Max DB size:   ${MAX_HR} (${PERCENT}%)"
echo "Status:        ${STATUS_LEVEL}"
echo "Message:       ${STATUS_MSG}"
echo "-----------------------------------------------------------"

# ------------------------------------------------------------------------------
# Splunk HEC output (optional)
# ------------------------------------------------------------------------------
send_to_splunk() {
  local payload
  payload=$(jq -n \
    --arg time "$(date +%s)" \
    --arg host "$(hostname)" \
    --arg env "$ENVIRONMENT" \
    --arg manager "$TARGET_HOST" \
    --arg service "$SERVICE_NAME" \
    --arg status "$STATUS_LEVEL" \
    --arg message "$STATUS_MSG" \
    --arg leader "${LEADER_HOST:-N/A}" \
    --argjson avg "$AVG_BYTES" \
    --argjson max "$MAX_BYTES" \
    --argjson percent "$PERCENT" \
    --argjson exit_code "$EXIT_CODE" \
    --arg index "$SPLUNK_INDEX" \
    --arg source "$SPLUNK_SOURCE" \
    --arg sourcetype "$SPLUNK_SOURCETYPE" \
    '{event:{
        time:$time,
        host:$host,
        environment:$env,
        manager:$manager,
        service:$service,
        status:$status,
        message:$message,
        leader:$leader,
        avg_db_size_bytes:$avg,
        max_db_size_bytes:$max,
        usage_percent:$percent,
        exit_code:$exit_code
      },
      index:$index, source:$source, sourcetype:$sourcetype}')

  if [[ -n "$SPLUNK_URL" && -n "$SPLUNK_TOKEN" ]]; then
    curl -s -X POST "$SPLUNK_URL" \
      -H "Authorization: Splunk ${SPLUNK_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$payload" >/dev/null 2>&1 || echo "⚠️ Failed to send data to Splunk"
  fi
}

if [[ "$SPLUNK_ENABLED" == true ]]; then
  send_to_splunk
fi

echo "ETCD sentinel check completed (exit code: $EXIT_CODE)"
exit $EXIT_CODE
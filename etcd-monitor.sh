#!/usr/bin/env bash
# ==============================================================================
#  etcd-monitor.sh
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

VERSION="1.1.0"
SERVICE_NAME="etcd_monitor"

# =============================
# Default configuration
# =============================
SPLUNK_ENABLED=false
OUTPUT_MODE="human"
THRESHOLD_WARN_GB=1.5
THRESHOLD_CRIT_GB=2

# =============================
# Parse CLI arguments
# =============================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --env) ENVIRONMENT="$2"; shift 2 ;;
    --splunk-url) SPLUNK_HEC_URL="$2"; SPLUNK_ENABLED=true; shift 2 ;;
    --splunk-token) SPLUNK_TOKEN="$2"; shift 2 ;;
    --index) SPLUNK_INDEX="$2"; shift 2 ;;
    --warn) THRESHOLD_WARN_GB="$2"; shift 2 ;;
    --crit) THRESHOLD_CRIT_GB="$2"; shift 2 ;;
    --json) OUTPUT_MODE="json"; shift ;;
    --version) echo "etcd-sentinel ${VERSION}"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "${TARGET:-}" ]]; then
  echo "Usage: $0 --target <hostname> [--env PROD|NOPROD] [--json] [--splunk-url ...]"
  exit 1
fi

# =============================
# Thresholds conversion
# =============================
THRESHOLD_WARN=$(awk "BEGIN {printf \"%d\", ${THRESHOLD_WARN_GB} * 1024 * 1024 * 1024}")
THRESHOLD_CRIT=$(awk "BEGIN {printf \"%d\", ${THRESHOLD_CRIT_GB} * 1024 * 1024 * 1024}")

# =============================
# Fetch status remotely
# =============================
STATUS_JSON=$(ssh -o StrictHostKeyChecking=no root@"$TARGET" \
  "docker exec -e ETCDCTL_API=3 \$(docker ps -q -f name=ucp-kv) etcdctl --cluster=true endpoint status -w json" 2>/dev/null)

AVG_BYTES=$(echo "$STATUS_JSON" | jq '[.[].Status.dbSize] | add/length')
MAX_BYTES=$(echo "$STATUS_JSON" | jq '[.[].Status.dbSize] | max')
RAW_LEADER=$(echo "$STATUS_JSON" | jq '.[0].Status.leader')
LEADER_EP=$(echo "$STATUS_JSON" | jq -r --argjson lid "$RAW_LEADER" '.[] | select(.Status.header.member_id == $lid) | .Endpoint')
LEADER_IP=$(echo "$LEADER_EP" | sed -E 's#https://([^:]+):.*#\1#')

LEADER_HOST=$(getent hosts "$LEADER_IP" | awk '{print $2}' | head -n 1 || echo "$LEADER_IP")

PERCENT=$(awk "BEGIN {printf \"%d\", (${MAX_BYTES} / ${THRESHOLD_CRIT}) * 100}")

if (( MAX_BYTES >= THRESHOLD_CRIT )); then
  STATUS_LEVEL="CRITICAL"
  STATUS_MSG="ETCD DB size exceeds ${THRESHOLD_CRIT_GB} GB (${PERCENT}%)"
  EXIT_CODE=2
elif (( MAX_BYTES >= THRESHOLD_WARN )); then
  STATUS_LEVEL="WARNING"
  STATUS_MSG="ETCD DB size approaching limit (${PERCENT}% of ${THRESHOLD_CRIT_GB} GB)"
  EXIT_CODE=1
else
  STATUS_LEVEL="OK"
  STATUS_MSG="ETCD DB size within safe limits (${PERCENT}% of ${THRESHOLD_CRIT_GB} GB)"
  EXIT_CODE=0
fi

# =============================
# Output functions
# =============================
print_status() {
  if [[ "$OUTPUT_MODE" == "json" ]]; then
    jq -n \
      --arg version "$VERSION" \
      --arg host "$TARGET" \
      --arg env "${ENVIRONMENT:-UNKNOWN}" \
      --arg leader "$LEADER_HOST" \
      --arg status "$STATUS_LEVEL" \
      --arg message "$STATUS_MSG" \
      --argjson avg "$AVG_BYTES" \
      --argjson max "$MAX_BYTES" \
      --argjson percent "$PERCENT" \
      --arg service "$SERVICE_NAME" \
      '{
        version:$version,
        environment:$env,
        host:$host,
        leader:$leader,
        service:$service,
        status:$status,
        message:$message,
        avg_db_size_bytes:$avg,
        max_db_size_bytes:$max,
        usage_percent:$percent
      }'
  else
    echo "===> ETCD Summary @ ${TARGET} (${ENVIRONMENT:-UNKNOWN})"
    echo "-----------------------------------------------------------"
    echo "Leader:             ${LEADER_HOST}"
    echo "Average DB size:    $(awk "BEGIN {printf \"%.2f GB\", ${AVG_BYTES}/1024/1024/1024}")"
    echo "Maximum DB size:    $(awk "BEGIN {printf \"%.2f GB\", ${MAX_BYTES}/1024/1024/1024}")"
    echo "Status:             ${STATUS_LEVEL}"
    echo "Message:            ${STATUS_MSG}"
    echo "-----------------------------------------------------------"
  fi
}

# =============================
# Send to Splunk (if enabled)
# =============================
send_to_splunk() {
  local payload
  payload=$(jq -n \
    --arg time "$(date +%s)" \
    --arg host "$TARGET" \
    --arg env "${ENVIRONMENT:-UNKNOWN}" \
    --arg service "$SERVICE_NAME" \
    --arg status "$STATUS_LEVEL" \
    --arg message "$STATUS_MSG" \
    --arg leader "$LEADER_HOST" \
    --argjson avg "$AVG_BYTES" \
    --argjson max "$MAX_BYTES" \
    --argjson percent "$PERCENT" \
    '{event:{
      time:$time,host:$host,environment:$env,service:$service,
      status:$status,message:$message,leader:$leader,
      avg_db_size_bytes:$avg,max_db_size_bytes:$max,
      usage_percent:$percent
    }}')

  curl -s -X POST "$SPLUNK_HEC_URL" \
    -H "Authorization: Splunk ${SPLUNK_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null 2>&1 || echo "⚠️ Failed to send event to Splunk"
}

# =============================
# Run
# =============================
print_status
[[ "$SPLUNK_ENABLED" == true ]] && send_to_splunk
exit ${EXIT_CODE:-0}
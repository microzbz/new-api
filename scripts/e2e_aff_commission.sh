#!/usr/bin/env bash

set -euo pipefail

MYSQL_BIN="${MYSQL_BIN:-/usr/local/mysql/bin/mysql}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_NAME="${DB_NAME:-new_api}"
GLOBAL_COMMISSION_PERCENT="${GLOBAL_COMMISSION_PERCENT:-1}"
CUSTOM_COMMISSION_PERCENT="${CUSTOM_COMMISSION_PERCENT:-25}"
CONSUMED_QUOTA="${CONSUMED_QUOTA:-5000}"
SETTLE_WAIT_SECONDS="${SETTLE_WAIT_SECONDS:-90}"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d%H%M%S)_$RANDOM}"
INVITER_USERNAME="${INVITER_USERNAME:-ea${TIMESTAMP}}"
INVITEE_USERNAME="${INVITEE_USERNAME:-eb${TIMESTAMP}}"
REQUEST_ID="req_${TIMESTAMP}"

resolve_mysql_bin() {
  if [[ -x "${MYSQL_BIN}" ]]; then
    echo "${MYSQL_BIN}"
    return 0
  fi

  local discovered
  discovered="$(command -v mysql 2>/dev/null || true)"
  if [[ -n "${discovered}" ]]; then
    echo "${discovered}"
    return 0
  fi

  echo "mysql client not found. Set MYSQL_BIN or install mysql." >&2
  return 1
}

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "required command not found: ${cmd}" >&2
    exit 1
  fi
}

cleanup() {
  set +e

  if [[ -n "${ORIGINAL_GLOBAL_EXISTS:-}" ]]; then
    if [[ "${ORIGINAL_GLOBAL_EXISTS}" == "1" ]]; then
      mysql_exec "UPDATE options SET value='${ORIGINAL_GLOBAL_VALUE}' WHERE \`key\`='AffCommissionPercentage';" >/dev/null 2>&1
    else
      mysql_exec "DELETE FROM options WHERE \`key\`='AffCommissionPercentage';" >/dev/null 2>&1
    fi
  fi

  if [[ -n "${invitee_id:-}" && -n "${settle_date:-}" ]]; then
    mysql_exec "DELETE FROM aff_daily_commission_settlements WHERE invitee_id=${invitee_id} AND settle_date='${settle_date}';" >/dev/null 2>&1
  fi

  if [[ -n "${REQUEST_ID:-}" ]]; then
    mysql_exec "DELETE FROM logs WHERE request_id='${REQUEST_ID}';" >/dev/null 2>&1
  fi

  if [[ -n "${inviter_id:-}" && -n "${invitee_id:-}" && -n "${settle_date:-}" ]]; then
    mysql_exec "DELETE FROM logs WHERE user_id=${inviter_id} AND type=4 AND content LIKE '邀请用户日消耗返佣 %' AND content LIKE '%用户ID:${invitee_id}%' AND content LIKE '%结算日:${settle_date}%';" >/dev/null 2>&1
  fi

  if [[ -n "${invitee_id:-}" ]]; then
    mysql_exec "DELETE FROM users WHERE id=${invitee_id};" >/dev/null 2>&1
  fi

  if [[ -n "${inviter_id:-}" ]]; then
    mysql_exec "DELETE FROM users WHERE id=${inviter_id};" >/dev/null 2>&1
  fi
}

MYSQL_BIN="$(resolve_mysql_bin)"
require_command jq
trap cleanup EXIT

if ! [[ "${GLOBAL_COMMISSION_PERCENT}" =~ ^[0-9]+$ ]] || (( GLOBAL_COMMISSION_PERCENT < 0 || GLOBAL_COMMISSION_PERCENT > 100 )); then
  echo "GLOBAL_COMMISSION_PERCENT must be an integer between 0 and 100" >&2
  exit 1
fi

if ! [[ "${CUSTOM_COMMISSION_PERCENT}" =~ ^[0-9]+$ ]] || (( CUSTOM_COMMISSION_PERCENT < 0 || CUSTOM_COMMISSION_PERCENT > 100 )); then
  echo "CUSTOM_COMMISSION_PERCENT must be an integer between 0 and 100" >&2
  exit 1
fi

if ! [[ "${CONSUMED_QUOTA}" =~ ^[0-9]+$ ]] || (( CONSUMED_QUOTA <= 0 )); then
  echo "CONSUMED_QUOTA must be a positive integer" >&2
  exit 1
fi

mysql_exec() {
  MYSQL_PWD="${DB_PASSWORD}" "${MYSQL_BIN}" \
    -h "${DB_HOST}" \
    -P "${DB_PORT}" \
    -u "${DB_USER}" \
    -D "${DB_NAME}" \
    -N -B \
    -e "$1"
}

yesterday_date() {
  if date -d "yesterday" "+%F" >/dev/null 2>&1; then
    date -d "yesterday" "+%F"
  else
    date -v-1d "+%F"
  fi
}

yesterday_noon_ts() {
  local day
  day="$(yesterday_date)"
  if date -d "${day} 12:00:00" "+%s" >/dev/null 2>&1; then
    date -d "${day} 12:00:00" "+%s"
  else
    date -j -f "%F %T" "${day} 12:00:00" "+%s"
  fi
}

wait_for_settlement() {
  local invitee_id="$1"
  local settle_date="$2"
  local timeout="$3"
  local elapsed=0

  while (( elapsed < timeout )); do
    local count
    count="$(mysql_exec "SELECT COUNT(*) FROM aff_daily_commission_settlements WHERE invitee_id=${invitee_id} AND settle_date='${settle_date}';")"
    if [[ "${count}" == "1" ]]; then
      return 0
    fi
    sleep 2
    elapsed=$(( elapsed + 2 ))
  done

  return 1
}

echo "Ensuring global default commission percent is ${GLOBAL_COMMISSION_PERCENT}% ..."
ORIGINAL_GLOBAL_EXISTS="$(mysql_exec "SELECT COUNT(*) FROM options WHERE \`key\`='AffCommissionPercentage';")"
ORIGINAL_GLOBAL_VALUE="$(mysql_exec "SELECT value FROM options WHERE \`key\`='AffCommissionPercentage' LIMIT 1;")"
mysql_exec "INSERT INTO options(\`key\`, value) VALUES ('AffCommissionPercentage', '${GLOBAL_COMMISSION_PERCENT}') ON DUPLICATE KEY UPDATE value = VALUES(value);"

settle_date="$(yesterday_date)"
consume_ts="$(yesterday_noon_ts)"

echo "Creating inviter ${INVITER_USERNAME} and invitee ${INVITEE_USERNAME} ..."
mysql_exec "INSERT INTO users (username, password, display_name, role, status, quota, used_quota, request_count, \`group\`, aff_code, aff_count, aff_quota, aff_history, aff_commission_percent, inviter_id) VALUES ('${INVITER_USERNAME}', 'password123', '${INVITER_USERNAME}', 1, 1, 0, 0, 0, 'default', 'aff${TIMESTAMP}a', 0, 0, 0, ${CUSTOM_COMMISSION_PERCENT}, 0);"
inviter_id="$(mysql_exec "SELECT id FROM users WHERE username='${INVITER_USERNAME}' ORDER BY id DESC LIMIT 1;")"
mysql_exec "INSERT INTO users (username, password, display_name, role, status, quota, used_quota, request_count, \`group\`, aff_code, aff_count, aff_quota, aff_history, aff_commission_percent, inviter_id) VALUES ('${INVITEE_USERNAME}', 'password123', '${INVITEE_USERNAME}', 1, 1, 0, 0, 0, 'default', 'aff${TIMESTAMP}b', 0, 0, 0, -1, ${inviter_id});"
invitee_id="$(mysql_exec "SELECT id FROM users WHERE username='${INVITEE_USERNAME}' ORDER BY id DESC LIMIT 1;")"

inviter_before_quota="$(mysql_exec "SELECT quota FROM users WHERE id=${inviter_id};")"
inviter_before_history="$(mysql_exec "SELECT aff_history FROM users WHERE id=${inviter_id};")"

echo "Writing yesterday consume log for invitee ${invitee_id}, quota ${CONSUMED_QUOTA} ..."
mysql_exec "INSERT INTO logs (user_id, created_at, type, content, username, token_name, model_name, quota, prompt_tokens, completion_tokens, use_time, is_stream, channel_id, token_id, \`group\`, ip, request_id, other) VALUES (${invitee_id}, ${consume_ts}, 2, 'e2e daily commission consume log', '${INVITEE_USERNAME}', '', 'gpt-4.1', ${CONSUMED_QUOTA}, 100, 50, 1, 0, 0, 0, 'default', '', '${REQUEST_ID}', '{}');"

echo "Waiting up to ${SETTLE_WAIT_SECONDS}s for daily settlement task to process ${settle_date} ..."
if ! wait_for_settlement "${invitee_id}" "${settle_date}" "${SETTLE_WAIT_SECONDS}"; then
  echo "Timed out waiting for daily commission settlement. Ensure the new-api service is running the latest build." >&2
  exit 1
fi

inviter_after_quota="$(mysql_exec "SELECT quota FROM users WHERE id=${inviter_id};")"
inviter_after_history="$(mysql_exec "SELECT aff_history FROM users WHERE id=${inviter_id};")"
settlement_row="$(mysql_exec "SELECT inviter_id, consumed_quota, commission_percent, commission_quota FROM aff_daily_commission_settlements WHERE invitee_id=${invitee_id} AND settle_date='${settle_date}' LIMIT 1;")"

read -r settlement_inviter_id settlement_consumed_quota settlement_percent settlement_commission_quota <<<"${settlement_row}"

expected_commission=$(( CONSUMED_QUOTA * CUSTOM_COMMISSION_PERCENT / 100 ))
inviter_delta_quota=$(( inviter_after_quota - inviter_before_quota ))
inviter_delta_history=$(( inviter_after_history - inviter_before_history ))

if (( settlement_inviter_id != inviter_id )); then
  echo "Settlement inviter mismatch: expected ${inviter_id}, got ${settlement_inviter_id}" >&2
  exit 1
fi
if (( settlement_consumed_quota != CONSUMED_QUOTA )); then
  echo "Settlement consumed quota mismatch: expected ${CONSUMED_QUOTA}, got ${settlement_consumed_quota}" >&2
  exit 1
fi
if (( settlement_percent != CUSTOM_COMMISSION_PERCENT )); then
  echo "Settlement percent mismatch: expected ${CUSTOM_COMMISSION_PERCENT}, got ${settlement_percent}" >&2
  exit 1
fi
if (( settlement_commission_quota != expected_commission )); then
  echo "Settlement commission mismatch: expected ${expected_commission}, got ${settlement_commission_quota}" >&2
  exit 1
fi
if (( inviter_delta_quota != expected_commission )); then
  echo "Inviter quota delta mismatch: expected ${expected_commission}, got ${inviter_delta_quota}" >&2
  exit 1
fi
if (( inviter_delta_history != expected_commission )); then
  echo "Inviter aff_history delta mismatch: expected ${expected_commission}, got ${inviter_delta_history}" >&2
  exit 1
fi

echo
echo "E2E aff daily commission validation passed."
jq -n \
  --arg settle_date "${settle_date}" \
  --arg inviter_username "${INVITER_USERNAME}" \
  --arg invitee_username "${INVITEE_USERNAME}" \
  --argjson inviter_id "${inviter_id}" \
  --argjson invitee_id "${invitee_id}" \
  --argjson global_commission_percent "${GLOBAL_COMMISSION_PERCENT}" \
  --argjson custom_commission_percent "${CUSTOM_COMMISSION_PERCENT}" \
  --argjson consumed_quota "${CONSUMED_QUOTA}" \
  --argjson expected_commission "${expected_commission}" \
  --argjson inviter_quota_delta "${inviter_delta_quota}" \
  --argjson inviter_aff_history_delta "${inviter_delta_history}" \
  '{
    settle_date: $settle_date,
    inviter: {
      id: $inviter_id,
      username: $inviter_username
    },
    invitee: {
      id: $invitee_id,
      username: $invitee_username
    },
    global_commission_percent: $global_commission_percent,
    custom_commission_percent: $custom_commission_percent,
    consumed_quota: $consumed_quota,
    expected_commission: $expected_commission,
    inviter_quota_delta: $inviter_quota_delta,
    inviter_aff_history_delta: $inviter_aff_history_delta
  }'

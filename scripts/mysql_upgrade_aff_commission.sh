#!/usr/bin/env bash

set -euo pipefail

MYSQL_BIN="${MYSQL_BIN:-/usr/local/mysql/bin/mysql}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_NAME="${DB_NAME:-new_api}"

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

MYSQL_BIN="$(resolve_mysql_bin)"

mysql_exec() {
  MYSQL_PWD="${DB_PASSWORD}" "${MYSQL_BIN}" \
    -h "${DB_HOST}" \
    -P "${DB_PORT}" \
    -u "${DB_USER}" \
    -D "${DB_NAME}" \
    -N -B \
    -e "$1"
}

echo "Checking users.aff_commission_percent ..."
column_exists="$(mysql_exec "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='users' AND COLUMN_NAME='aff_commission_percent';")"

if [[ "${column_exists}" == "0" ]]; then
  echo "Adding users.aff_commission_percent ..."
  mysql_exec "ALTER TABLE users ADD COLUMN aff_commission_percent BIGINT NULL DEFAULT -1;"
else
  echo "Column already exists, skipping add."
fi

echo "Backfilling NULL commission percentages to -1 ..."
mysql_exec "UPDATE users SET aff_commission_percent = -1 WHERE aff_commission_percent IS NULL;"

echo "Settling legacy aff_quota into quota ..."
mysql_exec "UPDATE users SET quota = quota + aff_quota WHERE aff_quota > 0;"
mysql_exec "UPDATE users SET aff_quota = 0 WHERE aff_quota > 0;"

echo "Ensuring option row AffCommissionPercentage exists ..."
mysql_exec "INSERT INTO options(\`key\`, value) VALUES ('AffCommissionPercentage', '1') ON DUPLICATE KEY UPDATE value = value;"

echo "Ensuring aff_daily_commission_settlements table exists ..."
mysql_exec "
CREATE TABLE IF NOT EXISTS aff_daily_commission_settlements (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  invitee_id BIGINT NOT NULL,
  inviter_id BIGINT NOT NULL DEFAULT 0,
  settle_date VARCHAR(10) NOT NULL,
  start_timestamp BIGINT NOT NULL,
  end_timestamp BIGINT NOT NULL,
  consumed_quota BIGINT NOT NULL DEFAULT 0,
  commission_percent BIGINT NOT NULL DEFAULT 0,
  commission_quota BIGINT NOT NULL DEFAULT 0,
  created_at BIGINT NOT NULL,
  UNIQUE KEY idx_aff_daily_invitee_date (invitee_id, settle_date),
  KEY idx_aff_daily_commission_settlements_inviter_id (inviter_id),
  KEY idx_aff_daily_commission_settlements_created_at (created_at)
);"

echo "Upgrade complete."
mysql_exec "SHOW COLUMNS FROM users LIKE 'aff_commission_percent'; SELECT \`key\`, value FROM options WHERE \`key\` = 'AffCommissionPercentage'; SELECT COUNT(*) AS pending_aff_quota_users FROM users WHERE aff_quota > 0; SHOW TABLES LIKE 'aff_daily_commission_settlements';"

#!/usr/bin/env bash
set -euo pipefail

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_DIR="${1:-$PWD}"
WORK_DIR="$(mktemp -d)"
BACKUP_ROOT="${WORK_DIR}/firephenix-backup"

DB_NAME="${DB_NAME:-firephenix}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-}"
TS3_DIR="${TS3_DIR:-/home/ts3server/serverfiles}"
TS3_ENABLED="${TS3_ENABLED:-true}"
STACK_ENV_FILE="${STACK_ENV_FILE:-}"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

mkdir -p "${BACKUP_ROOT}/mariadb" "${BACKUP_ROOT}/teamspeak" "${BACKUP_ROOT}/metadata"

if [[ -z "${DB_PASSWORD}" ]]; then
  read -r -s -p "MariaDB password for ${DB_USER}: " DB_PASSWORD
  echo
fi

echo "Creating MariaDB backup..."
mysqldump \
  -u "${DB_USER}" \
  -p"${DB_PASSWORD}" \
  --single-transaction \
  --routines \
  --triggers \
  "${DB_NAME}" > "${BACKUP_ROOT}/mariadb/${DB_NAME}.sql"

if [[ "${TS3_ENABLED}" == "true" && -d "${TS3_DIR}" ]]; then
  echo "Archiving TeamSpeak directory from ${TS3_DIR}..."
  tar -C "${TS3_DIR}" -czf "${BACKUP_ROOT}/teamspeak/teamspeak-server.tar.gz" .
  TS3_INCLUDED="true"
else
  echo "Skipping TeamSpeak backup."
  TS3_INCLUDED="false"
fi

if [[ -n "${STACK_ENV_FILE}" && -f "${STACK_ENV_FILE}" ]]; then
  echo "Copying environment file metadata..."
  cp "${STACK_ENV_FILE}" "${BACKUP_ROOT}/metadata/stack.env.backup"
fi

{
  echo "timestamp=${TIMESTAMP}"
  echo "hostname=$(hostname -f 2>/dev/null || hostname)"
  echo "db_name=${DB_NAME}"
  echo "ts3_dir=${TS3_DIR}"
  echo "ts3_included=${TS3_INCLUDED}"
  echo "kernel=$(uname -r)"
} > "${BACKUP_ROOT}/metadata/manifest.env"

ARCHIVE_PATH="${OUTPUT_DIR%/}/firephenix-backup-${TIMESTAMP}.tar.gz"
tar -C "${WORK_DIR}" -czf "${ARCHIVE_PATH}" firephenix-backup

echo "Backup created at ${ARCHIVE_PATH}"

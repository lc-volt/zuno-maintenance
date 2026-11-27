#!/usr/bin/env bash
# Verifica o backup canônico mais recente sem restaurar dados e publica o
# resultado no endpoint dedicado da API. Segredos nunca aparecem em argumentos.
set -euo pipefail
umask 077

STATUS_SCRIPT="$(cd "$(dirname "$0")" && pwd)/report-backup-status.mjs"
STATUS_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STATUS_BACKUP_ID=""
STATUS_BACKUP_CREATED_AT=""
STATUS_STAGE="validation"
STATUS_REPORTED=false
WORK_DIR=""

fail() {
  echo "$1" >&2
  exit 1
}

report_status() {
  local outcome="$1"
  local error_code="${2:-}"
  [ "$STATUS_REPORTED" = false ] || return 0
  STATUS_REPORTED=true
  if [ -z "$STATUS_URL_VALUE" ] && [ -z "$STATUS_TOKEN_VALUE" ]; then
    return 0
  fi
  if [ -z "$STATUS_URL_VALUE" ] || [ -z "$STATUS_TOKEN_VALUE" ]; then
    echo "Backup status reporting is not configured completely." >&2
    return 0
  fi
  local finished_at duration_ms verified=false
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  duration_ms="$(( $(date -u +%s) - $(date -u -d "$STATUS_STARTED_AT" +%s) ))"
  [ "$outcome" != "success" ] || verified=true
  if ! BACKUP_STATUS_URL="$STATUS_URL_VALUE" \
    BACKUP_STATUS_TOKEN="$STATUS_TOKEN_VALUE" \
    BACKUP_STATUS_STARTED_AT="$STATUS_STARTED_AT" \
    BACKUP_STATUS_FINISHED_AT="$finished_at" \
    BACKUP_STATUS_DURATION_MS="$duration_ms" \
    BACKUP_STATUS_OUTCOME="$outcome" \
    BACKUP_STATUS_VERIFIED="$verified" \
    BACKUP_STATUS_BACKUP_ID="$STATUS_BACKUP_ID" \
    BACKUP_STATUS_BACKUP_CREATED_AT="$STATUS_BACKUP_CREATED_AT" \
    BACKUP_STATUS_ERROR_CODE="$error_code" \
    NODE_ENV=production \
    node "$STATUS_SCRIPT"; then
    echo "Backup verification status report failed; the verification exit code is unchanged." >&2
  fi
}

on_exit() {
  local code=$?
  trap - EXIT
  if [ "$code" -eq 0 ]; then
    report_status success
  else
    local error_code="verification_failed"
    case "$STATUS_STAGE" in
      validation) error_code="validation_failed" ;;
      checksum) error_code="checksum_failed" ;;
      stale) error_code="stale_backup" ;;
    esac
    report_status failure "$error_code"
  fi
  if [ -n "$WORK_DIR" ]; then
    rm -rf -- "$WORK_DIR"
  fi
  exit "$code"
}
trap on_exit EXIT

for tool in node aws gpg sha256sum pg_restore date mktemp; do
  command -v "$tool" >/dev/null || fail "Required backup verification tool is missing: $tool"
done
: "${BACKUP_S3_BUCKET:?Set BACKUP_S3_BUCKET}"
: "${BACKUP_S3_REGION:?Set BACKUP_S3_REGION}"
: "${BACKUP_S3_ACCESS_KEY_ID:?Set BACKUP_S3_ACCESS_KEY_ID}"
: "${BACKUP_S3_SECRET_ACCESS_KEY:?Set BACKUP_S3_SECRET_ACCESS_KEY}"
: "${BACKUP_ENCRYPTION_PASSPHRASE:?Set BACKUP_ENCRYPTION_PASSPHRASE}"

STATUS_URL_VALUE="${BACKUP_STATUS_URL:-}"
STATUS_TOKEN_VALUE="${BACKUP_STATUS_TOKEN:-}"
BACKUP_PASSPHRASE_VALUE="$BACKUP_ENCRYPTION_PASSPHRASE"
BACKUP_ACCESS_KEY_ID_VALUE="$BACKUP_S3_ACCESS_KEY_ID"
BACKUP_SECRET_ACCESS_KEY_VALUE="$BACKUP_S3_SECRET_ACCESS_KEY"
BACKUP_SESSION_TOKEN_VALUE="${BACKUP_S3_SESSION_TOKEN:-}"
unset BACKUP_STATUS_URL BACKUP_STATUS_TOKEN BACKUP_ENCRYPTION_PASSPHRASE \
  BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY BACKUP_S3_SESSION_TOKEN \
  BACKUP_DATABASE_URL RESTORE_DATABASE_URL \
  EVIDENCE_S3_ACCESS_KEY_ID EVIDENCE_S3_SECRET_ACCESS_KEY

prefix="${BACKUP_S3_PREFIX:-zuno}"
while [[ "$prefix" == */ ]]; do
  prefix="${prefix%/}"
done
[ -n "$prefix" ] || fail "BACKUP_S3_PREFIX must not be empty."
prefix="$prefix/"
case "$prefix" in
  /*|*\\*|*..*|*[[:cntrl:]]*) fail "BACKUP_S3_PREFIX must be a safe relative S3 prefix." ;;
esac

AWS_ARGS=(--region "$BACKUP_S3_REGION")
if [ -n "${BACKUP_S3_ENDPOINT_URL:-}" ]; then
  AWS_ARGS+=(--endpoint-url "$BACKUP_S3_ENDPOINT_URL")
fi

aws_backup() {
  AWS_ACCESS_KEY_ID="$BACKUP_ACCESS_KEY_ID_VALUE" \
  AWS_SECRET_ACCESS_KEY="$BACKUP_SECRET_ACCESS_KEY_VALUE" \
  AWS_SESSION_TOKEN="$BACKUP_SESSION_TOKEN_VALUE" \
  AWS_DEFAULT_REGION="$BACKUP_S3_REGION" \
    aws "${AWS_ARGS[@]}" "$@"
}

LIST_OUTPUT="$(aws_backup s3api list-objects-v2 \
  --bucket "$BACKUP_S3_BUCKET" \
  --prefix "$prefix" \
  --query "reverse(sort_by(Contents,&LastModified))[].[Key,LastModified]" \
  --output text)"

LATEST_KEY=""
LATEST_MODIFIED=""
while IFS=$'\t' read -r key modified_at; do
  backup_name="${key##*/}"
  if [[ "$key" == "$prefix"* && "$backup_name" =~ ^zuno_[0-9]{8}_[0-9]{6}_[0-9]+_[0-9]+\.sql\.dump\.gpg$ ]]; then
    LATEST_KEY="$key"
    LATEST_MODIFIED="$modified_at"
    break
  fi
done <<< "$LIST_OUTPUT"
[ -n "$LATEST_KEY" ] || fail "No canonical backup object found."

STATUS_BACKUP_ID="$(basename "$LATEST_KEY" .sql.dump.gpg)"
STATUS_BACKUP_CREATED_AT="$LATEST_MODIFIED"
latest_epoch="$(date -u -d "$LATEST_MODIFIED" +%s 2>/dev/null)" || fail "Latest backup timestamp is invalid."
now_epoch="$(date -u +%s)"
age_seconds=$((now_epoch - latest_epoch))
if (( age_seconds < -300 )); then
  STATUS_STAGE="validation"
  fail "Latest backup timestamp is more than five minutes in the future."
fi
if (( age_seconds > 86400 )); then
  STATUS_STAGE="stale"
  fail "Latest backup is older than 24 hours."
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zuno-backup-verify.XXXXXX")"
LOCAL_FILE="$WORK_DIR/$(basename "$LATEST_KEY")"
STATUS_STAGE="download"
aws_backup s3 cp "s3://$BACKUP_S3_BUCKET/$LATEST_KEY" "$LOCAL_FILE" --only-show-errors
aws_backup s3 cp "s3://$BACKUP_S3_BUCKET/$LATEST_KEY.sha256" "$LOCAL_FILE.sha256" --only-show-errors

STATUS_STAGE="checksum"
(cd "$WORK_DIR" && sha256sum -c "$(basename "$LOCAL_FILE").sha256" >/dev/null)

STATUS_STAGE="decrypt"
DECRYPTED_FILE="$LOCAL_FILE.dump"
printf '%s' "$BACKUP_PASSPHRASE_VALUE" | gpg \
  --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
  --decrypt --output "$DECRYPTED_FILE" "$LOCAL_FILE"

STATUS_STAGE="restore_check"
pg_restore --list "$DECRYPTED_FILE" >/dev/null

echo "Backup verification passed: $LATEST_KEY"

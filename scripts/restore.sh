#!/usr/bin/env bash
# Verify, decrypt and restore a ZUNO backup into an explicitly approved target.
# Usage: BACKUP_* RESTORE_DATABASE_URL=... RESTORE_CONFIRM=RESTORE ./scripts/restore.sh <local-file|s3://bucket/key>
set -euo pipefail
umask 077

fail() {
  echo "$1" >&2
  exit 1
}

validate_database_url() {
  local value="$1"
  case "$value" in
    postgresql://*|postgres://*) ;;
    *) fail "RESTORE_DATABASE_URL must be a PostgreSQL libpq URI." ;;
  esac
  [[ "$value" != *[[:space:]]* ]] || fail "RESTORE_DATABASE_URL must not contain unescaped whitespace."
}

validate_s3_endpoint() {
  local value="${1:-}"
  [ -n "$value" ] || return 0
  [[ "$value" =~ ^https?://[^[:space:]]+$ ]] || fail "The S3 endpoint must be an HTTP(S) URL."
  local authority="${value#*://}"
  authority="${authority%%/*}"
  [ -n "$authority" ] || fail "The S3 endpoint must include a host."
  [[ "$value" != *'?'* && "$value" != *'#'* ]] || fail "The S3 endpoint must not contain query parameters or fragments."
  [[ ! "$value" =~ ^https?://[^/]*@ ]] || fail "The S3 endpoint must not contain credentials."
  if [ "${NODE_ENV:-}" = "production" ]; then
    [[ "$value" == https://* ]] || fail "The S3 endpoint must use HTTPS in production."
  fi
}

SOURCE="${1:-}"
: "${RESTORE_DATABASE_URL:?RESTORE_DATABASE_URL is required}"
if [ "${RESTORE_CONFIRM:-}" != "RESTORE" ]; then
  fail "Set RESTORE_CONFIRM=RESTORE after reviewing the target database."
fi
: "${BACKUP_ENCRYPTION_PASSPHRASE:?BACKUP_ENCRYPTION_PASSPHRASE is required}"
validate_database_url "$RESTORE_DATABASE_URL"
validate_s3_endpoint "${BACKUP_S3_ENDPOINT_URL:-}"
[ "${#BACKUP_ENCRYPTION_PASSPHRASE}" -ge 24 ] || fail "BACKUP_ENCRYPTION_PASSPHRASE must have at least 24 characters."
if [ -n "${BACKUP_S3_ACCESS_KEY_ID:-}" ] && [ -z "${BACKUP_S3_SECRET_ACCESS_KEY:-}" ]; then
  fail "BACKUP_S3_ACCESS_KEY_ID and BACKUP_S3_SECRET_ACCESS_KEY must be provided together."
fi
if [ -z "${BACKUP_S3_ACCESS_KEY_ID:-}" ] && { [ -n "${BACKUP_S3_SECRET_ACCESS_KEY:-}" ] || [ -n "${BACKUP_S3_SESSION_TOKEN:-}" ]; }; then
  fail "BACKUP_S3_ACCESS_KEY_ID and BACKUP_S3_SECRET_ACCESS_KEY must be provided together."
fi

RESTORE_DB_URL="$RESTORE_DATABASE_URL"
RESTORE_PASSPHRASE="$BACKUP_ENCRYPTION_PASSPHRASE"
RESTORE_EXPECTED_CHECKSUM="${RESTORE_EXPECTED_SHA256:-}"
RESTORE_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID:-}"
RESTORE_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY:-}"
RESTORE_SESSION_TOKEN_VALUE="${BACKUP_S3_SESSION_TOKEN:-}"
unset RESTORE_DATABASE_URL BACKUP_DATABASE_URL BACKUP_ENCRYPTION_PASSPHRASE RESTORE_EXPECTED_SHA256 \
  BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY BACKUP_S3_SESSION_TOKEN \
  EVIDENCE_S3_ACCESS_KEY_ID EVIDENCE_S3_SECRET_ACCESS_KEY

for tool in node gpg sha256sum pg_restore psql; do
  command -v "$tool" >/dev/null || fail "Required restore tool is missing: $tool"
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT
export GNUPGHOME="$WORK_DIR/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

aws_restore() {
  if [ -n "$RESTORE_ACCESS_KEY_ID" ]; then
    AWS_ACCESS_KEY_ID="$RESTORE_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$RESTORE_SECRET_ACCESS_KEY" \
    AWS_SESSION_TOKEN="$RESTORE_SESSION_TOKEN_VALUE" \
    AWS_PAGER="" "${AWS_COMMAND[@]}" "$@"
  else
    AWS_PAGER="" "${AWS_COMMAND[@]}" "$@"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if command -v aws >/dev/null; then
  AWS_COMMAND=(aws)
else
  [ -f "$SCRIPT_DIR/s3-file-transfer.mjs" ] || fail "AWS CLI or the S3 SDK transfer helper is required."
  AWS_COMMAND=(node "$SCRIPT_DIR/s3-file-transfer.mjs")
fi

if [[ "$SOURCE" == s3://* ]]; then
  : "${BACKUP_S3_BUCKET:?BACKUP_S3_BUCKET is required for S3 restores}"
  : "${BACKUP_S3_REGION:?BACKUP_S3_REGION is required for S3 restores}"
  BUCKET="${SOURCE#s3://}"
  BUCKET="${BUCKET%%/*}"
  KEY="${SOURCE#s3://$BUCKET/}"
  [[ "$BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || fail "The backup S3 bucket name is invalid."
  [ "$BUCKET" = "$BACKUP_S3_BUCKET" ] || fail "The S3 source must use the configured BACKUP_S3_BUCKET."
  if [ -n "${EVIDENCE_S3_BUCKET:-}" ] && [ "$BUCKET" = "$EVIDENCE_S3_BUCKET" ]; then
    fail "BACKUP_S3_BUCKET must be separate from EVIDENCE_S3_BUCKET."
  fi
  [ -n "$KEY" ] || fail "The backup S3 object key is required."
  [[ "$KEY" != *[[:cntrl:]]* ]] || fail "The backup S3 object key must not contain control characters."
  OBJECT_NAME="${KEY##*/}"
  [[ "$OBJECT_NAME" =~ ^zuno_[0-9]{8}_[0-9]{6}_[0-9]+_[0-9]+\.sql\.dump\.gpg$ ]] || fail "The S3 source must be a canonical ZUNO backup artifact."
  RESTORE_PREFIX="${BACKUP_S3_PREFIX:-zuno/}"
  RESTORE_PREFIX="${RESTORE_PREFIX%/}"
  [ -n "$RESTORE_PREFIX" ] || fail "BACKUP_S3_PREFIX must not be empty."
  case "$RESTORE_PREFIX" in
    /*|*\\*|*..*|*[[:cntrl:]]*) fail "BACKUP_S3_PREFIX must be a safe relative S3 prefix." ;;
  esac
  [[ "$KEY" == "$RESTORE_PREFIX/"* ]] || fail "The S3 source is outside the configured BACKUP_S3_PREFIX."
  AWS_ARGS=(--region "$BACKUP_S3_REGION")
  if [ -n "${BACKUP_S3_ENDPOINT_URL:-}" ]; then
    AWS_ARGS+=(--endpoint-url "$BACKUP_S3_ENDPOINT_URL")
  fi
  ENCRYPTED_FILE="$WORK_DIR/$OBJECT_NAME"
  CHECKSUM_FILE="$ENCRYPTED_FILE.sha256"
  aws_restore "${AWS_ARGS[@]}" s3 cp "$SOURCE" "$ENCRYPTED_FILE" --only-show-errors
  aws_restore "${AWS_ARGS[@]}" s3 cp "$SOURCE.sha256" "$CHECKSUM_FILE" --only-show-errors
elif [ -f "$SOURCE" ]; then
  ENCRYPTED_FILE="$SOURCE"
  CHECKSUM_FILE="$SOURCE.sha256"
else
  fail "Backup file does not exist: $SOURCE"
fi

[ -f "$CHECKSUM_FILE" ] || fail "Checksum sidecar is missing; restore aborted."
CHECKSUM_LINE="$(sha256sum < "$ENCRYPTED_FILE")"
ACTUAL_CHECKSUM="${CHECKSUM_LINE%% *}"
if [ -n "$RESTORE_EXPECTED_CHECKSUM" ]; then
  RESTORE_EXPECTED_CHECKSUM="${RESTORE_EXPECTED_CHECKSUM,,}"
  [[ "$RESTORE_EXPECTED_CHECKSUM" =~ ^[0-9a-f]{64}$ ]] || fail "The approved expected checksum is malformed; restore aborted."
  [ "$ACTUAL_CHECKSUM" = "$RESTORE_EXPECTED_CHECKSUM" ] || fail "Backup does not match the approved expected checksum; restore aborted."
fi
EXPECTED_CHECKSUM="$(cut -d ' ' -f 1 "$CHECKSUM_FILE")"
EXPECTED_CHECKSUM="${EXPECTED_CHECKSUM,,}"
[[ "$EXPECTED_CHECKSUM" =~ ^[0-9a-f]{64}$ ]] || fail "Checksum sidecar is malformed; restore aborted."
if [ "$ACTUAL_CHECKSUM" != "$EXPECTED_CHECKSUM" ]; then
  fail "Backup checksum mismatch; restore aborted."
fi

DUMP_FILE="$WORK_DIR/restore.sql.dump"
printf '%s\n' "$RESTORE_PASSPHRASE" | gpg \
  --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
  --decrypt --output "$DUMP_FILE" -- "$ENCRYPTED_FILE"
pg_restore --list "$DUMP_FILE" >/dev/null

# A single transaction rolls back the entire restore on any conflict/error;
# --clean is deliberately absent so unrelated target objects are never deleted.
DATABASE_URI="$RESTORE_DB_URL" node "$(dirname "$0")/run-with-database-url.mjs" \
  pg_restore --no-password --exit-on-error --single-transaction --no-owner --no-privileges "$DUMP_FILE"

restore_psql() {
  DATABASE_URI="$RESTORE_DB_URL" node "$SCRIPT_DIR/run-with-database-url.mjs" \
    psql --no-password --tuples-only --no-align --field-separator=' ' --set=ON_ERROR_STOP=1 "$@"
}

# pg_dump qualifies objects and clears search_path inside the archive. Validate
# the restored table explicitly and ensure Prisma can resolve the same schema.
# Use an unpooled URI for Neon: its pooler rejects libpq startup options.
MIGRATION_TABLE_PRESENT="$(restore_psql \
  --command "SELECT to_regclass('public._prisma_migrations') IS NOT NULL;")"
if [ "$MIGRATION_TABLE_PRESENT" != "t" ]; then
  MIGRATION_TABLE_SCHEMAS="$(restore_psql \
    --command "SELECT coalesce(string_agg(nspname, ',' ORDER BY nspname), '') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname = '_prisma_migrations' AND c.relkind IN ('r', 'p');")"
  [ -z "$MIGRATION_TABLE_SCHEMAS" ] || \
    fail "Restored _prisma_migrations exists outside public (schema: $MIGRATION_TABLE_SCHEMAS); wrong schema refused."
  fail "Restored public._prisma_migrations table is absent; Prisma cannot initialize a non-empty database."
fi
MIGRATION_COLUMN_COUNT="$(restore_psql \
  --command "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '_prisma_migrations' AND column_name IN ('id', 'checksum', 'finished_at', 'migration_name', 'logs', 'rolled_back_at', 'started_at', 'applied_steps_count');")"
[ "$MIGRATION_COLUMN_COUNT" = "8" ] || \
  fail "Restored public._prisma_migrations has an incompatible schema."
MIGRATION_SCHEMA="$(restore_psql --command "SELECT current_schema();")"
[ "$MIGRATION_SCHEMA" = "public" ] || \
  fail "Restored Prisma search_path resolves to ${MIGRATION_SCHEMA:-empty}; set schema=public in RESTORE_DATABASE_URL."
MIGRATION_COUNTS="$(restore_psql \
  --command "SELECT count(*), count(*) FILTER (WHERE finished_at IS NOT NULL AND rolled_back_at IS NULL), count(*) FILTER (WHERE finished_at IS NULL), count(*) FILTER (WHERE rolled_back_at IS NOT NULL) FROM public._prisma_migrations;")"
read -r MIGRATION_TOTAL MIGRATION_ACTIVE MIGRATION_UNFINISHED MIGRATION_ROLLED_BACK <<< "$MIGRATION_COUNTS"
[[ "$MIGRATION_TOTAL" =~ ^[0-9]+$ && "$MIGRATION_ACTIVE" =~ ^[0-9]+$ && \
   "$MIGRATION_UNFINISHED" =~ ^[0-9]+$ && "$MIGRATION_ROLLED_BACK" =~ ^[0-9]+$ ]] || \
  fail "Restored Prisma migration history could not be validated."
[ "$MIGRATION_TOTAL" -gt 0 ] || fail "Restored public._prisma_migrations is empty; Prisma cannot deploy into a non-empty database."
[ "$MIGRATION_ACTIVE" -gt 0 ] || fail "Restored Prisma migration history has no applied migrations."
[ "$MIGRATION_UNFINISHED" -eq 0 ] || fail "Restored Prisma migration history has unfinished migrations."
echo "Prisma migration ledger: total=$MIGRATION_TOTAL active=$MIGRATION_ACTIVE unfinished=$MIGRATION_UNFINISHED rolledBack=$MIGRATION_ROLLED_BACK."

echo "Restore completed successfully."

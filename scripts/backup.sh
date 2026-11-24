#!/usr/bin/env bash
# Encrypted, checksummed PostgreSQL custom-format backup to a separate S3 bucket.
# Requires PostgreSQL client tools, Node.js, GnuPG and sha256sum. The AWS SDK
# fallback removes the AWS CLI dependency for S3-compatible providers such as Neon.
# Secrets never appear in arguments.
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
    *) fail "The database URL must be a PostgreSQL libpq URI." ;;
  esac
  [[ "$value" != *[[:space:]]* ]] || fail "The database URL must not contain unescaped whitespace."
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

validate_bucket() {
  local value="$1"
  [[ "$value" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || fail "The S3 bucket name is invalid."
}

: "${BACKUP_DATABASE_URL:?BACKUP_DATABASE_URL (libpq URI) is required}"
: "${BACKUP_ENCRYPTION_PASSPHRASE:?BACKUP_ENCRYPTION_PASSPHRASE is required}"
: "${BACKUP_S3_BUCKET:?BACKUP_S3_BUCKET is required}"
: "${BACKUP_S3_REGION:?BACKUP_S3_REGION is required}"

validate_database_url "$BACKUP_DATABASE_URL"
validate_bucket "$BACKUP_S3_BUCKET"
validate_s3_endpoint "${BACKUP_S3_ENDPOINT_URL:-}"
[ "${#BACKUP_ENCRYPTION_PASSPHRASE}" -ge 24 ] || fail "BACKUP_ENCRYPTION_PASSPHRASE must have at least 24 characters."
[ -n "${BACKUP_S3_REGION//[[:space:]]/}" ] || fail "BACKUP_S3_REGION must not be empty."
if [ -n "${EVIDENCE_S3_BUCKET:-}" ] && [ "$BACKUP_S3_BUCKET" = "$EVIDENCE_S3_BUCKET" ]; then
  fail "BACKUP_S3_BUCKET must be separate from EVIDENCE_S3_BUCKET."
fi
if [ -n "${BACKUP_S3_ACCESS_KEY_ID:-}" ] && [ "$BACKUP_S3_ACCESS_KEY_ID" = "${EVIDENCE_S3_ACCESS_KEY_ID:-}" ]; then
  fail "BACKUP_S3_ACCESS_KEY_ID must be separate from EVIDENCE_S3_ACCESS_KEY_ID."
fi
if [ -n "${BACKUP_S3_ACCESS_KEY_ID:-}" ] && [ -z "${BACKUP_S3_SECRET_ACCESS_KEY:-}" ]; then
  fail "BACKUP_S3_ACCESS_KEY_ID and BACKUP_S3_SECRET_ACCESS_KEY must be provided together."
fi
if [ -z "${BACKUP_S3_ACCESS_KEY_ID:-}" ] && { [ -n "${BACKUP_S3_SECRET_ACCESS_KEY:-}" ] || [ -n "${BACKUP_S3_SESSION_TOKEN:-}" ]; }; then
  fail "BACKUP_S3_ACCESS_KEY_ID and BACKUP_S3_SECRET_ACCESS_KEY must be provided together."
fi

RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || fail "BACKUP_RETENTION_DAYS must be an integer."
[ "$RETENTION_DAYS" -ge 1 ] && [ "$RETENTION_DAYS" -le 365 ] || fail "BACKUP_RETENTION_DAYS must be between 1 and 365."
BACKUP_S3_PREFIX="${BACKUP_S3_PREFIX:-zuno/}"
BACKUP_S3_PREFIX="${BACKUP_S3_PREFIX%/}"
[ -n "$BACKUP_S3_PREFIX" ] || fail "BACKUP_S3_PREFIX must not be empty."
case "$BACKUP_S3_PREFIX" in
  /*|*\\*|*..*|*[[:cntrl:]]*) fail "BACKUP_S3_PREFIX must be a safe relative S3 prefix." ;;
esac

# Keep database, passphrase and both evidence/backup credentials out of the
# environments inherited by unrelated child tools. AWS receives only its own
# command-scoped credentials in aws_backup below.
BACKUP_DB_URL="$BACKUP_DATABASE_URL"
BACKUP_PASSPHRASE="$BACKUP_ENCRYPTION_PASSPHRASE"
BACKUP_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID:-}"
BACKUP_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY:-}"
BACKUP_SESSION_TOKEN_VALUE="${BACKUP_S3_SESSION_TOKEN:-}"
unset BACKUP_DATABASE_URL RESTORE_DATABASE_URL BACKUP_ENCRYPTION_PASSPHRASE \
  BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY BACKUP_S3_SESSION_TOKEN \
  EVIDENCE_S3_ACCESS_KEY_ID EVIDENCE_S3_SECRET_ACCESS_KEY

for tool in node pg_dump psql gpg sha256sum; do
  command -v "$tool" >/dev/null || fail "Required backup tool is missing: $tool"
done
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Prefer an explicitly installed AWS CLI (also used by the isolated test
# fixtures); use the repository-pinned SDK helper when the CLI is unavailable.
if command -v aws >/dev/null; then
  AWS_COMMAND=(aws)
else
  [ -f "$SCRIPT_DIR/s3-file-transfer.mjs" ] || fail "AWS CLI or the S3 SDK transfer helper is required."
  AWS_COMMAND=(node "$SCRIPT_DIR/s3-file-transfer.mjs")
fi

# A custom-format dump preserves whatever is in the source, including an empty
# Prisma ledger. Refuse to publish a backup that cannot be deployed afterwards.
MIGRATION_TABLE_PRESENT="$(DATABASE_URI="$BACKUP_DB_URL" node "$SCRIPT_DIR/run-with-database-url.mjs" \
  psql --no-password --tuples-only --no-align --field-separator=' ' --set=ON_ERROR_STOP=1 \
  --command "SELECT to_regclass('public._prisma_migrations') IS NOT NULL;")"
if [ "$MIGRATION_TABLE_PRESENT" != "t" ]; then
  MIGRATION_TABLE_SCHEMAS="$(DATABASE_URI="$BACKUP_DB_URL" node "$SCRIPT_DIR/run-with-database-url.mjs" \
    psql --no-password --tuples-only --no-align --field-separator=' ' --set=ON_ERROR_STOP=1 \
    --command "SELECT coalesce(string_agg(nspname, ',' ORDER BY nspname), '') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname = '_prisma_migrations' AND c.relkind IN ('r', 'p');")"
  [ -z "$MIGRATION_TABLE_SCHEMAS" ] || fail "Source _prisma_migrations exists outside public (schema: $MIGRATION_TABLE_SCHEMAS); backup refused."
  fail "Source public._prisma_migrations table is absent; backup refused."
fi
MIGRATION_COLUMN_COUNT="$(DATABASE_URI="$BACKUP_DB_URL" node "$SCRIPT_DIR/run-with-database-url.mjs" \
  psql --no-password --tuples-only --no-align --field-separator=' ' --set=ON_ERROR_STOP=1 \
  --command "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '_prisma_migrations' AND column_name IN ('id', 'checksum', 'finished_at', 'migration_name', 'logs', 'rolled_back_at', 'started_at', 'applied_steps_count');")"
[ "$MIGRATION_COLUMN_COUNT" = "8" ] || fail "Source public._prisma_migrations has an incompatible schema; backup refused."
MIGRATION_COUNTS="$(DATABASE_URI="$BACKUP_DB_URL" node "$SCRIPT_DIR/run-with-database-url.mjs" \
  psql --no-password --tuples-only --no-align --field-separator=' ' --set=ON_ERROR_STOP=1 \
  --command "SELECT count(*), count(*) FILTER (WHERE finished_at IS NOT NULL AND rolled_back_at IS NULL), count(*) FILTER (WHERE finished_at IS NULL), count(*) FILTER (WHERE rolled_back_at IS NOT NULL) FROM public._prisma_migrations;")"
read -r MIGRATION_TOTAL MIGRATION_ACTIVE MIGRATION_UNFINISHED MIGRATION_ROLLED_BACK <<< "$MIGRATION_COUNTS"
[[ "$MIGRATION_TOTAL" =~ ^[0-9]+$ && "$MIGRATION_ACTIVE" =~ ^[0-9]+$ && \
   "$MIGRATION_UNFINISHED" =~ ^[0-9]+$ && "$MIGRATION_ROLLED_BACK" =~ ^[0-9]+$ ]] || \
  fail "Source Prisma migration history could not be validated; backup refused."
[ "$MIGRATION_TOTAL" -gt 0 ] || fail "Source public._prisma_migrations is empty; backup refused."
[ "$MIGRATION_ACTIVE" -gt 0 ] || fail "Source Prisma migration history has no applied migrations; backup refused."
[ "$MIGRATION_UNFINISHED" -eq 0 ] || fail "Source Prisma migration history has unfinished migrations; backup refused."

BACKUP_DIR="${BACKUP_DIR:-$PWD/backups}"
[ ! -e "$BACKUP_DIR" ] || [ -d "$BACKUP_DIR" ] || fail "BACKUP_DIR must be a directory."
mkdir -p "$BACKUP_DIR"
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"
WORK_DIR="$(mktemp -d "$BACKUP_DIR/.zuno-backup.XXXXXX")"
PUBLISHED_FILES=()
PUBLISH_COMPLETE=false
cleanup() {
  rm -rf -- "$WORK_DIR"
  if [ "$PUBLISH_COMPLETE" = false ] && [ "${#PUBLISHED_FILES[@]}" -gt 0 ]; then
    rm -f -- "${PUBLISHED_FILES[@]}"
  fi
}
trap cleanup EXIT
export GNUPGHOME="$WORK_DIR/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

aws_backup() {
  if [ -n "$BACKUP_ACCESS_KEY_ID" ]; then
    AWS_ACCESS_KEY_ID="$BACKUP_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$BACKUP_SECRET_ACCESS_KEY" \
    AWS_SESSION_TOKEN="$BACKUP_SESSION_TOKEN_VALUE" \
    AWS_PAGER="" "${AWS_COMMAND[@]}" "$@"
  else
    AWS_PAGER="" "${AWS_COMMAND[@]}" "$@"
  fi
}

NAME="zuno_$(date -u +%Y%m%d_%H%M%S)_$$_${RANDOM}"
DUMP_FILE="$WORK_DIR/$NAME.sql.dump"
ENCRYPTED_FILE="$WORK_DIR/$NAME.sql.dump.gpg"

# Decompose the URI into PG* variables: libpq treats PGDATABASE from the
# environment as a literal database name, not as a connection URI.
DATABASE_URI="$BACKUP_DB_URL" node "$(dirname "$0")/run-with-database-url.mjs" \
  pg_dump --no-password --format=custom --no-owner --no-privileges --file "$DUMP_FILE"
printf '%s\n' "$BACKUP_PASSPHRASE" | gpg \
  --batch --yes --pinentry-mode loopback --passphrase-fd 0 --force-mdc \
  --symmetric --cipher-algo AES256 --compress-algo none \
  --output "$ENCRYPTED_FILE" "$DUMP_FILE"

CHECKSUM="$(sha256sum < "$ENCRYPTED_FILE")"
CHECKSUM="${CHECKSUM%% *}"
printf '%s  %s\n' "$CHECKSUM" "$(basename "$ENCRYPTED_FILE")" > "$ENCRYPTED_FILE.sha256"
printf '{"createdAt":"%s","sha256":"%s","format":"postgresql-custom","encryption":"gpg-aes256-mdc"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CHECKSUM" > "$ENCRYPTED_FILE.manifest.json"

publish() {
  local source="$1"
  local destination="$BACKUP_DIR/$(basename "$source")"
  # Hard-link publication is atomic and fails rather than overwriting an
  # existing artifact. WORK_DIR is on the same filesystem as BACKUP_DIR.
  ln -- "$source" "$destination"
  PUBLISHED_FILES+=("$destination")
}
publish "$ENCRYPTED_FILE"
publish "$ENCRYPTED_FILE.sha256"
publish "$ENCRYPTED_FILE.manifest.json"
PUBLISH_COMPLETE=true

AWS_ARGS=(--region "$BACKUP_S3_REGION")
if [ -n "${BACKUP_S3_ENDPOINT_URL:-}" ]; then
  AWS_ARGS+=(--endpoint-url "$BACKUP_S3_ENDPOINT_URL")
fi
REMOTE_PREFIX="${BACKUP_S3_PREFIX}/"
REMOTE_BASE="s3://$BACKUP_S3_BUCKET/$REMOTE_PREFIX"
REMOTE_NAME="$(basename "$ENCRYPTED_FILE")"
aws_backup "${AWS_ARGS[@]}" s3 cp "$ENCRYPTED_FILE" "$REMOTE_BASE$REMOTE_NAME" --sse AES256 --only-show-errors
aws_backup "${AWS_ARGS[@]}" s3 cp "$ENCRYPTED_FILE.sha256" "$REMOTE_BASE$REMOTE_NAME.sha256" --only-show-errors
aws_backup "${AWS_ARGS[@]}" s3 cp "$ENCRYPTED_FILE.manifest.json" "$REMOTE_BASE$REMOTE_NAME.manifest.json" --only-show-errors

# Retain only canonical backup triplets under the dedicated prefix. Sidecars
# and unrelated objects never count toward the retention window or get deleted.
RETENTION_CUTOFF_EPOCH="$(date -u -d "$RETENTION_DAYS days ago" +%s)"
LIST_OUTPUT="$(aws_backup "${AWS_ARGS[@]}" s3api list-objects-v2 \
  --bucket "$BACKUP_S3_BUCKET" \
  --prefix "$REMOTE_PREFIX" \
  --query "reverse(sort_by(Contents,&LastModified))[].[Key,LastModified]" \
  --output text)"
BACKUP_KEYS=()
while IFS=$'\t' read -r key modified_at; do
  backup_name="${key##*/}"
  if [[ "$key" != "$REMOTE_PREFIX"* || ! "$backup_name" =~ ^zuno_[0-9]{8}_[0-9]{6}_[0-9]+_[0-9]+\.sql\.dump\.gpg$ ]]; then
    continue
  fi
  # Fail closed on malformed listings or timestamps: never delete an object
  # unless AWS reports it inside the dedicated prefix and older than the cutoff.
  [ -n "$modified_at" ] || continue
  modified_epoch="$(date -u -d "$modified_at" +%s 2>/dev/null)" || continue
  if [ "$modified_epoch" -le "$RETENTION_CUTOFF_EPOCH" ]; then
    BACKUP_KEYS+=("$key")
  fi
done <<< "$LIST_OUTPUT"
for old_key in "${BACKUP_KEYS[@]}"; do
  aws_backup "${AWS_ARGS[@]}" s3api delete-object --bucket "$BACKUP_S3_BUCKET" --key "$old_key" --only-show-errors >/dev/null
  aws_backup "${AWS_ARGS[@]}" s3api delete-object --bucket "$BACKUP_S3_BUCKET" --key "$old_key.sha256" --only-show-errors >/dev/null
  aws_backup "${AWS_ARGS[@]}" s3api delete-object --bucket "$BACKUP_S3_BUCKET" --key "$old_key.manifest.json" --only-show-errors >/dev/null
done

echo "Encrypted backup uploaded: $REMOTE_BASE$REMOTE_NAME"
echo "SHA256: $CHECKSUM"

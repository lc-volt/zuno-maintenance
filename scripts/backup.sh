#!/usr/bin/env bash
# Backup PostgreSQL customizado, criptografado e com checksum, enviado a um bucket
# S3 separado. Requer PostgreSQL, Node.js, GnuPG e sha256sum. O fallback da AWS
# evita depender do AWS CLI em serviços S3 compatíveis, como o Neon.
# Segredos nunca aparecem nos argumentos dos comandos.
set -euo pipefail
umask 077

# O runner reporta somente códigos bounded; URLs, credenciais e mensagens brutas
# nunca entram no status persistido. A credencial fica apenas no processo filho.
STATUS_SCRIPT="$(cd "$(dirname "$0")" && pwd)/report-backup-status.mjs"
STATUS_URL="${BACKUP_STATUS_URL:-}"
STATUS_TOKEN="${BACKUP_STATUS_TOKEN:-}"
STATUS_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STATUS_BACKUP_ID=""
STATUS_BACKUP_CREATED_AT=""
STATUS_STAGE="validation"
STATUS_REPORTED=false

report_status() {
  local outcome="$1"
  local error_code="${2:-}"
  [ "$STATUS_REPORTED" = false ] || return 0
  STATUS_REPORTED=true
  if [ -z "$STATUS_URL" ] && [ -z "$STATUS_TOKEN" ]; then
    return 0
  fi
  if [ -z "$STATUS_URL" ] || [ -z "$STATUS_TOKEN" ]; then
    echo "Backup status reporting is not configured completely." >&2
    return 0
  fi
  local finished_at duration_ms
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  duration_ms="$(( $(date -u +%s) - $(date -u -d "$STATUS_STARTED_AT" +%s) ))"
  if ! BACKUP_STATUS_URL="$STATUS_URL" \
    BACKUP_STATUS_TOKEN="$STATUS_TOKEN" \
    BACKUP_STATUS_STARTED_AT="$STATUS_STARTED_AT" \
    BACKUP_STATUS_FINISHED_AT="$finished_at" \
    BACKUP_STATUS_DURATION_MS="$duration_ms" \
    BACKUP_STATUS_OUTCOME="$outcome" \
    BACKUP_STATUS_BACKUP_ID="$STATUS_BACKUP_ID" \
    BACKUP_STATUS_BACKUP_CREATED_AT="$STATUS_BACKUP_CREATED_AT" \
    BACKUP_STATUS_ERROR_CODE="$error_code" \
    node "$STATUS_SCRIPT"; then
    echo "Backup status report failed; the backup exit code is unchanged." >&2
  fi
}

on_exit() {
  local code=$?
  trap - EXIT
  if [ "$code" -eq 0 ] || [ "${PUBLISH_COMPLETE:-false}" = true ]; then
    report_status success
  else
    local error_code="unknown"
    case "$STATUS_STAGE" in
      validation|source_validation) error_code="validation_failed" ;;
      dump) error_code="dump_failed" ;;
      encryption) error_code="encryption_failed" ;;
      checksum) error_code="checksum_failed" ;;
      publish) error_code="publish_failed" ;;
      upload) error_code="upload_failed" ;;
      retention) error_code="retention_failed" ;;
    esac
    report_status failure "$error_code"
  fi
  if declare -F cleanup >/dev/null; then
    if ! cleanup; then
      echo "Backup local cleanup failed; inspect the preserved files." >&2
    fi
  fi
  exit "$code"
}
trap on_exit EXIT

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

# Banco, passphrase e credenciais de evidências/backup ficam fora do ambiente
# herdado por ferramentas que não precisam delas. A AWS recebe apenas as próprias
# credenciais no escopo do comando, na função aws_backup abaixo.
BACKUP_DB_URL="$BACKUP_DATABASE_URL"
BACKUP_PASSPHRASE="$BACKUP_ENCRYPTION_PASSPHRASE"
BACKUP_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID:-}"
BACKUP_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY:-}"
BACKUP_SESSION_TOKEN_VALUE="${BACKUP_S3_SESSION_TOKEN:-}"
unset BACKUP_DATABASE_URL RESTORE_DATABASE_URL BACKUP_ENCRYPTION_PASSPHRASE \
  BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY BACKUP_S3_SESSION_TOKEN \
  BACKUP_STATUS_TOKEN BACKUP_STATUS_URL \
  EVIDENCE_S3_ACCESS_KEY_ID EVIDENCE_S3_SECRET_ACCESS_KEY

for tool in node pg_dump psql gpg sha256sum; do
  command -v "$tool" >/dev/null || fail "Required backup tool is missing: $tool"
done
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if command -v aws >/dev/null; then
  AWS_COMMAND=(aws)
else
  [ -f "$SCRIPT_DIR/s3-file-transfer.mjs" ] || fail "AWS CLI or the S3 SDK transfer helper is required."
  AWS_COMMAND=(node "$SCRIPT_DIR/s3-file-transfer.mjs")
fi

# O dump customizado preserva a origem, inclusive um histórico Prisma vazio.
# Não publicamos um backup que não possa ser restaurado depois.
STATUS_STAGE="source_validation"
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
  rm -rf -- "$WORK_DIR" || return 1
  if [ "$PUBLISH_COMPLETE" = false ] && [ "${#PUBLISHED_FILES[@]}" -gt 0 ]; then
    rm -f -- "${PUBLISHED_FILES[@]}" || return 1
  fi
  return 0
}
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
STATUS_BACKUP_ID="$NAME"
DUMP_FILE="$WORK_DIR/$NAME.sql.dump"
ENCRYPTED_FILE="$WORK_DIR/$NAME.sql.dump.gpg"

# Separa a URI em variáveis PG*: o libpq trata PGDATABASE como nome do banco,
# não como URI de conexão.
STATUS_STAGE="dump"
DATABASE_URI="$BACKUP_DB_URL" node "$(dirname "$0")/run-with-database-url.mjs" \
  pg_dump --no-password --format=custom --no-owner --no-privileges --file "$DUMP_FILE"
STATUS_STAGE="encryption"
printf '%s\n' "$BACKUP_PASSPHRASE" | gpg \
  --batch --yes --pinentry-mode loopback --passphrase-fd 0 --force-mdc \
  --symmetric --cipher-algo AES256 --compress-algo none \
  --output "$ENCRYPTED_FILE" "$DUMP_FILE"

STATUS_STAGE="checksum"
CHECKSUM="$(sha256sum < "$ENCRYPTED_FILE")"
CHECKSUM="${CHECKSUM%% *}"
printf '%s  %s\n' "$CHECKSUM" "$(basename "$ENCRYPTED_FILE")" > "$ENCRYPTED_FILE.sha256"
STATUS_BACKUP_CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"createdAt":"%s","sha256":"%s","format":"postgresql-custom","encryption":"gpg-aes256-mdc"}\n' \
  "$STATUS_BACKUP_CREATED_AT" "$CHECKSUM" > "$ENCRYPTED_FILE.manifest.json"

publish() {
  local source="$1"
  local destination="$BACKUP_DIR/$(basename "$source")"
  # O hard link torna a publicação atômica e impede sobrescrever um artefato.
  # WORK_DIR e BACKUP_DIR ficam no mesmo sistema de arquivos.
  ln -- "$source" "$destination"
  PUBLISHED_FILES+=("$destination")
}
STATUS_STAGE="publish"
publish "$ENCRYPTED_FILE"
publish "$ENCRYPTED_FILE.sha256"
publish "$ENCRYPTED_FILE.manifest.json"

AWS_ARGS=(--region "$BACKUP_S3_REGION")
if [ -n "${BACKUP_S3_ENDPOINT_URL:-}" ]; then
  AWS_ARGS+=(--endpoint-url "$BACKUP_S3_ENDPOINT_URL")
fi
REMOTE_PREFIX="${BACKUP_S3_PREFIX}/"
REMOTE_BASE="s3://$BACKUP_S3_BUCKET/$REMOTE_PREFIX"
REMOTE_NAME="$(basename "$ENCRYPTED_FILE")"
STATUS_STAGE="upload"
aws_backup "${AWS_ARGS[@]}" s3 cp "$ENCRYPTED_FILE" "$REMOTE_BASE$REMOTE_NAME" --sse AES256 --only-show-errors
aws_backup "${AWS_ARGS[@]}" s3 cp "$ENCRYPTED_FILE.sha256" "$REMOTE_BASE$REMOTE_NAME.sha256" --only-show-errors
aws_backup "${AWS_ARGS[@]}" s3 cp "$ENCRYPTED_FILE.manifest.json" "$REMOTE_BASE$REMOTE_NAME.manifest.json" --only-show-errors
# Só agora o tripleto remoto está completo; falhas de upload limpam a publicação local.
PUBLISH_COMPLETE=true
STATUS_STAGE="retention"

# Remove apenas backups completos dentro do prefixo dedicado que ficaram mais
# antigos que o corte. Sidecars soltos e objetos de outros sistemas não entram
# na retenção nem são apagados.
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
  # Se a lista ou a data estiver malformada, nada é apagado. Só removemos objetos
  # que a AWS confirmou dentro do prefixo dedicado e antes do corte.
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

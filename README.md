# zuno-maintenance

Trusted external runner for ZUNO API maintenance and encrypted offsite backups.

GitHub's `schedule` trigger has been unreliable for private repositories since
August 2026. This public repository therefore owns the 20-minute schedule, while
the ZUNO codebase stays private. The Windows task `ZUNO Maintenance Dispatcher`
is a reinforcement: it calls this workflow every 20 minutes and skips when a
recent run already exists. The task uses the GitHub credential already stored on
that machine and never prints it.

The API job authenticates only through GitHub OIDC. The token's `repository`,
`ref`, `workflow` and `workflow_ref` claims must match the API's
`OPERATIONS_OIDC_*` configuration, and the audience must equal the API origin
stored in the `ZUNO_API_URL` repository variable. Every run mints a short-lived
token that the API verifies and consumes once. The job calls
`POST /api/v1/operations/maintenance` with
`{tasks:["outbox","purge","reencrypt","schedulers"],batchSize:50,timeBudgetMs:20000}` and
fails if the API reports an unhealthy result. The `reencrypt` task advances at
most one persistent PQC field-key rotation batch per invocation.

The separate backup job runs `scripts/backup.sh` on the GitHub-hosted Ubuntu
runner, never in the web container. It lists the dedicated backup prefix and
runs only when the newest canonical `.sql.dump.gpg` is at least 24 hours old;
a listing failure fails open to a backup attempt so the window is not missed.
The script produces a PostgreSQL custom dump, encrypts it with GPG AES-256/MDC,
writes a SHA-256 sidecar and manifest, uploads all three to the separate S3
bucket and applies retention. Backup credentials exist only as encrypted
GitHub Actions secrets and are never printed. Restore remains an explicit,
confirmed operation using `scripts/restore.sh`; it is never scheduled.

After a new backup is published, `scripts/verify-backup.sh` downloads the
canonical object and sidecar, validates SHA-256, decrypts it and checks the dump
with `pg_restore --list`. It never restores data. Success and failure are
reported to `POST /api/v1/operations/backup-status` with the dedicated
`BACKUP_STATUS_TOKEN` Actions secret; the same value is configured on Render as
`BACKUP_STATUS_TOKEN`. `BACKUP_STATUS_URL` is derived from `ZUNO_API_URL` and
must be the exact HTTPS endpoint. Reports contain only bounded status codes and
timestamps, never credentials or raw provider errors. The API exposes freshness,
failure and verification gauges to Prometheus.

An authorized `workflow_dispatch` may override `backup_interval_hours`; `0`
forces a verification backup. Scheduled and dispatcher runs use the default of
24 hours. On 2026-11-24, run `45452755762` created a real encrypted artifact
whose SHA-256 sidecar and GPG decryption were verified and whose dump was
accepted by `pg_restore --list` (34 tables). Run `45453266656` then confirmed
the normal not-due path without creating another dump.

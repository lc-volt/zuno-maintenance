# zuno-maintenance

Trusted external runner for ZUNO API maintenance and encrypted offsite backups.

GitHub's `schedule` trigger has been unreliable since August 2026: it stopped
creating runs for private repositories and, as observed on 2026-11-24, also
created no runs for this public repository even with a new every-minute probe.
The workflow therefore keeps both `schedule` and `workflow_dispatch`, but an
external dispatcher is required for reliable maintenance. The ZUNO codebase
stays in a private repository; its `scripts/dispatch-maintenance.mjs` is
registered as the Windows task `ZUNO Maintenance Dispatcher`, which calls this
workflow every 20 minutes and skips when a recent run already exists. The task
uses the GitHub credential already stored on that machine and never prints it.

The API job authenticates only through GitHub OIDC. The token's `repository`,
`ref`, `workflow` and `workflow_ref` claims must match the API's
`OPERATIONS_OIDC_*` configuration, and the audience must equal the API origin
stored in the `ZUNO_API_URL` repository variable. Every run mints a short-lived
token that the API verifies and consumes once. The job calls
`POST /api/v1/operations/maintenance` with
`{tasks:["outbox","purge","schedulers"],batchSize:50,timeBudgetMs:20000}` and
fails if the API reports an unhealthy result.

The separate backup job runs `scripts/backup.sh` on the GitHub-hosted Ubuntu
runner, never in the web container. It lists the dedicated backup prefix and
runs only when the newest canonical `.sql.dump.gpg` is at least 24 hours old;
a listing failure fails open to a backup attempt so the window is not missed.
The script produces a PostgreSQL custom dump, encrypts it with GPG AES-256/MDC,
writes a SHA-256 sidecar and manifest, uploads all three to the separate S3
bucket and applies retention. Backup credentials exist only as encrypted
GitHub Actions secrets and are never printed. Restore remains an explicit,
confirmed operation using `scripts/restore.sh`; it is never scheduled.

# zuno-maintenance

Scheduled trigger for the ZUNO API maintenance endpoint.

GitHub's `schedule` trigger has been unreliable since August 2026: it stopped
creating runs for private repositories and, as observed on 2026-11-24, also
created no runs for this public repository even with a new every-minute probe.
The workflow therefore keeps both `schedule` and `workflow_dispatch`, but an
external dispatcher is required for reliable maintenance. The ZUNO codebase
stays in a private repository; its `scripts/dispatch-maintenance.mjs` is
registered as the Windows task `ZUNO Maintenance Dispatcher`, which calls this
workflow every 20 minutes and skips when a recent run already exists. The task
uses the GitHub credential already stored on that machine and never prints it.

There are no credentials here. The API trusts this workflow through GitHub
OIDC: the token's `repository`, `ref`, `workflow` and `workflow_ref` claims must
match the API's `OPERATIONS_OIDC_*` configuration, and the audience must equal
the API origin stored in the `ZUNO_API_URL` repository variable. Every run
mints a short-lived token that the API verifies and consumes once.

The workflow calls `POST /api/v1/operations/maintenance` with
`{tasks:["outbox","purge","schedulers"],batchSize:50,timeBudgetMs:20000}` and
fails the run if the API reports an unhealthy result.

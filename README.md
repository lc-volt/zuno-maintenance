# zuno-maintenance

Scheduled trigger for the ZUNO API maintenance endpoint.

GitHub's `schedule` trigger stopped creating runs for **private** repositories
in August 2026, while schedules in public repositories keep firing. This
public repository only exists to host the hourly trigger; the ZUNO codebase
itself stays in a private repository.

There are no credentials here. The API trusts this workflow through GitHub
OIDC: the token's `repository`, `ref`, `workflow` and `workflow_ref` claims must
match the API's `OPERATIONS_OIDC_*` configuration, and the audience must equal
the API origin stored in the `ZUNO_API_URL` repository variable. Every run
mints a short-lived token that the API verifies and consumes once.

The workflow calls `POST /api/v1/operations/maintenance` with
`{tasks:["outbox","purge","schedulers"],batchSize:50,timeBudgetMs:20000}` and
fails the run if the API reports an unhealthy result.

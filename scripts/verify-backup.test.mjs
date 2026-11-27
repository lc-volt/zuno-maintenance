import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const script = join(root, "verify-backup.sh");
const backupName = "zuno_20261127_030000_123_4.sql.dump.gpg";

function fixture(t) {
  const directory = mkdtempSync(join(tmpdir(), "zuno-verify-test-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const bin = join(directory, "bin");
  mkdirSync(bin, { recursive: true });
  const backup = join(directory, backupName);
  const sidecar = `${backup}.sha256`;
  const statusCapture = join(directory, "status.txt");
  const content = "encrypted backup fixture\n";
  writeFileSync(backup, content);
  writeFileSync(
    sidecar,
    `${createHash("sha256").update(content).digest("hex")}  ${backupName}\n`,
  );

  const executables = {
    aws: `#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"s3api list-objects-v2"* ]]; then
  printf 'zuno/%s\\t%s\\n' "$FAKE_BACKUP_NAME" "$FAKE_BACKUP_TIME"
elif [[ "$*" == *"s3 cp"* ]]; then
  args=("$@")
  for ((index=0; index<\${#args[@]}; index++)); do
    if [[ "\${args[index]}" = "s3" && "\${args[index+1]}" = "cp" ]]; then
      source="\${args[index+2]}"
      destination="\${args[index+3]}"
      break
    fi
  done
  if [[ "$source" == *.sha256 ]]; then
    cp "$FAKE_SIDECAR_FILE" "$destination"
  else
    cp "$FAKE_BACKUP_FILE" "$destination"
  fi
else
  echo "unexpected aws arguments" >&2
  exit 2
fi
`,
    gpg: `#!/usr/bin/env bash
set -euo pipefail
output=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '--output' ]; then
    output="$2"
    shift 2
  else
    shift
  fi
done
cat >/dev/null
[ -n "$output" ] || exit 2
printf 'TABLE DATA public users\\n' > "$output"
`,
    pg_restore: `#!/usr/bin/env bash
set -euo pipefail
[ "$1" = '--list' ] && [ -s "$2" ] || exit 2
printf 'TABLE DATA public users\\n'
`,
    node: `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$BACKUP_STATUS_OUTCOME" "$BACKUP_STATUS_VERIFIED" "$BACKUP_STATUS_BACKUP_ID" "$BACKUP_STATUS_ERROR_CODE" > "$FAKE_STATUS_CAPTURE"
`,
  };
  for (const [name, source] of Object.entries(executables)) {
    const path = join(bin, name);
    writeFileSync(path, source);
    chmodSync(path, 0o755);
  }

  const minutesAgo = (minutes) =>
    new Date(Date.now() - minutes * 60_000).toISOString();
  const environment = {
    ...process.env,
    PATH: `${bin}${process.platform === "win32" ? ";" : ":"}${process.env.PATH}`,
    BACKUP_S3_BUCKET: "backups",
    BACKUP_S3_REGION: "test-1",
    BACKUP_S3_ACCESS_KEY_ID: "test-access",
    BACKUP_S3_SECRET_ACCESS_KEY: "test-secret",
    BACKUP_ENCRYPTION_PASSPHRASE: "test-passphrase",
    BACKUP_S3_PREFIX: "zuno",
    FAKE_BACKUP_NAME: backupName,
    FAKE_BACKUP_TIME: minutesAgo(5),
    FAKE_BACKUP_FILE: backup,
    FAKE_SIDECAR_FILE: sidecar,
    FAKE_STATUS_CAPTURE: statusCapture,
  };
  delete environment.BACKUP_STATUS_URL;
  delete environment.BACKUP_STATUS_TOKEN;

  return {
    backup,
    sidecar,
    statusCapture,
    environment,
    run: (overrides = {}) =>
      spawnSync("bash", [script], {
        cwd: root,
        env: { ...environment, ...overrides },
        encoding: "utf8",
        timeout: 30_000,
      }),
  };
}

test("verifies checksum, decryption and pg_restore without restoring data", (t) => {
  const { run } = fixture(t);
  const result = run();
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Backup verification passed/);
});

test("reports verified success with the canonical backup id", (t) => {
  const { run, statusCapture } = fixture(t);
  const result = run({
    BACKUP_STATUS_URL:
      "https://api.example.com/api/v1/operations/backup-status",
    BACKUP_STATUS_TOKEN: "x".repeat(43),
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(readFileSync(statusCapture, "utf8").trim().split("\n"), [
    "success",
    "true",
    backupName.replace(/\.sql\.dump\.gpg$/, ""),
  ]);
});

test("rejects a backup older than 24 hours", (t) => {
  const { run } = fixture(t);
  const result = run({
    FAKE_BACKUP_TIME: new Date(Date.now() - 25 * 60 * 60_000).toISOString(),
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /older than 24 hours/);
});

test("rejects a checksum mismatch and reports a bounded failure code", (t) => {
  const { run, sidecar, statusCapture } = fixture(t);
  writeFileSync(sidecar, `${"0".repeat(64)}  ${backupName}\n`);
  const result = run({
    BACKUP_STATUS_URL:
      "https://api.example.com/api/v1/operations/backup-status",
    BACKUP_STATUS_TOKEN: "x".repeat(43),
  });
  assert.notEqual(result.status, 0);
  assert.deepEqual(readFileSync(statusCapture, "utf8").trim().split("\n"), [
    "failure",
    "false",
    backupName.replace(/\.sql\.dump\.gpg$/, ""),
    "checksum_failed",
  ]);
});

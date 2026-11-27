import { reportBackupStatus } from './backup-status-reporter.mjs';

const payload = {
  ...(process.env.BACKUP_STATUS_BACKUP_ID
    ? { backupId: process.env.BACKUP_STATUS_BACKUP_ID }
    : {}),
  startedAt: process.env.BACKUP_STATUS_STARTED_AT,
  finishedAt: process.env.BACKUP_STATUS_FINISHED_AT,
  durationMs: Number(process.env.BACKUP_STATUS_DURATION_MS),
  outcome: process.env.BACKUP_STATUS_OUTCOME,
  ...(process.env.BACKUP_STATUS_VERIFIED === undefined
    ? {}
    : { verified: process.env.BACKUP_STATUS_VERIFIED === 'true' }),
  ...(process.env.BACKUP_STATUS_BACKUP_CREATED_AT
    ? { backupCreatedAt: process.env.BACKUP_STATUS_BACKUP_CREATED_AT }
    : {}),
  ...(process.env.BACKUP_STATUS_ERROR_CODE
    ? { errorCode: process.env.BACKUP_STATUS_ERROR_CODE }
    : {}),
};

try {
  const result = await reportBackupStatus(payload, {
    url: process.env.BACKUP_STATUS_URL,
    token: process.env.BACKUP_STATUS_TOKEN,
    production: process.env.NODE_ENV === 'production',
  });
  console.log(
    `BACKUP_STATUS_REPORTED outcome=${payload.outcome} accepted=${result.accepted}`,
  );
} catch (error) {
  console.error(`BACKUP_STATUS_REPORT_FAILED code=${error?.code ?? 'unknown'}`);
  process.exitCode = 1;
}

const MAX_AGE_SKEW_MS = 5 * 60_000;
const ERROR_CODES = new Set([
  'validation_failed',
  'dump_failed',
  'encryption_failed',
  'checksum_failed',
  'publish_failed',
  'upload_failed',
  'retention_failed',
  'stale_backup',
  'verification_failed',
  'unknown',
]);
const ALLOWED_FIELDS = new Set([
  'backupId',
  'startedAt',
  'finishedAt',
  'durationMs',
  'outcome',
  'verified',
  'backupCreatedAt',
  'errorCode',
]);

class ReporterError extends Error {
  constructor(code) {
    super(code);
    this.name = 'ReporterError';
    this.code = code;
  }
}

function fail(code) {
  throw new ReporterError(code);
}

function iso(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T/.test(value))
    return null;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? timestamp : null;
}

export function validateStatusUrl(value, { production = false } = {}) {
  let url;
  try {
    url = new URL(value);
  } catch {
    fail('invalid_status_url');
  }
  const loopback =
    url.hostname === 'localhost' ||
    url.hostname === '127.0.0.1' ||
    url.hostname === '[::1]';
  if (
    url.protocol !== 'https:' &&
    !(url.protocol === 'http:' && loopback && !production)
  ) {
    fail('insecure_status_url');
  }
  if (url.username || url.password || url.search || url.hash)
    fail('unsafe_status_url');
  if (url.pathname !== '/api/v1/operations/backup-status')
    fail('invalid_status_path');
  return url;
}

export function validateStatusPayload(payload) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload))
    fail('invalid_payload');
  if (Object.keys(payload).some((key) => !ALLOWED_FIELDS.has(key)))
    fail('invalid_payload');

  const startedAt = iso(payload.startedAt);
  const finishedAt = iso(payload.finishedAt);
  const backupCreatedAt =
    payload.backupCreatedAt === undefined ? null : iso(payload.backupCreatedAt);
  if (startedAt === null || finishedAt === null || finishedAt < startedAt)
    fail('invalid_payload');
  if (payload.backupCreatedAt !== undefined && backupCreatedAt === null)
    fail('invalid_payload');
  if (
    !Number.isInteger(payload.durationMs) ||
    payload.durationMs < 0 ||
    payload.durationMs > 604_800_000
  ) {
    fail('invalid_payload');
  }
  if (payload.outcome !== 'success' && payload.outcome !== 'failure')
    fail('invalid_payload');
  if (payload.verified !== undefined && typeof payload.verified !== 'boolean')
    fail('invalid_payload');
  if (payload.backupId !== undefined) {
    if (
      typeof payload.backupId !== 'string' ||
      !/^zuno_[0-9]{8}_[0-9]{6}_[0-9]+_[0-9]+$/.test(payload.backupId) ||
      payload.backupId.length > 80
    ) {
      fail('invalid_payload');
    }
  }
  if (payload.errorCode !== undefined && !ERROR_CODES.has(payload.errorCode)) {
    fail('invalid_payload');
  }
  if (payload.outcome === 'success') {
    if (
      !payload.backupId ||
      backupCreatedAt === null ||
      payload.errorCode !== undefined
    ) {
      fail('invalid_payload');
    }
    if (
      (payload.verified !== true &&
        backupCreatedAt < startedAt - MAX_AGE_SKEW_MS) ||
      backupCreatedAt > finishedAt + MAX_AGE_SKEW_MS
    ) {
      fail('invalid_payload');
    }
  } else if (
    !payload.errorCode ||
    payload.verified === true ||
    payload.backupCreatedAt !== undefined
  ) {
    fail('invalid_payload');
  }
  return payload;
}

export async function reportBackupStatus(
  payload,
  { url, token, production = false, fetchImpl = fetch, timeoutMs = 10_000 },
) {
  validateStatusUrl(url, { production });
  validateStatusPayload(payload);
  if (typeof token !== 'string' || token.length < 32 || token.length > 512) {
    fail('invalid_status_token');
  }

  let response;
  try {
    response = await fetchImpl(url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify(payload),
      redirect: 'error',
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch {
    fail('status_request_failed');
  }
  if (!response.ok) fail(`status_http_${response.status}`);
  let result;
  try {
    result = await response.json();
  } catch {
    fail('invalid_status_response');
  }
  if (
    result &&
    typeof result === 'object' &&
    result.data &&
    typeof result.data === 'object'
  ) {
    result = result.data;
  }
  if (
    !result ||
    typeof result !== 'object' ||
    typeof result.accepted !== 'boolean' ||
    !result.status ||
    typeof result.status !== 'object'
  ) {
    fail('invalid_status_response');
  }
  return result;
}

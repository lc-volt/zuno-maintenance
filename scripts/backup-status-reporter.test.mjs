import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import test from 'node:test';
import {
  reportBackupStatus,
  validateStatusPayload,
  validateStatusUrl,
} from './backup-status-reporter.mjs';

const token = 'synthetic-status-token-with-at-least-32-characters';
const url = 'https://status.example.com/api/v1/operations/backup-status';
const payload = {
  backupId: 'zuno_20261126_000000_1_1',
  startedAt: '2026-11-26T00:00:00.000Z',
  finishedAt: '2026-11-26T00:05:00.000Z',
  durationMs: 300_000,
  outcome: 'success',
  backupCreatedAt: '2026-11-26T00:04:00.000Z',
};

test('status URL rejects credentials, query, fragment, wrong path and insecure remote HTTP', () => {
  for (const value of [
    'https://user:password@status.example.com/api/v1/operations/backup-status',
    `${url}?token=secret`,
    `${url}#fragment`,
    'https://status.example.com/api/v1/operations',
    'http://status.example.com/api/v1/operations/backup-status',
  ]) {
    assert.throws(() => validateStatusUrl(value, { production: true }), { code: /status/ });
  }
  assert.equal(
    validateStatusUrl('http://127.0.0.1:3000/api/v1/operations/backup-status').protocol,
    'http:',
  );
  assert.throws(
    () =>
      validateStatusUrl('http://127.0.0.1:3000/api/v1/operations/backup-status', {
        production: true,
      }),
    { code: 'insecure_status_url' },
  );
});

test('payload validation rejects unknown fields and inconsistent outcomes', () => {
  assert.throws(() => validateStatusPayload({ ...payload, databaseUrl: 'secret' }), {
    code: 'invalid_payload',
  });
  assert.throws(() => validateStatusPayload({ ...payload, errorCode: 'upload_failed' }), {
    code: 'invalid_payload',
  });
  assert.throws(
    () => validateStatusPayload({ ...payload, outcome: 'failure', errorCode: 'upload_failed' }),
    { code: 'invalid_payload' },
  );
  assert.doesNotThrow(() =>
    validateStatusPayload({
      ...payload,
      startedAt: '2026-11-26T01:00:00.000Z',
      finishedAt: '2026-11-26T01:05:00.000Z',
      verified: true,
    }),
  );
});

test('reporter sends the credential only in the bearer header over loopback', async (t) => {
  let received;
  const server = createServer(async (request, response) => {
    let body = '';
    for await (const chunk of request) body += chunk;
    received = {
      method: request.method,
      url: request.url,
      authorization: request.headers.authorization,
      idempotencyKey: request.headers['idempotency-key'],
      payload: JSON.parse(body),
    };
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(
      JSON.stringify({
        data: { accepted: true, duplicate: false, outOfOrder: false, status: {} },
      }),
    );
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();
  const loopbackUrl = `http://127.0.0.1:${address.port}/api/v1/operations/backup-status`;

  const result = await reportBackupStatus(payload, { url: loopbackUrl, token });

  assert.equal(result.accepted, true);
  assert.equal(received.method, 'POST');
  assert.equal(received.url, '/api/v1/operations/backup-status');
  assert.equal(received.authorization, `Bearer ${token}`);
  assert.match(received.idempotencyKey, /^[A-Fa-f0-9]{64}$/);
  assert.deepEqual(received.payload, payload);
  assert.ok(!loopbackUrl.includes(token));
});

test('idempotency keys are stable across property order and change with the report', async () => {
  const calls = [];
  const fetchImpl = async (_url, init) => {
    calls.push(init);
    return {
      ok: true,
      json: async () => ({ accepted: true, status: {} }),
    };
  };
  const options = { url, token, fetchImpl };

  await reportBackupStatus(payload, options);
  await reportBackupStatus(Object.fromEntries(Object.entries(payload).reverse()), options);
  await reportBackupStatus({ ...payload, durationMs: payload.durationMs + 1 }, options);

  const [first, reordered, changed] = calls.map((call) => call.headers['idempotency-key']);
  assert.match(first, /^[A-Fa-f0-9]{64}$/);
  assert.equal(first, reordered);
  assert.notEqual(first, changed);
});

test('reporter does not follow redirects or expose response bodies in errors', async (t) => {
  const server = createServer((_request, response) => {
    response.writeHead(307, { location: 'https://other.example.com/collect' });
    response.end('sensitive-provider-response');
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();
  const loopbackUrl = `http://127.0.0.1:${address.port}/api/v1/operations/backup-status`;

  await assert.rejects(reportBackupStatus(payload, { url: loopbackUrl, token }), (error) => {
    assert.equal(error.code, 'status_request_failed');
    assert.doesNotMatch(error.message, /sensitive-provider-response/);
    return true;
  });
});

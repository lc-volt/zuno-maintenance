import { spawnSync } from 'node:child_process';

const databaseUri = process.env.DATABASE_URI;
const [command, ...args] = process.argv.slice(2);

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

if (!databaseUri) fail('DATABASE_URI is required.');
if (!command) fail('A PostgreSQL client command is required.');

let url;
try {
  url = new URL(databaseUri);
} catch {
  fail('DATABASE_URI must be a valid PostgreSQL libpq URI.');
}
if (url.protocol !== 'postgresql:' && url.protocol !== 'postgres:') {
  fail('DATABASE_URI must use PostgreSQL.');
}
if (!url.hostname || url.pathname === '/' || url.pathname.length === 1) {
  fail('DATABASE_URI must include a host and database name.');
}

let username = '';
let password = '';
let database = '';
try {
  username = decodeURIComponent(url.username);
  password = decodeURIComponent(url.password);
  database = decodeURIComponent(url.pathname.slice(1));
} catch {
  fail('DATABASE_URI contains invalid percent encoding.');
}

const environment = { ...process.env };
delete environment.DATABASE_URI;
environment.PGHOST = url.hostname.startsWith('[') ? url.hostname.slice(1, -1) : url.hostname;
environment.PGPORT = url.port || '5432';
environment.PGUSER = username;
environment.PGPASSWORD = password;
environment.PGDATABASE = database;
environment.PGCONNECT_TIMEOUT ||= '15';

// A libpq URI passed through the PGDATABASE environment variable is treated
// as a literal database name by libpq. Decompose supported URI parameters into
// their PG* equivalents instead, preserving TLS/channel-binding requirements.
const parameterNames = {
  host: 'PGHOST',
  hostaddr: 'PGHOSTADDR',
  port: 'PGPORT',
  dbname: 'PGDATABASE',
  user: 'PGUSER',
  password: 'PGPASSWORD',
  passfile: 'PGPASSFILE',
  connect_timeout: 'PGCONNECT_TIMEOUT',
  client_encoding: 'PGCLIENTENCODING',
  options: 'PGOPTIONS',
  application_name: 'PGAPPNAME',
  sslmode: 'PGSSLMODE',
  sslnegotiation: 'PGSSLNEGOTIATION',
  sslcompression: 'PGSSLCOMPRESSION',
  sslcert: 'PGSSLCERT',
  sslkey: 'PGSSLKEY',
  sslrootcert: 'PGSSLROOTCERT',
  sslcrl: 'PGSSLCRL',
  sslcrldir: 'PGSSLCRLDIR',
  sslpassword: 'PGSSLPASSWORD',
  requirepeer: 'PGREQUIREPEER',
  krbsrvname: 'PGKRBSRVNAME',
  gssencmode: 'PGGSSENCMODE',
  channel_binding: 'PGCHANNELBINDING',
  target_session_attrs: 'PGTARGETSESSIONATTRS',
  load_balance_hosts: 'PGLOADBALANCEHOSTS',
};
for (const [rawKey, value] of url.searchParams) {
  const key = rawKey.toLowerCase();
  if (key === 'schema') continue; // Handled as a libpq search_path setting below.
  const environmentKey = parameterNames[key];
  if (!environmentKey) fail(`DATABASE_URI parameter is not supported: ${key}`);
  environment[environmentKey] = value;
}
const schema = url.searchParams.get('schema');
if (schema) {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(schema)) {
    fail('DATABASE_URI schema parameter is not a safe PostgreSQL identifier.');
  }
  const existingOptions = environment.PGOPTIONS?.trim();
  environment.PGOPTIONS = `${existingOptions ? `${existingOptions} ` : ''}-csearch_path=${schema}`;
}
if (
  process.env.NODE_ENV === 'production' &&
  url.searchParams.get('sslmode')?.toLowerCase() === 'disable'
) {
  fail('TLS cannot be disabled for a production database connection.');
}

const commandName = command
  .split(/[\\/]/)
  .pop()
  .replace(/\.exe$/i, '');
const hasDatabaseArgument = args.some(
  (argument) =>
    argument === '-d' ||
    argument === '--dbname' ||
    argument.startsWith('--dbname=') ||
    (argument.startsWith('-d') && argument.length > 2),
);
// pg_restore requires an explicit database selector even when libpq parameters
// are supplied through PG* environment variables. Pass only the database name;
// host, user, password and TLS settings remain outside the process arguments.
const toolArgs =
  commandName === 'pg_restore' && !hasDatabaseArgument
    ? ['--dbname', environment.PGDATABASE, ...args]
    : args;

const result = spawnSync(
  process.platform === 'win32' ? 'bash' : command,
  process.platform === 'win32'
    ? ['-c', 'exec "$@"', 'zuno-database-client', command, ...toolArgs]
    : toolArgs,
  {
    env: environment,
    stdio: 'inherit',
    windowsHide: true,
  },
);

if (result.error)
  fail(`Unable to execute ${command}: ${result.error.code ?? result.error.message}`);
if (result.signal) fail(`${command} terminated by signal ${result.signal}.`);
process.exit(result.status ?? 1);

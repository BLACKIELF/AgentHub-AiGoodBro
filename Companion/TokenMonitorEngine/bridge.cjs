#!/usr/bin/env node
'use strict';

// Token Monitor engine bridge — process entry.
//
// One UTF-8 JSON request on stdin, one JSON result on stdout, sanitized
// structured diagnostic codes on stderr, and a non-zero exit on any request
// level failure. No HTTP server, no Electron, no hub.
//
//   node engine/bridge.cjs < request.json > response.json
//
// The request handler itself lives in lib/handler.cjs and is exported for
// fixture testing; this file owns only the process concerns: stdin/stdout
// framing, the total deadline, cancellation, descendant termination, timezone
// setup and exit status.

// Installed before anything else so every upstream module that destructures
// child_process.spawn at load time captures the tracking wrapper.
const descendants = require('./lib/runtime/descendants.cjs');
descendants.install();

const { CODES, BridgeError, structuredError } = require('./lib/errors.cjs');
const { readStdinBounded, writeStdoutBounded } = require('./lib/runtime/stdio.cjs');
const { createRequestScope } = require('./lib/runtime/scope.cjs');
const { createDiagnostics } = require('./lib/runtime/diagnostics.cjs');
const { isKnownTimeZone, isIso8601, parseJson } = require('./lib/protocol.cjs');

const diagnostics = createDiagnostics(process.stderr);
const DEFAULT_TIMEOUT_MS = 30000;

// stderr is a structured channel: sanitized codes only. Node's own warnings
// (e.g. the experimental node:sqlite notice upstream pulls in) would otherwise
// arrive as free-form text that may embed filesystem paths. They are reported
// as a code with no message, so the channel stays parseable and leak-free.
process.emitWarning = function emitWarningSuppressed() {
  diagnostics.warn('runtime-warning', { phase: 'runtime' });
};

const EXIT_CODES = Object.freeze({
  [CODES.INVALID_REQUEST]: 2,
  [CODES.UNSUPPORTED_SCHEMA_VERSION]: 2,
  [CODES.UNKNOWN_OPERATION]: 2,
  [CODES.REQUEST_TOO_LARGE]: 2,
  [CODES.INVALID_SOURCE]: 2,
  [CODES.DUPLICATE_SOURCE_ID]: 2,
  [CODES.RESPONSE_TOO_LARGE]: 5,
  [CODES.TIMEOUT]: 3,
  [CODES.CANCELLED]: 4,
  [CODES.INTERNAL_ERROR]: 1
});

function exitCodeFor(code) {
  return EXIT_CODES[code] || 1;
}

function describeEngineSafely() {
  try {
    const loader = require('./lib/upstream/loader.cjs');
    return loader.describeEngine();
  } catch (_) {
    return { repository: 'Javis603/token-monitor', commit: 'unknown', version: 'unknown', hooks: [], vendorPackages: [] };
  }
}

function errorEnvelope(requestId, engine, code) {
  return {
    schemaVersion: 1,
    requestId: typeof requestId === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(requestId) ? requestId : '',
    engine: { repository: engine.repository, commit: engine.commit, version: engine.version },
    collectedAt: new Date().toISOString(),
    timezone: '',
    status: 'error',
    sources: [],
    payload: {},
    coverage: { entries: [], days: [], cost: 'unknown' },
    errors: [structuredError(code)]
  };
}

// Emits the response, then exits once stdout has actually drained — a pipe
// write is asynchronous and process.exit() would truncate it.
function finish(response, exitCode) {
  let text;
  try {
    text = `${JSON.stringify(response)}\n`;
  } catch (_) {
    diagnostics.error('response-serialization-failed', { phase: 'write' });
    text = `${JSON.stringify(errorEnvelope(response?.requestId, describeEngineSafely(), CODES.INTERNAL_ERROR))}\n`;
    exitCode = 1;
  }
  let writable = true;
  try {
    writeStdoutBounded(process.stdout, text);
  } catch (error) {
    writable = false;
    diagnostics.error(error instanceof BridgeError ? error.code : CODES.INTERNAL_ERROR, { phase: 'write' });
    exitCode = exitCodeFor(error instanceof BridgeError ? error.code : CODES.INTERNAL_ERROR);
  }
  if (!writable) {
    process.exit(exitCode);
    return;
  }
  process.stdout.write('', () => process.exit(exitCode));
}

async function main(testDependencies = {}) {
  let scope = null;
  const onSignal = () => {
    diagnostics.warn('signal-received', { phase: 'cancel' });
    // Before the scope exists there is nothing to abort, so exit directly
    // rather than leaving a process that ignored its termination signal.
    if (scope) scope.cancel();
    else process.exit(4);
  };
  process.on('SIGTERM', () => onSignal('SIGTERM'));
  process.on('SIGINT', () => onSignal('SIGINT'));

  let text;
  try {
    text = await readStdinBounded(process.stdin);
  } catch (error) {
    const code = error instanceof BridgeError ? error.code : CODES.INVALID_REQUEST;
    diagnostics.error(code, { phase: 'read' });
    finish(errorEnvelope('', describeEngineSafely(), code), exitCodeFor(code));
    return;
  }

  let parsed;
  try {
    parsed = parseJson(text);
  } catch (error) {
    const code = error instanceof BridgeError ? error.code : CODES.INVALID_REQUEST;
    diagnostics.error(code, { phase: 'parse' });
    finish(errorEnvelope('', describeEngineSafely(), code), exitCodeFor(code));
    return;
  }

  // The declared timezone must be in force before the first Date is constructed
  // anywhere in the process, because upstream's localTodayKey() and
  // computePeriodWindows() read the process timezone. Node re-reads TZ on
  // assignment, so this is set here rather than at process start.
  const requestTimezone = typeof parsed?.timezone === 'string' ? parsed.timezone.trim() : '';
  if (isKnownTimeZone(requestTimezone)) {
    process.env.TZ = requestTimezone;
  }

  const timeoutMs = Number.isFinite(parsed?.options?.timeoutMs) && parsed.options.timeoutMs > 0
    ? Math.min(parsed.options.timeoutMs, 600000)
    : DEFAULT_TIMEOUT_MS;
  scope = createRequestScope({ timeoutMs }).start();

  try {
    const { handleRequest } = require('./lib/handler.cjs');
    const response = await handleRequest(parsed, { scope, signal: scope.signal, ...testDependencies });
    scope.checkAborted();
    scope.dispose();
    diagnostics.info('request-complete', { phase: 'collect' });
    finish(response, 0);
  } catch (error) {
    scope.dispose();
    const cleanupConfirmed = await scope.waitForCleanup();
    if (!cleanupConfirmed) diagnostics.error('descendant-cleanup-unconfirmed', { phase: 'cancel' });
    const code = !cleanupConfirmed ? CODES.INTERNAL_ERROR : error instanceof BridgeError
      ? error.code
      : scope.timedOut
        ? CODES.TIMEOUT
        : scope.cancelled
          ? CODES.CANCELLED
          : error?.code === 'HOOK_APPLY_FAILED'
            ? CODES.INTERNAL_ERROR
            : CODES.INTERNAL_ERROR;
    diagnostics.error(code, { phase: 'handle', retryable: structuredError(code).retryable });
    const requestId = typeof parsed?.requestId === 'string' ? parsed.requestId : '';
    finish(errorEnvelope(requestId, describeEngineSafely(), code), exitCodeFor(code));
  }
}

if (require.main === module) main().catch((error) => {
  diagnostics.error(CODES.INTERNAL_ERROR, { phase: 'bootstrap' });
  finish(errorEnvelope('', describeEngineSafely(), CODES.INTERNAL_ERROR), 1);
});

module.exports = { main };

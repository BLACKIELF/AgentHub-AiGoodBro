'use strict';

const { CODES, BridgeError } = require('./errors.cjs');

const SCHEMA_VERSION = 1;
const OPERATIONS = Object.freeze(['collectUsage', 'collectLimits', 'capabilities']);
const MAX_SOURCES = 256;
const MAX_CUSTOM_SOURCES = 256;

function isPlainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function isIso8601(value) {
  if (!isNonEmptyString(value)) return false;
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value.trim())) return false;
  return Number.isFinite(Date.parse(value));
}

function isKnownTimeZone(value) {
  if (!isNonEmptyString(value)) return false;
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: value.trim() });
    return true;
  } catch (_) {
    return false;
  }
}

function requireField(condition) {
  if (!condition) throw new BridgeError(CODES.INVALID_REQUEST);
}

function parseJson(text) {
  try {
    return JSON.parse(text);
  } catch (_) {
    throw new BridgeError(CODES.INVALID_REQUEST);
  }
}

// Validates and normalizes a decoded request. Throws a BridgeError carrying the
// structured code the response and the process exit status are built from.
function validateRequest(request) {
  if (!isPlainObject(request)) throw new BridgeError(CODES.INVALID_REQUEST);

  if (request.schemaVersion !== SCHEMA_VERSION) {
    throw new BridgeError(CODES.UNSUPPORTED_SCHEMA_VERSION);
  }
  if (!isNonEmptyString(request.requestId) || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(request.requestId)) throw new BridgeError(CODES.INVALID_REQUEST);
  if (!isNonEmptyString(request.operation)) throw new BridgeError(CODES.INVALID_REQUEST);
  const operation = request.operation.trim();
  if (!OPERATIONS.includes(operation)) throw new BridgeError(CODES.UNKNOWN_OPERATION);

  requireField(isIso8601(request.now));
  requireField(isKnownTimeZone(request.timezone));
  requireField(isNonEmptyString(request.cacheDirectory));
  requireField(require('node:path').isAbsolute(request.cacheDirectory.trim()) && !request.cacheDirectory.includes('\0'));

  const rawSources = request.sources === undefined ? [] : request.sources;
  requireField(Array.isArray(rawSources));
  requireField(rawSources.length <= MAX_SOURCES);

  const rawOptions = request.options === undefined ? {} : request.options;
  requireField(isPlainObject(rawOptions));

  const options = {
    timeoutMs: rawOptions.timeoutMs === undefined ? 30000 : rawOptions.timeoutMs,
    allowPriceNetwork: rawOptions.allowPriceNetwork === true,
    allowSelfSync: rawOptions.allowSelfSync === true,
    allowCredentialRefresh: rawOptions.allowCredentialRefresh === true,
    includeLiveCodexAccount: rawOptions.includeLiveCodexAccount === true,
    allowProviderNetwork: rawOptions.allowProviderNetwork === undefined
      ? true
      : rawOptions.allowProviderNetwork === true
  };
  requireField(Number.isFinite(options.timeoutMs) && options.timeoutMs > 0 && options.timeoutMs <= 600000);

  const rawCustom = request.customSources === undefined ? [] : request.customSources;
  requireField(Array.isArray(rawCustom));
  requireField(rawCustom.length <= MAX_CUSTOM_SOURCES);

  return {
    schemaVersion: SCHEMA_VERSION,
    requestId: request.requestId.trim(),
    operation,
    now: request.now.trim(),
    timezone: request.timezone.trim(),
    cacheDirectory: request.cacheDirectory.trim(),
    sources: rawSources,
    customSources: rawCustom,
    options
  };
}

function engineIdentity(describeEngine) {
  return {
    repository: describeEngine.repository,
    commit: describeEngine.commit,
    version: describeEngine.version
  };
}

module.exports = {
  SCHEMA_VERSION,
  OPERATIONS,
  MAX_SOURCES,
  MAX_CUSTOM_SOURCES,
  isPlainObject,
  isNonEmptyString,
  isIso8601,
  isKnownTimeZone,
  parseJson,
  validateRequest,
  engineIdentity
};

'use strict';

const crypto = require('node:crypto');

const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const USERINFO_URL = 'https://www.googleapis.com/oauth2/v2/userinfo';
const API_BASE_URL = 'https://cloudcode-pa.googleapis.com';
const API_DAILY_BASE_URL = 'https://daily-cloudcode-pa.googleapis.com';
const API_DAILY_SANDBOX_BASE_URL = 'https://daily-cloudcode-pa.sandbox.googleapis.com';
// CLIProxyAPI follows Antigravity Hub's own client identity. Cloud Code rejects
// newer model data for clients below 2.9.0, so keep the same safe floor when an
// installed app is older or unavailable.
const ANTIGRAVITY_CLIENT_VERSION = '2.9.1';
const ANTIGRAVITY_USER_AGENT = `antigravity/hub/${ANTIGRAVITY_CLIENT_VERSION} darwin/arm64`;
const ANTIGRAVITY_ONBOARD_USER_AGENT = `${ANTIGRAVITY_USER_AGENT} google-api-nodejs-client/10.3.0`;
const ANTIGRAVITY_GOOG_API_CLIENT = 'gl-node/22.21.1';
const SCOPES = Object.freeze([
  'https://www.googleapis.com/auth/cloud-platform',
  'https://www.googleapis.com/auth/userinfo.email',
  'https://www.googleapis.com/auth/userinfo.profile',
  'https://www.googleapis.com/auth/cclog',
  'https://www.googleapis.com/auth/experimentsandconfigs'
]);
// Antigravity OAuth is disabled here; local usage parsing remains available.
const ANTIGRAVITY_METADATA = Object.freeze({ ideType: 'ANTIGRAVITY' });
const ANTIGRAVITY_CONTROL_PLANE_METADATA = Object.freeze({
  ide_type: 'ANTIGRAVITY',
  ide_version: ANTIGRAVITY_CLIENT_VERSION,
  ide_name: 'antigravity'
});

function trimmed(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function unique(values) {
  return [...new Set(values.filter(Boolean))];
}

function disabledOAuthError() {
  const error = new Error('Antigravity OAuth is not enabled in AiGoodBro. Existing local usage remains readable.');
  error.code = 'antigravity_oauth_disabled';
  error.status = 'unsupported';
  return error;
}

function officialOAuthClient() {
  throw disabledOAuthError();
}

function normalizeEmail(value) {
  return trimmed(value).toLowerCase();
}

function accountKey(email) {
  const normalized = normalizeEmail(email);
  if (!normalized) return '';
  const hash = crypto.createHash('sha256');
  hash.update('antigravity').update('\0').update(normalized).update('\0');
  return `sha256:${hash.digest('hex')}`;
}

function normalizeManagedAccounts(value, options = {}) {
  if (!Array.isArray(value)) return [];
  const seenIds = new Set();
  const seenAccounts = new Set();
  return value.flatMap((entry) => {
    const id = trimmed(entry?.id);
    const accountEmail = normalizeEmail(entry?.accountEmail || entry?.email);
    const identity = accountKey(accountEmail);
    if (!id || !accountEmail || seenIds.has(id) || seenAccounts.has(identity)) return [];
    seenIds.add(id);
    seenAccounts.add(identity);
    const normalized = {
      id,
      accountKey: trimmed(entry?.accountKey) || identity,
      accountEmail,
      accountLabel: trimmed(entry?.accountLabel),
      enabled: entry?.enabled !== false,
      addedAt: trimmed(entry?.addedAt),
      updatedAt: trimmed(entry?.updatedAt)
    };
    if (options.includeCredentials === true && entry?.credentials && typeof entry.credentials === 'object') {
      normalized.credentials = { ...entry.credentials };
    }
    return [normalized];
  });
}

function managedAccountsForCollector(value, readCredential) {
  if (typeof readCredential !== 'function') throw new TypeError('readCredential is required');
  return normalizeManagedAccounts(value).map((account) => ({
    ...account,
    credentials: readCredential(account.id)
  }));
}

function parseClientFromText() {
  throw disabledOAuthError();
}

function candidateOAuthArtifacts() {
  return [];
}

function discoverOAuthClient() {
  throw disabledOAuthError();
}

function generatePkce() {
  const codeVerifier = crypto.randomBytes(32).toString('base64url');
  const codeChallenge = crypto.createHash('sha256').update(codeVerifier).digest('base64url');
  return { codeVerifier, codeChallenge };
}

function authorizationUrl() {
  throw disabledOAuthError();
}

function formBody(values) {
  return new URLSearchParams(Object.entries(values).filter(([, value]) => trimmed(value))).toString();
}

function errorWithStatus(status, message, httpStatus = null) {
  const error = new Error(message);
  error.status = status;
  if (Number.isInteger(httpStatus)) error.httpStatus = httpStatus;
  return error;
}

function googleVerificationRequired(status, body) {
  if (status !== 403) return false;
  const detail = trimmed(body?.error?.message || body?.message || body?.error_description || body?.error);
  if (!/\bverify (?:your )?account\b/i.test(detail)) return false;
  const urls = detail.match(/https?:\/\/[^\s"'<>]+/gi) || [];
  return urls.some((value) => {
    try { return new URL(value).hostname === 'accounts.google.com'; } catch (_) { return false; }
  });
}

async function responseJson(response, action) {
  let body = null;
  try { body = await response.json(); } catch (_) {}
  if (response?.ok) return body || {};
  const status = Number(response?.status);
  const detail = trimmed(body?.error_description || body?.error?.message || body?.error) || `HTTP ${status || 0}`;
  if (status === 400 || status === 401) throw errorWithStatus('unauthorized', `${action}: ${detail}`, status);
  if (googleVerificationRequired(status, body)) {
    throw errorWithStatus(
      'verificationRequired',
      'Google requires account verification. Open Antigravity and complete verification, then refresh.',
      status
    );
  }
  if (status === 403) throw errorWithStatus('permissionDenied', `${action}: ${detail}`, status);
  if (status === 429) throw errorWithStatus('rateLimited', `${action}: ${detail}`, status);
  throw errorWithStatus('unavailable', `${action}: ${detail}`, status);
}

async function exchangeAuthorizationCode() {
  throw disabledOAuthError();
}

async function fetchGoogleIdentity() {
  throw disabledOAuthError();
}

async function refreshCredential() {
  throw disabledOAuthError();
}

async function cloudCodeRequest(endpoint, accessToken, body, deps = {}, options = {}) {
  const baseUrl = trimmed(options.baseUrl) || API_BASE_URL;
  const response = await (deps.fetch || fetch)(`${baseUrl}${endpoint}`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${accessToken}`,
      accept: '*/*',
      'content-type': 'application/json',
      'user-agent': trimmed(options.userAgent) || ANTIGRAVITY_USER_AGENT,
      ...(options.headers || {})
    },
    body: JSON.stringify(body || {}),
    signal: deps.signal
  });
  return responseJson(response, `Antigravity API ${endpoint} failed`);
}

function projectIdFrom(value) {
  for (const container of [value, value?.response]) {
    for (const key of ['cloudaicompanionProject', 'projectId', 'project']) {
      const project = container?.[key];
      const id = trimmed(typeof project === 'string' ? project : project?.value || project?.id || project?.projectId);
      if (id) return id;
    }
  }
  return '';
}

function planFromLoadResponse(response, credential) {
  const direct = trimmed(response?.planInfo?.planType);
  if (direct) return direct;
  const paidTierId = trimmed(response?.paidTier?.id).toLowerCase();
  if (paidTierId === 'g1-pro-tier') return 'Pro';
  const paidTierName = trimmed(response?.paidTier?.name);
  if (paidTierName) return paidTierName;
  const tierId = trimmed(response?.currentTier?.id);
  if (tierId === 'standard-tier') return 'Paid';
  if (tierId === 'legacy-tier') return 'Legacy';
  if (tierId === 'free-tier') return hostedDomainFromIdToken(credential?.idToken) ? 'Workspace' : 'Free';
  return trimmed(response?.currentTier?.name);
}

function hostedDomainFromIdToken(idToken) {
  try {
    const payload = String(idToken || '').split('.')[1];
    if (!payload) return '';
    return trimmed(JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'))?.hd);
  } catch (_) {
    return '';
  }
}

function onboardTier(response) {
  const allowed = Array.isArray(response?.allowedTiers) ? response.allowedTiers : [];
  return trimmed(allowed.find((tier) => tier?.isDefault === true)?.id)
    || trimmed(allowed.find((tier) => tier?.id)?.id)
    || trimmed(response?.paidTier?.id)
    || trimmed(response?.currentTier?.id)
    || 'free-tier';
}

function delay(ms, signal) {
  if (signal?.aborted) return Promise.reject(signal.reason || errorWithStatus('unavailable', 'Operation cancelled'));
  return new Promise((resolve, reject) => {
    const timer = setTimeout(resolve, ms);
    const abort = () => {
      clearTimeout(timer);
      reject(signal.reason || errorWithStatus('unavailable', 'Operation cancelled'));
    };
    signal?.addEventListener('abort', abort, { once: true });
  });
}

async function resolveProjectId(loadResponse, credential, deps = {}) {
  const stored = trimmed(credential?.projectId);
  if (stored) return stored;
  const loaded = projectIdFrom(loadResponse);
  if (loaded) return loaded;
  const tierId = onboardTier(loadResponse);
  try {
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const onboarded = await cloudCodeRequest('/v1internal:onboardUser', credential.accessToken, {
        tier_id: tierId,
        metadata: ANTIGRAVITY_CONTROL_PLANE_METADATA
      }, deps, {
        baseUrl: API_DAILY_BASE_URL,
        userAgent: ANTIGRAVITY_ONBOARD_USER_AGENT,
        headers: { 'x-goog-api-client': ANTIGRAVITY_GOOG_API_CLIENT }
      });
      const projectId = projectIdFrom(onboarded);
      if (projectId) return projectId;
      if (attempt < 4) await (deps.delay || delay)(2000, deps.signal);
    }
  } catch (error) {
    deps.logger?.(`Antigravity onboarding failed: ${error.message}`);
  }
  return '';
}

async function fetchAvailableModels(accessToken, projectBody, deps = {}) {
  const baseUrls = Array.isArray(deps.antigravityModelBaseUrls) && deps.antigravityModelBaseUrls.length > 0
    ? deps.antigravityModelBaseUrls
    : [API_BASE_URL, API_DAILY_BASE_URL, API_DAILY_SANDBOX_BASE_URL];
  let lastError = null;
  for (const baseUrl of baseUrls) {
    try {
      return await cloudCodeRequest('/v1internal:fetchAvailableModels', accessToken, projectBody, deps, { baseUrl });
    } catch (error) {
      lastError = error;
      if (error?.status === 'unauthorized' || error?.status === 'verificationRequired' || error?.status === 'rateLimited') throw error;
    }
  }
  throw lastError || errorWithStatus('unavailable', 'Antigravity model endpoints returned no response');
}

function clampFraction(value) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.max(0, Math.min(1, number)) : null;
}

function modelsFromAvailable(response) {
  const models = response?.models && typeof response.models === 'object' ? response.models : {};
  return Object.entries(models).flatMap(([modelId, value]) => {
    if (!value?.quotaInfo) return [];
    return [{
      modelId,
      label: trimmed(value.displayName || value.label) || modelId,
      remainingFraction: clampFraction(value.quotaInfo.remainingFraction),
      resetTime: trimmed(value.quotaInfo.resetTime) || null
    }];
  });
}

function modelsFromBuckets(response) {
  const byModel = new Map();
  for (const bucket of Array.isArray(response?.buckets) ? response.buckets : []) {
    const modelId = trimmed(bucket?.modelId);
    if (!modelId) continue;
    const next = {
      modelId,
      label: modelId,
      remainingFraction: clampFraction(bucket?.remainingFraction),
      resetTime: trimmed(bucket?.resetTime) || null
    };
    const current = byModel.get(modelId);
    if (!current || (next.remainingFraction ?? Infinity) < (current.remainingFraction ?? Infinity)) byModel.set(modelId, next);
  }
  return [...byModel.values()];
}

function mergeVerifiedModels(available, verified) {
  const byId = new Map(verified.map((model) => [normalizeEmail(model.modelId), model]));
  const merged = [];
  for (const model of available) {
    const match = byId.get(normalizeEmail(model.modelId));
    if (!match) continue;
    byId.delete(normalizeEmail(model.modelId));
    merged.push({
      ...model,
      remainingFraction: match.remainingFraction ?? model.remainingFraction,
      resetTime: match.resetTime || model.resetTime
    });
  }
  for (const model of byId.values()) if (model.remainingFraction !== null) merged.push(model);
  return merged;
}

async function fetchRemoteSnapshot() {
  throw disabledOAuthError();
}

module.exports = {
  AUTH_URL,
  TOKEN_URL,
  USERINFO_URL,
  SCOPES,
  accountKey,
  authorizationUrl,
  candidateOAuthArtifacts,
  discoverOAuthClient,
  exchangeAuthorizationCode,
  fetchGoogleIdentity,
  fetchRemoteSnapshot,
  generatePkce,
  modelsFromAvailable,
  modelsFromBuckets,
  managedAccountsForCollector,
  normalizeManagedAccounts,
  parseClientFromText,
  refreshCredential,
  _disabledOAuthError: disabledOAuthError,
  _mergeVerifiedModels: mergeVerifiedModels,
  _planFromLoadResponse: planFromLoadResponse,
  _officialOAuthClient: officialOAuthClient
};

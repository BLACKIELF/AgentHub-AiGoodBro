'use strict';

const antigravityOAuth = require('../../../shared/providers/antigravity/oauth');

const DEFAULT_TIMEOUT_MS = 120_000;

function loginError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function callbackPage(ok) {
  const title = ok ? 'Sign-in received' : 'Antigravity sign-in failed';
  const detail = ok
    ? 'Return to Token Monitor to finish connecting this account.'
    : 'Return to Token Monitor for details.';
  return `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${title}</title><body style="font:16px system-ui;padding:40px;max-width:560px;margin:auto"><h1>${title}</h1><p>${detail}</p></body></html>`;
}

async function runAntigravityOAuthLogin() {
  // Refuse before binding a callback socket, opening a browser, or requesting credentials.
  throw antigravityOAuth._disabledOAuthError();
}

module.exports = {
  DEFAULT_TIMEOUT_MS,
  runAntigravityOAuthLogin,
  _callbackPage: callbackPage
};

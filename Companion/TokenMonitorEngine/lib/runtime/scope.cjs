'use strict';

const descendants = require('./descendants.cjs');
const { CODES, BridgeError } = require('../errors.cjs');

// One request, one deadline, one abort signal.
//
// The deadline is the contract's total budget: it covers validation, the
// upstream scans, history and limits, and the aggregation afterwards. When it
// fires — or when the host cancels — the signal aborts the upstream call (which
// throws between stages) and every spawned descendant is terminated, so no
// tokscale scan outlives the request that started it.

class RequestScope {
  constructor({ timeoutMs }) {
    this.controller = new AbortController();
    this.signal = this.controller.signal;
    this.timeoutMs = timeoutMs;
    this.timedOut = false;
    this.cancelled = false;
    this.timer = null;
    this.cleanup = null;
    this.startedAt = Date.now();
  }

  start() {
    if (this.timer || this.timeoutMs === undefined) return this;
    // Deliberately not unref'd. An unref'd deadline does not keep the event
    // loop alive, so a request parked on a child process that never settles
    // would let Node exit 0 with no response at all — the exact failure the
    // deadline exists to prevent. The timer must be able to outlive the work.
    this.timer = setTimeout(() => {
      this.timedOut = true;
      this.abort(new BridgeError(CODES.TIMEOUT));
    }, this.timeoutMs);
    return this;
  }

  abort(error) {
    if (this.signal.aborted) return;
    this.controller.abort(error instanceof Error ? error : new BridgeError(CODES.CANCELLED));
    this.cleanup = descendants.killAll();
  }

  cancel() {
    if (this.signal.aborted) return;
    this.cancelled = true;
    this.abort(new BridgeError(CODES.CANCELLED));
  }

  // Called at every stage boundary. The upstream collector also checks its own
  // signal, so a long scan is interrupted from inside as well.
  checkAborted() {
    if (!this.signal.aborted) return;
    throw this.signal.reason instanceof Error ? this.signal.reason : new BridgeError(CODES.CANCELLED);
  }

  elapsedMs() {
    return Date.now() - this.startedAt;
  }

  waitForCleanup() {
    return this.cleanup || Promise.resolve(true);
  }

  dispose() {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  }
}

function createRequestScope(options) {
  return new RequestScope(options);
}

module.exports = { RequestScope, createRequestScope };

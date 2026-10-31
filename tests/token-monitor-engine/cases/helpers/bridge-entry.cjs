'use strict';
require('./bootstrap.cjs');
if (process.env.TOKEN_MONITOR_ENGINE_FIXTURES_MODE === 'cleanup-unconfirmed') {
  const scopes = require('../../lib/runtime/scope.cjs');
  const create = scopes.createRequestScope;
  scopes.createRequestScope = options => {
    const scope = create(options);
    scope.waitForCleanup = async () => false;
    return scope;
  };
}
require('../../bridge.cjs').main(require('./fixture-runner.cjs'));

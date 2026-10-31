import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { errorIdentity, collectTaskResources } from './failure-diagnostics.mjs';


export default class FailureReporter {
  onTestEnd(test, result) {
    if (!['failed', 'timedOut', 'interrupted'].includes(result.status)) return;
    try {
      // Playwright owns outputDir and gives each case a disjoint run directory.
      const directory = result.attachments.find(a => a.name === 'error-context')?.path;
      // Even a failure before fixture setup gets an owned, content-free folder.
      const key = createHash('sha256').update(`${test.id}:${result.retry}`).digest('hex').slice(0, 24);
      const target = directory ? path.dirname(directory)
        : path.join(test.parent.project().outputDir, `failure-${key}`);
      mkdirSync(target, { recursive: true });
      let failureResources;
      try { failureResources = JSON.parse(readFileSync(path.join(target, 'page-errors.redacted.json'), 'utf8')).failureResources; } catch {}
      writeFileSync(path.join(target, 'failure-resources.redacted.json'), JSON.stringify({
        schemaVersion: 1, syntheticOnly: true, status: result.status,
        errors: result.errors.map(errorIdentity), resources: failureResources || collectTaskResources(),
      }, null, 2));
    } catch { /* Preserve the original outcome, including missing diagnostics. */ }
  }
}

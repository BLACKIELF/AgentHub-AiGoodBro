'use strict';

// Minimal, source-anchored backport of the merged PR925 export privacy fix.
// This transformer is intentionally separate from the host branding stage:
// it only changes the pinned 0.62.0 exporter/usage sources.
const crypto = require('node:crypto');

const INPUT_SHA256 = Object.freeze({
  'src/shared/exporter.js': 'ca0043029abfddbe34267e0c8d0c02229a682b8280dafbfadca0202f1fc73fe2',
  'src/shared/usage.js': 'fcff884a3b9097ff10ba33b9578cd902d00bfa1b2990f8ccb24221dd45b08f88'
});

function replaceOne(source, needle, replacement, label) {
  const first = source.indexOf(needle);
  if (first < 0 || source.indexOf(needle, first + needle.length) >= 0) {
    throw new Error(`${label}: expected exactly one source anchor`);
  }
  return source.slice(0, first) + replacement + source.slice(first + needle.length);
}

function patchUsage(source) {
  return replaceOne(source,
    '  projectRollupFromSessions,\n  stripSessionTextFromDeviceRecord\n};',
    '  projectRollupFromSessions,\n  stripSessionTextFromDeviceRecord,\n  stripSessionTextFromPeriod\n};',
    'usage privacy helper export');
}

function patchExporter(source) {
  let text = replaceOne(source,
    '// node:test-able and its signatures physically exclude devices/limits (privacy).\n',
    "// node:test-able and its signatures physically exclude devices/limits (privacy).\n\nconst { stripSessionTextFromPeriod } = require('./usage');\n",
    'exporter usage import');
  text = replaceOne(text,
    '  // Lossless: a whole period is usage data (cache/output/session breakdowns\n  // included) — pass it through untouched to honor the "lossless JSON" contract.\n  // The privacy boundary is the function signature: devices/limits are siblings\n  // of `periods` in the aggregate and never reach this module.\n  return p && typeof p === \'object\' ? p : {};',
    '  // Preserve usage dimensions and counters, while applying the same explicit\n  // session-text field list used at Hub ingress. Devices and limits remain\n  // outside this function by signature.\n  return p && typeof p === \'object\' ? stripSessionTextFromPeriod(p) : {};',
    'exporter period privacy boundary');
  return text;
}

const TRANSFORMS = Object.freeze({
  'src/shared/exporter.js': patchExporter,
  'src/shared/usage.js': patchUsage
});

function transformExportPrivacy(sourceMap) {
  if (!sourceMap || typeof sourceMap !== 'object') throw new Error('Expected a staging source map');
  const outputs = [];
  for (const [relativePath, transform] of Object.entries(TRANSFORMS)) {
    const source = sourceMap[relativePath];
    if (typeof source !== 'string') throw new Error(`Missing staged source: ${relativePath}`);
    const actual = crypto.createHash('sha256').update(source).digest('hex');
    if (actual !== INPUT_SHA256[relativePath]) throw new Error(`Pinned upstream hash changed: ${relativePath}`);
    const output = transform(source);
    if (output === source) throw new Error(`No staged change produced: ${relativePath}`);
    outputs.push({ relativePath, source, output });
  }
  return outputs;
}

module.exports = { INPUT_SHA256, TRANSFORMS, patchExporter, patchUsage, replaceOne, transformExportPrivacy };

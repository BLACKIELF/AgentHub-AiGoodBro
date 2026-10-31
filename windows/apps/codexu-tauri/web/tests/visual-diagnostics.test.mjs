import assert from 'node:assert/strict';
import test from 'node:test';
import { readdir, readFile } from 'node:fs/promises';
import { errorIdentity } from './visual/failure-diagnostics.mjs';

test('diagnostic errors retain a category and correlation hash without private text', () => {
  const privateValue = 'token=synthetic-private-value user@example.invalid C:\\private\\account';
  const error = new TypeError(`net::ERR_NO_BUFFER_SPACE ${privateValue}`);
  const result = errorIdentity(error);
  assert.equal(result.name, 'TypeError');
  assert.equal(result.networkCode, 'ERR_NO_BUFFER_SPACE');
  assert.match(result.messageSHA256, /^[a-f0-9]{64}$/);
  assert.equal(JSON.stringify(result).includes(privateValue), false);
  assert.deepEqual(errorIdentity(error), result);
  assert.notEqual(errorIdentity(new Error('another error')).messageSHA256, result.messageSHA256);
  assert.equal(errorIdentity({ name: privateValue, message: privateValue }).name, 'Error');
});

test('every visual spec uses the synthetic diagnostic entry point', async () => {
  const directory = new URL('./visual/', import.meta.url);
  const specs = (await readdir(directory)).filter(name => name.endsWith('.visual.spec.mjs'));
  assert.ok(specs.length > 0);
  for (const name of specs) {
    const source = await readFile(new URL(name, directory), 'utf8');
    assert.match(source, /import\s*\{\s*installTauriStub\s*\}\s*from\s*['"]\.\/tauri-stub\.mjs['"]/,
      `${name}: route through the synthetic diagnostic entry point`);
    assert.match(source, /(?:await\s+)?installTauriStub\(/);
  }
});

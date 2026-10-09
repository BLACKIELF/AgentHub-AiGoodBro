'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');
const { INPUT_SHA256, transformStage } = require('../Companion/TokenMonitorDesktop/transform-stage.cjs');

const vendor = path.resolve(__dirname, '../Companion/TokenMonitorEngine/upstream');

function staging(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'token-monitor-stage-1006-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const inputs = new Map();
  for (const [relative, expected] of Object.entries(INPUT_SHA256)) {
    const original = fs.readFileSync(path.join(vendor, relative), 'utf8');
    assert.equal(crypto.createHash('sha256').update(original).digest('hex'), expected);
    inputs.set(relative, original);
    const target = path.join(root, relative);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, original);
  }
  return { root, inputs };
}

test('unified staging validates and applies every backport with existing host adaptation', (t) => {
  const { root, inputs } = staging(t);
  const changed = transformStage(root);
  assert.deepEqual(new Set(changed), new Set(Object.keys(INPUT_SHA256)));
  for (const relative of changed) {
    const output = fs.readFileSync(path.join(root, relative), 'utf8');
    assert.notEqual(output, inputs.get(relative));
    if (relative.endsWith('.js')) new vm.Script(output, { filename: relative });
    assert.equal(fs.readFileSync(path.join(vendor, relative), 'utf8'), inputs.get(relative));
  }
  assert.throws(() => transformStage(root), /Pinned upstream hash changed/);
});

test('late hash drift leaves all staging files unchanged', (t) => {
  const { root, inputs } = staging(t);
  const last = [...inputs.keys()].at(-1);
  inputs.set(last, inputs.get(last) + '\n// Synthetic drift\n');
  fs.writeFileSync(path.join(root, last), inputs.get(last));
  assert.throws(() => transformStage(root), /Pinned upstream hash changed/);
  for (const [relative, input] of inputs) {
    assert.equal(fs.readFileSync(path.join(root, relative), 'utf8'), input);
  }
});

test('missing source and relative roots fail before any staging write', (t) => {
  const { root, inputs } = staging(t);
  const last = [...inputs.keys()].at(-1);
  fs.unlinkSync(path.join(root, last));
  assert.throws(() => transformStage(root), /ENOENT/);
  assert.throws(() => transformStage('relative-stage'), /absolute staging/);
  for (const [relative, input] of inputs) {
    if (relative !== last) assert.equal(fs.readFileSync(path.join(root, relative), 'utf8'), input);
  }
});

function detailRenderer(source, i18n, locale) {
  const start = source.indexOf('function renderSessionDetail(');
  const end = source.indexOf('\nfunction ', start + 1);
  assert.ok(start >= 0 && end > start);
  const element = () => ({
    children: [],
    classList: { add() {}, remove() {} },
    replaceChildren() { this.children = []; },
    append(child) { this.children.push(child); },
    addEventListener() {}
  });
  const els = { breakdown: element(), sessionDetail: element(), sessionDetailHead: element() };
  const context = vm.createContext({
    els, document: { createElement: element }, sessionDetailBack() {},
    sessionDetailBackButton: element,
    sessionRowsApi: require(path.join(vendor, 'src/electron/renderer/sessionRows.js')),
    detailNote: text => ({ text }), t: key => i18n.translate(locale, key),
    state: { detailSort: 'newest' }, Date,
    sessionDetailApi: { exchangeRows: () => [] }
  });
  vm.runInContext(source.slice(start, end), context);
  return args => {
    context.renderSessionDetail(args);
    return els.sessionDetail.children.map(child => child.text);
  };
}

test('staged production renderer separates read failure, oversized records and missing files in all locales', (t) => {
  const { root } = staging(t);
  transformStage(root);
  const app = fs.readFileSync(path.join(root, 'src/electron/renderer/app.js'), 'utf8');
  const i18n = require(path.join(root, 'src/electron/renderer/i18n.js'));
  for (const locale of ['en', 'zh-TW', 'zh-CN', 'ko', 'ja', 'pt-BR']) {
    const render = detailRenderer(app, i18n, locale);
    for (const [code, key] of [['line-too-large', 'detailRecordTooLarge'], ['read-failed', 'detailReadFailed']]) {
      const message = i18n.translate(locale, key);
      assert.notEqual(message, key);
      assert.deepEqual(render({ detail: { found: false, error: code } }), [message]);
    }
    assert.deepEqual(render({ error: true }), [i18n.translate(locale, 'detailReadFailed')]);
    assert.deepEqual(render({ detail: { found: false } }), [i18n.translate(locale, 'detailNotFound')]);
    assert.deepEqual(render({ loading: true, detail: { error: 'line-too-large' } }), [i18n.translate(locale, 'detailLoading')]);
    assert.deepEqual(render({ detail: { found: true, exchanges: [] } }), [i18n.translate(locale, 'detailEmpty')]);
  }
});

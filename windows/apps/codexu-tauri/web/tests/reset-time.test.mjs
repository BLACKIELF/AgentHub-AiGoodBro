import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import ts from 'typescript';

async function load(name) {
  const source = await readFile(new URL(`../src/utils/${name}.ts`, import.meta.url), 'utf8');
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ES2020 } }).outputText;
  return import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
}
const { resetCountdown } = await load('resetTime');
const { parseNotices, sourceURL } = await load('publicFeeds');

test('countdown uses absolute time across missed ticks, clock changes and exact expiry', () => {
  assert.equal(resetCountdown(90061000, 0, 'forecast', true), '最晚还有 1 天 01:01:01');
  assert.equal(resetCountdown(3601000, 3600000, 'account', false), 'Resets in 00:00:01');
  assert.equal(resetCountdown(60001, 0, 'forecast', false), 'Due within 00:01:01');
  assert.match(resetCountdown(0, 0, 'forecast', true), /等待来源确认/);
  assert.match(resetCountdown(0, 1000, 'account', true), /等待额度更新/);
  assert.equal(resetCountdown(60000, -60000, 'account', false), 'Resets in 00:02:00');
  for (const value of [null, Infinity, NaN]) assert.equal(resetCountdown(value, 0, 'account', true), '重置时间未知');
});

test('publisher feed rejects invalid values and only returns active notices', () => {
  const now = Date.parse('2026-09-22T12:00:00Z');
  const message = { id: 'synthetic', title: 'Example', body: 'Synthetic notice', publishedAt: '2026-09-22T11:00:00Z', expiresAt: '2026-09-23T00:00:00Z', url: null };
  const feed = messages => JSON.stringify({ version: 1, messages });
  assert.equal(parseNotices(feed([message]), now, true).length, 1);
  assert.equal(parseNotices(feed([{ ...message, publishedAt: '2026-09-22T13:00:00Z' }]), now, true).length, 0);
  assert.equal(parseNotices(feed([{ ...message, expiresAt: '2026-09-22T11:30:00Z' }]), now, true).length, 0);
  assert.throws(() => parseNotices(feed([message, message]), now, true));
  assert.throws(() => parseNotices(feed([{ ...message, expiresAt: 'not-a-date' }]), now, true));
  assert.throws(() => parseNotices(feed([{ ...message, url: 'https://evil.example/' }]), now, true));
  for (const url of ['http://x.com/thsottiaux/status/1', 'https://user:secret@x.com/thsottiaux/status/1', 'https://x.com/thsottiaux/status/1?anything=yes']) assert.throws(() => sourceURL(url));
});

test('history retains verified provenance and never equates a notice with account reset', () => {
  const now = Date.parse('2026-09-22T12:00:00Z');
  const item = { id: '1234', reset_type: 'regular', announced_at: '2026-09-22T11:00:00Z', text: 'Public synthetic claim', source: { type: 'x_post', author: 'thsottiaux', url: 'https://x.com/thsottiaux/status/1234' } };
  const feed = data => JSON.stringify({ data, meta: { api_version: 'v1', generated_at: new Date(now).toISOString() } });
  assert.equal(parseNotices(feed([item]), now, false)[0].id, '1234');
  assert.throws(() => parseNotices(feed([{ ...item, source: { ...item.source, author: 'other' } }]), now, false));
  assert.throws(() => parseNotices(feed([{ ...item, announced_at: '2026-09-23T00:00:00Z' }]), now, false));
});

 test('unsafe absolute timestamps never become a confirmed reset', () => {
  assert.equal(resetCountdown(1e18, 1e18, 'account', false), 'Reset time unknown');
});

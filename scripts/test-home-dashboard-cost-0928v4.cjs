'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { explicitCost, graphCostEvidence, mergeGraphCostEvidence, collectHistoryPerTarget } =
  require('../Companion/TokenMonitorEngine/lib/collect.cjs');
const { computeCoverage } = require('../Companion/TokenMonitorEngine/lib/coverage.cjs');

assert.equal(explicitCost(0), 0);
assert.equal(explicitCost('$1.25'), 1.25);
assert.equal(explicitCost(null), null);
assert.equal(explicitCost(-1), null);
assert.equal(explicitCost(''), null);
assert.equal(explicitCost('$'), null);
assert.equal(explicitCost(' , '), null);

const first = { contributions: [
  { date: '2026-09-26', clients: [{ cost: 1.25 }, { tokens: { input: 100 } }] },
  { date: '2026-09-27', clients: [{ cost: 0 }] },
  { date: '2026-09-28', clients: [{ tokens: { input: 50 } }] }
] };
const second = { contributions: [
  { date: '2026-09-26', clients: [{ cost: 0.75 }] },
  { date: '2026-09-27', clients: [{ cost: 0 }] }
] };
assert.deepEqual(graphCostEvidence(first).get('2026-09-27'),
  { date: '2026-09-27', cost: 0, recorded: 1, missing: 0 });
const history = { daily: ['2026-09-26', '2026-09-27', '2026-09-28', '2026-09-29']
  .map(date => ({ date, tokens: 100, cost: 0 })) };
const result = mergeGraphCostEvidence([first, second], history);
assert.deepEqual(result.daily, [
  { date: '2026-09-26', cost: 2, status: 'partial' },
  { date: '2026-09-27', cost: 0, status: 'estimated' },
  { date: '2026-09-28', cost: null, status: 'unknown' },
  { date: '2026-09-29', cost: null, status: 'unknown' }
]);
assert.equal(result.totalCost, 2);
assert.equal(result.status, 'partial');
assert.equal(mergeGraphCostEvidence([second], {daily:history.daily.slice(1,2)}).status, 'estimated');
assert.equal(mergeGraphCostEvidence([second], {daily:history.daily.slice(0,3)}).status, 'partial');
assert.equal(mergeGraphCostEvidence([second], history, true).daily[1].status, 'partial');
assert.deepEqual(mergeGraphCostEvidence([], history), {
  daily: history.daily.map(day => ({ date: day.date, cost: null, status: 'unknown' })),
  totalCost: null, status: 'unknown'
});
assert.deepEqual(mergeGraphCostEvidence([], {daily:[{date:'2026-09-27',cost:2.5}],summary:{totalCost:2.5}}), {
  daily:[{date:'2026-09-27',cost:2.5,status:'partial'}], totalCost:2.5, status:'partial'
});
assert.equal(mergeGraphCostEvidence([second], {
  daily:history.daily.slice(0,2), monthly:[{month:'2026-08',tokens:100,cost:0}],
  summary:{totalCost:3}
}).status, 'partial');
assert.deepEqual(mergeGraphCostEvidence([second], {daily:[{date:'2026-09-27',cost:2}]}).daily,
  [{date:'2026-09-27',cost:2,status:'partial'}]);
const coverage = computeCoverage({
  sources: [{ id:'source', providerId:'codex', status:'ok', evidence:{
    historySucceeded:true, history:{daily:history.daily.map(day => ({...day,perClient:{codex:{tokens:day.tokens}}}))},
    costEstimates:graphCostEvidence(second), todayKey:'2026-09-29', scanSucceeded:true,
    clientStatus:{codex:'active'}, today:{clients:{codex:100},models:{priced:{}}},
    pricedModels:new Set(['priced'])
  } }],
  acceptedCustom:[], excludedCustom:[], history, limitsSnapshot:null,
  todayKey:'2026-09-29', timezone:'Asia/Shanghai', options:{}
});
const statuses = new Map(coverage.entries.filter(entry => entry.metric === 'cost').map(entry => [entry.date,entry.status]));
// Estimates are useful display evidence, not proof of verified model prices.
assert.equal(statuses.get('2026-09-27'), 'unknown');
assert.equal(statuses.get('2026-09-28'), 'unknown');
assert.equal(statuses.get('2026-09-29'), 'known');
assert.equal(coverage.cost, 'partial'); // Today's verified prices remain known; historical prices remain unknown.

(async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dashboard-cost-fixture-'));
  try {
    const target = {root, pathRole:'userHome', providerIds:['codex'], sourceIds:['source'], evidence:{}};
    const graph = {contributions:[{date:'2026-09-27',clients:[{cost:0}]}]};
    const upstream = {collector:{collectHistoryOnce:async options => {
      await options.runGraph({clients:'codex'});
      options.onHistoryStatus({successAt:'2026-09-28T00:00:00Z',failureCode:null});
      return {daily:[{date:'2026-09-27',tokens:10,cost:0,perClient:{codex:{tokens:10}}}]};
    }}};
    const errors = [];
    const result = await collectHistoryPerTarget(upstream, [target],
      {timezone:'Asia/Shanghai',options:{timeoutMs:20000}}, {runGraph:async () => graph},
      {checkAborted() {}}, '2026-09-28', errors);
    assert.deepEqual(errors, []);
    assert.deepEqual(result.costEstimates.daily,
      [{date:'2026-09-27',cost:0,status:'estimated'}]);
    assert.equal(target.evidence.costEstimates.get('2026-09-27').recorded, 1);
  } finally {
    fs.rmSync(root,{recursive:true,force:true});
  }
  console.log('Home dashboard cost projection passed: explicit zero, missing, partial, multi-graph aggregation and collector wiring.');
})().catch(error => { console.error(error); process.exitCode = 1; });

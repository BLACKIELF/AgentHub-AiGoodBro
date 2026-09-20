'use strict';
// Narrow DOM fixture: real vendor/adapter execution and event handlers, NOT a browser/layout test.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const resource = name => fs.readFileSync(path.join(root,'Resources/UpstreamCharts',name),'utf8');
class Element {
  constructor(attrs = {}) { this.attrs = attrs; this.hidden = false; this.value = ''; this.listeners = {}; this.children = []; this.style = {setProperty:(k,v) => { this.style[k] = v; }}; this.textContent = ''; this.classes = new Set(); this.classList = {add:x => this.classes.add(x)}; }
  set textContent(value) { this.text = value; this.children = []; }
  get textContent() { return this.text; }
  setAttribute(k,v) { this.attrs[k] = v; }
  getAttribute(k) { return this.attrs[k]; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener(k,f) { (this.listeners[k] ||= []).push(f); }
  fire(k,extra = {}) { for (const f of this.listeners[k] || []) f({preventDefault(){},...extra}); }
  appendChild(child) { this.children.push(child); }
  append(...children) { this.children.push(...children); }
  querySelector() { return null; } // Axis geometry is tested with a real browser.
  getBoundingClientRect() { return {left:0,top:0}; }
  get offsetWidth() { return 200; }
  get offsetHeight() { return 32; }
  set innerHTML(value) {
    this.html = value; this.children = [];
    // Only materialize SVG rect interaction targets emitted by the actual vendor.
    for (const tag of value.matchAll(/<rect\b([^>]*)>/g)) {
      const attrs = Object.fromEntries([...tag[1].matchAll(/([\w-]+)="([^"]*)"/g)].map(m => [m[1],m[2]]));
      this.children.push(new Element(attrs));
    }
  }
  get innerHTML() { return this.html; }
  querySelectorAll(selector) { const key = selector.slice(1,-1); return this.children.filter(x => x.attrs[key] !== undefined); }
}
const ids = Object.fromEntries(['context','charts','overview','trends','details','calendar','month','group','from','to','date','bars','legend','selection','dimensions','period','day-summary','day-total','day-tools','day-donut','hover-tooltip'].map(id => [id,new Element()]));
ids.group.value = 'client'; ids.period.value = 'day';
const tabs = ['overview','trends','details'].map(mode => new Element({'data-mode':mode}));
const document = {documentElement:{clientWidth:650,clientHeight:320},body:new Element(),querySelector:()=>new Element(),getElementById:id => ids[id], querySelectorAll:selector => selector === '[data-mode]' ? tabs : [], createElement:() => new Element(), createElementNS:() => new Element()};
const window = {};
const context = vm.createContext({window,document,Intl,Date,Map,Set,Number,Error,TextEncoder});
vm.runInContext(resource('usageCharts.js'),context);
vm.runInContext(resource('standalone.js'),context);
const vendorHash = crypto.createHash('sha256').update(resource('usageCharts.js')).digest('hex');
assert.equal(vendorHash,'9f7bb053c55afc080342820093b899c156d22754683afab0009fb0d7ee5f9441');
const hostile = '</script><script>window.pwned=1</script>"雪';
const fixture = {
  schemaVersion:1,collectedAt:'2026-09-12T16:30:00Z',timezone:'Asia/Shanghai',status:'ok',sources:[{coverage:'known'}],
  payload:{aggregate:{periods:{allTime:{totalTokens:123456}},history:{daily:[
    {date:'2026-09-11',tokens:90,perClient:{Codex:{tokens:60},Claude:{tokens:30}},perModel:{alpha:{tokens:20},beta:{tokens:30},[hostile]:{tokens:40}},sessions:{safe:{tokens:90}}},
    {date:'2026-09-12',tokens:0},
    {date:'2026-09-13',tokens:20,perModel:{alpha:{tokens:20}}}
  ]}},history:{daily:[{date:'2026-09-11',tokens:999999}]}},
  coverage:{days:[{date:'2026-09-11',status:'known'},{date:'2026-09-12',status:'known'},{date:'2026-09-13',status:'partial'}]}
};

const before = JSON.stringify(fixture);
const render = value => window.__renderTrend(value,{language:'en'});
const cell = key => ids.calendar.children.find(x => x.attrs['data-d'] === key);
const contents = el => el.textContent + el.children.map(contents).join(' ');
// Cost/coverage now live in Details. Inspect the real day pane, then restore its period.
const selectedDayDetails = () => {
  const period = ids.period.value;
  ids.period.value='day'; ids.period.fire('change');
  const text = contents(ids.dimensions);
  ids.period.value=period; ids.period.fire('change');
  return text;
};
render(fixture);
assert.equal(JSON.stringify(fixture),before);
assert.equal(ids.overview.hidden, false);
assert.equal(ids.trends.hidden, false, 'overview keeps bars visible in the split layout');
assert.equal(ids.details.hidden, true);
window.__renderTrend(fixture,{language:'en',from:'2026-09-12',to:'2026-09-13'});
assert.equal(ids.from.value,'2026-09-12');
assert.equal(ids.to.value,'2026-09-13');
assert(cell('2026-09-12'), 'selected window still includes recorded days');
assert.equal(cell('2026-09-11'), undefined, 'leading week padding must not expose out-of-range records');
cell('2026-09-13').fire('click');
window.__renderTrend(fixture,{language:'en',from:'2026-09-11',to:'2026-09-12'});
assert.equal(ids.date.value,'2026-09-12','selection follows the native window instead of retaining a hidden day');
ids.date.value='2026-09-13'; ids.date.fire('change');
assert.match(contents(ids.selection),/outside the selected range/);
assert.match(contents(ids['day-total']),/2026-09-12/,'rejected selection does not change day details');

// Size feedback must be independent of the old host viewport; it must shrink.
const sizes = [];
window.requestAnimationFrame = callback => callback();
window.webkit = {messageHandlers:{chartSize:{postMessage: value => sizes.push(value)}}};
document.documentElement.scrollHeight = 1400;
document.body.getBoundingClientRect = () => ({height:420});
document.body.scrollHeight = 1400;
window.__renderTrend(JSON.stringify(fixture),{snapshotID:'geometry:1',language:'en'});
assert.equal(sizes.at(-1).height,424,'size report excludes viewport-backed scrollHeight');
document.body.getBoundingClientRect = () => ({height:240});
tabs[1].fire('click');
assert.equal(sizes.at(-1).height,244,'switching to shorter content shrinks the host');
delete window.requestAnimationFrame; delete window.webkit;
console.log('PASS 0921v1 native range boundaries and grow/shrink size feedback (VM contract).');
render(fixture);
assert(!cell('2026-09-12').classes.has('unknown'));
assert(!cell('2026-09-13').classes.has('unknown'));
assert(cell('2026-09-10').classes.has('unknown'));
const globalPartial = JSON.parse(before); globalPartial.status='partial'; globalPartial.sources=[{coverage:'unknown',reasonCode:'UNKNOWN_COST'}]; globalPartial.coverage.cost='unknown';
render(globalPartial);
assert(!cell('2026-09-12').classes.has('unknown'),'global/source/cost partial cannot corrupt known zero');
cell('2026-09-12').fire('click');assert.match(selectedDayDetails(),/0 Token · known/);assert.match(selectedDayDetails(),/Cost \(USD\): Not provided/);
// Supplied output from the pinned original collector, not a replacement engine stub.
// Portable projection of the synthetic original collector response; values/period and day shapes preserved.
const enginePeriod = {"capabilities":{"tokenComponents":true,"throughput":true},"totalTokens":130,"costUsd":0,"cacheReadTokens":20,"cacheWriteTokens":0,"outputTokens":30,"unclassifiedTokens":0,"timedTokens":130,"timedOutputTokens":30,"timedDurationMs":1000,"clients":{"codex":130},"clientCosts":{},"clientCacheReads":{"codex":20},"clientCacheWrites":{},"clientOutputs":{"codex":30},"clientUnclassifiedTokens":{},"models":{"gpt-5.4":130},"modelCosts":{},"modelCacheReads":{"gpt-5.4":20},"modelCacheWrites":{},"modelOutputs":{"gpt-5.4":30},"modelUnclassifiedTokens":{},"clientModels":{"codex":{"gpt-5.4":130}},"clientModelCosts":{},"projects":{"opaque-244210e48437b6556980a702":{"label":"opaque-244210e48437b6556980a702","tokens":130,"costUsd":0,"clients":{"codex":130}}},"sessions":{"opaque-deb796c0ba7af201b9f3edbe":{"client":"codex","sessionId":"opaque-0a9099c0e3a5c4355f05a10c","totalTokens":130,"costUsd":0,"messageCount":1,"inputTokens":80,"outputTokens":30,"cacheReadTokens":20,"cacheWriteTokens":0,"reasoningTokens":0,"startedAt":"2026-09-12T16:00:00.000Z","lastUsedAt":"2026-09-13T00:00:02.000Z","projectId":"opaque-70a7729322b4764bb2d0ac22","projectLabel":"opaque-244210e48437b6556980a702","title":"opaque-e3b0c44298fc1c149afbf4c8","sessionKind":"","models":{"gpt-5.4":130},"modelCosts":{},"providers":{"openai":130}}}};
const engine = {schemaVersion:1,collectedAt:"2026-09-13T00:00:10Z",timezone:"Asia/Shanghai",status:"ok",coverage:{"entries":[{"sourceId":"managed-a","providerId":"codex","date":"2026-09-13","metric":"tokens","status":"known"},{"sourceId":"managed-a","providerId":"codex","date":"2026-09-13","metric":"cost","status":"unknown"},{"sourceId":"managed-a","providerId":"codex","date":"2026-09-13","metric":"quota","status":"unknown"}],"days":[{"date":"2026-09-13","status":"known"}],"cost":"unknown"},payload:{aggregate:Object.fromEntries(['today','month','allTime'].map(name=>[name,JSON.parse(JSON.stringify(enginePeriod))])),history:{daily:[{"date":"2026-09-13","tokens":130,"cost":0,"messages":1,"cacheReadTokens":20,"cacheWriteTokens":0,"outputTokens":30,"unclassifiedTokens":0,"tokenComponentsAvailable":true,"activeTimeMs":1000,"perClient":{"codex":{"tokens":130,"cost":0,"messages":1,"unclassifiedTokens":0,"cacheReadTokens":20,"outputTokens":30}},"perModel":{"gpt-5.4":{"tokens":130,"cost":0,"unclassifiedTokens":0,"cacheReadTokens":20,"outputTokens":30}},"tokenIntensity":4,"costIntensity":0,"intensity":0}]}}};
render(engine);cell('2026-09-13').fire('click');
assert(ids['day-tools'].children.some(child => child.className === 'tool-row'),'selected day renders real tool bars below the chart');
assert.equal(ids['day-donut'].children[0].attrs.role,'img','selected day renders an accessible composition chart');
assert.equal(ids['day-donut'].children[1].className,'day-legend','selected day renders a clear tool legend');
assert.match(selectedDayDetails(),/Cost \(USD\): Not provided/,'original engine unknown zero must be unavailable');
assert.match(selectedDayDetails(),/130 Token · known/);
for (const language of ['zh','en']) {
  const unavailable = language === 'en' ? /Cost \(USD\): Not provided/ : /费用（美元）: 未提供/;
  for (const coverage of [undefined,'unknown','known','partial']) for (const value of [0,2.5,null,undefined,'4',{},-1,Infinity,NaN]) {
    const x=JSON.parse(JSON.stringify(engine));x.coverage.cost=coverage;x.payload.history.daily[0].cost=value;
    window.__renderTrend(x,{language});cell('2026-09-13').fire('mouseenter');
    assert.match(ids['hover-tooltip'].textContent,/130 Token$/);
    cell('2026-09-13').fire('click');
    const valid=typeof value==='number' && Number.isFinite(value) && value>=0;
    const expected=!valid || !['known','partial'].includes(coverage) ? unavailable : coverage==='known' ? (language==='en' ? new RegExp('Cost \\(USD\\): '+value+' · known') : new RegExp('费用（美元）: '+value+' · 已确认')) : (language==='en' ? /Observed cost \(USD\): .*completeness unconfirmed/ : /已观察费用（美元）: .*完整性未确认/);
    assert.match(selectedDayDetails(),expected);assert(!cell('2026-09-13').classes.has('unknown'));
    cell('2026-09-13').fire('click');ids.period.value='day';ids.period.fire('change');assert.match(contents(ids.dimensions),expected);
  }
}
const missingCost=JSON.parse(JSON.stringify(engine));delete missingCost.coverage.cost;render(missingCost);cell('2026-09-13').fire('click');assert.match(selectedDayDetails(),/Cost \(USD\): Not provided/);
for (const period of ['today','month','allTime']) {
  render(engine);ids.period.value=period;ids.period.fire('change');
  assert.match(contents(ids.dimensions),/Cost \(USD\): Not provided/);assert.doesNotMatch(contents(ids.dimensions),/Cost \(USD\): 0/);assert.match(contents(ids.dimensions),/130/);
  const scoped=JSON.parse(JSON.stringify(engine));scoped.coverage.periods={[period]:{cost:'known'}};
  scoped.payload.aggregate[period].sessions[Object.keys(scoped.payload.aggregate[period].sessions)[0]].coverage={cost:'partial'};
  render(scoped);assert.match(contents(ids.dimensions),/Cost \(USD\): 0 · known/);assert.match(contents(ids.dimensions),/Observed cost \(USD\): 0 · completeness unconfirmed/);
}
const scopedDay=JSON.parse(JSON.stringify(engine));scopedDay.coverage.days[0].cost='known';render(scopedDay);cell('2026-09-13').fire('click');assert.match(selectedDayDetails(),/Cost \(USD\): 0 · known/);
scopedDay.payload.history.daily[0].coverage={cost:'unknown'};render(scopedDay);assert.match(selectedDayDetails(),/Cost \(USD\): Not provided/);
ids.period.value='day';
const observed=JSON.parse(before); observed.coverage.days[0].status='unknown';render(observed);cell('2026-09-11').fire('click');assert.match(selectedDayDetails(),/90 Token.*observed value, completeness unconfirmed/);assert.match(ids.month.textContent,/3\/13 days recorded/);
for(const value of [null,undefined,'4',-1,Infinity,NaN]) { const x=JSON.parse(before);x.payload.aggregate.history.daily[1].tokens=value;render(x);assert(cell('2026-09-12').classes.has('unknown'));cell('2026-09-12').fire('click');assert.match(selectedDayDetails(),/Tokens unavailable/); }
const mapped=JSON.parse(before);mapped.coverage.days={'2026-09-12':{status:'known'}};render(mapped);assert(!cell('2026-09-12').classes.has('unknown'));
const absent=JSON.parse(before);delete absent.coverage;render(absent);assert(!cell('2026-09-12').classes.has('unknown'),'recorded zero stays visible without completeness metadata');
const detailed=JSON.parse(before);detailed.payload.aggregate.periods.today={totalTokens:42,clients:{A:30,B:12},clientCosts:{A:0,B:null},models:{x:1,y:2,z:39},sessions:{s:{sessionId:'safe-id',totalTokens:42,title:'DO NOT RENDER'}},projects:{p:{label:'Project',tokens:42}}};render(detailed);ids.period.value='today';ids.period.fire('change');assert.match(contents(ids.dimensions),/safe-id/);assert.match(contents(ids.dimensions),/Project/);assert.doesNotMatch(contents(ids.dimensions),/DO NOT RENDER/);assert.match(contents(ids.dimensions),/42/);
assert.throws(()=>render({schemaVersion:2,payload:{}}));
// Same 16 MiB UTF-8 boundary as the native DTO/renderer; real dimensions make a valid >10 MB payload.
const maximumBytes=16*1024*1024;
const large=JSON.parse(JSON.stringify(engine));
for(let i=0;i<74000;i++)large.payload.aggregate.allTime.models['model-'+String(i).padStart(6,'0')+'-'+'x'.repeat(128)]=0;
const largeJSON=JSON.stringify(large);assert(Buffer.byteLength(largeJSON)>10085083 && Buffer.byteLength(largeJSON)<maximumBytes);
render(largeJSON);cell('2026-09-13').fire('click');assert.match(selectedDayDetails(),/130 Token · known/);
ids.period.value='allTime';ids.period.fire('change');assert.match(contents(ids.dimensions),/more entries omitted/);
vm.runInContext(`{
  const parse = JSON.parse, Encoder = TextEncoder;
  window.largeParses = 0; window.largeEncodes = 0;
  JSON.parse = function(value, ...args) { if (typeof value === 'string' && value.length > 1000000) window.largeParses++; return parse.call(this,value,...args); };
  TextEncoder = class extends Encoder { encode(value) { if (typeof value === 'string' && value.length > 1000000) window.largeEncodes++; return super.encode(value); } };
}`,context);
window.__renderTrend(largeJSON,{snapshotID:'realm:1',language:'en'});
for(let i=0;i<8;i++) window.__renderTrend(null,{snapshotID:'realm:1',width:500+i*35,height:260+i,language:i%2?'zh':'en',resetAnnotations:[{date:'2026-09-13',kind:'regular',text:'reset '+i}]});
assert.equal(window.largeParses,1);assert.equal(window.largeEncodes,1);
assert.doesNotMatch(selectedDayDetails() + ids['day-total'].textContent,/reset 7/,'reset content stays outside the Token panel');
window.__renderTrend(largeJSON+'\n',{snapshotID:'realm:2',language:'en'});
assert.equal(window.largeParses,2);assert.equal(window.largeEncodes,2);
assert.throws(()=>window.__renderTrend(null,{snapshotID:'realm:1',language:'en'}),/snapshot unavailable/);
assert.throws(()=>window.__renderTrend('{}',{snapshotID:'invalid',language:'en'}),/Invalid dashboard schema/);
assert.throws(()=>window.__renderTrend(null,{snapshotID:'invalid',language:'en'}),/snapshot unavailable/);
// Dense histories keep every data point, but only emit date ticks with room to read.
const dense = JSON.parse(JSON.stringify(fixture));
dense.payload.aggregate.history.daily = Array.from({length:120},(_,i)=>({date:new Date(Date.UTC(2026,4,1+i)).toISOString().slice(0,10),tokens:100000000+i*3137,perClient:{Codex:{tokens:100000000+i*3137}}}));
ids.group.value='client';ids.from.value='';ids.to.value='';
window.__renderTrend(dense,{language:'en',width:360});tabs[1].fire('click');
const xTicks = () => [...ids.bars.innerHTML.matchAll(/<text class="axis-label" x="([^"]+)"[^>]*>([^<]+)<\/text>/g)];
const narrowTicks=xTicks();assert(narrowTicks.length>=2 && narrowTicks.length<=5, JSON.stringify({ticks:narrowTicks.length,range:[ids.from.value,ids.to.value],bars:ids.bars.innerHTML.slice(0,240)}));
assert.equal(ids.bars.querySelectorAll('[data-i]').length,120,'tick sampling must retain every bar and tooltip target');
for(let i=1;i<narrowTicks.length;i++)assert(Number(narrowTicks[i][1])-Number(narrowTicks[i-1][1])>=60,'date labels must remain separated');
assert.match(ids.bars.innerHTML,/>[0-9.]+M<\/text>/,'large Y ticks use compact values');
ids.from.value='2026-06-01';ids.to.value='2026-07-31';ids.from.fire('change');
window.__renderTrend(dense,{language:'en',width:960});
assert.equal(ids.from.value,'2026-06-01');assert.equal(ids.to.value,'2026-07-31');
assert(xTicks().length>narrowTicks.length,'wide charts use the available width');
console.log('PASS dense trend ticks: all bars retained, readable compact axis labels, responsive width and date range persistence.');

const nextWindow={}, nextContext=vm.createContext({window:nextWindow,document,Intl,Date,Map,Set,Number,Error,TextEncoder});
vm.runInContext(resource('usageCharts.js'),nextContext);vm.runInContext(resource('standalone.js'),nextContext);
assert.throws(()=>nextWindow.__renderTrend(null,{snapshotID:'realm:2',language:'en'}),/snapshot unavailable/);
assert.ok(nextWindow.__renderTrend(largeJSON,{snapshotID:'next:1',language:'en'}).startsWith('<svg'));
console.log('PASS VM snapshot reuse: 10MB JSON parse/UTF-8 once across width/height/language/reset options; second snapshot twice; stale identity and fresh realm require installation.');
const baseJSON=JSON.stringify(engine);const exactLimit=baseJSON+' '.repeat(maximumBytes-Buffer.byteLength(baseJSON));
render(exactLimit);assert.throws(()=>render(exactLimit+' '),/Dashboard too large/);
const multibyteJSON=JSON.stringify({...engine,encodingProbe:'汉'.repeat(6000000)});
assert(multibyteJSON.length<maximumBytes && Buffer.byteLength(multibyteJSON)>maximumBytes);
assert.throws(()=>render(multibyteJSON),/Dashboard too large/);
ids.period.value='day';
const dup=JSON.parse(before);dup.payload.aggregate.history.daily.push(dup.payload.aggregate.history.daily[0]);assert.throws(()=>render(dup));
assert(window.__renderTrend([{date:'2026-09-12',tokens:0}],{height:40}).startsWith('<svg'));
console.log('PASS narrow VM: pinned vendor, immutable canonical input, known tokens independent of global/source/cost status, unknown observed values, true zero, null/string/nonfinite negatives, absent coverage, actual period dimensions, transcript exclusion, invalid schema/size/duplicates, legacy. NOT real DOM proof.');

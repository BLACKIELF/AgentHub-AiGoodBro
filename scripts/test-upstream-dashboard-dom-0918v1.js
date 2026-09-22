'use strict';
// Real-DOM acceptance for the CURRENT dashboard contract (0918).
// Supersedes test-upstream-dashboard-dom-0913v2.js (0913-era spec: status
// classes and reset annotations no longer exist in the web view; selection and
// tooltips carry the short description; the embedded home view lets the native
// period own the date window). Caller supplies Playwright via NODE_PATH.
const assert = require('node:assert/strict');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const {chromium} = require('playwright');
const root = path.resolve(__dirname,'..');
const hostile = '</script><script>window.pwned=1</script>"雪\u2028';
function period(n) { return {totalTokens:n, costUsd:null, outputTokens:0, clients:{Codex:n-10,Claude:10},clientCosts:{Codex:1,Claude:null},clientOutputs:{Codex:0},models:{alpha:1,beta:9,[hostile]:n-10},modelCosts:{alpha:0},sessions:{one:{client:'Codex',sessionId:'safe-session-1',totalTokens:n-3,costUsd:2,messageCount:4,models:{alpha:n-3},projectId:'p1',projectLabel:'Project one',title:'NEVER RENDER TRANSCRIPT TITLE'},two:{client:'Claude',sessionId:'safe-session-2',totalTokens:3}},projects:{p1:{label:'Project one',tokens:n-3,costUsd:2,clients:{Codex:n-3}},p2:{label:'Project two',tokens:3}},accounts:{'safe-account':{tokens:n,costUsd:null}}}; }
const fixture = {schemaVersion:1,collectedAt:'2026-09-13T00:00:00Z',timezone:'UTC',status:'partial',coverage:{cost:'unknown',days:[{date:'2026-09-10',status:'known'},{date:'2026-09-11',status:'unknown'},{date:'2026-09-12',status:'known'},{date:'2026-09-13',status:'known'}]},payload:{aggregate:{periods:{today:period(30),month:period(300),allTime:period(3000)},history:{daily:[{date:'2026-09-10',tokens:null},{date:'2026-09-11',tokens:90,perClient:{Codex:{tokens:60},Claude:{tokens:30}},perModel:{alpha:{tokens:20},beta:{tokens:30},[hostile]:{tokens:40}}},{date:'2026-09-12',tokens:0,cost:null,perClient:{Codex:{tokens:0}},perModel:{alpha:{tokens:0}}},{date:'2026-09-13',tokens:20,cost:null,perClient:{Codex:{tokens:20}},perModel:{alpha:{tokens:12},beta:{tokens:8}}}]}}}};
(async()=>{
  const browser = await chromium.launch();
  try {
    const context = await browser.newContext({viewport:{width:900,height:650}});
    const requests=[];
    await context.route(/^https?:/, route=>{requests.push(route.request().url()); return route.abort();});
    const page = await context.newPage(); const errors=[]; page.on('pageerror',e=>errors.push(e.message));
    await page.goto(pathToFileURL(path.join(root,'Resources/UpstreamCharts/standalone.html')).href);
    const render = (data,options) => page.evaluate(({data,options})=>{const before=typeof data==='string'?data.length:JSON.stringify(data); const result=window.__renderTrend(data,options??{}); if((typeof data==='string'?data.length:JSON.stringify(data))!==before) throw Error('Input mutated'); return result;},{data,options});
    const text = id => page.locator('#'+id).textContent();
    const cell = date => page.locator(`[data-d="${date}"]`);

    // ── 布局：宽屏概览同时显示日历和柱图；模式切换；窄屏与明细单列 ──
    await render(fixture);
    assert.equal(await page.locator('html').getAttribute('lang'),'zh');
    assert.equal(await page.getByRole('button',{name:'概览',exact:true}).getAttribute('aria-pressed'),'true');
    assert.equal(await page.locator('#overview').isVisible(),true);
    assert.equal(await page.locator('#trends').isVisible(),true,'宽屏概览同时显示日历和柱图');
    assert.equal(await page.evaluate(()=>getComputedStyle(document.getElementById('charts')).gridTemplateColumns.split(' ').length),2);
    await page.getByRole('button',{name:'明细',exact:true}).click();
    assert.equal(await page.locator('#overview').isVisible(),false);
    assert.equal(await page.locator('#details').isVisible(),true);
    assert.equal(await page.locator('#selection').isVisible(),false,'明细模式隐藏选中区');
    assert.equal(await page.evaluate(()=>getComputedStyle(document.getElementById('charts')).gridTemplateColumns.split(' ').length),1);
    await page.setViewportSize({width:700,height:650});
    await page.getByRole('button',{name:'概览',exact:true}).click();
    assert.equal(await page.evaluate(()=>getComputedStyle(document.getElementById('charts')).gridTemplateColumns.split(' ').length),1,'窄屏概览单列');
    await page.setViewportSize({width:900,height:650});

    // ── 嵌入模式：原生期间独占窗口，from/to 禁用；热图窗口化；累计不被裁剪 ──
    await render(fixture,{from:'2026-09-10',to:'2026-09-13'});
    assert.equal(await page.locator('#from').isDisabled(),true,'嵌入模式起始日期禁用');
    assert.equal(await page.locator('#to').isDisabled(),true,'嵌入模式结束日期禁用');
    assert.equal(await page.locator('#from').inputValue(),'2026-09-10');
    assert.equal(await page.locator('#to').inputValue(),'2026-09-13');
    const windowDates = await page.locator('[data-d]').evaluateAll(els=>els.map(e=>e.getAttribute('data-d')).sort());
    assert.equal(windowDates[windowDates.length-1],'2026-09-13','热图最后一天对齐窗口结束日');
    assert.ok(windowDates.includes('2026-09-10'),'窗口起始日在热图中');
    await page.getByRole('button',{name:'明细',exact:true}).click();
    await page.locator('#period').selectOption('allTime');
    assert.match(await text('dimensions'),/3,000/,'累计不被窗口裁剪');
    assert.match(await text('dimensions'),/safe-session-1/);
    assert.match(await text('dimensions'),/Project one/);
    assert.match(await text('dimensions'),/safe-account/);
    assert.doesNotMatch(await text('dimensions'),/999999|NEVER RENDER/,'会话标题等原始元数据不渲染');

    // ── 独立页：from/to 可用；图内日期只影响柱图，热图不重建 ──
    await render(fixture);
    assert.equal(await page.locator('#from').isDisabled(),false,'独立页起始日期可用');
    assert.equal(await page.locator('#to').isDisabled(),false,'独立页结束日期可用');
    const calendarBefore = await page.locator('#calendar').innerHTML();
    await page.getByRole('button',{name:'趋势',exact:true}).click();
    await page.locator('#group').selectOption('model');
    assert.ok((await text('legend')).includes(hostile),'宿主键作为文本出现在图例');
    assert.ok(await page.locator('#bars svg').count());
    await page.locator('#group').selectOption('client');
    await page.locator('#from').fill('2026-09-12'); await page.locator('#from').dispatchEvent('change');
    assert.equal(await page.locator('#calendar').innerHTML(),calendarBefore,'图内日期不重建热图');
    assert.match(await text('legend'),/2026-09-12 – 2026-09-13/,'柱图范围随图内日期变化');
    assert.ok(await page.locator('#bars svg').count());
    await page.locator('#to').fill('2026-09-09'); await page.locator('#to').dispatchEvent('change');
    assert.match(await text('bars'),/日期范围无效/);
    await page.locator('#to').fill('2026-09-13'); await page.locator('#to').dispatchEvent('change');

    // ── 指针与键盘：hover/focus 工具提示、点击选择、Enter 键选择 ──
    await page.getByRole('button',{name:'概览',exact:true}).click();
    await cell('2026-09-13').hover();
    assert.equal(await page.locator('#hover-tooltip').isHidden(),false,'hover 显示工具提示');
    assert.equal((await text('hover-tooltip')).trim(),'2026-09-13 · 20 Token');
    await cell('2026-09-11').focus();
    assert.equal((await text('hover-tooltip')).trim(),'2026-09-11 · 90 Token','focus 显示该日工具提示');
    await cell('2026-09-13').click();
    assert.equal((await text('selection')).trim(),'2026-09-13 · 20 Token','选中区为短描述，不带完整性文案');
    assert.equal(await cell('2026-09-13').getAttribute('aria-pressed'),'true');
    assert.match(await text('month'),/2026-09 · 110 Token · 3\/13 天有记录/);
    assert.equal(await cell('2026-09-13').getAttribute('aria-label'),'2026-09-13 · 20 Token');
    await cell('2026-09-10').focus(); await page.keyboard.press('Enter');
    assert.equal((await text('selection')).trim(),'2026-09-10 · 未采集','Enter 选择空数据日');
    await page.keyboard.press(' ');
    assert.equal((await text('selection')).trim(),'2026-09-10 · 未采集','空格同样选择');
    await page.getByRole('button',{name:'明细',exact:true}).click();
    await page.locator('#period').selectOption('day');
    assert.match(await text('dimensions'),/2026-09-10 · Token 未提供 · 完整性未确认/,'明细日行携带完整性文案');
    await page.locator('#date').fill('2026-09-14'); await page.locator('#date').dispatchEvent('change');
    assert.match(await text('selection'),/日期无效或晚于统计日期/);
    await page.locator('#date').evaluate(el=>{el.value='2026-02-30';el.dispatchEvent(new Event('change'));});
    assert.match(await text('selection'),/日期无效或晚于统计日期/);

    // ── 数据边界：未知不当 0；合法 0 保留；覆盖信息与展示状态分别判断 ──
    await render(fixture);
    await page.getByRole('button',{name:'概览',exact:true}).click();
    await cell('2026-09-13').click();
    assert.match(await text('selection'),/20 Token/);
    await cell('2026-09-12').click();
    assert.match(await text('selection'),/0 Token/,'合法零值保留');
    assert.doesNotMatch(await cell('2026-09-12').getAttribute('class'),/unknown/,'有记录零值不算未知');
    assert.match(await cell('2026-09-10').getAttribute('class'),/unknown/,'无记录日标为未知');
    for (const value of [null,'4',-1,Infinity,NaN]) {
      const malformed = structuredClone(fixture);
      malformed.payload.aggregate.history.daily[2].tokens = value;
      await render(malformed);
      assert.match(await cell('2026-09-12').getAttribute('class'),/unknown/,'畸形值按未知处理');
      assert.doesNotMatch(await cell('2026-09-12').getAttribute('class'),/partial/);
    }
    const noCoverage = structuredClone(fixture);
    delete noCoverage.coverage;
    await render(noCoverage);
    assert.doesNotMatch(await cell('2026-09-12').getAttribute('class'),/unknown/,'无覆盖信息时有记录零值仍可见');

    // ── 语言：zh/en 切换 ──
    await render(fixture,{language:'en'});
    assert.equal(await page.locator('html').getAttribute('lang'),'en');
    assert.ok(await page.getByRole('button',{name:'Details',exact:true}).count());
    await page.getByRole('button',{name:'Details',exact:true}).click();
    await page.locator('#period').selectOption('today');
    assert.match(await text('dimensions'),/Not provided/);
    assert.match(await text('dimensions'),/Cost \(USD\)/);
    await render(fixture);
    assert.equal(await page.locator('html').getAttribute('lang'),'zh');

    // ── 费用覆盖矩阵：仅费用证据适用；值有效性独立于覆盖判断（明细日行/期间行承载） ──
    const costCase = async (coverage, value, expected) => {
      const x = structuredClone(fixture);
      if (coverage === undefined) delete x.coverage.cost; else x.coverage.cost = coverage;
      x.coverage.days[3].cost = coverage;
      x.payload.aggregate.history.daily[3].cost = value;
      await render(x);
      await page.getByRole('button',{name:'明细',exact:true}).click();
      await page.locator('#period').selectOption('day');
      await page.locator('#date').fill('2026-09-13'); await page.locator('#date').dispatchEvent('change');
      assert.match(await text('dimensions'), expected);
    };
    await costCase('known', 2.5, /费用（美元）: 2\.5 · 已确认/);
    await costCase('partial', 2.5, /已观察费用（美元）: 2\.5 · 完整性未确认/);
    await costCase(undefined, 2.5, /费用（美元）: 未提供/);
    await costCase('known', null, /费用（美元）: 未提供/);
    await costCase('known', '4', /费用（美元）: 未提供/);
    await costCase('known', -1, /费用（美元）: 未提供/);
    await costCase('known', Infinity, /费用（美元）: 未提供/);
    const periodCost = structuredClone(fixture);
    periodCost.coverage.periods = {today:{cost:'known'}};
    periodCost.payload.aggregate.periods.today.costUsd = 2.5;
    await render(periodCost);
    await page.getByRole('button',{name:'明细',exact:true}).click();
    await page.locator('#period').selectOption('today');
    assert.match(await text('dimensions'),/费用（美元）: 2\.5 · 已确认/,'期间费用走 periods 覆盖');
    await render(fixture,{language:'en'});
    await page.getByRole('button',{name:'Details',exact:true}).click();
    await page.locator('#period').selectOption('today');
    assert.match(await text('dimensions'),/Cost \(USD\): Not provided/);

    // ── 安全与快照：转义、大小边界、快照协议、零网络 ──
    assert.equal(await page.evaluate(()=>window.pwned),undefined,'注入文本未执行');
    assert.deepEqual(errors,[],'无页面错误');
    assert.deepEqual(requests,[],'零 HTTP(S) 请求');
    assert.ok((await render([{date:'2026-09-12',tokens:0}])).startsWith('<svg'),'旧版数组仍可渲染');
    await render(fixture);

    const maximumBytes = 16*1024*1024;
    const large = structuredClone(fixture);
    for (let i=0;i<74000;i++) large.payload.aggregate.periods.allTime.models['model-'+String(i).padStart(6,'0')+'-'+'x'.repeat(128)] = 0;
    const largeJSON = JSON.stringify(large);
    assert(Buffer.byteLength(largeJSON) > 10085083 && Buffer.byteLength(largeJSON) < maximumBytes,'合成载荷超过 10MB 且低于上限');
    const countLargeParses = async () => page.evaluate(()=>{
      const parse = JSON.parse, Encoder = TextEncoder;
      window.largeParses = 0; window.largeEncodes = 0;
      JSON.parse = function(value,...args){ if (typeof value==='string' && value.length>1000000) window.largeParses++; return parse.call(this,value,...args); };
      window.TextEncoder = class extends Encoder { encode(value){ if (typeof value==='string' && value.length>1000000) window.largeEncodes++; return super.encode(value); } };
    });
    await countLargeParses();
    await page.evaluate(data=>window.__renderTrend(data,{snapshotID:'realm:1',language:'en'}),largeJSON);
    const reused = await page.evaluate(()=>{
      for (let i=0;i<8;i++) window.__renderTrend(null,{snapshotID:'realm:1',width:500+i*35,height:260+i,language:i%2?'zh':'en'});
      return [window.largeParses,window.largeEncodes];
    });
    assert.deepEqual(reused,[1,1],'快照复用只解析一次');
    await page.evaluate(data=>window.__renderTrend(data,{snapshotID:'realm:2',language:'en'}),largeJSON+'\n');
    assert.equal(await page.evaluate(()=>{try{window.__renderTrend(null,{snapshotID:'realm:1',language:'en'});return null;}catch(e){return e.message;}}),'Dashboard snapshot unavailable','旧快照被新快照替换后不可用');
    await page.reload();
    assert.equal(await page.evaluate(()=>{try{window.__renderTrend(null,{snapshotID:'realm:2',language:'en'});return null;}catch(e){return e.message;}}),'Dashboard snapshot unavailable','快照不跨刷新存活');
    await countLargeParses();
    await page.evaluate(data=>window.__renderTrend(data,{snapshotID:'next:1',language:'en'}),largeJSON+'\n');
    assert.deepEqual(await page.evaluate(()=>[window.largeParses,window.largeEncodes]),[1,1],'新快照重新解析一次');
    const baseJSON = JSON.stringify(fixture);
    const exactLimit = baseJSON + ' '.repeat(maximumBytes-Buffer.byteLength(baseJSON));
    await render(exactLimit,{language:'en'});
    for (const oversized of [exactLimit+' ', JSON.stringify({...fixture,encodingProbe:'汉'.repeat(6000000)})]) {
      const rejection = await page.evaluate(data=>{try{window.__renderTrend(data,{language:'en'});return null;}catch(e){return e.message;}},oversized);
      assert.equal(rejection,'Dashboard too large','超过 16 MiB 必须拒绝');
    }
    await render(fixture);
    console.log('PASS real Chromium DOM (0918 contract): overview layout modes, narrow/detail single column, native-owned date window with disabled filters, standalone local range affects bars only, hover/focus/click/Enter keyboard selection, short-description selection, details day line carries completeness, unknown-vs-zero boundaries, malformed values, zh/en, hostile escaping, >10MB snapshot reuse protocol, 16MiB boundary, zero HTTP and zero page errors.');
    await context.close();
  } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exitCode=1;});

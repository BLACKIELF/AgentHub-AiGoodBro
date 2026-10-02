'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {createHash} = require('node:crypto');
const {pathToFileURL} = require('node:url');
const {chromium} = require('playwright');
const root = path.resolve(__dirname, '..');
const assets = path.join(root, 'Resources/UpstreamCharts');
const manifest = JSON.parse(fs.readFileSync(path.join(assets, 'desktop/SOURCE.json')));
for (const [name, entry] of Object.entries(manifest.files)) {
  const copy = fs.readFileSync(path.join(assets, 'desktop', name));
  assert.equal(createHash('sha256').update(copy).digest('hex'), entry.sha256);
  assert.deepEqual(copy, fs.readFileSync(path.join(root, 'Companion/TokenMonitorEngine/upstream/src', entry.source)));
}
const tools = ['codex','zcode','workbuddy','grok','kimi','codebuddy','opencode','hermes','dsh','claude'];
const daily = Array.from({length:95}, (_,i) => {
  const tokens = Math.round((80 + Math.sin(i * .6) * 40 + i * 2) * 1000000);
  const client = tools[1 + i % 9];
  return {date:new Date(Date.UTC(2026,5,26+i)).toISOString().slice(0,10),tokens,cost:tokens / 10000000,
    perClient:{codex:{tokens:tokens*.8},[client]:{tokens:tokens*.2}},
    perModel:{'gpt-6-sol':{tokens:tokens*.6},'gpt-6-luna':{tokens:tokens*.4}}};
});
const fixture = {schemaVersion:1,collectedAt:'2026-09-28T10:00:00Z',timezone:'Asia/Shanghai',coverage:{cost:'known'},
  payload:{aggregate:{allTime:{costUsd:19732.09},history:{daily,summary:{totalTokens:21600123456,totalCost:16600.25,activeDays:95,currentStreak:95,
    activeTimeMs:4450800000,peakDayTokens:1200000000,favoriteModel:'gpt-6-sol',messages:164800}}}}};
(async () => {
  const browser = await chromium.launch({executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || undefined});
  try {
    const context = await browser.newContext({viewport:{width:1260,height:610},colorScheme:'dark',reducedMotion:'reduce'});
    const page = await context.newPage(); const errors = [], requests = [];
    page.on('pageerror', e => errors.push(e.message));
    await context.route(/^https?:/, route => { requests.push(route.request().url()); return route.abort(); });
    await page.addInitScript(() => { window.events = []; window.webkit = {messageHandlers:{
      chartPreferences:{postMessage:v => window.events.push(v)},chartSize:{postMessage:v => {window.lastSize = v;}}
    }}; });
    await page.goto(pathToFileURL(path.join(assets,'home-dashboard.html')).href);
    const render = (input, options = {}) => page.evaluate(({input,options}) => window.__renderTrend(input, options), {input,options:{snapshotID:'test:1',language:'zh',...options}});
    assert.ok((await render(fixture)).startsWith('<svg'));
    await page.waitForTimeout(60);
    assert.equal(await page.locator('#activityPane').isVisible(), true);
    assert.equal(await page.locator('#trendsPane').isVisible(), true);
    const columns = await page.locator('#homeDashboard').evaluate(el => getComputedStyle(el).gridTemplateColumns.split(' '));
    assert.equal(columns.length, 3);
    assert.equal(await page.locator('#dashSplitter').getAttribute('role'), 'separator');
    assert.equal(await page.locator('#dashSplitter').getAttribute('aria-valuenow'), '34');
    assert.equal(await page.locator('#heatmapStart').inputValue(), '2026-06-01');
    assert.equal(await page.locator('#dashCards .dash-card').count(), 8);
    const cardWidths = await page.locator('#dashCards .dash-card').evaluateAll(cards => cards.map(card => card.getBoundingClientRect().width));
    assert.ok(cardWidths[2] < cardWidths[0] * .55 && cardWidths[3] < cardWidths[5] * .55,
      'Day counters release width for token totals and peak-day values');
    assert.ok(await page.locator('#dashCards .dash-card').evaluateAll(cards => cards.every(card => card.scrollWidth <= card.clientWidth + 1)),
      'Compact day counters and exact totals fit without horizontal overflow');
    assert.equal(await page.locator('.dash-card-v').nth(0).textContent(), '21,600,123,456');
    assert.match(await page.locator('.dash-card-v').nth(1).textContent(), /19,?732\.09/);
    const autoWidths = () => page.locator('#dashCards .dash-card').evaluateAll(cards => cards.map(card => card.getBoundingClientRect().width));
    const shortNumbers = structuredClone(fixture);
    shortNumbers.payload.aggregate.history.summary.totalTokens = 12;
    shortNumbers.payload.aggregate.allTime.costUsd = 1;
    await render(shortNumbers, {homePreferences:{summaryWidths:{}}});
    const shortWidths = await autoWidths();
    await render(fixture, {homePreferences:{summaryWidths:{}}});
    const longWidths = await autoWidths();
    assert.ok(longWidths[0] > shortWidths[0]+30 && longWidths[1] > shortWidths[1]+30,
      'Long token totals and dual-currency amounts receive space according to their rendered content');
    assert.ok(longWidths[2] < shortWidths[2], 'Short counters release space as other numbers grow');
    await render(null);
    assert.deepEqual(await autoWidths(),longWidths,'Identical data keeps column positions stable');
    const costOnlyNodes = await page.evaluate(() => {
      window.costOnlyNodes = {heat:document.querySelector('#dashHeatmap svg'),chart:document.querySelector('#dashChart svg'),handle:document.querySelector('.summary-resize')};
      return true;
    });
    assert.equal(costOnlyNodes,true);
    for (const [value,status,label] of [[19733.1,'known','成本估算'],[19733.1,'partial','部分成本估算'],[null,'known','成本未记录'],[0,'known','成本估算']]) {
      await render(null,{summaryCost:{value,status}});
      const text = await page.locator('.dash-card-v').nth(1).textContent();
      const usd = value === 0 ? '$0.0000' : `$${value?.toFixed(2)}`;
      const cny = value == null ? null : '¥' + new Intl.NumberFormat('zh', {minimumFractionDigits:2,maximumFractionDigits:2}).format(value * 6.8);
      assert.equal(text,value == null ? '—' : `${usd} ${cny}`);
      assert.equal(await page.locator('.dash-cost-cny').count(), value == null ? 0 : 1,
        'Unknown cost clears the previous conversion; recorded zero retains a real zero');
      if (value != null) assert.match(await page.locator('.dash-card-v').nth(1).getAttribute('title'), /USD × 6\.8/);
      assert.equal(await page.locator('.dash-card-k').nth(1).textContent(),label);
      assert.equal(await page.evaluate(() => window.costOnlyNodes.heat===document.querySelector('#dashHeatmap svg')
        && window.costOnlyNodes.chart===document.querySelector('#dashChart svg')
        && window.costOnlyNodes.handle===document.querySelector('.summary-resize')),true,
        'Cost-only updates refresh the visible number without rebuilding charts or losing resize focus');
    }
    await render(null,{summaryCost:{value:19732.09,status:'known'}});
    assert.equal(await page.locator('.dash-card-v').nth(5).textContent(), '1,200,000,000');
    assert.equal(await page.locator('.dash-card-v').nth(7).textContent(), '164,800');
    // Every metric can change through its neighboring boundary, and widths
    // survive a native preference round-trip without rebuilding chart content.
    const beforeResize = await page.locator('#dashCards .dash-card').evaluateAll(cards => cards.map(card => card.getBoundingClientRect().width));
    const handle = page.locator('.summary-resize').nth(0);
    const bounds = await handle.boundingBox();
    await page.mouse.move(bounds.x+bounds.width/2,bounds.y+bounds.height/2);
    await page.mouse.down(); await page.mouse.move(bounds.x+bounds.width/2+50,bounds.y+bounds.height/2); await page.mouse.up();
    const afterResize = await page.locator('#dashCards .dash-card').evaluateAll(cards => cards.map(card => card.getBoundingClientRect().width));
    assert.ok(afterResize[0] > beforeResize[0]+40 && afterResize[1] < beforeResize[1]-40);
    const widths = await page.evaluate(() => window.events.at(-1).preferences.summaryWidths);
    assert.equal(Object.keys(widths).length,8);
    for (let index=1;index<7;index++) {
      await page.locator('.summary-resize').nth(index).focus(); await page.keyboard.press('ArrowRight');
    }
    const savedWidths = await page.evaluate(() => window.events.at(-1).preferences);
    await render(null,{homePreferences:savedWidths});
    assert.deepEqual(await page.evaluate(() => window.AiGoodBroDashboard.preferences.summaryWidths),savedWidths.summaryWidths);
    const manualWidths = await autoWidths();
    await render(null,{summaryCost:{value:1,status:'known'}});
    assert.deepEqual(await autoWidths(),manualWidths,'Manual column widths take precedence over changing numeric lengths');
    await render(null,{summaryCost:{value:19732.09,status:'known'}});
    await page.locator('.summary-resize').first().dblclick();
    assert.deepEqual(await page.evaluate(() => window.AiGoodBroDashboard.preferences.summaryWidths),{});
    const summaryLayout = await page.evaluate(() => {
      const cards = document.getElementById('dashCards').getBoundingClientRect();
      const left = document.getElementById('activityPane').getBoundingClientRect();
      const right = document.getElementById('trendsPane').getBoundingClientRect();
      return cards.bottom < left.top && cards.bottom < right.top
        && Math.abs(cards.left - left.left) < 1 && Math.abs(cards.right - right.right) < 1;
    });
    assert.ok(summaryLayout, 'Summary must span both panes above the calendar and trend');
    assert.equal(await page.locator('#breakdownDetails').evaluate(el => el.open), false);
    assert.equal(await page.locator('#dashBreakdown').isVisible(), false);
    await page.locator('#breakdownSummary').click();
    assert.equal(await page.locator('#dashBreakdown').isVisible(), true);
    await page.locator('#breakdownSummary').click();
    const compactGeometry = await page.evaluate(() => ({
      cells:Array.from(document.querySelectorAll('#dashHeatmap rect[data-d]'), el => el.getBoundingClientRect().width),
      calendarHeight:document.querySelector('#dashHeatmap svg').getBoundingClientRect().height,
      chartHeight:document.getElementById('dashChart').clientHeight,
      chartViewBox:document.querySelector('#dashChart svg').viewBox.baseVal.height
    }));
    assert.ok(compactGeometry.cells.length > 0);
    assert.ok(compactGeometry.cells.every(size => size > 0 && size <= 18.1), 'Calendar cells must remain compact');
    assert.ok(compactGeometry.calendarHeight <= 164, 'Calendar should fit seven compact rows');
    assert.equal(compactGeometry.chartHeight, 170);
    assert.equal(compactGeometry.chartViewBox, 170, 'Chart geometry must match its shorter viewport');
    const paneGeometry = await page.evaluate(() => ({
      calendar:document.getElementById('activityPane').clientWidth,
      heatmap:document.querySelector('#dashHeatmap svg').getBoundingClientRect().width,
      trend:document.getElementById('trendsPane').clientWidth
    }));
    assert.ok(paneGeometry.calendar - paneGeometry.heatmap < 24, 'Calendar pane must not reserve an empty half-window');
    assert.ok(paneGeometry.trend > paneGeometry.calendar * 1.2, 'Trend uses space released by the compact calendar');
    await page.locator('#dashSplitter').focus();
    await page.keyboard.press('ArrowRight');
    await page.waitForTimeout(20);
    assert.equal(await page.locator('#dashSplitter').getAttribute('aria-valuenow'), '38');
    assert.ok(await page.evaluate(() => window.events.some(event => event.preferences?.splitRatio === .38)), 'split ratio must persist through the native bridge');
    await page.setViewportSize({width:1260,height:301});
    await page.waitForTimeout(160);
    assert.ok(await page.locator('#homeDashboard').evaluate(el => el.scrollHeight <= el.clientHeight + 1),
      'Summary, calendar, chart, legend and collapsed details fit the compact desktop height');
    await page.setViewportSize({width:1260,height:610});
    await page.waitForTimeout(160);
    assert.ok(await page.locator('#dashChart .bar-seg').count() > 0);
    assert.ok(await page.locator('#dashChart .bar-seg').evaluateAll(els => els.some(el => el.getAttribute('fill') === '#3492ce')));
    await page.evaluate(() => {
      window.renderCounts = {heat:0,chart:0};
      for (const [id,key] of [['dashHeatmap','heat'],['dashChart','chart']]) {
        new MutationObserver(records => {
          if (records.some(record => record.type === 'childList' && (record.addedNodes.length || record.removedNodes.length))) window.renderCounts[key]++;
        }).observe(document.getElementById(id), {childList:true});
      }
    });
    const counts = () => page.evaluate(() => ({...window.renderCounts}));
    const beforeHeightDrag = await counts();
    for (const height of [580,540,500,460,420,380,340,300,260,300,340,380,420,460,500,540,580,610]) {
      await page.setViewportSize({width:1260,height});
      await page.waitForTimeout(135);
      assert.equal(await page.locator('#homeDashboard').evaluate(el => el.scrollTop), 0,
        'Resizing height from the top must not jump the dashboard scroll position');
    }
    assert.deepEqual(await counts(), beforeHeightDrag, 'Height-only resizing must retain both chart DOM trees');
    const beforeRepeat = await counts();
    await page.locator('[data-mode="bars"]').click();
    assert.deepEqual(await counts(), beforeRepeat);
    const bars30 = await page.locator('#dashChart .bar-hover').count();
    await page.locator('#rangeSelect [data-val="7"]').click();
    await page.waitForTimeout(50);
    assert.equal(await page.locator('#dashChart .bar-hover').count(), 7);
    assert.ok(bars30 > 7);
    const heatBeforeMode = await counts();
    await page.locator('[data-mode="kline"]').click();
    await page.waitForTimeout(50);
    assert.ok(await page.locator('.candle-body').count() > 0);
    assert.equal((await counts()).heat, heatBeforeMode.heat);
    assert.equal(await page.locator('[data-control="stack"]').isVisible(), false);
    await page.locator('#dashChart .bar-hover').first().hover();
    await page.waitForTimeout(20);
    assert.match(await page.locator('#dashTooltip').textContent(), /O.*H.*L.*C/);
    await page.locator('[data-mode="bars"]').click();
    await page.locator('[data-stack="model"]').click();
    await page.waitForTimeout(50);
    assert.match(await page.locator('#dashLegend').textContent(), /gpt-6-sol/);
    await page.locator('#heatmapStart').fill('2026-08-01');
    await page.locator('#heatmapStart').dispatchEvent('change');
    assert.equal(await page.locator('#heatmapStart').inputValue(),'2026-08-01');
    assert.equal(await page.locator('#dashHeatmap [data-d="2026-06-01"]').count(), 0);
    assert.ok(await page.evaluate(() => Math.abs(document.getElementById('dashChart').clientWidth
      - document.querySelector('#dashChart svg').viewBox.baseVal.width) < 1),
      'Changing calendar dates resizes the neighboring chart geometry');
    const saved = await page.evaluate(() => window.events.at(-1).preferences);
    assert.equal(saved.heatmapStart,'2026-08-01'); assert.equal(saved.mode,'bars'); assert.equal(saved.stackBy,'model'); assert.equal(saved.height,340);
    await render(null,{homePreferences:saved});
    assert.equal(await page.locator('#heatmapStart').inputValue(),'2026-08-01');
    await page.locator('#heatmapStartReset').click();
    assert.equal(await page.locator('#heatmapStart').inputValue(),'2026-06-01');
    await page.locator('[data-control="heatmapMetric"] [data-val="tokens"]').click();
    await page.waitForTimeout(50);
    assert.equal(await page.locator('[data-val="tokens"]').getAttribute('aria-pressed'),'true');
    const chartBeforeMetric = await counts();
    await page.locator('[data-control="heatmapMetric"] [data-val="cost"]').click();
    assert.equal((await counts()).chart, chartBeforeMetric.chart);
    const metricRepeat = await counts();
    await page.locator('[data-control="heatmapMetric"] [data-val="cost"]').click();
    assert.deepEqual(await counts(), metricRepeat);
    await page.locator('[data-control="heatmapMetric"] [data-val="cost"]').focus();
    await page.keyboard.press('ArrowLeft');
    assert.equal(await page.locator('[data-val="tokens"]').getAttribute('aria-pressed'), 'true');
    assert.equal(await page.evaluate(() => document.activeElement.dataset.val), 'tokens');
    assert.equal((await counts()).chart, metricRepeat.chart, 'Keyboard metric change retains trend DOM');
    await page.keyboard.press('End');
    assert.equal(await page.locator('[data-val="cost"]').getAttribute('aria-pressed'), 'true');
    assert.equal(await page.locator('[data-val="cost"]').evaluate(el => getComputedStyle(el).transitionDuration), '0s');
    await page.locator('[data-mode="bars"]').focus();
    await page.keyboard.press('ArrowRight');
    assert.ok(await page.locator('.candle-body').count() > 0);
    await page.keyboard.press('Home');
    assert.ok(await page.locator('#dashChart .bar-seg').count() > 0);
    const estimated = structuredClone(fixture); estimated.coverage.cost = 'partial';
    estimated.payload.costEstimates = {status:'partial',totalCost:17.25,daily:daily.map((row,i) =>
      ({date:row.date,cost:i === 0 ? 0 : i === 1 ? null : i === 2 ? 1.75 : row.cost,
        status:i === 1 ? 'unknown' : i === 2 ? 'partial' : 'estimated'}))};
    await render(estimated);
    assert.notEqual(await page.locator('.dash-card-v').nth(1).textContent(),'—');
    assert.match(await page.locator('.dash-card-k').nth(1).textContent(), /成本估算/);
    const projected = await page.evaluate(() => [
      window.AiGoodBroDashboard.rawDaily.get('2026-06-26'),
      window.AiGoodBroDashboard.rawDaily.get('2026-06-27'),
      window.AiGoodBroDashboard.rawDaily.get('2026-06-28')
    ].map(row => ({cost:row.cost,status:row.costStatus})));
    assert.deepEqual(projected,[{cost:0,status:'estimated'},{cost:null,status:'unknown'},{cost:1.75,status:'partial'}]);
    await page.locator('#dashHeatmap [data-d="2026-06-26"]').hover();
    assert.match(await page.locator('#dashTooltip').textContent(), /成本估算.*0/);
    await page.locator('#dashHeatmap [data-d="2026-06-28"]').hover();
    assert.match(await page.locator('#dashTooltip').textContent(), /部分成本估算/);
    const legacyEstimate = structuredClone(fixture); legacyEstimate.coverage.cost = 'unknown';
    legacyEstimate.payload.aggregate.history.daily[0].cost = 0;
    await render(legacyEstimate);
    assert.equal(await page.evaluate(() => window.AiGoodBroDashboard.rawDaily.get('2026-06-26').cost), null);
    assert.ok(await page.evaluate(() => window.AiGoodBroDashboard.rawDaily.get('2026-06-27').cost) > 0);
    assert.equal(await page.locator('.dash-card-v').nth(1).textContent(),'—');
    const unknown = structuredClone(fixture); unknown.coverage.cost = 'unknown'; delete unknown.payload.aggregate.history.summary.messages;
    unknown.payload.costEstimates = {status:'unknown',totalCost:null,daily:daily.map(row => ({date:row.date,cost:null,status:'unknown'}))};
    await render(unknown);
    assert.equal(await page.locator('.dash-card-v').nth(1).textContent(),'—');
    assert.match(await page.locator('.dash-card-k').nth(1).textContent(), /未记录/);
    assert.equal(await page.locator('.dash-card-v').nth(7).textContent(),'—');
    await page.locator('#dashHeatmap [data-d="2026-06-01"]').hover();
    assert.match(await page.locator('#dashTooltip').textContent(), /未记录/);
    await render(fixture,{language:'en'});
    assert.equal(await page.locator('#heatmapStartLabel').textContent(),'Start date');
    assert.equal(await page.locator('#breakdownSummary').textContent(),'By model / By tool');
    assert.equal(await page.locator('html').getAttribute('lang'),'en');
    const output = process.env.AIGOODBRO_DASHBOARD_QA_OUTPUT || path.join(root,'.local-artifacts/local-proxy-0928v1/split-dashboard'); fs.mkdirSync(output,{recursive:true});
    await render(fixture,{homePreferences:{heatmapStart:'',heatmapMetric:'tokens',range:'30',mode:'bars',stackBy:'client'}});
    await page.evaluate(() => { document.documentElement.style.background = 'linear-gradient(130deg,#394452,#353943 60%,#2f485a)'; document.body.style.padding='14px'; });
    await page.waitForTimeout(100);
    await page.screenshot({path:path.join(output,'overview-bars-zh.png'),fullPage:true});
    await page.locator('[data-mode="kline"]').click(); await page.waitForTimeout(80);
    await page.screenshot({path:path.join(output,'overview-kline-zh.png'),fullPage:true});
    await page.setViewportSize({width:700,height:1000}); await page.waitForTimeout(180);
    assert.equal(await page.locator('#homeDashboard').evaluate(el => getComputedStyle(el).gridTemplateColumns.split(' ').length),1);
    assert.ok(await page.evaluate(() => document.body.scrollWidth <= innerWidth + 1));
    assert.ok(await page.locator('#dashCards .dash-card').evaluateAll(cards => cards.every(card => card.scrollWidth <= card.clientWidth+1)));
    await page.screenshot({path:path.join(output,'overview-narrow-summary-zh.png'),fullPage:true});
    await page.setViewportSize({width:700,height:340}); await page.waitForTimeout(180);
    await page.locator('#breakdownSummary').click();
    const narrowBounds = await page.evaluate(() => {
      const overview = document.getElementById('activityPane');
      const bottom = Math.max(overview.getBoundingClientRect().bottom,
        ...Array.from(overview.children, child => child.getBoundingClientRect().bottom));
      return {overviewBottom:bottom, trendsTop:document.getElementById('trendsPane').getBoundingClientRect().top};
    });
    assert.ok(narrowBounds.trendsTop >= narrowBounds.overviewBottom,
      `Narrow dashboard panes overlap: ${JSON.stringify(narrowBounds)}`);
    const scrolling = await page.locator('#homeDashboard').evaluate(el => ({height:el.clientHeight,content:el.scrollHeight}));
    assert.ok(scrolling.content > scrolling.height);
    await page.locator('#homeDashboard').focus();
    await page.keyboard.press('PageDown');
    await page.waitForFunction(() => document.getElementById('homeDashboard').scrollTop > 0);
    assert.ok(await page.locator('#homeDashboard').evaluate(el => el.scrollTop) > 0);
    await page.screenshot({path:path.join(output,'overview-narrow-zh.png'),fullPage:true});
    assert.deepEqual(errors,[]); assert.deepEqual(requests,[]);
    console.log('Home dashboard passed: measured numeric widths, fixed USD/CNY conversion, manual-width persistence, unknown/partial/zero, unchanged upstream assets, 8 KPIs, charts, bilingual and narrow layouts; no network requests.');
  } finally {await browser.close();}
})().catch(error => {console.error(error);process.exitCode = 1;});

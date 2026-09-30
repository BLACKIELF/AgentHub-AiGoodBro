'use strict';
// Host adapter for the byte-identical Token Monitor dashboard controller.
// The upstream chart builders, OHLC buckets, animation and controls are reused.
const home = window.AiGoodBroDashboard;
const dateKey = value => typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value)
  && Number.isFinite(Date.parse(value + 'T00:00:00Z'))
  && new Date(value + 'T00:00:00Z').toISOString().slice(0, 10) === value;
const presentNumber = value => typeof value === 'number' && Number.isFinite(value) && value >= 0;
const fullNumber = value => new Intl.NumberFormat(state.locale, {maximumFractionDigits:20}).format(value);
const splitBounds = Object.freeze({min:0.28, max:0.72, default:0.34});
const safeSplitRatio = value => Number.isFinite(Number(value))
  ? Math.min(splitBounds.max, Math.max(splitBounds.min, Number(value))) : splitBounds.default;
const juneStart = end => `${Number(end.slice(0, 4)) - (end.slice(5, 10) < '06-01' ? 1 : 0)}-06-01`;
const currentStart = () => dateKey(home.preferences.heatmapStart)
  ? (home.preferences.heatmapStart > home.end ? home.end : home.preferences.heatmapStart) : juneStart(home.end);
const toolPalette = Object.freeze({codex:'#3492ce',zcode:'#8c2ed1',workbuddy:'#cf2d79',grok:'#d6b72b',
  kimi:'#44cf2a',codebuddy:'#29c7c9',opencode:'#4531d7',hermes:'#d52caa',dsh:'#d96b2e',claude:'#8cd32a'});
const originalHeatmap = charts.contribHeatmap;
charts.contribHeatmap = (daily, options) => {
  const adapted = {...options, gap:2, startDate:currentStart(), endDate:home.end};
  const heat = originalHeatmap(daily, adapted);
  const dashboard = document.getElementById('homeDashboard');
  const available = document.getElementById('dashHeatmap').clientWidth;
  if (!heat.weeks || !available) return heat;
  // Keep a compact seven-row calendar even for a short custom date range.
  const cell = Math.max(2, Math.min(18, (available - (heat.weeks - 1) * adapted.gap) / heat.weeks));
  return originalHeatmap(daily, {...adapted, cell});
};
todayKey = () => home.end || charts.localDayKey();
const upstreamColorFor = colorFor;
colorFor = key => state.stackBy === 'client' && toolPalette[key.toLowerCase()]
  ? toolPalette[key.toLowerCase()] : upstreamColorFor(key);
// The host owns the full-width summary strip and its responsive column count.
balanceStatCards = () => {};
// The embedded trend is shorter than the standalone window's 200px minimum.
chartSize = () => ({w:Math.max(1, els.chart.clientWidth), h:Math.max(1, els.chart.clientHeight)});

let sizeQueued = false;
let lastReportedSize = '';
function reportHomeSize() {
  if (sizeQueued) return;
  sizeQueued = true;
  requestAnimationFrame(() => {
    sizeQueued = false;
    if (!home.snapshotID) return;
    const width = window.innerWidth, height = Math.ceil(document.body.getBoundingClientRect().height) + 4;
    const size = `${home.snapshotID}:${width}:${height}`;
    if (size === lastReportedSize) return;
    lastReportedSize = size;
    window.webkit?.messageHandlers?.chartSize?.postMessage({snapshotID:home.snapshotID,
      width, height});
  });
}
function savePreferences(patch = {}) {
  const next = {...home.preferences, range:state.range, mode:state.mode,
    stackBy:state.stackBy, heatmapMetric:state.heatmapMetric, splitRatio:safeSplitRatio(home.preferences.splitRatio), ...patch};
  next.splitRatio = safeSplitRatio(next.splitRatio);
  if (JSON.stringify(next) === JSON.stringify(home.preferences)) return;
  home.preferences = next;
  window.webkit?.messageHandlers?.chartPreferences?.postMessage({snapshotID:home.snapshotID, preferences:home.preferences});
  syncActivityTrack();
}
home.save = savePreferences;

function tooltipRow(parent, name, value, color) {
  const row = document.createElement('div'); row.className = 'tt-row';
  if (color) { const dot = document.createElement('span'); dot.className = 'tt-dot'; dot.style.background = color; row.append(dot); }
  const label = document.createElement('span'); label.className = 'tt-name'; label.textContent = name;
  const count = document.createElement('span'); count.className = 'tt-val'; count.textContent = value;
  row.append(label, count); parent.append(row);
}
function tooltipHeading(text) {
  els.tooltip.replaceChildren();
  const heading = document.createElement('div'); heading.className = 'tt-head'; heading.textContent = text; els.tooltip.append(heading);
}
// Use text nodes for external model/tool labels in the two upstream paths that
// interpolate HTML. Other upstream SVG/card paths already escape their labels.
renderLegend = model => {
  const totals = new Map();
  for (const bar of model.bars) for (const s of bar.segments) totals.set(s.key, (totals.get(s.key) || 0) + s.value);
  const grand = [...totals.values()].reduce((a, b) => a + b, 0) || 1;
  els.legend.replaceChildren();
  for (const [key, value] of [...totals].filter(([,v]) => v > 0).sort((a,b) => b[1] - a[1])) {
    const row = document.createElement('div'); row.className = 'dash-legend-row';
    const swatch = document.createElement('span'); swatch.className = 'dash-legend-swatch'; swatch.style.background = colorFor(key);
    const name = document.createElement('span'); name.className = 'dash-legend-name'; name.textContent = key; name.style.color = colorFor(key);
    row.title = `${key}: ${fullNumber(value)} · ${(value / grand * 100).toFixed(1)}%`;
    row.append(swatch, name); els.legend.append(row);
  }
};
showBarTooltip = (bar, ev) => {
  tooltipHeading(`${shortDate(bar.label)} · ${fullNumber(bar.total)}`);
  for (const s of [...bar.segments].filter(s => s.value > 0).sort((a,b) => b.value - a.value)) {
    tooltipRow(els.tooltip, s.key, fullNumber(s.value), colorFor(s.key));
  }
  positionTooltip(ev);
};
showHeatTooltip = (date, _day, ev) => {
  const day = home.rawDaily.get(date);
  tooltipHeading(longDate(date));
  tooltipRow(els.tooltip, 'Tokens', presentNumber(day?.tokens) ? fullNumber(day.tokens) : (state.locale.startsWith('zh') ? '未记录' : 'Not recorded'));
  const partial = day?.costStatus === 'partial';
  tooltipRow(els.tooltip, state.locale.startsWith('zh')
    ? (partial ? '部分成本估算' : '成本估算') : (partial ? 'Partial cost estimate' : 'Cost estimate'),
    presentNumber(day?.cost) ? formatCost(day.cost) : (state.locale.startsWith('zh') ? '未记录' : 'Not recorded'));
  positionTooltip(ev);
};
let lastActivityKey = '', lastTrendKey = '';
renderNow = () => {
  if (!home.ready) return;
  hideTooltip();
  // The host shows both panes. Switching a control must not replay the
  // upstream entry animation or replace the unaffected pane's SVG.
  state.motion = 'none';
  els.activityPane.classList.remove('hidden'); els.trendsPane.classList.remove('hidden');
  els.empty.classList.toggle('hidden', (state.history?.daily || []).length > 0);
  els.modeBtns.forEach(b => {const selected = b.dataset.mode === state.mode; b.classList.toggle('active', selected); b.setAttribute('aria-pressed', selected);});
  els.stackBtns.forEach(b => {const selected = b.dataset.stack === state.stackBy; b.classList.toggle('active', selected); b.setAttribute('aria-pressed', selected);});
  els.heatmapMetricBtns.forEach(b => {const selected = b.dataset.val === state.heatmapMetric; b.classList.toggle('active', selected); b.setAttribute('aria-pressed', selected);});
  document.querySelector('[data-control="stack"]').style.display = state.mode === 'kline' ? 'none' : '';
  const activityKey = [home.revision, state.heatmapMetric, currentStart(), state.locale,
    window.innerWidth, els.activityPane.clientWidth].join(':');
  if (activityKey !== lastActivityKey) {
    renderActivity(); lastActivityKey = activityKey;
    // Unknown summary fields stay unknown instead of inheriting upstream n(null)=0.
    const cards = charts.statsCards(state.history?.summary || {});
    els.cards.querySelectorAll('.dash-card').forEach((card, index) => {
      const key = cards[index]?.key, raw = state.history?.summary?.[key];
      const value = card.querySelector('.dash-card-v');
      if (value) {
        if (raw == null || (key !== 'favoriteModel' && !presentNumber(raw))) value.textContent = '—';
        else if (key === 'totalCost') value.textContent = formatCost(raw);
        else if (key !== 'favoriteModel' && key !== 'activeTimeMs') value.textContent = fullNumber(raw);
      }
      if (value) value.title = value.textContent;
      if (key === 'totalCost') {
        const zh = state.locale.startsWith('zh');
        card.querySelector('.dash-card-k').textContent = home.totalCostStatus === 'unknown'
          ? (zh ? '成本未记录' : 'Cost not recorded')
          : home.totalCostStatus === 'partial'
            ? (zh ? '部分成本估算' : 'Partial cost estimate')
            : (zh ? '已记录成本估算' : 'Recorded cost estimate');
        if (value) value.title = home.totalCostStatus === 'unknown'
          ? (zh ? '未记录可确认的成本' : 'No recorded cost estimate')
          : home.totalCostStatus === 'partial'
            ? (zh ? '部分记录的估算值，非实际账单' : 'Partial recorded estimate, not a bill')
            : (zh ? '估算值，非实际账单' : 'Estimate, not a bill');
      }
    });
  }
  const start = document.getElementById('heatmapStart'); start.value = currentStart(); start.max = home.end;
  const zh = state.locale.startsWith('zh');
  els.cards.setAttribute('aria-label', zh ? '用量总览' : 'Usage summary');
  document.getElementById('heatmapStartLabel').textContent = zh ? '开始日期' : 'Start date';
  document.getElementById('heatmapStartReset').textContent = zh ? '默认' : 'Default';
  document.getElementById('heatmapStartReset').title = zh ? '从最近的 6 月 1 日开始' : 'Start from the most recent June 1';
  document.getElementById('breakdownSummary').textContent = zh ? '按模型 / 按工具' : 'By model / By tool';
  const trendKey = [home.revision, state.range, state.mode, state.stackBy, state.locale, els.chart.clientWidth].join(':');
  if (trendKey !== lastTrendKey) { renderTrends(); lastTrendKey = trendKey; }
  syncActivityTrack();
  reportHomeSize();
};
home.render = renderNow;

window.__renderTrend = (input, options = {}) => {
  if (input != null) {
    const data = typeof input === 'string' ? JSON.parse(input) : input;
    if (data?.schemaVersion !== 1 || !data.payload) throw Error('Invalid dashboard snapshot');
    const aggregate = data.payload.aggregate || data.payload.usage || {};
    const original = aggregate.history || data.payload.history || data.payload.usage?.history || {};
    if (original.daily != null && !Array.isArray(original.daily)) throw Error('Invalid daily history');
    if ((original.daily || []).length > 10000) throw Error('History too large');
    const projection = data.payload.costEstimates;
    const estimates = new Map(Array.isArray(projection?.daily)
      ? projection.daily.filter(row => dateKey(row?.date)).map(row => [row.date, row]) : []);
    const dates = new Set();
    const daily = (original.daily || []).filter(row => row && dateKey(row.date)).map(row => {
      if (dates.has(row.date)) throw Error('Duplicate daily history'); dates.add(row.date);
      const recorded = estimates.get(row.date);
      if (projection) return {...row, cost:presentNumber(recorded?.cost) && ['estimated','partial'].includes(recorded.status) ? recorded.cost : null,
        costStatus:recorded?.status || 'unknown'};
      // Older engine snapshots have no raw graph provenance. A positive cost
      // still proves an estimate was recorded; a normalized zero does not.
      const usable = presentNumber(row.cost) && (row.cost > 0 || ['known','partial'].includes(data.coverage?.cost));
      return {...row, cost:usable ? row.cost : null, costStatus:usable ? 'partial' : 'unknown'};
    }).sort((a,b) => a.date.localeCompare(b.date));
    home.input = data;
    home.revision = (home.revision || 0) + 1;
    home.rawDaily = new Map(daily.map(row => [row.date, row]));
    home.history = {...original, daily:daily.filter(row => presentNumber(row.tokens)), summary:{...original.summary}};
    const fallbackTotal = original.summary?.totalCost;
    const fallbackUsable = presentNumber(fallbackTotal)
      && (fallbackTotal > 0 || ['known','partial'].includes(data.coverage?.cost));
    home.history.summary.totalCost = projection
      ? presentNumber(projection.totalCost) && ['estimated','partial'].includes(projection.status) ? projection.totalCost : null
      : fallbackUsable ? fallbackTotal : null;
    home.totalCostStatus = projection?.status || (fallbackUsable ? 'partial' : 'unknown');
    let end = aggregate.periodWindows?.today?.key;
    if (!dateKey(end) && data.collectedAt && data.timezone) {
      const parts = new Intl.DateTimeFormat('en-US', {timeZone:data.timezone,year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date(data.collectedAt));
      const get = type => parts.find(p => p.type === type)?.value;
      end = `${get('year')}-${get('month')}-${get('day')}`;
    }
    home.end = dateKey(end) ? end : daily.at(-1)?.date || charts.localDayKey();
  }
  if (!home.input) throw Error('Missing dashboard snapshot');
  home.snapshotID = options.snapshotID || home.snapshotID;
  const p = options.homePreferences || home.preferences;
  home.preferences = {heatmapStart:dateKey(p.heatmapStart) ? p.heatmapStart : '',
    heatmapMetric:['cost','tokens'].includes(p.heatmapMetric) ? p.heatmapMetric : 'cost',
    range:RANGES.includes(p.range) ? p.range : '30', mode:['bars','kline'].includes(p.mode) ? p.mode : 'bars',
    stackBy:['client','model'].includes(p.stackBy) ? p.stackBy : 'client',
    height:Number.isSafeInteger(p.height) ? Math.min(900, Math.max(260, p.height)) : 340,
    splitRatio:safeSplitRatio(p.splitRatio)};
  state.history = home.history; Object.assign(state, home.preferences);
  state.locale = options.language === 'en' ? 'en' : 'zh-CN';
  home.settings = {locale:state.locale,heatmapMetric:state.heatmapMetric};
  applyAppearance(home.settings); applyTranslations(); populateRangeSelect();
  home.ready = true;
  const initialDashboard = document.getElementById('homeDashboard');
  initialDashboard.style.setProperty('--activity-ratio', `${home.preferences.splitRatio}fr`);
  initialDashboard.style.setProperty('--trend-ratio', `${1 - home.preferences.splitRatio}fr`);
  renderNow();
  if (home.resolveSettings) {home.resolveSettings(home.settings); home.resolveSettings = null;}
  return els.chart.querySelector('svg')?.outerHTML || els.heatmap.querySelector('svg')?.outerHTML || '<svg data-empty="true"></svg>';
};
document.addEventListener('click', event => {
  if (event.target.closest('[data-control="mode"], [data-control="stack"], #rangeSelect')) savePreferences();
});
// The original controls keep their click behavior. Arrow keys provide the same
// choice without moving focus to the chart or rebuilding the other pane.
document.addEventListener('keydown', event => {
  const group = event.target.closest('[data-control], #rangeSelect');
  if (!group || !event.target.matches('button') || !['ArrowLeft','ArrowRight','Home','End'].includes(event.key)) return;
  const buttons = [...group.querySelectorAll('button:not(:disabled)')];
  const current = buttons.indexOf(event.target);
  if (current < 0 || buttons.length < 2) return;
  event.preventDefault();
  const index = event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1
    : (current + (event.key === 'ArrowRight' ? 1 : -1) + buttons.length) % buttons.length;
  buttons[index].focus({preventScroll:true});
  buttons[index].click();
});
document.getElementById('heatmapStart').addEventListener('change', event => {
  const value = event.target.value;
  if (!dateKey(value) || value > home.end) { event.target.value = currentStart(); return; }
  savePreferences({heatmapStart:value}); state.motion = 'none'; renderNow();
});
document.getElementById('heatmapStartReset').addEventListener('click', () => {
  savePreferences({heatmapStart:''}); state.motion = 'none'; renderNow();
});

const splitter = document.getElementById('dashSplitter');
let splitPointerID = null;
function syncActivityTrack() {
  const dashboard = document.getElementById('homeDashboard');
  const ratio = safeSplitRatio(home.preferences?.splitRatio);
  if (window.matchMedia('(max-width: 760px)').matches || ratio !== splitBounds.default) {
    dashboard.style.removeProperty('grid-template-columns');
    return;
  }
  const heatmap = document.querySelector('#dashHeatmap svg');
  const width = heatmap?.getBoundingClientRect().width;
  if (!Number.isFinite(width) || width <= 0) return;
  const activityWidth = Math.min(420, Math.floor((dashboard.clientWidth - 12) * .48),
    Math.max(320, Math.ceil(width + 23)));
  dashboard.style.gridTemplateColumns = `minmax(0, ${activityWidth}px) 12px minmax(0, 1fr)`;
}
function applySplitRatio(ratio, {persist = true} = {}) {
  const value = safeSplitRatio(ratio);
  const dashboard = document.getElementById('homeDashboard');
  dashboard.style.setProperty('--activity-ratio', `${value}fr`);
  dashboard.style.setProperty('--trend-ratio', `${1 - value}fr`);
  splitter.setAttribute('aria-valuenow', String(Math.round(value * 100)));
  if (persist) {
    state.motion = 'none';
    savePreferences({splitRatio:value});
    renderNow();
  } else {
    dashboard.style.removeProperty('grid-template-columns');
  }
}
splitter.addEventListener('pointerdown', event => {
  if (window.matchMedia('(max-width: 760px)').matches) return;
  splitPointerID = event.pointerId; splitter.setPointerCapture?.(event.pointerId);
  splitter.classList.add('is-dragging'); event.preventDefault();
});
splitter.addEventListener('pointermove', event => {
  if (splitPointerID !== event.pointerId) return;
  const rect = document.getElementById('homeDashboard').getBoundingClientRect();
  const usable = Math.max(1, rect.width - 12);
  applySplitRatio((event.clientX - rect.left) / usable, {persist:false});
});
function finishSplit(event) {
  if (splitPointerID !== event.pointerId) return;
  splitPointerID = null; splitter.classList.remove('is-dragging');
  splitter.releasePointerCapture?.(event.pointerId);
  applySplitRatio(parseFloat(document.getElementById('homeDashboard').style.getPropertyValue('--activity-ratio')) || home.preferences.splitRatio);
}
splitter.addEventListener('pointerup', finishSplit); splitter.addEventListener('pointercancel', finishSplit);
splitter.addEventListener('dblclick', () => applySplitRatio(splitBounds.default));
splitter.addEventListener('keydown', event => {
  if (!['ArrowLeft','ArrowRight','Home','End'].includes(event.key)) return;
  event.preventDefault();
  const current = safeSplitRatio(home.preferences.splitRatio);
  const next = event.key === 'Home' ? splitBounds.min : event.key === 'End' ? splitBounds.max
    : current + (event.key === 'ArrowRight' ? 0.04 : -0.04);
  applySplitRatio(next);
});
let lastLayoutWidths = '';
const layoutObserver = new ResizeObserver(() => {
  const widths = [document.getElementById('homeDashboard').clientWidth,
    els.activityPane.clientWidth, els.chart.clientWidth].join(':');
  if (widths !== lastLayoutWidths) {
    lastLayoutWidths = widths;
    renderNow();
  }
  reportHomeSize();
});
[document.getElementById('homeDashboard'), els.activityPane, els.trendsPane]
  .forEach(element => layoutObserver.observe(element));

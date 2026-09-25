'use strict';
(function (root) {
  const api = root.TokenMonitorUsageCharts;
  const $ = id => document.getElementById(id);
  const amount = v => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= Number.MAX_SAFE_INTEGER ? v : null;
  const day = v => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) && Number.isFinite(Date.parse(v + 'T00:00:00Z')) && new Date(v + 'T00:00:00Z').toISOString().slice(0, 10) === v;
  // Do not display raw metadata. Engine remains responsible for sanitizing the full response.
  const publicText = v => String(v ?? '').replace(/(?:https?:\/\/\S+|\b[^\s@]+@[^\s@]+\b|(?:\/(?:Users|home|private|tmp|var|Volumes|opt)\/|[A-Z]:\\)\S*|\b(?:sk-|Bearer\s+)\S+)/gi, t('[已隐藏]', '[redacted]')).slice(0,200);
  const dimension = (row, key) => {
    const map = row && row[key];
    if (!map || typeof map !== 'object' || Array.isArray(map)) return null;
    const entries = Object.entries(map).filter(([k]) => !['__proto__', 'constructor', 'prototype'].includes(k));
    return entries.length ? entries : null;
  };
  let state, installedSnapshot, language = 'zh';
  const t = (zh, en) => language === 'en' ? en : zh;
  const missing = () => t('未提供', 'Not provided');
  const number = v => amount(v) === null ? missing() : v.toLocaleString(language === 'en' ? 'en-US' : 'zh-CN');
  const labelStatus = s => s === 'known' ? t('已确认', 'known') : s === 'partial' ? t('部分覆盖', 'partial coverage') : t('完整性未确认', 'completeness unconfirmed');
  const labels = {overview:['概览','Overview'],trends:['趋势','Trends'],details:['明细','Details'],activity:['每日活跃','Daily activity'],activityHint:['悬停看数值，点击切换下方详情','Hover for values; click to update the details below'],trendTitle:['趋势','Trend'],trendHint:['按工具堆叠，缺失日期保持空白','Stacked by tool; missing dates stay blank'],less:['少','Less'],more:['多','More'],selectedDate:['所选日期','Selected date'],dailyTools:['当天工具用量','Daily tool usage'],composition:['工具构成','Tool composition'],selectedDay:['所选日期','Selected date'],group:['分组','Group'],from:['起始日期','From'],to:['结束日期','To'],date:['日期','Date'],period:['期间','Period'],day:['所选日','Selected day'],today:['今天','Today'],month:['本月','This month'],allTime:['全部时间','All time'],client:['工具','Tool'],model:['模型','Model']};
  function localize() {
    document.documentElement.lang = language;
    document.querySelector('nav').setAttribute('aria-label', t('用量视图','Usage view'));
    document.querySelectorAll('[data-mode], [data-label], option').forEach(el => {
      // The body carries data-mode for CSS only; replacing its textContent
      // would wipe the whole dashboard on every re-render after a mode switch.
      if (el === document.body) return;
      const key = el.getAttribute('data-mode') || el.getAttribute('data-label') || el.value;
      if (labels[key]) el.textContent = t(...labels[key]);
    });
  }
  function cost(value, ...contexts) {
    // Only cost-specific evidence applies; token/day status is not price evidence.
    const coverage = contexts.map(x => x?.coverage?.cost ?? x?.costCoverage).find(x => x != null) ?? state.input.coverage?.cost;
    const available = amount(value) !== null && (coverage === 'known' || coverage === 'partial');
    const label = coverage === 'partial' && available ? t('已观察费用（美元）','Observed cost (USD)') : t('费用（美元）','Cost (USD)');
    return `${label}: ${available ? number(value) : missing()} · ${available && coverage === 'known' ? labelStatus('known') : labelStatus('unknown')}`;
  }
  function costContext(period, key) {
    const coverage = state.input.coverage;
    const scoped = period === 'day' ? (Array.isArray(coverage?.days) ? coverage.days.find(x => x?.date === key) : coverage?.days?.[key]) : coverage?.periods?.[period];
    return {coverage:{cost:scoped?.cost ?? scoped?.coverage?.cost}};
  }
  function normalize(input, annotations) {
    const legacy = Array.isArray(input);
    if (!legacy && (!input || input.schemaVersion !== 1 || !input.payload)) throw Error(t('仪表盘数据格式无效','Invalid dashboard schema'));
    const payload = legacy ? {} : input.payload;
    const canonical = payload.aggregate ?? payload.usage ?? {};
    const history = canonical.history ?? payload.history ?? payload.usage?.history;
    const rows = legacy ? input : history?.daily;
    if (rows != null && !Array.isArray(rows)) throw Error(t('历史记录无效','Invalid history'));
    if ((rows || []).length > 10000) throw Error(t('历史记录过大','History too large'));
    const byDate = new Map();
    for (const row of rows || []) {
      if (!row || !day(row.date)) continue;
      if (byDate.has(row.date)) throw Error(t('汇总日期重复','Duplicate canonical date'));
      byDate.set(row.date, row);
    }
    const rawCoverage = legacy ? [] : input.coverage?.days;
    const dayCoverage = Array.isArray(rawCoverage) ? rawCoverage : rawCoverage && typeof rawCoverage === 'object' ? Object.entries(rawCoverage).map(([date,value]) => ({date,status:value?.status})) : [];
    const coverage = new Map(dayCoverage.filter(x => x && day(x.date)).map(x => [x.date, x.status]));
    let end = canonical.periodWindows?.today?.key ?? payload.usage?.periodWindows?.today?.key;
    if (!day(end) && !legacy && typeof input.collectedAt === 'string' && typeof input.timezone === 'string') {
      const instant = new Date(input.collectedAt);
      if (Number.isFinite(instant.getTime())) {
        const parts = new Intl.DateTimeFormat('en-US', {timeZone: input.timezone, year:'numeric', month:'2-digit', day:'2-digit'}).formatToParts(instant);
        const get = type => parts.find(p => p.type === type).value;
        end = `${get('year')}-${get('month')}-${get('day')}`;
      }
    }
    if (!day(end)) end = [...byDate.keys()].sort().at(-1);
    if (!day(end)) throw Error(t('统计日期未提供','Statistics day unavailable'));
    return {input, canonical, history, byDate, coverage, end, legacy};
  }
  function status(key) {
    const row = state.byDate.get(key), tokens = amount(row?.tokens);
    const coverage = state.coverage.get(key);
    if (tokens === null || (!state.legacy && coverage !== 'known' && coverage !== 'partial')) return 'unknown';
    return coverage === 'partial' ? 'partial' : 'known';
  }
  function describe(key) {
    const row = state.byDate.get(key), value = amount(row?.tokens), c = status(key);
    const lines = [`${key} · ${value === null ? t('Token 未提供','Tokens unavailable') : number(value) + ' Token'} · ${labelStatus(c)}${value !== null && c !== 'known' ? t(' · 已观察值，完整性未确认',' · observed value, completeness unconfirmed') : ''}`, cost(row?.costUsd ?? row?.cost, row, costContext('day', key))];
    for (const [field, label] of [['perClient',t('工具','Tools')],['perModel',t('模型','Models')]]) {
      const entries = dimension(row, field);
      lines.push(`${label}: ` + (entries ? entries.slice(0,30).map(([k,v]) => `${publicText(k)}: ${number(v?.tokens)}`).join(', ') + omitted(entries.length,30) : missing()));
    }
    return lines.join('\n');
  }
  function shortDescription(key) {
    const value = amount(state.byDate.get(key)?.tokens);
    return `${key} · ${value === null ? t('未采集','Not recorded') : number(value) + ' Token'}`;
  }
  const toolColor = index => `hsl(${(index * 67 + 205) % 360},65%,52%)`;
  function daySummary(key) {
    const row = state.byDate.get(key), total = amount(row?.tokens);
    const entries = (dimension(row, 'perClient') || [])
      .map(([name,value]) => [name,amount(value?.tokens)])
      .filter(([,value]) => value !== null)
      .sort((a,b) => b[1] - a[1]);
    const sum = entries.reduce((sum,[,value]) => sum + value,0);
    const complete = total !== null && total > 0 && sum === total;
    $('day-total').textContent = `${key} · ${total === null ? t('Token 未提供','Tokens unavailable') : number(total) + ' Token'}`;
    const box = $('day-tools'); box.textContent = '';
    const heading = document.createElement('p');
    heading.textContent = entries.length ? t('各工具占比','Share by tool') : total === 0 ? t('当天记录为 0','Recorded zero for this day') : t('未提供工具明细','Tool breakdown unavailable');
    box.appendChild(heading);
    const maximum = Math.max(1, ...entries.map(([,value]) => value));
    for (const [index,[name,value]] of entries.slice(0,8).entries()) {
      const item = document.createElement('div'); item.className = 'tool-row';
      const label = document.createElement('span'); label.textContent = publicText(name);
      const count = document.createElement('span'); count.textContent = complete ? `${(100 * value / total).toFixed(1)}%` : number(value);
      const bar = document.createElement('progress'); bar.max = complete ? total : maximum; bar.value = value;
      bar.style.accentColor = toolColor(index);
      bar.setAttribute('aria-label', `${publicText(name)}: ${number(value)} Token${complete ? ` · ${(100 * value / total).toFixed(1)}%` : ''}`);
      item.append(label,count,bar); box.appendChild(item);
    }
    if (entries.length && !complete) {
      const note = document.createElement('p'); note.className = 'muted'; note.textContent = t('工具明细覆盖不完整，显示已记录值','Tool coverage is incomplete; showing recorded values'); box.appendChild(note);
    }
    if (entries.length > 8) {
      const note = document.createElement('p'); note.className = 'muted'; note.textContent = t('其余工具见明细页','See Details for other tools'); box.appendChild(note);
    }
    renderDayComposition(entries, total, sum, complete);
  }
  function renderDayComposition(entries, total, sum, complete) {
    const box = $('day-donut'); box.textContent = '';
    if (!entries.length) {
      const note = document.createElement('p'); note.className = 'muted';
      note.textContent = total === 0 ? t('没有可绘制的工具构成。','No tool composition to draw.') : t('工具构成未提供。','Tool composition unavailable.');
      box.appendChild(note);
      return;
    }
    const svg = document.createElementNS('http://www.w3.org/2000/svg','svg');
    svg.setAttribute('viewBox','0 0 120 120');
    svg.setAttribute('role','img');
    svg.setAttribute('aria-label', `${t('工具构成','Tool composition')} · ${number(total ?? sum)} Token`);
    const track = document.createElementNS('http://www.w3.org/2000/svg','circle');
    track.setAttribute('class','donut-track'); track.setAttribute('cx','60'); track.setAttribute('cy','60'); track.setAttribute('r','45');
    svg.appendChild(track);
    const circumference = 2 * Math.PI * 45;
    let offset = 0;
    for (const [index,[name,value]] of entries.slice(0,8).entries()) {
      const fraction = sum > 0 ? value / sum : 0;
      const segment = document.createElementNS('http://www.w3.org/2000/svg','circle');
      segment.setAttribute('class','donut-segment'); segment.setAttribute('cx','60'); segment.setAttribute('cy','60'); segment.setAttribute('r','45');
      segment.setAttribute('stroke',toolColor(index));
      segment.setAttribute('stroke-dasharray',`${fraction * circumference} ${circumference}`);
      segment.setAttribute('stroke-dashoffset',`${-offset}`);
      segment.setAttribute('aria-label',`${publicText(name)}: ${number(value)} Token${complete ? ` · ${(100 * value / total).toFixed(1)}%` : ''}`);
      svg.appendChild(segment);
      offset += fraction * circumference;
    }
    const centerValue = document.createElementNS('http://www.w3.org/2000/svg','text');
    centerValue.setAttribute('class','donut-center-value'); centerValue.setAttribute('x','60'); centerValue.setAttribute('y','59'); centerValue.textContent = String(entries.length);
    const centerLabel = document.createElementNS('http://www.w3.org/2000/svg','text');
    centerLabel.setAttribute('class','donut-center-label'); centerLabel.setAttribute('x','60'); centerLabel.setAttribute('y','70'); centerLabel.textContent = t('个有记录工具','recorded tools');
    svg.append(centerValue, centerLabel);
    box.appendChild(svg);
    const legend = document.createElement('div'); legend.className = 'day-legend';
    for (const [index,[name,value]] of entries.slice(0,8).entries()) {
      const item = document.createElement('div'); item.className = 'day-legend-row'; item.style.setProperty('--legend-color',toolColor(index));
      const swatch = document.createElement('i'); swatch.setAttribute('aria-hidden','true');
      const label = document.createElement('span'); label.textContent = publicText(name);
      const amountLabel = document.createElement('strong'); amountLabel.textContent = complete ? `${number(value)} · ${(100 * value / total).toFixed(1)}%` : number(value);
      item.append(swatch,label,amountLabel); legend.appendChild(item);
    }
    box.appendChild(legend);
  }
  function omitted(count, limit) { return count > limit ? t(`；另有 ${count-limit} 项未显示`, `; ${count-limit} more entries omitted`) : ''; }
  const fields = [['inputTokens','输入 Token','Input tokens'],['outputTokens','输出 Token','Output tokens'],['cacheReadTokens','缓存读取 Token','Cache read tokens'],['cacheWriteTokens','缓存写入 Token','Cache write tokens'],['reasoningTokens','推理 Token','Reasoning tokens'],['unclassifiedTokens','未分类 Token','Unclassified tokens'],['messageCount','消息数','Message count']];
  function reportSize() {
    if (!root.requestAnimationFrame || !root.webkit?.messageHandlers?.chartSize) return;
    root.requestAnimationFrame(() => {
      if (!state?.snapshotID) return;
      // flow-root contains the normal-flow content, including its margins.
      // scrollHeight includes the host viewport: feeding it back (+4) creates
      // a growth loop and prevents the native view from ever shrinking.
      const height = document.body.getBoundingClientRect().height;
      root.webkit.messageHandlers.chartSize.postMessage({snapshotID:state.snapshotID,
        width:root.innerWidth ?? document.documentElement.clientWidth, height:Math.ceil(height) + 4});
    });
  }
  function breakdown(parent, title, entries, total, component = false) {
    const panel = document.createElement('section'); panel.className = 'breakdown';
    const heading = document.createElement('h3'); heading.textContent = title; panel.appendChild(heading);
    const values = (entries || []).map(([key,v]) => [key,amount(typeof v === 'number' ? v : v?.totalTokens ?? v?.tokens)]);
    const known = values.filter(([,v]) => v !== null).sort((a,b) => b[1]-a[1]);
    const complete = !component && total > 0 && values.length === known.length && known.reduce((sum,[,v]) => sum+v,0) === total;
    const max = Math.max(1,...known.map(([,v]) => v));
    for (const [key,value] of known.slice(0,8)) {
      const row = document.createElement('div'); row.className = 'tool-row';
      const label = document.createElement('span'); label.textContent = publicText(key);
      const count = document.createElement('span'); count.textContent = number(value) + (complete ? ` · ${(100*value/total).toFixed(1)}%` : '');
      const bar = document.createElement('progress'); bar.max = complete ? total : max; bar.value = value;
      bar.setAttribute('aria-label', `${publicText(key)}: ${number(value)} Token`);
      row.append(label,count,bar); panel.appendChild(row);
    }
    const note = document.createElement('p'); note.className = 'muted';
    note.textContent = !known.length ? t('未提供此维度','This dimension is unavailable') : component
      ? t('分项按原记录显示；推理与缓存可能包含在其他项中，不重复加总。','Components follow source records; reasoning and cache may overlap other fields and are not added again.')
      : complete ? t('占所选期间总量','Share of the selected period') : t('显示已记录值，维度覆盖未确认','Recorded values; dimension coverage unconfirmed');
    const unknown = values.filter(([,v]) => v === null).map(([key]) => publicText(key));
    if (unknown.length) note.textContent += ` · ${t('未提供','Unavailable')}: ${unknown.join('、')}`;
    if (known.length > 8) note.textContent += omitted(known.length,8);
    panel.appendChild(note); parent.appendChild(panel);
  }
  function details() {
    const period = $('period').value || 'day';
    const data = period === 'day' ? state.byDate.get(state.selected) : (state.canonical.periods ? state.canonical.periods[period] : state.canonical[period]);
    const box = $('dimensions'); box.textContent = '';
    const add = (tag, text, parent = box) => { const el = document.createElement(tag); el.textContent = text; parent.appendChild(el); return el; };
    const total = amount(period === 'day' ? data?.tokens : data?.totalTokens);
    add('p', period === 'day' ? describe(state.selected).split('\n')[0] : `${t(...labels[period])} · ${number(total)} Token · ${t('期间完整性未确认','Period completeness unconfirmed')}`);
    const costLine = add('p',cost(data?.costUsd ?? data?.cost, data, costContext(period, state.selected))); costLine.className = 'muted';
    const charts = add('div',''); charts.className = 'detail-charts';
    breakdown(charts,t('工具用量','Usage by tool'),dimension(data,period === 'day' ? 'perClient' : 'clients'),total);
    breakdown(charts,t('模型用量','Usage by model'),dimension(data,period === 'day' ? 'perModel' : 'models'),total);
    breakdown(charts,t('Token 分项','Token components'),fields.filter(([key]) => key !== 'messageCount').map(([key,zh,en]) => [t(zh,en),data?.[key]]),total,true);
    add('p', `${t('消息数','Message count')}: ${number(data?.messageCount)}`).className = 'muted';
    for (const [key,zh,en,daily,prefix] of [['clients','工具','Tools','perClient','client'],['models','模型','Models','perModel','model'],['sessions','会话','Sessions','sessions'],['projects','项目','Projects','projects'],['accounts','账号','Accounts','perAccount']]) {
      const entries = dimension(data, period === 'day' ? daily : key);
      if (!entries) continue;
      const disclosure = add('details','');
      add('summary', `${t(zh,en)} · ${entries.length} ${t('项原始明细','recorded entries')}`, disclosure);
      disclosure.addEventListener('toggle', reportSize);
      const table = add('table','',disclosure);
      const head = add('tr','',table);
      for (const title of [t('名称 / 标识','Name / ID'),'Token',t('费用及属性','Cost and properties')]) add('th',title,head);
      for (const [id,value] of entries.slice(0,40)) {
        const obj = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
        const row = add('tr','',table);
        add('td',publicText(typeof obj.label === 'string' && obj.label ? obj.label : id),row);
        add('td',number(typeof value === 'number' ? value : obj.totalTokens ?? obj.tokens),row);
        const attrs = [cost(prefix && period !== 'day' ? data?.[prefix+'Costs']?.[id] : obj.costUsd ?? obj.cost, obj, data, costContext(period, state.selected))];
        for (const [field,zh,en] of fields) {
          const suffix = {outputTokens:'Outputs',cacheReadTokens:'CacheReads',cacheWriteTokens:'CacheWrites',unclassifiedTokens:'UnclassifiedTokens'}[field];
          attrs.push(`${t(zh,en)}: ${number(prefix && period !== 'day' && suffix ? data?.[prefix+suffix]?.[id] : obj[field])}`);
        }
        if (key === 'sessions' || key === 'projects' || key === 'accounts') {
          for (const [field,zh,en] of [['client','工具','Tool'],['sessionId','会话标识','Session ID'],['projectId','项目标识','Project ID'],['projectLabel','项目名称','Project label']]) {
            attrs.push(`${t(zh,en)}: ${typeof obj[field] === 'string' && obj[field] ? publicText(obj[field]) : missing()}`);
          }
          for (const [field,zh,en] of [['models','模型','Models'],['clients','工具','Tools']]) {
            const sub = dimension(obj,field);
            attrs.push(`${t(zh,en)}: ${sub ? sub.slice(0,20).map(([k,v]) => `${publicText(k)}: ${number(v)}`).join(', ') + omitted(sub.length,20) : missing()}`);
          }
        }
        add('td',attrs.join(' · '),row);
      }
      add('p',omitted(entries.length,40),disclosure);
    }
    reportSize();
  }
  function select(key) {
    if (!day(key) || key > state.end) { $('selection').textContent = t('日期无效或晚于统计日期','Invalid date or after statistics date'); return; }
    if (state.nativeRange && (key < state.nativeRange.from || key > state.nativeRange.to)) {
      $('date').value = state.selected;
      $('selection').textContent = t('日期不在所选范围内','Date outside the selected range');
      return;
    }
    state.selected = key; $('date').value = key;
    $('selection').textContent = shortDescription(key); details(); daySummary(key);
    $('calendar').querySelectorAll('[data-d]').forEach(el => el.setAttribute('aria-pressed',String(el.getAttribute('data-d') === key)));
    const month = key.slice(0,7);
    const cells = state.calendar.cells.filter(c => c.date.startsWith(month));
    const values = cells.map(c => amount(state.byDate.get(c.date)?.tokens)).filter(v => v !== null);
    const sum = values.reduce((a,b) => a+b, 0);
    $('month').textContent = `${month} · ${values.length ? number(sum) : missing()} Token · ${values.length}/${cells.length} ${t('天有记录','days recorded')}`;
  }
  function bindDate(element, key) {
    element.setAttribute('tabindex','0'); element.setAttribute('role','button');
    element.setAttribute('aria-label',shortDescription(key));
    element.addEventListener('click', () => select(key));
    const show = event => {
      const tooltip = $('hover-tooltip'); tooltip.textContent = shortDescription(key); tooltip.hidden = false;
      const rect = element.getBoundingClientRect();
      const x = event.clientX ?? rect.left, y = event.clientY ?? rect.top;
      tooltip.style.left = Math.max(4, Math.min(x + 10, document.documentElement.clientWidth - tooltip.offsetWidth - 4)) + 'px';
      tooltip.style.top = Math.max(4, Math.min(y + 16, document.documentElement.clientHeight - tooltip.offsetHeight - 4)) + 'px';
    };
    element.addEventListener('focus', show); element.addEventListener('mouseenter', show); element.addEventListener('mousemove', show);
    for (const name of ['blur','mouseleave']) element.addEventListener(name, () => { $('hover-tooltip').hidden = true; });
    element.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); select(key); } });
  }
  function calendarLabels() {
    const svg = $('calendar').querySelector('svg');
    if (!svg) return;
    const width = svg.viewBox.baseVal.width || Number(svg.getAttribute('width'));
    let previous = null;
    const labels = [...svg.querySelectorAll('.heat-month')];
    labels.forEach((el, index) => {
      const full = el.textContent, match = /^(\d{4})-(\d{2})$/.exec(full);
      if (match) {
        el.setAttribute('aria-label', full);
        el.textContent = index === 0 || match[2] === '01' ? `${match[1]}/${match[2]}` : language === 'zh' ? `${Number(match[2])}月` : ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][Number(match[2])-1];
      }
      const length = el.getComputedTextLength() || el.textContent.length * 6;
      let left = Number(el.getAttribute('x')) || 0;
      if (left + length > width - 2) { left = width - length - 2; el.setAttribute('x',left); }
      if (previous && left < previous.right + 6) {
        if (index === labels.length - 1) previous.element.style.display = 'none';
        else { el.style.display = 'none'; return; }
      }
      previous = {right:left + length,element:el};
    });
  }
  function heatmapCell(start, end) {
    const days = Math.round((Date.parse(end + 'T00:00:00Z') - Date.parse(start + 'T00:00:00Z')) / 86400000) + 1;
    if (!Number.isFinite(days) || days <= 14) return 16;
    if (days <= 40) return 15;
    return 13;
  }
  function barsWidth() {
    const measured = $('bars').getBoundingClientRect?.().width;
    if (Number.isFinite(measured) && measured > 80) return Math.max(280, Math.min(2000, measured));
    if (state.mode === 'overview' && state.width >= 800) return Math.max(280, Math.round(state.width * 0.58));
    return state.width;
  }
  function bars() {
    const field = $('group').value === 'model' ? 'perModel' : 'perClient';
    const start = $('from').value, end = $('to').value;
    if (!day(start) || !day(end) || start > end || end > state.end) { $('bars').textContent = t('日期范围无效','Invalid date range'); $('legend').textContent = ''; return; }
    const available = [...state.byDate.values()].filter(r => r.date >= start && r.date <= end).sort((a,b) => a.date.localeCompare(b.date));
    const rows = available.filter(r => dimension(r, field)?.some(([,v]) => amount(v?.tokens) !== null)).map(r => ({date:r.date, [field]:Object.fromEntries(dimension(r, field).filter(([,v]) => amount(v?.tokens) !== null).map(([k,v]) => [k,{tokens:v.tokens}]))}));
    if (!rows.length) { $('bars').textContent = t('此范围未提供该维度','Dimension unavailable in this range'); $('legend').textContent = t('无法从每日总量推断模型或工具分组。','No model/tool grouping inferred from daily totals.'); return; }
    const model = api.dailyBarsChart(rows,{width:barsWidth(),height:150,padLeft:56,stackBy:$('group').value,metric:'tokens'});
    const colorFor = k => `hsl(${(model.keys.indexOf(k)*67+205)%360},65%,52%)`;
    const labelStride = Math.max(1, Math.ceil(rows.length / Math.max(2, Math.floor(model.plot.w / 72))));
    const tickFormat = new Intl.NumberFormat(language === 'en' ? 'en-US' : 'zh-CN', {notation:'compact',maximumFractionDigits:1});
    $('bars').innerHTML = api.barsChartSvg(model,{
      colorFor,titleOf:b => describe(b.label),
      axisLabel:(b,i) => i % labelStride === 0 ? b.label.slice(5) : '',
      yTicks:3,formatTick:value => tickFormat.format(value)
    });
    $('legend').textContent = `${start} – ${end} · ${t('已观察 Token；未提供的维度已略过，完整性未确认','observed tokens; unavailable dimensions omitted, completeness unconfirmed')}\n`;
    for (const k of model.keys) { const item = document.createElement('span'); item.textContent = `● ${publicText(k)}  `; item.style.color = colorFor(k); $('legend').appendChild(item); }
    $('bars').querySelectorAll('[data-i]').forEach(el => bindDate(el,rows[Number(el.getAttribute('data-i'))].date));
  }
  function mode(name) {
    state.mode = name;
    if (document.body && document.body.setAttribute) document.body.setAttribute('data-mode', name);
    $('hover-tooltip').hidden = true;
    $('selection').hidden = name === 'details';
    $('overview').hidden = name !== 'overview';
    $('trends').hidden = name === 'details';
    $('charts').hidden = name === 'details';
    $('day-summary').hidden = name === 'details';
    $('details').hidden = name !== 'details';
    document.querySelectorAll('[data-mode]').forEach(el => el.setAttribute('aria-pressed',String(el.getAttribute('data-mode') === name)));
    if (name === 'overview' || name === 'trends') bars();
    reportSize();
  }
  root.__renderTrend = function (input, options = {}) {
    language = options.language === 'en' ? 'en' : 'zh'; localize();
    // Native sends the bounded JSON once per snapshot/navigation. Presentation
    // updates carry only its identity and options, reusing this realm's object.
    const snapshotID = options.snapshotID;
    if (snapshotID != null && (typeof snapshotID !== 'string' || !snapshotID || snapshotID.length > 128)) throw Error(t('快照标识无效','Invalid snapshot identity'));
    if (snapshotID != null && input === null) {
      if (installedSnapshot?.id !== snapshotID) throw Error(t('图表快照尚未加载','Dashboard snapshot unavailable'));
      input = installedSnapshot.input;
    } else if (snapshotID != null && typeof input !== 'string') {
      throw Error(t('仪表盘数据格式无效','Invalid dashboard schema'));
    }
    if (typeof input === 'string') { if (input.length > 16*1024*1024 || new TextEncoder().encode(input).byteLength > 16*1024*1024) throw Error(t('仪表盘数据过大','Dashboard too large')); try { input = JSON.parse(input); } catch { throw Error(t('仪表盘数据格式无效','Invalid dashboard schema')); } }
    if (Array.isArray(input)) {
      const rows = input.filter(r => r && day(r.date) && amount(r.tokens) !== null);
      if (!rows.length) throw Error(t('旧版数据未提供','Legacy data unavailable'));
      document.querySelectorAll('[data-mode]').forEach(el => { el.hidden = true; });
      for (const id of ['context','month','trends','details','selection','day-summary','charts']) $(id).hidden = true;
      $('overview').hidden = false;
      const svg = api.areaLineSvg(api.areaLineChart(rows,{width:options.width || 650,height:options.height || 40,metric:'tokens',curve:true}));
      $('calendar').innerHTML = svg;
      installedSnapshot = undefined;
      return svg;
    }
    document.querySelectorAll('[data-mode]').forEach(el => { el.hidden = false; });
    for (const id of ['context','month','selection','day-summary','charts']) $(id).hidden = false;
    const previous = state;
    const previousFrom = $('from').value, previousTo = $('to').value;
    state = normalize(input,options.resetAnnotations);
    state.snapshotID = snapshotID;
    state.width = Number.isFinite(options.width) ? Math.max(320,Math.min(2000,options.width)) : 650;
    $('context').textContent = `${t('每日 Token','Daily tokens')} · ${publicText(input.timezone)} · ${t('仅汇总已记录用量','Recorded usage only')}`;
    const rows = [...state.byDate.values()].filter(r => amount(r.tokens) !== null);
    const intensities = api.computeHeatmapIntensities(rows).map(r => ({...r,intensity:r.tokenIntensity}));
    const optionFrom = day(options.from) ? options.from : null;
    const optionTo = day(options.to) && options.to <= state.end ? options.to : (day(options.to) ? state.end : null);
    const retainRange = !optionFrom && !optionTo && previous?.userRange && day(previousFrom) && day(previousTo) && previousFrom <= previousTo && previousTo <= state.end;
    const windowEnd = optionTo || (retainRange ? previousTo : state.end);
    const windowStart = optionFrom && optionFrom <= windowEnd ? optionFrom : (retainRange ? previousFrom : null);
    $('to').value = windowEnd;
    if (windowStart) {
      $('from').value = windowStart;
      state.calendar = api.contribHeatmap(intensities,{startDate:windowStart,endDate:windowEnd,cell:heatmapCell(windowStart,windowEnd),gap:3});
    } else {
      state.calendar = api.rollingYearHeatmap(intensities,{endDate:state.end,cell:13,gap:3});
      $('from').value = state.calendar.cells[0] ? state.calendar.cells[0].date : state.end;
    }
    // Embedded home view: the native period owns the window, so the in-chart
    // date filters stay read-only; the standalone page keeps local filtering.
    const nativeOwned = optionFrom != null && optionTo != null;
    state.nativeRange = nativeOwned ? {from:$('from').value,to:windowEnd} : null;
    // The vendor pads to Sunday for alignment. Keep its geometry, but never
    // turn the padding into selectable records outside the native period.
    if (nativeOwned) state.calendar.cells = state.calendar.cells.filter(c => c.date >= state.nativeRange.from && c.date <= windowEnd);
    $('from').disabled = nativeOwned;
    $('to').disabled = nativeOwned;
    $('date').min = nativeOwned ? state.nativeRange.from : '';
    $('date').max = nativeOwned ? windowEnd : state.end;
    const svg = api.heatmapSvg(state.calendar,{titleOf:c => shortDescription(c.date)});
    $('calendar').innerHTML = svg;
    calendarLabels();
    $('calendar').querySelectorAll('[data-d]').forEach(el => {
      const key = el.getAttribute('data-d');
      if (amount(state.byDate.get(key)?.tokens) === null) el.classList.add('unknown');
      if (status(key) === 'unknown') { el.removeAttribute('data-t'); el.removeAttribute('data-cost'); }
      bindDate(el,key);
    });
    const retainedSelection = previous?.selected && day(previous.selected) && previous.selected <= state.end
      && (!nativeOwned || (previous.selected >= state.nativeRange.from && previous.selected <= windowEnd));
    select(retainedSelection ? previous.selected : nativeOwned ? windowEnd : state.end);
    state.userRange = Boolean(optionFrom || optionTo) ? false : retainRange;
    mode(previous?.mode || 'overview');
    installedSnapshot = snapshotID != null ? {id:snapshotID,input} : undefined;
    return svg;
  };
  document.querySelectorAll('[data-mode]').forEach(el => el.addEventListener('click', () => mode(el.getAttribute('data-mode'))));
  for (const id of ['group','from','to']) $(id).addEventListener('change',() => { if (state && (id === 'from' || id === 'to')) state.userRange = true; bars(); reportSize(); });
  $('period').addEventListener('change',details);
  $('date').addEventListener('change', () => select($('date').value));
})(window);

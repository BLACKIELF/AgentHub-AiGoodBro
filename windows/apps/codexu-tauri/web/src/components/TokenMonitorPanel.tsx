import { StatisticsTimezoneSettings } from './StatisticsTimezoneSettings';
import { useEffect, useMemo, useState } from 'react';
import { Check, Info, RefreshCw, Save, Square } from 'lucide-react';
import { useI18n } from '../i18n/I18nProvider';
import type { TokenMonitorController } from '../hooks/useTokenMonitor';
import { durationText, statisticsChartSnapshot, statisticsHasEvidence, visibleStatisticsRate, type StatisticsPeriod } from '../utils/tokenMonitor';
import { TokenMonitorChart } from './TokenMonitorChart';

type Text=(zh:string,en:string)=>string;
function errorText(code:string,text:Text):string{
  const values:Record<string,[string,string]>={
    statistics_timezone_required:['尚未确认本地时区，刷新后重试。','The local time zone is unconfirmed. Refresh to retry.'],
    statistics_timezone_save_failed:['时区未能保存，请重试。','Time zone could not be saved. Try again.'],
    statistics_timezone_preferences_unavailable:['已保存时区无法读取，请重新选择。','The saved time zone could not be read. Select it again.'],
    invalid_statistics_timezone:['本地时区无效，请检查系统时区。','The local time zone is invalid. Check system time zone settings.'],
    statistics_resources_unavailable:['统计组件暂不可用，请检查当前安装包。','Statistics components are unavailable. Check the installed package.'],
    statistics_resources_untrusted:['当前安装包缺少已校验的统计组件。','This package does not contain verified statistics components.'],
    statistics_resources_invalid:['统计组件校验未通过，请检查当前安装包。','Statistics component verification failed. Check the installed package.'],
    statistics_cleanup_unconfirmed:['统计扫描停止结果未确认，请再次停止后重试。','Stopping the scan is unconfirmed. Stop it again before retrying.'],
    statistics_busy:['统计正在处理其他操作，请稍后重试。','Another statistics operation is in progress. Try again shortly.'],
    statistics_timeout:['统计读取超时，保留上次记录。','Statistics collection timed out. Previous records have been kept.'],
    statistics_save_failed:['来源保存失败，编辑内容已保留。','Sources could not be saved. Your edits have been kept.'],
    windows_required:['此统计服务需要 Windows。','This statistics service requires Windows.'],
  };return values[code]?text(...values[code]):text('统计暂时无法更新，请重试。','Statistics could not update. Try again.');
}
export function TokenMonitorPanel({controller}:{controller:TokenMonitorController}){
  const {language}=useI18n();const text:Text=(zh,en)=>language==='zh-Hans'?zh:en,locale=language==='zh-Hans'?'zh-CN':'en-GB';
  const {state,error,busy,refresh,selectSources,cancel}=controller;
  const [draft,setDraft]=useState<string[]>([]),[saved,setSaved]=useState(false);
  const sourceSignature=JSON.stringify(state?.sources.map(source=>[source.id,source.enabled,source.label])||[]);
  useEffect(()=>{setDraft(state?.sources.filter(source=>source.enabled).map(source=>source.id)||[]);setSaved(false);},[sourceSignature]);
  const dirty=JSON.stringify([...(state?.sources.filter(source=>source.enabled).map(source=>source.id)||[])].sort())!==JSON.stringify([...draft].sort());
  const snapshot=state?.snapshot,hasEvidence=snapshot?statisticsHasEvidence(snapshot):false;
  const stale=!!snapshot&&(!!error||!['ready','partial'].includes(state?.phase||''));
  const rate=visibleStatisticsRate(state);
  const chart=useMemo(()=>snapshot?statisticsChartSnapshot(snapshot):null,[snapshot]);
  const number=(value:number|null|undefined)=>value==null?'—':new Intl.NumberFormat(locale,{maximumFractionDigits:2}).format(value);
  const timestamp=(value:string|number|null|undefined)=>value==null?'—':new Date(value).toLocaleString(locale,{timeZone:state?.timezone||undefined,hour12:false});
  const cost=(period:StatisticsPeriod|null|undefined)=>hasEvidence&&period?.costUsd!=null&&snapshot?.coverage.cost!=='unknown'?'≈ $'+new Intl.NumberFormat(locale,{minimumFractionDigits:2,maximumFractionDigits:2}).format(period.costUsd):text('成本未确认','Cost unconfirmed');
  const reason=error||state?.failureCode;
  const phase=state?.phase==='partial'?text('部分来源有数据缺口','Some sources have gaps'):state?.phase==='loading'?text(snapshot?'正在更新 · 显示上次记录':'正在读取统计，历史较多时需要稍候',snapshot?'Updating · previous records shown':'Loading statistics; large histories may take a while'):state?.phase==='stopped'?text('已停止扫描 · 显示上次记录','Scanning stopped · previous records shown'):!snapshot?text('尚无统计快照','No statistics snapshot yet'):null;
  return <section className="token-monitor-panel glass-panel" aria-label={text('Token Monitor 统计','Token Monitor statistics')}>
    <header className="token-monitor-heading"><div><h2>Token Monitor</h2><p>{text('本机用量统计','Local usage statistics')}{state?.timezone&&<span> · {state.timezone}</span>}</p></div><div className="token-monitor-actions">
      <button type="button" className="glass-button" title={text('刷新统计','Refresh statistics')} aria-label={text('刷新统计','Refresh statistics')} disabled={busy} onClick={()=>void refresh()}><RefreshCw size={15} className={busy?'animate-spin':''}/></button>
      <button type="button" className="glass-button" title={text('停止统计扫描','Stop statistics scanning')} aria-label={text('停止统计扫描','Stop statistics scanning')} disabled={!state?.contextKey||state.phase==='stopped'} onClick={()=>void cancel()}><Square size={14}/></button>
      <details className="token-monitor-info"><summary aria-label={text('统计详情','Statistics details')} title={text('统计详情','Statistics details')}><Info size={15}/></summary><div><p>{text('用量、历史、成本与生成耗时均来自相同的 Token Monitor 来源。','Usage, history, costs and generation time come from the same Token Monitor sources.')}</p><p>{text('总 Token 使用全量 TOTAL；图表显示所选历史范围。','Total tokens uses the full TOTAL; charts show their selected history range.')}</p><p>{text('TPM 取新增已计时记录，不以等待或监听时间计算。','TPM uses new timed records, rather than waiting or watcher time.')}</p></div></details>
    </div></header>
    {reason&&<p role="alert" className="token-monitor-note is-error">{errorText(reason,text)}</p>}
    {phase&&<p role="status" className="token-monitor-note">{phase}</p>}
    <div className={`token-monitor-periods ${stale?'is-stale':''}`}>
      {([['today',text('今日 Token','Today tokens')],['month',text('本月 Token','This month tokens')],['allTime',text('总 Token','Total tokens')]] as const).map(([key,label])=>{const period=snapshot?.payload.aggregate[key];return <article key={key} data-testid={`token-monitor-${key}`}><span>{label}</span><strong>{number(hasEvidence?period?.totalTokens:null)}</strong><small>{cost(period)}</small></article>;})}
      <article data-testid="token-monitor-rate" className={rate?.idle?'is-idle':''}><span>TPM {rate?.idle&&<small>{text('上次采样','Last sample')}</small>}</span><strong>{number(rate?.burnPerMinute)}</strong><small>{rate?`${number(rate.speedPerSecond)} tok/s`:text('等待新增计时记录','Waiting for new timed records')}</small></article>
    </div>
    <StatisticsTimezoneSettings controller={controller} />
    <div className="token-monitor-source-bar"><details><summary>{text('统计来源','Statistics sources')} <span>{state?.sources.filter(source=>source.enabled).length??0}</span></summary><form onSubmit={event=>{event.preventDefault();setSaved(false);void selectSources(draft).then(ok=>setSaved(ok));}}><fieldset disabled={busy}><legend>{text('选择本机已登记来源','Choose registered local sources')}</legend><div className="token-monitor-source-grid">{state?.sources.map(source=><label key={source.id}><input type="checkbox" checked={draft.includes(source.id)} onChange={event=>{setSaved(false);setDraft(previous=>event.target.checked?[...previous,source.id]:previous.filter(id=>id!==source.id));}}/><span>{source.label}</span><small>{source.providerId}</small></label>)}</div>{!state?.sources.length&&<p>{text('暂无可选来源','No registered sources')}</p>}<button type="submit" className="glass-button-solid" disabled={!dirty||busy}><Save size={13}/>{text('保存来源','Save sources')}</button>{saved&&<span role="status"><Check size={13}/>{text('来源已保存','Sources saved')}</span>}</fieldset></form></details><p>{text('统计更新','Statistics updated')} {timestamp(snapshot?.collectedAt)}{snapshot?.historyCollectedAt!=null&&<span> · {text('历史更新','History updated')} {timestamp(snapshot.historyCollectedAt)}</span>}</p></div>
    {chart?<TokenMonitorChart snapshot={chart} language={language==='en'?'en':'zh-Hans'} stale={stale}/>:<p className="token-monitor-empty">{text('统计就绪后将显示活动热图、趋势与工具 / 模型明细。','The activity heatmap, trends and tool / model breakdown appear when statistics are ready.')}</p>}
    <footer className={stale?'is-stale':''}><span>{text('活动时长','Active time')} {durationText(hasEvidence?snapshot?.payload.history?.summary.activeTimeMs:null,locale)}</span><span title={text('来自有时长记录的真实生成耗时；并发记录可能重叠。','Actual generation durations from timed records; concurrent records may overlap.')}>{text('生成耗时','Generation time')} {durationText(hasEvidence?snapshot?.payload.aggregate.today?.timedDurationMs:null,locale)}</span></footer>
  </section>;
}

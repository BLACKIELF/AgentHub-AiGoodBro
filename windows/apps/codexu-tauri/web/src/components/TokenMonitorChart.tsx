import { useEffect, useRef, useState } from 'react';
import { parseChartPreferences, type ChartPreferences, type StatisticsSnapshot } from '../utils/tokenMonitor';

const preferenceKey='aigoodbro.token-monitor.chart';
function readPreferences():ChartPreferences{try{return parseChartPreferences(JSON.parse(localStorage.getItem(preferenceKey)||'{}'));}catch{return {};}}
export function TokenMonitorChart({snapshot,language,stale}:{snapshot:StatisticsSnapshot;language:string;stale:boolean}){
  const frame=useRef<HTMLIFrameElement>(null),container=useRef<HTMLDivElement>(null),preferences=useRef(readPreferences()),active=useRef('');
  const [ready,setReady]=useState(false),[failed,setFailed]=useState(false),[height,setHeight]=useState(360);
  const snapshotID=`${snapshot.requestId}:${snapshot.collectedAt}:${snapshot.historyCollectedAt}`;
  useEffect(()=>{
    const receive=(event:MessageEvent)=>{
      if(event.source!==frame.current?.contentWindow||event.data?.channel!=='aigoodbro-token-monitor')return;
      const message=event.data;
      if(message.type==='ready'){setReady(true);return;}
      if(message.snapshotID!==active.current)return;
      if(message.type==='failed'){setFailed(true);return;}
      if(message.type==='rendered'){setFailed(false);return;}
      if(message.type==='preferences')try{preferences.current=parseChartPreferences(message.preferences);localStorage.setItem(preferenceKey,JSON.stringify(preferences.current));}catch{/* Current controls continue working without persistence. */}
    };
    window.addEventListener('message',receive);return()=>window.removeEventListener('message',receive);
  },[]);
  useEffect(()=>{const node=container.current;if(!node)return;const observer=new ResizeObserver(entries=>{const width=entries[0]?.contentRect.width;if(width)setHeight(width<=760?760:360);});observer.observe(node);return()=>observer.disconnect();},[]);
  useEffect(()=>{
    if(!ready)return;
    active.current=snapshotID;
    const send=()=>{const style=getComputedStyle(document.documentElement);frame.current?.contentWindow?.postMessage({channel:'aigoodbro-token-monitor',type:'render',snapshotID,snapshot,language,preferences:preferences.current,light:!document.documentElement.classList.contains('dark'),appearance:{accent:style.getPropertyValue('--accent').trim(),bg:style.getPropertyValue('--surface').trim(),text:style.getPropertyValue('--text-primary').trim(),muted:style.getPropertyValue('--text-secondary').trim()}},'*');};
    send();
    const appearance=new MutationObserver(send);appearance.observe(document.documentElement,{attributes:true,attributeFilter:['class','data-palette']});
    return()=>appearance.disconnect();
  },[ready,snapshotID,snapshot,language]);
  return <div ref={container} className={`token-monitor-chart ${stale?'is-stale':''}`}>
    {(!ready||failed)&&<p role={failed?'alert':'status'}>{language==='en'?(failed?'Chart is unavailable. Refresh to retry.':'Loading chart…'):(failed?'图表暂不可用，请刷新重试。':'图表加载中…')}</p>}
    <iframe ref={frame} title={language==='en'?'Token Monitor history and trends':'Token Monitor 历史与趋势'} src="./token-monitor-home/home-dashboard.html" sandbox="allow-scripts" style={{height}} onLoad={()=>frame.current?.contentWindow?.postMessage({channel:'aigoodbro-token-monitor',type:'hello'},'*')} onError={()=>setFailed(true)} />
  </div>;
}

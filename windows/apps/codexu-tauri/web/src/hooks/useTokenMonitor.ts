import { useCallback, useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { requireTauriRuntime } from '../utils/tauri';
import { parseStatisticsState, statisticsFailure, type StatisticsState } from '../utils/tokenMonitor';

export function useTokenMonitor() {
  const [state,setState]=useState<StatisticsState|null>(null);
  const [error,setError]=useState<string|null>(null);
  const [busy,setBusy]=useState(false);
  const generation=useRef(0), alive=useRef(false), operation=useRef<number|null>(null), initialized=useRef(false), invalidated=useRef(false);
  const current=useRef<StatisticsState|null>(null), pendingScope=useRef(false);
  const requestRefresh=useRef<(clearScope?:boolean)=>Promise<void>>(async()=>{});
  const apply=useCallback((raw:unknown,epoch:number)=>{
    if(!alive.current||epoch!==generation.current)return;
    const next=parseStatisticsState(raw);
    if(current.current&&next.revision<current.current.revision)return;
    if(next.snapshot&&current.current?.snapshot?.requestId===next.snapshot.requestId&&current.current.snapshot.collectedAt===next.snapshot.collectedAt&&current.current.contextKey===next.contextKey)next.snapshot=current.current.snapshot;
    const visible=invalidated.current?{...next,snapshot:null,tokenRate:null}:next;
    current.current=visible;setState(visible);setError(null);
  },[]);
  const refresh=useCallback(async(clearScope=false)=>{
    if(!alive.current)return;
    if(operation.current!==null){if(clearScope){pendingScope.current=true;invalidated.current=true;setState(previous=>previous?{...previous,snapshot:null,tokenRate:null}:null);}return;}
    const epoch=++generation.current;operation.current=epoch;setBusy(true);setError(null);
    if(clearScope){invalidated.current=true;setState(previous=>previous?{...previous,snapshot:null,tokenRate:null,phase:'loading'}:null);}
    try{
      requireTauriRuntime();
      const timezone=Intl.DateTimeFormat().resolvedOptions().timeZone;
      if(!timezone)throw Error('statistics_timezone_required');
      // Native validates IANA and cancels an old zone before collection starts.
      await invoke('set_token_monitor_timezone',{timezone});
      if(!alive.current||epoch!==generation.current)return;
      const next=await invoke('refresh_token_monitor_usage');
      if(!alive.current||epoch!==generation.current)return;
      invalidated.current=pendingScope.current;apply(next,epoch);initialized.current=true;
    }catch(error){if(alive.current&&epoch===generation.current)setError(statisticsFailure(error));}
    finally{if(operation.current===epoch)operation.current=null;if(alive.current&&epoch===generation.current)setBusy(false);if(alive.current&&pendingScope.current&&operation.current===null){pendingScope.current=false;queueMicrotask(()=>void requestRefresh.current(true));}}
  },[apply]);
  const selectSources=useCallback(async(sourceIds:string[])=>{
    if(operation.current!==null||!alive.current)return false;
    const epoch=++generation.current;operation.current=epoch;setBusy(true);setError(null);
    try{
      requireTauriRuntime();
      const next=await invoke('set_token_monitor_sources',{sourceIds});
      if(!alive.current||epoch!==generation.current)return false;
      invalidated.current=pendingScope.current;apply(next,epoch);
      const collected=await invoke('refresh_token_monitor_usage');
      apply(collected,epoch);initialized.current=true;return true;
    }catch(error){if(alive.current&&epoch===generation.current)setError(statisticsFailure(error));return false;}
    finally{if(operation.current===epoch)operation.current=null;if(alive.current&&epoch===generation.current)setBusy(false);if(alive.current&&pendingScope.current&&operation.current===null){pendingScope.current=false;queueMicrotask(()=>void requestRefresh.current(true));}}
  },[apply]);
  const cancel=useCallback(async()=>{
    if(!alive.current)return;
    // Cancellation has its own intent generation and can revoke a late refresh.
    const epoch=++generation.current;operation.current=epoch;pendingScope.current=false;setBusy(true);setError(null);
    try{const next=await invoke('cancel_token_monitor_usage');if(alive.current&&epoch===generation.current){invalidated.current=false;apply(next,epoch);}}
    catch(error){if(alive.current&&epoch===generation.current)setError(statisticsFailure(error));}
    finally{if(operation.current===epoch)operation.current=null;if(alive.current&&epoch===generation.current)setBusy(false);}
  },[apply]);
  requestRefresh.current=refresh;
  useEffect(()=>{
    alive.current=true;let disposed=false,polling=false;const unlisteners:Array<()=>void>=[];
    queueMicrotask(()=>{if(!disposed)void refresh();});
    const poll=setInterval(()=>{
      if(!initialized.current||operation.current!==null||polling)return;
      polling=true;const epoch=generation.current;
      void invoke('get_token_monitor_state').then(raw=>apply(raw,epoch)).catch(error=>{if(alive.current&&epoch===generation.current)setError(statisticsFailure(error));}).finally(()=>{polling=false;});
    },1000);
    for(const name of ['settings:changed','profiles:changed','managed-accounts:changed']){
      void listen(name,()=>{if(!disposed&&alive.current)void refresh(true);}).then(unlisten=>{if(!disposed)unlisteners.push(unlisten);else unlisten();}).catch(()=>{if(!disposed&&alive.current)setError('statistics_events_unavailable');});
    }
    return()=>{disposed=true;alive.current=false;generation.current++;operation.current=null;clearInterval(poll);unlisteners.forEach(unlisten=>unlisten());};
  },[apply,refresh]);
  return {state,error,busy,refresh:()=>refresh(),selectSources,cancel};
}
export type TokenMonitorController=ReturnType<typeof useTokenMonitor>;

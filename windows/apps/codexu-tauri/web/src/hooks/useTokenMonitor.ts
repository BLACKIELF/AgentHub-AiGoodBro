import { useCallback, useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { defaultStatisticsTimezone, readStatisticsTimezone, resolveStatisticsTimezone, saveStatisticsTimezone, STATISTICS_TIMEZONE_KEY, type StatisticsTimezonePreference } from '../utils/statisticsTimezone';
import { requireTauriRuntime } from '../utils/tauri';
import { readCustomStatistics } from '../utils/customStatistics';
import { parseStatisticsState, statisticsFailure, type StatisticsState } from '../utils/tokenMonitor';

export function useTokenMonitor(passive=false) {
  const [state,setState]=useState<StatisticsState|null>(null);
  const [error,setError]=useState<string|null>(null);
  const [busy,setBusy]=useState(false);
  const [timezonePreference,setTimezonePreference]=useState<StatisticsTimezonePreference>(defaultStatisticsTimezone);
  const generation=useRef(0), alive=useRef(false), operation=useRef<number|null>(null), invalidated=useRef(false);
  const current=useRef<StatisticsState|null>(null), pendingScope=useRef(false);
  const requestRefresh=useRef<(clearScope?:boolean)=>Promise<void>>(async()=>{});
  const upstreamSelected=()=>{
    try{return readCustomStatistics().engine==='upstream';}
    catch{setError('statistics_preferences_unavailable');return false;}
  };
  const apply=useCallback((raw:unknown,epoch:number)=>{
    if(!alive.current||epoch!==generation.current)return;
    const next=parseStatisticsState(raw);
    const timezone=resolveStatisticsTimezone(readStatisticsTimezone());
    if(current.current&&next.revision<current.current.revision)return;
    // A request ID and timestamp do not prove that a pushed payload is unchanged.
    // Retain the reference only for an identical validated snapshot (for example
    // a rate-only event), otherwise session and chart consumers must see it.
    if(next.snapshot&&current.current?.snapshot&&current.current.contextKey===next.contextKey&&JSON.stringify(current.current.snapshot)===JSON.stringify(next.snapshot))next.snapshot=current.current.snapshot;
    const visible=invalidated.current||next.timezone!==timezone?{...next,snapshot:null,tokenRate:null}:next;
    current.current=visible;setState(visible);setError(null);
  },[]);
  const refresh=useCallback(async(clearScope=false)=>{
    if(!alive.current||!upstreamSelected())return;
    if(operation.current!==null){if(clearScope){pendingScope.current=true;invalidated.current=true;setState(previous=>previous?{...previous,snapshot:null,tokenRate:null}:null);}return;}
    const epoch=++generation.current;operation.current=epoch;setBusy(true);setError(null);
    if(clearScope){invalidated.current=true;setState(previous=>previous?{...previous,snapshot:null,tokenRate:null,phase:'loading'}:null);}
    try{
      requireTauriRuntime();
      const preference=readStatisticsTimezone(),timezone=resolveStatisticsTimezone(preference);
      setTimezonePreference(preference);
      // Native validates IANA and cancels an old zone before collection starts.
      await invoke('set_token_monitor_timezone',{timezone});
      if(!alive.current||epoch!==generation.current||!upstreamSelected())return;
      const next=await invoke('refresh_token_monitor_usage');
      if(!alive.current||epoch!==generation.current)return;
      invalidated.current=pendingScope.current;apply(next,epoch);
    }catch(error){if(alive.current&&epoch===generation.current)setError(statisticsFailure(error));}
    finally{if(operation.current===epoch)operation.current=null;if(alive.current&&epoch===generation.current)setBusy(false);if(alive.current&&pendingScope.current&&operation.current===null){pendingScope.current=false;queueMicrotask(()=>void requestRefresh.current(true));}}
  },[apply]);
  const selectSources=useCallback(async(sourceIds:string[])=>{
    if(operation.current!==null||!alive.current||!upstreamSelected())return false;
    const epoch=++generation.current;operation.current=epoch;setBusy(true);setError(null);
    try{
      requireTauriRuntime();
      const next=await invoke('set_token_monitor_sources',{sourceIds});
      if(!alive.current||epoch!==generation.current||!upstreamSelected())return false;
      invalidated.current=pendingScope.current;apply(next,epoch);
      const collected=await invoke('refresh_token_monitor_usage');
      apply(collected,epoch);return true;
    }catch(error){if(alive.current&&epoch===generation.current)setError(statisticsFailure(error));return false;}
    finally{if(operation.current===epoch)operation.current=null;if(alive.current&&epoch===generation.current)setBusy(false);if(alive.current&&pendingScope.current&&operation.current===null){pendingScope.current=false;queueMicrotask(()=>void requestRefresh.current(true));}}
  },[apply]);
  const selectTimezone=useCallback(async(preference:StatisticsTimezonePreference)=>{
    if(operation.current!==null||!alive.current||!upstreamSelected())return false;
    const epoch=++generation.current;operation.current=epoch;setBusy(true);setError(null);
    invalidated.current=true;setState(previous=>previous?{...previous,snapshot:null,tokenRate:null}:null);
    try{
      const timezone=resolveStatisticsTimezone(preference);
      requireTauriRuntime();
      const configured=await invoke('set_token_monitor_timezone',{timezone});
      if(!alive.current||epoch!==generation.current||!upstreamSelected())return false;
      // Native validates the zone and stops the prior scope before it is saved.
      // A rejected local write remains a visible failure, never a saved choice.
      saveStatisticsTimezone(preference);setTimezonePreference(preference);
      invalidated.current=pendingScope.current;apply(configured,epoch);
      const next=await invoke('refresh_token_monitor_usage');apply(next,epoch);return true;
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
    alive.current=true;let disposed=false;const unlisteners:Array<()=>void>=[];
    try{setTimezonePreference(readStatisticsTimezone());}catch(error){setError(statisticsFailure(error));}
    const stored=(event:StorageEvent)=>{
      if(event.key!==null&&event.key!==STATISTICS_TIMEZONE_KEY)return;
      try{setTimezonePreference(readStatisticsTimezone());}catch(error){setError(statisticsFailure(error));}
      // Other windows read the latest persisted choice at request time. Passive
      // compact windows invalidate/read shared state, never launch a scanner.
      invalidated.current=true;setState(previous=>previous?{...previous,snapshot:null,tokenRate:null}:null);
      if(!passive)void refresh(true);
      else { if(operation.current!==null){pendingScope.current=true;return;} const epoch=++generation.current;void invoke('get_token_monitor_state').then(raw=>{invalidated.current=false;apply(raw,epoch);}).catch(error=>{if(alive.current&&epoch===generation.current)setError(statisticsFailure(error));}); }
    };
    window.addEventListener('storage',stored);
    const subscribe=async()=>{
      const events=[listen<unknown>('token-monitor:changed',event=>{
        if(disposed||!alive.current)return;
        try{apply(event.payload,generation.current);}catch(error){setError(statisticsFailure(error));}
      })];
      if(!passive)for(const name of ['settings:changed','profiles:changed','managed-accounts:changed']){
        events.push(listen(name,()=>{if(!disposed&&alive.current)void refresh(true);}));
      }
      const registrations=await Promise.allSettled(events);
      let failed=false;
      for(const result of registrations){
        if(result.status==='fulfilled'){if(disposed)result.value();else unlisteners.push(result.value);}
        else failed=true;
      }
      if(disposed)return;
      const epoch=generation.current;
      try{const raw=await invoke('get_token_monitor_state');apply(raw,epoch);}
      catch(error){if(!disposed&&alive.current&&epoch===generation.current)setError(statisticsFailure(error));}
      if(disposed)return;
      if(failed){setError('statistics_events_unavailable');return;}
      // Main retains its existing initial collection. Compact consumers only
      // read this shared state and receive native pushes; no extra host/timer.
      if(!passive)void refresh();
    };
    void subscribe();
    return()=>{disposed=true;alive.current=false;generation.current++;operation.current=null;pendingScope.current=false;unlisteners.forEach(unlisten=>unlisten());window.removeEventListener('storage',stored);};
  },[apply,refresh,passive]);
  useEffect(()=>{
    const rate=state?.tokenRate;if(!rate)return;
    const expected=state.contextKey,revision=state.revision;
    // One presentation deadline hides an expired rate without periodic IPC.
    const timer=setTimeout(()=>{
      const previous=current.current;
      if(previous?.contextKey!==expected||previous.revision!==revision||previous.tokenRate?.expiresAt!==rate.expiresAt)return;
      const next={...previous,tokenRate:null};current.current=next;setState(next);
    },Math.max(0,rate.expiresAt-Date.now()));
    return()=>clearTimeout(timer);
  },[state?.contextKey,state?.revision,state?.tokenRate]);
  return {state,error,busy,refresh:()=>refresh(),selectSources,cancel,timezonePreference,selectTimezone};
}
export type TokenMonitorController=ReturnType<typeof useTokenMonitor>;

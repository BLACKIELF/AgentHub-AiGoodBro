import { useCallback,useEffect,useRef,useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { compactFailure,compactProjectionDeadline,expireCompactProjection,parseCompactState,type BubblePreferences,type CompactAction,type CompactPreferences,type CompactState } from '../utils/compactUi';
export function useCompactUi(){
 const [state,setState]=useState<CompactState|null>(null),[error,setError]=useState<string|null>(null),[busy,setBusy]=useState(false);
 const alive=useRef(false),value=useRef<CompactState|null>(null),pending=useRef(false),invalidated=useRef(false),scope=useRef(0),readSerial=useRef(0),activeRead=useRef<number|null>(null),readAgain=useRef(false);
 const lifetime=useRef(0);
 const debounce=useRef<ReturnType<typeof setTimeout>|null>(null),requestRead=useRef<()=>Promise<void>>(async()=>{});
 const apply=useCallback((raw:unknown)=>{
  if(!alive.current)return;let next=expireCompactProjection(parseCompactState(raw));
  if(value.current&&next.revision<value.current.revision)return;
  if(invalidated.current)next={...next,cachedProjection:{...next.cachedProjection,accounts:next.cachedProjection.accounts.map(account=>({...account,active:null,available:false,reasonCode:'compact_source_changed'}))}};
  value.current=next;setState(next);setError(null);
 },[]);
 const read=useCallback(async()=>{
  if(!alive.current)return;
  if(activeRead.current!==null){readAgain.current=true;return;}
  const id=++readSerial.current,epoch=scope.current;activeRead.current=id;
  try{
   const raw=parseCompactState(await invoke('get_compact_ui_state'));
   if(!alive.current||epoch!==scope.current||activeRead.current!==id)return;
   // A late initial read cannot replace a newer pushed cache, even when only
   // the layout appears to have changed. The native revision orders both.
   if(value.current&&raw.revision<value.current.revision)return;
   invalidated.current=false;apply(raw);
  }catch(error){if(alive.current&&epoch===scope.current)setError(compactFailure(error));}
  finally{if(activeRead.current===id){activeRead.current=null;if(readAgain.current&&alive.current){readAgain.current=false;queueMicrotask(()=>void requestRead.current());}}}
 },[apply]);
 requestRead.current=read;
 const run=useCallback(async(command:string,args:Record<string,unknown>)=>{
  if(!alive.current||pending.current)return false;const epoch=lifetime.current;pending.current=true;setBusy(true);setError(null);
  try{const raw=await invoke(command,args);if(!alive.current||epoch!==lifetime.current)return false;apply(raw);return true;}catch(error){if(alive.current&&epoch===lifetime.current)setError(compactFailure(error));return false;}
  finally{if(epoch===lifetime.current){pending.current=false;if(alive.current)setBusy(false);}}
 },[apply]);
 useEffect(()=>{
  alive.current=true;lifetime.current++;let disposed=false;const releases:Array<()=>void>=[];
  const register=async()=>{
   const registrations=await Promise.allSettled([
    listen<unknown>('compact-ui:changed',event=>{if(disposed)return;try{apply(event.payload);}catch(error){setError(compactFailure(error));}}),
    ...['managed-accounts:changed','claude-subscriptions:changed','profiles:changed','quota-display:changed'].map(name=>listen(name,()=>{
     if(disposed)return;scope.current++;invalidated.current=true;
     if(value.current)apply(value.current);
     if(debounce.current)clearTimeout(debounce.current);
     debounce.current=setTimeout(()=>{debounce.current=null;void read();},80);
    })),
   ]);
   let failed=false;for(const result of registrations){if(result.status==='fulfilled'){if(disposed)result.value();else releases.push(result.value);}else failed=true;}
   if(disposed)return;await read();if(failed&&!disposed)setError('compact_events_unavailable');
  };
  void register();
  return()=>{disposed=true;alive.current=false;lifetime.current++;pending.current=false;scope.current++;activeRead.current=null;readAgain.current=false;if(debounce.current)clearTimeout(debounce.current);releases.forEach(release=>release());};
 },[apply,read]);
 useEffect(()=>{
  if(!state)return;const at=compactProjectionDeadline(state);if(at===null)return;
  const timer=setTimeout(()=>{if(value.current){const next=expireCompactProjection(value.current);value.current=next;setState(next);}},Math.max(0,at-Date.now()));
  return()=>clearTimeout(timer);
 },[state]);
 return {state,error,busy,read,retryShortcut:()=>run('retry_compact_ui_shortcut',{}),save:(patch:Partial<CompactPreferences>,expectedBubble?:BubblePreferences)=>run('set_compact_ui_preferences',{patch,...(expectedBubble?{expectedBubble}: {})}),action:(action:CompactAction,itemId?:string)=>run('compact_ui_action',{action,itemId:itemId??null})};
}

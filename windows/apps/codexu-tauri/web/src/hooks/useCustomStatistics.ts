import {useEffect,useRef,useState} from 'react';
import {invoke} from '@tauri-apps/api/core';
import {parseStatisticsState} from '../utils/tokenMonitor';
import {CUSTOM_STATISTICS_EVENT,CUSTOM_STATISTICS_KEY,readCustomStatistics,tokensFromWan,updateCustomStatistics,type CustomStatistics,type StatisticsEngine} from '../utils/customStatistics';
export function useCustomStatistics(){
 const [initial]=useState(()=>{try{return {value:readCustomStatistics(),error:''};}catch{return {value:null,error:'custom_statistics_unavailable'};}});
 const [value,setValue]=useState<CustomStatistics|null>(initial.value),[error,setError]=useState(initial.error),[busy,setBusy]=useState(false);const active=useRef(false),alive=useRef(false);
 function read(){try{setValue(readCustomStatistics());setError('');}catch{setValue(null);setError('custom_statistics_unavailable');}}
 useEffect(()=>{alive.current=true;const storage=(event:StorageEvent)=>{if(event.key===CUSTOM_STATISTICS_KEY||event.key===null)read();};window.addEventListener('storage',storage);window.addEventListener(CUSTOM_STATISTICS_EVENT,read);return()=>{alive.current=false;window.removeEventListener('storage',storage);window.removeEventListener(CUSTOM_STATISTICS_EVENT,read);};},[]);
 async function mutate(change:(value:CustomStatistics)=>CustomStatistics){if(active.current)return false;active.current=true;setBusy(true);setError('');try{await updateCustomStatistics(change,async(previous,next)=>{if(previous.engine==='upstream'&&next.engine==='custom'){const state=parseStatisticsState(await invoke('cancel_token_monitor_usage'));if(state.phase!=='stopped'||state.failureCode!==null)throw Error('custom_statistics_cancel_failed');}});if(alive.current)read();return true;}catch(e){if(alive.current)setError(e instanceof Error?e.message:'custom_statistics_save_failed');return false;}finally{active.current=false;if(alive.current)setBusy(false);}}
 return {value,error,busy,read,setEngine:(engine:StatisticsEngine)=>mutate(value=>({...value,engine})),add:(name:string,input:string)=>mutate(value=>{const entry={name:name.trim(),tokens:tokensFromWan(input)};return {...value,entries:[...value.entries.filter(e=>e.name!==entry.name),entry]};}),remove:(name:string)=>mutate(value=>({...value,entries:value.entries.filter(e=>e.name!==name)}))};
}
export type CustomStatisticsController=ReturnType<typeof useCustomStatistics>;

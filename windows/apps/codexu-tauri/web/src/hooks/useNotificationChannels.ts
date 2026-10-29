import { useCallback, useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { notificationKinds, notificationError, notificationOptionsEqual, parseNotificationChannels, parseNotificationChannel, parseNotificationReceipt, parsePersonalNotificationLogin, personalNotificationLoginActive, type NotificationKind, type NotificationChannel, type NotificationOptions, type NotificationReceipt, type PersonalNotificationLogin } from '../utils/notificationChannels';

type PerChannel<T>=Partial<Record<NotificationKind,T>>;
type Pending={epoch:number;action:string};
const personal:NotificationKind='personal-wechat';
export function useNotificationChannels(){
 const [channels,setChannels]=useState<NotificationChannel[]|null>(null),[fresh,setFresh]=useState<PerChannel<boolean>>({}),[pending,setPending]=useState<PerChannel<Pending>>({}),[errors,setErrors]=useState<PerChannel<string>>({}),[receipts,setReceipts]=useState<PerChannel<NotificationReceipt>>({});
 const [readError,setReadError]=useState<string|null>(null),[reading,setReading]=useState(false),[notice,setNotice]=useState<string|null>(null),[login,setLogin]=useState<PersonalNotificationLogin|null>(null),[loginError,setLoginError]=useState<string|null>(null),[cancelling,setCancelling]=useState(false),[clock,setClock]=useState(Date.now());
 const alive=useRef(false),snapshot=useRef<NotificationChannel[]|null>(null),epochs=useRef<Record<NotificationKind,number>>({feishu:0,telegram:0,wechat:0,'personal-wechat':0}),operations=useRef<PerChannel<Pending>>({}),readEpoch=useRef(0),loginEpoch=useRef(0),attempt=useRef<PersonalNotificationLogin|null>(null),suspended=useRef(false),cancelIntent=useRef(false);
 const putLogin=useCallback((value:PersonalNotificationLogin|null)=>{attempt.current=value;if(alive.current)setLogin(value);},[]);
 const put=useCallback((values:NotificationChannel[],expected:PerChannel<number>)=>{
  if(!alive.current)return;const previous=snapshot.current||[];const next=[...previous];const accepted:NotificationKind[]=[];
  for(const value of values){if(expected[value.channel]!==epochs.current[value.channel])continue;const index=next.findIndex(row=>row.channel===value.channel);const prior=next[index];if(prior&&prior.revision>value.revision)continue;
   if(prior&&prior.revision!==value.revision)setReceipts(old=>({...old,[value.channel]:undefined}));
   if(index<0)next.push(value);else next[index]=value;accepted.push(value.channel);
  }
  next.sort((a,b)=>notificationKinds.indexOf(a.channel)-notificationKinds.indexOf(b.channel));snapshot.current=next;setChannels(next);setFresh(old=>({...old,...Object.fromEntries(accepted.map(channel=>[channel,true]))}));
 },[]);
 const read=useCallback(async(restore=false)=>{
  const readId=++readEpoch.current,expected={...epochs.current};if(alive.current)setReading(true);
  try{const values=parseNotificationChannels(await invoke(restore?'restore_notification_channels':'get_notification_channels'));if(!alive.current||readId!==readEpoch.current)return null;put(values,expected);setReadError(null);if(restore)setNotice('restored');return values;}
  catch(error){if(alive.current&&readId===readEpoch.current){setReadError(notificationError(error));setFresh({});}return null;}
  finally{if(alive.current&&readId===readEpoch.current)setReading(false);}
 },[put]);
 const perform=useCallback(async<T,>(channel:NotificationKind,action:string,work:(current:()=>boolean)=>Promise<T>,affected:NotificationKind[]=[channel],override=false):Promise<T|null>=>{
  if(!alive.current||!override&&affected.some(kind=>operations.current[kind]))return null;
  const expected:PerChannel<number>={};for(const kind of affected){const epoch=++epochs.current[kind];expected[kind]=epoch;operations.current[kind]={epoch,action};}
  setPending({...operations.current});setErrors(old=>({...old,...Object.fromEntries(affected.map(kind=>[kind,undefined]))}));setNotice(null);
  const current=()=>alive.current&&affected.every(kind=>epochs.current[kind]===expected[kind]);
  try{return await work(current);}
  catch(error){if(current()){setErrors(old=>({...old,[channel]:notificationError(error)}));setFresh(old=>({...old,...Object.fromEntries(affected.map(kind=>[kind,false]))}));void read();}return null;}
  finally{for(const kind of affected)if(operations.current[kind]?.epoch===expected[kind])delete operations.current[kind];if(alive.current)setPending({...operations.current});}
 },[read]);
 const update=useCallback(async(channel:NotificationKind,command:string,args:Record<string,unknown>,action:string,override=false)=>perform(channel,action,async current=>{
  const value=parseNotificationChannel(await invoke(command,command==='refresh_personal_wechat_context'?args:{channel,...args}),channel);if(!current())return null;put([value],{[channel]:epochs.current[channel]});return value;
 },[channel],override),[perform,put]);
 const cancel=useCallback(async(channel:NotificationKind)=>{
  const expected=channel===personal?++loginEpoch.current:0;
  if(channel===personal){suspended.current=true;cancelIntent.current=true;setCancelling(true);setLoginError(null);if(attempt.current)putLogin({...attempt.current,qrContent:null});}
  const value=await update(channel,'cancel_notification_channel',{},'cancel',true);
  if(channel===personal&&expected!==loginEpoch.current)return false;
  if(channel===personal&&alive.current){setCancelling(false);if(value){putLogin(attempt.current?{...attempt.current,phase:'cancelled',qrContent:null}:null);suspended.current=false;cancelIntent.current=false;setLoginError(null);}else setLoginError('notification_cancel_unconfirmed');}
  return !!value;
 },[putLogin,update]);
 const enable=useCallback(async(channel:NotificationKind,enabled:boolean)=>{
  if(channel===personal){loginEpoch.current++;suspended.current=true;cancelIntent.current=true;setCancelling(false);if(attempt.current)putLogin({...attempt.current,qrContent:null});}
  const value=await update(channel,'set_notification_channel_enabled',{enabled},'enable',!enabled);
  if(value&&channel===personal){putLogin(null);suspended.current=false;cancelIntent.current=false;setLoginError(null);}return !!value;
 },[putLogin,update]);
 const save=useCallback(async(channel:NotificationKind,secret:string,target:string|null)=>perform(channel,'save',async current=>{
  const value=parseNotificationChannel(await invoke('save_notification_channel',{channel,secret,target}),channel);
  if(!value.credentialPresent||channel==='telegram'&&!value.targetPresent)throw Error('notification_invalid_response');
  if(!current())return false;put([value],{[channel]:epochs.current[channel]});return true;
 }),[perform,put]);
 const saveOptions=useCallback(async(channel:NotificationKind,options:NotificationOptions)=>{
  const affected:NotificationKind[]=channel==='wechat'||channel===personal?['wechat',personal]:[channel];
  return !!await perform(channel,'options',async current=>{
   const value=parseNotificationChannel(await invoke('set_notification_channel_options',{channel,options}),channel);
   if(!notificationOptionsEqual(value.options,options))throw Error('notification_invalid_response');
   const expected={...epochs.current};
   const values=affected.length===1?[value]:parseNotificationChannels(await invoke('get_notification_channels'));
   if(affected.some(kind=>!values.find(row=>row.channel===kind)||!notificationOptionsEqual(values.find(row=>row.channel===kind)!.options,options)))throw Error('notification_invalid_response');
   if(!current())return false;put(values,expected);return true;
  },affected);
 },[perform,put]);
 const forget=useCallback(async(channel:NotificationKind)=>{
  if(channel===personal){loginEpoch.current++;suspended.current=true;cancelIntent.current=true;setCancelling(false);if(attempt.current)putLogin({...attempt.current,qrContent:null});}
  const value=await update(channel,'forget_notification_channel',{},'forget');
  if(value&&(value.enabled||value.credentialPresent||value.targetPresent)){setErrors(old=>({...old,[channel]:'notification_invalid_response'}));return false;}
  if(value&&channel===personal){putLogin(null);cancelIntent.current=false;suspended.current=false;setLoginError(null);}return !!value;
 },[putLogin,update]);
 const test=useCallback(async(channel:NotificationKind)=>perform(channel,'test',async current=>{
  const revision=snapshot.current?.find(row=>row.channel===channel)?.revision;setReceipts(old=>({...old,[channel]:undefined}));
  const receipt=parseNotificationReceipt(await invoke('test_notification_channel',{channel}),channel);
  if(!current())return false;
  const values=await read();if(!current())return false;
  const actual=values?.find(row=>row.channel===channel)||snapshot.current?.find(row=>row.channel===channel);
  if(actual?.revision!==revision)throw Error('configuration_changed');
  setReceipts(old=>({...old,[channel]:receipt}));return true;
 }),[perform,read]);
 const refreshContext=useCallback(async()=>update(personal,'refresh_personal_wechat_context',{},'context'),[update]);
 const begin=useCallback(async()=>{
  if(operations.current[personal]||personalNotificationLoginActive(attempt.current))return;
  const expected=++loginEpoch.current;suspended.current=false;cancelIntent.current=false;setLoginError(null);putLogin(null);
  await perform(personal,'begin',async current=>{
   const value=parsePersonalNotificationLogin(await invoke('begin_personal_wechat_login'));
   if(!current()||expected!==loginEpoch.current)return false;putLogin(value);void read();return true;
  });
 },[perform,putLogin,read]);
 const checkLogin=useCallback(async(verificationCode?:string,passive=false)=>{
  const old=attempt.current;if(!old||!personalNotificationLoginActive(old))return false;
  const expected=loginEpoch.current;
  const result=await perform(personal,passive?'login-state':'poll',async current=>{
   const value=parsePersonalNotificationLogin(await invoke(passive?'get_personal_wechat_login':'poll_personal_wechat_login',{attemptId:old.attemptId,...(passive?{}:{verificationCode:verificationCode??null})}),old.attemptId);
   if(!current()||expected!==loginEpoch.current)return false;
   putLogin(value);if(!personalNotificationLoginActive(value)){suspended.current=false;cancelIntent.current=false;}else if(!cancelIntent.current)suspended.current=false;
   setLoginError(null);if(!personalNotificationLoginActive(value))void read();return true;
  });
  if(!result&&alive.current&&expected===loginEpoch.current)suspended.current=true;
  return !!result;
 },[perform,putLogin,read]);
 const check=useRef(checkLogin),cancelCurrent=useRef(cancel);check.current=checkLogin;cancelCurrent.current=cancel;
 useEffect(()=>{
  alive.current=true;let disposed=false;queueMicrotask(()=>{if(!disposed)void read();});
  let unlisten:(()=>void)|undefined;
  void listen('notification-channels:changed',()=>{if(!disposed)void read();}).then(release=>{if(disposed)release();else unlisten=release;}).catch(()=>{if(!disposed)setReadError('notification_events_unavailable');});
  const timer=setInterval(()=>{
   setClock(Date.now());const active=attempt.current;if(!active||!personalNotificationLoginActive(active))return;
   if(active.expiresAt*1000<=Date.now()&&!cancelIntent.current){
    void cancelCurrent.current(personal).then(ok=>{if(ok&&!disposed&&attempt.current?.attemptId===active.attemptId)putLogin({...active,phase:'local_timeout',qrContent:null});});return;
   }
   if(suspended.current)return;
   if(!operations.current[personal]&&active.phase!=='verification_required')void check.current(undefined,active.phase==='starting');
  },2000);
  return()=>{disposed=true;alive.current=false;readEpoch.current++;loginEpoch.current++;clearInterval(timer);unlisten?.();for(const channel of notificationKinds)epochs.current[channel]++;if(personalNotificationLoginActive(attempt.current)||operations.current[personal]?.action==='begin')void invoke('cancel_notification_channel',{channel:personal}).catch(()=>{});attempt.current=null;};
 },[putLogin,read]);
 return {channels,fresh,pending,errors,receipts,readError,reading,notice,login,loginError,cancelling,clock,read:()=>read(),restore:()=>read(true),enable,save,saveOptions,forget,test,cancel,begin,checkLogin,refreshContext};
}
export type NotificationController=ReturnType<typeof useNotificationChannels>;

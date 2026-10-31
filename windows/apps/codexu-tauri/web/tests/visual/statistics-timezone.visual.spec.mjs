import {test,expect} from '@playwright/test';
import {readFileSync} from 'node:fs';
import {installTauriStub} from './tauri-stub.mjs';
import {SYNTHETIC_DASHBOARD,SYNTHETIC_SETTINGS} from './synthetic-fixtures.mjs';
const fixture=JSON.parse(readFileSync(new URL('../../../../../token-monitor/tests/fixtures/handler-snapshot.json',import.meta.url),'utf8'));
const key='aigoodbro.statistics.timezone.v1';
async function setup(context,page,{saved=null}={}){
 let state={phase:'ready',revision:1,contextKey:'a'.repeat(64),timezone:'UTC',sources:[{id:'codex-synthetic',providerId:'codex',label:'Codex synthetic',enabled:true},{id:'claude-synthetic',providerId:'claude',label:'Claude synthetic',enabled:true}],snapshot:{...structuredClone(fixture),timezone:'UTC'},tokenRate:null,failureCode:null};
 const calls=[];let heldPage=null,releaseHeld=null,held=false;
 await context.exposeBinding('__timezoneNative',async({page},command,args)=>{
  calls.push({page,command,args:structuredClone(args??{})});
  if(command==='set_token_monitor_timezone'){
   state={...state,timezone:args.timezone,revision:state.revision+1,snapshot:null,contextKey:null};
  }
  if(command==='refresh_token_monitor_usage'){
   state={...state,revision:state.revision+1,contextKey:'a'.repeat(64),snapshot:{...structuredClone(fixture),timezone:state.timezone}};
  }
  const result=structuredClone(state);if(command==='refresh_token_monitor_usage'&&page===heldPage){heldPage=null;held=true;await new Promise(resolve=>{releaseHeld=resolve;});}return result;
 });
 const prepare=async(target,label='main')=>{
  const custom=new Function(`
   localStorage.setItem('aigoodbro.workspace.page','usage');
   if(${JSON.stringify(saved)}!==null&&!localStorage.getItem(${JSON.stringify(key)}))localStorage.setItem(${JSON.stringify(key)},JSON.stringify(${JSON.stringify(saved)}));
   const original=window.__TAURI_INTERNALS__.invoke;window.zoneHandlers=[];
   window.pushZoneState=value=>{for(const handler of window.zoneHandlers)window['_'+handler]({event:'token-monitor:changed',payload:value,id:3});};
   window.__TAURI_INTERNALS__.invoke=async(command,args)=>{
    if(command==='plugin:event|listen'&&args.event==='token-monitor:changed')window.zoneHandlers.push(args.handler);
    if(['get_token_monitor_state','set_token_monitor_timezone','refresh_token_monitor_usage'].includes(command))return window.__timezoneNative(command,args);
    return original(command,args);
   };
  `);
  await installTauriStub(target,{settings:{...SYNTHETIC_SETTINGS,language:'en'},dashboard:SYNTHETIC_DASHBOARD,windowLabel:label},custom);
  await target.goto('/');
 };
 await prepare(page);const panel=page.getByRole('region',{name:'Token Monitor statistics',exact:true});await expect(panel.getByTestId('token-monitor-allTime')).toContainText('300');
 return {panel,calls,prepare,state:()=>structuredClone(state),holdRefresh:target=>{heldPage=target;},isHeld:()=>held,release:()=>releaseHeld?.()};
}
async function change(panel,zone){await panel.locator('.token-monitor-timezone summary').click();await panel.getByLabel('Usage time zone',{exact:true}).selectOption('fixed');await panel.getByLabel('Fixed time zone',{exact:true}).fill(zone);await panel.getByRole('button',{name:'Save time zone',exact:true}).click();}
test('saved fixed zone is applied before first collection and survives reload',async({context,page})=>{
 const {panel,calls}=await setup(context,page,{saved:{selection:'fixed',fixedIdentifier:'Asia/Shanghai'}});
 expect(calls.filter(c=>c.command==='set_token_monitor_timezone')[0].args.timezone).toBe('Asia/Shanghai');
 expect(calls.findIndex(c=>c.command==='set_token_monitor_timezone')).toBeLessThan(calls.findIndex(c=>c.command==='refresh_token_monitor_usage'));
 await page.reload();await expect(panel.getByTestId('token-monitor-allTime')).toContainText('300');
 expect(calls.filter(c=>c.command==='set_token_monitor_timezone').every(c=>c.args.timezone==='Asia/Shanghai')).toBe(true);
});
test('main and compact share the current saved zone and late old-scope pushes stay hidden',async({context,page})=>{
 const {panel,calls,prepare,state}=await setup(context,page);
 const compact=await context.newPage();await prepare(compact,'token-monitor-popover');
 await expect(compact.getByTestId('token-monitor-compact').locator('.compact-total')).toHaveText('300');
 const old=state();await change(panel,'America/Los_Angeles');
 await expect(panel).toContainText('America/Los_Angeles');
 await expect.poll(()=>compact.evaluate(key=>JSON.parse(localStorage.getItem(key)).fixedIdentifier,key)).toBe('America/Los_Angeles');
 await compact.getByRole('button',{name:'Refresh statistics',exact:true}).click();
 await expect.poll(()=>calls.filter(c=>c.page===compact&&c.command==='set_token_monitor_timezone').length).toBe(1);
 expect(calls.filter(c=>c.page===compact&&c.command==='set_token_monitor_timezone')[0].args.timezone).toBe('America/Los_Angeles');
 old.revision=0;old.snapshot.payload.aggregate.allTime.totalTokens=999999;
 await page.evaluate(old=>window.pushZoneState(old),old);await compact.evaluate(old=>window.pushZoneState(old),old);
 await expect(panel.getByTestId('token-monitor-allTime')).toContainText('300');await expect(compact.getByTestId('token-monitor-compact').locator('.compact-total')).toHaveText('300');
 await compact.close();
});
test('denied preference write retains old saved choice and never reports saved',async({context,page})=>{
 const {panel}=await setup(context,page);
 await page.evaluate(key=>{const original=Storage.prototype.setItem;Storage.prototype.setItem=function(k,v){if(k===key)throw Error('denied');return original.call(this,k,v);};},key);
 await change(panel,'Asia/Shanghai');
 await expect(panel.getByRole('alert')).toContainText('could not be saved');await expect(panel).not.toContainText('Time zone saved');
 expect(await page.evaluate(key=>localStorage.getItem(key),key)).toBe(null);
 await expect(panel.getByTestId('token-monitor-allTime')).toContainText('—');
});

test('a zone change during compact refresh releases busy and collects the latest scope',async({context,page})=>{
 const f=await setup(context,page),compact=await context.newPage();await f.prepare(compact,'token-monitor-popover');
 const refresh=compact.getByRole('button',{name:'Refresh statistics',exact:true});f.holdRefresh(compact);await refresh.click();await expect.poll(f.isHeld).toBe(true);
 await change(f.panel,'Asia/Shanghai');await expect(f.panel).toContainText('Time zone saved');
 await expect.poll(()=>compact.evaluate(key=>JSON.parse(localStorage.getItem(key)).fixedIdentifier,key)).toBe('Asia/Shanghai');
 f.release();await expect(refresh).toBeEnabled();await expect.poll(()=>f.calls.filter(c=>c.page===compact&&c.command==='set_token_monitor_timezone').at(-1)?.args.timezone).toBe('Asia/Shanghai');
 await expect(compact.getByTestId('token-monitor-compact').locator('.compact-total')).toHaveText('300');await compact.close();
});

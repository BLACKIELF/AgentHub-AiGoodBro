import {test,expect} from '@playwright/test';
import {readFileSync,writeFileSync} from 'node:fs';
import {installTauriStub} from './tauri-stub.mjs';
import {SYNTHETIC_DASHBOARD,SYNTHETIC_SETTINGS} from './synthetic-fixtures.mjs';
const fixture=JSON.parse(readFileSync(new URL('../../../../../token-monitor/tests/fixtures/handler-snapshot.json',import.meta.url),'utf8'));
const key='aigoodbro.statistics.custom.v1';
const saved={version:1,revision:1,engine:'custom',entries:[{name:'Manual fixture',tokens:'9007199254740993'}]};
async function setup(context,page,{initial=null,holdStartupTimezone=false}={}){
 const exerciseStartup=holdStartupTimezone;
 let state={phase:'ready',revision:1,contextKey:'a'.repeat(64),timezone:'UTC',sources:[{id:'codex-synthetic',providerId:'codex',label:'Codex synthetic',enabled:true},{id:'claude-synthetic',providerId:'claude',label:'Claude synthetic',enabled:true}],snapshot:{...structuredClone(fixture),timezone:'UTC'},tokenRate:null,failureCode:null};
 const calls=[];let hold=null,release,entered=false,startupEntered=false,releaseStartup;
 await context.exposeBinding('__customNative',async(_,command,args,engine)=>{
  calls.push({command,args:structuredClone(args??{}),engine});
  if(command==='set_token_monitor_timezone')state={...state,timezone:args.timezone,revision:state.revision+1,snapshot:null};
  if(command==='refresh_token_monitor_usage')state={...state,phase:'ready',revision:state.revision+1,contextKey:'a'.repeat(64),snapshot:{...structuredClone(fixture),timezone:state.timezone}};
  if(command==='cancel_token_monitor_usage')state={...state,phase:'stopped',revision:state.revision+1,contextKey:null,snapshot:null};
  const result=structuredClone(state);
  if(holdStartupTimezone&&command==='set_token_monitor_timezone'){
   holdStartupTimezone=false;startupEntered=true;await new Promise(r=>{releaseStartup=r;});
  }else if(command===hold){hold=null;entered=true;await new Promise(r=>{release=r;});}return result;
 });
 async function prepare(target,label='main'){
  const extra=new Function(`
   localStorage.setItem('aigoodbro.workspace.page','usage');
   if(${JSON.stringify(initial)}!==null&&!localStorage.getItem(${JSON.stringify(key)}))localStorage.setItem(${JSON.stringify(key)},JSON.stringify(${JSON.stringify(initial)}));
   const old=window.__TAURI_INTERNALS__.invoke;window.customListeners=[];
   window.customPush=(name,payload)=>{for(const event of window.customListeners)if(event.event===name)window['_'+event.handler]({event:name,payload,id:1});};
   window.__TAURI_INTERNALS__.invoke=(command,args)=>{if(command==='plugin:event|listen')window.customListeners.push(args);if(['get_token_monitor_state','set_token_monitor_timezone','set_token_monitor_sources','refresh_token_monitor_usage','cancel_token_monitor_usage'].includes(command))return window.__customNative(command,args,JSON.parse(localStorage.getItem(${JSON.stringify(key)})||'{"engine":"upstream"}').engine);return old(command,args);};
  `);
  await installTauriStub(target,{settings:{...SYNTHETIC_SETTINGS,language:'en'},dashboard:SYNTHETIC_DASHBOARD,windowLabel:label},extra);await target.goto('/');
 }
 await prepare(page);
 const f={calls,prepare,state:()=>structuredClone(state),hold:(command='refresh_token_monitor_usage')=>{hold=command;entered=false;},entered:()=>entered,release:()=>release?.(),startupEntered:()=>startupEntered,releaseStartup:()=>releaseStartup?.()};
 // Ordinary upstream cases must finish startup before arming a manual hold or
 // counting subsequent requests. Only the explicit startup fixtures opt out.
 if(initial?.engine!=='custom'&&!exerciseStartup)await waitForInitialCollection(page,f);
 return f;
}
async function waitForInitialCollection(page,f){
 // The initial state already contains a snapshot. Its visible total does not
 // mean that the separate startup collection has completed.
 await expect.poll(()=>f.calls.filter(c=>c.command==='refresh_token_monitor_usage').length).toBe(1);
 await expect(page.getByRole('button',{name:'Refresh',exact:true})).toBeEnabled();
}
async function add(page,name,tokens){const panel=page.getByRole('region',{name:'Custom recorded cumulative',exact:true});await panel.locator('summary').click();await panel.getByLabel('Source name',{exact:true}).fill(name);await panel.getByLabel('Lifetime tokens in 10,000s').fill(tokens);await panel.getByRole('button',{name:'Save custom source',exact:true}).click();await expect(panel.getByRole('status')).toHaveText('Custom source saved.');}
test('saved custom starts without collector and every existing main/compact refresh remains local',async({context,page})=>{
 const f=await setup(context,page,{initial:saved});await expect(page.getByTestId('custom-statistics-total')).toHaveText('9,007,199,254,740,993');
 const compact=await context.newPage();await f.prepare(compact,'token-monitor-popover');await expect(compact.locator('.compact-total')).toHaveText('9,007,199,254,740,993');
 await compact.getByRole('button',{name:'Refresh statistics',exact:true}).click();
 await page.getByRole('button',{name:'Refresh',exact:true}).click();
 await page.evaluate(()=>{window.customPush('profiles:changed',{});window.customPush('settings:changed',{});});
 await expect(page.getByTestId('custom-statistics-total')).toHaveText('9,007,199,254,740,993');
 expect(f.calls.filter(c=>c.command==='refresh_token_monitor_usage')).toHaveLength(0);
 await expect(page.getByRole('region',{name:'Token Monitor statistics',exact:true})).toHaveCount(0);await expect(compact.getByRole('img',{name:'180-day activity heatmap'})).toHaveCount(0);
 await page.reload();await expect(page.getByTestId('custom-statistics-total')).toHaveText('9,007,199,254,740,993');expect(f.calls.filter(c=>c.command==='refresh_token_monitor_usage')).toHaveLength(0);await compact.close();
});
test('late collector and queued scope cannot overwrite custom or start a hidden collection; upstream can resume',async({context,page})=>{
 const f=await setup(context,page);await expect(page.getByTestId('token-monitor-allTime')).toContainText('300');
 f.hold();await page.getByRole('button',{name:'Refresh',exact:true}).click();await expect.poll(f.entered).toBe(true);
 await page.evaluate(()=>window.dispatchEvent(new StorageEvent('storage',{key:'aigoodbro.statistics.timezone.v1'})));
 await page.getByLabel('Statistics mode',{exact:true}).selectOption('custom');await expect(page.getByRole('region',{name:'Custom recorded cumulative',exact:true})).toBeVisible();
 const before=f.calls.filter(c=>c.command==='refresh_token_monitor_usage').length;f.release();
 await page.evaluate(s=>window.customPush('token-monitor:changed',s),f.state());
 await page.getByRole('button',{name:'Refresh',exact:true}).click();await expect(page.getByRole('region',{name:'Custom recorded cumulative',exact:true})).toBeVisible();
 expect(f.calls.filter(c=>c.command==='refresh_token_monitor_usage')).toHaveLength(before);expect(f.calls.some(c=>c.command==='cancel_token_monitor_usage')).toBe(true);
 await page.getByLabel('Statistics mode',{exact:true}).selectOption('upstream');await expect(page.getByTestId('token-monitor-allTime')).toContainText('300');expect(f.calls.filter(c=>c.command==='refresh_token_monitor_usage').length).toBeGreaterThan(before);
});
test('two windows serialize manual changes, retain both entries, and reload exact totals',async({context,page})=>{
 const f=await setup(context,page,{initial:{...saved,entries:[]}}),second=await context.newPage();await f.prepare(second);
 await Promise.all([add(page,'First','900719925474.0993'),add(second,'Second','.0001')]);
 await expect(page.getByTestId('custom-statistics-total')).toHaveText('9,007,199,254,740,994');await expect(second.getByTestId('custom-statistics-total')).toHaveText('9,007,199,254,740,994');
 await page.reload();await expect(page.getByTestId('custom-statistics-total')).toHaveText('9,007,199,254,740,994');expect(f.calls.filter(c=>c.command==='refresh_token_monitor_usage')).toHaveLength(0);await second.close();
});
test('storage rejection retains the saved engine and does not claim custom was saved',async({context,page})=>{
 await setup(context,page);await expect(page.getByTestId('token-monitor-allTime')).toContainText('300');
 await page.evaluate(key=>{const old=Storage.prototype.setItem;Storage.prototype.setItem=function(k,v){if(k===key)throw Error('denied');return old.call(this,k,v);};},key);
 await page.getByLabel('Statistics mode',{exact:true}).selectOption('custom');await expect(page.getByRole('alert').filter({hasText:'Statistics settings could not'})).toBeVisible();
 await expect(page.getByLabel('Statistics mode',{exact:true})).toHaveValue('upstream');await expect(page.getByRole('region',{name:'Custom recorded cumulative',exact:true})).toHaveCount(0);expect(await page.evaluate(key=>localStorage.getItem(key),key)).toBe(null);
});
test('a stale window checks the persisted mode before refresh even before its storage notification arrives',async({context,page})=>{
 const f=await setup(context,page);await expect(page.getByTestId('token-monitor-allTime')).toContainText('300');
 const before=f.calls.filter(c=>c.command==='refresh_token_monitor_usage').length;
 // A write in this document emits no storage event, faithfully retaining the
 // old rendered selection until the cross-window notification is delivered.
 await page.evaluate(({key,saved})=>localStorage.setItem(key,JSON.stringify(saved)),{key,saved});
 await page.getByRole('button',{name:'Refresh',exact:true}).click();
 expect(f.calls.filter(c=>c.command==='refresh_token_monitor_usage')).toHaveLength(before);
 await page.evaluate(key=>window.dispatchEvent(new StorageEvent('storage',{key})),key);
 await expect(page.getByTestId('custom-statistics-total')).toHaveText('9,007,199,254,740,993');
});

for(const action of ['refresh','sources','timezone'])test(`a held ${action} prerequisite cannot restart collection after custom is persisted`,async({context,page})=>{
 const f=await setup(context,page);await expect(page.getByTestId('token-monitor-allTime')).toContainText('300');
 const before=f.calls.filter(c=>c.command==='refresh_token_monitor_usage').length;
 f.hold(action==='sources'?'set_token_monitor_sources':'set_token_monitor_timezone');
 const panel=page.getByRole('region',{name:'Token Monitor statistics',exact:true});
 if(action==='refresh')await page.getByRole('button',{name:'Refresh',exact:true}).click();
 else if(action==='sources'){
  await panel.locator('.token-monitor-source-bar summary').click();await panel.getByLabel('Claude synthetic',{exact:false}).uncheck();await panel.getByRole('button',{name:'Save sources',exact:true}).click();
 }else{
  await panel.locator('.token-monitor-timezone summary').click();await panel.getByLabel('Usage time zone',{exact:true}).selectOption('fixed');await panel.getByLabel('Fixed time zone',{exact:true}).fill('Asia/Shanghai');await panel.getByRole('button',{name:'Save time zone',exact:true}).click();
 }
 await expect.poll(f.entered).toBe(true);
 // Delayed storage notification: native cancellation has completed and the new
 // mode is persisted, while this older window still renders its prior mode.
 await page.evaluate(async({key,saved})=>{await window.__TAURI_INTERNALS__.invoke('cancel_token_monitor_usage');localStorage.setItem(key,JSON.stringify(saved));},{key,saved});
 f.release();await expect(page.getByRole('button',{name:'Refresh',exact:true})).toBeEnabled();
 expect(f.calls.filter(c=>c.command==='refresh_token_monitor_usage')).toHaveLength(before);
 if(action==='timezone')expect(await page.evaluate(()=>localStorage.getItem('aigoodbro.statistics.timezone.v1'))).toBe(null);
 await page.evaluate(key=>window.dispatchEvent(new StorageEvent('storage',{key})),key);
 await expect(page.getByTestId('custom-statistics-total')).toHaveText('9,007,199,254,740,993');
 expect(f.calls.filter(c=>c.command==='refresh_token_monitor_usage')).toHaveLength(before);
});

test('a visible saved snapshot precedes startup collection; only the later explicit prerequisite is cancelled by custom',async({context,page},testInfo)=>{
 const f=await setup(context,page,{holdStartupTimezone:true});
 await expect(page.getByTestId('token-monitor-allTime')).toContainText('300');
 await expect.poll(f.startupEntered).toBe(true);
 const refresh=page.getByRole('button',{name:'Refresh',exact:true});
 await expect(refresh).toBeDisabled();
 const earlyCount=f.calls.filter(c=>c.command==='refresh_token_monitor_usage').length;
 expect(earlyCount).toBe(0);
 f.hold('set_token_monitor_timezone');
 const clicked=refresh.click();f.releaseStartup();await clicked;
 await expect.poll(f.entered).toBe(true);
 const before=f.calls.filter(c=>c.command==='refresh_token_monitor_usage').length;
 expect(before).toBe(1);
 expect(f.calls.filter(c=>c.command==='refresh_token_monitor_usage').map(c=>c.engine)).toEqual(['upstream']);
 await page.evaluate(async({key,saved})=>{await window.__TAURI_INTERNALS__.invoke('cancel_token_monitor_usage');localStorage.setItem(key,JSON.stringify(saved));},{key,saved});
 f.release();await expect(refresh).toBeEnabled();
 expect(f.calls.filter(c=>c.command==='refresh_token_monitor_usage')).toHaveLength(before);
 await page.evaluate(key=>window.dispatchEvent(new StorageEvent('storage',{key})),key);
 await expect(page.getByTestId('custom-statistics-total')).toHaveText('9,007,199,254,740,993');
 expect(f.calls.filter(c=>c.command==='refresh_token_monitor_usage')).toHaveLength(before);
 const evidence=testInfo.outputPath('startup-and-explicit-collection-order.json');
 writeFileSync(evidence,JSON.stringify({earlyCount,before,calls:f.calls},null,2));
 await testInfo.attach('startup-and-explicit-collection-order',{path:evidence,contentType:'application/json'});
});

test('a hold armed before startup can disable Refresh; the startup barrier reserves the later explicit hold',async({context,page},testInfo)=>{
 const f=await setup(context,page,{holdStartupTimezone:true});
 await expect(page.getByTestId('token-monitor-allTime')).toContainText('300');
 await expect.poll(f.startupEntered).toBe(true);
 const refresh=page.getByRole('button',{name:'Refresh',exact:true});
 f.hold();f.releaseStartup();await expect.poll(f.entered).toBe(true);
 await expect(refresh).toBeDisabled();
 let oldClickTimedOut=false;
 try{await refresh.click({timeout:500});}catch(error){oldClickTimedOut=error.name==='TimeoutError';}
 expect(oldClickTimedOut).toBe(true);
 expect(f.calls.filter(c=>c.command==='refresh_token_monitor_usage')).toHaveLength(1);
 f.release();await waitForInitialCollection(page,f);
 f.hold();await refresh.click();await expect.poll(f.entered).toBe(true);
 const before=f.calls.filter(c=>c.command==='refresh_token_monitor_usage').length;
 expect(before).toBe(2);
 await page.getByLabel('Statistics mode',{exact:true}).selectOption('custom');
 await expect(page.getByRole('region',{name:'Custom recorded cumulative',exact:true})).toBeVisible();
 f.release();await expect(refresh).toBeEnabled();await refresh.click();
 expect(f.calls.filter(c=>c.command==='refresh_token_monitor_usage')).toHaveLength(before);
 expect(f.calls.filter(c=>c.command==='refresh_token_monitor_usage').every(c=>c.engine==='upstream')).toBe(true);
 const evidence=testInfo.outputPath('startup-hold-and-manual-hold-order.json');
 writeFileSync(evidence,JSON.stringify({oldClickTimedOut,before,calls:f.calls},null,2));
 await testInfo.attach('startup-hold-and-manual-hold-order',{path:evidence,contentType:'application/json'});
});

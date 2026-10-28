import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { installTauriStub } from './tauri-stub.mjs';
import { SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
const fixture=JSON.parse(readFileSync(new URL('../../../../../token-monitor/tests/fixtures/handler-snapshot.json',import.meta.url),'utf8'));
const initial=()=>({phase:'ready',revision:1,contextKey:'a'.repeat(64),timezone:'UTC',sources:[{id:'codex-synthetic',providerId:'codex',label:'Codex synthetic',enabled:true},{id:'claude-synthetic',providerId:'claude',label:'Claude synthetic',enabled:true}],snapshot:{...structuredClone(fixture),timezone:'UTC'},tokenRate:null,failureCode:null});
async function setup(page,{language='en',theme='dark',failSave=false,delayRefresh=false,missingZone=false}={}){
  await page.route('**/*',route=>route.request().url().startsWith('http://127.0.0.1:')?route.continue():route.abort());
  const script=new Function(`
    localStorage.setItem('aigoodbro.workspace.page','usage');
    const original=window.__TAURI_INTERNALS__.invoke;
    window.tmState=${JSON.stringify(initial())};window.tmCalls=[];window.tmListeners={};window.tmFailSave=${failSave};window.tmDelay=${delayRefresh};window.tmRefreshCount=0;
    window.tmEmit=(event)=>{for(const callback of window.tmListeners[event]||[])window['_'+callback]({event,payload:null,id:1});};
    window.__TAURI_INTERNALS__.invoke=async(command,args)=>{
      if(command==='plugin:event|listen'){(window.tmListeners[args.event]||=[]).push(args.handler);return original(command,args);}
      if(command.includes('token_monitor'))window.tmCalls.push({command,args:structuredClone(args||{})});
      if(command==='set_token_monitor_timezone'){window.tmState.timezone=args.timezone;window.tmState.snapshot.timezone=args.timezone;return structuredClone(window.tmState);}
      if(command==='refresh_token_monitor_usage'){
        window.tmRefreshCount++;
        if(window.tmDelay&&window.tmRefreshCount>1)return new Promise(resolve=>{window.tmResolve=()=>resolve({...structuredClone(window.tmState),phase:'ready',revision:100,snapshot:{...structuredClone(window.tmState.snapshot),payload:{...structuredClone(window.tmState.snapshot.payload),aggregate:{...structuredClone(window.tmState.snapshot.payload.aggregate),allTime:{...structuredClone(window.tmState.snapshot.payload.aggregate.allTime),totalTokens:999999}}}}});});
        return structuredClone(window.tmState);
      }
      if(command==='get_token_monitor_state')return structuredClone(window.tmState);
      if(command==='set_token_monitor_sources'){
        if(window.tmFailSave)throw 'statistics_save_failed';
        for(const source of window.tmState.sources)source.enabled=args.sourceIds.includes(source.id);window.tmState.revision++;return structuredClone(window.tmState);
      }
      if(command==='cancel_token_monitor_usage'){window.tmState.phase='stopped';window.tmState.tokenRate=null;window.tmState.revision++;return structuredClone(window.tmState);}
      return original(command,args);
    };
    ${missingZone?"const format=Intl.DateTimeFormat;Intl.DateTimeFormat=function(...args){const result=new format(...args);if(args.length===0)result.resolvedOptions=()=>({timeZone:undefined});return result;};":''}
  `);
  await installTauriStub(page,{settings:{...SYNTHETIC_SETTINGS,language,theme},dashboard:SYNTHETIC_DASHBOARD},script);
  await page.goto('/');
  const panel=page.getByRole('region',{name:language==='en'?'Token Monitor statistics':'Token Monitor 统计',exact:true});await expect(panel).toBeVisible();return panel;
}
test('original renderer retains heatmap, trends, ranges and provider/model controls with same-engine TOTAL',async({page})=>{
 const panel=await setup(page);await expect(panel.getByTestId('token-monitor-allTime')).toContainText('300');await expect(panel.getByTestId('token-monitor-rate')).toContainText('—');
 const frame=page.frameLocator('iframe[title="Token Monitor history and trends"]');await expect(frame.locator('#dashHeatmap svg')).toBeVisible();await expect(frame.locator('#dashChart svg')).toBeVisible();
 expect(await frame.locator('body').evaluate(()=>window.AiGoodBroDashboard.history.summary.totalTokens)).toBe(300);
 expect(await frame.locator('body').evaluate(()=>window.AiGoodBroDashboard.history.daily[0].tokens)).toBe(100);
 await frame.locator('[data-stack="model"]').click();await frame.locator('[data-mode="kline"]').click();
 expect(await frame.locator('body').evaluate(()=>window.AiGoodBroDashboard.preferences.stackBy)).toBe('model');
 expect(await frame.locator('body').evaluate(()=>window.AiGoodBroDashboard.preferences.mode)).toBe('kline');
 await page.reload();await expect(panel.getByTestId('token-monitor-allTime')).toContainText('300');await expect(frame.locator('[data-mode="kline"]')).toHaveClass(/active/);
 expect(await frame.locator('body').evaluate(()=>window.AiGoodBroDashboard.settings.themeColors.bg)).toBe(await page.evaluate(()=>getComputedStyle(document.documentElement).getPropertyValue('--surface').trim()));
 await expect(panel).toHaveScreenshot('token-monitor-en-dark.png');
});
test('Chinese light narrow view keeps the original controls within the viewport',async({page})=>{
 await page.setViewportSize({width:480,height:1600});const panel=await setup(page,{language:'zh-Hans',theme:'light'});await expect(panel.getByTestId('token-monitor-today')).toContainText('300');
 const frame=page.frameLocator('iframe[title="Token Monitor 历史与趋势"]');await expect(frame.locator('#dashHeatmap svg')).toBeVisible();
 expect(await page.locator('body').evaluate(element=>element.scrollWidth<=innerWidth)).toBe(true);
 expect(await frame.locator('body').evaluate(element=>element.scrollWidth<=innerWidth)).toBe(true);
 await expect(panel).toHaveScreenshot('token-monitor-zh-light-480.png');
});
test('source drafts save only after a native success and failed saves preserve edits',async({page})=>{
 const panel=await setup(page,{failSave:true});await expect(panel.getByTestId('token-monitor-allTime')).toContainText('300');await panel.locator('.token-monitor-source-bar summary').click();
 await panel.getByRole('checkbox',{name:/Claude synthetic/}).uncheck();await panel.getByRole('button',{name:'Save sources',exact:true}).click();
 await expect(panel.getByRole('alert')).toContainText('could not be saved');await expect(panel.getByRole('checkbox',{name:/Claude synthetic/})).not.toBeChecked();
 expect(await page.evaluate(()=>window.tmState.sources[1].enabled)).toBe(true);await expect(panel).not.toContainText('Sources saved');
 await page.evaluate(()=>window.tmFailSave=false);await panel.getByRole('button',{name:'Save sources',exact:true}).click();
 await expect(panel.getByRole('status')).toContainText('Sources saved');expect(await page.evaluate(()=>window.tmState.sources.map(s=>s.id))).toEqual(['codex-synthetic','claude-synthetic']);
});
test('cancellation fences a late refresh response and retains only the previous snapshot',async({page})=>{
 const panel=await setup(page,{delayRefresh:true});await expect(panel.getByTestId('token-monitor-allTime')).toContainText('300');await panel.getByRole('button',{name:'Refresh statistics',exact:true}).click();
 await expect.poll(()=>page.evaluate(()=>typeof window.tmResolve)).toBe('function');await panel.getByRole('button',{name:'Stop statistics scanning',exact:true}).click();await expect(panel).toContainText('Scanning stopped');
 await page.evaluate(()=>window.tmResolve());await page.waitForTimeout(50);await expect(panel.getByTestId('token-monitor-allTime')).toContainText('300');await expect(panel).not.toContainText('999,999');
});
test('native scope events refresh composition while ordinary polling remains cache-only',async({page})=>{
 const panel=await setup(page);await expect(panel.getByTestId('token-monitor-allTime')).toContainText('300');
 await page.waitForTimeout(1200);const before=await page.evaluate(()=>window.tmRefreshCount);expect(before).toBe(1);
 await page.evaluate(()=>window.tmEmit('profiles:changed'));await expect.poll(()=>page.evaluate(()=>window.tmRefreshCount)).toBe(2);
 const calls=await page.evaluate(()=>window.tmCalls);expect(calls[0].command).toBe('set_token_monitor_timezone');expect(calls[1].command).toBe('refresh_token_monitor_usage');
});
test('wrong provenance or private fields cannot replace a valid visible snapshot',async({page})=>{
 const panel=await setup(page);await expect(panel.getByTestId('token-monitor-allTime')).toContainText('300');
 await page.evaluate(()=>{window.tmState.snapshot.engine.commit='old';window.tmState.snapshot.payload.history.daily[0].prompt='SYNTHETIC_PRIVATE_MUST_NOT_RENDER';});
 await panel.getByRole('button',{name:'Refresh statistics',exact:true}).click();await expect(panel.getByRole('alert')).toContainText('could not update');await expect(panel).not.toContainText('SYNTHETIC_PRIVATE_MUST_NOT_RENDER');await expect(panel.getByTestId('token-monitor-allTime')).toContainText('300');
});
test('a true zero rate is retained but an expired rate never appears live',async({page})=>{
 const panel=await setup(page);await expect(panel.getByTestId('token-monitor-allTime')).toContainText('300');
 await page.evaluate(()=>{const now=Date.now();window.tmState.tokenRate={mode:'burn',scope:'local',burnPerMinute:0,speedPerSecond:0,sampledAt:now,expiresAt:now+8000,idle:false,revision:1,contextKey:window.tmState.contextKey};window.tmState.revision++;});
 await expect(panel.getByTestId('token-monitor-rate').locator('strong')).toHaveText('0');
 await page.evaluate(()=>{window.tmState.tokenRate.sampledAt=Date.now()-9000;window.tmState.tokenRate.expiresAt=Date.now()-1000;window.tmState.revision++;});
 await expect(panel.getByTestId('token-monitor-rate').locator('strong')).toHaveText('—');
});
test('an unknown browser timezone never becomes an implicit UTC collection',async({page})=>{
 const panel=await setup(page,{missingZone:true});await expect(panel.getByRole('alert')).toContainText('local time zone is unconfirmed');
 expect(await page.evaluate(()=>window.tmCalls.filter(call=>call.command==='refresh_token_monitor_usage').length)).toBe(0);await expect(panel.getByTestId('token-monitor-allTime')).toContainText('—');
});

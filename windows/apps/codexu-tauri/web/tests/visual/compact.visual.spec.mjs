import { test,expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { installTauriStub } from './tauri-stub.mjs';
import { SYNTHETIC_DASHBOARD,SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
const snapshot=JSON.parse(readFileSync(new URL('../../../../../token-monitor/tests/fixtures/handler-snapshot.json',import.meta.url),'utf8'));
const item=(metric)=>({id:`stat:${metric}`,type:'stat',providerId:null,accountId:null,metric,hiddenAccountIds:[],showUsage:true,showSessions:true,accountMode:'lowest',runningOnly:false,groupBy:'none',cellDetail:'clients'});
const items=[{...item('today'),id:'proxy',type:'proxy',metric:null,showUsage:false,showSessions:false},item('today'),{...item('today'),id:'limit:codex',type:'limit',providerId:'codex',metric:null,accountMode:'active'},item('liveRate')];
const prefs=()=>({enabled:false,mode:'autoHide',side:'right',offset:.3,displayId:null,items:null,hapticEnabled:true,warnColors:false,quotaStyle:'ring',refreshEnabled:false,runningIndicatorEnabled:true,size:'medium',customScale:1});
const account=()=>({id:'managed:synthetic-pro',providerId:'codex',label:'Synthetic Pro',loggedIn:true,active:true,observedAt:Date.parse('2026-09-13T02:00:00Z'),available:false,reasonCode:'evidence_stale',planType:'pro',windows:[{id:'five-hour',label:'5h',usedPercent:90,resetsAt:Date.parse('2026-09-13T04:00:00Z')},{id:'seven-day',label:'7d',usedPercent:20,resetsAt:Date.parse('2026-09-20T02:00:00Z')}],creditsUsd:null,creditPoints:'12.5',resetCards:null});
const native=()=>({revision:1,windows:['popover','edge_peek','edge_rail','edge_card'].map(surface=>({surface,visible:true,pinned:false,collapsed:false})),selectedItemId:null,resolvedItems:items,pageIndex:0,pageCount:1,displayAvailable:true,side:'right',scale:1,viewportHeight:288,preferences:prefs(),displays:[{id:'display-synthetic',label:'Synthetic display · 1920×1080',isPrimary:true,available:true}],failureCode:null,shortcutStatus:'registered',cachedProjection:{accounts:[account()],proxy:null,sessionCount:null}});
const statistics=()=>({phase:'ready',revision:1,contextKey:'a'.repeat(64),sources:[{id:'codex-synthetic',providerId:'codex',label:'Codex synthetic',enabled:true},{id:'claude-synthetic',providerId:'claude',label:'Claude synthetic',enabled:true}],timezone:'UTC',snapshot:{...structuredClone(snapshot),timezone:'UTC'},tokenRate:null,failureCode:null});
async function setup(page,{label='token-monitor-popover',language='en',theme='dark',selected=null,deferRead=false}={}){
 await page.clock.setFixedTime(new Date('2026-09-13T02:00:00Z'));
 await page.route('**/*',route=>new URL(route.request().url()).hostname==='127.0.0.1'?route.continue():route.abort());
 const script=new Function(`
  const base=window.__TAURI_INTERNALS__.invoke;window.compactState=${JSON.stringify(native())};window.compactState.selectedItemId=${JSON.stringify(selected)};window.statisticsState=${JSON.stringify(statistics())};window.compactCalls=[];window.compactListeners={};
  window.emitCompact=()=>{for(const handler of window.compactListeners['compact-ui:changed']||[])window['_'+handler]({event:'compact-ui:changed',id:18,payload:structuredClone(window.compactState)});};
  window.emitStatistics=()=>{for(const handler of window.compactListeners['token-monitor:changed']||[])window['_'+handler]({event:'token-monitor:changed',id:19,payload:structuredClone(window.statisticsState)});};
  window.__TAURI_INTERNALS__.invoke=async(command,args)=>{
   if(command==='plugin:event|listen'){(window.compactListeners[args.event]||=[]).push(args.handler);return base(command,args);}
   if(command.includes('compact')||command.includes('token_monitor'))window.compactCalls.push({command,args:structuredClone(args||{})});
   if(command==='get_compact_ui_state'){if(${JSON.stringify(deferRead)}&&!window.releaseCompactRead){const saved=structuredClone(window.compactState);return new Promise(resolve=>{window.releaseCompactRead=()=>resolve(saved);});}return structuredClone(window.compactState);}
   if(command==='get_token_monitor_state'||command==='set_token_monitor_timezone'||command==='refresh_token_monitor_usage')return structuredClone(window.statisticsState);
   if(command==='retry_compact_ui_shortcut'){if(window.failCompactShortcut)throw 'compact_shortcut_unavailable';window.compactState.shortcutStatus=window.compactRetryStatus||'registered';window.compactState.revision++;return structuredClone(window.compactState);}
   if(command==='set_compact_ui_preferences'){if(window.failCompactSave)throw 'compact_preferences_unavailable';window.compactState.preferences={...window.compactState.preferences,...args.patch};window.compactState.resolvedItems=window.compactState.preferences.items===null?${JSON.stringify(items)}:structuredClone(window.compactState.preferences.items);window.compactState.revision++;return structuredClone(window.compactState);}
   if(command==='compact_ui_action'){if(window.failCompactAction)throw 'compact_window_unavailable';const surface=${JSON.stringify(label.replace('token-monitor-','').replaceAll('-','_'))};const value=window.compactState.windows.find(value=>value.surface===surface);if(args.action==='pin')value.pinned=true;if(args.action==='unpin')value.pinned=false;if(args.action==='collapse')value.collapsed=!value.collapsed;if(args.action==='close')value.visible=false;window.compactState.revision++;return structuredClone(window.compactState);}
   return base(command,args);
  };`);
 await installTauriStub(page,{settings:{...SYNTHETIC_SETTINGS,language,theme},dashboard:SYNTHETIC_DASHBOARD,windowLabel:label},script);
 await page.goto('/');
}
test('popover reads shared TOTAL/history/TPM without creating another scanner or polling loop',async({page})=>{
 await page.setViewportSize({width:420,height:640});await setup(page);
 await expect(page.getByTestId('token-monitor-compact').locator('.compact-total')).toHaveText('300');
 await expect(page.getByRole('img',{name:'180-day activity heatmap'})).toBeVisible();await expect(page.getByRole('img',{name:'30-day trend'})).toBeVisible();
 await expect(page.getByText('Cost unconfirmed',{exact:true})).toBeVisible();
 await page.waitForTimeout(1200);
 expect(await page.evaluate(()=>window.compactCalls.filter(call=>call.command==='get_token_monitor_state').length)).toBe(1);
 expect(await page.evaluate(()=>window.compactCalls.filter(call=>call.command==='refresh_token_monitor_usage').length)).toBe(0);
 await expect(page.getByTestId('token-monitor-compact')).toHaveScreenshot('compact-popover-en-dark-420.png');
});
test('pushes update real TPM and absent status/model evidence stays unknown without false healthy badges',async({page})=>{
 await setup(page);await expect(page.locator('.compact-total')).toHaveText('300');
 await page.evaluate(()=>{const now=Date.now();window.statisticsState.revision++;window.statisticsState.tokenRate={mode:'burn',scope:'local',burnPerMinute:60,speedPerSecond:1,sampledAt:now,expiresAt:now+8000,idle:false,revision:1,contextKey:window.statisticsState.contextKey};window.emitStatistics();});
 await expect(page.getByTestId('token-monitor-compact')).toContainText('TPM 60');
 await page.getByLabel('Choose usage view',{exact:true}).selectOption('models');await expect(page.locator('.compact-breakdown')).toContainText('vendor-x/ultra-long-context');
 await page.getByLabel('Choose usage view',{exact:true}).selectOption('status');await expect(page.locator('.compact-scroll')).toContainText('No verified official status snapshot');await expect(page.locator('.compact-scroll')).not.toContainText('Operational');
});
test('failed pin keeps acknowledged state; collapse follows only a successful native reply',async({page})=>{
 await page.setViewportSize({width:420,height:640});await setup(page);await expect(page.locator('.compact-total')).toHaveText('300');
 await page.evaluate(()=>{window.failCompactAction=true;});await page.getByRole('button',{name:'Pin',exact:true}).click();await expect(page.getByRole('alert')).toContainText('state is unconfirmed');await expect(page.getByRole('button',{name:'Pin',exact:true})).toHaveAttribute('aria-pressed','false');
 await page.evaluate(()=>{window.failCompactAction=false;});await page.getByRole('button',{name:'Pin',exact:true}).click();await expect(page.getByRole('button',{name:'Pin',exact:true})).toHaveAttribute('aria-pressed','true');
 await page.getByRole('button',{name:'Collapse or expand'}).click();await expect(page.locator('.compact-scroll')).toHaveCount(0);await expect(page.getByTestId('token-monitor-compact')).toHaveClass(/is-collapsed/);
});
test('rail uses the native stable order and the verified active Pro seven-day window, not the first quota',async({page})=>{
 await page.setViewportSize({width:64,height:288});await setup(page,{label:'token-monitor-edge-rail'});
 await expect(page.locator('[data-item-id="limit:codex"] strong')).toHaveText('80%');
 expect(await page.locator('[data-item-id]').evaluateAll(nodes=>nodes.map(node=>node.dataset.itemId))).toEqual(['proxy','stat:today','limit:codex','stat:liveRate']);
 await page.evaluate(()=>{window.compactState.cachedProjection.accounts[0].active=null;window.compactState.revision++;window.emitCompact();});await expect(page.locator('[data-item-id="limit:codex"] strong')).toHaveText('—');
 await expect(page.locator('.compact-edge-rail')).toHaveScreenshot('compact-rail-64.png');
});
test('account card retains genuine stale snapshots and no unknown session or request count becomes zero',async({page})=>{
 await page.setViewportSize({width:292,height:440});await setup(page,{label:'token-monitor-edge-card',selected:'limit:codex'});
 await expect(page.locator('.compact-account')).toContainText('Previous snapshot');await expect(page.getByRole('img',{name:'5h · 10%'})).toBeVisible();await expect(page.getByRole('img',{name:'7d · 80%'})).toBeVisible();await expect(page.locator('.compact-account')).toContainText('12.5');
 await expect(page.locator('.compact-edge-card')).toHaveScreenshot('compact-stale-account-card-292.png');
 await page.evaluate(()=>{window.compactState.selectedItemId='proxy';window.compactState.revision++;window.emitCompact();});await expect(page.locator('.compact-scroll')).toContainText('Current requests —');await expect(page.locator('.compact-scroll')).toContainText('Egress readback Unconfirmed');
});
test('Chinese light compact surfaces and local fish style use the same returned values',async({page})=>{
 await page.setViewportSize({width:292,height:440});await setup(page,{label:'token-monitor-edge-card',language:'zh-Hans',theme:'light',selected:'limit:codex'});
 await page.evaluate(()=>{window.compactState.preferences.quotaStyle='fish';window.compactState.revision++;window.emitCompact();});await expect(page.locator('.compact-fish')).toHaveCount(2);await expect(page.locator('.compact-fish').nth(1)).toContainText('80%');
 await expect(page.locator('.compact-edge-card')).toHaveScreenshot('compact-card-zh-light-fish.png');
});
test('settings drafts persist on native failure and manual pin selection preserves existing display order',async({page})=>{
 await setup(page,{label:'settings'});await page.getByText('Edge Dock and compact statistics',{exact:true}).click();
 const body=page.locator('.compact-dock-settings-body');await expect(body.getByLabel('Show Edge Dock',{exact:true})).not.toBeChecked();await body.getByLabel('Show Edge Dock',{exact:true}).check();
 await page.evaluate(()=>{window.failCompactSave=true;});await body.getByRole('button',{name:'Save Edge Dock settings',exact:true}).click();await expect(body.getByRole('alert')).toContainText('unavailable');await expect(body.getByLabel('Show Edge Dock',{exact:true})).toBeChecked();expect(await page.evaluate(()=>window.compactState.preferences.enabled)).toBe(false);
 await page.evaluate(()=>{window.failCompactSave=false;});await body.getByRole('button',{name:'Save Edge Dock settings',exact:true}).click();await expect(body.getByRole('status').filter({hasText:'Edge Dock settings saved'})).toContainText('settings saved');
 await body.getByText('Pinned accounts',{exact:true}).click();await body.getByLabel('Synthetic Pro · codex',{exact:true}).check();await body.getByRole('button',{name:'Save Edge Dock settings',exact:true}).click();
 expect(await page.evaluate(()=>window.compactState.preferences.items.map(item=>item.id))).toEqual(['proxy','stat:today','limit:codex','stat:liveRate','limit:codex:account:managed:synthetic-pro']);
 await expect(body).toHaveScreenshot('compact-dock-settings-draft.png');
});

test('peek is its own bounded surface and reveal submits only the finite native action',async({page})=>{
 await page.setViewportSize({width:10,height:88});await setup(page,{label:'token-monitor-edge-peek'});
 const peek=page.locator('.compact-edge-peek');await expect(peek).toBeVisible();await expect(peek).toHaveScreenshot('compact-peek-10.png');
 await page.getByRole('button',{name:'Reveal Edge Dock'}).click();
 expect(await page.evaluate(()=>window.compactCalls.filter(call=>call.command==='compact_ui_action').at(-1).args)).toEqual({action:'reveal',itemId:null});
 expect(await page.evaluate(()=>document.documentElement.scrollWidth)).toBeLessThanOrEqual(10);
});
test('late initial state read cannot replace a newer pushed account cache',async({page})=>{
 await page.setViewportSize({width:292,height:440});await setup(page,{label:'token-monitor-edge-card',selected:'limit:codex',deferRead:true});
 await page.waitForFunction(()=>typeof window.releaseCompactRead==='function');
 await page.evaluate(()=>{window.compactState.revision=3;window.compactState.cachedProjection.accounts[0].label='Newer synthetic receipt';window.emitCompact();});
 await expect(page.locator('.compact-account h2')).toHaveText('Newer synthetic receipt');
 await page.evaluate(()=>window.releaseCompactRead());await page.waitForTimeout(100);
 await expect(page.locator('.compact-account h2')).toHaveText('Newer synthetic receipt');
});
test('missing selected display and intentionally empty items survive settings save',async({page})=>{
 await setup(page,{label:'settings'});await page.getByText('Edge Dock and compact statistics',{exact:true}).click();
 const body=page.locator('.compact-dock-settings-body');await expect(body.getByLabel('Show Edge Dock',{exact:true})).toBeVisible();
 await page.evaluate(()=>{window.compactState.preferences.displayId='display-disconnected';window.compactState.displayAvailable=false;window.compactState.revision++;window.emitCompact();});
 await expect(body.getByLabel('Display',{exact:true})).toHaveValue('display-disconnected');await expect(body).toContainText('Your choice is kept');
 await body.getByText('Dock items',{exact:true}).click();await body.getByRole('button',{name:'Customize current items'}).click();
 while(await body.getByRole('button',{name:'Remove item',exact:true}).count())await body.getByRole('button',{name:'Remove item',exact:true}).first().click();
 await body.getByRole('button',{name:'Save Edge Dock settings',exact:true}).click();
 expect(await page.evaluate(()=>window.compactState.preferences.items)).toEqual([]);
 expect(await page.evaluate(()=>window.compactState.preferences.displayId)).toBe('display-disconnected');
 await expect(body).toHaveScreenshot('compact-settings-empty-disconnected.png');
});
test('provider options use stable item IDs and save only changed preferences after a failed save',async({page})=>{
 await setup(page,{label:'settings'});await page.getByText('Edge Dock and compact statistics',{exact:true}).click();
 const body=page.locator('.compact-dock-settings-body');await body.getByText('Dock items',{exact:true}).click();await body.getByRole('button',{name:'Customize current items'}).click();
 const row=body.locator('[data-settings-item="limit:codex"]');await row.getByText('Limit item options',{exact:true}).click();
 await row.getByLabel('Show token usage in card',{exact:true}).uncheck();await row.getByLabel('Rail value',{exact:true}).selectOption('lowest');await row.getByLabel('Synthetic Pro',{exact:true}).uncheck();
 await page.evaluate(()=>{window.failCompactSave=true;window.compactState.revision++;window.emitCompact();});
 await body.getByRole('button',{name:'Save Edge Dock settings',exact:true}).click();await expect(row.getByLabel('Show token usage in card',{exact:true})).not.toBeChecked();
 await page.evaluate(()=>{window.failCompactSave=false;});await body.getByRole('button',{name:'Save Edge Dock settings',exact:true}).click();
 expect(await page.evaluate(()=>Object.keys(window.compactCalls.filter(call=>call.command==='set_compact_ui_preferences').at(-1).args.patch))).toEqual(['items']);
 const configured=await page.evaluate(()=>window.compactState.preferences.items.find(item=>item.id==='limit:codex'));expect(configured.accountMode).toBe('lowest');expect(configured.hiddenAccountIds).toEqual(['managed:synthetic-pro']);expect(configured.showUsage).toBe(false);
 await expect(body.getByLabel('Trackpad haptics · unavailable on Windows',{exact:true})).toBeDisabled();
 await expect(row).toHaveScreenshot('compact-limit-item-options.png');
});
for(const scale of [.85,1.25,1.5])test(`native scale ${scale} fits rail and card inside their logical viewport`,async({page})=>{
 await page.setViewportSize({width:Math.ceil(64*scale),height:Math.ceil(288*scale)});await setup(page,{label:'token-monitor-edge-rail'});
 await page.evaluate(scale=>{window.compactState.scale=scale;window.compactState.revision++;window.emitCompact();},scale);
 await expect(page.locator('.compact-edge-rail')).toHaveScreenshot(`compact-rail-scale-${scale}.png`);
 const box=await page.locator('.compact-edge-rail').boundingBox();expect(box.width).toBeLessThanOrEqual(Math.ceil(64*scale));expect(box.height).toBeLessThanOrEqual(Math.ceil(288*scale));
});
test('collected session cards preserve month precedence and never claim live task status',async({page})=>{
 await page.setViewportSize({width:292,height:440});await setup(page,{label:'token-monitor-edge-card',selected:'stat:sessions'});
 await page.evaluate(()=>{const item={...window.compactState.resolvedItems[1],id:'stat:sessions',metric:'sessions',runningOnly:true};window.compactState.resolvedItems=[item];window.compactState.selectedItemId=item.id;window.compactState.revision++;window.statisticsState.snapshot.collectedAt='2026-09-13T02:00:00Z';window.statisticsState.snapshot.payload.aggregate.month.sessions={'opaque-aaaaaaaaaaaaaaaaaaaaaaaa':{client:'codex',totalTokens:42,models:{'synthetic-model':42},lastUsedAt:'2026-09-13T01:59:00Z'},'opaque-bbbbbbbbbbbbbbbbbbbbbbbb':{client:'claude',totalTokens:99,lastUsedAt:'2026-09-13T01:59:30Z',turnEnded:true}};window.statisticsState.snapshot.payload.aggregate.today.sessions={'opaque-aaaaaaaaaaaaaaaaaaaaaaaa':{client:'claude',totalTokens:999,lastUsedAt:'2026-09-13T01:59:00Z'}};window.statisticsState.revision++;window.emitStatistics();window.emitCompact();});
 await expect(page.locator('.compact-total')).toHaveText('1');await expect(page.locator('.compact-session-list li')).toHaveCount(1);await expect(page.locator('.compact-session-list')).toContainText('42 Token');await expect(page.locator('.compact-session-list')).toContainText('Active at collection');await expect(page.locator('.compact-session-list')).not.toContainText('999');
 await expect(page.locator('.compact-edge-card')).toHaveScreenshot('compact-sessions-last-collection.png');
 await page.getByRole('button',{name:'Open tasks',exact:true}).click();expect(await page.evaluate(()=>window.compactCalls.filter(call=>call.command==='compact_ui_action').at(-1).args.action)).toBe('open_running_tasks');
});

test('same-request same-time pushes still update changed session contents',async({page})=>{
 await page.setViewportSize({width:292,height:440});await setup(page,{label:'token-monitor-edge-card',selected:'stat:sessions'});
 await page.evaluate(()=>{const item={...window.compactState.resolvedItems[1],id:'stat:sessions',metric:'sessions'};window.compactState.resolvedItems=[item];window.compactState.selectedItemId=item.id;window.compactState.revision++;window.statisticsState.snapshot.payload.aggregate.month.sessions={};window.statisticsState.revision++;window.emitStatistics();window.emitCompact();});
 await expect(page.locator('.compact-total')).toHaveText('0');
 await page.evaluate(()=>{window.statisticsState.snapshot.payload.aggregate.month.sessions={'opaque-aaaaaaaaaaaaaaaaaaaaaaaa':{client:'codex',totalTokens:42,lastUsedAt:'2026-09-13T01:59:00Z'}};window.statisticsState.revision++;window.emitStatistics();});
 await expect(page.locator('.compact-total')).toHaveText('1');await expect(page.locator('.compact-session-list')).toContainText('42 Token');
 await page.evaluate(()=>{window.statisticsState.snapshot.payload.aggregate.month.sessions['opaque-aaaaaaaaaaaaaaaaaaaaaaaa'].totalTokens=84;window.statisticsState.revision++;window.emitStatistics();});
 await expect(page.locator('.compact-session-list')).toContainText('84 Token');await expect(page.locator('.compact-session-list')).not.toContainText('42 Token');
});
test('account-specific cards do not inherit provider aggregate usage or other accounts sessions',async({page})=>{
 await page.setViewportSize({width:292,height:440});await setup(page,{label:'token-monitor-edge-card',selected:'limit:codex'});
 await page.evaluate(()=>{const item={...window.compactState.resolvedItems[2],id:'limit:codex:account:managed:synthetic-pro',accountId:'managed:synthetic-pro',showUsage:true,showSessions:true};window.compactState.resolvedItems=[item];window.compactState.selectedItemId=item.id;window.compactState.revision++;window.emitCompact();});
 await expect(page.locator('.compact-account')).toBeVisible();await expect(page.locator('.compact-provider-usage')).toHaveCount(0);await expect(page.locator('.compact-session-list')).toHaveCount(0);
});
test('compact settings and workspace navigation are finite native actions',async({page})=>{
 await page.setViewportSize({width:420,height:640});await setup(page);
 for(const [name,action] of [['Settings','open_settings'],['Tasks','open_running_tasks'],['Accounts','open_accounts'],['Open workspace','open_workspace']]){await page.getByRole('button',{name,exact:true}).click();expect(await page.evaluate(()=>window.compactCalls.filter(call=>call.command==='compact_ui_action').at(-1).args)).toEqual({action,itemId:null});}
});

test('Claude rail headline uses literal observed balance and unknown stays unknown despite known percentages',async({page})=>{
 await page.setViewportSize({width:64,height:288});await setup(page,{label:'token-monitor-edge-rail'});
 await page.evaluate(()=>{const item={...window.compactState.resolvedItems[2],id:'limit:claude',providerId:'claude',accountMode:'lowest'};window.compactState.resolvedItems=[item];window.compactState.cachedProjection.accounts=[{...window.compactState.cachedProjection.accounts[0],providerId:'claude',creditsUsd:12.5,available:true}];window.compactState.revision++;window.emitCompact();});
 await expect(page.locator('[data-item-id="limit:claude"] strong')).toHaveText('$12.5');
 await page.evaluate(()=>{window.compactState.cachedProjection.accounts[0].creditsUsd=null;window.compactState.revision++;window.emitCompact();});
 await expect(page.locator('[data-item-id="limit:claude"] strong')).toHaveText('—');
 await expect(page.locator('[data-item-id="limit:claude"] strong')).not.toHaveText(/%/);
});

test('shortcut registration failure remains explicit and retry acknowledges only its native result',async({page})=>{
 await setup(page,{label:'settings'});await page.getByText('Edge Dock and compact statistics',{exact:true}).click();
 const body=page.locator('.compact-dock-settings-body'),status=body.getByTestId('compact-shortcut-status');
 await page.evaluate(()=>{window.compactState.shortcutStatus='occupied';window.compactState.revision++;window.emitCompact();});
 await expect(status).toContainText('Ctrl+I is occupied');await expect(body.getByLabel('Show Edge Dock',{exact:true})).toBeEnabled();
 await page.evaluate(()=>{window.failCompactShortcut=true;});await body.getByRole('button',{name:'Retry Ctrl+I',exact:true}).click();
 await expect(status).toContainText('Ctrl+I is occupied');await expect(body.getByRole('button',{name:'Retry Ctrl+I',exact:true})).toBeEnabled();
 await page.evaluate(()=>{window.failCompactShortcut=false;window.compactRetryStatus='failed';});await body.getByRole('button',{name:'Retry Ctrl+I',exact:true}).click();
 await expect(status).toContainText('Ctrl+I could not register');
 await expect(body).toHaveScreenshot('compact-shortcut-failed.png');
 await page.evaluate(()=>{window.compactRetryStatus='registered';});await body.getByRole('button',{name:'Retry Ctrl+I',exact:true}).click();
 await expect(status).toContainText('Ctrl+I reveals or hides');await expect(body.getByRole('button',{name:'Retry Ctrl+I',exact:true})).toHaveCount(0);
 expect(await page.evaluate(()=>window.compactCalls.filter(call=>call.command==='retry_compact_ui_shortcut').length)).toBe(3);
});

import {test,expect} from '@playwright/test';
import {installTauriStub} from './tauri-stub.mjs';
import {FIXED_NOW_ISO,SYNTHETIC_DASHBOARD,SYNTHETIC_SETTINGS} from './synthetic-fixtures.mjs';

async function setup(page,{settings=false,language='en',theme='dark'}={}){
 await page.clock.install({time:new Date(FIXED_NOW_ISO)});
 await page.route('**/*',route=>new URL(route.request().url()).hostname==='127.0.0.1'?route.continue():route.abort());
 await installTauriStub(page,{settings:{...SYNTHETIC_SETTINGS,language,theme},dashboard:SYNTHETIC_DASHBOARD,windowLabel:settings?'settings':'main'},()=>{
  const original=window.__TAURI_INTERNALS__.invoke,callbacks={};window.parityCalls=[];
  window.emitParity=name=>(callbacks[name]||[]).forEach(id=>window[`_${id}`]({event:name,payload:null,id:991}));
  window.liveState={phase:'live',issueCode:null,observedAtMs:Date.now(),tasks:[{ordinal:1,state:'running',turnState:'completed',startedAtMs:Date.now()-10000,completedAtMs:Date.now()-1000}]};
  window.toolReady=false;window.toolRows=[{id:'1',label:'Synthetic Grok',selected:true,platform:'grok',platform_name:'Grok',can_view_usage:false}];
  window.toolSession={session_id:'b'.repeat(32),platform:'grok',phase:'running',authentication_state:'unknown',reason_code:null};
  window.dependencyState={task_id:'a'.repeat(32),platform:'grok',phase:'running',verification_state:'unknown',version:null,reason_code:null};
  window.automaticPreferences={enabled:false,fiveHourRemainingThreshold:5,sevenDayRemainingThreshold:10,excludedProfileIds:[],pauseAtOnePercent:false,resumeAfterSwitch:false};
  window.automaticStatus={phase:'disabled',issueCode:null,sourceAccountId:null,targetAccountId:null,lastAttemptAtMs:null,lastSucceededAtMs:null,nextEligibleAtMs:null,liveTasksAvailable:false,pauseResumeAvailable:false,resumeAfterSwitchAvailable:false,lastSwitchRestored:null};
  window.__TAURI_INTERNALS__.invoke=async(command,args)=>{
   if(command==='plugin:event|listen'){(callbacks[args.event]||=[]).push(args.handler);return original(command,args);}
   if(command==='get_live_task_state'){
    window.parityCalls.push({command});const saved=structuredClone(window.liveState);
    if(window.holdLive){window.holdLive=false;return new Promise(resolve=>window.releaseLive=()=>resolve(saved));}return saved;
   }
   if(command==='reconnect_live_tasks'){window.parityCalls.push({command});if(window.failReconnect)throw 'official_tasks_unavailable';return structuredClone(window.liveState);}
   if(command==='list_profiles')return structuredClone(window.toolRows);
   if(command==='list_platforms')return [{id:'codex',name:'Codex',command:'codex',default_directory:null,isolation:'managed',quota_supported:true,desktop:false},{id:'grok',name:'Grok',command:'grok',default_directory:null,isolation:'managed',quota_supported:true,desktop:false}];
   if(command==='get_local_cli_actions'){window.parityCalls.push({command,args});return {platform:'grok',can_login:window.toolReady,can_open:window.toolReady,reason_code:window.toolReady?null:'provider_runtime_unverified',phase:'idle'};}
   if(command==='prepare_local_cli_dependency'){window.parityCalls.push({command,args});return {task_id:'a'.repeat(32),platform:args.platform,phase:'prepared',prompt:'Check and prepare the selected official tool.\n<img src=x onerror="window.syntheticExecuted=true">'};}
   if(command==='begin_local_cli_dependency'){window.parityCalls.push({command,args});if(window.failBeginDependency)throw 'launch_failed';return structuredClone(window.dependencyState);}
   if(command==='get_local_cli_dependency'){window.parityCalls.push({command,args});return structuredClone(window.dependencyState);}
   if(command==='cancel_local_cli_dependency'){window.parityCalls.push({command,args});window.dependencyState.phase='cancelled';window.dependencyState.verification_state='unknown';return structuredClone(window.dependencyState);}
   if(command==='plugin:dialog|open')return 'C:\\Synthetic\\Workspace';
   if(command==='start_local_cli'){window.parityCalls.push({command,args});window.toolSession.phase='running';return structuredClone(window.toolSession);}
   if(command==='get_local_cli_session'){window.parityCalls.push({command,args});return structuredClone(window.toolSession);}
   if(command==='stop_local_cli_session'){window.parityCalls.push({command,args});if(window.failToolStop)throw 'cleanup_unconfirmed';window.toolSession.phase='stopped';return structuredClone(window.toolSession);}
   if(command==='create_local_cli_profile'){window.parityCalls.push({command,args});if(window.failToolCreate)throw 'duplicate_label';window.toolRows.push({id:'2',label:args.label,selected:false,platform:'grok',platform_name:'Grok',can_view_usage:false});return {profile_id:'2',platform:'grok',phase:'created'};}
   if(command==='get_automatic_switch_preferences')return structuredClone(window.automaticPreferences);
   if(command==='get_automatic_switch_status')return structuredClone(window.automaticStatus);
   if(command==='set_automatic_switch_preferences'){window.parityCalls.push({command,args});if(window.failAutomaticSave)throw 'automatic_switch_save_failed';window.automaticPreferences=structuredClone(args.preferences);window.automaticStatus.phase=args.preferences.enabled?'idle':'disabled';window.emitParity('automatic-switch:changed');return structuredClone(window.automaticPreferences);}
   if(command==='evaluate_automatic_switch'){window.parityCalls.push({command});if(window.holdAutomatic)return new Promise(resolve=>window.releaseAutomatic=()=>resolve({...window.automaticStatus,phase:'switched'}));return {...window.automaticStatus,phase:'blocked',issueCode:'automatic_switch_task_busy'};}
   if(command==='cancel_automatic_switch'){window.parityCalls.push({command});window.automaticStatus.phase='cancelled';window.automaticStatus.issueCode='switch_cancelled';return structuredClone(window.automaticStatus);}
   return original(command,args);
  };
 });
 await page.goto('/');
}
async function tasks(page){await page.getByRole('navigation').getByRole('button',{name:'Workspace',exact:true}).click();return page.getByRole('region',{name:'Live tasks',exact:true});}
test('live tasks keep runtime busy separate from completed turns; reset and failed reconnect clear claims but retain history',async({page})=>{
 await setup(page);const live=await tasks(page);
 await expect(live.locator('[data-runtime-state="running"]')).toBeVisible();await expect(live).toContainText('Turn record Completed');
 await expect(page.getByText('Synthetic running task with a deliberately long title to exercise truncation')).toBeVisible();
 await expect(live).toHaveScreenshot('live-tasks-runtime-and-turn.png');
 await page.evaluate(()=>{window.holdLive=true;});await live.getByRole('button',{name:'Read live tasks',exact:true}).click();await page.waitForFunction(()=>typeof window.releaseLive==='function');
 await page.evaluate(()=>{window.liveState={phase:'unavailable',issueCode:'official_tasks_scope_unverified',observedAtMs:null,tasks:[]};window.emitParity('live-tasks:changed');window.releaseLive();});
 await expect(live).toHaveAttribute('data-live-phase','unavailable');await expect(live.locator('[data-runtime-state]')).toHaveCount(0);await expect(live).not.toContainText('Idle');
 await page.evaluate(()=>{window.failReconnect=true;});await live.getByRole('button',{name:'Reconnect task source',exact:true}).click();
 await expect(live).toHaveAttribute('data-live-phase','unavailable');await expect(page.getByText('Synthetic running task with a deliberately long title to exercise truncation')).toBeVisible();
 await expect(live).toHaveScreenshot('live-tasks-disconnected.png');
});
test('native task deadline expires locally without another reader or an inferred idle state',async({page})=>{
 await setup(page);const live=await tasks(page);await expect(live).toHaveAttribute('data-live-phase','live');const before=await page.evaluate(()=>window.parityCalls.filter(call=>call.command==='get_live_task_state').length);
 await page.clock.runFor(45001);await expect(live).toHaveAttribute('data-live-phase','unavailable');await expect(live.locator('[data-runtime-state]')).toHaveCount(0);expect(await page.evaluate(()=>window.parityCalls.filter(call=>call.command==='get_live_task_state').length)).toBe(before);
});
test('dependency preparation binds and starts existing Codex; only independent verified status enables launcher actions',async({page})=>{
 await setup(page);const row=page.getByTestId('profile-1');await row.getByRole('button',{name:'Sign-in and launch',exact:false}).click();
 await expect(row.getByRole('button',{name:'Open tool',exact:true})).toBeDisabled();await row.getByRole('button',{name:'Prepare with my Codex',exact:true}).click();
 const dialog=page.getByRole('dialog',{name:'Codex dependency preparation',exact:true});await expect(dialog.locator('pre')).toContainText('<img src=x');await expect(dialog.locator('img')).toHaveCount(0);
 await dialog.getByRole('button',{name:'Start preparation',exact:true}).click();expect(await page.evaluate(()=>window.parityCalls.filter(call=>call.command==='begin_local_cli_dependency').at(-1).args)).toEqual({taskId:'a'.repeat(32)});
 await expect(dialog).toContainText('readiness still awaits');await expect(row.getByRole('button',{name:'Open tool',exact:true})).toBeDisabled();
 await expect(dialog).toHaveScreenshot('local-cli-codex-preparation-running.png');
 await page.evaluate(()=>{window.toolReady=true;window.dependencyState.phase='verified';window.dependencyState.verification_state='verified';window.dependencyState.version='1.2.3';window.emitParity('local-cli-dependency:changed');});
 await expect(dialog).toContainText('Independent local checks passed');await dialog.getByRole('button',{name:'Close',exact:true}).click();await expect(row.getByRole('button',{name:'Open tool',exact:true})).toBeEnabled();expect(await page.evaluate(()=>window.syntheticExecuted)).toBeUndefined();
 await row.getByRole('button',{name:'Open official sign-in',exact:true}).click();await expect(row).toContainText('Tool session running');
 expect(await page.evaluate(()=>window.parityCalls.filter(call=>call.command==='start_local_cli').at(-1).args.action)).toBe('login');
 await row.getByRole('button',{name:'Stop this tool session',exact:true}).click();await page.evaluate(()=>{window.failToolStop=true;});await row.getByRole('button',{name:'Confirm stop',exact:true}).click();await expect(row).toContainText('cleanup is unconfirmed');await expect(row).toContainText('Tool session running');
 await page.evaluate(()=>{window.failToolStop=false;});await row.getByRole('button',{name:'Confirm stop',exact:true}).click();await expect(row).toContainText('Tool session stopped');
 await row.getByRole('button',{name:'Open tool',exact:true}).click();expect(await page.evaluate(()=>window.parityCalls.filter(call=>call.command==='start_local_cli').at(-1).args.action)).toBe('open');
});
test('independent profile creation preserves a failed alias and uses only the actual create command',async({page})=>{
 await setup(page);await page.evaluate(()=>{window.toolReady=true;});await page.getByText('Connect other tools',{exact:true}).click();const catalog=page.locator('.local-cli-catalog');
 await expect(catalog.getByRole('button',{name:'Open tool',exact:true})).toBeEnabled();await catalog.getByLabel('Independent account alias',{exact:true}).fill('Synthetic New');await page.evaluate(()=>{window.failToolCreate=true;});await catalog.getByRole('button',{name:'Create independent directory',exact:true}).click();await expect(catalog).toContainText('already exists');await expect(catalog.getByLabel('Independent account alias',{exact:true})).toHaveValue('Synthetic New');
 await page.evaluate(()=>{window.failToolCreate=false;});await catalog.getByRole('button',{name:'Create independent directory',exact:true}).click();await expect(page.getByTestId('profile-2')).toContainText('Synthetic New');await expect(catalog).toContainText('Sign-in is not yet confirmed');
 expect(await page.evaluate(()=>window.parityCalls.filter(call=>call.command==='create_local_cli_profile').at(-1).args)).toEqual({platform:'grok',label:'Synthetic New',edition:null});await expect(catalog).toHaveScreenshot('local-cli-profile-created.png');
});
test('automatic switch defaults off, preserves failed edits, respects native capabilities and cancellation fences a late success',async({page})=>{
 await setup(page,{settings:true});await page.getByText('Low quota and automatic switching',{exact:true}).click();const panel=page.locator('.automatic-switch-body');
 await expect(panel.getByLabel('Switch when quota is low',{exact:true})).not.toBeChecked();await expect(panel.getByLabel('Switch when quota is low',{exact:true})).toBeDisabled();await expect(panel.getByLabel('Pause and switch at 1%',{exact:true})).toBeDisabled();await expect(panel.getByLabel('Restore the current conversation after switching',{exact:true})).toBeDisabled();expect(await page.evaluate(()=>window.parityCalls.filter(call=>call.command==='set_automatic_switch_preferences').length)).toBe(0);
 await expect(panel).toHaveScreenshot('automatic-switch-unavailable-default-off.png');
 await page.evaluate(()=>{window.automaticStatus.liveTasksAvailable=true;window.emitParity('automatic-switch:changed');});await expect(panel.getByLabel('Switch when quota is low',{exact:true})).toBeEnabled();await panel.getByLabel('Switch when quota is low',{exact:true}).check();await panel.getByLabel('5-hour remaining threshold',{exact:true}).selectOption('15');
 await page.evaluate(()=>{window.failAutomaticSave=true;});await panel.getByRole('button',{name:'Save automatic switch settings',exact:true}).click();await expect(panel.getByRole('alert')).toContainText('Save failed');await expect(panel.getByLabel('5-hour remaining threshold',{exact:true})).toHaveValue('15');
 await page.evaluate(()=>{window.failAutomaticSave=false;});await panel.getByRole('button',{name:'Save automatic switch settings',exact:true}).click();await expect(panel).toContainText('settings saved');
 await page.evaluate(()=>{window.holdAutomatic=true;});await panel.getByRole('button',{name:'Check switch conditions now',exact:true}).click();await page.waitForFunction(()=>typeof window.releaseAutomatic==='function');await panel.getByRole('button',{name:'Cancel this automatic attempt',exact:true}).click();await page.evaluate(()=>window.releaseAutomatic());await expect(panel).toContainText('Attempt cancelled');await expect(panel).not.toContainText('Account switch verified');
 expect(await page.evaluate(()=>window.parityCalls.filter(call=>call.command==='cancel_automatic_switch').length)).toBe(1);
});

import {test,expect} from '@playwright/test';
import {FIXED_NOW_ISO,SYNTHETIC_DASHBOARD,SYNTHETIC_SETTINGS} from './synthetic-fixtures.mjs';
import {installTauriStub} from './tauri-stub.mjs';
async function setup(page,language='en'){
 await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
 await installTauriStub(page,{settings:{...SYNTHETIC_SETTINGS,language},dashboard:SYNTHETIC_DASHBOARD},()=>{
  const previous=window.__TAURI_INTERNALS__.invoke;
  window.hubCalls=[];
  window.hubProfiles=[{id:'1',label:'Synthetic account',platform:'codex',selected:true,can_view_usage:true}];
  window.hubListeners=new Map();
  window.hubTaskRecords={};
  window.emitHubProfiles=()=>{for(const [id,handler] of window.hubListeners)window[`_${handler}`]({event:'profiles:changed',id,payload:null});};
  window.hubView={supported:true,connected:false,sessionId:null,workspace:null,selectedWorkspace:null,profileId:null,dispatchCode:null,sessions:[],overview:null};
  window.hubActivate=sessionId=>{
   const session=window.hubView.sessions.find(item=>item.sessionId===sessionId);
   Object.assign(window.hubView,{connected:!!session,sessionId:session?.sessionId??null,workspace:session?.workspace??null,profileId:session?.profileId??null,dispatchCode:session?.dispatchCode??null,overview:session?{tasks:structuredClone(window.hubTaskRecords[sessionId]??[]),agents:['codex'],accounts:['account-1'],projects:['workspace']}:null});
  };
  window.__TAURI_INTERNALS__.invoke=async(command,args)=>{
   if(command==='plugin:event|listen'&&args.event==='profiles:changed'){const id=await previous(command,args);window.hubListeners.set(id,args.handler);return id;}
   if(command==='plugin:event|unlisten')window.hubListeners.delete(args.eventId);
   if(command==='list_profiles'){const result=structuredClone(window.hubProfiles);if(window.delayNextProfiles){window.delayNextProfiles=false;return new Promise(resolve=>window.releaseOldProfiles=()=>resolve(result));}if(window.failProfiles)throw 'catalog_unavailable';return result;}
   if(command==='get_task_hub'){if(args?.sessionId&&args.sessionId!==window.hubView.sessionId){if(!window.hubView.sessions.some(session=>session.sessionId===args.sessionId))throw 'hub_session_unavailable';window.hubActivate(args.sessionId);}return structuredClone(window.hubView);}
   if(command==='select_task_hub_workspace'){window.hubView.selectedWorkspace=window.nextHubWorkspace??'Synthetic workspace';window.nextHubWorkspace=null;return structuredClone(window.hubView);}
   if(command==='connect_task_hub'){
    window.hubCalls.push({command,...args});
    let session=window.hubView.sessions.find(item=>item.profileId===args.profileId&&item.workspace===window.hubView.selectedWorkspace);
    if(!session){const code=String.fromCharCode(64+Number(args.profileId));const sid=String.fromCharCode(97+window.hubView.sessions.length).repeat(64);session={sessionId:sid,profileId:args.profileId,dispatchCode:code,workspace:window.hubView.selectedWorkspace};window.hubView.sessions.push(session);window.hubTaskRecords[sid]=[];}
    window.hubActivate(session.sessionId);return structuredClone(window.hubView);
   }
   if(command==='get_task_hub_messages'){window.hubCalls.push({command,...args});if(window.delayHubMessages)return new Promise(resolve=>window.releaseHubMessages=()=>resolve({taskId:args.taskId,messages:[{taskId:args.taskId,role:'user',text:'Synthetic reviewed task'}]}));return{taskId:args.taskId,messages:[{taskId:args.taskId,role:'user',text:'Synthetic reviewed task'}]};}
   if(command==='task_hub_action'){
    window.hubCalls.push({command,...args});const a=args.action;
    if(window.failHubAction){window.failHubAction=false;throw 'hub_request_unconfirmed';}
    if(a.kind==='create'||a.kind==='resume')window.hubView.overview.tasks.push({id:`task-${window.hubView.overview.tasks.length+1}`,version:1,agent:'codex',project:'workspace',accountAlias:'account-1',state:'awaiting_approval',actionHash:'a'.repeat(64),canResume:false,approvalExpired:false,createdAt:new Date().toISOString(),updatedAt:new Date().toISOString(),approvalExpiresAt:new Date(Date.now()+300000).toISOString()});
    if(a.kind==='approve'){const t=window.hubView.overview.tasks.find(t=>t.id===a.task_id);if(t.actionHash!==a.action_hash)throw'conflict';t.state='running';t.version++;}
    if(a.kind==='cancel'){const t=window.hubView.overview.tasks.find(t=>t.id===a.task_id);if(t.version!==a.expected_version)throw'conflict';t.state='cancelled';t.version++;t.canResume=true;}
    if(a.kind==='resolve'){const t=window.hubView.overview.tasks.find(t=>t.id===a.task_id);if(!a.confirmed_stopped||t.state!=='uncertain'||t.version!==a.expected_version||window.hubOwnedChildActive)throw'hub_conflict';t.state='failed';t.version++;t.reasonCode='operator_confirmed_stopped';t.canResume=true;}
    window.hubTaskRecords[window.hubView.sessionId]=structuredClone(window.hubView.overview.tasks);
    return structuredClone(window.hubView);
   }
   if(command==='disconnect_task_hub'){
    window.hubCalls.push({command,...args});
    window.hubTaskRecords[window.hubView.sessionId]=structuredClone(window.hubView.overview?.tasks??[]);
    window.hubView.sessions=window.hubView.sessions.filter(session=>session.sessionId!==args.sessionId);
    window.hubActivate(null);return structuredClone(window.hubView);
   }
   return previous(command,args);
  };
 });
 await page.goto('/');await page.getByRole('navigation',{name:language==='en'?'Home navigation':'主页导航'}).getByRole('button',{name:language==='en'?'Workspace':'工作台',exact:true}).click();await page.getByRole('tab',{name:language==='en'?'Tasks':'任务',exact:true}).click();return page.getByRole('region',{name:language==='en'?'Task dispatch':'任务派单',exact:true});
}
async function connect(panel){await panel.getByRole('combobox',{name:'Account',exact:true}).selectOption('1');await panel.getByRole('button',{name:'Choose working directory'}).click();await panel.getByRole('button',{name:'Connect dispatch session'}).click();await expect(panel.getByRole('textbox',{name:'Task instruction'})).toBeVisible();}
test('real Tasks flow creates a reviewable draft, approves exact hash, cancels version, resumes and stops only after terminal',async({page})=>{
 const panel=await setup(page);await connect(panel);await panel.getByRole('textbox',{name:'Task instruction'}).fill('Synthetic reviewed task');await panel.getByRole('button',{name:'Create for approval'}).click();
 expect(await page.evaluate(()=>window.hubCalls.filter(c=>c.action?.kind==='approve').length)).toBe(0);
 await panel.getByRole('button',{name:'Review and approve'}).click();const review=panel.getByRole('dialog',{name:'Approve task'});await expect(review.getByText('Synthetic reviewed task')).toBeVisible();await expect(review).toHaveScreenshot('task-hub-approval.png');
 await review.getByRole('button',{name:'Approve and run'}).click();await expect(panel.getByText('Running',{exact:true})).toBeVisible();await expect(panel.getByRole('button',{name:'Stop dispatch service'})).toBeDisabled();
 await panel.getByRole('button',{name:'Cancel task'}).click();await expect(panel.getByText('Cancelled',{exact:true})).toBeVisible();await panel.getByRole('button',{name:'Continue task'}).click();await panel.getByRole('textbox',{name:'Task instruction'}).fill('Synthetic follow-up');await panel.getByRole('button',{name:'Create for approval'}).click();await panel.getByRole('button',{name:'Cancel task'}).click();await panel.getByRole('button',{name:'Stop dispatch service'}).click();await expect(panel.getByRole('button',{name:'Connect dispatch session'})).toBeVisible();
 const actions=await page.evaluate(()=>window.hubCalls.filter(c=>c.command==='task_hub_action').map(c=>c.action));expect(actions.map(a=>a.kind)).toEqual(['create','approve','cancel','resume','cancel']);expect(actions[1].action_hash).toBe('a'.repeat(64));expect(actions[2].expected_version).toBe(2);
});
test('profile sessions switch and keep task actions and disconnect bound to their opaque session IDs',async({page})=>{
 const panel=await setup(page);await connect(panel);const sessionA=await page.evaluate(()=>window.hubView.sessionId);
 await panel.getByRole('textbox',{name:'Task instruction'}).fill('Synthetic task for A');await panel.getByRole('button',{name:'Create for approval'}).click();
 await page.evaluate(()=>{window.hubProfiles.push({id:'2',label:'Synthetic second account',platform:'codex',selected:false,can_view_usage:true});window.emitHubProfiles();});
 const account=panel.getByRole('combobox',{name:'Account',exact:true});await expect(account.getByRole('option',{name:'Synthetic second account',exact:true})).toHaveCount(1);await account.selectOption('2');
 await panel.getByRole('button',{name:'Synthetic workspace'}).click();await panel.getByRole('button',{name:'Connect dispatch session'}).click();const sessionB=await page.evaluate(()=>window.hubView.sessionId);expect(sessionB).not.toBe(sessionA);await expect(panel.getByRole('combobox',{name:'Connected dispatch session'})).toHaveValue(sessionB);await expect(panel).toHaveScreenshot('task-hub-multi-session.png');
 await panel.getByRole('textbox',{name:'Task instruction'}).fill('Synthetic task for B');await panel.getByRole('button',{name:'Create for approval'}).click();
 const sessions=panel.getByRole('combobox',{name:'Connected dispatch session'});await sessions.selectOption(sessionA);await expect.poll(()=>page.evaluate(()=>window.hubView.profileId)).toBe('1');await expect(panel.getByText('Synthetic task for A')).toHaveCount(0);await expect(panel.getByText('Awaiting approval',{exact:true})).toBeVisible();
 await panel.getByRole('button',{name:'Review and approve'}).click();await expect.poll(()=>page.evaluate(()=>window.hubCalls.find(call=>call.command==='get_task_hub_messages')?.sessionId)).toBe(sessionA);await panel.getByRole('button',{name:'Back'}).click();
 await sessions.selectOption(sessionB);await expect.poll(()=>page.evaluate(()=>window.hubView.profileId)).toBe('2');await panel.getByRole('button',{name:'Cancel task'}).click();await panel.getByRole('button',{name:'Stop dispatch service'}).click();
 const routed=await page.evaluate(()=>window.hubCalls.filter(call=>call.command==='task_hub_action').map(call=>call.sessionId));expect(routed).toEqual([sessionA,sessionB,sessionB]);expect(await page.evaluate(()=>window.hubCalls.at(-1))).toMatchObject({command:'disconnect_task_hub',sessionId:sessionB});
 await sessions.selectOption(sessionA);await expect.poll(()=>page.evaluate(()=>window.hubView.sessionId)).toBe(sessionA);await expect(panel.getByText('Awaiting approval',{exact:true})).toBeVisible();expect(await page.evaluate(()=>window.hubView.sessions.map(session=>session.sessionId))).toEqual([sessionA]);
});
test('a newly selected directory does not reroute work until its session is connected',async({page})=>{
 const panel=await setup(page);await connect(panel);const original=await page.evaluate(()=>window.hubView.sessionId);
 await page.evaluate(()=>{window.nextHubWorkspace='Synthetic second workspace';});
 await panel.getByRole('button',{name:'Synthetic workspace'}).click();
 await expect(panel.getByRole('button',{name:'Synthetic second workspace'})).toBeVisible();
 await expect(panel.getByText("After approval, work runs in the directory shown for the connected session.")).toBeVisible();
 await panel.getByRole('textbox',{name:'Task instruction'}).fill('Synthetic task stays on the connected session');
 await panel.getByRole('button',{name:'Create for approval'}).click();
 expect(await page.evaluate(()=>window.hubView.workspace)).toBe('Synthetic workspace');
 expect(await page.evaluate(()=>window.hubView.selectedWorkspace)).toBe('Synthetic second workspace');
 expect(await page.evaluate(()=>window.hubCalls.filter(call=>call.command==='task_hub_action').at(-1).sessionId)).toBe(original);
});
test('same profile and workspace basenames remain distinguishable in the session selector',async({page})=>{
 const panel=await setup(page);await connect(panel);
 const duplicateId=await page.evaluate(()=>{
  const original=window.hubView.sessions[0];
  const duplicate={...original,sessionId:'f'.repeat(64)};
  window.hubView.sessions.push(duplicate);
  return duplicate.sessionId;
 });
 await panel.getByRole('button',{name:'Refresh status'}).click();
 const selector=panel.getByRole('combobox',{name:'Connected dispatch session'});
 const labels=(await selector.locator('option').allTextContents()).filter(label=>label.includes('Synthetic workspace'));
 expect(labels).toHaveLength(2);expect(new Set(labels).size).toBe(2);expect(labels.every(label=>label.includes('Session'))).toBe(true);
 await selector.selectOption(duplicateId);await expect.poll(()=>page.evaluate(()=>window.hubView.sessionId)).toBe(duplicateId);
});
test('uncertain action keeps same idempotency request and blocks accidental duplicate draft',async({page})=>{
 const panel=await setup(page);await connect(panel);await panel.getByRole('textbox',{name:'Task instruction'}).fill('Synthetic reviewed task');await page.evaluate(()=>window.failHubAction=true);await panel.getByRole('button',{name:'Create for approval'}).click();await expect(panel.getByRole('alert')).toContainText('No operation receipt');await expect(panel.getByRole('button',{name:'Create for approval'})).toBeDisabled();await panel.getByRole('button',{name:'Retry same operation'}).click();const actions=await page.evaluate(()=>window.hubCalls.filter(c=>c.command==='task_hub_action').map(c=>c.action));expect(actions).toHaveLength(2);expect(actions[0]).toEqual(actions[1]);
});
test('expired approval and unloaded task instructions cannot approve',async({page})=>{
 const panel=await setup(page);await connect(panel);await panel.getByRole('textbox',{name:'Task instruction'}).fill('Synthetic reviewed task');await panel.getByRole('button',{name:'Create for approval'}).click();await page.evaluate(()=>window.delayHubMessages=true);await panel.getByRole('button',{name:'Review and approve'}).click();await expect(panel.getByRole('button',{name:'Approve and run'})).toBeDisabled();await page.evaluate(()=>window.releaseHubMessages());await expect(panel.getByRole('button',{name:'Approve and run'})).toBeEnabled();await page.clock.setFixedTime(new Date(Date.parse(FIXED_NOW_ISO)+301000));await panel.getByRole('button',{name:'Refresh status'}).click();await expect(panel.getByRole('button',{name:'Approve and run'})).toBeDisabled();
});
async function uncertainTask(page,panel){
 await connect(panel);await panel.getByRole('textbox',{name:'Task instruction'}).fill('Synthetic recovery task');await panel.getByRole('button',{name:'Create for approval'}).click();
 await page.evaluate(()=>{const t=window.hubView.overview.tasks[0];t.state='uncertain';t.version=3;t.actionHash=undefined;t.canResume=false;});await panel.getByRole('button',{name:'Refresh status'}).click();
}
async function finalRecoveryStep(page,panel){
 await panel.getByRole('button',{name:'Check stopped processes',exact:true}).click();const dialog=page.getByRole('dialog',{name:'Confirm task processes stopped'});
 await expect(dialog.getByRole('button',{name:'Checked; continue to final confirmation'})).toBeDisabled();
 await dialog.getByRole('checkbox').check();await dialog.getByRole('button',{name:'Checked; continue to final confirmation'}).click();return dialog;
}
test('uncertain task requires two explicit recovery confirmations; cancelled reviews never submit and only confirmed terminal state releases UI',async({page})=>{
 const panel=await setup(page);await uncertainTask(page,panel);
 await expect(panel.getByRole('button',{name:'Stop dispatch service'})).toBeDisabled();await expect(panel.getByRole('button',{name:'Continue task'})).toHaveCount(0);
 await panel.getByRole('button',{name:'Check stopped processes',exact:true}).click();let dialog=page.getByRole('dialog',{name:'Confirm task processes stopped'});
 await expect(dialog).toHaveScreenshot('task-hub-recovery-first.png');await dialog.getByRole('button',{name:'Cancel',exact:true}).click();
 dialog=await finalRecoveryStep(page,panel);await expect(dialog).toHaveScreenshot('task-hub-recovery-final.png');await dialog.getByRole('button',{name:'Cancel',exact:true}).click();
 expect(await page.evaluate(()=>window.hubCalls.filter(c=>c.action?.kind==='resolve'))).toHaveLength(0);
 dialog=await finalRecoveryStep(page,panel);await dialog.getByRole('button',{name:'Confirm stopped and release reservation'}).click();
 await expect(panel.getByText('Failed',{exact:true})).toBeVisible();await expect(panel.getByText('Stopped was confirmed by the operator; the task was not marked successful. Follow-up work still requires approval.')).toBeVisible();await expect(panel.getByText('Completed',{exact:true})).toHaveCount(0);await expect(panel.getByRole('button',{name:'Stop dispatch service'})).toBeEnabled();
 const actions=await page.evaluate(()=>window.hubCalls.filter(c=>c.action?.kind==='resolve').map(c=>c.action));expect(actions).toHaveLength(1);expect(actions[0]).toMatchObject({kind:'resolve',task_id:'task-1',expected_version:3,confirmed_stopped:true});
 await panel.getByRole('button',{name:'Continue task'}).click();await panel.getByRole('textbox',{name:'Task instruction'}).fill('Synthetic follow-up after recovery');await panel.getByRole('button',{name:'Create for approval'}).click();await expect(panel.getByText('Awaiting approval',{exact:true})).toBeVisible();expect(await page.evaluate(()=>window.hubCalls.filter(c=>c.action?.kind==='approve'))).toHaveLength(0);
 await panel.getByRole('button',{name:'Cancel task'}).click();await panel.getByRole('button',{name:'Stop dispatch service'}).click();await expect(panel.getByRole('button',{name:'Connect dispatch session'})).toBeVisible();
});
test('stale recovery version and owned live child rejection keep the uncertain reservation; a refreshed review never auto-confirms',async({page})=>{
 const panel=await setup(page);await uncertainTask(page,panel);let dialog=await finalRecoveryStep(page,panel);
 await page.evaluate(()=>window.hubView.overview.tasks[0].version++);await dialog.getByRole('button',{name:'Confirm stopped and release reservation'}).click();await expect(panel.getByRole('alert')).toBeVisible();await expect(panel.getByRole('button',{name:'Stop dispatch service'})).toBeDisabled();await expect(panel.getByRole('button',{name:'Retry same operation'})).toHaveCount(0);
 await panel.getByRole('button',{name:'Refresh status'}).click();dialog=await finalRecoveryStep(page,panel);await page.evaluate(()=>window.hubOwnedChildActive=true);await dialog.getByRole('button',{name:'Confirm stopped and release reservation'}).click();await expect(panel.getByText('Check execution state',{exact:true})).toBeVisible();await expect(panel.getByRole('button',{name:'Continue task'})).toHaveCount(0);await expect(panel.getByRole('button',{name:'Stop dispatch service'})).toBeDisabled();
 const actions=await page.evaluate(()=>window.hubCalls.filter(c=>c.action?.kind==='resolve').map(c=>c.action));expect(actions.map(a=>a.expected_version)).toEqual([3,4]);expect(actions.every(a=>a.confirmed_stopped===true)).toBe(true);
 await page.evaluate(()=>window.hubOwnedChildActive=false);await panel.getByRole('button',{name:'Refresh status'}).click();expect(await page.evaluate(()=>window.hubCalls.filter(c=>c.action?.kind==='resolve'))).toHaveLength(2);
});
test('unconfirmed recovery preserves exactly one request ID and does not show execution success or release before its positive receipt',async({page})=>{
 const panel=await setup(page);await uncertainTask(page,panel);const dialog=await finalRecoveryStep(page,panel);await page.evaluate(()=>window.failHubAction=true);await dialog.getByRole('button',{name:'Confirm stopped and release reservation'}).click();await expect(panel.getByRole('alert')).toContainText('No operation receipt');await expect(panel.getByRole('button',{name:'Stop dispatch service'})).toBeDisabled();await expect(panel.getByRole('button',{name:'Continue task'})).toHaveCount(0);
 await panel.getByRole('button',{name:'Retry same operation'}).click();await expect(panel.getByText('Failed',{exact:true})).toBeVisible();await expect(panel.getByRole('button',{name:'Stop dispatch service'})).toBeEnabled();const actions=await page.evaluate(()=>window.hubCalls.filter(c=>c.action?.kind==='resolve').map(c=>c.action));expect(actions).toHaveLength(2);expect(actions[0]).toEqual(actions[1]);
});


test('mounted task selector follows registration rename and removal; stale reads and failed refresh cannot connect', async ({page}) => {
 const panel=await setup(page), select=panel.getByRole('combobox',{name:'Account',exact:true});
 await expect(select).toBeEnabled();
 await page.evaluate(()=>{window.hubProfiles.push({id:'2',label:'Newly registered synthetic',platform:'codex',selected:false,can_view_usage:true});window.emitHubProfiles();});
 await expect(select.getByRole('option',{name:'Newly registered synthetic',exact:true})).toHaveCount(1);
 await select.selectOption('2');
 await panel.getByRole('button',{name:'Choose working directory'}).click();
 await page.evaluate(()=>{window.delayNextProfiles=true;});
 await panel.getByRole('button',{name:'Refresh status'}).click();
 await expect.poll(()=>page.evaluate(()=>typeof window.releaseOldProfiles)).toBe('function');
 await page.evaluate(()=>{window.hubProfiles[1].label='Renamed synthetic';window.emitHubProfiles();});
 await expect(select.getByRole('option',{name:'Renamed synthetic',exact:true})).toHaveCount(1);
 await page.evaluate(()=>window.releaseOldProfiles());
 await expect(select.getByRole('option',{name:'Newly registered synthetic',exact:true})).toHaveCount(0);
 await expect(select).toHaveValue('2');
 await page.evaluate(()=>{window.failProfiles=true;});
 await panel.getByRole('button',{name:'Refresh status'}).click();
 await expect(panel.getByRole('alert')).toContainText('Could not read the account list');
 await expect(panel.getByRole('button',{name:'Connect dispatch session'})).toBeDisabled();
 await page.evaluate(()=>{window.failProfiles=false;window.hubProfiles=window.hubProfiles.filter(row=>row.id!=='2');window.emitHubProfiles();});
 await expect(select).toBeEnabled();await expect(select).toHaveValue('');
 await expect(panel.getByRole('button',{name:'Connect dispatch session'})).toBeDisabled();
 expect(await page.evaluate(()=>window.hubCalls.filter(call=>call.command==='connect_task_hub'))).toEqual([]);
});

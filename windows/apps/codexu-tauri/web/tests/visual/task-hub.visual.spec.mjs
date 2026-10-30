import {test,expect} from '@playwright/test';
import {FIXED_NOW_ISO,SYNTHETIC_DASHBOARD,SYNTHETIC_SETTINGS} from './synthetic-fixtures.mjs';
import {installTauriStub} from './tauri-stub.mjs';
async function setup(page,language='en'){
 await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
 await installTauriStub(page,{settings:{...SYNTHETIC_SETTINGS,language},dashboard:SYNTHETIC_DASHBOARD},()=>{
  const previous=window.__TAURI_INTERNALS__.invoke;window.hubCalls=[];window.hubView={supported:true,connected:false,workspace:null,profileId:null,overview:null};
  window.__TAURI_INTERNALS__.invoke=async(command,args)=>{
   if(command==='list_profiles')return [{id:'1',label:'Synthetic account',platform:'codex',selected:true,can_view_usage:true}];
   if(command==='get_task_hub')return structuredClone(window.hubView);
   if(command==='select_task_hub_workspace'){window.hubView.workspace='Synthetic workspace';return structuredClone(window.hubView);}
   if(command==='connect_task_hub'){window.hubCalls.push({command,...args});Object.assign(window.hubView,{connected:true,profileId:args.profileId,overview:{tasks:[],agents:['codex'],accounts:['account-1'],projects:['workspace']}});return structuredClone(window.hubView);}
   if(command==='get_task_hub_messages'){window.hubCalls.push({command,...args});if(window.delayHubMessages)return new Promise(resolve=>window.releaseHubMessages=()=>resolve({taskId:args.taskId,messages:[{taskId:args.taskId,role:'user',text:'Synthetic reviewed task'}]}));return{taskId:args.taskId,messages:[{taskId:args.taskId,role:'user',text:'Synthetic reviewed task'}]};}
   if(command==='task_hub_action'){
    window.hubCalls.push({command,...args});const a=args.action;
    if(window.failHubAction){window.failHubAction=false;throw 'hub_request_unconfirmed';}
    if(a.kind==='create'||a.kind==='resume')window.hubView.overview.tasks.push({id:`task-${window.hubView.overview.tasks.length+1}`,version:1,agent:'codex',project:'workspace',accountAlias:'account-1',state:'awaiting_approval',actionHash:'a'.repeat(64),canResume:false,approvalExpired:false,createdAt:new Date().toISOString(),updatedAt:new Date().toISOString(),approvalExpiresAt:new Date(Date.now()+300000).toISOString()});
    if(a.kind==='approve'){const t=window.hubView.overview.tasks.find(t=>t.id===a.task_id);if(t.actionHash!==a.action_hash)throw'conflict';t.state='running';t.version++;}
    if(a.kind==='cancel'){const t=window.hubView.overview.tasks.find(t=>t.id===a.task_id);if(t.version!==a.expected_version)throw'conflict';t.state='cancelled';t.version++;t.canResume=true;}
    if(a.kind==='resolve'){const t=window.hubView.overview.tasks.find(t=>t.id===a.task_id);if(!a.confirmed_stopped||t.state!=='uncertain'||t.version!==a.expected_version||window.hubOwnedChildActive)throw'hub_conflict';t.state='failed';t.version++;t.reasonCode='operator_confirmed_stopped';t.canResume=true;}
    return structuredClone(window.hubView);
   }
   if(command==='disconnect_task_hub'){window.hubCalls.push({command});window.hubView.connected=false;window.hubView.overview=null;return structuredClone(window.hubView);}
   return previous(command,args);
  };
 });
 await page.goto('/');await page.getByRole('navigation',{name:language==='en'?'Home navigation':'主页导航'}).getByRole('button',{name:language==='en'?'Workspace':'工作台',exact:true}).click();await page.getByRole('tab',{name:language==='en'?'Tasks':'任务',exact:true}).click();return page.getByRole('region',{name:language==='en'?'Task dispatch':'任务派单',exact:true});
}
async function connect(panel){await panel.getByRole('combobox',{name:'Account',exact:true}).selectOption('1');await panel.getByRole('button',{name:'Choose working directory'}).click();await panel.getByRole('button',{name:'Enable task dispatch'}).click();await expect(panel.getByRole('textbox',{name:'Task instruction'})).toBeVisible();}
test('real Tasks flow creates a reviewable draft, approves exact hash, cancels version, resumes and stops only after terminal',async({page})=>{
 const panel=await setup(page);await connect(panel);await panel.getByRole('textbox',{name:'Task instruction'}).fill('Synthetic reviewed task');await panel.getByRole('button',{name:'Create for approval'}).click();
 expect(await page.evaluate(()=>window.hubCalls.filter(c=>c.action?.kind==='approve').length)).toBe(0);
 await panel.getByRole('button',{name:'Review and approve'}).click();const review=panel.getByRole('dialog',{name:'Approve task'});await expect(review.getByText('Synthetic reviewed task')).toBeVisible();await expect(review).toHaveScreenshot('task-hub-approval.png');
 await review.getByRole('button',{name:'Approve and run'}).click();await expect(panel.getByText('Running',{exact:true})).toBeVisible();await expect(panel.getByRole('button',{name:'Stop dispatch service'})).toBeDisabled();
 await panel.getByRole('button',{name:'Cancel task'}).click();await expect(panel.getByText('Cancelled',{exact:true})).toBeVisible();await panel.getByRole('button',{name:'Continue task'}).click();await panel.getByRole('textbox',{name:'Task instruction'}).fill('Synthetic follow-up');await panel.getByRole('button',{name:'Create for approval'}).click();await panel.getByRole('button',{name:'Cancel task'}).click();await panel.getByRole('button',{name:'Stop dispatch service'}).click();await expect(panel.getByRole('button',{name:'Enable task dispatch'})).toBeVisible();
 const actions=await page.evaluate(()=>window.hubCalls.filter(c=>c.command==='task_hub_action').map(c=>c.action));expect(actions.map(a=>a.kind)).toEqual(['create','approve','cancel','resume','cancel']);expect(actions[1].action_hash).toBe('a'.repeat(64));expect(actions[2].expected_version).toBe(2);
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
 await panel.getByRole('button',{name:'Cancel task'}).click();await panel.getByRole('button',{name:'Stop dispatch service'}).click();await expect(panel.getByRole('button',{name:'Enable task dispatch'})).toBeVisible();
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

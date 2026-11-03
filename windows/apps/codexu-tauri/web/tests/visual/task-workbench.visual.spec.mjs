import {test,expect} from '@playwright/test';
import {installTauriStub} from './tauri-stub.mjs';
import {SYNTHETIC_DASHBOARD,SYNTHETIC_SETTINGS} from './synthetic-fixtures.mjs';
async function setup(page){
 await installTauriStub(page,{settings:{...SYNTHETIC_SETTINGS,language:'en'},dashboard:SYNTHETIC_DASHBOARD},()=>{
  localStorage.setItem('aigoodbro.workspace.page','tools');const original=window.__TAURI_INTERNALS__.invoke;
  const first='12345678-1234-1234-1234-123456789abc',second='87654321-1234-1234-1234-123456789abc';
  const base={updatedAtMs:100,archived:false,executionState:'recorded',outcome:'unknown',decision:'none',decisionAtMs:null,inventoryIsStale:false,needsAttention:false,inventory:null};
  const initial={scopeId:'a'.repeat(64),checkedAtMs:100,sourceAvailable:true,truncated:false,items:[{...base,threadId:first,title:'Alpha project chat',project:'Alpha'},{...base,threadId:second,title:'Beta project chat',project:'Beta'}]};
  window.workbench=JSON.parse(localStorage.getItem('synthetic.workbench')||'null')||initial;window.workbenchSourceA=structuredClone(window.workbench);window.workbenchCalls=[];window.ownerCalls=[];window.ownerInvocations=[];window.ownerStatusMode='unknown';window.ownerPollState='completed';window.ownerPreviewMode='immediate';window.inventoryMode='cancel';window.wbListeners=[];
  window.emitWorkbench=(name)=>{for(const {event,handler} of window.wbListeners)if(event===name)window['_'+handler]({event,payload:null,id:7});};
  window.__TAURI_INTERNALS__.invoke=async(command,args)=>{
   if(['prepare_original_owner_start','prepare_original_owner_interrupt','discard_original_owner_preview','confirm_original_owner_action','get_original_owner_action_status','poll_original_owner_action'].includes(command)){window.ownerCalls.push(command);window.ownerInvocations.push({command,args:structuredClone(args)});}
   if(command==='plugin:event|listen'&&['task-workbench:changed','settings:changed','task-workbench:owner-previews-closed'].includes(args.event))window.wbListeners.push(args);
   if(command==='prepare_original_owner_start'||command==='prepare_original_owner_interrupt'){
    const preview={previewId:'11111111-1111-1111-1111-111111111111',actionHash:'a'.repeat(64),snapshotRevision:9};
    if(window.ownerPreviewMode==='hold')return new Promise(resolve=>{window.finishOwnerPreview=()=>resolve(preview);});
    return preview;
   }
   if(command==='discard_original_owner_preview')return true;
   if(command==='confirm_original_owner_action')return {operationId:args.operationId,state:'accepted',turnId:'33333333-3333-3333-3333-333333333333'};
   if(command==='get_original_owner_action_status')return window.ownerStatusMode==='missing'?null:{operationId:args.operationId,state:window.ownerStatusMode,turnId:null};
   if(command==='poll_original_owner_action')return {operationId:args.operationId,state:window.ownerPollState,turnId:'33333333-3333-3333-3333-333333333333'};
   if(command==='get_task_workbench')return structuredClone(window.workbench);
   if(['set_task_workbench_decision','import_task_workbench_inventory','open_task_workbench_artifact'].includes(command)){
    window.workbenchCalls.push({command,...args});if(args.expectedScopeId!==window.workbench.scopeId)throw 'workbench_source_changed';
    if(command==='open_task_workbench_artifact')return 'openedFolder';
    if(command==='import_task_workbench_inventory'){
     if(window.inventoryMode==='cancel')return null;
     if(window.inventoryMode==='fail')throw 'workbench_invalid';
     if(window.inventoryMode==='hold')return new Promise(resolve=>{window.finishInventory=()=>resolve(structuredClone(initial));});
     const i=window.workbench.items.find(i=>i.threadId===args.threadId);i.inventory={threadID:i.threadId,project:i.project,outcome:'awaitingAcceptance',remaining:['Review result'],nextStep:'Review the document',artifacts:[{title:'Result document',reference:'C:\\synthetic\\result.pdf'}],evidence:'Synthetic imported report',checkedAtMs:101,sourceTurnID:null};i.outcome='awaitingAcceptance';
    }else{const i=window.workbench.items.find(i=>i.threadId===args.threadId);i.decision=args.decision;i.decisionAtMs=102;if(args.decision==='completed')i.outcome='complete';}
    localStorage.setItem('synthetic.workbench',JSON.stringify(window.workbench));return structuredClone(window.workbench);
   }
   return original(command,args);
  };
 });
 await page.goto('/');await page.getByRole('navigation',{name:'Home navigation'}).getByRole('button',{name:'Workspace',exact:true}).click();await page.getByRole('tab',{name:'Tasks',exact:true}).click();const panel=page.getByRole('region',{name:'Project chat inventory',exact:true});await expect(panel.getByRole('button',{name:/Alpha project chat/})).toBeVisible();return panel;
}
test('inventory filters local metadata and cancel/failure preserve the existing record',async({page})=>{
 const panel=await setup(page);expect(await page.evaluate(()=>window.workbenchCalls)).toEqual([]);
 await panel.getByLabel('Filter project',{exact:true}).selectOption('Beta');await expect(panel.getByRole('button',{name:/Alpha project chat/})).toHaveCount(0);await panel.getByLabel('Filter project',{exact:true}).selectOption('');
 await panel.getByRole('button',{name:/Alpha project chat/}).click();const selected=panel.getByRole('article',{name:'Selected chat inventory'});
 await selected.getByRole('button',{name:'Import inventory JSON'}).click();await expect(selected).toContainText('No inventory has been imported.');await expect(panel).not.toContainText('Local record saved.');
 await page.evaluate(()=>window.inventoryMode='fail');await selected.getByRole('button',{name:'Import inventory JSON'}).click();await expect(panel.getByRole('alert')).toContainText('invalid or belongs');await expect(selected).toContainText('No inventory has been imported.');
 expect(await page.evaluate(()=>window.workbenchCalls.map(c=>c.command))).toEqual(['import_task_workbench_inventory','import_task_workbench_inventory']);
});
test('import remains awaiting acceptance, manual decisions persist, and artifacts use a bounded index',async({page})=>{
 const panel=await setup(page);await panel.getByRole('button',{name:/Alpha project chat/}).click();const selected=panel.getByRole('article',{name:'Selected chat inventory'});await page.evaluate(()=>window.inventoryMode='success');
 await selected.getByRole('button',{name:'Import inventory JSON'}).click();await expect(selected).toContainText('Awaiting acceptance');await selected.getByRole('button',{name:'Show folder: Result document'}).click();
 expect(await page.evaluate(()=>window.workbenchCalls.at(-1))).toEqual({command:'open_task_workbench_artifact',expectedScopeId:'a'.repeat(64),threadId:'12345678-1234-1234-1234-123456789abc',artifactIndex:0});
 await selected.getByRole('button',{name:'Manually completed',exact:true}).click();await expect(panel).toContainText('Local record saved.');await page.reload();await panel.getByRole('button',{name:/Alpha project chat/}).click();await expect(selected.getByRole('button',{name:'Manually completed',exact:true})).toBeDisabled();await expect(selected).toContainText('Manually completed');
 expect(await page.evaluate(()=>window.workbenchCalls)).toEqual([]);
});
test('a late inventory result cannot replace a newly selected source',async({page})=>{
 const panel=await setup(page);await panel.getByRole('button',{name:/Alpha project chat/}).click();await page.evaluate(()=>window.inventoryMode='hold');await panel.getByRole('button',{name:'Import inventory JSON'}).click();await expect.poll(()=>page.evaluate(()=>typeof window.finishInventory)).toBe('function');
 await page.evaluate(()=>{window.workbench={...window.workbench,scopeId:'b'.repeat(64),items:[]};window.emitWorkbench('settings:changed');});await expect(panel).toContainText('No chats match these filters.');await page.evaluate(()=>window.finishInventory());await expect(panel.getByRole('button',{name:/Alpha project chat/})).toHaveCount(0);await expect(panel).not.toContainText('Local record saved.');await expect(panel.getByRole('button',{name:'Refresh inventory'})).toBeEnabled();
});
test('the native close event clears an unsubmitted owner preview before the hidden window is reused',async({page})=>{
 const panel=await setup(page);await panel.getByRole('button',{name:/Alpha project chat/}).click();const selected=panel.getByRole('article',{name:'Selected chat inventory'});
 await selected.getByLabel('Text for the original chat').fill('Continue the existing task.');await selected.getByRole('button',{name:'Preview and continue'}).click();
 const preview=selected.getByRole('group',{name:'Original chat action preview'});await expect(preview).toContainText('Snapshot revision 9');
 await page.evaluate(()=>window.emitWorkbench('task-workbench:owner-previews-closed'));
 await expect(preview).toHaveCount(0);await expect(panel).toContainText('Unsubmitted previews were cleared when the window closed.');
 await expect(selected.getByRole('button',{name:'Confirm and send'})).toHaveCount(0);expect(await page.evaluate(()=>window.ownerCalls)).toEqual(['prepare_original_owner_start']);
});
test('polling after selecting another chat keeps the submitted operation bound to its original chat',async({page})=>{
 const panel=await setup(page),alpha='12345678-1234-1234-1234-123456789abc',scope='a'.repeat(64);
 await panel.getByRole('button',{name:/Alpha project chat/}).click();const alphaCard=panel.getByRole('article',{name:'Selected chat inventory'});
 await alphaCard.getByLabel('Text for the original chat').fill('Continue the existing task.');await alphaCard.getByRole('button',{name:'Preview and continue'}).click();
 await alphaCard.getByRole('button',{name:'Confirm and send'}).click();const action=panel.getByTestId('original-owner-operation');await expect(action).toContainText('Accepted by original chat');
 const binding=await page.evaluate(()=>JSON.parse(localStorage.getItem('aigoodbro.original-owner-operation-v1')));expect(binding).toMatchObject({scopeId:scope,threadId:alpha});expect(binding.operationId).toMatch(/^[a-f0-9-]{36}$/);const operation=binding.operationId;
 expect(await page.evaluate(value=>JSON.parse(localStorage.getItem('aigoodbro.original-owner-operation-v1')),binding)).toEqual(binding);
 await panel.getByRole('button',{name:/Beta project chat/}).click();await action.getByRole('button',{name:'Refresh original chat result'}).click();
 await expect(action).toContainText('Completed in original chat');
 expect(await page.evaluate(()=>window.ownerInvocations.filter(c=>c.command==='poll_original_owner_action'))).toEqual([{command:'poll_original_owner_action',args:{expectedScopeId:scope,threadId:alpha,operationId:operation}}]);
 expect(await page.evaluate(()=>localStorage.getItem('aigoodbro.original-owner-operation-v1'))).toBeNull();
 const betaCard=panel.getByRole('article',{name:'Selected chat inventory'});await betaCard.getByLabel('Text for the original chat').fill('Continue the second task.');
 await expect(betaCard.getByRole('button',{name:'Preview and continue'})).toBeEnabled();
});
test('live owner polling is disabled on another source while local status stays queryable and original-thread polling returns with the source',async({page})=>{
 const panel=await setup(page),operation='55555555-5555-5555-5555-555555555555',scope='a'.repeat(64),thread='12345678-1234-1234-1234-123456789abc',binding={operationId:operation,scopeId:scope,threadId:thread};
 await page.evaluate(value=>localStorage.setItem('aigoodbro.original-owner-operation-v1',JSON.stringify(value)),binding);await page.reload();let action=page.getByTestId('original-owner-operation');await expect(action).toContainText('Unknown');await expect.poll(()=>page.evaluate(()=>window.ownerInvocations.some(c=>c.command==='get_original_owner_action_status'))).toBe(true);
 await page.evaluate(()=>{window.ownerInvocations=[];window.ownerStatusMode='accepted';});await action.getByRole('button',{name:'Check same operation'}).click();await expect(action).toContainText('Accepted by original chat');
 await page.evaluate(()=>{window.ownerInvocations=[];window.workbench={...window.workbench,scopeId:'b'.repeat(64)};window.emitWorkbench('settings:changed');});await expect(panel.getByRole('button',{name:/Beta project chat/})).toBeVisible();action=panel.getByTestId('original-owner-operation');
 await expect(action.getByRole('button',{name:'Refresh original chat result'})).toBeDisabled();await expect(action).toContainText('Return to this operation’s original source to refresh the original chat result.');
 await action.getByRole('button',{name:'Check same operation'}).click();await expect(action).toContainText('Accepted by original chat');expect(await page.evaluate(()=>window.ownerInvocations)).toEqual([{command:'get_original_owner_action_status',args:{operationId:operation}}]);
 await page.evaluate(()=>{window.workbench=structuredClone(window.workbenchSourceA);window.emitWorkbench('settings:changed');});await expect(panel.getByRole('button',{name:/Beta project chat/})).toBeVisible();await panel.getByRole('button',{name:/Beta project chat/}).click();action=panel.getByTestId('original-owner-operation');
 await expect(action.getByRole('button',{name:'Refresh original chat result'})).toBeEnabled();await action.getByRole('button',{name:'Refresh original chat result'}).click();await expect(action).toContainText('Completed in original chat');
 expect(await page.evaluate(()=>window.ownerInvocations.filter(c=>c.command==='poll_original_owner_action'))).toEqual([{command:'poll_original_owner_action',args:{expectedScopeId:scope,threadId:thread,operationId:operation}}]);
});
test('an unknown operation stays queryable with its saved binding across source changes and reloads',async({page})=>{
 const panel=await setup(page),operation='44444444-4444-4444-4444-444444444444',scope='a'.repeat(64),thread='12345678-1234-1234-1234-123456789abc',binding={operationId:operation,scopeId:scope,threadId:thread};
 await page.evaluate(value=>localStorage.setItem('aigoodbro.original-owner-operation-v1',JSON.stringify(value)),binding);await page.reload();
 let action=page.getByTestId('original-owner-operation');await expect(action).toContainText('Unknown');
 await expect.poll(()=>page.evaluate(()=>window.ownerInvocations.some(c=>c.command==='get_original_owner_action_status'))).toBe(true);
 await page.evaluate(()=>{window.ownerStatusMode='missing';window.ownerInvocations=[];});await action.getByRole('button',{name:'Check same operation'}).click();
 await expect(action).toContainText('Unknown');expect(await page.evaluate(()=>JSON.parse(localStorage.getItem('aigoodbro.original-owner-operation-v1')))).toEqual(binding);
 await page.evaluate(()=>{window.workbench={...window.workbench,scopeId:'b'.repeat(64)};localStorage.setItem('synthetic.workbench',JSON.stringify(window.workbench));window.emitWorkbench('settings:changed');});
 await expect(action).toContainText('Unknown');expect(await page.evaluate(()=>JSON.parse(localStorage.getItem('aigoodbro.original-owner-operation-v1')))).toEqual(binding);
 await panel.getByRole('button',{name:/Beta project chat/}).click();const betaCard=panel.getByRole('article',{name:'Selected chat inventory'});await betaCard.getByLabel('Text for the original chat').fill('A new action must wait.');
 await expect(betaCard.getByRole('button',{name:'Preview and continue'})).toBeDisabled();
 await page.reload();action=page.getByTestId('original-owner-operation');await expect(action).toContainText('Unknown');
 await expect.poll(()=>page.evaluate(()=>window.ownerInvocations.some(c=>c.command==='get_original_owner_action_status'))).toBe(true);
 await page.evaluate(()=>{window.ownerInvocations=[];window.ownerStatusMode='unknown';});await action.getByRole('button',{name:'Check same operation'}).click();
 expect(await page.evaluate(()=>window.ownerInvocations)).toEqual([{command:'get_original_owner_action_status',args:{operationId:operation}}]);
 expect(await page.evaluate(()=>JSON.parse(localStorage.getItem('aigoodbro.original-owner-operation-v1')))).toEqual(binding);
 await page.getByRole('button',{name:/Beta project chat/}).click();const restoredBeta=page.getByRole('article',{name:'Selected chat inventory'});await restoredBeta.getByLabel('Text for the original chat').fill('Still blocked.');
 await expect(restoredBeta.getByRole('button',{name:'Preview and continue'})).toBeDisabled();
});
test('a late preview is discarded after the source changes instead of attaching to the new chat',async({page})=>{
 const panel=await setup(page),alpha='12345678-1234-1234-1234-123456789abc',scope='a'.repeat(64);
 await panel.getByRole('button',{name:/Alpha project chat/}).click();const alphaCard=panel.getByRole('article',{name:'Selected chat inventory'});
 await alphaCard.getByLabel('Text for the original chat').fill('Continue the existing task.');await page.evaluate(()=>window.ownerPreviewMode='hold');
 await alphaCard.getByRole('button',{name:'Preview and continue'}).click();await expect.poll(()=>page.evaluate(()=>typeof window.finishOwnerPreview)).toBe('function');
 await page.evaluate(()=>{window.workbench={...window.workbench,scopeId:'b'.repeat(64)};window.emitWorkbench('settings:changed');});
 await expect(panel.getByRole('article',{name:'Selected chat inventory'})).toHaveCount(0);await page.evaluate(()=>window.finishOwnerPreview());
 await expect(panel.getByRole('group',{name:'Original chat action preview'})).toHaveCount(0);
 expect(await page.evaluate(()=>window.ownerInvocations.filter(c=>c.command==='prepare_original_owner_start'||c.command==='discard_original_owner_preview'))).toEqual([
  {command:'prepare_original_owner_start',args:{expectedScopeId:scope,threadId:alpha,text:'Continue the existing task.'}},
  {command:'discard_original_owner_preview',args:{previewId:'11111111-1111-1111-1111-111111111111'}},
 ]);
 expect(await page.evaluate(()=>window.ownerInvocations.some(c=>c.command==='confirm_original_owner_action'))).toBe(false);
});

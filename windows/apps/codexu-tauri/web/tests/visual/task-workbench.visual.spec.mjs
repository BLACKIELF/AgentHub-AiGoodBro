import {test,expect} from '@playwright/test';
import {installTauriStub} from './tauri-stub.mjs';
import {SYNTHETIC_DASHBOARD,SYNTHETIC_SETTINGS} from './synthetic-fixtures.mjs';
async function setup(page){
 await installTauriStub(page,{settings:{...SYNTHETIC_SETTINGS,language:'en'},dashboard:SYNTHETIC_DASHBOARD},()=>{
  localStorage.setItem('aigoodbro.workspace.page','tools');const original=window.__TAURI_INTERNALS__.invoke;
  const first='12345678-1234-1234-1234-123456789abc',second='87654321-1234-1234-1234-123456789abc';
  const base={updatedAtMs:100,archived:false,executionState:'recorded',outcome:'unknown',decision:'none',decisionAtMs:null,inventoryIsStale:false,needsAttention:false,inventory:null};
  const initial={scopeId:'a'.repeat(64),checkedAtMs:100,sourceAvailable:true,truncated:false,items:[{...base,threadId:first,title:'Alpha project chat',project:'Alpha'},{...base,threadId:second,title:'Beta archived chat',project:'Beta',archived:true}]};
  window.workbench=JSON.parse(localStorage.getItem('synthetic.workbench')||'null')||initial;window.workbenchCalls=[];window.inventoryMode='cancel';window.wbListeners=[];
  window.emitWorkbench=(name)=>{for(const {event,handler} of window.wbListeners)if(event===name)window['_'+handler]({event,payload:null,id:7});};
  window.__TAURI_INTERNALS__.invoke=async(command,args)=>{
   if(command==='plugin:event|listen'&&['task-workbench:changed','settings:changed'].includes(args.event))window.wbListeners.push(args);
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

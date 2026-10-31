import {test,expect} from '@playwright/test'; import {installTauriStub} from './tauri-stub.mjs'; import {SYNTHETIC_SETTINGS,SYNTHETIC_DASHBOARD} from './synthetic-fixtures.mjs';
async function open(page){
 await installTauriStub(page,{settings:{...SYNTHETIC_SETTINGS,language:'en'},dashboard:SYNTHETIC_DASHBOARD},()=>{
  const original=window.__TAURI_INTERNALS__.invoke;window.orderCalls=[];window.orderRows=['a','b','c'].map(id=>({id:id.repeat(32),label:id.toUpperCase()}));
  window.__TAURI_INTERNALS__.invoke=async(command,args)=>{if(command==='reorder_managed_accounts'){window.orderCalls.push(structuredClone(args));if(window.orderFail)throw Error('account_order_changed');window.orderRows=args.orderedIds.map(id=>window.orderRows.find(r=>r.id===id));return args.orderedIds;}return original(command,args);};
 });await page.goto('/');await page.evaluate(async()=>{document.getElementById('root').hidden=true;const node=document.createElement('div');node.id='account-order-fixture';document.body.append(node);const {mountAccountOrder}=await import('/tests/visual/account-order-component.fixture.tsx');window.orderHarness=mountAccountOrder(node,window.orderRows);});
 const panel=page.locator('#account-order-fixture');await panel.getByRole('button',{name:'Reorder accounts',exact:true}).click();return panel;
}
test('order editor submits exact stable full IDs and expected order, with accessible position and arrow controls',async({page})=>{
 const panel=await open(page);await panel.getByRole('button',{name:'Move down · A',exact:true}).click();await panel.getByRole('spinbutton',{name:'Target position · C',exact:true}).fill('1');
 expect(await page.evaluate(()=>window.orderCalls)).toEqual([]);await panel.getByRole('button',{name:'Save order',exact:true}).click();await expect(panel.getByRole('dialog')).toHaveCount(0);
 expect(await page.evaluate(()=>window.orderCalls)).toEqual([{orderedIds:['c'.repeat(32),'b'.repeat(32),'a'.repeat(32)],expectedOrder:['a'.repeat(32),'b'.repeat(32),'c'.repeat(32)]}]);
 await page.evaluate(()=>window.orderHarness.update(window.orderRows));await panel.getByRole('button',{name:'Reorder accounts',exact:true}).click();await expect(panel.getByRole('spinbutton',{name:'Target position · C',exact:true})).toHaveValue('1');
});
test('failed save retains the draft and a changed account set prevents stale submission',async({page})=>{
 const panel=await open(page);await panel.getByRole('button',{name:'Move down · A',exact:true}).click();await page.evaluate(()=>{window.orderFail=true;});await panel.getByRole('button',{name:'Save order',exact:true}).click();await expect(panel.getByRole('alert')).toContainText('Not saved');await expect(panel.getByRole('spinbutton',{name:'Target position · A',exact:true})).toHaveValue('2');
 await page.evaluate(()=>window.orderHarness.update([...window.orderRows,{id:'d'.repeat(32),label:'D'}]));await expect(panel.getByRole('button',{name:'Save order',exact:true})).toBeDisabled();expect(await page.evaluate(()=>window.orderCalls.length)).toBe(1);
 await panel.getByRole('button',{name:'Cancel',exact:true}).click();await expect(panel.getByRole('dialog')).toHaveCount(0);
});

import {test,expect}from'@playwright/test';
import {installTauriStub}from'./tauri-stub.mjs';
import {SYNTHETIC_DASHBOARD,SYNTHETIC_SETTINGS}from'./synthetic-fixtures.mjs';

async function open(page){
 await installTauriStub(page,{settings:{...SYNTHETIC_SETTINGS,language:'en'},dashboard:SYNTHETIC_DASHBOARD},()=>{
  const original=window.__TAURI_INTERNALS__.invoke;window.providerClientCalls=[];
  window.__TAURI_INTERNALS__.invoke=async(command,args)=>{
   if(command==='plugin:dialog|open')return 'C:\\Synthetic\\provider-workspace';
   if(command==='get_provider_pool_clients'){window.providerClientCalls.push({command,args:null});return [];}
   if(command==='start_provider_pool_client'){
    window.providerClientCalls.push({command,args:structuredClone(args)});
    return {...args.request,state:'running',issueCode:null};
   }
   return original(command,args);
  };
 });
 await page.goto('/');
 await page.evaluate(async()=>{
  document.getElementById('root').hidden=true;
  const node=document.createElement('div');node.id='provider-pool-client-fixture';
  node.style.cssText='max-width:760px;margin:16px auto;padding:20px;background:#152131;color:white';document.body.append(node);
  const {mountProviderPoolClient}=await import('/tests/visual/provider-pool-client-component.fixture.tsx');
  window.providerClientHarness=mountProviderPoolClient(node);
 });
 return page.getByLabel('Account pool clients',{exact:true});
}

test('Agy uses its default model, hides selection, and submits the empty-model contract',async({page})=>{
 const panel=await open(page);
 await expect(panel.getByLabel('Client',{exact:true})).toHaveValue('agy');
 await expect(panel.getByLabel('Observed model',{exact:true})).toHaveCount(0);
 await expect(panel).toContainText('Agy chooses its own default model');
 await panel.getByRole('button',{name:'Choose working directory',exact:true}).click();
 await expect(panel.getByRole('button',{name:'Launch client',exact:true})).toBeEnabled();
 await expect(panel).toHaveScreenshot('provider-pool-client-agy.png');
 await panel.getByRole('button',{name:'Launch client',exact:true}).click();
 await expect(panel).toContainText('Agy CLI');
 const call=await page.evaluate(()=>window.providerClientCalls.find(row=>row.command==='start_provider_pool_client'));
 expect(call.args.request).toMatchObject({runId:'r'.repeat(43),provider:'antigravity',kind:'agy',model:'',workspace:'C:\\Synthetic\\provider-workspace'});
});

test('Agy is blocked without a live Gemini model while other providers retain model selection',async({page})=>{
 const panel=await open(page);
 await page.evaluate(async()=>{
  const {clientSnapshot}=await import('/tests/visual/provider-pool-client-component.fixture.tsx');
  const next=structuredClone(clientSnapshot);next.providerModels.antigravity=['claude-3.7-sonnet'];
  window.providerClientHarness.snapshot(next);
 });
 await expect(panel.getByRole('alert')).toContainText('No Gemini model is currently observed');
 await expect(panel.getByRole('button',{name:'Launch client',exact:true})).toBeDisabled();
 await expect(panel).toHaveScreenshot('provider-pool-client-no-gemini.png');
 await page.evaluate(()=>window.providerClientHarness.provider('claude'));
 await expect(panel.getByLabel('Client',{exact:true})).toHaveValue('native');
 await expect(panel.getByLabel('Observed model',{exact:true})).toBeVisible();
 await expect(panel.getByLabel('Observed model',{exact:true})).toHaveValue('claude-3.7-sonnet');
 expect(await page.evaluate(()=>window.providerClientCalls.some(row=>row.command==='start_provider_pool_client'))).toBe(false);
});

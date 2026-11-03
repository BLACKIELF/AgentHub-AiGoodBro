import {test,expect} from '@playwright/test';
import {installTauriStub} from './tauri-stub.mjs';
import {SYNTHETIC_DASHBOARD,SYNTHETIC_SETTINGS} from './synthetic-fixtures.mjs';
async function setup(page){
 await installTauriStub(page,{settings:{...SYNTHETIC_SETTINGS,language:'en'},dashboard:SYNTHETIC_DASHBOARD},()=>{
  localStorage.setItem('aigoodbro.workspace.page','accounts');
  const original=window.__TAURI_INTERNALS__.invoke;window.metadataLabel='Legacy A';window.metadataFail=false;window.metadataCalls=[];const listeners=[];
  const changed=()=>{for(const event of listeners)if(['profiles:changed','managed-accounts:changed'].includes(event.event))window['_'+event.handler]({event:event.event,payload:null,id:1});};
  window.__TAURI_INTERNALS__.invoke=async(command,args)=>{
   if(command==='plugin:event|listen')listeners.push(args);
   if(command==='list_managed_accounts')return [{id:'a'.repeat(32),label:window.metadataLabel,platform:'codex',storage_kind:'managed',login_state:'signed_out',active_state:'unknown',masked_identity:null,can_login:true,can_switch:false,switch_block_reason:'needs_reauth',revision:1,recovery_required:false}];
   if(command==='list_profiles')return [{id:'1',label:window.metadataLabel,managed:true,platform:'codex',platform_name:'Codex',selected:false,can_view_usage:true},{id:'2',label:'Ordinary',managed:false,platform:'codex',platform_name:'Codex',selected:false,can_view_usage:true}];
   if(command==='rename_managed_account'||command==='update_profile'){
    window.metadataCalls.push({command,args});if(window.metadataFail)throw 'account_store_unavailable';
    const label=command==='rename_managed_account'?args.label:args.action.label;window.metadataLabel=label||'Legacy A';changed();
    return command==='rename_managed_account'?{account_id:args.accountId,phase:'renamed',error_code:null}:[];
   }
   return original(command,args);
  };
 });await page.goto('/');
 return {managed:page.getByTestId('managed-account-'+'a'.repeat(32)),profile:page.getByTestId('profile-1'),ordinary:page.getByTestId('profile-2')};
}
test('real Home and managed entries share remark readback, accept forty graphemes, and restore baseline on empty',async({page})=>{
 const f=await setup(page);const family='👨‍👩‍👧‍👦';
 await f.managed.getByRole('button',{name:'Customize name',exact:true}).click();const dialog=page.getByRole('dialog',{name:'Rename account',exact:true});
 await dialog.getByLabel('Account alias',{exact:true}).fill(family.repeat(41));await dialog.getByRole('button',{name:'Save alias',exact:true}).click();await expect(dialog).toHaveCount(0);
 await expect(f.managed.getByRole('heading',{level:3})).toHaveText(family.repeat(40));await expect(f.profile.locator('.account-directory-heading')).toContainText(family.repeat(40));
 expect(await page.evaluate(()=>window.metadataCalls[0].args.label)).toBe(family.repeat(40));
 await f.profile.getByRole('button',{name:'Customize name',exact:true}).click();const edit=page.getByLabel('Alias (not email)',{exact:true});await edit.fill('');
 await page.getByRole('button',{name:'Save',exact:true}).click();await expect(f.managed.getByRole('heading',{level:3})).toHaveText('Legacy A');await expect(f.profile).toContainText('Legacy A');
 await f.ordinary.getByRole('button',{name:'Customize name',exact:true}).click();await page.getByLabel('Alias (not email)',{exact:true}).fill('');await expect(page.getByRole('button',{name:'Save',exact:true})).toBeDisabled();
});
test('failed clear keeps draft and old label until authoritative readback succeeds',async({page})=>{
 const f=await setup(page);await f.managed.getByRole('button',{name:'Customize name',exact:true}).click();const dialog=page.getByRole('dialog',{name:'Rename account',exact:true});
 await dialog.getByLabel('Account alias',{exact:true}).fill('');await page.evaluate(()=>{window.metadataFail=true;});await dialog.getByRole('button',{name:'Save alias',exact:true}).click();
 await expect(dialog.getByRole('alert')).toBeVisible();await expect(dialog.getByLabel('Account alias',{exact:true})).toHaveValue('');await expect(f.managed.getByRole('heading',{level:3})).toHaveText('Legacy A');
 expect(await page.evaluate(()=>window.metadataCalls.length)).toBe(1);
});

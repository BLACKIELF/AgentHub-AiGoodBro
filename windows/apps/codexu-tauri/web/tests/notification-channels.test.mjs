import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import vm from 'node:vm';
import ts from 'typescript';
const cache=new Map();function load(url){if(cache.has(url.href))return cache.get(url.href);const context=vm.createContext({exports:{},TextEncoder,Date,require:specifier=>{if(!specifier.startsWith('.'))throw Error('unexpected import');return load(new URL(specifier+'.ts',url));}});vm.runInContext(ts.transpileModule(readFileSync(url,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,context);cache.set(url.href,context.exports);return context.exports;}
const api=load(new URL('../src/utils/notificationChannels.ts',import.meta.url));
const qr=load(new URL('../src/utils/notificationQr.ts',import.meta.url));
const options=()=>({includesAgentName:false,includesAccountLabel:true,includesQuotas:true,includesResetTimes:true,includesResetCredits:true,resetExpiryDetail:'nearest',notifiesFiveHourReset:true,notifiesSevenDayReset:true});
const channel=(kind='feishu')=>({channel:kind,enabled:false,phase:'disabled',revision:0,credentialPresent:false,targetPresent:false,lastAcceptedAt:null,failureCode:null,options:options()});
const plain=value=>JSON.parse(JSON.stringify(value));
test('all four native channels retain stable order and flags, never credential values',()=>{
 const input=api.notificationKinds.map(channel).reverse();assert.deepEqual(plain(api.parseNotificationChannels(input)).map(value=>value.channel),['feishu','telegram','wechat','personal-wechat']);
 for(const bad of [[channel()],api.notificationKinds.map(()=>channel()),[...input.slice(1),{...input[0],secret:'SYNTHETIC_NOT_REAL'}]])assert.throws(()=>api.parseNotificationChannels(bad));
 assert.throws(()=>api.parseNotificationChannel({...channel(),phase:'connected'}));assert.throws(()=>api.parseNotificationChannel({...channel(),enabled:true}));
});
test('saving a credential cannot imply opt-in or API acceptance; ready requires current proof',()=>{
 const saved={...channel(),credentialPresent:true};assert.equal(api.parseNotificationChannel(saved).enabled,false);assert.equal(api.notificationCanTest(saved),false);
 assert.throws(()=>api.parseNotificationChannel({...saved,enabled:true,phase:'ready'}));
 const ready={...saved,enabled:true,phase:'ready',lastAcceptedAt:100};assert.equal(api.notificationCanTest(api.parseNotificationChannel(ready)),true);
 const personal={...channel('personal-wechat'),enabled:true,credentialPresent:true,targetPresent:true,phase:'context_required'};assert.equal(api.notificationCanTest(api.parseNotificationChannel(personal)),false);
 assert.throws(()=>api.parseNotificationChannel({...ready,channel:'telegram',targetPresent:false}));
});
test('only actual acceptance/rejection/uncertainty receipt states are admitted',()=>{
 const receipt={channel:'telegram',eventId:'a'.repeat(64),state:'accepted',checkedAt:100,remoteMessageId:'77',failureCode:null};
 for(const state of ['accepted','rejected','uncertain','duplicate_skipped','not_sent'])assert.equal(api.parseNotificationReceipt({...receipt,state},'telegram').state,state);
 for(const state of ['delivered','read','sent','success'])assert.throws(()=>api.parseNotificationReceipt({...receipt,state},'telegram'));
 assert.throws(()=>api.parseNotificationReceipt(receipt,'feishu'));assert.throws(()=>api.parseNotificationReceipt({...receipt,errorText:'private response'},'telegram'));
});
test('personal QR data is admitted only for the current active attempt and pairing codes are bounded digits',()=>{
 const login={attemptId:'synthetic_attempt',phase:'waiting',qrContent:'SYNTHETIC_QR_ONLY_NOT_A_LOGIN',expiresAt:Math.floor(Date.now()/1000)+300};
 assert.equal(api.parsePersonalNotificationLogin(login,'synthetic_attempt').qrContent,login.qrContent);
 for(const change of [{attemptId:'previous_attempt'},{phase:'confirmed'},{qrContent:'x\nprivate'},{qrContent:'大'.repeat(1500)},{secret:'private'}])assert.throws(()=>api.parsePersonalNotificationLogin({...login,...change},'synthetic_attempt'));
 assert.equal(api.personalNotificationLoginActive(api.parsePersonalNotificationLogin({...login,phase:'confirmed',qrContent:null})),false);
 for(const value of ['0000','1234567890'])assert.equal(api.validNotificationVerificationCode(value),true);
 for(const value of ['123','12345678901','１２３４','1234 ','a1234'])assert.equal(api.validNotificationVerificationCode(value),false);
});
test('Mac compact/detailed presets preserve both notification opt-outs and exact native options',()=>{
 const original={...options(),notifiesFiveHourReset:false,notifiesSevenDayReset:false};const compact=api.applyNotificationPreset(original,'compact');assert.equal(api.notificationPreset(compact),'compact');assert.equal(compact.includesQuotas,false);assert.equal(compact.resetExpiryDetail,'none');assert.equal(compact.notifiesFiveHourReset,false);assert.equal(compact.notifiesSevenDayReset,false);
 const detailed=api.applyNotificationPreset(compact,'detailed');assert.equal(api.notificationPreset(detailed),'detailed');assert.equal(detailed.notifiesSevenDayReset,false);assert.equal(api.notificationOptionsEqual(detailed,{...detailed}),true);
 assert.deepEqual(plain(api.applyNotificationPreset(compact,'custom')),plain(compact));assert.throws(()=>api.parseNotificationOptions({...original,unsupported:true}));
});
test('the exact licensed QR encoder is vendored with only its module export added',()=>{
 const provenance=JSON.parse(readFileSync(new URL('../src/vendor/qrcodegen/SOURCE.json',import.meta.url)));const source=readFileSync(new URL('../src/vendor/qrcodegen/qrcodegen.ts',import.meta.url));
 const append=Buffer.from('\n// Module export for the existing Windows application bundle.\nexport { qrcodegen };\n');assert.equal(source.subarray(-append.length).equals(append),true);
 assert.equal(createHash('sha256').update(source.subarray(0,-append.length)).digest('hex'),provenance.sourceSHA256);assert.equal(provenance.commit,'720f62bddb7226106071d4728c292cb1df519ceb');
 assert.match(readFileSync(new URL('../public/licenses/qrcodegen-MIT-1.8.0.txt',import.meta.url),'utf8'),/Permission is hereby granted/);
});
test('pairing payloads become bounded pixel paths without HTML, URLs or external requests',()=>{
 const encoded=qr.notificationQr('SYNTHETIC_QR_ONLY_NOT_A_LOGIN');assert.ok(encoded.size>=29&&encoded.size<=185);assert.match(encoded.path,/^M/);assert.match(encoded.path,/^[M0-9,hvz-]+$/);assert.equal(encoded.path.includes('SYNTHETIC'),false);
 assert.throws(()=>qr.notificationQr(''));assert.throws(()=>qr.notificationQr('x'.repeat(4097)));assert.throws(()=>qr.notificationQr('x\nprivate'));
});

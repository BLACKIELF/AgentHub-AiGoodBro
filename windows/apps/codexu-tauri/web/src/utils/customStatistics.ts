export const CUSTOM_STATISTICS_KEY='aigoodbro.statistics.custom.v1';
export const CUSTOM_STATISTICS_EVENT='aigoodbro:custom-statistics';
export type StatisticsEngine='upstream'|'custom';
export interface CustomStatistics {version:1;revision:number;engine:StatisticsEngine;entries:{name:string;tokens:string}[]}
const max=9223372036854775807n;
function fail():never {throw Error('custom_statistics_invalid');}
export function tokensFromWan(input:string):string {
 const text=input.trim().replace(/,/g,'.').replace(/^([+]?)[.]/,'$10.');if(text.length>128)fail();
 const match=/^\+?(\d+)(?:\.(\d*))?(?:e([+-]?\d{1,3}))?$/i.exec(text);if(!match)fail();
 const digits=BigInt(match[1]+(match[2]??'')),scale=4-(match[2]?.length??0)+Number(match[3]??0);
 if(digits<=0n||scale>40||scale< -140)fail();
 const result=scale>=0?digits*10n**BigInt(scale):digits/10n**BigInt(-scale);if(result>max)fail();return result.toString();
}
export function customTotal(entries:CustomStatistics['entries']):string {let total=0n;for(const entry of entries){if(!/^(0|[1-9]\d{0,18})$/.test(entry.tokens))fail();const amount=BigInt(entry.tokens);if(amount>max)fail();total+=amount;if(total>max)fail();}return total.toString();}
export function parseCustomStatistics(raw:string|null):CustomStatistics {
 if(raw===null)return {version:1,revision:0,engine:'upstream',entries:[]};if(raw.length>32768)fail();
 let value:CustomStatistics;try{value=JSON.parse(raw);}catch{fail();}
 if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(k=>!['version','revision','engine','entries'].includes(k))||value.version!==1||!Number.isSafeInteger(value.revision)||value.revision<0||!['upstream','custom'].includes(value.engine)||!Array.isArray(value.entries)||value.entries.length>128)fail();
 const names=new Set<string>();for(const entry of value.entries){if(!entry||Object.keys(entry).sort().join(',')!=='name,tokens'||typeof entry.name!=='string'||entry.name.trim()!==entry.name||!entry.name||new TextEncoder().encode(entry.name).length>160||/[\x00-\x1f\x7f]/.test(entry.name)||names.has(entry.name)||typeof entry.tokens!=='string')fail();names.add(entry.name);}
 customTotal(value.entries);return value;
}
export function readCustomStatistics():CustomStatistics {try{return parseCustomStatistics(localStorage.getItem(CUSTOM_STATISTICS_KEY));}catch{throw Error('custom_statistics_unavailable');}}
export async function updateCustomStatistics(change:(value:CustomStatistics)=>CustomStatistics,beforeSave?:(old:CustomStatistics,next:CustomStatistics)=>Promise<void>):Promise<CustomStatistics>{
 if(!navigator.locks)throw Error('custom_statistics_lock_unavailable');
 // A browser-provided lock covers every same-origin window, including an
 // asynchronous cancellation before changing the persisted statistics mode.
 return navigator.locks.request(CUSTOM_STATISTICS_KEY,async()=>{
  const previous=readCustomStatistics(),next=change(structuredClone(previous));next.revision=previous.revision+1;
  const raw=JSON.stringify(next);parseCustomStatistics(raw);await beforeSave?.(previous,next);
  try{localStorage.setItem(CUSTOM_STATISTICS_KEY,raw);}catch{throw Error('custom_statistics_save_failed');}
  window.dispatchEvent(new Event(CUSTOM_STATISTICS_EVENT));return next;
 });
}

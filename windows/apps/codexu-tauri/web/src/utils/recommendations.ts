export const RECOMMENDATION_IDS=['oracle','handoff','jev-use','quicktoggle','rea','aihot'] as const;
export type RecommendationId=typeof RECOMMENDATION_IDS[number];
export interface RecommendationText {zh:string;en:string}
export interface RecommendationItem {id:RecommendationId;kind:'skill'|'app';title:RecommendationText;purpose:RecommendationText;summary:RecommendationText;sourceUrl:string;instructions:string;presence:'installed'|'notInstalled'|'unknown'|'notApplicable';hidden:boolean;packageAvailable:boolean;canInstall:boolean}
export interface Recommendations {revision:number;checkedAtMs:number|null;items:RecommendationItem[]}
const invalid=():never=>{throw Error('recommendation_invalid_response');};
function object(v:unknown){if(!v||typeof v!=='object'||Array.isArray(v))invalid();return v as Record<string,unknown>;}
function keys(v:Record<string,unknown>,names:string[]){if(Object.keys(v).sort().join('|')!==names.sort().join('|'))invalid();}
function text(v:unknown,max=32768){if(typeof v!=='string'||!v||v.length>max||v.includes('\0'))invalid();return v as string;}
function bilingual(v:unknown){const x=object(v);keys(x,['zh','en']);return{zh:text(x.zh,2048),en:text(x.en,2048)};}
const projects:Record<RecommendationId,string>={oracle:'https://github.com/BLACKIELF/AgentHub-AiGoodBro',handoff:'https://github.com/BLACKIELF/AgentHub-AiGoodBro','jev-use':'https://github.com/Sac-Y/Jev-cu',quicktoggle:'https://github.com/BLACKIELF/QuickToggle/releases',rea:'https://github.com/morluto/rea',aihot:'https://github.com/KKKKhazix/AIHOT'};
export function parseRecommendations(raw:unknown):Recommendations {
 const v=object(raw);keys(v,['revision','checkedAtMs','items']);if(!Number.isSafeInteger(v.revision)||Number(v.revision)<0||v.checkedAtMs!==null&&(!Number.isSafeInteger(v.checkedAtMs)||Number(v.checkedAtMs)<0||Number(v.checkedAtMs)>253402300799000))invalid();
 if(!Array.isArray(v.items)||v.items.length!==6)invalid();
 const items=(v.items as unknown[]).map((raw,index)=>{const a=object(raw);keys(a,['id','kind','title','purpose','summary','sourceUrl','instructions','presence','hidden','packageAvailable','canInstall']);const id=RECOMMENDATION_IDS[index],kind=['quicktoggle','aihot'].includes(id)?'app':'skill';if(a.id!==id||a.kind!==kind||a.sourceUrl!==projects[id]||!['installed','notInstalled','unknown','notApplicable'].includes(String(a.presence))||[a.hidden,a.packageAvailable,a.canInstall].some(x=>typeof x!=='boolean')||a.canInstall&&(kind!=='skill'||!a.packageAvailable))invalid();return{id,kind,title:bilingual(a.title),purpose:bilingual(a.purpose),summary:bilingual(a.summary),sourceUrl:a.sourceUrl as string,instructions:text(a.instructions),presence:a.presence as RecommendationItem['presence'],hidden:a.hidden as boolean,packageAvailable:a.packageAvailable as boolean,canInstall:a.canInstall as boolean};});
 return{revision:v.revision as number,checkedAtMs:v.checkedAtMs as number|null,items:items as RecommendationItem[]};
}
export function visibleRecommendations(value:Recommendations,filter:'all'|'skill'|'app'){return value.items.filter(x=>!x.hidden&&x.presence!=='installed'&&(filter==='all'||x.kind===filter));}
export function parseRecommendationAction(value:unknown){const v=object(value);keys(v,['status']);if(!['copied','codexRequested','copiedCodexUnavailable','packageShown','projectRequested'].includes(String(v.status)))invalid();return v.status as 'copied'|'codexRequested'|'copiedCodexUnavailable'|'packageShown'|'projectRequested';}

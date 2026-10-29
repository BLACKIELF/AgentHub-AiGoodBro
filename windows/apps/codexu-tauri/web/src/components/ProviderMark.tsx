import type { CSSProperties } from 'react';
import { CircleDashed } from 'lucide-react';
import { canonicalCompactProvider } from '../utils/compactUi';
const marks:Record<string,{file:string;mask?:boolean}>={codex:{file:'codex',mask:true},claude:{file:'claude',mask:true},grok:{file:'grok',mask:true},opencode:{file:'opencode',mask:true},gemini:{file:'gemini',mask:true},kimi:{file:'kimi',mask:true},workbuddy:{file:'workbuddy',mask:true},zai:{file:'zai',mask:true},trae:{file:'trae'},antigravity:{file:'antigravity'},mimo:{file:'xiaomi'}};
export function providerName(id:string){return ({codex:'Codex',claude:'Claude Code',grok:'Grok',opencode:'OpenCode',gemini:'Gemini CLI',kimi:'Kimi Code',workbuddy:'WorkBuddy',zai:'ZCode',trae:'TRAE',antigravity:'Antigravity',mimo:'MiMo'} as Record<string,string>)[canonicalCompactProvider(id)]??id;}
export function ProviderMark({provider,size=24}:{provider:string;size?:number}){
 const mark=marks[canonicalCompactProvider(provider)];
 if(!mark)return <CircleDashed size={size} aria-hidden="true"/>;
 const src='/provider-icons/'+mark.file+'.svg';
 return mark.mask?<span aria-hidden="true" className="provider-mark-mask" style={{width:size,height:size,maskImage:'url('+src+')',WebkitMaskImage:'url('+src+')'} as CSSProperties}/>:<img aria-hidden="true" className="provider-mark" alt="" src={src} width={size} height={size}/>;
}

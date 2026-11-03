'use strict';
// Source-embedded verifier: no package code or lifecycle script is loaded.
const fs=require('node:fs'), path=require('node:path'), https=require('node:https');
const crypto=require('node:crypto'),zlib=require('node:zlib');
const PACKAGES={grok:['@xai-official/grok','grok'],open_code:['opencode-ai','opencode'],kimi:['@moonshot-ai/kimi-code','kimi'],gemini:['@google/gemini-cli','gemini'],work_buddy:['@tencent-ai/codebuddy-code','codebuddy']};
const need=(ok,code)=>{if(!ok)throw new Error(code)};
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
function safe(rel){need(typeof rel==='string'&&rel.length>0&&rel.length<=4096&&!/[\\:<>"|?*\x00-\x1f]/.test(rel)&&!rel.startsWith('/')&&rel.split('/').every(x=>x&&x!=='.'&&x!=='..'&&!/[ .]$/.test(x)&&!/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)/i.test(x)),'package_path_invalid');return rel;}
function ordinary(p){const full=path.resolve(p);let next=full;while(true){const s=fs.lstatSync(next);need(!s.isSymbolicLink(),'package_path_linked');const parent=path.dirname(next);if(parent===next)break;next=parent;}return full;}
function read(p,max=2*1024*1024){ordinary(p);const fd=fs.openSync(p,'r');try{const s=fs.fstatSync(fd);need(s.isFile()&&s.size<=max&&s.nlink===1,'package_file_invalid');const b=Buffer.alloc(s.size+1);let at=0,n;while(at<b.length&&(n=fs.readSync(fd,b,at,b.length-at,at)))at+=n;need(at===s.size,'package_file_changed');return b.subarray(0,at);}finally{fs.closeSync(fd);}}
function octal(b){const t=b.toString('ascii').replace(/\0.*$/,'').trim();need(/^[0-7]*$/.test(t),'package_tar_invalid');return t?parseInt(t,8):0;}
function tarFiles(compressed){
  const b=zlib.gunzipSync(compressed,{maxOutputLength:256*1024*1024}),files=new Map(),casefold=new Set();let nextPath=null;
  for(let pos=0;pos+512<=b.length;){const h=b.subarray(pos,pos+512);if(h.every(x=>x===0))break;
    let sum=0;for(let i=0;i<512;i++)sum+=(i>=148&&i<156)?32:h[i];need(sum===octal(h.subarray(148,156)),'package_tar_invalid');
    const size=octal(h.subarray(124,136));need(size<=128*1024*1024&&pos+512+size<=b.length,'package_tar_invalid');
    const value=b.subarray(pos+512,pos+512+size),type=String.fromCharCode(h[156]||48);pos+=512+Math.ceil(size/512)*512;
    if(type==='x'){let at=0;while(at<value.length){const space=value.indexOf(32,at);need(space>at,'package_tar_invalid');const len=Number(value.subarray(at,space).toString('ascii'));need(Number.isInteger(len)&&len>space-at+1&&at+len<=value.length&&value[at+len-1]===10,'package_tar_invalid');const item=value.subarray(space+1,at+len-1).toString('utf8');if(item.startsWith('path='))nextPath=item.slice(5);need(!item.startsWith('linkpath='),'package_tar_linked');at+=len;}continue;}
    need(type==='0'||type==='5','package_tar_linked');let name=nextPath||h.subarray(0,100).toString().split('\0')[0];nextPath=null;
    const prefix=h.subarray(345,500).toString().split('\0')[0];if(prefix)name=prefix+'/'+name;
    if(type==='5'){name=name.replace(/\/$/,'');need(name==='package'||name.startsWith('package/'),'package_tar_invalid');if(name!=='package')safe(name.slice(8));continue;}need(name.startsWith('package/'),'package_tar_invalid');const rel=safe(name.slice(8));
    need(!casefold.has(rel.toLowerCase())&&files.size<25000,'package_tar_duplicate');casefold.add(rel.toLowerCase());files.set(rel,Buffer.from(value));
  }return files;
}
async function fetchBytes(url,max){const parsed=new URL(url);need(parsed.protocol==='https:'&&parsed.hostname==='registry.npmjs.org'&&!parsed.username&&!parsed.password&&!parsed.port,'registry_url_invalid');return new Promise((resolve,reject)=>{const request=https.get(parsed,{headers:{'User-Agent':'AiGoodBro-package-verifier'}},response=>{if(response.statusCode!==200){response.resume();reject(new Error('registry_unavailable'));return;}const chunks=[];let n=0;response.on('data',b=>{n+=b.length;if(n>max){response.destroy(new Error('registry_response_large'));return;}chunks.push(b);});response.on('end',()=>resolve(Buffer.concat(chunks)));response.on('error',reject);});request.setTimeout(15000,()=>request.destroy(new Error('registry_timeout')));request.on('error',reject);});}
function packagePath(base,name){need(/^(@[a-z0-9._-]+\/)?[a-z0-9._-]+$/.test(name),'package_name_invalid');let parent=base;for(let i=0;i<32;i++){const p=path.join(parent,'node_modules',...name.split('/'));if(fs.existsSync(path.join(p,'package.json')))return ordinary(p);const next=path.dirname(parent);if(next===parent)break;parent=next;}throw new Error('package_dependency_missing');}
function installedFiles(root){const result=new Map();let total=0;function walk(dir,rel){for(const entry of fs.readdirSync(dir,{withFileTypes:true})){if(entry.name==='node_modules')continue;const key=rel?rel+'/'+entry.name:entry.name;safe(key);const p=path.join(dir,entry.name);ordinary(p);const s=fs.lstatSync(p);need(!s.isSymbolicLink(),'package_path_linked');if(s.isDirectory())walk(p,key);else{need(s.isFile()&&s.nlink===1&&s.size<=128*1024*1024,'package_file_invalid');total+=s.size;need(total<=512*1024*1024&&result.size<25000,'package_too_large');result.set(key,hash(read(p,128*1024*1024)));}}}walk(root,'');return result;}
async function verify(candidate,semver,fetch=fetchBytes){
  need(candidate&&candidate.schema===1&&PACKAGES[candidate.platform]&&typeof candidate.package_root==='string'&&path.isAbsolute(candidate.package_root),'dependency_candidate_invalid');
  const [name,command]=PACKAGES[candidate.platform],root=ordinary(candidate.package_root),seen=new Map(),records=[],queue=[{root,name,range:'*'}];let filesCount=0;
  for(let index=0;index<queue.length;index++){
    need(index<256,'package_closure_large');const item=queue[index];if(seen.has(item.root)){const prior=seen.get(item.root);need(prior.name===item.name&&semver.satisfies(prior.version,item.range),'package_identity_mismatch');continue;}
    const local=JSON.parse(read(path.join(item.root,'package.json')).toString());need(local.name===item.name&&semver.valid(local.version)&&semver.satisfies(local.version,item.range,{includePrerelease:false}),'package_version_mismatch');
    const meta=JSON.parse((await fetch('https://registry.npmjs.org/'+encodeURIComponent(item.name)+'/'+encodeURIComponent(local.version),4*1024*1024)).toString());
    need(meta.name===item.name&&meta.version===local.version&&meta.dist&&/^sha512-[A-Za-z0-9+/]+=*$/.test(meta.dist.integrity),'package_metadata_invalid');
    if(meta.engines?.node)need(semver.validRange(meta.engines.node)&&semver.satisfies(process.version,meta.engines.node),'package_node_version_mismatch');
    const blob=await fetch(meta.dist.tarball,96*1024*1024);need('sha512-'+crypto.createHash('sha512').update(blob).digest('base64')===meta.dist.integrity,'package_integrity_mismatch');
    const official=tarFiles(blob),actual=installedFiles(item.root),expected=new Map([...official].filter(([rel])=>!rel.split('/').includes('node_modules')).map(([rel,data])=>[rel,hash(data)]));
    need(expected.size===actual.size&&[...expected].every(([key,value])=>actual.get(key)===value),'package_files_changed');
    // Bundled dependencies are part of the original tarball too. They may not
    // be dropped from the receipt merely because npm puts them in node_modules.
    for(const [rel,bytes] of official){const digest=hash(bytes);need(hash(read(path.join(item.root,rel),128*1024*1024))===digest,'package_files_changed');actual.set(rel,digest);}
    seen.set(item.root,{name:item.name,version:meta.version});filesCount+=actual.size;need(filesCount<=40000,'package_closure_large');
    records.push({root:item.root,name:item.name,version:meta.version,integrity:meta.dist.integrity,files:Object.fromEntries(actual)});
    const dependencies={...meta.dependencies,...meta.optionalDependencies};for(const [dep,range] of Object.entries(dependencies||{})){
      let name=dep,requested=range;need(typeof range==='string','package_dependency_invalid');if(range.startsWith('npm:')){const at=range.lastIndexOf('@');need(at>4,'package_dependency_invalid');name=range.slice(4,at);requested=range.slice(at+1);}
      let child;try{child=packagePath(item.root,dep);}catch(error){if(meta.optionalDependencies&&dep in meta.optionalDependencies)continue;throw error;}
      const info=JSON.parse(read(path.join(child,'package.json')).toString());const os=info.os||[],cpu=info.cpu||[];
      if((os.length&&!os.includes('win32')&&!os.every(x=>x.startsWith('!')))||os.includes('!win32')||(cpu.length&&!cpu.includes(process.arch)&&!cpu.every(x=>x.startsWith('!')))||cpu.includes('!'+process.arch)){need(meta.optionalDependencies&&dep in meta.optionalDependencies,'package_platform_mismatch');continue;}
      need(semver.validRange(requested),'package_dependency_invalid');queue.push({root:child,name,range:requested});
    }
  }
  const main=JSON.parse(read(path.join(root,'package.json')).toString());const bin=typeof main.bin==='string'?main.bin:main.bin&&main.bin[command];need(typeof bin==='string','package_bin_invalid');safe(bin.replace(/^\.\//,''));const entry=path.join(root,bin);need(records[0].files[bin.replace(/^\.\//,'')],'package_bin_invalid');
  let product=null;
  if(candidate.platform==='work_buddy'){
    // A generic CodeBuddy package cannot claim a WorkBuddy subscription. The
    // selected WorkBuddy product must itself be in the verified official tar.
    const rel=candidate.edition==='international'?'product.workbuddy-ai.json':'product.workbuddy.json';need(records[0].files[rel],'workbuddy_product_unverified');product=path.join(root,rel);
    const config=JSON.parse(read(product).toString());need(config.authentication?.attributes?.platform==='workbuddy','workbuddy_product_unverified');
  }
  const bytes=read(entry,128*1024*1024),native=bytes[0]===77&&bytes[1]===90;
  return {schema:1,platform:candidate.platform,version:main.version,entry,entry_type:native?'native':'script',product,packages:records};
}
module.exports={safe,tarFiles,installedFiles,verify,fetchBytes,PACKAGES};
if(require.main===module){(async()=>{const file=process.argv[2],semver=require(process.argv[3]);const candidate=JSON.parse(read(file,16384).toString());const result=await verify(candidate,semver);const output=JSON.stringify(result);need(Buffer.byteLength(output)<=8*1024*1024,'verification_report_large');process.stdout.write(output);})().catch(error=>{const code=String(error.message||'verification_failed');process.stdout.write(JSON.stringify({error:/^[a-z_]{1,64}$/.test(code)?code:'verification_failed'}));process.exitCode=1;});}

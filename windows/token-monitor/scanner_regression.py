#!/usr/bin/env python3
"""Run the actual scanner only against generated, isolated synthetic homes."""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def need(value,code):
    if not value: raise ValueError(code)
def hashes(home): return {str(p.relative_to(home)):sha(p) for p in sorted(home.rglob('*')) if p.is_file()}
def environment(home,cache,tmp):
    env={key:os.environ[key] for key in ('SystemRoot','WINDIR') if key in os.environ}
    env.update(HOME=str(home),USERPROFILE=str(home),APPDATA=str(home/'AppData/Roaming'),LOCALAPPDATA=str(home/'AppData/Local'),TEMP=str(tmp),TMP=str(tmp),TMPDIR=str(tmp),PATH='',TOKSCALE_CONFIG_DIR=str(cache),TOKSCALE_PRICING_CACHE_ONLY='1',TOKSCALE_AUTOSUBMIT_SKIP_SCHEDULER='1',TZ='UTC',CI='1')
    return env

def private(value):
    if isinstance(value,dict):
        need(not any(key.lower() in {'prompt','response','content','email','auth','access_token','refresh_token','api_key','path','cwd','directory'} for key in value),'scanner_private_output')
        for item in value.values(): private(item)
    elif isinstance(value,list):
        for item in value: private(item)

def run(binary,source,output):
    need(not output.exists(),'scanner_regression_output_exists'); output.mkdir(parents=True);tmp=output/'tmp';tmp.mkdir()
    day=(datetime.now(timezone.utc)-timedelta(days=1)).strftime('%Y-%m-%d');prior=(datetime.now(timezone.utc)-timedelta(days=2)).strftime('%Y-%m-%d')
    timestamp=int(datetime.fromisoformat(day).replace(tzinfo=timezone.utc).timestamp()*1000)
    cases=[]
    def scan(name,home,client,expected,cost=None,fresh=False,graph=False):
        cache=output/('cache-'+name if fresh else 'cache-'+home.name);before=hashes(home)
        args=[str(binary.resolve()),'--home',str(home)]
        args+=['graph','--client',client,'--no-spinner'] if graph else ['--no-spinner','--json','--client',client,'--group-by','client,model']
        result=subprocess.run(args,cwd=output,env=environment(home,cache,tmp),capture_output=True,timeout=90)
        (output/(name+'.stdout.json')).write_bytes(result.stdout);(output/(name+'.stderr.txt')).write_bytes(result.stderr)
        need(result.returncode==0,'scanner_regression_process_failed');need(len(result.stdout)<=32*1024*1024,'scanner_regression_output_too_large')
        value=json.loads(result.stdout);private(value);need(before==hashes(home),'scanner_source_changed')
        if graph:
            rows=[row for day in value['contributions'] for row in day.get('clients',[])];need(all(row['client']==client for row in rows),'scanner_source_filter_failed')
            total=sum(day['totals']['tokens'] for day in value['contributions'])
        else:
            rows=value['entries'];need(all(row['client']==client for row in rows),'scanner_source_filter_failed')
            total=sum(sum(row.get(k,0) for k in ('input','output','cacheRead','cacheWrite','reasoning')) for row in rows)
            if cost is not None:need(abs(value['totalCost']-cost)<1e-9,'scanner_cost_regression')
        need(total==expected,'scanner_token_regression')
        cases.append({'case':name,'client':client,'tokens':total,'graph':graph,'sourceUnchanged':True,'outputSHA256':hashlib.sha256(result.stdout).hexdigest()})
        return value
    def qwen(home,total=0):
        path=home/'.qwen/projects/synthetic/chats/usage.jsonl';path.parent.mkdir(parents=True,exist_ok=True)
        usage={'promptTokenCount':1000,'candidatesTokenCount':300,'cachedContentTokenCount':0,'thoughtsTokenCount':120}
        if total is not None:usage['totalTokenCount']=total
        path.write_text(json.dumps({'type':'assistant','model':'synthetic-model','timestamp':day+'T00:00:00Z','sessionId':'synthetic','usageMetadata':usage})+'\n')
    def cursor(home,rows):
        path=home/'.config/tokscale/cursor-cache/usage.json';path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps({'usageEventsDisplay':rows}));return path
    def row(ts,event,tokens,cents):
        value={'timestamp':str(ts),'model':'synthetic-model','conversationId':'synthetic-session','tokenUsage':{'inputTokens':tokens,'outputTokens':0}}
        if event is not None:value['usageEventId']=event
        if cents is not None:value['chargedCents']=cents;value['tokenUsage']['totalCents']=cents
        return value
    for name,total,expected in [('qwen-zero',0,1300),('qwen-absent',None,1420)]:
        home=output/name;qwen(home,total);cursor(home,[row(timestamp,'other',99999,99)])
        for mode in ('cold','warm','fresh'):scan(name+'-'+mode,home,'qwen',expected,fresh=mode=='fresh')
    home=output/'cursor';qwen(home,None)
    rows=[row(timestamp,'a',10,1),row(timestamp,'a',20,2),row(timestamp,None,30,3),row(timestamp+1,None,7,.7)]
    file=cursor(home,rows)
    for mode in ('cold','warm','fresh'):scan('cursor-'+mode,home,'cursor',37,.037,fresh=mode=='fresh')
    rows.append(row(int(datetime.fromisoformat(prior).replace(tzinfo=timezone.utc).timestamp()*1000),None,5,.5));file.write_text(json.dumps({'usageEventsDisplay':rows}))
    graph=scan('cursor-two-day-history',home,'cursor',42,graph=True)
    need({day,prior}=={item['date'] for item in graph['contributions'] if item['totals']['tokens']},'scanner_history_dates')
    tie=output/'cursor-free';qwen(tie,None);tie_rows=[row(timestamp,'free',10,None),row(timestamp,'free',10,0)];file=cursor(tie,tie_rows)
    for reverse in (False,True):
        if reverse:file.write_text(json.dumps({'usageEventsDisplay':list(reversed(tie_rows))}))
        scan('cursor-free-'+str(reverse).lower(),tie,'cursor',10,0)
    codex=output/'codex';qwen(codex,None);path=codex/'.codex/sessions/synthetic.jsonl';path.parent.mkdir(parents=True)
    fixture=source/'crates/tokscale-core/tests/fixtures/codex_duration_timing.jsonl';path.write_bytes(fixture.read_bytes().replace(b'2040-01-01',day.encode()))
    for mode in ('cold','warm','fresh'):
        value=scan('codex-timed-'+mode,codex,'codex',160,fresh=mode=='fresh');performance=value['entries'][0]['performance']
        need(performance['timedTokens']==160 and performance['totalDurationMs']==7000 and performance['sampleCount']==3,'scanner_duration_regression')
    receipt={'schemaVersion':1,'binarySHA256':sha(binary),'syntheticOnly':True,'realAccountsRead':False,'realHistoryScanned':False,'network':'pricing cache only; no credential inputs','cases':cases}
    (output/'receipt.json').write_text(json.dumps(receipt,sort_keys=True,indent=2)+'\n');return receipt

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',type=Path,required=True);p.add_argument('--source',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();print(json.dumps(run(a.binary,a.source,a.output),sort_keys=True))
if __name__=='__main__':main()

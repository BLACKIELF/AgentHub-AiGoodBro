#!/usr/bin/env python3
"""Build the exact 1027 scanner on Windows MSVC and issue a tested receipt.

The receipt is written only after actual selected-source Cargo regressions and
real binary synthetic scans pass. It never accepts an assertion flag from a
caller and never opens a real user home. No installer or application is run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import urllib.request
from scanner_source import reconstruct, ARCHIVE_SHA, BASE_COMMIT, PATCH_SHA, INVENTORY_SHA, need, sha
from scanner_regression import run as scanner_regression

URL='https://codeload.github.com/Javis603/tokscale/tar.gz/'+BASE_COMMIT
TARGETS={'x86_64-pc-windows-msvc':'AMD64','aarch64-pc-windows-msvc':'ARM64'}
def tool_homes(environment=None,user_home=None):
    # Resolve before HOME/USERPROFILE are isolated. Rustup's proxy otherwise
    # searches the empty fixture home when the caller uses its usual defaults.
    environment=os.environ if environment is None else environment
    user_home=Path.home()if user_home is None else Path(user_home)
    result={name:str(Path(environment.get(name)or user_home/default).expanduser().resolve())for name,default in [('CARGO_HOME','.cargo'),('RUSTUP_HOME','.rustup')]}
    need(all(Path(path).is_dir()for path in result.values()),'scanner_toolchain_home_unavailable')
    return result
def archive(args):
    if args.archive is not None:return args.archive
    path=args.cache/('sha256-'+ARCHIVE_SHA)
    if not path.exists():
        need(args.download,'scanner_archive_not_in_cache');args.cache.mkdir(parents=True,exist_ok=True)
        with urllib.request.urlopen(URL,timeout=60)as response:
            need(response.geturl()==URL,'scanner_archive_redirect');data=response.read(64*1024*1024+1)
        need(len(data)<=64*1024*1024 and hashlib.sha256(data).hexdigest()==ARCHIVE_SHA,'scanner_archive_hash_mismatch')
        partial=path.with_suffix('.partial');partial.write_bytes(data);partial.replace(path)
    need(not path.is_symlink() and path.is_file() and sha(path.read_bytes())==ARCHIVE_SHA,'scanner_archive_hash_mismatch');return path

def build(args):
    need(os.name=='nt' and platform.machine().upper()==TARGETS[args.target],'native_windows_build_required')
    homes=tool_homes()
    need(not args.output.exists(),'scanner_build_output_exists');args.output.mkdir(parents=True)
    source=args.output/'source';reconstruct(archive(args),source)
    home=args.output/'isolated-home';home.mkdir();tmp=args.output/'tmp';tmp.mkdir()
    env={key:os.environ[key] for key in ('PATH','SystemRoot','WINDIR','PATHEXT','COMSPEC','CARGO_HOME','RUSTUP_HOME','RUSTUP_TOOLCHAIN','RUSTFLAGS','VCToolsInstallDir','VCINSTALLDIR','WindowsSdkDir','WindowsSDKVersion','LIB','LIBPATH','INCLUDE')if key in os.environ}
    env.update(homes)
    env.update(HOME=str(home),USERPROFILE=str(home),APPDATA=str(home/'AppData/Roaming'),LOCALAPPDATA=str(home/'AppData/Local'),TEMP=str(tmp),TMP=str(tmp),TMPDIR=str(tmp),CARGO_TARGET_DIR=str(args.target_dir or args.output/'target'),TOKSCALE_PRICING_CACHE_ONLY='1',TOKSCALE_AUTOSUBMIT_SKIP_SCHEDULER='1',TZ='UTC',CI='1',CARGO_BUILD_JOBS=str(args.jobs))
    # Shared public dependency caches/toolchains may be reused; account/model/
    # GitHub tokens and ambient provider/proxy settings are never forwarded.
    common=['--manifest-path',str(source/'Cargo.toml'),'--target',args.target,'--locked']+(['--offline']if args.offline else[])
    def cargo(label,arguments,tests=False):
        stdout=args.output/(label+'.stdout.log');stderr=args.output/(label+'.stderr.log')
        with stdout.open('wb')as out,stderr.open('wb')as err:
            process=subprocess.Popen(['cargo',*arguments],cwd=source,env=env,stdout=out,stderr=err)
            try:code=process.wait(timeout=2400)
            except subprocess.TimeoutExpired:
                process.kill()
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:raise ValueError('scanner_build_cleanup_unconfirmed')
                raise ValueError('scanner_build_timeout')
        need(code==0,'scanner_build_or_test_failed')
        result={'command':arguments,'stdoutSHA256':hashlib.sha256(stdout.read_bytes()).hexdigest(),'stderrSHA256':hashlib.sha256(stderr.read_bytes()).hexdigest()}
        if tests:
            matches=re.findall(r'test result: ok\. (\d+) passed; (\d+) failed;',stdout.read_text(errors='replace'))
            need(matches and all(int(failed)==0 for _,failed in matches) and sum(int(passed)for passed,_ in matches)>0,'scanner_test_count_missing')
            result['passed']=sum(int(passed)for passed,_ in matches)
        return result
    unit=[]
    for filter in ('codex','qwen','cursor','message_cache'):
        unit.append(cargo('unit-'+filter,['test',*common,'-p','tokscale-core',filter,'--','--test-threads=1'],True))
    cargo('release',['build',*common,'-p','tokscale-cli','--bin','tokscale','--release'])
    binary=Path(env['CARGO_TARGET_DIR'])/args.target/'release/tokscale.exe';need(binary.is_file(),'scanner_binary_missing')
    # A build script must not mutate the frozen source inputs.
    inventory=json.loads((Path(__file__).resolve().parents[2]/'Companion/TokenMonitorEngine/scanner-backports/1027v1/source-inventory.json').read_bytes())
    for name,expected in inventory.items():need(hashlib.sha256((source/name).read_bytes()).hexdigest()==expected,'scanner_source_changed_during_build')
    regression=scanner_regression(binary,source,args.output/'synthetic-regression')
    receipt={'schemaVersion':1,'baseCommit':BASE_COMMIT,'sourceArchiveSHA256':ARCHIVE_SHA,'patchSHA256':PATCH_SHA,'sourceInventorySHA256':INVENTORY_SHA,'target':args.target,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'syntheticRegressionPassed':True,'syntheticRegressionReceiptSHA256':hashlib.sha256((args.output/'synthetic-regression/receipt.json').read_bytes()).hexdigest(),'syntheticCases':len(regression['cases']),'unitTests':unit,'realAccountsRead':False,'realHistoryScanned':False}
    destination=args.output/'tokscale.exe';destination.write_bytes(binary.read_bytes())
    (args.output/'SCANNER-RECEIPT.json').write_text(json.dumps(receipt,sort_keys=True,indent=2)+'\n');print(json.dumps({'binary':str(destination),'receipt':str(args.output/'SCANNER-RECEIPT.json'),'binarySHA256':receipt['binarySHA256']},sort_keys=True))

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--cache',type=Path,required=True);p.add_argument('--archive',type=Path);p.add_argument('--target',choices=TARGETS,default='x86_64-pc-windows-msvc');p.add_argument('--target-dir',type=Path);p.add_argument('--jobs',type=int,default=2);p.add_argument('--download',action='store_true');p.add_argument('--offline',action='store_true');a=p.parse_args();need(1<=a.jobs<=8,'invalid_build_jobs');build(a)
if __name__=='__main__':main()

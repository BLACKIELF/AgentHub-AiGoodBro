#!/usr/bin/env python3
"""Stage the frozen engine for Windows; never touches the Mac resource stager.

Only fixed public assets are downloaded. No npm scripts, accounts, logs or scan
commands run. A Windows scanner receipt must bind the exact 1027 source inputs.
"""
import argparse, base64, hashlib, io, json, os, shutil, struct, tarfile, urllib.request, zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / 'Companion/TokenMonitorEngine'
CHECKSUM_SHA = '778ac5b2fcdbd68d9c0ae9f4310674faa3af0910bd0d18e7f6597787c40a3e39'
NODE = {
    'x64': {'archive': '1177b4137ba5adaa56354ae40f1080c7450e8ae09cecb47da459d1c52ac99f97', 'binary': '0d0f5e39f9f3d9587bc19f73eab3c2c9c4903fd02d6dbf9c853dd81b3d95fad4', 'machine': 0x8664},
    'arm64': {'archive': 'fec025a6da31757e3b6af84c5a1628e9d38442ca99a2161091d78f2fcfa35ef3', 'binary': '97cce5301a815d2dce07ac5bfd1e6039eae88185ec1d10ae4f8cb712f1732878', 'machine': 0xaa64},
}
PATCH = 'a5c09f55a7e70f167e4a48b793a169043fdc45c946773360b4e2739cdff5f52d'
INVENTORY = '5f9c2d938d7df0167cbe316f5bd3c9cba8991994283119f517faf029ef5e3054'
BASE = 'fa5f0c13324838d1a988fda317597f9b90da7ad0'
def need(ok, code):
    if not ok: raise ValueError(code)
def digest(data, algorithm='sha256'): return hashlib.new(algorithm, data).hexdigest()
def canonical(value): return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()
def relative(raw):
    need(isinstance(raw,str) and raw and '\\' not in raw and ':' not in raw and not raw.startswith('/'), 'unsafe_archive_path')
    need(all(part not in ('','.','..') for part in raw.split('/')), 'unsafe_archive_path')
    return PurePosixPath(raw)
def pe(data, arch):
    need(data[:2] == b'MZ' and len(data)>64, 'invalid_windows_binary')
    offset=struct.unpack_from('<I',data,60)[0]
    need(offset+6<=len(data) and data[offset:offset+4]==b'PE\0\0' and struct.unpack_from('<H',data,offset+4)[0]==NODE[arch]['machine'], 'wrong_windows_architecture')
def fetch(url, cache, expected, algorithm, download):
    target=cache/(algorithm+'-'+expected)
    if target.exists():
        need(target.is_file() and not target.is_symlink(),'unsafe_cache_entry'); data=target.read_bytes()
    else:
        need(download,'asset_not_in_verified_cache')
        need(url.startswith(('https://nodejs.org/dist/v22.23.2/','https://registry.npmjs.org/')),'unapproved_asset_url')
        request=urllib.request.Request(url,headers={'User-Agent':'AiGoodBro-fixed-resource-stager'})
        with urllib.request.urlopen(request,timeout=45) as response:
            need(response.geturl()==url,'asset_redirect_forbidden'); data=response.read(256*1024*1024+1)
        need(len(data)<=256*1024*1024,'asset_too_large')
        need(digest(data,algorithm)==expected,'asset_hash_mismatch')
        cache.mkdir(parents=True,exist_ok=True); temp=target.with_suffix('.partial'); temp.write_bytes(data); temp.replace(target)
    need(digest(data,algorithm)==expected,'asset_hash_mismatch')
    return data
def supported(entry,arch):
    for field,target in [('os','win32'),('cpu',arch)]:
        values=entry.get(field,[])
        if '!'+target in values or any(not v.startswith('!') for v in values) and target not in values and 'any' not in values:return False
    return True
def closure(lock,arch):
    packages=lock['packages']; selected={}; queue=[(name,'',False) for name in ['semver','dotenv','chokidar','undici','koffi','tokscale',f'@tokscale/cli-win32-{arch}-msvc']]
    while queue:
        name,origin,optional=queue.pop(0);directory=origin
        while True:
            key=(directory+'/' if directory else '')+'node_modules/'+name
            if key in packages:break
            need(directory,'missing_locked_dependency');directory=directory.rsplit('/node_modules/',1)[0] if '/node_modules/' in directory else ''
        entry=packages[key];relative(key)
        if not supported(entry,arch):need(optional,'wrong_dependency_architecture');continue
        if key in selected:continue
        need(not entry.get('link') and entry.get('resolved','').startswith('https://registry.npmjs.org/') and entry.get('integrity','').startswith('sha512-'),'unverified_locked_dependency')
        selected[key]=entry
        for dep in sorted(set(entry.get('dependencies',{}))|set(entry.get('optionalDependencies',{}))):queue.append((dep,key,dep in entry.get('optionalDependencies',{})))
    return selected
def extract_package(blob,destination):
    with tarfile.open(fileobj=io.BytesIO(blob),mode='r:gz') as archive:
        seen=set();total=0;members=[]
        for member in archive:
            rel=relative(member.name.rstrip('/'));need(rel.parts[0]=='package' and (member.isfile() or member.isdir()),'unsafe_package_member')
            key=str(rel).casefold();need(key not in seen,'duplicate_package_member');seen.add(key);total+=member.size;need(total<=512*1024*1024,'expanded_package_too_large');members.append(member)
        for member in members:
            rel=PurePosixPath(member.name).relative_to('package')
            if not rel.parts:continue
            target=destination.joinpath(*rel.parts)
            if member.isdir():target.mkdir(parents=True,exist_ok=True)
            else:target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(archive.extractfile(member).read())
def stage(args):
    need(not args.output.exists(),'output_already_exists')
    source=json.loads((ENGINE/'SOURCE.json').read_bytes());inventory=source['finalSource']['files']
    need(source['upstream']['commit']=='5d2db368d8313415763860d594de00e46a663418','wrong_engine_commit')
    need(source['tokscale']['localBackport']['patchSHA256']==PATCH,'wrong_scanner_patch')
    for rel,expected in inventory.items():need(digest((ENGINE/rel).read_bytes())==expected,'engine_source_drift')
    receipt=json.loads(args.scanner_receipt.read_bytes());scanner=args.scanner.read_bytes();pe(scanner,args.arch)
    need(receipt.get('baseCommit')==BASE and receipt.get('patchSHA256')==PATCH and receipt.get('sourceInventorySHA256')==INVENTORY and receipt.get('target')==('x86_64-pc-windows-msvc' if args.arch=='x64' else 'aarch64-pc-windows-msvc') and receipt.get('binarySHA256')==digest(scanner),'scanner_receipt_mismatch')
    need(receipt.get('syntheticRegressionPassed') is True,'scanner_regression_required')
    need(receipt.get('schemaVersion') == 1 and receipt.get('sourceArchiveSHA256') == '5f7fcc2872b40d61319ef88a847c9ef4bb0ef240cfd16139a4fa65de03f47503' and receipt.get('syntheticCases',0) >= 15,'scanner_regression_required')
    unit=receipt.get('unitTests',[]);need(len(unit)==4 and all(item.get('passed',0)>0 for item in unit),'scanner_unit_regression_required')
    regression_file=args.scanner_receipt.parent/'synthetic-regression/receipt.json'
    regression_bytes=regression_file.read_bytes();need(digest(regression_bytes)==receipt.get('syntheticRegressionReceiptSHA256'),'scanner_regression_receipt_mismatch')
    regression=json.loads(regression_bytes);need(regression.get('binarySHA256')==digest(scanner) and regression.get('syntheticOnly') is True and regression.get('realAccountsRead') is False and regression.get('realHistoryScanned') is False and len(regression.get('cases',[]))==receipt['syntheticCases'] and all(case.get('sourceUnchanged') is True for case in regression['cases']),'scanner_regression_receipt_mismatch')
    args.cache.mkdir(parents=True,exist_ok=True)
    checks=fetch('https://nodejs.org/dist/v22.23.2/SHASUMS256.txt',args.cache,CHECKSUM_SHA,'sha256',args.download)
    need((NODE[args.arch]['archive']+'  node-v22.23.2-win-'+args.arch+'.zip').encode() in checks,'official_node_pin_mismatch')
    nodezip=fetch(f'https://nodejs.org/dist/v22.23.2/node-v22.23.2-win-{args.arch}.zip',args.cache,NODE[args.arch]['archive'],'sha256',args.download)
    with zipfile.ZipFile(io.BytesIO(nodezip)) as archive:
        prefix=f'node-v22.23.2-win-{args.arch}/'
        node=archive.read(prefix+'node.exe');license=archive.read(prefix+'LICENSE')
    need(digest(node)==NODE[args.arch]['binary'],'node_binary_pin_mismatch');pe(node,args.arch)
    args.output.mkdir(parents=True)
    try:
        for rel,expected in inventory.items():
            p=PurePosixPath(rel)
            if p.parts[0] not in ['bridge.cjs','lib','hooks','upstream','provenance.json','client-catalog.json']:continue
            if p.parts[0]=='upstream' and len(p.parts)>1 and p.parts[1] in ['tests','scripts','.github'] and rel!='upstream/scripts/vendor/tokscale.json':continue
            target=args.output/'engine'/rel;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ENGINE/rel).read_bytes())
        (args.output/'engine/SOURCE.json').write_bytes((ENGINE/'SOURCE.json').read_bytes())
        shutil.copyfile(Path(__file__).parent/'service.cjs',args.output/'service.cjs')
        (args.output/'runtime').mkdir();(args.output/'runtime/node.exe').write_bytes(node);(args.output/'runtime/LICENSE').write_bytes(license)
        lock=json.loads((ENGINE/'upstream/package-lock.json').read_bytes())
        packages=closure(lock,args.arch)
        for rel,entry in packages.items():
            integrity=base64.b64decode(entry['integrity'][7:],validate=True);need(len(integrity)==64,'invalid_dependency_integrity')
            blob=fetch(entry['resolved'],args.cache,integrity.hex(),'sha512',args.download)
            dest=args.output/'engine/vendor'/rel;extract_package(blob,dest)
            need(json.loads((dest/'package.json').read_bytes())['version']==entry['version'],'dependency_version_mismatch')
        slot=args.output/f'engine/vendor/node_modules/@tokscale/cli-win32-{args.arch}-msvc/bin/tokscale.exe';need(slot.is_file(),'missing_scanner_slot');slot.write_bytes(scanner)
        files={str(p.relative_to(args.output)).replace('\\','/'):digest(p.read_bytes()) for p in args.output.rglob('*') if p.is_file()}
        manifest={'schemaVersion':1,'platform':'win32-'+args.arch,'nodeSHA256':NODE[args.arch]['binary'],'scannerSHA256':digest(scanner),'scannerPatchSHA256':PATCH,'engineSourceSHA256':digest((ENGINE/'SOURCE.json').read_bytes()),'files':files}
        (args.output/'WINDOWS-RESOURCES.json').write_bytes(canonical(manifest))
    except BaseException:
        shutil.rmtree(args.output)
        raise
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--cache',type=Path,required=True);parser.add_argument('--scanner',type=Path,required=True);parser.add_argument('--scanner-receipt',type=Path,required=True);parser.add_argument('--arch',choices=NODE,default='x64');parser.add_argument('--download',action='store_true');args=parser.parse_args();stage(args)
if __name__=='__main__':main()

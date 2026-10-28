#!/usr/bin/env python3
"""Run the production Go evidence collector with explicit synthetic Rust inputs."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import signal

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--build-root",type=Path,required=True)
    args=parser.parse_args()
    if not all(p.is_absolute() for p in (args.input,args.output,args.build_root)):
        raise ValueError("Cross-language fixture paths must be explicit and absolute")
    args.build_root.mkdir(parents=True,exist_ok=True)
    # The input is made by the isolated Rust fixture, never a product command.
    data=json.loads(args.input.read_bytes())
    if not isinstance(data,dict) or data.get("syntheticFixture") is not True:
        raise ValueError("Only an explicitly synthetic fixture is accepted")
    environment=dict(os.environ,AIGOODBRO_TEST_EVIDENCE_INPUT=str(args.input),AIGOODBRO_TEST_EVIDENCE_OUTPUT=str(args.output),GOPROXY="off",GOTOOLCHAIN="local")
    for name,subdir in (("GOMODCACHE","go-mod"),("GOCACHE","go-build"),("GOTMPDIR","tmp"),("TMPDIR","tmp"),("TEMP","tmp"),("TMP","tmp")):
        candidate=Path(environment[name]) if environment.get(name) else args.build_root/subdir
        if not candidate.is_absolute():raise ValueError("Fixture cache must be absolute")
        candidate.mkdir(parents=True,exist_ok=True);environment[name]=str(candidate)
    target="windows-amd64" if sys.platform=="win32" else "host"
    command=[sys.executable,str(Path(__file__).with_name("build.py")),"--build-root",str(args.build_root),"--target",target,"test","-mod=readonly","-timeout=120s","-run","^TestWindowsDesktopEvidenceCrossLanguageFixture$","."]
    options={"start_new_session":True} if os.name!="nt" else {"creationflags":subprocess.CREATE_NEW_PROCESS_GROUP}
    process=subprocess.Popen(command,env=environment,**options)
    try:
        result=process.wait(timeout=240)
    except subprocess.TimeoutExpired:
        if os.name!="nt":os.killpg(process.pid,signal.SIGKILL)
        else:
            # taskkill targets only this freshly held fixture's process tree.
            system=Path(os.environ.get("SystemRoot",r"C:\Windows"))/"System32/taskkill.exe"
            subprocess.run([str(system),"/PID",str(process.pid),"/T","/F"],timeout=15,check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        process.wait(timeout=15)
        raise ValueError("The owned cross-language fixture exceeded 240 seconds")
    if result:raise subprocess.CalledProcessError(result,command)
    if args.output.is_symlink() or not args.output.is_file():
        raise ValueError("The collector did not return a fixture proof")
    return 0
if __name__=="__main__":
    try:sys.exit(main())
    except (ValueError,OSError,subprocess.SubprocessError)as error:
        print("Desktop evidence fixture rejected: "+str(error),file=sys.stderr);sys.exit(1)

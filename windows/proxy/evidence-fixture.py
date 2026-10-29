#!/usr/bin/env python3
"""Run the production Go evidence collector with explicit synthetic Rust inputs."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import signal

class FixtureFailure(Exception):
    def __init__(self, code):
        self.code=code


def fixture_environment(build_root, input_path, output_path):
    environment=dict(os.environ,AIGOODBRO_TEST_EVIDENCE_INPUT=str(input_path),AIGOODBRO_TEST_EVIDENCE_OUTPUT=str(output_path),GOPROXY="off",GOTOOLCHAIN="local")
    caches=("GOMODCACHE","GOCACHE")
    missing=[name for name in caches if not environment.get(name)]
    if missing:
        # go env includes the tool's effective defaults and task-local GOENV.
        # A new empty cache plus GOPROXY=off cannot reuse the earlier CI build.
        try:
            result=subprocess.run(["go","env","-json",*missing],env=environment,capture_output=True,timeout=15,check=True)
            effective=json.loads(result.stdout)
            for name in missing:
                value=effective.get(name)
                if not isinstance(value,str) or not value:
                    raise ValueError("missing effective cache")
                environment[name]=value
        except (ValueError,OSError,subprocess.SubprocessError):
            raise FixtureFailure("cache_unavailable") from None
    for name in caches:
        candidate=Path(environment[name])
        if not candidate.is_absolute() or not candidate.is_dir():
            raise FixtureFailure("cache_unavailable")
    for name in ("GOTMPDIR","TMPDIR","TEMP","TMP"):
        candidate=Path(environment[name]) if environment.get(name) else build_root/"tmp"
        if not candidate.is_absolute():
            raise FixtureFailure("paths_rejected")
        candidate.mkdir(parents=True,exist_ok=True)
        environment[name]=str(candidate)
    return environment


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--build-root",type=Path,required=True)
    args=parser.parse_args()
    if not all(p.is_absolute() for p in (args.input,args.output,args.build_root)):
        raise FixtureFailure("paths_rejected")
    args.build_root.mkdir(parents=True,exist_ok=True)
    # The input is made by the isolated Rust fixture, never a product command.
    try:data=json.loads(args.input.read_bytes())
    except (ValueError,OSError):raise FixtureFailure("input_rejected") from None
    if not isinstance(data,dict) or data.get("syntheticFixture") is not True:
        raise FixtureFailure("input_rejected")
    environment=fixture_environment(args.build_root,args.input,args.output)
    target="windows-amd64" if sys.platform=="win32" else "host"
    command=[sys.executable,str(Path(__file__).with_name("build.py")),"--build-root",str(args.build_root),"--target",target,"test","-mod=readonly","-timeout=120s","-run","^TestWindowsDesktopEvidenceCrossLanguageFixture$","."]
    options={"start_new_session":True} if os.name!="nt" else {"creationflags":subprocess.CREATE_NEW_PROCESS_GROUP}
    try:process=subprocess.Popen(command,env=environment,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,**options)
    except OSError:raise FixtureFailure("launch_failed") from None
    try:
        result=process.wait(timeout=240)
    except subprocess.TimeoutExpired:
        if os.name!="nt":os.killpg(process.pid,signal.SIGKILL)
        else:
            # taskkill targets only this freshly held fixture's process tree.
            system=Path(os.environ.get("SystemRoot",r"C:\Windows"))/"System32/taskkill.exe"
            subprocess.run([str(system),"/PID",str(process.pid),"/T","/F"],timeout=15,check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        process.wait(timeout=15)
        raise FixtureFailure("timeout")
    if result:raise FixtureFailure("go_test_failed")
    if args.output.is_symlink() or not args.output.is_file():
        raise FixtureFailure("proof_missing")
    return 0
if __name__=="__main__":
    try:sys.exit(main())
    except FixtureFailure as error:
        print("AIGOODBRO_EVIDENCE_FIXTURE_ERROR="+error.code,file=sys.stderr);sys.exit(1)
    except (ValueError,OSError,subprocess.SubprocessError):
        print("AIGOODBRO_EVIDENCE_FIXTURE_ERROR=launch_failed",file=sys.stderr);sys.exit(1)

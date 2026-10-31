#!/usr/bin/env python3
"""Fixed installed entry point; delegates only to the same one-shot IPC client."""
import json
from pathlib import Path
import runpy
import sys

ALLOWED = ('reserve', 'run', 'status')

def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ALLOWED + ("--help", "-h"):
        print(json.dumps({"issueCode": "companion_method_unsupported"}, separators=(",", ":")))
        return 2
    launcher = Path(__file__).absolute().parent.parent / "bin" / "next-dispatch.py"
    entry = runpy.run_path(str(launcher), run_name="companion_fixed_client")
    return entry["main"]()

if __name__ == "__main__":
    raise SystemExit(main())

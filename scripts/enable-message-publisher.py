#!/usr/bin/env python3
"""Enable the local maintainer editor after GitHub owner verification. No token is saved."""
import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

OWNER_ID = 134734669
REPOSITORY = "BLACKIELF/AgentHub-AiGoodBro"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--enable", action="store_true", help="Save the non-secret local editor marker")
    args = parser.parse_args()
    gh = next((p for p in ("/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh") if os.access(p, os.X_OK)), None)
    if not gh:
        raise RuntimeError("GitHub CLI is unavailable")

    def api(endpoint):
        result = subprocess.run(
            [gh, "api", "--hostname", "github.com", endpoint], capture_output=True, timeout=20, check=True
        )
        return json.loads(result.stdout)

    user = api("user")
    repo = api("repos/" + REPOSITORY)
    if not (
        user.get("id") == OWNER_ID
        and user.get("login") == "BLACKIELF"
        and repo.get("owner", {}).get("id") == OWNER_ID
        and repo.get("permissions", {}).get("admin") is True
    ):
        raise RuntimeError("Only BLACKIELF may enable this editor")
    folder = Path.home() / "Library/Application Support/CodexAccountManagerNext/publisher-messages"
    target = folder / "owner-v1.json"
    marker = {"schemaVersion": 1, "githubUserID": OWNER_ID}
    if args.enable:
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = folder.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise RuntimeError("Publisher directory must be private and owned by this user")
        if target.exists() or target.is_symlink():
            info = target.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or json.loads(target.read_bytes()) != marker:
                raise RuntimeError("An unexpected publisher marker already exists; it was preserved")
        else:
            with tempfile.NamedTemporaryFile(mode="w", dir=folder, delete=False) as output:
                pending = Path(output.name)
                json.dump(marker, output)
                output.write("\n")
                output.flush()
                os.fsync(output.fileno())
            try:
                os.chmod(pending, 0o600)
                os.replace(pending, target)
            finally:
                pending.unlink(missing_ok=True)
    print(json.dumps({"ownerVerified": True, "editorEnabled": args.enable and json.loads(target.read_bytes()) == marker, "credentialsWritten": False}))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        # Do not print command output, credentials or private filesystem details.
        raise SystemExit("Publisher setup failed: " + (str(error) if isinstance(error, RuntimeError) else type(error).__name__))

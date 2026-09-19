"""Select Windows CI from the event's actual diff, without running app code."""

import json
import os
import subprocess


def windows_changed(event_name, event, cwd=None):
    if event_name == "workflow_dispatch":
        return event.get("inputs", {}).get("windows", False) in (True, "true")
    if event_name == "pull_request":
        pull = event["pull_request"]
        revisions = [pull["base"]["sha"] + "..." + pull["head"]["sha"]]
    elif event_name == "push":
        before = event["before"]
        if before and set(before) == {"0"}:
            return True  # A newly published branch has no previous remote baseline.
        revisions = [before, event["after"]]
    else:
        raise ValueError("Unsupported CI event")
    result = subprocess.run(
        ["git", "diff", "--quiet", *revisions, "--", "windows/",
         "Resources/Palettes/", "Resources/LeadershipBadges/",
         ".github/workflows/ci.yml", "scripts/ci_windows_changed.py",
         "tests/test_ci_windows_changed.py"],
        cwd=cwd,
    )
    if result.returncode not in (0, 1):
        raise RuntimeError("Cannot establish the CI diff; refusing to skip checks")
    return result.returncode == 1


if __name__ == "__main__":
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as stream:
        event = json.load(stream)
    changed = windows_changed(os.environ["GITHUB_EVENT_NAME"], event)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
        stream.write("windows=" + str(changed).lower() + "\n")

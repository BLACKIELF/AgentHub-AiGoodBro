#!/usr/bin/env python3
"""Build the Windows adapter from the reviewed shared LocalProxy sources.

Only platform glue is replaced. The upstream module and exact metadata patch
are still verified/applied by Companion/LocalProxy/go.py.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
SHARED = HERE.parents[1] / "Companion" / "LocalProxy"
PLATFORM_BOUNDARIES = {
    "bridge.go": "f327c318b03c737121c0e7c94920fad7af432f8f7e080e15baa5d2f1a114467f",
    "cooldown.go": "3e5bfb6e47c31f400fe552985f5c17cda6ee79162a78d08a3e0407d7c8f72436",
    "desktop.go": "020f3bdf7f94764fc144b29dde3c946e2eec64de4bc35da00784458743ed1ad2",
    "desktop_bridge.go": "5d183f815b95cc45be1c91887ba6a28c1f5d73400e90daadb08e0ddec5b47019",
    "desktop_gateway.go": "e94b862f1233ab7b449ca9e293c0f15698e27cd0b6cb0ce57ad4baac78a7ac6f",
}


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("Shared LocalProxy platform boundary changed; review required")
    return text.replace(old, new, 1)


def write_utf8(path, text):
    with path.open("w", encoding="utf-8", newline="\n") as output:
        output.write(text)


def stage(destination):
    destination.mkdir(parents=True, exist_ok=False)
    inputs = {}
    for path in sorted(SHARED.glob("*.go")):
        data = path.read_bytes()
        inputs[path.name] = hashlib.sha256(data).hexdigest()
        if path.name in PLATFORM_BOUNDARIES and inputs[path.name] != PLATFORM_BOUNDARIES[path.name]:
            raise ValueError("Shared LocalProxy platform input changed; review required: " + path.name)
        text = data.decode("utf-8")
        if path.name in ("desktop.go", "desktop_bridge.go"):
            text = "//go:build !windows\n\n" + text
        if path.name == "desktop.go":
            pure = text[text.index("func desktopCleanKey("):text.index("func runDesktopAdapter(")]
            write_utf8(destination / "desktop_common_windows.go",
                '//go:build windows\n\npackage main\nimport ("bufio"; "bytes"; "encoding/json"; "io"; "strconv"; "strings")\n'
                + pure)
        if path.name == "main_test.go":
            text=replace_once(text,'func TestMain(m *testing.M) {','func TestMain(m *testing.M) {\n\tif windowsDesktopBackendFixture() { os.Exit(0) }')
        if path.name == "bridge.go":
            text = replace_once(text, '(&net.Dialer{}).DialContext(ctx, "unix", b.socket)',
                                'dialControl(ctx, b.socket)')
        if path.name == "cooldown.go":
            start = text.index('\tif !filepath.IsAbs(dir)')
            end = text.index('\tf, err := root.Open(".")', start)
            text = text[:start] + '\troot, err := platformCooldownRoot(dir)\n\tif err != nil { return nil, err }\n' + text[end:]
            for imp in ('\n\t"path/filepath"', '\n\t"syscall"'):
                text = replace_once(text, imp, '')
            text = text.replace('s.root.OpenFile(', 'platformCooldownOpen(s.root, ')
            text = text.replace('|syscall.O_NOFOLLOW', '')
        if path.name == "desktop_gateway.go":
            text = replace_once(text, '\n\t"os"', '')
            text = replace_once(text, 'fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW, 0)',
                                'f, err := desktopOpenFile(path)')
            text = replace_once(text, '\n\tf := os.NewFile(uintptr(fd), path)', '')
            text = replace_once(text, '!desktopOwned(info)', '!platformDesktopOwned(f, info)')
            text = replace_once(text, '} else if name == "HOME" {',
                                '} else if name == "HOME" || (name == "USERPROFILE" && userHome == "") {')
            # The already-owned Windows backend may reconnect after a native
            # proxy restart by reloading only its private loopback connection.
            text = replace_once(text, 'request.SetURL(target)\n\t\t\trequest.Out.Header.Set("Authorization", "Bearer "+c.ClientKey)',
                                'selected := desktopRequestConnection(request.In.Context(), c)\n\t\t\tcurrentTarget, _ := url.Parse(selected.Endpoint)\n\t\t\tcurrentTarget.Path = ""\n\t\t\trequest.SetURL(currentTarget)\n\t\t\trequest.Out.Header.Set("Authorization", "Bearer "+selected.ClientKey)')
            text = replace_once(text, 'handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {',
                                'handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {\n\t\tcurrent, err := desktopCurrentConnection(c)\n\t\tif err != nil { http.Error(w, "Desktop proxy connection is unavailable.", http.StatusServiceUnavailable); return }\n\t\tr = r.WithContext(context.WithValue(r.Context(), desktopConnectionContext{}, current))')
        write_utf8(destination / path.name, text)
    for path in sorted(HERE.glob("*.go")):
        shutil.copyfile(path, destination / path.name)
    for name in ("go.mod", "go.sum", "SOURCE.json", "LICENSE.CLIProxyAPI", "LICENSE.Hazmat", "THIRD-PARTY-NOTICES.txt"):
        shutil.copyfile(SHARED / name, destination / name)
    shutil.copytree(SHARED / "upstream-patches", destination / "upstream-patches")
    write_utf8(destination / "windows-source.json", json.dumps({
        "schemaVersion": 1, "sharedInputs": inputs,
        "platformInputs": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(HERE.glob("*.go"))},
        "stagedInputs": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(destination.glob("*.go"))},
        "buildScriptSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "pinnedBuildScriptSHA256": hashlib.sha256((SHARED / "go.py").read_bytes()).hexdigest(),
    }, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", type=Path, required=True)
    parser.add_argument("--target", choices=("windows-amd64", "windows-arm64", "host"), default="windows-amd64")
    parser.add_argument("command", choices=("build", "test", "vet", "stage"))
    args, flags = parser.parse_known_args()
    if any(f.startswith(("-overlay", "-modfile")) for f in flags):
        parser.error("Source overrides are not permitted")
    root = args.build_root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ, GOWORK="off")
    environment.setdefault("CGO_ENABLED", "0")
    if args.target != "host":
        environment.update(GOOS="windows", GOARCH=args.target.split("-")[1], CGO_ENABLED="0")
    # Both stages remain beneath the explicitly selected task build root.
    with tempfile.TemporaryDirectory(prefix="windows-proxy-", dir=root) as temporary:
        temp = Path(temporary)
        source = temp / "source"
        stage(source)
        if args.command == "stage":
            target = root / "staged-source"
            if target.exists():
                raise ValueError("Staged source already exists; choose another build root")
            shutil.copytree(source, target)
            return 0
        spec = importlib.util.spec_from_file_location("pinned_proxy_build", SHARED / "go.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        adapter, manifest, _ = module.prepare_source(temp / "pinned", environment, source=source)
        out_flags = [str((Path.cwd() / f).resolve()) if i > 0 and flags[i - 1] == "-o" else f for i, f in enumerate(flags)]
        result = subprocess.run(["go", args.command, *out_flags], cwd=adapter, env=environment)
        if result.returncode == 0:
            receipt = json.loads((source / "windows-source.json").read_text(encoding="utf-8"))
            receipt.update(target=args.target, command=args.command, upstream=manifest)
            receipt["arguments"] = ["<output>" if i > 0 and out_flags[i-1] == "-o" else f for i, f in enumerate(out_flags)]
            if "-o" in out_flags:
                artifact = Path(out_flags[out_flags.index("-o")+1])
                if artifact.is_file():
                    receipt["artifact"] = {"name":artifact.name,"size":artifact.stat().st_size,"sha256":hashlib.sha256(artifact.read_bytes()).hexdigest()}
            write_utf8(root / (args.command + "-" + args.target + ".json"), json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        return result.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print("Windows LocalProxy build rejected: " + str(error), file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Package the isolated OAuth gateway with the same pinned SDK verification."""
import importlib.util
import json
from pathlib import Path

SCRIPT = Path(__file__).resolve()
spec = importlib.util.spec_from_file_location("proxy_resources", SCRIPT.with_name("prepare-local-proxy-resources.py"))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
builder.SOURCE = SCRIPT.parent.parent / "Companion/AntigravityProxy"
builder.EXECUTABLE = "aigoodbro-antigravity-proxy"
builder.RESOURCE_DIRECTORY = "AntigravityProxy"


def provider_patch_support():
    builder.check_regular(builder.SOURCE / "SOURCE.json")
    builder.check_regular(builder.SOURCE / "go.py")
    provenance = json.loads((builder.SOURCE / "SOURCE.json").read_text())
    if provenance.get("upstreamPatchManifest") != "upstream-patches/manifest.json":
        raise ValueError("Provider proxy is missing its reviewed upstream patch manifest")
    spec = importlib.util.spec_from_file_location("provider_proxy_upstream_patch", builder.SOURCE / "go.py")
    support = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(support)
    manifest = support.load_manifest(builder.SOURCE)
    for field in ("upstreamModule", "upstreamVersion", "upstreamCommit", "moduleSum", "moduleGoModSum", "license"):
        if provenance.get(field) != manifest.get(field):
            raise ValueError("Provider proxy source provenance does not match reviewed patches")
    return support, manifest


# The shared builder owns binary and license validation. Supply the provider's
# independently pinned patches without changing LocalProxy's patch policy.
builder.upstream_patch_support = provider_patch_support
_verify = builder.verify


def verify_provider(resources, arch):
    packaged = resources / builder.RESOURCE_DIRECTORY
    for name in ("SOURCE.json", "LICENSE.CLIProxyAPI", "LICENSE.Hazmat"):
        builder.check_regular(builder.SOURCE / name)
        builder.check_regular(packaged / name)
        if builder.digest(packaged / name) != builder.digest(builder.SOURCE / name):
            raise ValueError("Provider proxy packaged source or license differs from reviewed input")
    _verify(resources, arch)


builder.verify = verify_provider

if __name__ == "__main__":
    builder.main()

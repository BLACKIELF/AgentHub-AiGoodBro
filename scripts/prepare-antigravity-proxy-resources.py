#!/usr/bin/env python3
"""Package the isolated OAuth gateway with the same pinned SDK verification."""
import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).resolve()
spec = importlib.util.spec_from_file_location("proxy_resources", SCRIPT.with_name("prepare-local-proxy-resources.py"))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
builder.SOURCE = SCRIPT.parent.parent / "Companion/AntigravityProxy"
builder.EXECUTABLE = "aigoodbro-antigravity-proxy"
builder.RESOURCE_DIRECTORY = "AntigravityProxy"

if __name__ == "__main__":
    builder.main()

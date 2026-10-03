#!/usr/bin/env python3
"""Offline tests for the build-time purchase link and homepage fallback."""
from pathlib import Path
import importlib.util
import json
import plistlib
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("invite_link", Path(__file__).with_name("check-invite-purchase-link.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
checks = 0


def expect(value):
    global checks
    assert value
    checks += 1


html = b"<html><title>Codex invite points</title></html>"
expect(module.usable(200, module.PRODUCT, "text/html; charset=utf-8", html))
for status, url, kind, body in [
    (404, module.PRODUCT, "text/html", html),
    (503, module.PRODUCT, "text/html", html),
    (200, module.FALLBACK, "text/html", html),
    (200, "https://example.invalid/products/codex-invite-points", "text/html", html),
    (200, module.PRODUCT, "application/json", b"{}"),
    (200, module.PRODUCT, "text/html", b"<title>404 Not found</title>"),
    (200, module.PRODUCT, "text/html", "<h1>商品不存在</h1>".encode()),
    (200, module.PRODUCT, "text/html", b""),
]:
    expect(not module.usable(status, url, kind, body))
for url in ["http://aigoodbro.com", "https://user@aigoodbro.com", "https://aigoodbro.com:8443", "https://aigoodbro.com.example.invalid"]:
    expect(not module.permitted(url))
with patch.object(module.urllib.request, "build_opener", side_effect=TimeoutError):
    result = module.check()
    expect(result["productAvailable"] is False and result["selectedURL"] == module.FALLBACK)
with tempfile.TemporaryDirectory(prefix="invite-link-fixture-") as directory:
    folder = Path(directory)
    plist, receipt = folder / "Info.plist", folder / "receipt.json"
    plist.write_bytes(plistlib.dumps({"CFBundleIdentifier": "invalid.example.fixture", "KeepExisting": True}))
    with patch.object(module, "check", return_value=result), patch("sys.argv", ["check", "--plist", str(plist), "--receipt", str(receipt)]):
        module.main()
    saved = plistlib.loads(plist.read_bytes())
    expect(saved["KeepExisting"] is True and saved["AiGoodBroInvitePurchaseURL"] == module.FALLBACK)
    expect(json.loads(receipt.read_text())["productAvailable"] is False)
print(f"PASS: {checks} purchase-link checks; no network or installed app changes")

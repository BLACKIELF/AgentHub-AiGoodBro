#!/usr/bin/env python3
"""Offline fixtures only: no real IPC, Keychain, account or network access."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="wechat-bot-fixtures-") as directory:
    binary = pathlib.Path(directory) / "tests"
    sources = [root / "Sources/CodexUsageWidget/Services" / name for name in
               ["CodexDesktopIPC.swift", "WeChatBotEventLedger.swift", "WeChatCodexConversation.swift"]]
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", *map(str, sources),
                    str(root / "tests/WeChatBotTests.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

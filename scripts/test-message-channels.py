#!/usr/bin/env python3
"""Interpret offline message-channel Swift tests; never builds or launches the app.

Concatenates the extracted WidgetLanguage helper, the three new message-channel
sources, and tests/MessageChannelsTests.swift into one script executed with
`xcrun swift`. Only synthetic placeholder credentials are used; no Keychain
item is created and no network request leaves the machine.
"""

import os
import pathlib
import platform
import subprocess
import tempfile

TARGET_BY_ARCH = {"arm64": "arm64-apple-macos13.0", "x86_64": "x86_64-apple-macos13.0"}
FRAMEWORKS = ["-framework", "Cocoa", "-framework", "Carbon", "-framework", "Security", "-framework", "SwiftUI"]


def main():
    repo = pathlib.Path(__file__).resolve().parent.parent
    target = TARGET_BY_ARCH.get(platform.machine())
    if target is None:
        raise SystemExit(f"unsupported host architecture: {platform.machine()}")
    sdk_path = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="camnext-message-channels-") as temporary:
        work = pathlib.Path(temporary)
        env = {**os.environ, "MACOSX_DEPLOYMENT_TARGET": "13.0"}
        module_cache = str(work / "ModuleCache")
        settings = repo / "Sources/CodexUsageWidget/Services/AppSettings.swift"

        announcement = (repo / "Sources/CodexUsageWidget/Services/PublicResetAnnouncements.swift").read_text()
        announcement = announcement[announcement.index("struct PublicResetAnnouncement:"):announcement.index("struct PublicResetPage:")]
        translation = (repo / "Sources/CodexUsageWidget/Services/PublicResetTranslation.swift").read_text()
        quota_event = (repo / "Sources/CodexUsageWidget/Domain/CodexQuotaEventTracker.swift").read_text().split("/// Compares", 1)[0]
        message_options = (repo / "Sources/CodexUsageWidget/Domain/FeishuMessageOptions.swift").read_text().split("\nenum FeishuQuotaValue", 1)[0]
        if "--typecheck-only" in os.sys.argv:
            # WidgetLanguage plus its EnvironmentKey and EnvironmentValues
            # extension: everything the message-channel UI needs, without the
            # whole settings module.
            language = "enum WidgetLanguage:" + settings.read_text().split("enum WidgetLanguage:", 1)[1].split(
                "\nenum WidgetThemeMode", 1
            )[0]
            language_file = work / "widget-language-extract.swift"
            language_file.write_text(
                "import SwiftUI\nimport Foundation\n"
                + (repo / "Sources/CodexUsageWidget/Domain/TokenFormatter.swift").read_text()
                + "\n" + language)
            announcement_file = work / "public-reset-announcement-extract.swift"
            announcement_file.write_text(translation + "\n" + announcement)
            options_file = work / "message-options-extract.swift"
            options_file.write_text(quota_event + "\n" + message_options)
            source_paths = [announcement_file,
                language_file,
                options_file,
                repo / "Sources/CodexUsageWidget/Domain/MessageChannel.swift",
                repo / "Sources/CodexUsageWidget/Services/TelegramMessageChannel.swift",
                repo / "Sources/CodexUsageWidget/Services/WeChatMessageChannel.swift",
                repo / "Sources/CodexUsageWidget/Services/PersonalWeChatMessageChannel.swift",
                repo / "Sources/CodexUsageWidget/Services/CodexDesktopIPC.swift",
                repo / "Sources/CodexUsageWidget/Services/WeChatCodexConversation.swift",
                repo / "Sources/CodexUsageWidget/UI/MessageChannelsView.swift",
                repo / "Sources/CodexUsageWidget/UI/PersonalWeChatSettingsView.swift",
                repo / "Sources/CodexUsageWidget/UI/FeishuMessageOptionsView.swift",
            ]
            print(f"Typechecking {len(source_paths)} message-channel sources; no app build or launch.", flush=True)
            result = subprocess.run(
                ["xcrun", "swiftc", "-typecheck", "-parse-as-library",
                 "-target", target, "-sdk", sdk_path, "-module-cache-path", module_cache,
                 *[str(path) for path in source_paths], *FRAMEWORKS],
                cwd=repo, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            report(result, repo, temporary)
            return

        language = "enum WidgetLanguage:" + settings.read_text().split("enum WidgetLanguage:", 1)[1].split(
            "\nprivate struct WidgetLanguageEnvironmentKey", 1
        )[0]
        parts = [
            (repo / "Sources/CodexUsageWidget/Domain/TokenFormatter.swift").read_text(),
            language,
            translation,
            announcement,
            quota_event,
            message_options,
            (repo / "Sources/CodexUsageWidget/Domain/MessageChannel.swift").read_text(),
            (repo / "Sources/CodexUsageWidget/Services/TelegramMessageChannel.swift").read_text(),
            (repo / "Sources/CodexUsageWidget/Services/WeChatMessageChannel.swift").read_text(),
            (repo / "Sources/CodexUsageWidget/Services/PersonalWeChatMessageChannel.swift").read_text(),
            (repo / "tests/MessageChannelsTests.swift").read_text(),
        ]
        script = work / "message-channel-tests.swift"
        script.write_text("\n".join(parts))
        print("Interpreting offline message-channel Swift tests in a temporary directory.", flush=True)
        result = subprocess.run(
            ["xcrun", "swift", "-target", target, "-sdk", sdk_path, "-module-cache-path", module_cache,
             str(script)],
            cwd=repo, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        report(result, repo, temporary)


def report(result: subprocess.CompletedProcess, repo: pathlib.Path, temporary: str) -> None:
    output = result.stdout
    for private, label in [(str(repo), "<repo>"), (temporary, "<temporary-check-directory>"),
                           (str(pathlib.Path.home()), "<home>")]:
        output = output.replace(private, label)
    print(output, end="", flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()

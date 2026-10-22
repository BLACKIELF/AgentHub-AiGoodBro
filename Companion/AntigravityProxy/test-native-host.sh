#!/bin/bash
set -euo pipefail
SOURCE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SOURCE/../.." && pwd)
RUN=$(mktemp -d /private/tmp/aigoodbro-antigravity-host.XXXXXX)
trap 'rm -rf "$RUN"' EXIT
export GOCACHE="${GOCACHE:-$RUN/go-cache}"
go build -trimpath -buildvcs=false -o "$RUN/mock-helper" "$SOURCE/fixtures/mock-helper/main.go"
/usr/bin/codesign --force --sign - "$RUN/mock-helper"
SDK=$(xcrun --sdk macosx --show-sdk-path)
if [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]; then SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk; fi
xcrun swiftc -parse-as-library -sdk "$SDK" -module-cache-path "$RUN/swift-cache" \
  "$ROOT/Sources/CodexUsageWidget/Domain/AntigravityProxyAccount.swift" \
  "$ROOT/Sources/CodexUsageWidget/Services/AntigravityProxyKeychain.swift" \
  "$ROOT/Sources/CodexUsageWidget/Services/AntigravityProxyStore.swift" \
  "$SOURCE/fixtures/NativeHostFixture.swift" -o "$RUN/fixture"
"$RUN/fixture" "$RUN/mock-helper" "$RUN/state"

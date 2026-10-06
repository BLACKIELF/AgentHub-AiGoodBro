# Distribution

AiGoodBro supports macOS 13+ on Apple Silicon and Intel. The inherited Windows 10/11 x86_64 Tauri workspace is retained with a distinct product name, installer filename, cache directory, and application identifier so it cannot overwrite the legacy Windows App.

## Local macOS package

```bash
make release-package VERSION=9.6.80 RELEASE_ARCHITECTURES=arm64
make release-check VERSION=9.6.80 RELEASE_ARCHITECTURES=arm64
```

Artifacts:

```text
dist/AiGoodBro-9.6.80-mac-arm64.dmg
dist/AiGoodBro-9.6.80-mac-arm64.dmg.sha256
```

Default builds are ad-hoc signed. Public distribution should use a Developer ID Application certificate, notarization, and checksum verification. The update window shows the version and release notes. Clicking Download fetches the matching installer, displays progress, and checks its size and SHA-256 before the user opens it. It never quits or replaces the running App automatically.

## Release gates

```bash
make memory-risk-check
make release-package VERSION=9.6.80 RELEASE_ARCHITECTURES=arm64
make release-check VERSION=9.6.80 RELEASE_ARCHITECTURES=arm64
```

`release-package` defaults to both macOS architectures. Set `RELEASE_ARCHITECTURES=arm64` explicitly for an ARM64-only release; use the same scope for `release-check`. The package wrapper keeps the pure self-tests and resource/signature checks, including automatic-switch policy, switch safety, Feishu serialization, audit storage, profile storage, app-server pipe, quota, rendering, and update checks. `release-check` rechecks metadata, checksums, the mounted DMG and signatures; it does not rerun the application self-tests. Neither performs a real login, account switch, or Feishu send. The v9.6.80 (130), 1006v3 public release provides only macOS 13+ Apple Silicon ARM64 installers; Intel and Windows installers were not built or published for this version. Use `release-cross-platform-check` only for an explicitly approved release that actually includes the required Intel and Windows assets.

The tag-triggered GitHub workflow builds macOS artifacts but does not create a GitHub Release. Windows packaging requires the explicit manual Windows option. Tags, release creation, signing credentials, and notarization remain explicit external actions.

## Windows

On a Windows runner with Rust, Node.js, npm, and the MSVC toolchain:

```powershell
.\scripts\build-windows-release.ps1 -Version 8.24.1
```

The Windows implementation is inherited and does not yet expose the new macOS automatic-switch/Feishu control center. Do not claim cross-platform parity for those two features until they are implemented and verified on Windows.

Windows artifacts are named `CodexAccountManagerNext-8.24.1-windows-x86_64.*`.

import AppKit
import SwiftUI

/// Reuse the upstream artwork already bundled inside the signed TokenMonitorEngine.
/// The application icon and custom account avatars remain AiGoodBro-owned.
enum UpstreamProviderArtwork {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for providerID: String) -> NSImage? {
        let id = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name: String
        switch id {
        case "claude", "claudecode", "claude-code": name = "claude"
        case "codex": name = "codex"
        case "chatgpt": name = "codex"
        case "hermes", "hermesagent": name = "hermes-agent"
        case "factory": name = "droid"
        case "mimo": name = "xiaomi"
        case "zcode", "zaiteam": name = "zai"
        case "open-code": name = "opencode"
        case "lm-studio", "lm studio": name = "lmstudio"
        default: name = id
        }
        // Provider IDs never select the upstream app logo or escape the icon directory.
        guard name != "token-monitor",
            !name.hasPrefix("os-"),
            name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
        else { return nil }
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let url =
            resourceURL
            .appendingPathComponent("TokenMonitorEngine/upstream/assets/icons", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("svg")
        guard var artwork = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        if name == "gemini" {
            // CoreSVG misreads this upstream path's adjacent arc flags and
            // renders only a tiny fragment. Add separators without changing
            // its geometry or the signed upstream asset.
            artwork = artwork.replacingOccurrences(of: "0 01", with: "0 0 1 ")
                .replacingOccurrences(of: "0 00", with: "0 0 0 ")
        }
        guard let image = NSImage(data: Data(artwork.utf8)) else { return nil }
        // Upstream currentColor marks need system foreground ink in dark and light mode.
        image.isTemplate = artwork.contains("currentColor")
        cache.setObject(image, forKey: name as NSString)
        return image
    }
}

struct UpstreamProviderIcon: View {
    let image: NSImage
    let size: CGFloat
    var monochrome = false

    var body: some View {
        Image(nsImage: image)
            .renderingMode(image.isTemplate ? .template : .original)
            .resizable()
            .scaledToFit()
            .foregroundStyle(monochrome ? Color.secondary : Color.primary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct AccountAvatarEditKey: EnvironmentKey {
    static let defaultValue: ((AccountAvatarTarget) -> Void)? = nil
}

private struct AccountAvatarSettingsKey: EnvironmentKey {
    static let defaultValue: AppSettings? = nil
}

extension EnvironmentValues {
    var accountAvatarEdit: ((AccountAvatarTarget) -> Void)? {
        get { self[AccountAvatarEditKey.self] }
        set { self[AccountAvatarEditKey.self] = newValue }
    }

    var accountAvatarSettings: AppSettings? {
        get { self[AccountAvatarSettingsKey.self] }
        set { self[AccountAvatarSettingsKey.self] = newValue }
    }
}

/// Shared provider mark. Navigation uses a 20pt container with a 16–18pt glyph;
/// account avatars use the F24 slots. Source artwork is never redesigned here.
struct ProviderMark: View {
    let providerID: String
    var slot: ProviderIconSlot = .navigation
    var monochrome = false

    var body: some View {
        let container = slot.container
        let glyph = slot.glyph
        ZStack {
            if let image = UpstreamProviderArtwork.image(for: providerID) {
                UpstreamProviderIcon(image: image, size: glyph, monochrome: monochrome)
            } else if providerID == AgentNavCatalog.codexID {
                RuntimeLogoView(scope: .codex, size: glyph)
            } else if let kind = AgentNavCatalog.localKind(providerID) {
                LocalCLIIcon(kind: kind)
                    .frame(width: glyph, height: glyph)
                    .foregroundStyle(monochrome ? Color.secondary : Color.primary)
            } else {
                Image(systemName: "square.dashed")
                    .font(.system(size: max(10, glyph * 0.72), weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: container, height: container)
        .clipped()
        .accessibilityHidden(true)
    }
}

struct AccountAvatarView: View {
    let record: AccountAvatarRecord
    let providerID: String
    var slot: ProviderIconSlot = .list
    var image: NSImage? = nil
    var onEdit: (() -> Void)? = nil
    var onRestore: (() -> Void)? = nil
    @Environment(\.widgetLanguage) private var language

    var body: some View {
        Group {
            if let onEdit {
                Button(action: onEdit) { visual }
                    .buttonStyle(.plain)
                    .help(language.text("更换头像", "Change avatar"))
                    .contextMenu {
                        Button(language.text("更换头像", "Change avatar"), action: onEdit)
                        if let onRestore {
                            Button(language.text("恢复默认", "Restore default"), action: onRestore)
                        }
                    }
            } else {
                visual
            }
        }
        .accessibilityLabel(language.text("账号头像", "Account avatar"))
    }

    private var visual: some View {
        ZStack(alignment: .bottomTrailing) {
            avatarContent
                .frame(width: slot.container, height: slot.container)
                .clipShape(Circle())
            if record.mode != .platformDefault {
                ProviderMark(providerID: providerID, slot: .badge, monochrome: true)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: slot.container, height: slot.container)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var avatarContent: some View {
        switch record.mode {
        case .image:
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ProviderMark(providerID: providerID, slot: slot)
            }
        case .emoji:
            Text(record.emoji ?? "")
                .font(.system(size: slot.container * ProviderIconMetrics.emojiScale))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .platformDefault:
            ProviderMark(providerID: providerID, slot: slot)
        }
    }
}

/// Production consumer seam; the existing editor continues to use AccountAvatarView directly.
struct AccountProfileAvatarView: View {
    @ObservedObject var settings: AppSettings
    var target: AccountAvatarTarget
    var slot: ProviderIconSlot = .list
    var onEdit: ((AccountAvatarTarget) -> Void)? = nil

    var body: some View {
        AccountAvatarView(
            record: settings.accountAvatars.record(for: target.profileID),
            providerID: target.providerID,
            slot: slot,
            image: settings.avatarImage(for: target.profileID),
            onEdit: onEdit.map { action in { action(target) } },
            onRestore: { settings.setAvatar(.init(mode: .platformDefault), for: target.profileID) }
        )
    }
}

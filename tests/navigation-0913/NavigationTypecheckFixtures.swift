import SwiftUI

enum LocalCLIKind: String, CaseIterable { case alpha; var displayName: String { rawValue } }
enum WidgetLanguage { case en; func text(_ zh: String, _ en: String) -> String { en } }
struct ProviderIconSlot { static let navigation = Self(); let container: CGFloat = 20 }
struct ProviderMark: View {
    let providerID: String
    let slot: ProviderIconSlot
    var body: some View { Color.clear }
}

// Rendering dependencies for the isolated navigation management fixture.
// The full application build validates these against the production theme.
private struct NavigationVisualTokensKey: EnvironmentKey {
    static let defaultValue = NavigationVisualTokens()
}
struct NavigationVisualTokens {
    struct Paint { let color: Color = .accentColor }
    struct Selection { let fill = Paint(); let stroke = Paint() }
    struct Accent { let primary = Paint() }
    let selection = Selection()
    let accent = Accent()
}
extension EnvironmentValues {
    var visualTokens: NavigationVisualTokens {
        get { self[NavigationVisualTokensKey.self] }
        set { self[NavigationVisualTokensKey.self] = newValue }
    }
}
struct WorkspaceGlassSurface: View {
    let cornerRadius: CGFloat
    var body: some View { Color.clear }
}

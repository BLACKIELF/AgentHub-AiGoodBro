// Synthetic peripheral presentation only. The editor, policy and preference types are production code.
struct CreditBalancePresentation: Equatable {}
enum WidgetLanguage {
    case en
    func text(_ zh: String, _ en: String) -> String { en }
}
enum WorkspaceStatusForeground { static let warning = Color.orange }
struct CreditBalanceView: View {
    let presentation: CreditBalancePresentation
    let compact: Bool
    let title: String
    var body: some View { EmptyView() }
}

private enum PolicyEditorFixtureProbe {
    static var summary = ""
    static var dirty = false
    static var saveFailed = false
    static var bounds: [String: CGRect] = [:]
    static func observe(summary: String, dirty: Bool, saveFailed: Bool) -> String {
        self.summary = summary
        self.dirty = dirty
        self.saveFailed = saveFailed
        return summary
    }
}

private struct PolicyEditorFixtureBounds: View {
    let name: String
    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { PolicyEditorFixtureProbe.bounds[name] = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { PolicyEditorFixtureProbe.bounds[name] = $0 }
        }
    }
}

@MainActor
private final class PolicyEditorFixtureModel: ObservableObject {
    @Published var row = LocalProxyQueueRow(
        id: "synthetic-policy-editor", label: "Synthetic policy fixture",
        isEnabled: false, isPriority: false, isCurrent: false,
        quotaText: nil, state: "unknown", cooldownUntil: nil)
    @Published var defaultPrimary = 2000
    @Published var defaultSecondary = 1500
    var failSave = false
    var saved: [LocalProxyAccountPolicy] = []
    var preferences = LocalProxyPreferences()
    let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POLICY_EDITOR_FIXTURE_ROOT"]!)
        .appendingPathComponent("preferences.json")

    func save(_ policy: LocalProxyAccountPolicy) -> Bool {
        print("TRACE save requested limit=\(policy.fiveHourUsedLimit)")
        guard !failSave, policy.isValid else { return false }
        preferences.accountPolicies = [row.id: policy]
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(preferences).write(to: file, options: .atomic)
        } catch { return false }
        saved.append(policy)
        publishRow()
        return true
    }

    func publishRow() {
        var updated = row
        updated.policy = preferences.resolvedPolicy(for: row.id)
        updated.usesDefaultCreditFloors = preferences.policy(for: row.id).creditPrimaryFloor == nil
        row = updated
    }

    func persisted() -> LocalProxyAccountPolicy? {
        guard let data = try? Data(contentsOf: file),
              let preferences = try? JSONDecoder().decode(LocalProxyPreferences.self, from: data) else { return nil }
        return preferences.accountPolicies?[row.id]
    }
}

private struct PolicyEditorFixtureRoot: View {
    @ObservedObject var model: PolicyEditorFixtureModel
    var body: some View {
        LocalProxyAccountPolicyEditor(
            row: model.row, language: .en, enabled: true, globalCreditsEnabled: false,
            defaultPrimary: model.defaultPrimary, defaultSecondary: model.defaultSecondary,
            initiallyExpanded: true, quotaContent: Text("Synthetic quota"), resetAction: EmptyView(),
            save: { model.save($0) })
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(PolicyEditorFixtureBounds(name: "root"))
    }
}

@main
@MainActor
private enum LocalProxyPolicyEditorFixture {
    static func pump(_ duration: TimeInterval = 0.12) {
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
    }

    static func nativeViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(nativeViews)
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL \(message)"); exit(1) }
    }

    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let model = PolicyEditorFixtureModel()
        let host = NSHostingView(rootView: PolicyEditorFixtureRoot(model: model))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 980, height: 330),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        window.setContentSize(NSSize(width: 980, height: 330))
        defer { window.orderOut(nil); window.contentView = nil }
        pump(0.4)

        func fields() -> [NSTextField] {
            nativeViews(host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        }
        func dump(_ name: String) {
            print("TRACE \(name): inputs=\(fields().map { $0.stringValue }), saved=\(model.row.policy.fiveHourUsedLimit), dirty=\(PolicyEditorFixtureProbe.dirty), summary=\(PolicyEditorFixtureProbe.summary)")
        }
        func press(_ name: String) {
            guard let bounds = PolicyEditorFixtureProbe.bounds[name], let root = PolicyEditorFixtureProbe.bounds["root"] else {
                print("FAIL Native control geometry missing: \(name)"); exit(1)
            }
            let point = host.convert(NSPoint(x: bounds.midX - root.minX, y: bounds.midY - root.minY), to: nil)
            if CommandLine.arguments.contains("--diagnose") {
                print("TRACE click \(name) geometry=\(bounds), native=\(point), host=\(host.bounds), field=\(fields().first.map { $0.convert($0.bounds, to: nil) } as Any)")
            }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
            pump()
        }
        func edit(_ value: String, at index: Int = 0) {
            require(fields().indices.contains(index), "Native TextField is missing at \(index)")
            let field = fields()[index]
            field.selectText(nil)
            guard let editor = field.currentEditor() as? NSTextView else {
                print("FAIL Native field editor is unavailable"); exit(1)
            }
            editor.selectAll(nil)
            editor.insertText(value, replacementRange: editor.selectedRange())
            pump()
        }
        func resize(_ width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 330))
            pump()
            require(abs(host.bounds.width - width) < 1, "Native viewport did not resize to \(width)")
        }
        func checkSaved(_ value: Double, text: String) {
            require(model.row.policy.fiveHourUsedLimit == value, "Published policy differs from \(value)")
            require(model.persisted()?.fiveHourUsedLimit == value, "Persisted rule differs from \(value)")
            require(fields().first?.stringValue == text, "A live input reverted after saving \(value)")
            require(PolicyEditorFixtureProbe.summary.contains("5h limit \(text)%"), "Rendered summary differs from \(value)")
            require(!PolicyEditorFixtureProbe.dirty && !PolicyEditorFixtureProbe.saveFailed, "Successful save remained unsaved")
        }

        dump("initial")
        require(fields().count == 1, "Default floors should have one native input")
        for (value, text) in [(30.0, "30"), (70, "70"), (37.25, "37.25"), (0, "0"), (100, "100")] {
            edit(text)
            require(PolicyEditorFixtureProbe.dirty, "Editing \(text) did not become unsaved")
            press("save")
            dump("saved \(text)")
            checkSaved(value, text: text)
        }
        print("PASS native input, rendered summary and persisted percentages: 30, 70, 37.25, 0, 100")

        edit("55.5")
        let inputID = ObjectIdentifier(fields()[0])
        model.row.snapshotStale.toggle()
        pump()
        for width: CGFloat in [440, 320, 760, 980, 440, 980] {
            resize(width)
            require(fields().count == 1 && ObjectIdentifier(fields()[0]) == inputID,
                    "Resizing replaced or duplicated the native limit editor")
            require(fields()[0].stringValue == "55.5" && PolicyEditorFixtureProbe.dirty,
                    "Refresh or resize discarded the unsaved draft")
        }
        press("rules")
        require(fields().isEmpty, "The rules did not collapse")
        press("rules")
        require(fields().first?.stringValue == "55.5" && PolicyEditorFixtureProbe.dirty, "Collapse lost the draft")
        print("PASS refresh, collapse and 320–980px layout changes retain the unsaved draft")

        model.failSave = true
        press("save")
        require(model.persisted()?.fiveHourUsedLimit == 100 && model.row.policy.fiveHourUsedLimit == 100,
                "Rejected save changed the persisted policy")
        require(fields()[0].stringValue == "55.5" && PolicyEditorFixtureProbe.dirty && PolicyEditorFixtureProbe.saveFailed,
                "Rejected save did not retain the draft and failure state")
        model.preferences.accountPolicies?[model.row.id]?.fiveHourUsedLimit = 70
        model.publishRow()
        pump()
        require(fields()[0].stringValue == "55.5" && PolicyEditorFixtureProbe.dirty && PolicyEditorFixtureProbe.saveFailed,
                "A later saved-policy refresh replaced a rejected draft")
        resize(440)
        press("rules")
        press("rules")
        require(fields()[0].stringValue == "55.5", "Rejected draft was lost after collapse or resize")
        model.failSave = false
        press("save")
        checkSaved(55.5, text: "55.5")
        print("PASS rejected save retains draft, persisted rule and failure state until retry succeeds")

        resize(980)
        model.defaultPrimary = 2600
        model.defaultSecondary = 1600
        model.preferences.creditPrimaryFloor = 2600
        model.preferences.creditSecondaryFloor = 1600
        model.publishRow()
        pump()
        require(!PolicyEditorFixtureProbe.dirty, "Default-floor refresh falsely marked the rule unsaved")
        press("defaults")
        require(fields().count == 3, "Custom floors did not expose exactly three native inputs")
        require(fields()[1].stringValue == "2600" && fields()[2].stringValue == "1600", "New defaults did not populate clean floor inputs")
        edit("3000", at: 1)
        edit("1000", at: 2)
        press("credits")
        let ids = fields().map(ObjectIdentifier.init)
        resize(320)
        require(fields().map(ObjectIdentifier.init) == ids, "Resizing replaced custom-floor editors")
        press("save")
        let custom = model.persisted()
        require(custom?.creditPrimaryFloor == 3000 && custom?.creditSecondaryFloor == 1000 && custom?.allowsCredits == false,
                "Custom floors or credit permission did not persist")
        require(!PolicyEditorFixtureProbe.dirty, "Custom-floor save remained unsaved")
        press("defaults")
        press("save")
        require(model.persisted()?.creditPrimaryFloor == nil && model.persisted()?.creditSecondaryFloor == nil,
                "Default floors were stored as overrides")
        print("PASS credit permission, custom integer floors and inherited-floor semantics remain intact")

        resize(980)
        for text in ["", "invalid", "nan", "-1", "101"] {
            let count = model.saved.count
            edit(text)
            press("save")
            require(model.saved.count == count && fields().first?.stringValue == text && PolicyEditorFixtureProbe.dirty,
                    "Invalid limit \(text) was saved or discarded")
        }
        edit("30")
        press("save")
        checkSaved(30, text: "30")
        print("PASS invalid limits remain editable and cannot save; recovery to a valid rule succeeds")
        print("PASS native production policy editor fixture (synthetic data, no live accounts or proxy)")
    }
}

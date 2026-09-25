import Foundation
import UserNotifications

final class NextLocalNotificationService: NSObject, UNUserNotificationCenterDelegate {
    enum AuthorizationStatus: Equatable {
        case notDetermined
        case denied
        case authorized
        case provisional
        case ephemeral
        case unknown
    }

    struct AuthorizationState: Equatable {
        let status: AuthorizationStatus
        let alertsEnabled: Bool
    }

    enum ServiceError: Error, Equatable {
        case userInitiationRequired
        case authorizationNotDetermined
        case authorizationDenied
        case alertsDisabled
        case unsupportedAuthorizationStatus
        case authorizationRequestFailed
        case invalidQuotaData
        case notificationSubmissionFailed
    }

    struct SubmissionReceipt: Equatable {
        let identifier: String
    }

    static let shared = NextLocalNotificationService()

    private static let notificationIdentifierPrefix = "com.blackielf.codex-account-manager-next.low-quota."
    private static let resetIdentifierPrefix = "com.blackielf.codex-account-manager-next.reset."
    static let integrationPingPrefix = "com.blackielf.codex-account-manager-next.integration-ping."

    private let center: UNUserNotificationCenter

    private override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    /// Reads system state without requesting authorization.
    func authorizationStatus(completion: @escaping (AuthorizationState) -> Void) {
        center.getNotificationSettings { settings in
            Self.completeOnMain(Self.authorizationState(from: settings), completion: completion)
        }
    }

    /// Requests alert authorization only for an explicit user enablement action.
    func requestAlertAuthorization(
        userInitiated: Bool,
        completion: @escaping (Result<AuthorizationState, ServiceError>) -> Void
    ) {
        guard userInitiated else {
            Self.completeOnMain(.failure(.userInitiationRequired), completion: completion)
            return
        }

        center.getNotificationSettings { [center] settings in
            let state = Self.authorizationState(from: settings)
            switch Self.authorizationRequestAction(for: state, userInitiated: userInitiated) {
            case .succeed:
                Self.completeOnMain(.success(state), completion: completion)
            case .fail(let error):
                Self.completeOnMain(.failure(error), completion: completion)
            case .request:
                center.requestAuthorization(options: [.alert]) { granted, error in
                    guard error == nil else {
                        Self.completeOnMain(.failure(.authorizationRequestFailed), completion: completion)
                        return
                    }
                    guard granted else {
                        Self.completeOnMain(.failure(.authorizationDenied), completion: completion)
                        return
                    }
                    center.getNotificationSettings { updatedSettings in
                        let updatedState = Self.authorizationState(from: updatedSettings)
                        if let error = Self.submissionAuthorizationError(for: updatedState) {
                            Self.completeOnMain(.failure(error), completion: completion)
                        } else {
                            Self.completeOnMain(.success(updatedState), completion: completion)
                        }
                    }
                }
            }
        }
    }

    /// Submits a system request; success means accepted by the notification center, not delivered.
    func submitLowQuotaNotification(
        fiveHourRemainingPercent: Double?,
        sevenDayRemainingPercent: Double?,
        language: WidgetLanguage = .storedOrAutomatic(),
        completion: @escaping (Result<SubmissionReceipt, ServiceError>) -> Void
    ) {
        guard
            let payload = Self.payload(
                fiveHourRemainingPercent: fiveHourRemainingPercent,
                sevenDayRemainingPercent: sevenDayRemainingPercent,
                language: language
            )
        else {
            Self.completeOnMain(.failure(.invalidQuotaData), completion: completion)
            return
        }

        center.getNotificationSettings { [center] settings in
            let state = Self.authorizationState(from: settings)
            if let error = Self.submissionAuthorizationError(for: state) {
                Self.completeOnMain(.failure(error), completion: completion)
                return
            }

            let content = UNMutableNotificationContent()
            content.title = payload.title
            content.body = payload.body
            content.sound = nil

            let identifier = Self.notificationIdentifier(for: UUID())
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            center.add(request) { error in
                if error == nil {
                    Self.completeOnMain(.success(SubmissionReceipt(identifier: identifier)), completion: completion)
                } else {
                    Self.completeOnMain(.failure(.notificationSubmissionFailed), completion: completion)
                }
            }
        }
    }

    func submitResetAnnouncement(
        _ announcement: PublicResetAnnouncement,
        language: WidgetLanguage = .storedOrAutomatic(),
        completion: @escaping (Result<SubmissionReceipt, ServiceError>) -> Void
    ) {
        guard announcement.isValid(now: Date()) else {
            Self.completeOnMain(.failure(.invalidQuotaData), completion: completion)
            return
        }
        submitReset(
            identifier: Self.resetIdentifierPrefix + announcement.id,
            title: announcement.title(language),
            body: announcement.summary(language),
            completion: completion)
    }

    func submitOfficialReset(
        _ event: CodexQuotaEvent,
        language: WidgetLanguage = .storedOrAutomatic(),
        completion: @escaping (Result<SubmissionReceipt, ServiceError>) -> Void
    ) {
        let title: String
        let body: String
        switch event {
        case .quotaReset(let fiveHour, let sevenDay):
            title = language.text("账号额度已恢复", "Account limits restored")
            let windows = [fiveHour ? language.text("5 小时", "5-hour") : nil, sevenDay ? language.text("7 天", "7-day") : nil].compactMap { $0 }.joined(separator: "、")
            body = language.text("\(windows)额度已通过官方刷新确认，可以继续工作。", "Your \(windows) limit refresh is confirmed. You can keep working.")
        case .resetCreditsAdded(let added, let available):
            title = language.text("收到新的重置卡", "New reset credits received")
            body = language.text("新增 \(added) 次，当前可用 \(available) 次。需要时可在 Codex 中使用。", "\(added) added; \(available) available. Use them in Codex when needed.")
        }
        submitReset(identifier: Self.resetIdentifierPrefix + UUID().uuidString, title: title, body: body, completion: completion)
    }

    func submitPublisherMessage(
        _ message: PublisherMessage,
        shouldSend: @escaping @MainActor () -> Bool,
        completion: @escaping (Result<SubmissionReceipt, ServiceError>) -> Void
    ) {
        submitReset(
            identifier: Self.resetIdentifierPrefix + "publisher." + message.id,
            title: "AiGoodBro · " + message.title,
            body: String(message.body.prefix(500)),
            shouldSend: shouldSend,
            completion: completion)
    }

    /// Authorized integration ping. Copy is fixed and contains no account, path or quota numbers.
    func submitAuthorizedIntegrationPing(
        language: WidgetLanguage = .storedOrAutomatic(),
        completion: @escaping (Result<SubmissionReceipt, ServiceError>) -> Void
    ) {
        submitReset(
            identifier: Self.integrationPingPrefix + UUID().uuidString,
            title: language.text("AiGoodBro 集成回执", "AiGoodBro integration receipt"),
            body: language.text("已授权的系统通知已提交到通知中心。", "The authorized system notification was submitted to Notification Center."),
            completion: completion
        )
    }

    private func submitReset(
        identifier: String, title: String, body: String,
        shouldSend: @escaping @MainActor () -> Bool = { true },
        completion: @escaping (Result<SubmissionReceipt, ServiceError>) -> Void
    ) {
        center.getNotificationSettings { [center] settings in
            if let error = Self.submissionAuthorizationError(for: Self.authorizationState(from: settings)) {
                Self.completeOnMain(.failure(error), completion: completion)
                return
            }
            // The stable public ID also reconciles a process exit after submit
            // but before the delivery ledger was saved.
            center.getDeliveredNotifications { delivered in
                if delivered.contains(where: { $0.request.identifier == identifier }) {
                    Self.completeOnMain(.success(.init(identifier: identifier)), completion: completion)
                    return
                }
                center.getPendingNotificationRequests { pending in
                    if pending.contains(where: { $0.identifier == identifier }) {
                        Self.completeOnMain(.success(.init(identifier: identifier)), completion: completion)
                        return
                    }
                    DispatchQueue.main.async {
                        guard shouldSend() else {
                            completion(.failure(.notificationSubmissionFailed))
                            return
                        }
                        let content = UNMutableNotificationContent()
                        content.title = title
                        content.body = body
                        content.sound = nil
                        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
                            Self.completeOnMain(error == nil ? .success(.init(identifier: identifier)) : .failure(.notificationSubmissionFailed), completion: completion)
                        }
                    }
                }
            }
        }
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let options: UNNotificationPresentationOptions =
            notification.request.identifier.hasPrefix(Self.notificationIdentifierPrefix)
                || notification.request.identifier.hasPrefix(Self.resetIdentifierPrefix)
                || notification.request.identifier.hasPrefix(Self.integrationPingPrefix) ? [.banner, .list] : []
        Self.completeOnMain(options, completion: completionHandler)
    }

    static func selfTest() -> Bool {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let chinese = payload(fiveHourRemainingPercent: 4.6, sevenDayRemainingPercent: 12.4, language: .zh)
        expect(chinese?.title == "Codex Next 额度较低", "Chinese title is not fixed")
        expect(chinese?.body == "剩余额度：5 小时 5%，7 天 12%。", "percentages are not rounded or formatted correctly")

        let english = payload(fiveHourRemainingPercent: nil, sevenDayRemainingPercent: 0, language: .en)
        expect(english?.title == "Codex Next quota is low", "English title is not fixed")
        expect(english?.body == "Remaining quota: 7d 0%.", "single-window payload is incorrect")

        expect(payload(fiveHourRemainingPercent: nil, sevenDayRemainingPercent: nil, language: .en) == nil, "missing quota accepted")
        expect(payload(fiveHourRemainingPercent: .nan, sevenDayRemainingPercent: 10, language: .en) == nil, "NaN quota accepted")
        expect(payload(fiveHourRemainingPercent: .infinity, sevenDayRemainingPercent: 10, language: .en) == nil, "infinite quota accepted")
        expect(payload(fiveHourRemainingPercent: -0.1, sevenDayRemainingPercent: 10, language: .en) == nil, "negative quota accepted")
        expect(payload(fiveHourRemainingPercent: 10, sevenDayRemainingPercent: 100.1, language: .en) == nil, "quota above 100 accepted")

        let safeText = [chinese?.title, chinese?.body, english?.title, english?.body].compactMap { $0 }.joined(separator: " ")
        let allowedCharacters = CharacterSet.letters.union(.decimalDigits).union(.whitespaces).union(CharacterSet(charactersIn: "%，。：:,."))
        expect(safeText.unicodeScalars.allSatisfy(allowedCharacters.contains), "payload contains material outside the fixed copy and percentages")
        expect(!safeText.contains("\n") && !safeText.contains("@") && !safeText.contains("/"), "payload contains an unexpected extra field")

        let authorized = AuthorizationState(status: .authorized, alertsEnabled: true)
        let disabled = AuthorizationState(status: .authorized, alertsEnabled: false)
        let undetermined = AuthorizationState(status: .notDetermined, alertsEnabled: false)
        let denied = AuthorizationState(status: .denied, alertsEnabled: false)
        expect(authorizationRequestAction(for: authorized, userInitiated: true) == .succeed, "authorized request gate failed")
        expect(authorizationRequestAction(for: undetermined, userInitiated: true) == .request, "undetermined request gate failed")
        expect(authorizationRequestAction(for: denied, userInitiated: true) == .fail(.authorizationDenied), "denied request gate failed")
        expect(authorizationRequestAction(for: disabled, userInitiated: true) == .fail(.alertsDisabled), "disabled-alert request gate failed")
        expect(authorizationRequestAction(for: undetermined, userInitiated: false) == .fail(.userInitiationRequired), "background request gate failed")
        expect(submissionAuthorizationError(for: authorized) == nil, "authorized submission rejected")
        expect(submissionAuthorizationError(for: undetermined) == .authorizationNotDetermined, "undetermined submission allowed")
        expect(submissionAuthorizationError(for: denied) == .authorizationDenied, "denied submission allowed")

        let fixedIdentifier = UUID(uuidString: "00000000-0000-0000-0000-000000000001").map(notificationIdentifier(for:))
        expect(
            fixedIdentifier == "com.blackielf.codex-account-manager-next.low-quota.00000000-0000-0000-0000-000000000001",
            "notification identifier is outside the Next product namespace"
        )

        if failures.isEmpty {
            print("Next local notification self-test passed")
            return true
        }
        for failure in failures { print("Next local notification self-test failed: \(failure)") }
        return false
    }

    private enum AuthorizationRequestAction: Equatable {
        case succeed
        case request
        case fail(ServiceError)
    }

    private struct Payload: Equatable {
        let title: String
        let body: String
    }

    private static func authorizationState(from settings: UNNotificationSettings) -> AuthorizationState {
        let status: AuthorizationStatus
        switch settings.authorizationStatus {
        case .notDetermined:
            status = .notDetermined
        case .denied:
            status = .denied
        case .authorized:
            status = .authorized
        case .provisional:
            status = .provisional
        case .ephemeral:
            status = .ephemeral
        @unknown default:
            status = .unknown
        }
        return AuthorizationState(status: status, alertsEnabled: settings.alertSetting == .enabled)
    }

    private static func authorizationRequestAction(for state: AuthorizationState, userInitiated: Bool) -> AuthorizationRequestAction {
        guard userInitiated else { return .fail(.userInitiationRequired) }
        switch state.status {
        case .notDetermined:
            return .request
        case .authorized, .provisional:
            return state.alertsEnabled ? .succeed : .fail(.alertsDisabled)
        case .denied:
            return .fail(.authorizationDenied)
        case .ephemeral, .unknown:
            return .fail(.unsupportedAuthorizationStatus)
        }
    }

    private static func submissionAuthorizationError(for state: AuthorizationState) -> ServiceError? {
        switch state.status {
        case .notDetermined:
            return .authorizationNotDetermined
        case .denied:
            return .authorizationDenied
        case .authorized, .provisional:
            return state.alertsEnabled ? nil : .alertsDisabled
        case .ephemeral, .unknown:
            return .unsupportedAuthorizationStatus
        }
    }

    private static func payload(
        fiveHourRemainingPercent: Double?,
        sevenDayRemainingPercent: Double?,
        language: WidgetLanguage
    ) -> Payload? {
        guard fiveHourRemainingPercent != nil || sevenDayRemainingPercent != nil,
            isValidPercentage(fiveHourRemainingPercent),
            isValidPercentage(sevenDayRemainingPercent)
        else { return nil }

        let fiveHour = fiveHourRemainingPercent.map { Int($0.rounded()) }
        let sevenDay = sevenDayRemainingPercent.map { Int($0.rounded()) }
        let body: String
        switch (fiveHour, sevenDay) {
        case (.some(let fiveHour), .some(let sevenDay)):
            body = language.text(
                "剩余额度：5 小时 \(fiveHour)%，7 天 \(sevenDay)%。",
                "Remaining quota: 5h \(fiveHour)%, 7d \(sevenDay)%."
            )
        case (.some(let fiveHour), .none):
            body = language.text("剩余额度：5 小时 \(fiveHour)%。", "Remaining quota: 5h \(fiveHour)%.")
        case (.none, .some(let sevenDay)):
            body = language.text("剩余额度：7 天 \(sevenDay)%。", "Remaining quota: 7d \(sevenDay)%.")
        case (.none, .none):
            return nil
        }
        return Payload(
            title: language.text("Codex Next 额度较低", "Codex Next quota is low"),
            body: body
        )
    }

    private static func isValidPercentage(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && (0...100).contains(value)
    }

    private static func notificationIdentifier(for uuid: UUID) -> String {
        notificationIdentifierPrefix + uuid.uuidString
    }

    private static func completeOnMain<Value>(_ value: Value, completion: @escaping (Value) -> Void) {
        if Thread.isMainThread {
            completion(value)
        } else {
            DispatchQueue.main.async { completion(value) }
        }
    }
}

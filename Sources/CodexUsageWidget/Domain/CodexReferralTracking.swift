import Foundation

enum CodexReferralPeriod: String, CaseIterable, Identifiable {
    case thisMonth = "this_month"
    case past90Days = "past_90_days"
    var id: String { rawValue }
    func title(_ language: WidgetLanguage) -> String {
        self == .thisMonth ? language.text("本月", "This month") : language.text("过去 90 天", "Past 90 days")
    }
}

struct CodexReferralRecipients: Equatable {
    let emails: [String]
    let invalidCount: Int
    let duplicateCount: Int
    let tooLong: Bool

    static func parse(_ text: String) -> Self {
        guard text.utf8.count <= 4096 else { return Self(emails: [], invalidCount: 0, duplicateCount: 0, tooLong: true) }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;，；"))
        var seen = Set<String>()
        var emails: [String] = []
        var invalid = 0
        var duplicates = 0
        for part in text.components(separatedBy: separators).filter({ !$0.isEmpty }) {
            guard let email = CodexReferralPresentation.email(part) else {
                invalid += 1
                continue
            }
            guard seen.insert(email.lowercased()).inserted else {
                duplicates += 1
                continue
            }
            emails.append(email)
        }
        return Self(emails: emails, invalidCount: invalid, duplicateCount: duplicates, tooLong: false)
    }

    func canSend(capacity: Int) -> Bool {
        !tooLong && invalidCount == 0 && !emails.isEmpty && emails.count <= min(5, capacity)
    }
}

struct CodexReferralRecord: Identifiable, Equatable {
    enum Status: String {
        case pending, redeemed, expired, unknown
        func title(_ language: WidgetLanguage) -> String {
            switch self {
            case .pending: return language.text("待接受", "Pending")
            case .redeemed: return language.text("已接受", "Accepted")
            case .expired: return language.text("已过期", "Expired")
            case .unknown: return language.text("状态待核对", "Status unverified")
            }
        }
    }
    let id: String
    let email: String?
    let status: Status

    // The official tracker exposes acceptance, not a per-invitation credit
    // receipt. Never derive a credited amount from today's eligibility offer.
    static func parse(_ object: [String: Any]) throws -> Self {
        guard let id = object["referral_id"] as? String, !id.isEmpty, id.utf8.count <= 512 else {
            throw CodexReferralFailure.invalidResponse
        }
        let email: String?
        if let value = object["email"] as? String {
            guard let parsed = CodexReferralPresentation.email(value) else { throw CodexReferralFailure.invalidResponse }
            email = parsed
        } else {
            guard object["email"] == nil || object["email"] is NSNull else { throw CodexReferralFailure.invalidResponse }
            email = nil
        }
        return Self(id: id, email: email, status: Status(rawValue: object["status"] as? String ?? "") ?? .unknown)
    }
}

struct CodexReferralPage: Equatable {
    let items: [CodexReferralRecord]
    let cursor: String?
    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let values = object["items"] as? [[String: Any]], values.count <= 100
        else { throw CodexReferralFailure.invalidResponse }
        let items = try values.map(CodexReferralRecord.parse)
        guard Set(items.map(\.id)).count == items.count else { throw CodexReferralFailure.invalidResponse }
        let cursor: String?
        if let value = object["cursor"] as? String {
            guard value.utf8.count <= 2048, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw CodexReferralFailure.invalidResponse
            }
            cursor = value.isEmpty ? nil : value
        } else {
            guard object["cursor"] == nil || object["cursor"] is NSNull else { throw CodexReferralFailure.invalidResponse }
            cursor = nil
        }
        return Self(items: items, cursor: cursor)
    }
}

struct CodexReferralBatchResult: Equatable {
    let sent: [String]
    let failed: [String]
    let uncertain: [String]

    static func parseRejection(_ data: Data, recipients: [String]) throws -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let detail = object["detail"] as? [String: Any], detail["failed_emails"] != nil
        else { return nil }
        guard let values = detail["failed_emails"] as? [String] else { throw CodexReferralFailure.deliveryUncertain }
        guard !values.isEmpty else { return nil }
        let failed = Set(values.map { $0.lowercased() })
        guard values.count <= recipients.count, failed.count == values.count,
            failed.isSubset(of: Set(recipients.map { $0.lowercased() }))
        else { throw CodexReferralFailure.deliveryUncertain }
        // Official error details identify rejected recipients. They do not
        // acknowledge delivery for the rest of the submitted batch.
        return Self(
            sent: [], failed: recipients.filter { failed.contains($0.lowercased()) },
            uncertain: recipients.filter { !failed.contains($0.lowercased()) })
    }

    static func parse(_ data: Data, recipients: [String]) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let invites = object["invites"] as? [[String: Any]], invites.count <= recipients.count
        else { throw CodexReferralFailure.deliveryUncertain }
        let requested = Set(recipients.map { $0.lowercased() })
        var sent = Set<String>()
        for invite in invites {
            guard let id = (invite["referral_id"] as? String) ?? (invite["id"] as? String), !id.isEmpty, id.utf8.count <= 512 else {
                throw CodexReferralFailure.deliveryUncertain
            }
            // A single-address acknowledgement can omit email. A batch cannot.
            let email = (invite["email"] as? String) ?? (recipients.count == 1 ? recipients.first : nil)
            guard let email, requested.contains(email.lowercased()), sent.insert(email.lowercased()).inserted else {
                throw CodexReferralFailure.deliveryUncertain
            }
        }
        let failedValues: [String]
        if object["failed_emails"] == nil {
            failedValues = []
        } else if let values = object["failed_emails"] as? [String] {
            failedValues = values
        } else {
            throw CodexReferralFailure.deliveryUncertain
        }
        let failed = Set(failedValues.map { $0.lowercased() })
        guard failedValues.count <= recipients.count, failed.count == failedValues.count,
            failed.isSubset(of: requested), sent.isDisjoint(with: failed)
        else { throw CodexReferralFailure.deliveryUncertain }
        return Self(
            sent: recipients.filter { sent.contains($0.lowercased()) },
            failed: recipients.filter { failed.contains($0.lowercased()) },
            uncertain: recipients.filter { !sent.contains($0.lowercased()) && !failed.contains($0.lowercased()) })
    }
}

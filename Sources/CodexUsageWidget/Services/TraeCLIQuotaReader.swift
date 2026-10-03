import CommonCrypto
import CoreFoundation
import CryptoKit
import Foundation

/// TRAE SOLO CN's selected local session and official entitlement endpoint.
/// byteCrypto decoding follows the installed client's storage format; no
/// browser cookies, login changes, or inference requests are involved.
struct TraeCLIQuotaReader {
    private enum Failure: Error { case missing, unreadable, invalid, changed }
    private let transport: any LocalCLIQuotaTransport
    private let fileReader: LocalCLIQuotaReader.FileReader
    private let storageURL: URL
    private static let maximumBytes = 4 * 1_024 * 1_024

    init(
        transport: any LocalCLIQuotaTransport = LocalCLIURLSessionTransport(),
        fileReader: @escaping LocalCLIQuotaReader.FileReader = { url, limit, missing in
            try DispatchParticipationSync.readBoundedRegularFile(url, maximumBytes: limit, allowMissing: missing)
        }, storageURL: URL? = nil
    ) {
        self.transport = transport
        self.fileReader = fileReader
        self.storageURL =
            storageURL
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TRAE SOLO CN/User/globalStorage/storage.json")
    }

    func load(profile: LocalCLIProfile, now: Date = Date()) async -> LocalCLIQuotaResult {
        guard profile.kind == .trae, profile.isDefault,
            URL(fileURLWithPath: profile.configDirectory, isDirectory: true).standardizedFileURL
                == LocalCLIKind.trae.defaultConfigDirectory(home: FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL
        else { return result(.unsupported, now: now, message: "local_cli_trae_default_required") }
        do {
            let before = try session()
            var request = URLRequest(url: URL(string: "https://api.trae.cn/trae/api/v2/pay/ide_user_ent_usage")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Cloud-IDE-JWT " + before.token, forHTTPHeaderField: "Authorization")
            request.setValue("CN", forHTTPHeaderField: "X-User-Region")
            request.httpBody = Data(#"{"require_usage":true,"req_source":2}"#.utf8)
            let response = try await transport.response(for: request)
            guard response.data.count <= 1_048_576 else { throw Failure.invalid }
            if response.statusCode == 429 { return result(.rateLimited, now: now, message: "local_cli_rate_limited") }
            if response.statusCode == 401 || response.statusCode == 403 { return result(.unavailable, now: now, message: "local_cli_authorization_unverified") }
            guard response.statusCode == 200 else { throw Failure.invalid }
            let parsed = try Self.parse(response.data)
            let after = try session()
            guard after.id == before.id, after.token == before.token else { throw Failure.changed }
            let fingerprint = SHA256.hash(data: Data(("trae:" + before.id).utf8)).map { String(format: "%02x", $0) }.joined()
            return LocalCLIQuotaResult(
                state: .available, fetchedAt: now, maskedIdentity: nil,
                identityFingerprint: fingerprint, planLabel: "TRAE SOLO CN",
                windows: [
                    LocalCLIQuotaWindow(id: "credits", label: "积分", usedPercent: parsed.usedPercent, resetsAt: nil)
                ], balance: parsed.remaining, balanceCurrency: "CREDITS", sourceLabel: "TRAE official credits", messageCode: nil)
        } catch Failure.missing {
            return result(.needsLogin, now: now, message: "local_cli_needs_login")
        } catch Failure.unreadable {
            return result(.unavailable, now: now, message: "local_cli_trae_session_unreadable")
        } catch { return result(.unavailable, now: now, message: "local_cli_unavailable") }
    }

    private func session() throws -> (id: String, token: String) {
        guard let bytes = try fileReader(storageURL, Self.maximumBytes, true),
            let storage = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            let encoded = storage["iCubeAuthInfo://icube.cloudide"] as? String
        else { throw Failure.missing }
        guard let decoded = Self.decodeSession(encoded),
            let session = try JSONSerialization.jsonObject(with: decoded) as? [String: Any],
            let id = Self.header(session["userId"]), let token = Self.header(session["token"]),
            session["account"] is [String: Any]
        else { throw Failure.unreadable }
        return (id, token)
    }

    static func parse(_ data: Data) throws -> (remaining: Double, usedPercent: Double) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["code"] == nil || number(root["code"]) == 0,
            let packs = (root["user_entitlement_pack_list"] ?? root["userEntitlementPackList"]) as? [[String: Any]],
            packs.count <= 512
        else { throw Failure.invalid }
        var limit = 0.0
        var used = 0.0
        for pack in packs {
            let info = (pack["entitlement_base_info"] ?? pack["entitlementBaseInfo"]) as? [String: Any]
            guard let quota = info?["quota"] as? [String: Any] else { throw Failure.invalid }
            let usage = pack["usage"] as? [String: Any]
            let rawLimit = quota["credits_limit"] ?? quota["creditsLimit"]
            let rawUsed = usage?["credits_amount"] ?? usage?["creditsAmount"]
            if rawLimit == nil && rawUsed == nil { continue }
            guard let total = number(rawLimit), total >= 0,
                let consumed = rawUsed == nil ? 0 : number(rawUsed), consumed >= 0
            else { throw Failure.invalid }
            if total == 0 && consumed == 0 { continue }
            guard total > 0 else { throw Failure.invalid }
            limit += total
            used += consumed
        }
        guard limit.isFinite, used.isFinite, limit > 0 else { throw Failure.invalid }
        return (max(0, limit - used), min(100, used / limit * 100))
    }

    /// The public byteCrypto format prefixes a random seed, then AES-CBC of
    /// SHA-512(plaintext) + plaintext. The digest must match before JSON is read.
    static func decodeSession(_ value: String) -> Data? {
        guard let bytes = Data(base64Encoded: value), bytes.count > 38, bytes.count < maximumBytes,
            Array(bytes.prefix(6)) == [116, 99, 5, 16, 0, 0]
        else { return nil }
        let left: [UInt8] = [
            82, 9, 106, 213, 48, 54, 165, 56, 191, 64, 163, 158, 129, 243, 215, 251, 124, 227, 57, 130, 155, 47, 255, 135, 52, 142, 67, 68, 196, 222, 233, 203, 84, 123, 148, 50,
            166, 194, 35, 61, 238, 76, 149, 11, 66, 250, 195, 78, 8, 46, 161, 102, 40, 217, 36, 178, 118, 91, 162, 73, 109, 139, 209, 37,
        ]
        let right: [UInt8] = [
            31, 221, 168, 51, 136, 7, 199, 49, 177, 18, 16, 89, 39, 128, 236, 95, 96, 81, 127, 169, 25, 181, 74, 13, 45, 229, 122, 159, 147, 201, 156, 239, 160, 224, 59, 77, 174,
            42, 245, 176, 200, 235, 187, 60, 131, 83, 153, 97, 23, 43, 4, 126, 186, 119, 214, 38, 225, 105, 20, 99, 85, 33, 12, 125,
        ]
        let salted = Data(SHA512.hash(data: bytes.subdata(in: 6..<38))) + Data(zip(left, right).map { $0 ^ $1 })
        let derived = Data(SHA512.hash(data: salted))
        let key = derived.prefix(16)
        let iv = derived.subdata(in: 16..<32)
        let encrypted = bytes.dropFirst(38)
        var output = Data(count: encrypted.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { destination in
            key.withUnsafeBytes { key in
                iv.withUnsafeBytes { iv in
                    encrypted.withUnsafeBytes { source in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            key.baseAddress, 16, iv.baseAddress, source.baseAddress, source.count,
                            destination.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess, written > 64 else { return nil }
        output.count = written
        let plaintext = output.dropFirst(64)
        guard Data(SHA512.hash(data: plaintext)) == output.prefix(64) else { return nil }
        return Data(plaintext)
    }

    private static func header(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 32_768,
            !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return text
    }
    private static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            result = n.doubleValue
        } else if let s = value as? String {
            result = Double(s)
        } else {
            result = nil
        }
        return result?.isFinite == true ? result : nil
    }
    private func result(_ state: LocalCLIQuotaState, now: Date, message: String) -> LocalCLIQuotaResult {
        LocalCLIQuotaResult(
            state: state, fetchedAt: now, maskedIdentity: nil, identityFingerprint: nil,
            planLabel: nil, windows: [], balance: nil, balanceCurrency: nil, sourceLabel: "TRAE official credits", messageCode: message)
    }
}

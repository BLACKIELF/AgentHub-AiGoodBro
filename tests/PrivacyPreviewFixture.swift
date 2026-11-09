import Foundation

@main
enum PrivacyPreviewFixture {
    static func main() throws {
        var assertions = 0
        func expect(_ value: Bool, _ label: String) {
            precondition(value, label)
            assertions += 1
        }
        let secret = "synthetic-preview-value"
        let email = "synthetic@example.invalid"
        let path = "/" + "Users" + "/synthetic/Private Project/notes.txt"
        let input = "🔒 api_key=\(secret)\ncontact=\(email)\npath=\"\(path)\"\ntoken='\(secret)'"
        let output = try PrivacyPreview.preview(input)
        expect(output.replacements == 4, "mixed kinds")
        expect(!output.text.contains(secret) && !output.text.contains(email) && !output.text.contains(path), "no detected values remain")
        expect(output.text.contains("🔒 api_key={{SECRET_1}}"), "Unicode preserves offsets")
        expect(output.text.contains("token='{{SECRET_1}}'"), "repeated values have one placeholder")
        expect(output.text.contains("path=\"{{PATH_3}}\""), "quoted paths with spaces")

        let normal = "中文 notes\nmodel=default\ncount=12\n"
        expect(try PrivacyPreview.preview(normal) == .init(text: normal, replacements: 0), "ordinary text unchanged")
        expect(try PrivacyPreview.preview("") == .init(text: "", replacements: 0), "empty input")
        let collision = try PrivacyPreview.preview("{{SECRET_1}} token=synthetic-first password=synthetic-second")
        expect(collision.text == "{{SECRET_1}} token={{SECRET_2}} password={{SECRET_3}}", "placeholders cannot collide")

        let escaped = try PrivacyPreview.preview(#"{"api_key":"synthetic\"quote\\tail","model":"default"}"#)
        expect(escaped.text == #"{"api_key":"{{SECRET_1}}","model":"default"}"#, "escaped JSON strings fully masked")
        let quotedSecrets: [(String, String, Int)] = [
            ("api_key=\"synthetic-unclosed", "api_key=\"{{SECRET_1}}", 1),
            ("token='synthetic-unclosed", "token='{{SECRET_1}}", 1),
            ("password=\"synthetic with spaces", "password=\"{{SECRET_1}}", 1),
            ("{\"access_token\":\"synthetic-unclosed", "{\"access_token\":\"{{SECRET_1}}", 1),
            ("token=\"prefix \(email) suffix", "token=\"{{SECRET_1}}", 1),
            ("token='prefix \(path) suffix", "token='{{SECRET_1}}", 1),
            (#"token="synthetic\"quote remains"#, "token=\"{{SECRET_1}}", 1),
            (#"token='synthetic\'quote remains"#, "token='{{SECRET_1}}", 1),
            ("api_key=\"synthetic-tail\\", "api_key=\"{{SECRET_1}}", 1),
            ("api_key=\"synthetic-one\r\nordinary=kept", "api_key=\"{{SECRET_1}}\r\nordinary=kept", 1),
            ("token='synthetic-one\rnext=kept", "token='{{SECRET_1}}\rnext=kept", 1),
            ("token=\"synthetic-one\npassword='synthetic-two'", "token=\"{{SECRET_1}}\npassword='{{SECRET_2}}'", 2),
            ("token=\"synthetic with spaces\" next=kept", "token=\"{{SECRET_1}}\" next=kept", 1),
            (#"token='synthetic\'quote' next=kept"#, "token='{{SECRET_1}}' next=kept", 1),
            ("token='synthetic-tail\\\r\nnext=kept", "token='{{SECRET_1}}\r\nnext=kept", 1),
        ]
        for (source, expected, count) in quotedSecrets {
            expect(try PrivacyPreview.preview(source) == .init(text: expected, replacements: count), "closed and truncated quoted secret")
        }
        let overlap = try PrivacyPreview.preview("api_key=\(email)")
        expect(overlap.replacements == 1 && overlap.text == "api_key={{SECRET_1}}", "overlapping rules count once")
        let unicode = try PrivacyPreview.preview("联系 测试@示例.invalid")
        expect(unicode.text == "联系 {{EMAIL_1}}", "Unicode email")
        let bearer = try PrivacyPreview.preview("Authorization: Bearer \(secret)")
        expect(bearer.text == "Authorization: Bearer {{SECRET_1}}", "bearer value")
        let namespaced = try PrivacyPreview.preview("SYNTHETIC_PROVIDER_API_KEY=\(secret)")
        expect(namespaced.text == "SYNTHETIC_PROVIDER_API_KEY={{SECRET_1}}", "provider-prefixed environment key")
        let prefixedKey = ["s", "k", "-"].joined() + String(repeating: "synthetic", count: 4)
        expect(!(try PrivacyPreview.preview("key \(prefixedKey)")).text.contains(prefixedKey), "recognizable key without a label")
        let jwt = "eyJsynthetic.synthetic.synthetic"
        expect(!(try PrivacyPreview.preview(jwt)).text.contains(jwt), "JWT-shaped token")
        let pem = "-----BEGIN " + "PRIVATE KEY-----\nsynthetic-only\n-----END " + "PRIVATE KEY-----"
        expect(try PrivacyPreview.preview(pem) == .init(text: "{{PRIVATE_KEY_1}}", replacements: 1), "private-key block")
        let incompletePEM = "-----BEGIN " + "PRIVATE KEY-----\nsynthetic-incomplete"
        expect(try PrivacyPreview.preview(incompletePEM) == .init(text: "{{PRIVATE_KEY_1}}", replacements: 1), "truncated private-key block does not expose its tail")

        let unquotedPath = "/home/synthetic/repository/file"
        expect(try PrivacyPreview.preview("file=\(unquotedPath), next") == .init(text: "file={{PATH_1}}, next", replacements: 1), "unquoted path delimiters")
        expect(try PrivacyPreview.preview("~/private/file") == .init(text: "{{PATH_1}}", replacements: 1), "home-relative path")

        let limit = String(repeating: "a", count: PrivacyPreview.maximumInputBytes)
        expect(try PrivacyPreview.preview(limit).text == limit, "exact byte limit")
        let quotePrefix = "token=\""
        let longQuoted = quotePrefix + String(repeating: "a", count: PrivacyPreview.maximumInputBytes - quotePrefix.utf8.count)
        expect(try PrivacyPreview.preview(longQuoted) == .init(text: quotePrefix + "{{SECRET_1}}", replacements: 1), "long truncated quoted secret stays bounded")
        let longEscaped = quotePrefix + String(repeating: "\\\"", count: (PrivacyPreview.maximumInputBytes - quotePrefix.utf8.count) / 2)
        expect(try PrivacyPreview.preview(longEscaped) == .init(text: quotePrefix + "{{SECRET_1}}", replacements: 1), "long escaped truncated secret stays bounded")
        let manyUnfinishedKeys = String(repeating: "-----BEGIN " + "PRIVATE KEY-----\n", count: 1_000)
        expect(try PrivacyPreview.preview(manyUnfinishedKeys) == .init(text: "{{PRIVATE_KEY_1}}", replacements: 1), "many unfinished key headers stay bounded")
        do {
            _ = try PrivacyPreview.preview(limit + "a")
            preconditionFailure("oversized input accepted")
        } catch PrivacyPreview.Failure.tooLarge { assertions += 1 }
        do {
            _ = try PrivacyPreview.preview(String(repeating: "界", count: PrivacyPreview.maximumInputBytes / 3 + 1))
            preconditionFailure("UTF-8 byte limit ignored")
        } catch PrivacyPreview.Failure.tooLarge { assertions += 1 }
        do {
            _ = try PrivacyPreview.preview(String(repeating: "token=a ", count: 2_049))
            preconditionFailure("too many matches accepted")
        } catch PrivacyPreview.Failure.tooManyMatches { assertions += 1 }
        expect(try PrivacyPreview.preview(input) == output, "no cross-preview retained state")
        print("PASS privacy-preview \(assertions) assertions")
    }
}

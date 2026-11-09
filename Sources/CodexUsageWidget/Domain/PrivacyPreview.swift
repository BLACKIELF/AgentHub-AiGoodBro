import Foundation

/// An on-demand text preview. It does not intercept requests or retain input.
enum PrivacyPreview {
    static let maximumInputBytes = 65_536
    private static let maximumMatches = 2_048

    enum Failure: Error {
        case tooLarge, tooManyMatches, unavailable
    }

    struct Result: Equatable {
        let text: String
        let replacements: Int
    }

    private struct Rule {
        let kind: String
        let pattern: String
        var groups = [0]
    }

    private struct Match {
        let range: NSRange
        let kind: String
        let priority: Int
    }

    private static let rules: [(Rule, NSRegularExpression?)] = [
        Rule(kind: "PRIVATE_KEY", pattern: #"-----BEGIN ((?:[A-Z0-9]+ )?PRIVATE KEY)-----[\s\S]*?(?:-----END \1-----|\z)"#),
        Rule(
            kind: "SECRET",
            pattern:
                #"(?i)(?<![\w-])["']?(?:[A-Z0-9]+[_-])*(?:API[_-]?KEY|ACCESS[_-]?TOKEN|REFRESH[_-]?TOKEN|ID[_-]?TOKEN|AUTH[_-]?TOKEN|CLIENT[_-]?SECRET|PASSWORD|PASSWD|SECRET|TOKEN)["']?\s*[:=]\s*(?:"((?:\\[^\r\n]|[^"\\\r\n]|\\(?=[\r\n]|\z))++)(?:"|(?=[\r\n]|\z))|'((?:\\[^\r\n]|[^'\\\r\n]|\\(?=[\r\n]|\z))++)(?:'|(?=[\r\n]|\z))|([^\s,;'"{}]+))"#,
            groups: [1, 2, 3]),
        Rule(kind: "SECRET", pattern: #"(?i)\bBearer[ \t]+([^\s"',;<>]+)"#, groups: [1]),
        Rule(kind: "SECRET", pattern: #"(?<![A-Za-z0-9_])(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AIza[A-Za-z0-9_-]{30,})"#),
        Rule(kind: "SECRET", pattern: #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#),
        Rule(kind: "EMAIL", pattern: #"(?<![\p{L}\p{N}._%+\-])[\p{L}\p{N}._%+\-]++@[\p{L}\p{N}\-]++(?:\.[\p{L}\p{N}\-]++)+"#),
        Rule(kind: "PATH", pattern: #"(?<=")(?:/Users/|/home/|~/)[^"\r\n]+(?=")"#),
        Rule(kind: "PATH", pattern: #"(?<=')(?:/Users/|/home/|~/)[^'\r\n]+(?=')"#),
        Rule(kind: "PATH", pattern: #"(?:/Users/|/home/|~/)[^\s"'<>;,]+"#),
    ].map { ($0, try? NSRegularExpression(pattern: $0.pattern)) }

    static func preview(_ input: String) throws -> Result {
        guard input.utf8.count <= maximumInputBytes else { throw Failure.tooLarge }
        let source = input as NSString
        let entire = NSRange(location: 0, length: source.length)
        var matches: [Match] = []
        for (priority, item) in rules.enumerated() {
            let (rule, expression) = item
            guard let expression else { throw Failure.unavailable }
            var exceededLimit = false
            expression.enumerateMatches(in: input, range: entire) { match, _, stop in
                guard let match, let range = rule.groups.map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound && $0.length > 0 }) else { return }
                guard matches.count < maximumMatches else {
                    exceededLimit = true
                    stop.pointee = true
                    return
                }
                matches.append(Match(range: range, kind: rule.kind, priority: priority))
            }
            guard !exceededLimit else { throw Failure.tooManyMatches }
        }
        // A larger enclosing match wins so a key containing an email or path
        // cannot expose its unmatched suffix. Range arithmetic stays in UTF-16.
        matches.sort {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.priority < $1.priority
        }
        var selected: [Match] = []
        for match in matches {
            if let last = selected.last, match.range.location < NSMaxRange(last.range) {
                selected[selected.count - 1] = Match(
                    range: NSRange(location: last.range.location, length: max(NSMaxRange(last.range), NSMaxRange(match.range)) - last.range.location),
                    kind: last.priority <= match.priority ? last.kind : match.kind,
                    priority: min(last.priority, match.priority))
            } else {
                selected.append(match)
            }
        }
        var output = ""
        var cursor = 0
        var replacements = 0
        var placeholders: [String: String] = [:]
        var usedPlaceholders = Set<String>()
        for match in selected {
            let value = source.substring(with: match.range)
            let placeholder: String
            if let existing = placeholders[value] {
                placeholder = existing
            } else {
                var number = placeholders.count + 1
                var candidate = "{{\(match.kind)_\(number)}}"
                while input.contains(candidate) || usedPlaceholders.contains(candidate) {
                    number += 1
                    candidate = "{{\(match.kind)_\(number)}}"
                }
                placeholder = candidate
                placeholders[value] = placeholder
                usedPlaceholders.insert(placeholder)
            }
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += placeholder
            cursor = NSMaxRange(match.range)
            replacements += 1
        }
        output += source.substring(from: cursor)
        return Result(text: output, replacements: replacements)
    }
}

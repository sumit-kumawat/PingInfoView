import Foundation

struct ParseResult: Equatable, Sendable {
    var targets: [ParsedTarget]
    var warnings: [String]
}

enum HostParser {
    static func parse(_ text: String, options: ParseOptions = ParseOptions()) -> ParseResult {
        var source = text
        if source.hasPrefix("\u{feff}") {
            source.removeFirst()
        }
        source = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        let described = usesDescriptions(source, mode: options.mode)
        var warnings: [String] = []
        var targets: [ParsedTarget] = []
        var group = ""

        if described {
            for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if let name = groupName(in: line) {
                    group = name
                    continue
                }
                let pieces = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
                let token = String(pieces[0])
                let description = pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespaces) : ""
                append(token: token, description: description, group: group, options: options, targets: &targets, warnings: &warnings)
            }
        } else {
            let comma = CharacterSet(charactersIn: ",;")
            for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let flattened = line.components(separatedBy: comma).joined(separator: " ")
                for token in flattened.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    let trimmed = String(token).trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                    append(token: trimmed, description: "", group: "", options: options, targets: &targets, warnings: &warnings)
                }
            }
        }

        for index in targets.indices {
            targets[index].order = index + 1
        }
        return ParseResult(targets: targets, warnings: warnings)
    }

    static func isIPAddress(_ value: String) -> Bool {
        ipv4Value(value) != nil || isIPv6Literal(value)
    }

    static func ipv4Value(_ value: String) -> UInt32? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard part.count <= 3, let number = UInt32(part), number <= 255, part.allSatisfy(\.isNumber) else {
                return nil
            }
            result = (result << 8) | number
        }
        return result
    }

    static func isIPv6Literal(_ value: String) -> Bool {
        var host = value
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<end])
        }
        if let zone = host.firstIndex(of: "%") {
            host = String(host[..<zone])
        }
        return host.filter { $0 == ":" }.count >= 2
    }

    private static func usesDescriptions(_ text: String, mode: HostListFormat) -> Bool {
        switch mode {
        case .plain:
            return false
        case .described:
            return true
        case .automatic:
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if groupName(in: line) != nil { return true }
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if parts.count >= 2 && parts.dropFirst().contains(where: { !looksLikeHost(String($0)) }) {
                    return true
                }
            }
            return false
        }
    }

    private static func looksLikeHost(_ token: String) -> Bool {
        let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
        if cleaned.isEmpty || cleaned.hasPrefix("#") { return true }
        if ipv4Value(cleaned) != nil || isIPv6Literal(cleaned) || cleaned.hasPrefix("[") { return true }
        if cleaned.contains(".") || cleaned.contains("/") || cleaned.contains(":") { return true }
        return cleaned.lowercased() == "localhost"
    }

    private static func groupName(in line: String) -> String? {
        guard let match = line.range(of: #"^(?i)group\s*:"#, options: .regularExpression) else {
            return nil
        }
        return String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    private static func append(
        token: String,
        description: String,
        group: String,
        options: ParseOptions,
        targets: inout [ParsedTarget],
        warnings: inout [String]
    ) {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if cleaned.count > 512 {
            warnings.append("Skipped an entry longer than 512 characters.")
            return
        }
        if cleaned.contains(":") && cleaned.contains("/") && !cleaned.hasPrefix("[") {
            warnings.append("IPv6 ranges are not expanded: \(cleaned)")
            return
        }

        if let slash = cleaned.lastIndex(of: "/"), ipv4Value(String(cleaned[..<slash])) != nil {
            let prefixText = String(cleaned[cleaned.index(after: slash)...])
            guard let prefix = Int(prefixText), let ip = ipv4Value(String(cleaned[..<slash])) else {
                warnings.append("Could not understand \(cleaned).")
                return
            }
            switch expandCIDR(ip: ip, prefix: prefix, options: options) {
            case .warning(let message):
                warnings.append(message)
            case .hosts(let addresses):
                if addresses.isEmpty {
                    warnings.append("\(cleaned) produced no addresses after skipping the network or broadcast address.")
                }
                for address in addresses {
                    targets.append(ParsedTarget(host: address, port: nil, description: description, group: group, order: 0))
                }
            }
            return
        }

        if let range = expandRange(cleaned, limit: options.expansionLimit) {
            switch range {
            case .warning(let message):
                warnings.append(message)
            case .hosts(let addresses):
                for address in addresses {
                    targets.append(ParsedTarget(host: address, port: nil, description: description, group: group, order: 0))
                }
            }
            return
        }

        guard let endpoint = splitHostAndPort(cleaned) else {
            warnings.append("Could not understand \(cleaned).")
            return
        }
        if isIPv6Literal(endpoint.host) && !options.allowIPv6 {
            warnings.append("Ignored IPv6 address \(endpoint.host) because IPv6 is turned off.")
            return
        }
        targets.append(ParsedTarget(host: endpoint.host, port: endpoint.port, description: description, group: group, order: 0))
    }

    private static func splitHostAndPort(_ token: String) -> (host: String, port: UInt16?)? {
        if token.hasPrefix("[") {
            guard let end = token.firstIndex(of: "]") else { return nil }
            let host = String(token[token.index(after: token.startIndex)..<end])
            guard !host.isEmpty else { return nil }
            let rest = token[token.index(after: end)...]
            if rest.isEmpty { return (host, nil) }
            guard rest.hasPrefix(":") else { return nil }
            guard let port = UInt16(rest.dropFirst()), port > 0 else { return nil }
            return (host, port)
        }
        if isIPv6Literal(token) {
            return (token, nil)
        }
        guard let colon = token.lastIndex(of: ":") else { return (token, nil) }
        let host = String(token[..<colon])
        let portText = String(token[token.index(after: colon)...])
        guard !host.isEmpty, !host.contains(":"), let port = UInt16(portText), port > 0 else {
            return (token, nil)
        }
        return (host, port)
    }

    private enum AddressExpansion {
        case hosts([String])
        case warning(String)
    }

    private static func expandRange(_ token: String, limit: Int) -> AddressExpansion? {
        let full = #"^(\d{1,3}(?:\.\d{1,3}){3})-(\d{1,3}(?:\.\d{1,3}){3})$"#
        let short = #"^(\d{1,3}(?:\.\d{1,3}){3})-(\d{1,3})$"#
        if let match = firstCapturePair(token, pattern: full) {
            guard let start = ipv4Value(match.0), let end = ipv4Value(match.1) else {
                return .warning("Could not understand \(token).")
            }
            return expand(from: start, to: end, token: token, limit: limit)
        }
        if let match = firstCapturePair(token, pattern: short) {
            guard let start = ipv4Value(match.0), let last = UInt32(match.1), last <= 255 else {
                return .warning("Could not understand \(token).")
            }
            let prefix = start & 0xFFFF_FF00
            let end = prefix | last
            if end < start {
                return .warning("\(token) is not an ascending range.")
            }
            return expand(from: start, to: end, token: token, limit: limit)
        }
        return nil
    }

    private static func expand(from start: UInt32, to end: UInt32, token: String, limit: Int) -> AddressExpansion {
        let low = min(start, end)
        let high = max(start, end)
        let count = UInt64(high) - UInt64(low) + 1
        if count > UInt64(limit) {
            return .warning("Skipped \(token) because it expands to more than \(limit) addresses.")
        }
        var values: [String] = []
        var cursor = low
        while true {
            values.append(formatIPv4(cursor))
            if cursor == high { break }
            cursor &+= 1
        }
        return .hosts(values)
    }

    private static func expandCIDR(ip: UInt32, prefix: Int, options: ParseOptions) -> AddressExpansion {
        guard (0...32).contains(prefix) else {
            return .warning("CIDR prefix /\(prefix) is not valid.")
        }
        let hostBits = 32 - prefix
        let count: UInt64 = hostBits == 32 ? UInt64(UInt32.max) + 1 : 1 << hostBits
        let label = "\(formatIPv4(ip))/\(prefix)"
        if count > UInt64(options.expansionLimit) {
            return .warning("Skipped \(label) because it expands to more than \(options.expansionLimit) addresses.")
        }
        let mask: UInt32 = hostBits == 32 ? 0 : (UInt32.max << hostBits)
        let network = ip & mask
        var start: UInt64 = 0
        var finish = count
        if options.skipFirstInCIDR && count > 1 { start = 1 }
        if options.skipLastInCIDR && count > 1 { finish = count - 1 }
        if start >= finish { return .hosts([]) }
        var values: [String] = []
        var index = start
        while index < finish {
            values.append(formatIPv4(network &+ UInt32(index)))
            index += 1
        }
        return .hosts(values)
    }

    private static func formatIPv4(_ value: UInt32) -> String {
        "\((value >> 24) & 255).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
    }

    private static func firstCapturePair(_ text: String, pattern: String) -> (String, String)? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range), match.numberOfRanges == 3,
              let first = Range(match.range(at: 1), in: text),
              let second = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return (String(text[first]), String(text[second]))
    }
}

import CoreGraphics
import Foundation

enum ProbeStatus: String, Codable, Sendable {
    case unknown
    case up
    case down
}

enum ColumnID: String, CaseIterable, Codable, Identifiable, Sendable {
    case order
    case group
    case hostName
    case ipAddress
    case replyIP
    case description
    case pingType
    case status
    case succeeded
    case failed
    case percentFailed
    case totalSent
    case lastPingMs
    case average
    case minimum
    case maximum
    case ttl
    case lastSucceed
    case lastFailed
    case consecutiveFailed
    case maxConsecutiveFailed
    case maxConsecutiveFailedTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .order: "Order"
        case .group: "Group"
        case .hostName: "Host Name"
        case .ipAddress: "IP Address"
        case .replyIP: "Reply IP Address"
        case .description: "Description"
        case .pingType: "Ping Type"
        case .status: "Status"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .percentFailed: "% Failed"
        case .totalSent: "Total Sent"
        case .lastPingMs: "Last Ping (ms)"
        case .average: "Average (ms)"
        case .minimum: "Minimum (ms)"
        case .maximum: "Maximum (ms)"
        case .ttl: "TTL"
        case .lastSucceed: "Last Succeed On"
        case .lastFailed: "Last Failed On"
        case .consecutiveFailed: "Consecutive Failed"
        case .maxConsecutiveFailed: "Max Consecutive Failed"
        case .maxConsecutiveFailedTime: "Max Consecutive Failed Time"
        }
    }

    var xmlTag: String {
        switch self {
        case .order: "order"
        case .group: "group"
        case .hostName: "hostname"
        case .ipAddress: "ipaddress"
        case .replyIP: "replyipaddress"
        case .description: "description"
        case .pingType: "pingtype"
        case .status: "lastpingstatus"
        case .succeeded: "succeedcount"
        case .failed: "failedcount"
        case .percentFailed: "percentfailed"
        case .totalSent: "totalsentpings"
        case .lastPingMs: "lastpingtime"
        case .average: "averagepingtime"
        case .minimum: "minimumpingtime"
        case .maximum: "maximumpingtime"
        case .ttl: "lastpingttl"
        case .lastSucceed: "lastsucceedon"
        case .lastFailed: "lastfailedon"
        case .consecutiveFailed: "consecutivefailedcount"
        case .maxConsecutiveFailed: "maxconsecutivefailedcount"
        case .maxConsecutiveFailedTime: "maxconsecutivefailedtime"
        }
    }

    var commandToken: String {
        switch self {
        case .order: "%Order%"
        case .group: "%Group%"
        case .hostName: "%HostName%"
        case .ipAddress: "%IPAddress%"
        case .replyIP: "%ReplyIPAddress%"
        case .description: "%Description%"
        case .pingType: "%PingType%"
        case .status: "%LastPingStatus%"
        case .succeeded: "%SucceedCount%"
        case .failed: "%FailedCount%"
        case .percentFailed: "%PercentFailed%"
        case .totalSent: "%TotalSentPings%"
        case .lastPingMs: "%LastPingTime%"
        case .average: "%AveragePingTime%"
        case .minimum: "%MinimumPingTime%"
        case .maximum: "%MaximumPingTime%"
        case .ttl: "%LastPingTTL%"
        case .lastSucceed: "%LastSucceedOn%"
        case .lastFailed: "%LastFailedOn%"
        case .consecutiveFailed: "%ConsecutiveFailedCount%"
        case .maxConsecutiveFailed: "%MaxConsecutiveFailedCount%"
        case .maxConsecutiveFailedTime: "%MaxConsecutiveFailedTime%"
        }
    }

    var shortTitle: String {
        switch self {
        case .replyIP: "Reply IP"
        case .percentFailed: "% Fail"
        case .totalSent: "Sent"
        case .lastPingMs: "Last ms"
        case .average: "Avg ms"
        case .minimum: "Min ms"
        case .maximum: "Max ms"
        case .lastSucceed: "Last OK"
        case .lastFailed: "Last Fail"
        case .consecutiveFailed: "Fail Streak"
        case .maxConsecutiveFailed: "Max Streak"
        case .maxConsecutiveFailedTime: "Max Streak At"
        case .succeeded: "OK"
        default: title
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .order: 44
        case .group: 84
        case .hostName: 130
        case .ipAddress, .replyIP: 104
        case .description: 104
        case .pingType: 62
        case .status: 92
        case .succeeded, .failed, .totalSent, .ttl: 52
        case .percentFailed: 60
        case .lastPingMs, .average, .minimum, .maximum: 66
        case .lastSucceed, .lastFailed, .maxConsecutiveFailedTime: 128
        case .consecutiveFailed, .maxConsecutiveFailed: 76
        }
    }

    var weight: CGFloat {
        switch self {
        case .hostName, .description: 3
        case .ipAddress, .replyIP, .group: 2
        case .lastSucceed, .lastFailed, .maxConsecutiveFailedTime: 1.5
        default: 1
        }
    }

    var priority: Int {
        switch self {
        case .hostName: 0
        case .status: 1
        case .ipAddress: 2
        case .lastPingMs: 3
        case .description: 4
        case .percentFailed: 5
        case .failed: 6
        case .average: 7
        case .succeeded: 8
        case .group: 9
        case .consecutiveFailed: 10
        case .pingType: 11
        case .minimum: 12
        case .maximum: 13
        case .totalSent: 14
        case .lastFailed: 15
        case .lastSucceed: 16
        case .ttl: 17
        case .replyIP: 18
        case .maxConsecutiveFailed: 19
        case .maxConsecutiveFailedTime: 20
        case .order: 21
        }
    }

    var isNumeric: Bool {
        switch self {
        case .order, .succeeded, .failed, .percentFailed, .totalSent, .lastPingMs, .average, .minimum, .maximum, .ttl, .consecutiveFailed, .maxConsecutiveFailed:
            true
        default:
            false
        }
    }

    static let defaultVisible: [ColumnID] = [
        .hostName, .ipAddress, .description, .status,
        .succeeded, .failed, .percentFailed,
        .lastPingMs, .average, .minimum, .maximum
    ]
}

enum SortValue: Comparable {
    case number(Double)
    case text(String)
    case ip(UInt32?, String)
    case date(Date)

    static func < (lhs: SortValue, rhs: SortValue) -> Bool {
        switch (lhs, rhs) {
        case let (.number(a), .number(b)):
            return a < b
        case let (.text(a), .text(b)):
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        case let (.ip(aAddress, aText), .ip(bAddress, bText)):
            switch (aAddress, bAddress) {
            case let (a?, b?):
                return a == b ? aText < bText : a < b
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return aText < bText
            }
        case let (.date(a), .date(b)):
            return a < b
        default:
            return false
        }
    }
}

struct DisplayFormat: Equatable, Sendable {
    var highResolution: Bool
    var useGMT: Bool

    func milliseconds(_ value: Double?) -> String {
        guard let value else { return "" }
        let places = highResolution ? 3 : 0
        return String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    func percent(_ value: Double, sent: Int) -> String {
        guard sent > 0 else { return "" }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    func date(_ value: Date?) -> String {
        guard let value else { return "" }
        return DateText.shared.string(from: value, gmt: useGMT)
    }
}

final class DateText: @unchecked Sendable {
    static let shared = DateText()
    private let lock = NSLock()
    private let local: DateFormatter
    private let gmt: DateFormatter

    private init() {
        local = DateFormatter()
        gmt = DateFormatter()
        for formatter in [local, gmt] {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        }
        gmt.timeZone = TimeZone(secondsFromGMT: 0)
        local.timeZone = .current
    }

    func string(from date: Date, gmt: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        return (gmt ? self.gmt : local).string(from: date)
    }
}

struct ParsedTarget: Equatable, Sendable {
    var host: String
    var port: UInt16?
    var description: String
    var group: String
    var order: Int

    var endpointLabel: String {
        if let port {
            return "\(host):\(port)"
        }
        return host
    }
}

struct HistoryEntry: Identifiable, Equatable, Sendable {
    var id: UUID
    var sentAt: Date
    var endedAt: Date?
    var success: Bool
    var latencyMs: Double?
    var ttl: Int?
    var replyAddress: String?
    var error: String?
    var count: Int

    func sentText(format: DisplayFormat) -> String {
        let start = format.date(sentAt)
        guard count > 1, let endedAt else { return start }
        return "\(start) – \(format.date(endedAt))"
    }
}

struct IngestEffect: Equatable, Sendable {
    var beepFailure = false
    var beepRecovery = false
    var runFailureCommand = false
    var runRecoveryCommand = false

    var hasAlert: Bool {
        beepFailure || beepRecovery || runFailureCommand || runRecoveryCommand
    }
}

struct HostRecord: Identifiable, Equatable, Sendable {
    var id: UUID
    var target: ParsedTarget
    var enabled: Bool
    var sent: Int
    var succeeded: Int
    var failed: Int
    var currentStreak: Int
    var lastStreak: Int
    var maxConsecutiveFailed: Int
    var maxConsecutiveFailedAt: Date?
    var lastStatus: ProbeStatus
    var lastLatencyMs: Double?
    var minLatencyMs: Double?
    var maxLatencyMs: Double?
    var latencyTotalMs: Double
    var lastTTL: Int?
    var replyAddress: String?
    var resolvedAddress: String?
    var reverseName: String?
    var didReverseLookup: Bool
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var lastError: String?
    var history: [HistoryEntry]

    init(target: ParsedTarget) {
        id = UUID()
        self.target = target
        enabled = true
        sent = 0
        succeeded = 0
        failed = 0
        currentStreak = 0
        lastStreak = 0
        maxConsecutiveFailed = 0
        maxConsecutiveFailedAt = nil
        lastStatus = .unknown
        lastLatencyMs = nil
        minLatencyMs = nil
        maxLatencyMs = nil
        latencyTotalMs = 0
        lastTTL = nil
        replyAddress = nil
        resolvedAddress = nil
        reverseName = nil
        didReverseLookup = false
        lastSuccessAt = nil
        lastFailureAt = nil
        lastError = nil
        history = []
    }

    var averageMs: Double? {
        guard succeeded > 0 else { return nil }
        return latencyTotalMs / Double(succeeded)
    }

    var percentFailed: Double {
        guard sent > 0 else { return 0 }
        return (Double(failed) / Double(sent)) * 100
    }

    var consecutiveFailed: Int {
        currentStreak > 0 ? currentStreak : lastStreak
    }

    var hostNameText: String {
        if HostParser.isIPAddress(target.host) {
            if let reverseName, !reverseName.isEmpty { return reverseName }
            return target.host
        }
        return target.host
    }

    var ipText: String {
        if let resolvedAddress, !resolvedAddress.isEmpty { return resolvedAddress }
        if HostParser.isIPAddress(target.host) { return target.host }
        return ""
    }

    var statusText: String {
        if !enabled { return "Disabled" }
        switch lastStatus {
        case .unknown: return "Waiting"
        case .up: return "Succeeded"
        case .down: return "Failed"
        }
    }

    var pingTypeText: String {
        if let port = target.port { return "TCP \(port)" }
        return "ICMP"
    }

    func text(for column: ColumnID, format: DisplayFormat) -> String {
        switch column {
        case .order: "\(target.order)"
        case .group: target.group
        case .hostName: hostNameText
        case .ipAddress: ipText
        case .replyIP: replyAddress ?? ""
        case .description: target.description
        case .pingType: pingTypeText
        case .status: statusText
        case .succeeded: "\(succeeded)"
        case .failed: "\(failed)"
        case .percentFailed: format.percent(percentFailed, sent: sent)
        case .totalSent: "\(sent)"
        case .lastPingMs: format.milliseconds(lastLatencyMs)
        case .average: format.milliseconds(averageMs)
        case .minimum: format.milliseconds(minLatencyMs)
        case .maximum: format.milliseconds(maxLatencyMs)
        case .ttl: lastTTL.map(String.init) ?? ""
        case .lastSucceed: format.date(lastSuccessAt)
        case .lastFailed: format.date(lastFailureAt)
        case .consecutiveFailed: sent == 0 ? "" : "\(consecutiveFailed)"
        case .maxConsecutiveFailed: maxConsecutiveFailed == 0 ? "" : "\(maxConsecutiveFailed)"
        case .maxConsecutiveFailedTime: format.date(maxConsecutiveFailedAt)
        }
    }

    func sortValue(for column: ColumnID) -> SortValue {
        switch column {
        case .order:
            return .number(Double(target.order))
        case .group:
            return .text(target.group)
        case .hostName:
            return .text(hostNameText)
        case .ipAddress:
            return .ip(HostParser.ipv4Value(ipText), ipText.lowercased())
        case .replyIP:
            return .ip(HostParser.ipv4Value(replyAddress ?? ""), (replyAddress ?? "").lowercased())
        case .description:
            return .text(target.description)
        case .pingType:
            return .text(pingTypeText)
        case .status:
            let rank: Double
            if !enabled {
                rank = 3
            } else {
                switch lastStatus {
                case .down: rank = 0
                case .unknown: rank = 1
                case .up: rank = 2
                }
            }
            return .number(rank)
        case .succeeded:
            return .number(Double(succeeded))
        case .failed:
            return .number(Double(failed))
        case .percentFailed:
            return .number(sent == 0 ? -1 : percentFailed)
        case .totalSent:
            return .number(Double(sent))
        case .lastPingMs:
            return .number(lastLatencyMs ?? -1)
        case .average:
            return .number(averageMs ?? -1)
        case .minimum:
            return .number(minLatencyMs ?? -1)
        case .maximum:
            return .number(maxLatencyMs ?? -1)
        case .ttl:
            return .number(Double(lastTTL ?? -1))
        case .lastSucceed:
            return .date(lastSuccessAt ?? .distantPast)
        case .lastFailed:
            return .date(lastFailureAt ?? .distantPast)
        case .consecutiveFailed:
            return .number(Double(consecutiveFailed))
        case .maxConsecutiveFailed:
            return .number(Double(maxConsecutiveFailed))
        case .maxConsecutiveFailedTime:
            return .date(maxConsecutiveFailedAt ?? .distantPast)
        }
    }

    mutating func clearStats() {
        sent = 0
        succeeded = 0
        failed = 0
        currentStreak = 0
        lastStreak = 0
        maxConsecutiveFailed = 0
        maxConsecutiveFailedAt = nil
        lastStatus = .unknown
        lastLatencyMs = nil
        minLatencyMs = nil
        maxLatencyMs = nil
        latencyTotalMs = 0
        lastTTL = nil
        replyAddress = nil
        lastSuccessAt = nil
        lastFailureAt = nil
        lastError = nil
        history = []
    }

    @discardableResult
    mutating func ingest(_ sample: PingSample, settings: AppSettings) -> IngestEffect {
        if sample.skipped { return IngestEffect() }

        if let address = sample.address, !address.isEmpty {
            resolvedAddress = address
        }
        sent += 1
        var effect = IngestEffect()
        let threshold = max(1, settings.alertAfterConsecutive)
        let failureCommand = settings.failureCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let successCommand = settings.successCommand.trimmingCharacters(in: .whitespacesAndNewlines)

        if sample.success {
            succeeded += 1
            lastStatus = .up
            lastSuccessAt = sample.sentAt
            lastError = nil
            if let latency = sample.latencyMs {
                lastLatencyMs = latency
                latencyTotalMs += latency
                minLatencyMs = min(minLatencyMs ?? latency, latency)
                maxLatencyMs = max(maxLatencyMs ?? latency, latency)
            }
            lastTTL = sample.ttl ?? lastTTL
            if let reply = sample.replyAddress, !reply.isEmpty {
                replyAddress = reply
            }
            if currentStreak >= threshold && currentStreak > 0 {
                effect.beepRecovery = settings.beepOnSuccessAfterFailure
                effect.runRecoveryCommand = !successCommand.isEmpty
            }
            if currentStreak > 0 {
                lastStreak = currentStreak
                currentStreak = 0
            }
        } else {
            failed += 1
            lastStatus = .down
            lastFailureAt = sample.sentAt
            lastLatencyMs = nil
            lastError = sample.error ?? "No reply"
            currentStreak += 1
            lastStreak = currentStreak
            if currentStreak > maxConsecutiveFailed {
                maxConsecutiveFailed = currentStreak
                maxConsecutiveFailedAt = sample.sentAt
            }
            if currentStreak >= threshold {
                effect.beepFailure = settings.beepOnFailed
                effect.runFailureCommand = currentStreak == threshold && !failureCommand.isEmpty
            }
        }

        appendHistory(sample, mode: settings.lowerPaneMode)
        let cap = max(1, settings.historyLimit)
        if history.count > cap {
            history.removeFirst(history.count - cap)
        }
        return effect
    }

    private mutating func appendHistory(_ sample: PingSample, mode: LowerPaneMode) {
        switch mode {
        case .off:
            return
        case .failedOnly where sample.success:
            return
        case .statusChange:
            if !history.isEmpty {
                let lastIndex = history.count - 1
                if history[lastIndex].success == sample.success {
                    history[lastIndex].count += 1
                    history[lastIndex].endedAt = sample.sentAt
                    history[lastIndex].latencyMs = sample.latencyMs
                    history[lastIndex].ttl = sample.ttl
                    history[lastIndex].replyAddress = sample.replyAddress
                    history[lastIndex].error = sample.error
                    return
                }
            }
        default:
            break
        }

        history.append(HistoryEntry(
            id: UUID(),
            sentAt: sample.sentAt,
            endedAt: nil,
            success: sample.success,
            latencyMs: sample.latencyMs,
            ttl: sample.ttl,
            replyAddress: sample.replyAddress,
            error: sample.error,
            count: 1
        ))
    }
}

enum HostMerge {
    static func merge(existing: [HostRecord], parsed: [ParsedTarget]) -> [HostRecord] {
        struct Key: Hashable {
            var host: String
            var port: UInt16?
            var group: String
        }

        var buckets: [Key: [HostRecord]] = [:]
        for record in existing {
            let key = Key(host: record.target.host.lowercased(), port: record.target.port, group: record.target.group)
            buckets[key, default: []].append(record)
        }

        var used: [Key: Int] = [:]
        return parsed.enumerated().map { index, source in
            var target = source
            target.order = index + 1
            let key = Key(host: target.host.lowercased(), port: target.port, group: target.group)
            let offset = used[key, default: 0]
            used[key] = offset + 1
            if let bucket = buckets[key], offset < bucket.count {
                var record = bucket[offset]
                record.target = target
                return record
            }
            return HostRecord(target: target)
        }
    }
}

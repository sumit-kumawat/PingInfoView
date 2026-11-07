import AppKit
import Foundation

enum PathTokens {
    static func expand(_ path: String) -> String {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let now = Date()
        text = text.replacingOccurrences(of: "{date}", with: stamp("yyyyMMdd", now))
        text = text.replacingOccurrences(of: "{time}", with: stamp("HHmmss", now))
        if text.hasPrefix("~") {
            text = (text as NSString).expandingTildeInPath
        }
        return text
    }

    private static func stamp(_ format: String, _ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

enum TextFile {
    static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) { return text }
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }
}

enum CommandTemplate {
    static let tokens: [(token: String, meaning: String)] = [
        ("%HostName%", "Host name"),
        ("%IPAddress%", "IP address"),
        ("%ReplyIPAddress%", "Reply address"),
        ("%Description%", "Description"),
        ("%Group%", "Group"),
        ("%LastPingStatus%", "Succeeded or Failed"),
        ("%LastPingTime%", "Latest latency"),
        ("%SucceedCount%", "Succeeded count"),
        ("%FailedCount%", "Failed count"),
        ("%PercentFailed%", "Percent failed"),
        ("%ConsecutiveFailedCount%", "Consecutive failures"),
        ("%Order%", "Original order")
    ]

    static func render(_ template: String, record: HostRecord, format: DisplayFormat) -> String {
        var command = template
        let pairs: [(String, String)] = [
            ("%HostName%", record.hostNameText),
            ("%IPAddress%", record.ipText),
            ("%ReplyIPAddress%", record.replyAddress ?? ""),
            ("%SucceedCount%", "\(record.succeeded)"),
            ("%FailedCount%", "\(record.failed)"),
            ("%ConsecutiveFailedCount%", "\(record.consecutiveFailed)"),
            ("%MaxConsecutiveFailedCount%", "\(record.maxConsecutiveFailed)"),
            ("%MaxConsecutiveFailedTime%", format.date(record.maxConsecutiveFailedAt)),
            ("%PercentFailed%", format.percent(record.percentFailed, sent: record.sent)),
            ("%TotalSentPings%", "\(record.sent)"),
            ("%LastPingStatus%", record.statusText),
            ("%LastPingTime%", format.milliseconds(record.lastLatencyMs)),
            ("%LastPingTTL%", record.lastTTL.map(String.init) ?? ""),
            ("%AveragePingTime%", format.milliseconds(record.averageMs)),
            ("%MinimumPingTime%", format.milliseconds(record.minLatencyMs)),
            ("%MaximumPingTime%", format.milliseconds(record.maxLatencyMs)),
            ("%Description%", record.target.description),
            ("%LastSucceedOn%", format.date(record.lastSuccessAt)),
            ("%LastFailedOn%", format.date(record.lastFailureAt)),
            ("%Order%", "\(record.target.order)"),
            ("%Disabled%", record.enabled ? "0" : "1"),
            ("%Group%", record.target.group),
            ("%PingType%", record.pingTypeText)
        ]
        for pair in pairs.sorted(by: { $0.0.count > $1.0.count }) {
            command = command.replacingOccurrences(of: pair.0, with: shellQuote(pair.1))
        }
        return command
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum CommandRunner {
    static func run(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", trimmed]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let keeper = ProcessKeeper.shared
        process.terminationHandler = { finished in keeper.remove(finished) }
        keeper.add(process)
        do {
            try process.run()
        } catch {
            keeper.remove(process)
        }
    }

    static func openInTerminal(_ script: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PingInfoView", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("ping-\(UUID().uuidString).command")
        try "#!/bin/zsh\n\(script)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

private final class ProcessKeeper: @unchecked Sendable {
    static let shared = ProcessKeeper()
    private let lock = NSLock()
    private var running: [ObjectIdentifier: Process] = [:]

    func add(_ process: Process) {
        lock.lock()
        running[ObjectIdentifier(process)] = process
        lock.unlock()
    }

    func remove(_ process: Process) {
        lock.lock()
        running.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }
}

struct CustomMenuItem: Identifiable, Equatable, Sendable {
    var id: Int
    var title: String
    var command: String
    var isSeparator: Bool
}

enum CustomMenuFile {
    static func parse(_ text: String) -> [CustomMenuItem] {
        var titles: [Int: String] = [:]
        var commands: [Int: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[") { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if key.lowercased().hasPrefix("caption"), let index = Int(key.dropFirst("caption".count)) {
                titles[index] = value
            } else if key.lowercased().hasPrefix("command"), let index = Int(key.dropFirst("command".count)) {
                commands[index] = value
            }
        }
        return titles.keys.sorted().compactMap { index in
            guard let title = titles[index], !title.isEmpty else { return nil }
            if title == "-" {
                return CustomMenuItem(id: index, title: "-", command: "", isSeparator: true)
            }
            return CustomMenuItem(id: index, title: title, command: commands[index] ?? "", isSeparator: false)
        }
    }
}

enum LogWriter {
    static func append(entries: [(HostRecord, PingSample)], path: String, includeHeader: Bool, format: DisplayFormat) throws {
        guard !entries.isEmpty else { return }
        let expanded = PathTokens.expand(path)
        guard !expanded.isEmpty else { return }
        let url = URL(fileURLWithPath: expanded)
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let exists = FileManager.default.fileExists(atPath: url.path)
        var line = ""
        if !exists && includeHeader {
            line += ["Time", "Host Name", "IP Address", "Description", "Status", "Ping (ms)", "TTL", "Reply", "Error"].joined(separator: ",") + "\n"
        }
        for (record, sample) in entries {
            let cells = [
                format.date(sample.sentAt),
                record.hostNameText,
                record.ipText,
                record.target.description,
                sample.success ? "Succeeded" : "Failed",
                format.milliseconds(sample.latencyMs),
                sample.ttl.map(String.init) ?? "",
                sample.replyAddress ?? "",
                sample.error ?? ""
            ].map(csv)
            line += cells.joined(separator: ",") + "\n"
        }
        if exists {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func csv(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

enum SupportPaths {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent(Brand.appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static var settings: URL {
        directory.appendingPathComponent("settings.json")
    }

    static var customMenu: URL {
        directory.appendingPathComponent("CustomMenu.ini")
    }
}

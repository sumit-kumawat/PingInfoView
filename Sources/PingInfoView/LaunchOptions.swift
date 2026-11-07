import Darwin
import Foundation

struct LaunchOptions: Equatable {
    var help = false
    var version = false
    var loadFile: String?
    var hostArguments: [String] = []
    var outputs: [(ExportFormat, String)] = []
    var timeoutMs: Int?
    var pingEvery: Bool?
    var intervalSeconds: Int?
    var hostListFormat: HostListFormat?
    var payloadSize: Int?
    var maxConcurrent: Int?
    var allowIPv6: Bool?
    var resolveEveryPing: Bool?
    var resolveAddresses: Bool?
    var windowTitle: String?
    var startImmediately: Bool?
    var unknown: [String] = []

    var requestsHeadless: Bool {
        help || version || !outputs.isEmpty
    }

    static func == (lhs: LaunchOptions, rhs: LaunchOptions) -> Bool {
        lhs.help == rhs.help
            && lhs.version == rhs.version
            && lhs.loadFile == rhs.loadFile
            && lhs.hostArguments == rhs.hostArguments
            && lhs.outputSignature == rhs.outputSignature
            && lhs.timeoutMs == rhs.timeoutMs
            && lhs.pingEvery == rhs.pingEvery
            && lhs.intervalSeconds == rhs.intervalSeconds
            && lhs.hostListFormat == rhs.hostListFormat
            && lhs.payloadSize == rhs.payloadSize
            && lhs.maxConcurrent == rhs.maxConcurrent
            && lhs.allowIPv6 == rhs.allowIPv6
            && lhs.resolveEveryPing == rhs.resolveEveryPing
            && lhs.resolveAddresses == rhs.resolveAddresses
            && lhs.windowTitle == rhs.windowTitle
            && lhs.startImmediately == rhs.startImmediately
            && lhs.unknown == rhs.unknown
    }

    private var outputSignature: [String] {
        outputs.map { "\($0.0.rawValue):\($0.1)" }
    }

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let key = argument.lowercased()
            if key == "-psn" || key.hasPrefix("-psn_") || key == "-applelocale" || key.hasPrefix("-nslanguage") {
                index += 1
                continue
            }
            func takeValue() -> String? {
                guard index + 1 < arguments.count else { return nil }
                index += 1
                return arguments[index]
            }
            switch key {
            case "--help", "-h", "/?", "/help":
                options.help = true
            case "--version", "/version":
                options.version = true
            case "/loadfile", "--loadfile", "-f":
                options.loadFile = takeValue() ?? ""
            case "/stext", "--stext":
                if let path = takeValue() { options.outputs.append((.text, path)) }
            case "/stab", "--stab":
                if let path = takeValue() { options.outputs.append((.tab, path)) }
            case "/scomma", "--scomma":
                if let path = takeValue() { options.outputs.append((.csv, path)) }
            case "/stabular", "--stabular":
                if let path = takeValue() { options.outputs.append((.tabular, path)) }
            case "/shtml", "--shtml":
                if let path = takeValue() { options.outputs.append((.html, path)) }
            case "/sverhtml", "--sverhtml":
                if let path = takeValue() { options.outputs.append((.verticalHTML, path)) }
            case "/sxml", "--sxml":
                if let path = takeValue() { options.outputs.append((.xml, path)) }
            case "/pingtimeout", "--timeout", "--ping-timeout":
                options.timeoutMs = takeValue().flatMap(Int.init)
            case "/pingevery", "--ping-every":
                options.pingEvery = takeValue().flatMap(parseBool)
            case "/pingeveryseconds", "--interval":
                options.intervalSeconds = takeValue().flatMap(Int.init)
            case "/iphostdescformat", "--descriptions":
                if let value = takeValue().flatMap(parseBool) {
                    options.hostListFormat = value ? .described : .plain
                }
            case "/pingsize", "--size":
                options.payloadSize = takeValue().flatMap(Int.init)
            case "/maxconcurrentpings", "--max-concurrent":
                options.maxConcurrent = takeValue().flatMap(Int.init)
            case "/ipv6", "--ipv6":
                options.allowIPv6 = takeValue().flatMap(parseBool)
            case "/resolveeveryping", "--resolve-every-ping":
                options.resolveEveryPing = takeValue().flatMap(parseBool)
            case "/resolveaddresses", "--resolve-addresses":
                options.resolveAddresses = takeValue().flatMap(parseBool)
            case "/windowtitle", "--window-title":
                options.windowTitle = takeValue()
            case "/startpingimmediately", "--start-immediately":
                options.startImmediately = takeValue().flatMap(parseBool)
            default:
                if argument.hasPrefix("-") || argument.hasPrefix("/") {
                    options.unknown.append(argument)
                } else {
                    options.hostArguments.append(argument)
                }
            }
            index += 1
        }
        return options
    }

    func apply(to settings: inout AppSettings) {
        if let timeoutMs { settings.timeoutMs = timeoutMs }
        if let pingEvery { settings.pingEvery = pingEvery }
        if let intervalSeconds { settings.intervalSeconds = intervalSeconds }
        if let hostListFormat { settings.hostListFormat = hostListFormat }
        if let payloadSize { settings.payloadSize = payloadSize }
        if let maxConcurrent { settings.maxConcurrent = maxConcurrent }
        if let allowIPv6 { settings.allowIPv6 = allowIPv6 }
        if let resolveEveryPing { settings.resolveEveryPing = resolveEveryPing }
        if let resolveAddresses { settings.resolveAddresses = resolveAddresses }
        if let windowTitle { settings.windowTitle = windowTitle }
        if let startImmediately { settings.startImmediately = startImmediately }
    }

    static func headless(_ options: LaunchOptions) -> Int32 {
        if options.help {
            print(helpText)
            return 0
        }
        if options.version {
            print("\(Brand.appName) \(Brand.version)")
            print("Author: \(Brand.author)")
            print(Brand.website)
            print(Brand.email)
            return 0
        }
        if !options.unknown.isEmpty {
            fputs("Unknown option \(options.unknown.joined(separator: ", ")).\n\n\(helpText)\n", stderr)
            return 1
        }
        var settings = AppSettings()
        options.apply(to: &settings)
        settings = settings.normalized()
        var text = ""
        if let loadFile = options.loadFile {
            let path = PathTokens.expand(loadFile)
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                fputs("Could not read \(path)\n", stderr)
                return 1
            }
            do {
                text = try TextFile.read(url)
            } catch {
                fputs("Could not read \(path): \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        if !options.hostArguments.isEmpty {
            if !text.isEmpty { text += "\n" }
            text += options.hostArguments.joined(separator: "\n")
        }
        settings.hostList = text
        let parsed = HostParser.parse(text, options: settings.parseOptions)
        if parsed.targets.isEmpty {
            fputs("No hosts to ping. Pass host names or /loadfile.\n", stderr)
            return 1
        }
        for warning in parsed.warnings {
            fputs("\(warning)\n", stderr)
        }
        let records = parsed.targets.map(HostRecord.init(target:))
        let activeSettings = settings
        let results = runBlocking {
            await ProbeBatch.ping(records, settings: activeSettings)
        }
        var finished = records
        for result in results {
            guard let index = finished.firstIndex(where: { $0.id == result.id }) else { continue }
            _ = finished[index].ingest(result.sample, settings: settings)
        }
        let exportOptions = ExportOptions.from(settings)
        for output in options.outputs {
            do {
                try Exporter.write(records: finished, format: output.0, to: output.1, options: exportOptions)
                fputs("Wrote \(PathTokens.expand(output.1))\n", stderr)
            } catch {
                fputs("Could not write \(output.1): \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        let up = finished.filter { $0.lastStatus == .up }.count
        let down = finished.filter { $0.lastStatus == .down }.count
        fputs("Pinged \(finished.count) \(finished.count == 1 ? "host" : "hosts"): \(up) succeeded, \(down) failed\n", stderr)
        return 0
    }

    private static func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            let value = await work()
            box.set(value)
            semaphore.signal()
        }
        semaphore.wait()
        return box.get()!
    }

    private static func parseBool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "1", "true", "yes", "on": true
        case "0", "false", "no", "off": false
        default: nil
        }
    }

    static let helpText = """
    \(Brand.appName) \(Brand.version)
    \(Brand.author)
    \(Brand.website)
    \(Brand.email)

    Ping many host names and IP addresses, then save one round of results.

    Usage:
      PingInfoView /loadfile hosts.txt /scomma results.csv
      PingInfoView /shtml report.html 1.1.1.1 example.com
      PingInfoView --help

    Save options (each takes a file path):
      /stext       Plain text
      /stab        Tab-delimited text
      /scomma      CSV
      /stabular    Aligned text table
      /shtml       HTML table
      /sverhtml    Vertical HTML
      /sxml        XML

    Other options:
      /loadfile <path>             Host list to read
      /PingTimeout <ms>            Reply timeout, default 2000
      /PingEverySeconds <seconds>  Kept for compatibility; a command-line save runs once
      /IPHostDescFormat <0|1>      1 uses "IP description" lines and Group: headers
      /PingSize <bytes>            ICMP payload size, default 32
      /MaxConcurrentPings <count>  Default 50
      /IPv6 <0|1>                  Allow IPv6 addresses and prefer AAAA lookups
      /ResolveEveryPing <0|1>
      /ResolveAddresses <0|1>
      /WindowTitle <text>
      /StartPingImmediately <0|1>

    A command-line save always performs a single round. Open the app without
    a save option to keep pinging on a timer.

    In an IP-and-description list, '#' starts a comment and "Group: Name"
    starts a group. Add :port, for example 192.168.1.10:443, to use TCP.
    """
}

private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?

    func set(_ value: T) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

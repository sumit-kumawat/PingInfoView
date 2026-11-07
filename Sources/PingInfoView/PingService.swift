import Darwin
import Foundation
import Network

struct PingRequest: Equatable, Sendable {
    var destination: String
    var port: UInt16?
    var timeoutMs: Int
    var payloadSize: Int
    var ttl: Int
    var dontFragment: Bool
    var allowIPv6: Bool
    var sourceAddress: String
}

struct PingSample: Equatable, Sendable {
    var skipped = false
    var success = false
    var latencyMs: Double?
    var ttl: Int?
    var replyAddress: String?
    var address: String?
    var error: String?
    var sentAt = Date()

    static func skipped() -> PingSample {
        PingSample(skipped: true)
    }
}

struct ParsedPing: Equatable, Sendable {
    var success: Bool
    var latencyMs: Double?
    var ttl: Int?
    var replyAddress: String?
    var address: String?
    var error: String?
}

enum PingReportParser {
    static func parse(_ text: String) -> ParsedPing {
        let received = firstInt(text, pattern: #"(\d+) packets received"#) ?? 0
        var address: String?
        if let ip = firstString(text, pattern: #"PING\s+\S+\s+\(([^)]+)\)"#) {
            address = ip
        } else if let ip = firstString(text, pattern: #"-->\s+(\S+)"#) {
            address = ip
        }

        var latency: Double?
        var ttl: Int?
        var reply: String?
        for line in text.split(separator: "\n") {
            let row = String(line)
            guard let ms = firstString(row, pattern: #"time=([0-9.]+)\s*ms"#), let value = Double(ms) else {
                continue
            }
            latency = value
            if let hop = firstString(row, pattern: #"(?:ttl|hlim)=([0-9]+)"#) {
                ttl = Int(hop)
            }
            if let from = firstString(row, pattern: #"from\s+(\S+)"#) {
                reply = cleanReply(from)
            }
            break
        }

        let success = latency != nil && (received > 0 || !text.contains("packets received"))
        return ParsedPing(
            success: success,
            latencyMs: success ? latency : nil,
            ttl: success ? ttl : nil,
            replyAddress: success ? reply : nil,
            address: address,
            error: success ? nil : reason(text)
        )
    }

    private static func cleanReply(_ raw: String) -> String {
        var reply = raw
        while reply.hasSuffix(",") { reply.removeLast() }
        let colons = reply.filter { $0 == ":" }.count
        if colons < 2 && reply.hasSuffix(":") { reply.removeLast() }
        return reply
    }

    private static func reason(_ text: String) -> String {
        let lowered = text.lowercased()
        if lowered.contains("unknown host")
            || lowered.contains("nodename nor servname")
            || lowered.contains("name or service not known")
            || lowered.contains("cannot resolve") {
            return "Unknown host"
        }
        if lowered.contains("destination host unreachable") { return "Host unreachable" }
        if lowered.contains("destination net unreachable") { return "Network unreachable" }
        if lowered.contains("network is unreachable") { return "Network unreachable" }
        if lowered.contains("no route to host") { return "No route to host" }
        if lowered.contains("time to live exceeded") || lowered.contains("time exceeded") { return "TTL expired in transit" }
        if lowered.contains("frag needed") || lowered.contains("message too long") { return "Packet too big" }
        if lowered.contains("can't assign requested address") { return "Source address is not on this Mac" }
        if lowered.contains("operation not permitted") { return "Not permitted" }
        if lowered.contains("connection refused") { return "Connection refused" }
        return "Timeout"
    }

    private static func firstString(_ text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[capture])
    }

    private static func firstInt(_ text: String, pattern: String) -> Int? {
        firstString(text, pattern: pattern).flatMap(Int.init)
    }
}

enum DNS {
    enum Family {
        case v4
        case v6

        var code: Int32 { self == .v4 ? AF_INET : AF_INET6 }
    }

    static func lookup(_ host: String, family: Family) -> String? {
        var hints = addrinfo()
        hints.ai_family = family.code
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }
        return numericHost(info)
    }

    static func reverse(_ address: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let code = getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
        guard code == 0 else { return nil }
        let name = decodeHost(buffer)
        if name.isEmpty || name == address { return nil }
        return name
    }

    private static func numericHost(_ info: UnsafeMutablePointer<addrinfo>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let code = getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
        guard code == 0 else { return nil }
        let text = decodeHost(buffer)
        return text.isEmpty ? nil : text
    }

    private static func decodeHost(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

final class ReverseResolver: @unchecked Sendable {
    static let shared = ReverseResolver()
    private let queue: OperationQueue

    private init() {
        queue = OperationQueue()
        queue.name = "PingInfoView.reverse-dns"
        queue.maxConcurrentOperationCount = 8
        queue.qualityOfService = .utility
    }

    func resolve(_ address: String, completion: @escaping @Sendable (String?) -> Void) {
        queue.addOperation {
            completion(DNS.reverse(address))
        }
    }
}

enum RequestBuilder {
    static func request(for record: HostRecord, settings: AppSettings) -> PingRequest {
        let destination: String
        if !settings.resolveEveryPing, let cached = record.resolvedAddress, !cached.isEmpty {
            destination = cached
        } else {
            destination = record.target.host
        }
        return PingRequest(
            destination: destination,
            port: record.target.port,
            timeoutMs: settings.timeoutMs,
            payloadSize: settings.payloadSize,
            ttl: settings.ttl,
            dontFragment: settings.dontFragment,
            allowIPv6: settings.allowIPv6,
            sourceAddress: settings.sourceAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

enum PingArguments {
    static let ipv4Tool = "/sbin/ping"
    static let ipv6Tool = "/sbin/ping6"

    /// ping6 has no reply-timeout option (its -W is a flag), so IPv6 relies on the caller's kill timer.
    static func make(ipv6: Bool, host: String, request: PingRequest) -> [String] {
        let timeout = max(100, request.timeoutMs)
        var arguments = ["-c", "1", "-n"]
        if ipv6 {
            arguments += ["-s", "\(min(max(0, request.payloadSize), 65_487))"]
            if request.ttl > 0 { arguments += ["-h", "\(request.ttl)"] }
            if request.dontFragment { arguments.append("-D") }
        } else {
            let seconds = Int(ceil(Double(timeout) / 1000)) + 1
            arguments += ["-W", "\(timeout)", "-t", "\(seconds)", "-s", "\(min(max(0, request.payloadSize), 65_507))"]
            if request.ttl > 0 { arguments += ["-m", "\(request.ttl)"] }
            if request.dontFragment { arguments.append("-D") }
        }
        let source = request.sourceAddress
        if !source.isEmpty {
            let sourceIsV6 = HostParser.isIPv6Literal(source)
            let sourceIsV4 = HostParser.ipv4Value(source) != nil
            if (ipv6 && sourceIsV6) || (!ipv6 && sourceIsV4) {
                arguments += ["-S", source]
            }
        }
        arguments.append(host)
        return arguments
    }
}

enum PingService {
    private static let resolverQueue = DispatchQueue(label: "PingInfoView.resolve", qos: .utility, attributes: .concurrent)
    private static let networkQueue = DispatchQueue(label: "PingInfoView.tcp", qos: .utility, attributes: .concurrent)

    static func probe(_ request: PingRequest) async -> PingSample {
        if request.port != nil {
            return await tcpProbe(request)
        }
        return await icmpProbe(request)
    }

    private static func icmpProbe(_ request: PingRequest) async -> PingSample {
        let sentAt = Date()
        let host = stripBrackets(request.destination)
        let route = await chooseFamily(host, allowIPv6: request.allowIPv6)
        var sample = await runPing(ipv6: route.ipv6, host: route.target, request: request, sentAt: sentAt)
        if sample.address == nil, HostParser.isIPAddress(route.target) {
            sample.address = route.target
        }
        return sample
    }

    private static func chooseFamily(_ host: String, allowIPv6: Bool) async -> (ipv6: Bool, target: String) {
        if HostParser.isIPv6Literal(host) { return (true, host) }
        if HostParser.ipv4Value(host) != nil || !allowIPv6 { return (false, host) }
        return await withCheckedContinuation { continuation in
            resolverQueue.async {
                if let ipv6 = DNS.lookup(host, family: .v6) {
                    continuation.resume(returning: (true, ipv6))
                } else if let ipv4 = DNS.lookup(host, family: .v4) {
                    continuation.resume(returning: (false, ipv4))
                } else {
                    continuation.resume(returning: (false, host))
                }
            }
        }
    }

    private static func runPing(ipv6: Bool, host: String, request: PingRequest, sentAt: Date) async -> PingSample {
        let executable = ipv6 ? PingArguments.ipv6Tool : PingArguments.ipv4Tool
        let arguments = PingArguments.make(ipv6: ipv6, host: host, request: request)
        let timeout = max(100, request.timeoutMs)
        let grace = ipv6 ? 0 : 1000

        return await withCheckedContinuation { continuation in
            let gate = ResumeOnce<PingSample>()
            let job = PingJob()
            let process = job.process
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                try? output.fileHandleForReading.close()
                var parsed = PingReportParser.parse(String(decoding: data, as: UTF8.self))
                if !parsed.success && job.timedOut {
                    parsed.error = "Timeout"
                }
                gate.resume(continuation, with: PingSample(
                    success: parsed.success,
                    latencyMs: parsed.latencyMs,
                    ttl: parsed.ttl,
                    replyAddress: parsed.replyAddress,
                    address: parsed.address,
                    error: parsed.error,
                    sentAt: sentAt
                ))
            }
            do {
                try process.run()
            } catch {
                try? output.fileHandleForReading.close()
                try? output.fileHandleForWriting.close()
                gate.resume(continuation, with: PingSample(
                    success: false,
                    error: "Could not start ping (\(error.localizedDescription))",
                    sentAt: sentAt
                ))
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(timeout + grace)) {
                job.stopIfRunning()
            }
        }
    }

    private static func tcpProbe(_ request: PingRequest) async -> PingSample {
        let sentAt = Date()
        let host = stripBrackets(request.destination)
        guard let port = request.port, let nwPort = NWEndpoint.Port(rawValue: port) else {
            return PingSample(success: false, error: "Invalid port", sentAt: sentAt)
        }
        let started = ContinuousClock.now
        let options = NWProtocolTCP.Options()
        options.connectionTimeout = max(1, Int(ceil(Double(request.timeoutMs) / 1000)))
        options.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: options)
        if !request.allowIPv6, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let timeout = max(100, request.timeoutMs)
        let literal = HostParser.isIPAddress(host) ? host : nil

        return await withCheckedContinuation { continuation in
            let gate = ResumeOnce<PingSample>()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let milliseconds = seconds(ContinuousClock.now - started) * 1000
                    var address = literal
                    if case let .hostPort(remote, _)? = connection.currentPath?.remoteEndpoint {
                        address = describe(remote)
                    }
                    gate.resume(continuation, with: PingSample(
                        success: true,
                        latencyMs: milliseconds,
                        replyAddress: address,
                        address: address,
                        sentAt: sentAt
                    ))
                    connection.cancel()
                case .waiting(let error), .failed(let error):
                    gate.resume(continuation, with: PingSample(
                        success: false,
                        address: literal,
                        error: tcpMessage(error),
                        sentAt: sentAt
                    ))
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: networkQueue)
            networkQueue.asyncAfter(deadline: .now() + .milliseconds(timeout)) {
                gate.resume(continuation, with: PingSample(
                    success: false,
                    address: literal,
                    error: "Timeout",
                    sentAt: sentAt
                ))
                connection.cancel()
            }
        }
    }

    private static func describe(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return "\(address)"
        case .ipv6(let address):
            let text = "\(address)"
            return text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }

    static func tcpMessage(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "Connection refused"
            case .ETIMEDOUT: return "Timeout"
            case .EHOSTUNREACH, .EHOSTDOWN: return "Host unreachable"
            case .ENETUNREACH, .ENETDOWN: return "Network unreachable"
            case .ECONNRESET: return "Connection reset"
            case .EADDRNOTAVAIL: return "Address not available"
            default: return "Connection failed"
            }
        case .dns:
            return "Unknown host"
        default:
            return "Connection failed"
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func stripBrackets(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return host }
        return String(host.dropFirst().dropLast())
    }
}

private final class PingJob: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var killed = false

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return killed
    }

    func stopIfRunning() {
        guard process.isRunning else { return }
        lock.lock()
        killed = true
        lock.unlock()
        process.terminate()
    }
}

final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume(_ continuation: CheckedContinuation<Value, Never>, with value: Value) {
        lock.lock()
        let shouldResume = !done
        done = true
        lock.unlock()
        if shouldResume {
            continuation.resume(returning: value)
        }
    }
}

struct PingSampleResult: Sendable {
    var id: UUID
    var sample: PingSample
}

enum ProbeBatch {
    static func ping(_ records: [HostRecord], settings: AppSettings) async -> [PingSampleResult] {
        let jobs: [(UUID, PingRequest)] = records.filter(\.enabled).map { record in
            (record.id, RequestBuilder.request(for: record, settings: settings))
        }
        let limiter = SlotLimiter(settings.maxConcurrent)
        return await withTaskGroup(of: PingSampleResult.self) { group in
            for job in jobs {
                group.addTask {
                    let acquired = await limiter.acquire()
                    if !acquired || Task.isCancelled {
                        if acquired { await limiter.release() }
                        return PingSampleResult(id: job.0, sample: .skipped())
                    }
                    let sample = await PingService.probe(job.1)
                    await limiter.release()
                    return PingSampleResult(id: job.0, sample: sample)
                }
            }
            var results: [PingSampleResult] = []
            results.reserveCapacity(jobs.count)
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
}

private actor SlotLimiter {
    private var slots: Int
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var order: [UUID] = []

    init(_ slots: Int) {
        self.slots = max(1, slots)
    }

    func acquire() async -> Bool {
        if slots > 0 {
            slots -= 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
                order.append(id)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        while let next = order.first {
            order.removeFirst()
            if let continuation = waiters.removeValue(forKey: next) {
                continuation.resume(returning: true)
                return
            }
        }
        slots += 1
    }

    private func cancel(_ id: UUID) {
        order.removeAll { $0 == id }
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(returning: false)
        }
    }
}

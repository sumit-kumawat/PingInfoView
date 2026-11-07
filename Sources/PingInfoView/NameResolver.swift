import Darwin
import Foundation

struct ResolvedName: Sendable, Equatable {
    enum Source: String, Sendable {
        case literal, dns, mdns, llmnr, netbios
    }

    var address: String
    var source: Source
}

/// Finds an address the way Windows does for a LAN: DNS with the Mac's search domains first, then mDNS
/// (`name.local`), LLMNR, and NetBIOS for single-label names such as `printer`.
enum NameResolver {
    private static let lookups: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "PingInfoView.resolve"
        queue.maxConcurrentOperationCount = 48
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private static let cache = ResolveCache()

    static func resolve(_ rawHost: String, preferIPv6: Bool, findLocalNames: Bool, timeoutMs: Int) async -> ResolvedName? {
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        if HostParser.isIPAddress(host) {
            return ResolvedName(address: host, source: .literal)
        }
        let key = "\(host.lowercased())|\(preferIPv6)|\(findLocalNames)"
        if let cached = cache.value(for: key) {
            return cached.answer
        }
        let dnsBudget = min(max(timeoutMs, 2000), 5000)
        var answer = await run(timeoutMs: dnsBudget) { systemLookup(host, preferIPv6: preferIPv6) }.map {
            ResolvedName(address: $0, source: host.lowercased().hasSuffix(".local") ? .mdns : .dns)
        }
        let single = !host.contains(".")
        if answer == nil, findLocalNames, single {
            answer = await localLookup(host, preferIPv6: preferIPv6, timeoutMs: min(max(timeoutMs, 800), 2000))
        }
        cache.store(answer, for: key, seconds: answer == nil ? 15 : 120)
        return answer
    }

    static func clearCache() {
        cache.clear()
    }

    /// Tries mDNS, LLMNR, and NetBIOS together and keeps the first answer.
    private static func localLookup(_ host: String, preferIPv6: Bool, timeoutMs: Int) async -> ResolvedName? {
        await withTaskGroup(of: ResolvedName?.self) { group in
            group.addTask {
                await run(timeoutMs: timeoutMs) { systemLookup("\(host).local", preferIPv6: preferIPv6) }
                    .map { ResolvedName(address: $0, source: .mdns) }
            }
            group.addTask {
                await run(timeoutMs: timeoutMs) { LLMNR.query(host, timeoutMs: timeoutMs) }
                    .map { ResolvedName(address: $0, source: .llmnr) }
            }
            if host.utf8.count <= 15 {
                group.addTask {
                    await run(timeoutMs: timeoutMs) { NetBIOS.query(host, timeoutMs: timeoutMs) }
                        .map { ResolvedName(address: $0, source: .netbios) }
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    /// `getaddrinfo` can block for many seconds on an unknown name; the caller gets `nil` after `timeoutMs`.
    static func run(timeoutMs: Int, _ work: @escaping @Sendable () -> String?) async -> String? {
        await withCheckedContinuation { continuation in
            let gate = ResumeOnce<String?>()
            lookups.addOperation {
                gate.resume(continuation, with: work())
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
                gate.resume(continuation, with: nil)
            }
        }
    }

    static func systemLookup(_ host: String, preferIPv6: Bool) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = AI_ADDRCONFIG
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(first) }
        var v4: String?
        var v6: String?
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let node = cursor {
            if let address = node.pointee.ai_addr {
                var storage = sockaddr_storage()
                let size = Int(node.pointee.ai_addrlen)
                if size <= MemoryLayout<sockaddr_storage>.size {
                    withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: UnsafeRawBufferPointer(start: address, count: size)) }
                    let text = SocketAddress(storage: storage, length: node.pointee.ai_addrlen).numericHost
                    if node.pointee.ai_family == AF_INET, v4 == nil { v4 = text }
                    if node.pointee.ai_family == AF_INET6, v6 == nil { v6 = text }
                }
            }
            cursor = node.pointee.ai_next
        }
        return preferIPv6 ? (v6 ?? v4) : (v4 ?? v6)
    }

    static func reverse(_ address: String, findLocalNames: Bool) -> String? {
        if let name = DNS.reverse(address) { return name }
        guard findLocalNames, NetworkErrors.isPrivateIPv4(address) else { return nil }
        return NetBIOS.nodeStatus(address, timeoutMs: 800)
    }
}

private final class ResolveCache: @unchecked Sendable {
    struct Entry {
        var answer: ResolvedName?
        var expires: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func value(for key: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        if entry.expires < Date() {
            entries[key] = nil
            return nil
        }
        return entry
    }

    func store(_ answer: ResolvedName?, for key: String, seconds: TimeInterval) {
        lock.lock()
        entries[key] = Entry(answer: answer, expires: Date().addingTimeInterval(seconds))
        lock.unlock()
    }

    func clear() {
        lock.lock()
        entries = [:]
        lock.unlock()
    }
}

/// A blocking UDP socket with a receive deadline, used for one LLMNR or NetBIOS exchange.
private struct UDPExchange {
    let fd: Int32

    init?(broadcast: Bool = false, multicastTTL: UInt8? = nil) {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        if broadcast {
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        if var ttl = multicastTTL {
            setsockopt(fd, Int32(IPPROTO_IP), IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        }
    }

    func send(_ packet: [UInt8], to host: String, port: UInt16) {
        guard let address = SocketAddress(numeric: host, port: port) else { return }
        _ = packet.withUnsafeBytes { bytes in
            address.withSockaddr { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, $1) }
        }
    }

    /// Calls `accept` with each datagram until it returns a value or the deadline passes.
    func receive<T>(until deadline: Date, accept: ([UInt8], String?) -> T?) -> T? {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            var timeout = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - floor(remaining)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var name = sockaddr_storage()
            var nameLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &name) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &nameLength)
                    }
                }
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            let from = SocketAddress(storage: name, length: nameLength).numericHost
            if let value = accept(Array(buffer[0..<count]), from) { return value }
        }
    }

    func close() {
        Darwin.close(fd)
    }
}

enum LLMNR {
    static func packet(_ name: String, id: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            let utf8 = Array(label.utf8.prefix(63))
            bytes.append(UInt8(utf8.count))
            bytes += utf8
        }
        bytes += [0, 0, 1, 0, 1]
        return bytes
    }

    static func answer(_ bytes: [UInt8], id: UInt16) -> String? {
        guard bytes.count >= 12, UInt16(bytes[0]) << 8 | UInt16(bytes[1]) == id else { return nil }
        guard bytes[2] & 0x80 != 0, bytes[3] & 0x0F == 0 else { return nil }
        let questions = Int(UInt16(bytes[4]) << 8 | UInt16(bytes[5]))
        let answers = Int(UInt16(bytes[6]) << 8 | UInt16(bytes[7]))
        var offset = 12
        for _ in 0..<questions {
            guard let next = DNSWire.skipName(bytes, offset), next + 4 <= bytes.count else { return nil }
            offset = next + 4
        }
        for _ in 0..<answers {
            guard let next = DNSWire.skipName(bytes, offset), next + 10 <= bytes.count else { return nil }
            let type = UInt16(bytes[next]) << 8 | UInt16(bytes[next + 1])
            let length = Int(UInt16(bytes[next + 8]) << 8 | UInt16(bytes[next + 9]))
            let data = next + 10
            guard data + length <= bytes.count else { return nil }
            if type == 1, length == 4 {
                return "\(bytes[data]).\(bytes[data + 1]).\(bytes[data + 2]).\(bytes[data + 3])"
            }
            offset = data + length
        }
        return nil
    }

    static func query(_ name: String, timeoutMs: Int) -> String? {
        guard let exchange = UDPExchange(multicastTTL: 1) else { return nil }
        defer { exchange.close() }
        let id = UInt16.random(in: 1...UInt16.max)
        exchange.send(packet(name, id: id), to: "224.0.0.252", port: 5355)
        return exchange.receive(until: Date().addingTimeInterval(Double(timeoutMs) / 1000)) { bytes, _ in
            answer(bytes, id: id)
        }
    }
}

enum NetBIOS {
    /// First-level encoding from RFC 1001: 16 bytes, space padded, each nibble mapped to `A`...`P`.
    static func encodedName(_ name: String, suffix: UInt8 = 0x00, wildcard: Bool = false) -> [UInt8] {
        var raw: [UInt8]
        if wildcard {
            raw = [UInt8(ascii: "*")] + [UInt8](repeating: 0, count: 15)
        } else {
            raw = Array(name.uppercased().utf8.prefix(15))
            raw += [UInt8](repeating: 0x20, count: 15 - raw.count)
            raw.append(suffix)
        }
        var encoded: [UInt8] = [0x20]
        for byte in raw {
            encoded.append(UInt8(ascii: "A") + (byte >> 4))
            encoded.append(UInt8(ascii: "A") + (byte & 0x0F))
        }
        encoded.append(0)
        return encoded
    }

    static func nameQuery(_ name: String, id: UInt16) -> [UInt8] {
        [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x10, 0, 1, 0, 0, 0, 0, 0, 0] + encodedName(name) + [0x00, 0x20, 0x00, 0x01]
    }

    static func statusQuery(id: UInt16) -> [UInt8] {
        [UInt8(id >> 8), UInt8(id & 0xFF), 0x00, 0x00, 0, 1, 0, 0, 0, 0, 0, 0] + encodedName("", wildcard: true) + [0x00, 0x21, 0x00, 0x01]
    }

    private static func answerData(_ bytes: [UInt8], id: UInt16, type expected: UInt16) -> [UInt8]? {
        guard bytes.count >= 12, UInt16(bytes[0]) << 8 | UInt16(bytes[1]) == id else { return nil }
        guard bytes[2] & 0x80 != 0, bytes[3] & 0x0F == 0 else { return nil }
        let questions = Int(UInt16(bytes[4]) << 8 | UInt16(bytes[5]))
        let answers = Int(UInt16(bytes[6]) << 8 | UInt16(bytes[7]))
        guard answers > 0 else { return nil }
        var offset = 12
        for _ in 0..<questions {
            guard let next = DNSWire.skipName(bytes, offset), next + 4 <= bytes.count else { return nil }
            offset = next + 4
        }
        guard let next = DNSWire.skipName(bytes, offset), next + 10 <= bytes.count else { return nil }
        let type = UInt16(bytes[next]) << 8 | UInt16(bytes[next + 1])
        let length = Int(UInt16(bytes[next + 8]) << 8 | UInt16(bytes[next + 9]))
        let data = next + 10
        guard type == expected, data + length <= bytes.count else { return nil }
        return Array(bytes[data..<(data + length)])
    }

    static func address(in bytes: [UInt8], id: UInt16) -> String? {
        guard let data = answerData(bytes, id: id, type: 0x20) else { return nil }
        var offset = 0
        while offset + 6 <= data.count {
            let ip = Array(data[(offset + 2)..<(offset + 6)])
            if ip != [0, 0, 0, 0] {
                return "\(ip[0]).\(ip[1]).\(ip[2]).\(ip[3])"
            }
            offset += 6
        }
        return nil
    }

    /// The first unique workstation or server name in a node status reply.
    static func machineName(in bytes: [UInt8], id: UInt16) -> String? {
        guard let data = answerData(bytes, id: id, type: 0x21), let count = data.first else { return nil }
        var fallback: String?
        for index in 0..<Int(count) {
            let start = 1 + index * 18
            guard start + 18 <= data.count else { break }
            let suffix = data[start + 15]
            let group = data[start + 16] & 0x80 != 0
            let name = String(decoding: data[start..<(start + 15)], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard !group, !name.isEmpty else { continue }
            if suffix == 0x00 { return name }
            if suffix == 0x20, fallback == nil { fallback = name }
        }
        return fallback
    }

    static func query(_ name: String, timeoutMs: Int) -> String? {
        let targets = broadcastAddresses()
        guard !targets.isEmpty, let exchange = UDPExchange(broadcast: true) else { return nil }
        defer { exchange.close() }
        let id = UInt16.random(in: 1...UInt16.max)
        let packet = nameQuery(name, id: id)
        for target in targets {
            exchange.send(packet, to: target, port: 137)
        }
        return exchange.receive(until: Date().addingTimeInterval(Double(timeoutMs) / 1000)) { bytes, _ in
            address(in: bytes, id: id)
        }
    }

    static func nodeStatus(_ address: String, timeoutMs: Int) -> String? {
        guard let exchange = UDPExchange() else { return nil }
        defer { exchange.close() }
        let id = UInt16.random(in: 1...UInt16.max)
        exchange.send(statusQuery(id: id), to: address, port: 137)
        return exchange.receive(until: Date().addingTimeInterval(Double(timeoutMs) / 1000)) { bytes, _ in
            machineName(in: bytes, id: id)
        }
    }

    /// The IPv4 broadcast address of every active interface that has one (Wi-Fi, Ethernet, bridges).
    static func broadcastAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(first) }
        var results: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let node = cursor {
            let flags = Int32(node.pointee.ifa_flags)
            if flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
               let address = node.pointee.ifa_dstaddr,
               Int32(address.pointee.sa_family) == AF_INET,
               let local = node.pointee.ifa_addr, Int32(local.pointee.sa_family) == AF_INET {
                var storage = sockaddr_storage()
                withUnsafeMutableBytes(of: &storage) {
                    $0.copyMemory(from: UnsafeRawBufferPointer(start: address, count: MemoryLayout<sockaddr_in>.size))
                }
                if let text = SocketAddress(storage: storage, length: socklen_t(MemoryLayout<sockaddr_in>.size)).numericHost,
                   text != "0.0.0.0", !results.contains(text) {
                    results.append(text)
                }
            }
            cursor = node.pointee.ifa_next
        }
        return results
    }
}

enum DNSWire {
    /// Returns the offset after a DNS-encoded name, following one compression pointer.
    static func skipName(_ bytes: [UInt8], _ start: Int) -> Int? {
        var offset = start
        while offset < bytes.count {
            let length = bytes[offset]
            if length == 0 { return offset + 1 }
            if length & 0xC0 == 0xC0 { return offset + 2 <= bytes.count ? offset + 2 : nil }
            offset += 1 + Int(length)
        }
        return nil
    }
}

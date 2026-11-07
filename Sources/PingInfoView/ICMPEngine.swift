import Darwin
import Foundation

/// RFC 3542 values from `<netinet6/in6.h>`; Swift doesn't import them because they depend on `__APPLE_USE_RFC_3542`.
private let IPV6_RECVHOPLIMIT: Int32 = 37
private let IPV6_HOPLIMIT: Int32 = 47

struct ICMPOptions: Sendable, Hashable {
    var payloadSize: Int = 32
    var ttl: Int = 0
    var dontFragment = false
    var source = ""
}

struct ICMPReply: Sendable, Equatable {
    var success: Bool
    var latencyMs: Double?
    var ttl: Int?
    var from: String?
    var error: String?
    /// The `errno` from `sendto`, when the packet never left this Mac.
    var sendErrno: Int32?
    /// True when unprivileged ICMP sockets are unavailable, so the caller should fall back to `/sbin/ping`.
    var unavailable = false
}

enum ICMPPacket {
    static let echoRequestV4: UInt8 = 8
    static let echoReplyV4: UInt8 = 0
    static let echoRequestV6: UInt8 = 128
    static let echoReplyV6: UInt8 = 129

    enum Parsed: Equatable {
        case reply(identifier: UInt16, sequence: UInt16, ttl: Int?, payload: [UInt8])
        case failure(identifier: UInt16, sequence: UInt16, message: String)
        case other
    }

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum &+= UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            sum &+= UInt32(bytes[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(truncatingIfNeeded: sum)
    }

    /// ICMPv6 checksums are filled in by the kernel; IPv4 checksums are computed here.
    static func echoRequest(ipv6: Bool, identifier: UInt16, sequence: UInt16, payload: [UInt8]) -> [UInt8] {
        var packet: [UInt8] = [
            ipv6 ? echoRequestV6 : echoRequestV4, 0, 0, 0,
            UInt8(identifier >> 8), UInt8(identifier & 0xFF),
            UInt8(sequence >> 8), UInt8(sequence & 0xFF)
        ]
        packet += payload
        if !ipv6 {
            let sum = checksum(packet)
            packet[2] = UInt8(sum >> 8)
            packet[3] = UInt8(sum & 0xFF)
        }
        return packet
    }

    /// Payloads start with a 4-byte token so replies can be matched even if the kernel rewrites the identifier.
    static func payload(size: Int, token: UInt32) -> [UInt8] {
        let count = max(0, size)
        var bytes = [UInt8](repeating: 0, count: count)
        let tokenBytes: [UInt8] = [UInt8(token >> 24), UInt8((token >> 16) & 0xFF), UInt8((token >> 8) & 0xFF), UInt8(token & 0xFF)]
        for index in 0..<count {
            bytes[index] = index < 4 ? tokenBytes[index] : UInt8(truncatingIfNeeded: 0x20 + index % 64)
        }
        return bytes
    }

    static func token(in payload: [UInt8]) -> UInt32? {
        guard payload.count >= 4 else { return nil }
        return UInt32(payload[0]) << 24 | UInt32(payload[1]) << 16 | UInt32(payload[2]) << 8 | UInt32(payload[3])
    }

    /// IPv4 datagram sockets on macOS deliver the IP header too; it is stripped here and its TTL kept.
    static func parse(_ data: [UInt8], ipv6: Bool, hopLimit: Int? = nil) -> Parsed {
        var bytes = data
        var ttl = hopLimit
        if !ipv6, bytes.count >= 20, bytes[0] >> 4 == 4 {
            let headerLength = Int(bytes[0] & 0x0F) * 4
            guard headerLength >= 20, bytes.count >= headerLength + 8 else { return .other }
            ttl = Int(bytes[8])
            bytes = Array(bytes[headerLength...])
        }
        guard bytes.count >= 8 else { return .other }
        let type = bytes[0]
        let code = bytes[1]
        if type == (ipv6 ? echoReplyV6 : echoReplyV4) {
            return .reply(
                identifier: UInt16(bytes[4]) << 8 | UInt16(bytes[5]),
                sequence: UInt16(bytes[6]) << 8 | UInt16(bytes[7]),
                ttl: ttl,
                payload: Array(bytes[8...])
            )
        }
        guard let message = errorMessage(type: type, code: code, ipv6: ipv6) else { return .other }
        let inner = Array(bytes[8...])
        let offset: Int
        if ipv6 {
            guard inner.count >= 48, inner[6] == 58 else { return .other }
            offset = 40
        } else {
            guard inner.count >= 28, inner[0] >> 4 == 4 else { return .other }
            offset = Int(inner[0] & 0x0F) * 4
            guard inner.count >= offset + 8, inner[9] == 1 else { return .other }
        }
        guard inner[offset] == (ipv6 ? echoRequestV6 : echoRequestV4) else { return .other }
        return .failure(
            identifier: UInt16(inner[offset + 4]) << 8 | UInt16(inner[offset + 5]),
            sequence: UInt16(inner[offset + 6]) << 8 | UInt16(inner[offset + 7]),
            message: message
        )
    }

    private static func errorMessage(type: UInt8, code: UInt8, ipv6: Bool) -> String? {
        if ipv6 {
            switch type {
            case 1:
                switch code {
                case 0: return "No route to host"
                case 1: return "Administratively prohibited"
                case 3: return "Host unreachable"
                case 4: return "Port unreachable"
                default: return "Destination unreachable"
                }
            case 2: return "Packet too big"
            case 3: return "TTL expired in transit"
            case 4: return "Parameter problem"
            default: return nil
            }
        }
        switch type {
        case 3:
            switch code {
            case 0, 6, 11: return "Network unreachable"
            case 1, 7, 12: return "Host unreachable"
            case 2: return "Protocol unreachable"
            case 3: return "Port unreachable"
            case 4: return "Packet too big"
            case 5: return "Source route failed"
            case 9, 10, 13: return "Administratively prohibited"
            default: return "Destination unreachable"
            }
        case 11: return "TTL expired in transit"
        case 12: return "Parameter problem"
        default: return nil
        }
    }
}

/// Sends ICMP echo requests from this process over unprivileged datagram sockets, so thousands of hosts can be
/// in flight at once without starting a `ping` process for each one.
final class ICMPEngine: @unchecked Sendable {
    static let shared = ICMPEngine()

    private struct SocketKey: Hashable {
        var ipv6: Bool
        var source: String
    }

    private struct Channel {
        var fd: Int32
        var reader: DispatchSourceRead
        var ttl: Int32 = -2
        var dontFragment: Int32 = -1
    }

    private struct Pending {
        var ipv6: Bool
        var started: UInt64
        var timer: DispatchWorkItem
        var completion: @Sendable (ICMPReply) -> Void
    }

    private let queue = DispatchQueue(label: "PingInfoView.icmp", qos: .userInitiated)
    private let identifier = UInt16.random(in: 1...UInt16.max)
    private let token = UInt32.random(in: 1...UInt32.max)
    private var nextSequence = UInt16.random(in: 0...UInt16.max)
    private var channels: [SocketKey: Channel] = [:]
    private var unavailable: Set<Bool> = []
    private var pending: [UInt16: Pending] = [:]

    func ping(_ address: String, options: ICMPOptions, timeoutMs: Int) async -> ICMPReply {
        await withCheckedContinuation { continuation in
            queue.async {
                self.send(address, options: options, timeoutMs: max(100, timeoutMs), attempt: 0) { reply in
                    continuation.resume(returning: reply)
                }
            }
        }
    }

    private func send(_ address: String, options: ICMPOptions, timeoutMs: Int, attempt: Int, completion: @escaping @Sendable (ICMPReply) -> Void) {
        guard let destination = SocketAddress(numeric: address) else {
            completion(ICMPReply(success: false, error: "Not an IP address"))
            return
        }
        let ipv6 = destination.isIPv6
        let source = options.source
        let sourceMatches = source.isEmpty || (ipv6 ? HostParser.isIPv6Literal(source) : HostParser.ipv4Value(source) != nil)
        let key = SocketKey(ipv6: ipv6, source: sourceMatches ? source : "")
        guard var channel = channel(for: key) else {
            completion(ICMPReply(success: false, error: "ICMP is not available", unavailable: true))
            return
        }
        configure(&channel, ipv6: ipv6, options: options)
        channels[key] = channel

        guard let sequence = takeSequence() else {
            completion(ICMPReply(success: false, error: "Too many pings in flight"))
            return
        }
        let payloadLimit = ipv6 ? 65_487 : 65_507
        let packet = ICMPPacket.echoRequest(
            ipv6: ipv6,
            identifier: identifier,
            sequence: sequence,
            payload: ICMPPacket.payload(size: min(options.payloadSize, payloadLimit), token: token)
        )
        let started = DispatchTime.now().uptimeNanoseconds
        let sent = packet.withUnsafeBytes { bytes in
            destination.withSockaddr { address, length in
                sendto(channel.fd, bytes.baseAddress, bytes.count, 0, address, length)
            }
        }
        if sent < 0 {
            let code = errno
            if (code == ENOBUFS || code == EAGAIN) && attempt < 20 {
                queue.asyncAfter(deadline: .now() + .milliseconds(15)) {
                    self.send(address, options: options, timeoutMs: timeoutMs, attempt: attempt + 1, completion: completion)
                }
                return
            }
            completion(ICMPReply(success: false, error: NetworkErrors.message(errno: code), sendErrno: code))
            return
        }
        let timer = DispatchWorkItem { [weak self] in
            self?.finish(sequence, with: ICMPReply(success: false, error: "Timeout"))
        }
        pending[sequence] = Pending(ipv6: ipv6, started: started, timer: timer, completion: completion)
        queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timer)
    }

    private func takeSequence() -> UInt16? {
        for _ in 0..<Int(UInt16.max) {
            let candidate = nextSequence
            nextSequence &+= 1
            if pending[candidate] == nil { return candidate }
        }
        return nil
    }

    private func finish(_ sequence: UInt16, with reply: ICMPReply) {
        guard let entry = pending.removeValue(forKey: sequence) else { return }
        entry.timer.cancel()
        entry.completion(reply)
    }

    private func channel(for key: SocketKey) -> Channel? {
        if let existing = channels[key] { return existing }
        if unavailable.contains(key.ipv6) { return nil }
        let fd = socket(key.ipv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, key.ipv6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP)
        guard fd >= 0 else {
            unavailable.insert(key.ipv6)
            return nil
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var buffer: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        if key.ipv6 {
            setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_RECVHOPLIMIT, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        if !key.source.isEmpty, let source = SocketAddress(numeric: key.source) {
            let bound = source.withSockaddr { bind(fd, $0, $1) }
            if bound != 0 {
                close(fd)
                return nil
            }
        }
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let ipv6 = key.ipv6
        reader.setEventHandler { [weak self] in
            self?.drain(fd, ipv6: ipv6)
        }
        reader.setCancelHandler {
            close(fd)
        }
        reader.resume()
        return Channel(fd: fd, reader: reader)
    }

    private func configure(_ channel: inout Channel, ipv6: Bool, options: ICMPOptions) {
        let ttl: Int32 = options.ttl > 0 ? Int32(min(options.ttl, 255)) : (ipv6 ? -1 : 64)
        if channel.ttl != ttl {
            var value = ttl
            if ipv6 {
                setsockopt(channel.fd, Int32(IPPROTO_IPV6), IPV6_UNICAST_HOPS, &value, socklen_t(MemoryLayout<Int32>.size))
            } else {
                setsockopt(channel.fd, Int32(IPPROTO_IP), IP_TTL, &value, socklen_t(MemoryLayout<Int32>.size))
            }
            channel.ttl = ttl
        }
        let dontFragment: Int32 = options.dontFragment ? 1 : 0
        if channel.dontFragment != dontFragment {
            var value = dontFragment
            if ipv6 {
                setsockopt(channel.fd, Int32(IPPROTO_IPV6), 62, &value, socklen_t(MemoryLayout<Int32>.size))
            } else {
                setsockopt(channel.fd, Int32(IPPROTO_IP), 28, &value, socklen_t(MemoryLayout<Int32>.size))
            }
            channel.dontFragment = dontFragment
        }
    }

    private func drain(_ fd: Int32, ipv6: Bool) {
        var buffer = [UInt8](repeating: 0, count: 65_600)
        var control = [UInt8](repeating: 0, count: 256)
        while true {
            var name = sockaddr_storage()
            var count = 0
            var controlLength = 0
            let received = buffer.withUnsafeMutableBytes { data -> Int in
                control.withUnsafeMutableBytes { controlBytes -> Int in
                    withUnsafeMutablePointer(to: &name) { namePointer -> Int in
                        var vector = iovec(iov_base: data.baseAddress, iov_len: data.count)
                        return withUnsafeMutablePointer(to: &vector) { vectorPointer -> Int in
                            var message = msghdr(
                                msg_name: UnsafeMutableRawPointer(namePointer),
                                msg_namelen: socklen_t(MemoryLayout<sockaddr_storage>.size),
                                msg_iov: vectorPointer,
                                msg_iovlen: 1,
                                msg_control: controlBytes.baseAddress,
                                msg_controllen: socklen_t(controlBytes.count),
                                msg_flags: 0
                            )
                            let result = recvmsg(fd, &message, 0)
                            controlLength = Int(message.msg_controllen)
                            return result
                        }
                    }
                }
            }
            if received < 0 { return }
            count = received
            let arrived = DispatchTime.now().uptimeNanoseconds
            let hopLimit = ipv6 ? Self.hopLimit(control, length: controlLength) : nil
            let from = SocketAddress(storage: name, length: socklen_t(name.ss_len)).numericHost
            handle(Array(buffer[0..<count]), ipv6: ipv6, hopLimit: hopLimit, from: from, arrived: arrived)
        }
    }

    private func handle(_ bytes: [UInt8], ipv6: Bool, hopLimit: Int?, from: String?, arrived: UInt64) {
        switch ICMPPacket.parse(bytes, ipv6: ipv6, hopLimit: hopLimit) {
        case let .reply(replyID, sequence, ttl, payload):
            guard let entry = pending[sequence], entry.ipv6 == ipv6 else { return }
            let tokenMatches = ICMPPacket.token(in: payload) == token
            guard replyID == identifier || tokenMatches else { return }
            if payload.count >= 4 && !tokenMatches { return }
            let latency = Double(arrived &- entry.started) / 1_000_000
            finish(sequence, with: ICMPReply(success: true, latencyMs: latency, ttl: ttl, from: from))
        case let .failure(failureID, sequence, message):
            guard failureID == identifier, let entry = pending[sequence], entry.ipv6 == ipv6 else { return }
            finish(sequence, with: ICMPReply(success: false, from: from, error: message))
        case .other:
            return
        }
    }

    /// Reads IPV6_HOPLIMIT from the control messages; Darwin aligns `cmsghdr` data to 4 bytes.
    private static func hopLimit(_ control: [UInt8], length: Int) -> Int? {
        var offset = 0
        let header = 12
        while offset + header <= min(length, control.count) {
            let cmsgLength = Int(readUInt32(control, offset))
            let level = Int32(bitPattern: readUInt32(control, offset + 4))
            let type = Int32(bitPattern: readUInt32(control, offset + 8))
            guard cmsgLength >= header else { return nil }
            if level == IPPROTO_IPV6, type == IPV6_HOPLIMIT, offset + header + 4 <= control.count {
                return Int(Int32(bitPattern: readUInt32(control, offset + header)))
            }
            offset += (cmsgLength + 3) & ~3
        }
        return nil
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

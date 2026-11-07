import Darwin
import Foundation

/// A numeric IPv4 or IPv6 address ready for the BSD socket calls. IPv6 zones such as `fe80::1%en0` are kept.
struct SocketAddress: @unchecked Sendable {
    var storage = sockaddr_storage()
    var length: socklen_t = 0

    var isIPv6: Bool { Int32(storage.ss_family) == AF_INET6 }

    init?(numeric host: String, port: UInt16 = 0) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_DGRAM
        var info: UnsafeMutablePointer<addrinfo>?
        let service = port == 0 ? nil : String(port)
        guard getaddrinfo(host, service, &hints, &info) == 0, let info, let address = info.pointee.ai_addr else { return nil }
        defer { freeaddrinfo(info) }
        let size = Int(info.pointee.ai_addrlen)
        guard size <= MemoryLayout<sockaddr_storage>.size else { return nil }
        withUnsafeMutableBytes(of: &storage) { raw in
            raw.copyMemory(from: UnsafeRawBufferPointer(start: address, count: size))
        }
        length = info.pointee.ai_addrlen
    }

    init(storage: sockaddr_storage, length: socklen_t) {
        self.storage = storage
        self.length = length
    }

    var numericHost: String? {
        var copy = storage
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let code = withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard code == 0 else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
    }

    func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var copy = storage
        return withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }
}

enum NetworkErrors {
    static func message(errno code: Int32) -> String {
        switch code {
        case EHOSTUNREACH, EHOSTDOWN: "No route to host"
        case ENETUNREACH, ENETDOWN: "Network unreachable"
        case EADDRNOTAVAIL: "Source address is not on this Mac"
        case EMSGSIZE: "Packet too big"
        case EACCES, EPERM: "Not permitted"
        case ECONNREFUSED: "Connection refused"
        default: String(cString: strerror(code))
        }
    }

    /// 10/8, 172.16/12, 192.168/16, 169.254/16, and 100.64/10, where macOS Local Network permission applies.
    static func isPrivateIPv4(_ value: String) -> Bool {
        guard let ip = HostParser.ipv4Value(value) else { return false }
        let a = ip >> 24, b = (ip >> 16) & 255
        return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
    }
}
